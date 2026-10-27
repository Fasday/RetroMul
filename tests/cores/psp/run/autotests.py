"""Runs pspautotests through PSPRun and compares with what a real PSP printed
(.expected) and drew (.expected.bmp, the 512x272 BGRA framebuffer).

  autotests.py [filter...] [--exe PATH] [--frames N] [--jobs N] [--out FILE] [--show] [--keep DIR]
Results: PASS / FAIL / CRASH / TIMEOUT. Writes a summary file (default autotests.txt).
Environment: PSP_AUTOTESTS overrides the test folder.
"""
import argparse
import concurrent.futures
import difflib
import os
import struct
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
                    if not filters or any(x in rel for x in filters):
                        out.append(rel)
    return sorted(out)


def normalize(s):
    lines = s.replace('\r\n', '\n').replace('\r', '\n').split('\n')
    while lines and lines[-1].strip() == '':
        lines.pop()
    return [l.rstrip() for l in lines]


def compare_bmp(expected, actual):
    """Returns (differing pixels, differing ignoring alpha, first difference)."""
    a = open(expected, 'rb').read()
    try:
        b = open(actual, 'rb').read()
    except OSError:
        return -1, -1, 'no screenshot'
    if len(a) != len(b):
        return -1, -1, 'size %d vs %d' % (len(a), len(b))
    off = struct.unpack_from('<I', a, 10)[0]
    pa = memoryview(a)[off:]
    pb = memoryview(b)[off:]
    n = len(pa) // 4
    diff = 0
    diff_rgb = 0
    first = ''
    ia = struct.iter_unpack('<I', pa)
    ib = struct.iter_unpack('<I', pb)
    for i, ((x,), (y,)) in enumerate(zip(ia, ib)):
        if x != y:
            diff += 1
            if (x ^ y) & 0xFFFFFF:
                diff_rgb += 1
                if not first:
                    row = 271 - i // 512
                    first = 'first at x=%d y=%d expected %08x got %08x' % (i % 512, row, x, y)
    return diff, diff_rgb, first


def run(rel, exe, frames, timeout, keep):
    base = os.path.join(TESTS, rel)
    has_bmp = os.path.exists(base + '.expected.bmp')
    shot = None
    args = [exe, base + '.prx', '-test', '-quiet', '-frames', str(frames)]
    if has_bmp:
        if keep:
            shot = os.path.join(keep, rel.replace('/', '_') + '.bmp')
        else:
            fd, shot = tempfile.mkstemp(suffix='.bmp')
            os.close(fd)
            os.unlink(shot)
        args += ['-shot', shot]
    try:
        p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        out = p.stdout.decode('latin1')
        err = p.stderr.decode('latin1')
        code = p.returncode
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b'').decode('latin1')
        err = 'timeout'
        code = -1
    exp = open(base + '.expected', 'rb').read().decode('latin1')
    a, b = normalize(exp), normalize(out)
    text_ok = a == b
    bmp_note = ''
    bmp_ok = True
    if has_bmp:
        d, drgb, first = compare_bmp(base + '.expected.bmp', shot)
        bmp_ok = d == 0
        if not bmp_ok:
            bmp_note = 'screenshot: %d pixels differ (%d in color) %s' % (d, drgb, first)
        if not keep:
            try:
                os.unlink(shot)
            except OSError:
                pass
    if text_ok and bmp_ok:
        return rel, 'PASS', '', err
    status = 'FAIL'
    if code == -1:
        status = 'TIMEOUT'
    elif code != 0:
        status = 'CRASH'
    diff = ''
    if not text_ok:
        diff = '\n'.join(list(difflib.unified_diff(a, b, 'expected', 'actual', lineterm='', n=1))[:40])
    if bmp_note:
        diff = (diff + '\n' + bmp_note).strip()
    return rel, status, diff, err


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('filters', nargs='*')
    ap.add_argument('--exe', default=EXE)
    ap.add_argument('--frames', type=int, default=1200)
    ap.add_argument('--jobs', type=int, default=8)
    ap.add_argument('--timeout', type=int, default=60)
    ap.add_argument('--out', default=os.path.join(ROOT, 'autotests.txt'))
    ap.add_argument('--keep', default='')
    ap.add_argument('--show', action='store_true')
    args = ap.parse_args()
    if args.keep:
        os.makedirs(args.keep, exist_ok=True)
    tests = collect(args.filters)
    results = []
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as ex:
        futs = [ex.submit(run, t, args.exe, args.frames, args.timeout, args.keep) for t in tests]
        for f in concurrent.futures.as_completed(futs):
            results.append(f.result())
    results.sort()
    counts = {}
    with open(args.out, 'w', encoding='utf8') as fo:
        for rel, st, diff, err in results:
            counts[st] = counts.get(st, 0) + 1
            fo.write('%s %s\n' % (st, rel))
        fo.write('\n')
        for rel, st, diff, err in results:
            if st != 'PASS':
                fo.write('==== %s %s\n%s\n' % (st, rel, diff))
                errl = [l for l in err.splitlines() if l.strip()][:12]
                if errl:
                    fo.write('-- stderr:\n' + '\n'.join(errl) + '\n')
    for rel, st, diff, err in results:
        if args.show or st != 'PASS':
            print('%-8s %s' % (st, rel))
            if args.show and st != 'PASS':
                print(diff)
                print('\n'.join([l for l in err.splitlines() if l.strip()][:8]))
    print(' '.join('%s=%d' % kv for kv in sorted(counts.items())), 'total=%d' % len(results))


if __name__ == '__main__':
    main()
