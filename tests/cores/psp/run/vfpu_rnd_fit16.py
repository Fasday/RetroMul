import os, sys, itertools
sys.path.insert(0, os.path.dirname(__file__))
exec(open(os.path.join(os.path.dirname(__file__), 'vfpu_rnd_fit11.py')).read().split('tab = defaultdict')[0])
# cout = floor((a*w2 + b*w3 + g*c + d*nw + K) / 2^32) for small integer coefficients.
R = [(t['w2'], t['w3'], t['c'], t['nw'], t['cout']) for t in recs]
best = []
for a, b, d in itertools.product(range(-3, 4), repeat=3):
    for g in range(-2, 3):
        for k in range(-4, 5):
            K = k << 30
            bad = 0
            for w2, w3, c, nw, co in R:
                if ((a * w2 + b * w3 + g * c + d * nw + K) >> 32) != co:
                    bad += 1
                    if bad > 20:
                        break
            if bad <= 20:
                best.append((bad, a, b, g, d, k))
best.sort()
for x in best[:20]:
    print(x)
