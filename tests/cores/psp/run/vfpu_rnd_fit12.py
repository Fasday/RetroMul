import os, sys
sys.path.insert(0, os.path.dirname(__file__))
exec(open(os.path.join(os.path.dirname(__file__), 'vfpu_rnd_fit11.py')).read().split('tab = defaultdict')[0])
# Steps where the truncated-sum carry is wrong, and a sample where it's right.
ok = bad = 0
for t in recs:
    w2, w3, c = t['w2'], t['w3'], t['c']
    trunc = (w2 + ((w3 << 1) & M) + c) >> 32
    if trunc == t['cout']:
        ok += 1
        continue
    bad += 1
    full = (w2 + 2 * w3 + c) >> 32
    print('s=%08x n=%2d w2=%08x w3=%08x c=%x nw=%08x cout=%d trunc=%d full=%d' % (
        t['s'], t['n'], w2, w3, c, t['nw'], t['cout'], trunc, full))
print(ok, bad)
