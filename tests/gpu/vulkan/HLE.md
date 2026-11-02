# Vulkan HLE renderer for the PSP GE

`PSP.GE.VulkanHLE` (`TGEVulkanHLEBackend`) draws the GE's primitives with
Vulkan graphics pipelines. It is fast but not bit exact; the CPU renderer
(`PSP.GE.Raster`) stays the reference and the default. The compute renderer is
now called Vulkan LLE (`PSP.GE.VulkanLLE`, formerly `PSP.GE.GPU`). It is
unchanged and still bit exact. The design is our own and no other emulator's
sources were consulted.

What does not depend on the GE is in the common base `RM.Vulkan.HLE`
(`TVulkanHLERenderer`): the device and its command slots, targets, coherence
with guest memory, the texture cache, pipelines, batches and frames.
`TGEVulkanHLEBackend` derives from it; the engine draws through its
`EngineBackend`. How to build an HLE renderer for another console on the base
is in **`HLE-RENDERERS.md`**.

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
  newer than VRAM, but only the rows actually drawn. Any CPU, DMA, display or
  GE access to a held page reads every target back (`FlushAll`). The rest of
  a drawn target is watched. A write there marks the image stale outside the
  drawn rows: it is not shown from the image, and drawing into those rows
  reads it back and loads it again. Such a write does not stop the GPU. The
  same holds for textures and for depth buffers that are only read: they are
  decoded on the CPU (`GEFetchTexel`), cached, compared with their source
  bytes once per epoch, and watched from then on. For this, the memory got
  `OnWatchFault` with the write's address, separate from `OnVRAMFault`.
  A target that is not held is compared with its shadow copy and reloaded
  when the CPU changed it. Targets that take turns with one depth buffer pass
  it on with a GPU image copy.
- **Render-to-texture** samples the target's image directly, at its scale,
  without reading it back. This needs a texture with one level, not swizzled,
  of the target's format, address and stride, and a current image (newer than
  guest memory with no stale rows, or equal to it). It is not used when the
  draw's own target shares bytes with it. The shader takes the texels in the
  target format's precision; their alpha is the stencil, and 565 is opaque.
  The fixed function's stencil operations leave the colour's alpha (the
  stencil's mirror) behind. A compute pass brings it up to date before such
  a texture, or a blend with destination alpha, reads it. Other cases go
  through VRAM.
- **Shader blending** applies where the device has
  `VK_EXT_fragment_shader_interlock` (pixel interlock) and RGBA8 storage
  images, for draws that blend, use a logic operation or mask part of a
  channel's bits, but write no depth and no stencil. Such draws go through a
  second fragment shader (`PSPGEHLEBlend.frag`) in a render pass without
  attachments:
  - it tests depth and stencil against the target's images (only read);
  - then, in primitive order, it does the GE's blend (every factor, the
    `(c + 1) * f >> 8` rounding, the absolute difference), dither after the
    blend, the logic operation and the bit masks, in the target format's
    bits.

  Other draws keep the fixed function. `PSPRun -fixed-blend` turns shader
  blending off.

## Known differences from hardware (and from the CPU renderer)

- Draws that blend with the fixed function have these differences. These are
  all blending draws without shader blending, and those that also write depth
  or stencil:
  - blending rounds like the GPU, not with the GE's `(c + 1) * f >> 8`, so
    alpha blends can be off by one;
  - double destination alpha and the doubled factors on the destination side
    are drawn undoubled;
  - the absolute-difference op is drawn as the maximum;
  - a source FIX factor is applied in the shader, which is wrong when the
    destination factor also uses the source colour;
  - write masks that keep only some bits of a colour channel are applied per
    channel.
- Stencil increment and decrement on 4444/5551 targets work on the 8-bit
  value, not in the format's precision.
- Gouraud colours are interpolated in float, not with the GE's fixed-point
  planes (off by one at times).
- Without shader blending, dither is added to the source before the blend.
- At a scale above 1, guest memory gets the sample at the centre of each
  pixel's block (the nearest one for even scales). Programs that read rendered
  pixels back (render-to-texture, CPU reads) see that sample, and mipmap
  levels follow the higher resolution, as intended for sharper output.

## Internal resolution (upscaling)

*Settings → PSP video → Internal resolution* (`[Video] Resolution=1..8` in
`psp.ini`, offered as 1×, 2×, 3×, 4×, 6× and 8×) applies to the Vulkan HLE
renderer. `PSPRun -gpu-hle -scale N` and `autotests.py --backend hle --scale N`
take it as well.

- Targets are drawn at N times the PSP's resolution: the viewport, scissor,
  points and dither scale with it.
- Frames are shown from the renderer's image (`TPSPConsole.OnPresent`), at
  1920×1088 for 4×. This applies whenever the shown framebuffer is a target
  whose image is current: newer than guest memory, or equal to it. Otherwise,
  for example movies the CPU writes, the display shows guest memory at 1×.
  Showing a frame does not read the targets back, so at 1× this path also
  saves the per-frame flush.
- A compute kernel (`PSPGEHLEDown.comp`) brings targets back to the PSP's
  resolution when guest memory needs them. It also writes the shown frame as
  ARGB.
- Loads from guest memory expand every pixel to its block, in row bands. The
  device used here cannot blit into depth/stencil images.

Measurements (MHP3rd, 12000 frames with the state test's inputs, same final
hash at every scale):

| Renderer | Time | Frames shown by the renderer | Flushes |
|---|---:|---:|---:|
| CPU, 10 threads | 41.1 s | – | – |
| Vulkan HLE 1× | 36.7 s | 5236 (1.2 s) | 184 |
| Vulkan HLE 2× | 37.4 s | 5236 (3.1 s) | 184 |
| Vulkan HLE 4× | 45.9 s | 5236 (10.4 s, about 2 ms a frame) | 184 |

The rest of the 12000 frames are movies the CPU writes into VRAM; they are
shown at 1×. Before frames were shown from the renderer, HLE at 1× flushed
2796 times. The 1× frames shown from the renderer are identical to those
shown from guest memory.

`autotests.py --backend hle --scale 2`: 533/638. The 11 further failures
against 1× read exact sampling results back (`gpu/filtering/*`,
`textures/mipmap`, `mipinvalid`, `size`, `texmtx/uvs`, `clipping/homogeneous`):
at 2× they get the block's sample and finer mipmap levels. At 3× (an exact
centre sample) 8 of these still differ, from the level of detail.

## Texture scaling

*Settings → PSP video → Texture scaling* (`[Video] TextureScale=0|2..6` in
`psp.ini`, off by default; `PSPRun -texscale N`) makes textures larger when
the internal resolution is above 1×, with *Texture filter*
(`[Video] TextureFilter=xbrz|hybrid|bicubic`; `PSPRun -texfilter`). It is not
the GE's behaviour: it trades exactness for sharper or smoother textures.

- `RM.Vulkan.TexScale` scales each decoded level on the CPU.
  - xBRZ: edges at the corners between texels come from colour differences
    along the two diagonals of the 4×4 around them; each texel's block then
    takes the colour across the edge in its corners, cut diagonally, at half
    or twice that slope, or rounded. Colours are compared in Y'CbCr with
    alpha and mixed weighted by alpha.
  - Bicubic: Catmull-Rom over the 4×4 texels around each pixel, with the
    colour premultiplied by alpha.
  - Hybrid: bicubic for texels that differ little from all eight around them
    (distance under 40), xBRZ's blocks elsewhere.
  - Textures of 64×64 and up are scaled in row bands on the thread pool.
- The image holds the texels N times larger (`TVulkanHLETexture.Scale`); the
  shader multiplies its coordinates by N (`TEX_SCALED`) and wraps at any size.
  The level of detail still comes from the GE's coordinates.
- Not scaled: render targets used as textures (already at the internal
  resolution), textures under 8 texels a side (ramps and tables that bilinear
  filtering keeps smooth), sizes beyond 1024 texels after scaling (the factor
  drops), levels that do not halve in both directions, and textures decoded
  again in every GE run. A scaled texture whose bytes change twice within 60
  frames shown (videos, textures streamed through one place) is made again
  unscaled; its old image goes once the GPU has finished.

Tekken 6 at 4× with 4× textures: 1392 uploads scaled in 4600 frames, 1.1 s in
all with xBRZ (at most 9 ms for one 256×256), about 2 s with the bicubic and
hybrid filters, most of it while loading; the battle's frame rate does not
change.

## Results

Measured on Windows x64 with an AMD Radeon RX 9070 XT.

- `autotests.py --backend hle` (regular profile): **544 PASS / 94 FAIL / 638**,
  against 547 for the CPU renderer. The only differences are 3 GPU tests that
  pass on the CPU, all from the limits listed above:
  - `gpu/commands/blend`: its blends also write the stencil, so they keep
    the fixed function (rounding, doubled destination alpha);
  - `gpu/primitives/immediate`: Gouraud ±1 on 960 pixels;
  - `gpu/stencil/writemask`: 4444/5551 increment and decrement.

  In `gpu/` the HLE passes 74 of the 77 tests the CPU renderer passes. Among
  them are texture filtering, mipmaps, the level-of-detail modes, render
  targets and copies. Shader blending made `blend565` and `dither` pass.
- Monster Hunter Portable 3rd, 12000 frames with the state test's menu inputs:
  - The final frame hash is the same as with the CPU renderer.
  - Of the frames at every 1000, 9 are identical. Four menu frames differ in
    73 to 490 pixels (with fixed-function blending: up to 13,692).
  - Flushes went from 2796 to 175 once frames were shown from the renderer
    and watched-page writes stopped flushing (times: see the table above).
- 14 games, 3600 frames each with start/cross presses, frames every 300
  compared with the CPU renderer: at most 34 pixels in a frame differ by more
  than 24 (Dissidia; the rest 0 to 12).
  - God of War: flushes 116,927 → 4,812 with row holds and watch faults; run
    time 54.6 → 25.5–26.2 s (CPU renderer 26.5 s) with render-to-texture,
    which takes 1158 textures straight from target images.
  - Tekken 6's glow (a 128×64 565 target drawn in one pass and sampled in the
    next) needed a full barrier at every pass switch; with it the frame buffer
    at frame 3600 differs from the CPU renderer's in 12,752 pixels by at most
    3 (of 31), as without render-to-texture. At 2× and 4× the glow is
    sampled at the higher resolution, so it differs more from the 1× result.
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
