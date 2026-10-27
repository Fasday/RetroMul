import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from vfpu_fn_data import *
from fractions import Fraction

d = load()
fn = sys.argv[1] if len(sys.argv) > 1 else 'rcp'
out = []


def exact(name, x):
    if name in ('rcp', 'nrcp'):
        return 1 / Fraction(x)
    if name == 'sqrt':
        return Fraction(math.sqrt(x))
    if name == 'rsq':
        return Fraction(1 / math.sqrt(x))
    if name == 'exp2':
        return Fraction(2 ** x)
    if name == 'rexp2':
        return Fraction(2 ** -x)
    if name == 'log2':
        return Fraction(math.log2(x))
    if name == 'sin':
        return Fraction(math.sin(x * math.pi / 2))
    if name == 'cos':
        return Fraction(math.cos(x * math.pi / 2))
    if name == 'asin':
        return Fraction(math.asin(x) / (math.pi / 2))


for inp, o in d[fn]:
    if not normal(inp) or not normal(o):
        continue
    x = f(inp)
    try:
        e = exact(fn, x)
    except Exception:
        continue
    if e == 0:
        continue
    y = f(o)
    # error in units of the result's 2^-23 ulp
    m, ex = math.frexp(abs(float(e)))
    ulp = Fraction(2) ** (ex - 24)
    err = (Fraction(abs(y)) - abs(e)) / ulp
    out.append('%08x %08x exact=%.10g  err=%+.4f ulp  mant=%06x lowbits=%d' % (inp, o, float(e), float(err), o & 0x7FFFFF, o & 3))
open(os.environ.get('OUTF', fn + '.txt'), 'w').write('\n'.join(out) + '\n')
