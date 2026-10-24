unit RM.Settings.DC;

interface

uses
  RM.Settings.Platform, System.IniFiles;

type
  TDCSettings = class(TSettingsPlatform)
  public
    procedure Initialize(Context: TSettingsPageContext); override;
    procedure Video(Context: TSettingsPageContext); override;
    procedure Peripherals(Context: TSettingsPageContext); override;
    function PortOptions(Port: Integer): TSettingsPortOptions; override;
  end;

implementation

uses
  System.SysUtils;

procedure TDCSettings.Initialize(Context: TSettingsPageContext);
begin
  Context.CreateGroup('DCSystem', 'System');
  Context.CreateOption('RowDCBoot', 'Boot',
    'Built-in high-level boot. Automatic also takes the font of a boot ROM (dc_boot.bin) when found; ' +
    'Boot ROM file starts the console from it.', sekCombo);
  Context.CreateOption('RowDCBIOS', 'Boot ROM file',
    'Optional 2 MiB boot ROM. Without it, dc_boot.bin beside the game or in the dc ROM folder is used.', sekPath);
  Context.CreateOption('RowDCFlash', 'Flash file',
    'Optional 128 KiB system flash for the boot ROM. Settings are kept in the save folder.', sekPath);
  Context.CreateOption('RowDCRegion', 'Region', 'Automatic follows the area symbols of the disc.', sekCombo);
  Context.CreateOption('RowDCLanguage', 'Language', 'System language stored in the console settings.', sekCombo);
  Context.CreateOption('RowDCCable', 'Video cable', 'Some games offer extra modes for VGA or RGB.', sekCombo);
  Context.CreateOption('RowDCVideo', 'Video standard', 'Automatic uses 50 Hz PAL for European consoles.', sekCombo);
  for var Port := 1 to 4 do
    Context.CreateOption('RowDCControllerPort' + IntToStr(Port), 'Controller',
      'Dreamcast controller (with a Visual Memory unit), keyboard, mouse, light gun or nothing. The keyboard ' +
      'takes the host keys; the light gun aims with the mouse pointer and fires with its left button.', sekCombo);
  Context.CreateGroup('DCPeripherals', 'Visual Memory and rumble');
  Context.CreateOption('RowDCVMUScreen', 'VMU screen',
    'Show the Visual Memory display of the first controller in a corner of the picture.', sekCombo);
  Context.CreateOption('RowDCRumble', 'Jump pack rumble',
    'Vibrate the gamepad when the game runs the jump pack of the first controller.', sekSwitch);
end;

procedure TDCSettings.Video(Context: TSettingsPageContext);
begin
  Context.Heading('GroupDCSystem');
  Context.Combo('RowDCBoot', 'Hardware', 'BIOSMode', ['Built-in (high-level)', 'Automatic', 'Boot ROM file'],
    ['hle', 'auto', 'external'], 'hle');
  Context.PathEdit('RowDCBIOS', 'Hardware', 'BIOS', '', False);
  Context.PathEdit('RowDCFlash', 'Hardware', 'Flash', '', False);
  Context.Combo('RowDCRegion', 'System', 'Region', ['Automatic', 'Japan', 'North America', 'Europe'],
    ['auto', 'japan', 'usa', 'europe'], 'auto');
  Context.Combo('RowDCLanguage', 'System', 'Language', ['English', 'Japanese', 'German', 'French', 'Spanish', 'Italian'],
    ['english', 'japanese', 'german', 'french', 'spanish', 'italian'], 'english');
  Context.Combo('RowDCCable', 'System', 'Cable', ['Composite', 'RGB', 'VGA'], ['composite', 'rgb', 'vga'], 'composite');
  Context.Combo('RowDCVideo', 'System', 'Video', ['Automatic', 'NTSC (60 Hz)', 'PAL (50 Hz)'], ['auto', 'ntsc', 'pal'],
    'auto');
end;

procedure TDCSettings.Peripherals(Context: TSettingsPageContext);
begin
  Context.Heading('GroupDCPeripherals');
  Context.Combo('RowDCVMUScreen', 'Peripherals', 'VMUScreen', ['Off', 'Top left', 'Top right', 'Bottom left',
    'Bottom right'], ['off', 'top-left', 'top-right', 'bottom-left', 'bottom-right'], 'top-right');
  Context.Check('RowDCRumble', 'Peripherals', 'Rumble', True);
end;

function TDCSettings.PortOptions(Port: Integer): TSettingsPortOptions;
begin
  Result.RowName := 'RowDCControllerPort' + IntToStr(Port + 1);
  Result.Labels := ['Controller + VMU', 'Controller', 'Keyboard', 'Mouse', 'Light gun', 'None'];
  Result.Values := ['pad-vmu', 'pad', 'keyboard', 'mouse', 'lightgun', 'none'];
  // As 'auto' in the core: a VMU in the first controller only.
  Result.Default := 'pad';
  if Port = 0 then
    Result.Default := 'pad-vmu';
end;

end.
