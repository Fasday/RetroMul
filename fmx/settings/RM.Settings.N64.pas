unit RM.Settings.N64;

interface

uses
  RM.Settings.Platform, System.IniFiles;

type
  TN64Settings = class(TSettingsPlatform)
  public
    procedure Initialize(Context: TSettingsPageContext); override;
    procedure Video(Context: TSettingsPageContext); override;
  end;

implementation

uses
  System.SysUtils, System.Math, FMX.Types, FMX.StdCtrls, FMX.ListBox, RM.Icons;

procedure TN64Settings.Initialize(Context: TSettingsPageContext);
begin
  Context.CreateGroup('N64Cartridge', 'N64 cartridge');
  Context.CreateOption('RowN64SaveType', 'Save memory', 'Auto uses known cartridge IDs and probes FlashRAM commands. Override unknown save formats; reopen the ROM after changing this setting.', sekCombo);
end;

procedure TN64Settings.Video(Context: TSettingsPageContext);
begin
  Context.Heading('GroupN64Cartridge');
  Context.Combo('RowN64SaveType', 'Cartridge', 'SaveType',
    [Translate('Auto'), Translate('EEPROM 4 Kbit'), Translate('EEPROM 16 Kbit'),
      Translate('SRAM 32 KiB'), Translate('FlashRAM 128 KiB'), Translate('None')],
    ['0', '1', '2', '3', '4', '5'], '0');
end;

end.

