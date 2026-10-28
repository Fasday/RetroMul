# Vulkan compute and the optional PSP GE backend

The normal renderer is still `PSP.GE.Raster`. Nothing in the frontend enables
Vulkan implicitly. `PSPRun -gpu` attaches `TGEGPUBackend` to the GE engine;
`-gpu-check` draws each batch with both implementations, compares VRAM and keeps
the CPU result. If Vulkan initialization, required features or the startup
arithmetic self-test fail, the runner prints the reason and uses the CPU.

The current branch integrates `pr/psp-core` 9938cbf and the GE worker through
`fc49936`, including threaded CPU rasterization and permuted EDRAM. See
**`tests/gpu/vulkan/ROUND2.md`** for the current integration and qualification.
The initial qualification figures below record the earlier `aa709ab` reference
(Gouraud colour planes), not the newer threaded baseline. CPU numerical
expressions were **not changed to make the GPU agree**. No other emulator's
sources were consulted.

## Build and run (from the repository root)

```powershell
# These builds use committed SPIR-V includes, not a Vulkan SDK.
.\tests\gpu\vulkan\build.ps1
.\tests\gpu\vulkan\bin\ComputeTest_win64.exe -validation
.\tests\gpu\vulkan\build.ps1 -Project GERasterTest.dpr
.\tests\gpu\vulkan\bin\GERasterTest_win64.exe

.\tests\cores\psp\run\build.ps1
.\tests\cores\psp\run\bin\PSPRun_win64.exe game.iso -gpu -frames 1800
.\tests\cores\psp\run\bin\PSPRun_win64.exe game.iso -gpu-check -frames 900
python tests\cores\psp\run\gpudiff.py --jobs 4
python tests\cores\psp\run\gpudiff.py --check --jobs 4
python tests\cores\psp\run\autotests.py gpu/ --backend vulkan --jobs 4

# Recompile after changing GLSL. glslc, spirv-dis/as/val come from the SDK.
.\source\gpu\shaders\compile.ps1
```

`gpudiff.py` compares stdout, **every** screenshot emitted by a test, and the
whole final 2 MiB VRAM dump (`PSPRun -vram path`). For games it also compares
frame snapshots every 60 frames. Example:

```powershell
python tests\cores\psp\run\gpudiff.py --games --frames 1800 --mash 500 --jobs 1 `
  'D:\Soft\PSP\God of War - Chains of Olympus.iso'
```

`NO_DRAWS` is reported separately when a test does no GPU work; it is not counted
as proof of the shader. A missing device, process failure or timeout is not a
passing comparison. `autotests.py --backend cpu|vulkan|check` still uses the real
PSP's expected output, rather than the CPU implementation, as its oracle.

To enable synchronization validation as well as ordinary validation for the GE
stress test (requires the SDK's validation layer):

```powershell
$env:VK_INSTANCE_LAYERS = 'VK_LAYER_KHRONOS_validation'
$env:VK_LAYER_VALIDATE_SYNC = '1'
.\tests\gpu\vulkan\bin\GERasterTest_win64.exe
Remove-Item Env:VK_INSTANCE_LAYERS, Env:VK_LAYER_VALIDATE_SYNC
```

## What runs where

* Command processing, decoding, vertex transforms, lighting, clipping and patch
  tessellation remain on the CPU, exactly the existing GE engine.
* Triangle coverage uses integer edge functions and the reference's top-left
  rule. Gouraud colour uses the reference's 14-bit gradient planes anchored at
  its lowest/rightmost vertex. Z, secondary colour and fog retain the reference's
  double-precision expression order and round-to-even conversions.
* Sprites, including turned corners and projective Q, rasterize on the GPU.
  Line/point coverage and interpolation are currently set up on the CPU;
  their texture and pixel pipelines execute in the shader.
* The shader samples linear/swizzled direct and CLUT textures, including
  DXT1/3/5 with the reference's PSP block layout and precision; nearest and
  bilinear filters. It implements texture functions, fog, tests, stencil,
  depth, blend, dither, logic operations and write masks.
* The backend **falls back per primitive** for LOD-dependent texture sampling
  (`TGETexture.NeedLod`, including mipmaps and min/mag filter switching), pixels
  aliasing framebuffer/depth memory, texture feedback within a primitive, or a
  texture snapshot larger than 16 MiB. These are logged and counted, not silently
  approximated. A run can consequently contain both CPU and GPU rendering.
* Native GPU division is not IEEE bit-exact (the probe finds thousands of
  differences); `SoftDouble.glsl` performs significand long division with exact
  round-to-nearest-even instead. `precise` and SPIR-V float-control modes prevent
  contraction, reassociation and denormal flushing. Startup checks the required
  float operations against the host CPU before attaching the backend.

## Ordering and memory

A pass has one framebuffer and, when used, one depth mapping. Passes split on
render-target changes or read/write hazards. CPU binning builds ordered lists
for 16x16 tiles. One shader invocation owns a pixel and visits its list in GE
order. There are no scheduling-dependent atomics or unordered primitive writes.
Two descriptor/buffer/command slots allow submission while the CPU continues.
The shared GPU VRAM is still serialized, including transfer-readback versus
subsequent shader/transfer writes.

The backend holds pages of VRAM that queued or pending work reads or writes.
`TPSPMemory` removes those pages from **all four mirrors** of the page table.
Any CPU read, write, pointer request, code fetch or reset that needs held data
synchronizes and restores it first. This also covers the integrated JIT: a nil
page goes to its existing slow memory routine. Unheld CPU writes are detected
by page comparison at submission. RAM textures and CLUT are snapshotted before
the CPU can modify them. Only held pages are read back.

`HostPtr` is deliberately limited to the GE's CPU texture fast path: it forms a
pointer without consuming held data. It must not be used for ordinary guest
reads. Fallback drawing synchronizes before using such texture pointers.

The caller owns `TGEGPUBackend`; detach `Engine.Backend` and destroy it while its
`TPSPMemory` is still alive. It owns its `TVulkanCompute`. One backend may hold a
memory instance's pages. The PSP frontend now has an optional, restart-applied
`[Video] Renderer=cpu|vulkan` choice (CPU default); see
`tests/cores/psp/run/frontend_renderer.md` for its lifecycle and smoke tests.
A device loss during submitted work is reported as a host error; automatic
recovery/replay after device loss is not implemented.

## Verified results (AMD Radeon RX 9070 XT, Vulkan 1.4.349)

* `ComputeTest_win64`: all integer-width arithmetic, 8/16-bit storage, buffer
  copies/fill/update and the toy triangle mesh match the Pascal reference.
  2,066 toy triangles into 512x272: typically 1.2 ms GPU kernel; CPU timings vary
  with host load (roughly 45–105 ms). Float add/multiply/conversion probes agree
  with IEEE controls; native divisions are intentionally diagnostic, not used
  as a correctness substitute. Validation is clean.
* `ComputeTest_win32`: integer/storage/copy/toy raster tests pass. IEEE float
  probes are skipped because the CPU uses x87 extended intermediates. The
  **GE backend intentionally declines Win32**; the runner uses the CPU there.
* `GERasterTest_win64`: 16,128 deterministic randomized primitives, 64 whole-VRAM
  comparisons, including projective coordinates, all texture formats, state
  changes, RAM/CLUT mutation, CPU writes to held pages and slot reuse: exact.
  14,882 nonempty primitives execute on the GPU, zero CPU fallbacks. Ordinary
  and synchronization validation report no errors.
* All 113 `gpu/*` autotests: identical CPU/GPU stdout, all screenshots and final
  VRAM with both interpreter and integrated JIT. 78 perform GPU work; 35 do no
  GPU draws. One run executes 48,821 GPU primitives and 938 CPU fallbacks.
  Batch checking also reports zero differences. A checked-build subset of 21
  primitive/pixel/texture-format tests matches as well.
* This is **not** a claim that all 113 match PSP hardware: hardware-oracle
  results are the same for CPU and Vulkan, **63 PASS / 50 FAIL** at this revision.
* At 900 frames, Start/Cross alternated from frame 500, all of these match in
  15 frame snapshots, final VRAM and per-batch differential checking:
  God of War: Chains of Olympus, Daxter, Lumines, Tekken 6, Ridge Racer 2,
  Burnout Legends, Final Fantasy IV TCC, Metal Gear Acid 2. Across these runs,
  all 779,757 checked GPU batches match (CPU fallback primitives are separate).
* A forced missing Vulkan ICD falls back successfully: CPU and fallback runs
  of `gpu/primitives/triangles` have identical stdout and entire final VRAM.

### Measured game speed

Same binary, integrated JIT, CPU then GPU, one game at a time, 1,800 frames,
Start/Cross from frame 500, 30 exact frame snapshots and final VRAM comparison.
These are whole-run host seconds, not steady-state FPS or isolated shader
benchmarks. Both modes can still have missing guest functionality.

| Game | CPU reference | Optional GPU backend | Speedup |
|---|---:|---:|---:|
| God of War: Chains of Olympus | 232.89 s | 28.63 s | 8.1x |
| Daxter | 49.96 s | 17.31 s | 2.9x |
| Tekken 6 | 73.38 s | 5.11 s | 14.4x |

God of War executes 7,690,142 GPU primitives and 167,257 CPU fallbacks in that
run (mostly self-texturing); measured GPU drawing is 5.58 s and host waiting is
2.78 s. The rest includes CPU emulation, setup, snapshots, binning and I/O.
Windows/Win64 on this AMD device is the qualified GE target. Linux64/Android64
frontend and compute units now cross-compile (see the frontend report), but were
not run on devices here. No claim of universal device/driver bit-exactness is
made by a finite test suite.

## Existing shared files changed by this worker

* `source/gpu/vulkan/RM.Vulkan.Bindings.pas`: additive compute/buffer/descriptor,
  feature-query, semaphore, timestamp and command declarations.
* `source/gpu/vulkan/RM.Vulkan.Loader.pas`: load those core functions; external
  memory/semaphore extension functions are optional when not enabled, so a
  headless device needs no texture-sharing extension.
* `source/cores/psp/PSP.Memory.pas`: held-page/fault callback API, nil-page slow
  paths in scalar accesses and code fetches, pointer-range synchronization,
  reset synchronization and the GE-only `HostPtr` helper. The JIT's page-table
  accessors from the integrator are preserved.
* `source/cores/psp/PSP.GE.Engine.pas`: non-owning backend field, four draw hooks,
  release hook and non-consuming texture pointer lookup. No change to the
  CPU raster/texture arithmetic.
* `source/cores/psp/PSP.GE.pas`: release the backend whenever `RunHW` returns.
* `tests/cores/psp/run/PSPRun.dpr`: `-gpu`, `-gpu-check`, `-vram`, backend lifetime
  and statistics; the integrator's history/audio/HW/test options remain.
* `tests/cores/psp/run/build.ps1`: Vulkan unit/include paths; exclusions relative
  to `source` (the worktree itself is named `gpu`).
* `tests/cores/psp/run/autotests.py`: optional backend selection and validation of
  the requested backend in hardware-oracle runs.
* `.gitignore`: admit `tests/gpu/`, preserving the integrator's test directories.

Everything else added here is new compute/backend/shader/test infrastructure.
Merges also import other workers' changes; those are not GPU arithmetic changes.
