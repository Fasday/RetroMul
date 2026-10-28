"""Paired, resumable game benchmarks. Checks frame hashes and guest cycle counts before reporting speed.
Usage: cpucompare.py BASE NEW --out FILE [--frames 3000] [--only SUBSTRING]
Process CPU time is also recorded on Windows to distinguish host contention from emulator work.
"""
import argparse
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
import re
import subprocess
import time
from cpubench import GAMES

ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('base')
ap.add_argument('new')
ap.add_argument('--out', required=True)
ap.add_argument('--frames', type=int, default=3000)
ap.add_argument('--only')
ap.add_argument('--reverse', action='store_true', help='Invert the alternating A/B order')
a = ap.parse_args()
config = {'frames': a.frames, 'reverse': a.reverse,
          'base': hashlib.sha256(open(a.base, 'rb').read()).hexdigest(),
          'new': hashlib.sha256(open(a.new, 'rb').read()).hexdigest()}
if os.path.exists(a.out):
    with open(a.out) as f:
        data = json.load(f)
    data['config'].setdefault('reverse', False)
    if data['config'] != config:
        raise SystemExit('Output file belongs to a different binary pair or frame count')
else:
    data = {'config': config, 'games': {}}


def save():
    with open(a.out + '.tmp', 'w') as f:
        json.dump(data, f, indent=2)
    os.replace(a.out + '.tmp', a.out)


def process_seconds(proc):
    if os.name != 'nt':
        return None
    k32 = ctypes.WinDLL('kernel32', use_last_error=True)
    ft = wintypes.FILETIME
    k32.GetProcessTimes.argtypes = [wintypes.HANDLE, ctypes.POINTER(ft), ctypes.POINTER(ft),
                                    ctypes.POINTER(ft), ctypes.POINTER(ft)]
    k32.GetProcessTimes.restype = wintypes.BOOL
    start, end, kernel, user = ft(), ft(), ft(), ft()
    if not k32.GetProcessTimes(int(proc._handle), ctypes.byref(start), ctypes.byref(end),
                               ctypes.byref(kernel), ctypes.byref(user)):
        return None
    return ((kernel.dwHighDateTime << 32) + kernel.dwLowDateTime +
            (user.dwHighDateTime << 32) + user.dwLowDateTime) * 1e-7


def run(exe, game):
    cmd = [exe, game, '-frames', str(a.frames), '-press', 'start@500:6', '-press', 'cross@650:6']
    start = time.perf_counter()
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        out = proc.communicate(timeout=3600)[0].decode('latin1')
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()
        raise
    wall = time.perf_counter() - start
    cpu = process_seconds(proc)
    m = re.search(r'frames=.*', out)
    if m is None:
        raise RuntimeError(out[-2000:])
    line = m.group(0).strip()
    return {'summary': line, 'wall': wall, 'process_cpu': cpu,
            'hash': re.search(r'hash=(\w+)', line)[1],
            'cycles': re.search(r'cpu=([\d.,]+)M', line)[1]}


for i, game in enumerate(GAMES):
    if a.only and a.only.lower() not in game.lower():
        continue
    row = data['games'].setdefault(game, {})
    order = [('base', a.base), ('new', a.new)]
    if bool(i & 1) != a.reverse:
        order.reverse()
    for which, exe in order:
        if which not in row:
            row[which] = run(exe, game)
            save()
        print(os.path.basename(game), which, row[which]['summary'],
              'process_cpu=%.3fs' % row[which]['process_cpu'], flush=True)
    if row['base']['hash'] != row['new']['hash'] or row['base']['cycles'] != row['new']['cycles']:
        raise SystemExit('Guest output changed: ' + game)
    print('  identical; wall %.3fx, process CPU %.3fx' % (
        row['base']['wall'] / row['new']['wall'],
        row['base']['process_cpu'] / row['new']['process_cpu']), flush=True)
