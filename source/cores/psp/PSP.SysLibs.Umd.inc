{ PSP.SysLibs: sceUmdUser. A disc is always present and initialised; it is
  readable (READY) once activated. Waits are on the drive state, like waits on
  the firmware's event flag; callbacks hear every activate and deactivate. }

const
  UMD_NOT_PRESENT = $01;
  UMD_PRESENT = $02;
  UMD_INITED = $10;
  UMD_READY = $20;
  UMD_WAITABLE = $3B;
  UMD_MIN_TIMEOUT = 200;
  UMD_ERROR_INVALID = SCE_ERROR_ERRNO_EINVAL;

function TPSPSysLibs.UmdStat: Cardinal;
begin
  Result := UMD_PRESENT or UMD_INITED;
  if FUmdActivated then
    Result := Result or UMD_READY;
end;

procedure TPSPSysLibs.UmdChanged(Arg: Cardinal);
begin
  if FUmdCallback <> 0 then
  begin
    var CB := TPSPCallback(FKernel.GetObject(FUmdCallback, TPSPCallback));
    if CB <> nil then
      FKernel.NotifyCallback(CB, Arg);
  end;
  var Stat := UmdStat;
  for var T in FUmd.Waiters.ToArray do
    if (T.Wait.Data[0] and Stat) <> 0 then
      FKernel.EndWait(T, 0);
end;

function TPSPSysLibs.UmdRetry(T: TPSPThread): Boolean;
begin
  Result := (T.Wait.Data[0] and UmdStat) <> 0;
  if Result then
    T.SetResult(0);
end;

function TPSPSysLibs.UmdSatisfiedRetry(T: TPSPThread): Boolean;
begin
  T.SetResult(0);
  Result := True;
end;

function TPSPSysLibs.UmdDriveArgs(Mode, Drive: Cardinal): Boolean;
begin
  Result := ((Mode = 1) or (Mode = 2)) and (Drive <> 0) and (Drive < $80000000) and
    (FMemory.ReadString(Drive, 16) = 'disc0:');
end;

procedure TPSPSysLibs.hUmdActivate;
begin
  if not UmdDriveArgs(FHLE.Arg(0), FHLE.Arg(1)) then
    begin FHLE.Result(UMD_ERROR_INVALID); Exit; end;
  FUmdActivated := True;
  FHLE.Result(0);
  // Programs built for newer firmware hear the full state.
  if FKernel.CompiledSdkVersion = 0 then
    UmdChanged(UMD_PRESENT or UMD_READY)
  else
    UmdChanged(UmdStat);
end;

procedure TPSPSysLibs.hUmdDeactivate;
begin
  if not UmdDriveArgs(FHLE.Arg(0), FHLE.Arg(1)) then
    begin FHLE.Result(UMD_ERROR_INVALID); Exit; end;
  FUmdActivated := False;
  FHLE.Result(0);
  UmdChanged(UmdStat);
end;

procedure TPSPSysLibs.hUmdGetDriveStat;
begin
  FHLE.Result(UmdStat);
end;

procedure TPSPSysLibs.hUmdCheckMedium;
begin
  FHLE.Result(1);
end;

procedure TPSPSysLibs.UmdWait(AllowCB, HasTimer: Boolean);
begin
  var Want := FHLE.Arg(0);
  if (Want and UMD_WAITABLE) = 0 then
    begin FHLE.Result(UMD_ERROR_INVALID); Exit; end;
  if FKernel.InInterrupt then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT); Exit; end;
  if not FKernel.CanWait then
    begin FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT); Exit; end;
  var T := FKernel.Current;
  FHLE.Result(0);
  if (Want and UmdStat) <> 0 then
  begin
    // Already satisfied; the CB variant still runs pending callbacks.
    if AllowCB and T.HasPendingCallbacks then
      FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, True, UmdSatisfiedRetry, nil, 'umd');
    Exit;
  end;
  var TimeoutPtr: Cardinal := 0;
  if HasTimer and (FHLE.Arg(1) <> 0) then
  begin
    FMemory.Write32(FUmdTimeout, Max(FHLE.Arg(1), UMD_MIN_TIMEOUT));
    TimeoutPtr := FUmdTimeout;
  end;
  FUmd.AddWaiter(T);
  FKernel.BeginWait(PSPWaitEventFlag, FUmd, 0, TimeoutPtr, AllowCB, UmdRetry, nil, 'umd');
  T.Wait.Data[0] := Want;
  if (T.Frames.Count > 0) and (T.Wait.Kind = PSPWaitNone) then
  begin
    // Callbacks started first: the wait sits in their frame.
    var F := T.Frames.Last;
    F.SavedWait.Data[0] := Want;
    T.Frames[T.Frames.Count - 1] := F;
  end;
end;

procedure TPSPSysLibs.hUmdWaitDriveStat;
begin
  UmdWait(False, False);
end;

procedure TPSPSysLibs.hUmdWaitDriveStatWithTimer;
begin
  UmdWait(False, True);
end;

procedure TPSPSysLibs.hUmdWaitDriveStatCB;
begin
  UmdWait(True, True);
end;

procedure TPSPSysLibs.hUmdCancelWaitDriveStat;
begin
  FHLE.Result(0);
  for var T in FUmd.Waiters.ToArray do
    FKernel.EndWait(T, SCE_KERNEL_ERROR_WAIT_CANCEL);
end;

procedure TPSPSysLibs.hUmdRegisterCallback;
begin
  var CB := TPSPCallback(FKernel.GetObject(FHLE.Arg(0), TPSPCallback));
  if CB = nil then
    begin FHLE.Result(UMD_ERROR_INVALID); Exit; end;
  FUmdCallback := FHLE.Arg(0);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hUmdUnregisterCallback;
begin
  var Id := FHLE.Arg(0);
  if Id <> FUmdCallback then
    begin FHLE.Result(UMD_ERROR_INVALID); Exit; end;
  FUmdCallback := 0;
  // Before 3.00 the id comes back.
  if FKernel.CompiledSdkVersion > $3000000 then
    FHLE.Result(0)
  else
    FHLE.Result(Id);
end;

procedure TPSPSysLibs.hUmdGetDiscInfo;
begin
  var P := FHLE.Arg(0);
  if (P = 0) or (P >= $80000000) or (FMemory.Read32(P) <> 8) then
    begin FHLE.Result(UMD_ERROR_INVALID); Exit; end;
  FMemory.Write32(P + 4, $10);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hUmdZero;
begin
  FHLE.Result(0);
end;
