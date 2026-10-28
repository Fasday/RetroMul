"""Compare the actual GE vertex arithmetic with its former implementation.

  python tests/cores/psp/jit/t24_check.py [--win32] [pairs=50000000]

Extracts the vertex unit's arithmetic (T24, Exp24, Add24, Recip24, FloorInt,
MaxS, MinS) and GEPow from PSP.GE.Engine.pas, so this exercises the routines
that ship, not another copy of them; T24Check.dpr holds the former versions
and the matrix rows ClipPosition used to compute. Uses the installed Delphi
compiler (dcc64 by default, dcc32 with --win32).
"""
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
ARGS = sys.argv[1:]
WIN32 = '--win32' in ARGS
if WIN32:
    ARGS.remove('--win32')
OUT = HERE / 'bin' / 'T24' / ('Win32' if WIN32 else 'Win64')
DCC = Path(r'C:\Program Files (x86)\Embarcadero\Studio\37.0\bin') / ('dcc32.exe' if WIN32 else 'dcc64.exe')


def block(src, first, last, names):
    a = src.index(first)
    b = src.index(last, a)
    text = src[a:b]
    for name in names:
        if 'function ' + name not in text:
            raise RuntimeError('GE arithmetic layout changed (%s); update the extractor' % name)
    return text


def main():
    src = (ROOT / 'source/cores/psp/PSP.GE.Engine.pas').read_text(encoding='utf-8-sig')
    arith = block(src, 'function T24Special(V: Double): Double;', "// A value as the GE's 24-bit floats hold it",
                  ('T24(', 'Exp24(', 'Add24(', 'Recip24(', 'FloorInt(', 'MaxS(', 'MinS('))
    pow = block(src, 'function GEPow(', 'function Unit8(', ('GEPow(',))
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'T24.Actual.inc').write_text(arith, encoding='utf-8')
    (OUT / 'GEPow.Actual.inc').write_text(pow, encoding='utf-8')
    (OUT / 'T24Check.dpr').write_text((HERE / 'T24Check.dpr').read_text(encoding='utf-8'), encoding='utf-8')
    units = str(ROOT / 'source/cores/psp')
    subprocess.run([str(DCC), '-B', '-Q', '-$O+', '-NSSystem;Winapi', '-U' + units, '-NU' + str(OUT),
                    str(OUT / 'T24Check.dpr')], cwd=OUT, check=True)
    return subprocess.call([str(OUT / 'T24Check.exe')] + ARGS, cwd=OUT)


if __name__ == '__main__':
    sys.exit(main())
