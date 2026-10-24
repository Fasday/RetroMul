# SEGA Dreamcast (experimental)

This native Delphi core models the Dreamcast console: the SH-4 CPU, Holly
(system bus, interrupts and DMA), the PowerVR2 tile accelerator and renderer,
the GD-ROM drive, the AICA sound processor with its ARM7DI, and the Maple bus
with controllers, Visual Memory units and jump packs.

Open a `.gdi`, `.cdi`, `.chd`, `.cue`, `.iso`, `.mds` or `.nrg` image, an
`.m3u` playlist of them, or a homebrew `.elf` program, from the `dc` folder of
the library. `.gdi` and `.cdi` are always Dreamcast discs; `.cue`, `.iso`,
`.chd`, `.mds` and `.nrg` are recognised by the `SEGA SEGAKATANA` hardware
identifier in their boot track. A playlist in the `dc` folder, or one that lists
`.gdi`/`.cdi` images, opens here. The library shows a GDI, CUE or playlist
once, without its track files or discs. Archives are not supported for disc
images.

## Disc change

The core implements the frontend's disc control (as the PlayStation core
does): the discs of a playlist, or the started image plus any opened later,
can be changed or ejected while running. A change opens the drive lid, keeps it
open for a second of machine time and closes it on the new disc; RAM, VMUs and
the system flash stay. Games notice the lid through the drive status and check
the new disc with the boot ROM's check-disc call, which reads its IP.BIN
header. Snapshots taken with the lid open resume the change.

## Boot

No firmware is required. The built-in high-level boot loads IP.BIN and the
boot program from the disc (descrambling it on CD media) and provides the
system calls programs use: system information, ROM font, flash ROM, GD-ROM
and the menu call. In Dreamcast settings:

- `Built-in (high-level)` always uses it.
- `Automatic` also loads `dc_boot.bin` (and `dc_flash.bin`) when found in
  settings, beside the image or in the `dc` ROM folder; the high-level boot
  then returns the boot ROM's font glyphs. Without it the font area holds the
  12x24 ISO 8859-1 glyphs drawn from the public domain Hershey Simplex
  strokes; full-width (Japanese) glyphs stay blank.
- `Boot ROM file` starts the console from `dc_boot.bin`. Without a disc it
  shows the system menu; the GD-ROM drive does not provide the authentication
  data a boot ROM checks, so discs start through the high-level boot only.

The system flash (region, language, broadcast standard and saved settings) is
generated for the selected region unless a 128 KiB flash file is given, and is
saved per console as `saves/dc/dc_flash.bin`.

## Controls and peripherals

Each of the four ports holds a controller with a VMU, a controller alone, or
nothing; `Automatic` connects controllers to all ports and a VMU to port A.
The analog stick uses host axes or four bindable directions; the L and R
triggers are the logical Select and Mode buttons and report analog travel from
host triggers. A jump pack occupies port A's second slot when rumble is on.
VMU contents are saved as `saves/dc/vmu_A1.bin` and so on. The VMU screen is
drawn by the frontend in a corner of the game display (Dreamcast settings);
it is not part of frames, screenshots or frame hashes.

## Implementation notes

- SH-4: block interpreter with code-page invalidation, linked blocks and
  table-dispatched operations; FPU, exceptions, store queues, OCRAM, UTLB
  scaffolding, INTC, TMU, DMAC, SCIF, BSC and RTC. SingleStepTests/sh4 pass
  except TRAPA (treated as a no-op by the test generator) and two double NaN
  payload cases.
- PowerVR2: the tile accelerator decodes display lists into contexts; the
  software renderer draws opaque, punch-through and translucent lists
  (per-pixel sorting), modifier volumes, fog, textures (twiddled, strided, VQ,
  palettes, mipmaps, bilinear filtering, bump maps) on worker threads,
  overlapped with the emulated CPU. Results do not depend on the thread count.
- Wait loops (a short loop that only polls memory, possibly counting down a
  timeout) are recognised after two identical iterations and run ahead to the
  next scheduler event with exactly the state the iterations would leave.
- AICA: the shared sound generator and DSP (also used by the DSF player) with
  the ARM7DI, timers, shared interrupt registers and the RTC; CD-DA enters
  through the EXT inputs (DSP EXTS0/1, EFSDL/EFPAN slots 16 and 17).
  arm7wrestler DC passes.
- Snapshots contain the full machine, decoded TA contexts and VMU contents.

Not implemented: the MMU address translation used by Windows CE games, the
modem and broadband adapter, NAOMI/Atomiswave, and the GD-ROM authentication
a real boot ROM requires.

## References

Marcus Comstedt's Dreamcast pages (Maple, VMU, GD-ROM, IP.BIN, system calls,
scrambling), the Hitachi SH-4 software manual, SingleStepTests/sh4 (MIT),
KallistiOS examples and headers as usage references, ATA/ATAPI-4 for the
packet protocol, public PowerVR2/Holly/AICA register descriptions, the
240p Test Suite and arm7wrestler DC as test programs, and the Hershey fonts
(public domain). Code from GPL emulators was not used.
