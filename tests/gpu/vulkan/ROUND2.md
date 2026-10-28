# Threaded GE + Vulkan + permuted EDRAM integration

Integrated `pr/psp-core` **9938cbf**, then `psp/ge` **fc49936** on `psp/gpu`.
The conflicts in `PSP.Memory` and `PSP.GE.Engine` are reconciled; the frontend
renderer setting/lifetime and inline VFPU JIT are retained.

## Coherence and addressing

* Memory keeps both the physical held-page bitmap/callback and the GE worker's
  EDRAM translation state. Mirrors 0/2 are linear; mirrors 1/3 always have nil
  page-table entries. Releasing held pages restores **only** the linear views.
* Scalar accesses and range faults test the **translated physical page**, not
  the same-numbered logical page. All supported translations keep a guest 4 KB
  page in one physical page, but may XOR its bank number. `FaultRange` walks the
  requested guest pages through that mapping, including mirror boundaries.
* `Ptr` synchronizes intersecting mapped held pages, but returns nil for a
  nonlinear view. `PageBase` likewise never exposes a nonlinear page. The GE-only
  non-consuming `HostPtr` returns nil there too. `Valid` still recognizes the
  valid VRAM window independently of whether a contiguous pointer exists.
* A translation change drains outstanding work **before** changing the mapping.
  The bitmap and translation logic are shared by scalar reads/writes, bulk
  operations, code-page lookup and the JIT's existing nil-page slow paths.
  No JIT instruction-generation changes were necessary.
* GPU states capture both the raster's depth permutation and the current memory
  translation. Depth uses the exact `PSPDepthOffset` layout; VRAM texture fetches
  handle all four CPU mirror views. Halfword/word texture reads map the starting
  address and then read contiguous physical bytes, just as the CPU does, even
  for an unaligned read crossing a 32-byte permutation boundary.
* Depth and nonlinear texture hazards/held-page footprints are enclosed in
  64 KB banks (plus the possible next bank for an unaligned multi-byte fetch).
  This is conservative: some physically independent primitives fall back to CPU
  or split passes unnecessarily, but independent GPU invocations cannot alias
  through a permutation. A changed depth mapping also splits the pass.

## Engine and reference

With a backend attached, the engine calls `Backend.DrawTriangle/DrawSprite`;
otherwise it uses `FWorkers.Triangle/Sprite`. `ReleaseBackend` is preserved and
the engine destructor frees the workers. GPU per-primitive CPU fallbacks stay
serial, after synchronizing.

The Windows row pool and the GE worker's reference arithmetic remain intact.
The GPU follows the new bounded 32-bit raster rounding and the texture floor's
Single argument conversion. CPU numerical expressions were **not** changed to
make the shader agree. Two conditional-compilation guards were narrowed to
Windows x64 because `dcclinux64` rejects inline ASM; the existing Pascal fallback
is used on other targets. No numerical operators or the Win64 SSE body changed.

The incoming pool uses Windows events and x86 floating-point controls. It is
compiled only on Windows; other targets retain serial CPU rasterization through
the same seam. A portable multi-threaded pool is not claimed or introduced here.

## Regression results

On Windows/Win64, RX 9070 XT:

* `GEWorkersCheck`: **512 primitives**, whole physical VRAM identical with **1
  and 6 threads**, now cycling all five depth permutations.
* `GERasterTest`: **16,134 primitives / 70 whole-VRAM comparisons**, exact.
  Randomized depth permutations and all four texture mirror addresses are
  covered, as are large-coordinate bilinear-floor cases. 14,888 nonempty GPU
  primitives, zero CPU fallbacks.
* New `GECoherenceTest`: **32,991 draws / 229 whole-VRAM and page-table checks /
  80 native scalar/quad VFPU copies**, exact; all draws execute on the GPU.
  It covers widths 0/512/1024/2048/4096, mirrors 1/3 and their uncached aliases,
  submitted and queued GPU work, held byte/halfword/word accesses, bulk reads and
  writes across pages/mirrors (including a range longer than 2 MiB), pointer/code-page queries, nonlinear table entries after
  release, unrelated held pages, translated shader texture fetches (including
  unaligned words), physical shader depth writes, translation changes and reset.
  Native VFPU loads from nonlinear/held views and stores to nonlinear/held
  linear views are executed, not mocked. No valid access counts as unmapped.
* Normal and synchronization validation: no errors in coherence or frontend
  lifecycle tests.
* All **113 `gpu/*` tests** have identical stdout, every screenshot and final
  2 MiB VRAM for CPU vs Vulkan with **native JIT and interpreter**. Per-batch
  check mode also reports no differences in both modes. 77 tests exercise GPU
  primitives; 36 have no GPU work (including fallback-only/control cases).
* Hardware oracle `gpu/ge/edramswizzle`: **PASS** on both CPU and Vulkan.
  Relative CPU agreement is not otherwise a claim that every GPU autotest now
  matches hardware.

Representative games, native JIT, CPU pool set to 6, one game at a time, 1,800
frames, Start/Cross from frame 500: **all 30 frame snapshots, stdout and the
entire final VRAM are identical**.

| Game | CPU (6-worker reference) | Vulkan | Whole-run speedup |
|---|---:|---:|---:|
| God of War: Chains of Olympus | 104.51 s | 33.27 s | 3.1x |
| Daxter | 31.92 s | 14.52 s | 2.2x |
| Tekken 6 | 30.94 s | 6.88 s | 4.5x |

These are host elapsed times, not steady-state FPS. The new CPU reference is
faster than the old baseline, and the new physical layout/conservative hazards
increase CPU fallback in some games (172,103 fallback primitives in GoW and
12,908 in Tekken in these runs). They must not be compared as an unchanged
workload against the earlier historical speed table.

Frontend preservation: the worker-thread settings/Reset/LoadExec/failure cleanup
regression passes with validation. Actual factory/worker Daxter frame 180 CPU
vs Vulkan PNG/hash is identical, about 60 guest FPS in both modes. The full
Windows/Win64 Release application builds and links. Linux64 and Android64
frontend/core/compute units compile, but are **not linked or run on devices**.

## Reproduce

```powershell
.\tests\cores\psp\run\build.ps1 -Project GEWorkersCheck.dpr
.\tests\cores\psp\run\bin\GEWorkersCheck_win64.exe
.\tests\gpu\vulkan\build.ps1 -Project GERasterTest.dpr
.\tests\gpu\vulkan\bin\GERasterTest_win64.exe
.\tests\gpu\vulkan\build.ps1 -Project GECoherenceTest.dpr
.\tests\gpu\vulkan\bin\GECoherenceTest_win64.exe
.\tests\cores\psp\run\build.ps1
python tests\cores\psp\run\gpudiff.py --jobs 4
$env:PSPJIT = 'off'
python tests\cores\psp\run\gpudiff.py --jobs 4
python tests\cores\psp\run\gpudiff.py --check --jobs 4
Remove-Item Env:PSPJIT
```

Remaining limits: LOD-dependent sampling still uses CPU; alias/feedback and
oversized snapshot fallbacks remain; unaligned nonlinear texture fetches near
the physical VRAM boundary use CPU too. Bank bounds can cause additional false
hazards. Win32 GPU stays disabled. Only Windows x64 on this AMD device is
runtime-qualified; non-Windows CPU pool execution remains serial. Device-loss
replay/recovery is still absent. Frontend CPU remains the default, and changing
renderer still requires worker restart. No other emulator sources were used.
