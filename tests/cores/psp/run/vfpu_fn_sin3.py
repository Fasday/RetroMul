"""Sine model: angle to fixed point (FA fraction bits, truncated), quadrant reflection on the
integer, then sin of the first-quadrant angle; prints the interval the value before the final
22-bit truncation must be in, relative to the exact sine (units of 2^-28)."""
import sys, os, re
sys.path.insert(0, os.path.dirname(__file__))
from vfpu_fn_data import *
import mpmath
mpmath.mp.prec = 120
d = load()
FA = int(os.environ.get('FA', '23'))


def fixed_angle(x):
    e = (x >> 23) & 0xFF
    if e == 0:
        return 0
    m = (x & 0x7FFFFF) | 0x800000
    ue = e - 127
    if ue >= 32:
        ue = ue & 31 if (ue & 32) else -200
    sh = ue - 23 + FA
    v = m << sh if sh >= 0 else m >> (-sh)
    return v & ((4 << FA) - 1)


def first_quadrant(x, cosine):
    a = fixed_angle(x)
    neg = (x >> 31) & 1
    if neg and not cosine:
        a = (-a) & ((4 << FA) - 1)
    if cosine:
        a = (a + (1 << FA)) & ((4 << FA) - 1)
    q = a >> FA
    fr = a & ((1 << FA) - 1)
    if q & 1:
        fr = (1 << FA) - fr
    return fr, q


pts = []
for fn in ('sin', 'cos'):
    for inp, o in d[fn]:
        if ((inp >> 23) & 0xFF) == 255:
            continue
        pts.append((fn, inp, o))
cur = None
for line in open(os.path.join(T, 'vrot.expected')).read().split('\n'):
    m = re.match(r'== vrot\.q C000, S100, angle (\S+) ==', line)
    if m:
        cur = float(m.group(1))
        continue
    if line.startswith('=='):
        cur = None
    if cur is not None and line.startswith('imm  0:'):
        vals = [int(v, 16) for v in line.split(':')[1].split()[0].split(',')]
        pts.append(('cos', b(cur), vals[0]))
        pts.append(('sin', b(cur), vals[1]))
rows = []
for fn, inp, o in pts:
    if o & 0x7FFFFFFF in (0, 0x3F800000):
        continue
    fr, q = first_quadrant(inp, fn == 'cos')
    t = mpmath.mpf(fr) / (1 << FA)
    ex = mpmath.sin(t * mpmath.pi / 2)
    y = abs(mpmath.mpf(f(o)))
    e = ((o >> 23) & 0xFF) - 127
    ulp = mpmath.power(2, e - 21)
    lo = (y - ex) * 2 ** 28
    hi = (y + ulp - ex) * 2 ** 28
    rows.append((fr, float(lo), float(hi), lo <= 0 < hi, fn, inp, o))
rows.sort()
bad = sum(1 for r in rows if not r[3])
lines = ['bad %d of %d' % (bad, len(rows))]
lines += ['%08x %.9f [%+9.2f, %+9.2f] %s %s %08x -> %08x' % (r[0], r[0] / (1 << FA), r[1], r[2], '  ' if r[3] else '<<', r[4], r[5], r[6]) for r in rows]
open(os.path.join(os.getcwd(), os.environ.get('OUTF', 'sin3.txt')), 'w').write('\n'.join(lines) + '\n')
print(lines[0])
