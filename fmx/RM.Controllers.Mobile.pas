unit RM.Controllers.Mobile;

interface

uses
  RM.Controllers.Base
  {$IF Defined(ANDROID) or Defined(IOS)}
    , FMX.Platform
  {$ENDIF};

type
  TMobileController = class(TMainController)
  public
    {$IF Defined(ANDROID) or Defined(IOS)}
    procedure InitializeMobileViews;
    {$ENDIF}
    {$IFDEF ANDROID}
    procedure InitializeAndroidServices;
    {$ENDIF}
    {$IF Defined(ANDROID) or Defined(IOS)}
    function ApplicationStateChanged(Sender: TObject; const AAppEvent: TApplicationEvent; const AContext: TObject): Boolean;
    {$ENDIF}
    {$IFDEF ANDROID}
    procedure PollDocumentTransfer;
    {$ENDIF}
  end;

implementation

uses
  System.SysUtils, System.Types, System.UITypes, System.IOUtils, FMX.Types,
  FMX.Controls, FMX.Forms, FMX.Objects, RM.Dialogs
  {$IF Defined(ANDROID) or Defined(IOS)}
    , FMX.ApplicationEvents
  {$ENDIF}
  {$IFDEF ANDROID}
    , Androidapi.Helpers, Androidapi.JNI.App, Androidapi.JNI.Media,
    RM.DocumentTransfer.Android
  {$ENDIF};

{$IF Defined(ANDROID) or Defined(IOS)}
procedure TMobileController.InitializeMobileViews;
begin
  FState.Mobile.AppEvents := TApplicationEvents.Create(FView);
  FState.Mobile.AppEvents.OnStateChanged := FView.ApplicationStateChanged;
  for var Tool in [FView.ButtonLibrary, FView.GameFullscreen, FView.GameSettings, FView.GameInsertCoin, FView.GameControlsHelp] do
    Tool.Visible := False;
  FView.GamePause.Visible := True;
  FView.GamePause.Text := '';
  FView.GamePause.OnClick := FView.PauseClick;
  FView.GamePause.Align := TAlignLayout.Right;
  FView.GamePause.Width := 60;
  for var Child in FView.GamePause.Children do
    if Child is FMX.Objects.TPath then
      FMX.Objects.TPath(Child).Align := TAlignLayout.Center;
  FView.GameStatus.Visible := False;
  FView.GamePlatform.Visible := False;
  (FView.FindComponent('ToolbarBackground') as TControl).Visible := False;
  FView.LabelPaused.TextSettings.Font.Size := 60;
  FView.LabelStatus.Align := TAlignLayout.Client;
  FView.LabelStatus.StyledSettings := [TStyledSetting.Family, TStyledSetting.Size,
      TStyledSetting.Style];
  FView.LabelStatus.TextSettings.FontColor := TAlphaColors.White;
  FView.LayoutClient.Visible := False;
  FView.ScreenTabs.ActiveTab := FView.GameScreen;
  FView.LayoutHead.OnResize := FView.FormResize;
end;

{$ENDIF}
{$IFDEF ANDROID}
procedure TMobileController.InitializeAndroidServices;
begin
  // Hardware volume keys control game audio, including before a ROM is loaded.
  TAndroidHelper.Activity.setVolumeControlStream(TJAudioManager.JavaClass.STREAM_MUSIC);
  FState.Mobile.Transfer := TAndroidDocumentTransfer.Create(FState.Session.Storage);
end;

{$ENDIF}
{$IF Defined(ANDROID) or Defined(IOS)}
function TMobileController.ApplicationStateChanged(Sender: TObject; const AAppEvent: TApplicationEvent; const AContext: TObject): Boolean;
begin
  case AAppEvent of
    TApplicationEvent.WillBecomeInactive, TApplicationEvent.EnteredBackground:
      FState.Mobile.InBackground := True;
    TApplicationEvent.BecameActive:
      FState.Mobile.InBackground := False;
  else
    Exit(False);
  end;
  FView.SyncActivity;
  // Mobile systems may terminate a background app without closing its form.
  if AAppEvent = TApplicationEvent.EnteredBackground then
  try
    FView.AutosaveOnExit;
  except
    Application.HandleException(FView);
  end;
  Result := False;
end;

{$ENDIF}
{$IFDEF ANDROID}
procedure TMobileController.PollDocumentTransfer;
begin
  if not FState.Session.OpeningRom then
    Exit;
  var FileName, DisplayName, Error: string;
  if not FState.Mobile.Transfer.Poll(FileName, DisplayName, Error) then
    Exit;
  try
    try
      if Error <> '' then
        raise Exception.Create(Error);
      if FileName <> '' then
        if FState.Mobile.ChoosingTape then
        begin
          // SAF documents are imported into a durable app-owned cassette file.
          var Root := System.IOUtils.TPath.Combine(FState.Session.Storage.SaveRoot, 'cassettes');
          var Path := FState.Session.Storage.GamePath(Root, DisplayName, TGUID.NewGuid.ToString, '.tape');
          var Input := FState.Session.Storage.OpenRead(FileName);
          try
            FState.Session.Storage.WriteAtomic(Path, Input);
          finally
            Input.Free;
          end;
          FView.SelectTapeFile(Path);
        end
        else
          FView.LoadRom(FileName, DisplayName);
    except
      on E: Exception do
        ShowRetroMessage(FView, E.Message);
    end;
  finally
    FView.FinishFileSelection;
  end;
end;

{$ENDIF}
end.

