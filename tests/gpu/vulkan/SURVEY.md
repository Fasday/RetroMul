# Vulkan GE: level of detail, CPU runs, game survey

Branch `psp/gpu` after fast-forwarding to `pr/psp-core` **682b8a7**. Problem:
LocoRoco was 4x slower on Vulkan (cpu 10.6 s, gpu 40.4 s at 1,800 frames),
832,867 primitives drawn on the CPU ("LOD-dependent texture sampling") with a
sync and readback each.

## Changes

* **Level of detail on the GPU**, as `GESampleTextureLod` and `TexLod` compute
  it: TEXLEVEL modes (auto/const/slope), bias, slope, MIN filters 0-7 (nearest
  and linear mipmaps, mixing two levels by 1/16), MAG filter at LOD <= 0,
  levels up to `MaxLevel`. Triangles compute the LOD per pixel in the kernel
  from steps of S, T, Q the host rounds exactly as `GEDrawTriangle` does
  (Single `NSX..DQY`), with `System.Math.Max`'s NaN and signed-zero rules and
  soft-double division. Sprites get their constant LOD from the host (the
  same expressions as `GEDrawSprite`). Lines and points sample at LOD 0, as
  the CPU does. Level coordinates are scaled in single precision (Delphi
  rounds `S * Width` as Single: verified, it overflows to Inf), multiplying by
  the exact reciprocal of level 0's power-of-two size.
  Every sampled level has its own source (VRAM, any mirror, or a watched copy
  in the batch) and its own span for hazard tracking. Remaining CPU cases:
  triangles whose Q*w or w is not finite and positive (`GEDrawTriangle` then
  keeps the previous pixel's LOD, an order dependence), level 0 not a power of
  two with mipmaps.
* **Boxes no wider than the stride** go to the GPU even when they reach past
  the stride's end ("pixels share colour memory" was X2 >= stride): such
  pixels still have their own bytes; passes split when their box gets wider.
* **CPU runs**: a CPU-drawn primitive now goes to a `TGEWorkers` queue (the CPU
  renderer, unchanged, which holds and watches its own pages), and so do the
  following primitives while they cover fewer pixels than a budget: 16K pixels
  at first, growing x4 up to 256K while CPU-drawn primitives keep coming back
  within 64 GPU primitives. The queue is drained before the GPU draws again
  or synchronizes. GPU work is synchronized before a run starts, so the two
  never hold pages at once. `PSP_GPU_CPURUN` sets the maximum (0: no runs).
  Measured on LocoRoco with LOD forced to the CPU (the old situation):
  41.1 s without runs, 17.9 s with them; the CPU renderer took ~17 s.

## Exactness

* `gpudiff.py` all 113, JIT and `PSPJIT=off`: **71 SAME / 42 NO_DRAWS** with
  runs, **81 SAME / 32 NO_DRAWS** with `--check` (no runs) and with
  `PSP_GPU_CPURUN=0`; `PSP_GE_THREADS=1` (serial queue) also 71/42. No
  differences in any mode. The 10 tests that move to NO_DRAWS with runs draw
  everything after their first CPU-drawn primitive on the CPU queue; three
  mipmap tests (`gpu/filtering/mipmaplinear`, `gpu/textures/mipmap`,
  `gpu/textures/mipinvalid`) now draw on the GPU and match.
* `GERasterTest`: **56,134 primitives / 1,093 whole-VRAM compares**, exact,
  also with `PSP_GE_THREADS=1`. New: 8,000 random LOD draws (every filter,
  mode, bias, slope, 1-8 levels in RAM or any VRAM mirror, minified/
  magnified/flat/huge coordinates, any Q and w, all primitive kinds) and 8,000
  draws mixing CPU-drawn primitives, runs, GPU batches, CPU writes to held
  pages, GE stops and budgets. Caught mutations: slope mode +15 instead of +16,
  unscaled level coordinates, wrong trilinear weights, perturbed LOD
  division, a sign flip in the per-pixel steps, a sprite LOD off by one, a
  dropped step term; no queue drain before the GPU, none before a sync, no
  GPU sync before a run.
* `GECoherenceTest` with synchronization validation, renderer lifecycle test:
  pass.

## Survey

Every image in `D:\Soft\PSP` (40, including subfolders),
`gpudiff.py --games --frames 2400 --mash 500 --jobs 2`: 40 frame snapshots +
final VRAM each. **38 SAME, 0 DIFF**; KHBBS draws nothing in either mode;
Monster Hunter Portable 3rd does not load in either mode (core loader error
80020148). Seconds with two games at a time on a machine shared with other
workers (noisy; GPU runs of both jobs share the device):

| Image | CPU | Vulkan | CPU/Vulkan | CPU prims | Run prims |
|---|---:|---:|---:|---:|---:|
| Burnout Legends (rus).cso | 49.58 | 28.26 | 1.75 | 427 | 1,519 |
| Castlevania Dracula X Chronicles RUS.cso | 16.11 | 4.33 | 3.72 | 0 | 0 |
| Daxter.iso | 59.07 | 44.25 | 1.33 | 1 | 32 |
| Dissidia_Final_Fantasy_012.ISO | 10.96 | 5.63 | 1.95 | 0 | 0 |
| FFT WOTL RUS v0.6.iso | 43.07 | 22.74 | 1.89 | 1,115 | 1,041 |
| FF_IV_TCC.iso | 18.56 | 10.46 | 1.77 | 20 | 236 |
| Final_Fantasy_Anniversary_Edition_RUS.cso | 12.09 | 9.26 | 1.31 | 1 | 85 |
| GTA LCS 01.09.2005 ULUX80146 V0.02.iso | 133.61 | 47.11 | 2.84 | 857 | 19,508 |
| GTA_VCS_rus.iso | 68.65 | 34.02 | 2.02 | 1,332 | 125,411 |
| God of War - Chains of Olympus.iso | 132.41 | 30.95 | 4.28 | 1 | 2 |
| JD-0.3.iso | 36.33 | 17.40 | 2.09 | 0 | 0 |
| LocoRoco 2 [UCES-01059][RUS][L].iso | 25.50 | 14.25 | 1.79 | 0 | 0 |
| LocoRoco.cso | 54.73 | 18.84 | 2.90 | 1 | 1 |
| Lumines.cso | 58.17 | 7.97 | 7.30 | 1 | 0 |
| MGS PW.cso | 72.58 | 13.86 | 5.24 | 0 | 0 |
| Manhunt2rus.iso | 46.56 | 24.05 | 1.94 | 215 | 956 |
| Metal Slug Anthology.iso | 6.59 | 5.00 | 1.32 | 47 | 707 |
| Metal_Gear_Acid_2.cso | 11.32 | 5.08 | 2.23 | 1 | 0 |
| Monster Hunter Freedom Unite.iso | 33.07 | 8.94 | 3.70 | 1 | 0 |
| Need for Speed ProStreet (rus).cso | 34.72 | 21.64 | 1.60 | 1 | 0 |
| Need for Speed Underground Rivals (rus).cso | 49.51 | 17.84 | 2.78 | 1 | 0 |
| P3P RUS v.0.8.3.iso | 14.39 | 6.07 | 2.37 | 51 | 204 |
| RCSM.iso | 4.55 | 5.23 | 0.87 | 0 | 0 |
| Ridge Racer 2.iso | 15.91 | 6.33 | 2.51 | 1 | 0 |
| RivalSwords_RUS.cso | 31.93 | 25.01 | 1.28 | 510 | 13,638 |
| SF DM.iso | 72.23 | 15.08 | 4.79 | 0 | 0 |
| Second Evolution.cso | 45.82 | 44.78 | 1.02 | 2,424 | 21,484 |
| Sonic Rivals [FULL][RUS].iso | 19.07 | 6.46 | 2.95 | 4 | 100 |
| Star Wars The Force Unleashed rus.ISO | 85.24 | 31.88 | 2.67 | 251 | 16,371 |
| Tekken DR.cso | 59.23 | 13.32 | 4.45 | 0 | 0 |
| Tekken_6_[RUS].cso | 33.67 | 12.79 | 2.63 | 3 | 38 |
| Tony Hawks Underground 2 Remix.cso | 90.64 | 47.76 | 1.90 | 72 | 1,629 |
| VC2_RUS_1_0_ENGDUB.iso | 24.14 | 9.60 | 2.51 | 0 | 0 |
| VC2_RUS_1_0_JAPDUB.iso | 19.61 | 7.09 | 2.77 | 0 | 0 |
| Wipeout_Pure_JAP_PSP-DEV.iso | 4.15 | 5.42 | 0.77 | 1 | 0 |
| ccff7rusundub_v1.iso | 12.38 | 8.46 | 1.46 | 177 | 2,591 |
| ffiii_rus.iso | 5.02 | 3.89 | 1.29 | 0 | 0 |
| pata_rus.cso | 17.83 | 6.16 | 2.89 | 0 | 0 |

Close cases re-timed one game at a time (seconds, CPU / Vulkan): RCSM 4.68 /
4.69, WipeOut 4.29 / 4.59 (earlier 2.74 / 2.39), ffiii 4.75 / 4.53,
RivalSwords 28.99 / 28.10, Second Evolution 38.26 / 29.42, Final Fantasy
Anniversary 9.57 / 8.34 (earlier 6.62 / 4.47), Metal Slug 6.35 / 5.24, Daxter
49.97 / 33.29. RCSM and WipeOut are light 2D/menu workloads (100-140K primitives over
2,400 frames, 0.1 s of GPU drawing): the emulator's own work dominates and both
renderers keep up; the difference is within run-to-run noise (startup is
0.1 s either way). No game is much slower on Vulkan.

LocoRoco: 1,800 frames (`--mash 500`) cpu 10.56 s / gpu 5.95 s, SAME (was
40.4 s); frontend `-mash -from 8`: CPU 57.3 fps, Vulkan 59.9 fps.

## Remaining limits

* Second Evolution, RivalSwords, GTA VCS/LCS and Star Wars still draw thousands
  of primitives on the CPU ("texture from the pixels drawn" beyond the
  texel windows, swizzled textures in their own buffer, "pixels share colour
  memory" with boxes wider than the stride). Runs keep them near CPU speed.
* The texel windows (SPEED.md) are not used for mipmapped textures.
* Changed files: `PSP.GE.GPU.pas`, `PSPGERaster.comp` (+ `.spv.inc`),
  `PSPGEState.glsl`, `GERasterTest.dpr`, `PSPRun.dpr` (statistics line).
  `PSP.GE.Workers` is used as is (a second instance owned by the backend);
  no CPU raster, memory, engine or frontend file changed. No other emulator's
  sources were consulted.
