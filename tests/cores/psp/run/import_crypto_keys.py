"""Import numeric key data only from the user's saved PSP Developer Wiki Keys page.

No upstream routines are extracted. Output is deterministic and includes the
source file hash. Usage: import_crypto_keys.py "Keys - PSP Developer wiki.htm"
"""
import hashlib
from pathlib import Path
import re
import struct
import sys

from bs4 import BeautifulSoup


def parse(path):
    raw = Path(path).read_bytes()
    text = BeautifulSoup(raw, 'html.parser').get_text('\n', strip=True)
    slots = {int(i, 16): v.upper() for v, i in re.findall(
        r'^([0-9A-Fa-f]{32})\s+([0-9A-Fa-f]{1,2})(?:\s|$)', text, re.M)}
    assert set(range(128)).issubset(slots)
    keys = {}
    for n, body in re.findall(r'(\w+)\[\]\s*=\s*\{(.*?)\}', text, re.S):
        if n.startswith('g_key'):
            words = [int(v, 16) for v in re.findall(r'0x[0-9a-fA-F]+', body)]
            if len(words) == 36:
                keys[n] = struct.pack('<36I', *words).hex().upper()
    for n, body in re.findall(r'(key_[0-9A-Fa-f]{8}|pauthXorKey)\s*=\s*\{(.*?)\}', text, re.S):
        values = bytes(int(v, 16) for v in re.findall(r'0x[0-9a-fA-F]+', body))
        assert len(values) == 16
        keys[n] = values.hex().upper()
    return slots, keys, hashlib.sha256(raw).hexdigest()


def main():
    slots, keys, digest = parse(sys.argv[1])
    lines = ['// Generated numeric data from https://www.psdevwiki.com/psp/Keys',
             '// Saved HTML SHA-256: ' + digest, 'const',
             '  KirkSlotHex: array[0..127] of string = (']
    lines += ["    '%s'%s // %02X" % (slots[i], ',' if i < 127 else ');', i) for i in range(128)]
    lines += ['  PrxSeeds: array[0..%d] of TPRXSeedData = (' % (len(keys) - 1)]
    for i, (name, value) in enumerate(sorted(keys.items())):
        lines.append("    (Name: '%s'; Hex: '%s')%s" % (name, value, ',' if i < len(keys) - 1 else ');'))
    out = Path(__file__).resolve().parents[4] / 'source/cores/psp/PSP.Crypto.Keys.inc'
    out.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print('Imported 128 KIRK slots and', len(keys), 'PRX seeds to', out)


if __name__ == '__main__':
    main()
