"""Per-segment feasibility of a polynomial in x (x = offset in the segment, result in units of
2^-28 before flooring) against the hardware windows, with FA=23 angles. Env: SEG, DEG, SHOW."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
src = open(os.path.join(os.path.dirname(__file__), 'vfpu_fn_sin3.py')).read().split('rows = []')[0]
exec(src)
import numpy as np
from scipy.optimize import linprog
from collections import defaultdict
SEG = int(os.environ.get('SEG', str(0x10000)), 0)
DEG = int(os.environ.get('DEG', '2'))
SHOW = int(os.environ.get('SHOW', '-1'))
seg = defaultdict(list)
for fn, inp, o in pts:
    if o & 0x7FFFFFFF in (0, 0x3F800000):
        continue
    fr, q = first_quadrant(inp, fn == 'cos')
    y = abs(mpmath.mpf(f(o)))
    e = ((o >> 23) & 0xFF) - 127
    ulp = mpmath.power(2, e - 21)
    lo = float(y * 2 ** 28)
    hi = float((y + ulp) * 2 ** 28)
    seg[fr // SEG].append((fr % SEG, lo, hi, fn, inp, o))
infeas = 0
for s in sorted(seg):
    P = seg[s]
    A, bb = [], []
    a0 = float(mpmath.sin(mpmath.mpf(s * SEG) / (1 << FA) * mpmath.pi / 2) * 2 ** 28)
    sc = [1.0 / SEG ** k for k in range(DEG + 1)]  # scale x to [0,1)
    for x, lo, hi, *_ in P:
        hi = max(hi, lo + 1)
        u = x / SEG
        A.append([-(u ** k) for k in range(DEG + 1)]); bb.append(-lo)
        A.append([u ** k for k in range(DEG + 1)]); bb.append(hi - 1e-6)
    bounds = [(a0 - 1000, a0 + 1000)] + [(-1e9, 1e9)] * DEG
    r = linprog([0] * (DEG + 1), A_ub=A, b_ub=bb, bounds=bounds, method='highs')
    ok = r.status == 0
    if not ok:
        infeas += 1
    if s == SHOW or not ok:
        print('seg %3d n=%2d %s' % (s, len(P), 'ok' if ok else 'INFEASIBLE'))
    if s == SHOW:
        ex = lambda x: float(mpmath.sin(mpmath.mpf(s * SEG + x) / (1 << FA) * mpmath.pi / 2) * 2 ** 28)
        for x, lo, hi, fn, inp, o in sorted(P):
            print('   x=%05x lo-ex=%+8.2f hi-ex=%+8.2f %s %08x -> %08x' % (x, lo - ex(x), max(hi, lo + 1) - ex(x), fn, inp, o))
print('infeasible segments', infeas, 'of', len(seg))
