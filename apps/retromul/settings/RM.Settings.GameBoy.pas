unit RM.Settings.GameBoy;

interface

uses
  RM.Settings.Platform, System.IniFiles;

type
  TGameBoySettings = class(TSettingsPlatform)
  public
    procedure Display(Context: TSettingsPageContext); virtual;
    procedure Initialize(Context: TSettingsPageContext); override;
    procedure Video(Context: TSettingsPageContext); override;
    procedure Audio(Context: TSettingsPageContext); override;
    procedure Peripherals(Context: TSettingsPageContext); override;
  end;

implementation

uses
  System.SysUtils, System.Math, FMX.Types, FMX.StdCtrls, FMX.ListBox, RM.Icons,
  GB.Memory, GB.Palettes;

procedure TGameBoySettings.Initialize(Context: TSettingsPageContext);
begin
  Context.CreateGroup('BootROM', 'Boot ROM');
  Context.CreateOption('RowBootModel', 'Boot ROM model', 'Select a console boot sequence, or start the game directly.', sekCombo);
  for var Model := TGBBootModel.DMG to High(TGBBootModel) do
  begin
    var Detail := 'Choose your boot ROM file for this model.';
    if Model in [TGBBootModel.DMG, TGBBootModel.MGB] then
      Detail := 'Leave empty to use the built-in boot ROM.';
    Context.CreateOption('RowBootFile' + GB_BOOT_MODEL_KEYS[Model], 'Boot ROM file', Detail, sekPath);
  end;
  Context.CreateGroup('Rumble', 'Rumble');
  Context.CreateOption('RowRumble', 'Cartridge rumble', 'Vibrate the device when the game activates its rumble motor.', sekSwitch);
  Context.CreateGroup('GBEnhancements', 'Game Boy enhancements');
  var Names: TArray<string> := ['FrameBlending', 'BGPalette', 'OBJ0Palette', 'OBJ1Palette',
      'ShowBackground', 'ShowWindow', 'ShowSprites', 'RemoveSpriteLimit', 'Overclock',
      'Channel1Volume', 'Channel2Volume', 'Channel3Volume', 'Channel4Volume'];
  var Captions: TArray<string> := ['Frame blending', 'Background palette', 'OBJ0 palette', 'OBJ1 palette',
      'Show background', 'Show window', 'Show sprites', 'Remove sprite limit', 'CPU speed (%)',
      'Channel 1 volume (%)', 'Channel 2 volume (%)', 'Wave channel volume (%)', 'Noise channel volume (%)'];
  var Details: TArray<string> := ['Blend the current and previous emulated frames equally.',
      'Palette for monochrome games.', 'Palette for monochrome games.', 'Palette for monochrome games.',
      'Display the background layer.', 'Display the window layer.', 'Display the sprite layer.',
      'Display up to 40 sprites per line; games may show unexpected graphics.',
      '100 is normal speed; higher values reduce CPU slowdown and may affect games.',
      'Square wave with frequency sweep.', 'Second square wave channel.', 'Programmable wave channel.', 'Noise channel.'];
  for var i := 0 to High(Names) do
  begin
    var Kind := sekNumber;
    if i in [0, 4, 5, 6, 7] then
      Kind := sekSwitch;
    if i in [1, 2, 3] then
      Kind := sekCombo;
    Context.CreateOption('RowGB' + Names[i], Captions[i], Details[i], Kind);
  end;
end;

procedure TGameBoySettings.Display(Context: TSettingsPageContext);
begin
  var Scaling := Context.Owner.FindComponent('SettingsComboBoxRowImagescalingEditor') as TComboBox;
  var Labels, Values: TArray<string>;
  SetLength(Labels, SCREEN_PALETTE_COUNT);
  SetLength(Values, SCREEN_PALETTE_COUNT);
  for var i := 0 to SCREEN_PALETTE_COUNT - 1 do
  begin
    Labels[i] := ScreenPalettes[i].Name;
    Values[i] := IntToStr(i);
  end;
  var Palette := Context.Combo('RowGameBoypalette', 'Video', 'Palette', Labels, Values, '0');
  Context.PalettePreview(Palette, Scaling);
end;

procedure TGameBoySettings.Video(Context: TSettingsPageContext);
begin
  Display(Context);
  Context.Heading('GroupGBEnhancements');
  Context.Check('RowGBFrameBlending', 'Video', 'FrameBlending', False);
  var PaletteLabels, PaletteValues: TArray<string>;
  SetLength(PaletteLabels, SCREEN_PALETTE_COUNT + 1);
  SetLength(PaletteValues, SCREEN_PALETTE_COUNT + 1);
  PaletteLabels[0] := Translate('Default palette');
  PaletteValues[0] := '-1';
  for var i := 0 to SCREEN_PALETTE_COUNT - 1 do
  begin
    PaletteLabels[i + 1] := ScreenPalettes[i].Name;
    PaletteValues[i + 1] := IntToStr(i);
  end;
  Context.Combo('RowGBBGPalette', 'Video', 'BGPalette', PaletteLabels, PaletteValues, '-1');
  Context.Combo('RowGBOBJ0Palette', 'Video', 'OBJ0Palette', PaletteLabels, PaletteValues, '-1');
  Context.Combo('RowGBOBJ1Palette', 'Video', 'OBJ1Palette', PaletteLabels, PaletteValues, '-1');
  Context.Check('RowGBShowBackground', 'Video', 'ShowBackground', True);
  Context.Check('RowGBShowWindow', 'Video', 'ShowWindow', True);
  Context.Check('RowGBShowSprites', 'Video', 'ShowSprites', True);
  Context.Check('RowGBRemoveSpriteLimit', 'Video', 'RemoveSpriteLimit', False);
  var CPUPercent := Context.Number('RowGBOverclock', 'Emulation', 'Overclock', 100, 400);
  CPUPercent.Min := 100;
  CPUPercent.Value := EnsureRange(CPUPercent.Value, 100, 400);
  Context.Heading('GroupBootROM');
  var BootLabels, BootKeys: TArray<string>;
  SetLength(BootLabels, Ord(High(TGBBootModel)) + 1);
  SetLength(BootKeys, Length(BootLabels));
  for var Model := Low(TGBBootModel) to High(TGBBootModel) do
  begin
    BootLabels[Ord(Model)] := Translate(GB_BOOT_MODEL_LABELS[Model]);
    BootKeys[Ord(Model)] := GB_BOOT_MODEL_KEYS[Model];
  end;
  var BootModel := Context.Combo('RowBootModel', 'Boot', 'Model', BootLabels, BootKeys, 'none');
  BootModel.OnChange := Context.OnRebuild;
  var SelectedBoot := GBBootModel(Context.Draft.ReadString('Boot', 'Model', 'none'));
  if SelectedBoot <> TGBBootModel.Skip then
    Context.PathEdit('RowBootFile' + GB_BOOT_MODEL_KEYS[SelectedBoot], 'Boot',
      GB_BOOT_MODEL_KEYS[SelectedBoot] + 'File', '', False);
end;

procedure TGameBoySettings.Audio(Context: TSettingsPageContext);
begin
  for var i := 1 to 4 do
    Context.Number('RowGBChannel' + IntToStr(i) + 'Volume', 'Audio', 'Channel' + IntToStr(i) + 'Volume', 100, 100);
end;

procedure TGameBoySettings.Peripherals(Context: TSettingsPageContext);
begin
  Context.Heading('GroupRumble');
  Context.Check('RowRumble', 'Peripherals', 'Rumble', True);
end;

end.

