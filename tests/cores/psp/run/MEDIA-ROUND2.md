# PSP media: round 2

## Tested state

Worktree `D:\Work\RetroMul-psp-wt\media`, branch `psp/media`.
The integrated core through `1d5f88f` is merged (`6195d98`); the integrator's
`RunUntil`/`RunFrame` loop is retained. Media fixes are in `8e9fe91`,
`50d6124` and `f9702f2`. No oracle files are changed.

Release and PSP_CHECKED runner builds pass. The full release pspautotest suite
passes 520/638, matching the integrated baseline. Media/JPEG passes the same
38/47 tests in release JIT, release interpreter and PSP_CHECKED builds.

## Fixes

- Remove the old host0 path-retry workaround in `scePsmfPlayerSetPsmf`.
- Host-device synchronous read/seek yield through `PSP.IO.DeviceYield`.
  `video/mpeg/deletetiming` now passes. JPEG init/finish both pass after integration.
- Restore the `NoClobber` field used by the integrated runner; accept utility
  module `0x308` (libmp4), restoring `video/mp4/avchold`.
- Implement the low-level `sceVideocodec` entry points used by plain guest
  `sceMpeg_library`: open/init/decode/stop/delete, EDRAM allocation/release and
  memory setup. Keep an AVC decoder per codec block and publish picture-info
  and eight-plane entries in the layout the guest library reads.
- Implement the ME's low-address ES memory. `sceMpegBasePESpacketCopy` copies
  the guest's DMA list into that memory; `sceVideocodecDecode` reads it.
  Returning success without this copy decoded empty data.
- Implement `sceMpegBaseCscAvcRange` and the base CSC pixel-mode entry point;
  share pointer-based ME plane writes and CSC with HLE sceMpeg.
- Fix `sceMpegBaseYCrCbCopy`: its **source dimensions are pixels**, not
  macroblocks. The guest library builds the source from the codec's width and
  height, but builds the destination as a macroblock descriptor. Burnout's
  source is 480x272, destination 30x17. Rejecting the former left green output.
- Fix PSMF table lengths: the length is 23 bits, not 16; bit 23 is the AU
  attribute. Manhunt 2 STINGER's zero-based AU 43 is **70,681 bytes**, table
  flags/length `0001:1419`. Taking only `1419` (5,145) truncated its IDR, raised
  `EBitstreamFormat: Truncated bitstream`, reset the decoder and misaligned
  every following AU. This explains the ~45 CSC calls followed by a frozen
  Rockstar logo. The entire stinger now decodes (166 pictures), and the game
  proceeds into TITLES and the asylum opening.

Crisis Core's SQEXTEC streaming/decode/audio-output threads now run normally
on the merged scheduler/IO core. Its intro and opening credits play with PCM
output; the earlier semaphore-only snapshot is not reproduced. No special
thread wakeup, game-specific scheduler patch or host-clock pacing is added.

## Games

All successful movie rows have changing, visually inspected captures and
non-zero stereo PCM in the runner's WAV. This verifies PCM output, not a
subjective listening/sync test. No missing sceMpeg/scePsmf/sceVideocodec/
sceAudiocodec calls are logged in the final successful runs.

Commands use `PSPRun_win64 <image> -frames N -every 150 -out DIR -log -state
-wav DIR\a.wav`. Host/guest timestamps are recorded at each capture. Runs below
are **sequential**, release, with screenshots and WAV collection enabled.
A speed of 1x means the host can keep up with guest time. It is measured over
the specified movie interval, not the title screen/loading period. There is
no host pacing in this runner.

| Image | Result | Movie interval (runner frames) | Guest seconds / host seconds | Speed |
|---|---|---:|---:|---:|
| `ccff7rusundub_v1.iso` | Intro city/train FMV and credits; PCM | 750–3000 | 37.539 / 22.180 | 1.69x |
| `pata_rus.cso` | New-game storybook movie; PCM | 1800–3000 | 20.020 / 17.158 | 1.17x |
| `GTA LCS 01.09.2005 ULUX80146 V0.02.iso` | All three Rockstar logos, then title credits; PCM | 150–3000 | 47.554 / 4.963 | 9.58x |
| `GTA_VCS_rus.iso` | Logos and animated title credits; PCM | 150–3000 | 47.548 / 6.385 | 7.45x |
| `Tekken_6_[RUS].cso` | Snow/airfield opening; PCM | 1050–3000 | 32.532 / 28.366 | 1.15x |
| `Dissidia_Final_Fantasy_012.ISO` | Attract movie with Cosmos/Chaos and subtitles; PCM | 4500–6600 | 35.035 / 52.134 | **0.67x, GE-bound** |
| `Ridge Racer 2.iso` | Car/Reiko opening after Rally-X; PCM | 3150–5100 | 32.536 / 9.236 | 3.52x |
| `Metal Slug Anthology.iso` | Gameplay/character montage; PCM | 1950–3000 | 17.518 / 12.243 | 1.43x |
| `Daxter.iso` | New-game credits/parchment opening through the game's own libmpeg; PCM | 1200–3000 | 30.032 / 4.034 | 7.44x |
| `Burnout Legends (rus).cso` | EA logo and racing opening, then moving title background; PCM, no green screen | 600–1200 | 10.010 / 9.076 | 1.10x |
| `Manhunt2rus.iso` | Stinger finishes, TITLES/asylum opening continues; PCM | 1050–3000 | 32.534 / 70.385 | **0.46x, GE-bound** |

Controls: Patapon needs **Up at 1200**, Cross at 1400 to select NEW GAME rather
than LOAD. Daxter needs only Cross at 900; subsequent Cross presses skip its
movie. Other successful rows use no buttons. Ridge Racer needs 5100 frames,
and Dissidia 6600, to include their attract movies rather than just menus.

**LocoRoco (`LocoRoco.cso`) remains blocked before a movie starts.** After
Cross on the language selection it opens a MsgDialog saying: "Insufficient
space on Memory Stick Duo. It requires 96KB ... Continue anyway?" It then
polls `sceUtilityMsgDialogGetStatus`; no movie decode has started. Its screen
is black because the dialog has no renderer. This is the utility-dialog
issue in the integrator notes, not a video decoder hang. LocoRoco 2, tested
additionally, gets through its in-game free-space choice with Cross at 300,
Left at 500, Cross at 540 and plays the animated title with audio; this is
not counted as verification of LocoRoco 1's FMV.

Kingdom Hearts BBS is skipped as requested (PGD crypto).

## Decoder performance and identity

`PSPMediaBench.dpr` is a reproducible native harness, with no bundled game data:

```powershell
.\tests\cores\psp\run\build.ps1 -Project PSPMediaBench.dpr
.\tests\cores\psp\run\bin\PSPMediaBench_win64.exe <movie.pmf>
```

It decodes and drains every picture, converts RGB, decodes ATRAC3+, counts
errors and fingerprints **all YUV + RGB bytes and PCM samples**. Decode fps
includes AVC + RGB + audio time; a second figure includes demux and fingerprint
cost too. The reference uses `PSP.MpegVideo.pas` and `Video.AVC.H264.pas` from
`8e9fe91` with the same current demux (so both understand >64 KB AUs).

Optimizations: H.264 half-pixel preparation uses row pointers, bounded six-tap
sum/clipping tables, and the existing scalar/multithread selection; RGB
conversion uses luma/chroma/clamp tables with exactly the original floor,
rounding and saturation. No SIMD, platform assembly or ATRAC decoder changes.

| Movie | Pictures / audio frames | Reference decode fps | Optimized decode fps | YUV+RGB fingerprint (both) | PCM fingerprint (both) |
|---|---:|---:|---:|---|---|
| FF IV `Drill.pmf` | 251 / 183 | 219.6 | 290.2 | `2AA7DB25CB8CF73F` | `5929DA096CFBA6FE` |
| LocoRoco `story_03` extract | 990 / 714 | 228.7 | 306.4 | `71C58E8F9FDC9A37` | `D482A1B8D174ED6A` |
| Metal Slug `INTRO` extract | 2039 / 1467 | 164.7 | 250.7 | `E182F91EB1820A96` | `81C686B3AC702348` |
| Daxter `a1s5` extract | 1384 / 997 | 206.5 | 239.9 | `7175951B747D9BD8` | `AEB518EE92D251AB` |
| Tekken 6 `opening.pmf` | 5284 / 3799 | 172.0 | 206.7 | `72CB802FCDE70B22` | `0A54AF826EB9BB49` |
| Manhunt 2 `STINGER.PMF` | 166 / 122 | 313.9 | 380.4 | `234ABD1C0B22FD6B` | `D6098A0C6769D66D` |

All 10,114 pictures and 7,282 audio frames complete with **zero errors** and
matching output fingerprints. Even including demux/fingerprints, optimized
throughput is 183–306 fps in this run, well beyond 30 fps.

`hostprof.py` and a local main-thread-only variant identify the remaining
whole-game bottleneck: Dissidia's movie samples are mostly GE raster/texture
(about 85%); Manhunt 2 is likewise >80% GE, with `PSPCscMeRow` about 1% and
individual AVC routines below 1%. Boot/title GE also dominates Daxter and
Ridge Racer's total runtime. Further decoder changes cannot recover those
GE-bound cases; **whole-game real-time FMV is not yet achieved for Dissidia
and Manhunt 2**. The GE renderer is not changed in this branch.

## Tests

| Folder | Pass / total | Remaining failures |
|---|---:|---|
| `jpeg` | 8/11 | csc, decodeycbcr, mjpegcsc |
| `video/mp4` | 1/1 | — |
| `video/mpeg` (including ringbuffer) | 10/11 | basic: remaining reschedule-marker differences |
| `video/pmf` | 0/1 | pmf |
| `video/pmf_simple` | 0/1 | pmf_simple |
| `video/psmfplayer` | 19/22 | basic, configplayer, playmode |
| **Total** | **38/47** | Same set with release JIT/interpreter and PSP_CHECKED |

`jpeg/init`, `jpeg/finish`, `video/mpeg/deletetiming` and
`video/mp4/avchold` pass. The pmf/pmf_simple expectations are the previously
noted non-hardware-recorded files; they are not rewritten to turn them green.

`PSPMediaTest.dpr` adds synthetic, data-free regressions for a 70,681-byte
PSMF AU and next-AU alignment, base picture-copy pixel dimensions and both
field-selection bits, and ME CSC versus the scalar conversion. All three
pass in Win64 and Win32, release and checked. Build with
`build.ps1 -Project PSPMediaTest.dpr [-Checked] [-Platform win32]`.
Checked game runs also complete 3000 frames of Manhunt 2 and Burnout without
an arithmetic/range exception, with the same last-frame hashes as release.

## Exact original PSP_CHECKED startup overflow

Reproduced against the initially requested integrated revision `1e7d076`
(with only its missing NoClobber declaration supplied to make it compile):
`PSP.CPU.pas`, **OpADDIU, line 590**:

```pascal
C.Ctx.GPR[RT(Op)] := C.Ctx.GPR[RS(Op)] + SImm(Op);
```

The exception mapped to `OpADDIU + $45`; guest PC `089ACCD0` is Patapon's entry.
This unsigned addition of a sign-extended immediate must wrap. It was already
fixed by the integrator's `86983e9` (Q- in CPU/VFPU/JIT/memory/scheduler/loader),
which is included by the later merge. No additional CPU or loader patch is
made here. The initially suspected constructor/loader location was not the
actual first failing instruction in that reproduced build.

## Changes outside the media units

Authored this round (not other workers' changes brought by merges):

- `source/cores/psp/PSP.HLE.pas`: `NoClobber`, needed by the integrated runner.
- `source/cores/psp/PSP.IO.pas`: host-device read/seek yields; no new host-time input.
- `source/cores/psp/PSP.Utility.Dialogs.inc`: valid module `0x308` for libmp4.
- `source/media/video/avc/Video.AVC.H264.pas`: exact half-pixel optimization.
- `tests/cores/psp/run/PSPRun.dpr`: initially add WAV capture and avoid hashing
  every frame; merge the audio worker's richer WAV implementation; add host
  and guest timestamps to `-every` output for phase measurements. Diagnostic
  host timestamps never influence the guest.
- `tests/cores/psp/run/PSPMediaTest.dpr`, `PSPMediaBench.dpr`, and this report:
  regression tests, repeatable benchmark and results.

No GE, ATRAC3/ATRAC3+, CPU/kernel, frontend, crypto or expected-file changes
are authored. No push or rebase.

Local captures, WAVs, logs and exact command arrays are under
`%LOCALAPPDATA%\Temp\opencode\media_work\final-games\`; `results.json` and
`verified.png` summarize the final runs. Decoder reference comparison is in
`media_work\bench-final.txt`. Proprietary input movies are not committed.
