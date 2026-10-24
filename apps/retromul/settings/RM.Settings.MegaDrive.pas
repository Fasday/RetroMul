unit RM.Settings.MegaDrive;

interface

uses
  RM.Settings.Platform, System.IniFiles;

type
  TMegaDriveSettings = class(TSettingsPlatform)
  public
    procedure Audio(Context: TSettingsPageContext); override;
    procedure Expansion(Context: TSettingsPageContext); override;
    function PortOptions(Port: Integer): TSettingsPortOptions; override;
  end;

implementation

uses
  System.SysUtils, System.Math, FMX.Types, FMX.StdCtrls, FMX.ListBox, RM.Icons;

procedure TMegaDriveSettings.Audio(Context: TSettingsPageContext);
begin
  Context.Heading('GroupMDCDAudio');
  Context.Number('RowMDCDAudio', 'SegaCD', 'Volume', 100, 100);
  Context.Heading('GroupMD32XAudio');
  Context.Number('RowMD32XAudio', 'Sega32X', 'Volume', 100, 100);
end;

procedure TMegaDriveSettings.Expansion(Context: TSettingsPageContext);
begin
  Context.Heading('GroupMDCDInput');
  Context.Check('RowMDMicrophone', 'SegaCD', 'MicrophoneEnabled', False);
end;

function TMegaDriveSettings.PortOptions(Port: Integer): TSettingsPortOptions;
begin
  Result.RowName := 'RowConnecteddevice2Port' + IntToStr(Port + 1);
  Result.Labels := nil;
  Result.Values := ['pad6', 'pad3', 'none'];
  Result.Default := 'pad6';
end;

end.

