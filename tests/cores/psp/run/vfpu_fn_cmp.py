"""Runs cpu/vfpu/exact through PSPRun and counts mismatching results per function."""
import os, subprocess, sys
from collections import Counter
ROOT = os.path.dirname(os.path.abspath(__file__))
T = os.path.join(ROOT, 'pspautotests', 'tests', 'cpu', 'vfpu')
EXE = os.path.join(ROOT, 'bin', 'PSPRun_win64.exe')
p = subprocess.run([EXE, os.path.join(T, 'exact.prx'), '-test', '-quiet', '-frames', '600'],
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
act = p.stdout.decode('latin1').replace('\r', '').split('\n')
exp = open(os.path.join(T, 'exact.expected')).read().split('\n')


def parse(lines):
    d = {}
    for line in lines:
        if not line or line.startswith('--'):
            continue
        parts = line.split()
        try:
            inp = int(parts[0].rstrip(':'), 16)
        except ValueError:
            continue
        for i in range(1, len(parts) - 1, 2):
            d[(parts[i], inp)] = int(parts[i + 1], 16)
    return d


A, E = parse(act), parse(exp)
bad = Counter()
tot = Counter()
samples = {}
for k, v in E.items():
    tot[k[0]] += 1
    if A.get(k) != v:
        bad[k[0]] += 1
        samples.setdefault(k[0], []).append((k[1], v, A.get(k)))
for fn in tot:
    print('%-6s %3d / %3d' % (fn, bad[fn], tot[fn]))
want = sys.argv[1] if len(sys.argv) > 1 else None
if want:
    for inp, v, a in samples.get(want, []):
        print('%08x exp %08x act %s' % (inp, v, '%08x' % a if a is not None else None))
