"""Derives the add-with-carry word sequence from the 40-draw runs and lists the carries."""
import os, re
ROOT = os.path.dirname(os.path.abspath(__file__))
L = open(os.path.join(ROOT, 'pspautotests', 'tests', 'cpu', 'vfpu', 'vrnd.expected')).read().split('\n')
M = 0xFFFFFFFF


def lcg(x):
    return (x * 69069 + 1) & M


def xs(j):
    j ^= (j << 13) & M
    j ^= j >> 17
    j ^= (j << 5) & M
    return j


rows = []
cur = None
for l in L:
    m = re.match(r'-- seed (\w+) --', l)
    if m:
        cur = {'seed': int(m.group(1), 16), 'outs': []}
        rows.append(cur)
        continue
    if cur is None:
        continue
    if l.startswith('-- '):
        cur = None
        continue
    m = re.match(r'vrndi=(\w+)', l)
    if m:
        cur['outs'].append(int(m.group(1), 16))
    if l.startswith('next 40:') or l.startswith('        '):
        cur['outs'] += [int(x, 16) for x in l.replace('next 40:', '').split()]

out = []
for r in rows:
    s = r['seed']
    w0 = w1 = s
    w3s = [s, s]  # w2, w3 at seeding
    for o in r['outs']:
        w0 = lcg(w0)
        w1 = xs(w1)
        w3s.append((o - w0 - w1) & M)
    out.append('seed %08x' % s)
    c = s
    for n in range(2, len(w3s)):
        w2, w3, nw = w3s[n - 2], w3s[n - 1], w3s[n]
        cin = (nw - w2 - ((w3 << 1) & M)) & M
        tr = w2 + ((w3 << 1) & M) + cin
        fu = w2 + 2 * w3 + cin
        out.append('  %08x %08x cin=%08x -> %08x  trunc_hi=%d full_hi=%d' % (w2, w3, cin, nw, tr >> 32, fu >> 32))
open(os.environ.get('OUTF', 'rnd4.txt'), 'w').write('\n'.join(out) + '\n')
