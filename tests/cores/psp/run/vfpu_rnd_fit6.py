import os, sys
sys.path.insert(0, os.path.dirname(__file__))
src = open(os.path.join(os.path.dirname(__file__), 'vfpu_rnd_fit4.py')).read().split('# Candidate expressions.')[0]
exec(src)
# Simulate candidate carry rules over each seed's whole sequence and count mismatching words.
seqs = []
for r in rows:
    s = r['seed']
    w0 = w1 = s
    w3s = [s, s]
    for o in r['outs']:
        w0 = lcg(w0)
        w1 = xs(w1)
        w3s.append((o - w0 - w1) & M)
    seqs.append((s, w3s))


def run(rule):
    bad = 0
    for s, w3s in seqs:
        w2, w3, c = s, s, s
        hist = []
        for n in range(2, len(w3s)):
            S = w2 + ((w3 << 1) & M) + c
            nw = S & M
            if nw != w3s[n]:
                bad += 1
                nw = w3s[n]
            c = rule(w2, w3, c, nw, hist)
            hist.append((w2, w3, c, nw))
            w2, w3 = w3, nw
    return bad


rules = {
    'full>>32': lambda w2, w3, c, nw, h: (w2 + 2 * w3 + c) >> 32,
    'trunc>>32': lambda w2, w3, c, nw, h: (w2 + ((w3 << 1) & M) + c) >> 32,
    'full>>33': lambda w2, w3, c, nw, h: (w2 + 2 * w3 + c) >> 33,
    'nw<w2': lambda w2, w3, c, nw, h: 1 if nw < w2 else 0,
    'nw<w3': lambda w2, w3, c, nw, h: 1 if nw < w3 else 0,
    'nw<=w3': lambda w2, w3, c, nw, h: 1 if nw <= w3 else 0,
    'nw<w2+?': lambda w2, w3, c, nw, h: 1 if nw < ((w2 + c) & M) else 0,
}
for k, f in rules.items():
    print(k, run(f))
