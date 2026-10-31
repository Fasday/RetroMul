"""Runs PRX programs on a real PSP through PSPLink and keeps their output.

The PSP runs PSPLink (custom firmware); usbhostfs_pc runs on the PC with the
run directory as its working directory, so host0:/ is that directory. Each
program writes host0:/__testoutput.txt (and may write other files) and ends
by writing host0:/__testfinish.txt. Outputs go to the results directory under
the program's name; nothing in the test tree (.expected files) is written.

    python hwrun.py --root RUNDIR --results OUTDIR [--timeout S] "prog.prx [args]" ...

The PRX paths are relative to RUNDIR (host0:/).
"""
import argparse
import os
import subprocess
import time

OUT, ERR, FINISH, SHOT = '__testoutput.txt', '__testerror.txt', '__testfinish.txt', '__screenshot.bmp'


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--root', required=True, help='usbhostfs_pc working directory (host0:/)')
    p.add_argument('--results', required=True)
    p.add_argument('--pspsh', default='pspsh')
    p.add_argument('--port', default='3000')
    p.add_argument('--timeout', type=int, default=60)
    p.add_argument('programs', nargs='+')
    a = p.parse_args()

    def pspsh(cmd, timeout=10):
        try:
            r = subprocess.run([a.pspsh, '-p', a.port, '-e', cmd], cwd=a.root, capture_output=True, timeout=timeout)
            return r.stdout.decode('utf-8', 'replace')
        except subprocess.TimeoutExpired:
            return None

    def wait(pred, timeout, step=0.2):
        end = time.time() + timeout
        while time.time() < end:
            if pred():
                return True
            time.sleep(step)
        return False

    def ready():
        out = pspsh('ls', 3)
        return out is not None and out.count('\n') > 2

    os.makedirs(a.results, exist_ok=True)
    for prog in a.programs:
        for f in (OUT, ERR, FINISH, SHOT):
            path = os.path.join(a.root, f)
            if os.path.exists(path):
                os.unlink(path)
        parts = prog.split(' ')
        name = os.path.splitext(parts[0].replace('/', '_').replace('\\', '_'))[0]
        if len(parts) > 1:
            name += '_' + '_'.join(parts[1:])
        if not wait(ready, 20):
            print(prog, 'NOCONNECT', flush=True)
            continue
        start = time.time()
        msg = pspsh(prog.replace('\\', '/'))
        status = 'OK'
        if not wait(lambda: os.path.exists(os.path.join(a.root, FINISH)), a.timeout, 0.1):
            pspsh('reset')
            status = 'TIMEOUT'
        elapsed = time.time() - start
        for f, ext in ((OUT, '.txt'), (ERR, '.err'), (SHOT, '.bmp')):
            path = os.path.join(a.root, f)
            if os.path.exists(path) and os.path.getsize(path) > 0:
                with open(path, 'rb') as src, open(os.path.join(a.results, name + ext), 'wb') as dst:
                    dst.write(src.read())
        with open(os.path.join(a.results, name + '.log'), 'w', encoding='utf-8') as f:
            f.write('%s %.1fs\n%s\n' % (status, elapsed, msg or ''))
        print(prog, status, '%.1fs' % elapsed, flush=True)
        # PSPLink resets after a program exits; a command sent before it is
        # back is lost.
        time.sleep(4)


if __name__ == '__main__':
    main()
