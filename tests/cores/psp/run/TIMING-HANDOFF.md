# PSP scan phase, module completion and test inputs

Follow-up to `4366dcf`. The regular suite remains **540 PASS / 98 FAIL / 638**.
This round fixes narrower defects inside still-failing tests and adds independent
regressions; it does **not** claim another complete hardware test has passed.
Expected files, screenshots, normalization and the 12000-frame budget are unchanged.

## Scan clock

The display no longer resets its physical field origin to the instant the CPU
notices an interrupt. Late delivery advances the existing field edge by the fixed
frame period, so CPU/syscall latency cannot permanently slow the scan clock.
Hcount consequently reflects time since the physical edge, not the late handler.

The new synthetic MIPS fixture delays interrupt delivery by different amounts,
checks hcount and each following field deadline, and saves/restores both before
the interrupt tail and after the delayed fields. Checked Win64 and Win32 pass.
A negative control compiled with the baseline `PSP.Display` unit fails with
`Late interrupt delivery permanently shifted the display scan clock`, as intended.
No random timing jitter was added to match measured min/max buckets.

## Module unload

Clearing a module and its manager bookkeeping are preemptible CPU work, not a
drive wait that donates the whole interval to a worse thread. The unload tail now
uses the existing guest busy continuation. Memory-fill cost is shared with stack
creation rather than making memory clearing free.

The manager's completion handoff permits an equal-priority ready thread to run;
it does not let a lower-priority spinner run while the manager works. This
distinction is observed by both `modules/unloadfill` and `scheduling/syscallkinds`.
A saved `BusyYieldEqual` flag is explicitly optional when importing older thread
records. The guest-probe fixture checks equal/lower-priority behavior and direct
state continuation in the busy tail. Precise unload timing is still approximate.

## IO metadata and permissions

- Async priority accepts user priorities 8..119 or the inherited-priority option;
  kernel priorities are 1..126. Boundary checks no longer accept 127 or privileged
  priorities from a user caller.
- The internal IO worker uses the firmware-observed name, 2-KiB stack and
  origin-dependent system attributes. These are metadata facts, not copied IO
  implementation code. Reference: the public firmware reconstruction's
  [IO file manager](https://github.com/uofw/uofw/blob/4ca58f30b8fdd415483594dfa860bbaa2dc85856/src/kd/iofilemgr/iofilemgr.c).
  No other PSP emulator implementation was consulted or translated.
- Synthesized `.` and `..` entries now contain actual directory timestamps. At a
  mount root, the parent metadata is clamped to that root instead of exposing an
  outside host directory. The fixture distinguishes parent/root timestamps and
  verifies them after direct restore. Host-specific directory size/casing is not
  rewritten to imitate the recording machine.

## Isolated fixture inputs

The runner now stages existing cross-group inputs named by null-terminated path
literals in the actual ELF. It keeps the same suite-relative paths, copies only
inside the source suite and never invents a missing input or changes its contents.
Existing group/local staging remains, so this is not a complete general VFS or a
replacement for an explicit dependency manifest for dynamically constructed paths.

`callcosts` and `syscallkinds` can now load their real sibling module and ATRAC
inputs rather than returning early for absent files. Their remaining failures
are actual timing/CPU-share differences, not silently missing test sections.
This avoids copying the full roughly 124-MiB suite into every run.

Old `__testoutput`, `__testerror`, `__testfinish` and screenshot artifacts are not
seeded as inputs. A GUID in the scratch directory also avoids PID-reuse leftovers.
Original fixtures and user images/fonts remain read-only.

## Verification

- Full suite: **540 PASS / 98 FAIL / 638**, unchanged status set. Complete JIT/pool
  and interpreter/serial reports are byte-identical.
- GPU differential `--check`: **81 SAME / 32 NO_DRAWS**, no differences.
- Checked Win64/Win32 fixtures pass the clock, priority, directory-metadata and
  unload-handoff cases plus the earlier callback/async/SRC/FAT matrix.
- Old kind-1 audio and kind-2 MHP3rd imports retain their original Win64 digests.
- MHP3rd frame 11000 movie state: **11,266,757 bytes**, second-generation load
  **1144 ms**. Cancel/fresh/repeated load, 90 full memory/CPU/audio continuation
  frames, live-save preservation, actual guest writes and corrupt rejection pass.
- Win64 Release GUI, Win32/Linux64/Android32/Android64 core compilation and Vulkan
  worker paused/load/error/cancel/active-shutdown tests pass.

The two callback-aware disabled-context IO rows, measured
timing distributions, renderer/CPU/ME gaps, peer networking and the filesystem
capture limit remain unfinished. No speculative delay-cost changes were kept:
increasing the first-wait check broke the existing `delayzero` oracle and was
rejected rather than accepted to improve a different test.
