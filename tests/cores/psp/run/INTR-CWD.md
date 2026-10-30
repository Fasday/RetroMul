# PSP interrupt-context termination and device-less paths

Follow-up to `0bc09ec`.

## Thread termination from interrupt handlers

The real-PSP recordings of `gpu/signals/*` and `gpu/ge/queue2` call the common
`checkpoint()` helper inside GE signal/finish callbacks. That helper terminates and
restarts an equal-priority probe thread, so the next `[x]`/`[r]` marker shows
whether the probe ran afterwards.

The recordings expect two distinct results:

- SDK 0, 0x01000010 and 0x02080000: the probe does not run after the callback,
  so interrupt-context `sceKernelTerminateThread` succeeded. Restarting it from
  the handler failed, as the vblank/vtimer handler recordings already show.
- SDK 0x03080000 and 0x06060010: the probe still runs, so termination from the
  handler was refused.

The GE firmware driver calls these handlers through sub-interrupt dispatch with no
SDK split in this range. Its only callback-related threshold, 0x02000010, controls
the list-PC argument. The split therefore belongs to thread termination. In the
kernel, interrupt-context termination is now allowed below SDK 3.00 and refused
from 3.00 on. The recordings only narrow the cut-off to somewhere in
(0x02080000, 0x03080000]; the choice of 3.00 inside that range is an assumption.
Starting a thread from an interrupt remains refused for every SDK.

This makes `gpu/signals/continue`, `handlercalls`, `pause`, `pause2`, `suspend`,
`sync` and `gpu/ge/queue2` pass against their unchanged recordings.

`gpu/ge/get` still fails on its remaining `[r]` markers. The hardware completes
about 209 register commands before the next `sceGeListSync` call, but this
emulator's GE needs about 3.4 µs, more than the time between enqueue and sync.
No recording measures GE command throughput, so the cost model has not been
retuned.

## Paths without a device

The iofilemgr joins any path without a device to the current directory, even
when the path starts with a slash. Only one doubled slash is merged; nothing
switches to the device root. A directory change stores the joined path without
checking that it exists. So with the current directory at `ms0:/PSP/`,
`sceIoChdir("/PSP")` leads to `ms0:/PSP/PSP`, and a following `/` stays there.
`Resolve` now uses this rule, matching the `io/io/io` recording for SAVEDATA/PSP.

A mounted device root now exists even when no host directory backs it.
`flash0:/` lists its `.` and `..` entries. Directories below a root are still not
invented. `io/io/io` now differs only in `io.elf` and `io.o`, two build files
that were in the recording's host folder and are absent here.

A generated `tests/io/file/workdir/testfile`, left from an old non-isolated run
and ignored by the suite's own `.gitignore`, was removed from the local suite
checkout. Without it, `io/file/file` no longer starts from stale data. That test
still depends on host permission bits/dates and on POSIX rename/remove of an open
host file. Neither is faked.

## Verification

- Regular suite: **547 PASS / 91 FAIL / 638** (was 540), seven new passes, no
  status regressions. The complete JIT/pool and interpreter/serial reports are
  byte-identical.
- Separate `--hw` profile: **519 PASS / 119 FAIL / 638** (was 512). It is not
  combined with the regular score.
- GPU `--check` after the kernel change: **81 SAME / 32 NO_DRAWS**.
- Checked Win64 and Win32 fixtures pass, including a new case: slash-led paths
  continue the current directory, chdir does not check existence, the mounted
  flash root lists only `.`/`..`, and missing flash subdirectories stay missing.
- Old kind-1 audio and kind-2 MHP3rd imports keep their original digests on
  Win64 and Win32.
- MHP3rd frame11000 movie state: **11,266,788 bytes**, second-generation load
  **760 ms**. Cancel/fresh/repeated load, 90 full memory/CPU/audio frames, actual
  guest writes, newer-live-save preservation and corrupt rejection pass.
- Win64 GUI, Win32/Linux64/Android32/Android64 core compilation and Vulkan worker
  paused/load/error/cancel/active-shutdown tests pass.

No expected outputs, normalization, user settings or images were changed. No
`.inc`, pushes or main merges.
