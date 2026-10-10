unit RM.Controllers.Browser;

interface

uses
  RM.Controllers.Base;

type
  TBrowserController = class(TMainController)
  public
    procedure InitializeScreenshotTool;
    procedure InitializeLibrary;
    {$IF not Defined(ANDROID) and not Defined(IOS)}
    procedure InitializeDesktopViews;
    {$ENDIF}
    procedure LibraryPlay(Sender: TObject);
    procedure LibraryBack(Sender: TObject);
    procedure UpdateGameChrome;
    procedure SetStatus(const Text: string);
    procedure LayoutClientClick(Sender: TObject);
    procedure LayoutClientDblClick(Sender: TObject);
  end;

implementation

uses
  System.SysUtils, System.Classes, System.UITypes, FMX.Types, FMX.Controls,
  FMX.Objects, RM.Main.View, RM.Toolbar, RM.LibraryView, RM.Dialogs, RM.Styles,
  RM.Icons;

procedure TBrowserController.InitializeScreenshotTool;
begin
  // Split buttons and hardware views have no installed design-time components.
  {$IF Defined(ANDROID) or Defined(IOS)}
  var ScreenshotButton := FView.AndroidScreenshot;
  ScreenshotButton.Visible := True;
  {$ELSE}
  var ScreenshotButton := TToolbarSplitButton.Create(FView);
  {$ENDIF}
  FState.Browser.ScreenshotTool := ScreenshotButton;
  {$IF not Defined(ANDROID) and not Defined(IOS)}
  ScreenshotButton.Name := 'ButtonScreenshot';
  {$ENDIF}
  ScreenshotButton.Parent := FView.LayoutHead;
  ScreenshotButton.Align := TAlignLayout.Right;
  ScreenshotButton.Width := 60;
  ScreenshotButton.Text := '';
  FView.ButtonCloseRom.Hint := Translate('Close game');
  ScreenshotButton.Hint := Translate('Screenshot (F8)');
  ScreenshotButton.ShowHint := True;
  ScreenshotButton.OnClick := FView.ScreenshotClick;
end;

procedure TBrowserController.InitializeLibrary;
begin
  FState.Browser.View := TLibraryView.CreateLibrary(FView, FState.Session.Storage);
  FState.Browser.View.Parent := FView.LibraryScreen;
  FState.Browser.View.Align := TAlignLayout.Client;
  FState.Browser.View.OnPlay := FView.LibraryPlay;
  FState.Browser.View.OnSettings := FView.SettingsClick;
  FState.Browser.View.OnOpen := FView.ButtonOpenClick;
  FView.LayoutClient.Visible := False;
  FState.Browser.ViewingLibrary := True;
  FView.ScreenTabs.ActiveTab := FView.LibraryScreen;
end;

{$IF not Defined(ANDROID) and not Defined(IOS)}
procedure TBrowserController.InitializeDesktopViews;
begin
  FState.Browser.BackTool := FView.ButtonLibrary;
  FState.Browser.BackTool.OnClick := FView.LibraryBack;
  FView.ButtonCloseRom.Visible := False;
  FState.Browser.Tools[0] := FView.GamePause;
  FState.Browser.Tools[1] := TToolbarSplitButton.Create(FView);
  FState.Browser.Tools[1].Name := 'GameSave';
  FState.Browser.Tools[2] := TToolbarSplitButton.Create(FView);
  FState.Browser.Tools[2].Name := 'GameLoad';
  FState.Browser.Tools[3] := FView.GameFullscreen;
  FState.Browser.Tools[4] := FView.GameSettings;
  for var i := 1 to 2 do
  begin
    FState.Browser.Tools[i].Parent := FView.LayoutHead;
    FState.Browser.Tools[i].Width := 104;
  end;
  FState.Browser.Tools[0].OnClick := FView.PauseClick;
  FState.Browser.Tools[1].OnClick := FView.SaveStateClick;
  FState.Browser.Tools[2].OnClick := FView.LoadStateClick;
  FState.Browser.Tools[3].OnClick := FView.FullscreenClick;
  FState.Browser.Tools[4].OnClick := FView.SettingsClick;
  GameplayButton(FState.Browser.Tools[1], Translate('Save'), IconSave, Translate('Quick save · F5'));
  GameplayButton(FState.Browser.Tools[2], Translate('Load'), IconLoad, Translate('Quick load · F6'));
  GameplayButton(FState.Browser.ScreenshotTool, Translate('Screenshot'), IconCamera, Translate('Take screenshot · F8'));
  for var Button in [FState.Browser.Tools[1], FState.Browser.Tools[2], FState.Browser.ScreenshotTool] do
    Button.StylesData['text.Margins.Right'] := 32;
  FState.Browser.ScreenshotMenu := FView.ScreenshotMenu;
  FState.Browser.SaveMenu := FView.SaveSnapshotMenu;
  FState.Browser.LoadMenu := FView.LoadSnapshotMenu;
  for var Menu in [FState.Browser.ScreenshotMenu, FState.Browser.SaveMenu, FState.Browser.LoadMenu] do
    Menu.OnPopup := FView.PrepareGameplayMenu;
  FState.Browser.ScreenshotTool.PopupMenu := FState.Browser.ScreenshotMenu;
  FState.Browser.Tools[1].PopupMenu := FState.Browser.SaveMenu;
  FState.Browser.Tools[2].PopupMenu := FState.Browser.LoadMenu;
  FState.Browser.CoinTool := FView.GameInsertCoin;
  FState.Browser.CoinTool.OnClick := FView.InsertCoinClick;
  FState.Browser.HelpTool := FView.GameControlsHelp;
  FState.Browser.HelpTool.OnClick := FView.ControlsHelpClick;
  FState.Browser.GamePlatform := FView.GamePlatform;
  FState.Browser.GameStatus := FView.GameStatus;
  FState.Browser.GameFPS := FView.GameFPS;
  FState.Browser.GameAudio := FView.GameAudio;
  for var Tool in [FView.ButtonLibrary, FView.GamePause, FView.GameFullscreen, FView.GameSettings, FView.GameInsertCoin, FView.GameControlsHelp] do
  begin
    Tool.StylesData['text.Margins.Left'] := 36;
    Tool.StylesData['text.Margins.Right'] := 10;
  end;
  FormStyles.RelocalizeUI(FView.GameScreen, 'en');
  FView.LayoutHead.OnResize := FView.FormResize;
  FView.FormResize(FView);
end;
{$ENDIF}

procedure TBrowserController.LibraryPlay(Sender: TObject);
begin
  if (FState.Browser.View.Selected = nil) or FState.Session.OpeningRom then
    Exit;

  var Game := FState.Browser.View.Selected;
  var Snapshot := FState.Browser.View.SnapshotName;
  try
    FView.LoadRom(Game.FileInfo.Location, Game.Title, Snapshot <> '');
    if Snapshot <> '' then
      FView.LoadSnapshot(Snapshot);
  except
    on E: Exception do
      ShowRetroMessage(FView, Translate('Unable to open game: ') + E.Message);
  end;
end;

procedure TBrowserController.LibraryBack(Sender: TObject);
begin
  if FState.Browser.View = nil then
    Exit;

  FView.FormDeactivate(FView);
  if FState.Session.Emulation <> nil then
  begin
    FState.Session.Emulation.Pause;
    if not FState.Browser.ViewingLibrary then
      FView.AutosaveOnExit;
  end;
  if FView.FullScreen then
    FView.SwitchFullScreen;
  FView.LayoutClient.Visible := False;
  FView.ScreenTabs.ActiveTab := FView.LibraryScreen;
  FState.Browser.View.Visible := True;
  FState.Browser.View.RefreshSnapshots;
  FState.Browser.View.BringToFront;
  FState.Browser.ViewingLibrary := True;
  FView.SyncActivity;
end;

procedure TBrowserController.UpdateGameChrome;
begin
  if csDestroying in FView.ComponentState then
    Exit;

  if FState.Browser.GamePlatform <> nil then
  begin
    FState.Browser.GamePlatform.Text := LibrarySystemName(FState.Input.SystemId);
    if FState.Session.Emulation <> nil then
      FState.Browser.GamePlatform.Text := FState.Session.Emulation.Name;
  end;
  if FState.Browser.GameStatus <> nil then
  begin
    FState.Browser.GameStatus.Visible := not FView.FullScreen;
    if FState.Session.Emulation <> nil then
      if FState.Session.Emulation.Config.AudioEnabled and (FState.Session.Emulation.Config.AudioVolume > 0) and not FState.Session.SoundErrorShown then
        FState.Browser.GameAudio.Text := Translate('Audio on')
      else
        FState.Browser.GameAudio.Text := Translate('Audio off');
  end;

  {$IF not Defined(ANDROID) and not Defined(IOS)}
  FView.LayoutHead.Visible := (FState.Browser.View <> nil) and not FView.FullScreen;
  {$ENDIF}

  if FState.Browser.CoinTool <> nil then
  begin
    var WasVisible := FState.Browser.CoinTool.Visible;
    FState.Browser.CoinTool.Visible := (FState.Session.Emulation <> nil) and FState.Session.Emulation.HasCoinAcceptor;
    FState.Browser.CoinTool.Enabled := FState.Browser.CoinTool.Visible and not FState.Session.EmulationFaulted and not FState.Session.OpeningRom and
      not FState.Browser.ViewingLibrary and (FState.Settings.View = nil) and (FState.Help.View = nil);
    if WasVisible <> FState.Browser.CoinTool.Visible then
      FView.FormResize(FView);
  end;
  if FState.Browser.HelpTool <> nil then
  begin
    FState.Browser.HelpTool.Enabled := (FState.Session.Emulation <> nil) and not FState.Session.OpeningRom and not FState.Help.Closing;
    if FState.Help.View <> nil then
      FState.Browser.HelpTool.StyleLookup := 'buttonstyle_accent'
    else
      FState.Browser.HelpTool.StyleLookup := 'buttonstyle';
    var Color: TAlphaColor := $FFFFB43B;
    if FState.Help.View <> nil then
      Color := $FF1B2026;
    FState.Browser.HelpTool.TextSettings.FontColor := Color;
    for var Child in FState.Browser.HelpTool.Children do
      if Child is FMX.Objects.TPath then
        FMX.Objects.TPath(Child).Stroke.Color := Color;
  end;

  {$IF not Defined(ANDROID) and not Defined(IOS)}
  if FView.FullScreen then
  begin
    // SyncActivity and frame/status updates can make controls visible again.
    // Hide game chrome while retaining the pause overlay.
    for var Child in FView.LayoutClient.Children do
      if (Child is TControl) and (Child <> FView.ImageCanvas) and (Child <> FView.RectangleBG) and (Child <> FView.LabelPaused) then
        TControl(Child).Visible := False;
    FView.ImageLogo.Visible := False;
  end;
  {$ENDIF}

  FView.UpdatePauseOverlay;
end;

procedure TBrowserController.SetStatus(const Text: string);
begin
  FView.Caption := AppName;

  {$IF Defined(ANDROID) or Defined(IOS)}
  FView.LabelStatus.Text := Text;
  {$ELSE}

  FView.LabelStatus.Text := Text;
  if FState.Session.Emulation <> nil then
    FView.LabelStatus.Text := FState.Session.RomDisplayName;
  FView.UpdateGameChrome;
  if FState.Browser.View <> nil then
    FView.FormResize(FView);
  {$ENDIF}
end;

procedure TBrowserController.LayoutClientClick(Sender: TObject);
begin
  FView.LayoutClient.SetFocus;
end;

procedure TBrowserController.LayoutClientDblClick(Sender: TObject);
begin
  {$IF Defined(ANDROID) or Defined(IOS)}
  Exit;
  {$ENDIF}
  FView.SwitchFullScreen;
end;

end.

