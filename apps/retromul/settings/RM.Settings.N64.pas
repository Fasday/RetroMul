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
  Context.CreateGroup('N64Video', 'N64 rendering');
  Context.CreateOption('RowN64BilinearFiltering', 'Bilinear texture filtering',
    'Use the texture filtering requested by the game. Turn off for sharper textures and faster rendering. Applies during play, before output scaling and shaders.', sekSwitch);
  Context.CreateGroup('N64Cartridge', 'N64 cartridge');
  Context.CreateOption('RowN64SaveType', 'Save memory', 'Auto uses known cartridge IDs and probes FlashRAM commands. Override unknown save formats; reopen the ROM after changing this setting.', sekCombo);
end;

procedure TN64Settings.Video(Context: TSettingsPageContext);
begin
  Context.Heading('GroupN64Video');
  Context.Check('RowN64BilinearFiltering', 'Video', 'BilinearFiltering', True);
  Context.Heading('GroupN64Cartridge');
  Context.Combo('RowN64SaveType', 'Cartridge', 'SaveType',
    [Translate('Auto'), Translate('EEPROM 4 Kbit'), Translate('EEPROM 16 Kbit'),
      Translate('SRAM 32 KiB'), Translate('FlashRAM 128 KiB'), Translate('None')],
    ['0', '1', '2', '3', '4', '5'], '0');
end;

end.

