# PC Engine family

The native Delphi core reuses RetroMul's HuC6280 interpreter and six-channel PSG.
It integrates with the common emulation worker, PCM output, storage, input
bindings, library, previews, persistent saves and snapshots.

## Models

`pce` covers PC Engine, TurboGrafx-16, CoreGrafx/II, Shuttle, GT/TurboExpress
and LT. `sgx` adds SuperGrafx's independent 32 KiB work RAM, second 64 KiB
VRAM/VDC and HuC6202 priorities/windows. These revisions share the same HuCard
hardware except for region identification and the SuperGrafx additions.

`pcecd` covers CD-ROM², TurboGrafx-CD, Super CD-ROM², Duo/R/RX, TurboDuo,
Arcade Card Duo/Pro and SuperGrafx with Super CD or Arcade Card. The base CD
configuration has 64 KiB CD RAM and 2 KiB BRAM; Super CD configurations add
192 KiB RAM. Arcade Card adds 2 MiB RAM accessed through four programmable
ports and its shift/rotate registers. Arcade Card Pro does not itself turn an
ordinary console into a SuperGrafx.

## Images, BIOS and controls

Open `.pce`, `.sgx` or a ZIP containing one HuCard. A 512-byte copier header
is removed when the remaining file consists of 8 KiB banks. Historical
bit-reversed dumps are recognized from their reset vector/prologue. The loader
handles 384/512/768 KiB wiring, the 2.5 MiB Street Fighter II board and Populous
RAM. Known exclusive SuperGrafx cards select that model by normalized CRC;
`.sgx` and `(SGX)` filename hints are also accepted.

The library searches `pcengine/` and `pce/`; mixed `(SGX)` images appear under
SuperGrafx. Dedicated SuperGrafx folders are `sgx/` and `supergrafx/`.
CD images belong in `pcecd/`. Disc loading also recognizes the NEC boot string
in the second sector of the first data track, including a data track following
an audio track. The first-sector identifier used by diagnostic fixtures is
accepted as well.

CD images use the shared `Core.CD.Disc` / `Core.CD.CHD` reader for CUE/BIN,
PCM WAV, ISO and CHD. Its TOC, bounded sector access, pregaps, hashing and
native CHD decoding are independent of the emulated console. Filesystem checks
are explicit: the other CD core requests ISO 9660, while NEC discs can use
their native boot format. No external decoder binary is added.

System Card 1.0, 2.0 and Super System Card 3.0 are embedded as resources,
including US versions 2.0/3.0. Each image is 256 KiB; the total is 1.25 MiB.
Standard CD-ROM² selects 2.0; Super CD/Duo/Arcade Card selects 3.0.
TurboGrafx-CD and TurboDuo select the corresponding US firmware. This also
works on Android without selecting an external file.

A replacement BIOS is optional: select it in PC Engine CD settings, or place
the matching `syscard2.pce`, `syscard2u.pce`, `syscard3.pce`, `syscard3u.pce`
or generic `syscard.pce` beside the disc or in `pcecd/`. An explicit path takes
priority; a matching nearby file takes priority over the embedded default.
Advanced configuration also accepts `builtin:syscard1.pce` (or another bundled
filename) in `Hardware/BIOS` to select a particular embedded revision.
See [firmware provenance and checksums](firmware/README.md).

Buttons A/B map to I/II, Start to Run, and Select to Select. Avenue Pad 6 maps
X/Y/C/Z to III/IV/V/VI. Select the two-button pad or Avenue Pad 6 per port;
enable TurboTap for up to five players. Keyboard defaults are arrows,
Z/X, Shift and Enter, with C/V/A/S for III/IV/V/VI. The terminal frontend
forwards these keys as well.

## Validation and accuracy limits

The VDC implements planar background/sprite decoding, SATB, scrolling, sprite
limits/collision, gated interrupt status, VRAM read latches and clocked DMA.
VCE provides the 9-bit palette and dot-clock/frame-line selection. CPU timer
timing uses the high-speed clock independently of CPU speed. CLI interrupt
latency and mixed-speed CSL/CSH accounting are preserved.

This remains an experimental first implementation. Rendering occurs at
scanline boundaries; individual VRAM arbitration slots, within-line register
changes, memory access-width corner cases, exact CD seek/REQ/ACK delays,
ADPCM port delays/filtering and sound analogue response are not fully modeled.
The display crops to 242 rows while VDC interrupt timing uses its programmed
display height. HES regression tests verify that shared CPU changes retain
music playback and deterministic resets.

Unit and integration tests cover all CPU opcode dispatches, transfers,
banking, video/DMA/IRQ, five-port scanning, six-button scanning, snapshots,
SCSI command phases, READ6, TOC, CDDA, ADPCM, BRAM and the frontend. The
commercial HuCard smoke report and state continuation results are in
`codex-work/pce/compatibility.csv`. These are bounded runs, not playthroughs
or independent pixel/audio accuracy comparisons. All five embedded System
Cards boot their real menus and preserve deterministic frame/audio state.
All five also boot a diagnostic audio-first CD through the original IPL,
READ6 program loading and execution from CD RAM. Commercial CD gameplay is
still unverified.

## References

- [Hudson HuC6280 software manual](https://github.com/MiSTer-devel/TurboGrafx16_MiSTer/blob/master/docs/HuC6280%20-%20CMOS%208-bit%20Microprocessor%20Software%20Manual.pdf)
- [Hudson HuC6270 manual](https://github.com/MiSTer-devel/TurboGrafx16_MiSTer/blob/master/docs/HuC6270%20-%20CMOS%20Video%20Display%20Controller%20Manual.pdf), especially H7-4 (enabled interrupt status) and H7-7 (raster/scroll timing).
- [Hudson HuC6260 manual](https://github.com/MiSTer-devel/TurboGrafx16_MiSTer/blob/master/docs/HuC6260%20-%20CMOS%20Video%20Color%20Encoder%20Manual.pdf)
- [Hudson CD system software manual](https://github.com/MiSTer-devel/TurboGrafx16_MiSTer/blob/master/docs/Hu7%20CD%20System%20-%20Software%20Manual.pdf)
- [Mesen PCE sources](https://github.com/SourMesen/Mesen2/tree/master/Core/PCE), independent supplementary evidence for unusual mapper, controller, timer and CD behavior.
- [DSP system checklist](https://github.com/leniad/dsp-emulator). RetroMul's existing components were extended natively; DSP behavior is not a correctness target.
