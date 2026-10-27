"""Model of vsin/vcos: the angle (quarter turns) as fixed point, sine as fixed point."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from vfpu_fn_data import *
import mpmath

mpmath.mp.prec = 120
d = load()
FA = int(os.environ.get('FA', '23'))   # angle fraction bits
FO = int(os.environ.get('FO', '28'))   # output fraction bits
CLR = int(os.environ.get('CLR', '2'))  # low mantissa bits cleared


def angle_fixed(x):
    """Quarter turns as an integer in units of 2^-FA, modulo 4 turns, from the bits."""
    e = (x >> 23) & 0xFF
    if e == 0:
        return 0
    m = (x & 0x7FFFFF) | 0x800000
    ue = e - 127
    if ue >= 32:
        ue &= 31
    sh = ue - 23 + FA
    if sh >= 0:
        v = m << sh
    else:
        v = m >> (-sh)
    return v % (4 << FA)


def to_float_bits(v, neg):
    """Fixed point v * 2^-FO to float bits, truncating, low CLR bits cleared."""
    if v == 0:
        return 0x80000000 if neg else 0
    top = v.bit_length() - 1
    e = top - FO
    if top > 23:
        m = v >> (top - 23)
    else:
        m = v << (23 - top)
    m &= ~((1 << CLR) - 1)
    r = ((e + 127) << 23) | (m & 0x7FFFFF)
    return r | (0x80000000 if neg else 0)


def model_sin(x, cosine=False):
    a = angle_fixed(x)
    neg_in = (x >> 31) & 1
    if cosine:
        a = (a + (1 << FA)) % (4 << FA)
        neg_in = 0
    quad = a >> FA
    frac = a & ((1 << FA) - 1)
    t = mpmath.mpf(a) / (1 << FA)
    s = mpmath.sin(t * mpmath.pi / 2)
    neg = s < 0
    v = int(mpmath.floor(abs(s) * (1 << FO)))
    if neg_in:
        neg = not neg
    if v == 0:
        # exact zeros keep the quadrant's sign
        return (0x80000000 if (quad == 2) != bool(neg_in) else 0) if frac == 0 else (0x80000000 if neg else 0)
    return to_float_bits(v, neg)


if __name__ == '__main__':
    fn = sys.argv[1] if len(sys.argv) > 1 else 'sin'
    bad = 0
    lines = []
    for inp, o in d[fn]:
        if ((inp >> 23) & 0xFF) == 255:
            continue
        r = model_sin(inp, fn == 'cos')
        if fn == 'nsin':
            r ^= 0x80000000
        if r != o:
            bad += 1
            lines.append('%08x (%-14.8g) hw %08x model %08x  diff %d' % (inp, f(inp), o, r, (o & 0x7FFFFF) - (r & 0x7FFFFF)))
    lines.insert(0, 'bad %d of %d' % (bad, len(d[fn])))
    open(os.environ.get('OUTF', fn + '_model.txt'), 'w').write('\n'.join(lines) + '\n')
    print(lines[0])
