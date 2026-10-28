import os, struct
ROOT = os.path.dirname(os.path.abspath(__file__))
l = open(os.path.join(ROOT, 'pspautotests', 'tests', 'cpu', 'vfpu', 'vector.expected')).read().split('\n')
r = [x for x in l if x.startswith('checkVwbn')]
vals = [1e-20, 1, 100, 1e8, 2, 3, 4, 5, 100, 102, 104, 109, -100, -1e7, -0.001, -1]
out = []
for i, v in enumerate(vals):
    b = struct.unpack('<I', struct.pack('<f', v))[0]
    out.append('%-8g %08x | ' % (v, b) + ' | '.join(r[i * 4 + k].split(': ')[1] for k in range(4)))
open(os.environ.get('OUTF', 'vwbn.txt'), 'w').write('\n'.join(out) + '\n')
print(len(r))
