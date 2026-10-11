Neo Geo MVS / CD cores

Load named MAME ZIP sets or unencrypted NeoSD .neo images. Keep split-set
parents in the same directory. The current and legacy catalogs select ROM
wiring by set name and CRC, including older filenames with matching CRCs.
Unknown and protected variants without an implemented board are rejected
with a specific loading error; ZIP filenames alone do not guarantee support.

Implemented: Motorola 68000, Z80 with NMI sound commands, YM2610 FM/SSG and
ADPCM-A/B, planar sprites/FIX, shrink tables, animation, palette banks,
interrupts, watchdog, uPD4990 calendar, battery RAM and complete snapshots.
Protection: PRO-CT0 (Fatal Fury 2), KOF98, Metal Slug X, CMC42/50, SMA,
PCM2 and PVC for the catalogued original cartridge families. Bootleg boards:
CTHD2003/SP/SA, Garou, KOF2002/2003 derivatives, KOF10th/KF10THEP/KF2K5UNI,
SVC Bootleg/Plus/Super Plus, KOG, Lansquenet 2004, Samurai Shodown V Bootleg,
Matrimelee Bootleg, Metal Slug 3b6 and Metal Slug 5 Plus. Separate JAMMA PCB
wiring/decryption is supported for SVC, Metal Slug 5 and KOF2003. Metal Slug 5
PCB can reuse identical program chips from sibling mslug5.zip by CRC. Decrypted
clone chips can share still-encrypted parent chips; parent chains are bounded.
Jockey GP and V-Liner include persistent cartridge NVRAM. Irritating Maze
uses its own BIOS and trackball counters; mahjong controllers use a key matrix.

The host framebuffer stays black during the MVS BIOS memory tests.
The filter follows FIX-map initialization and cartridge graphics selection;
BIOS error messages and menus remain visible. CPU/VRAM/audio keep running
normally, with no startup timing shortcut or snapshot format change.

Video: 320 x 224; master clock 24 MHz; 1536 clocks x 264 lines per frame
(about 59.1856 Hz). Host audio is stereo 44100 Hz.
Default controls: arrows, Z/X/C/V = A/B/C/D, Enter = Start, 5 = Coin.
Second player: keypad 8/5/4/6, 1/2/3/Decimal, keypad 0, 6 = Coin.
Bindings are configurable in Neo Geo settings. Both ports work independently.
Irritating Maze: arrows move the trackball; Z/X operate its two buttons.
Mahjong (Bakatono, Minasan, Janshin): A-N select tiles, O = Pon, P = Chi,
Q = Kan, R = Ron, S = Reach, Enter = Start, 5 = Coin.
V-Liner: F1 = operator key, F2 = clear key, 5 = coin.

MVS limits: linked cabinets/MCUs, physical analog paddle input,
and unlisted protection boards are not implemented. Paddle games use
their joystick mode. Memory card hardware is absent. The built-in BIOS runs in
MVS arcade mode, including when loading compatible AES cartridge dumps.
Neo Pong 1.0/1.1 use a permissive sprite-rendering compatibility profile:
their backgrounds exceed the physical 96-sprite line limit and otherwise
hide the foreground. Other games retain the physical limit. Sprite ROM
address lines mirror at the next power of two; unpopulated holes stay blank.
Audio is a functional synthesis implementation, not a cycle-exact analog
model. Full gameplay compatibility is not implied by a successful boot test.

The shared Z80 state has two new latches. Mega Drive snapshot format is
therefore version 5; earlier version 4 snapshots require the previous build.
Battery saves are unaffected.

Reference algorithms are documented in the source; CHD licenses are in
../../chd/LICENSE.txt. Firmware: firmware/README.txt.
Development probes and checks are under codex-work/neo-geo and codex-work/tests.

Neo Geo CD / CDZ (experimental)

Select ISO (2048-byte Mode 1), CUE (MODE1/2048 or MODE1/2352 with BINARY or
44100 Hz stereo 16-bit PCM WAV audio), or CHD. Keep CUE companions in the same
directory. Compressed audio CUE tracks, parent/differential CHDs and CD ZIP
archives are not supported; unpack ZIPs and open their CUE. A paired data ISO
is hidden from the library when a CUE of the same name exists.

Place a 512 KiB CD or CDZ BIOS named neocd.bin beside the disc image or in
ROMS/neogeocd. top-sp1.bin, front-sp1.bin and neocd_t/f/z.rom are also accepted.
The BIOS is external; MVS firmware cannot boot CD games. Byte-swapped chip
and big-endian dumps are accepted. The default machine region is Europe.

The CD core uses the shared 68000/Z80/YM2610/video implementation, 2 MiB
program RAM, 4 MiB sprite RAM, 128 KiB FIX RAM, 64 KiB sound RAM, 1 MiB PCM RAM,
LC8951 sector decoding, vectored CD interrupts and memory/DMA upload modes.
CDDA mixes with YM2610 output. Master clock: 24.168 MHz, about 59.60 frames/s.
Data runs at 75 sectors/s (CD) or 150 sectors/s (CDZ). Backups are 8 KiB;
mutable memory, drive registers and CDDA sample position are saved in states.
CD saves use the neogeocd namespace and do not overwrite MVS saves.

Both controllers use Neo Geo settings: A/B/C/D, Start and Select (default 5
for player 1, 6 for player 2). Select does not insert an arcade coin.

BIOS boot and deterministic snapshots were checked with NeoThunder, Neo3D,
240p Test Suite, Double Dragon, Fatal Fury 3, Metal Slug, Metal Slug 2,
Neo-Geo CD Special, Rally Chase and Xeno Crisis. Metal Slug and Xeno Crisis
reached playable scenes. These checks do not establish complete gameplay compatibility.

CHD uses the native Delphi library in source/chd with a one-hunk cache
and reads through IStorage,
including Android SAF. Discs are hashed for state identity before startup;
large BIN/CHD sets can take several seconds to open. Limits: 99 tracks,
800 MiB per source file, 2 GiB CHD logical size, 100-minute TOC. CUE indexes
above 01/subchannel dumps are not emulated. CDZ protection indexes are
synthesized for standard images; unusual protection can remain incompatible.

Development fixtures, build logs and probes: codex-work/neogeocd and
codex-work/tests/NeoGeoCDTests.dpr. Hardware behavior was checked against
MAME neogeocd and NeoCD (https://github.com/libretro/neocd_libretro); their
BIOS, timing and controller implementations were used as reference.
