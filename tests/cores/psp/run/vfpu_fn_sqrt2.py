"""Is the hardware sqrt consistent with x * (the rsq value before its 22-bit truncation)?
For each input, intersect the rsq window [r, r + 4 ulp24) scaled by x with the sqrt window."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from vfpu_fn_data import *
import mpmath
mpmath.mp.prec = 100
d = load()
rsq = dict(d['rsq'])
bad = ok = 0
for inp, o in d['sqrt']:
    if not normal(inp) or not normal(o) or inp >> 31 or inp not in rsq:
        continue
    r = rsq[inp]
    if not normal(r):
        continue
    x = mpmath.mpf(f(inp))
    ry = mpmath.mpf(f(r))
    rul = mpmath.power(2, ((r >> 23) & 0xFF) - 127 - 21)
    sy = mpmath.mpf(f(o))
    sul = mpmath.power(2, ((o >> 23) & 0xFF) - 127 - 21)
    lo, hi = x * ry, x * (ry + rul)
    if hi <= sy or lo >= sy + sul:
        bad += 1
        print('inconsistent %08x rsq %08x sqrt %08x' % (inp, r, o))
    else:
        ok += 1
print('consistent', ok, 'inconsistent', bad)
