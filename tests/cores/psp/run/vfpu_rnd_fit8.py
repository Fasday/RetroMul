import os, sys
sys.path.insert(0, os.path.dirname(__file__))
src = open(os.path.join(os.path.dirname(__file__), 'vfpu_rnd_fit4.py')).read().split('# Candidate expressions.')[0]
exec(src)
out = []
prev = None
for i, t in enumerate(T):
    w2, w3, c, nw, co = t['w2'], t['w3'], t['c'], t['nw'], t['cout']
    if c > 2:
        prev = t
        continue
    fu = (w2 + 2 * w3 + c) >> 32
    exp = 1 if fu == 2 else 0
    mark = '  <<<' if exp != co else ''
    out.append('%3d %08x %08x c=%d -> %08x  full=%09x cout=%d w0=%08x w1=%08x%s' % (i, w2, w3, c, nw, w2 + 2 * w3 + c, co, t['w0'], t['w1'], mark))
open(os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))), 'rnd8.txt'), 'w').write('\n'.join(out) + '\n')
