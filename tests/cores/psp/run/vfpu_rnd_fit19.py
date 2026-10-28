import os, sys
sys.path.insert(0, os.path.dirname(__file__))
src = open(os.path.join(os.path.dirname(__file__), 'vfpu_rnd_fit4.py')).read().split('# Candidate expressions.')[0]
exec(src)
# Per seed: full-sum carry and the carry the next step used, side by side.
for r in rows:
    s = r['seed']
    w0 = w1 = s
    w3s = [s, s]
    for o in r['outs']:
        w0 = lcg(w0)
        w1 = xs(w1)
        w3s.append((o - w0 - w1) & M)
    cins = [s]
    for n in range(2, len(w3s)):
        w2, w3, nw = w3s[n - 2], w3s[n - 1], w3s[n]
        cins.append((nw - w2 - ((w3 << 1) & M)) & M)
    line = []
    for n in range(2, len(w3s) - 1):
        w2, w3 = w3s[n - 2], w3s[n - 1]
        c = cins[n - 1]
        full = (w2 + 2 * w3 + c) >> 32
        cout = cins[n]
        line.append('%d%d' % (full, cout) if cout < 16 else '%dX' % full)
    print('%08x' % s, ' '.join(line))
