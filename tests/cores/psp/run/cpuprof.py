"""hostprof.py with the idle (system DLL) samples dropped and the rest grouped: JIT code, PSP.CPU,
PSP.VFPU, GE, other. Usage: cpuprof.py EXE IMAGE [runner args] [--seconds S] [--top N]"""
import os, re, subprocess, sys
from collections import Counter

ROOT = os.path.dirname(os.path.abspath(__file__))
args = sys.argv[1:]
top = 40
if '--top' in args:
    i = args.index('--top')
    top = int(args[i + 1])
    del args[i:i + 2]
p = subprocess.run([sys.executable, os.path.join(ROOT, 'hostprof.py')] + args + ['--top', '100000'],
                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
rows = []
for line in p.stdout.decode('latin1').split('\n'):
    m = re.match(r'\s*([\d.]+)% (\S+)', line)
    if m:
        rows.append((float(m.group(1)), m.group(2)))
busy = [(v, n) for v, n in rows if not n.startswith('?7ff')]
tot = sum(v for v, _ in busy) or 1
groups = Counter()
for v, n in busy:
    if n.startswith('?'):
        g = 'jit code'
    elif n.startswith('PSP.VFPU'):
        g = 'VFPU'
    elif n.startswith('PSP.CPU.JIT'):
        g = 'JIT runtime'
    elif n.startswith('PSP.CPU'):
        g = 'CPU'
    elif n.startswith('PSP.GE'):
        g = 'GE'
    elif n.startswith('PSP.Memory'):
        g = 'Memory'
    else:
        g = 'other'
    groups[g] += v
print('busy share of samples %.1f%%' % tot)
for g, v in groups.most_common():
    print('  %-12s %5.1f%%' % (g, 100 * v / tot))
for v, n in busy[:top]:
    print('%6.2f%% %s' % (100 * v / tot, n))
