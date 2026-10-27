{ PSP.Kernel: threads and callbacks. }

function TPSPKernel.CreateThread(const Name: string; Entry: Cardinal; Priority: Integer; StackSize, Attr, GP, ModuleId: Cardinal): TPSPThread;
begin
  StackSize := AlignUp(StackSize, 256);
  var Stack := AllocUser(StackSize, True, 'stack:' + Name);
  if Stack = 0 then
    Exit(nil);
  var T := TPSPThread.Create;
  T.Name := Name;
  T.Entry := Entry;
  T.Priority := Priority;
  T.InitPriority := Priority;
  T.Attr := Attr;
  T.StackBlock := Stack;
  T.StackSize := StackSize;
  T.StackTop := Stack + StackSize;
  T.GP := GP;
  T.ModuleId := ModuleId;
  T.Status := PSPThreadDormant;
  if (Attr and $00100000) = 0 then
    FMemory.Fill(Stack, $FF, StackSize);
  AddObject(T);
  FThreads.Add(T);
  Result := T;
end;

procedure TPSPKernel.StartThread(T: TPSPThread; ArgSize, ArgPtr: Cardinal; const ArgData: TBytes);
begin
  var C := Default(TPSPContext);
  C.VC := FCPU.Ctx.VC;
  C.VC[VFPU_PFXS] := $E4;
  C.VC[VFPU_PFXT] := $E4;
  C.VC[VFPU_PFXD] := 0;
  C.VC[VFPU_CC] := $3F;
  var Top := T.StackTop;
  // The kernel keeps the thread's id at the stack top; k0 points there.
  var K0 := Top - $100;
  FMemory.Fill(K0, 0, $100);
  FMemory.Write32(K0 + $C0, T.UID);
  FMemory.Write32(K0 + $C8, T.StackBlock);
  FMemory.Write32(K0 + $F8, $FFFFFFFF);
  FMemory.Write32(K0 + $FC, $FFFFFFFF);
  var SP := K0;
  var A1: Cardinal := 0;
  if Length(ArgData) > 0 then
  begin
    SP := (SP - Cardinal(Length(ArgData))) and not Cardinal(15);
    FMemory.WriteBytes(SP, ArgData[0], Length(ArgData));
    A1 := SP;
    ArgSize := Length(ArgData);
  end
  else if (ArgPtr <> 0) and (ArgSize > 0) then
  begin
    SP := (SP - ArgSize) and not Cardinal(15);
    FMemory.Copy(SP, ArgPtr, ArgSize);
    A1 := SP;
  end;
  SP := SP - 64;
  C.GPR[4] := ArgSize;
  C.GPR[5] := A1;
  C.GPR[26] := K0;
  C.GPR[28] := T.GP;
  C.GPR[29] := SP;
  C.GPR[31] := FTrapBase + 8;
  C.PC := T.Entry;
  C.NPC := T.Entry + 4;
  T.Ctx := C;
  T.ExitStatus := SCE_KERNEL_ERROR_NOT_DORMANT;
  T.WakeupCount := 0;
  T.Priority := T.InitPriority;
  T.Wait := Default(TPSPWait);
  T.Frames.Clear;
  T.Status := PSPThreadReady;
  Inc(FThreadSeq);
  T.Seq := FThreadSeq;
  PushReady(T, False);
  RequestReschedule;
end;

procedure TPSPKernel.KillThreadFrames(T: TPSPThread);
begin
  T.Frames.Clear;
  T.CallbacksPending := False;
  for var I := FTimers.Count - 1 downto 0 do
    if (FTimers[I].Kind = tkWait) and (FTimers[I].Thread = T) then
      FTimers.Delete(I);
  ScheduleTimerEvent;
end;

procedure TPSPKernel.WakeEndWaiters(T: TPSPThread);
begin
  while T.EndWaiters.Count > 0 do
  begin
    var W := T.EndWaiters[0];
    T.EndWaiters.Delete(0);
    if W.IsWaiting and (W.Wait.Obj = T) then
      EndWait(W, T.ExitStatus);
  end;
end;

procedure TPSPKernel.ExitCurrent(Status: Cardinal);
begin
  var T := FCurrent;
  if T = nil then
    Exit;
  T.ExitStatus := Status;
  T.Status := PSPThreadDormant;
  KillThreadFrames(T);
  WakeEndWaiters(T);
  if Assigned(T.OnExit) then
  begin
    var Hook := T.OnExit;
    T.OnExit := nil;
    Hook(T);
  end;
  RequestReschedule;
end;

procedure TPSPKernel.TerminateThread(T: TPSPThread; Status: Cardinal);
begin
  if T.IsWaiting then
  begin
    if T.Wait.Obj <> nil then
      T.Wait.Obj.RemoveWaiter(T);
    if Assigned(T.Wait.Abort) then
      T.Wait.Abort(T);
  end;
  RemoveReady(T);
  T.Wait := Default(TPSPWait);
  T.ExitStatus := Status;
  T.Status := PSPThreadDormant;
  KillThreadFrames(T);
  WakeEndWaiters(T);
  if Assigned(T.OnExit) then
  begin
    var Hook := T.OnExit;
    T.OnExit := nil;
    Hook(T);
  end;
  RequestReschedule;
end;

procedure TPSPKernel.DeleteThread(T: TPSPThread);
begin
  RemoveReady(T);
  KillThreadFrames(T);
  for var CB in T.Callbacks.ToArray do
    DeleteObject(CB);
  T.Callbacks.Clear;
  if T.StackBlock <> 0 then
  begin
    if (T.Attr and $00200000) <> 0 then
      FMemory.Fill(T.StackBlock, 0, T.StackSize);
    FUserPartition.FreeBlock(T.StackBlock);
  end;
  FThreads.Remove(T);
  if FCurrent = T then
    FCurrent := nil;
  DeleteObject(T);
end;

procedure TPSPKernel.ChangePriority(T: TPSPThread; Priority: Integer);
begin
  if (T.Status and PSPThreadReady) <> 0 then
  begin
    RemoveReady(T);
    T.Priority := Priority;
    PushReady(T, False);
  end
  else
    T.Priority := Priority;
  RequestReschedule;
end;

{ HLE: threads }

function ValidUserPriority(P: Integer): Boolean; inline;
begin
  Result := (P >= 8) and (P <= 119);
end;

procedure TPSPKernel.hCreateThread;
begin
  var NamePtr := FHLE.Arg(0);
  var Entry := FHLE.Arg(1);
  var Prio := FHLE.ArgInt(2);
  var StackSize := FHLE.Arg(3);
  var Attr := FHLE.Arg(4);
  if NamePtr = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ERROR); Exit; end;
  if (Entry = 0) or ((Entry and 3) <> 0) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ENTRY); Exit; end;
  if Integer(StackSize) < $200 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_STACK_SIZE); Exit; end;
  if not ValidUserPriority(Prio) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_PRIORITY); Exit; end;
  if (Attr and $7F0F00FF) <> 0 then
    Attr := Attr and not $7F0F00FF;
  var GP := FCPU.Ctx.GPR[28];
  var ModuleId: Cardinal := 0;
  if FCurrent <> nil then
    ModuleId := FCurrent.ModuleId;
  var T := CreateThread(FMemory.ReadString(NamePtr, 31), Entry, Prio, StackSize, Attr or $80000000, GP, ModuleId);
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY); Exit; end;
  FHLE.Result(T.UID);
end;

procedure TPSPKernel.hStartThread;
begin
  var T := TPSPThread(GetObject(FHLE.Arg(0), TPSPThread));
  if T = nil then
  begin
    if FHLE.Arg(0) = 0 then
      begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_THID); Exit; end;
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  end;
  if (T.Status and PSPThreadDormant) = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_NOT_DORMANT); Exit; end;
  var Size := FHLE.Arg(1);
  var Ptr := FHLE.Arg(2);
  if Integer(Size) < 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_SIZE); Exit; end;
  FHLE.Result(0);
  StartThread(T, Size, Ptr);
end;

procedure TPSPKernel.hExitThread;
begin
  if (FCurrent = nil) or InInterrupt then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT); Exit; end;
  ExitCurrent(FHLE.Arg(0));
end;

procedure TPSPKernel.hExitDeleteThread;
begin
  var T := FCurrent;
  if (T = nil) or InInterrupt then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT); Exit; end;
  ExitCurrent(FHLE.Arg(0));
  Reschedule;
  DeleteThread(T);
end;

procedure TPSPKernel.hDeleteThread;
begin
  var Id := FHLE.Arg(0);
  if (Id = 0) or ((FCurrent <> nil) and (Id = FCurrent.UID)) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_THID); Exit; end;
  var T := TPSPThread(GetObject(Id, TPSPThread));
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  if (T.Status and PSPThreadDormant) = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_NOT_DORMANT); Exit; end;
  DeleteThread(T);
  FHLE.Result(0);
end;

procedure TPSPKernel.hTerminateThread;
begin
  var Id := FHLE.Arg(0);
  if (Id = 0) or ((FCurrent <> nil) and (Id = FCurrent.UID)) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_THID); Exit; end;
  var T := TPSPThread(GetObject(Id, TPSPThread));
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  if (T.Status and PSPThreadDormant) <> 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_DORMANT); Exit; end;
  TerminateThread(T, SCE_KERNEL_ERROR_THREAD_TERMINATED);
  FHLE.Result(0);
end;

procedure TPSPKernel.hTerminateDeleteThread;
begin
  var Id := FHLE.Arg(0);
  if (Id = 0) or ((FCurrent <> nil) and (Id = FCurrent.UID)) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_THID); Exit; end;
  var T := TPSPThread(GetObject(Id, TPSPThread));
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  if (T.Status and PSPThreadDormant) = 0 then
    TerminateThread(T, SCE_KERNEL_ERROR_THREAD_TERMINATED);
  DeleteThread(T);
  FHLE.Result(0);
end;

procedure TPSPKernel.hGetThreadId;
begin
  if InInterrupt then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT); Exit; end;
  if FCurrent = nil then
    FHLE.Result(0)
  else
    FHLE.Result(FCurrent.UID);
end;

procedure TPSPKernel.hGetThreadCurrentPriority;
begin
  if FCurrent = nil then
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT)
  else
    FHLE.Result(Cardinal(FCurrent.Priority));
end;

procedure TPSPKernel.hChangeThreadPriority;
begin
  var T := ThreadById(FHLE.Arg(0));
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  var P := FHLE.ArgInt(1);
  if P = 0 then
  begin
    if FCurrent = nil then
      begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_PRIORITY); Exit; end;
    P := FCurrent.Priority;
  end;
  if not ValidUserPriority(P) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_PRIORITY); Exit; end;
  if (T.Status and PSPThreadDormant) <> 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_DORMANT); Exit; end;
  FHLE.Result(0);
  ChangePriority(T, P);
end;

procedure TPSPKernel.hRotateThreadReadyQueue;
begin
  var P := FHLE.ArgInt(0);
  if FCurrent = nil then
    begin FHLE.Result(0); Exit; end;
  if P = 0 then
    P := FCurrent.Priority;
  if (P < 0) or (P > 127) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_PRIORITY); Exit; end;
  FHLE.Result(0);
  if P = FCurrent.Priority then
  begin
    if FReady[P].Count > 0 then
    begin
      // Current goes behind the others of its priority.
      FCurrent.Ctx := FCPU.Ctx;
      var T := FCurrent;
      T.Status := (T.Status and not PSPThreadRunning) or PSPThreadReady;
      PushReady(T, False);
      FCurrent := nil;
      T.Ctx := FCPU.Ctx;
      SwitchTo(BestReady);
    end;
  end
  else if FReady[P].Count > 1 then
  begin
    var T := FReady[P][0];
    FReady[P].Delete(0);
    FReady[P].Add(T);
  end;
end;

procedure TPSPKernel.hReferThreadStatus;
begin
  var T := ThreadById(FHLE.Arg(0));
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  var P := FHLE.Arg(1);
  if P = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR); Exit; end;
  var Size := FMemory.Read32(P);
  if Size = 0 then
    begin FHLE.Result(0); Exit; end;
  if Size > $68 then
    Size := $68;
  var Buf: array[0..$67] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  PCardinal(@Buf[0])^ := FMemory.Read32(P);
  var NameBytes := RawByteString(T.Name);
  if Length(NameBytes) > 31 then
    SetLength(NameBytes, 31);
  if NameBytes <> '' then
    Move(NameBytes[1], Buf[4], Length(NameBytes));
  var Status := T.Status;
  if T = FCurrent then
    Status := (Status and not (PSPThreadReady or PSPThreadWaiting)) or PSPThreadRunning;
  PCardinal(@Buf[$24])^ := T.Attr;
  PCardinal(@Buf[$28])^ := Status;
  PCardinal(@Buf[$2C])^ := T.Entry;
  PCardinal(@Buf[$30])^ := T.StackBlock;
  PCardinal(@Buf[$34])^ := T.StackSize;
  PCardinal(@Buf[$38])^ := T.GP;
  PCardinal(@Buf[$3C])^ := Cardinal(T.InitPriority);
  PCardinal(@Buf[$40])^ := Cardinal(T.Priority);
  if T.IsWaiting then
  begin
    PCardinal(@Buf[$44])^ := Cardinal(T.Wait.Kind);
    PCardinal(@Buf[$48])^ := T.Wait.Id;
  end;
  PCardinal(@Buf[$4C])^ := Cardinal(T.WakeupCount);
  PCardinal(@Buf[$50])^ := T.ExitStatus;
  PUInt64(@Buf[$54])^ := UInt64(T.RunClocks);
  PCardinal(@Buf[$60])^ := T.PreemptCount;
  PCardinal(@Buf[$64])^ := T.ReleaseCount;
  FMemory.WriteBytes(P, Buf, Size);
  FHLE.Result(0);
end;

procedure TPSPKernel.hReferThreadRunStatus;
begin
  var T := ThreadById(FHLE.Arg(0));
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  var P := FHLE.Arg(1);
  var Size := FMemory.Read32(P);
  if Size > $2C then
    Size := $2C;
  var Buf: array[0..$2B] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  PCardinal(@Buf[0])^ := FMemory.Read32(P);
  var Status := T.Status;
  if T = FCurrent then
    Status := PSPThreadRunning;
  PCardinal(@Buf[4])^ := Status;
  PCardinal(@Buf[8])^ := Cardinal(T.Priority);
  if T.IsWaiting then
  begin
    PCardinal(@Buf[12])^ := Cardinal(T.Wait.Kind);
    PCardinal(@Buf[16])^ := T.Wait.Id;
  end;
  PCardinal(@Buf[20])^ := Cardinal(T.WakeupCount);
  PUInt64(@Buf[24])^ := UInt64(T.RunClocks);
  FMemory.WriteBytes(P, Buf, Size);
  FHLE.Result(0);
end;

procedure TPSPKernel.hGetThreadExitStatus;
begin
  var T := ThreadById(FHLE.Arg(0));
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  if (T.Status and PSPThreadDormant) = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_NOT_DORMANT); Exit; end;
  FHLE.Result(T.ExitStatus);
end;

function TPSPKernel.NoRetry(T: TPSPThread): Boolean;
begin
  Result := False;
end;

function TPSPKernel.SleepRetry(T: TPSPThread): Boolean;
begin
  Result := T.WakeupCount > 0;
  if Result then
  begin
    Dec(T.WakeupCount);
    T.SetResult(0);
  end;
end;

procedure TPSPKernel.hSleepThread;
begin
  if not CanWait then
    begin FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT); Exit; end;
  FHLE.Result(0);
  if FCurrent.WakeupCount > 0 then
  begin
    Dec(FCurrent.WakeupCount);
    Exit;
  end;
  BeginWait(PSPWaitSleep, nil, 0, 0, False, SleepRetry);
end;

procedure TPSPKernel.hSleepThreadCB;
begin
  if not CanWait then
    begin FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT); Exit; end;
  FHLE.Result(0);
  if FCurrent.WakeupCount > 0 then
  begin
    Dec(FCurrent.WakeupCount);
    CheckCallbacksNow;
    Exit;
  end;
  BeginWait(PSPWaitSleep, nil, 0, 0, True, SleepRetry);
end;

procedure TPSPKernel.hWakeupThread;
begin
  var T := ThreadById(FHLE.Arg(0));
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  if (T.Status and PSPThreadDormant) <> 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_DORMANT); Exit; end;
  FHLE.Result(0);
  if T.IsWaiting and (T.Wait.Kind = PSPWaitSleep) then
    EndWait(T, 0)
  else
    Inc(T.WakeupCount);
end;

procedure TPSPKernel.hCancelWakeupThread;
begin
  var T := ThreadById(FHLE.Arg(0));
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  FHLE.Result(Cardinal(T.WakeupCount));
  T.WakeupCount := 0;
end;

procedure TPSPKernel.hSuspendThread;
begin
  var Id := FHLE.Arg(0);
  if (Id = 0) or ((FCurrent <> nil) and (Id = FCurrent.UID)) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_THID); Exit; end;
  var T := TPSPThread(GetObject(Id, TPSPThread));
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  if (T.Status and PSPThreadDormant) <> 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_DORMANT); Exit; end;
  if (T.Status and PSPThreadSuspended) <> 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_SUSPEND); Exit; end;
  if (T.Status and PSPThreadReady) <> 0 then
  begin
    RemoveReady(T);
    T.Status := T.Status and not PSPThreadReady;
  end;
  T.Status := T.Status or PSPThreadSuspended;
  FHLE.Result(0);
end;

procedure TPSPKernel.hResumeThread;
begin
  var T := TPSPThread(GetObject(FHLE.Arg(0), TPSPThread));
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  if (T.Status and PSPThreadSuspended) = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_NOT_SUSPEND); Exit; end;
  T.Status := T.Status and not PSPThreadSuspended;
  if (T.Status and (PSPThreadWaiting or PSPThreadDormant)) = 0 then
  begin
    T.Status := T.Status or PSPThreadReady;
    PushReady(T, False);
    RequestReschedule;
  end;
  FHLE.Result(0);
end;

function TPSPKernel.ThreadEndRetry(T: TPSPThread): Boolean;
begin
  var Target := TPSPThread(T.Wait.Obj);
  Result := (Target = nil) or not FObjects.ContainsKey(T.Wait.Id) or ((Target.Status and PSPThreadDormant) <> 0);
  if Result then
  begin
    if (Target <> nil) and FObjects.ContainsKey(T.Wait.Id) then
      T.SetResult(Target.ExitStatus)
    else
      T.SetResult(SCE_KERNEL_ERROR_WAIT_DELETE);
  end;
end;

procedure TPSPKernel.hWaitThreadEnd;
begin
  var Id := FHLE.Arg(0);
  if (FCurrent <> nil) and (Id = FCurrent.UID) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_THID); Exit; end;
  var T := TPSPThread(GetObject(Id, TPSPThread));
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  if (T.Status and PSPThreadDormant) <> 0 then
    begin FHLE.Result(T.ExitStatus); Exit; end;
  if not CanWait then
    begin FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT); Exit; end;
  T.EndWaiters.Add(FCurrent);
  BeginWait(PSPWaitThreadEnd, T, Id, FHLE.Arg(1), False, ThreadEndRetry);
end;

procedure TPSPKernel.hWaitThreadEndCB;
begin
  var Id := FHLE.Arg(0);
  if (FCurrent <> nil) and (Id = FCurrent.UID) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_THID); Exit; end;
  var T := TPSPThread(GetObject(Id, TPSPThread));
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  if (T.Status and PSPThreadDormant) <> 0 then
  begin
    FHLE.Result(T.ExitStatus);
    CheckCallbacksNow;
    Exit;
  end;
  if not CanWait then
    begin FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT); Exit; end;
  T.EndWaiters.Add(FCurrent);
  BeginWait(PSPWaitThreadEnd, T, Id, FHLE.Arg(1), True, ThreadEndRetry);
end;

function TPSPKernel.DelayRetry(T: TPSPThread): Boolean;
begin
  Result := T.Wait.Deadline <= FScheduler.Now;
  if Result then
    T.SetResult(0);
end;

procedure TPSPKernel.DelayCurrent(Microseconds: Int64; AllowCB: Boolean);
begin
  FHLE.Result(0);
  if not CanWait then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT);
    Exit;
  end;
  if Assigned(FOnSyncTime) then
    FOnSyncTime();
  // The thread manager's timer resolution adds a fixed latency.
  if Microseconds < 0 then
    Microseconds := 0;
  var Deadline := FScheduler.Now + (Microseconds + 15) * 1000;
  BeginWait(PSPWaitDelay, nil, 0, 0, AllowCB, DelayRetry);
  if (FCurrent <> nil) and (FCurrent.Wait.Kind = PSPWaitDelay) then
    SetWaitDeadline(FCurrent, Deadline)
  else if (FCurrent <> nil) and (FCurrent.Frames.Count > 0) then
  begin
    // Callbacks started first; the saved wait carries the deadline.
    var F := FCurrent.Frames.Last;
    F.SavedWait.Deadline := Deadline;
    FCurrent.Frames[FCurrent.Frames.Count - 1] := F;
  end;
end;

procedure TPSPKernel.hDelayThread;
begin
  DelayCurrent(FHLE.Arg(0), False);
end;

procedure TPSPKernel.hDelayThreadCB;
begin
  DelayCurrent(FHLE.Arg(0), True);
end;

procedure TPSPKernel.hDelaySysClockThread;
begin
  var P := FHLE.Arg(0);
  var Us := Int64(UInt64(FMemory.Read32(P)) or (UInt64(FMemory.Read32(P + 4)) shl 32));
  DelayCurrent(Us, False);
end;

procedure TPSPKernel.hDelaySysClockThreadCB;
begin
  var P := FHLE.Arg(0);
  var Us := Int64(UInt64(FMemory.Read32(P)) or (UInt64(FMemory.Read32(P + 4)) shl 32));
  DelayCurrent(Us, True);
end;

procedure TPSPKernel.hReleaseWaitThread;
begin
  var T := ThreadById(FHLE.Arg(0));
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  if T = FCurrent then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_THID); Exit; end;
  if not T.IsWaiting then
    begin FHLE.Result(SCE_KERNEL_ERROR_NOT_WAIT); Exit; end;
  Inc(T.ReleaseCount);
  FHLE.Result(0);
  EndWait(T, SCE_KERNEL_ERROR_RELEASE_WAIT);
end;

procedure TPSPKernel.hGetThreadStackFreeSize;
begin
  var T := ThreadById(FHLE.Arg(0));
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  var N: Cardinal := 0;
  while (N < T.StackSize) and (FMemory.Read8(T.StackBlock + N) = $FF) do
    Inc(N);
  FHLE.Result(N);
end;

procedure TPSPKernel.hCheckThreadStack;
begin
  if FCurrent = nil then
    begin FHLE.Result(0); Exit; end;
  var SP := FCPU.Ctx.GPR[29];
  if (SP >= FCurrent.StackBlock) and (SP <= FCurrent.StackTop) then
    FHLE.Result(SP - FCurrent.StackBlock)
  else
    FHLE.Result(0);
end;

procedure TPSPKernel.hChangeCurrentThreadAttr;
begin
  if FCurrent = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT); Exit; end;
  var Clear := FHLE.Arg(0);
  var SetBits := FHLE.Arg(1);
  if ((Clear or SetBits) and not $00F00000 and not $00004000) <> 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR); Exit; end;
  FCurrent.Attr := (FCurrent.Attr and not Clear) or SetBits;
  FHLE.Result(0);
end;

procedure TPSPKernel.hGetThreadmanIdType;
begin
  var O := GetObject(FHLE.Arg(0), nil);
  if (O = nil) or (O.IdType = 0) then
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ARGUMENT)
  else
    FHLE.Result(Cardinal(O.IdType));
end;

procedure TPSPKernel.hGetThreadmanIdList;
begin
  var Kind := FHLE.ArgInt(0);
  var Buf := FHLE.Arg(1);
  var Size := FHLE.ArgInt(2);
  var CountPtr := FHLE.Arg(3);
  if Size < 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_SIZE); Exit; end;
  var Ids := TList<Cardinal>.Create;
  try
    if Kind >= $41 then
    begin
      for var T in FThreads do
        case Kind of
          $41: if T.IsWaiting and (T.Wait.Kind = PSPWaitSleep) then Ids.Add(T.UID);
          $42: if T.IsWaiting and (T.Wait.Kind = PSPWaitDelay) then Ids.Add(T.UID);
          $43: if (T.Status and PSPThreadSuspended) <> 0 then Ids.Add(T.UID);
          $44: if (T.Status and PSPThreadDormant) <> 0 then Ids.Add(T.UID);
        end;
    end
    else if (Kind >= 1) and (Kind <= 12) then
    begin
      var Keys := FObjects.Keys.ToArray;
      TArray.Sort<Cardinal>(Keys);
      for var K in Keys do
        if FObjects[K].IdType = Kind then
          Ids.Add(K);
    end
    else
      begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_TYPE); Exit; end;
    var N := 0;
    for var I := 0 to Ids.Count - 1 do
      if (I < Size) and (Buf <> 0) then
      begin
        FMemory.Write32(Buf + Cardinal(I) * 4, Ids[I]);
        Inc(N);
      end;
    if CountPtr <> 0 then
      FMemory.Write32(CountPtr, Cardinal(Ids.Count));
    FHLE.Result(Cardinal(N));
  finally
    Ids.Free;
  end;
end;

procedure TPSPKernel.hSuspendDispatchThread;
begin
  if not FCPU.InterruptsEnabled then
    begin FHLE.Result(SCE_KERNEL_ERROR_CPUDI); Exit; end;
  FHLE.Result(Ord(not FDispatchSuspended));
  FDispatchSuspended := True;
end;

procedure TPSPKernel.hResumeDispatchThread;
begin
  if not FCPU.InterruptsEnabled then
    begin FHLE.Result(SCE_KERNEL_ERROR_CPUDI); Exit; end;
  FDispatchSuspended := FHLE.Arg(0) = 0;
  FHLE.Result(0);
  if not FDispatchSuspended then
    RequestReschedule;
end;

procedure TPSPKernel.hReferSystemStatus;
begin
  var P := FHLE.Arg(0);
  var Size := FMemory.Read32(P);
  if Size > $1C then
    Size := $1C;
  if Size > 4 then
    FMemory.Fill(P + 4, 0, Size - 4);
  FHLE.Result(0);
end;

{ HLE: callbacks }

procedure TPSPKernel.hCreateCallback;
begin
  if FCurrent = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT); Exit; end;
  var NamePtr := FHLE.Arg(0);
  if NamePtr = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ERROR); Exit; end;
  var CB := TPSPCallback.Create;
  CB.Name := FMemory.ReadString(NamePtr, 31);
  CB.Func := FHLE.Arg(1);
  CB.Common := FHLE.Arg(2);
  CB.GP := FCPU.Ctx.GPR[28];
  CB.Thread := FCurrent;
  AddObject(CB);
  FCurrent.Callbacks.Add(CB);
  FHLE.Result(CB.UID);
end;

procedure TPSPKernel.hDeleteCallback;
begin
  var CB := TPSPCallback(GetObject(FHLE.Arg(0), TPSPCallback));
  if CB = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_CBID); Exit; end;
  if CB.Thread <> nil then
    CB.Thread.Callbacks.Remove(CB);
  DeleteObject(CB);
  FHLE.Result(0);
end;

procedure TPSPKernel.hNotifyCallback;
begin
  var CB := TPSPCallback(GetObject(FHLE.Arg(0), TPSPCallback));
  if CB = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_CBID); Exit; end;
  FHLE.Result(0);
  NotifyCallback(CB, FHLE.Arg(1));
end;

procedure TPSPKernel.hCancelCallback;
begin
  var CB := TPSPCallback(GetObject(FHLE.Arg(0), TPSPCallback));
  if CB = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_CBID); Exit; end;
  CB.NotifyCount := 0;
  CB.NotifyArg := 0;
  FHLE.Result(0);
end;

procedure TPSPKernel.hGetCallbackCount;
begin
  var CB := TPSPCallback(GetObject(FHLE.Arg(0), TPSPCallback));
  if CB = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_CBID); Exit; end;
  FHLE.Result(CB.NotifyCount);
end;

procedure TPSPKernel.hCheckCallback;
begin
  FHLE.Result(0);
  if InInterrupt then
    Exit;
  CheckCallbacksNow;
end;

procedure TPSPKernel.hReferCallbackStatus;
begin
  var CB := TPSPCallback(GetObject(FHLE.Arg(0), TPSPCallback));
  if CB = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_CBID); Exit; end;
  var P := FHLE.Arg(1);
  var Size := FMemory.Read32(P);
  if Size > $38 then
    Size := $38;
  var Buf: array[0..$37] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  PCardinal(@Buf[0])^ := FMemory.Read32(P);
  var N := RawByteString(CB.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  if CB.Thread <> nil then
    PCardinal(@Buf[$24])^ := CB.Thread.UID;
  PCardinal(@Buf[$28])^ := CB.Func;
  PCardinal(@Buf[$2C])^ := CB.Common;
  PCardinal(@Buf[$30])^ := CB.NotifyCount;
  PCardinal(@Buf[$34])^ := CB.NotifyArg;
  FMemory.WriteBytes(P, Buf, Size);
  FHLE.Result(0);
end;
