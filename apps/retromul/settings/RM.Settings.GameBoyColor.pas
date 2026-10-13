unit RM.Settings.GameBoyColor;

interface

uses
  RM.Settings.Platform, RM.Settings.GameBoy;

type
  TGameBoyColorSettings = class(TGameBoySettings)
  public
    procedure Display(Context: TSettingsPageContext); override;
  end;

implementation

procedure TGameBoyColorSettings.Display(Context: TSettingsPageContext);
begin
  Context.Check('RowLCDcolors', 'Video', 'ColorCorrection', False);
end;

end.

