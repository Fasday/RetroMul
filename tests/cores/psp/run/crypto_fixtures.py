"""Independent synthetic PRX/KIRK fixtures (no commercial content).

AES/CMAC oracle: PyCryptodome. ECDSA: plain Python integer curve equation.
Only the *published* KIRK test signing scalar is used, never a user's key.
Usage: crypto_fixtures.py "Keys - PSP Developer wiki.htm"
The resulting include is committed; normal tests require neither Python nor
PyCryptodome/the wiki HTML.
"""
import gzip
import hashlib
from pathlib import Path
import struct
import sys

from Crypto.Cipher import AES
from Crypto.Hash import CMAC
from import_crypto_keys import parse


P = int('FFFFFFFFFFFFFFFF00000001FFFFFFFFFFFFFFFF', 16)
N = int('FFFFFFFFFFFFFFFF0001B5C617F290EAE1DBAD8F', 16)
G = (int('2259ACEE15489CB096A882F0AE1CF9FD8EE5F8FA', 16),
     int('604358456D0A1CB2908DE90F27D75C82BEC108C0', 16))
TEST_D = int('F392E26490B80FD889F2D9722C1F34D7274F983D', 16)


def add(a, b):
    if a is None:
        return b
    if b is None:
        return a
    x, y = a
    u, v = b
    if x == u:
        if (y + v) % P == 0:
            return None
        slope = (3*x*x - 3) * pow(2*y, -1, P) % P
    else:
        slope = (v-y) * pow(u-x, -1, P) % P
    xx = (slope*slope - x - u) % P
    return xx, (slope*(x-xx) - y) % P


def scale(a, k):
    r = None
    while k:
        if k & 1:
            r = add(r, a)
        a = add(a, a)
        k >>= 1
    return r


def sign(data):
    h = hashlib.sha1(data).digest()
    nonce = int.from_bytes(hashlib.sha256(b'RetroMul fixture' + h).digest(), 'big') % (N-1) + 1
    r = scale(G, nonce)[0] % N
    s = ((int.from_bytes(h, 'big') + r*TEST_D) * pow(nonce, -1, N)) % N
    return r.to_bytes(20, 'big') + s.to_bytes(20, 'big')


def xor(a, b):
    assert len(a) == len(b)
    return bytes(x ^ y for x, y in zip(a, b))


def encrypt(data, key):
    return AES.new(key, AES.MODE_CBC, iv=bytes(16)).encrypt(bytes(data))


def decrypt(data, key):
    return AES.new(key, AES.MODE_CBC, iv=bytes(16)).decrypt(bytes(data))


def mac(data, key):
    h = CMAC.new(key, ciphermod=AES)
    h.update(bytes(data))
    return h.digest()


def kirk(payload, metadata, signed):
    size = len(payload)
    data_key = bytes(range(16))
    mac_key = bytes(range(16, 32))
    b = bytearray(0x90)
    b[:32] = encrypt(data_key + mac_key, bytes.fromhex('98C940975C1D10E87FE60EA3FD03A8BA'))
    struct.pack_into('<4I', b, 0x60, 1, int(signed), 0, 0)
    struct.pack_into('<2I', b, 0x70, size, 0x80)
    b += metadata + encrypt(payload + bytes((-size) & 15), data_key)
    if signed:
        b[0x10:0x38] = sign(b[0x60:0x90])
        b[0x38:0x60] = sign(b[0x60:])
    else:
        b[0x20:0x30] = mac(b[0x60:0x90], mac_key)
        b[0x30:0x40] = mac(b[0x60:], mac_key)
    return b


def metadata(size):
    d = bytearray(0x80)
    d[:4] = b'~PSP'
    d[0xA:0x19] = b'RetroMulFixture'
    struct.pack_into('<I', d, 0x28, size)
    return d


def legacy(tag, seed, slot, extra, payload):
    m = metadata(len(payload))
    b = kirk(payload, m, False)
    h = bytearray(0x150)
    h[:4] = struct.pack('<I', tag)
    h[0x40:0xB0] = xor(encrypt(xor(b[:0x70], seed[0x20:0x90]), slot), seed[0x14:0x84])
    h[0xB0:] = b[0x70:0x110]
    h[4:24] = hashlib.sha1(seed[:20] + h[24:]).digest()
    if extra:
        h[0x10:0xB0] = encrypt(h[0x10:0xB0], slot)
    return m + h[0x80:0xD0] + h[:0x80] + b[0x110:]


def modern(tag, seed, slot, payload, elfsize, signed=False, caller=None, mask=None):
    m = metadata(elfsize)
    b = kirk(payload, m, signed)
    e = bytearray(seed*9)
    for i in range(9):
        e[i*16] = i
    schedule = decrypt(e, slot)
    if caller is not None:
        schedule = xor(schedule, caller*9)
    h = bytearray(0x150)
    h[4:8] = struct.pack('<I', tag)
    h[8:24] = schedule[:16]
    if signed:
        h[0x50:0x70] = b[0x40:0x60]
    h[0x70:0x80] = bytes(range(32, 48))
    h[0x80:0xC0] = xor(encrypt(xor(b[:0x40], schedule[0x50:0x90]), slot), schedule[0x10:0x50])
    h[0xC0:0xD0] = b[0x70:0x80]
    h[0xD0:] = m
    digest = hashlib.sha1(h[4:]).digest()
    clear = h[0x70:0x80] + digest + h[0x80:0xBC]
    assert len(clear) == 96
    outer = encrypt(clear, slot)
    if caller is not None:
        outer = xor(outer, mask*6)
    d = bytearray(0x150)
    d[:0x80] = m
    d[0xB0:0xC0] = b[0x70:0x80]
    struct.pack_into('<I', d, 0xD0, tag)
    if signed:
        d[0x10C:0x12C] = b[0x40:0x60]
    d[0x140:0x150] = outer[:16]
    d[0x13C:0x140] = outer[32:36]
    if caller is None:
        d[0x12C:0x13C] = outer[16:32]
        d[0x80:0xB0] = outer[36:84]
        d[0xC0:0xD0] = outer[84:] + h[0xBC:0xC0]
    else:
        weave = outer[36:84] + outer[84:] + h[0xBC:0xC0] + outer[16:32]
        assert len(weave) == 80
        weave = xor(encrypt(weave, slot), xor(mask, caller)*5)
        d[0x80:0xB0] = weave[:48]
        d[0xC0:0xD0] = weave[48:64]
        d[0x12C:0x13C] = weave[64:]
    d += b[0x110:]
    return d, b


def main():
    curve_b = int('65D1488C0359E234ADC95BD3908014BD91A525F9', 16)
    assert (G[1]*G[1] - (G[0]**3 - 3*G[0] + curve_b)) % P == 0
    assert scale(G, TEST_D) == (int('ED9CE58234E61A53C685D64D51D0236BC3B5D4B9', 16),
                                 int('049DF1A075C0E04FB344858B61B79B69A63D2C39', 16))
    slots, keys, _ = parse(sys.argv[1])
    slots = {i: bytes.fromhex(k) for i, k in slots.items()}
    keys = {i: bytes.fromhex(k) for i, k in keys.items()}
    # A harmless synthetic ELF-shaped buffer, not executable game content.
    elf = bytearray(128)
    elf[:7] = b'\x7fELF\x01\x01\x01'
    struct.pack_into('<HHI', elf, 16, 2, 8, 1)
    elf[64:80] = b'RetroMul test!!!'
    fixtures = {'PlainElf': elf}
    for tag, name, slot, extra in ((0, 'g_key0', 0x42, False),
                                    (0x02000000, 'g_key2', 0x45, False),
                                    (0x03000000, 'g_key3', 0x46, False),
                                    (0x08000000, 'g_keyEBOOT1xx', 0x4B, False),
                                    (0xC0CB167C, 'g_keyEBOOT2xx', 0x5D, True)):
        fixtures[f'Legacy{tag:08X}'] = legacy(tag, keys[name], slots[slot], extra, elf)
    for tag in (0xD91605F0, 0xD91680F0, 0xD91681F0):
        zipped = gzip.compress(bytes(elf), mtime=0)
        data, b = modern(tag, keys[f'key_{tag:08X}'], slots[0x5D], zipped, len(elf), tag >= 0xD9168000)
        fixtures[f'Modern{tag:08X}'] = data
        if tag == 0xD91681F0:
            fixtures['SignedKirk'] = b
            fixtures['ZippedElf'] = zipped
    fixtures['GzipOversize'], _ = modern(0xD91605F0, keys['key_D91605F0'], slots[0x5D],
                                         gzip.compress(bytes(elf), mtime=0), 52)
    fixtures['GzipBroken'], _ = modern(0xD91605F0, keys['key_D91605F0'], slots[0x5D],
                                       b'\x1f\x8b' + bytes(28), len(elf))
    caller = bytes.fromhex('00112233445566778899AABBCCDDEEFF')
    fixtures['CallerKey'] = caller
    for tag in (0x2FD311F0, 0x2FD312F0, 0x2FD313F0):
        fixtures[f'Pauth{tag:08X}'], _ = modern(tag, keys[f'key_{tag:08X}'], slots[0x47],
                                             elf, len(elf), caller=caller, mask=keys['pauthXorKey'])
    fixtures['CBCZero'] = encrypt(bytes(range(64)), bytes(range(16)))
    lines = ['// Generated by crypto_fixtures.py: synthetic data only.', 'const']
    for name, data in fixtures.items():
        hx = bytes(data).hex().upper()
        chunks = [hx[i:i+96] for i in range(0, len(hx), 96)]
        lines.append('  Fixture' + name + ' =')
        lines += ["    '%s'%s" % (part, ' +' if i < len(chunks)-1 else ';') for i, part in enumerate(chunks)]
    from pascal_data import write_block
    out = Path(__file__).with_name('PSPCryptoTest.dpr')
    write_block(out, 'PSP_CRYPTO_FIXTURES', '\n'.join(lines))
    print('Generated', len(fixtures), 'synthetic fixtures:', out)


if __name__ == '__main__':
    main()
