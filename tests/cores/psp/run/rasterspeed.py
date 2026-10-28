"""CPU renderer cost and exactness on the reference game runs.

  rasterspeed.py [--mode serial|pool|both] [--repeat 1] [--exe EXE] [game...]

Games: tekken (4200 frames: Start/Cross in turn every 75 frames from 500 to 2200,
then Cross every 100 frames from 2400 to 2800) and gow (2400 frames: Start/Cross
in turn every 75 frames from 500 to 2400). Each run prints the host seconds, the
final frame hash (which must equal the reference) and, from the GE's statistics,
the drawing time: serial = PSP_GE_THREADS=1, every primitive drawn when the GE
reaches it ('drawn on the emulator thread'); pool = the default background pool
('pool busy', 'waited'). Run one game at a time on a quiet machine.
"""
import argparse
import os
import re
import subprocess
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
EXE = os.path.join(ROOT, 'bin', 'PSPRun_win64.exe')
FOLDER = r'D:\Soft\PSP'


def presses_alternating(first, last):
    out = []
    for k, f in enumerate(range(first, last + 1, 75)):
        out += ['-press', '%s@%d:6' % ('start' if k % 2 == 0 else 'cross', f)]
    return out


GAMES = {
    'tekken': ('Tekken_6_[RUS].cso', 4200, '226f4ff99e79d522',
               presses_alternating(500, 2200) + sum((['-press', 'cross@%d:6' % f] for f in range(2400, 2801, 100)), [])),
    'gow': ('God of War - Chains of Olympus.iso', 2400, '0694d8d1ba5012ac', presses_alternating(500, 2400)),
}


def run(exe, game, serial):
    image, frames, want, presses = GAMES[game]
    env = dict(os.environ)
    if serial:
        env['PSP_GE_THREADS'] = '1'
    else:
        env.pop('PSP_GE_THREADS', None)
    t = time.time()
    p = subprocess.Popen([exe, os.path.join(FOLDER, image), '-frames', str(frames)] + presses,
                         stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env)
    err = p.communicate()[1].decode('latin1', 'replace')
    wall = time.time() - t
    cpu = process_seconds(p)
    m = re.search(r'frames=(\d+) .*?hash=(\w+)', err)
    got = m.group(2) if m else '?'
    ge = next((l for l in err.splitlines() if l.startswith('ge cpu:')), '')
    serial_s = re.search(r'drawn on the emulator thread ([\d.,]+)s', ge)
    busy = re.search(r'pool busy ([\d.,]+)s', ge)
    waited = re.search(r'waited ([\d.,]+)s', ge)
    num = lambda x: float(x.group(1).replace(',', '.')) if x else float('nan')
    return wall, got, want, num(serial_s), num(busy), num(waited), p.returncode, cpu


def process_seconds(p):
    """User + kernel CPU seconds of a finished child (Windows; NaN elsewhere). Unlike host seconds these do not
    grow while other programs have the CPU."""
    try:
        import ctypes
        import ctypes.wintypes as wt
        times = [wt.FILETIME() for _ in range(4)]
        if not ctypes.windll.kernel32.GetProcessTimes(wt.HANDLE(int(p._handle)), *[ctypes.byref(x) for x in times]):
            return float('nan')
        f = lambda x: (x.dwHighDateTime << 32 | x.dwLowDateTime) / 1e7
        return f(times[2]) + f(times[3])
    except Exception:
        return float('nan')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('games', nargs='*', default=['tekken', 'gow'])
    ap.add_argument('--mode', default='both', choices=['serial', 'pool', 'both'])
    ap.add_argument('--repeat', type=int, default=1)
    ap.add_argument('--exe', default=EXE)
    a = ap.parse_args()
    bad = 0
    for game in a.games:
        for serial in ([True, False] if a.mode == 'both' else [a.mode == 'serial']):
            for _ in range(a.repeat):
                wall, got, want, ser, busy, waited, code, cpu = run(a.exe, game, serial)
                ok = got == want and code == 0
                bad += not ok
                if serial:
                    detail = 'raster %.1fs, process cpu %.1fs' % (ser, cpu)
                else:
                    detail = 'pool busy %.1fs, emulator waited %.1fs, drawn on it %.1fs, process cpu %.1fs' % (
                        busy, waited, ser, cpu)
                print('%-7s %-6s wall %6.1fs  %s  hash %s %s' % (game, 'serial' if serial else 'pool', wall, detail,
                                                                  got, 'ok' if ok else 'DIFFERS (want %s)' % want),
                      flush=True)
    raise SystemExit(1 if bad else 0)


if __name__ == '__main__':
    main()
