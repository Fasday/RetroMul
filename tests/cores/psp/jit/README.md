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
