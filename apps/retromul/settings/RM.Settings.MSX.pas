unit RM.Settings.MSX;

interface

uses
  RM.Settings.Platform;

type
  TMSXSettings = class(TSettingsPlatform)
  public
    procedure Initialize(Context: TSettingsPageContext); override;
    procedure Video(Context: TSettingsPageContext); override;
    procedure Peripherals(Context: TSettingsPageContext); override;
  end;

implementation

uses
  System.SysUtils;

procedure TMSXSettings.Initialize(Context: TSettingsPageContext);
begin
  Context.CreateGroup('MSXHardware', 'MSX hardware');
  Context.CreateGroup('MSXKeyboard', 'Keyboard');
  Context.CreateGroup('MSXDisks', 'Disk drives');
  Context.CreateGroup('MSXCassette', 'Cassette recorder');
  Context.CreateGroup('MSXExpansion', 'Expansion hardware');
  Context.CreateOption('RowMSXBIOS', 'BIOS file',
    'Optional 32 KiB BIOS override. Built-in firmware is used when empty. Reopen the game to apply.', sekPath);
  Context.CreateOption('RowMSXOriginalBIOS', 'Original BIOS with BASIC',
    'Use the built-in machine BIOS for cartridges too. Disk and tape images select it automatically.', sekSwitch);
  Context.CreateOption('RowMSXSubROM', 'Sub-ROM file',
    'A matching 16 KiB sub-ROM is required with an external MSX2 or MSX2+ BIOS.', sekPath);
  Context.CreateOption('RowMSXVDPChip', 'Video chip',
    'Select the VDP fitted to the machine. Automatic follows the system and BIOS timing. Reopen the game to apply.', sekCombo);
  Context.CreateOption('RowMSXVDPWait', 'Connect VDP WAIT to CPU',
    'For V9958 machines with WAIT wired to the CPU. On MSX2, select the V9958 upgrade first. Reopen the game to apply.', sekSwitch);
  Context.CreateOption('RowMSXMapper', 'Cartridge mapper',
    'Automatic uses known ROM hashes and bank-switch instructions. Restart to apply.', sekCombo);
  Context.CreateOption('RowMSXKeyboardEnabled', 'Physical keyboard',
    'Send host keys to the MSX keyboard. Space is trigger 1; arrows move; Enter starts; F1 is available to games.', sekSwitch);
  Context.CreateOption('RowMSXDiskROM', 'Disk ROM',
    'Optional 16 KiB Philips WD2793 disk ROM override. Leave empty to use the built-in disk ROM.', sekPath);
  Context.CreateOption('RowMSXDiskA', 'Drive A image', 'Optional raw MSX DSK image. Opening a DSK directly replaces this image for that session.', sekPath);
  Context.CreateOption('RowMSXDiskB', 'Drive B image', 'Optional second raw MSX DSK image. Reopen the game to apply.', sekPath);
  Context.CreateOption('RowMSXDiskProtect', 'Write protect disks', 'Reject writes and formatting. Original images remain unchanged; writable disks use game saves.', sekSwitch);
  Context.CreateOption('RowMSXTapeFile', 'Cassette image', 'CAS or integer PCM WAV. Enable the original BIOS to use BASIC cassette commands with cartridges. Reopen the game to apply.', sekPath);
  Context.CreateOption('RowMSXTapeMode', 'Recorder mode', 'The MSX controls the motor. Recordings are saved as WAV alongside game saves when emulation stops.', sekCombo);
  Context.CreateOption('RowMSXTapeBaud', 'CAS speed', 'FSK speed for CAS images; WAV recordings keep their original timing.', sekCombo);
  Context.CreateOption('RowMSXKanji', 'Kanji ROM', 'Optional 128 KiB JIS1 or 256 KiB JIS1+JIS2 font ROM. Reopen the game to apply.', sekPath);
  Context.CreateOption('RowMSXMusic', 'MSX-MUSIC ROM', 'Optional 16 KiB FM BASIC ROM for MSX2/2+. Reopen the game to apply.', sekPath);
  Context.CreateOption('RowMSXKanjiBasic', 'Kanji BASIC ROM', 'Matching 32 KiB Kanji BASIC ROM; required by some Japanese MSX2+ BIOS startup screens.', sekPath);
  Context.CreateOption('RowMSXCartridge2', 'Second cartridge', 'Optional cartridge for slot 2, including game combinations and SRAM cartridges. Reopen the game to apply.', sekPath);
  Context.CreateOption('RowMSXExpansion2', 'Slot 2 device', 'Insert a cartridge, FM-PAC/PAC, a Konami sound cartridge or MSX-AUDIO. Firmware is included; reopen the game to apply.', sekCombo);
  Context.CreateOption('RowMSXAudioRAM', 'MSX-AUDIO sample memory', '32 KiB matches the original modules; 256 KiB provides expanded ADPCM sample storage. Reopen the game to apply.', sekCombo);
  Context.CreateOption('RowMSXMapper2', 'Second cartridge mapper', 'Mapper override for slot 2. Reopen the game to apply.', sekCombo);
  Context.CreateOption('RowMSXMouse', 'MSX mouse', 'Connect a mouse to either general-purpose port. Reopen the game to apply.', sekCombo);
end;

procedure TMSXSettings.Video(Context: TSettingsPageContext);
begin
  Context.Heading('GroupMSXHardware');
  Context.Check('RowMSXOriginalBIOS', 'Hardware', 'OriginalBIOS', False);
  Context.PathEdit('RowMSXBIOS', 'Hardware', 'BIOS', '', False);
  Context.PathEdit('RowMSXSubROM', 'Hardware', 'SubROM', '', False);
  if SameText(CoreId, 'MSX1') then
    Context.Combo('RowMSXVDPChip', 'Hardware', 'VDPChip',
      ['Automatic', 'TI TMS9918A (60 Hz)', 'TI TMS9929A (50 Hz)', 'TI TMS9118 (60 Hz)',
        'TI TMS9129 (50 Hz)', 'Toshiba T7937A (60 Hz)', 'Toshiba T6950 (50 Hz)'],
      ['0', '1', '2', '3', '4', '5', '6'], '0')
  else if SameText(CoreId, 'MSX2') then
    Context.Combo('RowMSXVDPChip', 'Hardware', 'VDPChip',
      ['Automatic', 'Yamaha V9938 A', 'Yamaha V9938 B', 'Yamaha V9938 C', 'Yamaha V9958 upgrade'], ['0', '7', '8', '9', '10'], '0')
  else
    Context.Combo('RowMSXVDPChip', 'Hardware', 'VDPChip', ['Automatic', 'Yamaha V9958'], ['0', '10'], '0');
  if not SameText(CoreId, 'MSX1') then
    Context.Check('RowMSXVDPWait', 'Hardware', 'VDPWaitConnected', False);
  Context.Combo('RowMSXMapper', 'Cartridge', 'Mapper',
    ['Automatic', 'Plain ROM', 'ASCII8', 'ASCII16', 'Konami', 'Konami SCC',
      'ASCII8 + SRAM', 'ASCII16 + SRAM', 'R-Type', 'Game Master 2', 'Koei + 32 KiB SRAM', 'FM-PAC', 'PAC',
      'SCC+ 128 KiB', 'Snatcher SCC+', 'SD Snatcher SCC+', 'Philips MSX-AUDIO', 'Panasonic MSX-AUDIO'],
    ['-1', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11', '12', '13', '14', '15', '16'], '-1');
end;

procedure TMSXSettings.Peripherals(Context: TSettingsPageContext);
begin
  Context.Heading('GroupMSXDisks');
  Context.PathEdit('RowMSXDiskROM', 'Disk', 'ROM', '', False);
  Context.PathEdit('RowMSXDiskA', 'Disk', 'DriveA', '', False);
  Context.PathEdit('RowMSXDiskB', 'Disk', 'DriveB', '', False);
  Context.Check('RowMSXDiskProtect', 'Disk', 'WriteProtected', False);
  Context.Heading('GroupMSXCassette');
  Context.PathEdit('RowMSXTapeFile', 'Cassette', 'File', '', False);
  Context.Combo('RowMSXTapeMode', 'Cassette', 'Mode', ['Stopped', 'Play', 'Record'], ['0', '1', '2'], '1');
  Context.Combo('RowMSXTapeBaud', 'Cassette', 'Baud', ['1200 baud', '2400 baud'], ['1200', '2400'], '1200');
  Context.Heading('GroupMSXExpansion');
  Context.PathEdit('RowMSXKanji', 'Hardware', 'Kanji', '', False);
  Context.PathEdit('RowMSXMusic', 'Hardware', 'MusicROM', '', False);
  Context.PathEdit('RowMSXKanjiBasic', 'Hardware', 'KanjiBasicROM', '', False);
  Context.Combo('RowMSXExpansion2', 'Cartridge', 'Expansion2',
    ['Cartridge file', 'FM-PAC', 'PAC', 'SCC+ 128 KiB', 'Snatcher SCC+', 'SD Snatcher SCC+', 'Philips MSX-AUDIO', 'Panasonic MSX-AUDIO'],
    ['0', '1', '2', '3', '4', '5', '6', '7'], '0');
  Context.Combo('RowMSXAudioRAM', 'Hardware', 'AudioSampleRAM', ['32 KiB', '256 KiB'], ['32', '256'], '32');
  Context.PathEdit('RowMSXCartridge2', 'Cartridge', 'Slot2', '', False);
  Context.Combo('RowMSXMapper2', 'Cartridge', 'Mapper2',
    ['Automatic', 'Plain ROM', 'ASCII8', 'ASCII16', 'Konami', 'Konami SCC',
      'ASCII8 + SRAM', 'ASCII16 + SRAM', 'R-Type', 'Game Master 2', 'Koei + 32 KiB SRAM', 'FM-PAC', 'PAC',
      'SCC+ 128 KiB', 'Snatcher SCC+', 'SD Snatcher SCC+', 'Philips MSX-AUDIO', 'Panasonic MSX-AUDIO'],
    ['-1', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11', '12', '13', '14', '15', '16'], '-1');
  Context.Combo('RowMSXMouse', 'Ports', 'MSXMousePort', ['Disconnected', 'Port 1', 'Port 2'], ['0', '1', '2'], '0');
  Context.Heading('GroupMSXKeyboard');
  Context.Check('RowMSXKeyboardEnabled', 'Ports', 'KeyboardEnabled', True);
end;

end.

