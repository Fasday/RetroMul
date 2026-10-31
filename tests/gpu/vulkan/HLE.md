# Vulkan HLE renderer for the PSP GE

`PSP.GE.VulkanHLE` (`TGEVulkanHLEBackend`) draws the GE's primitives with
Vulkan graphics pipelines. It is fast but not bit exact; the CPU renderer
(`PSP.GE.Raster`) stays the reference and the default. The compute renderer is
now called Vulkan LLE (`PSP.GE.VulkanLLE`, formerly `PSP.GE.GPU`). It is
unchanged and still bit exact. The design is our own and no other emulator's
sources were consulted.

## Selecting it

- Frontend: *Settings → PSP video → Renderer*: CPU (software), Vulkan LLE or
  Vulkan HLE. These are stored in `psp.ini` as `Renderer=cpu|vulkan|vulkan-hle`.
  The existing `vulkan` value still means the LLE, so current settings keep
  their meaning; `vulkan-lle` is read as a synonym.
- `PSPRun ... -gpu-hle`, `PSPAdapterRun ... -gpu-hle`,
  `PSPStateTest ... vulkan-hle`, `PSPWorkerSnapshotTest ... vulkan-hle`.
- `autotests.py --backend hle`.

If the device has no queue with both graphics and compute, or no
depth/stencil format with 8 stencil bits, the reason is reported and the CPU
renderer is used.

## How it draws

- **Vertices** come from the engine already transformed, lit and clipped, in
  target pixels. All attributes are interpolated linearly on the screen, as
  the GE interpolates them. Texture coordinates are passed multiplied by
  1/w and divided by q in the fragment shader. Flat shading takes the last
  vertex's colours. Sprites become two triangles, with S/T turned when only
  one axis is flipped.
- **Lines** do not cover the same pixels as Vulkan lines. They are therefore
  drawn as one point per pixel the GE covers, with the attributes the GE
  computes for that pixel.
- **Fragment shader**: the GE's texture functions in 8-bit integer
  arithmetic, secondary colour, fog, colour and alpha tests, the depth range
  test, and dither. Texels are fetched by the shader as the GE samples them:
  wrap or clamp per level, nearest by floor, bilinear with 4-bit weights, and
  the level of detail in 1/16 levels from the GE's 4-bit-mantissa log2, for
  automatic, constant (also mode 3) and slope modes. Depth is written as the
  GE rounds it, as Z/65536 (exact in a D32 float).
- **Fixed function**: blending, logic operations, depth and stencil tests and
  operations, and channel write masks.
- **Render targets** are images keyed by (address, format, stride). The PSP's
  framebuffer alpha is its stencil: it lives in the stencil aspect (8 bits,
  4-bit values times 17). It is merged back into the alpha bits on read-back.
  The colour image's alpha mirrors it for destination-alpha blending and is
  written only by clears.
- **Coherence with guest memory**: a target's pages are held while it is
  newer than VRAM. Any CPU, DMA, display or GE access to one reads every target
  back (`FlushAll`). Textures are decoded on the CPU (`GEFetchTexel`), cached,
  compared with their source bytes once per epoch, and watched from then on.
  Depth buffers that are only read are watched as well. A target that is not
  held is compared with its shadow copy and reloaded when the CPU changed it.
  Targets that take turns with one depth buffer pass it on with a GPU image
  copy. Render-to-texture goes through VRAM.

## Known differences from hardware (and from the CPU renderer)

- Blending rounds like the GPU, not with the GE's `(c + 1) * f >> 8`. This
  causes off-by-one colours in alpha blends. Double destination alpha and the
  doubled factors on the destination side have no fixed-function factor and
  are drawn undoubled. The absolute-difference op is drawn as the maximum.
  A source FIX factor is applied in the shader, which is wrong when the
  destination factor also uses the source colour.
- Write masks that keep only some bits of a colour channel are applied per
  channel.
- Stencil increment and decrement on 4444/5551 targets work on the 8-bit
  value, not in the format's precision.
- Gouraud colours are interpolated in float, not with the GE's fixed-point
  planes (off by one at times).
- Dither is added to the source before the blend.
- Upscaling is not enabled yet (the scale is 1). The pipeline and the
  shaders already take a scale.

## Results

Measured on Windows x64 with an AMD Radeon RX 9070 XT.

- `autotests.py --backend hle` (regular profile): **542 PASS / 96 FAIL / 638**,
  against 547 for the CPU renderer. The only differences are 5 GPU tests that
  pass on the CPU, all from the limits listed above:
  - `gpu/commands/blend` and `blend565`: blend rounding, doubled destination
    alpha, absolute difference;
  - `gpu/dither/dither`: partial channel write masks;
  - `gpu/primitives/immediate`: Gouraud ±1 on 960 pixels;
  - `gpu/stencil/writemask`: 4444/5551 increment and decrement.

  In `gpu/` the HLE passes 72 of the 77 tests the CPU renderer passes. Among
  them are texture filtering, mipmaps, the level-of-detail modes, render
  targets and copies.
- Monster Hunter Portable 3rd, 12000 frames with the state test's menu inputs:
  - The final frame hash is the same as with the CPU renderer.
  - Of the frames at every 1000, 8 are identical. Four menu frames differ in
    up to 13,692 pixels (at most 1,440 of them by more than 8), from blend
    rounding.
  - Run time is 33.8 s, against 30.9 s for the CPU renderer on its 10 threads.
    At this resolution the HLE is not faster yet: flushing to VRAM, which the
    display needs every frame, takes 2.4 s and state setup 0.9 s.
- Unchanged CPU and LLE behaviour:
  - The regular suite (547/638) and the `--hw` suite (520/638) have unchanged
    status sets. JIT and interpreter reports are byte-identical.
  - The LLE's `gpu/` results equal the CPU's. `gpudiff.py --check` gives
    81 SAME and 32 NO_DRAWS, with no differences.
  - `GERasterTest`, `GECoherenceTest` and `ComputeTest` pass.
- Lifecycle and state tests pass:
  - `PSPRendererLifecycleTest`, for both Vulkan renderers.
  - `PSPWorkerSnapshotTest`, with `vulkan` and `vulkan-hle`.
  - The old snapshot imports.
  - The MHP3rd frame-11000 movie-state matrix, with `vulkan` and `vulkan-hle`.
- Builds: the GUI for Win64 and Win32, the core for win32, linux64, android32
  and android64, and the frontend units for linux64 and android64. These
  targets were compiled only; they were not run.
