"""Foreground, deterministic-input game comparison (native JIT versus interpreter).

  python tests/cores/psp/jit/game_compare.py [filter ...] [--before older.exe]

Every selected game runs for 2400 frames by default, with the same Start/Cross
presses. Saves the full stdout/stderr and a JSON report in bin/game-compare.
Checks that all runs finish and that the final frame hashes and guest cycles
match. Wall-clock speed is diagnostic only: concurrent workers affect it.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
EXE = HERE.parent / 'run/bin/PSPRun_win64.exe'
GAMES = [
    'Tony Hawks Underground 2 Remix.cso',
    'GTA_VCS_rus.iso',
    'GTA LCS 01.09.2005 ULUX80146 V0.02.iso',
    'FF_IV_TCC.iso',
    'Lumines.cso',
    'SF DM.iso',
]
PRESSES = ['start@500:6', 'cross@650:6', 'cross@800:6', 'start@950:6', 'cross@1100:6']
SUMMARY = re.compile(r'frames=(\d+) time=([\d,.]+)s guest=([\d,.]+)s .*?hash=(\w+) '
                     r'cpu=([\d,.]+)M \(([\d,.]+) MHz host\)')


def number(s):
    return float(s.replace(',', '.'))


def run(exe, game, mode, frames, timeout, out):
    env = os.environ.copy()
    env['PSPJIT'] = 'off' if mode == 'off' else 'stats'
    cmd = [str(exe), str(game), '-frames', str(frames)]
    for press in PRESSES:
        cmd += ['-press', press]
    p = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    text = p.stdout.decode('utf-8', 'replace') + '\n' + p.stderr.decode('utf-8', 'replace')
    name = re.sub(r'[^A-Za-z0-9_.-]', '_', game.stem)
    (out / (name + '_' + mode + '.log')).write_text(text, encoding='utf-8')
    m = SUMMARY.search(text)
    if p.returncode or not m or int(m[1]) != frames or '\nERROR:' in text:
        raise RuntimeError('%s %s did not finish %d frames; see the log' % (game.name, mode, frames))
    return dict(frames=int(m[1]), seconds=number(m[2]), guest_seconds=number(m[3]),
                hash=m[4], guest_mcycles=number(m[5]), mhz=number(m[6]))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('filters', nargs='*')
    ap.add_argument('--exe', type=Path, default=EXE)
    ap.add_argument('--before', type=Path)
    ap.add_argument('--games', type=Path, default=Path(r'D:\Soft\PSP'))
    ap.add_argument('--frames', type=int, default=2400)
    ap.add_argument('--timeout', type=int, default=1800)
    ap.add_argument('--out', type=Path, default=HERE / 'bin/game-compare')
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    report = {}
    for name in GAMES:
        if args.filters and not any(f.lower() in name.lower() for f in args.filters):
            continue
        modes = [('on', args.exe), ('off', args.exe)]
        if args.before:
            modes.insert(0, ('before', args.before))
        rows = {}
        for mode, exe in modes:
            row = run(exe, args.games / name, mode, args.frames, args.timeout, args.out)
            rows[mode] = row
            print('%-41s %-6s %7.2fs %7.1f MHz %s' %
                  (name, mode, row['seconds'], row['mhz'], row['hash']), flush=True)
        if len({(r['hash'], r['frames'], r['guest_mcycles'], r['guest_seconds']) for r in rows.values()}) != 1:
            raise RuntimeError('%s: hashes or guest cycle counts differ' % name)
        report[name] = rows
        (args.out / 'report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print('All selected games have identical final hashes, frames and guest cycles.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
