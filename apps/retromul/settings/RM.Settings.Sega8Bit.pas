unit RM.Settings.Sega8Bit;

interface

uses
  RM.Settings.Platform;

type
  // Common TMS9918/PSG controls; each platform supplies its own hardware page.
  TSega8BitSettings = class(TSettingsPlatform)
  public
    procedure Initialize(Context: TSettingsPageContext); override;
    procedure Video(Context: TSettingsPageContext); override;
    procedure Audio(Context: TSettingsPageContext); override;
    procedure Hardware(Context: TSettingsPageContext); virtual;
    procedure Keyboard(Context: TSettingsPageContext; Cassette: Boolean);
  end;

implementation

uses
  System.SysUtils, FMX.Types, FMX.StdCtrls, RM.Icons;

procedure TSega8BitSettings.Initialize(Context: TSettingsPageContext);
begin
  Context.CreateGroup('SegaHardware', 'Sega hardware');
  Context.CreateGroup('SegaVideo', 'Video layers');
  Context.CreateGroup('SegaSound', 'Sound chips');
  Context.CreateGroup('SegaKeyboard', 'Keyboard and cassette');
  Context.CreateGroup('SegaDisk', 'Floppy drive');
  Context.CreateOption('RowSegaGGRegion', 'Console region', 'Automatic follows the cartridge header. Some games require Japanese hardware.', sekCombo);
  Context.CreateOption('RowSegaModel', 'Console model', 'Select the hardware used when opening a ROM.', sekCombo);
  Context.CreateOption('RowSegaBIOS', 'BIOS file', 'Optional 8, 16 or 32 KiB Master System BIOS.', sekPath);
  Context.CreateOption('RowSegaBIOSEnabled', 'Use BIOS', 'Run the selected BIOS before the cartridge.', sekSwitch);
  Context.CreateOption('RowSegaIPL', 'IPL ROM file', 'Required 8 KiB SF-7000 firmware. Leave empty to search beside the disk.', sekPath);
  Context.CreateOption('RowSegaWarmBoot', 'Fast boot', 'Skip the SF-7000 startup memory tests for a faster boot.', sekSwitch);
  Context.CreateOption('RowSegaMapper', 'Cartridge mapper', 'Auto detects known cartridges. Override for unrecognized ROMs.', sekCombo);
  Context.CreateOption('RowSegaShowBackground', 'Show background', 'Display the background layer.', sekSwitch);
  Context.CreateOption('RowSegaShowSprites', 'Show sprites', 'Display the sprite layer.', sekSwitch);
  Context.CreateOption('RowSegaRemoveSpriteLimit', 'Remove sprite limit', 'Reduce sprite flicker. Extra sprites may reveal unexpected graphics.', sekSwitch);
  for var i := 1 to 4 do
    Context.CreateOption('RowSegaChannel' + IntToStr(i) + 'Volume', 'PSG channel ' + IntToStr(i) + ' volume (%)',
      'Channels 1–3 are tones; channel 4 is noise. Zero mutes the channel.', sekNumber);
  Context.CreateOption('RowSegaFMEnabled', 'FM sound (YM2413)', 'Enable the FM sound expansion for games that support it.', sekSwitch);
  Context.CreateOption('RowSegaFMVolume', 'FM volume (%)', 'Adjust FM sound independently of the PSG channels.', sekNumber);
  Context.CreateOption('RowSegaKeyboardEnabled', 'Physical keyboard', 'Send computer key presses to the emulated keyboard. The screen keyboard remains available.', sekSwitch);
  Context.CreateOption('RowSegaTapeFile', 'Initial cassette', 'Optional PCM WAV cassette loaded when opening a ROM.', sekPath);
  Context.CreateOption('RowSegaTapeAutoPlay', 'Play cassette on startup', 'Start playback of the initial cassette automatically.', sekSwitch);
  Context.CreateOption('RowSegaWriteProtected', 'Write protect disk', 'Prevent the emulated drive from writing or formatting the disk.', sekSwitch);
end;

procedure TSega8BitSettings.Video(Context: TSettingsPageContext);
begin
  if Context.PageId = SETTINGS_PAGE_SMS then
    Context.Combo('RowNESregion', 'Video', 'Region', [Translate('Auto'), 'NTSC', 'PAL'], ['Auto', 'NTSC', 'PAL'], 'Auto')
  else
    Context.Combo('RowNESregion', 'Video', 'Region', ['NTSC', 'PAL'], ['NTSC', 'PAL'], 'NTSC');
  (Context.Owner.FindComponent('LabelRowNESregionTitle') as TLabel).Text := 'NTSC / PAL';
  if Context.PageId = SETTINGS_PAGE_SMS then
    (Context.Owner.FindComponent('LabelRowNESregionDetail') as TLabel).Text :=
      Translate('Auto detects the ROM region; unknown ROMs use NTSC. Restart with Shift+R to apply.')
  else
    (Context.Owner.FindComponent('LabelRowNESregionDetail') as TLabel).Text := Translate('Select the video standard and frame timing.');
  Hardware(Context);
  Context.Heading('GroupSegaVideo');
  Context.Check('RowSegaShowBackground', 'Video', 'ShowBackground', True);
  Context.Check('RowSegaShowSprites', 'Video', 'ShowSprites', True);
  Context.Check('RowSegaRemoveSpriteLimit', 'Video', 'RemoveSpriteLimit', False);
end;

procedure TSega8BitSettings.Audio(Context: TSettingsPageContext);
begin
  Context.Heading('GroupSegaSound');
  for var i := 1 to 4 do
    Context.Number('RowSegaChannel' + IntToStr(i) + 'Volume', 'Audio', 'Channel' + IntToStr(i) + 'Volume', 100, 100);
end;

procedure TSega8BitSettings.Hardware(Context: TSettingsPageContext);
begin

end;

procedure TSega8BitSettings.Keyboard(Context: TSettingsPageContext; Cassette: Boolean);
begin
  Context.Heading('GroupSegaKeyboard');
  Context.Check('RowSegaKeyboardEnabled', 'Ports', 'KeyboardEnabled', True);
  if Cassette then
  begin
    Context.PathEdit('RowSegaTapeFile', 'Ports', 'TapeFile', '', False);
    Context.Check('RowSegaTapeAutoPlay', 'Ports', 'TapeAutoPlay', False);
  end;
end;

end.

