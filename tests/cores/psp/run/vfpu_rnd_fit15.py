import os, sys, itertools
sys.path.insert(0, os.path.dirname(__file__))
exec(open(os.path.join(os.path.dirname(__file__), 'vfpu_rnd_fit11.py')).read().split('tab = defaultdict')[0])
# Carry-save forms of w2 + 2*w3 + c: which carry-out of the final adder fits?


def csa(a, b, c):
    s = a ^ b ^ c
    k = ((a & b) | (a & c) | (b & c)) << 1
    return s, k


def rules(w2, w3, c):
    out = {}
    d = (w3 << 1) & M
    for name, (a, b, cc) in {
        'w2,2w3,c': (w2, d, c), 'w2,w3,w3': (w2, w3, w3),
    }.items():
        s, k = csa(a, b, cc)
        out[name + ' adder'] = ((s & M) + (k & M)) >> 32
        out[name + ' adder+k32'] = (((s & M) + (k & M)) >> 32) + (k >> 32)
        out[name + ' k32'] = k >> 32
    # w2,w3,w3 compressor then adder with c as carry in
    s, k = csa(w2, w3, w3)
    out['w2w3w3+cin adder'] = ((s & M) + (k & M) + c) >> 32
    out['w2w3w3+cin adder|k32'] = (((s & M) + (k & M) + c) >> 32) | (k >> 32)
    out['w2w3w3+cin adder&k32'] = (((s & M) + (k & M) + c) >> 32) & (k >> 32)
    return out


from collections import Counter
bad = Counter()
for t in recs:
    for k, v in rules(t['w2'], t['w3'], t['c']).items():
        if v != t['cout']:
            bad[k] += 1
for k in sorted(bad, key=lambda k: bad[k]):
    print(bad[k], k)
