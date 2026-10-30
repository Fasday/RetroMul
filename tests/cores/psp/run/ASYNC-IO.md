# PSP asynchronous IO scheduling and refused SRC waits

Follow-up to `03a8009` (539/638). The regular hardware-reference suite now reaches
**540 PASS / 98 FAIL / 638**, with no previously passing case lost.
`threads/scheduling/dispatch` is the new PASS. Oracles and normalization are
unchanged; emulator-device and `--hw` profiles are not combined.

## Asynchronous file operations

Previously a host read/write/seek happened at submission and a timer later marked
its result complete, regardless of whether an IO thread could have run. Each
descriptor now owns a guest `SceIoAsync` worker, executing a small internal syscall
stub through the ordinary CPU and kernel scheduler. No native host thread or
closure is retained in the state.

Open, close, read, write, seek and ioctl requests are explicit named actions with
captured virtual paths and guest arguments. The worker waits for the transfer
deadline, performs the request, publishes its result and parks. A timer makes the
worker runnable; it does not perform a host transfer while dispatch/interrupts
prevent the worker from executing. Paths are resolved when queued, not against a
possibly changed current directory at completion.

Creating the worker resumes thread dispatch without enabling CPU interrupts, as
the existing ThreadMan creation behavior does. Async priorities are no longer an
ignored call. The SDK explicitly exposes the IO worker priority API; reference:
[PSPSDK file IO declarations](https://pspdev.github.io/pspsdk/pspiofilemgr_8h.html).
The implementation is independently authored, not taken from another emulator.

Waiting/polling consumes a completed result. The retry after a guest callback also
consumes it, including a close or failed open. Worker stacks, timers and file
descriptors are released on collection/close, reset and console destruction.
Invalid transfer buffers do not schedule enormous transfers or allocate a host
buffer from an unchecked 32-bit byte count.

USB-host sync file calls retain their bridge failure (`ffffffff`) in a disabled
dispatch context; FAT/UMD calls keep the distinct kernel cannot-wait error. An
interrupt remains an illegal context.

## Direct states

Worker UID, priority, deadline and pending action persist as ordinary typed state.
New fields are explicitly optional when reading older direct IO records. Old
timer-only records have a controlled completion path; new states do not replay
inputs or store host addresses, code pointers, native handles or JIT caches.
No new external root binding is inserted into the direct graph.

The expanded `PSPContinuationTest` checks:

- queued open, delayed read and completed-but-uncollected result states;
- no buffer change before transfer completion;
- queued write restore/cancellation without touching newer live data;
- result consumption and signed 64-bit failure results;
- result completion while the caller waits inside a delayed guest callback;
- close collection on callback return, without retaining its descriptor/worker;
- priority changes, pending close and failed-open cleanup;
- invalid-buffer rejection without modifying the host file.

These extend the existing pending font/PGF, driver, MPEG/MP4, module, network,
utility and FAT fixtures. They use independently assembled MIPS routines and
temporary data, not modified game images or bundled firmware fonts.

## SRC failure state

SRC rejects an interrupt before submission. A descriptor submitted with thread
waiting disabled is not silently undone when its wait is refused. Two such
submissions fill the existing two-descriptor DMA queue; a separate failed-wait
lock protects it until DMA retirement. It does not retain a pointer to a thread
which never actually entered a wait. The new flag has an explicit old-state
default, and its pending/full-queue states have direct save/load/cancel tests.

The corresponding SRC rows in `intr/waits` now match hardware. That test still
fails on two callback-aware async-wait rows with interrupts/dispatch disabled;
this is not claimed solved.

## Verification

- Final full suite: **540 PASS / 98 FAIL / 638**, no status regressions versus
  `03a8009`. Complete JIT/pool and interpreter/serial reports are byte-identical.
- GPU differential `--check`: **81 SAME / 32 NO_DRAWS**, no differences.
- Checked Win64 and Win32 fixtures pass all the new worker/transfer/result/
  delayed-callback/close-cleanup/SRC states, including restored continuation and
  cancellation. The existing PGF/driver/media/module/network/FAT cases still pass.
- Old kind-1 audio and kind-2 MHP3rd states import on both Win64 and Win32 with
  their original full memory/CPU/audio digests.
- MHP3rd frame 11000 during its opening movie: direct state **11,266,381 bytes**,
  second-generation load **771 ms**. Fresh/repeated load, cancellation, 90 full
  RAM/VRAM/CPU/audio frames, actual guest writes, newer-live-save preservation and
  corruption rejection pass.
- Win64 Release GUI, Win32/Linux64/Android32/Android64 core compilation and Vulkan
  worker paused/load/error/cancel/active-shutdown tests pass.

This remains an incremental implementation. Exact IO priority/device timing and
multi-consumer corner cases are not fully qualified. The other accuracy failures,
ME/cache/VFPU/GE gaps, peer networking and filesystem capture's 48 MiB / 20,000
entry limit are not declared finished. No `.inc` or disguised textual includes,
oracle changes, pushes or main merges.
