import os, sys
sys.path.insert(0, os.path.dirname(__file__))
exec(open(os.path.join(os.path.dirname(__file__), 'vfpu_rnd_fit11.py')).read().split('tab = defaultdict')[0])
# How far T = 2*w2 + w3 + c could move in each step before the carry rule breaks.
lows, highs = [], []
for t in recs:
    T = 2 * t['w2'] + t['w3'] + t['c']
    co = t['cout']
    if co == 0:
        lo, hi = -(1 << 40), (2 << 32) - T          # T + d < 2^33
    else:
        lo, hi = ((co + 1) << 32) - T, ((co + 2) << 32) - T
    lows.append((lo, t))
    highs.append((hi, t))
lo = max(l for l, _ in lows)
hi = min(h for h, _ in highs)
print('d range %x .. %x' % (lo, hi) if lo >= 0 else 'd range -%x .. %x' % (-lo, hi))
for l, t in sorted(lows, key=lambda z: -z[0])[:5]:
    print('low  %+x' % l, {k: '%08x' % v for k, v in t.items() if k in ('w2', 'w3', 'c', 'nw', 'cout')})
for h, t in sorted(highs, key=lambda z: z[0])[:5]:
    print('high %+x' % h, {k: '%08x' % v for k, v in t.items() if k in ('w2', 'w3', 'c', 'nw', 'cout')})
