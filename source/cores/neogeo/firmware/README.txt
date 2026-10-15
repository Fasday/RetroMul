Embedded Neo Geo system firmware

Selected source: Neo-Geo BIOS (MAME v0.254) from the user-provided page:
https://www.emu-land.net/arcade/neogeo/bios
Download: https://www.emu-land.net/arcade/neogeo/bios?act=getfile&id=17204

Only the four required system ROMs are embedded (512 KiB total):
sp-s2.sp1   131072 bytes  CRC32 9036d879  Europe MVS revision 2
sfix.sfix   131072 bytes  CRC32 c2ea0cfd  system fixed-layer graphics
sm1.sm1     131072 bytes  CRC32 94416d67  system Z80 program
000-lo.lo   131072 bytes  CRC32 5a86cff2  sprite vertical zoom table

SHA-256:
sp-s2.sp1 ae1c5cc9a0acdead8a3d5a16ee84f575582f2209677464b05a2b8b0451f658a1
sfix.sfix fcf51e688c006408be92c5adaf37d4302d05e7e681193dd0623072e53915c90e
sm1.sm1 fdc811988098d008d1aa6aed6fdc4e5c9ba034c5505ceb6808eef3af66fc95ab
000-lo.lo 2a76f023dc578804c6bcd58ed514ffc04fcb433b3bd75d4452575ffda57a0707

The BIOS and system ROMs remain copyrighted by SNK.
NeoGeo.Firmware.rc compiles with Embarcadero brcc32; its generated .res
is included by NeoGeo.Cartridge.pas. The RC uses UTF-8 without BOM because
brcc32 does not accept a BOM; Pascal source uses UTF-8 with BOM.

An optional neogeo.zip alongside a game can override these exact filenames.
No additional BIOS download is required for the built-in MVS configuration.

AES firmware added 2026-10-15 for the separate home-console platform.
Source: https://github.com/Abdess/retrobios/blob/main/bios/SNK/Neo%20Geo/aes.zip
Hashes verified against MAME src/mame/snk/neogeo.cpp AES BIOS declarations:
neo-epo.bin 131072 bytes CRC32 d27a71f1 SHA1 1b3b22092f30c4d1b2c15f04d1670eb1e9fbea07
neo-po.bin  131072 bytes CRC32 16d0c132 SHA1 4e4a440cae46f3889d20234aebd7f8d5f522e22c
Both AES images are embedded as NG_AES_BIOS_EU / NG_AES_BIOS_JP.
External firmware overrides still take precedence; missing explicit overrides
remain an error. With no override, AES can use the built-in regional BIOS.
