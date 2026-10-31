# PSP asynchronous request slot

Follow-up to `c677620`.

A descriptor accepts one asynchronous request at a time. The next request is
refused with `SCE_KERNEL_ERROR_ASYNC_BUSY` (`80020329`) until the previous
result has been collected, not merely completed. Results are collected by
`sceIoWaitAsync[CB]`, `sceIoPollAsync` or `sceIoGetAsyncStat`. Before this
change, a completed but uncollected read/write/seek/ioctl/close result could be
silently overwritten by the next request.

Programs built after SDK 2.60 also cannot close a descriptor synchronously
while it has an uncollected result; older programs still can. Synchronous
read/write/seek remain refused only while a request is actually running. The
iofilemgr control flow came from uofw's factual iofilemgr metadata, which shows
the request semaphore being signalled only on collection. No emulator code was
consulted.

`intr/waits` exercised this directly. Its `sceIoLseekAsync` calls after an
uncollected seek must be refused, so the later `sceIoWaitAsyncCB` with interrupts
disabled collects the first result (`0`) and the next call reports `8002032a`.
The physical-style `--hw` profile now passes against the unchanged recording.

The regular emulator-device profile still differs on these two rows. There,
test output goes through the emulator devctl, which does not block. On hardware,
PSPLink's host output transfer gives the async worker time to run first. That
host transfer is not imitated in the regular profile.

## Verification

- Regular suite: **547 PASS / 91 FAIL / 638**, unchanged status set. The complete
  JIT/pool and interpreter/serial reports are byte-identical.
- Separate `--hw` profile: **520 PASS / 118 FAIL / 638** (was 519); `intr/waits`
  is the only status change.
- The checked Win64 fixture now proves that a new async request after a
  completed but uncollected read is refused, and that a newer program's
  synchronous close is refused before collection; collection then still returns
  the original result. Checked Win32 fixtures pass as well.
- Old kind-1 audio and kind-2 MHP3rd imports keep their original digests.
- MHP3rd frame11000 movie state: **11,266,776 bytes**, second-generation load
  **763 ms**. Cancel/fresh/repeated load, 90 full memory/CPU/audio frames, actual
  guest writes, newer-live-save preservation and corrupt rejection pass.
- Win64 GUI and Win32/Linux64/Android32/Android64 core compilation pass.

No expected outputs, normalization, user settings or images were changed. No
`.inc`, pushes or main merges.
