unit RM.Settings.NES;

interface

uses
  RM.Settings.Platform, System.IniFiles;

type
  TNESSettings = class(TSettingsPlatform)
  public
    procedure Video(Context: TSettingsPageContext); override;
    procedure Peripherals(Context: TSettingsPageContext); override;
    procedure Expansion(Context: TSettingsPageContext); override;
    procedure Validate(Draft: TMemIniFile); override;
    function PlayerCount(Draft: TMemIniFile): Integer; override;
    function PortOptions(Port: Integer): TSettingsPortOptions; override;
  end;

implementation

uses
  System.SysUtils, System.Math, FMX.Types, FMX.StdCtrls, FMX.ListBox, RM.Icons;

procedure TNESSettings.Video(Context: TSettingsPageContext);
begin
  Context.Combo('RowNESregion', 'Video', 'Region', [Translate('Automatic'), 'NTSC', 'PAL'], ['Auto', 'NTSC', 'PAL'], 'Auto');
  (Context.Owner.FindComponent('LabelRowNESregionTitle') as TLabel).Text := Translate('NES region');
  (Context.Owner.FindComponent('LabelRowNESregionDetail') as TLabel).Text := Translate('Frame rate and timing based on the ROM.');
end;

procedure TNESSettings.Peripherals(Context: TSettingsPageContext);
begin
  Context.Heading('GroupAdditionalplayers');
  var FourScore := Context.Check('RowFourScore', 'Input', 'FourScore', False);
  FourScore.OnSwitch := Context.OnRebuild;
end;

procedure TNESSettings.Expansion(Context: TSettingsPageContext);
begin
  Context.Heading('GroupFamicomexpansionport');
  var Expansion := Context.Combo('RowConnecteddevice', 'Ports', 'Expansion', [], ['auto', 'none', 'subor', 'famicom', 'recorder'], 'auto');
  Expansion.OnChange := Context.OnRebuild;
  var Device := Context.Draft.ReadString('Ports', 'Expansion', 'auto');
  if (Device = 'subor') or (Device = 'famicom') then
  begin
    Context.Check('RowPhysicalkeyboard', 'Ports', 'KeyboardEnabled', True);
    Context.BuildBindings(4, Device);
  end;
  if (Device = 'recorder') or (Device = 'famicom') then
    Context.PathEdit('RowInitialcassette', 'Ports', 'TapeFile', '', False);
end;

function TNESSettings.PlayerCount(Draft: TMemIniFile): Integer;
begin
  Result := 2;
  if Draft.ReadBool('Input', 'FourScore', False) then
    Result := 4;
end;

function TNESSettings.PortOptions(Port: Integer): TSettingsPortOptions;
begin
  Result := inherited PortOptions(Port);
  Result.Labels := nil;
  Result.Default := 'auto';
  case Port of
    0:
      begin
        Result.RowName := 'RowConnecteddevice10Port1';
        Result.Values := ['auto', 'pad', 'paddendy', 'piano', 'none'];
      end;
    1:
      begin
        Result.RowName := 'RowConnecteddevice18Port2';
        Result.Values := ['auto', 'pad', 'paddendy', 'zapper', 'powerpad', 'none'];
      end;
  else
    Result.Labels := ['Gamepad', 'Dendy · Turbo', 'None'];
    Result.Values := ['pad', 'paddendy', 'none'];
    Result.Default := 'pad';
  end;
end;

procedure TNESSettings.Validate(Draft: TMemIniFile);
begin
  if Draft.ReadBool('Input', 'FourScore', False) and
    ((Draft.ReadString('Ports', 'Port1', 'auto') = 'piano') or
    (Draft.ReadString('Ports', 'Port2', 'auto') = 'zapper') or
    (Draft.ReadString('Ports', 'Port2', 'auto') = 'powerpad')) then
    raise Exception.Create(Translate('Disable Four Score to use Zapper, Power Pad or Miracle Piano.'));

  if (Draft.ReadString('Ports', 'Port1', 'auto') = 'piano') and
    ((Draft.ReadString('Ports', 'Port2', 'auto') = 'zapper') or
    (Draft.ReadString('Ports', 'Port2', 'auto') = 'powerpad')) then
    raise Exception.Create(Translate('Miracle Piano uses both ports. Disconnect Zapper or Power Pad.'));
end;

end.

