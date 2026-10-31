# PSP core

Allegrex interpreter and optional block recompiler, deterministic guest-time HLE,
software GE renderer, audio synthesis/decoding and movie playback. This is an
experimental core: observed menus and short gameplay runs do not establish
complete game compatibility.

## Execution and rendering

`PSP.Console` owns the CPU, memory, scheduler, kernel and registered services.
The master clock is in guest nanoseconds; devices and waits run on that clock.
`PSP.CPU.JIT` uses `HW.JIT`, calls interpreter handlers for uncompiled operations,
and invalidates generated blocks on code writes.

`PSP.GE.Engine` performs list interpretation and primitive setup. The software
rasterizer is the reference. The optional `PSP.GE.GPU` backend uses ordered Vulkan
compute tiles and synchronizes held VRAM pages before CPU access. Unsupported
primitives use the software path. CPU/GPU equality is verified separately from
agreement with hardware-recorded pspautotests.

On Windows the CPU renderer queues primitives in batches (`PSP.GE.Workers`) and
draws a batch on a pool while the emulator goes on (processor count minus two
threads, at most ten; `PSP_GE_THREADS=1` draws every primitive at once). Each
thread takes whole bands of rows and draws the batch's primitives in order, so
the result does not depend on the thread count. Batches outlive GE command runs:
the VRAM pages they draw into are held and the pages their textures come from
are watched (`TPSPMemory.HoldVRAM`/`WatchPage`), so any later access by the CPU,
DMA, the display or the GE itself draws the queue first. Feedback and aliasing
layouts start a new batch or are drawn alone. `tests/cores/psp/run/queuecheck.py`
compares game frames with `PSP_GE_THREADS=1`; `GEWorkersCheck` compares VRAM.
Other hosts use the serial renderer. See the combined-build results in
[`INTEGRATION.md`](../../../tests/cores/psp/run/INTEGRATION.md).

Frontend `psp.ini` settings:

```ini
[Emulation]
Execution=jit

[Video]
Renderer=cpu

[System]
Language=1
ButtonSwap=1
Nickname=RetroMul
```

`Execution=interpreter` disables the recompiler. `Renderer=vulkan` requests the
compute backend on the next worker start; CPU is the default. Missing Vulkan,
unsupported features or failed arithmetic qualification select CPU. Reset and
LoadExec retain the active renderer. Vulkan qualification and CPU-fallback cases
are documented in [`tests/gpu/vulkan/README.md`](../../../tests/gpu/vulkan/README.md).
The qualified runtime is Windows x64 on the tested AMD device; successful unit
compilation for other hosts is not runtime qualification.

## Verification

PSP sources and their generators use ordinary Pascal units/data blocks, not
textual implementation includes. Run `python tests/cores/psp/run/check_sources.py`
to check the no-`.inc` rule in the owned PSP/shader sources and tests.

From the repository root:

```powershell
.\tests\cores\psp\run\build.ps1
python tests\cores\psp\run\autotests.py --jobs 3
python tests\cores\psp\run\gpudiff.py --jobs 2
.\tests\cores\psp\jit\build.ps1
.\tests\cores\psp\jit\bin\Win64\PSPJitTest.exe 1000
```

The suite and SDK are obtained by `tests/cores/psp/run/fetch.ps1`.
`PSPRun -test` isolates host0 and memory-stick files. Optional `-hw` (or
`autotests.py --hw`) omits the emulator device so tests write their own output
and screenshots, as in the hardware recording setup. It changes the guest path;
report its results separately. Never change expected images to match a renderer.

`PSPRun -gpu-check` compares individual GPU batches against software. `gpudiff.py`
compares stdout, all screenshots and final VRAM; tests without GPU draws are
reported separately. Frame hashes alone do not verify all CPU state.

The current verified suite passes 540/638 hardware-reference tests, with identical
JIT/pool and interpreter/serial reports. See
[the asynchronous request slot report](../../../tests/cores/psp/run/ASYNC-SLOT.md),
[the interrupt-termination/current-directory report](../../../tests/cores/psp/run/INTR-CWD.md),
[the synchronous-write report](../../../tests/cores/psp/run/SYNC-WRITES.md),
[the explicit removable-card condition](../../../tests/cores/psp/run/MEMSTICK.md),
[the timing/handoff report](../../../tests/cores/psp/run/TIMING-HANDOFF.md),
[the async IO report](../../../tests/cores/psp/run/ASYNC-IO.md) and
[profile distinctions](../../../tests/cores/psp/run/ACCURACY-FOLLOWUP.md).

## Known gaps and provenance

- New save states use only the separately validated direct memory/object-graph
  format. Persistent HLE callbacks are explicit actions; controller history is
  not recorded or replayed. Older reconstruction states remain importable.
  Loading remains cancellable; filesystem capture is still bounded to 48 MiB.
  Host pointers and closures are never dumped. See
  [continuation verification and limitations](../../../tests/cores/psp/run/CONTINUATIONS.md).
  In-game memory-stick saves remain a separate feature.
- PGD-protected files and unsupported PRX tags can prevent game loading.
- Some VFPU functions and GE precision/timing still differ from hardware.
- Built-in fonts cover Latin-1 and fullwidth Latin, not complete Japanese or
  Cyrillic typefaces. Optional read-only PGFs can be selected in PSP settings
  (`System/FontDirectory`) or with `PSPRun -fontdir`.
- Networking pair tests require peers and are not covered by single-console runs.

The former PRX/AES implementation has now also been replaced. The current
decoder implements AES/CBC/CMAC, PRX reconstruction and KIRK ECDSA verification,
using the user's saved documentation and published key data; it also implements
the Pauth service used by Monster Hunter Portable 3rd. See
[PSP.Crypto.md](PSP.Crypto.md) for sources, validation, supported formats and
limitations, and [PSP.PRX-LICENSE.md](PSP.PRX-LICENSE.md) for reference notices.
This is independently authored code based on published reverse engineering,
not a claim of a formally separated legal clean-room process.
