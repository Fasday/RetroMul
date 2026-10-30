# PSP synchronous host-file transfer waits

Follow-up to `6cf9349`. Positive synchronous host-backed file writes now wait for
the drive transfer, using the existing IO latency model. Previously they modified
the host file and returned without ever allowing a ready lower-priority guest
thread to run, despite rejecting a context that could not wait.

Stdout/stderr remain separate console streams, not fake disk transfers. Guest IO
driver callbacks keep their existing path. Invalid/zero-length writes do not gain
an artificial transfer wait. Asynchronous writes already wait on their worker and
are not delayed twice.

The new checked Win64/Win32 fixture starts a lower-priority MIPS probe, snapshots
the caller in the write's `iodev` wait, verifies restored continuation and the byte
count, and confirms that stdout is still nonblocking.

This also fixes a real scheduling problem in the physical-style APCTL offline
test. Its library worker has lower priority than main, so it needs main to yield.
With `--hw`, printf writes a host file; those writes now let the scan worker run.
The measured scan duration and both state-change events match the original PSP
recording. The remaining mismatch is the access-point list: this console has no
discovered APs. None are fabricated and the scan state is not forced to 1 before
the worker runs (the recording explicitly expects state 0 immediately after scan).

## Verification

- Regular suite: **540 PASS / 98 FAIL / 638**, no status regressions. Full JIT/pool
  and interpreter/serial reports are byte-identical.
- Separate full `--hw` profile: **512 PASS / 126 FAIL / 638**. It is not merged with
  regular-profile passes to manufacture a higher score.
- GPU `--check`: **81 SAME / 32 NO_DRAWS**, no differences.
- Checked Win64/Win32 callback/FAT/async/SRC/clock/unload/write fixtures pass.
- Old kind-1 audio and kind-2 MHP3rd imports retain their original Win64 digests.
- MHP3rd frame11000 movie state: **11,266,763 bytes**, second-generation load
  **1098 ms**. Cancellation, fresh/repeated load, 90 full memory/CPU/audio frames,
  live-save preservation, actual guest writes and corruption rejection pass.
- Win64 GUI, Win32/Linux64/Android32/Android64 core compilation and Vulkan worker
  paused/load/error/cancel/active-shutdown tests pass.

The regular score has not increased in this round. Other timing/renderer/CPU/ME
and network gaps, absent-card configuration and filesystem snapshot limits remain
unfinished. No expected outputs, normalization, user settings, firmware data or
commercial images were changed; no `.inc`, pushes or main merges.
