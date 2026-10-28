"""Frame hashes of games with the CPU renderer's queue against drawing at once.

  queuecheck.py [--frames 2400] [--every 200] [--jobs 3] [filter...]

Each game runs twice with the same input (Start and Cross in turn from frame
500): with PSP_GE_THREADS=1 (every primitive drawn when the GE reaches it) and
with the default pool (queued, banded, in the background). Every captured frame
must hash the same. Host seconds of both runs are printed.
"""
import argparse
import concurrent.futures
import os
import re
import subprocess
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
EXE = os.path.join(ROOT, 'bin', 'PSPRun_win64.exe')
FOLDER = r'D:\Soft\PSP'


def run(path, frames, every, env):
    args = [EXE, path, '-frames', str(frames), '-every', str(every)]
    k = 0
    for f in range(500, frames, 75):
        args += ['-press', ('start@%d' if k % 2 == 0 else 'cross@%d') % f]
        k += 1
    e = dict(os.environ)
    e.update(env)
    t = time.time()
    p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e)
    err = p.stderr.decode('latin1', 'replace')
    hashes = re.findall(r'frame (\d+) hash (\w+)', err)
    return hashes, time.time() - t


def check(path, frames, every):
    a, ta = run(path, frames, every, {'PSP_GE_THREADS': '1'})
    b, tb = run(path, frames, every, {})
    bad = [f for (f, h), (g, k) in zip(a, b) if h != k]
    ok = len(a) == len(b) and len(a) > 0 and not bad
    return path, ok, len(a), bad[:3], ta, tb


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--frames', type=int, default=2400)
    ap.add_argument('--every', type=int, default=200)
    ap.add_argument('--jobs', type=int, default=3)
    ap.add_argument('filters', nargs='*')
    args = ap.parse_args()
    games = []
    for root, _, files in os.walk(FOLDER):
        for f in files:
            if f.lower().endswith(('.iso', '.cso')):
                p = os.path.join(root, f)
                if not args.filters or any(x.lower() in p.lower() for x in args.filters):
                    games.append(p)
    failed = 0
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as ex:
        for path, ok, n, bad, ta, tb in ex.map(lambda g: check(g, args.frames, args.every), sorted(games)):
            failed += not ok
            print('%-6s %-60s %2d frames  serial %6.1fs  queued %6.1fs %s' % (
                'SAME' if ok else 'DIFF', os.path.basename(path)[:60], n, ta, tb, ' '.join(bad)), flush=True)
    print('%d of %d differ' % (failed, len(games)))
    return 1 if failed else 0


if __name__ == '__main__':
    raise SystemExit(main())
