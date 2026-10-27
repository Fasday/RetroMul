unit PSP.SysLibs;

// Small system libraries: UtilsForUser, scePower, sceUmdUser, sceRtc,
// sceImpose, sceHprm, sceDmac, sceOpenPSID and offline network stubs.
// Wall-clock time is a fixed epoch plus guest time, so runs repeat exactly.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}

interface

uses
  System.SysUtils, System.Generics.Collections, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel, PSP.Scheduler, PSP.Service;

type
  TPSPSysLibs = class(TPSPService)
  private
    FUmdCallback: Cardinal;
    FUmdActivated: Boolean;
    FPowerCallbacks: array[0..15] of Cardinal;
    FBusMHz: Cardinal;
    FPllMHz: Cardinal;
    FLanguage, FButtonSwap: Cardinal;
    FMt: TDictionary<Cardinal, TArray<Cardinal>>;
    FUmdWaiters: TList<TPSPThread>;
    function EpochTicks: UInt64;
    function NowTicks: UInt64;
    procedure WriteDateTime(Address: Cardinal; Ticks: UInt64);
    function ReadDateTime(Address: Cardinal; out Ticks: UInt64): Boolean;
    function UmdStat: Cardinal;
    procedure hDcacheNop;
    procedure hLibcTime;
    procedure hLibcGettimeofday;
    procedure hLibcClock;
    procedure hMd5Digest;
    procedure hSha1Digest;
    procedure hMt19937Init;
    procedure hMt19937UInt;
    procedure hGetGPI;
    procedure hPowerGetCpu;
    procedure hPowerGetBus;
    procedure hPowerGetPll;
    procedure hPowerGetCpuFloat;
    procedure hPowerGetBusFloat;
    procedure hPowerSetClock;
    procedure hPowerSetCpu;
    procedure hPowerSetBus;
    procedure hPowerRegisterCallback;
    procedure hPowerUnregisterCallback;
    procedure hPowerBatteryPercent;
    procedure hPowerOne;
    procedure hPowerZero;
    procedure hPowerBatteryLifeTime;
    procedure hPowerBatteryTemp;
    procedure hPowerBatteryVolt;
    procedure hUmdActivate;
    procedure hUmdDeactivate;
    procedure hUmdGetDriveStat;
    procedure hUmdCheckMedium;
    procedure hUmdWaitDriveStat;
    procedure hUmdWaitDriveStatCB;
    procedure hUmdRegisterCallback;
    procedure hUmdUnregisterCallback;
    procedure hUmdGetDiscInfo;
    procedure hUmdZero;
    procedure hRtcGetCurrentTick;
    procedure hRtcGetTickResolution;
    procedure hRtcGetCurrentClock;
    procedure hRtcGetCurrentClockLocalTime;
    procedure hRtcGetTick;
    procedure hRtcSetTick;
    procedure hRtcTickAddTicks;
    procedure hRtcTickAddMicroseconds;
    procedure hRtcTickAddSeconds;
    procedure hRtcTickAddMinutes;
    procedure hRtcTickAddHours;
    procedure hRtcTickAddDays;
    procedure hRtcTickAddWeeks;
    procedure hRtcTickAddMonths;
    procedure hRtcTickAddYears;
    procedure hRtcCompareTick;
    procedure hRtcConvertCopy;
    procedure hRtcGetDaysInMonth;
    procedure hRtcGetDayOfWeek;
    procedure hRtcIsLeapYear;
    procedure hRtcCheckValid;
    procedure hRtcGetTime_t;
    procedure hRtcSetTime_t;
    procedure hRtcGetTime64_t;
    procedure hRtcSetTime64_t;
    procedure hRtcGetAccumulativeTime;
    procedure hImposeGetLanguageMode;
    procedure hImposeGetBatteryIconStatus;
    procedure hImposeZero;
    procedure hImposeGetHomePopup;
    procedure hHprmZero;
    procedure hDmacMemcpy;
    procedure hGetPSID;
    procedure hZero;
    procedure TickAdd(Units: Int64);
  public
    constructor Create(System: TPSPSystem); override;
    destructor Destroy; override;
    procedure Reset; override;
    procedure Register; override;
  end;

implementation

uses
  System.Math, System.DateUtils, System.Hash;

const
  UnixEpochTicks: UInt64 = 62135596800000000;

constructor TPSPSysLibs.Create(System: TPSPSystem);
begin
  inherited Create(System);
  FMt := TDictionary<Cardinal, TArray<Cardinal>>.Create;
  FUmdWaiters := TList<TPSPThread>.Create;
end;

destructor TPSPSysLibs.Destroy;
begin
  FMt.Free;
  FUmdWaiters.Free;
  inherited;
end;

procedure TPSPSysLibs.Reset;
begin
  FUmdCallback := 0;
  FUmdActivated := False;
  FillChar(FPowerCallbacks, SizeOf(FPowerCallbacks), 0);
  FBusMHz := 111;
  FPllMHz := 222;
  FLanguage := 1;
  FButtonSwap := 1;
  FMt.Clear;
  FUmdWaiters.Clear;
end;

function TPSPSysLibs.EpochTicks: UInt64;
begin
  // 2026-01-01 00:00:00 UTC.
  Result := UnixEpochTicks + UInt64(DateTimeToUnix(EncodeDate(2026, 1, 1), True)) * 1000000;
end;

function TPSPSysLibs.NowTicks: UInt64;
begin
  Result := EpochTicks + UInt64(FKernel.NowUs);
end;

procedure TPSPSysLibs.WriteDateTime(Address: Cardinal; Ticks: UInt64);
begin
  var Unix := Int64(Ticks div 1000000) - Int64(UnixEpochTicks div 1000000);
  var DT := UnixToDateTime(Unix, True);
  var Y, Mo, D, H, Mi, S, Ms: Word;
  DecodeDateTime(DT, Y, Mo, D, H, Mi, S, Ms);
  FMemory.Write16(Address, Y);
  FMemory.Write16(Address + 2, Mo);
  FMemory.Write16(Address + 4, D);
  FMemory.Write16(Address + 6, H);
  FMemory.Write16(Address + 8, Mi);
  FMemory.Write16(Address + 10, S);
  FMemory.Write32(Address + 12, Cardinal(Ticks mod 1000000));
end;

function TPSPSysLibs.ReadDateTime(Address: Cardinal; out Ticks: UInt64): Boolean;
begin
  var Y := FMemory.Read16(Address);
  var Mo := FMemory.Read16(Address + 2);
  var D := FMemory.Read16(Address + 4);
  var H := FMemory.Read16(Address + 6);
  var Mi := FMemory.Read16(Address + 8);
  var S := FMemory.Read16(Address + 10);
  var Us := FMemory.Read32(Address + 12);
  Ticks := 0;
  var DT: TDateTime;
  if not TryEncodeDateTime(Y, Mo, D, H, Mi, S, 0, DT) then
    Exit(False);
  var Unix := DateTimeToUnix(DT, True);
  Ticks := UInt64(Int64(UnixEpochTicks div 1000000) + Unix) * 1000000 + Us;
  Result := True;
end;

{ Utils }

procedure TPSPSysLibs.hDcacheNop;
begin
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hLibcTime;
begin
  var T := Cardinal((NowTicks - UnixEpochTicks) div 1000000);
  if FHLE.Arg(0) <> 0 then
    FMemory.Write32(FHLE.Arg(0), T);
  FHLE.Result(T);
end;

procedure TPSPSysLibs.hLibcGettimeofday;
begin
  var Us := NowTicks - UnixEpochTicks;
  var P := FHLE.Arg(0);
  if P <> 0 then
  begin
    FMemory.Write32(P, Cardinal(Us div 1000000));
    FMemory.Write32(P + 4, Cardinal(Us mod 1000000));
  end;
  if FHLE.Arg(1) <> 0 then
  begin
    FMemory.Write32(FHLE.Arg(1), 0);
    FMemory.Write32(FHLE.Arg(1) + 4, 0);
  end;
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hLibcClock;
begin
  FHLE.Result(Cardinal(FKernel.NowUs));
end;

procedure TPSPSysLibs.hMd5Digest;
begin
  var Data: TBytes;
  SetLength(Data, FHLE.Arg(1));
  if Length(Data) > 0 then
    FMemory.ReadBytes(FHLE.Arg(0), Data[0], Length(Data));
  var H := THashMD5.Create;
  H.Update(Data);
  var Digest := H.HashAsBytes;
  FMemory.WriteBytes(FHLE.Arg(2), Digest[0], 16);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hSha1Digest;
begin
  var Data: TBytes;
  SetLength(Data, FHLE.Arg(1));
  if Length(Data) > 0 then
    FMemory.ReadBytes(FHLE.Arg(0), Data[0], Length(Data));
  var H := THashSHA1.Create;
  H.Update(Data);
  var Digest := H.HashAsBytes;
  FMemory.WriteBytes(FHLE.Arg(2), Digest[0], 20);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hMt19937Init;
begin
  var Ctx := FHLE.Arg(0);
  var Seed := FHLE.Arg(1);
  var MT: TArray<Cardinal>;
  SetLength(MT, 625);
  MT[0] := Seed;
  for var I := 1 to 623 do
    MT[I] := Cardinal(1812433253 * (MT[I - 1] xor (MT[I - 1] shr 30)) + Cardinal(I));
  MT[624] := 624;
  for var I := 0 to 624 do
    FMemory.Write32(Ctx + Cardinal(I) * 4, MT[I]);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hMt19937UInt;
begin
  var Ctx := FHLE.Arg(0);
  var Index := FMemory.Read32(Ctx + 624 * 4);
  if Index >= 624 then
  begin
    for var I := 0 to 623 do
    begin
      var Y := (FMemory.Read32(Ctx + Cardinal(I) * 4) and $80000000) or
        (FMemory.Read32(Ctx + Cardinal((I + 1) mod 624) * 4) and $7FFFFFFF);
      var V := FMemory.Read32(Ctx + Cardinal((I + 397) mod 624) * 4) xor (Y shr 1);
      if (Y and 1) <> 0 then
        V := V xor $9908B0DF;
      FMemory.Write32(Ctx + Cardinal(I) * 4, V);
    end;
    Index := 0;
  end;
  var Y := FMemory.Read32(Ctx + Index * 4);
  Y := Y xor (Y shr 11);
  Y := Y xor ((Y shl 7) and $9D2C5680);
  Y := Y xor ((Y shl 15) and $EFC60000);
  Y := Y xor (Y shr 18);
  FMemory.Write32(Ctx + 624 * 4, Index + 1);
  FHLE.Result(Y);
end;

procedure TPSPSysLibs.hGetGPI;
begin
  FHLE.Result(0);
end;

{ Power }

procedure TPSPSysLibs.hPowerGetCpu;
begin
  FHLE.Result(FKernel.Scheduler.MHz);
end;

procedure TPSPSysLibs.hPowerGetBus;
begin
  FHLE.Result(FBusMHz);
end;

procedure TPSPSysLibs.hPowerGetPll;
begin
  FHLE.Result(FPllMHz);
end;

procedure TPSPSysLibs.hPowerGetCpuFloat;
begin
  FHLE.ResultFloat(FKernel.Scheduler.MHz);
  FHLE.Result(FHLE.CPU.Ctx.FPR[0]);
end;

procedure TPSPSysLibs.hPowerGetBusFloat;
begin
  FHLE.ResultFloat(FBusMHz);
  FHLE.Result(FHLE.CPU.Ctx.FPR[0]);
end;

procedure TPSPSysLibs.hPowerSetClock;
begin
  var Pll := FHLE.ArgInt(0);
  var Cpu := FHLE.ArgInt(1);
  var Bus := FHLE.ArgInt(2);
  if (Cpu < 1) or (Cpu > 333) or (Bus < 1) or (Bus > 166) or (Pll < 19) or (Pll > 333) then
    begin FHLE.Result(SCE_KERNEL_ERROR_INVAL); Exit; end;
  FKernel.NowUs;
  FKernel.Scheduler.MHz := Cpu;
  FBusMHz := Bus;
  FPllMHz := Pll;
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hPowerSetCpu;
begin
  var Cpu := FHLE.ArgInt(0);
  if (Cpu < 1) or (Cpu > 333) then
    begin FHLE.Result(SCE_KERNEL_ERROR_INVAL); Exit; end;
  FKernel.NowUs;
  FKernel.Scheduler.MHz := Cpu;
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hPowerSetBus;
begin
  var Bus := FHLE.ArgInt(0);
  if (Bus < 1) or (Bus > 166) then
    begin FHLE.Result(SCE_KERNEL_ERROR_INVAL); Exit; end;
  FBusMHz := Bus;
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hPowerRegisterCallback;
begin
  var Slot := FHLE.ArgInt(0);
  var CBId := FHLE.Arg(1);
  if Slot = -1 then
  begin
    for var I := 0 to High(FPowerCallbacks) do
      if FPowerCallbacks[I] = 0 then
      begin
        Slot := I;
        Break;
      end;
    if Slot = -1 then
      begin FHLE.Result($80000022); Exit; end;
  end;
  if (Slot < 0) or (Slot > High(FPowerCallbacks)) then
    begin FHLE.Result($80000102); Exit; end;
  if FPowerCallbacks[Slot] <> 0 then
    begin FHLE.Result($80000020); Exit; end;
  var CB := TPSPCallback(FKernel.GetObject(CBId, TPSPCallback));
  if CB = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_CBID); Exit; end;
  FPowerCallbacks[Slot] := CBId;
  // The callback learns the current state: AC power, battery present, high charge.
  FKernel.NotifyCallback(CB, $00001380);
  FHLE.Result(Cardinal(Slot));
end;

procedure TPSPSysLibs.hPowerUnregisterCallback;
begin
  var Slot := FHLE.ArgInt(0);
  if (Slot < 0) or (Slot > High(FPowerCallbacks)) then
    begin FHLE.Result($80000102); Exit; end;
  if FPowerCallbacks[Slot] = 0 then
    begin FHLE.Result($80000025); Exit; end;
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

{ UMD }

function TPSPSysLibs.UmdStat: Cardinal;
begin
  // Present, initialized, ready (and readable once activated).
  if FUmdActivated then
    Result := $32
  else
    Result := $12;
end;

procedure TPSPSysLibs.hUmdActivate;
begin
  FUmdActivated := True;
  FHLE.Result(0);
  if FUmdCallback <> 0 then
  begin
    var CB := TPSPCallback(FKernel.GetObject(FUmdCallback, TPSPCallback));
    if CB <> nil then
      FKernel.NotifyCallback(CB, UmdStat);
  end;
end;

procedure TPSPSysLibs.hUmdDeactivate;
begin
  FUmdActivated := False;
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hUmdGetDriveStat;
begin
  FHLE.Result(UmdStat);
end;

procedure TPSPSysLibs.hUmdCheckMedium;
begin
  FHLE.Result(1);
end;

procedure TPSPSysLibs.hUmdWaitDriveStat;
begin
  var Want := FHLE.Arg(0);
  if (Want and UmdStat) <> 0 then
    begin FHLE.Result(0); Exit; end;
  // The drive becomes ready only through sceUmdActivate; wait for a vblank's worth.
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hUmdWaitDriveStatCB;
begin
  FHLE.Result(0);
  FKernel.CheckCallbacks;
end;

procedure TPSPSysLibs.hUmdRegisterCallback;
begin
  var CB := TPSPCallback(FKernel.GetObject(FHLE.Arg(0), TPSPCallback));
  if CB = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_CBID); Exit; end;
  FUmdCallback := FHLE.Arg(0);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hUmdUnregisterCallback;
begin
  if FHLE.Arg(0) <> FUmdCallback then
    begin FHLE.Result($80010016); Exit; end;
  FUmdCallback := 0;
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hUmdGetDiscInfo;
begin
  var P := FHLE.Arg(0);
  if (P = 0) or (FMemory.Read32(P) <> 8) then
    begin FHLE.Result($80010016); Exit; end;
  FMemory.Write32(P + 4, $10);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hUmdZero;
begin
  FHLE.Result(0);
end;

{ RTC }

procedure TPSPSysLibs.hRtcGetCurrentTick;
begin
  var T := NowTicks;
  FMemory.Write32(FHLE.Arg(0), Cardinal(T));
  FMemory.Write32(FHLE.Arg(0) + 4, Cardinal(T shr 32));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcGetTickResolution;
begin
  FHLE.Result(1000000);
end;

procedure TPSPSysLibs.hRtcGetCurrentClock;
begin
  // tz in minutes
  var T := Int64(NowTicks) + Int64(FHLE.ArgInt(1)) * 60000000;
  WriteDateTime(FHLE.Arg(0), UInt64(T));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcGetCurrentClockLocalTime;
begin
  WriteDateTime(FHLE.Arg(0), NowTicks);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcGetTick;
begin
  var T: UInt64;
  if not ReadDateTime(FHLE.Arg(0), T) then
    begin FHLE.Result($80000103); Exit; end;
  FMemory.Write32(FHLE.Arg(1), Cardinal(T));
  FMemory.Write32(FHLE.Arg(1) + 4, Cardinal(T shr 32));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcSetTick;
begin
  var P := FHLE.Arg(1);
  var T := UInt64(FMemory.Read32(P)) or (UInt64(FMemory.Read32(P + 4)) shl 32);
  WriteDateTime(FHLE.Arg(0), T);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.TickAdd(Units: Int64);
begin
  var Dst := FHLE.Arg(0);
  var Src := FHLE.Arg(1);
  var N := Int64(FHLE.Arg64(2));
  var T := Int64(UInt64(FMemory.Read32(Src)) or (UInt64(FMemory.Read32(Src + 4)) shl 32));
  T := T + N * Units;
  FMemory.Write32(Dst, Cardinal(T));
  FMemory.Write32(Dst + 4, Cardinal(UInt64(T) shr 32));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcTickAddTicks;
begin
  TickAdd(1);
end;

procedure TPSPSysLibs.hRtcTickAddMicroseconds;
begin
  TickAdd(1);
end;

procedure TPSPSysLibs.hRtcTickAddSeconds;
begin
  TickAdd(1000000);
end;

procedure TPSPSysLibs.hRtcTickAddMinutes;
begin
  TickAdd(60000000);
end;

procedure TPSPSysLibs.hRtcTickAddHours;
begin
  var Dst := FHLE.Arg(0);
  var Src := FHLE.Arg(1);
  var N := Int64(FHLE.ArgInt(2));
  var T := Int64(UInt64(FMemory.Read32(Src)) or (UInt64(FMemory.Read32(Src + 4)) shl 32));
  T := T + N * 3600000000;
  FMemory.Write32(Dst, Cardinal(T));
  FMemory.Write32(Dst + 4, Cardinal(UInt64(T) shr 32));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcTickAddDays;
begin
  var Dst := FHLE.Arg(0);
  var Src := FHLE.Arg(1);
  var N := Int64(FHLE.ArgInt(2));
  var T := Int64(UInt64(FMemory.Read32(Src)) or (UInt64(FMemory.Read32(Src + 4)) shl 32));
  T := T + N * 86400000000;
  FMemory.Write32(Dst, Cardinal(T));
  FMemory.Write32(Dst + 4, Cardinal(UInt64(T) shr 32));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcTickAddWeeks;
begin
  var Dst := FHLE.Arg(0);
  var Src := FHLE.Arg(1);
  var N := Int64(FHLE.ArgInt(2));
  var T := Int64(UInt64(FMemory.Read32(Src)) or (UInt64(FMemory.Read32(Src + 4)) shl 32));
  T := T + N * 7 * 86400000000;
  FMemory.Write32(Dst, Cardinal(T));
  FMemory.Write32(Dst + 4, Cardinal(UInt64(T) shr 32));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcTickAddMonths;
begin
  var Dst := FHLE.Arg(0);
  var Src := FHLE.Arg(1);
  var N := FHLE.ArgInt(2);
  var T := UInt64(FMemory.Read32(Src)) or (UInt64(FMemory.Read32(Src + 4)) shl 32);
  var Unix := Int64(T div 1000000) - Int64(UnixEpochTicks div 1000000);
  var DT := IncMonth(UnixToDateTime(Unix, True), N);
  var R := UInt64(Int64(UnixEpochTicks div 1000000) + DateTimeToUnix(DT, True)) * 1000000 + T mod 1000000;
  FMemory.Write32(Dst, Cardinal(R));
  FMemory.Write32(Dst + 4, Cardinal(R shr 32));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcTickAddYears;
begin
  var Dst := FHLE.Arg(0);
  var Src := FHLE.Arg(1);
  var N := FHLE.ArgInt(2);
  var T := UInt64(FMemory.Read32(Src)) or (UInt64(FMemory.Read32(Src + 4)) shl 32);
  var Unix := Int64(T div 1000000) - Int64(UnixEpochTicks div 1000000);
  var DT := IncYear(UnixToDateTime(Unix, True), N);
  var R := UInt64(Int64(UnixEpochTicks div 1000000) + DateTimeToUnix(DT, True)) * 1000000 + T mod 1000000;
  FMemory.Write32(Dst, Cardinal(R));
  FMemory.Write32(Dst + 4, Cardinal(R shr 32));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcCompareTick;
begin
  var A := UInt64(FMemory.Read32(FHLE.Arg(0))) or (UInt64(FMemory.Read32(FHLE.Arg(0) + 4)) shl 32);
  var B := UInt64(FMemory.Read32(FHLE.Arg(1))) or (UInt64(FMemory.Read32(FHLE.Arg(1) + 4)) shl 32);
  if A < B then FHLE.Result($FFFFFFFF)
  else if A > B then FHLE.Result(1)
  else FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcConvertCopy;
begin
  FMemory.Write32(FHLE.Arg(1), FMemory.Read32(FHLE.Arg(0)));
  FMemory.Write32(FHLE.Arg(1) + 4, FMemory.Read32(FHLE.Arg(0) + 4));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcGetDaysInMonth;
begin
  var Y := FHLE.ArgInt(0);
  var M := FHLE.ArgInt(1);
  if (M < 1) or (M > 12) or (Y < 1) then
    begin FHLE.Result($80000102); Exit; end;
  FHLE.Result(DaysInAMonth(Y, M));
end;

procedure TPSPSysLibs.hRtcGetDayOfWeek;
begin
  var DT: TDateTime;
  if not TryEncodeDate(FHLE.ArgInt(0), FHLE.ArgInt(1), FHLE.ArgInt(2), DT) then
    begin FHLE.Result(0); Exit; end;
  FHLE.Result(Cardinal(DayOfWeek(DT) - 1));
end;

procedure TPSPSysLibs.hRtcIsLeapYear;
begin
  FHLE.Result(Ord(IsLeapYear(FHLE.ArgInt(0))));
end;

procedure TPSPSysLibs.hRtcCheckValid;
begin
  var T: UInt64;
  if ReadDateTime(FHLE.Arg(0), T) then
    FHLE.Result(0)
  else
    FHLE.Result($FFFFFFFF);
end;

procedure TPSPSysLibs.hRtcGetTime_t;
begin
  var T: UInt64;
  ReadDateTime(FHLE.Arg(0), T);
  FMemory.Write32(FHLE.Arg(1), Cardinal((T - UnixEpochTicks) div 1000000));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcSetTime_t;
begin
  WriteDateTime(FHLE.Arg(0), UnixEpochTicks + UInt64(FHLE.Arg(1)) * 1000000);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcGetTime64_t;
begin
  var T: UInt64;
  ReadDateTime(FHLE.Arg(0), T);
  var S := (T - UnixEpochTicks) div 1000000;
  FMemory.Write32(FHLE.Arg(1), Cardinal(S));
  FMemory.Write32(FHLE.Arg(1) + 4, Cardinal(S shr 32));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcSetTime64_t;
begin
  WriteDateTime(FHLE.Arg(0), UnixEpochTicks + FHLE.Arg64(2) * 1000000);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcGetAccumulativeTime;
begin
  FHLE.Result64(NowTicks);
end;

{ Impose, Hprm, Dmac, misc }

procedure TPSPSysLibs.hImposeGetLanguageMode;
begin
  if FHLE.Arg(0) <> 0 then FMemory.Write32(FHLE.Arg(0), FLanguage);
  if FHLE.Arg(1) <> 0 then FMemory.Write32(FHLE.Arg(1), FButtonSwap);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hImposeGetBatteryIconStatus;
begin
  if FHLE.Arg(0) <> 0 then FMemory.Write32(FHLE.Arg(0), 0);
  if FHLE.Arg(1) <> 0 then FMemory.Write32(FHLE.Arg(1), 3);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hImposeZero;
begin
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hImposeGetHomePopup;
begin
  FHLE.Result(1);
end;

procedure TPSPSysLibs.hHprmZero;
begin
  if FHLE.Arg(0) <> 0 then
    FMemory.Write32(FHLE.Arg(0), 0);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hDmacMemcpy;
begin
  var Dst := FHLE.Arg(0);
  var Src := FHLE.Arg(1);
  var Size := FHLE.Arg(2);
  if (Size = 0) then
    begin FHLE.Result(SCE_KERNEL_ERROR_INVALID_SIZE); Exit; end;
  if (Dst = 0) or (Src = 0) then
    begin FHLE.Result(SCE_KERNEL_ERROR_INVALID_POINTER); Exit; end;
  FMemory.Copy(Dst, Src, Size);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hGetPSID;
begin
  var P := FHLE.Arg(0);
  for var I := 0 to 15 do
    FMemory.Write8(P + Cardinal(I), Cardinal(I) * 17);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hZero;
begin
  FHLE.Result(0);
end;

procedure TPSPSysLibs.Register;
const
  U = 'UtilsForUser';
  P = 'scePower';
  M = 'sceUmdUser';
  R = 'sceRtc';
  I = 'sceImpose';
begin
  var H := FHLE;
  for var NID in [Cardinal($79D1C3FA), $B435DEC5, $3EE30821, $34B9FA9E, $BFA98062, $920F104A, $C2DF770E,
    $80001C4C, $16641D70, $4FD31C9D, $FB05FAD0] do
    H.Register(U, NID, Format('sceKernelDcache_%.8X', [NID]), hDcacheNop);
  H.Register(U, $27CC57F0, 'sceKernelLibcTime', hLibcTime);
  H.Register(U, $71EC4271, 'sceKernelLibcGettimeofday', hLibcGettimeofday);
  H.Register(U, $91E4F6A7, 'sceKernelLibcClock', hLibcClock);
  H.Register(U, $C8186A58, 'sceKernelUtilsMd5Digest', hMd5Digest);
  H.Register(U, $840259F1, 'sceKernelUtilsSha1Digest', hSha1Digest);
  H.Register(U, $E860E75E, 'sceKernelUtilsMt19937Init', hMt19937Init);
  H.Register(U, $06FB8A63, 'sceKernelUtilsMt19937UInt', hMt19937UInt);
  H.Register(U, $37FB5C42, 'sceKernelGetGPI', hGetGPI);
  H.Register(U, $6AD345D7, 'sceKernelSetGPO', hZero);
  H.Register(P, $FDB5BFE9, 'scePowerGetCpuClockFrequencyInt', hPowerGetCpu);
  H.Register(P, $FEE03A2F, 'scePowerGetCpuClockFrequency', hPowerGetCpu);
  H.Register(P, $BD681969, 'scePowerGetBusClockFrequencyInt', hPowerGetBus);
  H.Register(P, $478FE6F5, 'scePowerGetBusClockFrequency', hPowerGetBus);
  H.Register(P, $34F9C463, 'scePowerGetPllClockFrequencyInt', hPowerGetPll);
  H.Register(P, $B1A52C83, 'scePowerGetCpuClockFrequencyFloat', hPowerGetCpuFloat);
  H.Register(P, $9BADB3EB, 'scePowerGetBusClockFrequencyFloat', hPowerGetBusFloat);
  H.Register(P, $737486F2, 'scePowerSetClockFrequency', hPowerSetClock);
  H.Register(P, $545A7F3C, 'scePowerSetClockFrequency2', hPowerSetClock);
  H.Register(P, $EBD177D6, 'scePowerSetClockFrequency3', hPowerSetClock);
  H.Register(P, $843FBF43, 'scePowerSetCpuClockFrequency', hPowerSetCpu);
  H.Register(P, $B8D7B3FB, 'scePowerSetBusClockFrequency', hPowerSetBus);
  H.Register(P, $04B7766E, 'scePowerRegisterCallback', hPowerRegisterCallback);
  H.Register(P, $DFA8BAF8, 'scePowerUnregisterCallback', hPowerUnregisterCallback);
  H.Register(P, $DB9D28DD, 'scePowerUnregitserCallback', hPowerUnregisterCallback);
  H.Register(P, $2085D15D, 'scePowerGetBatteryLifePercent', hPowerBatteryPercent);
  H.Register(P, $87440F5E, 'scePowerIsPowerOnline', hPowerOne);
  H.Register(P, $0AFD0D8B, 'scePowerIsBatteryExist', hPowerOne);
  H.Register(P, $1E490401, 'scePowerIsBatteryCharging', hPowerZero);
  H.Register(P, $D3075926, 'scePowerIsLowBattery', hPowerZero);
  H.Register(P, $B4432BC8, 'scePowerGetBatteryChargingStatus', hPowerZero);
  H.Register(P, $8EFB3FA2, 'scePowerGetBatteryLifeTime', hPowerBatteryLifeTime);
  H.Register(P, $28E12023, 'scePowerGetBatteryTemp', hPowerBatteryTemp);
  H.Register(P, $483CE86B, 'scePowerGetBatteryVolt', hPowerBatteryVolt);
  H.Register(P, $EFD3C963, 'scePowerTick', hPowerZero);
  H.Register(P, $D6D016EF, 'scePowerLock', hPowerZero);
  H.Register(P, $CA3D34C1, 'scePowerUnlock', hPowerZero);
  H.Register(P, $7F30B3B1, 'scePowerIdleTimerEnable', hPowerZero);
  H.Register(P, $972CE941, 'scePowerIdleTimerDisable', hPowerZero);
  H.Register(P, $DB62C9CF, 'scePowerCancelRequest', hPowerZero);
  H.Register(P, $78A1A796, 'scePowerIsSuspendRequired', hPowerZero);
  H.Register(P, $7FA406DD, 'scePowerIsRequest', hPowerZero);
  H.Register(P, $2B7C7CF4, 'scePowerRequestStandby', hPowerZero);
  H.Register(P, $AC32C9CC, 'scePowerRequestSuspend', hPowerZero);
  H.Register(P, $0442D852, 'scePowerRequestColdReset', hPowerZero);
  H.Register(P, $94F5A53F, 'scePowerGetBatteryRemainCapacity', hPowerBatteryLifeTime);
  H.Register(P, $FD18A0FF, 'scePowerGetBatteryFullCapacity', hPowerBatteryLifeTime);
  H.Register(P, $862AE1A6, 'scePowerGetBatteryElec', hPowerZero);
  H.Register(P, $23436A4A, 'scePowerGetInnerTemp', hPowerBatteryTemp);
  H.Register(P, $0CD21B1F, 'scePowerSetPowerSwMode', hPowerZero);
  H.Register(P, $165CE085, 'scePowerGetPowerSwMode', hPowerZero);
  H.Register(P, $27F3292C, 'scePowerBatteryUpdateInfo', hPowerZero);
  H.Register(P, $E8E4E204, 'scePowerGetForceSuspendCapacity', hPowerZero);
  H.Register(P, $B999184C, 'scePowerGetLowBatteryCapacity', hPowerZero);
  H.Register(P, $EDC13FE5, 'scePowerGetIdleTimer', hPowerZero);
  H.Register(P, $442BFBAC, 'scePowerGetBacklightMaximum', hPowerZero);
  H.Register(P, $2B51FE2F, 'scePowerGetWlanActivity', hPowerZero);
  H.Register(P, $0074EF9B, 'scePowerGetResumeCount', hPowerZero);
  H.Register(M, $C6183D47, 'sceUmdActivate', hUmdActivate);
  H.Register(M, $E83742BA, 'sceUmdDeactivate', hUmdDeactivate);
  H.Register(M, $6B4A146C, 'sceUmdGetDriveStat', hUmdGetDriveStat);
  H.Register(M, $46EBB729, 'sceUmdCheckMedium', hUmdCheckMedium);
  H.Register(M, $8EF08FCE, 'sceUmdWaitDriveStat', hUmdWaitDriveStat);
  H.Register(M, $56202973, 'sceUmdWaitDriveStatWithTimer', hUmdWaitDriveStat);
  H.Register(M, $4A9E5E29, 'sceUmdWaitDriveStatCB', hUmdWaitDriveStatCB);
  H.Register(M, $AEE7404D, 'sceUmdRegisterUMDCallBack', hUmdRegisterCallback);
  H.Register(M, $BD2BDE07, 'sceUmdUnRegisterUMDCallBack', hUmdUnregisterCallback);
  H.Register(M, $340B7686, 'sceUmdGetDiscInfo', hUmdGetDiscInfo);
  H.Register(M, $20628E6F, 'sceUmdGetErrorStat', hUmdZero);
  H.Register(M, $6AF9B50A, 'sceUmdCancelWaitDriveStat', hUmdZero);
  H.Register(M, $87533940, 'sceUmdReplaceProhibit', hUmdZero);
  H.Register(M, $CBE9F02A, 'sceUmdReplacePermit', hUmdZero);
  H.Register(R, $3F7AD767, 'sceRtcGetCurrentTick', hRtcGetCurrentTick);
  H.Register(R, $C41C2853, 'sceRtcGetTickResolution', hRtcGetTickResolution);
  H.Register(R, $4CFA57B0, 'sceRtcGetCurrentClock', hRtcGetCurrentClock);
  H.Register(R, $E7C27D1B, 'sceRtcGetCurrentClockLocalTime', hRtcGetCurrentClockLocalTime);
  H.Register(R, $6FF40ACC, 'sceRtcGetTick', hRtcGetTick);
  H.Register(R, $7ED29E40, 'sceRtcSetTick', hRtcSetTick);
  H.Register(R, $44F45E05, 'sceRtcTickAddTicks', hRtcTickAddTicks);
  H.Register(R, $26D25A5D, 'sceRtcTickAddMicroseconds', hRtcTickAddMicroseconds);
  H.Register(R, $F2A4AFE5, 'sceRtcTickAddSeconds', hRtcTickAddSeconds);
  H.Register(R, $E6605BCA, 'sceRtcTickAddMinutes', hRtcTickAddMinutes);
  H.Register(R, $26D7A24A, 'sceRtcTickAddHours', hRtcTickAddHours);
  H.Register(R, $E51B4B7A, 'sceRtcTickAddDays', hRtcTickAddDays);
  H.Register(R, $CF3A2CA8, 'sceRtcTickAddWeeks', hRtcTickAddWeeks);
  H.Register(R, $DBF74F1B, 'sceRtcTickAddMonths', hRtcTickAddMonths);
  H.Register(R, $42842C77, 'sceRtcTickAddYears', hRtcTickAddYears);
  H.Register(R, $9ED0AE87, 'sceRtcCompareTick', hRtcCompareTick);
  H.Register(R, $34885E0D, 'sceRtcConvertUtcToLocalTime', hRtcConvertCopy);
  H.Register(R, $779242A2, 'sceRtcConvertLocalTimeToUTC', hRtcConvertCopy);
  H.Register(R, $05EF322C, 'sceRtcGetDaysInMonth', hRtcGetDaysInMonth);
  H.Register(R, $57726BC1, 'sceRtcGetDayOfWeek', hRtcGetDayOfWeek);
  H.Register(R, $42307A17, 'sceRtcIsLeapYear', hRtcIsLeapYear);
  H.Register(R, $4B1B5E82, 'sceRtcCheckValid', hRtcCheckValid);
  H.Register(R, $27C4594C, 'sceRtcGetTime_t', hRtcGetTime_t);
  H.Register(R, $3A807CC8, 'sceRtcSetTime_t', hRtcSetTime_t);
  H.Register(R, $E1C93E47, 'sceRtcGetTime64_t', hRtcGetTime64_t);
  H.Register(R, $1909C99B, 'sceRtcSetTime64_t', hRtcSetTime64_t);
  H.Register(R, $011F03C1, 'sceRtcGetAccumulativeTime', hRtcGetAccumulativeTime);
  H.Register(R, $029CA3B3, 'sceRtcGetAccumlativeTime', hRtcGetAccumulativeTime);
  H.Register(I, $24FD7BCF, 'sceImposeGetLanguageMode', hImposeGetLanguageMode);
  H.Register(I, $36AA6E91, 'sceImposeSetLanguageMode', hImposeZero);
  H.Register(I, $8C943191, 'sceImposeGetBatteryIconStatus', hImposeGetBatteryIconStatus);
  H.Register(I, $381BD9E7, 'sceImposeHomeButton', hImposeZero);
  H.Register(I, $5595A71A, 'sceImposeSetHomePopup', hImposeZero);
  H.Register(I, $0F341BE4, 'sceImposeGetHomePopup', hImposeGetHomePopup);
  H.Register(I, $72189C48, 'sceImposeSetUMDPopup', hImposeZero);
  H.Register(I, $E0887BC8, 'sceImposeGetUMDPopup', hImposeGetHomePopup);
  H.Register(I, $8F6E3518, 'sceImposeGetBacklightOffTime', hImposeZero);
  H.Register(I, $967F6D4A, 'sceImposeSetBacklightOffTime', hImposeZero);
  H.Register('sceHprm', $1910B327, 'sceHprmPeekCurrentKey', hHprmZero);
  H.Register('sceHprm', $2BCEC83E, 'sceHprmPeekLatch', hHprmZero);
  H.Register('sceHprm', $40D2F9F0, 'sceHprmReadLatch', hHprmZero);
  H.Register('sceHprm', $208DB1BD, 'sceHprmIsRemoteExist', hZero);
  H.Register('sceHprm', $7E69EDA4, 'sceHprmIsHeadphoneExist', hZero);
  H.Register('sceHprm', $219C58F1, 'sceHprmIsMicrophoneExist', hZero);
  H.Register('sceHprm', $C7154136, 'sceHprmRegisterCallback', hZero);
  H.Register('sceHprm', $444ED0B7, 'sceHprmUnregisterCallback', hZero);
  H.Register('sceDmac', $617F3FE6, 'sceDmacMemcpy', hDmacMemcpy);
  H.Register('sceDmac', $D97F94D8, 'sceDmacTryMemcpy', hDmacMemcpy);
  H.Register('sceOpenPSID', $C69BEBCE, 'sceOpenPSIDGetOpenPSID', hGetPSID);
  H.Register('sceWlanDrv', $93440B11, 'sceWlanDevIsPowerOn', hZero);
  H.Register('sceWlanDrv', $D7763699, 'sceWlanGetSwitchState', hZero);
  H.Register('sceWlanDrv', $0C622081, 'sceWlanGetEtherAddr', hZero);
end;

initialization
  RegisterPSPService(TPSPSysLibs);

end.
