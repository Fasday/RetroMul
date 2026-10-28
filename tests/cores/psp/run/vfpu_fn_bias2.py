"""Mismatch count against the bias for one function (see vfpu_fn_bias.py)."""
import os, sys
fn = sys.argv[1]
sys.argv = ['x', fn]
src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'vfpu_fn_bias.py')).read().split('best = []')[0]
exec(src)
for k in [i / 32 for i in range(-32, 40)]:
    print('%+.4f %d' % (k, sum(1 for lo, hi, *_ in rows if not (lo <= k < hi))))
