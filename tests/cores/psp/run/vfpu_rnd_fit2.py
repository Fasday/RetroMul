import os, re
ROOT = os.path.dirname(os.path.abspath(__file__))
L = open(os.path.join(ROOT, 'pspautotests', 'tests', 'cpu', 'vfpu', 'vrnd.expected')).read().split('\n')
M = 0xFFFFFFFF


def unpack(rcx):
    w = [(rcx[i] & 0xFFFF) | ((rcx[i + 4] & 0xFFFF) << 16) for i in range(4)]
    c = 0
    for i in range(8):
        c |= ((rcx[i] >> 16) & 0xF) << (4 * i)
    return w, c


seqs = []
cur = []
for l in L:
    m = re.search(r'RCX: (.*)', l)
    if m and ('vrndi=' in l or 'after vrnds' in l or 'reads back' in l):
        rcx = [int(x, 16) for x in m.group(1).split()]
        if 'after vrnds' in l or 'reads back' in l:
            if cur:
                seqs.append(cur)
            cur = []
        cur.append(rcx)
if cur:
    seqs.append(cur)
out = []
for s in seqs:
    for a, b in zip(s, s[1:]):
        w, c = unpack(a)
        w2, c2 = unpack(b)
        st = w[2] + ((w[3] << 1) & M) + c
        sf = w[2] + 2 * w[3] + c
        out.append('w2=%08x w3=%08x c=%08x -> w3=%08x c=%x | trunc low=%08x hi=%x full hi=%x %s' % (
            w[2], w[3], c, w2[3], c2, st & M, st >> 32, sf >> 32, 'OK' if (st & M) == w2[3] else 'LOWBAD'))
open(os.environ.get('OUTF', 'rnd3.txt'), 'w').write('\n'.join(out) + '\n')
