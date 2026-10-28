import os, re
ROOT = os.path.dirname(os.path.abspath(__file__))
L = open(os.path.join(ROOT, 'pspautotests', 'tests', 'cpu', 'vfpu', 'vrnd.expected')).read().split('\n')
M = 0xFFFFFFFF
# Exact single-draw transitions from consecutive RCX dumps.


def state(regs):
    lo = [r & 0xFFFF for r in regs]
    nib = [(r >> 16) & 0xF for r in regs]
    w = [lo[i] | (lo[i + 4] << 16) for i in range(4)]
    c = 0
    for i in range(8):
        c |= nib[i] << (4 * i)
    return w, c


prev = None
for l in L:
    m = re.search(r'RCX: ((?:[0-9a-f]{8} ?){8})', l)
    if not m:
        if l.startswith('--') or l.startswith('wrote') or 'vrndi.q' in l or 'vrndf' in l:
            prev = None if not l.startswith('wrote') else prev
        continue
    regs = [int(x, 16) for x in m.group(1).split()]
    st = state(regs)
    single = l.lstrip().startswith('vrndi=')
    if prev is not None and single:
        (w0, w1, w2, w3), c = prev
        (n0, n1, n2, n3), nc = st
        S = w2 + 2 * w3 + c
        ok = (S & M) == n3 and n2 == w3
        T = w2 + ((w3 << 1) & M) + c
        print('w2=%08x w3=%08x c=%08x -> nw=%08x %s  full=%d trunc=%d awc=%d  ncarry=%x  w0=%08x w1=%08x n0=%08x n1=%08x' % (
            w2, w3, c, n3, 'ok' if ok else 'BAD', S >> 32, T >> 32, (w2 + w3 + c) >> 32, nc, w0, w1, n0, n1))
    prev = st
