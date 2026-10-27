{ PSP.Kernel: semaphores and event flags. }

{ TPSPSema }

constructor TPSPSema.Create;
begin
  inherited Create;
  Waiters := TPSPWaitQueue.Create(False);
end;

destructor TPSPSema.Destroy;
begin
  Waiters.Free;
  inherited;
end;

class function TPSPSema.IdType: Integer;
begin
  Result := 2;
end;

procedure TPSPSema.RemoveWaiter(T: TPSPThread);
begin
  Waiters.Remove(T);
end;

procedure TPSPSema.AddWaiter(T: TPSPThread);
begin
  Waiters.Add(T);
end;

function TPSPSema.TryTake(T: TPSPThread): Boolean;
begin
  var Need := Integer(T.Wait.Data[0]);
  Result := Count >= Need;
  if Result then
  begin
    Dec(Count, Need);
    T.SetResult(0);
  end;
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

constructor TPSPEventFlag.Create;
begin
  inherited Create;
  Waiters := TPSPWaitQueue.Create(False);
end;

destructor TPSPEventFlag.Destroy;
begin
  Waiters.Free;
  inherited;
end;

class function TPSPEventFlag.IdType: Integer;
begin
  Result := 3;
end;

procedure TPSPEventFlag.RemoveWaiter(T: TPSPThread);
begin
  Waiters.Remove(T);
end;

procedure TPSPEventFlag.AddWaiter(T: TPSPThread);
begin
  Waiters.Add(T);
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
  var NamePtr := FHLE.Arg(0);
  var Attr := FHLE.Arg(1);
  var Init := FHLE.ArgInt(2);
  var Max := FHLE.ArgInt(3);
  if NamePtr = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ERROR); Exit; end;
  if Attr >= $200 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR); Exit; end;
  if (Init < 0) or (Max <= 0) or (Init > Max) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_COUNT); Exit; end;
  var S := TPSPSema.Create;
  S.Name := FMemory.ReadString(NamePtr, 31);
  S.Attr := Attr;
  S.Count := Init;
  S.InitCount := Init;
  S.MaxCount := Max;
  S.Waiters.ByPriority := (Attr and $100) <> 0;
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
  if N <= 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_COUNT); Exit; end;
  if Int64(S.Count) + N - S.Waiters.Count > S.MaxCount then
  begin
    // Waiters about to take count do not count against the maximum.
    var Pending: Int64 := 0;
    for var I := 0 to S.Waiters.Count - 1 do
      Inc(Pending, Integer(S.Waiters.Item(I).Wait.Data[0]));
    if Int64(S.Count) + N - Pending > S.MaxCount then
      begin FHLE.Result(SCE_KERNEL_ERROR_SEMA_OVF); Exit; end;
  end;
  Inc(S.Count, N);
  FHLE.Result(0);
  S.WakeWaiters;
end;

procedure WaitSemaCommon(K: TPSPKernel; AllowCB: Boolean);
begin
  var H := K.FHLE;
  var S := TPSPSema(K.GetObject(H.Arg(0), TPSPSema));
  var Need := H.ArgInt(1);
  if Need <= 0 then
    begin H.Result(SCE_KERNEL_ERROR_ILLEGAL_COUNT); Exit; end;
  if S = nil then
    begin H.Result(SCE_KERNEL_ERROR_UNKNOWN_SEMID); Exit; end;
  if Need > S.MaxCount then
    begin H.Result(SCE_KERNEL_ERROR_ILLEGAL_COUNT); Exit; end;
  H.Result(0);
  if (S.Count >= Need) and (S.Waiters.Count = 0) then
  begin
    Dec(S.Count, Need);
    if AllowCB then
      K.CheckCallbacksNow;
    Exit;
  end;
  if not K.CanWait then
    begin H.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT); Exit; end;
  S.Waiters.Add(K.Current);
  K.BeginWait(PSPWaitSema, S, S.UID, H.Arg(2), AllowCB, K.SemaRetry);
  if K.Current <> nil then
    K.Current.Wait.Data[0] := Cardinal(Need);
  if (K.Current <> nil) and (K.Current.Frames.Count > 0) and (K.Current.Wait.Kind = PSPWaitNone) then
  begin
    var F := K.Current.Frames.Last;
    F.SavedWait.Data[0] := Cardinal(Need);
    K.Current.Frames[K.Current.Frames.Count - 1] := F;
  end;
end;

procedure TPSPKernel.hWaitSema;
begin
  WaitSemaCommon(Self, False);
end;

procedure TPSPKernel.hWaitSemaCB;
begin
  WaitSemaCommon(Self, True);
end;

procedure TPSPKernel.hPollSema;
begin
  var S := TPSPSema(GetObject(FHLE.Arg(0), TPSPSema));
  var Need := FHLE.ArgInt(1);
  if Need <= 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_COUNT); Exit; end;
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
  var P := FHLE.Arg(1);
  var Size := FMemory.Read32(P);
  if Size > $38 then
    Size := $38;
  var Buf: array[0..$37] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  PCardinal(@Buf[0])^ := FMemory.Read32(P);
  var N := RawByteString(S.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  PCardinal(@Buf[$24])^ := S.Attr;
  PCardinal(@Buf[$28])^ := Cardinal(S.InitCount);
  PCardinal(@Buf[$2C])^ := Cardinal(S.Count);
  PCardinal(@Buf[$30])^ := Cardinal(S.MaxCount);
  PCardinal(@Buf[$34])^ := Cardinal(S.Waiters.Count);
  FMemory.WriteBytes(P, Buf, Size);
  FHLE.Result(0);
end;

{ HLE: event flags }

function TPSPKernel.EventFlagRetry(T: TPSPThread): Boolean;
begin
  var E := TPSPEventFlag(T.Wait.Obj);
  if (E = nil) or not FObjects.ContainsKey(T.Wait.Id) then
  begin
    T.SetResult(SCE_KERNEL_ERROR_WAIT_DELETE);
    Exit(True);
  end;
  Result := E.TryTake(T);
end;

procedure TPSPKernel.hCreateEventFlag;
begin
  var NamePtr := FHLE.Arg(0);
  var Attr := FHLE.Arg(1);
  if NamePtr = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ERROR); Exit; end;
  if (Attr and $100) <> 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR); Exit; end;
  if Attr >= $300 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR); Exit; end;
  var E := TPSPEventFlag.Create;
  E.Name := FMemory.ReadString(NamePtr, 31);
  E.Attr := Attr;
  E.Pattern := FHLE.Arg(2);
  E.InitPattern := E.Pattern;
  FHLE.Result(AddObject(E));
end;

procedure TPSPKernel.hDeleteEventFlag;
begin
  var E := TPSPEventFlag(GetObject(FHLE.Arg(0), TPSPEventFlag));
  if E = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_EVFID); Exit; end;
  FHLE.Result(0);
  while E.Waiters.Count > 0 do
    EndWait(E.Waiters.First, SCE_KERNEL_ERROR_WAIT_DELETE);
  DeleteObject(E);
end;

procedure TPSPKernel.hSetEventFlag;
begin
  var E := TPSPEventFlag(GetObject(FHLE.Arg(0), TPSPEventFlag));
  if E = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_EVFID); Exit; end;
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

procedure WaitEventFlagCommon(K: TPSPKernel; AllowCB: Boolean);
begin
  var H := K.FHLE;
  var E := TPSPEventFlag(K.GetObject(H.Arg(0), TPSPEventFlag));
  var Bits := H.Arg(1);
  var Mode := H.Arg(2);
  var OutPtr := H.Arg(3);
  if E = nil then
    begin H.Result(SCE_KERNEL_ERROR_UNKNOWN_EVFID); Exit; end;
  if (Mode and not Cardinal($31)) <> 0 then
    begin H.Result(SCE_KERNEL_ERROR_ILLEGAL_MODE); Exit; end;
  if ((Mode and $30) = $30) then
    begin H.Result(SCE_KERNEL_ERROR_ILLEGAL_MODE); Exit; end;
  if Bits = 0 then
    begin H.Result(SCE_KERNEL_ERROR_EVF_ILPAT); Exit; end;
  if not K.CanWait then
    begin H.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT); Exit; end;
  H.Result(0);
  if E.Matches(Bits, Mode) then
  begin
    if OutPtr <> 0 then
      K.Memory.Write32(OutPtr, E.Pattern);
    if (Mode and $10) <> 0 then
      E.Pattern := 0
    else if (Mode and $20) <> 0 then
      E.Pattern := E.Pattern and not Bits;
    if AllowCB then
      K.CheckCallbacksNow;
    Exit;
  end;
  if ((E.Attr and $200) = 0) and (E.Waiters.Count > 0) then
    begin H.Result(SCE_KERNEL_ERROR_EVF_MULTI); Exit; end;
  E.Waiters.Add(K.Current);
  K.BeginWait(PSPWaitEventFlag, E, E.UID, H.Arg(4), AllowCB, K.EventFlagRetry);
  var T := K.Current;
  if T <> nil then
  begin
    if T.Wait.Kind = PSPWaitEventFlag then
    begin
      T.Wait.Data[0] := Bits;
      T.Wait.Data[1] := Mode;
      T.Wait.Data[2] := OutPtr;
    end
    else if T.Frames.Count > 0 then
    begin
      var F := T.Frames.Last;
      F.SavedWait.Data[0] := Bits;
      F.SavedWait.Data[1] := Mode;
      F.SavedWait.Data[2] := OutPtr;
      T.Frames[T.Frames.Count - 1] := F;
    end;
  end;
end;

procedure TPSPKernel.hWaitEventFlag;
begin
  WaitEventFlagCommon(Self, False);
end;

procedure TPSPKernel.hWaitEventFlagCB;
begin
  WaitEventFlagCommon(Self, True);
end;

procedure TPSPKernel.hPollEventFlag;
begin
  var E := TPSPEventFlag(GetObject(FHLE.Arg(0), TPSPEventFlag));
  var Bits := FHLE.Arg(1);
  var Mode := FHLE.Arg(2);
  var OutPtr := FHLE.Arg(3);
  if E = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_EVFID); Exit; end;
  if (Mode and not Cardinal($31)) <> 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MODE); Exit; end;
  if ((Mode and $30) = $30) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MODE); Exit; end;
  if Bits = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_EVF_ILPAT); Exit; end;
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
  while E.Waiters.Count > 0 do
    EndWait(E.Waiters.First, SCE_KERNEL_ERROR_WAIT_CANCEL);
  E.Pattern := FHLE.Arg(1);
end;

procedure TPSPKernel.hReferEventFlagStatus;
begin
  var E := TPSPEventFlag(GetObject(FHLE.Arg(0), TPSPEventFlag));
  if E = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_EVFID); Exit; end;
  var P := FHLE.Arg(1);
  var Size := FMemory.Read32(P);
  if Size > $34 then
    Size := $34;
  var Buf: array[0..$33] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  PCardinal(@Buf[0])^ := FMemory.Read32(P);
  var N := RawByteString(E.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  PCardinal(@Buf[$24])^ := E.Attr;
  PCardinal(@Buf[$28])^ := E.InitPattern;
  PCardinal(@Buf[$2C])^ := E.Pattern;
  PCardinal(@Buf[$30])^ := Cardinal(E.Waiters.Count);
  FMemory.WriteBytes(P, Buf, Size);
  FHLE.Result(0);
end;
