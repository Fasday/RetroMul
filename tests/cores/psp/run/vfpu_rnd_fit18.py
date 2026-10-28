import os, re, sys, itertools
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# Exact transitions from the RCX dumps: search sums of up to three state words (each possibly
# doubled) whose carry-out gives the new carry.
ROOT = os.path.dirname(os.path.abspath(__file__))
L = open(os.path.join(ROOT, 'pspautotests', 'tests', 'cpu', 'vfpu', 'vrnd.expected')).read().split('\n')
M = 0xFFFFFFFF


def state(regs):
    lo = [r & 0xFFFF for r in regs]
    nib = [(r >> 16) & 0xF for r in regs]
    w = [lo[i] | (lo[i + 4] << 16) for i in range(4)]
    c = 0
    for i in range(8):
        c |= nib[i] << (4 * i)
    return w, c


T = []
prev = None
for l in L:
    m = re.search(r'RCX: ((?:[0-9a-f]{8} ?){8})', l)
    if not m:
        continue
    regs = [int(x, 16) for x in m.group(1).split()]
    st = state(regs)
    if prev is not None and l.lstrip().startswith('vrndi='):
        (w0, w1, w2, w3), c = prev
        (n0, n1, n2, n3), nc = st
        T.append(dict(w0=w0, w1=w1, w2=w2, w3=w3, c=c, n0=n0, n1=n1, nw=n3, nc=nc))
    prev = st
T = [t for t in T if (t['w2'] + 2 * t['w3'] + t['c']) >> 32]
print(len(T), 'transitions with a carry out of the full sum')
names = ['w0', 'w1', 'w2', 'w3', 'c', 'n0', 'n1', 'nw']
terms = [(n, 1) for n in names] + [(n, 2) for n in names]
hits = []
for k in (2, 3):
    for combo in itertools.combinations(terms, k):
        if len(set(n for n, _ in combo)) < k:
            continue
        ok = 0
        for t in T:
            s = sum(t[n] * m for n, m in combo)
            if (s >> 32) == t['nc']:
                ok += 1
        hits.append((ok, combo))
        # also: carry of the sum minus 1 floor at 0
hits.sort(reverse=True)
for h in hits[:10]:
    print(h)
