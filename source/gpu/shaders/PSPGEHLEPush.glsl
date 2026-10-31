// Per-draw state of the HLE renderer's pipelines (PSP.GE.VulkanHLE TGEHLEPush).
layout(push_constant) uniform Push {
  // 2 / width and 2 / height of the target in PSP pixels.
  vec2 ndcScale;
  // FLAG_* bits, the colour test function in bits 8-9, the source premultiply
  // in bits 12-13, the target format in bits 16-17, the scale in bits 24-27.
  uint flags;
  // Function in bits 0-2, texture alpha in bit 3, colour doubling in bit 4,
  // the level of detail in bits 5-6 (0 none, 1 from the derivatives plus the
  // bias, 2 the bias, 3 from the slope and w plus the bias), TEX_* bits, the
  // minification filter in bits 8-10, the image's highest level in 13-15.
  uint texFunc;
  uint env;
  uint fogColor;
  // Function in bits 0-2, reference in bits 8-15, mask in bits 16-23.
  uint alphaTest;
  uint colorRef;
  uint colorMask;
  float minZ;
  float maxZ;
  // In 1/16 levels.
  float lodBias;
  vec2 texSize;
  // The 4x4 dither matrix as signed nibbles, row-major.
  uint dither0;
  uint dither1;
  uint fixA;
  float lodSlope;
} pc;

const uint FLAG_TEXTURED = 1u;
const uint FLAG_FOG = 2u;
const uint FLAG_COLORTEST = 4u;
const uint FLAG_ALPHATEST = 8u;
const uint FLAG_RANGE = 16u;
const uint FLAG_CLAMPZ = 32u;
const uint FLAG_CLEAR = 64u;
const uint FLAG_DITHER = 128u;
const uint FLAG_QUANTIZE = 1024u;

const uint TEX_MAGLINEAR = 128u;
const uint TEX_CLAMPU = 2048u;
const uint TEX_CLAMPV = 4096u;
