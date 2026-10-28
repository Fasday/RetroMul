"""Compare CPU and optional Vulkan GE rendering, without hardware tolerances.

  gpudiff.py [filters...] [--check] [--games] [--frames N] [--mash N]

Default filters: gpu/. Each test runs twice, once on CPU and once with -gpu.
All screenshots (including repeated sceDisplay screenshots), stdout, exit code
and the entire final 2 MiB VRAM must agree. --check compares each GPU batch
against the CPU internally. --games treats filters as image paths, also compares
frames every 60 frames; --mash N alternates Start/Cross from frame N.
SAME means agreement with the CPU reference, NOT a pass against real hardware.
"""
import argparse
import concurrent.futures
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
TESTS = Path(os.environ.get('PSP_AUTOTESTS') or ROOT / 'pspautotests' / 'tests')
EXE = ROOT / 'bin' / 'PSPRun_win64.exe'
TEMP = Path(os.environ.get('LOCALAPPDATA', tempfile.gettempdir())) / 'Temp' / 'opencode'
TEMP.mkdir(parents=True, exist_ok=True)


def collect(filters):
    return sorted(p.relative_to(TESTS).with_suffix('').as_posix()
                  for p in TESTS.rglob('*.prx')
                  if p.with_suffix('.expected').exists()
                  and any(f in p.relative_to(TESTS).as_posix() for f in filters))


def execute(args, timeout):
    try:
        p = subprocess.run([str(a) for a in args], stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=timeout)
        return p.returncode, p.stdout, p.stderr.decode('latin1')
    except subprocess.TimeoutExpired as e:
        return -1, e.stdout or b'', (e.stderr or b'').decode('latin1') + '\ntimeout'


def gpu_lines(err):
    return [line for line in err.splitlines() if line.startswith('gpu')]


def run(name, args):
    game = args.games
    image = name if game else str(TESTS / (name + '.prx'))
    common = [args.exe, image, '-frames', str(args.frames)]
    if game:
        common += ['-every', '60']
        if args.mash:
            for i, frame in enumerate(range(args.mash, args.frames + 1, 60)):
                common += ['-press', ('start' if i % 2 == 0 else 'cross') + '@%d:6' % frame]
    else:
        common += ['-test', '-quiet']
    timeout = args.timeout * (20 if game else 1)
    if args.check:
        code, out, err = execute(common + ['-gpu-check'], timeout)
        match = re.search(r'gpu check: (\d+) of (\d+) batches differ', err)
        notes = gpu_lines(err)
        if code:
            return name, 'TIMEOUT' if code == -1 else 'CRASH', '\n'.join(notes + err.splitlines()[-6:])
        if not match:
            return name, 'NOGPU', '\n'.join(notes or err.splitlines()[-6:])
        status = 'DIFF' if int(match[1]) else ('SAME' if int(match[2]) else 'NO_DRAWS')
        return name, status, '\n'.join(notes)

    with tempfile.TemporaryDirectory(prefix='ge-diff-', dir=TEMP) as tmp:
        results, dirs = [], []
        for mode in ('cpu', 'gpu'):
            dest = Path(tmp) / mode
            dest.mkdir()
            dirs.append(dest)
            cmd = common + ['-shot', dest / 'shot.bmp', '-vram', dest / 'vram.bin']
            if game:
                cmd += ['-out', dest]
            if mode == 'gpu':
                cmd += ['-gpu']
            results.append(execute(cmd, timeout))
        notes = []
        status = 'SAME'
        for i, (code, out, err) in enumerate(results):
            if code:
                status = 'TIMEOUT' if code == -1 else 'CRASH'
                notes.append('%s exit %d: %s' % (('cpu', 'gpu')[i], code, '\n'.join(err.splitlines()[-5:])))
        if results[0][1] != results[1][1]:
            status = 'DIFF'
            notes.append('stdout differs')
        files = [{p.name: p.read_bytes() for p in d.iterdir() if p.is_file()} for d in dirs]
        if 'vram.bin' not in files[0] or 'vram.bin' not in files[1]:
            status = 'CRASH'
            notes.append('VRAM dump missing')
        for filename in sorted(files[0].keys() | files[1].keys()):
            a, b = files[0].get(filename), files[1].get(filename)
            if a != b:
                status = 'DIFF'
                first = next((i for i, (x, y) in enumerate(zip(a or b'', b or b'')) if x != y), -1)
                notes.append('%s differs (first byte offset %x)' % (filename, first))
        err = results[1][2]
        stats = re.search(r'gpu: (\d+) batches, (\d+) passes, (\d+) prims, (\d+) on the CPU', err)
        if not stats:
            status = 'NOGPU'
        elif stats[3] == '0' and status == 'SAME':
            status = 'NO_DRAWS'
        notes += gpu_lines(err)
        if game:
            hashes = [re.findall(r'frame (\d+) hash (\w+)', r[2]) for r in results]
            if hashes[0] != hashes[1]:
                status = 'DIFF'
                notes.append('frame hashes/counts differ')
            times = [re.search(r'time=([\d.,]+)s', r[2]) for r in results]
            notes.insert(0, 'cpu %s s, gpu %s s; %d frame snapshots, final VRAM compared' %
                         (times[0] and times[0][1], times[1] and times[1][1], len(hashes[0])))
        return name, status, '\n'.join(notes)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('filters', nargs='*')
    ap.add_argument('--exe', default=str(EXE))
    ap.add_argument('--frames', type=int, default=1200)
    ap.add_argument('--jobs', type=int, default=4)
    ap.add_argument('--timeout', type=int, default=120)
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--games', action='store_true')
    ap.add_argument('--mash', type=int, default=0)
    ap.add_argument('--out', default=str(ROOT / 'gpudiff.txt'))
    args = ap.parse_args()
    tests = args.filters if args.games else collect(args.filters or ['gpu/'])
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        results = sorted(pool.map(lambda name: run(name, args), tests))
    counts = {}
    with open(args.out, 'w', encoding='utf8') as output:
        for name, status, notes in results:
            counts[status] = counts.get(status, 0) + 1
            output.write('%s %s\n  %s\n' % (status, name, notes.replace('\n', '\n  ')))
            if status not in ('SAME', 'NO_DRAWS') or args.games:
                print('%-9s %s\n  %s' % (status, name, notes.replace('\n', '\n  ')))
    print(' '.join('%s=%d' % pair for pair in sorted(counts.items())), 'total=%d' % len(results))
    return 1 if any(status not in ('SAME', 'NO_DRAWS') for _, status, _ in results) or not results else 0


if __name__ == '__main__':
    raise SystemExit(main())
