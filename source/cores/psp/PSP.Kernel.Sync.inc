{ PSP.Kernel: semaphores and event flags. }

{ TPSPSema }

class function TPSPSema.IdType: Integer;
begin
  Result := 2;
end;

function TPSPSema.TryTake(T: TPSPThread): Boolean;
begin
  var Need := Integer(T.Wait.Data[0]);
  Result := (Count >= Need) and ((Waiters.Count = 0) or (Waiters.First = T));
  if Result then
  begin
    Dec(Count, Need);
    T.SetResult(0);
  end;
end;

procedure TPSPSema.WaiterGone;
begin
  WakeWaiters;
end;

procedure TPSPSema.WakeWaiters;
begin
  while Waiters.Count > 0 do
  begin
    var T := Waiters.First;
    var Need := Integer(T.Wait.Data[0]);
    if Count < Need then
      Break;
    Dec(Count, Need);
    Kernel.EndWait(T, 0);
  end;
end;

{ TPSPEventFlag }

class function TPSPEventFlag.IdType: Integer;
begin
  Result := 3;
end;

function TPSPEventFlag.Matches(Bits, Mode: Cardinal): Boolean;
begin
  if (Mode and 1) <> 0 then
    Result := (Pattern and Bits) <> 0
  else
    Result := (Pattern and Bits) = Bits;
end;

function TPSPEventFlag.TryTake(T: TPSPThread): Boolean;
begin
  var Bits := T.Wait.Data[0];
  var Mode := T.Wait.Data[1];
  Result := Matches(Bits, Mode);
  if Result then
  begin
    if T.Wait.Data[2] <> 0 then
      Kernel.Memory.Write32(T.Wait.Data[2], Pattern);
    if (Mode and $10) <> 0 then
      Pattern := 0
    else if (Mode and $20) <> 0 then
      Pattern := Pattern and not Bits;
    T.SetResult(0);
  end;
end;

procedure TPSPEventFlag.WakeWaiters;
begin
  var I := 0;
  while I < Waiters.Count do
  begin
    var T := Waiters.Item(I);
    var Bits := T.Wait.Data[0];
    var Mode := T.Wait.Data[1];
    if Matches(Bits, Mode) then
    begin
      if T.Wait.Data[2] <> 0 then
        Kernel.Memory.Write32(T.Wait.Data[2], Pattern);
      if (Mode and $10) <> 0 then
        Pattern := 0
      else if (Mode and $20) <> 0 then
        Pattern := Pattern and not Bits;
      Kernel.EndWait(T, 0);
    end
    else
      Inc(I);
  end;
end;

{ HLE: semaphores }

function TPSPKernel.SemaRetry(T: TPSPThread): Boolean;
begin
  var S := TPSPSema(T.Wait.Obj);
  if (S = nil) or not FObjects.ContainsKey(T.Wait.Id) then
  begin
    T.SetResult(SCE_KERNEL_ERROR_WAIT_DELETE);
    Exit(True);
  end;
  Result := S.TryTake(T);
end;

procedure TPSPKernel.hCreateSema;
begin
  var Name: string;
  if not ReadName(FHLE.Arg(0), Name) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ERROR); Exit; end;
  var Attr := FHLE.Arg(1);
  if Attr >= $200 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR); Exit; end;
  var S := TPSPSema.Create;
  S.Name := Name;
  S.Attr := Attr;
  S.Count := FHLE.ArgInt(2);
  S.InitCount := S.Count;
  S.MaxCount := FHLE.ArgInt(3);
  S.Waiters.ByPriority := (Attr and $100) <> 0;
  Spend(PSPSyncCallNs);
  FHLE.Result(AddObject(S));
end;

procedure TPSPKernel.hDeleteSema;
begin
  var S := TPSPSema(GetObject(FHLE.Arg(0), TPSPSema));
  if S = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_SEMID); Exit; end;
  FHLE.Result(0);
  while S.Waiters.Count > 0 do
    EndWait(S.Waiters.First, SCE_KERNEL_ERROR_WAIT_DELETE);
  DeleteObject(S);
end;

procedure TPSPKernel.hSignalSema;
begin
  var S := TPSPSema(GetObject(FHLE.Arg(0), TPSPSema));
  if S = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_SEMID); Exit; end;
  var N := FHLE.ArgInt(1);
  // What the waiters at the head take does not count against the maximum.
  var Left := Int64(S.Count) + N;
  for var I := 0 to S.Waiters.Count - 1 do
  begin
    var Need := Integer(S.Waiters.Item(I).Wait.Data[0]);
    if Left < Need then
      Break;
    Dec(Left, Need);
  end;
  if Left > S.MaxCount then
    begin FHLE.Result(SCE_KERNEL_ERROR_SEMA_OVF); Exit; end;
  Spend(PSPSyncCallNs);
  Inc(S.Count, N);
  FHLE.Result(0);
  S.WakeWaiters;
end;

procedure TPSPKernel.WaitSemaCommon(AllowCB: Boolean);
begin
  var Need := FHLE.ArgInt(1);
  if Need <= 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_COUNT); Exit; end;
  var S := TPSPSema(GetObject(FHLE.Arg(0), TPSPSema));
  if S = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_SEMID); Exit; end;
  if Need > S.MaxCount then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_COUNT); Exit; end;
  Spend(PSPSyncCallNs);
  FHLE.Result(0);
  if (S.Count >= Need) and (S.Waiters.Count = 0) then
  begin
    Dec(S.Count, Need);
    if AllowCB then
      CheckCallbacksNow;
    Exit;
  end;
  if not CanWait then
    begin FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT); Exit; end;
  S.Waiters.Add(FCurrent);
  BeginWaitData(PSPWaitSema, S, S.UID, FHLE.Arg(2), AllowCB, SemaRetry, [Cardinal(Need)]);
end;

procedure TPSPKernel.hWaitSema;
begin
  WaitSemaCommon(False);
end;

procedure TPSPKernel.hWaitSemaCB;
begin
  WaitSemaCommon(True);
end;

procedure TPSPKernel.hPollSema;
begin
  var Need := FHLE.ArgInt(1);
  if Need <= 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_COUNT); Exit; end;
  var S := TPSPSema(GetObject(FHLE.Arg(0), TPSPSema));
  if S = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_SEMID); Exit; end;
  if (S.Count >= Need) and (S.Waiters.Count = 0) then
  begin
    Dec(S.Count, Need);
    FHLE.Result(0);
  end
  else
    FHLE.Result(SCE_KERNEL_ERROR_SEMA_ZERO);
end;

procedure TPSPKernel.hCancelSema;
begin
  var S := TPSPSema(GetObject(FHLE.Arg(0), TPSPSema));
  if S = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_SEMID); Exit; end;
  var NewCount := FHLE.ArgInt(1);
  if NewCount > S.MaxCount then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_COUNT); Exit; end;
  if FHLE.Arg(2) <> 0 then
    FMemory.Write32(FHLE.Arg(2), Cardinal(S.Waiters.Count));
  FHLE.Result(0);
  while S.Waiters.Count > 0 do
    EndWait(S.Waiters.First, SCE_KERNEL_ERROR_WAIT_CANCEL);
  if NewCount < 0 then
    S.Count := S.InitCount
  else
    S.Count := NewCount;
end;

procedure TPSPKernel.hReferSemaStatus;
begin
  var S := TPSPSema(GetObject(FHLE.Arg(0), TPSPSema));
  if S = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_SEMID); Exit; end;
  var Buf: array[0..$37] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var N := RawByteString(S.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  PCardinal(@Buf[$24])^ := S.Attr;
  PCardinal(@Buf[$28])^ := Cardinal(S.InitCount);
  PCardinal(@Buf[$2C])^ := Cardinal(S.Count);
  PCardinal(@Buf[$30])^ := Cardinal(S.MaxCount);
  PCardinal(@Buf[$34])^ := Cardinal(S.Waiters.Count);
  WriteInfo(FHLE.Arg(1), Buf, $38);
  FHLE.Result(0);
end;

{ HLE: event flags }

function TPSPKernel.EventFlagRetry(T: TPSPThread): Boolean;
begin
  var E := TPSPEventFlag(T.Wait.Obj);
  if (E = nil) or not FObjects.ContainsKey(T.Wait.Id) then
  begin
    T.SetResult(SCE_KERNEL_ERROR_WAIT_DELETE);
    if T.Wait.Data[2] <> 0 then
      FMemory.Write32(T.Wait.Data[2], 0);
    Exit(True);
  end;
  Result := E.TryTake(T);
end;

procedure TPSPKernel.EventFlagAbort(T: TPSPThread);
begin
  // A wait that ends without the bits still reports the pattern, unless it
  // timed out before it began.
  var E := TPSPEventFlag(T.Wait.Obj);
  if T.Wait.Deadline = 0 then
    Exit;
  if (T.Wait.Data[2] <> 0) and (E <> nil) and FObjects.ContainsKey(T.Wait.Id) then
    FMemory.Write32(T.Wait.Data[2], E.Pattern);
end;

procedure TPSPKernel.hCreateEventFlag;
begin
  var Name: string;
  if not ReadName(FHLE.Arg(0), Name) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ERROR); Exit; end;
  var Attr := FHLE.Arg(1);
  if (Attr and $100) <> 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR); Exit; end;
  if Attr >= $300 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR); Exit; end;
  var E := TPSPEventFlag.Create;
  E.Name := Name;
  E.Attr := Attr;
  E.Pattern := FHLE.Arg(2);
  E.InitPattern := E.Pattern;
  Spend(PSPSyncCallNs);
  FHLE.Result(AddObject(E));
end;

procedure TPSPKernel.hDeleteEventFlag;
begin
  var E := TPSPEventFlag(GetObject(FHLE.Arg(0), TPSPEventFlag));
  if E = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_EVFID); Exit; end;
  FHLE.Result(0);
  E.Pattern := 0;
  while E.Waiters.Count > 0 do
    EndWait(E.Waiters.First, SCE_KERNEL_ERROR_WAIT_DELETE);
  DeleteObject(E);
end;

procedure TPSPKernel.hSetEventFlag;
begin
  var E := TPSPEventFlag(GetObject(FHLE.Arg(0), TPSPEventFlag));
  if E = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_EVFID); Exit; end;
  Spend(PSPSyncCallNs);
  FHLE.Result(0);
  E.Pattern := E.Pattern or FHLE.Arg(1);
  E.WakeWaiters;
end;

procedure TPSPKernel.hClearEventFlag;
begin
  var E := TPSPEventFlag(GetObject(FHLE.Arg(0), TPSPEventFlag));
  if E = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_EVFID); Exit; end;
  E.Pattern := E.Pattern and FHLE.Arg(1);
  FHLE.Result(0);
end;

function EventFlagModeError(Mode, Bits: Cardinal): Cardinal;
begin
  if ((Mode and not Cardinal($31)) <> 0) or ((Mode and $30) = $30) then
    Result := SCE_KERNEL_ERROR_ILLEGAL_MODE
  else if Bits = 0 then
    Result := SCE_KERNEL_ERROR_EVF_ILPAT
  else
    Result := 0;
end;

procedure TPSPKernel.WaitEventFlagCommon(AllowCB: Boolean);
begin
  var Bits := FHLE.Arg(1);
  var Mode := FHLE.Arg(2);
  var OutPtr := FHLE.Arg(3);
  var Err := EventFlagModeError(Mode, Bits);
  if Err <> 0 then
    begin FHLE.Result(Err); Exit; end;
  var E := TPSPEventFlag(GetObject(FHLE.Arg(0), TPSPEventFlag));
  if E = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_EVFID); Exit; end;
  if not CanWait then
    begin FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT); Exit; end;
  Spend(PSPSyncCallNs);
  FHLE.Result(0);
  if ((E.Attr and $200) = 0) and (E.Waiters.Count > 0) then
    begin FHLE.Result(SCE_KERNEL_ERROR_EVF_MULTI); Exit; end;
  if E.Matches(Bits, Mode) then
  begin
    if OutPtr <> 0 then
      FMemory.Write32(OutPtr, E.Pattern);
    if (Mode and $10) <> 0 then
      E.Pattern := 0
    else if (Mode and $20) <> 0 then
      E.Pattern := E.Pattern and not Bits;
    if AllowCB then
      CheckCallbacksNow;
    Exit;
  end;
  E.Waiters.Add(FCurrent);
  if not BeginWaitData(PSPWaitEventFlag, E, E.UID, FHLE.Arg(4), AllowCB, EventFlagRetry, [Bits, Mode, OutPtr], EventFlagAbort) then
    Exit;
end;

procedure TPSPKernel.hWaitEventFlag;
begin
  WaitEventFlagCommon(False);
end;

procedure TPSPKernel.hWaitEventFlagCB;
begin
  WaitEventFlagCommon(True);
end;

procedure TPSPKernel.hPollEventFlag;
begin
  var Bits := FHLE.Arg(1);
  var Mode := FHLE.Arg(2);
  var OutPtr := FHLE.Arg(3);
  var Err := EventFlagModeError(Mode, Bits);
  if Err <> 0 then
    begin FHLE.Result(Err); Exit; end;
  var E := TPSPEventFlag(GetObject(FHLE.Arg(0), TPSPEventFlag));
  if E = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_EVFID); Exit; end;
  if ((E.Attr and $200) = 0) and (E.Waiters.Count > 0) then
    begin FHLE.Result(SCE_KERNEL_ERROR_EVF_MULTI); Exit; end;
  if OutPtr <> 0 then
    FMemory.Write32(OutPtr, E.Pattern);
  if E.Matches(Bits, Mode) then
  begin
    if (Mode and $10) <> 0 then
      E.Pattern := 0
    else if (Mode and $20) <> 0 then
      E.Pattern := E.Pattern and not Bits;
    FHLE.Result(0);
  end
  else
    FHLE.Result(SCE_KERNEL_ERROR_EVF_COND);
end;

procedure TPSPKernel.hCancelEventFlag;
begin
  var E := TPSPEventFlag(GetObject(FHLE.Arg(0), TPSPEventFlag));
  if E = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_EVFID); Exit; end;
  if FHLE.Arg(2) <> 0 then
    FMemory.Write32(FHLE.Arg(2), Cardinal(E.Waiters.Count));
  FHLE.Result(0);
  E.Pattern := FHLE.Arg(1);
  while E.Waiters.Count > 0 do
    EndWait(E.Waiters.First, SCE_KERNEL_ERROR_WAIT_CANCEL);
end;

procedure TPSPKernel.hReferEventFlagStatus;
begin
  var E := TPSPEventFlag(GetObject(FHLE.Arg(0), TPSPEventFlag));
  if E = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_EVFID); Exit; end;
  var Buf: array[0..$33] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var N := RawByteString(E.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  PCardinal(@Buf[$24])^ := E.Attr;
  PCardinal(@Buf[$28])^ := E.InitPattern;
  PCardinal(@Buf[$2C])^ := E.Pattern;
  PCardinal(@Buf[$30])^ := Cardinal(E.Waiters.Count);
  WriteInfo(FHLE.Arg(1), Buf, $34);
  FHLE.Result(0);
end;
