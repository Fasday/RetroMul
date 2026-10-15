unit RM.Settings.Saturn;

interface

uses
  RM.Settings.Platform, System.IniFiles;

type
  TSaturnSettings = class(TSettingsPlatform)
  public
    procedure Initialize(Context: TSettingsPageContext); override;
    procedure Video(Context: TSettingsPageContext); override;
    procedure Peripherals(Context: TSettingsPageContext); override;
    function PlayerCount(Draft: TMemIniFile): Integer; override;
    function PortOptions(Port: Integer): TSettingsPortOptions; override;
  end;

implementation

uses
  System.SysUtils;

procedure TSaturnSettings.Initialize(Context: TSettingsPageContext);
begin
  Context.CreateGroup('SaturnSystem', 'System');
  Context.CreateOption('RowSaturnRegion', 'Region', 'Select the console region used by the BIOS.', sekCombo);
  Context.CreateOption('RowSaturnBIOS', 'BIOS file', 'Optional 512 KiB BIOS override. A regional BIOS is built in.', sekPath);
  Context.CreateOption('RowSaturnRAMCart', 'Cartridge', 'Expansion RAM, game ROM, or persistent backup memory.', sekCombo);
  Context.CreateOption('RowSaturnCartROM', 'ROM cartridge file', 'Game-specific ROM cartridge image, used when ROM cartridge is selected.', sekPath);
  Context.CreateOption('RowSaturnCDBackend', 'CD Block', 'Command model or original SH-1 firmware. Firmware mode is experimental.', sekCombo);
  Context.CreateOption('RowSaturnProtection', 'Optical protection', 'Require the physical security ring. Sector images cannot provide it.', sekSwitch);
  for var Port := 1 to 12 do
    Context.CreateOption('RowSaturnControllerPort' + IntToStr(Port), 'Controller', 'Digital pad, analog 3D pad, or disconnected.', sekCombo);
  Context.CreateOption('RowSaturnPAL', 'PAL video', 'Use PAL video timing.', sekSwitch);
end;

procedure TSaturnSettings.Video(Context: TSettingsPageContext);
begin
  Context.Heading('GroupSaturnSystem');
  Context.Combo('RowSaturnRegion', 'System', 'Region', ['Japan', 'North America', 'Europe'], ['1', '4', '12'], '4');
  Context.PathEdit('RowSaturnBIOS', 'Hardware', 'BIOS', '', False);
  Context.Combo('RowSaturnRAMCart', 'Hardware', 'RAMCart',
    ['None', '1 MiB RAM', '4 MiB RAM', 'ROM cartridge', '512 KiB backup', '1 MiB backup', '2 MiB backup', '4 MiB backup'],
    ['0', '1', '4', '16', '33', '34', '35', '36'], '0');
  Context.PathEdit('RowSaturnCartROM', 'Hardware', 'CartROM', '', False);
  Context.Combo('RowSaturnCDBackend', 'Hardware', 'CDBackend', ['Command model', 'SH-1 firmware (experimental)'], ['model', 'sh1'], 'model');
  Context.Check('RowSaturnProtection', 'Hardware', 'OpticalProtection', False);
  Context.Check('RowSaturnPAL', 'System', 'PAL', False);
end;

procedure TSaturnSettings.Peripherals(Context: TSettingsPageContext);
begin
  Context.Heading('GroupAdditionalplayers');
  Context.Check('RowMultitapport1', 'Input', 'Multitap1', False).OnSwitch := Context.OnRebuild;
  Context.Check('RowMultitapport2', 'Input', 'Multitap2', False).OnSwitch := Context.OnRebuild;
end;

function TSaturnSettings.PlayerCount(Draft: TMemIniFile): Integer;
begin
  Result := 2;
  for var Port := 1 to 2 do
    if Draft.ReadBool('Input', 'Multitap' + IntToStr(Port), False) then
      Inc(Result, 5);
end;

function TSaturnSettings.PortOptions(Port: Integer): TSettingsPortOptions;
begin
  Result.RowName := 'RowSaturnControllerPort' + IntToStr(Port + 1);
  Result.Labels := ['Digital pad', 'Analog 3D pad', 'None'];
  Result.Values := ['pad', 'pad-analog', 'none'];
  Result.Default := 'pad';
end;

end.

