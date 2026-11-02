"""Updates PSP.Misc.pas's generated JIS X 0201 / JIS X 0208 data section:
codes to Unicode, from the host's code page 932. sceCcc uses it when the program sets no tables.

  genccc.py            # writes the generated Pascal data block
  genccc.py check      # compares with the tables pspautotests/tests/ccc ships (taken from a PSP)
"""
import os
import struct
import sys
import io
from pascal_data import write_block

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', '..', '..', '..', 'source', 'cores', 'psp', 'PSP.Misc.pas')


def jis_to_sjis(j):
    j1, j2 = j >> 8, j & 0xFF
    s1 = (j1 + 1) // 2 + 0x70
    if s1 >= 0xA0:
        s1 += 0x40
    if j1 & 1:
        s2 = j2 + 0x1F
        if s2 >= 0x7F:
            s2 += 1
    else:
        s2 = j2 + 0x7E
    return bytes([s1, s2])


def build():
    pairs = [(c, c) for c in range(0x01, 0x20)]
    for c in list(range(0x20, 0x7F)) + list(range(0xA1, 0xE0)):
        pairs.append((c, ord(bytes([c]).decode('cp932'))))
    for j1 in range(0x21, 0x7F):
        for j2 in range(0x21, 0x7F):
            j = (j1 << 8) | j2
            try:
                u = jis_to_sjis(j).decode('cp932')
            except UnicodeDecodeError:
                continue
            if len(u) == 1:
                pairs.append((j, ord(u)))
    return pairs


def check(pairs):
    d = os.path.join(HERE, 'pspautotests', 'tests', 'ccc')
    j2u = struct.unpack('<65536H', open(os.path.join(d, 'jis2ucs.bin'), 'rb').read())
    ours = dict(pairs)
    conflicts = [j for j in ours if j2u[j] and j2u[j] != ours[j]]
    print('entries %d, conflicts %d, only here %d, only on the PSP %d' % (
        len(pairs), len(conflicts), sum(1 for j in ours if not j2u[j]),
        sum(1 for j in range(65536) if j2u[j] and j not in ours)))


def write(pairs):
    with io.StringIO() as out:
        out.write('{ Generated from code page 932: JIS X 0201 bytes and\n')
        out.write('  JIS X 0208 row/cell codes, each packed as (JIS shl 16) or Unicode, in JIS order. }\n\n')
        out.write('const\n  CccJisCount = %d;\n  CccJisTable: array[0..CccJisCount - 1] of Cardinal = (\n' % len(pairs))
        vals = ['$%08X' % ((j << 16) | u) for j, u in pairs]
        for i in range(0, len(vals), 10):
            out.write('    ' + ', '.join(vals[i:i + 10]) + (',' if i + 10 < len(vals) else ');') + '\n')
        write_block(OUT, 'PSP_CCC_DATA', out.getvalue())
    print(len(pairs), 'entries')


if __name__ == '__main__':
    p = build()
    if len(sys.argv) > 1 and sys.argv[1] == 'check':
        check(p)
    else:
        write(p)
