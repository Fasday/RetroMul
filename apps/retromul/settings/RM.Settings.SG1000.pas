unit RM.Settings.SG1000;

interface

uses
  RM.Settings.Platform, RM.Settings.Sega8Bit;

type
  TSG1000Settings = class(TSega8BitSettings)
  public
    procedure Hardware(Context: TSettingsPageContext); override;
    procedure Peripherals(Context: TSettingsPageContext); override;
  end;

implementation

uses
  System.SysUtils, FMX.Types, FMX.StdCtrls, RM.Icons;

procedure TSG1000Settings.Hardware(Context: TSettingsPageContext);
begin
  Context.Heading('GroupSegaHardware');
  Context.Combo('RowSegaModel', 'Hardware', 'Model',
    [Translate('Automatic'), 'SG-1000', 'SG-1000 II / SK-1100'], ['auto', 'sg1000', 'sg1000ii'], 'auto');
end;

procedure TSG1000Settings.Peripherals(Context: TSettingsPageContext);
begin
  if SameText(Context.Draft.ReadString('Hardware', 'Model', 'auto'), 'sg1000ii') then
    Keyboard(Context, True);
end;

end.

