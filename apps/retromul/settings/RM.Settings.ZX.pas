unit RM.Settings.ZX;

interface

uses
  System.IniFiles, RM.Settings.Platform;

type
  TZXSettings = class(TSettingsPlatform)
  public
    procedure Validate(Draft: TMemIniFile); override;
    function HasConfiguration: Boolean; override;
    function ChangeConfiguration(Draft: TMemIniFile; const Section, Key: string): Boolean; override;
    function ConfigurationNotice(Draft: TMemIniFile): string; override;
    procedure Initialize(Context: TSettingsPageContext); override;
    procedure Audio(Context: TSettingsPageContext); override;
    procedure Configuration(Context: TSettingsPageContext); override;
    procedure Video(Context: TSettingsPageContext); override;
    procedure Peripherals(Context: TSettingsPageContext); override;
  end;

implementation

uses
  System.SysUtils, FMX.Types, ZX.Configuration;

function LocalizeConfigurationText(const Text: string): string;
const
  ConflictPrefix = 'Conflict: ';
begin
  Result := '';
  for var Line in Text.Split([sLineBreak]) do
  begin
    if Result <> '' then
      Result := Result + sLineBreak;
    if Line.StartsWith(ConflictPrefix) then
      Result := Result + Translate(ConflictPrefix) + Translate(Line.Substring(Length(ConflictPrefix)))
    else
      Result := Result + Translate(Line);
  end;
end;

procedure TZXSettings.Validate(Draft: TMemIniFile);
begin
  inherited;
  var Errors := TZXConfiguration.ReadMachine(Draft).ConfigurationErrors;
  if Length(Errors) > 0 then
    raise EArgumentException.Create(LocalizeConfigurationText(string.Join(sLineBreak, Errors)));
end;

function TZXSettings.HasConfiguration: Boolean;
begin
  Result := True;
end;

function TZXSettings.ChangeConfiguration(Draft: TMemIniFile; const Section, Key: string): Boolean;
begin
  Result := False;
  if SameText(Section, 'Hardware') and SameText(Key, 'Preset') then
  begin
    TZXConfiguration.ApplyPreset(Draft, Draft.ReadString('Hardware', 'Preset', 'custom'));
    Exit(True);
  end;
  if TZXConfiguration.ManagedSetting(Section, Key) then
    Draft.WriteString('Hardware', 'Preset', 'custom');
end;

function TZXSettings.ConfigurationNotice(Draft: TMemIniFile): string;
begin
  Result := LocalizeConfigurationText(TZXConfiguration.Notice(Draft));
end;

procedure TZXSettings.Initialize(Context: TSettingsPageContext);
begin
  Context.CreateGroup('ZXConfiguration', 'Ready configurations');
  Context.CreateOption('ZXConfigurationPreset', 'Configuration preset', 'Replaces machine, interface, sound, input and media options in this draft. Apply saves; Cancel discards. Manual changes select Custom. Shaders, master volume and button bindings are preserved.', sekCombo);
  Context.CreateGroup('ZXHardware', 'ZX Spectrum');
  Context.CreateOption('ZXTapeModel', 'Machine model', 'KDI opens on Byte-01. PRO opens on Profi 1024K unless Profi 512K is selected. TRD/SCL retain selected Pentagon, Scorpion or Profi; other models use Pentagon 128K. DSK opens on +3. Tapes use the selected machine. Select Gama 1989 for esxDOS autoboot; older Gama ROMs switch memory after its boot hook. Changes apply when opening media.', sekCombo);
  Context.CreateOption('ZXTimexCartridge', 'Timex TC2068 cartridge', 'Optional DCK HOME/DOCK/EXROM cartridge attached to tapes and snapshots. Use a Spectrum emulator cartridge for Spectrum software on TC2068. Open DCK directly to boot a cartridge.', sekPath);
  Context.CreateOption('ZXServiceROM', 'Pentagon service ROM', 'Optional 16 KiB Gluk ROM or 64 KiB GLUK/DOS/128/48 ROM set for Pentagon 1024K disk boot. Leave empty for the classic TR-DOS boot.', sekPath);
  Context.CreateOption('ZXTKTiming', 'TK90X / TK95 video timing', 'Select the original Microdigital MC16845 60 Hz timing or its 50 Hz pin setting. Applies on opening media; other machine families ignore this option.', sekCombo);
  Context.CreateOption('ZXTKSpanish', 'TK90X / TK95 Spanish ROM', 'Select the original Spanish EPROM and export-board keyboard input. Disabled selects the Brazilian Portuguese EPROM. Applies only to TK90X/TK95.', sekSwitch);
  Context.CreateOption('ZXByteCompatibility', 'Byte Spectrum compatibility', 'Position of the original Byte compatibility switch. The ROM overlay becomes active after reading Kempston port 1F. Applies on open; Byte-01 has no overlay PROMs.', sekSwitch);
  Context.CreateOption('ZXVI53Volume', 'Byte VI53 volume (%)', 'Adjust the three-channel Byte/Byte-01 timer synthesizer independently of the beeper and AY.', sekNumber);
  Context.CreateOption('ZXULAPlus', 'ULAplus palette', 'Attach the programmable 64-entry palette. Programs select colors through its ports. Applies when opening media.', sekSwitch);
  Context.CreateOption('ZXTimexVideo', 'Timex video modes', 'Attach dual-screen, HiColor and 512-pixel HiRes video modes. Applies when opening media.', sekSwitch);
  Context.CreateOption('ZXKempstonMouse', 'Kempston mouse', 'Use host relative mouse movement and three buttons. Applies when opening media.', sekSwitch);
  Context.CreateOption('ZXSecondJoystick', 'Second joystick', 'Map controller 2 to Gama PPI port B (63), or Interface 2 keys 1–5 on other machines. Configure both controllers in Controls.', sekSwitch);
  Context.CreateGroup('ZXSound', 'Spectrum sound');
  Context.CreateOption('ZXTurboSound', 'Turbo Sound', 'Attach a second AY/YM chip using the NedoPC FF/FE selector. Applies when opening media.', sekSwitch);
  Context.CreateOption('ZXTurboSoundFM', 'Turbo Sound FM', 'Replace the PSG with two YM2203 chips (NedoPC revision C). FM uses the expansion volume; SSG uses AY / YM volume. Applies when opening media.', sekSwitch);
  Context.CreateOption('ZXSAA1099', 'SAA1099 sound board', 'Attach the 8 MHz board at ports 00FF/01FF. Shares ports with Timex video; applies when opening media.', sekSwitch);
  Context.CreateOption('ZXDAC', 'DAC sound board', 'Choose the external 8-bit DAC interface. GS-port Covox is the B3 DAC interface. Applies when opening media.', sekCombo);
  Context.CreateOption('ZXGeneralSound', 'General Sound', 'Attach the classic 12 MHz Z80 sound card with built-in GS ROM 1.05b and four DAC channels. Applies when opening media.', sekSwitch);
  Context.CreateOption('ZXGeneralSoundRAM', 'General Sound RAM', 'Select the classic 128 KiB board or GS512 expansion. GS512 retains the original missing 32 KiB region. Applies when opening media.', sekCombo);
  Context.CreateOption('ZXSID', 'SID (eZX/MB)', 'Attach one SID through the eZX/MB ports. No BIOS is required. Applies when opening media.', sekSwitch);
  Context.CreateOption('ZXSIDModel', 'SID model', 'Initial SID model. Software can switch 6581/8580 without resetting the voices.', sekCombo);
  Context.CreateOption('ZXSIDClock', 'SID clock', 'Initial PAL or NTSC SID clock. This does not change Spectrum video timing. Software can change the SID clock.', sekCombo);
  Context.CreateOption('ZXMoonSound', 'ZXM-MoonSound', 'Attach OPL4 with 18 FM and 24 wave channels, 1 MiB RAM and built-in Yamaha sample ROM. Flash updates are saved automatically. Applies when opening media.', sekSwitch);
  Context.CreateOption('ZXMoonSoundIRQ', 'MoonSound IRQ jumper', 'Connect OPL4 timer interrupts to the Spectrum CPU. The standard music players use frame interrupts and do not require this jumper.', sekSwitch);
  Context.CreateOption('ZXMoonSoundInDOS', 'MoonSound in TR-DOS', 'Emulate the PentEvo jumper and keep MoonSound accessible in DOS ROM. Disk-controller accesses still take priority.', sekSwitch);
  Context.CreateOption('ZXDMAUSC', 'DMA Ultrasound Card', 'Attach the four-channel DMA Ultrasound Card. Samples use motherboard RAM; no BIOS is required. Applies when opening media.', sekSwitch);
  Context.CreateOption('ZXDMAUSCStereo', 'DMA Ultrasound stereo', 'Route the four physical audio outputs to stereo or mono.', sekCombo);
  Context.CreateOption('ZXDMAUSCULABypass', 'Keep ULA interrupts enabled', 'Compatibility option for early DMA USC players. Keep frame interrupts enabled regardless of IRQ-control bit 3. Turn off to emulate the complete interrupt controller.', sekSwitch);
  Context.CreateOption('ZXNeoGS', 'NeoGS', 'Attach NeoGS with built-in firmware 1.11, 4/8-channel PCM, VS1011e MP3, SD and DMA. Flash updates are saved automatically. Applies when opening media.', sekSwitch);
  Context.CreateOption('ZXNeoGSRAM', 'NeoGS RAM', 'Select 512 KiB, 2 MiB or 4 MiB of sound card RAM. Programs control paging, channel mode and the 10/12/20/24 MHz CPU clock.', sekCombo);
  Context.CreateOption('ZXNeoGSImage', 'NeoGS SD image', 'Optional raw SD image for the NeoGS slot, independent of divMMC. Sector changes are saved separately; the original image is preserved.', sekPath);
  Context.CreateOption('ZXNextDACMode', 'Next-DAC port profile', 'Choose enabled DAC aliases on startup. Programs can change these gates through NextReg 84. Applies only to Next-DAC.', sekCombo);
  Context.CreateOption('ZXNextDACStartup', 'Enable Next-DAC on startup', 'Enable the DAC for classic software. Turn off to start with the hardware power-on gate closed; programs can enable NextReg 08 bit 3.', sekSwitch);
  Context.CreateOption('ZXExpansionVolume', 'Expansion sound volume (%)', 'Adjust DAC, GS/NeoGS, SAA1099, FM, MoonSound and SID independently of the PSG and beeper.', sekNumber);
  Context.CreateOption('ZXPSGModel', 'PSG chip', 'Select AY-3-8912 or YM2149 sound characteristics. Turbo Sound FM always uses YM2203 SSG.', sekCombo);
  Context.CreateOption('ZXStereo', 'PSG stereo layout', 'Mono or channel order from left to right. ABC preserves the previous sound.', sekCombo);
  Context.CreateOption('ZXAYVolume', 'AY / YM volume (%)', 'Adjust PSG sound independently. Zero mutes the chip.', sekNumber);
  Context.CreateOption('ZXBeeperVolume', 'Beeper volume (%)', 'Adjust the Spectrum speaker and MIC output. Zero mutes them.', sekNumber);
  Context.CreateGroup('ZXStorage', 'CF / SD interface');
  Context.CreateOption('ZXDivType', 'CF / SD interface', 'Attach divIDE (32 KiB RAM) or divMMC with esxDOS 0.8.9. Changes apply on open. F9 is the NMI button (also Scorpion Magic without a CF/SD interface).', sekCombo);
  Context.CreateOption('ZXDivRAM', 'DivMMC RAM', 'Select the installed divMMC RAM. divIDE always has 32 KiB.', sekCombo);
  Context.CreateOption('ZXDivImage', 'CF / SD image', 'Optional raw 512-byte-sector FAT image attached to tapes/snapshots. Open .ide or .mmc directly to boot the card.', sekPath);
  Context.CreateOption('ZXDivFirmware', 'Interface firmware', 'Optional 8 KiB ROM override; empty uses built-in esxDOS 0.8.9. The card needs matching SYS/BIN files.', sekPath);
  Context.CreateGroup('ZXMedia', 'Tape and disk');
  Context.CreateOption('ZXAutoLoad', 'Auto-load media', 'Automatically enter the tape loading command or start the +3 Loader / boot TR-DOS after opening media. Applies on open or reset.', sekSwitch);
  Context.CreateOption('ZXTapeAutoPlay', 'Play tape on startup', 'Start the tape automatically after opening or resetting. F7 toggles playback; F8 rewinds.', sekSwitch);
  Context.CreateOption('ZXTapeSpeed', 'Tape playback speed', 'Accelerate the whole machine while the tape is playing; accelerated playback is muted. F7 returns to normal speed.', sekCombo);
  Context.CreateOption('ZXFastForwardSpeed', 'Fast-forward speed (hold F10)', 'Accelerate any media while F10 is held. All hardware clocks are emulated; host audio is muted.', sekCombo);
  Context.CreateOption('ZXDiskWriteProtected', 'Write protect disk', 'Prevent writes and formatting. Existing saved disk changes remain readable.', sekSwitch);
  Context.CreateGroup('ZXKeyboard', 'Spectrum input');
  Context.CreateOption('ZXJoystick', 'Joystick emulation', 'Choose Kempston, QAOP/Space, both, or no joystick. Button bindings are in Controls.', sekCombo);
  Context.CreateOption('ZXKeyboard', 'Keyboard', 'Send keyboard input to Spectrum. Shift is CAPS SHIFT; Ctrl is SYMBOL SHIFT. Tape shortcuts remain available.', sekSwitch);
end;

procedure TZXSettings.Configuration(Context: TSettingsPageContext);
begin
  Context.Heading('GroupZXConfiguration');
  var Presets := TZXConfiguration.Presets;
  var Labels, Values: TArray<string>;
  SetLength(Labels, Length(Presets) + 1);
  SetLength(Values, Length(Labels));
  Labels[0] := 'Custom configuration';
  Values[0] := 'custom';
  for var I := 0 to High(Presets) do
  begin
    Labels[I + 1] := Presets[I].Name;
    Values[I + 1] := Presets[I].Id;
  end;
  Context.Draft.WriteString('Hardware', 'Preset', TZXConfiguration.SelectedPreset(Context.Draft));
  Context.Combo('ZXConfigurationPreset', 'Hardware', 'Preset', Labels, Values, 'custom');
end;

procedure TZXSettings.Video(Context: TSettingsPageContext);
begin
  Context.Heading('GroupZXHardware');
  Context.Combo('ZXTapeModel', 'Hardware', 'TapeModel',
    ['48K', '128K / 48 BASIC', 'Pentagon 128K / TR-DOS', 'Pentagon 512K / TR-DOS', 'Pentagon 1024K / TR-DOS', '16K', '+2 (grey) / 48 BASIC', '+2b (black) / 48 BASIC', '+3 / disk', 'Timex TC2048', 'Timex TC2068 / BASIC 64', 'Scorpion ZS-256', 'Profi+ 512K', 'Profi+ 1024K', 'Byte 48K', 'Byte-01 / KVU', 'Didaktik Gama 1987 / 80K', 'Didaktik Gama 1988 / 80K', 'Didaktik Gama 1989 / 80K', 'Microdigital TK90X', 'Microdigital TK95'], ['48k', '128k', 'pentagon', 'pentagon512', 'pentagon1024', '16k', 'plus2', 'plus2b', 'plus3', 'tc2048', 'tc2068', 'scorpion', 'profi512', 'profi', 'byte', 'byte01', 'gama87', 'gama88', 'gama', 'tk90x', 'tk95'], '48k');
  Context.Combo('ZXTKTiming', 'Hardware', 'TKTiming', ['Microdigital 60 Hz', 'Microdigital 50 Hz'], ['60hz', '50hz'], '60hz');
  Context.Check('ZXTKSpanish', 'Hardware', 'TKSpanish', False);
  Context.PathEdit('ZXTimexCartridge', 'Hardware', 'TimexCartridge', '', False);
  Context.PathEdit('ZXServiceROM', 'Hardware', 'ServiceROM', '', False);
  Context.Check('ZXByteCompatibility', 'Hardware', 'ByteCompatibility', True);
  Context.Check('ZXULAPlus', 'Hardware', 'ULAPlus', False);
  Context.Check('ZXTimexVideo', 'Hardware', 'TimexVideo', False);
  Context.Heading('GroupZXStorage');
  Context.Combo('ZXDivType', 'Hardware', 'DivType', ['None', 'divIDE / esxDOS', 'divMMC / esxDOS'], ['none', 'divide', 'divmmc'], 'none');
  Context.Combo('ZXDivRAM', 'Hardware', 'DivRAMKB', ['128 KiB', '512 KiB'], ['128', '512'], '128');
  Context.PathEdit('ZXDivImage', 'Hardware', 'DivImage', '', False);
  Context.PathEdit('ZXDivFirmware', 'Hardware', 'DivFirmware', '', False);
end;

procedure TZXSettings.Audio(Context: TSettingsPageContext);
begin
  Context.Heading('GroupZXSound');
  Context.Check('ZXTurboSound', 'Hardware', 'TurboSound', False);
  Context.Check('ZXTurboSoundFM', 'Hardware', 'TurboSoundFM', False);
  Context.Check('ZXSAA1099', 'Hardware', 'SAA1099', False);
  Context.Combo('ZXDAC', 'Hardware', 'DAC', ['None', 'Covox #FB', 'Covox #DD', 'GS-port Covox #B3', 'SounDrive 1.00', 'SpecDrum #DF', 'Next-DAC (audio only)'],
    ['none', 'covoxfb', 'covoxdd', 'covoxgs', 'soundrive', 'specdrum', 'nextdac'], 'none');
  Context.Check('ZXGeneralSound', 'Hardware', 'GeneralSound', False);
  Context.Combo('ZXGeneralSoundRAM', 'Hardware', 'GeneralSoundRAMKB', ['128 KiB', '512 KiB'], ['128', '512'], '128');
  Context.Check('ZXSID', 'Hardware', 'SID', False);
  Context.Combo('ZXSIDModel', 'Hardware', 'SIDModel', ['MOS 6581', 'MOS 8580'], ['0', '1'], '0');
  Context.Combo('ZXSIDClock', 'Hardware', 'SIDClock', ['PAL (985248 Hz)', 'NTSC (1022730 Hz)'], ['pal', 'ntsc'], 'pal');
  Context.Check('ZXMoonSound', 'Hardware', 'MoonSound', False);
  Context.Check('ZXMoonSoundIRQ', 'Hardware', 'MoonSoundIRQ', False);
  Context.Check('ZXMoonSoundInDOS', 'Hardware', 'MoonSoundInDOS', False);
  Context.Check('ZXDMAUSC', 'Hardware', 'DMAUSC', False);
  Context.Combo('ZXDMAUSCStereo', 'Hardware', 'DMAUSCStereo', ['AD left / BC right', 'AB left / CD right', 'Mono'], ['0', '1', '2'], '0');
  Context.Check('ZXDMAUSCULABypass', 'Hardware', 'DMAUSCULABypass', True);
  Context.Check('ZXNeoGS', 'Hardware', 'NeoGS', False);
  Context.Combo('ZXNeoGSRAM', 'Hardware', 'NeoGSRAMKB', ['512 KiB', '2 MiB', '4 MiB'], ['512', '2048', '4096'], '2048');
  Context.PathEdit('ZXNeoGSImage', 'Hardware', 'NeoGSImage', '', False);
  Context.Combo('ZXNextDACMode', 'Hardware', 'NextDACMode', ['All DAC aliases', 'SounDrive mode 1', 'SounDrive mode 2', 'Profi stereo Covox', 'Stereo Covox', 'Pentagon / ATM mono', 'GS Covox mono', 'SpecDrum mono', 'NextReg mirrors only'], ['0', '1', '2', '3', '4', '5', '6', '7', '8'], '0');
  Context.Check('ZXNextDACStartup', 'Hardware', 'NextDACStartup', True);
  Context.Number('ZXExpansionVolume', 'Audio', 'ExpansionVolume', 100, 100);
  Context.Combo('ZXPSGModel', 'Audio', 'PSGModel', ['AY-3-8912', 'YM2149'], ['ay', 'ym'], 'ay');
  Context.Combo('ZXStereo', 'Audio', 'Stereo', ['ABC', 'Mono', 'ACB', 'BAC', 'BCA', 'CAB', 'CBA'],
    ['abc', 'mono', 'acb', 'bac', 'bca', 'cab', 'cba'], 'abc');
  Context.Number('ZXVI53Volume', 'Audio', 'PITVolume', 100, 100);
  Context.Number('ZXAYVolume', 'Audio', 'AYVolume', 100, 100);
  Context.Number('ZXBeeperVolume', 'Audio', 'BeeperVolume', 100, 100);
end;

procedure TZXSettings.Peripherals(Context: TSettingsPageContext);
begin
  Context.Heading('GroupZXKeyboard');
  Context.Check('ZXKeyboard', 'Ports', 'KeyboardEnabled', True);
  Context.Combo('ZXJoystick', 'Ports', 'JoystickMode',
    ['Kempston + QAOP/Space', 'Kempston', 'QAOP/Space', 'Disconnected', 'Interface 2 (6–0)', 'Interface 2 (1–5)'],
    ['both', 'kempston', 'qaop', 'none', 'sinclair1', 'sinclair2'], 'both');
  Context.Check('ZXSecondJoystick', 'Ports', 'SecondJoystick', False);
  Context.Check('ZXKempstonMouse', 'Hardware', 'KempstonMouse', False);
  Context.Heading('GroupZXMedia');
  Context.Check('ZXAutoLoad', 'Media', 'AutoLoad', True);
  Context.Check('ZXTapeAutoPlay', 'Media', 'TapeAutoPlay', True);
  Context.Combo('ZXTapeSpeed', 'Media', 'TapeSpeed', ['1x (normal)', '2x', '4x', '8x'], ['1', '2', '4', '8'], '1');
  Context.Combo('ZXFastForwardSpeed', 'Media', 'FastForwardSpeed', ['1x (normal)', '2x', '4x', '8x'], ['1', '2', '4', '8'], '8');
  Context.Check('ZXDiskWriteProtected', 'Media', 'DiskWriteProtected', False);
end;

end.

