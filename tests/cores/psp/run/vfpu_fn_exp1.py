"""exp2 with the input truncated to 23 fraction bits: list the mismatches with the error window
(hardware minus exact, in ulp24 of the result)."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from vfpu_fn_data import *
import mpmath
mpmath.mp.prec = 100
IB = int(os.environ.get('IB', '23'))
d = load()
rows = []
for inp, o in d['exp2']:
    if not normal(inp) or not normal(o):
        continue
    x = mpmath.mpf(f(inp))
    xq = mpmath.floor(x * 2 ** IB) / 2 ** IB
    v = mpmath.power(2, xq)
    e = int(mpmath.floor(mpmath.log(v, 2)))
    u24 = mpmath.power(2, e - 23)
    y = mpmath.mpf(f(o))
    ue = ((o >> 23) & 0xFF) - 127
    ulp = mpmath.power(2, ue - 21)
    lo = float((y - v) / u24)
    hi = float((y + ulp - v) / u24)
    frac = float(xq - mpmath.floor(xq))
    rows.append((frac, inp, o, lo, hi, float(xq)))
rows.sort()
for frac, inp, o, lo, hi, xq in rows:
    flag = '' if lo <= 0 < hi else ' <<'
    print('%.9f x=%+.9f %08x -> %08x [%+6.2f, %+6.2f)%s' % (frac, xq, inp, o, lo, hi, flag))
