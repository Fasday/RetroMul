"""Brings the PSP unit lists of the application projects in line with
source/cores/psp: removes units that no longer exist and adds new ones.

  sync_projects.py            # rewrites RetroMul and RetromulTerm .dpr/.dproj
"""
import os
import re

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..', '..'))
CORE = os.path.join(ROOT, 'source', 'cores', 'psp')
PROJECTS = [os.path.join(ROOT, 'apps', 'retromul', 'RetroMul'), os.path.join(ROOT, 'apps', 'terminal', 'RetromulTerm')]


def units():
    return sorted(f[:-4] for f in os.listdir(CORE) if f.endswith('.pas'))


def sync_dpr(path, names):
    text = open(path, encoding='utf-8-sig').read()
    nl = '\r\n' if '\r\n' in text else '\n'
    lines = text.split(nl)
    rx = re.compile(r"^\s*(PSP\.[\w.]+) in '\.\.\\\.\.\\source\\cores\\psp\\[\w.]+\.pas',\s*$")
    present = []
    out = []
    anchor = None
    for line in lines:
        m = rx.match(line)
        if m:
            if m.group(1) in names:
                present.append(m.group(1))
                out.append(line)
                anchor = len(out)
            continue
        out.append(line)
    missing = [n for n in names if n not in present]
    if anchor is None:
        raise SystemExit('no PSP units in ' + path)
    add = ["  %s in '..\\..\\source\\cores\\psp\\%s.pas'," % (n, n) for n in missing]
    out[anchor:anchor] = add
    open(path, 'w', encoding='utf-8-sig' if text.startswith('\ufeff') else 'utf-8', newline='').write(nl.join(out))
    return missing


def sync_dproj(path, names):
    text = open(path, encoding='utf-8-sig').read()
    nl = '\r\n' if '\r\n' in text else '\n'
    lines = text.split(nl)
    rx = re.compile(r'^\s*<DCCReference Include="\.\.\\\.\.\\source\\cores\\psp\\([\w.]+)\.pas"/>\s*$')
    present = []
    out = []
    anchor = None
    indent = '        '
    for line in lines:
        m = rx.match(line)
        if m:
            indent = line[:len(line) - len(line.lstrip())]
            if m.group(1) in names:
                present.append(m.group(1))
                out.append(line)
                anchor = len(out)
            continue
        out.append(line)
    missing = [n for n in names if n not in present]
    if anchor is None:
        raise SystemExit('no PSP units in ' + path)
    out[anchor:anchor] = ['%s<DCCReference Include="..\\..\\source\\cores\\psp\\%s.pas"/>' % (indent, n) for n in missing]
    open(path, 'w', encoding='utf-8-sig' if text.startswith('\ufeff') else 'utf-8', newline='').write(nl.join(out))
    return missing


def main():
    names = units()
    for p in PROJECTS:
        a = sync_dpr(p + '.dpr', names)
        b = sync_dproj(p + '.dproj', names)
        print(os.path.basename(p), 'added', a, b)


if __name__ == '__main__':
    main()
