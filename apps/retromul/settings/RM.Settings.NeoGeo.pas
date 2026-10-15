unit RM.Settings.NeoGeo;

interface

uses
  RM.Settings.Platform;

type
  TNeoGeoSettings = class(TSettingsPlatform)
  public
    procedure Video(Context: TSettingsPageContext); override;
    procedure Peripherals(Context: TSettingsPageContext); override;
  end;

implementation

procedure TNeoGeoSettings.Video(Context: TSettingsPageContext);
begin
  Context.Heading('GroupNGHardware');
  if CoreId = 'neogeocd' then
    Context.Combo('RowNGModel', 'Hardware', 'Model',
      ['Automatic', 'Neo Geo CD front loader', 'Neo Geo CD top loader', 'Neo Geo CDZ'],
      ['auto', 'front', 'top', 'cdz'], 'auto')
  else if CoreId = 'neogeoaes' then
    Context.Check('RowNGPAL', 'Hardware', 'PAL', False)
  else
  begin
    Context.Combo('RowNGModel', 'Hardware', 'Model', ['Neo Geo MVS', 'Neo Geo AES'], ['auto', 'aes'], 'auto');
    Context.Check('RowNGPAL', 'Hardware', 'PAL', False);
  end;
  Context.Combo('RowNGRegion', 'Hardware', 'Region', ['Automatic', 'Japan', 'USA', 'Europe'],
    ['auto', 'japan', 'usa', 'europe'], 'auto');
  Context.PathEdit('RowNGBIOS', 'Hardware', 'BIOS', '', False);
end;

procedure TNeoGeoSettings.Peripherals(Context: TSettingsPageContext);
begin
  if CoreId = 'neogeocd' then
  begin
    Context.Heading('GroupNGDrive');
    Context.Check('RowNGDiscPresent', 'Drive', 'DiscPresent', True);
    Context.Check('RowNGTrayOpen', 'Drive', 'TrayOpen', False);
    Exit;
  end;
  Context.Heading('GroupNGCard');
  Context.Check('RowNGCardInserted', 'MemoryCard', 'Inserted', False);
  Context.Check('RowNGCardReadOnly', 'MemoryCard', 'ReadOnly', False);
  Context.PathEdit('RowNGCardPath', 'MemoryCard', 'Path', '', False);
  Context.Combo('RowNGCardSize', 'MemoryCard', 'Size', ['2 KiB', '4 KiB', '6 KiB', '8 KiB', '10 KiB', '12 KiB', '14 KiB', '16 KiB'],
    ['2048', '4096', '6144', '8192', '10240', '12288', '14336', '16384'], '2048');
  if (CoreId <> 'neogeoaes') and (Context.Draft.ReadString('Hardware', 'Model', 'auto') <> 'aes') then
  begin
    Context.Heading('GroupNGCabinet');
    Context.Check('RowNGSettingsMode', 'Cabinet', 'Settings', False);
    Context.Check('RowNGFreePlay', 'Cabinet', 'FreePlay', False);
    Context.Check('RowNGFreeze', 'Cabinet', 'Freeze', False);
    Context.Check('RowNGSingleCoin', 'Cabinet', 'SingleCoin', False);
  end;
end;

end.

