import os, sys
sys.path.insert(0, os.path.dirname(__file__))
src = open(os.path.join(os.path.dirname(__file__), 'vfpu_rnd_fit4.py')).read().split('# Candidate expressions.')[0]
exec(src)
from collections import Counter
tab = Counter()
lines = []
for t in T:
    w2, w3, c, nw, co = t['w2'], t['w3'], t['c'], t['nw'], t['cout']
    if c > 2:
        continue
    tr = (w2 + ((w3 << 1) & M) + c) >> 32
    fu = (w2 + 2 * w3 + c) >> 32
    tab[(tr, fu, w3 >> 31, co)] += 1
    if fu == 1:
        lines.append('%08x %08x c=%d -> %08x tr=%d top=%d cout=%d   w2+w3=%09x' % (w2, w3, c, nw, tr, w3 >> 31, co, w2 + w3))
print(sorted(tab.items()))
open('rnd5.txt', 'w').write('\n'.join(sorted(lines, key=lambda s: s[-12:])) + '\n')
