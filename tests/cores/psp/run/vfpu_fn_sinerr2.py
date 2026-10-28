"""For each sine data point, the interval the pre-truncation value must lie in, relative to the
exact sine of the angle quantized to 2^-23 quarter turns (units of 2^-28)."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
src = open(os.path.join(os.path.dirname(__file__), 'vfpu_fn_sinerr.py')).read()
src = src.split('pts.sort()')[0]
exec(src)
FA = int(os.environ.get('FA', '23'))
rows = []
for t, err, fn, inp, o in pts:
    if o & 0x7FFFFFFF in (0, 0x3F800000):
        continue
    tq = mpmath.floor(mpmath.mpf(t) * 2 ** FA) / 2 ** FA
    ex = mpmath.sin(tq * mpmath.pi / 2)
    y = abs(mpmath.mpf(f(o)))
    e = ((o >> 23) & 0xFF) - 127
    ulp = mpmath.power(2, e - 21)
    lo = (y - ex) * 2 ** 28
    hi = (y + ulp - ex) * 2 ** 28
    ok = lo <= 0 < hi
    rows.append((float(t), float(lo), float(hi), ok, fn, inp, o))
rows.sort()
bad = sum(1 for r in rows if not r[3])
lines = ['bad %d of %d' % (bad, len(rows))]
lines += ['%.9f [%+9.2f, %+9.2f] %s %s %08x -> %08x' % (r[0], r[1], r[2], '  ' if r[3] else '<<', r[4], r[5], r[6]) for r in rows]
open(os.path.join(os.getcwd(), 'sinerr2.txt'), 'w').write('\n'.join(lines) + '\n')
print(lines[0])
