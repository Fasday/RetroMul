# Vulkan GE speed round

Branch `psp/gpu`, after fast-forwarding to `pr/psp-core` **8f60810** (CPU batch
queue, watched pages, `PixelProcsExtra`, `TGETexLevel.Fits`; no conflicts).

The Vulkan renderer was slower than the CPU renderer in Tekken 6 battle
(frontend ~23 vs ~58 fps). Causes, as measured, and what changed:

| Cause (before) | Change |
|---|---|
| 69,823 Tekken primitives on the CPU, "colour and depth share memory": depth and permuted-texture spans were rounded to 64 KB banks | Rounded to the permutation's own block (`PSPDepthOffset`): 2 KB untranslated, else `1 shl (shift + 4)`, as `PSP.GE.Workers` does. Tekken: **30** (real overlaps; the CPU queue also draws those 30 alone) |
| Every CPU-drawn primitive and every `Release` with 2048+ primitives submitted and read back; 85,070 batches in 4200 frames | Batches outlive GE runs: `Release` submits (no readback) when the batch has 256+ primitives and the GPU has finished the previous one; held pages are read back only by `Sync` (an access, a CPU-drawn primitive) |
| A full 2 MB `CompareMem` against the shadow per submission (13-20% of the emulator thread) | A page is compared once per epoch (until the next `Sync`) when a batch first uses it; from then on it is held or watched, so guest memory cannot change it |
| VRAM texture pages held: any CPU *read* forced a `Sync`; texture pages read back | VRAM textures are **watched** (`TPSPMemory.WatchPage`, all four mirrors, whole 64 KB banks in the odd ones): only writes synchronize; only drawn pages are read back |
| Textures in RAM compared with guest memory per primitive | Snapshot once per batch and watched; the copy stays valid without comparison |
| `Place`: pass reads appended per primitive (quadratic), all overlap checks per primitive | Primitives inside the pass's box, buffers and a texture it already reads take a fast path; read spans are deduplicated; holds happen when the box grows |
| GoW: 167,257 primitives on the CPU, "texture from the pixels drawn" (bloom downsampling within one buffer; a 2x downsample of the frame buffer whose 512x512 level spans the target) | Render targets and unswizzled textures are tracked by their **rows**; sprites and triangles use the **texels they can sample** (corner or vertex S/T, two texels of margin for rounding and bilinear neighbours, plus 1 per 65536). GoW: **1** primitive on the CPU |
| `CompareMem` for raster state/CLUT per primitive | 32-byte-at-a-time comparison (`SameBytes`) |

Correctness of the narrower tracking rests on: 16- and 32-bit native stores at
aligned addresses and byte texture reads in the kernel (byte-disjoint spans
cannot race), triangles sampling convex combinations of `S/Q` when all `Q`
and `W` are positive (`GEDrawTriangle`), and sprites' coordinates being linear
across the box when unprojected (`GEDrawSprite`). Anything else (projected
sprites, non-positive `Q`/`W`, swizzled/DXT levels, odd mirrors, coordinates
beyond 2^20 or NaN) keeps the whole level.

## Measured speed

RX 9070 XT, Win64. The machine was shared with other workers' emulators
(up to ~9 busy cores during some runs); CPU and Vulkan runs were interleaved and
repeated. Both renderers produce identical frame hashes in every run.

Frontend (`PSPAdapterRun`, sound-paced, the frontend caps at 60 fps):

| Run | CPU renderer | Vulkan |
|---|---:|---:|
| Tekken 6 battle `-mash -from 52`, before this round | 58.8 | **23.1** |
| Tekken 6 battle `-mash -from 52`, quiet machine | 59.1 | 59.9 |
| Tekken 6 battle `-mash -from 52`, loaded machine (7 runs) | 57.6, 58.5, 30.6, 55.0, 58.7, 46.2, 47.4 | 57.6, 55.9, 59.9, 59.9, 52.1, 59.9, 59.9 |
| God of War `-mash -from 52` (2 runs) | 59.9, 59.9 | 59.9, 60.0 |
| God of War `-mash -from 8` (whole run) | 50.4 | **59.9** |
| Tekken 6 `-mash -from 8` (whole run) | 57.6 | 58.0 |

(In GoW the CPU renderer reached guest frame ~2,100 by 52 s, Vulkan ~3,090.)

Headless `PSPRun`, Start/Cross every 60 frames from frame 500, seconds:

| Run | CPU renderer (10-thread pool) | Vulkan |
|---|---:|---:|
| Tekken 6, 4200 frames, before this round | 58.96 | **152.35** |
| Tekken 6, 4200 frames, quiet machine | 58.96 | 27.26, 27.90, 28.29, 28.50 |
| Tekken 6, 4200 frames, loaded machine | 61.80, 51.46 | 33.14, 41.51 |
| God of War, 2400 frames, quiet machine | 41.40 | 18.33 |
| God of War, 2400 frames, loaded machine | 42.26, 46.18 | 17.23, 18.11 |

Tekken 6 Vulkan stats (4200 frames): 85,070 -> ~23,000 batches; waiting for
the GPU 29.3 s -> 1.6-1.9 s; 3,364 synchronizations (all by access: once per
frame or so, the same count as the CPU queue's "synchronized by access").
The emulator thread is now dominated by the GE's vertex processing
(`ClipPosition`, `Add24`, `Light`, `DecodeVertex`) and JIT code; the backend's
own code (`SameBytes`, `DrawTriangle`, `Place`, submissions) is a few percent.

`PSP_GPU_RELEASE` overrides the 256-primitive release threshold for measurements
(16/64/256/1024 measured; 256 best within noise).

## Exactness evidence (final commit)

* `gpudiff.py`, all 113 `gpu/*` tests, native JIT and `PSPJIT=off`, plus
  `--check` in both: **78 SAME / 35 NO_DRAWS**, no differences (one more test,
  `gpu/clipping/guardband`, now draws on the GPU).
* `gpudiff.py --games`, Tekken 6 / God of War / Daxter, 1,800 frames: SAME
  (30 frame snapshots + final VRAM each); Tekken 6 and God of War at 4,200
  frames (Tekken battle included): SAME (70 snapshots + final VRAM).
* `GERasterTest`: **40,134 primitives / 761 whole-VRAM compares**, exact. New:
  textures interleaved with colour/depth rows in all layouts and mirrors,
  sprites/triangles sampling a window of their own buffer (random positive Q,
  W). Mutations narrowing row overlap tests or footprint margins are caught.
* `GECoherenceTest` (with synchronization validation): **63,981 draws / 354
  VRAM+page-table checks / 105 native VFPU copies**. New: several submissions
  per epoch read back once, textures drawn by earlier submissions, watched VRAM
  textures read without synchronizing and written through every mirror,
  `WriteBytes`, a linear alias, a JIT store and `Ptr`; watched RAM textures
  likewise, with the batch's copy reused afterwards. Removing either watch
  makes it fail.
* `GEWorkersCheck`, renderer lifecycle (validation), frontend Daxter frame 180
  CPU vs Vulkan: pass / identical. Linux64 and Android64 compile.

A harness fix found by the final-VRAM comparison: `PSPRun` saved VRAM in CPU mode
without draining the new CPU queue (Daxter's last batch was missing; the GPU's
VRAM equalled the serial `PSP_GE_THREADS=1` reference). It now calls
`Workers.Sync` first.

## Changed files

* `source/cores/psp/PSP.GE.GPU.pas` (backend).
* `tests/cores/psp/run/PSPRun.dpr`: GPU statistics line; drains the CPU queue
  before writing VRAM.
* `tests/gpu/vulkan/GERasterTest.dpr`, `GECoherenceTest.dpr`, this file.

Not changed: `PSP.Memory`, `PSP.GE.Engine`, `PSP.GE`, `PSP.GE.Workers`,
`PSP.GE.Raster`/`Texture`/`Pixel*.inc`, the shader, frontend units.

## Remaining limits

* The frontend is capped at 60 fps, so "much faster" shows headless (Tekken
  ~2x, GoW ~2.3x) and under load; at 60 fps the Vulkan emulator thread spends
  most of its time in vertex processing, not in the backend.
* Readback happens at every access to a held page (the display reading the
  frame being drawn, the game's own VRAM accesses): ~1 per frame in Tekken.
  `PSP.Display` uses `Ptr` per row, which also synchronizes on *watched*
  pages (a displayed buffer that is also a texture); `ReadPtr` would not.
* Texture windows: projected sprites, non-positive Q/W, swizzled and DXT
  levels and odd-mirror textures still use the whole level for hazards.
* Still on the CPU: LOD-dependent sampling, aliasing/feedback that is real,
  oversized snapshots. Win32 GPU stays disabled; only Windows x64 on this AMD
  device is runtime-qualified; no device-loss recovery.
* No other emulator's sources were consulted.
