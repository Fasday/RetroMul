import os, sys, itertools, re
sys.path.insert(0, os.path.dirname(__file__))
exec(open(os.path.join(os.path.dirname(__file__), 'vfpu_rnd_fit11.py')).read().split('tab = defaultdict')[0])
# Add the exact transitions with large carries (seeds and direct writes) and search
# cout = max(0, floor((a*w2 + b*w3 + g*c + d*nw + e*(c>>16<<16) + K) / 2^32)).
src = open(os.path.join(os.path.dirname(__file__), 'vfpu_rnd_fit18.py')).read()
src = src.split("T = [t for t in T if")[0]
exec(src)
R = [(t['w2'], t['w3'], t['c'], t['nw'], t['cout']) for t in recs]
R += [(t['w2'], t['w3'], t['c'], t['nw'], t['nc']) for t in T]
print(len(R))
best = []
for a, b, d in itertools.product(range(-3, 4), repeat=3):
    for g in range(-3, 4):
        for e in range(-2, 3):
            for k in range(-12, 5):
                K = k << 30
                bad = 0
                for w2, w3, c, nw, co in R:
                    v = (a * w2 + b * w3 + g * c + e * (c & 0xFFFF0000) + d * nw + K) >> 32
                    if max(0, v) != co:
                        bad += 1
                        if bad > 3:
                            break
                if bad <= 3:
                    best.append((bad, a, b, g, e, d, k))
best.sort()
for x in best[:20]:
    print(x)
