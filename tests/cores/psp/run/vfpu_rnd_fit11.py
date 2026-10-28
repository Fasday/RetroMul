import os, sys
from collections import Counter, defaultdict
sys.path.insert(0, os.path.dirname(__file__))
src = open(os.path.join(os.path.dirname(__file__), 'vfpu_rnd_fit4.py')).read().split('# Candidate expressions.')[0]
exec(src)
# The carry each step implies (resynced to the data every step), against candidate features.
recs = []
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
    # cins[k] is the carry into step k+2 (k=0 is the seed)
    for n in range(2, len(w3s) - 1):
        w2, w3, nw = w3s[n - 2], w3s[n - 1], w3s[n]
        c = cins[n - 1]
        cout = cins[n]
        if cout > 15:
            continue
        recs.append(dict(s=s, n=n, w2=w2, w3=w3, c=c, nw=nw, cout=cout))
tab = defaultdict(Counter)
for t in recs:
    w2, w3, c = t['w2'], t['w3'], t['c']
    full = (w2 + 2 * w3 + c) >> 32
    trunc = (w2 + ((w3 << 1) & M) + c) >> 32
    a = (w2 + w3) >> 32
    b = (((w2 + w3) & M) + w3 + c) >> 32
    key = (full, trunc, w3 >> 31, a, b)
    tab[key][t['cout']] += 1
print('key = full, trunc, w3top, (w2+w3)>>32, carry of ((w2+w3)+w3+c)')
for k, v in sorted(tab.items()):
    print(k, dict(v))
