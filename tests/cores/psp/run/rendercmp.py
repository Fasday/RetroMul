"""Frames of games under the Vulkan renderers against the CPU reference.

  rendercmp.py [--frames 2400] [--every 120] [--jobs 3] [--out dir] [filter...]

Each image under D:\\Soft\\PSP (or those matching a filter) runs three times
with the same input (Start and Cross in turn from frame 500): the reference
(interpreter, PSPJIT=off, and every primitive drawn by the CPU renderer in
order, PSP_GE_THREADS=1), Vulkan LLE (-gpu) and Vulkan HLE (-gpu-hle, 1x).
Every captured frame is compared with the reference's: LLE must be the same
to the bit; for HLE the share of differing pixels, the mean channel error and
the PSNR are reported, and the worst frame of each game is saved side by side
(reference | HLE | difference x4) in the output directory.
"""
import argparse
import concurrent.futures
import math
import os
import re
import subprocess
import tempfile
import time

import numpy as np

ROOT = os.path.dirname(os.path.abspath(__file__))
EXE = os.path.join(ROOT, 'bin', 'PSPRun_win64.exe')
FOLDER = r'D:\Soft\PSP'
MODES = (('ref', [], {'PSPJIT': 'off', 'PSP_GE_THREADS': '1'}),
         ('lle', ['-gpu'], {}),
         ('hle', ['-gpu-hle', '-scale', '1'], {}))


def read_bmp(path):
    d = open(path, 'rb').read()
    off = int.from_bytes(d[10:14], 'little')
    w = int.from_bytes(d[18:22], 'little', signed=True)
    h = int.from_bytes(d[22:26], 'little', signed=True)
    bpp = int.from_bytes(d[28:30], 'little')
    row = ((w * bpp // 8) + 3) & ~3
    a = np.frombuffer(d, dtype=np.uint8, count=row * abs(h), offset=off).reshape(abs(h), row)
    a = a[:, :w * bpp // 8].reshape(abs(h), w, bpp // 8)[:, :, :3]
    if h > 0:
        a = a[::-1]
    return a[:, :, ::-1]  # RGB


def write_bmp(path, rgb):
    h, w, _ = rgb.shape
    row = (w * 3 + 3) & ~3
    data = np.zeros((h, row), dtype=np.uint8)
    data[:, :w * 3] = rgb[::-1, :, ::-1].reshape(h, w * 3)
    size = 54 + data.size
    hdr = b'BM' + size.to_bytes(4, 'little') + b'\0' * 4 + (54).to_bytes(4, 'little')
    hdr += (40).to_bytes(4, 'little') + w.to_bytes(4, 'little') + h.to_bytes(4, 'little') + (1).to_bytes(2, 'little')
    hdr += (24).to_bytes(2, 'little') + b'\0' * 4 + data.size.to_bytes(4, 'little') + b'\0' * 16
    open(path, 'wb').write(hdr + data.tobytes())


def run(path, mode, frames, every, out):
    name, flags, env = mode
    args = [EXE, path, '-frames', str(frames), '-every', str(every), '-out', out] + flags
    k = 0
    for f in range(500, frames, 75):
        args += ['-press', ('start@%d' if k % 2 == 0 else 'cross@%d') % f]
        k += 1
    e = dict(os.environ)
    e.update(env)
    t = time.time()
    p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e)
    err = p.stderr.decode('latin1', 'replace')
    return p.returncode, err, time.time() - t


def compare(path, args):
    title = os.path.splitext(os.path.basename(path))[0]
    with tempfile.TemporaryDirectory(prefix='rendercmp-', dir=args.temp) as tmp:
        runs = {}
        for mode in MODES:
            d = os.path.join(tmp, mode[0])
            os.makedirs(d)
            code, err, secs = run(path, mode, args.frames, args.every, d)
            gpu = re.findall(r'^gpu[^\n]*', err, re.M)
            runs[mode[0]] = (d, code, secs, gpu)
        ref = sorted(f for f in os.listdir(runs['ref'][0]) if f.startswith('f') and f.endswith('.bmp'))
        res = {'title': title, 'frames': len(ref), 'secs': {k: v[2] for k, v in runs.items()},
               'codes': {k: v[1] for k, v in runs.items()}, 'gpu': {k: v[3][-1:] for k, v in runs.items()}}
        lle_same = lle_n = 0
        lle_bad = []
        hle = []
        worst = None
        for f in ref:
            a = read_bmp(os.path.join(runs['ref'][0], f))
            lp = os.path.join(runs['lle'][0], f)
            if os.path.exists(lp):
                lle_n += 1
                b = read_bmp(lp)
                same = b.shape == a.shape and bool((a == b).all())
                lle_same += same
                if not same:
                    lle_bad.append(f)
            hp = os.path.join(runs['hle'][0], f)
            if os.path.exists(hp):
                c = read_bmp(hp)
                if c.shape != a.shape:
                    hle.append((f, 1.0, 255.0, 0.0))
                    continue
                d = np.abs(a.astype(int) - c.astype(int))
                share = float((d.max(axis=2) > 0).mean())
                mean = float(d.mean())
                mse = float((d ** 2).mean())
                psnr = 99.0 if mse == 0 else 10 * math.log10(255 * 255 / mse)
                hle.append((f, share, mean, psnr))
                if worst is None or mse > worst[0]:
                    worst = (mse, f, a, c, d)
        res['lle'] = (lle_same, lle_n, lle_bad)
        res['hle'] = hle
        if worst is not None and worst[0] > 0:
            mse, f, a, c, d = worst
            side = np.concatenate([a, c, np.clip(d * 4, 0, 255).astype(np.uint8)], axis=1)
            write_bmp(os.path.join(args.out, '%s_%s.bmp' % (re.sub(r'[^\w.-]+', '_', title)[:60], f[:-4])), side)
        return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('filters', nargs='*')
    ap.add_argument('--frames', type=int, default=2400)
    ap.add_argument('--every', type=int, default=120)
    ap.add_argument('--jobs', type=int, default=3)
    ap.add_argument('--out', default=os.path.join(os.environ.get('LOCALAPPDATA', tempfile.gettempdir()), 'Temp', 'opencode',
                                                  'rendercmp'))
    ap.add_argument('--temp', default=os.path.join(os.environ.get('LOCALAPPDATA', tempfile.gettempdir()), 'Temp', 'opencode'))
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    os.makedirs(args.temp, exist_ok=True)
    images = sorted(os.path.join(dp, f) for dp, dn, fn in os.walk(FOLDER) for f in fn
                    if f.lower().endswith(('.iso', '.cso', '.pbp'))
                    and (not args.filters or any(x.lower() in os.path.join(dp, f).lower() for x in args.filters)))
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        results = list(pool.map(lambda p: compare(p, args), images))
    report = []
    tot_lle = [0, 0]
    tot_hle = []
    for r in sorted(results, key=lambda r: r['title'].lower()):
        ls, ln, lbad = r['lle']
        tot_lle[0] += ls
        tot_lle[1] += ln
        tot_hle += r['hle']
        h = r['hle']
        if h:
            share = sum(x[1] for x in h) / len(h)
            mean = sum(x[2] for x in h) / len(h)
            psnr = min(x[3] for x in h)
            hs = 'HLE pixels differ %5.1f%% mean err %5.2f worst PSNR %5.1f dB' % (share * 100, mean, psnr)
        else:
            hs = 'HLE no frames'
        codes = ' '.join('%s=%s' % kv for kv in r['codes'].items() if kv[1])
        line = '%-50s frames %3d  LLE same %3d/%-3d  %s  %s' % (r['title'][:50], r['frames'], ls, ln, hs, codes)
        if lbad:
            line += '  LLE differs: ' + ' '.join(lbad[:6])
        report.append(line)
        print(line, flush=True)
    summary = 'LLE: %d of %d frames bit-identical' % tuple(tot_lle)
    if tot_hle:
        summary += '; HLE: %.1f%% of pixels differ on average, mean channel error %.2f, frames at or above 30 dB ' \
                   'PSNR %d of %d' % (100 * sum(x[1] for x in tot_hle) / len(tot_hle), sum(x[2] for x in tot_hle) / len(tot_hle),
                                      sum(1 for x in tot_hle if x[3] >= 30), len(tot_hle))
    report.append(summary)
    print(summary)
    open(os.path.join(args.out, 'report.txt'), 'w', encoding='utf8').write('\n'.join(report) + '\n')


if __name__ == '__main__':
    main()
