unit RM.Settings.PS1;

interface

uses
  RM.Settings.Platform, System.IniFiles;

type
  TPS1Settings = class(TSettingsPlatform)
  public
    procedure Initialize(Context: TSettingsPageContext); override;
    procedure Video(Context: TSettingsPageContext); override;
    function PlayerCount(Draft: TMemIniFile): Integer; override;
    function PortOptions(Port: Integer): TSettingsPortOptions; override;
  end;

implementation

uses
  System.SysUtils;

procedure TPS1Settings.Initialize(Context: TSettingsPageContext);
begin
  Context.CreateGroup('PS1System', 'System');
  Context.CreateOption('RowPS1BIOS', 'BIOS file',
    'Optional 512 KiB PlayStation BIOS. Without it, a BIOS beside the game or the built-in one is used.', sekPath);
  Context.CreateOption('RowPS1Video', 'Video standard', 'Automatic follows the BIOS or the disc region.', sekCombo);
  for var Port := 1 to 2 do
    Context.CreateOption('RowPS1ControllerPort' + IntToStr(Port), 'Controller', 'Digital pad or disconnected.', sekCombo);
end;

procedure TPS1Settings.Video(Context: TSettingsPageContext);
begin
  Context.Heading('GroupPS1System');
  Context.PathEdit('RowPS1BIOS', 'Hardware', 'BIOS', '', False);
  Context.Combo('RowPS1Video', 'System', 'Video', ['Automatic', 'NTSC (60 Hz)', 'PAL (50 Hz)'], ['auto', 'ntsc', 'pal'],
    'auto');
end;

function TPS1Settings.PlayerCount(Draft: TMemIniFile): Integer;
begin
  Result := 2;
end;

function TPS1Settings.PortOptions(Port: Integer): TSettingsPortOptions;
begin
  Result.RowName := 'RowPS1ControllerPort' + IntToStr(Port + 1);
  Result.Labels := ['Digital pad', 'None'];
  Result.Values := ['pad', 'none'];
  Result.Default := 'pad';
end;

end.
