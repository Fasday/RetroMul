# PSP accuracy follow-up: FAT and blocking contexts

Baseline: `bdc92de`, 535 PASS / 103 FAIL / 638 in emulator-device mode.
This is an incremental accuracy round, not a claim that the core or all tests
are complete. Expected outputs, screenshots and normalization are unchanged.

## Fixes

- Memory-stick FAT short names: preserve guest creation order and per-directory
  collisions, resolve case-insensitive long/8.3 paths, implement the pre-3.08 and
  current `sceIoDread` private layouts, reuse deleted aliases and preserve child
  aliases through directory renames. The name table uses root-relative keys and
  is part of direct states; older IO records may omit only that new field.
  Host0 is not incorrectly given FAT short names.
- Unresolved imports return `8002013a`, not fake success. Kernel 6.6x module
  load/unload NIDs resolve to the existing user-library implementations without
  shifting the syscall table. The isolated runner includes sibling PRX fixtures
  instead of allowing absent fixture loads to look successful.
- Reject blocking file open/read/write, SAS synthesis and module start/stop in
  invalid interrupt/dispatch contexts before their side effects. Preserve the
  APIs' distinct errors. MPEG creation and ATRAC reinitialization retain their
  library-specific context errors. Controller reads and vblank waits reject an
  interrupt, while valid display-mode configuration can succeed without waiting.
- Correct the volatile-memory service's dispatch check and the interrupt-context
  check for `sceIoGetAsyncStat`, including its polling variant.

`PSPContinuationTest` now dispatches by `HLE.Call`, not by directly invoking a
handler whose forwarding alias requires a current syscall name. Driver cases
explicitly require a pending guest callback. Its FAT case checks both private
layouts, aliases after direct restore, pending directory enumeration, deletion /
reuse and a directory rename. No firmware font data is included.

## Test duration and profiles

The old 1200-frame budget stopped the message-dialog test before its final two
scenarios. With enough frames it matches the original hardware output, without
a core or expected-output workaround. The default budget is now 12000 frames;
programs still stop at normal exit and the host timeout remains unchanged.

The regular profile reaches **539 PASS / 99 FAIL / 638**, with no formerly passing
test lost. Three new core PASS cases are `io/shortname`, `modules/unresolved` and
`intr/delays`. The fourth is the now-completed `utility/msgdialog/dialog` case.
The old 1200-frame profile is retained as a separate comparison, not conflated
with a core timing improvement: **538 PASS / 100 FAIL / 638** at that budget.

Some GPU screenshot mismatches are startup-environment differences: only the
alpha/stencil bits of the debug banner in the first eight rows differ. The guest
takes a different startup path with the emulator device present. For example,
`gpu/commands/cull`, `gpu/primitives/points` and `gpu/vertices/colors` pass in
`--hw` without any renderer change. This is not fixed by masking alpha, painting
the expected banner or silently changing profiles for individual tests.

The full `--hw` run is **511 PASS / 127 FAIL / 638** and remains a separate result.
It is not combined with regular-profile passes to manufacture a higher score.
Actual raster/lighting precision failures still remain.

The complete interpreter/serial and JIT/pool reports are byte-identical, with no
baseline PASS lost. GPU differential `--check`: **81 SAME / 32 NO_DRAWS**, no
differences. Win64 Release GUI, Win32/Linux64/Android32/Android64 core compilation
and Vulkan worker paused/load/error/cancel/active-shutdown tests pass. Checked
Win64/Win32 callback/FAT fixtures pass. Old kind-1 audio and kind-2 MHP3rd snapshots
import with their original memory/CPU/audio digests.

The live-game state fixture now performs its file writes in a small, independently
assembled guest thread. Calling a blocking handler from the host while the guest
was idle was not a valid syscall context; the new kernel guard correctly rejected
that old fixture. The helper allocates guest code/data and leaves an actual open
file in the graph, without changing the image or weakening the context guard.

MHP3rd at frame 11000 in its opening movie: direct state **11,266,258 bytes**,
second-generation load **777 ms**. Cancellation, repeated/fresh load, 90 full
RAM/VRAM/CPU/audio continuation frames, newer-live-save preservation, guest writes
and corruption rejection pass. Frame-zero live-game state tests also pass checked
Win64 and Win32.

## Still unfinished

The remaining cases include real implementation gaps (cache alias/writeback,
VFPU/GE precision, scheduling, JPEG/ME behavior and networking), not only test
setup. Peer tests need coordinated peers; UMD tests require a mounted disc;
font/system-parameter/host metadata recordings depend on the original external
data and configuration. None is made green by changing the oracle or user
settings. Filesystem snapshot capture still has its 48 MiB / 20,000-entry limit.
Folder mounts do not contain original FAT directory metadata; aliases of
pre-existing host files are initially seeded from host enumeration. Guest-created
alias allocation and its save-state persistence are the behavior qualified here.

Work remains in the separate PSP worktree. No `.inc` or disguised textual
includes, modified commercial images, bundled PGFs, pushes or main merges.
