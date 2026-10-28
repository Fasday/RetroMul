# CPU performance, round 2

Baseline: `pr/psp-core` at `1d5f88f` (includes round 4 / `71e15d5`), merged into `psp/cpu`.
All measurements use release builds. Other workers were benchmarking on the same host (Ryzen 5 7500F).

## Changes

- `PSP.VFPU.Math`: the dot-product accumulator and aligned terms fit in 32 bits. Only the exact
  24-by-24-bit product needs UInt64. A bit scan replaces scanning down from bit 63 after every lane.
  The exponent checks also implement denormal flushing without two extra `VFlush` calls.
- `PSP.VFPU.Fast.inc` and decoder: size-specialized add/subtract/multiply handlers. They check the
  actual S/T/D prefix registers on **every call**, falling back to the complete prefixed implementation.
  Unprefixed operations gather results before writing any lane (overlap is preserved). Scalar arithmetic
  is inlined, removing the per-lane function-pointer call.
- Quad register gathers/scatters, matrix loads, full prefix-latch updates and unprefixed `WriteLast`
  have straight-line common paths. The irregular lane tables and uncommon prefix paths are unchanged.
- COP1 add/subtract: a double sum is exact for single operands within 29 exponents. Beyond that distance,
  the smaller operand supplies the lost residual's sign. This replaces an unconditional two-sum.
  Normal round-to-nearest results can set flags directly. Multiply uses one exact double product,
  rounded to single, instead of doing the multiplication twice. Tiny/boundary/non-nearest cases retain
  the full rounding, flush and flag handling.
- The interpreter dispatch loop is a separate method, outside `Run`'s floating-point-state try/finally.
  Floating-point state is still saved/restored by `Run`; the loop gets better register allocation.
  `clz` uses a bit scan; `bitrev` uses fixed mask/shift stages. `clo` retains its old cheap zero-count path.

No change to `TPSPContext`, handler signatures, instruction cycle accounting, JIT source, or the
integrator's **CurPC + 4** branch/jump targets. No runtime files outside `PSP.CPU*` / `PSP.VFPU*` changed.

## Correctness

- Win64 complete suite, JIT on: **520 PASS / 118 FAIL / 638**.
- Win64 complete suite, JIT off: **520 PASS / 118 FAIL / 638**.
- Both complete reports, including the failure diffs, are byte-identical to the baseline report.
- CPU filter: **54 PASS / 2 FAIL / 56**, with Win64 JIT on/off and the Win32 interpreter.
  Remaining failures are the unchanged `cpu/lsu/cacheop` and `cpu/vfpu/exact`.
- Win32's CPU report is byte-identical to the baseline Win32 CPU report.
- `CPUPerf -diff`: deterministic hashes of one million random dot products, 33 opcode families with
  randomized register mappings, sizes, overlap, exceptional values and prefixes (16,384 states each),
  800,000 COP1 arithmetic states across all modes, and 1.2 million bit-operation calls. Matches the
  saved baseline hashes on Win32 and Win64; the Win64 checked build matches too.
- Every game below has the same final frame hash **and guest cycle count** before/after.

## Handler / interpreter microbenchmarks

`CPUPerf.dpr` and `perfcompare.py`: five alternating baseline/current pairs, median throughput in
millions of calls (or interpreted instructions) per second. Do not treat the last decimal as precise:
unchanged operations also fluctuate with host load and placement.

| Operation | Win64 before -> after | Win32 before -> after |
|---|---:|---:|
| vadd.q | 39.2 -> 98.0 | 44.2 -> 75.2 |
| vmul.q | 41.3 -> 106.4 | 42.9 -> 74.6 |
| vdot.q | 9.56 -> 32.47 | 4.40 -> 24.27 |
| vmmul.q | 0.641 -> 3.145 | 0.260 -> 2.004 |
| vtfm4.q | 1.95 -> 11.24 | 0.975 -> 7.246 |
| add.s | 113.6 -> 212.8 | 65.8 -> 161.3 |
| mul.s | 149.3 -> 243.9 | 94.3 -> 161.3 |
| integer dispatch loop | 130.2 -> 194.9 | 238.7 -> 425.5 |
| clz (19 leading zeros) | 99.0 -> 400.0 | 97.1 -> 434.8 |
| bitrev | 71.9 -> 454.5 | 74.1 -> 384.6 |

## Games

`cpucompare.py BASE NEW --out FILE` runs the same command for each binary:

```
PSPRun.exe IMAGE -frames 3000 -press start@500:6 -press cross@650:6
```

Paired runs alternate A/B order. Times/MHz below are the runner's own output. The first, earlier
unpaired baseline batch was much slower overall; these later paired runs are a better comparison.

| Game | cpu=M, unchanged | Seconds before -> after | Host MHz before -> after | Frame hash, unchanged |
|---|---:|---:|---:|---|
| THUG2 | 1869.6 | 8.49 -> 8.54 | 220.2 -> 218.9 | af6e81caf6b4ce90 |
| Tekken 6 | 106.8 | 58.65 -> 61.90 | 1.8 -> 1.7 | 46f02fa74ba4e47b |
| Daxter | 2018.6 | 207.23 -> 173.08 | 9.7 -> 11.7 | 293dc242672732cb |
| SF DM, pair 1 | 1632.9 | 221.70 -> 285.29 | 7.4 -> 5.7 | c8c1dc5cae62ddfc |
| SF DM, reversed repeat | 1632.9 | 300.15 -> 229.34 | 5.4 -> 7.1 | c8c1dc5cae62ddfc |
| God of War CoO | 651.9 | 667.95 -> 792.31 | 1.0 -> 0.8 | b83717df31a5df93 |
| Star Wars TFU | 647.8 | 146.90 -> 155.70 | 4.4 -> 4.2 | 4c6483003e41a1d5 |

**These do not demonstrate a general end-to-end game speedup.** Several paired runs were slower.
SF DM changed from 22% slower to 31% faster when only the pair order was reversed, with neither binary
changed. Report that variation rather than attributing it to the CPU patch.

Profiles of the prescribed routes explain the limited reach of CPU work: Star Wars has ~84% of non-idle
samples in GE, Daxter ~66% directly in GE plus substantial time in its RTL math helpers (CPU ~2.6%,
VFPU ~0.4%), Tekken is also dominated by GE; THUG2 is mostly AVC/CSC/display in its intro. The renderer
and codecs remain the main costs on these routes.

The Win32 interpreter has a visible game-level gain on two additional paired checks:

| Game / frames | cpu=M, unchanged | Seconds before -> after | Host MHz before -> after | Frame hash, unchanged |
|---|---:|---:|---:|---|
| THUG2 / 3000 | 1869.6 | 14.87 -> 12.15 | 125.7 -> 153.9 | af6e81caf6b4ce90 |
| Daxter / 1000 | 299.9 | 86.76 -> 76.98 | 3.5 -> 3.9 | c89302d744a7083c |

## Reproducing

```
.\tests\cores\psp\run\build.ps1
.\tests\cores\psp\run\build.ps1 -Platform win32
.\tests\cores\psp\run\build.ps1 -Project CPUPerf.dpr
.\tests\cores\psp\run\build.ps1 -Project CPUPerf.dpr -Platform win32
python tests\cores\psp\run\perfcompare.py OLD_CPUPerf.exe NEW_CPUPerf.exe --rounds 5
python tests\cores\psp\run\cpucompare.py OLD_PSPRun.exe NEW_PSPRun.exe --out pairs.json
```

`cpucompare.py` saves completed runs atomically, resumes them after interruption, checks binary hashes
before resuming, records process CPU time as well as wall time, and refuses mismatched game frame hashes
or guest cycle counts. `--reverse` provides the opposite pairing order.
