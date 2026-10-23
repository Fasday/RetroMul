# SEGA Dreamcast (experimental)

This native Delphi core models the Dreamcast console: the SH-4 CPU, Holly
(system bus, interrupts and DMA), the PowerVR2 tile accelerator and renderer,
the GD-ROM drive, the AICA sound processor with its ARM7DI, and the Maple bus
with controllers, Visual Memory units and jump packs.

Open a `.gdi`, `.cdi`, `.chd`, `.cue`, `.iso` or `.mds` image, or a homebrew
`.elf` program, from the `dc` folder of the library. `.gdi` and `.cdi` are always
Dreamcast discs; `.cue`, `.iso`, `.chd` and `.mds` are recognised by the
`SEGA SEGAKATANA` hardware identifier in their boot track. Archives are not
supported for disc images.

## Boot

No firmware is required. The built-in high-level boot loads IP.BIN and the
boot program from the disc (descrambling it on CD media) and provides the
system calls programs use: system information, ROM font, flash ROM, GD-ROM
and the menu call. In Dreamcast settings:

- `Built-in (high-level)` always uses it.
- `Automatic` also loads `dc_boot.bin` (and `dc_flash.bin`) when found in
  settings, beside the image or in the `dc` ROM folder; the high-level boot
  then returns the boot ROM's font glyphs.
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
  palettes, mipmaps, bilinear filtering) on worker threads, overlapped with
  the emulated CPU. Results do not depend on the thread count.
- AICA: the shared sound generator and DSP (also used by the DSF player) with
  the ARM7DI, timers, shared interrupt registers, the RTC and CD-DA mixing.
- Snapshots contain the full machine, decoded TA contexts and VMU contents.

Not implemented: the MMU address translation used by Windows CE games, the
modem and broadband adapter, bump mapping, NAOMI/Atomiswave.

## References

Marcus Comstedt's Dreamcast pages (Maple, VMU, GD-ROM, IP.BIN, system calls,
scrambling), the Hitachi SH-4 software manual, SingleStepTests/sh4 (MIT),
KallistiOS examples and headers as usage references, ATA/ATAPI-4 for the
packet protocol, and public PowerVR2/Holly/AICA register descriptions. Code
from GPL emulators was not used.
