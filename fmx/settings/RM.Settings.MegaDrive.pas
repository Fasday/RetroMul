unit RM.Settings.MegaDrive;

interface

uses
  RM.Settings.Platform, System.IniFiles;

type
  TMegaDriveSettings = class(TSettingsPlatform)
  public
    function PortOptions(Port: Integer): TSettingsPortOptions; override;
  end;

implementation

uses
  System.SysUtils, System.Math, FMX.Types, FMX.StdCtrls, FMX.ListBox, RM.Icons;

function TMegaDriveSettings.PortOptions(Port: Integer): TSettingsPortOptions;
begin
  Result.RowName := 'RowConnecteddevice2Port' + IntToStr(Port + 1);
  Result.Labels := nil;
  Result.Values := ['pad6', 'pad3', 'none'];
  Result.Default := 'pad6';
end;

end.

