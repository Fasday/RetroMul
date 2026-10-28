"""Maps an address of a dcc64 -GD build to routine and source line.

  addr2line.py EXE ADDRESS IMAGEBASE
"""
import bisect
import os
import re
import sys

exe, addr, base = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3], 16)
off = addr - base - 0x1000
mp = os.path.splitext(exe)[0] + '.map'
pubs = []
lines = []
unit = None
rx_pub = re.compile(r'^\s*0001:([0-9A-F]{8})\s+(\S+)\s*$')
rx_unit = re.compile(r'^Line numbers for (\S+)\((\S+)\)')
rx_line = re.compile(r'(\d+)\s+0001:([0-9A-F]{8})')
section = None
for l in open(mp, encoding='latin1'):
    if 'Publics by Value' in l:
        section = 'pub'
        continue
    m = rx_unit.match(l)
    if m:
        section = 'lines'
        unit = m.group(2)
        continue
    if section == 'pub':
        m = rx_pub.match(l)
        if m:
            pubs.append((int(m.group(1), 16), m.group(2)))
    elif section == 'lines':
        for n, a in rx_line.findall(l):
            lines.append((int(a, 16), unit, int(n)))
pubs.sort()
lines.sort()
i = bisect.bisect_right([p[0] for p in pubs], off) - 1
print('routine:', pubs[i][1] if i >= 0 else '?', '+%x' % (off - pubs[i][0]))
j = bisect.bisect_right([x[0] for x in lines], off) - 1
if j >= 0:
    print('line:', lines[j][1], lines[j][2])
