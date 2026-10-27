"""Boots every game image in a folder for N frames and records how far it got.

  smoke.py [filter...] [--dir D:\\Soft\\PSP] [--frames 1800] [--jobs 4] [--out smoke.txt] [--shots DIR]
For each game: exit status, frames run, guest seconds, last frame hash, the
error if it stopped, and the most frequent unimplemented functions.
"""
import argparse
import concurrent.futures
import os
import re
import subprocess

ROOT = os.path.dirname(os.path.abspath(__file__))
EXE = os.path.join(ROOT, 'bin', 'PSPRun_win64.exe')


def images(folder, filters):
    out = []
    for dp, dn, fn in os.walk(folder):
        for f in sorted(fn):
            if f.lower().endswith(('.iso', '.cso')):
                p = os.path.join(dp, f)
                if not filters or any(x.lower() in p.lower() for x in filters):
                    out.append(p)
    return out


def run(path, exe, frames, timeout, shots, mash=0):
    args = [exe, path, '-frames', str(frames)]
    # From frame `mash` on, Start and Cross in turn every 150 frames, to get
    # through notices, title screens and menus.
    if mash:
        for k, f in enumerate(range(mash, frames, 75)):
            args += ['-press', '%s@%d:6' % ('start' if k % 2 == 0 else 'cross', f)]
    if shots:
        d = os.path.join(shots, re.sub(r'[^A-Za-z0-9_.-]+', '_', os.path.basename(path)))
        os.makedirs(d, exist_ok=True)
        args += ['-out', d, '-every', str(max(1, frames // 6))]
    try:
        p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        out = p.stdout.decode('latin1', 'replace')
        err = p.stderr.decode('latin1', 'replace')
        code = p.returncode
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b'').decode('latin1', 'replace')
        err = (e.stderr or b'').decode('latin1', 'replace') + '\ntimeout'
        code = -1
    return path, code, out, err


def summarize(path, code, out, err):
    lines = err.splitlines()
    info = next((l for l in lines if l.startswith('frames=')), '')
    error = next((l for l in lines if l.startswith('ERROR:')), '')
    title = next((l for l in lines if l.startswith('title=')), '')
    unimpl = [re.sub(r' \(a0=.*', '', l) for l in lines if l.startswith('unimplemented')]
    status = 'OK' if code == 0 else ('TIMEOUT' if code == -1 else 'STOP')
    s = '%-7s %s\n  %s\n  %s\n' % (status, os.path.basename(path), title, info)
    if error:
        s += '  %s\n' % error
        pc = next((l for l in lines if l.startswith('pc=')), '')
        if pc:
            s += '  %s\n' % pc
    if unimpl:
        s += '  unimplemented: %s\n' % ', '.join(u.replace('unimplemented ', '') for u in unimpl[:25])
    tail = [l for l in out.splitlines() if l.strip()][-3:]
    if tail:
        s += '  stdout: %s\n' % ' | '.join(t[:120] for t in tail)
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('filters', nargs='*')
    ap.add_argument('--dir', default=r'D:\Soft\PSP')
    ap.add_argument('--exe', default=EXE)
    ap.add_argument('--frames', type=int, default=1800)
    ap.add_argument('--timeout', type=int, default=600)
    ap.add_argument('--jobs', type=int, default=4)
    ap.add_argument('--out', default=os.path.join(ROOT, 'smoke.txt'))
    ap.add_argument('--shots', default='')
    ap.add_argument('--mash', type=int, default=0, help='press Start/Cross in turn from this frame on')
    args = ap.parse_args()
    imgs = images(args.dir, args.filters)
    results = []
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as ex:
        futs = [ex.submit(run, p, args.exe, args.frames, args.timeout, args.shots, args.mash) for p in imgs]
        for f in concurrent.futures.as_completed(futs):
            results.append(f.result())
    results.sort()
    with open(args.out, 'w', encoding='utf8') as fo:
        for r in results:
            s = summarize(*r)
            fo.write(s)
            print(s, end='')


if __name__ == '__main__':
    main()
