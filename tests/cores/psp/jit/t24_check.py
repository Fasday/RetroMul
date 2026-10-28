"""Compare the actual GE vertex arithmetic with its former implementation.

  python tests/cores/psp/jit/t24_check.py [--win32] [pairs=50000000]

Extracts T24, Exp24 and Add24 from PSP.GE.Engine.pas, so this exercises the
routines that ship, not another copy of them. Uses the installed Delphi
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


def main():
    src = (ROOT / 'source/cores/psp/PSP.GE.Engine.pas').read_text(encoding='utf-8-sig')
    first = src.index('function T24(V: Double): Double;')
    last = src.index('// The GE\'s 1/x:', first)
    actual = src[first:last]
    if not all('function ' + name in actual for name in ('T24(', 'Exp24(', 'Add24(')):
        raise RuntimeError('GE arithmetic layout changed; update the extractor')
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'T24.Actual.inc').write_text(actual, encoding='utf-8')
    (OUT / 'T24Check.dpr').write_text((HERE / 'T24Check.dpr').read_text(encoding='utf-8'), encoding='utf-8')
    subprocess.run([str(DCC), '-B', '-Q', '-$O+', '-NSSystem;Winapi', str(OUT / 'T24Check.dpr')],
                   cwd=OUT, check=True)
    return subprocess.call([str(OUT / 'T24Check.exe')] + ARGS, cwd=OUT)


if __name__ == '__main__':
    sys.exit(main())
