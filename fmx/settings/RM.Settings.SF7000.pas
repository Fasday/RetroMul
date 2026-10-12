unit RM.Settings.SF7000;

interface

uses
  RM.Settings.Platform, RM.Settings.Sega8Bit;

type
  TSF7000Settings = class(TSega8BitSettings)
  public
    procedure Hardware(Context: TSettingsPageContext); override;
    procedure Peripherals(Context: TSettingsPageContext); override;
  end;

implementation

uses
  System.SysUtils, FMX.Types, FMX.StdCtrls, RM.Icons;

procedure TSF7000Settings.Hardware(Context: TSettingsPageContext);
begin
  Context.Heading('GroupSegaHardware');
  Context.PathEdit('RowSegaIPL', 'Hardware', 'IPL', '', False);
  Context.Check('RowSegaWarmBoot', 'Hardware', 'WarmBoot', True);
end;

procedure TSF7000Settings.Peripherals(Context: TSettingsPageContext);
begin
  Keyboard(Context, True);
  Context.Heading('GroupSegaDisk');
  Context.Check('RowSegaWriteProtected', 'Disk', 'WriteProtected', False);
end;

end.

