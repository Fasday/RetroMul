"""Segment 0 of the sine: which subsets of the hardware windows a quadratic/cubic can meet."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
src = open(os.path.join(os.path.dirname(__file__), 'vfpu_fn_sin3.py')).read().split('rows = []')[0]
exec(src)
from scipy.optimize import linprog
P = []
for fn, inp, o in pts:
    if o & 0x7FFFFFFF in (0, 0x3F800000):
        continue
    fr, q = first_quadrant(inp, fn == 'cos')
    if fr >= 0x10001:
        continue
    y = abs(mpmath.mpf(f(o)))
    e = ((o >> 23) & 0xFF) - 127
    ulp = max(mpmath.power(2, e - 21), mpmath.power(2, -28))
    P.append((fr, float(y * 2 ** 28), float((y + ulp) * 2 ** 28)))
P = sorted(set(P))


def feasible(pts, deg):
    A, bb = [], []
    for x, lo, hi in pts:
        u = x / 65536
        A.append([-(u ** k) for k in range(deg + 1)]); bb.append(-lo)
        A.append([u ** k for k in range(deg + 1)]); bb.append(hi - 1e-7)
    r = linprog([0] * (deg + 1), A_ub=A, b_ub=bb, bounds=[(-1e9, 1e9)] * (deg + 1), method='highs')
    return r.status == 0, (r.x if r.status == 0 else None)


for deg in (2, 3, 4):
    for cut in (0, 0x100, 0x1000):
        sub = [p for p in P if p[0] > cut]
        ok, x = feasible(sub, deg)
        print('deg', deg, 'x >', hex(cut), len(sub), ok, x)
