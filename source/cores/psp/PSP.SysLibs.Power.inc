{ PSP.SysLibs: scePower. The PLL runs at 1332/N MHz (N = 4..7); the CPU at
  PLL * K / 511 and the bus at half the PLL, so set frequencies round down to
  those steps. Callbacks hear AC power, a battery present and full charge. }

const
  PowerCallbackInfo = $00001000 or $00000080 or 100;
  SCE_POWER_ERROR_SLOT_BUSY = Cardinal($80000020);
  SCE_POWER_ERROR_NO_SLOT = Cardinal($80000022);
  SCE_POWER_ERROR_KERNEL_SLOT = Cardinal($80000023);
  SCE_POWER_ERROR_NOT_REGISTERED = Cardinal($80000025);

function TPSPSysLibs.PllFloat: Single;
begin
  Result := 1332 / FPllN;
end;

function TPSPSysLibs.CpuFloat: Single;
begin
  var Pll: Single := PllFloat;
  var Scaled: Single := Pll * FCpuK;
  Result := Scaled / 511;
end;

function TPSPSysLibs.BusFloat: Single;
begin
  Result := PllFloat / 2;
end;

procedure TPSPSysLibs.ApplyCpuClock;
begin
  FKernel.NowUs;
  FKernel.Scheduler.MHz := Max(1, Trunc(CpuFloat));
  // The running slice was sized at the old clock.
  FHLE.CPU.Stop;
end;

procedure TPSPSysLibs.hPowerGetCpu;
begin
  FHLE.Result(Cardinal(Trunc(CpuFloat)));
end;

procedure TPSPSysLibs.hPowerGetBus;
begin
  FHLE.Result(Cardinal(Trunc(BusFloat)));
end;

procedure TPSPSysLibs.hPowerGetPll;
begin
  FHLE.Result(Cardinal(Trunc(PllFloat)));
end;

procedure TPSPSysLibs.hPowerGetCpuFloat;
begin
  FHLE.ResultFloat(CpuFloat);
end;

procedure TPSPSysLibs.hPowerGetBusFloat;
begin
  FHLE.ResultFloat(BusFloat);
end;

procedure TPSPSysLibs.hPowerGetPllFloat;
begin
  FHLE.ResultFloat(PllFloat);
end;

procedure TPSPSysLibs.hPowerSetClock;
begin
  var Pll := FHLE.ArgInt(0);
  var Cpu := FHLE.ArgInt(1);
  var Bus := FHLE.ArgInt(2);
  if (Pll < 19) or (Pll > 333) or (Cpu < 1) or (Cpu > 333) or (Bus < 1) or (Bus > 166) then
    begin FHLE.Result(SCE_KERNEL_ERROR_INVALID_VALUE); Exit; end;
  // The slowest PLL step that reaches the requested frequency.
  var N := 7;
  while (N > 4) and (1332 < Pll * N) do
    Dec(N);
  FPllN := N;
  FCpuK := Min(511, (Cpu * 511 * N) div 1332);
  ApplyCpuClock;
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hPowerSetCpu;
begin
  var Cpu := FHLE.ArgInt(0);
  if (Cpu < 1) or (Cpu > Trunc(PllFloat)) then
    begin FHLE.Result(SCE_KERNEL_ERROR_INVALID_VALUE); Exit; end;
  FCpuK := Min(511, (Cpu * 511 * FPllN) div 1332);
  ApplyCpuClock;
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hPowerSetBus;
begin
  // The bus follows the PLL; the call only validates.
  var Bus := FHLE.ArgInt(0);
  if (Bus < 1) or (Bus > Trunc(BusFloat)) then
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_VALUE)
  else
    FHLE.Result(0);
end;

procedure TPSPSysLibs.hPowerRegisterCallback;
begin
  var Slot := FHLE.ArgInt(0);
  var CBId := FHLE.Arg(1);
  if (Slot < -1) or (Slot >= 32) then
    begin FHLE.Result(SCE_KERNEL_ERROR_INVALID_INDEX); Exit; end;
  if Slot >= 16 then
    begin FHLE.Result(SCE_POWER_ERROR_KERNEL_SLOT); Exit; end;
  var CB := TPSPCallback(FKernel.GetObject(CBId, TPSPCallback));
  if CB = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_INVALID_ID); Exit; end;
  if Slot = -1 then
  begin
    for var I := 0 to High(FPowerCallbacks) do
      if FPowerCallbacks[I] = 0 then
      begin
        Slot := I;
        Break;
      end;
    if Slot = -1 then
      begin FHLE.Result(SCE_POWER_ERROR_NO_SLOT); Exit; end;
  end
  else if FPowerCallbacks[Slot] <> 0 then
    begin FHLE.Result(SCE_POWER_ERROR_SLOT_BUSY); Exit; end;
  FPowerCallbacks[Slot] := CBId;
  FKernel.NotifyCallback(CB, PowerCallbackInfo);
  FHLE.Result(Cardinal(Slot));
end;

procedure TPSPSysLibs.hPowerUnregisterCallback;
begin
  var Slot := FHLE.ArgInt(0);
  if (Slot < 0) or (Slot >= 32) then
    begin FHLE.Result(SCE_KERNEL_ERROR_INVALID_INDEX); Exit; end;
  if Slot >= 16 then
    begin FHLE.Result(SCE_POWER_ERROR_KERNEL_SLOT); Exit; end;
  if FPowerCallbacks[Slot] = 0 then
    begin FHLE.Result(SCE_POWER_ERROR_NOT_REGISTERED); Exit; end;
  FPowerCallbacks[Slot] := 0;
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hPowerBatteryPercent;
begin
  FHLE.Result(100);
end;

procedure TPSPSysLibs.hPowerOne;
begin
  FHLE.Result(1);
end;

procedure TPSPSysLibs.hPowerZero;
begin
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hPowerBatteryLifeTime;
begin
  FHLE.Result(300);
end;

procedure TPSPSysLibs.hPowerBatteryTemp;
begin
  FHLE.Result(28);
end;

procedure TPSPSysLibs.hPowerBatteryVolt;
begin
  FHLE.Result(4135);
end;

const
  SCE_KERNEL_ERROR_POWER_VMEM_IN_USE = Cardinal($802B0200);

// The volatile memory lock: mode 0 only, waiters served in the order they
// came. A lock that cannot wait still reports where the memory is; unlocking
// it when free answers like a semaphore signalled past its maximum.
procedure TPSPSysLibs.VolatileGrant(Ptr, SizePtr: Cardinal);
begin
  if Ptr <> 0 then
    FMemory.Write32(Ptr, $08400000);
  if SizePtr <> 0 then
    FMemory.Write32(SizePtr, $00400000);
end;

procedure TPSPSysLibs.VolatileAbort(T: TPSPThread);
begin
  FVolatileWaiters.Remove(T);
end;

procedure TPSPSysLibs.hVolatileMemLock;
begin
  var Ptr := FHLE.Arg(1);
  var SizePtr := FHLE.Arg(2);
  if FHLE.Arg(0) <> 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_MODE);
    Exit;
  end;
  if FKernel.InInterrupt then
  begin
    VolatileGrant(Ptr, SizePtr);
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  if not FSystem.CPU.InterruptsEnabled then
  begin
    VolatileGrant(Ptr, SizePtr);
    FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT);
    Exit;
  end;
  if not FVolatileLocked then
  begin
    FVolatileLocked := True;
    VolatileGrant(Ptr, SizePtr);
    FHLE.Result(0);
    Exit;
  end;
  if not FKernel.CanWait then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT);
    Exit;
  end;
  var T := FKernel.Current;
  FVolatileWaiters.Add(T);
  FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, False, nil, VolatileAbort, 'volatile');
  T.Wait.Data[0] := Ptr;
  T.Wait.Data[1] := SizePtr;
end;

procedure TPSPSysLibs.hVolatileMemTryLock;
begin
  if FHLE.Arg(0) <> 0 then
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_MODE)
  else if FVolatileLocked then
    FHLE.Result(SCE_KERNEL_ERROR_POWER_VMEM_IN_USE)
  else
  begin
    FVolatileLocked := True;
    VolatileGrant(FHLE.Arg(1), FHLE.Arg(2));
    FHLE.Result(0);
  end;
end;

procedure TPSPSysLibs.hVolatileMemUnlock;
begin
  if FHLE.Arg(0) <> 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_MODE);
    Exit;
  end;
  if not FVolatileLocked then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_SEMA_OVF);
    Exit;
  end;
  FHLE.Result(0);
  // The lock passes to the first thread waiting for it.
  while FVolatileWaiters.Count > 0 do
  begin
    var T := FVolatileWaiters[0];
    FVolatileWaiters.Delete(0);
    if T.IsWaiting and (T.Wait.HLETag = 'volatile') then
    begin
      VolatileGrant(T.Wait.Data[0], T.Wait.Data[1]);
      FKernel.EndWait(T, 0);
      Exit;
    end;
  end;
  FVolatileLocked := False;
end;

// scePower's volatile memory calls are the sceSuspend ones under another name.
procedure TPSPSysLibs.hPowerVolatileLock;
begin
  hVolatileMemLock;
end;

procedure TPSPSysLibs.hPowerVolatileTryLock;
begin
  hVolatileMemTryLock;
end;

procedure TPSPSysLibs.hPowerVolatileUnlock;
begin
  hVolatileMemUnlock;
end;

procedure TPSPSysLibs.hKernelPowerLock;
begin
  // Only lock type 0 exists for user code.
  if FHLE.Arg(0) <> 0 then
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_MODE)
  else
    FHLE.Result(0);
end;

procedure TPSPSysLibs.hKernelPowerTick;
begin
  FHLE.Result(0);
end;
