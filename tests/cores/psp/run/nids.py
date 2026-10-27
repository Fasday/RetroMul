"""NID name table from pspsdk stubs and import statistics over the survey.

  nids.py names <pspsdk_src> <out.txt>       # "Module NID Name" lines
  nids.py stats <survey.json> <names.txt>    # usage counts per module/function
"""
import collections
import json
import os
import re
import sys


def names(src, out):
    rx = re.compile(r'(?:IMPORT_FUNC|STUB_FUNC)\s*\(?\s*"?([A-Za-z0-9_]+)"?\s*,\s*(0x[0-9A-Fa-f]+)\s*,\s*([A-Za-z0-9_]+)')
    seen = {}
    for dp, dn, fn in os.walk(src):
        for f in fn:
            if f.endswith('.S'):
                for line in open(os.path.join(dp, f), encoding='latin1'):
                    m = rx.search(line)
                    if m:
                        mod, nid, name = m.group(1), int(m.group(2), 16), m.group(3)
                        seen[(mod, nid)] = name
    with open(out, 'w') as fo:
        for (mod, nid), name in sorted(seen.items()):
            fo.write('%s %08X %s\n' % (mod, nid, name))
    print(len(seen))


def stats(survey, namefile):
    nm = {}
    bynid = {}
    for line in open(namefile):
        mod, nid, name = line.split()
        nm[(mod, nid)] = name
        bynid.setdefault(nid, name)
    d = json.load(open(survey, encoding='utf8'))
    use = collections.Counter()
    games = collections.defaultdict(set)
    for g in d:
        for key in ('eboot', 'boot'):
            e = g.get(key, {})
            for lib, nids in e.get('imports', {}).items():
                for n in nids:
                    use[(lib, n)] += 1
                    games[(lib, n)].add(g['file'])
        for p, m in g.get('modules', {}).items():
            for lib, nids in m.get('imports', {}).items():
                for n in nids:
                    use[(lib, n)] += 1
    mods = collections.Counter()
    for (lib, n), c in use.items():
        mods[lib] += 1
    for lib, c in sorted(mods.items()):
        print('== %s (%d distinct)' % (lib, c))
        for (l, n), cnt in sorted(use.items(), key=lambda x: -x[1]):
            if l != lib:
                continue
            print('   %3d %s %s' % (cnt, n, nm.get((l, n.lstrip('V')), bynid.get(n.lstrip('V'), '?'))))


if __name__ == '__main__':
    if sys.argv[1] == 'names':
        names(sys.argv[2], sys.argv[3])
    else:
        stats(sys.argv[2], sys.argv[3])
