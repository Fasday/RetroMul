# RetroMul

![RetroMul](https://github.com/HemulGM/RetroMul/blob/main/screen/screen0.png?raw=true)

RetroMul is a multi-system retro game emulator written in Delphi with a FireMonkey interface. It runs games for NES / Famicom, Game Boy, Game Boy Color, Game Boy Advance, SEGA Mega Drive / Genesis, SEGA SG-1000 / SC-3000 / SF-7000, Othello Multivision, SEGA Master System / Mark III, SEGA Game Gear, Super Nintendo, Neo Geo MVS, Neo Geo CD, and the PC Engine / TurboGrafx / SuperGrafx family. The repository also includes RetroTune, a companion music player, and RetromulTerm, a Windows console frontend.

## Supported systems and ROM formats

| System | ROM formats |
| --- | --- |
| NES / Famicom | `.nes` |
| Game Boy | `.gb`, `.gbx` |
| Game Boy Color | `.gbc`, `.gbx` |
| Game & Watch | `.gw`, `.mgw`, catalogued MAME `.zip` sets with SVG screens |
| Game Boy Advance (experimental) | `.gba` |
| Nintendo 64 (experimental) | `.z64`, `.n64`, `.v64` |
| SEGA Mega Drive / Genesis | `.md`, `.bin`, `.gen`, `.smd` |
| SEGA SG-1000 | `.sg` (legacy `.sms` images in `sg1000/`) |
| SEGA SC-3000 | `.sc` |
| SEGA SF-7000 | `.sf7`, `.sf`, `.dsk` (external IPL required) |
| Othello Multivision | `.mv` |
| SEGA Master System / Mark III | `.sms` |
| SEGA Game Gear | `.gg` |
| Super Nintendo / Super Famicom | `.sfc`, `.smc`, `.swc`, `.fig` |
| Neo Geo MVS | Named MAME ROM sets in `.zip`, unencrypted NeoSD `.neo` images |
| Neo Geo CD / CDZ (experimental) | `.iso`, `.cue` with BIN/PCM WAV tracks, `.chd` |
| PC Engine / TurboGrafx-16 (experimental) | `.pce`, single-HuCard `.zip` |
| SuperGrafx (experimental) | `.sgx`, `.pce`, single-HuCard `.zip` |
| PC Engine CD / Duo / Arcade Card (experimental) | `.cue`, `.iso`, `.chd` (built-in System Cards 1/2/3) |

Cartridge ROM detection uses file contents. GBX files select Game Boy or Game Boy Color from the cartridge header. Mega Drive loading handles SMD interleaving and byte-swapped images; SNES loading handles supported copier headers. For Neo Geo CD, open the disc's `.cue`, `.iso`, or `.chd` file. SG-1000 and SC-3000 cartridges have no mandatory header and are selected by `.sg` and `.sc`; unknown raw `.bin` files are not guessed as these systems.

Neo Geo runs in MVS arcade mode with embedded system firmware. Split ROM sets need their parent ZIPs in the same directory. The loader recognizes catalogued original, decrypted, bootleg, and PCB variants; a ZIP extension alone does not guarantee a supported set. See the [Neo Geo core notes](source/cores/neogeo/README.txt) for hardware coverage, controls, and limitations.

Neo Geo CD / CDZ is experimental. It boots through an external 512 KiB CD/CDZ BIOS named `neocd.bin`, placed beside the image or in `ROMS/neogeocd/`. Common BIOS names such as `top-sp1.bin`, `front-sp1.bin`, and `neocd_z.rom` are also accepted. MVS firmware cannot boot CD games.

CD images support Mode 1 ISO data, CUE sheets with MODE1/2048 or MODE1/2352 data and BINARY or 44.1 kHz stereo 16-bit PCM WAV audio, and CHD images. Keep every file referenced by a CUE together; choose the CUE to retain CD music. The library hides a matching ISO when a CUE with the same base name exists. Extract CD ZIP archives first. Compressed audio CUE tracks and parent/differential CHDs are not supported by the CD frontend.

CD games use the **Neo Geo (CD)** input settings for both players, with Select in place of Coin. CDDA music mixes with the emulated YM2610 audio. Backup saves and snapshots are kept separately from MVS games. Disc images load in the background with a loading indicator and Cancel button; large images can take several seconds to open. Android disc access uses the selected ROM folder through the system storage picker. CHD decoding uses the native cross-platform Delphi library in `source/chd`, with no external decoder binaries. See the [Neo Geo CD notes](source/cores/neogeo/README.txt) and [decoder documentation](source/chd/README.md) for compatibility and image limits.

Game Boy Advance uses a native ARM/Thumb core with built-in open emibios firmware, stereo audio, SRAM/Flash/EEPROM saves, RTC, tilt, gyroscope and solar-sensor cartridges, cartridge rumble, and save states. GBA settings allow automatic or manual save-memory selection and a Boktai sunlight level from 0 to 255. A replacement 16 KiB BIOS can be selected in GBA settings. Compatibility is still incomplete; see the [GBA firmware notes](source/cores/gba/firmware/README.md) for the bundled firmware, source and license.

## Features

Game & Watch uses a native Delphi SM5xx core for firmware packages and a native script runtime for MGW simulations. SVG LCD segments are rendered with the project's FMX SVG implementation. Games appear under the Game & Watch library filter and have configurable controls, audio, snapshots and MGW high-score/settings persistence. See the [Game & Watch notes](source/cores/gamewatch/README.md) for archive contents, controls and verified coverage.

- Browse a game library in grid or list view with cover art and information from `gamelist.xml`, search by title, filter by system or initial letter, and keep favorites and recently played games. ROM files can also be opened directly or dropped onto the desktop application.
- Assign keyboard keys, controller buttons, axes, and D-pad directions for each system and controller port. View the active bindings in the in-game controls help.
- Play with an Android screen gamepad, including NES / Dendy turbo buttons and six-button SEGA controls.
- Use multiple controllers, NES Four Score, and SNES Multitap in compatible games.
- Pause, reset, save and restore game states with preview images, and keep battery-backed saves. Continue games from saved states in the library.
- Switch to fullscreen, resize the game display, and capture screenshots.
- Configure video filtering, audio, Game Boy palettes and boot ROMs, and system-specific hardware and peripherals. Supported settings can be applied during a game.
- Customize Game Boy / Game Boy Color frame blending, separate monochrome background and sprite palettes, layer visibility, sprite limits, CPU speed (100–400%), and individual sound-channel volume. Game Boy Color also offers LCD color correction. Higher CPU speeds and relaxed sprite limits can change game behavior.
- Use Game Boy / Game Boy Color / Game Boy Advance cartridge rumble and cartridge motion inputs on supported devices; tilt and rotation depend on available device sensors.
- Use supported NES peripherals, including Zapper, Power Pad, Family BASIC and Subor keyboards, Miracle Piano, and the Famicom Data Recorder. Four Score must be disabled when using Zapper, Power Pad or Miracle Piano.
- Use an English or Russian interface, with language selection in settings.
- Listen to native streaming audio. Supported audio platforms include Windows, Linux, Android, macOS, and iOS.

Compatibility depends on the game's cartridge hardware, protection, and peripherals. Mapper or ROM-set support does not imply complete hardware accuracy or full gameplay compatibility for every game. Save-state formats can change between builds.

Nintendo 64 uses a native Delphi VR4300/RSP interpreter and software RDP with no external emulator, plugin or PIF BIOS. Cartridge settings select EEPROM 4/16 Kbit, SRAM or FlashRAM. It is experimental: advanced rendering, exact timing and full FPU/RSP conformance remain incomplete. Passing CPU/RSP tests does not establish commercial gameplay compatibility. Implementation and test details: `codex-work/n64/REPORT.md`.

The SEGA 8-bit family shares RetroMul's Delphi Z80, TMS9918A / Sega Mode 4 video, and clocked PSG. SG-1000 / SC-3000 support NTSC/PAL, two controllers, snapshots and known cartridge RAM layouts including BASIC II/III and Music Editor. SC-3000 accepts physical and on-screen keyboard input; Shift, Ctrl, Graph and Kana latch when tapped. BASIC RAM checks can take several seconds. RetromulTerm uses F12 to exit computer sessions so Escape remains available as BREAK.

Master System / Mark III support cartridge banking, SRAM, optional 8/16/32 KiB BIOS and YM2413 FM. Game Gear uses a 160×144 viewport, 12-bit palette, stereo PSG, separate Start input, automatic or manual Japanese/export hardware region, Sega / Codemasters cartridges, SRAM and 93C46 EEPROM saves. Game Gear timing is always NTSC. Each platform has its own settings, library filter, saves and snapshots.

SF-7000 supports 160 KiB raw disks and CPC DSK images through its native floppy controller; select the external 8 KiB IPL in settings or put it beside the disk. SC/SF computer models also provide PCM WAV cassette support. The library checks both dedicated `sc3000/`, `sf7000/`, `omv/` folders and legacy matching extensions in `sg1000/`. Game Gear link-cable multiplayer, SMS light gun/paddle peripherals and complete hardware timing conformance remain outside the verified coverage. Verification and current limitations: `codex-work/sega8/REPORT.md`.

PC Engine reuses RetroMul's HuC6280 and PSG with native VDC/VCE video, SuperGrafx's second VDC and priority controller, HuCard banking, timer/IRQs, TurboTap and Avenue Pad 6. CD-ROM², Super CD-ROM², Duo and Arcade Card configurations add native CD commands, CDDA, ADPCM, BRAM and expansion RAM. CD media parsing and CHD access are shared through `Core.CD.Disc` and `Core.CD.CHD`. System Cards 1/2/3 are embedded, with automatic hardware/region selection and an optional external replacement. All five BIOS menus, state continuation and diagnostic CD boot are tested; commercial CD gameplay remains unverified. Bounded HuCard checks do not imply full gameplay or hardware accuracy. See the [PC Engine notes](source/cores/pce/README.md).

## Getting started

Open a ROM directly, or select the library root folder in Settings. The library uses these system subdirectories:

```text
ROMS/
  nes/
  gb/
  gbc/
  gw/
  gba/
  n64/
  megadrive/
  sg1000/
  sc3000/
  sf7000/
  omv/
  sms/
  gg/
  snes/
  neogeo/
  neogeocd/
  pcengine/
  sgx/
  pcecd/
```

Place ROMs in the corresponding folders. On desktop, an optional `gamelist.xml` in each system folder supplies titles, descriptions, cover paths, and other metadata; games without metadata use their filenames. On Android, choose the ROM folder through the system folder picker.

Choose input devices and button bindings in Settings before playing. Use the game toolbar to pause, save or load a state, return to the library, or open settings and controls help.

For Neo Geo CD, put the BIOS and all disc companion files in `neogeocd/` before opening the game. On Android, grant access to the ROM folder so the loader can find the BIOS and CUE tracks. A standalone data ISO does not include CD music tracks.

Desktop shortcuts during gameplay:

| Key | Action |
| --- | --- |
| `P` | Pause / resume |
| `F5` | Save the quick state |
| `F6` | Load the quick state |
| `F8` | Take a screenshot |

These shortcuts are suspended while an emulated NES keyboard is active. The Save and Load toolbar menus provide access to other snapshot slots.

## Building from source

The main application uses Delphi / RAD Studio and FireMonkey. Its Windows sources currently reference the Delphi 13 platform fixes in the DelphiWinUI3 submodule. Initialize the repository's submodules before building:

```sh
git submodule update --init --recursive
```

Open `RetromulGroup.groupproj` for the project group, or open an individual project:

| Project | Purpose |
| --- | --- |
| `fmx/RetroMul.dproj` | FireMonkey emulator |
| `tune/RetroTune.dproj` | FireMonkey music player |
| `term/RetromulTerm.dproj` | Windows console emulator with ASCII video output |

`BuildReleases.ps1` builds and packages RetroMul for Windows 32/64-bit, Linux 64-bit, and Android 32/64-bit. Install and configure the corresponding RAD Studio platform SDKs and toolchains. For example, build only the Windows packages from the repository root:

```powershell
.\BuildReleases.ps1 -Platforms win32,win64
```

Packages are written to `releases/RetroMul-<platform>.zip`. Use `-BdsPath` if the script cannot locate RAD Studio. This script packages RetroMul; build RetroTune and RetromulTerm from their own projects. Development checks, reports, and helper tools are kept in `codex-work`.

## RetroTune

<details>
<summary>RetroTune features, supported music formats, and Delphi integration</summary>

RetroTune is the companion player for retro game music, chiptunes, tracker modules, MIDI / General MIDI, and WAV audio. Its decoder registry and threaded PCM player can also be used in another Delphi application without the RetroTune interface.

- Play NES NSF/NSFe, SNES SPC, Game Boy GBS, Commodore SID, Atari music, VGM/VGZ, and a wide range of Spectrum tracker and chip-dump formats.
- Listen to MSX / Master System KSS, PC Engine HES, Amiga AHX/HVL/MOD, Dreamcast DSF/MiniDSF, TIATracker, TurboSound, TurboFM, IMF/DRO, XGM/XGM2, and digital tracker music.
- Play MIDI with GeneralUser GS, TimGM6mb, FluidR3 GM, or a custom SF2 bank. Switching banks preserves the selected track, position, and playback state.
- Extract supported music from Spectrum TAP and TR-DOS disk containers.
- Select tracks, pause and resume playback, seek, and adjust volume.
- Choose from eleven audio visualizations, including spectrograms, stereo spectra, phase correlation, and RMS/peak meters.
- Inspect file information, track durations, metadata, and the supported-format reference.
- Export a selected track to WAV in the background, with progress and cancellation.
- Use an English or Russian interface. The system language is selected automatically at startup; other languages use English.

See [RetroTune format details](tune/FORMATS.md) for supported variants and limitations.

### Supported music formats

The following table lists every extension registered by the RetroTune application. Extensions identify specific supported variants; they do not imply support for every unrelated format that uses the same suffix.

| Format / family | Extensions |
| --- | --- |
| NES Nintendo Sound Format, NSF2, NSFe | `.nsf`, `.nsf2`, `.nsfe` |
| SNES SPC | `.spc` |
| Game Boy Sound | `.gbs` |
| Commodore 64 SID (PSID) | `.sid` |
| Video Game Music, compressed VGM | `.vgm`, `.vgz` |
| Mega Drive / Genesis GYM | `.gym` |
| Mega Drive XGM / XGM2, compiled XGM2 | `.xgm`, `.xgm2`, `.xgc` |
| MSX / Sega Master System KSS | `.kss` |
| PC Engine HES | `.hes` |
| Dreamcast DSF / MiniDSF | `.dsf`, `.minidsf` |
| Amiga AHX, HivelyTracker | `.ahx`, `.hvl` |
| Amiga SoundTracker / ProTracker MOD | `.mod` |
| Atari 2600 TIATracker, cartridge music | `.ttt`, `.a26` |
| Atari SAP, Raster Music Tracker | `.sap`, `.rmt` |
| Atari Music ProTracker with samples, 15 kHz sample bank | `.md1`, `.d15` |
| AY executable music (ZX Spectrum / CPC) | `.ay` |
| ASC Sound Master | `.as0`, `.asc` |
| Fast Tracker | `.ftc` |
| Global Tracker | `.gtr` |
| Pro Sound Creator | `.psc` |
| Pro Sound Maker | `.psm` |
| Pro Tracker 1 / 2 / 3, including PT3 TurboSound | `.pt1`, `.pt2`, `.pt3` |
| SQ-Tracker | `.sqt` |
| Sound Tracker editor / compiled modules | `.s`, `.st1`, `.st3`, `.stc` |
| Sound Tracker Pro | `.stp` |
| AY register log | `.psg` |
| ST Sound YM | `.ym` |
| VTX AY / YM | `.vtx` |
| CPC AYC | `.ayc` |
| AY text register dump | `.debugay` |
| Vortex Tracker text module | `.txt` |
| TurboSound container | `.ts` |
| TFM Music Maker | `.tf0`, `.tfe` |
| TurboFM compiled / register dump | `.tfc`, `.tfd` |
| Multitrack audio container | `.mtc` |
| SAM Coupe E-Tracker / SAA1099 | `.cop`, `.etc`, `.sng` |
| Spectrum tape containing E-Tracker music | `.tap` |
| TR-DOS disk image / SINCLAIR disk archive containing music | `.trd`, `.scl` |
| Chip Tracker | `.chi` |
| Digital Music Maker | `.dmm` |
| Digital Studio | `.dst` |
| SQ Digital Tracker | `.sqd` |
| Sample Tracker | `.str` |
| Extreme Tracker, Extreme / ProDigiTracker raw modules | `.et1`, `.d`, `.m` |
| ProDigiTracker | `.pdt` |
| id Software AdLib IMF, DOSBox RAW OPL | `.imf`, `.dro` |
| Standard MIDI / General MIDI, RIFF MIDI, karaoke audio | `.mid`, `.midi`, `.rmi`, `.kar` |
| RIFF/WAVE PCM / IEEE Float audio | `.wav` |

SID playback supports PSID; RSID is outside the supported variant. IMF uses 700 Hz timing. `.xgc` refers to compiled XGM2. `.sng` refers to raw SAM Coupe E-Tracker modules; `.txt` refers to Vortex Tracker modules. TAP/TRD/SCL are music containers, not general tape/disk program emulators. KAR plays the MIDI audio; lyrics are skipped. WAV supports mono/stereo PCM 8/16/24/32-bit and IEEE Float 32/64-bit, including the corresponding WAVE_FORMAT_EXTENSIBLE subformats.

MiniDSF needs its referenced library files beside the source file. MD1 needs the companion `.d15` or `.d8` sample bank; `.d8` is a companion file, not a separately registered playable format. MIDI needs a SoundFont2 bank. Standard banks are plain `GeneralUser-GS.sf2`, `TimGM6mb.sf2`, and `FluidR3_GM.sf2` files in the `sf2` directory beside the executable, with their license notices. The Windows RetroTune build prepares that directory automatically. Custom SF2 files can be selected separately; the banks are not embedded in the EXE.

### Using the player in another Delphi application

`TTunePlayer` in `tune/playback/RetroTune.Player.pas` owns the playback thread and PCM device; it does not depend on FireMonkey or `RetroTune.Main`. Add `tune/decoders`, `tune/common`, `tune/chips`, `tune/playback`, and `source/pcm` to your project's unit search path. Other decoders can additionally require `tune/trackers`, `source/cores`, and the relevant core subdirectories.

Decoder units register their formats in their `initialization` sections. This standalone console example enables WAV and MIDI; add the other `RetroTune.Decoder.*` units used by [RetroTune.dpr](tune/RetroTune.dpr) to enable their formats. Keep dependent decoder units when using containers. For MIDI, prepare the `sf2` directory beside **your application's** EXE, or call `SetMidiSoundFont` with a custom SF2 path before opening the MIDI file.

The example plays the default track for up to ten seconds, checks asynchronous playback errors, and releases the player even if playback fails:

```pascal
program StandaloneTune;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes,
  RetroTune.Decoder, RetroTune.Player,
  RetroTune.Decoder.WAV, RetroTune.Decoder.MIDI;

begin
  try
    if ParamCount <> 1 then
      raise Exception.Create('Usage: StandaloneTune <music.wav|music.mid>');

    // Optional for MIDI: SetMidiSoundFont('C:\Music\MyBank.sf2');
    var Decoder := TTuneDecoders.Open(ParamStr(1));
    var Info := Decoder.GetInfo;
    var Player := TTunePlayer.Create(Decoder);
    try
      Player.SetVolume(80); // 0..100
      Player.SelectTrack(Info.DefaultTrack); // Track indexes start at zero.
      Player.Play;
      var Started := TThread.GetTickCount64;
      repeat
        var State := Player.Status;
        if State.Error <> '' then
          raise Exception.Create(State.Error);
        if State.State = TTunePlayerState.Finished then
          Break;
        TThread.Sleep(20);
      until TThread.GetTickCount64 - Started >= 10000;
      Player.Stop;
    finally
      Player.Free; // Terminates and joins the worker; closes the audio device.
    end;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
```

Run it as `StandaloneTune.exe "C:\Music\song.mid"` or pass a WAV file. `Player.Pause` pauses and `Player.Play` resumes; `Player.Seek(30.0)` requests an asynchronous seek to 30 seconds (`Player.Status.Seeking` reports progress). `SelectTrack` resets the selected track to its beginning. `Status` and the player control methods synchronize access internally. After creating the player, use those methods rather than calling the same decoder's `Render` or `SelectTrack` from another thread. Read metadata before handing the decoder to the player, as above.

Audio output is selected by `PCM.Audio.Factory`: WaveOut on Windows, ALSA on Linux, AudioTrack on Android, and Audio Queue on macOS/iOS. Your own application still needs the normal platform audio setup. No RetroTune forms, `Application.Initialize`, or `Application.Run` are required for the console example.

</details>
