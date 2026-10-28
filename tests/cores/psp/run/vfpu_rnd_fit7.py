import os, sys
sys.path.insert(0, os.path.dirname(__file__))
src = open(os.path.join(os.path.dirname(__file__), 'vfpu_rnd_fit6.py')).read().split('rules = {')[0]
exec(src)


def run_hidden(bits_extra, mode):
    bad = 0
    for s, w3s in seqs:
        W = 32 + bits_extra
        X2, X3, c = s, s, s
        for n in range(2, len(w3s)):
            if mode == 0:
                F = X2 + 2 * X3 + c
            else:
                F = X2 + ((X3 << 1) & ((1 << W) - 1)) + c
            nw = F & M
            if nw != w3s[n]:
                bad += 1
            X2, X3 = X3, F & ((1 << W) - 1)
            X3 = (X3 & ~M) | w3s[n]
            c = F >> W
    return bad


for e in range(0, 4):
    for mode in (0, 1):
        print(e, mode, run_hidden(e, mode))
