unit Core.Platforms;

interface

uses System.SysUtils, System.Generics.Collections;

{$SCOPEDENUMS ON}

type
  TRomSystem = (Unknown, NES, GB, GBC, MD, SNES, NeoGeo, GBA, NeoGeoCD, N64, SG1000, SC3000,
    SF7000, Multivision, SMS, GameGear, GameWatch, PCE, SuperGrafx, PCECD);
  TPlatformPadLayout = (Nes, Sega, Snes, GameBoy, GameBoyColor, NeoGeo, Dendy, GameBoyAdvance, Nintendo64, PCE);

const
  SETTINGS_PAGE_MAIN = 0;
  SETTINGS_PAGE_GB = 1;
  SETTINGS_PAGE_GBC = 2;
  SETTINGS_PAGE_NES = 3;
  SETTINGS_PAGE_MD = 4;
  SETTINGS_PAGE_SNES = 5;
  SETTINGS_PAGE_NEOGEO = 6;
  SETTINGS_PAGE_GBA = 7;
  SETTINGS_PAGE_N64 = 8;
  SETTINGS_PAGE_SG1000 = 9;
  SETTINGS_PAGE_SC3000 = 10;
  SETTINGS_PAGE_SF7000 = 11;
  SETTINGS_PAGE_MULTIVISION = 12;
  SETTINGS_PAGE_SMS = 13;
  SETTINGS_PAGE_GG = 14;
  SETTINGS_PAGE_GW = 15;
  SETTINGS_PAGE_PCE = 16;
  SETTINGS_PAGE_SGX = 17;
  SETTINGS_PAGE_PCECD = 18;
  SETTINGS_PAGE_NEOGEOCD = 19;

type
  // Stable IDs and settings page numbers preserve existing collections and INI files.
  TPlatformInfo = record
    System: TRomSystem;
    Id, CoreId, Name, ShortName, Manufacturer, SearchTerms, Folder, IconData: string;
    ScanFolders, Extensions: TArray<string>;
    SettingsPageId: Integer;
    SettingsProfile, SettingsCoreId, LegacySettingsId: string;
    PadLayout: TPlatformPadLayout;
    Ports: Integer;
    function CopyInfo: TPlatformInfo;
  end;

  TPlatformRegistry = class sealed
  strict private
    class var FItems: TList<TPlatformInfo>;
    class procedure RegisterPlatform(System: TRomSystem; const Id, Name, ShortName,
      Manufacturer, SearchTerms, Folder: string; const ScanFolders, Extensions: array of string;
      SettingsPageId: Integer; const SettingsProfile, SettingsCoreId: string;
      PadLayout: TPlatformPadLayout; Ports: Integer; const IconData: string;
      const LegacySettingsId: string = ''); static;
  public
    class constructor Create;
    class destructor Destroy;
    class function All: TArray<TPlatformInfo>; static;
    class function Find(const Id: string; out Info: TPlatformInfo): Boolean; overload; static;
    class function Find(System: TRomSystem; out Info: TPlatformInfo): Boolean; overload; static;
    class function Require(const Id: string): TPlatformInfo; static;
    class function FileFilter: string; static;
  end;

implementation

uses System.Generics.Defaults, Core.RomFormat, Core.Platforms.Icons;

function TPlatformInfo.CopyInfo: TPlatformInfo;
begin
  Result := Self;
  Result.ScanFolders := Copy(ScanFolders);
  Result.Extensions := Copy(Extensions);
end;

class constructor TPlatformRegistry.Create;
begin
  FItems := TList<TPlatformInfo>.Create;
  RegisterPlatform(TRomSystem.GameWatch, ROM_SYSTEM_GW, 'Game & Watch', 'Game & Watch',
    'Nintendo', 'GW MGW LCD Micro Vs', 'gw', ['gw'], [ROM_EXTENSION_GW, ROM_EXTENSION_MGW, ROM_EXTENSION_ZIP],
    SETTINGS_PAGE_GW, '', 'gw', TPlatformPadLayout.Snes, 2, PlatformIconGW);
  RegisterPlatform(TRomSystem.GB, ROM_SYSTEM_GB, 'Game Boy', 'GB',
    'Nintendo', 'GB DMG MGB', 'gb', ['gb'], [ROM_EXTENSION_GB, ROM_EXTENSION_GBX],
    SETTINGS_PAGE_GB, 'GameBoy', 'gb', TPlatformPadLayout.GameBoy, 1, PlatformIconGB);
  RegisterPlatform(TRomSystem.GBC, ROM_SYSTEM_GBC, 'Game Boy Color', 'GBC',
    'Nintendo', 'GBC CGB', 'gbc', ['gbc'], [ROM_EXTENSION_GBC, ROM_EXTENSION_GBX],
    SETTINGS_PAGE_GBC, 'GameBoyColor', 'gbc', TPlatformPadLayout.GameBoyColor, 1, PlatformIconGBC);
  RegisterPlatform(TRomSystem.GBA, ROM_SYSTEM_GBA, 'Game Boy Advance', 'GBA',
    'Nintendo', 'GBA AGB', 'gba', ['gba'], [ROM_EXTENSION_GBA],
    SETTINGS_PAGE_GBA, 'GBA', 'gba', TPlatformPadLayout.GameBoyAdvance, 1, PlatformIconGBA);
  RegisterPlatform(TRomSystem.NES, ROM_SYSTEM_NES, 'NES / Famicom', 'NES',
    'Nintendo', 'NES Famicom Dendy', 'nes', ['nes'], [ROM_EXTENSION_NES],
    SETTINGS_PAGE_NES, 'NES', 'nes', TPlatformPadLayout.Nes, 2, PlatformIconNES);
  RegisterPlatform(TRomSystem.SNES, ROM_SYSTEM_SNES, 'Super Nintendo', 'SNES',
    'Nintendo', 'SNES Super Famicom', 'snes', ['snes'], [ROM_EXTENSION_SFC, ROM_EXTENSION_SMC, ROM_EXTENSION_SWC, ROM_EXTENSION_FIG],
    SETTINGS_PAGE_SNES, 'SNES', 'snes', TPlatformPadLayout.Snes, 2, PlatformIconSNES);
  RegisterPlatform(TRomSystem.N64, ROM_SYSTEM_N64, 'Nintendo 64', 'Nintendo 64',
    'Nintendo', 'N64', 'n64', ['n64'], [ROM_EXTENSION_Z64, ROM_EXTENSION_N64, ROM_EXTENSION_V64],
    SETTINGS_PAGE_N64, 'N64', 'n64', TPlatformPadLayout.Nintendo64, 4, PlatformIconN64);
  RegisterPlatform(TRomSystem.MD, ROM_SYSTEM_MD, 'Mega Drive', 'Mega Drive',
    'Sega', 'MD Genesis', 'megadrive', ['megadrive'], [ROM_EXTENSION_SMD, ROM_EXTENSION_BIN, ROM_EXTENSION_GEN, ROM_EXTENSION_MD],
    SETTINGS_PAGE_MD, 'MegaDrive', 'md', TPlatformPadLayout.Sega, 2, PlatformIconMD);
  RegisterPlatform(TRomSystem.SG1000, ROM_SYSTEM_SG1000, 'SG-1000', 'SG-1000',
    'Sega', 'SG1000 SG-1000 II SK-1100', 'sg1000', ['sg1000'], [ROM_EXTENSION_SG, ROM_EXTENSION_SMS],
    SETTINGS_PAGE_SG1000, 'SG1000', 'sg1000', TPlatformPadLayout.Nes, 2, PlatformIconSG1000);
  RegisterPlatform(TRomSystem.SC3000, ROM_SYSTEM_SC3000, 'SC-3000', 'SC-3000',
    'Sega', 'SC3000 SC-3000H', 'sc3000', ['sc3000', 'sg1000'], [ROM_EXTENSION_SC],
    SETTINGS_PAGE_SC3000, 'SC3000', 'sc3000', TPlatformPadLayout.Nes, 2, PlatformIconSC3000);
  RegisterPlatform(TRomSystem.SF7000, ROM_SYSTEM_SF7000, 'SF-7000', 'SF-7000',
    'Sega', 'SF7000 floppy', 'sf7000', ['sf7000', 'sg1000'], [ROM_EXTENSION_SF7, ROM_EXTENSION_SF, ROM_EXTENSION_DSK],
    SETTINGS_PAGE_SF7000, 'SF7000', 'sf7000', TPlatformPadLayout.Nes, 2, PlatformIconSF7000);
  RegisterPlatform(TRomSystem.SMS, ROM_SYSTEM_SMS, 'Master System', 'Master System',
    'Sega', 'SMS Mark III', 'sms', ['sms'], [ROM_EXTENSION_SMS],
    SETTINGS_PAGE_SMS, 'MasterSystem', 'sms', TPlatformPadLayout.Nes, 2, PlatformIconSMS);
  RegisterPlatform(TRomSystem.GameGear, ROM_SYSTEM_GG, 'Game Gear', 'Game Gear',
    'Sega', 'GG GameGear', 'gg', ['gg'], [ROM_EXTENSION_GG],
    SETTINGS_PAGE_GG, 'GameGear', 'gg', TPlatformPadLayout.Nes, 1, PlatformIconGG);
  RegisterPlatform(TRomSystem.Multivision, ROM_SYSTEM_OMV, 'Multivision', 'Multivision',
    'Tsukuda Original', 'OMV Othello Multivision', 'omv', ['omv', 'sg1000'], [ROM_EXTENSION_MV],
    SETTINGS_PAGE_MULTIVISION, 'Multivision', 'omv', TPlatformPadLayout.Nes, 2, PlatformIconOMV);
  RegisterPlatform(TRomSystem.NeoGeo, ROM_SYSTEM_NEOGEO, 'Neo Geo', 'Neo Geo',
    'SNK', 'NG NeoGeo Neo Geo CD', 'neogeo', ['neogeo'], [ROM_EXTENSION_ZIP, ROM_EXTENSION_NEO],
    SETTINGS_PAGE_NEOGEO, 'NeoGeo', 'neogeo', TPlatformPadLayout.NeoGeo, 2, PlatformIconNEOGEO);
  RegisterPlatform(TRomSystem.NeoGeoCD, ROM_SYSTEM_NEOGEOCD, 'Neo Geo CD', 'Neo Geo CD',
    'SNK', 'NG NeoGeo CD', 'neogeocd', ['neogeocd'], [ROM_EXTENSION_CUE, ROM_EXTENSION_ISO, ROM_EXTENSION_CHD],
    SETTINGS_PAGE_NEOGEOCD, 'NeoGeo', 'neogeocd', TPlatformPadLayout.NeoGeo, 2, PlatformIconNEOGEOCD, ROM_SYSTEM_NEOGEO);
  RegisterPlatform(TRomSystem.PCE, ROM_SYSTEM_PCE, 'PC Engine / TurboGrafx-16', 'PC Engine',
    'NEC', 'PCE CoreGrafx Shuttle GT LT TurboExpress', 'pcengine', ['pcengine', 'pce'], [ROM_EXTENSION_PCE, ROM_EXTENSION_ZIP],
    SETTINGS_PAGE_PCE, 'PCE', 'pce', TPlatformPadLayout.PCE, 5, PlatformIconPCE);
  RegisterPlatform(TRomSystem.SuperGrafx, ROM_SYSTEM_SGX, 'SuperGrafx', 'SuperGrafx',
    'NEC', 'SGX', 'sgx', ['sgx', 'supergrafx', 'pcengine', 'pce'], [ROM_EXTENSION_SGX, ROM_EXTENSION_PCE, ROM_EXTENSION_ZIP],
    SETTINGS_PAGE_SGX, 'PCE', 'sgx', TPlatformPadLayout.PCE, 5, PlatformIconSGX);
  RegisterPlatform(TRomSystem.PCECD, ROM_SYSTEM_PCECD, 'PC Engine CD', 'PC Engine CD',
    'NEC', 'CD-ROM2 Super CD-ROM2 Duo TurboDuo Arcade Card', 'pcecd', ['pcecd'], [ROM_EXTENSION_CUE, ROM_EXTENSION_ISO, ROM_EXTENSION_CHD],
    SETTINGS_PAGE_PCECD, 'PCE', 'pcecd', TPlatformPadLayout.PCE, 5, PlatformIconPCECD);
  FItems.Sort(TComparer<TPlatformInfo>.Construct(
    function(const A, B: TPlatformInfo): Integer
    begin
      Result := CompareText(A.Manufacturer, B.Manufacturer);
      if Result = 0 then Result := CompareText(A.Name, B.Name);
    end));
end;

class destructor TPlatformRegistry.Destroy;
begin
  FItems.Free;
end;

class procedure TPlatformRegistry.RegisterPlatform(System: TRomSystem;
  const Id, Name, ShortName, Manufacturer, SearchTerms, Folder: string;
  const ScanFolders, Extensions: array of string; SettingsPageId: Integer;
  const SettingsProfile, SettingsCoreId: string; PadLayout: TPlatformPadLayout; Ports: Integer; const IconData, LegacySettingsId: string);
begin
  if (System = TRomSystem.Unknown) or (Id = '') or (Name = '') or
    (Manufacturer = '') or (Folder = '') or (Length(ScanFolders) = 0) or
    (Length(Extensions) = 0) or (SettingsPageId <= 0) or (Ports < 1) or (Ports > 8) or
    (SettingsCoreId = '') or (IconData = '') then
    raise EArgumentException.Create('Invalid platform: ' + Id);
  for var Existing in FItems do
    if (Existing.System = System) or SameText(Existing.Id, Id) or
      (Existing.SettingsPageId = SettingsPageId) or SameText(Existing.SettingsCoreId, SettingsCoreId) then
      raise EArgumentException.Create('Duplicate platform: ' + Id);
  var Item: TPlatformInfo;
  Item.System := System;
  Item.Id := Id;
  Item.CoreId := Id.ToUpper;
  Item.Name := Name;
  Item.IconData := IconData;
  Item.ShortName := ShortName;
  Item.Manufacturer := Manufacturer;
  Item.SearchTerms := SearchTerms;
  Item.Folder := Folder;
  SetLength(Item.ScanFolders, Length(ScanFolders));
  for var I := 0 to High(ScanFolders) do Item.ScanFolders[I] := ScanFolders[I];
  SetLength(Item.Extensions, Length(Extensions));
  for var I := 0 to High(Extensions) do Item.Extensions[I] := Extensions[I];
  Item.SettingsPageId := SettingsPageId;
  Item.SettingsProfile := SettingsProfile;
  Item.SettingsCoreId := SettingsCoreId;
  Item.LegacySettingsId := LegacySettingsId;
  Item.PadLayout := PadLayout;
  Item.Ports := Ports;
  FItems.Add(Item);
end;

class function TPlatformRegistry.All: TArray<TPlatformInfo>;
begin
  SetLength(Result, FItems.Count);
  for var I := 0 to FItems.Count - 1 do Result[I] := FItems[I].CopyInfo;
end;

class function TPlatformRegistry.Find(const Id: string; out Info: TPlatformInfo): Boolean;
begin
  for var Item in FItems do
    if SameText(Item.Id, Id) or SameText(Item.Folder, Id) then
    begin
      Info := Item.CopyInfo;
      Exit(True);
    end;
  Info := Default(TPlatformInfo);
  Result := False;
end;

class function TPlatformRegistry.Find(System: TRomSystem; out Info: TPlatformInfo): Boolean;
begin
  for var Item in FItems do
    if Item.System = System then
    begin
      Info := Item.CopyInfo;
      Exit(True);
    end;
  Info := Default(TPlatformInfo);
  Result := False;
end;

class function TPlatformRegistry.Require(const Id: string): TPlatformInfo;
begin
  if not Find(Id, Result) then
    raise EArgumentException.Create('Unknown platform: ' + Id);
end;

class function TPlatformRegistry.FileFilter: string;
begin
  var Extensions := TList<string>.Create;
  try
    Result := '';
    for var Item in All do
    begin
      var Masks := '';
      for var Ext in Item.Extensions do
      begin
        if not Extensions.Contains(Ext) then Extensions.Add(Ext);
        if Masks <> '' then Masks := Masks + ';';
        Masks := Masks + '*' + Ext;
      end;
      Result := Result + '|' + Item.Name + '|' + Masks;
    end;
    var Masks := '';
    for var Ext in Extensions do
    begin
      if Masks <> '' then Masks := Masks + ';';
      Masks := Masks + '*' + Ext;
    end;
    Result := 'ROM|' + Masks + Result;
  finally
    Extensions.Free;
  end;
end;

end.
