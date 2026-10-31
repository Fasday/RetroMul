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

## Findings (PSP-E1000, 2026-10-31)

- Lighting is an 8-bit pipeline. Factors in [0, 1] (N.L, N.H or N.L raised
  to the shininess, the attenuation, the spot factor) become
  min(255, floor(256 x)). Two 8-bit values multiply as
  floor((2a + 1)(2b + 1) / 1024), so 255 is 1. A light adds
  S * (A * (La * Ma)) + S * (A * (D * (Ld * Md))) and, for specular,
  S * (A * (P * (Ls * Ms))), each product in that order; the colour is
  emissive + Al * Ma plus the lights' terms, stopped at 255. These are exact
  over all recorded samples. The 8-bit attenuation is floor(256 / den)
  except that the hardware's reciprocal comes out slightly high: with a
  factor of 1 + 2^-16, 99.9% match. The distance is the root of the squared
  distance (a 24-bit float) truncated to a 24-bit float; the quadratic term
  uses the squared distance. pow is the piecewise-linear log2/exp2 the core
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
