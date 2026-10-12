unit RM.Settings.SNES;

interface

uses
  RM.Settings.Platform, System.IniFiles;

type
  TSNESSettings = class(TSettingsPlatform)
  public
    procedure Video(Context: TSettingsPageContext); override;
    procedure Peripherals(Context: TSettingsPageContext); override;
    function PlayerCount(Draft: TMemIniFile): Integer; override;
  end;

implementation

uses
  System.SysUtils, System.Math, FMX.Types, FMX.StdCtrls, FMX.ListBox, RM.Icons;

procedure TSNESSettings.Video(Context: TSettingsPageContext);
begin
  Context.Check('RowCropoverscan', 'Video', 'CropOverscan', False);
end;

procedure TSNESSettings.Peripherals(Context: TSettingsPageContext);
begin
  Context.Heading('GroupAdditionalplayers');
  var Multi := Context.Check('RowMultitapport2', 'Input', 'Multitap2', False);
  Multi.OnSwitch := Context.OnRebuild;
  Multi := Context.Check('RowMultitapport1', 'Input', 'Multitap1', False);
  Multi.OnSwitch := Context.OnRebuild;
end;

function TSNESSettings.PlayerCount(Draft: TMemIniFile): Integer;
begin
  Result := 2;
  if Draft.ReadBool('Input', 'Multitap2', False) then
    Result := 5;
  if Draft.ReadBool('Input', 'Multitap1', False) then
    Result := 8;
end;

end.

