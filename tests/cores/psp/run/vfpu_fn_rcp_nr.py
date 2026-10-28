"""Search table + Newton-Raphson reciprocal models (fixed point) against the hardware vrcp."""
import sys, os, itertools
sys.path.insert(0, os.path.dirname(__file__))
from vfpu_fn_data import *
d = load()
pts = {}
for inp, o in d['rcp']:
    if not normal(inp) or not normal(o):
        continue
    M = (inp & 0x7FFFFF) | 0x800000
    if M == 0x800000:
        continue
    pts[M] = 0x800000 | (o & 0x7FFFFF)   # 24-bit result mantissa for r in (0.5, 1)
pts[(0x3dcccccd & 0x7FFFFF) | 0x800000] = 0x800000 | (0x41200000 & 0x7FFFFF)
P = sorted(pts.items())
print(len(P), 'mantissas')


def model(M, J, K, c2, iters, B, rnd):
    i = (M >> (23 - J)) & ((1 << J) - 1)
    # table: 2^K / (1 + (i + c2/2)/2^J), as Y with K fraction bits
    num = (1 << (K + J + 1)) * 2
    den = 2 * ((1 << (J + 1)) + 2 * i + c2)
    Y = (num // den) if not rnd else (num + den // 2) // den
    F = K
    for _ in range(iters):
        s = 23 + F - B
        Pm = (M * Y) >> s if s >= 0 else (M * Y) << -s  # m*y with B fraction bits, truncated
        E = (2 << B) - Pm
        Y = (Y * E) >> B                      # keeps F fraction bits
    R = (Y << 24) >> F if F <= 24 else Y >> (F - 24)
    return R & ~3


best = []
for J in range(5, 13):
    for K in range(J + 2, 31):
        for c2 in (0, 1, 2):
            for iters in (1, 2):
                for B in range(22, 34):
                    for rnd in (0, 1):
                        bad = 0
                        for M, R in P:
                            if model(M, J, K, c2, iters, B, rnd) != R:
                                bad += 1
                                if bad > 20:
                                    break
                        if bad <= 20:
                            best.append((bad, J, K, c2, iters, B, rnd))
best.sort()
print(best[:20])
