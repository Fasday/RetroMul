"""Resolves merge conflict hunks in the given files by keeping one side.

  resolve_ours.py ours|theirs|both FILE...
'both' keeps ours then theirs (for lists of declarations or uses).
"""
import re
import sys

mode = sys.argv[1]
rx = re.compile(r'<<<<<<< [^\n]*\n(.*?)=======\n(.*?)>>>>>>> [^\n]*\n', re.S)
for path in sys.argv[2:]:
    t = open(path, encoding='utf8', newline='').read()
    crlf = '\r\n' in t
    t = t.replace('\r\n', '\n')

    def pick(m):
        if mode == 'ours':
            return m.group(1)
        if mode == 'theirs':
            return m.group(2)
        return m.group(1) + m.group(2)

    n = len(rx.findall(t))
    t = rx.sub(pick, t)
    if crlf:
        t = t.replace('\n', '\r\n')
    open(path, 'w', encoding='utf8', newline='').write(t)
    print(path, n, 'hunks')
