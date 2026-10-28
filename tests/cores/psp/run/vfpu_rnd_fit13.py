import os, sys, itertools
sys.path.insert(0, os.path.dirname(__file__))
exec(open(os.path.join(os.path.dirname(__file__), 'vfpu_rnd_fit11.py')).read().split('tab = defaultdict')[0])
# Two-adder decompositions of w2 + 2*w3 + c and ways of combining their carries.
orders = {
    '(w2+w3+c)+w3': lambda w2, w3, c: (w2 + w3 + c, w3),
    '(w3+w3+c)+w2': lambda w2, w3, c: (w3 + w3 + c, w2),
    '(w2+w3)+w3+c': lambda w2, w3, c: (w2 + w3, w3 + c),
    '(w3+w3)+w2+c': lambda w2, w3, c: (w3 + w3, w2 + c),
    '(w2+c)+2w3': lambda w2, w3, c: (w2 + c, 2 * w3),
    '(w3+c)+(w2+w3)': lambda w2, w3, c: (w3 + c, w2 + w3),
}
combs = {
    'c1': lambda a, b: a, 'c2': lambda a, b: b, 'or': lambda a, b: a | b, 'and': lambda a, b: a & b,
    'xor': lambda a, b: a ^ b, 'sum': lambda a, b: a + b,
}
res = []
for on, of in orders.items():
    for cn, cf in combs.items():
        bad = 0
        for t in recs:
            x, y = of(t['w2'], t['w3'], t['c'])
            c1 = x >> 32
            c2 = ((x & M) + y) >> 32
            if cf(c1, c2) != t['cout']:
                bad += 1
        res.append((bad, on, cn))
res.sort()
for r in res[:12]:
    print(r)
