"""PSP image survey: ISO/CSO reader, ISO9660, PARAM.SFO, ELF/PRX imports.

Usage:
  pspimg.py survey <dir> [out.json]
  pspimg.py ls <image> [path]
  pspimg.py get <image> <path> <outfile>
"""
import json
import os
import struct
import sys
import zlib


class Image:
    def __init__(self, path):
        self.path = path
        self.f = open(path, 'rb')
        head = self.f.read(24)
        self.cso = head[:4] == b'CISO'
        if self.cso:
            _, hsize, total, block, ver, align = struct.unpack('<4sIQIBB', head[:22])
            self.size = total
            self.block = block
            self.align = align
            n = (total + block - 1) // block
            self.f.seek(24)
            self.index = struct.unpack('<%dI' % (n + 1), self.f.read(4 * (n + 1)))
        else:
            self.f.seek(0, 2)
            self.size = self.f.tell()
        self.cache = {}

    def sector(self, lba):
        if not self.cso:
            self.f.seek(lba * 2048)
            return self.f.read(2048)
        b = self.cache.get(lba)
        if b is not None:
            return b
        e = self.index[lba]
        e2 = self.index[lba + 1]
        start = (e & 0x7FFFFFFF) << self.align
        end = (e2 & 0x7FFFFFFF) << self.align
        self.f.seek(start)
        data = self.f.read(end - start)
        if e & 0x80000000:
            data = data[:2048]
        else:
            data = zlib.decompress(data, -15)
        if len(self.cache) > 4096:
            self.cache.clear()
        self.cache[lba] = data
        return data

    def read(self, lba, size):
        out = bytearray()
        n = (size + 2047) // 2048
        for i in range(n):
            out += self.sector(lba + i)
        return bytes(out[:size])

    def pvd(self):
        p = self.sector(16)
        if p[1:6] != b'CD001':
            raise ValueError('not ISO9660')
        root = p[156:156 + 34]
        lba, size = struct.unpack_from('<I', root, 2)[0], struct.unpack_from('<I', root, 10)[0]
        return lba, size

    def listdir(self, lba, size):
        data = self.read(lba, size)
        out = []
        pos = 0
        while pos < len(data):
            ln = data[pos]
            if ln == 0:
                pos = (pos // 2048 + 1) * 2048
                continue
            rec = data[pos:pos + ln]
            elba = struct.unpack_from('<I', rec, 2)[0]
            esize = struct.unpack_from('<I', rec, 10)[0]
            flags = rec[25]
            nlen = rec[32]
            name = rec[33:33 + nlen]
            pos += ln
            if name in (b'\x00', b'\x01'):
                continue
            name = name.decode('latin1').split(';')[0]
            out.append((name, elba, esize, bool(flags & 2)))
        return out

    def find(self, path):
        lba, size = self.pvd()
        parts = [p for p in path.replace('\\', '/').split('/') if p]
        isdir = True
        for part in parts:
            if not isdir:
                return None
            hit = None
            for name, elba, esize, d in self.listdir(lba, size):
                if name.upper() == part.upper():
                    hit = (elba, esize, d)
                    break
            if hit is None:
                return None
            lba, size, isdir = hit
        return lba, size, isdir

    def readfile(self, path):
        r = self.find(path)
        if r is None or r[2]:
            return None
        return self.read(r[0], r[1])

    def walk(self, path='/'):
        r = self.find(path)
        if r is None:
            return
        stack = [(path.rstrip('/'), r[0], r[1])]
        while stack:
            base, lba, size = stack.pop()
            for name, elba, esize, d in self.listdir(lba, size):
                p = base + '/' + name
                if d:
                    stack.append((p, elba, esize))
                else:
                    yield p, elba, esize


def sfo(data):
    if data is None or data[:4] != b'\x00PSF':
        return {}
    _, ver, keyoff, valoff, count = struct.unpack_from('<IIIII', data, 0)
    out = {}
    for i in range(count):
        ko, fmt, ln, mx, vo = struct.unpack_from('<HHIII', data, 20 + i * 16)
        k = data[keyoff + ko:data.index(b'\x00', keyoff + ko)].decode()
        v = data[valoff + vo:valoff + vo + ln]
        if fmt == 0x404:
            out[k] = struct.unpack('<I', v[:4])[0]
        else:
            out[k] = v.rstrip(b'\x00').decode('utf8', 'replace')
    return out


def elf_imports(data):
    """Returns dict(kind, modname, imports{lib:[nids]}, exports{lib:count}) or a kind for encrypted."""
    if data is None:
        return {'kind': 'missing'}
    if data[:4] == b'~PSP':
        tag = struct.unpack_from('<I', data, 0xD0)[0]
        attr = struct.unpack_from('<H', data, 4)[0]
        comp = struct.unpack_from('<H', data, 6)[0]
        name = data[0x0A:0x0A + 28].rstrip(b'\x00').decode('latin1')
        return {'kind': '~PSP', 'tag': '%08X' % tag, 'modname': name, 'comp': comp, 'attr': attr}
    if data[:4] == b'~SCE':
        return {'kind': '~SCE+' + elf_imports(data[0x40:])['kind']}
    if data[:4] != b'\x7fELF':
        if not any(data[:4096]):
            return {'kind': 'zero'}
        return {'kind': 'unknown:' + data[:4].hex()}
    etype = struct.unpack_from('<H', data, 16)[0]
    phoff = struct.unpack_from('<I', data, 28)[0]
    shoff = struct.unpack_from('<I', data, 32)[0]
    phnum = struct.unpack_from('<H', data, 44)[0]
    shnum = struct.unpack_from('<H', data, 48)[0]
    shstrndx = struct.unpack_from('<H', data, 50)[0]
    phs = []
    for i in range(phnum):
        t, off, va, pa, fs, ms, fl, al = struct.unpack_from('<8I', data, phoff + i * 32)
        phs.append((t, off, va, pa, fs, ms))

    def v2o(va):
        for t, off, pva, pa, fs, ms in phs:
            if t == 1 and pva <= va < pva + fs:
                return off + va - pva
        return None

    mi_off = None
    if etype == 0xFFA0 and phs:
        p0 = phs[0]
        mi_off = p0[3] & 0x7FFFFFFF
    else:
        # look for section .rodata.sceModuleInfo
        if shoff and shnum and shstrndx < shnum:
            sh = [struct.unpack_from('<10I', data, shoff + i * 40) for i in range(shnum)]
            stroff = sh[shstrndx][4]
            for s in sh:
                nm = data[stroff + s[0]:data.index(b'\x00', stroff + s[0])]
                if nm == b'.rodata.sceModuleInfo':
                    mi_off = s[4]
        if mi_off is None and phs:
            p0 = phs[0]
            if p0[3] >= p0[2]:
                mi_off = v2o(p0[3])
            else:
                mi_off = p0[3]
    if mi_off is None:
        return {'kind': 'elf-nomodinfo'}
    attr = struct.unpack_from('<H', data, mi_off)[0]
    name = data[mi_off + 4:mi_off + 32].split(b'\x00')[0].decode('latin1')
    gp, ent, ent_end, stub, stub_end = struct.unpack_from('<5I', data, mi_off + 32)
    imports = {}
    exports = {}
    o = v2o(stub)
    oe = v2o(stub_end - 1)
    if o is not None and oe is not None:
        oe += 1
        while o < oe:
            libname, ver, at, entlen, varcount, funccount, nidtab, functab = struct.unpack_from('<IHHBBHII', data, o)
            ln = data[v2o(libname):data.index(b'\x00', v2o(libname))].decode('latin1') if libname else '?'
            nids = []
            no = v2o(nidtab)
            if no is not None:
                nids = ['%08X' % x for x in struct.unpack_from('<%dI' % funccount, data, no)]
            vnids = []
            if entlen >= 6 and varcount:
                vartab = struct.unpack_from('<I', data, o + 24)[0]
                vo = v2o(vartab)
                if vo is not None:
                    vnids = ['V%08X' % struct.unpack_from('<I', data, vo + 8 * k + 4)[0] for k in range(varcount)]
            imports.setdefault(ln, []).extend(nids + vnids)
            o += max(entlen, 5) * 4
    o = v2o(ent)
    oe = v2o(ent_end - 1)
    if o is not None and oe is not None:
        oe += 1
        while o < oe:
            libname, ver, at, entlen, varcount, funccount = struct.unpack_from('<IHHBBH', data, o)
            ln = '(module)'
            if libname:
                lo = v2o(libname)
                if lo is not None:
                    ln = data[lo:data.index(b'\x00', lo)].decode('latin1')
            exports[ln] = funccount + varcount
            o += max(entlen, 4) * 4
    return {'kind': 'ELF' if etype != 0xFFA0 else 'PRX', 'modname': name, 'imports': imports, 'exports': exports}


def survey_image(path):
    img = Image(path)
    res = {'file': os.path.basename(path), 'cso': img.cso, 'size': img.size}
    try:
        img.pvd()
    except Exception as e:
        res['error'] = str(e)
        return res
    p = sfo(img.readfile('/PSP_GAME/PARAM.SFO'))
    res['sfo'] = {k: p.get(k) for k in ('DISC_ID', 'TITLE', 'PSP_SYSTEM_VER', 'REGION', 'DISC_VERSION', 'PARENTAL_LEVEL') if k in p}
    res['eboot'] = elf_imports(img.readfile('/PSP_GAME/SYSDIR/EBOOT.BIN'))
    res['boot'] = elf_imports(img.readfile('/PSP_GAME/SYSDIR/BOOT.BIN'))
    mods = {}
    for fp, lba, size in img.walk('/PSP_GAME'):
        up = fp.upper()
        if up.endswith('.PRX') or ('/MODULE' in up and size < 8 * 1024 * 1024):
            head = img.read(lba, min(size, 8 * 1024 * 1024)) if size < 8 * 1024 * 1024 else img.read(lba, 4096)
            info = elf_imports(head)
            mods[fp] = info
    res['modules'] = mods
    return res


def main():
    cmd = sys.argv[1]
    if cmd == 'survey':
        root = sys.argv[2]
        out = sys.argv[3] if len(sys.argv) > 3 else None
        results = []
        for dp, dn, fn in os.walk(root):
            for f in sorted(fn):
                if f.lower().endswith(('.iso', '.cso')):
                    path = os.path.join(dp, f)
                    try:
                        r = survey_image(path)
                    except Exception as e:
                        r = {'file': f, 'error': repr(e)}
                    r['path'] = path
                    results.append(r)
                    print(r['file'], r.get('sfo', {}).get('DISC_ID'), r.get('eboot', {}).get('kind'),
                          r.get('boot', {}).get('kind'), len(r.get('modules', {})), flush=True)
        if out:
            with open(out, 'w', encoding='utf8') as fo:
                json.dump(results, fo, indent=1)
    elif cmd == 'ls':
        img = Image(sys.argv[2])
        for p, lba, size in img.walk(sys.argv[3] if len(sys.argv) > 3 else '/'):
            print('%10d %8d %s' % (size, lba, p))
    elif cmd == 'get':
        img = Image(sys.argv[2])
        data = img.readfile(sys.argv[3])
        with open(sys.argv[4], 'wb') as fo:
            fo.write(data)


if __name__ == '__main__':
    main()
