"""Scripted MHP3rd new-character path (Japanese game: Circle confirms).

No patched game files or host-injected game state: input only. The OSK uses
the configured confirm button (Cross by default), so it differs from the game.
"""
import argparse
from pathlib import Path
import subprocess


def presses():
    actions = [('start', 650), ('circle', 850), ('circle', 1150),
               ('circle', 1450), ('circle', 1750)]
    actions += [('cross', f) for f in (1820, 1860, 1900, 1940, 1980, 2020)]
    actions += [('start', 2100)]
    actions += [('down', f) for f in (2220, 2270, 2320, 2370, 2420, 2470, 2520)]
    actions += [('circle', 2750), ('left', 2900), ('circle', 3050), ('circle', 3450),
                ('circle', 3850), ('circle', 4250), ('left', 4450), ('circle', 4650), ('circle', 5050),
                ('circle', 5450), ('start', 7000), ('circle', 7500), ('circle', 8000), ('circle', 8500)]
    actions += [('circle', f) for f in range(14200, 20000, 300)]
    return [x for b, f in actions for x in ('-press', f'{b}@{f}:6')]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('image')
    ap.add_argument('--exe', default=str(Path(__file__).with_name('bin') / 'PSPRun_win64.exe'))
    ap.add_argument('--out', required=True)
    ap.add_argument('--frames', type=int, default=12000)
    ap.add_argument('--memstick', help='explicit persistent test memory stick')
    ap.add_argument('--gpu', action='store_true')
    ap.add_argument('--check', action='store_true')
    args = ap.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    cmd = [args.exe, args.image, '-frames', str(args.frames), '-every', '600', '-out', str(out), '-log', '-state']
    if args.memstick:
        cmd += ['-memstick', args.memstick]
    if args.frames > 20100:
        cmd += ['-press', 'square@20100:6', '-stick', '0,-32768@20300:240',
                '-stick', '32767,0@20800:240', '-stick', '0,32767@21300:240']
    if args.check:
        cmd += ['-gpu-check']
    elif args.gpu:
        cmd += ['-gpu']
    p = subprocess.run(cmd + presses(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=1800)
    (out / 'stdout.txt').write_bytes(p.stdout)
    (out / 'stderr.txt').write_bytes(p.stderr)
    text = p.stderr.decode('latin1', errors='replace')
    for line in text.splitlines():
        if any(x in line for x in ('pauth:', 'frames=', 'gpu check:', 'loader:')):
            print(line)
    # PSPRun uses 1 for a frame-limited run, and 3 for an exception.
    if p.returncode not in (0, 1) or 'frames=' not in text:
        raise SystemExit(p.returncode or 1)


if __name__ == '__main__':
    main()
