import sys, os, itertools, math
sys.path.insert(0, os.path.dirname(__file__))
from vfpu_dot_fit import *


def mexp(x):
    """Exponent e with 2^e <= |x| < 2^(e+1) for a Fraction."""
    a = abs(x)
    e = a.numerator.bit_length() - a.denominator.bit_length()
    while Fraction(2) ** e > a:
        e -= 1
    while Fraction(2) ** (e + 1) <= a:
        e += 1
    return e


def inexp(x):
    return math.frexp(x)[1] - 1


def quant(v, unit, how):
    q = v / unit
    if how == 'floor':
        n = q.numerator // q.denominator
    elif how == 'trunc':
        n = int(q)
    else:
        fl = q.numerator // q.denominator
        r = q - fl
        n = fl + (1 if r >= Fraction(1, 2) else 0)
    return n * unit


def rnd(v, mode, mbits=24):
    if v == 0:
        return Fraction(0)
    neg = v < 0
    a = -v if neg else v
    e = mexp(a)
    unit = Fraction(2) ** (e - (mbits - 1))
    q = a / unit
    fl = q.numerator // q.denominator
    rem = q - fl
    if mode == 'n':
        if rem > Fraction(1, 2) or (rem == Fraction(1, 2) and fl % 2 == 1):
            fl += 1
    elif mode == 'h':  # ties toward zero
        if rem > Fraction(1, 2):
            fl += 1
    elif mode == 'a':  # ties away
        if rem >= Fraction(1, 2):
            fl += 1
    elif mode == 'u':
        if rem != 0:
            fl += 1
    r = fl * unit
    return -r if neg else r


def model(pairs, ref, k, F, how, mode, pbits):
    prods = []
    refs = []
    for a, b in pairs:
        p = Fraction(a) * Fraction(b)
        if pbits and p != 0:
            p = rnd(p, 't', pbits)
        prods.append(p)
        if p != 0:
            if ref == 'prod':
                refs.append(mexp(p))
            else:
                refs.append(inexp(a) + inexp(b))
    if not refs:
        return 0.0
    R = max(refs) + k
    unit = Fraction(2) ** (R - F)
    tot = sum((quant(p, unit, how) for p in prods), Fraction(0))
    return float(rnd(tot, mode))


def score(fn):
    bad = 0
    for name, pairs, exp in cases:
        if any(x != x or abs(x) == INF for p in pairs for x in p):
            continue
        r = fn(pairs)
        if isinstance(exp, int):
            ok = bits(r) == exp
        else:
            ok = ('%f' % r) == exp
        if not ok:
            bad += 1
    return bad


res = []
for ref in ('prod', 'in'):
    for k in range(-1, 3):
        for F in range(20, 30):
            for how in ('floor', 'trunc', 'round'):
                for mode in 'nthau':
                    for pbits in (0, 24, 25, 26):
                        b = score(lambda p: model(p, ref, k, F, how, mode, pbits))
                        res.append((b, ref, k, F, how, mode, pbits))
res.sort()
open(os.environ.get('OUTF', 'fit3.txt'), 'w').write('\n'.join(str(r) for r in res[:40]))
