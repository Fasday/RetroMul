import os, sys
sys.path.insert(0, os.path.dirname(__file__))
exec(open(os.path.join(os.path.dirname(__file__), 'vfpu_rnd_fit11.py')).read().split('tab = defaultdict')[0])
# The carry rule max(0, ((2*w2 + w3 + f(c)) >> 32) - 1) for a few f.
fs = {'c': lambda c: c, 'c|c<<1': lambda c: c | ((c << 1) & M), '2c': lambda c: 2 * c,
      'rotl': lambda c: ((c << 1) & M) | (c >> 31)}
for n, f in fs.items():
    bad = sum(1 for t in recs if max(0, ((2 * t['w2'] + t['w3'] + f(t['c'])) >> 32) - 1) != t['cout'])
    print(n, bad)
