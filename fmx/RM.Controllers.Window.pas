unit RM.Controllers.Window;

interface

uses
  System.Types, RM.Controllers.Base;

type
  TWindowController = class(TMainController)
  public
    procedure FormResize(Sender: TObject);
    procedure ApplyControlInset;
    procedure FormSafeAreaChanged(Sender: TObject; const AInsets: TRectF);
    {$IFDEF MSWINDOWS}
    procedure RestoreWindowState;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    procedure SaveWindowState;
    {$ENDIF}
    procedure FullscreenClick(Sender: TObject);
    procedure SwitchFullScreen;
  end;

implementation

uses
  System.SysUtils, System.Classes, System.Math, System.UITypes, FMX.Types,
  FMX.Forms, FMX.Objects, FMX.StdCtrls, RM.Toolbar, RM.Gamepad,
  SG1000.Keyboard, NES.SuborKeyboard, NES.FamicomKeyboard, NES.MiraclePiano, NES.PowerPad,
  NES.DataRecorder, RM.Styles, RM.Icons
  {$IFDEF MSWINDOWS}
    , Winapi.Windows, Winapi.MultiMon, FMX.Platform.Win, FMX.Helpers.Win
  {$ENDIF};

procedure TWindowController.FormResize(Sender: TObject);
begin
  if csDestroying in FView.ComponentState then
    Exit;

  {$IF Defined(ANDROID) or Defined(IOS)}
  if FState.Browser.ScreenshotTool <> nil then
  begin
    FState.Browser.ScreenshotTool.Align := TAlignLayout.None;
    FView.GamePause.Align := TAlignLayout.None;
    var ToolY := FView.LayoutHead.Padding.Top;
    var ToolHeight := Max(0, FView.LayoutHead.Height - ToolY - FView.LayoutHead.Padding.Bottom);
    var ToolX := FView.LayoutHead.Width - FView.LayoutHead.Padding.Right - FState.Browser.ScreenshotTool.Width;
    FState.Browser.ScreenshotTool.SetBounds(ToolX, ToolY, 60, ToolHeight);
    FView.GamePause.SetBounds(ToolX - 68, ToolY, 60, ToolHeight);
    FView.LabelStatus.Align := TAlignLayout.None;
    FView.LabelStatus.SetBounds(55, ToolY, Max(0, ToolX - 68 - 63), ToolHeight);
  end;
  {$ENDIF}

  if (FState.Browser.BackTool <> nil) and (FState.Browser.HelpTool <> nil) then
  begin
    var HasCoin := (FState.Browser.CoinTool <> nil) and FState.Browser.CoinTool.Visible;
    var Narrow := FView.LayoutHead.Width < IfThen(HasCoin, 1482, 1282);
    var Compact := FView.LayoutHead.Width < IfThen(HasCoin, 740, 660);
    var Y := IfThen(Narrow, 56, 8);
    var Actions: TArray<TButton> := [
        FState.Browser.Tools[0], FState.Browser.Tools[1], FState.Browser.Tools[2],
        FState.Browser.ScreenshotTool,
        FState.Browser.Tools[3], FState.Browser.Tools[4], FState.Browser.HelpTool];
    var Widths: TArray<Single> := [130, 164, 164, 144, 44, 44, 88];
    if HasCoin then
    begin
      Actions := [
          FState.Browser.Tools[0], FState.Browser.CoinTool, FState.Browser.Tools[1],
          FState.Browser.Tools[2], FState.Browser.ScreenshotTool,
          FState.Browser.Tools[3], FState.Browser.Tools[4], FState.Browser.HelpTool];
      Widths := [130, 188, 164, 164, 144, 44, 44, 88];
    end;
    if Narrow and Compact then
    begin
      var Minimum: Single := 0;
      for var i := 0 to High(Actions) do
      begin
        Widths[i] := 32;
        if Actions[i] is TToolbarSplitButton then
          Widths[i] := 48;
        if i = 0 then
          Widths[i] := 58;
        Minimum := Minimum + Widths[i];
      end;
      var Extra := Max(0, (FView.LayoutHead.Width - 16 - (Length(Actions) - 1) * 6 - Minimum) / Length(Actions));
      for var i := 0 to High(Widths) do
        Widths[i] := Widths[i] + Extra;
    end;
    var Total: Single := (Length(Actions) - 1) * 8;
    for var W in Widths do
      Total := Total + W;
    var X := FView.LayoutHead.Width - Total - 12;
    if Narrow then
      X := 8;
    FView.LayoutHead.Height := IfThen(Narrow, 104, 64);
    FState.Browser.BackTool.Align := TAlignLayout.None;
    FState.Browser.BackTool.SetBounds(8, 8, 156, 40);
    var TitleWidth := Max(0, IfThen(Narrow, FView.LayoutHead.Width - 188, X - 192));
    FView.LabelStatus.SetBounds(184, 5, TitleWidth, 30);
    FState.Browser.GamePlatform.SetBounds(184, 33, TitleWidth, 22);
    FState.Browser.ScreenshotTool.Align := TAlignLayout.None;
    for var i := 0 to High(Actions) do
    begin
      var W := Widths[i];
      if Narrow and not Compact then
      begin
        W := (FView.LayoutHead.Width - 16 - (Length(Actions) - 1) * 6) / Length(Actions);
        if i = 0 then
          W := Max(32, W) + 26
        else
          W := Max(32, W - 26 / (Length(Actions) - 1));
      end;
      Actions[i].SetBounds(X, Y, W, 40);
      X := X + W + IfThen(Narrow, 6, 8);
    end;
    if (FState.Session.Emulation <> nil) and (FState.Session.UserPaused or FState.Session.AutoPaused) then
      FState.Browser.Tools[0].Text := Translate('Resume')
    else
      FState.Browser.Tools[0].Text := Translate('Pause');
    FState.Browser.Tools[1].Text := Translate('Save');
    FState.Browser.Tools[2].Text := Translate('Load');
    FState.Browser.ScreenshotTool.Text := Translate('Screenshot');
    if HasCoin then
      FState.Browser.CoinTool.Text := Translate('Insert coin');
    FState.Browser.Tools[3].Text := '';
    FState.Browser.Tools[4].Text := '';
    for var i := 0 to High(Actions) do
    begin
      if (Compact and (Actions[i] <> FState.Browser.HelpTool)) or ((Actions[i] = FState.Browser.CoinTool) and (Actions[i].Width < 180)) then
        Actions[i].Text := '';
      for var Child in Actions[i].Children do
        if Child is FMX.Objects.TPath then
        begin
          var Icon := FMX.Objects.TPath(Child);
          if i = 0 then
            if (FState.Session.Emulation <> nil) and (FState.Session.UserPaused or FState.Session.AutoPaused) then
              Icon.Data.Data := IconPlay
            else
              Icon.Data.Data := IconPause;
          var IconWidth := Actions[i].Width;
          if Actions[i] is TToolbarSplitButton then
            IconWidth := IconWidth - 26;
          Icon.Position.X := IfThen(Actions[i].Text = '', (IconWidth - 20) / 2, 12);
        end;
    end;
  end;
  if FState.Input.MiraclePiano <> nil then
    FState.Input.MiraclePiano.Height := TNesMiraclePiano.PreferredHeight(FView.LayoutClient.Width,
      FView.ClientHeight - FView.Padding.Top - FView.Padding.Bottom - FView.LayoutHead.Height);
  if FState.Input.DataRecorder <> nil then
    FState.Input.DataRecorder.Height := TNesDataRecorder.PreferredHeight(FView.LayoutClient.Width,
      FView.ClientHeight - FView.Padding.Top - FView.Padding.Bottom - FView.LayoutHead.Height);
  if FState.Input.PowerPad <> nil then
    FState.Input.PowerPad.Height := TNesPowerPad.PreferredHeight(FView.LayoutClient.Width,
      FView.ClientHeight - FView.Padding.Top - FView.Padding.Bottom - FView.LayoutHead.Height);
  if FState.Input.Gamepad <> nil then
  begin
    FState.Input.Gamepad.Height := TScreenGamepad.PreferredHeight(
      FView.ClientWidth - FView.Padding.Left - FView.Padding.Right,
      FView.ClientHeight - FView.Padding.Top - FView.Padding.Bottom - FView.LayoutHead.Height);
  end;
  if FState.Input.SGKeyboard <> nil then
    FState.Input.SGKeyboard.Height := TSGKeyboard.PreferredHeight(
      FView.ClientWidth - FView.Padding.Left - FView.Padding.Right,
      FView.ClientHeight - FView.Padding.Top - FView.Padding.Bottom - FView.LayoutHead.Height);
  if FState.Input.SuborKeyboard <> nil then
  begin
    FState.Input.SuborKeyboard.Height := TNesSuborKeyboard.PreferredHeight(
      FView.ClientWidth - FView.Padding.Left - FView.Padding.Right,
      FView.ClientHeight - FView.Padding.Top - FView.Padding.Bottom - FView.LayoutHead.Height);
  end;
  if FState.Input.FamicomKeyboard <> nil then
    FState.Input.FamicomKeyboard.Height := TNesFamicomKeyboard.PreferredHeight(
      FView.ClientWidth - FView.Padding.Left - FView.Padding.Right,
      FView.ClientHeight - FView.Padding.Top - FView.Padding.Bottom - FView.LayoutHead.Height);
end;

procedure TWindowController.ApplyControlInset;
begin
  if FState.Input.Gamepad <> nil then
    FState.Input.Gamepad.Margins.Bottom := FState.Input.BottomInset;
  if FState.Input.PowerPad <> nil then
    FState.Input.PowerPad.Margins.Bottom := FState.Input.BottomInset;
  if FState.Input.SuborKeyboard <> nil then
    FState.Input.SuborKeyboard.Margins.Bottom := FState.Input.BottomInset;
  if FState.Input.SGKeyboard <> nil then FState.Input.SGKeyboard.Margins.Bottom := FState.Input.BottomInset;
  if FState.Input.FamicomKeyboard <> nil then
    FState.Input.FamicomKeyboard.Margins.Bottom := FState.Input.BottomInset;
  if FState.Input.MiraclePiano <> nil then
    FState.Input.MiraclePiano.Margins.Bottom := FState.Input.BottomInset;
end;

procedure TWindowController.FormSafeAreaChanged(Sender: TObject; const AInsets: TRectF);
begin
  FView.Padding.Left := AInsets.Left;
  FView.Padding.Top := AInsets.Top;
  FView.Padding.Right := AInsets.Right;
  FView.Padding.Bottom := AInsets.Bottom;
  FView.FormResize(FView);
end;

{$IFDEF MSWINDOWS}
procedure TWindowController.RestoreWindowState;
begin
  var Ini := FState.Session.Storage.ReadConfig(FState.Session.Storage.ConfigFile('config'));
  try
    if not (Ini.ValueExists('Window', 'Left') and Ini.ValueExists('Window', 'Top') and
      Ini.ValueExists('Window', 'Width') and Ini.ValueExists('Window', 'Height')) then
      Exit;

    var X := Ini.ReadInteger('Window', 'Left', 0);
    var Y := Ini.ReadInteger('Window', 'Top', 0);
    var W := Ini.ReadInteger('Window', 'Width', 0);
    var H := Ini.ReadInteger('Window', 'Height', 0);

    if (W <= 0) or (H <= 0) or (W > 1000000) or (H > 1000000) or
      (Abs(Int64(X)) > 1000000) or (Abs(Int64(Y)) > 1000000) then
      Exit;

    var Bounds := TRect.Create(X, Y, X + W, Y + H);
    var Monitor := Default(TMonitorInfo);
    Monitor.cbSize := SizeOf(Monitor);
    if not GetMonitorInfo(MonitorFromRect(@Bounds, MONITOR_DEFAULTTONEAREST), @Monitor) then
      Exit;

    var Wnd := WindowHandleToPlatform(FView.Handle).Wnd;
    var Scale := FMX.Helpers.Win.GetWndScale(Wnd);
    if Scale <= 0 then
      Scale := 1;
    W := Min(Max(W, Round(FView.Constraints.MinWidth * Scale)), Monitor.rcWork.Width);
    H := Min(Max(H, Round(FView.Constraints.MinHeight * Scale)), Monitor.rcWork.Height);
    X := EnsureRange(X, Monitor.rcWork.Left, Monitor.rcWork.Right - W);
    Y := EnsureRange(Y, Monitor.rcWork.Top, Monitor.rcWork.Bottom - H);
    Bounds := TRect.Create(X, Y, X + W, Y + H);

    // WINDOWPLACEMENT uses workspace coordinates, not screen coordinates.
    OffsetRect(Bounds, Monitor.rcMonitor.Left - Monitor.rcWork.Left, Monitor.rcMonitor.Top - Monitor.rcWork.Top);
    var Placement := Default(TWindowPlacement);
    Placement.length := SizeOf(Placement);
    Placement.rcNormalPosition := Bounds;
    if Ini.ReadBool('Window', 'Maximized', False) then
      Placement.showCmd := SW_SHOWMAXIMIZED
    else
      Placement.showCmd := SW_SHOWNORMAL;
    FView.Position := TFormPosition.Designed;
    SetWindowPlacement(Wnd, @Placement);
  finally
    Ini.Free;
  end;
end;

procedure TWindowController.SaveWindowState;
begin
  if not FState.Window.WindowStateRestored or (FState.Session.Storage = nil) then
    Exit;

  var Placement := Default(TWindowPlacement);
  Placement.length := SizeOf(Placement);
  // Fullscreen is temporary gameplay UI: preserve its original window placement.
  if FView.FullScreen and (FState.Window.FullScreenPlacement.length <> 0) then
    Placement := FState.Window.FullScreenPlacement
  else if not GetWindowPlacement(WindowHandleToPlatform(FView.Handle).Wnd, @Placement) then
    Exit;

  var Bounds := Placement.rcNormalPosition;
  if (Bounds.Width <= 0) or (Bounds.Height <= 0) then
    Exit;

  var Monitor := Default(TMonitorInfo);
  Monitor.cbSize := SizeOf(Monitor);
  if GetMonitorInfo(MonitorFromRect(@Bounds, MONITOR_DEFAULTTONEAREST), @Monitor) then
    OffsetRect(Bounds, Monitor.rcWork.Left - Monitor.rcMonitor.Left,
      Monitor.rcWork.Top - Monitor.rcMonitor.Top);
  var Maximized := (Placement.showCmd = SW_SHOWMAXIMIZED) or
    ((Placement.showCmd = SW_SHOWMINIMIZED) and ((Placement.flags and WPF_RESTORETOMAXIMIZED) <> 0));
  var Ini := FState.Session.Storage.ReadConfig(FState.Session.Storage.ConfigFile('config'));
  try
    Ini.WriteInteger('Window', 'Left', Bounds.Left);
    Ini.WriteInteger('Window', 'Top', Bounds.Top);
    Ini.WriteInteger('Window', 'Width', Bounds.Width);
    Ini.WriteInteger('Window', 'Height', Bounds.Height);
    Ini.WriteBool('Window', 'Maximized', Maximized);
    FState.Session.Storage.WriteConfig(Ini);
    FState.Window.WindowStateSaved := True;
  finally
    Ini.Free;
  end;
end;
{$ENDIF}

procedure TWindowController.FullscreenClick(Sender: TObject);
begin
  FView.SwitchFullScreen;
end;

procedure TWindowController.SwitchFullScreen;
begin
  if (FState.Session.Emulation = nil) or FState.Browser.ViewingLibrary or (FState.Settings.View <> nil) or (FState.Help.View <> nil) then
    Exit;
  {$IF not Defined(ANDROID) and not Defined(IOS)}
  if not FView.FullScreen then
    FState.Browser.FullScreenPadding := FView.Padding.Rect;
  {$ENDIF}

  {$IFDEF MSWINDOWS}
  if not FView.FullScreen then
  begin
    FState.Window.FullScreenBorderStyle := FView.BorderStyle;
    FState.Window.FullScreenWindowState := FView.WindowState;
    FState.Window.FullScreenPlacement := Default(TWindowPlacement);
    FState.Window.FullScreenPlacement.length := SizeOf(FState.Window.FullScreenPlacement);
    if not GetWindowPlacement(WindowHandleToPlatform(FView.Handle).Wnd, @FState.Window.FullScreenPlacement) then
      FState.Window.FullScreenPlacement.length := 0;
  end;
  {$ENDIF}

  FView.FullScreen := not FView.FullScreen;

  {$IFDEF MSWINDOWS}
  if not FView.FullScreen then
  begin
    // FMX skips restoring the frame when the first fullscreen entry is from
    // a maximized window, because its saved normal size is still empty.
    FView.BorderStyle := FState.Window.FullScreenBorderStyle;
    FView.WindowState := FState.Window.FullScreenWindowState;
    // Restoring BorderStyle recreates the HWND. Preserve its normal restore
    // rectangle too, including when fullscreen was entered while maximized.
    if FState.Window.FullScreenPlacement.length <> 0 then
      SetWindowPlacement(WindowHandleToPlatform(FView.Handle).Wnd, @FState.Window.FullScreenPlacement);
    FView.UpdateSystemBackdropType;
  end;
  {$ENDIF}

  {$IF not Defined(ANDROID) and not Defined(IOS)}
  if FView.FullScreen then
    FView.Padding.Rect := TRectF.Empty
  else
    FView.Padding.Rect := FState.Browser.FullScreenPadding;
  {$ENDIF}

  {$IF Defined(ANDROID) or Defined(IOS)}
  // The game tab owns its toolbar as well as the canvas.
  FView.LayoutClient.Visible := True;
  {$ENDIF}

  if FView.FullScreen then
  begin
    FView.LayoutClient.Cursor := crNone;
    FView.LayoutClient.SetFocus;
  end
  else
    FView.LayoutClient.Cursor := crDefault;
  FView.SyncActivity;
  FState.Input.SuppressInputUntilRelease := True;
  FState.Input.KeysDown[vkF11] := True;
end;

end.

