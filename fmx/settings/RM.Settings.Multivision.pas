unit RM.Settings.Multivision;

interface

uses
  RM.Settings.Platform, RM.Settings.Sega8Bit;

type
  TMultivisionSettings = class(TSega8BitSettings)
  public
    procedure Peripherals(Context: TSettingsPageContext); override;
  end;

implementation

uses
  System.SysUtils, FMX.Types, FMX.StdCtrls, RM.Icons;

procedure TMultivisionSettings.Peripherals(Context: TSettingsPageContext);
begin
  Keyboard(Context, False);
end;

end.

