"""Bias split by the input's exponent parity (for rsq/sqrt), see vfpu_fn_bias.py."""
import os, sys
fn = sys.argv[1]
sys.argv = ['x', fn]
src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'vfpu_fn_bias.py')).read().split('best = []')[0]
exec(src)
ks = [i / 16 for i in range(-16, 33)]
res = []
for ke in ks:
    for ko in ks:
        bad = 0
        for lo, hi, inp, o, m in rows:
            k = ke if ((((inp >> 23) & 0xFF) - 127) % 2 == 0) else ko
            if not (lo <= k < hi):
                bad += 1
        res.append((bad, ke, ko))
res.sort()
print(res[:10])
