unit RM.Settings.NGP;

interface

uses RM.Settings.Platform;

type
  TNGPSettings = class(TSettingsPlatform)
  public
    procedure Initialize(Context: TSettingsPageContext); override;
    procedure Video(Context: TSettingsPageContext); override;
  end;

implementation

procedure TNGPSettings.Initialize(Context: TSettingsPageContext);
begin
  Context.CreateGroup('NGPSystem','Neo Geo Pocket');
  Context.CreateOption('RowNGPBIOS','BIOS file',
    'Optional 64 KiB system ROM override. The monochrome and Color BIOS images are built in.',sekPath);
end;

procedure TNGPSettings.Video(Context: TSettingsPageContext);
begin
  Context.Heading('GroupNGPSystem');
  Context.PathEdit('RowNGPBIOS','Hardware','BIOS','',False);
end;

end.
