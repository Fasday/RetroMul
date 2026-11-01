# Hardware probes

Programs that record a real PSP's behaviour for calibrating the core. They
are not tests: their recordings are reference data, kept outside the
repository (they are large) and summarized here. pspautotests' `.expected`
files are never written from them.

## Setup

- A PSP with custom firmware (here a PSP-E1000 on 6.60 PRO-C) running
  PSPLink (`psplink.zip` from the psplinkusb releases, copied to
  `PSP/GAME/psplink`).
- On Windows, the "PSP Type B" USB device needs the libusb-win32 driver
  (Zadig). `usbhostfs_pc` and `pspsh` come from `pspsh-windows.zip` of the
  same releases.
- The PSPDEV SDK (Linux build, here in WSL) for building the probes:
  `build.sh <probe> <out dir>`.

## Running

Start `usbhostfs_pc -b 3000` in a run directory (it becomes `host0:/`; give
it no directory argument on Windows), copy the PRX there and run:

    python hwrun.py --root RUNDIR --results OUTDIR --pspsh PATH/pspsh.exe --timeout 900 "vfpu_sweep.prx"

The same PRX runs in the emulator (`PSPRun prog.prx -frames 200000`), where
`host0:/` is the PRX's directory, so both recordings can be compared.

## Probes

- `vfpu_sweep`: the VFPU function unit's results for every mantissa of [1, 2)
  (vrcp, vrsq, vsqrt, vlog2), [2, 4) (vrsq, vsqrt), [0.5, 1) (vlog2), every
  23-bit fixed-point step of [0, 1) (vsin, vcos, vexp2, vasin) and of
  (-1, 0] (vexp2), and 1M random bit patterns through all 11 functions
  (`sweep/*.bin`, 32-bit little endian results in input order). 35 s on the
  PSP.

- `ge_light`: the GE's lighting, one lit point per pixel with its own
  registers, 65536 samples a frame (`light/*.bin`, 272 rows of 512 8888
  pixels): light x material colour products, emissive plus global ambient,
  the attenuation over every 24-bit float of a range (constant, linear and
  quadratic terms), the diffuse factor, the spot factor and cutoff, specular
  and powered diffuse at several exponents, and their combinations. 5 s on
  the PSP.

- `ge_xform`: the vertex unit's arithmetic through the depth it writes, one
  point per pixel with its own z and matrix registers, 65536 samples a set
  (`xform/<set>_<view>.bin`, the depth buffer through VRAM's mirrors 0, 2
  and 6, plus `<set>_in.bin` with each sample's inputs): the viewport z,
  world-matrix multiply-adds, view after world, perspective, and exact
  readouts (results in [0.5, 1) at viewport scale 65536, centre -32768) of a
  product, a sum, a multiply-add, a dot product and the reciprocal of every
  24-bit w in [1, 4). 4 s on the PSP.

- `ge_zplane`: how the GE interpolates depth over a triangle: through-mode
  triangles, 16 a frame, depth read back through the linear view
  (`zplane/frame_*.bin` with `tris.bin`: random triangles with steep ramps;
  `var_*.bin` with `vtris.bin`: random triangles drawn eight ways, vertex
  order rotated and reversed, depths flipped, mirrored; `tie_*.bin` with
  `ttris.bin`: shared rows and columns, right angles). 7 s on the PSP.

- `ge_lod`: the texture level of detail in slope mode (TEXLEVEL mode 2):
  4 x 4 pixel quads, one w and TEXLODSLOPE each, over an 8-level texture
  whose level k is a solid colour with red 32 k, mipmap-linear, so red is
  twice the level of detail in 1/16 (`lod/w_*.bin`: slope 1 and every 24-bit
  w of [1, 4); `lod/ws_*.bin`: random w and slope; `*_in.bin` the inputs).
  4 s on the PSP.

- `ge_sprite`: where a through-mode sprite samples its texture: a 16 x 16
  texture whose texel (i, j) is red 16 i, green 16 j, bilinear and clamped,
  so red and green are the sample position in 1/16 texels less half a texel
  (`sprite/int.bin`: integer spans, every texel span 1..15 over pixel spans
  1..24; `frac.bin` and `neg.bin`: random fractional and decreasing spans;
  `*_in.bin` the sprites). 1 s on the PSP.

- `ge_line`: which pixels a line covers: through-mode lines, one per 30 x 17
  cell, 256 a frame (`line/<set>_<n>.bin`, `_in.bin` the end points in 1/16
  pixel): random end points, end points on the half-pixel grid, short lines,
  slopes near 1, and antialiased lines with random vertex alpha blended over
  black (`aa_<n>_col.bin` the colours). 3 s on the PSP.

- `ge_patch`: Bezier patches (4 x 4 control points, random divisions) drawn
  as points: 32 a frame, each point on its own pixel centre, the colour and
  depth buffers read back (`patch/<set>_<n>_c.bin`, `_z.bin`; `_in.bin` the
  divisions and the control points' z and colours): one control point set
  (the weights), random depths and colours, and in 3D with z in -1..1 at
  random exponents and signs. 3 s on the PSP.

- `ge_spline`: the same for splines (4..7 x 4..7 control points, random edge
  types and divisions, 16 a frame; `spline/`), the points on a grid that
  sorts by x and y. 5 s on the PSP.

- `ge_clut`: which CLUT entry a texel reads with a CLUT per level (TEXMODE
  bit 8): 8 x 8 through-mode sprites at a constant level, the CLUT's entries
  holding their own index; CLUT4..CLUT32, levels 0..7, CLUTFORMAT shifts,
  masks and offsets, the bit set and clear (`clut/frame_<n>.bin`,
  `cells_<n>.bin` the settings). Frame 2: where a buffer's rows lie for
  widths 1..64, CLUT4..CLUT32, 5650 and 8888. Under a second on the PSP.

- `ge_recip`: the depth plane's reciprocal of the area for every one of the
  2^16 mantissas: one strip triangle per mantissa (area (2^16 + m) * 4,
  480 pixels wide, depth 2000 to 62000), 60 a frame, the depth buffer read
  back (`recip/frame_<n>.bin`, 272 rows of 480). 48 s on the PSP.

- `ge_uv`: which texel a through-mode triangle samples: 16 random triangles
  a frame with float UVs (random fractions, or whole texels) over textures
  of 32 to 512 texels whose texels hold their own coordinates
  (`uv/frame_<n>.bin`, `tris_<n>.bin`). 2 s on the PSP.

- `ge_alod`: the automatic level of detail (TEXLEVEL mode 0): a CLUT4
  texture with a CLUT per level, each level its own red (32 L), linear
  between levels, so red is 32 times the level plus twice its sixteenths;
  16 random triangles a frame, through mode and perspective (each vertex
  its own w), `alod/<set>_<n>.bin`, `_in.bin` the vertices. 3 s on the PSP.

- `ge_tcache`: a sprite textured from the 4444 buffer it draws into (64 x
  64 at VRAM 0x154000, as gpu/exact's texture cache jobs), every pixel
  holding its own index, so each pixel tells which texel it read and
  whether that texel had been drawn yet: 80 cases of one sprite shifted
  against its pixels (1 to 32 in x or y, 16 to 48 pixels), gpu/exact's
  three sprites with and without TEXFLUSH or TEXSYNC between them, and two
  sprites reading each other (`tcache/case_<n>.bin`, `cases.bin`). The
  texture's address must be VRAM's (0x04154000): 0x154000 hangs the GE.
  Under a second on the PSP.

- `exact_dump.sh <test> <out>`: pspautotests' `gpu/exact/<test>` with a job
  runner that also writes every job's readback to `host0:/exact/`. All 131
  jobs of the nine tests give the stored CRCs on this PSP, so the readbacks
  are a pixel-level reference; the same PRX in the emulator gives the
  emulator's.

## Findings (PSP-E1000, 2026-10-31)

- Through-mode positions are truncated to 1/16 pixel (a point at x.97 stays
  on pixel x).
- Bilinear filtering truncates each row's mix before the column mix:
  ((top >> 4) (16 - fy) + (bottom >> 4) fy) >> 4. Every pixel of the
  texture jobs matches.
- A sprite's texture step per pixel is the difference over the length
  truncated toward zero (12 texels over 7 pixels steps a hair under 12/7);
  rounding it moved 20% of a scaled-sprite job's pixels.
- A triangle's fog factor is a plane like the Gouraud colours: each vertex's
  factor clamped to [0, 1] and rounded to 8 bits. Interpolating the
  unclamped factor was up to 127 off where vertex factors lie outside
  [0, 1].
- Gouraud colours and the fog factor are planes exactly like the depth
  (below): the same starting vertex, steps floor(N R / 2^(e + 2)) per 1/16
  pixel in 2^-14 from the same reciprocal of the area, floored at the pixel
  centre and clamped to 0..255. gpu/exact's Gouraud plane jobs (planes
  12-15) and fog jobs (transform 1-4) now match; planes from the lowest
  vertex with an exact division left 0.4-8% of their pixels one off.
- A triangle's depth is a plane from one of its vertices (`ge_zplane`): that
  vertex's depth plus steps per 1/16 pixel in x and y, fixed point with 14
  fraction bits, floored at the pixel centre. The vertex: of those at the
  ends in x (a tie to the upper one) and in y (a tie to the left one), the
  one not between the others on either axis; where two are left, the third
  vertex's side of the line through them picks one. Vertex order, mirroring
  and the depths do not change it; every triangle whose plane goes through
  a single vertex (1,416) fits. The steps are floor(N R / 2^(e + 2)), N the
  depth gradient times the area, R the reciprocal of the area's top 17 bits
  (`ge_recip`, every mantissa): for the mantissa 1 + m / 2^16, a table of
  256 segments of m, node floor(2^27 / (256 + j)) in 2^-11 and slope
  floor(2^24 / (256 + j)^2) in 2^-8 a step, R = (32 node - slope (m & 255))
  >> 8. All 65,536 match; floor(2^32 / (2^16 + m)) was one off for a fifth
  of them (2-4% of pixels a step off). gpu/exact's depth plane jobs now
  match; the core's barycentric depth matched 28-58%.
- Slope-mode level of detail (`ge_lod`) is log(TEXLODSLOPE) - log(1/w) +
  16 (+ bias) in 1/16 levels, each log the exponent and 4 mantissa bits of
  its own float, with 1/w as the pixel interpolates it (the vertices' 1/w
  from the vertex unit's reciprocal table): every sample matches. The core
  took log(slope * w), up to two sixteenths off; gpu/exact's mip slope job
  now matches. The automatic mode (gpu/exact's auto lod job) is likewise
  log(G) - log(Q/w): G the primitive's largest step of S/w or T/w per pixel
  (level 0 texels, one value a triangle), Q/w taken once for 4 pixels of a
  row (x aligned to 4), at the second of them (`ge_alod`: through mode every
  pixel; perspective 85% exact, the rest one sixteenth either way, where
  each pixel's own Q/w gave 75%; gpu/exact's auto lod job from 3,620
  pixels off to 119). The core's per-pixel derivative of S and T was up to
  38 sixteenths off.
- A texture read from the pixels being drawn (`ge_tcache`) goes through a
  texture cache of blocks of 8 rows of 16 bytes (a swizzled block), each
  loaded at its first texel after a TEXFLUSH (TEXSYNC does nothing to it)
  and kept by the primitives after; the pixels' writes reach memory late.
  A cycle model fits: a pixel a cycle, a block load 24, a write in memory
  38 cycles after the last of its row's aligned 4 pixels. It gets 21,288
  of 21,508 pixels the core read wrong (when it read every texel as
  memory held it then), and gpu/exact's texture cache jobs exactly; the
  model does not explain the other 220 (in 10 of the 80 cases). Levels narrower than 16 texels with a buffer width below 16
  read their lower rows elsewhere on the PSP (`ge_lod`'s random set, levels
  4 to 7): rows are at least 16 bytes (`ge_clut`, below).
- Through-mode texture coordinates (`ge_uv`) are planes like the depth's:
  S and T over the texture's width and height, truncated to 15 fraction
  bits (so 15 - log2(size) bits of a texel), the steps from the area's
  reciprocal. 99.98% of 368,000 pixels over textures of 32 to 512 texels;
  the rest a texel up within a few thousandths of the next. gpu/exact's
  quad as a strip now matches.
- Sprites sample the same planes, through V0's corner and the corners
  beside it along x and y, so their steps come from the reciprocal of width
  times height: every sample of `ge_sprite`'s integer spans matches (the
  hardware's one-sixteenth-lower samples below), 99.3% of its fractional
  ones; gpu/exact's scaled sprites job now matches.
- Sprite sampling (`ge_sprite`, before): the core's positions (start plus the
  truncated step times the distance to the pixel centre) match the random
  sets to 99.8% but are one sixteenth of a texel too high on most samples
  that land exactly on a sixteenth (integer spans: 1:1, 2:1 and so on). A
  constant unit off a 16-bit fixed point fits ge_sprite to 95-99.8% but
  breaks gpu/filtering's precision tests (recorded on real PSPs), so when
  the hardware lands lower is not known yet; not modelled.
- Lines (`ge_line`) follow a diamond-exit rule: a pixel is drawn when the
  line leaves its diamond (|x - cx| + |y - cy| < 1/2 pixel): the first
  vertex inside and the last not, or the line crossing it with neither end
  inside; a point on a diamond's edge counts as inside when it lies above the
  centre on x-major lines (|dx| > |dy|) or left of it on y-major ones. Every
  one of the probe's 8,192 lines and gpu/exact's line coverage jobs match
  (the core's centres-between rule missed about one line in ten).
  Gouraud colours step along the major axis: (c1 - c0) * 16 times the
  reciprocal of the length (the depth plane's table reciprocal, of the
  length in 1/16 pixels) per pixel, floored to 10 fraction bits, from the
  first vertex, floored and clamped: every one of gpu/exact's Gouraud line
  channels.
  Antialiased lines replace the fragment's alpha with a coverage from the
  line's minor position in the pixel: ceil(256 f) for f in [0, 1/2], 256 -
  that above, so 128 at the centre, the minor position from the slope
  (minor over the same reciprocal of the length) truncated to 2^-18: 99.5%
  of the probe's antialiased pixels, the rest one off where the coverage
  lands exactly on a step.
- Patches (`ge_patch`, `ge_spline`) are evaluated in steps between
  neighbours: t = i / div in 8 bits, floored from the nearer end (so the
  weights are symmetric), first along v (each column), then along u. Bezier
  curves take de Casteljau's three levels, every step at t; splines de
  Boor's, each step's fraction between its two knots floored from the nearer
  knot (knot k is k - 3, an open end repeating its knot; type bit 0 opens
  the start). A step on floats cuts both values toward zero at the larger
  one's 16th significant bit and floors a (256 - s) + b s over 256 there
  (t = 0 and 1 give the end itself); colours step in 2^-7, floored, and
  round up at the end. A spline segment's far edge is the next segment's
  near one. Every point's depth (through mode and 3D) and colour of both
  probes matches; float weights were up to 120 depth units off. Without
  normals, a Bezier patch's normal is the tangent along u (the last step's
  two values' difference) cross the one along v (gpu/exact's normals jobs;
  the reverse order mirrors them), negated by PATCHFACING.
- A CLUT per level (`ge_clut`, TEXMODE bit 8): level L's CLUT4 index (after
  shift, mask and offset) goes up by 16 L and CLUT8's by 256 L, within the
  CLUT's 512 entries; CLUT16 and CLUT32 are unchanged. Every texel of the
  probe and gpu/exact's clut per level job match.
- A texture row is the buffer width's bytes cut down to a multiple of 16, at
  least 16 (`ge_clut` frame 2: every non-DXT format, widths 1 to 64; width 0
  not recorded). That is also what `ge_lod`'s narrow levels showed.
- Near-plane clipping (gpu/exact's nearclip jobs, fitted through the
  emulator): the intersection is in the vertex unit's arithmetic: the
  distances z + w and their difference as its sums, the fraction their
  quotient by its reciprocal cut to 16 bits, each clip coordinate A + (B -
  A) t from the inside vertex. So the clipped vertices land a hair inside
  the plane (depth 2 to 3 where exact arithmetic gave 0). The polygon left
  starts at the point where its edges come back inside, as a fan; a strip's
  every other triangle has its first two vertices swapped. All clipped
  triangle, rotated order and strip jobs match; the dense and far-inside
  depth jobs keep 10% and 37% of their pixels 1 to 7 off (two vertices
  clipped, the inside one far from the plane; not resolved).
- Without depth clamping, a triangle with a vertex beyond the far plane is
  still drawn when its depth after the viewport lies in 0..65535, and one
  inside the planes whose depth falls outside that range is not; the near
  plane culls. Points beyond the far plane are not drawn.

- The vertex unit (`ge_xform`) works on 16-bit significands: inputs are
  truncated to 16 bits; a product keeps its bits down to 2^(ea + eb - 15)
  (ea, eb the factors' exponents), truncated; a row's terms (three products
  and the term added) are truncated at the quantum of the largest of them,
  summed, and the sum cut to 16 bits. The viewport is the same arithmetic.
  The GE first multiplies view by world with this arithmetic and transforms
  vertices by the result (applying the two in turn misses 20% of the
  view-after-world samples). The core does this: viewport, product, sum,
  multiply-add, dot product and world-matrix sets exact, view after world
  87 of 53,189 off.
- The perspective divide multiplies by a 16-bit reciprocal of w and cuts the
  product to 16 bits. The reciprocal is a table of 128 linear segments over
  w's top 15 mantissa bits, the same in every octave: segment F >> 8 gives
  floor((64 A - S (F & 255) - 1) / 128) in 2^-16, A in 2^-17 and S in 2^-23
  fitted per segment (each segment has exactly one pair that reproduces all
  its 256 recorded values; neither follows a simple formula, so the core
  keeps the measured table). The old model, linear between the exact
  reciprocals, matched 61%. With it the perspective, divide and full
  perspective-path sets are exact.

- Alpha blending multiplies the same way as lighting: each side is
  floor((2c + 1)(2f + 1) / 1024) of the colour and its factor, the sum
  stopped at 255 (gpu/exact's dither and 565 job: all 65,536 colour and
  alpha pairs of source alpha over one minus source alpha; the core's
  (c + 1) f / 256 matched 77%).
- Lighting is an 8-bit pipeline. Factors in [0, 1] (N.L, N.H or N.L raised
  to the shininess, the attenuation, the spot factor) become
  min(255, floor(256 x)). Two 8-bit values multiply as
  floor((2a + 1)(2b + 1) / 1024), so 255 is 1. A light adds
  S * (A * (La * Ma)) + S * (A * (D * (Ld * Md))) and, for specular,
  S * (A * (P * (Ls * Ms))), each product in that order; the colour is
  emissive + Al * Ma plus the lights' terms, stopped at 255. These are exact
  over all recorded samples. The 8-bit attenuation is floor(256 r) with r
  the vertex unit's table reciprocal of den (see the perspective divide
  below): exact over the KA and KC sweeps (the exact 1 / den: 99.75-99.9%).
  With KB the distance's root leaves 0.3% one step off. The distance is the
  root of the squared distance (a 24-bit float) truncated to a 24-bit float;
  the quadratic term uses the squared distance. pow is the piecewise-linear log2/exp2 the core
  already had (100% for exponents 0.5, 1, 2, 10); the spot exponent, like
  the shininess, keeps 4 mantissa bits. The core does all this:
  `gpu/commands/light` passes.

- The stored `cpu/vfpu/exact`, `cpu/vfpu/vector` and `gpu/exact/lighting`
  expectations match this PSP exactly.
- vsin/vcos: from 2^32 on, the angle shifter takes the exponent modulo 32 as
  1 to 32, so 2^32, 2^64 and 2^96 (times any mantissa) give an angle of 0 and
  2^65 behaves like 2^1. The core now does this; random inputs went from 14%
  to 5.6% mismatches (the rest are ±1 in the last bit).
- vasin: a quadratic in each of 128 segments of [0, 1), through the values
  at the segment's ends (the arcsine floored to 2^-30) with a quadratic term
  floored to 2^-26 that wraps modulo 2^-11; segment 0 is a line; the output
  is floored to 2^-30. The wrap hits the last 12 segments (up to 135 times),
  which is why the hardware is up to 0.02 off near 1. The core does this:
  78% of all 2^23 inputs bit-exact (was 68%), none more than two steps off
  (was up to 83,000); random inputs 5.5% -> 0.7% mismatches.
- vlog2: below 1 the result is fixed point with 15 fraction bits; above,
  the fraction has 22 bits and the result keeps 22 mantissa bits (only bit 0
  is always clear, unlike the other functions' two). The core does the first
  two with rounding offsets fitted to the recordings: [0.5, 1) 0.5% -> 87%
  bit-exact, [1, 2) 36% -> 82%, random inputs 24% -> 16% mismatches. From 2
  on the hardware sits about one step below the exact value (a scale of
  1 - 2^-23.7 fits 83%), yet log2(3.5) is exact, so its approximation is
  input-dependent; the core keeps the rounded logarithm there.
- vrcp, vrsq, vsqrt, vexp2: within ±1 in the last of their 22 bits of the
  exact value, with a sawtooth-shaped internal error; the algorithm is not
  known yet.
