"""exp2 / log2 with fixed-point quantization of the input (IB fraction bits) and/or of the
result (OB fraction bits, absolute), then the 22-bit truncation. Usage: vfpu_fn_q1.py exp2|log2"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from vfpu_fn_data import *
import mpmath
mpmath.mp.prec = 100
fn = sys.argv[1]
d = load()


def t22(v):
    s = 0
    if v < 0:
        s, v = 0x80000000, -v
    if v == 0:
        return s
    e = int(mpmath.floor(mpmath.log(v, 2)))
    m = int(mpmath.floor(v / mpmath.power(2, e - 23)))
    if m >= 1 << 24:
        m >>= 1
        e += 1
    if e < -126:
        return s
    if e > 127:
        return s | 0x7F800000
    m &= ~3
    return s | ((e + 127) << 23) | (m & 0x7FFFFF)


def run(ib, ob, rel):
    bad = 0
    for inp, o in d[fn]:
        if not normal(inp) or not normal(o):
            continue
        x = mpmath.mpf(f(inp))
        if fn == 'exp2':
            if ib is not None:
                x = mpmath.floor(x * 2 ** ib) / 2 ** ib
            v = mpmath.power(2, x)
        else:
            if x <= 0:
                continue
            v = mpmath.log(x, 2)
        if ob is not None:
            if rel:
                e = int(mpmath.floor(mpmath.log(abs(v), 2))) if v else 0
                q = mpmath.power(2, e - ob)
            else:
                q = mpmath.power(2, -ob)
            v = mpmath.floor(v / q) * q
        if t22(v) != o:
            bad += 1
    return bad


for ib in (None, 20, 22, 23, 24, 26):
    for ob in (None, 24, 26, 28, 30):
        print(fn, 'IB', ib, 'OB', ob, 'abs', run(ib, ob, False), 'rel', run(ib, ob, True) if ob else '')
