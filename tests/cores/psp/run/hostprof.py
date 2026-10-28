"""Sampling profiler for a running PSPRun (or any dcc64 -GD build) on Windows.

  hostprof.py EXE [args...] [--seconds 20] [--rate 500] [--top 40]

Starts EXE, samples the instruction pointer of all its threads, maps the
addresses to routines with the .map file next to the exe, prints the hottest.
"""
import bisect
import ctypes
import ctypes.wintypes as wt
import os
import re
import subprocess
import sys
import time
from collections import Counter

k32 = ctypes.WinDLL('kernel32', use_last_error=True)
TH32CS_SNAPTHREAD = 0x4
THREAD_ALL = 0x001F03FF
CONTEXT_AMD64 = 0x100000
CONTEXT_CONTROL = CONTEXT_AMD64 | 0x1


class THREADENTRY32(ctypes.Structure):
    _fields_ = [('dwSize', wt.DWORD), ('cntUsage', wt.DWORD), ('th32ThreadID', wt.DWORD),
                ('th32OwnerProcessID', wt.DWORD), ('tpBasePri', wt.LONG), ('tpDeltaPri', wt.LONG),
                ('dwFlags', wt.DWORD)]


class M128A(ctypes.Structure):
    _fields_ = [('Low', ctypes.c_uint64), ('High', ctypes.c_int64)]


class CONTEXT(ctypes.Structure):
    _pack_ = 16
    _fields_ = [('P1Home', ctypes.c_uint64), ('P2Home', ctypes.c_uint64), ('P3Home', ctypes.c_uint64),
                ('P4Home', ctypes.c_uint64), ('P5Home', ctypes.c_uint64), ('P6Home', ctypes.c_uint64),
                ('ContextFlags', wt.DWORD), ('MxCsr', wt.DWORD),
                ('SegCs', wt.WORD), ('SegDs', wt.WORD), ('SegEs', wt.WORD), ('SegFs', wt.WORD),
                ('SegGs', wt.WORD), ('SegSs', wt.WORD), ('EFlags', wt.DWORD),
                ('Dr0', ctypes.c_uint64), ('Dr1', ctypes.c_uint64), ('Dr2', ctypes.c_uint64),
                ('Dr3', ctypes.c_uint64), ('Dr6', ctypes.c_uint64), ('Dr7', ctypes.c_uint64),
                ('Rax', ctypes.c_uint64), ('Rcx', ctypes.c_uint64), ('Rdx', ctypes.c_uint64),
                ('Rbx', ctypes.c_uint64), ('Rsp', ctypes.c_uint64), ('Rbp', ctypes.c_uint64),
                ('Rsi', ctypes.c_uint64), ('Rdi', ctypes.c_uint64), ('R8', ctypes.c_uint64),
                ('R9', ctypes.c_uint64), ('R10', ctypes.c_uint64), ('R11', ctypes.c_uint64),
                ('R12', ctypes.c_uint64), ('R13', ctypes.c_uint64), ('R14', ctypes.c_uint64),
                ('R15', ctypes.c_uint64), ('Rip', ctypes.c_uint64),
                ('FltSave', ctypes.c_byte * 512), ('VectorRegister', M128A * 26),
                ('VectorControl', ctypes.c_uint64), ('DebugControl', ctypes.c_uint64),
                ('LastBranchToRip', ctypes.c_uint64), ('LastBranchFromRip', ctypes.c_uint64),
                ('LastExceptionToRip', ctypes.c_uint64), ('LastExceptionFromRip', ctypes.c_uint64)]


def load_map(path):
    """(addresses, names) of publics from a Delphi detailed map (segment 0001 = .text at image base + 0x1000)."""
    addrs, names = [], []
    rx = re.compile(r'^\s*0001:([0-9A-F]{8})\s+(\S+)\s*$')
    in_pub = False
    for line in open(path, encoding='latin1'):
        if 'Publics by Value' in line:
            in_pub = True
            continue
        if in_pub:
            m = rx.match(line)
            if m:
                addrs.append(int(m.group(1), 16))
                names.append(m.group(2))
            elif line.startswith(' Line numbers') or line.startswith('Line numbers'):
                break
    order = sorted(range(len(addrs)), key=lambda i: addrs[i])
    return [addrs[i] for i in order], [names[i] for i in order]


def main():
    args = sys.argv[1:]
    seconds, rate, top = 20.0, 500, 40
    for flag in ('--seconds', '--rate', '--top'):
        if flag in args:
            i = args.index(flag)
            v = args[i + 1]
            del args[i:i + 2]
            if flag == '--seconds':
                seconds = float(v)
            elif flag == '--rate':
                rate = int(v)
            else:
                top = int(v)
    exe = args[0]
    mp = os.path.splitext(exe)[0] + '.map'
    addrs, names = load_map(mp)
    proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.5)
    hproc = k32.OpenProcess(0x1F0FFF, False, proc.pid)
    psapi = ctypes.WinDLL('psapi')
    mods = (ctypes.c_void_p * 1)()
    need = wt.DWORD()
    psapi.EnumProcessModules(hproc, mods, ctypes.sizeof(mods), ctypes.byref(need))
    base = mods[0] or 0x140000000
    counts = Counter()
    total = 0
    end = time.time() + seconds
    ctx = CONTEXT()
    while time.time() < end and proc.poll() is None:
        snap = k32.CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0)
        te = THREADENTRY32()
        te.dwSize = ctypes.sizeof(te)
        ok = k32.Thread32First(snap, ctypes.byref(te))
        while ok:
            if te.th32OwnerProcessID == proc.pid:
                h = k32.OpenThread(THREAD_ALL, False, te.th32ThreadID)
                if h:
                    if k32.SuspendThread(h) != 0xFFFFFFFF:
                        ctx.ContextFlags = CONTEXT_CONTROL
                        if k32.GetThreadContext(h, ctypes.byref(ctx)):
                            rip = ctx.Rip - base - 0x1000
                            i = bisect.bisect_right(addrs, rip) - 1
                            if 0 <= i < len(names) and rip - addrs[i] < 0x100000:
                                counts[names[i]] += 1
                            else:
                                counts['?%x' % ctx.Rip] += 1
                            total += 1
                        k32.ResumeThread(h)
                    k32.CloseHandle(h)
            ok = k32.Thread32Next(snap, ctypes.byref(te))
        k32.CloseHandle(snap)
        time.sleep(1.0 / rate)
    proc.kill()
    idle = sum(c for n, c in counts.items() if 'NtWaitFor' in n or n.startswith('?7ff'))
    print('samples', total)
    for n, c in counts.most_common(top):
        print('%6.2f%% %s' % (100.0 * c / max(1, total), n))


if __name__ == '__main__':
    main()
