unit Core.Platforms;

interface

uses
  System.SysUtils, System.Generics.Collections;

{$SCOPEDENUMS ON}

type
  TRomSystem = (Unknown, NES, GB, GBC, MD, SNES, NeoGeo, GBA, NeoGeoCD, N64, SG1000, SC3000,
    SF7000, Multivision, SMS, GameGear, GameWatch, PCE, SuperGrafx, PCECD, SegaCD, Sega32X, Saturn, NeoGeoAES, NeoGeoPocket, NeoGeoPocketColor);

type
  // Stable system IDs and settings keys preserve existing collections and INI files.
  TPlatformInfo = record
    System: TRomSystem;
    Id, CoreId, Name, ShortName, Manufacturer, SearchTerms, Folder: string;
    ScanFolders, Extensions: TArray<string>;
    SettingsProfile, SettingsCoreId, LegacySettingsId: string;
    Ports: Integer;
    function CopyInfo: TPlatformInfo;
  end;

  TPlatformRegistry = class sealed
  strict private
    class var
      FItems: TList<TPlatformInfo>;
    class procedure RegisterPlatform(System: TRomSystem; const Id, Name, ShortName, Manufacturer, SearchTerms, Folder: string; const ScanFolders, Extensions: array of string; const SettingsProfile, SettingsCoreId: string; Ports: Integer; const LegacySettingsId: string = ''); static;
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

uses
  System.Generics.Defaults, Core.RomFormat;

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
    '', 'gw', 2);
  RegisterPlatform(TRomSystem.GB, ROM_SYSTEM_GB, 'Game Boy', 'GB',
    'Nintendo', 'GB DMG MGB', 'gb', ['gb'], [ROM_EXTENSION_GB, ROM_EXTENSION_GBX],
    'GameBoy', 'gb', 1);
  RegisterPlatform(TRomSystem.GBC, ROM_SYSTEM_GBC, 'Game Boy Color', 'GBC',
    'Nintendo', 'GBC CGB', 'gbc', ['gbc'], [ROM_EXTENSION_GBC, ROM_EXTENSION_GBX],
    'GameBoyColor', 'gbc', 1);
  RegisterPlatform(TRomSystem.GBA, ROM_SYSTEM_GBA, 'Game Boy Advance', 'GBA',
    'Nintendo', 'GBA AGB', 'gba', ['gba'], [ROM_EXTENSION_GBA],
    'GBA', 'gba', 1);
  RegisterPlatform(TRomSystem.NES, ROM_SYSTEM_NES, 'NES / Famicom', 'NES',
    'Nintendo', 'NES Famicom Dendy', 'nes', ['nes'], [ROM_EXTENSION_NES],
    'NES', 'nes', 2);
  RegisterPlatform(TRomSystem.SNES, ROM_SYSTEM_SNES, 'Super Nintendo', 'SNES',
    'Nintendo', 'SNES Super Famicom', 'snes', ['snes'], [ROM_EXTENSION_SFC, ROM_EXTENSION_SMC, ROM_EXTENSION_SWC, ROM_EXTENSION_FIG],
    'SNES', 'snes', 2);
  RegisterPlatform(TRomSystem.N64, ROM_SYSTEM_N64, 'Nintendo 64', 'Nintendo 64',
    'Nintendo', 'N64', 'n64', ['n64'], [ROM_EXTENSION_Z64, ROM_EXTENSION_N64, ROM_EXTENSION_V64],
    'N64', 'n64', 4);
  RegisterPlatform(TRomSystem.MD, ROM_SYSTEM_MD, 'MegaDrive', 'MegaDrive',
    'Sega', 'MD Genesis Sega CD Mega CD 32X', 'megadrive', ['megadrive'], [ROM_EXTENSION_SMD, ROM_EXTENSION_BIN, ROM_EXTENSION_GEN, ROM_EXTENSION_MD],
    'MegaDrive', 'md', 4);
  RegisterPlatform(TRomSystem.SegaCD, ROM_SYSTEM_SEGACD, 'Sega CD', 'Sega CD',
    'Sega', 'Mega CD CD32X 32X CD', 'segacd', ['segacd', 'megacd'], [ROM_EXTENSION_CUE, ROM_EXTENSION_ISO, ROM_EXTENSION_CHD],
    'MegaDrive', 'md', 4);
  RegisterPlatform(TRomSystem.Sega32X, ROM_SYSTEM_SEGA32X, 'Sega 32X', 'Sega 32X',
    'Sega', '32X Mars Super 32X', 'sega32x', ['sega32x', '32x'], ['.32x', ROM_EXTENSION_BIN, ROM_EXTENSION_GEN, ROM_EXTENSION_MD, ROM_EXTENSION_SMD],
    'MegaDrive', 'md', 4);
  RegisterPlatform(TRomSystem.SG1000, ROM_SYSTEM_SG1000, 'SG-1000', 'SG-1000',
    'Sega', 'SG1000 SG-1000 II SK-1100', 'sg1000', ['sg1000'], [ROM_EXTENSION_SG, ROM_EXTENSION_SMS],
    'SG1000', 'sg1000', 2);
  RegisterPlatform(TRomSystem.SC3000, ROM_SYSTEM_SC3000, 'SC-3000', 'SC-3000',
    'Sega', 'SC3000 SC-3000H', 'sc3000', ['sc3000', 'sg1000'], [ROM_EXTENSION_SC],
    'SC3000', 'sc3000', 2);
  RegisterPlatform(TRomSystem.SF7000, ROM_SYSTEM_SF7000, 'SF-7000', 'SF-7000',
    'Sega', 'SF7000 floppy', 'sf7000', ['sf7000', 'sg1000'], [ROM_EXTENSION_SF7, ROM_EXTENSION_SF, ROM_EXTENSION_DSK],
    'SF7000', 'sf7000', 2);
  RegisterPlatform(TRomSystem.SMS, ROM_SYSTEM_SMS, 'Master System', 'Master System',
    'Sega', 'SMS Mark III', 'mastersystem', ['mastersystem', 'sms'], [ROM_EXTENSION_SMS],
    'MasterSystem', 'sms', 2);
  RegisterPlatform(TRomSystem.GameGear, ROM_SYSTEM_GG, 'Game Gear', 'Game Gear',
    'Sega', 'GG GameGear', 'gamegear', ['gamegear', 'gg'], [ROM_EXTENSION_GG],
    'GameGear', 'gg', 1);
  RegisterPlatform(TRomSystem.Saturn, ROM_SYSTEM_SATURN, 'SEGA Saturn', 'Saturn',
    'Sega', 'Saturn SH2 CD', 'saturn', ['saturn'], [ROM_EXTENSION_BIN, ROM_EXTENSION_GENERIC, '.bios', ROM_EXTENSION_CUE, ROM_EXTENSION_ISO, ROM_EXTENSION_CHD],
    'Saturn', 'saturn', 2);
  RegisterPlatform(TRomSystem.Multivision, ROM_SYSTEM_OMV, 'Multivision', 'Multivision',
    'Tsukuda Original', 'OMV Othello Multivision', 'omv', ['omv', 'sg1000'], [ROM_EXTENSION_MV],
    'Multivision', 'omv', 2);
  RegisterPlatform(TRomSystem.NeoGeo, ROM_SYSTEM_NEOGEO, 'Neo Geo', 'Neo Geo',
    'SNK', 'NG NeoGeo Neo Geo CD', 'neogeo', ['neogeo'], [ROM_EXTENSION_ZIP, ROM_EXTENSION_NEO],
    'NeoGeo', 'neogeo', 2);
  RegisterPlatform(TRomSystem.NeoGeoAES, ROM_SYSTEM_NEOGEOAES, 'Neo Geo AES', 'Neo Geo AES',
    'SNK', 'NG AES Advanced Entertainment System', 'neogeoaes', ['neogeoaes', 'aes'], [ROM_EXTENSION_ZIP, ROM_EXTENSION_NEO],
    'NeoGeo', 'neogeoaes', 2);
  RegisterPlatform(TRomSystem.NeoGeoPocket, ROM_SYSTEM_NGP, 'Neo Geo Pocket', 'NGP',
    'SNK', 'NGP Pocket monochrome', 'ngp', ['ngp', 'neogeopocket'], [ROM_EXTENSION_NGP, ROM_EXTENSION_NGPC, ROM_EXTENSION_ZIP],
    'NeoGeoPocket', 'ngp', 1);
  RegisterPlatform(TRomSystem.NeoGeoPocketColor, ROM_SYSTEM_NGPC, 'Neo Geo Pocket Color', 'NGPC',
    'SNK', 'NGPC Pocket Color', 'ngpc', ['ngpc', 'neogeopocketcolor'], [ROM_EXTENSION_NGP, ROM_EXTENSION_NGPC, ROM_EXTENSION_ZIP],
    'NeoGeoPocket', 'ngpc', 1);
  RegisterPlatform(TRomSystem.NeoGeoCD, ROM_SYSTEM_NEOGEOCD, 'Neo Geo CD', 'Neo Geo CD',
    'SNK', 'NG NeoGeo CD', 'neogeocd', ['neogeocd'], [ROM_EXTENSION_CUE, ROM_EXTENSION_ISO, ROM_EXTENSION_CHD],
    'NeoGeo', 'neogeocd', 2, ROM_SYSTEM_NEOGEO);
  RegisterPlatform(TRomSystem.PCE, ROM_SYSTEM_PCE, 'PC Engine / TurboGrafx-16', 'PC Engine',
    'NEC', 'PCE CoreGrafx Shuttle GT LT TurboExpress', 'pcengine', ['pcengine', 'pce'], [ROM_EXTENSION_PCE, ROM_EXTENSION_ZIP],
    'PCE', 'pce', 5);
  RegisterPlatform(TRomSystem.SuperGrafx, ROM_SYSTEM_SGX, 'SuperGrafx', 'SuperGrafx',
    'NEC', 'SGX', 'sgx', ['sgx', 'supergrafx', 'pcengine', 'pce'], [ROM_EXTENSION_SGX, ROM_EXTENSION_PCE, ROM_EXTENSION_ZIP],
    'PCE', 'sgx', 5);
  RegisterPlatform(TRomSystem.PCECD, ROM_SYSTEM_PCECD, 'PC Engine CD', 'PC Engine CD',
    'NEC', 'CD-ROM2 Super CD-ROM2 Duo TurboDuo Arcade Card', 'pcenginecd', ['pcenginecd', 'pcecd'], [ROM_EXTENSION_CUE, ROM_EXTENSION_ISO, ROM_EXTENSION_CHD],
    'PCE', 'pcecd', 5);
  FItems.Sort(TComparer<TPlatformInfo>.Construct(
    function(const A, B: TPlatformInfo): Integer
    begin
      Result := CompareText(A.Manufacturer, B.Manufacturer);
      if Result = 0 then
        Result := CompareText(A.Name, B.Name);
    end));
end;

class destructor TPlatformRegistry.Destroy;
begin
  FItems.Free;
end;

class procedure TPlatformRegistry.RegisterPlatform(System: TRomSystem; const Id, Name, ShortName, Manufacturer, SearchTerms, Folder: string; const ScanFolders, Extensions: array of string; const SettingsProfile, SettingsCoreId: string; Ports: Integer; const LegacySettingsId: string);
begin
  if (System = TRomSystem.Unknown) or (Id = '') or (Name = '') or
    (Manufacturer = '') or (Folder = '') or (Length(ScanFolders) = 0) or
    (Length(Extensions) = 0) or (Ports < 1) or (Ports > 8) or
    (SettingsCoreId = '') then
    raise EArgumentException.Create('Invalid platform: ' + Id);
  for var Existing in FItems do
    if (Existing.System = System) or SameText(Existing.Id, Id) then
      raise EArgumentException.Create('Duplicate platform: ' + Id);
  var Item: TPlatformInfo;
  Item.System := System;
  Item.Id := Id;
  Item.CoreId := SettingsCoreId.ToUpper;
  Item.Name := Name;
  Item.ShortName := ShortName;
  Item.Manufacturer := Manufacturer;
  Item.SearchTerms := SearchTerms;
  Item.Folder := Folder;
  SetLength(Item.ScanFolders, Length(ScanFolders));
  for var I := 0 to High(ScanFolders) do
    Item.ScanFolders[I] := ScanFolders[I];
  SetLength(Item.Extensions, Length(Extensions));
  for var I := 0 to High(Extensions) do
    Item.Extensions[I] := Extensions[I];
  if not (System in [TRomSystem.SegaCD, TRomSystem.PCECD, TRomSystem.NeoGeoCD,
    TRomSystem.Saturn]) then
    Item.Extensions := Item.Extensions + [ROM_EXTENSION_7Z];
  Item.SettingsProfile := SettingsProfile;
  Item.SettingsCoreId := SettingsCoreId;
  Item.LegacySettingsId := LegacySettingsId;
  Item.Ports := Ports;
  FItems.Add(Item);
end;

class function TPlatformRegistry.All: TArray<TPlatformInfo>;
begin
  SetLength(Result, FItems.Count);
  for var I := 0 to FItems.Count - 1 do
    Result[I] := FItems[I].CopyInfo;
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
        if not Extensions.Contains(Ext) then
          Extensions.Add(Ext);
        if Masks <> '' then
          Masks := Masks + ';';
        Masks := Masks + '*' + Ext;
      end;
      Result := Result + '|' + Item.Name + '|' + Masks;
    end;
    var Masks := '';
    for var Ext in Extensions do
    begin
      if Masks <> '' then
        Masks := Masks + ';';
      Masks := Masks + '*' + Ext;
    end;
    Result := 'ROM|' + Masks + Result;
  finally
    Extensions.Free;
  end;
end;

end.

