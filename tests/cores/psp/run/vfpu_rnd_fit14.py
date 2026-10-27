import os, sys, itertools
from collections import defaultdict, Counter
sys.path.insert(0, os.path.dirname(__file__))
src = open(os.path.join(os.path.dirname(__file__), 'vfpu_rnd_fit4.py')).read().split('# Candidate expressions.')[0]
exec(src)
# Look for a lookup on a few bit features that predicts every carry.
recs = []
for r in rows:
    s = r['seed']
    w0 = w1 = s
    w3s = [s, s]
    w0s, w1s = [s], [s]
    for o in r['outs']:
        w0 = lcg(w0)
        w1 = xs(w1)
        w0s.append(w0)
        w1s.append(w1)
        w3s.append((o - w0 - w1) & M)
    cins = [s]
    for n in range(2, len(w3s)):
        w2, w3, nw = w3s[n - 2], w3s[n - 1], w3s[n]
        cins.append((nw - w2 - ((w3 << 1) & M)) & M)
    prev = None
    for n in range(2, len(w3s) - 1):
        k = n - 1  # draw index (1-based) producing w3s[n]
        w2, w3, nw = w3s[n - 2], w3s[n - 1], w3s[n]
        c = cins[n - 1]
        cout = cins[n]
        if c > 15 or cout > 15:
            prev = None
            continue
        a0, a1 = w0s[k - 1], w1s[k - 1]
        b0, b1 = w0s[k], w1s[k]
        f = {}
        full = w2 + 2 * w3 + c
        f['full'] = full >> 32
        f['trunc'] = (w2 + ((w3 << 1) & M) + c) >> 32
        f['w3t'] = w3 >> 31
        f['w2t'] = w2 >> 31
        f['nwt'] = nw >> 31
        f['nw30'] = (nw >> 30) & 1
        f['c23'] = (w2 + w3) >> 32
        f['c23c'] = (w2 + w3 + c) >> 32
        f['c'] = c
        f['o01'] = (b0 + b1) >> 32
        f['o013'] = (((b0 + b1) & M) + nw) >> 32
        f['b0t'] = b0 >> 31
        f['b1t'] = b1 >> 31
        f['a0t'] = a0 >> 31
        f['a1t'] = a1 >> 31
        f['lcgc'] = ((69069 * a0 + 1) >> 32) & 1
        f['cnw2'] = (nw + w3) >> 32
        f['cnw3'] = (nw + w2) >> 32
        f['w3_30'] = (w3 >> 30) & 1
        f['w2_30'] = (w2 >> 30) & 1
        base = dict(f)
        if prev is not None:
            for kk, vv in prev.items():
                f['p_' + kk] = vv
        recs.append((f, cout))
        prev = base
names = sorted(set().union(*[f.keys() for f, _ in recs]))
print(len(recs), 'records', len(names), 'features')
best = []
for k in (1, 2, 3):
    for combo in itertools.combinations(names, k):
        tab = defaultdict(Counter)
        n = 0
        for f, co in recs:
            if not all(x in f for x in combo):
                continue
            n += 1
            tab[tuple(f[x] for x in combo)][co] += 1
        bad = sum(sum(v.values()) - max(v.values()) for v in tab.values())
        best.append((bad, n, combo))
best.sort()
for b in best[:15]:
    print(b)
