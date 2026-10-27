{ PSP.Kernel: objects, queues, scheduler, waits, timers, guest calls. }

const
  // Time the thread manager spends (ns) where a test on hardware can see it.
  PSPSwitchNs = 4000;
  // A timeout never fires sooner than this after the call, and the woken thread
  // gets the CPU a little later still.
  PSPMinTimeoutUs = 205;
  PSPWaitLatencyNs = 28300;
  PSPDelayLatencyNs = 18400;
  // How far into a wait or delay call the kernel checks whether the time asked
  // for has already passed (then it returns at once, without blocking).
  PSPWaitCheckNs = 1700;
  PSPDelayCheckNs = 500;
  PSPFreshCheckNs = 1500;
  // The rest of that slower path, after the check, before the thread is off
  // the CPU.
  PSPFreshBlockNs = 20000;
  PSPPipeCheckNs = 2900;
  PSPThreadEndCheckNs = 2000;
  // Thread manager call costs (ns) as a test on hardware measures them.
  PSPCreateThreadNs = 185000;
  PSPStartThreadNs = 15000;
  PSPFirstRunNs = 13000;
  PSPExitThreadNs = 13000;
  PSPDeleteThreadNs = 65000;
  PSPTerminateThreadNs = 10000;
  PSPSyncCallNs = 2500;
  // Long calls are spent in slices this long.
  PSPBusyChunkNs = 10000;
  PSPBusyResumeNs = 20000;
  PSPNotifyWakeNs = 8000;
  // Leaving an interrupt that ran a handler, and handing the CPU to another
  // thread from there.
  PSPIntrExitNs = 30000;
  PSPIntrDispatchNs = 14000;
  // Thread event handler kinds.
  PSPThreadEventCreate = 1;
  PSPThreadEventStart = 2;
  PSPThreadEventExit = 4;
  PSPThreadEventDelete = 8;

function PSPThreadName(T: TPSPThread): string;
begin
  if T = nil then
    Result := '(idle)'
  else
    Result := Format('%s(%x)', [T.Name, T.UID]);
end;

{ TPSPKernelObject }

class function TPSPKernelObject.IdType: Integer;
begin
  Result := 0;
end;

procedure TPSPKernelObject.RemoveWaiter(T: TPSPThread);
begin
end;

procedure TPSPKernelObject.AddWaiter(T: TPSPThread);
begin
end;

procedure TPSPKernelObject.WaiterGone;
begin
end;

destructor TPSPKernelObject.Destroy;
begin
  inherited;
end;

class function TPSPCallback.IdType: Integer;
begin
  Result := 8;
end;

{ TPSPWaitQueue }

constructor TPSPWaitQueue.Create(ByPriority: Boolean);
begin
  inherited Create;
  FItems := TList<TPSPThread>.Create;
  FByPriority := ByPriority;
end;

destructor TPSPWaitQueue.Destroy;
begin
  FItems.Free;
  inherited;
end;

procedure TPSPWaitQueue.Add(T: TPSPThread);
begin
  if FItems.Contains(T) then
    Exit;
  if FByPriority then
  begin
    for var I := 0 to FItems.Count - 1 do
      if FItems[I].Priority > T.Priority then
      begin
        FItems.Insert(I, T);
        Exit;
      end;
  end;
  FItems.Add(T);
end;

procedure TPSPWaitQueue.Remove(T: TPSPThread);
begin
  FItems.Remove(T);
end;

function TPSPWaitQueue.First: TPSPThread;
begin
  if FItems.Count = 0 then
    Result := nil
  else
    Result := FItems[0];
end;

function TPSPWaitQueue.Count: Integer;
begin
  Result := FItems.Count;
end;

function TPSPWaitQueue.Item(I: Integer): TPSPThread;
begin
  Result := FItems[I];
end;

function TPSPWaitQueue.Contains(T: TPSPThread): Boolean;
begin
  Result := FItems.Contains(T);
end;

procedure TPSPWaitQueue.Clear;
begin
  FItems.Clear;
end;

{ TPSPWaitObject }

constructor TPSPWaitObject.Create;
begin
  inherited Create;
  Waiters := TPSPWaitQueue.Create(False);
end;

destructor TPSPWaitObject.Destroy;
begin
  Waiters.Free;
  inherited;
end;

procedure TPSPWaitObject.RemoveWaiter(T: TPSPThread);
begin
  Waiters.Remove(T);
end;

procedure TPSPWaitObject.AddWaiter(T: TPSPThread);
begin
  Waiters.Add(T);
end;

{ TPSPThread }

constructor TPSPThread.Create;
begin
  inherited Create;
  Callbacks := TList<TPSPCallback>.Create;
  Frames := TList<TPSPFrame>.Create;
  EndWaiters := TList<TPSPThread>.Create;
  ExtraStacks := TList<Cardinal>.Create;
end;

destructor TPSPThread.Destroy;
begin
  ExtraStacks.Free;
  EndWaiters.Free;
  Frames.Free;
  Callbacks.Free;
  inherited;
end;

class function TPSPThread.IdType: Integer;
begin
  Result := 1;
end;

procedure TPSPThread.RemoveWaiter(T: TPSPThread);
begin
  EndWaiters.Remove(T);
end;

procedure TPSPThread.AddWaiter(T: TPSPThread);
begin
  if not EndWaiters.Contains(T) then
    EndWaiters.Add(T);
end;

function TPSPThread.IsWaiting: Boolean;
begin
  Result := (Status and PSPThreadWaiting) <> 0;
end;

function TPSPThread.IsDormant: Boolean;
begin
  Result := (Status and PSPThreadDormant) <> 0;
end;

function TPSPThread.IsKernel: Boolean;
begin
  Result := (Attr and $80000000) = 0;
end;

procedure TPSPThread.SetResult(Value: Cardinal);
begin
  // A wait the thread is blocked in belongs to the level it runs at.
  if ((Status and PSPThreadWaiting) = 0) and (Frames.Count > 0) and (Frames.Last.Kind = fkCallback) and
    Frames.Last.WasWaiting then
  begin
    // The wait belongs to the context the callback frame restores.
    var F := Frames.Last;
    F.Saved.GPR[2] := Value;
    Frames[Frames.Count - 1] := F;
  end
  else if Kernel.Current = Self then
    Kernel.CPU.Ctx.GPR[2] := Value
  else
    Ctx.GPR[2] := Value;
end;

function TPSPThread.HasPendingCallbacks: Boolean;
begin
  for var CB in Callbacks do
    if CB.NotifyCount > 0 then
      Exit(True);
  Result := False;
end;

function TPSPThread.InCallback: Boolean;
begin
  Result := CallbackDepth > 0;
end;

function TPSPThread.CallbackDepth: Integer;
begin
  Result := 0;
  for var F in Frames do
    if F.Kind = fkCallback then
      Inc(Result);
end;

{ TPSPKernel }

constructor TPSPKernel.Create(CPU: TPSPCPU; Memory: TPSPMemory; HLE: TPSPHLE; Scheduler: TPSPScheduler);
begin
  inherited Create;
  FCPU := CPU;
  FMemory := Memory;
  FHLE := HLE;
  FScheduler := Scheduler;
  FObjects := TDictionary<Cardinal, TPSPKernelObject>.Create;
  FBlocks := TDictionary<Cardinal, TPSPKernelObject>.Create;
  for var I := 0 to 127 do
    FReady[I] := TList<TPSPThread>.Create;
  FThreads := TList<TPSPThread>.Create;
  FTimers := TList<TPSPTimer>.Create;
  FIntFrames := TList<TPSPFrame>.Create;
  FPendingInts := TQueue<TPSPPendingInterrupt>.Create;
  FVolatileWaiters := TList<TPSPThread>.Create;
  FEventHandlers := TList<TPSPKernelObject>.Create;
  FKernelPartition := TPSPPartition.Create(1, $08000000, $00400000);
  FVolatilePartition := TPSPPartition.Create(5, $08400000, $00400000);
  FUserPartition := TPSPPartition.Create(2, PSPUserBase, PSPUserEnd - PSPUserBase);
  // User thread stacks come from the memory above the user partition.
  FStackPartition := TPSPPartition.Create(2, $0A000000, $01E00000);
  FDebugOut := TStringBuilder.Create;
  Reset;
end;

destructor TPSPKernel.Destroy;
begin
  for var O in FObjects.Values do
    O.Free;
  FObjects.Free;
  FBlocks.Free;
  for var I := 0 to 127 do
    FReady[I].Free;
  FThreads.Free;
  FTimers.Free;
  FIntFrames.Free;
  FPendingInts.Free;
  FVolatileWaiters.Free;
  FEventHandlers.Free;
  FKernelPartition.Free;
  FVolatilePartition.Free;
  FUserPartition.Free;
  FStackPartition.Free;
  FDebugOut.Free;
  inherited;
end;

procedure TPSPKernel.Reset;
begin
  for var O in FObjects.Values do
    O.Free;
  FObjects.Clear;
  FBlocks.Clear;
  for var I := 0 to 127 do
    FReady[I].Clear;
  FThreads.Clear;
  FTimers.Clear;
  FIntFrames.Clear;
  FPendingInts.Clear;
  FVolatileWaiters.Clear;
  FEventHandlers.Clear;
  FillChar(FSubIntr, SizeOf(FSubIntr), 0);
  FillChar(FIntrHandlers, SizeOf(FIntrHandlers), 0);
  // Audio, DMA, GE, VBlank, ME and the last one belong to firmware drivers.
  for var I in [10, 21, 25, 30, 31, 67] do
  begin
    FIntrHandlers[I].Handler := $88000000;
    FIntrHandlers[I].Enabled := True;
  end;
  FCurrent := nil;
  FNextUID := $00100001;
  FTimerSeq := 0;
  FThreadSeq := 0;
  FRescheduleNeeded := False;
  FDispatchSuspended := False;
  FIntrSuspendLevel := 0;
  FExited := False;
  FExitCallback := 0;
  FCompiledSdkVersion := 0;
  FCompilerVersion := 0;
  FSdkVersionSet := False;
  FVolatileLocked := False;
  FTlsplCount := 0;
  FIdle := True;
  FDebugOut.Clear;
  FKernelPartition.Reset;
  FVolatilePartition.Reset;
  FUserPartition.Reset;
  FStackPartition.Reset;
  FTrapBase := FKernelPartition.Alloc($100, akLow, 0, 256, 'traps');
  // Return trap, thread exit trap.
  FMemory.Write32(FTrapBase + 0, (PSPTrapReturn shl 6) or $0C);
  FMemory.Write32(FTrapBase + 4, 0);
  FMemory.Write32(FTrapBase + 8, (PSPTrapThreadExit shl 6) or $0C);
  FMemory.Write32(FTrapBase + 12, 0);
  FIntStack := FKernelPartition.Alloc($10000, akLow, 0, 256, 'interrupt stack') + $10000;
  // The first 16 KB of user memory belong to the kernel on hardware.
  FUserPartition.Alloc($4000, akAddress, PSPUserBase, 256, 'reserved');
  // The recording setup (PSPLink) keeps about 280 KB near the top of user
  // memory, under a 2 KB hole.
  FUserPartition.Alloc($45800, akAddress, PSPUserEnd - $46000, 256, 'psplink');
  // The two idle threads have ids of their own.
  FIdleThreadIds[0] := FNextUID;
  Inc(FNextUID, 2);
  FIdleThreadIds[1] := FNextUID;
  Inc(FNextUID, 2);
  FScheduler.Cancel(TPSPEvent.Kernel);
  FHLE.Clear;
  RegisterAll;
  FHLE.Register('PSPKernelInternal', $00000001, 'kernel busy', hKernelBusy);
  FBusyStub := FTrapBase + $10;
  FMemory.Write32(FBusyStub, (Cardinal(FHLE.Find('PSPKernelInternal', $00000001)) shl 6) or $0C);
  FMemory.Write32(FBusyStub + 4, 0);
end;

procedure TPSPKernel.ScrambleCallerSaved;
begin
  var C := PPSPContext(@FCPU.Ctx);
  C.GPR[1] := $DEADBEEF;
  for var I := 4 to 15 do
    C.GPR[I] := $DEADBEEF;
  C.GPR[24] := $DEADBEEF;
  C.GPR[25] := $DEADBEEF;
  C.HI := $DEADBEEF;
  C.LO := $DEADBEEF;
end;

procedure TPSPKernel.SpendPreemptible(Ns: Int64);
begin
  var T := FCurrent;
  if (T = nil) or InInterrupt or (Ns <= PSPBusyChunkNs) then
  begin
    Spend(Ns);
    Exit;
  end;
  // The call returns through a stub that spends the time a slice at a time.
  T.BusyNs := Ns;
  T.BusyAt := FScheduler.Now;
  T.BusyPC := FCPU.Ctx.PC;
  T.BusyNPC := FCPU.Ctx.NPC;
  FCPU.Ctx.PC := FBusyStub;
  FCPU.Ctx.NPC := FBusyStub + 4;
end;

procedure TPSPKernel.hKernelBusy;
begin
  // Registers stay as the call left them.
  var T := FCurrent;
  if T = nil then
    Exit;
  // Taken off the CPU in the middle, the call costs more to pick up again.
  if FScheduler.Now > T.BusyAt + 2000 then
    Spend(PSPBusyResumeNs);
  var Chunk := T.BusyNs;
  if Chunk > PSPBusyChunkNs then
    Chunk := PSPBusyChunkNs;
  Dec(T.BusyNs, Chunk);
  Spend(Chunk - Int64(FHLE.CycleCost) * 1000 div FScheduler.MHz);
  T.BusyAt := FScheduler.Now;
  if T.BusyNs > 0 then
  begin
    FCPU.Ctx.PC := FBusyStub;
    FCPU.Ctx.NPC := FBusyStub + 4;
  end
  else
  begin
    FCPU.Ctx.PC := T.BusyPC;
    FCPU.Ctx.NPC := T.BusyNPC;
  end;
end;

function TPSPKernel.AddObject(Obj: TPSPKernelObject): Cardinal;
begin
  Obj.Kernel := Self;
  Obj.UID := FNextUID;
  Inc(FNextUID, 2);
  FObjects.Add(Obj.UID, Obj);
  Result := Obj.UID;
end;

procedure TPSPKernel.DeleteObject(Obj: TPSPKernelObject);
begin
  FObjects.Remove(Obj.UID);
  CancelTimersOf(Obj);
  Obj.Free;
end;

function TPSPKernel.GetObject(UID: Cardinal; Cls: TPSPKernelObjectClass): TPSPKernelObject;
begin
  if not FObjects.TryGetValue(UID, Result) then
    Exit(nil);
  if (Cls <> nil) and not (Result is Cls) then
    Result := nil;
end;

function TPSPKernel.ThreadById(UID: Cardinal): TPSPThread;
begin
  if UID = 0 then
    Exit(FCurrent);
  Result := TPSPThread(GetObject(UID, TPSPThread));
end;

function TPSPKernel.NowUs: Int64;
begin
  if Assigned(FOnSyncTime) then
    FOnSyncTime();
  Result := FScheduler.Now div 1000;
end;

procedure TPSPKernel.Spend(Ns: Int64);
begin
  if Ns <= 0 then
    Exit;
  FCPU.AddCycles(Integer((Ns * FScheduler.MHz + 999) div 1000));
  if Assigned(FOnSyncTime) then
    FOnSyncTime();
end;

function TPSPKernel.ReadName(Ptr: Cardinal; out Name: string): Boolean;
begin
  Name := '';
  if Ptr = 0 then
    Exit(False);
  Name := FMemory.ReadString(Ptr, 31);
  Result := True;
end;

function TPSPKernel.ValidUserAddress(Address: Cardinal): Boolean;
begin
  var A := Address and $3FFFFFFF;
  Result := ((A >= $08800000) and (A < $0C000000)) or ((A >= $04000000) and (A < $04800000)) or
    ((A >= $00010000) and (A < $00014000));
  if (Address and $80000000) <> 0 then
    Result := False;
end;

function TPSPKernel.WriteInfo(Ptr: Cardinal; const Buf; StructSize: Cardinal): Boolean;
begin
  // Refer* calls: a size of 0 leaves the struct alone; otherwise up to the
  // real size is written and the size field says what the struct is.
  Result := True;
  if Ptr = 0 then
    Exit(False);
  var Size := FMemory.Read32(Ptr);
  if Size = 0 then
    Exit;
  var Tmp: TBytes;
  SetLength(Tmp, StructSize);
  Move(Buf, Tmp[0], StructSize);
  PCardinal(@Tmp[0])^ := StructSize;
  if Size > StructSize then
    Size := StructSize;
  FMemory.WriteBytes(Ptr, Tmp[0], Size);
end;

{ Ready queue }

procedure TPSPKernel.PushReady(T: TPSPThread; Front: Boolean);
begin
  var Q := FReady[T.Priority and 127];
  Q.Remove(T);
  if Front then
    Q.Insert(0, T)
  else
    Q.Add(T);
end;

procedure TPSPKernel.RemoveReady(T: TPSPThread);
begin
  FReady[T.Priority and 127].Remove(T);
end;

function TPSPKernel.BestReady: TPSPThread;
begin
  for var P := 0 to 127 do
    if FReady[P].Count > 0 then
      Exit(FReady[P][0]);
  Result := nil;
end;

procedure TPSPKernel.RequestReschedule;
begin
  FRescheduleNeeded := True;
end;

function TPSPKernel.InInterrupt: Boolean;
begin
  Result := FIntFrames.Count > 0;
end;

function TPSPKernel.HasRunnable: Boolean;
begin
  Result := (FCurrent <> nil) or (FIntFrames.Count > 0);
end;

function TPSPKernel.CanWait: Boolean;
begin
  Result := (FCurrent <> nil) and not InInterrupt and not FDispatchSuspended and FCPU.InterruptsEnabled;
end;

function TPSPKernel.RefuseWait: Boolean;
begin
  // A call that may block is turned away before it looks at anything else.
  Result := True;
  if InInterrupt or (FCurrent = nil) then
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT)
  else if not CanWait then
    FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT)
  else
    Result := False;
end;

procedure TPSPKernel.T_(const Fmt: string; const Args: array of const);
begin
  if FTrace then
    FHLE.Log('%d %s: %s', [FScheduler.Now div 1000, PSPThreadName(FCurrent), Format(Fmt, Args)]);
end;

procedure TPSPKernel.SwitchTo(T: TPSPThread);
begin
  if (T = FCurrent) and (T <> nil) then
    Exit;
  if FTrace then
    T_('switch to %s (pending cb %s)', [PSPThreadName(T), BoolToStr((T <> nil) and T.CallbacksPending, True)]);
  if FCurrent <> nil then
  begin
    FCurrent.Ctx := FCPU.Ctx;
    if (FCurrent.Status and PSPThreadRunning) <> 0 then
    begin
      // Preempted while running: it stays first in its priority.
      FCurrent.Status := (FCurrent.Status and not PSPThreadRunning) or PSPThreadReady;
      Inc(FCurrent.PreemptCount);
      PushReady(FCurrent, True);
    end;
  end;
  FCurrent := T;
  if T <> nil then
  begin
    RemoveReady(T);
    T.Status := (T.Status and not PSPThreadReady) or PSPThreadRunning;
    FCPU.Ctx := T.Ctx;
    FIdle := False;
    Spend(PSPSwitchNs);
    if T.CallbacksPending then
    begin
      T.CallbacksPending := False;
      StartCallbacks(T);
    end;
  end
  else
  begin
    FIdle := True;
    FCPU.Stop;
  end;
end;

procedure TPSPKernel.DispatchThread(T: TPSPThread);
begin
  SwitchTo(T);
end;

procedure TPSPKernel.Reschedule;
begin
  if InInterrupt then
  begin
    FRescheduleNeeded := True;
    Exit;
  end;
  // Switching to a thread can run its callbacks, which may settle it back
  // into its wait: then choose again.
  var Rounds := 0;
  repeat
    FRescheduleNeeded := False;
    Inc(Rounds);
    var Running := (FCurrent <> nil) and ((FCurrent.Status and PSPThreadRunning) <> 0);
    // No dispatch while the running thread has interrupts or dispatch off.
    if Running and (FDispatchSuspended or not FCPU.InterruptsEnabled) then
      Exit;
    var Best := BestReady;
    if Running then
    begin
      if (Best <> nil) and (Best.Priority < FCurrent.Priority) then
        SwitchTo(Best);
    end
    else
    begin
      if FCurrent <> nil then
      begin
        FCurrent.Ctx := FCPU.Ctx;
        FCurrent := nil;
      end;
      SwitchTo(Best);
    end;
  until not FRescheduleNeeded or InInterrupt or (Rounds > 256);
end;

procedure TPSPKernel.AfterSyscall;
begin
  if FRescheduleNeeded then
    Reschedule;
end;

{ Waits }

function TPSPKernel.WaitDeadline(TimeoutPtr: Cardinal; out TimeoutEnd: Int64): Int64;
begin
  TimeoutEnd := PSPNever;
  if TimeoutPtr = 0 then
    Exit(PSPNever);
  var Us := Int64(FMemory.Read32(TimeoutPtr));
  TimeoutEnd := FScheduler.Now + Us * 1000;
  if Us < PSPMinTimeoutUs then
    Us := PSPMinTimeoutUs;
  Result := FScheduler.Now + Us * 1000;
end;

procedure TPSPKernel.BeginWait(Kind: Integer; Obj: TPSPKernelObject; Id, TimeoutPtr: Cardinal; AllowCB: Boolean;
  Retry: TPSPWaitRetry; Abort: TPSPWaitAbort; const Tag: string);
begin
  BeginWaitData(Kind, Obj, Id, TimeoutPtr, AllowCB, Retry, [], Abort, Tag);
end;

function TPSPKernel.BeginWaitData(Kind: Integer; Obj: TPSPKernelObject; Id, TimeoutPtr: Cardinal; AllowCB: Boolean;
  Retry: TPSPWaitRetry; const Data: array of Cardinal; Abort: TPSPWaitAbort; const Tag: string): Boolean;
begin
  var T := FCurrent;
  if T = nil then
    raise EPSPError.Create('PSP: wait without a current thread');
  if Assigned(FOnSyncTime) then
    FOnSyncTime();
  if FTrace then
    T_('wait kind %d id %x cb %s %s', [Kind, Id, BoolToStr(AllowCB, True), Tag]);
  Result := True;
  T.Wait := Default(TPSPWait);
  T.Wait.Kind := Kind;
  T.Wait.Obj := Obj;
  T.Wait.Id := Id;
  T.Wait.TimeoutPtr := TimeoutPtr;
  T.Wait.AllowCB := AllowCB;
  T.Wait.Retry := Retry;
  T.Wait.Abort := Abort;
  T.Wait.HLETag := Tag;
  for var I := 0 to High(Data) do
    if I <= High(T.Wait.Data) then
      T.Wait.Data[I] := Data[I];
  var Check: Int64 := PSPWaitCheckNs;
  if FWaitCheckNs <> 0 then
    Check := FWaitCheckNs;
  FWaitCheckNs := 0;
  var WasFresh := T.Fresh;
  if WasFresh then
    Check := PSPFreshCheckNs;
  T.Fresh := False;
  if (TimeoutPtr <> 0) and ((FScheduler.Now + Check) div 1000 > FScheduler.Now div 1000 + Int64(FMemory.Read32(TimeoutPtr))) then
  begin
    // A timeout that has run out by the time the kernel looks at it ends the
    // wait at once, without writing the time left back.
    if Obj <> nil then
      Obj.RemoveWaiter(T);
    T.SetResult(SCE_KERNEL_ERROR_WAIT_TIMEOUT);
    if Assigned(Abort) then
      Abort(T);
    T.Wait := Default(TPSPWait);
    if AllowCB then
      CheckCallbacksNow;
    Exit(False);
  end;
  T.Wait.Deadline := WaitDeadline(TimeoutPtr, T.Wait.TimeoutEnd);
  T.Status := (T.Status and not PSPThreadRunning) or PSPThreadWaiting;
  if T.Wait.Deadline <> PSPNever then
    SetWaitDeadline(T, T.Wait.Deadline);
  if AllowCB and T.HasPendingCallbacks and (T.CallbackDepth < 2) then
  begin
    // Callbacks run before the thread settles into its wait.
    T.Status := (T.Status and not PSPThreadWaiting) or PSPThreadRunning;
    StartCallbacks(T);
    Exit;
  end;
  if WasFresh then
    Spend(PSPFreshBlockNs);
  RequestReschedule;
end;

procedure TPSPKernel.SetWaitData(T: TPSPThread; Index: Integer; Value: Cardinal);
begin
  if T.Wait.Kind <> PSPWaitNone then
    T.Wait.Data[Index] := Value
  else if (T.Frames.Count > 0) and T.Frames.Last.WasWaiting then
  begin
    var F := T.Frames.Last;
    F.SavedWait.Data[Index] := Value;
    T.Frames[T.Frames.Count - 1] := F;
  end;
end;

procedure TPSPKernel.DropWaitTimer(T: TPSPThread);
begin
  var Changed := False;
  for var I := FTimers.Count - 1 downto 0 do
    if (FTimers[I].Kind = tkWait) and (FTimers[I].Thread = T) then
    begin
      FTimers.Delete(I);
      Changed := True;
    end;
  if Changed then
    ScheduleTimerEvent;
end;

procedure TPSPKernel.SetWaitDeadline(T: TPSPThread; Deadline: Int64);
begin
  for var I := FTimers.Count - 1 downto 0 do
    if (FTimers[I].Kind = tkWait) and (FTimers[I].Thread = T) then
      FTimers.Delete(I);
  T.Wait.Deadline := Deadline;
  if Deadline = PSPNever then
  begin
    ScheduleTimerEvent;
    Exit;
  end;
  var E := Default(TPSPTimer);
  E.At := Deadline;
  Inc(FTimerSeq);
  E.Seq := FTimerSeq;
  E.Kind := tkWait;
  E.Thread := T;
  var I := FTimers.Count;
  while (I > 0) and (FTimers[I - 1].At > Deadline) do
    Dec(I);
  FTimers.Insert(I, E);
  ScheduleTimerEvent;
end;

procedure TPSPKernel.WriteRemaining(T: TPSPThread);
begin
  if T.Wait.TimeoutPtr = 0 then
    Exit;
  if T.Wait.TimeoutEnd = PSPNever then
    Exit;
  var Left := (T.Wait.TimeoutEnd - FScheduler.Now) div 1000;
  if Left < 0 then
    Left := 0;
  FMemory.Write32(T.Wait.TimeoutPtr, Cardinal(Left));
end;

procedure TPSPKernel.EndWait(T: TPSPThread; Result: Cardinal);
begin
  if FTrace then
    T_('end wait of %s kind %d result %.8x status %x', [PSPThreadName(T), T.Wait.Kind, Result, T.Status]);
  if (T.Status and PSPThreadWaiting) = 0 then
  begin
    // A thread running its callbacks: the result goes to the saved wait.
    if (T.Frames.Count > 0) and T.Frames.Last.WasWaiting then
    begin
      var F := T.Frames.Last;
      F.WasWaiting := False;
      F.Saved.GPR[2] := Result;
      F.SavedWait.Kind := PSPWaitNone;
      T.Frames[T.Frames.Count - 1] := F;
    end;
    Exit;
  end;
  if T.Wait.Obj <> nil then
    T.Wait.Obj.RemoveWaiter(T);
  if Result = SCE_KERNEL_ERROR_WAIT_TIMEOUT then
  begin
    if T.Wait.TimeoutPtr <> 0 then
      FMemory.Write32(T.Wait.TimeoutPtr, 0);
  end
  else
    WriteRemaining(T);
  DropWaitTimer(T);
  if (Result <> 0) and Assigned(T.Wait.Abort) then
    T.Wait.Abort(T);
  if (Result <> 0) and T.Wait.FailAsZero then
    Result := 0;
  T.Wait := Default(TPSPWait);
  T.CallbacksPending := False;
  T.SetResult(Result);
  T.Status := T.Status and not PSPThreadWaiting;
  if (T.Status and PSPThreadSuspended) = 0 then
  begin
    T.Status := T.Status or PSPThreadReady;
    PushReady(T, False);
  end;
  RequestReschedule;
end;

procedure TPSPKernel.WakeThread(T: TPSPThread);
begin
  EndWait(T, 0);
end;

{ Timers }

procedure TPSPKernel.ScheduleTimerEvent;
begin
  if FTimers.Count = 0 then
    FScheduler.Cancel(TPSPEvent.Kernel)
  else
    FScheduler.Schedule(TPSPEvent.Kernel, FTimers[0].At);
end;

function TPSPKernel.AddTimer(At: Int64; Owner: TObject; const Event: TPSPTimerEvent): Int64;
begin
  var E := Default(TPSPTimer);
  E.At := At;
  Inc(FTimerSeq);
  E.Seq := FTimerSeq;
  E.Kind := tkCustom;
  E.Owner := Owner;
  E.Event := Event;
  var I := FTimers.Count;
  while (I > 0) and (FTimers[I - 1].At > At) do
    Dec(I);
  FTimers.Insert(I, E);
  ScheduleTimerEvent;
  Result := E.Seq;
end;

procedure TPSPKernel.CancelTimer(Handle: Int64);
begin
  for var I := FTimers.Count - 1 downto 0 do
    if FTimers[I].Seq = Handle then
      FTimers.Delete(I);
  ScheduleTimerEvent;
end;

procedure TPSPKernel.CancelTimersOf(Owner: TObject);
begin
  for var I := FTimers.Count - 1 downto 0 do
    if (FTimers[I].Owner = Owner) or (FTimers[I].Thread = Owner) then
      FTimers.Delete(I);
  ScheduleTimerEvent;
end;

procedure TPSPKernel.OnTimerEvent;
begin
  while (FTimers.Count > 0) and (FTimers[0].At <= FScheduler.Now) do
  begin
    var E := FTimers[0];
    FTimers.Delete(0);
    case E.Kind of
      tkWait:
        if (E.Thread <> nil) and E.Thread.IsWaiting then
        begin
          // The timer interrupt and the wakeup take the CPU a while, from
          // whatever was running.
          if E.Thread.Wait.Kind = PSPWaitDelay then
          begin
            Spend(PSPDelayLatencyNs);
            EndWait(E.Thread, 0);
          end
          else
          begin
            Spend(PSPWaitLatencyNs);
            var Obj := E.Thread.Wait.Obj;
            EndWait(E.Thread, SCE_KERNEL_ERROR_WAIT_TIMEOUT);
            if (Obj <> nil) and FObjects.ContainsKey(Obj.UID) then
              Obj.WaiterGone;
          end;
        end;
      tkCustom:
        if Assigned(E.Event) then
          E.Event();
    end;
  end;
  ScheduleTimerEvent;
end;

{ Guest calls }

procedure TPSPKernel.EnterGuest(Func, SP, GP: Cardinal; const Args: array of Cardinal);
begin
  for var I := 0 to High(Args) do
    if I < 8 then
      FCPU.Ctx.GPR[4 + I] := Args[I];
  FCPU.Ctx.GPR[29] := SP;
  if GP <> 0 then
    FCPU.Ctx.GPR[28] := GP;
  FCPU.Ctx.GPR[31] := FTrapBase;
  FCPU.SetPC(Func);
end;

procedure TPSPKernel.CallGuest(Func: Cardinal; const Args: array of Cardinal; const OnReturn: TPSPGuestReturn; GP: Cardinal);
begin
  if InInterrupt then
  begin
    // Nested call inside an interrupt handler.
    var F := Default(TPSPFrame);
    F.Kind := fkInterrupt;
    F.Saved := FCPU.Ctx;
    F.OnReturn := OnReturn;
    FIntFrames.Add(F);
    EnterGuest(Func, (FCPU.Ctx.GPR[29] - 64) and not Cardinal(15), GP, Args);
    Exit;
  end;
  var T := FCurrent;
  if T = nil then
    raise EPSPError.Create('PSP: guest call without a thread');
  var F := Default(TPSPFrame);
  F.Kind := fkHLE;
  F.Saved := FCPU.Ctx;
  F.OnReturn := OnReturn;
  T.Frames.Add(F);
  EnterGuest(Func, (FCPU.Ctx.GPR[29] - 64) and not Cardinal(15), GP, Args);
end;

procedure TPSPKernel.StartCallbacks(T: TPSPThread; KeepResult: Boolean);
begin
  if FTrace then
    T_('callbacks start, wait kind %d', [T.Wait.Kind]);
  // T is current. Saves the context (and wait) and runs the first pending callback.
  var F := Default(TPSPFrame);
  F.Kind := fkCallback;
  F.KeepResult := KeepResult;
  F.Saved := FCPU.Ctx;
  F.SavedWait := T.Wait;
  F.WasWaiting := T.Wait.Kind <> PSPWaitNone;
  if F.WasWaiting then
  begin
    if T.Wait.Obj <> nil then
      T.Wait.Obj.RemoveWaiter(T);
    DropWaitTimer(T);
  end;
  T.Wait := Default(TPSPWait);
  T.Status := (T.Status and not PSPThreadWaiting) or PSPThreadRunning;
  if not RunNextCallback(T, F) then
  begin
    // Nothing to run after all: settle back.
    FCPU.Ctx := F.Saved;
    T.Wait := F.SavedWait;
    if F.WasWaiting then
    begin
      T.Status := (T.Status and not PSPThreadRunning) or PSPThreadWaiting;
      if T.Wait.Obj <> nil then
        T.Wait.Obj.AddWaiter(T);
      if T.Wait.Deadline <> PSPNever then
        SetWaitDeadline(T, T.Wait.Deadline);
      RequestReschedule;
    end;
    Exit;
  end;
  T.Frames.Add(F);
end;

function TPSPKernel.RunNextCallback(T: TPSPThread; var Frame: TPSPFrame): Boolean;
begin
  for var CB in T.Callbacks do
    if CB.NotifyCount > 0 then
    begin
      var Count := CB.NotifyCount;
      var Arg := CB.NotifyArg;
      CB.NotifyCount := 0;
      CB.NotifyArg := 0;
      Frame.Callback := CB;
      Inc(Frame.CallbacksRan);
      FCPU.Ctx := Frame.Saved;
      EnterGuest(CB.Func, (Frame.Saved.GPR[29] - 64) and not Cardinal(15), CB.GP, [Count, Arg, CB.Common]);
      Exit(True);
    end;
  Result := False;
end;

procedure TPSPKernel.FinishCallbackFrame(T: TPSPThread);
begin
  var F := T.Frames.Last;
  var Ret := FCPU.Ctx.GPR[2];
  if (F.Callback <> nil) and (Ret <> 0) and FObjects.ContainsKey(F.Callback.UID) then
  begin
    T.Callbacks.Remove(F.Callback);
    DeleteObject(F.Callback);
  end;
  F.Callback := nil;
  if RunNextCallback(T, F) then
  begin
    T.Frames[T.Frames.Count - 1] := F;
    Exit;
  end;
  T.Frames.Delete(T.Frames.Count - 1);
  FCPU.Ctx := F.Saved;
  if FTrace then
    T_('callbacks done, was waiting %s kind %d', [BoolToStr(F.WasWaiting, True), F.SavedWait.Kind]);
  if F.WasWaiting then
  begin
    T.Wait := F.SavedWait;
    var Done := False;
    if (T.Wait.Deadline <> PSPNever) and (T.Wait.Deadline <= FScheduler.Now) then
    begin
      if T.Wait.Kind = PSPWaitDelay then
        FCPU.Ctx.GPR[2] := 0
      else
      begin
        FCPU.Ctx.GPR[2] := SCE_KERNEL_ERROR_WAIT_TIMEOUT;
        if T.Wait.TimeoutPtr <> 0 then
          FMemory.Write32(T.Wait.TimeoutPtr, 0);
        if Assigned(T.Wait.Abort) then
          T.Wait.Abort(T);
        T.Wait.TimeoutPtr := 0;
      end;
      Done := True;
    end
    else if Assigned(T.Wait.Retry) and T.Wait.Retry(T) then
      Done := True;
    if Done then
    begin
      WriteRemaining(T);
      T.Wait := Default(TPSPWait);
    end
    else
    begin
      T.Status := (T.Status and not PSPThreadRunning) or PSPThreadWaiting;
      if T.Wait.Obj <> nil then
        T.Wait.Obj.AddWaiter(T);
      if T.Wait.Deadline <> PSPNever then
        SetWaitDeadline(T, T.Wait.Deadline);
      RequestReschedule;
    end;
  end
  else if not F.KeepResult then
    // sceKernelCheckCallback returns whether callbacks ran.
    FCPU.Ctx.GPR[2] := Ord(F.CallbacksRan > 0);
end;

function TPSPKernel.CheckCallbacksNow(KeepResult: Boolean): Boolean;
begin
  var T := FCurrent;
  // One level of callbacks inside a callback, as with blocking CB waits.
  if (T = nil) or not T.HasPendingCallbacks or (T.CallbackDepth >= 2) then
    Exit(False);
  StartCallbacks(T, KeepResult);
  Result := True;
end;

function TPSPKernel.CheckCallbacks: Boolean;
begin
  if InInterrupt then
    Exit(False);
  Result := CheckCallbacksNow;
end;

procedure TPSPKernel.NotifyCallback(CB: TPSPCallback; Arg: Cardinal);
begin
  if FTrace then
    T_('notify %s of %s', [CB.Name, PSPThreadName(CB.Thread)]);
  Inc(CB.NotifyCount);
  CB.NotifyArg := Arg;
  var T := CB.Thread;
  if (T <> nil) and T.IsWaiting and T.Wait.AllowCB and not T.CallbacksPending and (T.CallbackDepth < 2) then
  begin
    // Leave the wait queue; run callbacks when dispatched, then wait again.
    T.CallbacksPending := True;
    if T.Wait.Obj <> nil then
      T.Wait.Obj.RemoveWaiter(T);
    DropWaitTimer(T);
    T.Ctx.GPR[2] := 0;
    // The saved wait is restored by StartCallbacks through T.Wait.
    T.Status := (T.Status and not PSPThreadWaiting);
    if (T.Status and PSPThreadSuspended) = 0 then
    begin
      T.Status := T.Status or PSPThreadReady;
      PushReady(T, False);
    end;
    RequestReschedule;
  end;
end;

procedure TPSPKernel.ReturnTrap;
begin
  if FIntFrames.Count > 0 then
  begin
    var F := FIntFrames.Last;
    FIntFrames.Delete(FIntFrames.Count - 1);
    var Ret := FCPU.Ctx.GPR[2];
    FCPU.Ctx := F.Saved;
    if Assigned(F.OnReturn) then
      F.OnReturn(Ret);
    if FIntFrames.Count = 0 then
    begin
      DropStaleInterrupts;
      if FPendingInts.Count > 0 then
        StartNextInterrupt
      else
      begin
        Spend(PSPIntrExitNs);
        var Best := BestReady;
        if (Best <> nil) and ((FCurrent = nil) or (Best.Priority < FCurrent.Priority)) and not FDispatchSuspended then
          Spend(PSPIntrDispatchNs);
        if FCurrent = nil then
        begin
          FIdle := True;
          FCPU.Stop;
        end;
        if FRescheduleNeeded then
          Reschedule;
      end;
    end;
    Exit;
  end;
  var T := FCurrent;
  if (T = nil) or (T.Frames.Count = 0) then
    raise EPSPGuestFault.CreateFmt('PSP: return trap without a frame (thread %s)', [PSPThreadName(T)]);
  var F := T.Frames.Last;
  case F.Kind of
    fkCallback:
      FinishCallbackFrame(T);
    fkHLE:
      begin
        T.Frames.Delete(T.Frames.Count - 1);
        var Ret := FCPU.Ctx.GPR[2];
        FCPU.Ctx := F.Saved;
        if Assigned(F.OnReturn) then
          F.OnReturn(Ret);
      end;
  else
    T.Frames.Delete(T.Frames.Count - 1);
  end;
  if FRescheduleNeeded then
    Reschedule;
end;

procedure TPSPKernel.ThreadExitTrap;
begin
  Spend(PSPExitThreadNs);
  var T := FCurrent;
  ExitCurrent(FCPU.Ctx.GPR[2]);
  if (T <> nil) and T.DeleteOnExit and (FCurrent = T) then
  begin
    T.Ctx := FCPU.Ctx;
    FCurrent := nil;
    DeleteThread(T);
    Reschedule;
  end;
end;

procedure TPSPKernel.Trap(Code: Cardinal);
begin
  case Code of
    PSPTrapReturn: ReturnTrap;
    PSPTrapThreadExit: ThreadExitTrap;
  else
    raise EPSPGuestFault.CreateFmt('PSP: unknown kernel trap %d', [Code]);
  end;
end;

{ Interrupts }

procedure TPSPKernel.QueueInterrupt(Func: Cardinal; const Args: array of Cardinal; GP: Cardinal; const OnReturn: TPSPGuestReturn;
  EntryNs: Int64; OwnerUID: Cardinal);
begin
  var P := Default(TPSPPendingInterrupt);
  P.Func := Func;
  if Length(Args) > 0 then P.A0 := Args[0];
  if Length(Args) > 1 then P.A1 := Args[1];
  if Length(Args) > 2 then P.A2 := Args[2];
  if Length(Args) > 3 then P.A3 := Args[3];
  P.GP := GP;
  P.OnReturn := OnReturn;
  P.EntryNs := EntryNs;
  P.OwnerUID := OwnerUID;
  FPendingInts.Enqueue(P);
  FCPU.Stop;
end;

procedure TPSPKernel.TriggerInterrupt(IntNo, SubNo: Integer; Arg2: Cardinal);
begin
  if (IntNo < 0) or (IntNo > High(FSubIntr)) then
    Exit;
  for var S := 0 to 31 do
  begin
    if (SubNo >= 0) and (S <> SubNo) then
      Continue;
    var H := FSubIntr[IntNo, S];
    if H.Enabled and (H.Handler <> 0) then
      QueueInterrupt(H.Handler, [Cardinal(S), H.Arg, Arg2], H.GP);
  end;
end;

procedure TPSPKernel.DropStaleInterrupts;
begin
  // Handlers of alarms and timers deleted while they were pending never run.
  while (FPendingInts.Count > 0) and (FPendingInts.Peek.OwnerUID <> 0) and
    not FObjects.ContainsKey(FPendingInts.Peek.OwnerUID) do
    FPendingInts.Dequeue;
end;

procedure TPSPKernel.StartNextInterrupt;
begin
  var P := FPendingInts.Dequeue;
  var F := Default(TPSPFrame);
  F.Kind := fkInterrupt;
  F.Saved := FCPU.Ctx;
  F.OnReturn := P.OnReturn;
  FIntFrames.Add(F);
  FIdle := False;
  if FCurrent <> nil then
    Inc(FCurrent.IntrPreemptCount);
  if P.EntryNs > 0 then
    Spend(P.EntryNs);
  EnterGuest(P.Func, FIntStack - 64, P.GP, [P.A0, P.A1, P.A2, P.A3]);
end;

procedure TPSPKernel.ProcessInterrupts;
begin
  DropStaleInterrupts;
  if (FPendingInts.Count = 0) or (FIntFrames.Count > 0) then
    Exit;
  if (FIntrSuspendLevel > 0) or not FCPU.InterruptsEnabled then
    Exit;
  StartNextInterrupt;
end;

{ Memory }

function TPSPKernel.AllocUser(Size: Cardinal; High: Boolean; const Tag: string): Cardinal;
begin
  if High then
    Result := FUserPartition.Alloc(Size, akHigh, 0, 256, Tag)
  else
    Result := FUserPartition.Alloc(Size, akLow, 0, 256, Tag);
end;

function TPSPKernel.AllocKernel(Size: Cardinal; const Tag: string): Cardinal;
begin
  Result := FKernelPartition.Alloc(Size, akLow, 0, 256, Tag);
end;

function TPSPKernel.Partition(Id: Integer): TPSPPartition;
begin
  case Id of
    1, 3, 4: Result := FKernelPartition;
    2, 6: Result := FUserPartition;
    5: Result := FVolatilePartition;
  else
    Result := nil;
  end;
end;

procedure TPSPKernel.DebugWrite(const S: RawByteString);
begin
  FDebugOut.Append(string(S));
end;

function TPSPKernel.TakeDebugOutput: string;
begin
  Result := FDebugOut.ToString;
  FDebugOut.Clear;
end;

function TPSPKernel.DescribeThreads: string;
begin
  Result := '';
  for var T in FThreads do
    Result := Result + Format('%s st=%x prio=%d wait=%d/%s pc=%.8x'#10,
      [PSPThreadName(T), T.Status, T.Priority, T.Wait.Kind, T.Wait.HLETag, T.Ctx.PC]);
end;
