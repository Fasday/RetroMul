"""Hardware results of the VFPU function unit, parsed from exact.expected."""
import os
import struct
import math

ROOT = os.path.dirname(os.path.abspath(__file__))
T = os.path.join(ROOT, 'pspautotests', 'tests', 'cpu', 'vfpu')

FUNCS = ['rcp', 'rsq', 'sqrt', 'sin', 'cos', 'nsin', 'asin', 'exp2', 'rexp2', 'log2', 'nrcp']


def f(b):
    return struct.unpack('<f', struct.pack('<I', b))[0]


def b(x):
    return struct.unpack('<I', struct.pack('<f', x))[0]


def load():
    """Returns {func: [(inbits, outbits)]}."""
    data = {k: [] for k in FUNCS}
    for line in open(os.path.join(T, 'exact.expected')).read().split('\n'):
        if not line or line.startswith('--'):
            continue
        parts = line.split()
        inp = int(parts[0].rstrip(':'), 16)
        for i in range(1, len(parts), 2):
            data[parts[i]].append((inp, int(parts[i + 1], 16)))
    return data


def normal(x):
    e = (x >> 23) & 0xFF
    return 0 < e < 255
