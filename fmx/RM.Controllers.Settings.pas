unit RM.Controllers.Settings;

interface

uses
  RM.Controllers.Base;

type
  TSettingsController = class(TMainController)
  public
    procedure Load;
    procedure Save;
    procedure SettingsClick(Sender: TObject);
    procedure SettingsApplied(Sender: TObject);
    procedure SettingsClose(Sender: TObject);
    procedure ControlsHelpClick(Sender: TObject);
    procedure ControlsHelpClose(Sender: TObject);
    procedure ControlsHelpSettings(Sender: TObject);
    procedure CloseControlsHelp(OpenSettings: Boolean = False);
  end;

implementation

uses
  System.SysUtils, System.Classes, System.Math, System.UITypes, FMX.Types,
  Core.Emulation, Core.Adapter.GB, Core.Adapter.NES, Core.SavePaths,
  Core.RomFormat, RM.Settings, RM.ControlsHelp, RM.Styles;

procedure TSettingsController.Load;
begin
  var Ini := FState.Session.Storage.ReadConfig(FState.Session.Storage.ConfigFile('config'));
  try
    var PreviousLanguage := FormStyles.Lang.Lang;
    var FirstLaunch := not Ini.ValueExists('General', 'Language');
    var Language := Ini.ReadString('General', 'Language', 'en');
    if FirstLaunch then
      Language := FView.SystemLanguage;
    FormStyles.SetLanguage(Language);
    if FirstLaunch then
    begin
      Ini.WriteString('General', 'Language', FormStyles.Lang.Lang);
      FState.Session.Storage.WriteConfig(Ini);
    end;
    if PreviousLanguage <> FormStyles.Lang.Lang then
    begin
      FormStyles.RelocalizeUI(FView.LayoutClient, PreviousLanguage);
      if FState.Browser.View <> nil then
        FState.Browser.View.ApplyLanguage(PreviousLanguage);
      if FState.Settings.View <> nil then
        FState.Settings.View.ApplyLanguage(PreviousLanguage);
      if FState.Session.Emulation = nil then
        FView.SetStatus(Translate('Open ROM'));
    end;
    FState.Input.BottomInset := EnsureRange(Ini.ReadInteger('General', 'ControlBottomInset', 100), 0, 400);
    FView.ApplyControlInset;
    FState.Preferences.PauseOnFocusLoss := Ini.ReadBool('General', 'PauseOnFocusLoss', True);
    FState.Preferences.StartFullscreen := Ini.ReadBool('General', 'StartFullscreen', False);
    FState.Autosave.OnExit := Ini.ReadBool('General', 'AutosaveOnExit', True);
    FState.Autosave.Periodic := Ini.ReadBool('General', 'AutosavePeriodic', False);
    FState.Autosave.Minutes := EnsureRange(Ini.ReadInteger('General', 'AutosaveMinutes',
        AUTOSAVE_DEFAULT_MINUTES), 1, AUTOSAVE_MAX_MINUTES);
    FState.Autosave.LastTick := FView.CurrentTick;
  finally
    Ini.Free;
  end;
end;

procedure TSettingsController.Save;
begin
  var Ini := FState.Session.Storage.ReadConfig(FState.Session.Storage.ConfigFile('config'));
  try
    Ini.WriteString('General', 'Path', FState.Session.Storage.RomFolder);
    Ini.WriteInteger('General', 'ControlBottomInset', FState.Input.BottomInset);
    FState.Session.Storage.WriteConfig(Ini);
  finally
    Ini.Free;
  end;
end;

procedure TSettingsController.SettingsClick(Sender: TObject);
begin
  if FState.Help.View <> nil then
  begin
    FView.CloseControlsHelp(True);
    Exit;
  end;

  if FView.FullScreen then
    FView.SwitchFullScreen;
  if (FState.Settings.View <> nil) or FState.Session.OpeningRom then
    Exit;

  FState.Settings.LibraryVisible := (FState.Browser.View <> nil) and FState.Browser.View.Visible;
  if FState.Browser.View <> nil then
    FState.Browser.View.Visible := False;
  FState.Settings.WasPaused := (FState.Session.Emulation <> nil) and FState.Session.Emulation.IsPaused;
  if FState.Browser.View <> nil then
    FState.Settings.WasPaused := FState.Browser.ViewingLibrary or FState.Session.UserPaused or FState.Session.AutoPaused;
  FView.FormDeactivate(FView);
  if FState.Session.Emulation <> nil then
    FState.Session.Emulation.Pause;
  FState.Settings.ClientVisible := FView.LayoutClient.Visible;
  FState.Settings.View := TSettingsView.CreateSettings(FView, FState.Session.Storage, FState.Input.Manager);
  if FState.Session.Emulation <> nil then
    for var i := Low(SettingsCoreIds) to High(SettingsCoreIds) do
      if SettingsCoreIds[i] = FState.Input.SystemId then
      begin
        FState.Settings.View.SelectCore(i, True);
        Break;
      end;
  FState.Settings.View.Parent := FView.SettingsScreen;
  FView.ScreenTabs.ActiveTab := FView.SettingsScreen;
  FState.Settings.View.Align := TAlignLayout.Client;
  FState.Settings.View.OnApply := FView.SettingsApplied;
  FState.Settings.View.OnClose := FView.SettingsClose;
  FView.LayoutClient.Visible := False;
  FState.Settings.View.BringToFront;
  FView.SyncActivity;

  {$IFDEF ANDROID}
  FState.Input.Gamepad.AttachToForm(nil);
  FState.Input.PowerPad.AttachToForm(nil);
  FState.Input.SuborKeyboard.AttachToForm(nil);
  FState.Input.FamicomKeyboard.AttachToForm(nil);
  FState.Input.MiraclePiano.AttachToForm(nil);
  {$ENDIF}
end;

procedure TSettingsController.SettingsApplied(Sender: TObject);
begin
  if FState.Session.Emulation <> nil then
  begin
    var Config := FState.Session.Emulation.Config;
    var Ini := FState.Session.Storage.ReadConfig(Config.FileName);
    try
      Config.Filter := Ini.ReadString('Video', 'Filter', Config.Filter);
      var GBConfig: IGBEmulatorConfig;
      if (FState.Input.SystemId = ROM_SYSTEM_GB) and Supports(Config, IGBEmulatorConfig, GBConfig) then
        GBConfig.ScreenPalette := Ini.ReadInteger('Video', 'Palette', GBConfig.ScreenPalette);
      FView.ImageCanvas.DisableInterpolation := SameText(Config.Filter, 'nearest');
      FView.ImageCanvas.Repaint;
    finally
      Ini.Free;
    end;
  end;
  FView.Load;
  if FState.Browser.View <> nil then
  begin
    FState.Browser.View.ApplyPreferences;
    FState.Browser.View.Reload;
  end;
  FView.ReloadHostInputBindings;
end;

procedure TSettingsController.SettingsClose(Sender: TObject);
begin
  if (FState.Settings.View = nil) or FState.Settings.Closing then
    Exit;

  FState.Settings.Closing := True;
  FState.Settings.View.Visible := False;
  // Release through the UI queue so the clicked button finishes its event first.
  var Alive: TFunc<Boolean> := FState.Session.CallbackAlive;
  TThread.ForceQueue(nil,
    procedure
    begin
      if not Alive() then
        Exit;

      FreeAndNil(FState.Settings.View);
      FState.Settings.Closing := False;
      if FState.Settings.LibraryVisible then
        FView.ScreenTabs.ActiveTab := FView.LibraryScreen
      else
        FView.ScreenTabs.ActiveTab := FView.GameScreen;
      if FState.Browser.View <> nil then
        FState.Browser.View.Visible := FState.Settings.LibraryVisible;
      FView.LayoutClient.Visible := FState.Settings.ClientVisible;
      //LoadSystem(FSystemId);
      FView.ReloadHostInputBindings;
      FState.Input.SuppressInputUntilRelease := True;
      if (FState.Session.Emulation <> nil) and not FState.Settings.WasPaused and not FState.Session.EmulationFaulted then
        FState.Session.Emulation.Resume;
      FView.SyncActivity;

      {$IF Defined(ANDROID) or Defined(IOS)}
      FView.FormActivate(FView);
      {$ENDIF}

      if FView.LayoutClient.Visible then
        FView.LayoutClient.SetFocus;
    end);
end;

procedure TSettingsController.ControlsHelpClick(Sender: TObject);
begin
  if FState.Help.View <> nil then
  begin
    FView.ControlsHelpClose(FView);
    Exit;
  end;

  if (FState.Session.Emulation = nil) or FState.Browser.ViewingLibrary or (FState.Settings.View <> nil) or FState.Session.OpeningRom or FState.Help.Closing then
    Exit;

  FState.Help.WasPaused := FState.Session.Emulation.IsPaused or FState.Session.UserPaused or FState.Session.AutoPaused;
  FState.Help.FullScreen := FView.FullScreen;
  if FView.FullScreen then
    FView.SwitchFullScreen;
  FView.FormDeactivate(FView);
  FState.Session.Emulation.Pause;
  var Players := 2;
  if FState.Input.SystemId = ROM_SYSTEM_GB then
    Players := 1;
  if FState.Input.SystemId = ROM_SYSTEM_GBC then
    Players := 1;
  if FState.Input.SystemId = ROM_SYSTEM_SNES then
    if FState.Input.Ports.Multitap[1] then
      Players := 8
    else if FState.Input.Ports.Multitap[0] then
      Players := 5;
  if FState.Input.SystemId = ROM_SYSTEM_NES then
  begin
    var Config: INesEmulatorConfig;
    if Supports(FState.Session.Emulation.Config, INesEmulatorConfig, Config) and Config.FourScore then
      Players := 4;
  end;
  var Peripheral: INesPeripheralCore;
  var Piano: INesMiraclePianoCore;
  var KeyboardPeripheral := FState.Session.Emulation.UsesSuborKeyboard or
    (Supports(FState.Session.Emulation, INesPeripheralCore, Peripheral) and Peripheral.UsesFamicomKeyboard) or
    (Supports(FState.Session.Emulation, INesMiraclePianoCore, Piano) and Piano.UsesMiraclePiano);
  try
    FState.Help.View := TControlsHelpView.CreateHelp(FView, FState.Input.Manager, FState.Input.SystemId, FState.Input.Ports, Players, KeyboardPeripheral, FState.Session.Storage, FState.Session.Emulation.HasCoinAcceptor);
    FState.Help.View.Parent := FView;
    FState.Help.View.Align := TAlignLayout.Contents;
    FState.Help.View.OnClose := FView.ControlsHelpClose;
    FState.Help.View.OnSettings := FView.ControlsHelpSettings;
    FState.Help.View.BringToFront;
  except
    FreeAndNil(FState.Help.View);
    if not FState.Help.WasPaused then
      FState.Session.Emulation.Resume;
    if FState.Help.FullScreen then
      FView.SwitchFullScreen;
    raise;
  end;

  FState.Input.KeysDown[vkF1] := True;
  FView.SyncActivity;
end;

procedure TSettingsController.ControlsHelpClose(Sender: TObject);
begin
  FView.CloseControlsHelp;
end;

procedure TSettingsController.ControlsHelpSettings(Sender: TObject);
begin
  FView.CloseControlsHelp(True);
end;

procedure TSettingsController.CloseControlsHelp(OpenSettings: Boolean);
begin
  if (FState.Help.View = nil) or FState.Help.Closing then
    Exit;

  FState.Help.Closing := True;
  var Alive: TFunc<Boolean> := FState.Session.CallbackAlive;
  TThread.ForceQueue(nil,
    procedure
    begin
      if not Alive() then
        Exit;

      FreeAndNil(FState.Help.View);
      FState.Help.Closing := False;
      if (FState.Session.Emulation <> nil) and
        not FState.Help.WasPaused and
        not FState.Session.UserPaused and
        not FState.Session.AutoPaused and
        not FState.Session.EmulationFaulted and
        FView.InputHasFocus then
        FState.Session.Emulation.Resume;
      FState.Input.SuppressInputUntilRelease := True;
      FillChar(FState.Input.KeysDown, SizeOf(FState.Input.KeysDown), 0);
      if OpenSettings then
      begin
        FView.SettingsClick(FView);
        if FState.Settings.View <> nil then
        begin
          for var i := Low(SettingsCoreIds) to High(SettingsCoreIds) do
            if SettingsCoreIds[i] = FState.Input.SystemId then
              FState.Settings.View.SelectCore(i);
          FState.Settings.View.SelectCategory(3);
        end;
      end
      else
      begin
        if FState.Help.FullScreen and (FState.Session.Emulation <> nil) and not FState.Browser.ViewingLibrary then
          FView.SwitchFullScreen;
        FView.FormActivate(FView);
        FView.LayoutClient.SetFocus;
      end;
      FView.SyncActivity;
    end);
end;

end.

