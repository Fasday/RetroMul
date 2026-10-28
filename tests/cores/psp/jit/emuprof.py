"""The emulator thread's profile of a game, by area.

  python tests/cores/psp/jit/emuprof.py GAME [--frames 3000] [--skip 5] [--seconds 40] [--top 40] [--exe EXE]

The input is emuspeed.py's (PSPAdapterRun -mash's presses at 60 frames a second).
Like hostprof.py --main, but the emulator thread's handle is opened once and
sampled about a thousand times a second. Prints each area's share and the
hottest routines ('??': generated code).
"""
import argparse
import bisect
import ctypes
from pathlib import Path
import subprocess
import sys
import time
from collections import Counter

HERE = Path(__file__).resolve().parent
RUN = HERE.parent / 'run'
sys.path.insert(0, str(RUN))
import hostprof as hp  # noqa: E402

AREAS = [
    ('raster (helping the pool)', ('PSP.GE.Raster', 'PSP.GE.Texture', 'PSP.GE.Pixel',
                                   'PSP.GE.Workers.TGEWorkers.WorkBands', 'PSP.GE.Workers.TGEWorkers.DrawSerial')),
    ('GE queue bookkeeping', ('PSP.GE.Workers',)),
    ('GE commands and vertices', ('PSP.GE.',)),
    ('generated code', ('??',)),
    ('recompiler (Pascal)', ('PSP.CPU.JIT',)),
    ('VFPU', ('PSP.VFPU',)),
    ('CPU/FPU handlers', ('PSP.CPU.',)),
    ('memory', ('PSP.Memory',)),
    ('display', ('PSP.Display',)),
    ('media', ('PSP.Mpeg', 'PSP.Psmf', 'PSP.Media', 'PSP.Atrac', 'PSP.MP3', 'PSP.AudioCodec', 'PSP.SAS',
               'PSP.Audio', 'PSP.Jpeg', 'PSP.Mp4', 'Video', 'Audio.', 'FMXAudio', 'Codec')),
    ('HLE, kernel, IO', ('PSP.',)),
    ('RTL', ('System.',)),
]


def presses(frames):
    # As emuspeed.py (PSPAdapterRun -mash at 60 frames a second).
    out = []
    for k, f in enumerate(range(480, min(frames, 2160), 75)):
        out += ['-press', '%s@%d:15' % ('start' if k % 2 == 0 else 'cross', f)]
    for f in range(2160, min(frames, 2820), 102):
        out += ['-press', 'cross@%d:15' % f]
    return out


def area(name):
    for title, prefixes in AREAS:
        if any(name.startswith(p) for p in prefixes):
            return title
    if name.startswith('?'):
        return 'system (waits, OS)'
    return 'other'


def load_lines(map_path):
    # (addresses, 'unit.pas:line') from the detailed map's line number sections.
    import re
    addrs, where = [], []
    unit = None
    rx = re.compile(r'(\d+) 0001:([0-9A-F]{8})')
    for line in open(map_path, encoding='latin1'):
        if line.startswith('Line numbers for '):
            m = re.match(r'Line numbers for [^(]*\(([^)]*)\) segment \.text', line)
            unit = m.group(1) if m else None
            continue
        if unit:
            found = rx.findall(line)
            if not found and line.strip() and not line.startswith(' '):
                unit = None
            for n, a in found:
                addrs.append(int(a, 16))
                where.append('%s:%s' % (unit, n))
    order = sorted(range(len(addrs)), key=lambda i: addrs[i])
    return [addrs[i] for i in order], [where[i] for i in order]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('game')
    ap.add_argument('--lines', help='per source line within routines whose name contains this')
    ap.add_argument('--exe', default=str(RUN / 'bin/PSPRun_win64.exe'))
    ap.add_argument('--frames', type=int, default=3000)
    ap.add_argument('--skip', type=float, default=5)
    ap.add_argument('--seconds', type=float, default=40)
    ap.add_argument('--top', type=int, default=40)
    ap.add_argument('--games', default=r'D:\Soft\PSP')
    args = ap.parse_args()
    game = args.game if Path(args.game).exists() else str(next(Path(args.games).glob('*%s*' % args.game)))
    cmd = [args.exe, game, '-frames', str(args.frames)]
    cmd += presses(args.frames)
    addrs, names = hp.load_map(str(Path(args.exe).with_suffix('.map')))
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.3)
    snap = hp.k32.CreateToolhelp32Snapshot(hp.TH32CS_SNAPTHREAD, 0)
    te = hp.THREADENTRY32()
    te.dwSize = ctypes.sizeof(te)
    ok = hp.k32.Thread32First(snap, ctypes.byref(te))
    tid = None
    while ok and tid is None:
        if te.th32OwnerProcessID == proc.pid:
            tid = te.th32ThreadID
        ok = hp.k32.Thread32Next(snap, ctypes.byref(te))
    hp.k32.CloseHandle(snap)
    h = hp.k32.OpenThread(hp.THREAD_ALL, False, tid)
    psapi = ctypes.WinDLL('psapi')
    mods = (ctypes.c_void_p * 1)()
    need = hp.wt.DWORD()
    hproc = hp.k32.OpenProcess(0x1F0FFF, False, proc.pid)
    psapi.EnumProcessModules(hproc, mods, ctypes.sizeof(mods), ctypes.byref(need))
    base = mods[0] or 0x140000000
    time.sleep(args.skip)
    counts = Counter()
    lines = Counter()
    if args.lines:
        laddrs, lwhere = load_lines(str(Path(args.exe).with_suffix('.map')))
    ctx = hp.CONTEXT()
    end = time.time() + args.seconds
    while time.time() < end and proc.poll() is None:
        if hp.k32.SuspendThread(h) != 0xFFFFFFFF:
            ctx.ContextFlags = hp.CONTEXT_CONTROL
            if hp.k32.GetThreadContext(h, ctypes.byref(ctx)):
                rip = ctx.Rip - base - 0x1000
                i = bisect.bisect_right(addrs, rip) - 1
                if 0 <= i < len(names) and rip - addrs[i] < 0x100000:
                    counts[names[i]] += 1
                    if args.lines and args.lines in names[i]:
                        k = bisect.bisect_right(laddrs, rip) - 1
                        if k >= 0:
                            lines[lwhere[k]] += 1
                elif ctx.Rip >= 0x7FF000000000:
                    counts['?system'] += 1
                else:
                    counts['??'] += 1
            hp.k32.ResumeThread(h)
        time.sleep(0.001)
    proc.kill()
    total = sum(counts.values())
    by_area = Counter()
    for n, c in counts.items():
        by_area[area(n)] += c
    print('%s: %d samples of the emulator thread' % (Path(game).name, total))
    for title, c in by_area.most_common():
        print('  %6.2f%% %s' % (100.0 * c / total, title))
    for n, c in counts.most_common(args.top):
        print('%6.2f%% %-26s %s' % (100.0 * c / total, area(n), n))
    if args.lines:
        print('lines of %s:' % args.lines)
        for n, c in lines.most_common(args.top):
            print('%6.2f%% %s' % (100.0 * c / total, n))


if __name__ == '__main__':
    main()
