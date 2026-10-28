"""Offline fit of the VFPU dot-product summation against hardware results.

Collects (products, printed result) cases from vector.expected and fcr31.expected
and tries summation models.
"""
import os
import struct
from fractions import Fraction

ROOT = os.path.dirname(os.path.abspath(__file__))
T = os.path.join(ROOT, 'pspautotests', 'tests', 'cpu', 'vfpu')


def f32(x):
    return struct.unpack('<f', struct.pack('<f', x))[0]


def bits(x):
    return struct.unpack('<I', struct.pack('<f', x))[0]


def frombits(b):
    return struct.unpack('<f', struct.pack('<I', b))[0]


INF = float('inf')
NAN = float('nan')
TV = [[1, 2, 3, 4], [5, 6, -7, -8], [-1, -2, -3, -4], [-4, -5, 6, 7], [f32(-0.1), 1000, INF, 0]]

cases = []  # (name, terms as list of (a, b) pairs, expected printed or bits)


def lines(name):
    return [l for l in open(os.path.join(T, name)).read().split('\n')]


vl = lines('vector.expected')


def take(prefix):
    return [l for l in vl if l.startswith(prefix + ':')]


for op, n in (('vdot_p', 2), ('vdot_t', 3), ('vdot_q', 4)):
    out = take(op)
    k = 0
    for i in range(5):
        for j in range(5):
            s, t = TV[i], TV[j]
            pairs = [(s[q], t[q]) for q in range(n)]
            cases.append((op, pairs, out[k].split(': ')[1].split(',')[0]))
            k += 1
for op, n in (('vhdp_p', 2), ('vhdp_t', 3), ('vhdp_q', 4)):
    out = take(op)
    k = 0
    for i in range(5):
        for j in range(5):
            s, t = TV[i], TV[j]
            pairs = [(s[q] if q < n - 1 else 1.0, t[q]) for q in range(n)]
            cases.append((op, pairs, out[k].split(': ')[1].split(',')[0]))
            k += 1
for op, n in (('vfad_p', 2), ('vfad_t', 3), ('vfad_q', 4)):
    out = take(op)
    for i in range(5):
        pairs = [(TV[i][q], 1.0) for q in range(n)]
        cases.append((op, pairs, out[i].split(': ')[1].split(',')[0]))
# fcr31 hex cases
cases.append(('fcr31 vdot', [(1.0, frombits(0x33c00000)), (-1.0, frombits(0xb3c00000)), (1.0, 3.0), (-1.0, 3.0)], 0x00000000))
cases.append(('fcr31 vhdp', [(1.0, frombits(0x33c00000)), (-1.0, frombits(0xb3c00000)), (1.0, 3.0), (1.0, 3.0)], 0x40c00000))


def tofr(x):
    return Fraction(x)


def round_frac(v, mode, mbits=24):
    """Round a Fraction to a float with mbits mantissa bits."""
    if v == 0:
        return 0.0
    neg = v < 0
    a = -v if neg else v
    e = a.numerator.bit_length() - a.denominator.bit_length()
    while Fraction(2) ** e > a:
        e -= 1
    while Fraction(2) ** (e + 1) <= a:
        e += 1
    q = a / (Fraction(2) ** (e - (mbits - 1)))
    fl = q.numerator // q.denominator
    rem = q - fl
    if mode == 'n':
        if rem > Fraction(1, 2) or (rem == Fraction(1, 2) and fl % 2 == 1):
            fl += 1
    elif mode == 'u':
        if rem != 0:
            fl += 1
    r = float(Fraction(fl) * Fraction(2) ** (e - (mbits - 1)))
    return -r if neg else r


def model_seq(pairs, mode, mbits=24):
    acc = Fraction(0)
    for a, b in pairs:
        p = tofr(a) * tofr(b)
        acc = Fraction(round_frac(acc + p, mode, mbits))
    return float(acc)


def model_exact(pairs, mode):
    acc = sum((tofr(a) * tofr(b) for a, b in pairs), Fraction(0))
    return round_frac(acc, mode)


def model_window(pairs, w, mode, floor_terms=True):
    ps = [tofr(a) * tofr(b) for a, b in pairs]
    nz = [abs(p) for p in ps if p != 0]
    if not nz:
        return 0.0
    m = max(nz)
    e = 0
    while Fraction(2) ** e > m:
        e -= 1
    while Fraction(2) ** (e + 1) <= m:
        e += 1
    unit = Fraction(2) ** (e - w)
    tot = Fraction(0)
    for p in ps:
        q = p / unit
        if floor_terms:
            fl = q.numerator // q.denominator
        else:
            fl = int(q)
        tot += fl * unit
    return round_frac(tot, mode)


def check(fn):
    bad = []
    for name, pairs, exp in cases:
        if any(x != x or abs(x) == INF for p in pairs for x in p):
            continue
        r = fn(pairs)
        if isinstance(exp, int):
            ok = bits(r) == exp
        else:
            ok = ('%f' % r) == exp
        if not ok:
            bad.append((name, pairs, exp, r))
    return bad


if __name__ == '__main__':
    for mode in 'ntu':
        b = check(lambda p: model_seq(p, mode))
        print('seq', mode, len(b), [(x[0], x[2], '%f' % x[3]) for x in b[:4]])
        b = check(lambda p: model_exact(p, mode))
        print('exact', mode, len(b), [(x[0], x[2], '%f' % x[3]) for x in b[:4]])
        for w in range(20, 34):
            for ft in (True, False):
                b = check(lambda p: model_window(p, w, mode, ft))
                if len(b) < 3:
                    print('window', w, mode, ft, len(b), [(x[0], x[2], '%f' % x[3]) for x in b[:4]])
