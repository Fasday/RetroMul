"""For each VFPU function, compares hardware results with the exact value and
reports the error (in units of the result's last bit) distribution."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from vfpu_fn_data import *
import mpmath
from collections import Counter

mpmath.mp.prec = 200
d = load()


def exact(name, x):
    x = mpmath.mpf(x)
    if name == 'rcp':
        return 1 / x
    if name == 'nrcp':
        return -1 / x
    if name == 'sqrt':
        return mpmath.sqrt(x)
    if name == 'rsq':
        return 1 / mpmath.sqrt(x)
    if name == 'exp2':
        return mpmath.power(2, x)
    if name == 'rexp2':
        return mpmath.power(2, -x)
    if name == 'log2':
        return mpmath.log(x, 2)
    if name == 'sin':
        return mpmath.sin(x * mpmath.pi / 2)
    if name == 'nsin':
        return -mpmath.sin(x * mpmath.pi / 2)
    if name == 'cos':
        return mpmath.cos(x * mpmath.pi / 2)
    if name == 'asin':
        return mpmath.asin(x) / (mpmath.pi / 2)


def analyse(fn, show=False):
    errs = []
    rows = []
    for inp, o in d[fn]:
        if not normal(inp) or not normal(o):
            continue
        x = f(inp)
        try:
            e = exact(fn, x)
        except Exception:
            continue
        if e == 0 or not mpmath.isfinite(e) or mpmath.im(e) != 0:
            continue
        y = mpmath.mpf(f(o))
        ex = (o >> 23) & 0xFF
        ulp = mpmath.power(2, ex - 127 - 23)
        err = (abs(y) - abs(e)) / ulp
        errs.append(float(err))
        rows.append((inp, o, float(e), float(err)))
    return errs, rows


if __name__ == '__main__':
    fns = sys.argv[1:] or FUNCS
    for fn in fns:
        errs, rows = analyse(fn)
        if not errs:
            print(fn, 'no data')
            continue
        lo, hi = min(errs), max(errs)
        hist = Counter(int(mpmath.floor(e)) for e in errs)
        print('%-6s n=%d min=%+.3f max=%+.3f hist=%s' % (fn, len(errs), lo, hi, dict(sorted(hist.items()))))
