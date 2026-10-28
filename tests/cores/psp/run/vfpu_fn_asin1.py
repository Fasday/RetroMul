"""asin model: input truncated to IB fraction bits, exact arcsine in quarter turns, floored to OB
fraction bits, then the 22-bit truncation. Reports mismatches. Env IB, OB."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from vfpu_fn_data import *
import mpmath
mpmath.mp.prec = 100
IB = int(os.environ.get('IB', '23'))
OB = int(os.environ.get('OB', '29'))
d = load()


def t22(v):
    if v == 0:
        return 0
    e = int(mpmath.floor(mpmath.log(v, 2)))
    m = int(mpmath.floor(v / mpmath.power(2, e - 23)))
    if m >= 1 << 24:
        m >>= 1
        e += 1
    if e < -126:
        return 0
    m &= ~3
    return ((e + 127) << 23) | (m & 0x7FFFFF)


bad = []
win = []
for inp, o in d['asin']:
    if not normal(inp) and (inp & 0x7FFFFFFF):
        continue
    x = abs(mpmath.mpf(f(inp)))
    if x > 1 or (inp & 0x7F800000) == 0x7F800000:
        continue
    a = mpmath.floor(x * 2 ** IB)
    v = mpmath.asin(a / 2 ** IB) * 2 / mpmath.pi
    q = mpmath.floor(v * 2 ** OB) / 2 ** OB
    r = t22(q) | (inp & 0x80000000 if q else inp & 0x80000000)
    if (r & 0x7FFFFFFF) != (o & 0x7FFFFFFF):
        y = abs(mpmath.mpf(f(o)))
        bad.append((float(a), inp, o, r, float((y - v) * 2 ** OB)))
print('IB', IB, 'OB', OB, 'bad', len(bad))
for a, inp, o, r, dv in sorted(bad)[:int(os.environ.get('N', '40'))]:
    print('%10.0f %08x exp %08x got %08x  hw-exact %+.2f' % (a, inp, o, r, dv))
