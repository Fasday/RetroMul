unit RM.Settings.MasterSystem;

interface

uses
  RM.Settings.Platform, RM.Settings.Sega8Bit;

type
  TMasterSystemSettings = class(TSega8BitSettings)
  public
    procedure Hardware(Context: TSettingsPageContext); override;
    procedure Audio(Context: TSettingsPageContext); override;
  end;

implementation

uses
  System.SysUtils, FMX.Types, FMX.StdCtrls, RM.Icons;

procedure TMasterSystemSettings.Hardware(Context: TSettingsPageContext);
begin
  Context.Heading('GroupSegaHardware');
  Context.Combo('RowSegaModel', 'Hardware', 'Model',
    [Translate('Automatic'), 'Master System', 'Mark III'], ['auto', 'sms', 'markiii'], 'auto');
  Context.Check('RowSegaBIOSEnabled', 'Hardware', 'BIOSEnabled', True);
  Context.PathEdit('RowSegaBIOS', 'Hardware', 'BIOS', '', False);
  Context.Combo('RowSegaMapper', 'Cartridge', 'Mapper',
    [Translate('Automatic'), 'Sega', 'Codemasters', 'Korean', 'Zemina', 'Nemesis',
      'Janggun', 'HiCom', '4 Pak', 'Korean 188', 'Fixed 48 KiB', 'Seojin', '93C46 EEPROM'],
    ['-1', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11'], '-1');
end;

procedure TMasterSystemSettings.Audio(Context: TSettingsPageContext);
begin
  inherited;
  Context.Check('RowSegaFMEnabled', 'Audio', 'FMEnabled', True);
  Context.Number('RowSegaFMVolume', 'Audio', 'FMVolume', 100, 100);
end;

end.

