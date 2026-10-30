# PRX replacement and Monster Hunter Portable 3rd

The previous AES/PRX implementation was replaced, with no legacy fallback.
Reference sources and numeric key provenance: `source/cores/psp/PSP.Crypto.md`.
All fixtures in `PSPCryptoFixtures.inc` are synthetic, not game data.

The geometry follow-up is in `GE-REGION.md`: an independent raster-clipping
defect was subsequently found and fixed. Its corrected game hashes supersede
the crypto-only game hashes below; the decrypted ELF hashes remain unchanged.

## Verified

- **97** encrypted modules that the preceding binary decoded have the exact
  same decrypted SHA-256/size. All **101** inspected encrypted modules now
  authenticate and decode: the added successes are MHP3rd's main D91681F0
  executable and three ECDSA-signed updater modules.
- MHP3rd main ELF: **2,247,320 bytes**, SHA-256
  `755e5d84262c3bb30635b32deffab11a66de118f501e4ac105f503308be8b950`.
  The outer SHA-1 and both KIRK ECDSA signatures verify; no signature bypass.
- `PSPCryptoTest`, Win64 and Win32 checked builds: AES known answers, all four
  NIST CMAC cases, independent CBC/PRX/KIRK/Pauth fixtures, corrupt/truncated
  inputs, bounded gzip, guest HLE success/failure and atomic output all pass.
- Full pspautotests: **527/638**, full report byte-identical to the preceding
  build and identical between JIT and interpreter.
- Win32, Linux64, Android32 and Android64 core-unit compilation passes.

## Monster Hunter: actual progression

Read-only image: `Monster Hunter Portable 3rd (PSP)[ENG]v.6.1.0.iso`, ULJM05800,
TMO Patch 6.1 / 2026. Tested via controller input, not prepatched ELF or injected
game state:

1. Boot through logos and title.
2. New character, six-letter name entered through utility OSK.
3. Local memory-stick save (`ULJM05800/MHP3RD.BIN`, 1,183,744 bytes).
4. Opening movie through arrival at Yukumo.
5. Opening bath dialogue; stand up and analogue movement in the 3D scene.
6. Separate process restarts, selects Continue and reloads the saved character;
   the saved file's SHA-256 remains unchanged.

22,500-frame JIT and interpreter runs match all 37 checkpoints, guest clock,
final hash **a0b0d2ff9de2e134**, and **26,468.3 million** guest cycles. A
6,000-frame GPU check compares **1,823,558 batches**, zero differing bytes.
These are correctness checks, not isolated performance benchmarks.

The additional non-crypto bug was the SDK `<>` save-name marker: it denotes the
game's save directory without a suffix, not a literal host directory name.
Treating it as invalid gave error 80110388 and prevented starting a new game.
This is fixed without relaxing validation of ordinary directory names.

## Reproduce

```powershell
.\tests\cores\psp\run\build.ps1 -Project PSPCryptoTest.dpr -Checked
.\tests\cores\psp\run\bin\PSPCryptoTest_win64_checked.exe
.\tests\cores\psp\run\build.ps1
python tests\cores\psp\run\monster_smoke.py "path\to\MHP3rd.iso" --gpu --frames 22500 --out "test-shots"
# To test persistence use a fresh, explicit test folder (not your personal saves):
# --memstick "path\to\test-memory-stick"
```

Remaining: quest/long-session/multiplayer/DLC coverage, incomplete menu font
text, real-PSP secure-save interchange, PGD and unsupported PRX/compression
variants. The old PPSSPP/libkirk-derived implementation remains in git history
only; the current replacement's source/data provenance is documented explicitly.
