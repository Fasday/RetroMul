import os, re, itertools
ROOT = os.path.dirname(os.path.abspath(__file__))
L = open(os.path.join(ROOT, 'pspautotests', 'tests', 'cpu', 'vfpu', 'vrnd.expected')).read().split('\n')
M = 0xFFFFFFFF


def lcg(x):
    return (x * 69069 + 1) & M


def xs(j):
    j ^= (j << 13) & M
    j ^= j >> 17
    j ^= (j << 5) & M
    return j


rows = []
cur = None
for l in L:
    m = re.match(r'-- seed (\w+) --', l)
    if m:
        cur = {'seed': int(m.group(1), 16), 'outs': []}
        rows.append(cur)
        continue
    if cur is None:
        continue
    if l.startswith('-- '):
        cur = None
        continue
    m = re.match(r'vrndi=(\w+)', l)
    if m:
        cur['outs'].append(int(m.group(1), 16))
    if l.startswith('next 40:') or l.startswith('        '):
        cur['outs'] += [int(x, 16) for x in l.replace('next 40:', '').split()]

T = []
for r in rows:
    s = r['seed']
    w0 = w1 = s
    w3s = [s, s]
    w0s, w1s = [], []
    for o in r['outs']:
        w0 = lcg(w0)
        w1 = xs(w1)
        w0s.append(w0)
        w1s.append(w1)
        w3s.append((o - w0 - w1) & M)
    cins = []
    for n in range(2, len(w3s)):
        w2, w3, nw = w3s[n - 2], w3s[n - 1], w3s[n]
        cins.append((nw - w2 - ((w3 << 1) & M)) & M)
    for n in range(len(cins) - 1):
        w2, w3, nw = w3s[n], w3s[n + 1], w3s[n + 2]
        T.append(dict(w2=w2, w3=w3, c=cins[n], nw=nw, cout=cins[n + 1], w0=w0s[n], w1=w1s[n], out=r['outs'][n]))
print(len(T))
# Candidate expressions.
names = ['w2', 'w3', 'c', 'nw', 'w0', 'w1', 'out']
cands = {}
for a, b in itertools.combinations_with_replacement(names + ['w3x2', 'w3sh'], 2):
    cands['(%s+%s)>>32' % (a, b)] = (a, b, None)
for a, b, c in itertools.combinations_with_replacement(names + ['w3x2', 'w3sh'], 3):
    cands['(%s+%s+%s)>>32' % (a, b, c)] = (a, b, c)


def val(t, n):
    if n == 'w3x2':
        return 2 * t['w3']
    if n == 'w3sh':
        return (t['w3'] << 1) & M
    return t[n]


best = []
for k, (a, b, c) in cands.items():
    bad = 0
    for t in T:
        s = val(t, a) + val(t, b) + (val(t, c) if c else 0)
        if (s >> 32) != t['cout']:
            bad += 1
    best.append((bad, k))
best.sort()
print(best[:10])
# Look at full-sum fraction for the ambiguous cases.
for t in T[:0]:
    pass
