"""Error of the hardware sine against the exact value, by the reduced angle."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from vfpu_fn_data import *
import mpmath, re
mpmath.mp.prec = 120
d = load()


def angle_q(x):
    """Reduced angle in quarter turns, exact rational, as the hardware wraps the exponent."""
    e = (x >> 23) & 0xFF
    if e == 0:
        return mpmath.mpf(0)
    m = (x & 0x7FFFFF) | 0x800000
    ue = e - 127
    if ue >= 32:
        ue = ue & 31 if (ue & 32) else -200
    v = mpmath.mpf(m) * mpmath.power(2, ue - 23)
    v = v - 4 * mpmath.floor(v / 4)
    return v


pts = []
for fn, shift in (('sin', 0), ('cos', 1)):
    for inp, o in d[fn]:
        if ((inp >> 23) & 0xFF) == 255:
            continue
        a = angle_q(inp)
        if (inp >> 31) and fn == 'sin':
            a = (4 - a) % 4
        a = (a + shift) % 4
        # map to first quadrant
        q = int(mpmath.floor(a))
        t = a - q
        if q == 1 or q == 3:
            t = 1 - t
        sgn = -1 if q >= 2 else 1
        y = f(o)
        ex = mpmath.sin(t * mpmath.pi / 2)
        err = (abs(mpmath.mpf(y)) - ex) * 2 ** 28
        pts.append((float(t), float(err), fn, inp, o))
# also vrot data: angle -> [c, s, s, s] for imm 0, from the separate-register cases.
T2 = os.path.join(T, 'vrot.expected')
cur = None
for line in open(T2).read().split('\n'):
    m = re.match(r'== vrot\.q C000, S100, angle (\S+) ==', line)
    if m:
        cur = float(m.group(1))
        continue
    if line.startswith('=='):
        cur = None
    if cur is not None and line.startswith('imm  0:'):
        vals = [int(v, 16) for v in line.split(':')[1].split()[0].split(',')]
        x = b(cur)
        for fn, idx, shift in (('cos', 0, 1), ('sin', 1, 0)):
            a = angle_q(x)
            if (x >> 31) and fn == 'sin':
                a = (4 - a) % 4
            a = (a + shift) % 4
            q = int(mpmath.floor(a))
            t = a - q
            if q == 1 or q == 3:
                t = 1 - t
            y = f(vals[idx])
            ex = mpmath.sin(t * mpmath.pi / 2)
            pts.append((float(t), float((abs(mpmath.mpf(y)) - ex) * 2 ** 28), 'vrot' + fn, x, vals[idx]))
pts.sort()
lines = ['%.9f  err=%+10.2f  %s %08x -> %08x' % p for p in pts]
open(os.path.join(os.getcwd(), 'sinerr.txt'), 'w').write('\n'.join(lines) + '\n')
print(len(pts))
