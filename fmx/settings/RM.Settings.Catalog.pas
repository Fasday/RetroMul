unit RM.Settings.Catalog;

interface

uses
  RM.Settings.Platform;

var
  SettingsPlatforms: TSettingsPlatformRegistry;
  // Compatibility lookup tables, generated from the registry. Index zero is Main.
  SettingsCoreIds, SettingsPageNames: TArray<string>;
  SettingsCoreOrder: TArray<Integer>;

implementation

uses
  Core.RomFormat, RM.Gamepad, RM.Settings.GameBoy, RM.Settings.GBA,
  RM.Settings.NES, RM.Settings.SNES, RM.Settings.N64, RM.Settings.MegaDrive,
  RM.Settings.Sega8Bit, RM.Settings.GameBoyColor, RM.Settings.SG1000,
  RM.Settings.SC3000, RM.Settings.SF7000, RM.Settings.Multivision,
  RM.Settings.MasterSystem, RM.Settings.NeoGeo;

procedure RegisterPlatforms;
begin
  SettingsPlatforms.Add(TGameBoySettings.Create(SETTINGS_PAGE_GB, ROM_SYSTEM_GB,
      'Game Boy', 'Nintendo', 'GB DMG MGB', TScreenGamepadLayout.GameBoy, 1));
  SettingsPlatforms.Add(TGameBoyColorSettings.Create(SETTINGS_PAGE_GBC, ROM_SYSTEM_GBC,
      'Game Boy Color', 'Nintendo', 'GBC CGB', TScreenGamepadLayout.GameBoyColor, 1));
  SettingsPlatforms.Add(TGBASettings.Create(SETTINGS_PAGE_GBA, ROM_SYSTEM_GBA,
      'Game Boy Advance', 'Nintendo', 'GBA AGB', TScreenGamepadLayout.GameBoyAdvance, 1));
  SettingsPlatforms.Add(TNESSettings.Create(SETTINGS_PAGE_NES, ROM_SYSTEM_NES,
      'NES / Famicom', 'Nintendo', 'NES Famicom Dendy', TScreenGamepadLayout.Nes, 2));
  SettingsPlatforms.Add(TSNESSettings.Create(SETTINGS_PAGE_SNES, ROM_SYSTEM_SNES,
      'Super Nintendo', 'Nintendo', 'SNES Super Famicom', TScreenGamepadLayout.Snes, 2));
  SettingsPlatforms.Add(TN64Settings.Create(SETTINGS_PAGE_N64, ROM_SYSTEM_N64,
      'Nintendo 64', 'Nintendo', 'N64', TScreenGamepadLayout.Nintendo64, 4));
  SettingsPlatforms.Add(TMegaDriveSettings.Create(SETTINGS_PAGE_MD, ROM_SYSTEM_MD,
      'Mega Drive', 'Sega', 'MD Genesis', TScreenGamepadLayout.Sega, 2));
  SettingsPlatforms.Add(TSG1000Settings.Create(SETTINGS_PAGE_SG1000, ROM_SYSTEM_SG1000,
      'SG-1000', 'Sega', 'SG1000 SG-1000 II SK-1100', TScreenGamepadLayout.Nes, 2));
  SettingsPlatforms.Add(TSC3000Settings.Create(SETTINGS_PAGE_SC3000, ROM_SYSTEM_SC3000,
      'SC-3000', 'Sega', 'SC3000 SC-3000H', TScreenGamepadLayout.Nes, 2));
  SettingsPlatforms.Add(TSF7000Settings.Create(SETTINGS_PAGE_SF7000, ROM_SYSTEM_SF7000,
      'SF-7000', 'Sega', 'SF7000 floppy', TScreenGamepadLayout.Nes, 2));
  SettingsPlatforms.Add(TMasterSystemSettings.Create(SETTINGS_PAGE_SMS, ROM_SYSTEM_SMS,
      'Master System', 'Sega', 'SMS Mark III', TScreenGamepadLayout.Nes, 2));
  SettingsPlatforms.Add(TMultivisionSettings.Create(SETTINGS_PAGE_MULTIVISION, ROM_SYSTEM_OMV,
      'Multivision', 'Tsukuda Original', 'OMV Othello Multivision', TScreenGamepadLayout.Nes, 2));
  SettingsPlatforms.Add(TNeoGeoSettings.Create(SETTINGS_PAGE_NEOGEO, ROM_SYSTEM_NEOGEO,
      'Neo Geo (CD)', 'SNK', 'NG NeoGeo Neo Geo CD', TScreenGamepadLayout.NeoGeo, 2));
  SetLength(SettingsCoreIds, SettingsPlatforms.MaxPageId + 1);
  SetLength(SettingsPageNames, Length(SettingsCoreIds));
  SettingsPageNames[0] := 'Main';
  var Ordered := SettingsPlatforms.Matching('');
  SetLength(SettingsCoreOrder, Length(Ordered));
  for var i := 0 to High(Ordered) do
  begin
    var platform := Ordered[i];
    SettingsCoreOrder[i] := platform.PageId;
    SettingsCoreIds[platform.PageId] := platform.CoreId;
    SettingsPageNames[platform.PageId] := platform.Name;
  end;
end;

initialization
  SettingsPlatforms := TSettingsPlatformRegistry.Create;
  RegisterPlatforms;

finalization
  SettingsPlatforms.Free;

end.

