unit PSP.SysLibs;

// Small system libraries: UtilsForUser, scePower, sceUmdUser, sceRtc,
// sceImpose, sceHprm, sceDmac, sceOpenPSID and offline network stubs.
// Wall-clock time is a fixed epoch plus guest time, so runs repeat exactly.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}

interface

uses
  System.SysUtils, System.Generics.Collections, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel, PSP.Scheduler,
  PSP.Service;

type
  // The UMD drive state as the threads waiting on it see it (an event flag in the firmware).
  TPSPUmdDrive = class(TPSPKernelObject)
  public
    Waiters: TList<TPSPThread>;
    constructor Create;
    destructor Destroy; override;
    procedure RemoveWaiter(T: TPSPThread); override;
    procedure AddWaiter(T: TPSPThread); override;
  end;

  TPSPDate = record
    Year, Month, Day, Hour, Minute, Second: Cardinal;
    Microsecond: Cardinal;
  end;

  TPSPSysLibs = class(TPSPService)
  private
    FUmdCallback: Cardinal;
    FUmdActivated: Boolean;
    FUmd: TPSPUmdDrive;
    FUmdTimeout: Cardinal;
    FPowerCallbacks: array[0..15] of Cardinal;
    // PLL = 1332 / FPllN MHz, CPU = PLL * FCpuK / 511.
    FPllN: Integer;
    FCpuK: Integer;
    function EpochTicks: UInt64;
    function NowTicks: UInt64;
    function LocalOffsetTicks: Int64;
    procedure WriteDate(Address: Cardinal; Ticks: UInt64);
    function ReadDate(Address: Cardinal): TPSPDate;
    function ReadTick(Address: Cardinal): UInt64;
    procedure WriteTick(Address: Cardinal; Ticks: UInt64);
    function PllFloat: Single;
    function CpuFloat: Single;
    function BusFloat: Single;
    procedure ApplyCpuClock;
    function UmdStat: Cardinal;
    procedure UmdChanged(Arg: Cardinal);
    function UmdRetry(T: TPSPThread): Boolean;
    function UmdSatisfiedRetry(T: TPSPThread): Boolean;
    procedure UmdWait(AllowCB, HasTimer: Boolean);
    function UmdDriveArgs(Mode, Drive: Cardinal): Boolean;
    procedure CallKernel(const Lib: string; NID: Cardinal);
    // Utils
    procedure hDcacheNop;
    procedure hDcacheWritebackRange;
    procedure hDcacheInvalidateRange;
    procedure hLibcTime;
    procedure hLibcGettimeofday;
    procedure hLibcClock;
    procedure hMd5Digest;
    procedure hMd5BlockInit;
    procedure hMd5BlockUpdate;
    procedure hMd5BlockResult;
    procedure hSha1Digest;
    procedure hSha1BlockInit;
    procedure hSha1BlockUpdate;
    procedure hSha1BlockResult;
    procedure hMt19937Init;
    procedure hMt19937UInt;
    procedure hGetGPI;
    // Power
    procedure hPowerGetCpu;
    procedure hPowerGetBus;
    procedure hPowerGetPll;
    procedure hPowerGetCpuFloat;
    procedure hPowerGetBusFloat;
    procedure hPowerGetPllFloat;
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
    procedure hPowerVolatileLock;
    procedure hPowerVolatileTryLock;
    procedure hPowerVolatileUnlock;
    procedure hKernelPowerLock;
    procedure hKernelPowerTick;
    // UMD
    procedure hUmdActivate;
    procedure hUmdDeactivate;
    procedure hUmdGetDriveStat;
    procedure hUmdCheckMedium;
    procedure hUmdWaitDriveStat;
    procedure hUmdWaitDriveStatWithTimer;
    procedure hUmdWaitDriveStatCB;
    procedure hUmdCancelWaitDriveStat;
    procedure hUmdRegisterCallback;
    procedure hUmdUnregisterCallback;
    procedure hUmdGetDiscInfo;
    procedure hUmdZero;
    // RTC
    procedure hRtcGetCurrentTick;
    procedure hRtcGetTickResolution;
    procedure hRtcGetCurrentClock;
    procedure hRtcGetCurrentClockLocalTime;
    procedure hRtcConvertUtcToLocal;
    procedure hRtcConvertLocalToUtc;
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
    procedure hRtcGetDaysInMonth;
    procedure hRtcGetDayOfWeek;
    procedure hRtcIsLeapYear;
    procedure hRtcCheckValid;
    procedure hRtcGetTime_t;
    procedure hRtcSetTime_t;
    procedure hRtcGetTime64_t;
    procedure hRtcSetTime64_t;
    procedure hRtcGetDosTime;
    procedure hRtcSetDosTime;
    procedure hRtcGetWin32FileTime;
    procedure hRtcSetWin32FileTime;
    procedure hRtcGetAccumulativeTime;
    procedure hRtcFormatRFC2822;
    procedure hRtcFormatRFC2822Local;
    procedure hRtcFormatRFC3339;
    procedure hRtcFormatRFC3339Local;
    procedure hRtcParseDateTime;
    procedure hRtcGetLastTime;
    procedure TickAdd(Units: UInt64; Count: UInt64);
    procedure TickAddMonths(Months: Int64);
    // Impose, Hprm, Dmac, misc
    procedure hImposeGetLanguageMode;
    procedure hImposeGetBatteryIconStatus;
    procedure hImposeZero;
    procedure hImposeGetHomePopup;
    procedure hHprmZero;
    procedure hDmacMemcpy;
    procedure hGetPSID;
    procedure hZero;
  public
    constructor Create(System: TPSPSystem); override;
    destructor Destroy; override;
    procedure Reset; override;
    procedure Register; override;
  end;

// Calendar on the proleptic Gregorian calendar; days count from 0001-01-01.
function PSPDaysFromCivil(Y, M, D: Int64): Int64;
procedure PSPCivilFromDays(Days: Int64; out Y, M, D: Int64);
function PSPIsLeapYear(Y: Int64): Boolean;
function PSPDaysInMonth(Y, M: Int64): Integer;
// 0 when the date is valid, else -1 (year) .. -7 (microseconds) for the first bad field.
function PSPCheckDate(const D: TPSPDate): Integer;
function PSPDateToTicks(const D: TPSPDate): UInt64;
function PSPTicksToDate(Ticks: UInt64): TPSPDate;

const
  PSPTicksPerDay: UInt64 = 86400000000;
  PSPUnixEpochTicks: UInt64 = 62135596800000000;

implementation

uses
  System.Math, PSP.Settings;

{$I PSP.SysLibs.Hash.inc}
{$I PSP.SysLibs.Rtc.inc}
{$I PSP.SysLibs.Power.inc}

{ TPSPUmdDrive }

constructor TPSPUmdDrive.Create;
begin
  inherited Create;
  Waiters := TList<TPSPThread>.Create;
end;

destructor TPSPUmdDrive.Destroy;
begin
  Waiters.Free;
  inherited;
end;

procedure TPSPUmdDrive.RemoveWaiter(T: TPSPThread);
begin
  Waiters.Remove(T);
end;

procedure TPSPUmdDrive.AddWaiter(T: TPSPThread);
begin
  if not Waiters.Contains(T) then
    Waiters.Add(T);
end;

{ TPSPSysLibs }

constructor TPSPSysLibs.Create(System: TPSPSystem);
begin
  inherited Create(System);
  FUmd := TPSPUmdDrive.Create;
  FUmd.Name := 'SceUmdDriveStat';
end;

destructor TPSPSysLibs.Destroy;
begin
  FUmd.Free;
  inherited;
end;

procedure TPSPSysLibs.Reset;
begin
  FUmdCallback := 0;
  FUmdActivated := False;
  FUmd.Waiters.Clear;
  FUmd.Kernel := FKernel;
  // A word the kernel reads wait timeouts from (it takes them by pointer).
  FUmdTimeout := FKernel.AllocKernel(16, 'umd timeout');
  FillChar(FPowerCallbacks, SizeOf(FPowerCallbacks), 0);
  FPllN := 6;
  FCpuK := 511;
end;

procedure TPSPSysLibs.CallKernel(const Lib: string; NID: Cardinal);
begin
  var F := FHLE.FunctionInfo(FHLE.Find(Lib, NID));
  if (F <> nil) and Assigned(F.Handler) then
    F.Handler()
  else
    FHLE.Result(0);
end;

{ Utils }

procedure TPSPSysLibs.hDcacheNop;
begin
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hDcacheWritebackRange;
begin
  if FHLE.ArgInt(1) < 0 then
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_SIZE)
  else
    FHLE.Result(0);
end;

procedure TPSPSysLibs.hDcacheInvalidateRange;
begin
  var P := FHLE.Arg(0);
  var Size := FHLE.Arg(1);
  // Invalidating a range that is not whole cache lines would lose neighbouring data.
  if Integer(P or Size or (P + Size)) < 0 then
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR)
  else if Size = 0 then
    FHLE.Result(0)
  else if ((P or Size) and 63) <> 0 then
    FHLE.Result($8002044C)
  else
    FHLE.Result(0);
end;

procedure TPSPSysLibs.hLibcTime;
begin
  var T := Cardinal((NowTicks - PSPUnixEpochTicks) div 1000000);
  if FHLE.Arg(0) <> 0 then
    FMemory.Write32(FHLE.Arg(0), T);
  FHLE.Result(T);
end;

procedure TPSPSysLibs.hLibcGettimeofday;
begin
  var Us := NowTicks - PSPUnixEpochTicks;
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

procedure TPSPSysLibs.hGetGPI;
begin
  FHLE.Result(0);
end;

{ Impose, Hprm, Dmac, misc }

procedure TPSPSysLibs.hImposeGetLanguageMode;
begin
  if FHLE.Arg(0) <> 0 then FMemory.Write32(FHLE.Arg(0), Cardinal(PSPSettings.Language));
  if FHLE.Arg(1) <> 0 then FMemory.Write32(FHLE.Arg(1), Cardinal(PSPSettings.ButtonSwap));
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
  if Size = 0 then
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

{$I PSP.SysLibs.Umd.inc}
{$I PSP.SysLibs.Register.inc}

initialization
  RegisterPSPService(TPSPSysLibs);

end.
