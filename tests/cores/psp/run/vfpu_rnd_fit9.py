import os, sys, itertools
sys.path.insert(0, os.path.dirname(__file__))
src = open(os.path.join(os.path.dirname(__file__), 'vfpu_rnd_fit6.py')).read().split('rules = {')[0]
exec(src)
# Per seed: list of steps (w2, w3, cin, nw); cin_{n+1} is the carry out of step n.
steps = []
for s, w3s in seqs:
    st = []
    for n in range(2, len(w3s)):
        w2, w3, nw = w3s[n - 2], w3s[n - 1], w3s[n]
        cin = (nw - w2 - ((w3 << 1) & M)) & M
        st.append((w2, w3, cin, nw))
    steps.append(st)


def feats(t):
    w2, w3, c, nw = t
    return {
        'full': (w2 + 2 * w3 + c) >> 32,
        'trunc': (w2 + ((w3 << 1) & M) + c) >> 32,
        'top3': w3 >> 31,
        'top2': w2 >> 31,
        'topn': nw >> 31,
        'c': c if c < 4 else 9,
        'add23': (w2 + w3) >> 32,
    }


# Tabulate cout against features of this step and the previous one.
from collections import Counter, defaultdict
for keys in [('full', 'trunc', 'top3', 'topn'), ('full', 'top2', 'top3', 'topn'), ('trunc', 'top3', 'topn', 'c')]:
    tab = defaultdict(Counter)
    for st in steps:
        for n in range(1, len(st) - 1):
            if st[n][2] > 3:
                continue
            f = feats(st[n])
            fp = feats(st[n - 1])
            key = tuple(f[k] for k in keys) + (fp['topn'],)
            tab[key][st[n + 1][2]] += 1
    amb = sum(1 for k, v in tab.items() if len(v) > 1)
    print(keys, 'ambiguous keys', amb)
    for k, v in sorted(tab.items()):
        print('   ', k, dict(v))
