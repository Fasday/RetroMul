"""Resolves merge conflict hunks one by one: resolve_hunks.py FILE CHOICES
CHOICES is one letter per hunk in order: o (ours), t (theirs), b (both, ours first), r (both, theirs first).
"""
import re
import sys

path, choices = sys.argv[1], sys.argv[2]
rx = re.compile(r'<<<<<<< [^\n]*\n(.*?)=======\n(.*?)>>>>>>> [^\n]*\n', re.S)
t = open(path, encoding='utf8', newline='').read()
crlf = '\r\n' in t
t = t.replace('\r\n', '\n')
hunks = rx.findall(t)
if len(hunks) != len(choices):
    raise SystemExit('%d hunks, %d choices' % (len(hunks), len(choices)))
it = iter(choices)


def pick(m):
    c = next(it)
    a, b = m.group(1), m.group(2)
    return {'o': a, 't': b, 'b': a + b, 'r': b + a}[c]


t = rx.sub(pick, t)
if crlf:
    t = t.replace('\n', '\r\n')
open(path, 'w', encoding='utf8', newline='').write(t)
print(path, len(hunks), 'hunks')
