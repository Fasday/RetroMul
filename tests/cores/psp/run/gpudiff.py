"""Differential test of the GE's GPU renderer against the CPU renderer.

  gpudiff.py [filter...] [--check] [--exe PATH] [--frames N] [--jobs N] [--games] [--out FILE]

Default: every pspautotests test with a screenshot (default filter gpu/) runs
twice, on the CPU and with -gpu; output and screenshot must be identical.
--check: runs once with -gpu-check, where every batch is drawn by both and
compared in VRAM (the run follows the CPU's result).
--games: the filters are disc images; runs each for --frames frames with
-every 60 and compares the frame hashes of the two runs (with --check: one
-gpu-check run).
"""
import argparse
import concurrent.futures
import os
import re
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.abspath(__file__))
TESTS = os.environ.get('PSP_AUTOTESTS') or os.path.join(ROOT, 'pspautotests', 'tests')
EXE = os.path.join(ROOT, 'bin', 'PSPRun_win64.exe')


def collect(filters):
    out = []
    for dp, dn, fn in os.walk(TESTS):
        for f in fn:
            if f.endswith('.prx'):
                base = os.path.join(dp, f[:-4])
                if os.path.exists(base + '.expected'):
                    rel = os.path.relpath(base, TESTS).replace('\\', '/')
                    if any(x in rel for x in filters):
                        out.append(rel)
    return sorted(out)


def execute(args, timeout):
    try:
        p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        return p.returncode, p.stdout.decode('latin1'), p.stderr.decode('latin1')
    except subprocess.TimeoutExpired as e:
        return -1, (e.stdout or b'').decode('latin1'), 'timeout'


def read(path):
    try:
        return open(path, 'rb').read()
    except OSError:
        return None


def first_diff(a, b):
    if a is None or b is None or len(a) != len(b):
        return 'missing or size differs'
    off = int.from_bytes(a[10:14], 'little')
    for i in range(off, len(a), 4):
        if a[i:i + 4] != b[i:i + 4]:
            p = (i - off) // 4
            return 'first at x=%d y=%d cpu %s gpu %s' % (p % 512, 271 - p // 512, a[i:i + 4][::-1].hex(), b[i:i + 4][::-1].hex())
    return ''


def gpu_lines(err):
    return [l for l in err.splitlines() if l.startswith('gpu')]


def run_test(rel, exe, frames, timeout, check):
    base = os.path.join(TESTS, rel)
    if check:
        code, out, err = execute([exe, base + '.prx', '-test', '-quiet', '-frames', str(frames), '-gpu-check'], timeout)
        m = re.search(r'gpu check: (\d+) of (\d+) batches differ', err)
        if code == -1:
            return rel, 'TIMEOUT', ''
        if not m:
            return rel, 'NOGPU', '\n'.join(gpu_lines(err)[:6] or err.splitlines()[-4:])
        status = 'SAME' if m.group(1) == '0' else 'DIFF'
        return rel, status, '\n'.join(gpu_lines(err)[:12])
    shots = []
    results = []
    for mode in ('', '-gpu'):
        fd, shot = tempfile.mkstemp(suffix='.bmp')
        os.close(fd)
        os.unlink(shot)
        shots.append(shot)
        args = [exe, base + '.prx', '-test', '-quiet', '-frames', str(frames), '-shot', shot]
        if mode:
            args.append(mode)
        results.append(execute(args, timeout))
    a, b = read(shots[0]), read(shots[1])
    for s in shots:
        try:
            os.unlink(s)
        except OSError:
            pass
    notes = []
    if results[0][1] != results[1][1]:
        notes.append('stdout differs')
    if a != b:
        notes.append('screenshot differs: ' + first_diff(a, b))
    if results[0][0] != results[1][0]:
        notes.append('exit code %d vs %d' % (results[0][0], results[1][0]))
    notes += gpu_lines(results[1][2])[:6]
    status = 'SAME' if len(notes) == len(gpu_lines(results[1][2])[:6]) else 'DIFF'
    if 'unavailable' in results[1][2]:
        status = 'NOGPU'
    return rel, status, '\n'.join(notes)


def run_game(image, exe, frames, timeout, check):
    if check:
        code, out, err = execute([exe, image, '-frames', str(frames), '-gpu-check', '-quiet'], timeout)
        m = re.search(r'gpu check: (\d+) of (\d+) batches differ', err)
        notes = gpu_lines(err)[:12]
        if not m:
            return image, 'NOGPU' if code != -1 else 'TIMEOUT', '\n'.join(notes or err.splitlines()[-4:])
        return image, 'SAME' if m.group(1) == '0' else 'DIFF', '\n'.join(notes)
    hashes = []
    errs = []
    for mode in ('', '-gpu'):
        args = [exe, image, '-frames', str(frames), '-every', '60']
        if mode:
            args.append(mode)
        code, out, err = execute(args, timeout)
        hashes.append(re.findall(r'frame (\d+) hash (\w+)', err))
        errs.append(err)
    notes = gpu_lines(errs[1])[:6]
    for (fa, ha), (fb, hb) in zip(hashes[0], hashes[1]):
        if ha != hb:
            notes.insert(0, 'frame %s differs' % fa)
            return image, 'DIFF', '\n'.join(notes)
    if len(hashes[0]) != len(hashes[1]):
        notes.insert(0, '%d vs %d frames' % (len(hashes[0]), len(hashes[1])))
        return image, 'DIFF', '\n'.join(notes)
    times = [re.search(r'time=([\d.,]+)s', e) for e in errs]
    notes.insert(0, 'cpu %s s, gpu %s s, %d frames hashed' % (times[0] and times[0].group(1), times[1] and times[1].group(1),
                                                             len(hashes[0])))
    return image, 'SAME', '\n'.join(notes)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('filters', nargs='*')
    ap.add_argument('--exe', default=EXE)
    ap.add_argument('--frames', type=int, default=1200)
    ap.add_argument('--jobs', type=int, default=4)
    ap.add_argument('--timeout', type=int, default=120)
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--games', action='store_true')
    ap.add_argument('--out', default=os.path.join(ROOT, 'gpudiff.txt'))
    args = ap.parse_args()
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as ex:
        if args.games:
            futs = [ex.submit(run_game, g, args.exe, args.frames, args.timeout * 20, args.check) for g in args.filters]
        else:
            tests = collect(args.filters or ['gpu/'])
            futs = [ex.submit(run_test, t, args.exe, args.frames, args.timeout, args.check) for t in tests]
        results = sorted(f.result() for f in concurrent.futures.as_completed(futs))
    counts = {}
    with open(args.out, 'w', encoding='utf8') as fo:
        for rel, st, notes in results:
            counts[st] = counts.get(st, 0) + 1
            fo.write('%s %s\n' % (st, rel))
            if notes and (st != 'SAME' or args.games):
                fo.write('  ' + notes.replace('\n', '\n  ') + '\n')
    for rel, st, notes in results:
        if st != 'SAME' or args.games:
            print('%-7s %s' % (st, rel))
            if notes:
                print('  ' + notes.replace('\n', '\n  '))
    print(' '.join('%s=%d' % kv for kv in sorted(counts.items())), 'total=%d' % len(results))


if __name__ == '__main__':
    main()
