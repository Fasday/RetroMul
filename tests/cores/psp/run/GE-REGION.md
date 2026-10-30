# MHP3rd stretched character: REGION clipping and vertex-memory corruption

## Cause

`PSP.GE.Engine.BuildRaster` used SCISSOR but ignored REGION for drawing. The
registers in the affected MHP3rd scene were:

| Register | X | Y |
|---|---:|---:|
| REGION1 | 0 | 0 |
| REGION2 (inclusive) | 479 | 271 |
| SCISSOR1 | 0 | 0 |
| SCISSOR2 (inclusive) | 480 | 272 |

Depth starts at VRAM offset `0x88000`, stride 512, with 1024-byte EDRAM
translation. The extra row's depth pixel **(337, 272)** maps to physical VRAM
offset **`0xCE122`**. That is the X coordinate of vertex 70 in a character mesh
at `0x040CDB9C`, stride 20, position offset 14. Depth gradients overwrote these
positions, producing the large brown triangles visible in the screenshot.

The fault was present in both CPU and Vulkan rendering. Their agreement did
not establish hardware accuracy. The captured weights and bone transforms were
consistent; the vertex bytes themselves were already damaged before skinning.
For example, one vertex changed from the corrupted
`(-0.860535, -0.860352, -0.860138)` back to
`(-0.121521, -0.027771, -0.121979)` when the out-of-region writes were prevented.

## Fix

- Draw only in the intersection of REGION and SCISSOR, including colour,
  stencil, depth, clearing, lines and points.
- Include REGION1/2 in the cached raster-state key; a change to REGION alone
  must rebuild the clipping state.
- No game-specific mesh changes, coordinate clamps or bone workarounds.
- Diagnostic vertex capture used to locate the fault was removed from the hot
  path after investigation.

The scissor/region roles are also visible in the allowed PSPSDK GU setup and
the hardware-recorded pspautotests (`gpu/bounding/viewport.cpp`). No expected
test image was changed.

## Regression checks

`GERegionCheck.dpr` constructs expected colour/depth writes independently and
compares **all 2 MiB of VRAM**, not just the displayed frame. Its **320 cases**
cover four framebuffer formats, five depth permutations, normal and clear
triangles/sprites, points/lines outside the region, the last valid pixel, empty
intersections and changes to REGION without another state change.

- Win64 checked: serial CPU, pooled CPU and Vulkan all pass.
- Win32 checked: serial and pooled CPU pass.
- Compiling the same test against the pre-fix engine (`8c80c6c`) fails on the
  first escaped pixel, confirming the test detects the original defect.
- Full pspautotests remain **527/638**, no pass-set regressions. JIT/pool and
  interpreter/serial full reports are identical.
- GPU per-batch differential suite: **81 SAME / 32 NO_DRAWS**, no differences.
- MHP3rd, 22,500 scripted frames: CPU and Vulkan match all **37 snapshots**,
  complete guest-frame progression, final hash **`6d921293cb415022`** and
  **26,431.7 million** guest cycles. The visible stretched geometry is gone.
- Core units compile for Win32, Linux64, Android32 and Android64.

These game hashes supersede the pre-fix geometry hashes in the crypto-only
report. Correcting guest-visible VRAM writes intentionally changes those hashes.

```powershell
.\tests\cores\psp\run\build.ps1 -Project GERegionCheck.dpr -Checked
.\tests\cores\psp\run\bin\GERegionCheck_win64_checked.exe -serial
.\tests\cores\psp\run\bin\GERegionCheck_win64_checked.exe
.\tests\cores\psp\run\bin\GERegionCheck_win64_checked.exe -gpu
```
