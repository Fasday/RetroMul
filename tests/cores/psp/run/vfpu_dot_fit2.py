import sys
sys.path.insert(0, __import__('os').path.dirname(__file__))
from vfpu_dot_fit import *

out = []
for name, pairs, exp in cases:
    if any(x != x or abs(x) == INF for p in pairs for x in p):
        continue
    ex = sum((tofr(a) * tofr(b) for a, b in pairs), Fraction(0))
    rn = round_frac(ex, 'n')
    rt = round_frac(ex, 't')
    ok_n = ('%f' % rn) == exp if not isinstance(exp, int) else bits(rn) == exp
    ok_t = ('%f' % rt) == exp if not isinstance(exp, int) else bits(rt) == exp
    prods = [float(tofr(a) * tofr(b)) for a, b in pairs]
    if ok_n and ok_t:
        continue
    out.append('%-8s n=%d t=%d exp=%s prods=%s exact=%r rn=%08x rt=%08x' % (
        name, ok_n, ok_t, exp, ['%.9g' % p for p in prods], float(ex), bits(rn), bits(rt)))
open(os.environ.get('OUTF', 'fit2.txt'), 'w').write('\n'.join(out))
