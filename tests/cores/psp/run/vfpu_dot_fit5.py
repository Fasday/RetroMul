import sys, os
sys.path.insert(0, os.path.dirname(__file__))
src = open(os.path.join(os.path.dirname(__file__), 'vfpu_dot_fit3.py')).read().split('res = []')[0]
exec(src)


def seqmodel(pairs, F, k, how, mode, pmode, accref):
    acc = Fraction(0)
    for a, b in pairs:
        p = Fraction(a) * Fraction(b)
        if p == 0:
            continue
        rp = inexp(a) + inexp(b) + k
        if acc == 0:
            R = rp
        else:
            ra = mexp(acc) + (0 if accref == 'n' else -1)
            R = max(rp, ra)
        unit = Fraction(2) ** (R - F)
        s = quant(acc, unit, how) + quant(p, unit, how)
        acc = rnd(s, mode) if s != 0 else Fraction(0)
    return float(acc)


res = []
for F in range(20, 30):
    for k in (0, 1):
        for how in ('floor', 'trunc', 'round'):
            for mode in 'nthau':
                for accref in 'nm':
                    b = score(lambda p: seqmodel(p, F, k, how, mode, None, accref))
                    res.append((b, F, k, how, mode, accref))
res.sort()
print('\n'.join(str(r) for r in res[:20]))
