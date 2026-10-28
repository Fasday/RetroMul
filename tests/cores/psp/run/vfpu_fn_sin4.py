"""Tests piecewise-quadratic interpolation models of the hardware sine."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
src = open(os.path.join(os.path.dirname(__file__), 'vfpu_fn_sin3.py')).read().split('rows = []')[0]
exec(src)
SEG = int(os.environ.get('SEG', str(0x10000)))


def model(fr):
    a = (fr // SEG) * SEG
    h = SEG / 2
    m = a + h
    bb = a + SEG
    s = lambda u: mpmath.sin(mpmath.mpf(u) / (1 << FA) * mpmath.pi / 2)
    ya, ym, yb = s(a), s(m), s(bb)
    u = (mpmath.mpf(fr) - a) / h  # 0..2
    # Newton form through u = 0, 1, 2
    d1 = ym - ya
    d2 = (yb - 2 * ym + ya) / 2
    return ya + d1 * u + d2 * u * (u - 1)


bad = 0
lines = []
for fn, inp, o in pts:
    if o & 0x7FFFFFFF in (0, 0x3F800000):
        continue
    fr, q = first_quadrant(inp, fn == 'cos')
    v = model(fr)
    y = abs(mpmath.mpf(f(o)))
    e = ((o >> 23) & 0xFF) - 127
    ulp = mpmath.power(2, e - 21)
    lo = (y - v) * 2 ** 28
    hi = (y + ulp - v) * 2 ** 28
    ok = lo <= 0 < hi
    if not ok:
        bad += 1
    lines.append((fr, '%08x [%+8.2f, %+8.2f] %s %s %08x -> %08x' % (fr, float(lo), float(hi), '  ' if ok else '<<', fn, inp, o)))
lines.sort()
open(os.path.join(os.getcwd(), os.environ.get('OUTF', 'sin4.txt')), 'w').write('bad %d\n' % bad + '\n'.join(l for _, l in lines) + '\n')
print('bad', bad, 'of', len(lines))
