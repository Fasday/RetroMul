"""Runs pspautotests through PSPRun and compares with .expected.

  autotests.py [filter...] [--exe PATH] [--frames N] [--jobs N] [--out FILE] [--show]
Results: PASS / FAIL (diff) / CRASH / TIMEOUT. Writes a summary file.
"""
import argparse
import concurrent.futures
import difflib
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(ROOT, 'pspautotests', 'tests')
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


def run(rel, exe, frames, timeout):
    base = os.path.join(TESTS, rel)
    try:
        p = subprocess.run([exe, base + '.prx', '-test', '-quiet', '-frames', str(frames)],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        out = p.stdout.decode('latin1')
        err = p.stderr.decode('latin1')
        code = p.returncode
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b'').decode('latin1')
        err = 'timeout'
        code = -1
    exp = open(base + '.expected', 'rb').read().decode('latin1')
    a, b = normalize(exp), normalize(out)
    if a == b:
        return rel, 'PASS', '', err
    status = 'FAIL'
    if code == -1:
        status = 'TIMEOUT'
    elif code != 0:
        status = 'CRASH'
    diff = '\n'.join(list(difflib.unified_diff(a, b, 'expected', 'actual', lineterm='', n=1))[:40])
    return rel, status, diff, err


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('filters', nargs='*')
    ap.add_argument('--exe', default=EXE)
    ap.add_argument('--frames', type=int, default=1200)
    ap.add_argument('--jobs', type=int, default=10)
    ap.add_argument('--timeout', type=int, default=60)
    ap.add_argument('--out', default=os.path.join(ROOT, 'autotests.txt'))
    ap.add_argument('--show', action='store_true')
    args = ap.parse_args()
    tests = collect(args.filters)
    results = []
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as ex:
        futs = [ex.submit(run, t, args.exe, args.frames, args.timeout) for t in tests]
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
