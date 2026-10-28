"""Quadratic-interpolation sine with variants of the quadrant reflection; reports mismatches
with the quadrant shown."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
src = open(os.path.join(os.path.dirname(__file__), 'vfpu_fn_sin3.py')).read().split('rows = []')[0]
exec(src)
SEG = 0x10000
REFL = os.environ.get('REFL', 'neg')


def quadrant(x, cosine):
    a = fixed_angle(x)
    neg = (x >> 31) & 1
    if neg and not cosine:
        a = (-a) & ((4 << FA) - 1)
    if cosine:
        a = (a + (1 << FA)) & ((4 << FA) - 1)
    q = a >> FA
    fr = a & ((1 << FA) - 1)
    if q & 1:
        fr = ((1 << FA) - fr) if REFL == 'neg' else ((1 << FA) - 1 - fr)
    return fr, q


def model(fr):
    a = (fr // SEG) * SEG
    h = SEG / 2
    s = lambda u: mpmath.sin(mpmath.mpf(u) / (1 << FA) * mpmath.pi / 2)
    ya, ym, yb = s(a), s(a + h), s(a + SEG)
    u = (mpmath.mpf(fr) - a) / h
    return ya + (ym - ya) * u + (yb - 2 * ym + ya) / 2 * u * (u - 1)


bad = 0
lines = []
for fn, inp, o in pts:
    if o & 0x7FFFFFFF in (0, 0x3F800000):
        continue
    fr, q = quadrant(inp, fn == 'cos')
    v = model(fr)
    y = abs(mpmath.mpf(f(o)))
    e = ((o >> 23) & 0xFF) - 127
    ulp = mpmath.power(2, e - 21)
    lo = (y - v) * 2 ** 28
    hi = (y + ulp - v) * 2 ** 28
    ok = lo <= 0 < hi
    if not ok:
        bad += 1
        lines.append((fr, '%08x q%d [%+8.2f, %+8.2f] %s %08x -> %08x' % (fr, q, float(lo), float(hi), fn, inp, o)))
lines.sort()
open(os.path.join(os.getcwd(), os.environ.get('OUTF', 'sin5.txt')), 'w').write('bad %d\n' % bad + '\n'.join(l for _, l in lines) + '\n')
print(REFL, 'bad', bad)
