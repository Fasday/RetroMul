# PSP direct-only states: resumable HLE operations

This follow-up completes the persistent callback conversion for the existing HLE
paths. New states are direct-only. `SaveSnapshot` no longer catches a schema/
continuation error and silently writes a reconstruction state. The worker no
longer records controller history or copies the initial stick at boot. A small
mount tracker retains the existing guest-file timestamp/publication behavior.

Old reconstruction files are still imported by the explicit compatibility reader.
Old direct action records may omit the newly added payload fields; only these
explicitly listed optional fields default to empty. Unknown, duplicate or missing
required fields remain errors. Import compatibility is not implemented by
accepting arbitrary record layout changes.

## Converted operations

- Font allocation/free steps, failure rollback, new-library completion, internal
  and user-memory/file opens, streamed PGF open/seek/header/table/read/close,
  cache free/reallocation and library cleanup. Captured headers, arrays, error
  paths and indices are data fields. Temporary parsed fonts have explicit action
  ownership until successfully transferred to the font library.
- Guest IO-driver open/close/exit returns; module read/load timers, start-thread
  exit/delete/status/wakeup and unload delays. Deferred module work identifies
  threads by guest UID instead of dereferencing a deleted closure capture.
- MPEG ringbuffer callback wraps and partial counts; MP4 seek/end/start and
  chunk-read completion.
- Utility dialog initialization/pumped initialization/shutdown/browser phases.
- Network delayed socket events/datagrams, blocking stream/datagram/select/poll
  attempts, timeouts/abort, PDP/PTP operations, ad hoc transitions, APCTL/library
  jobs and scan/game-mode timers. Library-thread jobs now contain named actions;
  partial sends and scatter/gather/select inputs persist as ordinary arrays.

`PSP.State.Action` has arrays, buffers, results, failure continuations and explicit
owned temporaries. These are serialized as data/object IDs and named methods,
not opaque compiler activation records. The kernel rejects new opaque timer,
guest-return, interrupt-return and sub-interrupt completion callbacks. The source
policy checker also detects accidental service timers/exit hooks using closures.

## Movie/codec state

The shared software H.264 decoder's fixed buffers have named array types with
RTTI; no codec algorithm was rewritten. The PSP schema persists parameter sets,
decoded reference pictures, picture order and queued/delayed output. Slice-local
readers and work lists are rebuilt between calls, rather than dumping transient
sentinels/removed reference pointers. A typed constructor factory supplies those
fresh scratch containers; staged graph replacement also releases constructor
children that the incoming state replaces.

Old bound-interface backups remain alive while the displaced graph is released.
This prevents a last interface owner from disappearing before link cleanup during
a repeated graph load. The graph fixture checks constructor-child counts and
forces a duplicate-key failure during installation, not just truncated input.

The existing MDCT transform is admitted as scalar/array state. H.264 SPS/PPS
records are explicitly pointer-free POD; video-frame planes/strides have typed
aliases. No host addresses or GPU/native texture handles are stored.

## Verification

`PSPContinuationTest` uses an independently assembled minimal MIPS ELF and guest
allocator/file callbacks. It saves while the callback is actually pending, not
only after a library test has finished. Each case checks cancellation after graph
installation, immediate restored memory/CPU/audio equality and subsequent frames.

Checked Win64 and Win32 cases pass:

- pending font library/table/cache allocations and frees;
- allocation-failure rollback and owned-PGF allocation failure/cancel cleanup;
- streamed PGF open, prefix read, header-body read and allocated-table chain;
- MPEG wrapped callback and MP4 seek/chunk reads;
- delayed module load, start/exit/delete/wakeup;
- guest driver open/close/exit;
- blocked socket receive/timeout, queued library job/scan timer and utility timer.

`PSPDirectGraphTest` also passes checked Win64/Win32: aliases/cycles/methods,
factory scratch reconstruction, replaced-constructor-child cleanup, old action
payload defaults, required/duplicate/unknown field rejection, installation-failure
rollback and truncated-input atomicity. Its tracked child count returns to zero.
Existing kind-1 audio and baseline kind-2 MHP3rd files still import with their
original complete memory/CPU/audio digests on both Win64 and Win32.

The PGF case accepts user data as an optional argument; none is bundled. Guest
test routines and synthetic ELF are test fixtures, not modified commercial ROMs.

MHP3rd new-character scenario at **frame 11000 during its opening movie**, Vulkan
source, direct-only format: **11,266,224 bytes**. Cancellation, fresh-console load,
second-generation load (**1019 ms**), 90 subsequent full RAM/VRAM/CPU/audio frames,
newer live-data preservation, post-load file writes and corruption rejection pass.
No controller-history replay exists on the new save/load path.

Full hardware-reference suite: **535 PASS / 103 FAIL / 638**, no changed statuses
against the preceding direct-state baseline. Complete JIT/pool and
interpreter/serial reports are byte-identical. GPU differential `--check`:
**81 SAME / 32 NO_DRAWS / 113**, no differences. Win64 Release GUI, core-unit
compilation for Win32/Linux64/Android32/Android64, and Vulkan worker
paused/save/load/error/cancellation/active-shutdown tests pass.

The current 48 MiB / 20,000-entry filesystem capture limit remains. Removing it
through a file overlay is a separate next step. The 103 outstanding hardware
tests, PGD/NPDRM/secure-save interchange and multiplayer are not declared solved.

The authoritative no-`.inc` rule remains enforced; no textual Pascal includes were
introduced. Game images and hardware expected outputs/normalization were not
changed. Work stays on the separate PSP branch without pushes or main merges.

Shared changes: `source/cores/psp/PSP.Console.pas`, `PSP.Kernel.pas`, `PSP.IO.pas`,
`PSP.Loader.pas`, `PSP.State*.pas`; font/media/network/utility HLE owners; and the
array type names in `source/media/video/avc/Video.AVC.H264.pas`. The existing
adapter transport and frontend API remain unchanged.
