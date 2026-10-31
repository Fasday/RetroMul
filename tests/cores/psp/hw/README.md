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

## Findings (PSP-E1000, 2026-10-31)

- The stored `cpu/vfpu/exact`, `cpu/vfpu/vector` and `gpu/exact/lighting`
  expectations match this PSP exactly.
- vsin/vcos: from 2^32 on, the angle shifter takes the exponent modulo 32 as
  1 to 32, so 2^32, 2^64 and 2^96 (times any mantissa) give an angle of 0 and
  2^65 behaves like 2^1. The core now does this; random inputs went from 14%
  to 5.6% mismatches (the rest are ±1 in the last bit).
- vasin: a quadratic in each of 128 segments of [0, 1); output floored to
  2^-30. Segment 0 is linear. The quadratic term wraps modulo 2^-11 in the
  last 12 segments (it is a field too narrow for them), which is why the
  hardware is up to 0.02 off near 1. The exact node and coefficient values
  are not those of the exact arcsine rounded; not modelled yet.
- vlog2: for results below 0 the result is fixed point with 15 fraction bits
  (magnitude truncated); above 0 it is a 22-bit float. Not modelled yet.
- vrcp, vrsq, vsqrt, vexp2: within ±1 in the last of their 22 bits of the
  exact value, with a sawtooth-shaped internal error; the algorithm is not
  known yet.
