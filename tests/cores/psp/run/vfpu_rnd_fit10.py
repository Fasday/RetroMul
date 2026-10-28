import os, sys
sys.path.insert(0, os.path.dirname(__file__))
src = open(os.path.join(os.path.dirname(__file__), 'vfpu_rnd_fit4.py')).read().split('# Candidate expressions.')[0]
exec(src)
# Print the carry sequence each seed implies, next to the full sums.
for r in rows:
    s = r['seed']
    w0 = w1 = s
    w3s = [s, s]
    for o in r['outs']:
        w0 = lcg(w0)
        w1 = xs(w1)
        w3s.append((o - w0 - w1) & M)
    print('seed %08x' % s)
    for n in range(2, len(w3s)):
        w2, w3, nw = w3s[n - 2], w3s[n - 1], w3s[n]
        cin = (nw - w2 - ((w3 << 1) & M)) & M
        full = w2 + 2 * w3
        print('  n=%2d w2=%08x w3=%08x nw=%08x cin=%x  (w2+2w3)>>32=%d  w2+w3>>32=%d  w3>>31=%d' % (
            n, w2, w3, nw, cin if cin < 16 else 0xFFFF, full >> 32, (w2 + w3) >> 32, w3 >> 31))
