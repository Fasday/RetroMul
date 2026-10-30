# PSP removable-card presence

Follow-up to `fe0a47c`. Card presence is now explicit device state, not a hardcoded
"inserted" devctl reply. The configured card's files are retained when it is
ejected; changing presence does not delete or rewrite the host directory.

## Behavior

- `mscmhc0:` reports inserted 1 / absent 2; FAT readiness reports 1 / 0.
- Removable ms/fatms aliases reject file/directory/stat/create/remove/rename,
  native read helpers and existing read/write/seek transfers when absent.
  Descriptors can still be closed. A queued async read rechecks the medium at
  execution rather than reading a card removed after submission.
- FAT insertion callbacks are retained, notified on a state change and removed
  on unregister. No guest callback is replayed merely by loading a state.
- Savedata uses its existing mode-specific no-medium errors and does not create
  a savedata directory while the medium is absent. An empty runner root cannot
  become an accidental path relative to the host working directory.
- Presence and registered callback IDs are direct-state data. Old IO records
  explicitly default to inserted with an empty registration list.

Configured card contents remain included in filesystem snapshots under the
existing capture policy, even while logically ejected. Restore/reinsertion thus
retains the same configured medium. Switching to different physical media and
PSP Go internal-storage behavior are not claimed qualified here.

## Explicit test condition

The original `utility/savedata/nomemstick` source requests two physical setups:
stick inserted and stick pulled out. Its committed recording is the absent-card
run. The new switches make that setup explicit, without special-casing a test name:

```powershell
python tests\cores\psp\run\autotests.py utility/savedata/nomemstick --no-memstick
python tests\cores\psp\run\autotests.py utility/savedata/nomemstick --no-memstick --hw
```

`PSPRun -no-memstick` ejects the configured card for that process. It does not
modify user settings or the card files. Normal runs still start inserted. The
absent-card case passes against its unchanged original expected output.

The default suite is still **540 PASS / 98 FAIL / 638** with no new status
regressions. The qualified absent-card PASS is kept separate, not added to the
default score or silently selected by the runner.

## Verification

Checked Win64 and Win32 cases pass callback registration/ejection, direct restore
without duplicate notifications, data-preserving reinsertion, ejection during
pending async IO and callback unregistration. The existing callbacks/FAT/async/
SRC/clock/unload/sync-write fixtures remain included.

- Default full suite: **540 PASS / 98 FAIL / 638**, unchanged status set; complete
  JIT/pool and interpreter/serial reports are byte-identical.
- The explicit absent-card test passes Win64 JIT, Win64 interpreter, Win64 `--hw`
  and checked Win32 `--hw`, against the original expected output.
- GPU `--check`: **81 SAME / 32 NO_DRAWS**, no differences.
- Old kind-1 audio and kind-2 MHP3rd imports keep their original full digests on
  Win64 and Win32.
- MHP3rd frame11000 movie state: **11,266,792 bytes**, second-generation load
  **784 ms**. Cancel/fresh/repeated load, 90 full memory/CPU/audio frames, actual
  guest writes, newer-live-save preservation and corrupt rejection pass.
- Win64 GUI, Win32/Linux64/Android32/Android64 core compilation and Vulkan worker
  paused/load/error/cancel/active-shutdown tests pass.

No oracles, normalization, firmware fixtures, `.inc`, pushes or main merges.
