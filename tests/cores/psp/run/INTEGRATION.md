# Integrated PSP verification — 2026-10-28

Final combined runtime: merge `8405d5f`, including CPU/VFPU and JIT optimizations,
utility UI, media fixes, the CPU row pool, EDRAM permutations and Vulkan coherence.
Worker reports describe their own earlier snapshots; counts below are from the
integrator's combined build on Windows x64 / Ryzen 5 7500F / Radeon RX 9070 XT.

## Correctness

- Full pspautotests, 1200 frames, 90-second timeout, 3 jobs: **527 PASS / 111 FAIL / 638**.
  Native JIT with the default CPU row pool and `PSPJIT=off PSP_GE_THREADS=1` have
  identical status sets. No previously passing test regressed; EDRAM swizzle is
  the new pass relative to the preceding 526-test integration.
- CPU/native/model differential testing before the final GE-only merge:
  **1000 random programs + 400 directed branch pairs + 256 VFPU cases**, no difference.
- Final CPU/GPU differential suite: **77 SAME / 36 NO_DRAWS / 113**. Checked with
  native JIT/per-batch checking and with interpreter/serial CPU reference.
  Comparisons include stdout, every screenshot and all final 2 MiB VRAM bytes.
- `GEWorkersCheck`: **512 primitives**, identical physical VRAM in 1 and 6 threads.
- `GECoherenceTest`: **32,991 GPU draws, 229 VRAM/page-table comparisons, 80 native
  scalar/quad VFPU copies**, exact, no CPU fallbacks in this test.
- Frontend lifecycle regression passes after the final merge: settings, worker
  ownership, Reset, LoadExec, constructor/run failure cleanup and reattachment.
- Checked media regressions pass: large PSMF access units, pixel-sized ME picture
  copying/field selection, CSC versus scalar conversion. Checked guest IO driver
  and RTC arithmetic hardware tests also pass.

The 527 count uses ordinary emulator-device mode. Optional `--hw` omits that
device and uses guest-written host0 output/screenshots, changing the test's path
and diagnostic framebuffer text. Its results must be reported separately.
CPU/GPU equality does not imply complete agreement with PSP hardware.

## Final game comparison

One game at a time; same executable, native JIT, `PSP_GE_THREADS=6`, 1800 frames,
Start/Cross alternating from frame 500. **All 30 frame snapshots and complete
final VRAM match** between CPU and Vulkan for every row.

| Game | CPU, six drawing threads | Vulkan | Ratio |
|---|---:|---:|---:|
| Daxter | 36.91 s | 15.69 s | 2.35x |
| God of War: Chains of Olympus | 106.66 s | 38.44 s | 2.77x |
| Tekken 6 | 38.19 s | 7.25 s | 5.27x |

Whole-run host times, not steady-state gameplay FPS. Vulkan may fall back to CPU
for individual primitives; host load and selected game scenes affect timings.

## Builds and selection

- Win64 **RetroMul Release** and **RetromulTerm Release** build and link.
- Core units compile for Win32, Linux64, Android32 and Android64.
- Frontend/compute units compile for Linux64 and Android64. Their linked apps and
  device runtime were not verified. The CPU pool is Windows-only; other hosts
  use serial CPU rendering. Win32 Vulkan GE is disabled.
- Frontend: `[Video] Renderer=cpu|vulkan`, CPU default, applied on worker restart.
  Reset/LoadExec retain the renderer. Unsupported Vulkan falls back to CPU.
- Headless: `PSPRun -gpu`, `-gpu-check`; `PSP_GE_THREADS=1` selects serial CPU.

## Reproduction

```powershell
.\tests\cores\psp\run\build.ps1
python tests\cores\psp\run\autotests.py --jobs 3 --timeout 90 --frames 1200
python tests\cores\psp\run\gpudiff.py --jobs 2 --check
.\tests\cores\psp\run\build.ps1 -Project GEWorkersCheck.dpr
.\tests\cores\psp\run\bin\GEWorkersCheck_win64.exe
.\tests\gpu\vulkan\build.ps1 -Project GECoherenceTest.dpr
.\tests\gpu\vulkan\bin\GECoherenceTest_win64.exe
.\tests\cores\psp\run\build_frontend.ps1
.\tests\cores\psp\run\build_targets.ps1
.\tests\cores\psp\run\build_frontend_targets.ps1
```

See `tests/gpu/vulkan/ROUND2.md` for synchronization design/fallbacks and
`source/cores/psp/README.md` for architecture and remaining gaps. In particular,
save states, PGD/unsupported PRX loading, remaining VFPU/GE hardware precision,
font coverage and unverified full-game compatibility remain open. Retained crypto
has pre-rewrite provenance; see `PSP.PRX-LICENSE.md`.
