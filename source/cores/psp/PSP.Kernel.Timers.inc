{ PSP.Kernel: alarms, virtual timers, thread event handlers. }

type
  TPSPAlarm = class(TPSPKernelObject)
  public
    Handler, Common, GP: Cardinal;
    // When it is due (system time, us) and when the handler really runs (ns).
    Schedule: UInt64;
    TimerHandle: Int64;
    class function IdType: Integer; override;
  end;

  TPSPVTimer = class(TPSPKernelObject)
  public
    Active: Boolean;
    // Time counted while stopped, and the system time (us) it last started at.
    Accumulated: UInt64;
    StartedAt: UInt64;
    Handler, Common, GP: Cardinal;
    Schedule: UInt64;
    TimerHandle: Int64;
    class function IdType: Integer; override;
    function Current(NowUs: UInt64): UInt64;
  end;

  TPSPThreadEventHandler = class(TPSPKernelObject)
  public
    ThreadId, Mask, Handler, Common: Cardinal;
    class function IdType: Integer; override;
  end;

const
  PSPErrorIllegalVTimer = Cardinal($800201BF);
  // The thread manager arms its timer no sooner than this after the call, and
  // the handler starts a while after the timer goes off.
  PSPAlarmMinUs = 215;
  PSPAlarmLatencyNs = 41000;
  PSPSetAlarmNs = 42000;

class function TPSPAlarm.IdType: Integer;
begin
  Result := 10;
end;

class function TPSPVTimer.IdType: Integer;
begin
  Result := 11;
end;

function TPSPVTimer.Current(NowUs: UInt64): UInt64;
begin
  Result := Accumulated;
  if Active then
    Inc(Result, NowUs - StartedAt);
end;

class function TPSPThreadEventHandler.IdType: Integer;
begin
  Result := 9;
end;

{ Alarms }

procedure TPSPKernel.ArmAlarm(Obj: TPSPKernelObject; FireAt: Int64);
begin
  var A := TPSPAlarm(Obj);
  var K := Self;
  A.TimerHandle := AddTimer(FireAt, A,
    procedure
    begin
      if not K.FObjects.ContainsKey(A.UID) then
        Exit;
      A.TimerHandle := 0;
      K.QueueInterrupt(A.Handler, [A.Common], A.GP,
        procedure(Ret: Cardinal)
        begin
          if not K.FObjects.ContainsKey(A.UID) then
            Exit;
          if Ret = 0 then
            K.DeleteObject(A)
          else
          begin
            Inc(A.Schedule, Ret);
            var At := Int64(A.Schedule) * 1000 + PSPAlarmLatencyNs;
            if At < K.FScheduler.Now then
              At := K.FScheduler.Now;
            K.ArmAlarm(A, At);
          end;
        end);
    end);
end;

procedure TPSPKernel.SetAlarmCommon(Us: UInt64);
begin
  var Handler := FHLE.Arg(1);
  if (Handler = 0) or not ValidUserAddress(Handler) and not ((FCurrent <> nil) and FCurrent.IsKernel) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR); Exit; end;
  var Start := FScheduler.Now;
  var A := TPSPAlarm.Create;
  A.Name := 'alarm';
  A.Handler := Handler;
  A.Common := FHLE.Arg(2);
  A.GP := FCPU.Ctx.GPR[28];
  A.Schedule := UInt64(Start div 1000) + Us;
  AddObject(A);
  var Wait := Us;
  if Wait < PSPAlarmMinUs then
    Wait := PSPAlarmMinUs;
  var FireAt: Int64 := PSPNever;
  if Wait < UInt64(High(Int64) div 4000) then
    FireAt := Start + Int64(Wait) * 1000 + PSPAlarmLatencyNs;
  if FireAt <> PSPNever then
    ArmAlarm(A, FireAt);
  Spend(PSPSetAlarmNs);
  FHLE.Result(A.UID);
end;

procedure TPSPKernel.hSetAlarm;
begin
  SetAlarmCommon(FHLE.Arg(0));
end;

procedure TPSPKernel.hSetSysClockAlarm;
begin
  var P := FHLE.Arg(0);
  var Us := UInt64(FMemory.Read32(P)) or (UInt64(FMemory.Read32(P + 4)) shl 32);
  SetAlarmCommon(Us);
end;

procedure TPSPKernel.hCancelAlarm;
begin
  var A := TPSPAlarm(GetObject(FHLE.Arg(0), TPSPAlarm));
  if A = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_ALMID); Exit; end;
  DeleteObject(A);
  FHLE.Result(0);
end;

procedure TPSPKernel.hReferAlarmStatus;
begin
  var A := TPSPAlarm(GetObject(FHLE.Arg(0), TPSPAlarm));
  if A = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_ALMID); Exit; end;
  var Buf: array[0..$13] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  PUInt64(@Buf[4])^ := A.Schedule;
  PCardinal(@Buf[$C])^ := A.Handler;
  PCardinal(@Buf[$10])^ := A.Common;
  WriteInfo(FHLE.Arg(1), Buf, $14);
  FHLE.Result(0);
end;

{ Virtual timers }

procedure TPSPKernel.ArmVTimer(Obj: TPSPKernelObject);
begin
  var V := TPSPVTimer(Obj);
  if V.TimerHandle <> 0 then
  begin
    CancelTimer(V.TimerHandle);
    V.TimerHandle := 0;
  end;
  if not V.Active or (V.Handler = 0) then
    Exit;
  var NowUs := UInt64(FScheduler.Now div 1000);
  var Cur := V.Current(NowUs);
  var Delta: UInt64 := 0;
  if V.Schedule > Cur then
    Delta := V.Schedule - Cur;
  if Delta > UInt64(High(Int64) div 4000) then
    Exit;
  var At := FScheduler.Now + Int64(Delta) * 1000 + PSPAlarmLatencyNs;
  var K := Self;
  V.TimerHandle := AddTimer(At, V,
    procedure
    begin
      if not K.FObjects.ContainsKey(V.UID) then
        Exit;
      V.TimerHandle := 0;
      if not V.Active or (V.Handler = 0) then
        Exit;
      // The handler gets the scheduled and the real elapsed time.
      var Args := K.FIntStack - $200;
      var Real := V.Current(UInt64(K.FScheduler.Now div 1000));
      K.FMemory.Write32(Args, Cardinal(V.Schedule));
      K.FMemory.Write32(Args + 4, Cardinal(V.Schedule shr 32));
      K.FMemory.Write32(Args + 8, Cardinal(Real));
      K.FMemory.Write32(Args + 12, Cardinal(Real shr 32));
      K.FFiringVTimer := V.UID;
      K.QueueInterrupt(V.Handler, [V.UID, Args, Args + 8, V.Common], V.GP,
        procedure(Ret: Cardinal)
        begin
          K.FFiringVTimer := 0;
          if not K.FObjects.ContainsKey(V.UID) then
            Exit;
          if Ret = 0 then
            V.Handler := 0
          else
          begin
            Inc(V.Schedule, Ret);
            K.ArmVTimer(V);
          end;
        end);
    end);
end;

procedure TPSPKernel.hCreateVTimer;
begin
  if InInterrupt then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT); Exit; end;
  var Name: string;
  if not ReadName(FHLE.Arg(0), Name) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ERROR); Exit; end;
  var V := TPSPVTimer.Create;
  V.Name := Name;
  FHLE.Result(AddObject(V));
end;

function TPSPKernel.VTimerOf(Id: Cardinal): TPSPKernelObject;
begin
  Result := GetObject(Id, TPSPVTimer);
end;

procedure TPSPKernel.hDeleteVTimer;
begin
  if InInterrupt then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT); Exit; end;
  var V := TPSPVTimer(VTimerOf(FHLE.Arg(0)));
  if V = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VTID); Exit; end;
  DeleteObject(V);
  FHLE.Result(0);
end;

procedure TPSPKernel.hGetVTimerBase;
begin
  var V := TPSPVTimer(VTimerOf(FHLE.Arg(0)));
  if V = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VTID); Exit; end;
  var P := FHLE.Arg(1);
  var Base: UInt64 := 0;
  if V.Active then
    Base := V.StartedAt;
  FMemory.Write32(P, Cardinal(Base));
  FMemory.Write32(P + 4, Cardinal(Base shr 32));
  FHLE.Result(0);
end;

procedure TPSPKernel.hGetVTimerBaseWide;
begin
  var V := TPSPVTimer(VTimerOf(FHLE.Arg(0)));
  if V = nil then
    begin FHLE.Result64(UInt64(-1)); Exit; end;
  if V.Active then
    FHLE.Result64(V.StartedAt)
  else
    FHLE.Result64(0);
end;

procedure TPSPKernel.hGetVTimerTime;
begin
  var V := TPSPVTimer(VTimerOf(FHLE.Arg(0)));
  if V = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VTID); Exit; end;
  var P := FHLE.Arg(1);
  var T := V.Current(UInt64(NowUs));
  FMemory.Write32(P, Cardinal(T));
  FMemory.Write32(P + 4, Cardinal(T shr 32));
  FHLE.Result(0);
end;

procedure TPSPKernel.hGetVTimerTimeWide;
begin
  var V := TPSPVTimer(VTimerOf(FHLE.Arg(0)));
  if V = nil then
    begin FHLE.Result64(UInt64(-1)); Exit; end;
  FHLE.Result64(V.Current(UInt64(NowUs)));
end;

procedure TPSPKernel.SetVTimerTimeTo(Obj: TPSPKernelObject; Value: UInt64);
begin
  var V := TPSPVTimer(Obj);
  var NowU := UInt64(NowUs);
  V.Accumulated := Value;
  if V.Active then
    V.StartedAt := NowU;
  ArmVTimer(V);
end;

procedure TPSPKernel.hSetVTimerTime;
begin
  if InInterrupt then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT); Exit; end;
  var V := TPSPVTimer(VTimerOf(FHLE.Arg(0)));
  if V = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VTID); Exit; end;
  var P := FHLE.Arg(1);
  var Old := V.Current(UInt64(NowUs));
  var Value := UInt64(FMemory.Read32(P)) or (UInt64(FMemory.Read32(P + 4)) shl 32);
  SetVTimerTimeTo(V, Value);
  FMemory.Write32(P, Cardinal(Old));
  FMemory.Write32(P + 4, Cardinal(Old shr 32));
  FHLE.Result(0);
end;

procedure TPSPKernel.hSetVTimerTimeWide;
begin
  if InInterrupt then
    begin FHLE.Result64(UInt64(-1)); Exit; end;
  var V := TPSPVTimer(VTimerOf(FHLE.Arg(0)));
  if V = nil then
    begin FHLE.Result64(UInt64(-1)); Exit; end;
  var Old := V.Current(UInt64(NowUs));
  SetVTimerTimeTo(V, FHLE.Arg64(2));
  FHLE.Result64(Old);
end;

procedure TPSPKernel.hStartVTimer;
begin
  if FHLE.Arg(0) = 0 then
    begin FHLE.Result(PSPErrorIllegalVTimer); Exit; end;
  var V := TPSPVTimer(VTimerOf(FHLE.Arg(0)));
  if V = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VTID); Exit; end;
  if V.Active then
    begin FHLE.Result(1); Exit; end;
  V.Active := True;
  V.StartedAt := UInt64(NowUs);
  ArmVTimer(V);
  FHLE.Result(0);
end;

procedure TPSPKernel.hStopVTimer;
begin
  if FHLE.Arg(0) = 0 then
    begin FHLE.Result(PSPErrorIllegalVTimer); Exit; end;
  var V := TPSPVTimer(VTimerOf(FHLE.Arg(0)));
  if V = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VTID); Exit; end;
  if not V.Active then
    begin FHLE.Result(0); Exit; end;
  V.Accumulated := V.Current(UInt64(NowUs));
  V.Active := False;
  ArmVTimer(V);
  FHLE.Result(1);
end;

procedure TPSPKernel.SetVTimerHandlerCommon(Schedule: UInt64; Handler, Common: Cardinal);
begin
  if FHLE.Arg(0) = 0 then
    begin FHLE.Result(PSPErrorIllegalVTimer); Exit; end;
  var V := TPSPVTimer(VTimerOf(FHLE.Arg(0)));
  if V = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VTID); Exit; end;
  FHLE.Result(0);
  // No handler only takes the old one away.
  if Handler = 0 then
  begin
    V.Handler := 0;
    ArmVTimer(V);
    Exit;
  end;
  V.Handler := Handler;
  V.Common := Common;
  V.GP := FCPU.Ctx.GPR[28];
  V.Schedule := Schedule;
  ArmVTimer(V);
  FHLE.Result(0);
end;

procedure TPSPKernel.hSetVTimerHandler;
begin
  var P := FHLE.Arg(1);
  var Sched: UInt64 := 0;
  if P <> 0 then
    Sched := UInt64(FMemory.Read32(P)) or (UInt64(FMemory.Read32(P + 4)) shl 32);
  SetVTimerHandlerCommon(Sched, FHLE.Arg(2), FHLE.Arg(3));
end;

procedure TPSPKernel.hSetVTimerHandlerWide;
begin
  SetVTimerHandlerCommon(FHLE.Arg64(2), FHLE.Arg(4), FHLE.Arg(5));
end;

procedure TPSPKernel.hCancelVTimerHandler;
begin
  // Outside a handler 0 is refused; inside one, the timer being handled is.
  var Id := FHLE.Arg(0);
  if (not InInterrupt and (Id = 0)) or (InInterrupt and (FFiringVTimer <> 0) and (Id = FFiringVTimer)) then
    begin FHLE.Result(PSPErrorIllegalVTimer); Exit; end;
  var V := TPSPVTimer(VTimerOf(Id));
  if V = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VTID); Exit; end;
  // The schedule and the common value stay.
  V.Handler := 0;
  ArmVTimer(V);
  FHLE.Result(0);
end;

procedure TPSPKernel.hReferVTimerStatus;
begin
  var V := TPSPVTimer(VTimerOf(FHLE.Arg(0)));
  if V = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VTID); Exit; end;
  var Buf: array[0..$47] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var N := RawByteString(V.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  var NowU := UInt64(NowUs);
  PCardinal(@Buf[$24])^ := Ord(V.Active);
  if V.Active then
    PUInt64(@Buf[$28])^ := V.StartedAt;
  PUInt64(@Buf[$30])^ := V.Current(NowU);
  PUInt64(@Buf[$38])^ := V.Schedule;
  PCardinal(@Buf[$40])^ := V.Handler;
  PCardinal(@Buf[$44])^ := V.Common;
  WriteInfo(FHLE.Arg(1), Buf, $48);
  FHLE.Result(0);
end;

{ Thread event handlers }

procedure TPSPKernel.NotifyThreadEvent(Kind: Cardinal; T: TPSPThread);
begin
  // Handlers are recorded but not called yet.
end;

procedure TPSPKernel.hRegisterThreadEventHandler;
begin
  var Name: string;
  if not ReadName(FHLE.Arg(0), Name) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ERROR); Exit; end;
  var Tid := FHLE.Arg(1);
  if (Tid <> 0) and (Tid <> $FFFFFFFF) and (Tid <> $FFFFFFFE) and (GetObject(Tid, TPSPThread) = nil) then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID); Exit; end;
  var E := TPSPThreadEventHandler.Create;
  E.Name := Name;
  E.ThreadId := Tid;
  E.Mask := FHLE.Arg(2);
  E.Handler := FHLE.Arg(3);
  E.Common := FHLE.Arg(4);
  FEventHandlers.Add(E);
  FHLE.Result(AddObject(E));
end;

procedure TPSPKernel.hReleaseThreadEventHandler;
begin
  var E := TPSPThreadEventHandler(GetObject(FHLE.Arg(0), TPSPThreadEventHandler));
  if E = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_TEID); Exit; end;
  FEventHandlers.Remove(E);
  DeleteObject(E);
  FHLE.Result(0);
end;

procedure TPSPKernel.hReferThreadEventHandlerStatus;
begin
  var E := TPSPThreadEventHandler(GetObject(FHLE.Arg(0), TPSPThreadEventHandler));
  if E = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_TEID); Exit; end;
  var Buf: array[0..$37] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var N := RawByteString(E.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  PCardinal(@Buf[$24])^ := E.ThreadId;
  PCardinal(@Buf[$28])^ := E.Mask;
  PCardinal(@Buf[$2C])^ := E.Handler;
  PCardinal(@Buf[$30])^ := E.Common;
  WriteInfo(FHLE.Arg(1), Buf, $34);
  FHLE.Result(0);
end;
