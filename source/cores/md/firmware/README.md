# Embedded Sega firmware

These are Sega firmware data images executed by the native emulated CPUs.
They are compiled by `../MD.Firmware.rc` into `../MD.Firmware.res` as RCDATA.
The images total 527,616 bytes (515.25 KiB). No separate BIOS installation or
runtime network download is needed. `MD.Firmware` validates the resource size
and SHA-1 before returning bytes.

| File | Firmware | Bytes | SHA-1 | Download source |
|---|---|---:|---|---|
| `32x-g.bin` | 32X 68000 | 256 | `dbebd76a448447cb6e524ac3cb0fd19fc065d944` | [Emu-Land](https://www.emu-land.net/consoles/32x/bios?act=getfile&id=5012) |
| `32x-m.bin` | 32X master SH-2 | 2048 | `1e5b0b2441a4979b6966d942b20cc76c413b8c5e` | [Emu-Land](https://www.emu-land.net/consoles/32x/bios?act=getfile&id=5013) |
| `32x-s.bin` | 32X slave SH-2 | 1024 | `4103668c1bbd66c5e24558e73d4f3f92061a109a` | [Emu-Land](https://www.emu-land.net/consoles/32x/bios?act=getfile&id=5014) |
| `cd-e.bin` | Mega CD 1, Europe v1.00 | 131072 | `f891e0ea651e2232af0c5c4cb46a0cae2ee8f356` | [Emu-Land](https://www.emu-land.net/consoles/segacd/bios?act=getfile&id=4969) |
| `cd-j.bin` | Mega CD 1, Japan v1.01 | 131072 | `4846f448160059a7da0215a5df12ca160f26dd69` | [Emu-Land](https://www.emu-land.net/consoles/segacd/bios?act=getfile&id=4971) |
| `cd-u.bin` | Sega CD 1, USA v1.10 | 131072 | `f4f315adcef9b8feb0364c21ab7f0eaf5457f3ed` | [Emu-Land](https://www.emu-land.net/consoles/segacd/bios?act=getfile&id=4977) |
| `cd-u2.bin` | Sega CD 2, USA v2.11 | 131072 | `328a3228c29fba244b9db2055adc1ec4f7a87e6b` | [Emu-Land](https://www.emu-land.net/consoles/segacd/bios?act=getfile&id=4980) |

Default CD firmware is Model 1 for the disc's U/E/J region. `cd_u2` is also
embedded for Model 2 compatibility testing. 32X loads all three processor BIOSes.

Rebuild the resource by running `brcc32 MD.Firmware.rc` from the parent directory.
The RC paths refer only to this source directory. `manifest.json` records SHA-256
as well. Retrieved from Emu-Land on 2026-10-14 at the user's request; the BIOS
copyright belongs to Sega.
