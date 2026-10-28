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

## Known gaps and provenance

- Save states are not implemented; pending callbacks and host closures are not
  serialized. In-game memory-stick saves are a separate feature.
- PGD-protected files and unsupported PRX tags can prevent game loading.
- Some VFPU functions and GE precision/timing still differ from hardware.
- Built-in font fallbacks have limited character coverage; real Japanese font
  tests require the appropriate user-supplied PGF data.
- Networking pair tests require peers and are not covered by single-console runs.

The new CPU, kernel, GE and HLE implementations were developed without consulting
PPSSPP/JPCSP code. Retained crypto units predate the rewrite and have different
provenance: see [PSP.PRX-LICENSE.md](PSP.PRX-LICENSE.md) and their source headers.
This distinction matters: the complete core is not claimed to be clean-room.
