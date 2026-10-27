{ PSP.Kernel: threads and callbacks. }

function TPSPKernel.CreateThread(const Name: string; Entry: Cardinal; Priority: Integer; StackSize, Attr, GP, ModuleId: Cardinal): TPSPThread;
begin
  StackSize := AlignUp(StackSize, 256);
  var Part := FStackPartition;
  if (Attr and $80000000) = 0 then
    Part := FKernelPartition
  else if (Attr and $00400000) <> 0 then
    Part := FUserPartition;
  var Stack: Cardinal;
  if Part = FUserPartition then
    Stack := Part.Alloc(StackSize, akLow, 0, 256, 'stack:' + Name)
  else
    Stack := Part.Alloc(StackSize, akHigh, 0, 256, 'stack:' + Name);
  if Stack = 0 then
    Exit(nil);
  var T := TPSPThread.Create;
  T.Name := Name;
  T.Entry := Entry;
  T.Priority := Priority;
  T.InitPriority := Priority;
  if (Attr and $80000000) <> 0 then
    Attr := Attr or $FF;
  T.Attr := Attr;
  T.StackBlock := Stack;
  T.StackSize := StackSize;
  T.StackTop := Stack + StackSize;
  T.StackPartition := Part;
  T.GP := GP;
  T.ModuleId := ModuleId;
  T.Status := PSPThreadDormant;
  T.ExitStatus := SCE_KERNEL_ERROR_DORMANT;
  if (Attr and $00100000) = 0 then
    FMemory.Fill(Stack, $FF, StackSize);
  AddObject(T);
  // The bottom of the stack holds the owner's id.
  FMemory.Write32(Stack, T.UID);
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
  end
  else
    ArgSize := 0;
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
  T.BusyNs := 0;
  T.Fresh := True;
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
  DropWaitTimer(T);
  while T.ExtraStacks.Count > 0 do
  begin
    var Block := T.ExtraStacks.Last;
    T.ExtraStacks.Delete(T.ExtraStacks.Count - 1);
    T.StackPartition.FreeBlock(Block);
  end;
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
  ReleaseMutexesOf(T);
  ReleaseTlsOf(T);
  NotifyThreadEvent(PSPThreadEventExit, T);
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
  var Obj: TPSPKernelObject := nil;
  if T.IsWaiting then
  begin
    Obj := T.Wait.Obj;
    if Obj <> nil then
      Obj.RemoveWaiter(T);
    if Assigned(T.Wait.Abort) then
      T.Wait.Abort(T);
  end;
  RemoveReady(T);
  T.Wait := Default(TPSPWait);
  T.ExitStatus := Status;
  T.Status := PSPThreadDormant;
  KillThreadFrames(T);
  // The threads waiting for the end are made ready, but nothing is dispatched.
  var Pending := FRescheduleNeeded;
  WakeEndWaiters(T);
  ReleaseMutexesOf(T);
  ReleaseTlsOf(T);
  if Obj <> nil then
    Obj.WaiterGone;
  FRescheduleNeeded := Pending;
  if Assigned(T.OnExit) then
  begin
    var Hook := T.OnExit;
    T.OnExit := nil;
    Hook(T);
  end;
end;

procedure TPSPKernel.FreeThreadStacks(T: TPSPThread);
begin
  if T.StackBlock = 0 then
    Exit;
  if (T.Attr and $00200000) <> 0 then
    FMemory.Fill(T.StackBlock, 0, T.StackSize);
  T.StackPartition.FreeBlock(T.StackBlock);
  T.StackBlock := 0;
end;

procedure TPSPKernel.DeleteThread(T: TPSPThread);
begin
  NotifyThreadEvent(PSPThreadEventDelete, T);
  RemoveReady(T);
  KillThreadFrames(T);
  for var CB in T.Callbacks.ToArray do
    DeleteObject(CB);
  T.Callbacks.Clear;
  FreeThreadStacks(T);
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
  if T.IsWaiting and (T.Wait.Obj is TPSPWaitObject) then
  begin
    var Q := TPSPWaitObject(T.Wait.Obj).Waiters;
    if Q.ByPriority and Q.Contains(T) then
    begin
      Q.Remove(T);
      Q.Add(T);
    end;
  end;
  RequestReschedule;
end;

{ HLE: threads }

function ValidUserPriority(P: Integer): Boolean; inline;
begin
  Result := (P >= 8) and (P <= 119);
end;

function TPSPKernel.ValidPriorityFor(P: Integer): Boolean;
begin
  if (FCurrent <> nil) and FCurrent.IsKernel then
    Result := (P >= 1) and (P <= 126)
  else
    Result := ValidUserPriority(P);
end;

procedure TPSPKernel.hCreateThread;
begin
  if InInterrupt then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT); Exit; end;
  var NamePtr := FHLE.Arg(0);
  var Entry := FHLE.Arg(1);
  var Prio := FHLE.ArgInt(2);
  var StackSize := FHLE.Arg(3);
  var Attr := FHLE.Arg(4);
  var Name: string;
  if not ReadName(NamePtr, Name) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ERROR); Exit; end;
  var KernelCaller := (FCurrent <> nil) and FCurrent.IsKernel;
  if (Entry <> 0) and not KernelCaller and not ValidUserAddress(Entry) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR); Exit; end;
  if StackSize < $200 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_STACK_SIZE); Exit; end;
  if not ValidPriorityFor(Prio) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_PRIORITY); Exit; end;
  if KernelCaller then
  begin
    if (Attr and $80000000) = 0 then
      Attr := Attr and not Cardinal($F0000000);
  end
  else
  begin
    if (Attr and $070F9F00) <> 0 then
      begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR); Exit; end;
    Attr := (Attr and $00706000) or $80000000;
  end;
  if StackSize > $1E00000 then
    begin FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY); Exit; end;
  var ModuleId: Cardinal := 0;
  if FCurrent <> nil then
    ModuleId := FCurrent.ModuleId;
  var T := CreateThread(Name, Entry, Prio, StackSize, Attr, FCPU.Ctx.GPR[28], ModuleId);
  if T = nil then
    begin Spend(PSPCreateThreadNs); FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY); Exit; end;
  // Filling the stack is most of it, and other threads may run meanwhile.
  SpendPreemptible(PSPCreateThreadNs + Int64(AlignUp(StackSize, 256)) * 42 div 10);
  FHLE.Result(T.UID);
  // Creating a thread leaves dispatching enabled again.
  FDispatchSuspended := False;
  NotifyThreadEvent(PSPThreadEventCreate, T);
end;

procedure TPSPKernel.hStartThread;
begin
  if InInterrupt then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT); Exit; end;
  var Id := FHLE.Arg(0);
  if Id = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_THID); Exit; end;
  var T := TPSPThread(GetObject(Id, TPSPThread));
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  if not T.IsDormant then
    begin FHLE.Result(SCE_KERNEL_ERROR_NOT_DORMANT); Exit; end;
  var Size := FHLE.Arg(1);
  var Ptr := FHLE.Arg(2);
  if Ptr <> 0 then
  begin
    if (Integer(Size) < 0) or (not ValidUserAddress(Ptr) and not ((FCurrent <> nil) and FCurrent.IsKernel)) then
      begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR); Exit; end;
  end
  else
    Size := 0;
  Spend(PSPStartThreadNs);
  FHLE.Result(0);
  // Status bits other than dormant (a suspend) do not survive a start.
  T.Status := PSPThreadDormant;
  StartThread(T, Size, Ptr);
  NotifyThreadEvent(PSPThreadEventStart, T);
  // A better thread gets the CPU at once, ahead of anything else ready;
  // otherwise nothing is dispatched.
  FRescheduleNeeded := False;
  if (FCurrent <> nil) and (T.Priority < FCurrent.Priority) and not InInterrupt and FCPU.InterruptsEnabled then
  begin
    Spend(PSPFirstRunNs);
    SwitchTo(T);
  end;
end;

procedure TPSPKernel.hExitThread;
begin
  if (FCurrent = nil) or InInterrupt then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT); Exit; end;
  Spend(PSPExitThreadNs);
  var T := FCurrent;
  ExitCurrent(FHLE.Arg(0));
  if T.DeleteOnExit and (FCurrent = T) then
  begin
    T.Ctx := FCPU.Ctx;
    FCurrent := nil;
    DeleteThread(T);
    Reschedule;
  end;
end;

procedure TPSPKernel.hExitDeleteThread;
begin
  var T := FCurrent;
  if (T = nil) or InInterrupt then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT); Exit; end;
  Spend(PSPExitThreadNs);
  ExitCurrent(FHLE.Arg(0));
  T.Ctx := FCPU.Ctx;
  FCurrent := nil;
  DeleteThread(T);
  Reschedule;
end;

procedure TPSPKernel.hDeleteThread;
begin
  if InInterrupt then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT); Exit; end;
  var Id := FHLE.Arg(0);
  var T := ThreadById(Id);
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  if (T = FCurrent) or not T.IsDormant then
    begin FHLE.Result(SCE_KERNEL_ERROR_NOT_DORMANT); Exit; end;
  Spend(PSPDeleteThreadNs);
  DeleteThread(T);
  FHLE.Result(0);
end;

procedure TPSPKernel.hTerminateThread;
begin
  if InInterrupt then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT); Exit; end;
  var Id := FHLE.Arg(0);
  if (Id = 0) or ((FCurrent <> nil) and (Id = FCurrent.UID)) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_THID); Exit; end;
  var T := TPSPThread(GetObject(Id, TPSPThread));
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  Spend(PSPSyncCallNs);
  if T.IsDormant then
    begin FHLE.Result(SCE_KERNEL_ERROR_DORMANT); Exit; end;
  Spend(PSPTerminateThreadNs);
  TerminateThread(T, SCE_KERNEL_ERROR_THREAD_TERMINATED);
  FHLE.Result(0);
end;

procedure TPSPKernel.hTerminateDeleteThread;
begin
  if InInterrupt then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT); Exit; end;
  var Id := FHLE.Arg(0);
  if (Id = 0) or ((FCurrent <> nil) and (Id = FCurrent.UID)) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_THID); Exit; end;
  var T := TPSPThread(GetObject(Id, TPSPThread));
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  Spend(PSPTerminateThreadNs + PSPDeleteThreadNs);
  if not T.IsDormant then
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
  if (FCurrent = nil) or InInterrupt then
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
  if not ValidPriorityFor(P) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_PRIORITY); Exit; end;
  if T.IsDormant then
    begin FHLE.Result(SCE_KERNEL_ERROR_DORMANT); Exit; end;
  Spend(PSPSyncCallNs);
  FHLE.Result(0);
  if (T = FCurrent) and ((T.Status and PSPThreadRunning) <> 0) then
  begin
    // The running thread goes behind the others of its new priority.
    T.Priority := P;
    YieldCurrent;
    Exit;
  end;
  ChangePriority(T, P);
end;

procedure TPSPKernel.YieldCurrent;
begin
  var T := FCurrent;
  if (T = nil) or InInterrupt then
    Exit;
  var Best := BestReady;
  if (Best = nil) or (Best.Priority > T.Priority) then
    Exit;
  T.Ctx := FCPU.Ctx;
  T.Status := (T.Status and not PSPThreadRunning) or PSPThreadReady;
  PushReady(T, False);
  FCurrent := nil;
  SwitchTo(Best);
end;

procedure TPSPKernel.hRotateThreadReadyQueue;
begin
  var P := FHLE.ArgInt(0);
  if FCurrent = nil then
    begin FHLE.Result(0); Exit; end;
  if P = 0 then
    P := FCurrent.Priority;
  if not ValidPriorityFor(P) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_PRIORITY); Exit; end;
  FHLE.Result(0);
  if P = FCurrent.Priority then
    // The current thread goes behind the others of its priority.
    YieldCurrent
  else if FReady[P].Count > 1 then
  begin
    var T := FReady[P][0];
    FReady[P].Delete(0);
    FReady[P].Add(T);
    RequestReschedule;
  end;
end;

function ThreadInfoStatus(K: TPSPKernel; T: TPSPThread): Cardinal;
begin
  Result := T.Status;
  if T = K.Current then
    Result := (Result and not (PSPThreadReady or PSPThreadWaiting)) or PSPThreadRunning;
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
  var StructSize: Cardinal := $68;
  if FCompiledSdkVersion > $02060010 then
  begin
    StructSize := $6C;
    if Size > StructSize then
      begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_SIZE); Exit; end;
  end;
  var Buf: array[0..$6B] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var NameBytes := RawByteString(T.Name);
  if Length(NameBytes) > 31 then
    SetLength(NameBytes, 31);
  if NameBytes <> '' then
    Move(NameBytes[1], Buf[4], Length(NameBytes));
  PCardinal(@Buf[$24])^ := T.Attr;
  PCardinal(@Buf[$28])^ := ThreadInfoStatus(Self, T);
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
  PCardinal(@Buf[$5C])^ := T.IntrPreemptCount;
  PCardinal(@Buf[$60])^ := T.PreemptCount;
  PCardinal(@Buf[$64])^ := T.ReleaseCount;
  WriteInfo(P, Buf, StructSize);
  FHLE.Result(0);
end;

procedure TPSPKernel.hReferThreadRunStatus;
begin
  var T := ThreadById(FHLE.Arg(0));
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  var P := FHLE.Arg(1);
  if P = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR); Exit; end;
  var Buf: array[0..$2B] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  PCardinal(@Buf[4])^ := ThreadInfoStatus(Self, T);
  PCardinal(@Buf[8])^ := Cardinal(T.Priority);
  if T.IsWaiting then
  begin
    PCardinal(@Buf[12])^ := Cardinal(T.Wait.Kind);
    PCardinal(@Buf[16])^ := T.Wait.Id;
  end;
  PCardinal(@Buf[20])^ := Cardinal(T.WakeupCount);
  PUInt64(@Buf[24])^ := UInt64(T.RunClocks);
  PCardinal(@Buf[32])^ := T.IntrPreemptCount;
  PCardinal(@Buf[36])^ := T.PreemptCount;
  PCardinal(@Buf[40])^ := T.ReleaseCount;
  WriteInfo(P, Buf, $2C);
  FHLE.Result(0);
end;

procedure TPSPKernel.hGetThreadExitStatus;
begin
  var T := TPSPThread(GetObject(FHLE.Arg(0), TPSPThread));
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  if not T.IsDormant then
    begin FHLE.Result(SCE_KERNEL_ERROR_NOT_DORMANT); Exit; end;
  FHLE.Result(T.ExitStatus);
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
  if RefuseWait then
    Exit;
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
  if RefuseWait then
    Exit;
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
  if T.IsDormant then
    begin FHLE.Result(SCE_KERNEL_ERROR_DORMANT); Exit; end;
  Spend(PSPSyncCallNs);
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

procedure TPSPKernel.hDonateWakeupThread;
begin
  var T := ThreadById(FHLE.Arg(0));
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  if T.IsDormant then
    begin FHLE.Result(SCE_KERNEL_ERROR_DORMANT); Exit; end;
  FHLE.Result(0);
  if T.IsWaiting and (T.Wait.Kind = PSPWaitSleep) then
    EndWait(T, 0)
  else
    Inc(T.WakeupCount);
end;

procedure TPSPKernel.hSuspendThread;
begin
  var Id := FHLE.Arg(0);
  if (Id = 0) or ((FCurrent <> nil) and (Id = FCurrent.UID)) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_THID); Exit; end;
  var T := TPSPThread(GetObject(Id, TPSPThread));
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  if T.IsDormant then
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
  var Id := FHLE.Arg(0);
  if (Id = 0) or ((FCurrent <> nil) and (Id = FCurrent.UID)) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_THID); Exit; end;
  var T := TPSPThread(GetObject(Id, TPSPThread));
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
  Result := (Target = nil) or not FObjects.ContainsKey(T.Wait.Id) or Target.IsDormant;
  if Result then
  begin
    if (Target <> nil) and FObjects.ContainsKey(T.Wait.Id) then
      T.SetResult(Target.ExitStatus)
    else
      T.SetResult(SCE_KERNEL_ERROR_WAIT_DELETE);
  end;
end;

procedure WaitThreadEndCommon(K: TPSPKernel; AllowCB: Boolean);
begin
  var H := K.FHLE;
  var Id := H.Arg(0);
  if (Id = 0) or ((K.FCurrent <> nil) and (Id = K.FCurrent.UID)) then
    begin H.Result(SCE_KERNEL_ERROR_ILLEGAL_THID); Exit; end;
  var T := TPSPThread(K.GetObject(Id, TPSPThread));
  if T = nil then
    begin H.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  if K.RefuseWait then
    Exit;
  if T.IsDormant then
  begin
    H.Result(T.ExitStatus);
    if AllowCB then
      K.CheckCallbacksNow;
    Exit;
  end;
  T.EndWaiters.Add(K.FCurrent);
  K.FWaitCheckNs := PSPThreadEndCheckNs;
  K.BeginWait(PSPWaitThreadEnd, T, Id, H.Arg(1), AllowCB, K.ThreadEndRetry);
end;

procedure TPSPKernel.hWaitThreadEnd;
begin
  WaitThreadEndCommon(Self, False);
end;

procedure TPSPKernel.hWaitThreadEndCB;
begin
  WaitThreadEndCommon(Self, True);
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
  if RefuseWait then
    Exit;
  if Assigned(FOnSyncTime) then
    FOnSyncTime();
  if Microseconds < 0 then
    Microseconds := 0;
  var T := FCurrent;
  var Check: Int64 := PSPDelayCheckNs;
  var WasFresh := T.Fresh;
  if WasFresh then
    Check := PSPFreshCheckNs;
  T.Fresh := False;
  // A delay that is over by the time the kernel looks returns at once.
  if (FScheduler.Now + Check) div 1000 > FScheduler.Now div 1000 + Microseconds then
  begin
    if AllowCB then
      CheckCallbacksNow;
    Exit;
  end;
  var Us := Microseconds;
  if Us < PSPMinTimeoutUs then
    Us := PSPMinTimeoutUs;
  var Deadline := FScheduler.Now + Us * 1000 + PSPDelayLatencyNs;
  BeginWait(PSPWaitDelay, nil, 0, 0, AllowCB, DelayRetry);
  if T.Wait.Kind = PSPWaitDelay then
  begin
    SetWaitDeadline(T, Deadline);
    if WasFresh then
      Spend(PSPFreshBlockNs);
  end
  else if T.Frames.Count > 0 then
  begin
    // Callbacks started first; the saved wait carries the deadline.
    var F := T.Frames.Last;
    F.SavedWait.Deadline := Deadline;
    T.Frames[T.Frames.Count - 1] := F;
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
  var Id := FHLE.Arg(0);
  if (Id = 0) or ((FCurrent <> nil) and (Id = FCurrent.UID)) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_THID); Exit; end;
  var T := TPSPThread(GetObject(Id, TPSPThread));
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  if not T.IsWaiting then
    begin FHLE.Result(SCE_KERNEL_ERROR_NOT_WAIT); Exit; end;
  Inc(T.ReleaseCount);
  Spend(PSPSyncCallNs);
  FHLE.Result(0);
  var Obj := T.Wait.Obj;
  EndWait(T, SCE_KERNEL_ERROR_RELEASE_WAIT);
  if Obj <> nil then
    Obj.WaiterGone;
end;

procedure TPSPKernel.hGetThreadStackFreeSize;
begin
  var T := ThreadById(FHLE.Arg(0));
  if T = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  // Counted from above the id word block at the bottom of the stack.
  var N: Cardinal := 0;
  while (N + $10 < T.StackSize) and (FMemory.Read8(T.StackBlock + $10 + N) = $FF) do
    Inc(N);
  FHLE.Result(N);
end;

procedure TPSPKernel.hCheckThreadStack;
begin
  if FCurrent = nil then
    begin FHLE.Result(0); Exit; end;
  var SP := FCPU.Ctx.GPR[29];
  if (SP >= FCurrent.StackBlock) and (SP <= FCurrent.StackBlock + FCurrent.StackSize) then
    FHLE.Result(SP - FCurrent.StackBlock)
  else
    FHLE.Result(0);
end;

procedure TPSPKernel.hExtendThreadStack;
begin
  var T := FCurrent;
  var Size := FHLE.Arg(0);
  var Func := FHLE.Arg(1);
  var Arg := FHLE.Arg(2);
  if (T = nil) or InInterrupt then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT); Exit; end;
  if Size < $200 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_STACK_SIZE); Exit; end;
  if Size > $1E00000 then
    begin FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY); Exit; end;
  Size := AlignUp(Size, 256);
  var Block := T.StackPartition.Alloc(Size, akHigh, 0, 256, 'stack ext:' + T.Name);
  if Block = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY); Exit; end;
  FMemory.Fill(Block, $FF, Size);
  FMemory.Write32(Block, T.UID);
  var OldBlock := T.StackBlock;
  var OldSize := T.StackSize;
  T.ExtraStacks.Add(Block);
  T.StackBlock := Block;
  T.StackSize := Size;
  var K := Self;
  var F := Default(TPSPFrame);
  F.Kind := fkHLE;
  F.Saved := FCPU.Ctx;
  F.OnReturn := procedure(Value: Cardinal)
    begin
      T.StackBlock := OldBlock;
      T.StackSize := OldSize;
      T.ExtraStacks.Remove(Block);
      T.StackPartition.FreeBlock(Block);
      K.CPU.Ctx.GPR[2] := Value;
    end;
  T.Frames.Add(F);
  EnterGuest(Func, Block + Size - 64, 0, [Arg]);
end;

procedure TPSPKernel.hChangeCurrentThreadAttr;
begin
  if (FCurrent = nil) or InInterrupt then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT); Exit; end;
  var Clear := FHLE.Arg(0);
  var SetBits := FHLE.Arg(1);
  if ((Clear or SetBits) and not Cardinal($00004000)) <> 0 then
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
  if not (((Kind >= 1) and (Kind <= 14)) or ((Kind >= $40) and (Kind <= $43))) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_TYPE); Exit; end;
  if Size < 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR); Exit; end;
  var Ids := TList<Cardinal>.Create;
  try
    if Kind >= $40 then
    begin
      for var T in FThreads do
        case Kind of
          $40: if T.IsWaiting and (T.Wait.Kind = PSPWaitSleep) then Ids.Add(T.UID);
          $41: if T.IsWaiting and (T.Wait.Kind = PSPWaitDelay) then Ids.Add(T.UID);
          $42: if (T.Status and PSPThreadSuspended) <> 0 then Ids.Add(T.UID);
          $43: if T.IsDormant then Ids.Add(T.UID);
        end;
    end
    else
    begin
      var Keys := FObjects.Keys.ToArray;
      TArray.Sort<Cardinal>(Keys);
      for var K in Keys do
        if FObjects[K].IdType = Kind then
          Ids.Add(K);
    end;
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
  if InInterrupt then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT); Exit; end;
  if not FCPU.InterruptsEnabled then
    begin FHLE.Result(SCE_KERNEL_ERROR_CPUDI); Exit; end;
  FHLE.Result(Ord(not FDispatchSuspended));
  FDispatchSuspended := True;
end;

procedure TPSPKernel.hResumeDispatchThread;
begin
  if InInterrupt then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT); Exit; end;
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
  var Buf: array[0..$1B] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  WriteInfo(P, Buf, $1C);
  FHLE.Result(0);
end;

procedure TPSPKernel.hReferThreadProfiler;
begin
  FHLE.Result(0);
end;

{ HLE: callbacks }

procedure TPSPKernel.hCreateCallback;
begin
  if (FCurrent = nil) or InInterrupt then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT); Exit; end;
  var Name: string;
  if not ReadName(FHLE.Arg(0), Name) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ERROR); Exit; end;
  var Func := FHLE.Arg(1);
  // Only a kernel address is refused.
  if ((Func and $80000000) <> 0) and not FCurrent.IsKernel then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR); Exit; end;
  var CB := TPSPCallback.Create;
  CB.Name := Name;
  CB.Func := Func;
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
  // Getting a waiting thread to its callbacks takes the kernel a while.
  var T := CB.Thread;
  if (T <> nil) and (T <> FCurrent) and T.IsWaiting and T.Wait.AllowCB and not T.CallbacksPending then
    Spend(PSPNotifyWakeNs);
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
  if InInterrupt or (FCurrent = nil) then
    Exit;
  if FCurrent.InCallback then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT); Exit; end;
  CheckCallbacksNow(False);
end;

procedure TPSPKernel.hReferCallbackStatus;
begin
  var CB := TPSPCallback(GetObject(FHLE.Arg(0), TPSPCallback));
  if CB = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_CBID); Exit; end;
  var Buf: array[0..$37] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var N := RawByteString(CB.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  if CB.Thread <> nil then
    PCardinal(@Buf[$24])^ := CB.Thread.UID;
  PCardinal(@Buf[$28])^ := CB.Func;
  PCardinal(@Buf[$2C])^ := CB.Common;
  PCardinal(@Buf[$30])^ := CB.NotifyCount;
  PCardinal(@Buf[$34])^ := CB.NotifyArg;
  WriteInfo(FHLE.Arg(1), Buf, $38);
  FHLE.Result(0);
end;
