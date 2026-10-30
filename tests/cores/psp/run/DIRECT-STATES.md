# PSP direct state format and include removal

## Direct state path

`PSP.Console.SaveSnapshot` now first writes a direct state. The new payload
contains compressed RAM/VRAM/scratchpad and a checked graph of device/kernel
state. Loading creates a separate cold console, installs the state and verifies
the complete memory/CPU/scheduler digest before publishing the replacement.
**No guest instructions or controller-history replay run on the direct load path.**

The graph stores object IDs, declared fields and named methods. It preserves
shared references, cycles, ready/wait queues, CPU/VFPU latches, GE lists/partial
primitive assembly, audio buffers, fonts, open-file positions and media objects.
Memory mappings, JIT caches, CPU raster workers and Vulkan resources are rebuilt
or rebound, never read back as saved host addresses.

Collections use their typed constructors and logical elements, not hash-table
internals, comparer pointers or allocator state. The existing MP3 state API is
used for the MP3 decoder. Other admitted data classes use checked field schemas;
only explicitly listed pointer-free records may be copied as POD blocks.
Method callbacks are rebound by declaring type/name and checked parameter/return
types, not code addresses. Interfaces have explicit GUIDs. Opaque anonymous
continuations and non-null host pointers are refused by the direct writer.

`PSP.State.Action` supplies explicit serializable continuations. The converted
operations include short audio/ATRAC/MP3/font/media waits, async IO completion,
controller sampling, DMA, alarms/virtual timers, VBlank completion and GE
signal/finish/interrupt completion. Their timing, queue order and guest-visible
results remain the same; active alarm/timer continuations use guest UIDs so a
deleted object is not dereferenced through an old closure capture.

Parsing, reference/type checks and field staging precede application. Existing
child objects stay alive until all new fields/collections are installed. A failed
load/cancellation never replaces the active game. Open files are reopened in a
temporary snapshot filesystem without truncating the live stick; later guest
writes publish to the original live paths, including after repeated save/load.

### Compatibility and current limits

- Existing reconstruction-format files remain readable.
- For an operation still holding an unconverted anonymous continuation or an
  unsupported state schema, the normal save command retains the compatibility
  replay format **when its original history is available**. The cause is logged;
  `LastSnapshotFormat` distinguishes `direct` from `replay`. This is not a claim
  that every in-flight HLE operation is already directly serializable.
- The direct-only API and file tests never fall back. File-only tests disable
  input recording at construction, so a successful restart cannot use replay.
- A direct file may retain an optional compatibility history; it is not executed
  when loading. It is dropped when necessary to stay inside the payload limit.
- The current filesystem capture is still bounded to 48 MiB / 20,000 entries,
  without symlinks. Direct graph allocation/decompression and payload sizes also
  have explicit limits. Files can contain private savedata and user-supplied PGFs.
- Long quests, all codec/library combinations and network sessions are not yet
  qualified. PGD/NPDRM and authentic PSP secure-save interchange are not added by
  this change. The remaining hardware discrepancies are not declared solved.

## Verification

- Checked graph tests: collection ownership, shared aliases, cycles, an explicit
  continuation chain, symbolic methods, host-only bindings, truncated-file atomicity.
- Checked direct-state continuation tests: DMAC, font/fonttest, font/newlib,
  audio/blocking/channels, utility/savedata/autosave, io/file/rename and
  threads/callbacks/create. The direct format is required by the test environment.
- MHP3rd at frame 1100 with supplied PGFs and a Vulkan source: direct save,
  cancellation, fresh-console and second-generation load, 90 subsequent frames
  matching full RAM/VRAM/CPU/audio, preservation of newer live data during load,
  post-load writes through a relative open file after chdir, and checksum rejection.
  The history-retaining state is about 12.67 MiB.
- Separate-process MHP3rd save/load with input recording disabled matches digest
  `3ccc1e4cadf4e909baa62230df1361a14f608c87cafe5995c2747bea25739f4f`.
  That direct file is 10.33 MiB; measured fresh-process load was 9.38 seconds,
  **including first-time hashing of the complete disc image**. Later in-session
  loads reuse the validated mounted-image digest: the checked second-generation
  load measured **1,179 ms**. Load cost no longer grows with the played history.
- Checked Win64 DMAC direct state loads unchanged in Win32. Per-target core
  compilation covers Win32/Linux64/Android32/Android64, not runtime qualification
  on Linux or Android.
- Worker path: paused save/load and preview, nonblocking polling, error propagation,
  cancellation/resumption and shutdown while an operation is pending, with Vulkan.

The callback/include migration retains the full **534/638** pass set; complete
JIT/pool and interpreter/serial reports match. GPU per-batch differential remains
**81 SAME / 32 NO_DRAWS**, no differences. An additional independent IO fix separates
explicit debug-terminal writes from stdout/stderr: `io/open/tty0` now passes, with
no changes to other IO/audio/font subset statuses or the expected recordings.
The final full suite is **535 PASS / 103 FAIL / 638 total**, without crashes or
timeouts; complete JIT/pool and interpreter/serial reports are byte-identical.

## No textual includes in owned PSP code

The 42 historical PSP/core-test fragments were materialized in their owning
ordinary Pascal sources, preserving the exact expanded declaration/implementation
order. The fragments were then deleted, not renamed to `.pas` and included under
another suffix. The generated SPIR-V words were moved into six real `SPV.*.pas`
units; their words were checked unchanged. Shader generation now writes Pascal
units. Key/JIS/synthetic-fixture generators update marked data sections in Pascal
sources and no longer create include files.

`python tests/cores/psp/run/check_sources.py` rejects `.inc` files and disguised
Pascal implementation imports in the owned PSP sources/tests and affected shader
directories. Unrelated emulator cores were not rewritten.

Shared integration files: `PSP.Console`, `PSP.Kernel`, `PSP.IO`, `PSP.Display`,
`PSP.Loader`, `PSP.Service`, `PSP.Scheduler` (schema only), `PSP.GE/GE.Engine`,
the HLE services owning migrated waits, GUI/terminal project unit lists, and the
shared compute-shader data generator. See the commit diff for the full expanded
source/file-removal list.
