"""Reverse engineering of vrnds/vrndi from vrnd.expected."""
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


seeds = {}
cur = None
for l in L:
    m = re.match(r'-- seed (\w+) --', l)
    if m:
        cur = int(m.group(1), 16)
        seeds[cur] = {'states': [], 'outs': [], 'next': []}
        continue
    if cur is None:
        continue
    if l.startswith('-- '):
        cur = None
        continue
    m = re.match(r'(after vrnds|vrndi=(\w+)) RCX: (.*)', l)
    if m:
        rcx = [int(x, 16) & 0x7FFFFF for x in m.group(3).split()]
        seeds[cur]['states'].append(rcx)
        if m.group(2):
            seeds[cur]['outs'].append(int(m.group(2), 16))
        continue
    if l.startswith('next 40:') or l.startswith('        '):
        seeds[cur]['next'] += [int(x, 16) for x in l.replace('next 40:', '').split()]

out = []
for s, d in seeds.items():
    out.append('seed %08x' % s)
    for st in d['states']:
        out.append('  ' + ' '.join('%05x' % x for x in st))
    # words from halves
    for k, st in enumerate(d['states'][1:]):
        w = [((st[i + 4] & 0xFFFF) << 16) | (st[i] & 0xFFFF) for i in range(4)]
        o = d['outs'][k]
        out.append('  w=%s out=%08x  w0+w1+w3=%08x' % (' '.join('%08x' % x for x in w), o, (w[0] + w[1] + w[3]) & M))
open(os.environ.get('OUTF', 'rnd.txt'), 'w').write('\n'.join(out) + '\n')
