import os, sys
sys.path.insert(0, os.path.dirname(__file__))
exec(open(os.path.join(os.path.dirname(__file__), 'vfpu_rnd_fit11.py')).read().split('tab = defaultdict')[0])
src = open(os.path.join(os.path.dirname(__file__), 'vfpu_rnd_fit18.py')).read().split("T = [t for t in T if")[0]
exec(src)
R = [(t['w2'], t['w3'], t['c'], t['cout']) for t in recs] + [(t['w2'], t['w3'], t['c'], t['nc']) for t in T]


def sgn(v):
    return v - (1 << 32) if v >= (1 << 31) else v


cands = {
    'T': lambda x, y, c: 2 * x + y + c,
    'T+min(y-x,c)': lambda x, y, c: 2 * x + y + c + max(0, min(y - x, c)),
    'T+min(y-x,c) signed': lambda x, y, c: 2 * x + y + c + min(y - x, c),
    'max(T, S-?)': lambda x, y, c: max(2 * x + y + c, x + 2 * y + c - (1 << 32)),
}
for n, f in cands.items():
    bad = [(x, y, c, co) for x, y, c, co in R if max(0, (f(x, y, c) >> 32) - 1) != co]
    print(n, len(bad), ['%08x %08x %08x %d' % b for b in bad[:4]])
