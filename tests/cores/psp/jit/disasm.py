"""Disassembles a routine of a dcc64 -GD build (with source lines).

  python tests/cores/psp/jit/disasm.py ROUTINE [--exe EXE] [--max 400]

ROUTINE is a substring of the map's public name (the first match is shown).
Needs the capstone module.
"""
import argparse
import bisect
from pathlib import Path
import struct
import sys

import capstone

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / 'run'))
import hostprof as hp  # noqa: E402
from emuprof import load_lines  # noqa: E402


def text_section(exe):
    data = exe.read_bytes()
    pe = struct.unpack_from('<I', data, 0x3C)[0]
    sections = struct.unpack_from('<H', data, pe + 6)[0]
    opt = struct.unpack_from('<H', data, pe + 20)[0]
    base = pe + 24 + opt
    for i in range(sections):
        name, vsize, va, rsize, raw = struct.unpack_from('<8sIIII', data, base + 40 * i)
        if name.rstrip(b'\0') == b'.text':
            return data[raw:raw + rsize], va
    raise RuntimeError('no .text')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('routine')
    ap.add_argument('--exe', default=str(HERE.parent / 'run/bin/PSPRun_win64.exe'))
    ap.add_argument('--max', type=int, default=400)
    args = ap.parse_args()
    exe = Path(args.exe)
    addrs, names = hp.load_map(str(exe.with_suffix('.map')))
    laddrs, lwhere = load_lines(str(exe.with_suffix('.map')))
    i = next(k for k, n in enumerate(names) if args.routine in n)
    start, end = addrs[i], addrs[i + 1] if i + 1 < len(addrs) else addrs[i] + 0x1000
    text, va = text_section(exe)
    # Segment 0001 starts at the image's .text (map offsets are from it).
    code = text[start:end]
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
    last = None
    print('%s: %d bytes' % (names[i], end - start))
    for n, ins in enumerate(md.disasm(code, start)):
        if n >= args.max:
            break
        k = bisect.bisect_right(laddrs, ins.address) - 1
        where = lwhere[k] if k >= 0 else ''
        if where != last:
            print('    ; %s' % where)
            last = where
        print('  %08x  %-8s %s' % (ins.address, ins.mnemonic, ins.op_str))


if __name__ == '__main__':
    main()
