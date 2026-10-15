# SEGA Saturn: native console, CD and sound

This native Delphi core provides the console, shared SH7604 model, SCU/SMPC,
VDP1/VDP2, CD Block, MC68EC000/SCSP, both DSPs and digital/analog pads.
Retail European 1.00 and Japanese 1.00/1.01 BIOSes boot into the system menu.
The real BIOS reads disc sectors and starts the game's initial program; there
is no host-side replacement for the boot ROM or game program.

Open an unpacked 512 KiB BIOS `.bin`, `.rom` or `.bios` in RetroMul or
RetromulTerm. BIOS reset vectors identify the platform independently of the
filename. Select the console region and PAL timing in Saturn settings before
starting the core. To open a game, select its `.cue`, `.iso` or `.chd`.
The program embeds the Japanese 1.00/1.01 and common USA/Europe BIOSes.
With no external override, Japan/Asia NTSC uses Japanese 1.01 and other
regions use `mpr-17933.bin`. No separate BIOS download is required.
To override this choice, configure `Hardware/BIOS` in Saturn settings, or put
`saturn_bios.bin` beside the image. `bios.bin`, `sega_101.bin` and
`mpr-17933.bin` are also recognized as companion BIOS filenames. An explicit
setting has priority over companion files; companion files have priority over
the automatic built-in default. `builtin:sega_100.bin`, `builtin:sega_101.bin`
and `builtin:mpr-17933.bin` explicitly select a resource and bypass companion
lookup. Resource loading validates size and SHA-256; a bad explicit override
raises an error instead of silently changing the firmware.
Region must match the game's supported area;
Japan is 1, North America is 4 and Europe is 12. Select a 1 or 4 MiB RAM
cartridge in Saturn settings for games requiring expanded memory.
See `firmware/README.md` and `firmware/manifest.json` for the embedded images.

The adapter uses the existing worker, storage, input ports and snapshot
interfaces. Keyboard defaults are arrows, Z/X/C for A/B/C, A/S/D for X/Y/Z,
Enter for Start, Shift for L and Tab for R. The shared logical input fields
Select and Mode carry L and R, respectively. Both controller ports are
independent; a port configured as `none` returns a disconnected device.
Each port can use a six-socket multitap, giving twelve controllers. Players
1/2 address the first socket on ports 1/2; additional sockets use players
3–7 on the first enabled tap and 8–12 on the second. Select `Analog 3D pad`
to use continuous host axes and L/R triggers. Direction/shoulder bindings also
provide digital fallbacks. Both SMPC INTBACK packets and direct serial polling
carry the selected device protocol.

## Implemented foundation

- Two SH-2 instruction interpreters through `HW.SH7604`, independent caches,
  FRT/input capture, two-channel DMAC, timed DIVU, watchdog interval operation,
  bus control registers and read-only master/slave mode pin.
- BIOS, independent low/high work RAM, address mirrors, backup RAM odd-byte
  lanes, sound memory, device registers and MINIT/SINIT capture signals.
- Event scheduling interleaves CPU instructions, DMA, raster events and SMPC
  commands. Bus delays are nominal; they are not a transistor-level bus model.
- SCU interrupt priorities/vectors, acknowledgement, timers and direct/indirect
  DMA with level-2 priority and B-bus word transfers.
- SMPC timed commands, RTC/SETTIME, region, slave start/stop, clock commands,
  frozen INTBACK packets/continuation and direct serial polling for digital
  pads, 3D analog pads and two six-socket multitaps.
- VDP1 command flow, clipping/local coordinates, sprites, scaled/distorted
  sprites, polygons, lines, mesh, RGB color calculations, Gouraud colors,
  erase/change and separate draw/display framebuffers.
- VDP2 normal tile/bitmap planes, palette modes, transparency, priorities,
  line scroll/zoom, basic rectangular windows, color offsets/blending and
  rotation parameter A for RBG0. PAL/NTSC raster status and basic video mode
  dimensions are exposed.
- CD Block models the host-visible firmware protocol: command/periodic replies,
  HIRQ/mask, TOC/session/sub-Q, image authentication, 1x/2x sector delivery,
  200-sector shared buffer, 24 filters/partitions, FIFO get/put/delete,
  copy/move through filters, FAD search and ISO9660 directory/file operations.
  The generic native media layer supports BIN/CUE, ISO and CHD, including
  raw Mode 2 tracks. Fixed-source SH-2/SCU DMA reads the actual CD FIFO.
- MC68EC000 reuses RetroMul's instruction engine. SCSP synthesizes 32 PCM8/16
  slots at 44.1 kHz, interpolation, four loop modes, envelopes/key scaling,
  LFO, noise, sound-stack modulation, send levels/panning, external CD-DA,
  timers/interrupts and sound RAM/register DMA. The worker submits stereo
  PCM through the existing audio output and honors pause, reset and volume.
- SCSP DSP executes 128 microsteps with coefficients, TEMP/MEMS/MIXS,
  effects/external registers, fixed/floating sound-memory transfers and ring
  addressing. SCU DSP executes operation/immediate/jump/loop/end instructions,
  48-bit ALU and multiplier, four data banks, delayed branches, DMA and ENDI.
- VDP2 additionally supports rotation parameter B, RBG1, 16/32-bit coefficient
  tables in VRAM/CRAM, parameter selection, signed parameter fields,
  vertical cell scroll, line windows, line color and additive color calculation.
- Native 1/4 MiB expansion RAM, bank mirrors and cartridge IDs 5A/5C;
  read-only 1/2/4 MiB ROM cartridges; odd-byte 512 KiB/1/2/4 MiB backup
  cartridges (IDs 21–24). Backup cartridges persist separately from internal
  backup RAM and share one save per capacity across games.
- SH7604 accesses stall while DIVU is busy, as required by the hardware manual.
  SMPC reports sound/CD reset signals, controls CD power and applies the
  boot ROM clock-change reset contract to video/SCU/SCSP while retaining CD
  and work RAM.
- Backup RAM persistence and snapshots of CPUs, devices, pending operations,
  memory and framebuffers, CD buffers/FIFO, audio voices and DSP operations.
  Snapshots check BIOS/disc identity and RAM cartridge type. The stage-3 state
  format is versioned; pre-stage-5 snapshots must be recreated. ROM cartridge,
  CD backend, firmware and protection settings are checked. Host callbacks
  and UI objects are not serialized.

## CD backend and protection

`Hardware/CDBackend=model` selects the native host-command model.
`Hardware/CDBackend=sh1` selects the experimental original-firmware backend:
native SH7034 execution, independent on-chip RAM/timers/SCI/DMAC, bridge
registers/FIFO, 512 KiB DRAM and the drive mechanism serial link. The embedded
CDB-106 ROM passes its DRAM/FIFO self-test, handles host commands, builds TOC
from serial lead-in records and receives actual sectors through DACK DMA.
This does not establish working commercial-game boot through SH-1; that
backend remains experimental and the command model remains the default.

`Hardware/OpticalProtection=false` disables the physical-media requirement.
The command model accepts Saturn-header images asynchronously. The SH-1
mechanism supplies a synthetic decoded alternating-bit ring, seek reports
and EDC; original CDB-106 code executes E0/E1 and validates it. No result is
written into SH-1 RAM by the host. Original firmware returns 4 for this model
and 3 for missing or deliberately corrupted ring data.
With protection enabled, sector images cannot authenticate and the command
model restricts data to the sixteen boot sectors, including filesystem access.
No physical-ring capture or hardware trace is available. RF/EFM/servo decoding
and validation against genuine captured media remain unsupported/unverified;
the synthetic model is an explicit bypass, not proof of a genuine disc.

## Timing and rendering checks

DMA uses separate read/write bus reservations with progress and completion
interrupts; SCSP register DMA advances by word. CD seek has a separate
distance-dependent completion deadline and can be cancelled by initialization.
Raster scheduling separates the active-area end, HSync and line boundary,
including 320/352 clocks and alternating interlace fields. These are nominal
bus/mechanical timings, not captured hardware calibration.

Envelope progression uses sample-clock steps, key-scaled rates, nonlinear
attack, decay thresholds, hold, loop-linked attack and release. VDP2 handles
all sixteen normal-shadow sprite formats, MSB shadow, sprite-window AND/OR,
sprite color calculation conditions and coefficient line-color selection
through A/B rotation modes and VRAM/CRAM tables. VDP1 uses edge-line quad
filling, signed coordinates, source end codes, Gouraud line corrections,
documented repeated polyline endpoint calculations, MSB-on preservation,
packed interlace rows and 8/16-bit erase boundaries.

## Remaining work

Original-firmware drive/host transfers now boot Virtua Cop 2; other commercial
games still need native-backend validation. Full 64 KiB transfers across sector
boundaries are checked through SCU DMA, SH7604 DMA and guest SH-2 PIO.
Physical RF/EFM security-ring input/decoding, optional MPEG/NetLink hardware and
complete SH7034/SH7604/BSC peripheral behavior remain incomplete. SCU indirect
descriptor reads and DSP DMA do not yet share every normal DMA bus phase.
Native host FIFO underflow suspends a pending DMA read until the SH-1 arms
the next sector. Synchronous CPU reads charge the local bridge advance to
the issuing CPU bus wait, bounded at 4096 SH-1 clocks. Detailed host wait-state
timing remains nominal.
VDP1 renders each command atomically and schedules its completion from nominal
work cost; this is not a per-pixel pipeline. Rotated framebuffers and all
hardware-specific edge/dropout cases are not fully validated. Sound envelope
rates and mechanical seek times need real-hardware traces for calibration.
Logical diagnostics cover the listed shadow/window/line-color/interlace rules;
they do not prove exhaustive pixel-accurate agreement with physical hardware.
Commercial compatibility is uneven: reaching a logo or title does not establish
correct gameplay. See the current measurements in `codex-work/saturn-stage5/REPORT.md`.

## Checks

`codex-work/tests/RunSaturn.ps1` builds and runs the hardware/device/adapter suites on
Win32 and Win64 with compiler overflow/range checking enabled. `-BIOS` adds
retail BIOS probes using all three embedded resources. The probe writes actual emulated frames and checks
complete-state replay after restoring a BIOS snapshot. The same probe accepts
`builtin:mpr-17933.bin`, `builtin:sega_100.bin` or `builtin:sega_101.bin` in
place of a BIOS path. Adapter tests load all three resources, check independent
SHA-1 hashes, boot without external files for Japan/USA/Europe and verify both
external and explicit built-in overrides.

`SaturnStage34Tests.dpr` verifies CD sectors/filters/FIFO/DMA/ISO9660/CD-DA,
both RAM cartridge sizes, guest DIVU stalls, DSP arithmetic/delay slots/DMA,
PCM8/16/panning/effects, video coefficients/windows, SMPC resets and replay.
`SaturnGameProbe.dpr` reads actual user-supplied discs, writes frames/audio,
applies controller input and compares complete state after snapshot restore.
`SaturnStage5Tests.dpr` checks the new cartridge/peripheral protocols, original
SH-1 firmware/ISA/TOC/DACK DMA, pending-operation replay, timing, protection,
envelopes and manually specified pixel results. `SaturnInputTests.dpr` covers
the twelve-player frontend, continuous axes/triggers and source filtering.

`SaturnSettingsLayoutTests.dpr` checks the Saturn settings at 360, 560, 1200
and 1600 pixels, including search and control layout. All working materials
and generated binaries remain under `codex-work`.

## Primary references

- [Hitachi SH7604 hardware manual](https://antime.kapsi.fi/sega/files/sh7604.pdf)
- [Hitachi SH7032/7034 hardware manual](https://bitsavers.trailing-edge.com/components/hitachi/superH/1994_SH7032_7034_SuperH_RISC_Engine_Hardware_Manual.pdf)
- [Sega SCU manual](https://antime.kapsi.fi/sega/files/ST-097-R5-072694.pdf)
- [Sega SMPC manual](https://antime.kapsi.fi/sega/files/ST-169-R1-072694.pdf)
- [Sega VDP1 manual](https://antime.kapsi.fi/sega/files/ST-013-R3-061694.pdf)
- [Sega VDP2 manual](https://antime.kapsi.fi/sega/files/ST-058-R2-060194.pdf)
- [CD communication interface](https://antime.kapsi.fi/sega/files/ST-162-062094.pdf)
- [Sega SCSP manual](https://antime.kapsi.fi/sega/files/ST-077-R2-052594.pdf)
- [Sega disc format standard](https://antime.kapsi.fi/sega/files/ST-040-R4-051795.pdf)
- [Sega extended RAM cartridge bulletin](https://antime.kapsi.fi/sega/files/ST-TECH-47.pdf)

Protocol/instruction details were cross-checked against
[Yabause sources](https://github.com/Yabause/yabause),
[Ymir sources](https://github.com/ymir-emu/Ymir) and
[analysis of the original CD firmware](https://github.com/user-none/erings/tree/main/docs/cdblock).
These are supplementary evidence; neither emulator compatibility nor its bugs
define this core's behavior. Yamaha envelope/LFO tables and floating-sample
conversion conventions reuse RetroMul's native AICA work.

Cache/FRT/DMAC algorithms reuse RetroMul's existing `MD.Mars` work. The LRU
primitive is shared with 32X without changing its snapshot layout. No external
emulator binary or DLL is linked into this implementation.
