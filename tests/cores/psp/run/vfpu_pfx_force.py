import itertools
# How a forced internal prefix might combine with the user's pending one (prefix_consume.c)
CONST = [0.0, 1.0, 2.0, 0.5, 3.0, 1/3, 0.25, 1/6]
raw = [1.5, -2.5, 3.5, -4.5]
# user S [-y,-x,-w,-z], T [1,1/2,3,0]
US = dict(sw=[1, 0, 3, 2], ab=[0]*4, cn=[0]*4, ng=[1]*4)
UT = dict(sw=[1, 3, 0, 0], ab=[0, 0, 1, 0], cn=[1]*4, ng=[0]*4)

def apply(p, reg):
    out = []
    for i in range(4):
        if p['cn'][i]:
            v = CONST[(p['ab'][i] << 2) | p['sw'][i]]
        else:
            v = reg[p['sw'][i]]
            if p['ab'][i]:
                v = abs(v)
        if p['ng'][i]:
            v = -v
        out.append(v)
    return out

def comb(u, f, mode):
    r = {}
    for k in u:
        if mode == 'or':
            r[k] = [a | b for a, b in zip(u[k], f[k])]
        else:
            r[k] = [a ^ b for a, b in zip(u[k], f[k])]
    return r

def sat(v):
    return 0.0 if v <= 0 else (1.0 if v >= 1 else v)

def mk(sw, ng):
    return dict(sw=list(sw), ab=[0]*4, cn=[0]*4, ng=list(ng))

lanes2 = [  # vbfy2: (sIdx, sNeg, tIdx, tNeg) options per lane
    [(0, 0, 2, 0), (2, 0, 0, 0)],
    [(1, 0, 3, 0), (3, 0, 1, 0)],
    [(0, 0, 2, 1), (2, 1, 0, 0)],
    [(1, 0, 3, 1), (3, 1, 1, 0)],
]
lanes1 = [
    [(0, 0, 1, 0), (1, 0, 0, 0)],
    [(0, 0, 1, 1), (1, 1, 0, 0)],
    [(2, 0, 3, 0), (3, 0, 2, 0)],
    [(2, 0, 3, 1), (3, 1, 2, 0)],
]
for name, lanes, exp in (('vbfy1', lanes1, [1, 0, 1, 0]), ('vbfy2', lanes2, [1, 0, 1, 0])):
    for mode in ('or', 'xor'):
        for ch in itertools.product(*lanes):
            fs = mk([c[0] for c in ch], [c[1] for c in ch])
            ft = mk([c[2] for c in ch], [c[3] for c in ch])
            s = apply(comb(US, fs, mode), raw)
            t = apply(comb(UT, ft, mode), raw)
            d = [sat(a + b) for a, b in zip(s, t)]
            if d == exp:
                print(name, mode, ch, s, t)
