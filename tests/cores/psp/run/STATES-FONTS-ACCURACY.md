# PSP: states, fonts and DMA

## Save states

The PSP adapter now implements quick/named states, the snapshot directory API,
previews and the frontend's save/load commands. `IEmulationSnapshotOperation`
adds optional nonblocking commands, progress and cancellation. The snapshot
controller polls on its own timer, including while the emulation is paused.
Other cores retain their existing synchronous interface; exit autosaves remain
synchronous.

These are **reconstruction states**, not instantaneous RAM dumps. The payload
contains the initial mounted host data, boot settings and run-length encoded
controller inputs. Loading builds a separate console and replays the history.
Consequently kernel objects, waits, timers, callback/guest-return frames, open
files, GE operations and media decoder histories are recreated through their
ordinary code paths. No host addresses, functions, native decoder objects or
audio/GPU handles are serialized.

Before accepting the replacement, SHA-256 checks the complete RAM, VRAM,
scratchpad, CPU context and scheduler time/deadlines/remainder. Both raster
queues are synchronized before inspecting VRAM. The common snapshot envelope
also checks the payload checksum and executable identity; the PSP payload
additionally checks the full mounted image hash. The current console remains
alive during reconstruction. Cancellation, invalid input or a reconstruction
hash mismatch discards only the candidate.
Serialized collection/byte lengths are explicitly 32-bit, not NativeInt.

Replay uses uniquely created temporary directories, not the live memory stick.
It does not replay writes/deletes against normal savedata. After a successful
load, subsequent guest file changes are mirrored to the original live paths.
Those destinations come from the active session, never from paths in a snapshot.
Repeated load/save and Reset retain the proper live destinations. Open-file
paths are canonical and follow guest renames, rather than changing meaning
when the guest changes its working directory. The worker reattaches the renderer, clears host
audio buffering and restarts pacing/frame-rate measurement after an operation.

### Intentional limits

- Loading time grows with the played history. There is no fast direct-state
  format yet; a long session can take a long time to reconstruct. The UI stays
  responsive and the operation can be cancelled.
- The initial host folders are bounded to 48 MiB and 20,000 entries. Symlinks
  are refused. Exceeding a capture limit does not stop gameplay, but saving a
  state reports the capture error. Payloads also bound input runs/duration.
- State files embed initial memory-stick/flash/host/font data, **not** the game
  image. They can contain private savedata and proprietary font data; do not
  publish them as repository fixtures.
- External edits to mounted data during play are not a supported input stream.
  A replay mismatch is an error, never a reason to patch RAM or ignore the hash.
- Mirroring a changed file currently copies its contents. Heavy install/cache
  workloads after loading have not been qualified for performance.
- Ordinary utility savedata still uses the existing local representation. This
  work does not implement authentic PSP secure-save interchange.

## Fonts

`System/FontDirectory` is an optional, read-only directory containing the user's
PGFs. It is exposed by the PSP settings folder picker and by `PSPRun -fontdir`.
Fonts are not bundled or committed. The configured PGF is tried before the
existing flash0/builtin alternatives.

The independent builtin font now includes fullwidth Latin U+FF01–U+FF5E and
ideographic space U+3000, with fullwidth advances. MHP3rd's main menu uses these
characters: New Game / Continue / Options / Download / Media Install are visible
both with PGFs and with the fallback. This is not a claim that the fallback
contains a complete Japanese/Cyrillic typeface.

PGF streamed glyph-cache allocations exclude the normal record's eight-byte
fixed header (six for shadow records), without losing its metric bytes. The
supplied `jpn0.pgf` parses as 9,778 glyphs; Latin, Cyrillic and hiragana glyphs
contain valid pixels and advances. `font/fonttest` with that PGF matches the
recorded metrics, bitmap and cache allocation size 71. Its raw `Font_Free`
addresses still differ by 0x20. They have not been offset or normalized away.
Some supplied Latin PGFs are a different firmware version: e.g. `ltn0.pgf` is
69,108 rather than the recording's 67,660 bytes. Their sizes are not forged.

## Hardware accuracy

DMA now distinguishes `sceDmacTryMemcpy` from the blocking operation. Transfers
of 272 bytes or more release the calling thread; concurrent TryMemcpy reports
`80000021`. Transfers share a completion timeline and write their destination
before waking the caller. The scheduling/error/order cases in the real-PSP
`dmac/dmactest` recording pass. Transfer latency remains an approximation, not
a hardware-calibrated bus model.

The final default-font suite is **534 PASS / 104 FAIL / 638 total**, with no
crashes/timeouts. JIT/pool and interpreter/serial reports are byte-identical.
Compared with `autotests_region.txt`, no previous PASS was lost. The additional
PASS cases are:

- `dmac/dmactest`
- `gpu/clipping/homogeneous`, `gpu/clipping/xycull`
- `gpu/commands/blend`, `gpu/commands/blend565`
- `gpu/rendertarget/copy`, `gpu/texfunc/add`

These GPU tests also use DMA (`homogeneous` makes 92 sceDmacMemcpy calls).
Neither the hardware recordings nor the test normalization was changed.
Audio blocking timing and other outstanding hardware discrepancies remain.

## Verification

- `PSPStateTest` in checked Win64: MHP3rd at frame 1100 with supplied PGFs and a
  Vulkan source console; mid-replay cancellation; fresh-console restoration;
  second-generation state; 90 subsequent frames matching full memory/CPU/audio;
  preservation of newer live savedata while loading; guest writes after repeated
  load; checksum-corruption rejection. The state is approximately 2.46 MB.
- Checked reconstruction/continuation cases: font/fonttest, font/newlib,
  audio/blocking/channels, utility/savedata/autosave, io/file/rename and
  threads/callbacks/create. Checked Win32 DMA and a frame-zero state also pass.
- Separate-process MHP3rd save/load at frame 1100 with embedded PGFs reproduces
  the full-memory/CPU/audio digest
  `3ccc1e4cadf4e909baa62230df1361a14f608c87cafe5995c2747bea25739f4f`.
  A Win64 audio state also loads unchanged in a fresh Win64 process, checked
  Win32, and Win64 interpreter/serial mode. `PSPStateTest image --save path N`
  and `image --load path` expose these file-only process tests.
- `PSPWorkerSnapshotTest`: save/load while paused, nonblocking status polling,
  frame publication, cancellation, resumption and worker teardown. CPU and Vulkan
  worker paths are exercised.
- The final 22,500-frame scripted MHP3rd new-character/save/movie/village/movement
  run completes, with final hash `6d921293cb415022` matching the qualified REGION
  baseline. Its guest cycle count is now 26,432.1M after DMA scheduling changes.
- GPU differential: **71 SAME / 42 NO_DRAWS** normally; **81 SAME / 32 NO_DRAWS**
  with `--check`; no differences, across 113 cases in each run.
- Region/scissor regression: all 320 full-VRAM cases pass on Win64 serial,
  pool and Vulkan.
- Win64 Release GUI and terminal applications build. Core units compile for Win32, Linux64,
  Android32 and Android64; this is not a claim of runtime testing on Linux/Android.

Local full reports: `autotests_states_jit.txt`,
`autotests_states_interpreter.txt`, `gpudiff_states.txt`,
`gpudiff_states_check.txt` (generated/ignored, like previous suite reports).

## Shared integration changes

- `source/cores/psp/PSP.Console.pas`: optional font directory, reconstruction
  orchestration, per-console system settings, file-change hooks and validation.
- `source/cores/psp/PSP.Service.pas`: optional read-only font directory.
- `source/cores/psp/PSP.IO.pas`: host-mutation notifications and canonical/renamed
  open paths.
- `source/cores/psp/PSP.Scheduler.pas`: read-only clock remainder for validation.
- `source/cores/psp/PSP.GE.Engine.pas`: explicit CPU/backend synchronization.
- `source/runtime/Core.Emulation.Types.pas`, `Core.Emulation.pas`: optional
  snapshot-operation interface and its alias; existing interfaces are unchanged.
- `source/platforms/psp/Core.Platforms.PSP.Adapter.pas`: worker commands, lifecycle integration,
  snapshot namespace and optional font configuration.
- `apps/retromul/controllers/RM.Controllers.Snapshots.pas`: optional asynchronous
  UI path with its own polling timer; existing synchronous cores keep working.
- Both GUI and terminal `.dpr`/`.dproj` files register the new PSP.State unit.
