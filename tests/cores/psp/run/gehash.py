"""Frame hashes of games, to check that renderer changes leave every pixel as it was.

  gehash.py --record ref.txt [--jobs 4] [filter...]
  gehash.py --compare ref.txt [--jobs 1] [--env PSP_GE_THREADS=1] [filter...]

Each game runs with the same command line (1200 frames, Start at 500, Cross at
650, a hash every 100 frames); --record writes the 'frame N hash' lines per
game, --compare runs again and reports the games whose hashes differ. Host
seconds per game are printed either way (use --jobs 1 for timings).
"""
import argparse
import concurrent.futures
import os
import re
import subprocess
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
EXE = os.path.join(ROOT, 'bin', 'PSPRun_win64.exe')
GAMES = [
    'God of War - Chains of Olympus.iso',
    'MGS PW.cso',
    'SF DM.iso',
    'GTA LCS 01.09.2005 ULUX80146 V0.02.iso',
    'Tekken_6_[RUS].cso',
    'Star Wars The Force Unleashed rus.ISO',
    'Tony Hawks Underground 2 Remix.cso',
    'Ridge Racer 2.iso',
    'Daxter.iso',
]
ARGS = ['-frames', '1200', '-press', 'start@500:6', '-press', 'cross@650:6', '-every', '100']


def run(game, folder, env):
    e = dict(os.environ)
    e.update(env)
    t = time.time()
    p = subprocess.run([EXE, os.path.join(folder, game)] + ARGS, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e)
    err = p.stderr.decode('latin1', 'replace')
    hashes = [l.strip() for l in err.splitlines() if re.match(r'frame \d+ hash ', l)]
    tail = [l.strip() for l in err.splitlines() if l.startswith(('frames=', 'ERROR'))]
    return game, time.time() - t, hashes, tail, p.returncode


def load(path):
    ref = {}
    cur = None
    for l in open(path, encoding='utf8'):
        l = l.rstrip('\n')
        if l.startswith('== '):
            cur = l[3:]
            ref[cur] = []
        elif cur is not None and l.startswith('frame '):
            ref[cur].append(l)
    return ref


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('filters', nargs='*')
    ap.add_argument('--record')
    ap.add_argument('--compare')
    ap.add_argument('--dir', default=r'D:\Soft\PSP')
    ap.add_argument('--jobs', type=int, default=1)
    ap.add_argument('--env', action='append', default=[])
    a = ap.parse_args()
    env = dict(x.split('=', 1) for x in a.env)
    games = [g for g in GAMES if not a.filters or any(f.lower() in g.lower() for f in a.filters)]
    ref = load(a.compare) if a.compare else None
    recorded = load(a.record) if a.record and os.path.exists(a.record) else {}
    games = [g for g in games if g not in recorded]
    bad = 0
    with concurrent.futures.ThreadPoolExecutor(a.jobs) as ex:
        for game, secs, hashes, tail, code in ex.map(lambda g: run(g, a.dir, env), games):
            valid = code == 0 and len(hashes) == 12
            status = '' if valid else 'INCOMPLETE (exit %d, %d/12 hashes)' % (code, len(hashes))
            if ref is not None:
                want = ref.get(game)
                if want is None:
                    bad += 1
                    status = 'NO REFERENCE'
                elif valid and want == hashes:
                    status = 'same'
                else:
                    bad += 1
                    first = next((i for i in range(min(len(want), len(hashes))) if want[i] != hashes[i]), min(len(want), len(hashes)))
                    status = 'DIFFERS from %s %s' % (want[first].split()[1] if first < len(want) else 'the end', status)
            print('%-42s %7.1fs %s %s' % (game, secs, status, tail[-1] if tail else ''), flush=True)
            if a.record:
                if not valid:
                    raise RuntimeError('Cannot record an incomplete run: ' + game)
                with open(a.record, 'a', encoding='utf8') as f:
                    f.write('== ' + game + '\n' + '\n'.join(hashes) + '\n')
                    f.write('# host seconds %.3f\n' % secs)
    if ref is not None:
        print('%d of %d differ' % (bad, len(games)))
        raise SystemExit(1 if bad else 0)


if __name__ == '__main__':
    main()
