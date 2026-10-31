# Allegrex recompiler tests and round-2 measurements

Snapshot merged: `pr/psp-core` at `8c8f791` (merge `cd8719f`). This is a fixed
snapshot, not the newer integration-round-4 build described in the workers' notes.

## Run

```powershell
.\tests\cores\psp\jit\build.ps1
.\tests\cores\psp\jit\bin\Win64\PSPJitTest.exe 1000
.\tests\cores\psp\jit\bin\Win64\PSPJitTest.exe 0 bench
.\tests\cores\psp\jit\build.ps1 -Platform Linux64
.\tests\cores\psp\jit\build.ps1 -Platform Win32
python tests\cores\psp\jit\t24_check.py
python tests\cores\psp\jit\t24_check.py --win32
python tests\cores\psp\jit\game_compare.py
python tests\cores\psp\jit\display_check.py
.\tests\cores\psp\jit\baseline.ps1                 # PSPRun at 8f60810 (+ the pool statistic)
python tests\cores\psp\jit\emuspeed.py --before tests\cores\psp\jit\bin\baseline-8f60810\PSPRun_win64.exe --rounds 2
python tests\cores\psp\jit\emuprof.py Tekken_6 --frames 7000 --skip 50 [--lines ROUTINE] [--callers ROUTINE]
python tests\cores\psp\jit\disasm.py TPSPGEEngine.ClipPosition
```

`PSPJitTest` compares the interpreter with native generated code and HW.JIT's
Pascal model, including the complete context, COP0, exposed VFPU condition hazard
state, CurPC, Stop, returned cycles, memory faults and the syscall log. The log
includes a GPR/HI/LO hash at each syscall. All RAM, VRAM and scratchpad bytes are
compared. The private FPU condition hazard is exercised through BC1 instructions.

Two-thirds of the random programs install synthetic VFPU handlers which can
inspect CurPC/PC/NPC, take/add cycles, stop, move PC or store into code. The rest
use the real VFPU decoder (including scalar moves, prefixes, scalar/quad memory
instructions, MFVC/MTVC and branches). Stores may overwrite the next instructions;
segment aliases, page ends, ERET, JR low bits, likely branches, nested delay-slot
branches and short budgets are included. Runs also switch the recompiler off/on.

There are also:

* 400 directed branch pairs (BEQ/BNE and likely, BLTZ/BGEZ, BVF/BVT and likely,
  four input states), both branches targeting the same label from **their own**
  CurPC + 4. They assert use of the interpreter fallback and compare budgets
  ending before, within and after the pair.
* 256 directed real-VFPU cases covering all scalar indices, both quad layouts,
  page crossings, unmapped memory, unconsumed prefixes and self-rewriting SV.Q.
  A store's four writes must all finish even if the first invalidates its block.

## Results (2026-10-28)

* Win64: **1,000 random programs + 656 directed cases, no difference** between
  interpreter, native and model. Random programs used 53,928,696 returned cycles
  per core (these include extra HLE costs and exclude cycles already taken by
  handlers). Native and model each compiled 289,740 blocks and entered generated
  code 4,059,764 times, including the directed cases. 139 random programs ended in
  matching guest faults, principally from self-modified instructions.
* Linux64/SysV under WSL: **300 random programs + 656 directed cases, no difference**
  between interpreter, native and model.
* Win32: **300 random programs + 656 directed cases, no difference** between
  interpreter and model. Production Win32 uses the interpreter, not native JIT.
* Full pspautotests, rebuilt headless runner, `--jobs 4`: **467 PASS, 171 FAIL / 638**
  with JIT off and on; the entire final reports were identical. This includes the
  CPU/thread comparison. The previous round's delayed background run had been
  52 PASS, 551 FAIL, 35 CRASH / 638 on both, and 22 PASS, 162 FAIL, 34 CRASH / 218
  for cpu/threads in both model/off modes, before integrating the other workers.
* `run/build_targets.ps1`: all units compile on Win32, Linux64, Android32 and
  Android64. The script reports the pre-existing unavailable link dependencies:
  Linux's `-lgcc_s`, Android's `ldandroid.exe`. It intentionally accepts these
  link-only failures. The differential-test Linux64 build links successfully
  using the GCC library path from `jit/build.ps1`.
* Actual GE vertex arithmetic (`t24_check.py`, extracted from PSP.GE.Engine, not
  a duplicate candidate): **50,000,000 pairs on each of Win64 and Win32, zero
  differences** versus the previous Frexp/Int/Ldexp implementation. Normal and
  subnormal doubles, single-derived values, infinities, NaNs, cancellation and
  extreme exponents are covered. NaNs are compared as NaNs; all other results,
  including signed zeros, are compared by bits. Win64 Add24: 78.6 -> 9.8 ns;
  Win32: 120.3 -> 40.4 ns in the recorded run.

## Speed round: the emulator thread (2026-10-28, after merging pr/psp-core 8f60810)

With the CPU raster in a background pool, the emulator thread (guest CPU, HLE,
GE commands and vertices, display conversion, media) is the other limit.

**Method.** `baseline.ps1` builds 8f60810 with only the pool's "helping the pool"
statistic added. `emuspeed.py` runs each game headless with PSPAdapterRun
`-mash`'s presses at 60 frames a second (Start/Cross every 75 frames from 480 to
2160, then Cross every 102 frames to 2820; Tekken 6 is in an arcade battle from
about frame 3600). Tekken runs 6,000 frames and the others 3,600, with a frame
hash every 200. **Own cpu** is the emulator thread's CPU time (GetThreadTimes)
minus the time it spent drawing for the CPU renderer: bands while it waits for
the pool, plus small batches. Old and new alternate, two rounds per game, one
game at a time on the shared machine. Every run of a game must give the same
frame hashes and the same guest cycles.

| Game | Own cpu before (runs) | After (runs) | Median speed-up | Hashes, guest cycles (all runs identical) |
|---|---:|---:|---:|---|
| Tekken 6 (battle) | 56.01, 53.46 s | 34.45, 33.43 s | **1.61x** | 30, 1738.8M, `d72283b87b407db4` |
| GTA LCS (prototype) | 109.03, 101.23 s | 68.02, 68.08 s | **1.54x** | 18, 1048.4M, `dc18ddd5e351eaca` |
| SF DM | 9.36, 6.94 s | 6.95, 3.85 s | 1.51x (noisy) | 18, 1720.8M, `8490408262f24e88` |
| Daxter | 35.27, 35.33 s | 24.54, 25.80 s | **1.40x** | 18, 1929.6M, `52ad2bfe0448468b` |
| MGS PW | 8.34, 7.73 s | 5.72, 6.98 s | 1.27x (noisy) | 18, 173.1M, `566cbf744b2c9949` |
| God of War | 23.44, 25.60 s | 20.47, 21.82 s | 1.16x | 18, 308.3M, `a9477253632aa047` |
| GTA VCS | 67.25, 68.63 s | 59.89, 58.27 s | 1.15x | 18, 2283.3M, `bdacaf1ffd4615dc` |

Wall times moved with the machine's load (GPU worker runs at the same time). An
earlier quiet single run measured Tekken at 76.6 -> 65.6 s wall and Daxter at
39.4 -> 29.6 s. God of War, GTA VCS, SF DM and MGS PW stay bound by the CPU
raster pool: the emulator thread mostly helps or waits for it, and that code
belongs to the GE worker. God of War's movies (H.264, about 12% of its samples)
are spread over many decoder routines and were left alone.

**What changed** (Tekken battle profile before: Add24 7%, ClipPosition 7%,
Workers.Add 4.5%, Light 4%, DecodeVertex 3.6%, Render 2.3%):

* Vertex arithmetic without RTL helpers. Add24's fast path is inline, including
  its zero cases. Recip24 builds Frexp's mantissa and exponent, and Ldexp's power
  of two, from the bits. FloorInt, MaxS/MinS, and GEPow without Floor/Ldexp.
  Special values still go through the former code (Add24Slow, Recip24Slow,
  T24Special).
* Matrices, viewport and bones are decoded once per primitive (PrepareGeometry,
  PrepareBones), kept while the registers compare equal. ClipPosition uses the
  rows in that form. On Win64, `Rows24Fast` and `Port24Fast` (assembler) run the
  matrix rows and the viewport in registers. They return False on anything
  outside the fast range, and then the Pascal versions run.
* Lighting: the setup is kept while its registers, MXCSR and x87 control word
  compare equal. A directional light's vector and half vector are made once.
* DecodeVertex reads RAM directly where TPSPMemory maps it linearly. Fixed-point
  fractions multiply by exact powers of two, and the vertex is zeroed without
  REP STOS. Strips and fans index a ring instead of moving vertices.
* BuildRaster keeps FRaster while the 77 registers it reads, the VRAM layout and
  the texture host pointers are the same. The CPU queue then neither copies nor
  compares the state again. ImmediateVertex, which edits FRaster afterwards,
  forces the next build.
* TGEWorkers.Add bookkeeping only. A state's texture analysis is done once per
  state, a target that grows holds only the new pages, and the previous
  primitive's watched ranges are not looked up again. The flush, band and
  exactness rules are untouched.
* TPSPGE.RunHW fetches display-list words directly from RAM, which is the same
  memory Read32 maps; RAM pages are never held.
* Display.Render converts 8888 pixels two at a time in a UInt64, and 16-bit
  pixels through per-byte tables.

**Exactness evidence.**

* All 7 games: identical frame hashes and guest cycles in every run, old and new.
* `queuecheck.py`: 7/7 SAME (serial vs pool).
* GEWorkersCheck: PASS.
* `t24_check.py`: 50,000,000 pairs, 50,000,000 Rows24 rows and 37,500,000 Port24
  values on each of Win64 (a quarter to a third of the batches in assembler, the
  rest through the Pascal fallback) and Win32, 0 differences against
  Frexp/Int/Ldexp/Floor/Math.Max/Min and the former Row24/Row24P on register
  values.
* `display_check.py`: all 3 x 65,536 16-bit values and 1,000,000 8888 pairs, 0
  differences.
* PSPJitTest 300: no difference.
* pspautotests: 527/638 with the same status set JIT on and off, and the full
  report identical to the baseline exe's.
* `run/build_targets.ps1`: Win32, Linux64, Android32 and Android64 compile.

**Shared files changed:** `PSP.GE.Engine.pas` (vertex pipeline, BuildRaster key,
RAMBase), `PSP.GE.Workers.pas` (Add's bookkeeping and the help statistic only),
`PSP.GE.pas` (RunHW's list fetch), `PSP.Display.pas` (Render). Not touched:
PSP.GE.Raster/Texture/Pixel*.inc, PSP.GE.VulkanLLE*, shaders, VFPU handlers, HW.JIT.

## Native CPU-only improvement

The new inline operations are LV.S, SV.S, LV.Q, SV.Q, MFV and MTV. Prefix/control
moves and arithmetic still call the interpreter. Quad fast paths do one
translation for all four lanes; code-page writes and crossings call the entire
original handler. They are selected only when the real VFPU decoder is installed.
No HW.JIT operations/backends were changed.

A paired `bench` run using the same current test source and the pre-VFPU-inline
`b4cd269` JIT unit in a temporary first search directory:

| VFPU memory/move loop | Before | After |
|---|---:|---:|
| Interpreter | 165.5 M instructions/s | 158.3 M instructions/s |
| Native recompiler | 305.6 M instructions/s | 1,947.6 M instructions/s |
| Model | 10.9 M instructions/s | 19.4 M instructions/s |

The native VFPU loop improved **6.37x**. Independent integer/memory and
call/multiply loops also remain in the benchmark; their code was not changed by
this optimization.

## Games: 2,400 frames, identical guest work

Each run used exactly:

```
-frames 2400 -press start@500:6 -press cross@650:6 -press cross@800:6 -press start@950:6 -press cross@1100:6
```

All runs below completed 2,400 frames / 42.03 guest seconds. MHz is the runner's
million guest cycles per host second, including HLE costs. Before is the merged,
JR/COP0-corrected round-2 baseline, before the vertex-arithmetic and VFPU-inline
optimizations. After includes both optimizations.

| Game | Before JIT: seconds / MHz | After JIT: seconds / MHz | After interpreter: seconds / MHz |
|---|---:|---:|---:|
| Tony Hawk Underground 2 Remix | 95.88 / 26.9 | 64.12 / 40.3 | 74.86 / 34.5 |
| GTA VCS | 191.55 / 6.8 | 129.50 / 10.1 | 85.98 / 15.2 |
| GTA LCS (2005 prototype) | 595.98 / 1.8 | 337.18 / 3.2 | 268.14 / 4.1 |
| FF IV TCC | 55.18 / 12.3 | 42.32 / 16.1 | 38.95 / 17.5 |
| Lumines | 80.78 / 19.1 | 60.70 / 25.4 | 52.75 / 29.3 |
| Syphon Filter DM | 351.11 / 4.6 | 210.32 / 7.7 | 219.00 / 7.4 |

**These are observed sequential wall times on a shared host, not controlled
speedup ratios.** Other workers caused large variations (even interpreter-vs-JIT
order reversals). Do not attribute all end-to-end differences to the JIT: the
GE vertex arithmetic is the larger measured host bottleneck. Runs interrupted
by restarts or host out-of-memory conditions were excluded.

Final frame hashes and printed guest cycle totals were identical in all three
runs (before/on/off) for each game:

| Game | Hash | Million guest cycles |
|---|---|---:|
| THUG2 | `7708863a19fca5e7` | 2580.9 |
| GTA VCS | `a4f73e7b5481d8dc` | 1306.4 |
| GTA LCS | `904a1da66d7ea837` | 1092.8 |
| FF IV | `2be8223269daeefc` | 680.7 |
| Lumines | `9af8af247241ae43` | 1544.5 |
| SF DM | `c4bf310f8e159b33` | 1628.4 |

`game_compare.py` reproduces the input sequence and performs these completion,
hash and guest-cycle checks; `--before older.exe` adds a baseline executable.

## Where host time went

Ran the provided `hostprof.py --seconds 30` on all six games. It samples every
thread: three waiting helper threads accounted for 75% of the raw samples.
Additional main-thread-only samples avoided counting those waits as CPU work.

Before the vertex change, GTA VCS's busy thread spent 48.0% in GE routines and
48.3% in RTL (mostly Frexp/Ldexp and double helpers called by GE vertex arithmetic).
THUG2 was 65.3% GE + 28.7% RTL; SF DM and FF IV were overwhelmingly raster/texture
work. Typical non-GE costs were:

* Generated CPU code: about 0.5-2.5% of main-thread samples.
* VFPU: about 1.5-1.8% before vertex optimization; VSum4 dominated it.
* Block lookup/dispatch/interpreter: about 0.1-0.5%.
* HLE/kernel: sub-percent (THUG2 about 0.9%); memory fallbacks negligible.
* No sustained invalidation churn: zero dropped blocks in VCS/FF IV/Lumines/SF DM;
  33 in LCS and 1,293 in THUG2 over the full run.

The vertex change replaces normal-double truncation/exponent extraction and
aligned 16-significand-bit addition with integer bit operations. Exceptional
values/exponents retain the original fallback, including the Single-overload
range of Ldexp(1, ..). It touches **only T24, Exp24, Add24 in PSP.GE.Engine.pas**;
no triangle/pixel/texture rasterizer or guest arithmetic semantics were changed.
Afterwards VCS main-thread sampling was 82.9% GE, 7.2% RTL, 5.6% VFPU and 2.4%
generated code. The remaining big bottleneck belongs to the GE worker.

## Changes outside this directory / PSP.CPU.JIT

In this round, the only new shared-file edit is `source/cores/psp/PSP.GE.Engine.pas`
(the three vertex arithmetic fast paths above). CPU/Console/Memory hooks from
round 1 were preserved through the merge, not expanded or rearranged. Project-list
merge conflicts kept the integrator's unit lists including PSP.CPU.JIT. No changes
to HW.JIT or to PSP.CPU/FPU/VFPU handlers.
