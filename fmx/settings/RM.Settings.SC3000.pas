unit RM.Settings.SC3000;

interface

uses
  RM.Settings.Platform, RM.Settings.Sega8Bit;

type
  TSC3000Settings = class(TSega8BitSettings)
  public
    procedure Hardware(Context: TSettingsPageContext); override;
    procedure Peripherals(Context: TSettingsPageContext); override;
  end;

implementation

uses
  System.SysUtils, FMX.Types, FMX.StdCtrls, RM.Icons;

procedure TSC3000Settings.Hardware(Context: TSettingsPageContext);
begin
  Context.Heading('GroupSegaHardware');
  Context.Combo('RowSegaModel', 'Hardware', 'Model',
    [Translate('Automatic'), 'SC-3000', 'SC-3000H'], ['auto', 'sc3000', 'sc3000h'], 'auto');
end;

procedure TSC3000Settings.Peripherals(Context: TSettingsPageContext);
begin
  Keyboard(Context, True);
end;

end.

