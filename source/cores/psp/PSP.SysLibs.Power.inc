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

// scePower's volatile memory calls are the sceSuspend ones under another name.
procedure TPSPSysLibs.hPowerVolatileLock;
begin
  CallKernel('sceSuspendForUser', $3E0271D3);
end;

procedure TPSPSysLibs.hPowerVolatileTryLock;
begin
  CallKernel('sceSuspendForUser', $A14F40B2);
end;

procedure TPSPSysLibs.hPowerVolatileUnlock;
begin
  CallKernel('sceSuspendForUser', $A569E425);
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
