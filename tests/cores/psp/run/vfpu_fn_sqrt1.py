"""Compositional hypotheses for the VFPU square root against exact.expected."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from vfpu_fn_data import *
import mpmath
mpmath.mp.prec = 100
d = load()


def t22(v):
    """Truncate a positive mpf to 22 mantissa bits, return float bits."""
    if v == 0:
        return 0
    e = int(mpmath.floor(mpmath.log(v, 2)))
    m = int(mpmath.floor(v / mpmath.power(2, e - 23)))
    if m >= 1 << 24:
        m >>= 1
        e += 1
    m &= ~3
    return ((e + 127) << 23) | (m & 0x7FFFFF)


def rnd(v, bits):
    e = int(mpmath.floor(mpmath.log(v, 2)))
    q = mpmath.power(2, e - bits + 1)
    return mpmath.nint(v / q) * q


def trn(v, bits):
    e = int(mpmath.floor(mpmath.log(v, 2)))
    q = mpmath.power(2, e - bits + 1)
    return mpmath.floor(v / q) * q


H = {
    'exact': lambda x: mpmath.sqrt(x),
    'x*rsq24': lambda x: x * rnd(1 / mpmath.sqrt(x), 24),
    'x*rsq24t': lambda x: x * trn(1 / mpmath.sqrt(x), 24),
    'x*rsq25t': lambda x: x * trn(1 / mpmath.sqrt(x), 25),
    'x*rsq26t': lambda x: x * trn(1 / mpmath.sqrt(x), 26),
    'x*rsq25': lambda x: x * rnd(1 / mpmath.sqrt(x), 25),
    'x*rsq26': lambda x: x * rnd(1 / mpmath.sqrt(x), 26),
    '1/rsq24': lambda x: 1 / rnd(1 / mpmath.sqrt(x), 24),
}
for name, h in H.items():
    bad = []
    for inp, o in d['sqrt']:
        if not normal(inp) or not normal(o) or inp >> 31:
            continue
        x = mpmath.mpf(f(inp))
        if t22(h(x)) != o:
            bad.append('%08x' % inp)
    print('%-10s %3d %s' % (name, len(bad), ' '.join(bad[:6])))
