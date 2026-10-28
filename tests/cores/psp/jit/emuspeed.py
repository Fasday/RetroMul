"""Emulator-thread speed of games, old executable against new, with exactness checks.

  python tests/cores/psp/jit/emuspeed.py [filter ...] [--before OLD.exe] [--exe NEW.exe]
         [--rounds 1] [--frames N] [--out DIR]

Each game runs headless with PSPAdapterRun -mash's input at 60 frames a second
(Tekken 6 reaches an arcade battle), a frame hash every 200 frames. "Own cpu" is the
emulator thread's CPU time (GetThreadTimes) minus what it spent drawing for
the CPU renderer (bands while it waits for the pool, small batches: PSPRun's
'ge cpu:' line): the guest CPU, HLE, GE command processing and vertex work,
display conversion. "Own" is the run's wall time minus all waits and draws. Every run of a game
must give the same frame hashes and guest cycles (cpu=..M). With --rounds > 1
old and new alternate (the machine is shared); medians are printed.
"""
import argparse
import ctypes
import ctypes.wintypes as wt
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
EXE = HERE.parent / 'run/bin/PSPRun_win64.exe'
GAMES = [
    ('Tekken_6_[RUS].cso', 6000),
    ('God of War - Chains of Olympus.iso', 3600),
    ('GTA LCS 01.09.2005 ULUX80146 V0.02.iso', 3600),
    ('GTA_VCS_rus.iso', 3600),
    ('SF DM.iso', 3600),
    ('Daxter.iso', 3600),
    ('MGS PW.cso', 3600),
]
SUMMARY = re.compile(r'frames=(\d+) time=([\d,.]+)s guest=([\d,.]+)s .*?hash=(\w*) cpu=([\d,.]+)M')
GE = re.compile(r'waited ([\d,.]+)s .*?drawn on the emulator thread ([\d,.]+)s(?:, helping the pool ([\d,.]+)s)?')
k32 = ctypes.WinDLL('kernel32', use_last_error=True)


class THREADENTRY32(ctypes.Structure):
    _fields_ = [('dwSize', wt.DWORD), ('cntUsage', wt.DWORD), ('th32ThreadID', wt.DWORD),
                ('th32OwnerProcessID', wt.DWORD), ('tpBasePri', wt.LONG), ('tpDeltaPri', wt.LONG),
                ('dwFlags', wt.DWORD)]


def main_thread(pid):
    # The process's first thread (the emulator thread), opened for its times.
    for _ in range(200):
        snap = k32.CreateToolhelp32Snapshot(4, 0)
        te = THREADENTRY32()
        te.dwSize = ctypes.sizeof(te)
        ok = k32.Thread32First(snap, ctypes.byref(te))
        while ok:
            if te.th32OwnerProcessID == pid:
                k32.CloseHandle(snap)
                return k32.OpenThread(0x0800, False, te.th32ThreadID)
            ok = k32.Thread32Next(snap, ctypes.byref(te))
        k32.CloseHandle(snap)
        time.sleep(0.005)
    return None


def thread_seconds(h):
    c, e, k, u = (ctypes.c_ulonglong() for _ in range(4))
    if not h or not k32.GetThreadTimes(h, ctypes.byref(c), ctypes.byref(e), ctypes.byref(k), ctypes.byref(u)):
        return float('nan')
    return (k.value + u.value) / 1E7
FRAME = re.compile(r'frame (\d+) hash (\w+)')


def presses(frames):
    # PSPAdapterRun -mash at 60 frames a second: Start and Cross in turn every
    # 75 frames from frame 480 to 2160 (15 frames each), then Cross every 102
    # frames until 2820. Tekken 6 is in an arcade battle from about 3600.
    out = []
    for k, f in enumerate(range(480, min(frames, 2160), 75)):
        out += ['-press', '%s@%d:15' % ('start' if k % 2 == 0 else 'cross', f)]
    for f in range(2160, min(frames, 2820), 102):
        out += ['-press', 'cross@%d:15' % f]
    return out


def number(s):
    return float(s.replace(',', '.'))


def run(exe, game, frames, out, tag):
    cmd = [str(exe), str(game), '-frames', str(frames), '-every', '200']
    cmd += presses(frames)
    env = dict(os.environ)
    env.pop('PSPJIT', None)
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    h = main_thread(p.pid)
    stdout, stderr = p.communicate(timeout=7200)
    cpu = thread_seconds(h)
    if h:
        k32.CloseHandle(h)
    text = stdout.decode('latin1', 'replace') + '\n' + stderr.decode('latin1', 'replace')
    (out / ('%s_%s.log' % (re.sub(r'[^A-Za-z0-9]+', '_', game.stem), tag))).write_text(text, encoding='utf-8')
    m = SUMMARY.search(text)
    g = GE.search(text)
    if p.returncode or not m or int(m[1]) != frames or not g:
        raise RuntimeError('%s (%s) did not finish %d frames' % (game.name, tag, frames))
    seconds = number(m[2])
    waited = number(g[1])
    drawn = number(g[2])
    helped = number(g[3]) if g[3] else float('nan')
    return dict(seconds=seconds, waited=waited, drawn=drawn, helped=helped, own=seconds - waited - drawn,
                cpu=cpu, owncpu=cpu - helped - drawn, cycles=m[5], hash=m[4], frames=FRAME.findall(text))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('filters', nargs='*')
    ap.add_argument('--exe', type=Path, default=EXE)
    ap.add_argument('--before', type=Path)
    ap.add_argument('--rounds', type=int, default=1)
    ap.add_argument('--frames', type=int)
    ap.add_argument('--games', type=Path, default=Path(r'D:\Soft\PSP'))
    ap.add_argument('--out', type=Path, default=HERE / 'bin/emuspeed')
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    report = {}
    for name, frames in GAMES:
        if args.filters and not any(f.lower() in name.lower() for f in args.filters):
            continue
        frames = args.frames or frames
        exes = [('new', args.exe)]
        if args.before:
            exes.insert(0, ('old', args.before))
        rows = {tag: [] for tag, _ in exes}
        for r in range(args.rounds):
            order = exes if r % 2 == 0 else list(reversed(exes))
            for tag, exe in order:
                row = run(exe, args.games / name, frames, args.out, '%s%d' % (tag, r))
                rows[tag].append(row)
                print('%-40s %-3s %7.2fs own %7.2fs (waited %6.2f, drawn %6.2f); thread cpu %7.2fs, '
                      'own cpu %7.2fs (helped %6.2f) cpu=%sM %s' % (
                          name[:40], tag, row['seconds'], row['own'], row['waited'], row['drawn'], row['cpu'],
                          row['owncpu'], row['helped'], row['cycles'], row['hash']), flush=True)
        all_rows = [x for v in rows.values() for x in v]
        first = all_rows[0]
        for x in all_rows[1:]:
            if x['frames'] != first['frames'] or x['cycles'] != first['cycles'] or x['hash'] != first['hash']:
                raise RuntimeError('%s: frame hashes or guest cycles differ between runs' % name)
        summary = {tag: dict(own=statistics.median(x['own'] for x in v),
                             owncpu=statistics.median(x['owncpu'] for x in v),
                             seconds=statistics.median(x['seconds'] for x in v), runs=v) for tag, v in rows.items()}
        if 'old' in summary:
            o, n = summary['old'], summary['new']
            print('%-40s own cpu %.2fs -> %.2fs (%.2fx); own %.2fs -> %.2fs; wall %.2fs -> %.2fs; '
                  '%d hashes, cpu=%sM identical' % (
                      name[:40], o['owncpu'], n['owncpu'], o['owncpu'] / max(n['owncpu'], 1e-9), o['own'], n['own'],
                      o['seconds'], n['seconds'], len(first['frames']), first['cycles']), flush=True)
        report[name] = summary
        (args.out / 'report.json').write_text(json.dumps(report, indent=1) + '\n', encoding='utf-8')
    return 0


if __name__ == '__main__':
    sys.exit(main())
