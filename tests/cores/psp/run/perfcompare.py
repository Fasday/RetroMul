"""Alternate baseline/current CPUPerf runs; report median throughput, not a single loaded-host sample.
Usage: perfcompare.py BASE NEW [--integer-base EXE] [--rounds 5] [--out FILE]
"""
import argparse
import json
import re
import statistics
import subprocess

ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('base')
ap.add_argument('new')
ap.add_argument('--integer-base')
ap.add_argument('--rounds', type=int, default=5)
ap.add_argument('--out')
a = ap.parse_args()
data = {'base': {}, 'new': {}}


def run(exe):
    p = subprocess.run([exe], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300, check=True)
    rows = {}
    for line in p.stdout.decode('latin1').splitlines():
        m = re.match(r'\s*(.*?)\s+([\d,.]+)s ([\d,.]+) Mops', line)
        if m:
            counts = {'vdot.q': 5000000, 'vmmul.q': 1000000, 'vtfm4.q': 3000000,
                      'integer loop': 100000000}
            seconds = float(m[2].replace(',', '.'))
            rows[m[1]] = counts.get(m[1], 10000000) / seconds / 1E6
    return rows


for i in range(a.rounds):
    order = [('base', a.base), ('new', a.new)]
    if i & 1:
        order.reverse()
    for which, exe in order:
        rows = run(exe)
        if which == 'base' and a.integer_base:
            extra = run(a.integer_base)
            for name in ('clz', 'clo', 'bitrev'):
                rows[name] = extra[name]
        for name, val in rows.items():
            data[which].setdefault(name, []).append(val)
        if a.out:
            with open(a.out, 'w') as f:
                json.dump(data, f, indent=2)
    print('completed pair', i + 1, flush=True)
for name, samples in data['base'].items():
    if name not in data['new']:
        continue
    b = statistics.median(samples)
    n = statistics.median(data['new'][name])
    print('%-14s %7.1f -> %7.1f Mops %5.2fx' % (name, b, n, n / b))
