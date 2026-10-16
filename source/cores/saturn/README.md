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
  erase/change and separate draw/display framebuffers. Automatic drawing starts
  only on framebuffer exchange; manual hold retains draw progress and CEF.
  Normal erase follows scanout one row at a time, using erase parameters latched
  at exchange. Rotation-mode erase runs during the following V-blank. Pending
  erase progress is serialized, including the latched area and fill color.
  Rotation-8 uses its documented 512x512 layout, and VDP2 reads rotated
  framebuffers using parameter A TV coordinates/increments.
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
  format is versioned; outer Saturn snapshots are now version 5, with raw device
  payload v9. Frontend v2..v4 and diagnostic raw v4..v8 remain importable; absent
  rotation/UART/DMA latches are initialized on import. ROM cartridge,
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
interrupts; indirect SCU descriptors fetch their three words through bus
arbitration/readiness phases and preserve partially fetched state in snapshots.
Unaligned SCU source/destination bytes are legal, including halfword-aligned
SGL command uploads. SCSP register DMA advances by word. CD seek has a separate
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

## Compatibility corrections (2026-10-15)

VDP2 window controls now select the area to process: that area becomes transparent,
selects rotation parameter B, or inhibits color calculation. Disabled window inputs
obey OR/AND truth tables. Base, line and vertical-cell scrolling retain their
fractional bits until the summed coordinate is truncated; line offsets add to the
base scroll and mosaic suppresses vertical-cell scroll. Negative coefficient
indices wrap on the VRAM address pins, and coefficient mode 3 replaces Xp while
retaining the scaled screen coordinate. Rotation screen-over processing now uses
the designated one-word over-pattern outside cell maps and clips bitmap modes 2/3
to their documented bounds.

SCU DSP DMA forwards its updated RA0/WA0 at issue, so completion cannot overwrite
an address prepared by subsequent DSP instructions. This fixes the observed Sonic R
code/stack corruption and BIOS restart. VDP1 framebuffer exchange now occurs after
vertical blank, allowing the blanking handler to observe CEF before it becomes BEF.
Manual erase is deferred to the field boundary, targets the display buffer and is
consumed once; manual change preserves both buffers. INTBACK continuation recognizes
both CONT transitions, retains its toggle level, keeps SF busy between status and
peripheral phases, and omits ports configured for zero-byte mode.

Rotation coefficients now follow RAMCTL bank roles: per-line coefficients ignore
DKAx, while per-dot VRAM reads require a coefficient bank; unsplit banks inherit
the first half's role. CRAM coefficients permit per-dot reads. Xst/Yst/KAst retain
line accumulators, RPRCTL reloads each selected accumulator once, and a new field
forces a reload. This removes the vertical stripes from the Sonic R control scene.
SCU external inputs share IMS bit 15; reserved upper IMS bits no longer suppress
individual external vectors.

The modem cartridge is absent by default, allowing NetLink editions to launch
their ordinary offline game. `CD.NetlinkPresent` optionally enables a bounded
offline UART/AT stub: byte scratch/configuration registers,
divisor latches, receive FIFO, local loopback and external interrupt 12. Setup AT
commands return OK; dial/answer return NO CARRIER and never establish a connection.
The stub is synchronous and does not model baud rate, modem DSP, sockets or network
transport. Cartridge presence is retained through reset and saved in v9 states;
v6..v8 imports retain the formerly always-present modem.

NiGHTS reaches a rendered gameplay scene, Shining Force III reaches dialogue, and
Sonic R reaches a rendered race/Pause scene. Street Fighter Zero 3 now reaches
a rendered fight with its HUD and stage after the video reset/type-5 fixes.
Daytona and Rally reach races, and Bomberman reaches its title and stage demo.
These observations do not establish full commercial compatibility. See
`codex-work/saturn-fixes-20261016c/REPORT.md` for the latest evidence;
`codex-work/saturn-reference-20261015/REPORT.md` records the earlier findings.

## Remaining work

Original-firmware drive/host transfers now boot Virtua Cop 2; other commercial
games still need native-backend validation. Full 64 KiB transfers across sector
boundaries are checked through SCU DMA, SH7604 DMA and guest SH-2 PIO.
Physical RF/EFM security-ring input/decoding, optional MPEG hardware, a complete NetLink modem and
complete SH7034/SH7604/BSC peripheral behavior remain incomplete. SCU DSP DMA does not yet share every normal DMA bus phase.
Native host FIFO underflow suspends a pending DMA read until the SH-1 arms
the next sector. Synchronous CPU reads charge the local bridge advance to
the issuing CPU bus wait, bounded at 4096 SH-1 clocks. Detailed host wait-state
timing remains nominal.
VDP1 renders each command atomically and schedules its completion from nominal
work cost; this is not a per-pixel pipeline. Rotated framebuffer address/coordinate
logic has diagnostic coverage, but hardware-specific rounding, edge/dropout
cases and erase/change timing still need physical-hardware validation. Sound envelope
rates and mechanical seek times need real-hardware traces for calibration.
Logical diagnostics cover the listed shadow/window/line-color/interlace rules;
they do not prove exhaustive pixel-accurate agreement with physical hardware.
Commercial compatibility is uneven: reaching a logo or title does not establish
correct gameplay. See the current measurements in
`codex-work/saturn-completion-20261015/REPORT.md` and the preceding
`codex-work/saturn-stage5/REPORT.md`.

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
envelopes and manually specified pixel results. `SaturnCompletionTests.dpr` additionally checks 544 unaligned DMA
copies, chained/blocked descriptor fetches with 131 snapshot replay points,
manual framebuffer hold/CEF, rotated framebuffer addressing/512x512 layout,
and sign-extended host/SH-1 bridge writes. `SaturnReadinessTests.dpr` checks
256 window controls, fractional scroll carries, asynchronous DSP address writes,
field-boundary CEF/BEF, deferred display-buffer erase, INTBACK CONT transitions,
zero-byte ports, negative coefficient indices, coefficient mode 3 and cell/bitmap
screen-over processing, coefficient-bank roles, one-shot rotation accumulators,
offline UART/AT/loopback/FIFO/IRQ state and all sixteen external interrupt vectors.
On-chip IRQ cache invalidation is checked for FRT/TIER, external priority, NMI and
snapshot restore. Exact field periods are checked for NTSC/PAL, both master-clock
modes and progressive/single-density/double-density interlace.
`SaturnInputTests.dpr` covers
the twelve-player frontend, continuous axes/triggers and source filtering.

`SaturnSettingsLayoutTests.dpr` checks the Saturn settings at 360, 560, 1200
and 1600 pixels, including search and control layout. All working materials
and generated binaries remain under `codex-work`.

## Performance

The complete local disc boot audit (15 CHD images, 3600 fields per cold start)
is recorded in `codex-work/saturn-boot-audit-20261015/REPORT.md`. SMPC now aborts
unfinished peripheral INTBACK/CONT exchanges at VBlank-in, releasing SF without
discarding OREG or generating an extra interrupt. This fixes the SEGA-logo stall
in Guardian Heroes and the black-screen stall in Virtua Cop 2. Keyed SH7604 WDT
writes now use the driven bus width, and disabling WDT cancels unread overflow.
This releases the shared NetLink loader's asynchronous file queue. CD file-info
responses now return the XA file number, or zero without XA system information,
instead of the directory index. This prevents the subsequent BIOS file-number
filter from discarding every Mode-1 sector. Daytona C.C.E. Net Link Edition,
Sega Rally Netlink and Saturn Bomberman now launch their offline games.
SCU DMA now latches its active address increments/mode independently of the next
register setup, retains EN, queues immediate GO while busy, and permits CPU/B-bus
uploads to A-bus cartridge DRAM. This fixes SFZ3's corrupt CD packet and loading
stall. Clock changes retain external video DRAM/CRAM, framebuffer contents and
VDP1 erase/local state. Sprite type 5 uses the documented three priority bits and
one color-calculation bit. These remove the observed SFZ3 corruption and trails.
VBE is sampled at the first V-blank H-blank, and V-blank OUT precedes the buffer
exchange, so guest handlers can request the immediately upcoming frame. This
removes Daytona's alternating loss of the road and cars. Updated checks and
game probes are in codex-work/saturn-fixes-20261016c/REPORT.md.
Passing snapshot replay is
not equivalent to successful game boot or complete compatibility.

`codex-work/tests/SaturnFrameBench.dpr` measures core RunFrame time without UI,
audio-device output, frame-file writes or bus/instruction observers in the timed
region. The latest benchmark script uses 120 warm-up fields, 360 measured fields, fixed main-thread CPU affinity and
reports mean/median/p95; frame and complete-state SHA-256 hashes verify the same
emulated result before and after optimization. The separate static VDP2 pass is
a renderer diagnostic, not an additional amount to add to RunFrame time.

Rotation matrices, coefficient-bank selection and framebuffer increments are
decoded once per line rather than once per pixel, following the per-line setup
used by Ymir/Mednafen. SH7604 register accesses have fixed-width paths, the FRT's
power-of-two divider uses exact shifts/masks, and interrupt arbitration is cached
until its inputs change. The cache is rebuilt after snapshot load. No instruction,
DMA phase or raster event is skipped for speed.
Unnecessary CPU-state copies are omitted when tracing and IRQ checks do not need
them. Detailed results and reproducible commands are in
`codex-work/saturn-reference-20261015/performance/REPORT.md`.

RunFrame stops at the VDP2 field event; frontend pacing uses the guest clocks
actually emulated for each field. Existing master-clock rates, CPU instruction
interleave and DMA phases are retained.

The frontend enables threaded VDP2 rendering on multicore hosts. Writes to video
memory/registers, reset, buffer exchange, snapshots and frame completion synchronize
the pending line. RPRCTL and rotation accumulators latch on the emulation thread
at the raster event, before CPU execution resumes. Standalone rendering can still
latch synchronously. Derived rendering/thread metadata is not serialized.

SH7604 timer deadlines defer counter work until an event or observable access;
large FRT gaps use exact compare/overflow arithmetic. Instruction fetch reuses
its selected cache line with tag/purge/load invalidation. SCU DMA and modeled CD
deadlines avoid idle scans and repeated unchanged IRQ notifications. VDP2 caches
per-line windows/planes and uses packed blending. VDP1 prepares shading gradients,
uses neutral/opaque fast paths and native erase-row fills. Scheduling and display
fields are separated to reduce cache-line contention between host threads.
CD directory-record padding is initialized to keep raw snapshots deterministic;
the scanout erase change introduced raw v7/outer v3. The active DMA controls and
queued GO extended these to raw v8/outer v4. Optional modem presence extends them
to raw v9/outer v5. Raw v4..v8 and outer v2..v4 are imported; legacy active DMA
controls are initialized from the old register setup. Restart games from BIOS
when checking compatibility fixes: an old snapshot can retain earlier guest RAM
corruption or initialization that already failed.

VDP1 quad interpolation carries signed integer remainders between dots, preserving
truncation toward zero without per-dot division. VDP2 horizontal counters are
calculated when read or saved. SH7604 reports actual external IRQ acceptance, so
an on-chip interrupt with the same stack effect/vector cannot acknowledge SCU.
These derived events and caches do not change the snapshot payload. Packed
on-chip register access, an idle-DMAC shortcut, inlined DSP arithmetic and cached
instruction-byte/LRU pointers reduce core overhead without skipping guest events.
The latest controlled Virtua Cop 2 benchmark is 22.4666 ms mean, 27.5969 ms median
and 29.2396 ms p95 over 360 fields after 120 warm-up fields. The 16.7 ms target
remains unmet. Each speed change has a matching pixel/full-state comparison;
corrected blank-out IRQ timing intentionally changes the guest CPU state.

With the user's authorization, validated/masked hardware paths use local Q-/R-
and native memory operations. Access-size/alignment and pixel-buffer guards,
time checks and snapshot validation remain; VDP1 clip/local coordinates are checked
on load. Four million opcode comparisons, frozen renderer comparisons and
serial/threaded game-state checks validate the optimizations.

The controlled benchmark uses 120 warm-up and 360 measured fields. The selected
Sonic R scene approaches the NTSC budget; NiGHTS and Shining Force III still exceed
it. These paused/dialogue probes do not establish real-time gameplay or complete
commercial compatibility. Full results and reproduction commands are in
`codex-work/saturn-core-speed-20261015/REPORT.md`.

## Latest verification: 2026-10-16, pass E

SFZ3's beach NBG1 now loads the correct blue sky and clouds. The stage palette
was correctly prepared in guest RAM, but cached SH-2 instructions continued
during SCU CPU-bus DMA and overwrote the next palette-upload setup. Pass E used
a whole-transfer CPU hold. The Rally correction below replaces that hold with
transaction-level bus ownership and permits cache execution. Descriptor and
payload buses are tracked separately; timers, sound and raster clocks continue.
Ownership is derived again after snapshot loading without changing its format.
This follows the bus-arbitration behavior checked against the SCU manual,
Beetle and Ymir sources, and uses RetroMul's native components.

Earlier corrections to fixed-source WRAM DMA, VDP1 texture end markers/HSS/EOS,
VDP2 byte CRAM accesses and physical palette-bank preservation remain in place.
Common SH-2 instructions now decode only their required registers and operands.
Byte TCSR reads use a direct path that preserves read-before-clear flags.
The broader experimental decoder was rejected after inconclusive timings.

The pass-E measurements, before the audio correction below, use an Intel
Core Ultra 9 285K, 120 warm-up and
360 measured active gameplay fields, CPU-0 affinity and threaded VDP2:

| Scene | Mean ms | Median ms | p95 ms |
|---|---:|---:|---:|
| Daytona C.C.E. Net Link | 20.3939 | 26.8537 | 28.4426 |
| Rally Plus Netlink | 18.7765 | 23.7077 | 25.3391 |
| Bomberman | 9.9185 | 9.8395 | 11.2862 |
| SFZ3 legacy scene | 18.1341 | 17.3475 | 20.7859 |
| SFZ3 with reloaded clouds | 17.2917 | 16.7847 | 18.9410 |

The 16.7 ms target remains unmet for Daytona, Rally and SFZ3. Bomberman meets it
in this saved scene. Final framebuffer and complete-state hashes match the
pre-TCSR optimization for all five measurements. SCU arbitration itself can
intentionally change guest execution and should not be presented as a
decoder-only performance comparison.

The correct sky was verified by reloading the arena from a BIOS-booted pre-stage
menu fixture. Old in-fight snapshots retain palette data damaged before the fix;
reload the stage or restart the game to initialize it with the corrected core.

Final Win32/Win64 validation contains 210 PASS results, including cached CPU-bus
holds, A-to-B execution, descriptor transitions, DMA priorities, forced stop,
complete mid-transfer replay, exhaustive SH-1/SH-2 arithmetic, timer/cache/IRQ/DMA,
DSP, texture/CRAM and independent composition/rotation comparisons. Four
600-field gameplay probes and complete five-field snapshot replay also pass.
GUI and terminal build on both architectures without build diagnostics.
Evidence, exact reproduction and remaining limits are in
`codex-work/saturn-fixes-20261016e/REPORT.md`.

## Audio follow-up: 2026-10-16

Daytona's clock-change field publishes 1438 stereo PCM frames, exceeding the
1024-frame audio backend limit. The worker now submits consecutive bounded
blocks and preserves all samples instead of disabling output after
`Invalid audio sample count`.

SCSP DSP COEF values are signed Q1.12 in register bits 15..3. The previous
executor used the low 13 bits, corrupting effect/filter gain and sign. Correct
decoding restores audible startup sound in the Daytona boot instead of the
observed 22050-Hz oscillation. The existing +0.5 test coefficient was corrected
from 0800 to the hardware register value 4000.

The latest validation has 214 PASS results across Win32/Win64, including analytic
coefficient cases and a real audio-worker regression with a 1097-frame burst.
The cold Daytona worker passes 1800 fields with audio enabled; a separate
600-field gameplay run passes complete five-field snapshot replay. GUI and
terminal builds succeed on both architectures without compiler diagnostics.
Recordings, limits and reproduction are in
`codex-work/saturn-audio-20261016/REPORT.md`.

## Playback stability: 2026-10-16

Daytona's racing workload can produce PCM more slowly than the output device
consumes it. The host audio path now uses a short preroll, device-clock pacing
and native stereo waveform-similarity overlap/add to adapt duration while
preserving pitch. Startup work and limiter sleep do not determine the sustained
rate estimate. Pause, mute, reset and snapshots clear the host staging/tail.
Windows supports optional paused preroll; other PCM clients retain their
existing immediate-playback behavior. Core/device state and native PCM are
unchanged. Buffer lead plus algorithm lookahead is around 100 ms.

Real Windows playback-position diagnostics show 102 empty checkpoints in the
900-field baseline and zero in the final 1500-field run, with no dropped backend
frames. The final suite has 234 PASS results on Win32/Win64; real-device
pause/mute/snapshot/reset checks and GUI/terminal builds also pass. The core
still misses the 16.7 ms budget in the racing scene: smooth output does not
establish full-speed gameplay. Evidence, recordings, reproduction and limits:
`codex-work/saturn-audio-pacing-20261016/REPORT.md`.

## Diagonal polygon coverage: 2026-10-16

VDP1 distorted sprites and polygons now use integer edge stepping and copy the
current texel/shade into diagonal corner pixels, as specified by Sega's VDP1
manual, Fig. 1.6. This closes pixel dropouts on Daytona's road and car seams.
The native mesh checkerboard remains enabled. Texture/end-code stepping is
unchanged; coverage writes do not consume extra texels.

A closed-form coverage oracle checks 1796 textured/untextured, mesh/opaque,
all-octant and irregular-quad cases per architecture, plus a varying-texel
copy test. The previous rasterizer fails the new tests. The complete Win32/
Win64 suite has 252 PASS results. Four 600-field gameplay probes (Daytona,
Rally, Bomberman and SFZ3 with restored clouds) pass complete-state replay.
GUI/terminal builds pass on both architectures. Daytona still exceeds the
16.7 ms field budget. Comparisons, timing and limits are recorded in
`codex-work/saturn-textures-20261016/REPORT.md`.

## Resident Evil core optimization: 2026-10-16

Cached SH-1/SH-2 instructions now use live opcode bytes outside the host
address-exception frame where safe. Selected aligned cache-hit loads share
SH7604's existing native cache view; misses, stores, peripherals and unaligned
accesses retain the checked bus path. TCSR read/clear latches, IRQ/delay-slot
semantics, wait cycles, cache invalidation and snapshot layout are preserved.
VDP2 decodes normal unit-zoom background dots in eight-pixel spans, hoists
scanline constants and reads non-rotated VDP1 rows through a validated view.
The scanline worker uses an atomic completion predicate and bounded polling.
Scheduler arithmetic removes redundant checks only within validated bounds.

On Resident Evil USA, 1200-field hall runs average 16.63-16.79 ms versus
18.85 ms before (about 11.4% faster). Dining-room repeats average 13.40-13.46 ms
versus 14.64 ms; the FMV sample improves from 19.79 to 17.89 ms. Hall P95 is
still about 22.1 ms, so a consistent 16.7 ms deadline remains unfulfilled.
These are native-core timings with PCM generation, excluding GUI/host stretch.

The checked Win32/Win64 suite has 326 PASS results. Seven 600-field comparisons
match every video field, native PCM byte and complete final state: Resident
Evil hall/dining-room/FMV, Daytona, Rally, Bomberman and SFZ3 with restored
clouds. Native Resident Evil snapshot replay and all GUI/terminal builds pass.
Real WinMM 1500-field final checks for Resident Evil and Daytona have zero
empty checkpoints, dropped samples or audio errors. Initial comparison runs
did show rare empty checkpoints, documented with the timing limitations in
`codex-work/saturn-speed-20261016h/REPORT.md`. The host audio path and previous
VDP1 coverage/NBG1 fixes are unchanged. Measurements and source hashes are in
that folder's `verification-summary.json`.

## Cache and scheduler follow-up: 2026-10-16

SH7604 now retains a derived data-cache selection per hardware index. SH2 can
select existing instruction-cache tags directly, while misses retain the
original bus reads/waits. Cached issue avoids the checked execution wrapper
where the instruction cannot fault; additional pure ALU/system/branch cases
use this path. Cache fills/stores preserve their big-endian bytes with word
operations. The board scheduler uses a trusted monotonic AdvanceForward path;
public device Advance calls retain backward-time checks, including the SCU
DSP check. Guest instruction counts, device update order and snapshots match.

On the final Resident Evil USA build, repeated 1200-field hall means are
14.08-14.21 ms and P95 is 19.46-19.69 ms. The dining-room sample is 10.69 ms
(P95 13.74 ms, 0/600 fields above 16.7 ms); FMV is 14.48 ms (P95 15.50 ms,
3/600 above budget). Nearly half the hall fields still exceed 16.7 ms, so the
consistent deadline remains open. These are native-core timings with PCM
generation, excluding host stretch/GUI presentation. The existing VDP2 worker
helps: 14.14 ms threaded mean versus 15.72 ms with serial video in the same
hall. SH2s retain timestamp-ordered execution; no new audio thread was added.

The final checked Win32/Win64 suite has 398 PASS results. Seven real-image
600-field comparisons preserve every video field, native PCM byte and full
final state, including SFZ3 clouds and Daytona coverage. Native Resident Evil
snapshot replay passes. Final 1500-field real WinMM runs for Resident Evil and
Daytona show zero empty checkpoints, dropped samples or audio errors. All four
GUI/terminal builds pass. Host audio behavior and VDP1/VDP2 pixel algorithms
are unchanged. Detailed timing, references, source hashes and limits:
`codex-work/saturn-speed-20261016i/REPORT.md` and `verification-summary.json`.

## Sega Rally framebuffer recovery: 2026-10-16

Cached instruction execution can continue while SCU DMA owns the external CPU
bus; misses, write-through stores and interrupt entry wait. CPU-bus bursts retain
ownership between their read and write phases so that SH-2 cannot reuse a source
buffer while it is being copied. A/B transfers independently leave the CPU bus
available, except while fetching a descriptor from CPU memory.
Cache-only operand lookup consults hardware tags when
derived hints are absent after state loading. Cached stack restores and RTE
retain their instruction cycles and delay-slot behavior.

The former scheduler also stopped cache execution, and SCU B-bus writes were
charged two clocks per halfword. SCU burst writes now use one B-bus clock per
halfword; SH-2 DMA and B-bus reads retain their previous latency. Both source
integrity and upload timing are needed: releasing the CPU bus between words
corrupted car-selection models, whereas the overly long transfer delayed the
V-blank handler until a queued framebuffer change was replaced by manual erase.
The user's menu and race saves now render complete models and the world.
Old snapshots remain importable. Raster algorithms and guest clocks are
unchanged. Arbitration is nominal, not a pin-level timing model. The final
source-integrity and car-selection checks are in
`codex-work/saturn-rally-cars-20261016/REPORT.txt`.

## Sega Rally streaming flicker: 2026-10-16

SCU bursts accessing VDP1 VRAM or the draw framebuffer now suspend VDP1 command
execution until the host burst releases that memory. This follows the host-over-
drawing priority in VDP1 manual section 2.1. CPU-bus ownership remains a separate
decision: cached SH-2 execution can still continue. The scheduler visits DMA
phase boundaries, and shifts the pending VDP1 drawing slot during contention
instead of executing overdue commands together when the burst ends. Existing
snapshot fields preserve this delay without changing the state format.

The moving race autosave exposed VDP1 traversing partially uploaded links:
59 consecutive draw lists executed 902 duplicate command addresses. With burst
arbitration the same interval executes each command once, and the distant world
no longer loses large groups of polygons between frames. The regression test
uploads a replacement list while drawing starts, checks the resulting sprite,
and restores the complete machine midway through contention on all DMA levels.
Captures, diagnostic controls and checks are in
`codex-work/saturn-rally-flicker-20261016/REPORT.txt`.

## Burning Rangers first scene: 2026-10-17

SCU DMA reads from high work RAM now use burst latency instead of charging
the SH-2's non-burst read latency for every word. A 48 KiB command upload used
to consume almost the entire V-blank interval. The V-blank-in handler returned
after V-blank-out, so the game's drawing-end handler missed the transition
from its intermediate black-polygon pass to the normal scene. Audio and game
logic continued while VDP2 retained the previous image.

The user's autosave now advances through the scene into the control tutorial
over 1800 fields, with full-machine snapshot replay passing. CPU-bus ownership
and VDP1 command-upload arbitration remain in effect. No guest patches or game
identification checks are used. The phase timing remains nominal: three clocks
per high-RAM-to-VDP longword, compared with Sega's measured approximately 2.2
clocks, rather than the former five. See Sega's
[general programming FAQ](https://docs.exodusemulator.com/Archives/SSDDV25/segahtml/faq/prog/p07_10.htm).
Regression sources, scene captures, validation and builds are in
`codex-work/saturn-burning-20261016`.

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
[Ymir sources](https://github.com/ymir-emu/Ymir),
[Mednafen/Beetle sources](https://github.com/libretro/beetle-saturn-libretro/tree/master/mednafen/ss) and
[analysis of the original CD firmware](https://github.com/user-none/erings/tree/main/docs/cdblock).
These are supplementary evidence; neither emulator compatibility nor its bugs
define this core's behavior. Yamaha envelope/LFO tables and floating-sample
conversion conventions reuse RetroMul's native AICA work.

Cache/FRT/DMAC algorithms reuse RetroMul's existing `MD.Mars` work. The LRU
primitive is shared with 32X without changing its snapshot layout. No external
emulator binary or DLL is linked into this implementation.
