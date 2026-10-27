{ PSP.Utility: message dialog, OSK, the dialogs that only fail offline, the
  HTML viewer, system parameters and utility modules. }

const
  MsgResult = $30;
  MsgMode = $34;
  MsgErrorNum = $38;
  MsgOptions = $23C;
  MsgButton = $240;
  MSG_ERROR_BAD_OPTION = Cardinal($80110501);
  MSG_ERROR_BAD_ERRORCODE = Cardinal($80110502);
  MSG_OPTION_DEFAULT_NO = $100;
  MSG_BUTTON_YES = 1;
  MSG_BUTTON_NO = 2;
  MSG_BUTTON_BACK = 3;
  DialogResult = $1C;
  OSK_RESULT_CHANGED = 2;
  SYSTEMPARAM_FAIL = Cardinal($80110103);
  SYSTEMPARAM_TOO_SHORT = Cardinal($80110102);
  NETPARAM_BAD_NETCONF = Cardinal($80110601);
  HtmlMemorySize = $380000;
  ModuleLoadUs = 1000;

procedure TPSPUtility.CheckMsgParams(D: TPSPDialog);
begin
  var P := D.Params;
  var BadOptions := (D.Size > MsgOptions) and ((FMemory.Read32(P + MsgOptions) and not $1FF) <> 0);
  if FMemory.Read32(P + MsgMode) = 0 then
  begin
    // Error dialogs only look at the options from the third version on.
    if FMemory.Read32(P + MsgErrorNum) = 0 then
      D.Error := MSG_ERROR_BAD_ERRORCODE
    else if BadOptions and (D.Size >= $2C4) then
      D.Error := MSG_ERROR_BAD_OPTION;
  end
  else if BadOptions then
    D.Error := MSG_ERROR_BAD_OPTION;
end;

procedure TPSPUtility.StepMsg(D: TPSPDialog);
begin
  var P := D.Params;
  // A failing dialog shows for its fade-in, then quits with the error.
  if D.Error <> 0 then
  begin
    if D.Updates > MsgFadeUpdates then
    begin
      FMemory.Write32(P + MsgResult, D.Error);
      Finish(D);
    end;
    Exit;
  end;
  // The first frame drawn clears the result.
  if D.Updates = 1 then
    FMemory.Write32(P + MsgResult, 0);
  if D.Aborted then
  begin
    if D.Updates >= MsgFadeUpdates then
      Finish(D);
    Exit;
  end;
  var B := Pressed(D);
  var Confirm: Cardinal := PSP_CTRL_CROSS;
  var Cancel: Cardinal := PSP_CTRL_CIRCLE;
  if PSPSettings.ButtonSwap = 0 then
  begin
    Confirm := PSP_CTRL_CIRCLE;
    Cancel := PSP_CTRL_CROSS;
  end;
  var Answer := 0;
  var DefaultAnswer := MSG_BUTTON_YES;
  if (D.Size > MsgOptions) and ((FMemory.Read32(P + MsgOptions) and MSG_OPTION_DEFAULT_NO) <> 0) then
    DefaultAnswer := MSG_BUTTON_NO;
  if (B and Confirm) <> 0 then
    Answer := DefaultAnswer
  else if (B and Cancel) <> 0 then
    Answer := MSG_BUTTON_BACK
  else if (FView = nil) and (FKernel.Scheduler.Now - D.RunningAt >= HeadlessAnswerNs) then
    Answer := DefaultAnswer;
  if (Answer <> 0) and (D.Updates >= MsgFadeUpdates) then
  begin
    if D.Size > MsgButton then
      FMemory.Write32(P + MsgButton, Cardinal(Answer));
    Finish(D);
  end;
end;

procedure TPSPUtility.StepOsk(D: TPSPDialog);
begin
  var P := D.Params;
  var Count := Integer(FMemory.Read32(P + $30));
  var Data := FMemory.Read32(P + $34);
  // Without a keyboard on screen every field is confirmed with its initial text.
  for var I := 0 to Count - 1 do
  begin
    var F := Data + Cardinal(I) * 52;
    var InText := FMemory.Read32(F + 32);
    var OutLength := Integer(FMemory.Read32(F + 36));
    var OutText := FMemory.Read32(F + 40);
    if OutText <> 0 then
    begin
      var N := 0;
      if InText <> 0 then
        while (N < OutLength - 1) and (FMemory.Read16(InText + Cardinal(N) * 2) <> 0) do
        begin
          FMemory.Write16(OutText + Cardinal(N) * 2, FMemory.Read16(InText + Cardinal(N) * 2));
          Inc(N);
        end;
      if OutLength > 0 then
        FMemory.Write16(OutText + Cardinal(N) * 2, 0);
    end;
    FMemory.Write32(F + 44, OSK_RESULT_CHANGED);
  end;
  FMemory.Write32(P + DialogResult, 0);
  Finish(D);
end;

procedure TPSPUtility.StepOther(D: TPSPDialog);
begin
  // Network dialogs find no access point; the others have nothing to show.
  // Each closes as if the player backed out.
  FMemory.Write32(D.Params + DialogResult, 1);
  Finish(D);
end;

{ Message dialog }

procedure TPSPUtility.hMsgInitStart;
begin
  InitStart(dtMsg, [$23C, $244, $2C4]);
end;

procedure TPSPUtility.hMsgGetStatus;
begin
  GetStatus(dtMsg);
end;

procedure TPSPUtility.hMsgUpdate;
begin
  Update(dtMsg);
end;

procedure TPSPUtility.hMsgShutdownStart;
begin
  ShutdownStart(dtMsg);
end;

procedure TPSPUtility.hMsgAbort;
begin
  if FCurrent <> dtMsg then
    begin FHLE.Result(SCE_UTILITY_ERROR_WRONG_TYPE); Exit; end;
  var D := FDialogs[dtMsg];
  if D.Status <> PSPDialogRunning then
    begin FHLE.Result(SCE_UTILITY_ERROR_INVALID_STATUS); Exit; end;
  D.Aborted := True;
  FHLE.Result(0);
end;

{ Savedata }

procedure TPSPUtility.hSavedataInitStart;
begin
  InitStart(dtSavedata, [$5C8, $5DC, $600]);
end;

procedure TPSPUtility.hSavedataGetStatus;
begin
  GetStatus(dtSavedata);
end;

procedure TPSPUtility.hSavedataUpdate;
begin
  Update(dtSavedata);
end;

procedure TPSPUtility.hSavedataShutdownStart;
begin
  ShutdownStart(dtSavedata);
end;

{ OSK }

procedure TPSPUtility.hOskInitStart;
begin
  InitStart(dtOsk, [$40, $44]);
end;

procedure TPSPUtility.hOskGetStatus;
begin
  GetStatus(dtOsk);
end;

procedure TPSPUtility.hOskUpdate;
begin
  Update(dtOsk);
end;

procedure TPSPUtility.hOskShutdownStart;
begin
  ShutdownStart(dtOsk);
end;

{ Netconf }

procedure TPSPUtility.hNetconfInitStart;
begin
  InitStart(dtNetconf, [$38, $40, $44]);
end;

procedure TPSPUtility.hNetconfGetStatus;
begin
  GetStatus(dtNetconf);
end;

procedure TPSPUtility.hNetconfUpdate;
begin
  Update(dtNetconf);
end;

procedure TPSPUtility.hNetconfShutdownStart;
begin
  ShutdownStart(dtNetconf);
end;

{ Game sharing }

procedure TPSPUtility.hSharingInitStart;
begin
  InitStart(dtGameSharing, [$50, $54, $64]);
end;

procedure TPSPUtility.hSharingGetStatus;
begin
  GetStatus(dtGameSharing);
end;

procedure TPSPUtility.hSharingUpdate;
begin
  Update(dtGameSharing);
end;

procedure TPSPUtility.hSharingShutdownStart;
begin
  ShutdownStart(dtGameSharing);
end;

{ Screenshot }

procedure TPSPUtility.hScreenshotInitStart;
begin
  InitStart(dtScreenshot, [$1B4, $3A0, $3A4]);
end;

procedure TPSPUtility.hScreenshotGetStatus;
begin
  GetStatus(dtScreenshot);
end;

procedure TPSPUtility.hScreenshotUpdate;
begin
  Update(dtScreenshot);
end;

procedure TPSPUtility.hScreenshotShutdownStart;
begin
  ShutdownStart(dtScreenshot);
end;

procedure TPSPUtility.hScreenshotContStart;
begin
  if FCurrent <> dtScreenshot then
    begin FHLE.Result(SCE_UTILITY_ERROR_WRONG_TYPE); Exit; end;
  FHLE.Result(SCE_UTILITY_ERROR_INVALID_STATUS);
end;

{ Gamedata install }

procedure TPSPUtility.hInstallInitStart;
begin
  InitStart(dtInstall, [$590, $598]);
end;

procedure TPSPUtility.hInstallGetStatus;
begin
  GetStatus(dtInstall);
end;

{ NP sign-in }

procedure TPSPUtility.hNpSigninInitStart;
begin
  InitStart(dtNpSignin, [$40]);
end;

procedure TPSPUtility.hNpSigninGetStatus;
begin
  GetStatus(dtNpSignin);
end;

procedure TPSPUtility.hNpSigninUpdate;
begin
  Update(dtNpSignin);
end;

procedure TPSPUtility.hNpSigninShutdownStart;
begin
  ShutdownStart(dtNpSignin);
end;

{ HTML viewer: its own state, not blocked by the other dialogs. It needs a
  3.5 MB block of user memory for the browser. }

procedure TPSPUtility.hHtmlInitStart;
begin
  var D := FDialogs[dtHtml];
  var P := FHLE.Arg(0);
  if FHtmlStarted and (D.Status <> PSPDialogNone) then
    begin FHLE.Result(SCE_UTILITY_ERROR_INVALID_STATUS); Exit; end;
  var Size: Cardinal := 0;
  if P <> 0 then
    Size := FMemory.Read32(P);
  if not ((Size = $70) or (Size = $78) or (Size = $80) or (Size = $98) or (Size = $A4) or (Size = $A8)) then
    begin FHLE.Result(SCE_UTILITY_ERROR_INVALID_PARAM_SIZE); Exit; end;
  var Block := FKernel.UserPartition.Alloc(HtmlMemorySize, akHigh, 0, 256, 'htmlviewer');
  if Block = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_MEMBLOCK_ALLOC_FAILED); Exit; end;
  FHtmlMemory := Block;
  FHtmlStarted := True;
  FKernel.CancelTimersOf(D);
  D.Status := PSPDialogInit;
  D.Params := P;
  D.Size := Size;
  D.Updates := 0;
  FHLE.Result(0);
  At(SavedataInitNs, D,
    procedure
    begin
      if D.Status = PSPDialogInit then
        D.Status := PSPDialogRunning;
    end);
end;

procedure TPSPUtility.hHtmlGetStatus;
begin
  if not FHtmlStarted then
    FHLE.Result(SCE_UTILITY_ERROR_WRONG_TYPE)
  else
    FHLE.Result(FDialogs[dtHtml].Status);
end;

procedure TPSPUtility.hHtmlUpdate;
begin
  var D := FDialogs[dtHtml];
  if not FHtmlStarted then
    begin FHLE.Result(SCE_UTILITY_ERROR_WRONG_TYPE); Exit; end;
  if D.Status <> PSPDialogRunning then
    begin FHLE.Result(SCE_UTILITY_ERROR_INVALID_STATUS); Exit; end;
  FHLE.Result(0);
  // No network: the browser can only be closed.
  FMemory.Write32(D.Params + DialogResult, 0);
  Finish(D);
  Yield(UpdateYieldUs);
end;

procedure TPSPUtility.hHtmlShutdownStart;
begin
  var D := FDialogs[dtHtml];
  if not FHtmlStarted then
    begin FHLE.Result(SCE_UTILITY_ERROR_WRONG_TYPE); Exit; end;
  if D.Status <> PSPDialogFinished then
    begin FHLE.Result(SCE_UTILITY_ERROR_INVALID_STATUS); Exit; end;
  FHLE.Result(0);
  D.Status := PSPDialogShutdown;
  At(DialogShutdownNs, D,
    procedure
    begin
      if D.Status = PSPDialogShutdown then
      begin
        D.Status := PSPDialogNone;
        if FHtmlMemory <> 0 then
          FKernel.UserPartition.FreeBlock(FHtmlMemory);
        FHtmlMemory := 0;
      end;
    end);
end;

{ System parameters }

procedure TPSPUtility.hGetSystemParamInt;
begin
  var V: Integer;
  case FHLE.ArgInt(0) of
    2: V := PSPSettings.AdhocChannel;
    3: V := PSPSettings.WlanPowerSave;
    4: V := PSPSettings.DateFormat;
    5: V := PSPSettings.TimeFormat;
    6: V := PSPSettings.Timezone;
    7: V := PSPSettings.DaylightSaving;
    8: V := PSPSettings.Language;
    9: V := PSPSettings.ButtonSwap;
    10: V := PSPSettings.ParentalLevel;
  else
    begin FHLE.Result(SYSTEMPARAM_FAIL); Exit; end;
  end;
  FMemory.Write32(FHLE.Arg(1), Cardinal(V));
  FHLE.Result(0);
end;

procedure TPSPUtility.hGetSystemParamString;
begin
  if FHLE.ArgInt(0) <> 1 then
    begin FHLE.Result(SYSTEMPARAM_FAIL); Exit; end;
  var S := UTF8Encode(PSPSettings.Nickname);
  var Len := FHLE.ArgInt(2);
  if Len <= Length(S) then
    begin FHLE.Result(SYSTEMPARAM_TOO_SHORT); Exit; end;
  FMemory.WriteString(FHLE.Arg(1), S, Len);
  FHLE.Result(0);
end;

procedure TPSPUtility.hSetSystemParamInt;
begin
  var V := FHLE.ArgInt(1);
  case FHLE.ArgInt(0) of
    2: PSPSettings.AdhocChannel := V;
    3: PSPSettings.WlanPowerSave := V;
    4: PSPSettings.DateFormat := V;
    5: PSPSettings.TimeFormat := V;
    6: PSPSettings.Timezone := V;
    7: PSPSettings.DaylightSaving := V;
    8: PSPSettings.Language := V;
    9: PSPSettings.ButtonSwap := V;
    10: PSPSettings.ParentalLevel := V;
  else
    begin FHLE.Result(SYSTEMPARAM_FAIL); Exit; end;
  end;
  FHLE.Result(0);
end;

procedure TPSPUtility.hSetSystemParamString;
begin
  if FHLE.ArgInt(0) <> 1 then
    begin FHLE.Result(SYSTEMPARAM_FAIL); Exit; end;
  PSPSettings.Nickname := UTF8ToString(FMemory.ReadAnsi(FHLE.Arg(1), 128));
  FHLE.Result(0);
end;

procedure TPSPUtility.hCheckNetParam;
begin
  // No network configurations are stored.
  FHLE.Result(NETPARAM_BAD_NETCONF);
end;

procedure TPSPUtility.hGetNetParam;
begin
  FHLE.Result(NETPARAM_BAD_NETCONF);
end;

{ Modules: the libraries are always present; loading only tracks the state
  and takes the time a load from flash takes. }

procedure TPSPUtility.ModuleLoad(Id: Cardinal; Valid: Boolean; ErrBase: Cardinal);
begin
  if not Valid then
    begin FHLE.Result(ErrBase + 1); Exit; end;
  if FModules.Contains(Id) then
    begin FHLE.Result(ErrBase + 2); Exit; end;
  FModules.Add(Id);
  FHLE.Result(0);
  Yield(ModuleLoadUs);
end;

procedure TPSPUtility.ModuleUnload(Id: Cardinal; Valid: Boolean; ErrBase: Cardinal);
begin
  if not Valid then
    begin FHLE.Result(ErrBase + 1); Exit; end;
  if not FModules.Contains(Id) then
    begin FHLE.Result(ErrBase + 3); Exit; end;
  FModules.Remove(Id);
  FHLE.Result(0);
  Yield(ModuleLoadUs);
end;

function ValidUtilityModule(Id: Cardinal): Boolean;
begin
  case Id shr 8 of
    1: Result := (Id and $FF) <= 6;
    2: Result := (Id and $FF) <= 3;
    3: Result := (Id and $FF) <= 7;
    4: Result := (Id and $FF) <= 2;
    5: Result := (Id and $FF) <= 1;
    6: Result := (Id and $FF) = 0;
  else
    Result := False;
  end;
end;

procedure TPSPUtility.hLoadModule;
begin
  ModuleLoad(FHLE.Arg(0), ValidUtilityModule(FHLE.Arg(0)), $80111100);
end;

procedure TPSPUtility.hUnloadModule;
begin
  ModuleUnload(FHLE.Arg(0), ValidUtilityModule(FHLE.Arg(0)), $80111100);
end;

procedure TPSPUtility.hLoadNetModule;
begin
  var N := FHLE.Arg(0);
  ModuleLoad($100 + N - 1, (N >= 1) and (N <= 7), $80110800);
end;

procedure TPSPUtility.hUnloadNetModule;
begin
  var N := FHLE.Arg(0);
  ModuleUnload($100 + N - 1, (N >= 1) and (N <= 7), $80110800);
end;

procedure TPSPUtility.hLoadAvModule;
begin
  var N := FHLE.Arg(0);
  ModuleLoad($300 + N, N <= 7, $80110F00);
end;

procedure TPSPUtility.hUnloadAvModule;
begin
  var N := FHLE.Arg(0);
  ModuleUnload($300 + N, N <= 7, $80110F00);
end;

procedure TPSPUtility.hLoadUsbModule;
begin
  var N := FHLE.Arg(0);
  ModuleLoad($10200 + N, (N >= 1) and (N <= 5), $80110B00);
end;

procedure TPSPUtility.hUnloadUsbModule;
begin
  var N := FHLE.Arg(0);
  ModuleUnload($10200 + N, (N >= 1) and (N <= 5), $80110B00);
end;
