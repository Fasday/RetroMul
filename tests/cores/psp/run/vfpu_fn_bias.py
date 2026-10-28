"""For a function, how many hardware results a fixed bias (in ulp24 of the exact result) before the
22-bit truncation would reproduce. Usage: vfpu_fn_bias.py rcp|rsq|sqrt|exp2|log2|asin"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from vfpu_fn_data import *
import mpmath
mpmath.mp.prec = 100
fn = sys.argv[1]
d = load()
extra = {'rcp': [(0x3dcccccd, 0x41200000), (0x40400000, 0x3eaaaaa8)],
         'rsq': [(0x3fc00000, 0x3f5105ec)],
         'log2': [(0x40600000, 0x3fe75768)]}
F = {
    'rcp': lambda x: 1 / x,
    'rsq': lambda x: 1 / mpmath.sqrt(x),
    'sqrt': lambda x: mpmath.sqrt(x),
    'exp2': lambda x: mpmath.power(2, x),
    'log2': lambda x: mpmath.log(x, 2),
    'asin': lambda x: mpmath.asin(x) * 2 / mpmath.pi,
}[fn]
rows = []
for inp, o in d[fn] + extra.get(fn, []):
    if not normal(inp) or not normal(o):
        continue
    x = mpmath.mpf(f(inp))
    try:
        ex = F(x)
    except Exception:
        continue
    if ex == 0:
        continue
    y = mpmath.mpf(f(o))
    s = 1 if y > 0 else -1
    y, ex = abs(y), abs(ex)
    e = int(mpmath.floor(mpmath.log(ex, 2)))
    u24 = mpmath.power(2, e - 23)
    ue = ((o >> 23) & 0xFF) - 127
    ulp = mpmath.power(2, ue - 21)
    lo = (y - ex) / u24
    hi = (y + ulp - ex) / u24
    rows.append((float(lo), float(hi), inp, o, float((ex / mpmath.power(2, e) - 1) * 2 ** 23)))
best = []
for k in [i / 64 for i in range(-256, 257)]:
    bad = sum(1 for lo, hi, *_ in rows if not (lo <= k < hi))
    best.append((bad, k))
best.sort()
print(fn, len(rows), 'best biases', best[:6])
k = best[0][1]
for lo, hi, inp, o, m in sorted(rows, key=lambda r: r[4]):
    flag = '' if lo <= k < hi else '  <<'
    print('%08x -> %08x  mant %9.1f  [%+6.2f, %+6.2f)%s' % (inp, o, m, lo, hi, flag))
