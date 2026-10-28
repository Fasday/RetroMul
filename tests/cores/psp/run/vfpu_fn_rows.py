import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from vfpu_fn_check import *
from collections import Counter

fn = sys.argv[1]
errs, rows = analyse(fn)
low = Counter(o & 3 for inp, o in d[fn] if normal(o))
lines = ['lowbits %s' % dict(low)]
for inp, o, e, err in sorted(rows, key=lambda r: r[3]):
    x = f(inp)
    lines.append('%08x (%-14.8g) -> %08x  exact %-16.10g err %+9.3f  mant_in=%06x' % (inp, x, o, e, err, inp & 0x7FFFFF))
open(os.environ.get('OUTF', fn + '_rows.txt'), 'w').write('\n'.join(lines) + '\n')
