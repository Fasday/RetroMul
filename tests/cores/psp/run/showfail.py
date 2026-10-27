"""Prints the diff sections of autotests.txt for the named tests (substring match)."""
import sys
import os

ROOT = os.path.dirname(os.path.abspath(__file__))
t = open(os.path.join(ROOT, 'autotests.txt'), encoding='utf8').read()
parts = t.split('\n==== ')
out = []
for p in parts[1:]:
    head = p.split('\n', 1)[0]
    if any(a in head for a in sys.argv[1:]):
        body = p.split('\n-- stderr', 1)[0]
        out.append('==== ' + body)
text = '\n'.join(out)
dest = os.environ.get('SHOWFAIL_OUT')
if dest:
    open(dest, 'w', encoding='utf8').write(text)
else:
    sys.stdout.write(text + '\n')
