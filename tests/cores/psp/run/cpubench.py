"""Runs the CPU-heavy games for a fixed number of frames and prints the runner's summary
(time, guest instructions, host MHz, frame hash). Usage: cpubench.py [EXE] [--frames N] [--only SUBSTR]"""
import os, re, subprocess, sys, time

ROOT = os.path.dirname(os.path.abspath(__file__))
GAMES = [
    r'D:\Soft\PSP\Tony Hawks Underground 2 Remix.cso',
    r'D:\Soft\PSP\Tekken_6_[RUS].cso',
    r'D:\Soft\PSP\Daxter.iso',
    r'D:\Soft\PSP\SF DM.iso',
    r'D:\Soft\PSP\God of War - Chains of Olympus.iso',
    r'D:\Soft\PSP\Star Wars The Force Unleashed rus.ISO',
]


def main():
    args = sys.argv[1:]
    exe = os.path.join(ROOT, 'bin', 'PSPRun_win64.exe')
    frames = '3000'
    only = None
    extra = []
    i = 0
    while i < len(args):
        if args[i] == '--frames':
            frames = args[i + 1]; i += 2
        elif args[i] == '--only':
            only = args[i + 1]; i += 2
        elif args[i] == '--':
            extra = args[i + 1:]; break
        else:
            exe = args[i]; i += 1
    for g in GAMES:
        if only and only.lower() not in g.lower():
            continue
        t = time.time()
        p = subprocess.run([exe, g, '-frames', frames, '-press', 'start@500:6', '-press', 'cross@650:6'] + extra,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=3600)
        out = p.stdout.decode('latin1')
        m = re.search(r'frames=.*', out)
        print('%-45s %6.1fs  %s' % (os.path.basename(g), time.time() - t, m.group(0).strip() if m else 'NO SUMMARY'))
        sys.stdout.flush()


if __name__ == '__main__':
    main()
