unit RM.Settings.GBA;

interface

uses
  RM.Settings.Platform, System.IniFiles;

type
  TGBASettings = class(TSettingsPlatform)
  public
    procedure Initialize(Context: TSettingsPageContext); override;
    procedure Video(Context: TSettingsPageContext); override;
    procedure Peripherals(Context: TSettingsPageContext); override;
  end;

implementation

uses
  System.SysUtils, System.Math, FMX.Types, FMX.StdCtrls, FMX.ListBox, RM.Icons;

procedure TGBASettings.Initialize(Context: TSettingsPageContext);
begin
  Context.CreateGroup('BootROM', 'Boot ROM');
  Context.CreateGroup('Rumble', 'Rumble');
  Context.CreateOption('RowRumble', 'Cartridge rumble', 'Vibrate the device when the game activates its rumble motor.', sekSwitch);
  Context.CreateOption('RowBootFileGBA', 'Boot ROM file', 'Optional 16 KiB GBA BIOS. Leave empty to use the built-in emibios.', sekPath);
  Context.CreateGroup('GBACartridge', 'GBA cartridge');
  Context.CreateOption('RowGBASaveType', 'Save memory', 'Auto detects the cartridge. Override only when a ROM uses an unrecognized save format.', sekCombo);
  Context.CreateOption('RowGBASolarLevel', 'Sunlight', 'Boktai sensor level: 0 is darkness, 255 is maximum light.', sekNumber);
end;

procedure TGBASettings.Video(Context: TSettingsPageContext);
begin
  Context.Heading('GroupBootROM');
  Context.PathEdit('RowBootFileGBA', 'Boot', 'File', '', False);
  Context.Heading('GroupGBACartridge');
  Context.Combo('RowGBASaveType', 'Cartridge', 'SaveType',
    [Translate('Auto'), Translate('None'), Translate('SRAM'),
      Translate('Flash 64 KiB'), Translate('Flash 128 KiB'), Translate('EEPROM')],
    ['-1', '0', '1', '2', '3', '4'], '-1');
  Context.Number('RowGBASolarLevel', 'Cartridge', 'SolarLevel', 128, 255);
end;

procedure TGBASettings.Peripherals(Context: TSettingsPageContext);
begin
  Context.Heading('GroupRumble');
  Context.Check('RowRumble', 'Peripherals', 'Rumble', True);
end;

end.

