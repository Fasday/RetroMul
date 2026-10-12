unit RM.Controllers.Session;

interface

uses
  System.SysUtils, FMX.Types, Core.Emulation, RM.Controllers.Base;

type
  TSessionController = class(TMainController)
  private
    FLoadingCore: Boolean;
    FLoadGeneration: Integer;
    procedure EndCoreLoading;
    procedure CancelCoreLoading;
    procedure InstallCore(const NewEmulation: IEmulationCore; const FileName, DisplayName: string; StartPaused: Boolean);
  public
    procedure FormActivate(Sender: TObject);
    procedure FormDeactivate(Sender: TObject);
    procedure ApplicationException(Sender: TObject; E: Exception);
    procedure DialogActivityChanged(Sender: TObject);
    procedure SyncActivity;
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormSaveState(Sender: TObject);
    procedure ButtonOpenClick(Sender: TObject);
    procedure OpenRom;
    procedure SelectDocument(ForCassette: Boolean; const FileName: string = '');
    procedure FinishFileSelection;
    function CanAcceptRomDrop(const Data: TDragObject): Boolean;
    procedure LoadRom(const FileName: string; const DisplayName: string = ''; StartPaused: Boolean = False; const SnapshotName: string = '');
    procedure ButtonCloseRomClick(Sender: TObject);
    procedure Stop;
    procedure StopOnError;
    procedure TimerUpdateTimer(Sender: TObject);
    function UpdateFrame: Boolean;
    procedure PauseClick(Sender: TObject);
    procedure SwitchPause;
    procedure UpdatePauseOverlay;
    procedure InsertCoinClick(Sender: TObject);
  end;

implementation

uses
  System.Classes, System.UITypes, System.Math, RM.Input, System.IOUtils,
  FMX.Forms, FMX.Objects, FMX.Graphics, FMX.OpenDialog, Core.Storage,
  Core.EmulatorFactory, Core.Adapter.SG1000, Core.Adapter.N64, Core.Adapter.MD, Core.Adapter.SNES, Core.Adapter.NeoGeo,
  Core.Adapter.GBA, Core.Adapter.GB, Core.Adapter.GBC, Core.Adapter.NES,
  Core.InputConfig, Core.RomFormat, RM.Gamepad, RM.FrameUpload, NES.Controller,
  RM.Dialogs, RM.Styles, RM.Icons;

procedure TSessionController.FormActivate(Sender: TObject);
begin
  if FState.Session.OpeningRom then
    Exit;

  if FState.Session.AutoPaused and not FState.Session.UserPaused and not FState.Browser.ViewingLibrary and
    not RetroDialogVisible(FView) and (FState.Settings.View = nil) and (FState.Help.View = nil) then
  begin
    FState.Session.AutoPaused := False;
    if (FState.Session.Emulation <> nil) and not FState.Session.EmulationFaulted then
      FState.Session.Emulation.Resume;
  end;

  FState.Input.SuppressInputUntilRelease := True;
  {$IFDEF ANDROID}
  if FState.Mobile.MiraclePianoTouchAttached then
    FState.Input.MiraclePiano.AttachToForm(FView)
  else if FState.Mobile.PowerPadTouchAttached then
    FState.Input.PowerPad.AttachToForm(FView)
  else if FState.Mobile.SGKeyboardTouchAttached then
    FState.Input.SGKeyboard.AttachToForm(FView)
  else if FState.Mobile.SuborKeyboardTouchAttached then
    FState.Input.SuborKeyboard.AttachToForm(FView)
  else if FState.Mobile.FamicomKeyboardTouchAttached then
    FState.Input.FamicomKeyboard.AttachToForm(FView)
  else if FState.Input.Gamepad <> nil then
    FState.Input.Gamepad.AttachToForm(FView);
  {$ENDIF}
  FView.SyncActivity;
end;

procedure TSessionController.FormDeactivate(Sender: TObject);
begin
  if FState.Input.Rumble <> nil then
    FState.Input.Rumble.Stop;

  {$IF not Defined(ANDROID) and not Defined(IOS)}
  if FState.Preferences.PauseOnFocusLoss and not FView.InputHasFocus and not FState.Browser.ViewingLibrary and
    not RetroDialogVisible(FView) and (FState.Settings.View = nil) and
    (FState.Session.Emulation <> nil) and not FState.Session.Emulation.IsPaused then
  begin
    FState.Session.AutoPaused := True;
    FState.Session.Emulation.Pause;
  end;
  {$ENDIF}

  // Release keys whose key-up may be lost. Mobile lifecycle controls pausing.
  FillChar(FState.Input.KeysDown, SizeOf(FState.Input.KeysDown), 0);
  FState.Input.SuppressInputUntilRelease := True;
  if FState.Input.Manager <> nil then
    FState.Input.Manager.Enabled := False;
  if FState.Settings.View <> nil then
    FState.Settings.View.CancelCapture;
  if FState.Input.Gamepad <> nil then
    FState.Input.Gamepad.ReleaseAll;
  if FState.Input.SuborKeyboard <> nil then
    FState.Input.SuborKeyboard.ReleaseAll;
  if FState.Input.SGKeyboard <> nil then FState.Input.SGKeyboard.ReleaseAll;
  if FState.Input.FamicomKeyboard <> nil then
    FState.Input.FamicomKeyboard.ReleaseAll;
  if FState.Input.MiraclePiano <> nil then
    FState.Input.MiraclePiano.ReleaseAll;
  if FState.Input.PowerPad <> nil then
    FState.Input.PowerPad.ReleaseAll;
  if FState.Session.Emulation <> nil then
    FState.Session.Emulation.ClearInput;
  FState.Input.GamepadInput := Default(TEmulatorInput);
  {$IF not Defined(ANDROID) and not Defined(IOS)}
  if not (csDestroying in FView.ComponentState) then
    FView.SyncActivity;
  {$ENDIF}
end;

procedure TSessionController.ApplicationException(Sender: TObject; E: Exception);
begin
  if not (E is EAbort) then
  begin
    var MessageText := E.Message;
    if MessageText.Trim = '' then
      MessageText := E.ClassName;
    ShowRetroMessage(FView, MessageText);
  end;
end;

procedure TSessionController.DialogActivityChanged(Sender: TObject);
begin
  if RetroDialogVisible(FView) then
  begin
    FState.Session.DialogCore := FState.Session.Emulation;
    FState.Session.DialogWasPaused := (FState.Session.Emulation = nil) or FState.Session.Emulation.IsPaused;
    FView.FormDeactivate(FView);
    if (FState.Session.Emulation <> nil) and not FState.Session.EmulationFaulted then
      FState.Session.Emulation.Pause;
  end
  else
  begin
    FState.Input.SuppressInputUntilRelease := True;
    FillChar(FState.Input.KeysDown, SizeOf(FState.Input.KeysDown), 0);
    if (FState.Session.DialogCore <> nil) and (FState.Session.DialogCore = FState.Session.Emulation) and
      not FState.Session.DialogWasPaused and not FState.Session.EmulationFaulted and not FState.Session.UserPaused and
      not FState.Session.AutoPaused and {$IF Defined(ANDROID) or Defined(IOS)}not FState.Mobile.InBackground and {$ENDIF} not FState.Session.OpeningRom and
      not FState.Browser.ViewingLibrary and (FState.Settings.View = nil) and (FState.Help.View = nil) then
      FState.Session.Emulation.Resume;
    FState.Session.DialogCore := nil;
  end;
  FView.SyncActivity;
end;

procedure TSessionController.SyncActivity;
begin
  if RetroDialogVisible(FView) and (FState.Session.Emulation <> nil) and (FState.Session.DialogCore <> FState.Session.Emulation) then
  begin
    // A queued message may survive loading a new session.
    FState.Session.DialogCore := FState.Session.Emulation;
    FState.Session.DialogWasPaused := FState.Session.UserPaused;
    FState.Session.Emulation.Pause;
  end;
  {$IF Defined(ANDROID) or Defined(IOS)}
  FView.GamePause.Enabled := (FState.Session.Emulation <> nil) and not FState.Session.EmulationFaulted and not FState.Session.OpeningRom;
  var UserPaused := (FState.Session.Emulation <> nil) and (FState.Session.UserPaused or FState.Session.AutoPaused);
  if UserPaused then
  begin
    FView.GamePause.Hint := Translate('Resume');
    FView.GamePause.StyleLookup := 'buttonstyle_accent';
  end
  else
  begin
    FView.GamePause.Hint := Translate('Pause');
    FView.GamePause.StyleLookup := 'buttonstyle';
  end;
  for var Child in FView.GamePause.Children do
    if Child is FMX.Objects.TPath then
    begin
      var Icon := FMX.Objects.TPath(Child);
      if UserPaused then
      begin
        Icon.Data.Data := IconPlay;
        Icon.Stroke.Color := $FF1B2026;
      end
      else
      begin
        Icon.Data.Data := IconPause;
        Icon.Stroke.Color := $FFE8ECF1;
      end;
    end;
  {$ENDIF}
  if FState.Browser.Tools[0] <> nil then
  begin
    FState.Browser.Tools[0].Enabled := (FState.Session.Emulation <> nil) and not FState.Session.EmulationFaulted and not FState.Session.OpeningRom;
    if (FState.Session.Emulation <> nil) and (FState.Session.UserPaused or FState.Session.AutoPaused) then
      FState.Browser.Tools[0].Text := Translate('Resume')
    else
      FState.Browser.Tools[0].Text := Translate('Pause');
    FState.Browser.Tools[1].Enabled := (FState.Session.Emulation <> nil) and FState.Session.Emulation.SupportsSnapshots and not FState.Session.OpeningRom;
    FState.Browser.Tools[2].Enabled := FState.Browser.Tools[1].Enabled;
    FState.Browser.Tools[4].Enabled := not FState.Session.OpeningRom;
  end;
  if FState.Browser.ScreenshotTool <> nil then
    FState.Browser.ScreenshotTool.Enabled := (FState.Session.Emulation <> nil) and not FState.Session.OpeningRom;
  var Tape: INesTapeCore;
  if FState.Input.DataRecorder <> nil then
  begin
    FState.Input.DataRecorder.Visible := Supports(FState.Session.Emulation, INesTapeCore, Tape) and Tape.UsesDataRecorder;
    FState.Input.DataRecorder.Enabled := FState.Input.DataRecorder.Visible and not FState.Session.OpeningRom and not FState.Session.EmulationFaulted;
    if FState.Input.DataRecorder.Visible then
      FState.Input.DataRecorder.Progress := Tape.GetTapeProgress;
  end;
  var SGKeyboard: ISGKeyboardCore;
  var SGKeyboardActive := Supports(FState.Session.Emulation, ISGKeyboardCore, SGKeyboard) and SGKeyboard.HasKeyboard;
  if FState.Input.SGKeyboard <> nil then
  begin
    FState.Input.SGKeyboard.Visible := SGKeyboardActive;
    FState.Input.SGKeyboard.Enabled := SGKeyboardActive and not FState.Session.EmulationFaulted and not FState.Session.OpeningRom
      and not FState.Browser.ViewingLibrary and (FState.Settings.View = nil) and (FState.Help.View = nil) and not RetroDialogVisible(FView);
  end;
  var SuborKeyboardActive := (FState.Session.Emulation <> nil) and FState.Session.Emulation.UsesSuborKeyboard;
  var Peripheral: INesPeripheralCore;
  var FamicomKeyboardActive := Supports(FState.Session.Emulation, INesPeripheralCore, Peripheral) and Peripheral.UsesFamicomKeyboard;
  var Piano: INesMiraclePianoCore;
  var PianoActive := Supports(FState.Session.Emulation, INesMiraclePianoCore, Piano) and Piano.UsesMiraclePiano;
  if FState.Input.MiraclePiano <> nil then
  begin
    FState.Input.MiraclePiano.Visible := PianoActive;
    FState.Input.MiraclePiano.Enabled := PianoActive and not FState.Session.EmulationFaulted and not FState.Session.OpeningRom;
  end;
  {$IF Defined(ANDROID) or Defined(IOS)}
  var KeyboardActive := SGKeyboardActive or SuborKeyboardActive or FamicomKeyboardActive or PianoActive;
  var PowerPadActive := Supports(FState.Session.Emulation, INesPeripheralCore, Peripheral);
  if PowerPadActive then
    PowerPadActive := Peripheral.UsesPowerPad and not KeyboardActive;
  if FState.Input.Gamepad <> nil then
  begin
    FState.Input.Gamepad.Visible := not KeyboardActive and not PowerPadActive;
    FState.Input.Gamepad.Enabled := (FState.Session.Emulation <> nil) and not FState.Session.EmulationFaulted and not FState.Session.OpeningRom and not KeyboardActive and not PowerPadActive;
  end;
  {$ENDIF}
  if FState.Input.SuborKeyboard <> nil then
  begin
    FState.Input.SuborKeyboard.Visible := SuborKeyboardActive;
    FState.Input.SuborKeyboard.Enabled := SuborKeyboardActive and not FState.Session.EmulationFaulted and not FState.Session.OpeningRom;
  end;
  if FState.Input.FamicomKeyboard <> nil then
  begin
    FState.Input.FamicomKeyboard.Visible := FamicomKeyboardActive;
    FState.Input.FamicomKeyboard.Enabled := FamicomKeyboardActive and not FState.Session.EmulationFaulted and not FState.Session.OpeningRom;
  end;

  {$IF Defined(ANDROID) or Defined(IOS)}
  if FState.Input.PowerPad <> nil then
  begin
    FState.Input.PowerPad.Visible := PowerPadActive;
    FState.Input.PowerPad.Enabled := PowerPadActive and not FState.Session.EmulationFaulted and not FState.Session.OpeningRom;
  end;
  {$IFDEF ANDROID}
  // The Android view accepts one native touch listener.
  // The controls are mutually exclusive, so hand it to the currently visible control.
  if (FState.Mobile.SGKeyboardTouchAttached <> SGKeyboardActive) or
    (FState.Mobile.SuborKeyboardTouchAttached <> SuborKeyboardActive) or
    (FState.Mobile.FamicomKeyboardTouchAttached <> FamicomKeyboardActive) or
    (FState.Mobile.PowerPadTouchAttached <> PowerPadActive) or
    (FState.Mobile.MiraclePianoTouchAttached <> PianoActive) then
  begin
    if FState.Mobile.MiraclePianoTouchAttached then
      FState.Input.MiraclePiano.AttachToForm(nil)
    else if FState.Mobile.PowerPadTouchAttached then
      FState.Input.PowerPad.AttachToForm(nil)
    else if FState.Mobile.SGKeyboardTouchAttached then
      FState.Input.SGKeyboard.AttachToForm(nil)
    else if FState.Mobile.SuborKeyboardTouchAttached then
      FState.Input.SuborKeyboard.AttachToForm(nil)
    else if FState.Mobile.FamicomKeyboardTouchAttached then
      FState.Input.FamicomKeyboard.AttachToForm(nil)
    else
      FState.Input.Gamepad.AttachToForm(nil);
    if PianoActive then
      FState.Input.MiraclePiano.AttachToForm(FView)
    else if PowerPadActive then
      FState.Input.PowerPad.AttachToForm(FView)
    else if SGKeyboardActive then
      FState.Input.SGKeyboard.AttachToForm(FView)
    else if SuborKeyboardActive then
      FState.Input.SuborKeyboard.AttachToForm(FView)
    else if FamicomKeyboardActive then
      FState.Input.FamicomKeyboard.AttachToForm(FView)
    else
      FState.Input.Gamepad.AttachToForm(FView);
    FState.Mobile.SGKeyboardTouchAttached := SGKeyboardActive;
    FState.Mobile.SuborKeyboardTouchAttached := SuborKeyboardActive;
    FState.Mobile.FamicomKeyboardTouchAttached := FamicomKeyboardActive;
    FState.Mobile.PowerPadTouchAttached := PowerPadActive;
    FState.Mobile.MiraclePianoTouchAttached := PianoActive;
  end;
  {$ENDIF}
  if FState.Input.MiraclePiano <> nil then
    FState.Input.MiraclePiano.Enabled := FState.Input.MiraclePiano.Enabled and not FState.Mobile.InBackground and not RetroDialogVisible(FView);
  var Paused := FState.Mobile.InBackground or FState.Session.OpeningRom or FState.Browser.ViewingLibrary or FState.Session.UserPaused or
    (FState.Settings.View <> nil) or (FState.Help.View <> nil) or RetroDialogVisible(FView);
  if FState.Input.PowerPad <> nil then
    FState.Input.PowerPad.Enabled := FState.Input.PowerPad.Enabled and not FState.Mobile.InBackground and not RetroDialogVisible(FView);
  if FState.Input.SGKeyboard <> nil then
    FState.Input.SGKeyboard.Enabled := FState.Input.SGKeyboard.Enabled and not FState.Mobile.InBackground;
  if FState.Input.Gamepad <> nil then
    FState.Input.Gamepad.Enabled := FState.Input.Gamepad.Enabled and not FState.Mobile.InBackground and not RetroDialogVisible(FView);
  if FState.Input.SuborKeyboard <> nil then
    FState.Input.SuborKeyboard.Enabled := FState.Input.SuborKeyboard.Enabled and not FState.Mobile.InBackground and not RetroDialogVisible(FView);
  if FState.Input.FamicomKeyboard <> nil then
    FState.Input.FamicomKeyboard.Enabled := FState.Input.FamicomKeyboard.Enabled and not FState.Mobile.InBackground and not RetroDialogVisible(FView);
  if Paused <> FState.Mobile.ActivityPaused then
  begin
    FState.Mobile.ActivityPaused := Paused;
    if FState.Session.Emulation <> nil then
      if Paused then
      begin
        FView.FormDeactivate(FView);
        FState.Session.Emulation.Pause;
      end
      else if not FState.Session.EmulationFaulted then
        FState.Session.Emulation.Resume;
  end;
  FView.TimerUpdate.Enabled := not FState.Mobile.InBackground and (FState.Session.OpeningRom or ((FState.Session.Emulation <> nil) and not FState.Session.EmulationFaulted));
  {$ELSE}

  // Idle windows use native key events. Keep polling for gameplay and settings
  // capture; background rendering is only needed while a core is running.
  var NeedsInput := (FState.Input.Manager <> nil) and FView.InputHasFocus and
    not FState.Session.OpeningRom and
    ((FState.Settings.View <> nil) or (FState.Session.Emulation <> nil));
  var NeedsFrames := (FState.Session.Emulation <> nil) and
    not FState.Session.EmulationFaulted and not FState.Session.Emulation.IsPaused;
  FView.TimerUpdate.Enabled := NeedsInput or NeedsFrames;
  {$ENDIF}
  FView.SyncMotionSensor;
  FView.PollRumble;
  FView.UpdateGameChrome;
end;

procedure TSessionController.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  try
    {$IFDEF MSWINDOWS}
    FView.SaveWindowState;
    {$ENDIF}
    FView.Stop;
  except
    on E: Exception do
    begin
      CanClose := False;
      {$IFDEF MSWINDOWS}
      FState.Window.WindowStateSaved := False;
      {$ENDIF}
      ShowRetroMessage(FView, E.Message);
    end;
  end;
end;

procedure TSessionController.FormSaveState(Sender: TObject);
begin
  try
    FView.Save;
  except
    on E: Exception do
      ShowRetroMessage(FView, E.Message);
  end;
end;

procedure TSessionController.ButtonOpenClick(Sender: TObject);
begin
  try
    FView.OpenRom;
  except
    on E: Exception do
      ShowRetroMessage(FView, E.Message);
  end;
end;

procedure TSessionController.OpenRom;
begin
  FView.SelectDocument(False);
end;

procedure TSessionController.SelectDocument(ForCassette: Boolean; const FileName: string);
begin
  if FState.Session.OpeningRom then
    Exit;

  if not ForCassette and (FState.Help.View <> nil) then
    FView.CloseControlsHelp;
  FState.Session.OpeningRom := True;
  FView.FormDeactivate(FView);
  FView.SyncActivity;
  var IsAlive: TFunc<Boolean> := FState.Session.CallbackAlive;
  var Completion: TStorageSelectionCallback :=
    procedure(const Selection: TStorageSelection)
    begin
      if not IsAlive() then
        Exit;

      var Importing := False;
      try
        try
          if Selection.Error <> '' then
            raise Exception.Create(Selection.Error);

          if not Selection.Cancelled then
          begin
            if ForCassette then
            begin
              {$IFDEF ANDROID}
              FState.Mobile.ChoosingTape := True;
              FState.Mobile.Transfer.Import(Selection.Location, True);
              Importing := True;
              {$ELSE}
              FView.SelectTapeFile(Selection.Location);
              {$ENDIF}
            end
            else
              FView.LoadRom(Selection.Location, FState.Session.Storage.Describe(Selection.Location).Name);
          end;
        except
          on E: Exception do
            ShowRetroMessage(FView, E.Message);
        end;
      finally
        if not Importing then
          FView.FinishFileSelection;
      end;
    end;
  if FileName <> '' then
  begin
    var Selection := Default(TStorageSelection);
    Selection.Location := FileName;
    Completion(Selection);
  end
  else if ForCassette then
  begin
    FState.Session.FileDialog.InitialDirectory := '';
    FState.Session.FileDialog.FileMustExist := False;
    FState.Session.FileDialog.Title := Translate('Choose a cassette file');
    FState.Session.FileDialog.Filter := Translate('Cassette (*.tape)|*.tape|All files|*.*');
    FState.Session.FileDialog.SelectFiles(
      procedure(const Selection: TFMXSelectionResult)
      begin
        var Result := Default(TStorageSelection);
        Result.Cancelled := Selection.Status = TFMXSelectionStatus.Cancelled;
        Result.Error := Selection.Error;
        if Selection.Status = TFMXSelectionStatus.Selected then
          Result.Location := Selection.Locations[0];
        Completion(Result);
      end);
  end
  else
  begin
    FView.ImageLogo.Visible := False;
    FState.Session.Storage.SelectRom(Completion);
  end;
end;

procedure TSessionController.FinishFileSelection;
begin
  if FLoadingCore then
    Exit;

  {$IFDEF ANDROID}
  FState.Mobile.Transfer.Finish;
  FState.Mobile.ChoosingTape := False;
  {$ENDIF}
  FState.Session.OpeningRom := False;
  FView.FormActivate(FView);
end;

function TSessionController.CanAcceptRomDrop(const Data: TDragObject): Boolean;
begin
  Result := not (csDestroying in FView.ComponentState) and not FState.Session.OpeningRom and
    not FState.Help.Closing and (FState.Settings.View = nil) and
    (FView.ScreenTabs.ActiveTab <> FView.SettingsScreen) and (Length(Data.Files) = 1);
  if Result then
    // Like the file picker, accept renamed ROMs and validate their contents on load.
    Result := TFile.Exists(Data.Files[0]);
end;

procedure TSessionController.EndCoreLoading;
begin
  FLoadingCore := False;
  FState.Session.OpeningRom := False;
  CloseRetroLoading(FView);
  FView.FinishFileSelection;
end;

procedure TSessionController.CancelCoreLoading;
begin
  if not FLoadingCore then
    Exit;

  Inc(FLoadGeneration);
  EndCoreLoading;
end;

procedure TSessionController.LoadRom(const FileName: string; const DisplayName: string; StartPaused: Boolean; const SnapshotName: string);
begin
  if FLoadingCore then
    Exit;

  var SourceName := FileName;
  if FileName.StartsWith('content://', True) then
    SourceName := FState.Session.Storage.Describe(FileName).Name;
  var Ext := ExtractFileExt(SourceName);
  if not (SameText(Ext, ROM_EXTENSION_CUE) or SameText(Ext, ROM_EXTENSION_ISO) or SameText(Ext, ROM_EXTENSION_CHD)) then
  begin
    InstallCore(FView.NewCore(FileName), FileName, DisplayName, StartPaused);
    if SnapshotName <> '' then
      FView.LoadSnapshot(SnapshotName);
    Exit;
  end;

  // Capture only immutable arguments and storage for the worker. All form/core
  // replacement and lifetime checks run on the main thread.
  var Storage := FState.Session.Storage;
  var IsAlive := FState.Session.CallbackAlive;
  var Path := FileName;
  var Title := DisplayName;
  var Snapshot := SnapshotName;
  var Paused := StartPaused;
  Inc(FLoadGeneration);
  var Generation := FLoadGeneration;
  FLoadingCore := True;
  FState.Session.OpeningRom := True;
  FView.FormDeactivate(FView);
  ShowRetroLoading(FView, SourceName,
    procedure
    begin
      CancelCoreLoading;
    end);
  FView.SyncActivity;
  try
    TThread.CreateAnonymousThread(
      procedure
      var
        Core: IEmulationCore;
        ErrorText: string;
      begin
        try
          var Stream := Storage.OpenRead(Path);
          try
            Core := CreateEmulationCore(Stream, Storage, Path);
          finally
            Stream.Free;
          end;
        except
          on E: Exception do
            ErrorText := E.Message;
        end;
        TThread.ForceQueue(nil,
          procedure
          begin
            if not IsAlive() then
              Exit;

            if Generation <> FLoadGeneration then
              Exit;

            try
              if ErrorText <> '' then
                ShowRetroMessage(FView, Translate('Unable to open game: ') + ErrorText)
              else
              try
                InstallCore(Core, Path, Title, Paused);
                if Snapshot <> '' then
                  FView.LoadSnapshot(Snapshot);
              except
                on E: Exception do
                  ShowRetroMessage(FView, Translate('Unable to open game: ') + E.Message);
              end;
            finally
              EndCoreLoading;
            end;
          end);
      end).Start;
  except
    EndCoreLoading;
    raise;
  end;
end;

procedure TSessionController.InstallCore(const NewEmulation: IEmulationCore; const FileName, DisplayName: string; StartPaused: Boolean);
begin
  FView.ImageLogo.Visible := False;
  // Construct first: an invalid ROM leaves the current worker running.
  if FState.Session.Emulation <> nil then
  begin
    FView.AutosaveOnExit;
    FState.Session.Emulation.Stop;
  end;

  if FState.Input.Gamepad <> nil then
    FState.Input.Gamepad.ReleaseAll;
  if FState.Input.SuborKeyboard <> nil then
    FState.Input.SuborKeyboard.ReleaseAll;
  if FState.Input.SGKeyboard <> nil then FState.Input.SGKeyboard.ReleaseAll;
  if FState.Input.FamicomKeyboard <> nil then
    FState.Input.FamicomKeyboard.ReleaseAll;
  if FState.Input.MiraclePiano <> nil then
    FState.Input.MiraclePiano.ReleaseAll;
  if FState.Input.PowerPad <> nil then
    FState.Input.PowerPad.ReleaseAll;
  FView.TimerUpdate.Enabled := False;
  if FState.Input.Rumble <> nil then
    FState.Input.Rumble.Reset;
  FState.Session.Emulation := nil; // Join before replacing the session.
  FView.SyncMotionSensor;
  FState.Session.Emulation := NewEmulation;

  var InputSystem := ROM_SYSTEM_NES;
  if FState.Session.Emulation.Config is TSGConfig then
    InputSystem := TSGConfig(FState.Session.Emulation.Config).SystemId
  else if FState.Session.Emulation.Config is TMDConfig then
    InputSystem := ROM_SYSTEM_MD
  else if FState.Session.Emulation.Config is TNeoGeoConfig then
    InputSystem := ROM_SYSTEM_NEOGEO
  else if FState.Session.Emulation.Config is TN64Config then
    InputSystem := ROM_SYSTEM_N64
  else if FState.Session.Emulation.Config is TSnesConfig then
    InputSystem := ROM_SYSTEM_SNES
  else if FState.Session.Emulation.Config is TGBAConfig then
    InputSystem := ROM_SYSTEM_GBA
  else if FState.Session.Emulation.Config is TGBCEmulatorConfig then
    InputSystem := ROM_SYSTEM_GBC
  else if FState.Session.Emulation.Config is TGBEmulatorConfig then
    InputSystem := ROM_SYSTEM_GB;
  FView.LoadHostInput(InputSystem);
  if FState.Session.Emulation.Config is TMDConfig then
    FState.Input.Gamepad.Layout := TScreenGamepadLayout.Sega
  else if FState.Session.Emulation.Config is TNeoGeoConfig then
    FState.Input.Gamepad.Layout := TScreenGamepadLayout.NeoGeo
  else if FState.Session.Emulation.Config is TN64Config then
    FState.Input.Gamepad.Layout := TScreenGamepadLayout.Nintendo64
  else if FState.Session.Emulation.Config is TSnesConfig then
    FState.Input.Gamepad.Layout := TScreenGamepadLayout.Snes
  else if FState.Session.Emulation.Config is TGBAConfig then
    FState.Input.Gamepad.Layout := TScreenGamepadLayout.GameBoyAdvance
  else if FState.Session.Emulation.Config is TGBCEmulatorConfig then
    FState.Input.Gamepad.Layout := TScreenGamepadLayout.GameBoyColor
  else if FState.Session.Emulation.Config is TGBEmulatorConfig then
    FState.Input.Gamepad.Layout := TScreenGamepadLayout.GameBoy
  else if FState.Input.Ports.Devices[0] = 'paddendy' then
    FState.Input.Gamepad.Layout := TScreenGamepadLayout.Dendy
  else
    FState.Input.Gamepad.Layout := TScreenGamepadLayout.Nes;
  FState.Input.Gamepad.ButtonMask := CoreButtons(InputSystem, FState.Input.Ports.Devices[0]);

  FView.ImageCanvas.HitTest := False;
  FView.ImageCanvas.CanFocus := False;
  FView.ImageCanvas.DisableFocusEffect := True;

  var Peripheral: INesPeripheralCore;
  if Supports(FState.Session.Emulation, INesPeripheralCore, Peripheral) then
  begin
    FView.ImageCanvas.HitTest := True;
    FView.ImageCanvas.CanFocus := True;
    FView.ImageCanvas.OnKeyDown := FView.FormKeyDown;
    FView.ImageCanvas.OnKeyUp := FView.FormKeyUp;
    FView.ImageCanvas.DisableFocusEffect := False;
    FView.ImageCanvas.CanParentFocus := True;
    Peripheral.Zapper.OnReadLight :=
      function(const Mask: TNesZapperMask): Boolean
      begin
        Result := TZapper.ReadMask(Mask, FState.Input.ZapperPixel.X, FState.Input.ZapperPixel.Y);
      end;
  end;

  FState.Session.UserPaused := StartPaused;
  FState.Session.AutoPaused := False;

  FView.ImageCanvas.DisableInterpolation := SameText(FState.Session.Emulation.Config.Filter, 'nearest');
  FillChar(FState.Input.KeysDown, SizeOf(FState.Input.KeysDown), 0);
  FState.Session.RomDisplayName := DisplayName;
  if FState.Session.RomDisplayName = '' then
    FState.Session.RomDisplayName := ExtractFileName(FileName);
  FState.Session.SoundErrorShown := False;
  try
    FView.ImageCanvas.Bitmap.Clear(TAlphaColors.Black);
    FState.Session.EmulationFaulted := False;
    if FState.Session.UserPaused then
      FState.Session.Emulation.Pause;
    {$IF Defined(ANDROID) or Defined(IOS)}
    if FState.Mobile.ActivityPaused then
      FState.Session.Emulation.Pause;
    {$ENDIF}
    FState.Session.Emulation.Start;
    FState.Autosave.LastTick := FView.CurrentTick;
    if FState.Browser.View <> nil then
    begin
      var Info: IEmulationSnapshotLocation;
      var Directory := '';
      if Supports(FState.Session.Emulation, IEmulationSnapshotLocation, Info) then
        Directory := Info.GetSnapshotDirectory;
      FState.Browser.View.RecordSession(FileName, Directory);
      FState.Browser.View.Visible := False;
      FView.ScreenTabs.ActiveTab := FView.GameScreen;
      FView.LayoutClient.Visible := True;
      FState.Browser.ViewingLibrary := False;
      FView.LayoutClient.SetFocus;
      if FState.Preferences.StartFullscreen and not FView.FullScreen then
        FView.SwitchFullScreen;
    end;
    FView.SyncActivity;
    FView.SetStatus(FState.Session.Emulation.Name + ' - ' + FState.Session.RomDisplayName);
  except
    FView.StopOnError;
    raise;
  end;

  {$IF Defined(ANDROID) or Defined(IOS)}
  if not FView.FullScreen then
    FView.SwitchFullScreen;
  {$ENDIF}
end;

procedure TSessionController.ButtonCloseRomClick(Sender: TObject);
begin
  FView.Stop;
  FView.SwitchFullScreen;
end;

procedure TSessionController.Stop;
begin
  CancelCoreLoading;

  {$IF Defined(ANDROID) or Defined(IOS)}
  if FView.FullScreen then
    FView.SwitchFullScreen;
  {$ENDIF}

  FView.FormDeactivate(FView);
  if FState.Session.Emulation <> nil then
  begin
    FView.AutosaveOnExit;
    FView.TimerUpdate.Enabled := False;
    FState.Session.Emulation.Stop;
    FView.ImageCanvas.Bitmap := nil;
    FView.ImageLogo.Visible := True;
    FState.Session.Emulation := nil;
  end;
  if FState.Browser.View <> nil then
    FView.LibraryBack(FView);
  FView.SyncActivity;
end;

procedure TSessionController.StopOnError;
begin
  FState.Session.EmulationFaulted := True;
  FView.TimerUpdate.Enabled := False;
  if FState.Session.Emulation <> nil then
    FState.Session.Emulation.Pause;
  FView.FormDeactivate(FView);
  FView.SetStatus(Translate('Stopped after error - ') + FState.Session.RomDisplayName);
  FView.SyncActivity;
end;

procedure TSessionController.TimerUpdateTimer(Sender: TObject);
begin
  if FState.Input.Manager <> nil then
  try
    FView.PollHostInput;
  except
    on E: Exception do
    begin
      FState.Input.Manager.Enabled := False;
      FView.TimerUpdate.Enabled := False;
      if FState.Input.Rumble <> nil then
        FState.Input.Rumble.Stop;
      if FState.Session.Emulation <> nil then
        FState.Session.Emulation.ClearInput;
      FView.SetStatus(Translate('Input error: ') + E.Message);
      ShowRetroMessage(FView, Translate('Input error: ') + E.Message);
      Exit;
    end;
  end;

  FView.PollRumble;
  if FState.Settings.View <> nil then
    Exit;

  {$IFDEF ANDROID}
  FView.PollDocumentTransfer;
  {$ENDIF}

  {$IF Defined(ANDROID) or Defined(IOS)}
  if FState.Session.OpeningRom then
    Exit;
  {$ENDIF}

  if FState.Session.EmulationFaulted or not FView.TimerUpdate.Enabled or (FState.Session.Emulation = nil) then
    Exit;

  FView.UpdatePauseOverlay;
  try
    FView.PollMotionSensor;
    FView.UpdatePeripheralFeedback;
    FView.UpdateFrame;
    FView.PollAutosave;
  except
    FView.StopOnError;
    raise;
  end;
end;

function TSessionController.UpdateFrame: Boolean;
begin
  Result := False;
  if FState.Session.Emulation = nil then
    Exit;

  var Frame: TEmulatorFrame;
  var NewFrame := FState.Session.Emulation.TryGetFrame(Frame);
  var AudioDiagnostics: IEmulationAudioDiagnostics;
  if Supports(FState.Session.Emulation, IEmulationAudioDiagnostics, AudioDiagnostics) then
  begin
    var AudioError := AudioDiagnostics.TakeAudioError;
    if (AudioError <> '') and not FState.Session.SoundErrorShown then
    begin
      FState.Session.SoundErrorShown := True;
      FView.ShowAudioError(AudioError);
    end;
  end;

  var ErrorText := FState.Session.Emulation.TakeError;
  if (ErrorText <> '') and not FState.Session.EmulationFaulted then
  begin
    FView.StopOnError;
    raise Exception.Create(ErrorText);
  end;

  if not FState.Session.EmulationFaulted and NewFrame then
  begin
    if FState.Browser.GameFPS <> nil then
      FState.Browser.GameFPS.Text := Format('%.1f FPS   ·   %s   ·   %d × %d',
        [Frame.FramesPerSecond, UpperCase(FState.Input.SystemId), Frame.Width, Frame.Height]);
    var NewCaption := Format('%s - %.1f FPS', [FState.Session.Emulation.Name, Frame.FramesPerSecond]);
    if FView.Caption <> NewCaption then
      FView.SetStatus(NewCaption);
  end;
  if not NewFrame then
    Exit;

  if (FView.ImageCanvas.Bitmap.Width <> Frame.Width) or (FView.ImageCanvas.Bitmap.Height <> Frame.Height) then
  begin
    FView.ImageCanvas.Bitmap.SetSize(Frame.Width, Frame.Height);
  end;
  var Data: TBitmapData;
  if FView.ImageCanvas.Bitmap.Map(TMapAccess.Write, Data) then
  try
    UploadFramePixels(Frame.Pixels, Frame.Width, Frame.Height, Data);
    Result := True;
  finally
    FView.ImageCanvas.Bitmap.Unmap(Data);
  end;
  FView.ImageCanvas.Repaint;
end;

procedure TSessionController.PauseClick(Sender: TObject);
begin
  FView.SwitchPause;
end;

procedure TSessionController.SwitchPause;
begin
  if (FState.Session.Emulation = nil) or FState.Session.EmulationFaulted then
    Exit;

  FState.Session.AutoPaused := False;
  FState.Session.UserPaused := not FState.Session.UserPaused;
  if FState.Session.UserPaused then
  begin
    FView.FormDeactivate(FView);
    FState.Session.Emulation.Pause;
  end
  else
  begin
    {$IF not Defined(ANDROID) and not Defined(IOS)}
    FState.Session.Emulation.Resume;
    {$ENDIF}
  end;
  FView.SyncActivity;
  // SyncActivity can release input again when the mobile pause state changes.
  FState.Input.KeysDown[vkP] := True;
end;

procedure TSessionController.UpdatePauseOverlay;
begin
  var Paused := (FState.Session.Emulation <> nil) and (FState.Session.UserPaused or FState.Session.AutoPaused or FState.Session.Emulation.IsPaused);
  FView.ImageCanvas.Opacity := IfThen(Paused, 0.5, 1);
  FView.LabelPaused.Visible := Paused and not FState.Browser.ViewingLibrary and (FState.Help.View = nil) and (FState.Settings.View = nil);
  if FView.LabelPaused.Visible then
    FView.LabelPaused.BringToFront;
end;

procedure TSessionController.InsertCoinClick(Sender: TObject);
begin
  if (FState.Session.Emulation = nil) or FState.Session.EmulationFaulted or FState.Session.OpeningRom or FState.Browser.ViewingLibrary or
    (FState.Settings.View <> nil) or (FState.Help.View <> nil) or not FState.Session.Emulation.HasCoinAcceptor then
    Exit;

  FState.Session.Emulation.InsertCoin1;
end;

end.

