import sys, os
sys.path.insert(0, os.path.dirname(__file__))
src = open(os.path.join(os.path.dirname(__file__), 'vfpu_dot_fit3.py')).read().split('res = []')[0]
exec(src)
args = sys.argv[1:] or ['in', '0', '25', 'trunc', 't', '0']
ref, k, F, how, mode, pb = args[0], int(args[1]), int(args[2]), args[3], args[4], int(args[5])
for name, pairs, exp in cases:
    if any(x != x or abs(x) == INF for p in pairs for x in p):
        continue
    r = model(pairs, ref, k, F, how, mode, pb)
    ok = bits(r) == exp if isinstance(exp, int) else ('%f' % r) == exp
    if not ok:
        print(name, pairs, exp, '%f' % r, hex(bits(r)))
