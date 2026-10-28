import itertools
# Search combination rules of a forced (instruction) prefix with the user's pending prefix
CONST = [0.0, 1.0, 2.0, 0.5, 3.0, 1/3, 0.25, 1/6]
raw = [1.5, -2.5, 3.5, -4.5]
US = dict(sw=[1, 0, 3, 2], ab=[0]*4, cn=[0]*4, ng=[1]*4)
UT = dict(sw=[1, 3, 0, 0], ab=[0, 0, 1, 0], cn=[1]*4, ng=[0]*4)


def lane(p, i, reg):
    if p['cn'][i]:
        v = CONST[(p['ab'][i] << 2) | p['sw'][i]]
    else:
        v = reg[p['sw'][i]]
        if p['ab'][i]:
            v = abs(v)
    return -v if p['ng'][i] else v


def apply(p, reg):
    return [lane(p, i, reg) for i in range(4)]


SWR = ['or', 'xor', 'fu', 'uf', 'user', 'forced', 'relor', 'relxor']
NGR = ['or', 'xor', 'user', 'forced', 'uf']


def build(u, f, swr, ngr, reg):
    # returns operand vector
    out = []
    for i in range(4):
        if swr == 'fu':      # forced indexes into the user-prefixed vector
            v = lane(u, f['sw'][i], reg)
            if ngr in ('or', 'xor', 'forced', 'uf'):
                v = -v if f['ng'][i] else v
            out.append(v)
            continue
        p = dict(sw=[0]*4, ab=u['ab'][:], cn=u['cn'][:], ng=[0]*4)
        if swr == 'or':
            s = u['sw'][i] | f['sw'][i]
        elif swr == 'xor':
            s = u['sw'][i] ^ f['sw'][i]
        elif swr == 'uf':
            s = f['sw'][u['sw'][i]] if not u['cn'][i] else u['sw'][i]
        elif swr == 'user':
            s = u['sw'][i]
        elif swr == 'forced':
            s = f['sw'][i]
        elif swr == 'relor':
            s = (((u['sw'][i] ^ i) | (f['sw'][i] ^ i)) ^ i)
        else:
            s = (((u['sw'][i] ^ i) ^ (f['sw'][i] ^ i)) ^ i)
        if ngr == 'or':
            n = u['ng'][i] | f['ng'][i]
        elif ngr == 'xor':
            n = u['ng'][i] ^ f['ng'][i]
        elif ngr == 'user':
            n = u['ng'][i]
        elif ngr == 'uf':
            n = u['ng'][i] ^ (f['ng'][u['sw'][i]] if not u['cn'][i] else 0)
        else:
            n = f['ng'][i]
        p['sw'] = [0]*4
        p['sw'][i] = s
        p['ng'][i] = n
        out.append(lane(p, i, reg))
    return out


def sat(v):
    return 0.0 if v <= 0 else (1.0 if v >= 1 else v)


def mk(sw, ng):
    return dict(sw=list(sw), ab=[0]*4, cn=[0]*4, ng=list(ng))


lanes2 = [[(0, 0, 2, 0), (2, 0, 0, 0)], [(1, 0, 3, 0), (3, 0, 1, 0)],
          [(0, 0, 2, 1), (2, 1, 0, 0)], [(1, 0, 3, 1), (3, 1, 1, 0)]]
lanes1 = [[(0, 0, 1, 0), (1, 0, 0, 0)], [(0, 0, 1, 1), (1, 1, 0, 0)],
          [(2, 0, 3, 0), (3, 0, 2, 0)], [(2, 0, 3, 1), (3, 1, 2, 0)]]


def ok(lanes, exp, rs):
    sols = []
    for ch in itertools.product(*lanes):
        fs = mk([c[0] for c in ch], [c[1] for c in ch])
        ft = mk([c[2] for c in ch], [c[3] for c in ch])
        s = build(US, fs, rs[0], rs[1], raw)
        t = build(UT, ft, rs[2], rs[3], raw)
        d = [sat(a + b) for a, b in zip(s, t)]
        if d == exp:
            sols.append(ch)
    return sols


for rs in itertools.product(SWR, NGR, SWR, NGR):
    a = ok(lanes1, [1, 0, 1, 0], rs)
    b = ok(lanes2, [1, 0, 1, 0], rs)
    if a and b:
        print(rs, len(a), len(b), a[0], b[0])
