unit RM.Settings.PCE;

interface

uses
  System.IniFiles, RM.Settings.Platform;

type
  TPCESettings = class(TSettingsPlatform)
  public
    procedure Initialize(Context: TSettingsPageContext); override;
    procedure Video(Context: TSettingsPageContext); override;
    procedure Peripherals(Context: TSettingsPageContext); override;
    function PlayerCount(Draft: TMemIniFile): Integer; override;
    function PortOptions(Port: Integer): TSettingsPortOptions; override;
  end;

implementation

uses
  System.SysUtils, FMX.Types;

procedure TPCESettings.Initialize(Context: TSettingsPageContext);
begin
  // The shared family controls and containers are stored in RM.Settings.fmx.
end;

procedure TPCESettings.Video(Context: TSettingsPageContext);
begin
  Context.Heading('GroupPCEHardware');
  if CoreId = 'pcecd' then
  begin
    Context.Combo('RowPCEModel', 'Hardware', 'Model',
      [Translate('Automatic'), 'CD-ROM²', 'TurboGrafx-CD', 'Super CD-ROM²', 'Duo', 'Duo-R', 'Duo-RX', 'TurboDuo',
        'Arcade Card Duo', 'Arcade Card Pro', 'SuperGrafx + Super CD-ROM²', 'SuperGrafx + Arcade Card'],
      ['auto', 'cdrom2', 'tgcd', 'supercd', 'duo', 'duor', 'duorx', 'turboduo', 'arcadeduo', 'arcadepro', 'sgxcd', 'sgxarcade'], 'auto');
    Context.PathEdit('RowPCEBIOS', 'Hardware', 'BIOS', '', False);
  end
  else if CoreId = 'sgx' then
    Context.Combo('RowPCEModel', 'Hardware', 'Model', [Translate('Automatic'), 'SuperGrafx'], ['auto', 'sgx'], 'auto')
  else
    Context.Combo('RowPCEModel', 'Hardware', 'Model',
      [Translate('Automatic'), 'PC Engine', 'TurboGrafx-16', 'CoreGrafx', 'CoreGrafx II', 'Shuttle', 'GT / TurboExpress', 'LT', 'SuperGrafx'],
      ['auto', 'pce', 'tg16', 'coregrafx', 'coregrafxii', 'shuttle', 'gt', 'lt', 'sgx'], 'auto');
  Context.Heading('GroupPCEVideo');
  Context.Check('RowPCEBackground', 'Video', 'ShowBackground', True);
  Context.Check('RowPCESprites', 'Video', 'ShowSprites', True);
  Context.Check('RowPCESpriteLimit', 'Video', 'RemoveSpriteLimit', False);
end;

procedure TPCESettings.Peripherals(Context: TSettingsPageContext);
begin
  Context.Heading('GroupPCEInput');
  Context.Check('RowPCETurboTap', 'Input', 'Multitap1', False).OnSwitch := Context.OnRebuild;
end;

function TPCESettings.PlayerCount(Draft: TMemIniFile): Integer;
begin
  Result := 1;
  if Draft.ReadBool('Input', 'Multitap1', False) then
    Result := 5;
end;

function TPCESettings.PortOptions(Port: Integer): TSettingsPortOptions;
begin
  Result.RowName := 'RowConnecteddevice26Port' + IntToStr(Port + 1);
  Result.Labels := ['Pad I / II', 'Avenue Pad 6', Translate('None')];
  Result.Values := ['pad', 'pad6', 'none'];
  Result.Default := 'pad';
end;

end.

