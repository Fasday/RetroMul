unit RM.Settings.GameGear;

interface

uses RM.Settings.Platform, RM.Settings.Sega8Bit;

type
  TGameGearSettings = class(TSega8BitSettings)
  public
    procedure Video(Context: TSettingsPageContext); override;
    procedure Hardware(Context: TSettingsPageContext); override;
  end;

implementation

uses FMX.Types;

procedure TGameGearSettings.Video(Context: TSettingsPageContext);
begin
  Hardware(Context);
  Context.Heading('GroupSegaVideo');
  Context.Check('RowSegaShowBackground', 'Video', 'ShowBackground', True);
  Context.Check('RowSegaShowSprites', 'Video', 'ShowSprites', True);
  Context.Check('RowSegaRemoveSpriteLimit', 'Video', 'RemoveSpriteLimit', False);
end;

procedure TGameGearSettings.Hardware(Context: TSettingsPageContext);
begin
  Context.Heading('GroupSegaHardware');
  Context.Combo('RowSegaGGRegion', 'Hardware', 'Territory',
    [Translate('Automatic'), 'Export', 'Japan'], ['0', '1', '2'], '0');
  Context.Combo('RowSegaMapper', 'Cartridge', 'Mapper',
    [Translate('Automatic'), 'Sega', 'Codemasters', '93C46 EEPROM'], ['-1', '0', '1', '11'], '-1');
end;

end.
