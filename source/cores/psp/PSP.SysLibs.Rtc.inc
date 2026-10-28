{ PSP.SysLibs: sceRtc. Ticks are microseconds since 0001-01-01 00:00:00 on the
  proleptic Gregorian calendar; arithmetic wraps at 64 bits like the
  firmware's, and the year field of a date is 16 bits. }

const
  DaysTo1970 = 719162;
  TicksPerSec = 1000000;
  WeekDayNames: array[0..6] of string = ('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat');
  WeekDayLong: array[0..6] of string = ('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday');
  MonthNames: array[1..12] of string = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec');

function PSPDaysFromCivil(Y, M, D: Int64): Int64;
begin
  if M <= 2 then
    Dec(Y);
  var Era: Int64;
  if Y >= 0 then
    Era := Y div 400
  else
    Era := (Y - 399) div 400;
  var Yoe := Y - Era * 400;
  var Doy := (153 * ((M + 9) mod 12) + 2) div 5 + D - 1;
  var Doe := Yoe * 365 + Yoe div 4 - Yoe div 100 + Doy;
  Result := Era * 146097 + Doe - 719468 + DaysTo1970;
end;

procedure PSPCivilFromDays(Days: Int64; out Y, M, D: Int64);
begin
  var Z := Days - DaysTo1970 + 719468;
  var Era: Int64;
  if Z >= 0 then
    Era := Z div 146097
  else
    Era := (Z - 146096) div 146097;
  var Doe := Z - Era * 146097;
  var Yoe := (Doe - Doe div 1460 + Doe div 36524 - Doe div 146096) div 365;
  Y := Yoe + Era * 400;
  var Doy := Doe - (365 * Yoe + Yoe div 4 - Yoe div 100);
  var Mp := (5 * Doy + 2) div 153;
  D := Doy - (153 * Mp + 2) div 5 + 1;
  if Mp < 10 then
    M := Mp + 3
  else
    M := Mp - 9;
  if M <= 2 then
    Inc(Y);
end;

function PSPIsLeapYear(Y: Int64): Boolean;
begin
  Result := ((Y mod 4 = 0) and (Y mod 100 <> 0)) or (Y mod 400 = 0);
end;

function PSPDaysInMonth(Y, M: Int64): Integer;
const
  Days: array[1..12] of Integer = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);
begin
  if (M < 1) or (M > 12) then
    Exit(0);
  Result := Days[M];
  if (M = 2) and PSPIsLeapYear(Y) then
    Result := 29;
end;

function PSPCheckDate(const D: TPSPDate): Integer;
begin
  if (D.Year < 1) or (D.Year > 9999) then Exit(-1);
  if (D.Month < 1) or (D.Month > 12) then Exit(-2);
  if (D.Day < 1) or (Integer(D.Day) > PSPDaysInMonth(D.Year, D.Month)) then Exit(-3);
  if D.Hour > 23 then Exit(-4);
  if D.Minute > 59 then Exit(-5);
  if D.Second > 59 then Exit(-6);
  if D.Microsecond >= 1000000 then Exit(-7);
  Result := 0;
end;

function PSPDateToTicks(const D: TPSPDate): UInt64;
begin
  Result := UInt64(PSPDaysFromCivil(D.Year, D.Month, D.Day)) * PSPTicksPerDay +
    UInt64(D.Hour) * 3600000000 + UInt64(D.Minute) * 60000000 + UInt64(D.Second) * TicksPerSec + D.Microsecond;
end;

function PSPTicksToDate(Ticks: UInt64): TPSPDate;
begin
  var Y, M, D: Int64;
  PSPCivilFromDays(Int64(Ticks div PSPTicksPerDay), Y, M, D);
  var Rem := Ticks mod PSPTicksPerDay;
  Result.Year := Cardinal(Y) and $FFFF;
  Result.Month := M;
  Result.Day := D;
  Result.Hour := Rem div 3600000000;
  Result.Minute := (Rem div 60000000) mod 60;
  Result.Second := (Rem div TicksPerSec) mod 60;
  Result.Microsecond := Rem mod TicksPerSec;
end;

function TicksWeekDay(Ticks: UInt64): Integer;
begin
  // 0001-01-01 was a Monday.
  Result := Integer((Ticks div PSPTicksPerDay + 1) mod 7);
end;

function TPSPSysLibs.EpochTicks: UInt64;
begin
  // 2026-01-01 00:00:00 UTC.
  Result := UInt64(PSPDaysFromCivil(2026, 1, 1)) * PSPTicksPerDay;
end;

function TPSPSysLibs.NowTicks: UInt64;
begin
  Result := EpochTicks + UInt64(FKernel.NowUs);
end;

function TPSPSysLibs.LocalOffsetTicks: Int64;
begin
  Result := Int64(PSPSettings.Timezone + 60 * PSPSettings.DaylightSaving) * 60000000;
end;

procedure TPSPSysLibs.WriteDate(Address: Cardinal; Ticks: UInt64);
begin
  var D := PSPTicksToDate(Ticks);
  FMemory.Write16(Address, D.Year);
  FMemory.Write16(Address + 2, D.Month);
  FMemory.Write16(Address + 4, D.Day);
  FMemory.Write16(Address + 6, D.Hour);
  FMemory.Write16(Address + 8, D.Minute);
  FMemory.Write16(Address + 10, D.Second);
  FMemory.Write32(Address + 12, D.Microsecond);
end;

function TPSPSysLibs.ReadDate(Address: Cardinal): TPSPDate;
begin
  Result.Year := FMemory.Read16(Address);
  Result.Month := FMemory.Read16(Address + 2);
  Result.Day := FMemory.Read16(Address + 4);
  Result.Hour := FMemory.Read16(Address + 6);
  Result.Minute := FMemory.Read16(Address + 8);
  Result.Second := FMemory.Read16(Address + 10);
  Result.Microsecond := FMemory.Read32(Address + 12);
end;

function TPSPSysLibs.ReadTick(Address: Cardinal): UInt64;
begin
  Result := UInt64(FMemory.Read32(Address)) or (UInt64(FMemory.Read32(Address + 4)) shl 32);
end;

procedure TPSPSysLibs.WriteTick(Address: Cardinal; Ticks: UInt64);
begin
  FMemory.Write32(Address, Cardinal(Ticks));
  FMemory.Write32(Address + 4, Cardinal(Ticks shr 32));
end;

procedure TPSPSysLibs.hRtcGetCurrentTick;
begin
  WriteTick(FHLE.Arg(0), NowTicks);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcGetTickResolution;
begin
  FHLE.Result(TicksPerSec);
end;

procedure TPSPSysLibs.hRtcGetCurrentClock;
begin
  WriteDate(FHLE.Arg(0), UInt64(Int64(NowTicks) + Int64(FHLE.ArgInt(1)) * 60000000));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcGetCurrentClockLocalTime;
begin
  WriteDate(FHLE.Arg(0), UInt64(Int64(NowTicks) + LocalOffsetTicks));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcConvertUtcToLocal;
begin
  WriteTick(FHLE.Arg(1), UInt64(Int64(ReadTick(FHLE.Arg(0))) + LocalOffsetTicks));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcConvertLocalToUtc;
begin
  WriteTick(FHLE.Arg(1), UInt64(Int64(ReadTick(FHLE.Arg(0))) - LocalOffsetTicks));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcGetTick;
begin
  var D := ReadDate(FHLE.Arg(0));
  // The microseconds are added as they are, without a range check.
  var V := PSPCheckDate(D);
  if (V <> 0) and (V <> -7) then
    begin FHLE.Result(SCE_KERNEL_ERROR_INVALID_VALUE); Exit; end;
  WriteTick(FHLE.Arg(1), PSPDateToTicks(D));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcSetTick;
begin
  WriteDate(FHLE.Arg(0), ReadTick(FHLE.Arg(1)));
  FHLE.Result(0);
end;

// Tick arithmetic is modulo 2^64, including negative counts.
{$Q-}
procedure TPSPSysLibs.TickAdd(Units: UInt64; Count: UInt64);
begin
  WriteTick(FHLE.Arg(0), ReadTick(FHLE.Arg(1)) + Count * Units);
  FHLE.Result(0);
end;
{$IFDEF PSP_CHECKED}{$Q+}{$ENDIF}

procedure TPSPSysLibs.hRtcTickAddTicks;
begin
  TickAdd(1, FHLE.Arg64(2));
end;

procedure TPSPSysLibs.hRtcTickAddMicroseconds;
begin
  TickAdd(1, FHLE.Arg64(2));
end;

procedure TPSPSysLibs.hRtcTickAddSeconds;
begin
  TickAdd(TicksPerSec, FHLE.Arg64(2));
end;

procedure TPSPSysLibs.hRtcTickAddMinutes;
begin
  TickAdd(60000000, FHLE.Arg64(2));
end;

procedure TPSPSysLibs.hRtcTickAddHours;
begin
  TickAdd(3600000000, UInt64(Int64(FHLE.ArgInt(2))));
end;

procedure TPSPSysLibs.hRtcTickAddDays;
begin
  TickAdd(PSPTicksPerDay, UInt64(Int64(FHLE.ArgInt(2))));
end;

procedure TPSPSysLibs.hRtcTickAddWeeks;
begin
  TickAdd(7 * PSPTicksPerDay, UInt64(Int64(FHLE.ArgInt(2))));
end;

procedure TPSPSysLibs.TickAddMonths(Months: Int64);
begin
  var T := ReadTick(FHLE.Arg(1));
  var Y, M, D: Int64;
  PSPCivilFromDays(Int64(T div PSPTicksPerDay), Y, M, D);
  var Index := Y * 12 + (M - 1) + Months;
  var NY := Index div 12;
  var NM := Index mod 12 + 1;
  if Index < 0 then
  begin
    NY := (Index - 11) div 12;
    NM := Index - NY * 12 + 1;
  end;
  FHLE.Result(0);
  // A result outside years 1..9999 leaves the destination as it was.
  if (NY < 1) or (NY > 9999) then
    Exit;
  var Last := PSPDaysInMonth(NY, NM);
  if D > Last then
    D := Last;
  WriteTick(FHLE.Arg(0), UInt64(PSPDaysFromCivil(NY, NM, D)) * PSPTicksPerDay + T mod PSPTicksPerDay);
end;

procedure TPSPSysLibs.hRtcTickAddMonths;
begin
  TickAddMonths(FHLE.ArgInt(2));
end;

procedure TPSPSysLibs.hRtcTickAddYears;
begin
  TickAddMonths(Int64(FHLE.ArgInt(2)) * 12);
end;

procedure TPSPSysLibs.hRtcCompareTick;
begin
  var A := ReadTick(FHLE.Arg(0));
  var B := ReadTick(FHLE.Arg(1));
  if A < B then FHLE.Result($FFFFFFFF)
  else if A > B then FHLE.Result(1)
  else FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcGetDaysInMonth;
begin
  var Y := FHLE.ArgInt(0);
  var M := FHLE.ArgInt(1);
  if (M < 1) or (M > 12) or (Y < 1) then
    begin FHLE.Result(SCE_KERNEL_ERROR_INVALID_INDEX); Exit; end;
  FHLE.Result(Cardinal(PSPDaysInMonth(Y, M)));
end;

procedure TPSPSysLibs.hRtcGetDayOfWeek;
const
  T: array[1..12] of Integer = (0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4);
begin
  var Y := FHLE.ArgInt(0);
  var M := FHLE.ArgInt(1);
  var D := FHLE.ArgInt(2);
  // Sakamoto's method; the day is not range checked. Months outside 1..12 index
  // past the firmware's table: these are the words found there.
  var Off: Integer;
  if (M >= 1) and (M <= 12) then
    Off := T[M]
  else
    case M of
      0: Off := 1;
      573: Off := 0;
      1024: Off := 4;
      4587: Off := 6;
    else
      Off := 0;
    end;
  if (M = 1) or (M = 2) then
    Dec(Y);
  var R := (Int64(Y) + Y div 4 - Y div 100 + Y div 400 + Off + D) mod 7;
  if R < 0 then
    Inc(R, 7);
  FHLE.Result(Cardinal(R));
end;

procedure TPSPSysLibs.hRtcIsLeapYear;
begin
  FHLE.Result(Ord(PSPIsLeapYear(FHLE.ArgInt(0))));
end;

procedure TPSPSysLibs.hRtcCheckValid;
begin
  FHLE.Result(Cardinal(PSPCheckDate(ReadDate(FHLE.Arg(0)))));
end;

procedure TPSPSysLibs.hRtcGetTime_t;
begin
  var T := PSPDateToTicks(ReadDate(FHLE.Arg(0)));
  FMemory.Write32(FHLE.Arg(1), Cardinal(Int64(T - PSPUnixEpochTicks) div TicksPerSec));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcSetTime_t;
begin
  WriteDate(FHLE.Arg(0), PSPUnixEpochTicks + UInt64(FHLE.Arg(1)) * TicksPerSec);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcGetTime64_t;
begin
  var T := PSPDateToTicks(ReadDate(FHLE.Arg(0)));
  WriteTick(FHLE.Arg(1), UInt64(Int64(T - PSPUnixEpochTicks) div TicksPerSec));
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcSetTime64_t;
begin
  WriteDate(FHLE.Arg(0), PSPUnixEpochTicks + FHLE.Arg64(2) * TicksPerSec);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcGetDosTime;
begin
  var D := ReadDate(FHLE.Arg(0));
  if (D.Year < 1980) or (D.Year > 2107) then
    begin FHLE.Result($FFFFFFFF); Exit; end;
  var V := ((D.Year - 1980) shl 25) or ((D.Month and 15) shl 21) or ((D.Day and 31) shl 16) or
    ((D.Hour and 31) shl 11) or ((D.Minute and 63) shl 5) or ((D.Second shr 1) and 31);
  FMemory.Write32(FHLE.Arg(1), V);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcSetDosTime;
begin
  var P := FHLE.Arg(0);
  var V := FHLE.Arg(1);
  FMemory.Write16(P, 1980 + (V shr 25));
  FMemory.Write16(P + 2, (V shr 21) and 15);
  FMemory.Write16(P + 4, (V shr 16) and 31);
  FMemory.Write16(P + 6, (V shr 11) and 31);
  FMemory.Write16(P + 8, (V shr 5) and 63);
  FMemory.Write16(P + 10, (V and 31) * 2);
  FMemory.Write32(P + 12, 0);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcGetWin32FileTime;
begin
  var D := ReadDate(FHLE.Arg(0));
  var P := FHLE.Arg(1);
  if P = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_INVALID_VALUE); Exit; end;
  // Only the year is checked: a day past the month's end runs into the next.
  if (D.Year < 1601) or (D.Year > 9999) then
  begin
    WriteTick(P, 0);
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_VALUE);
    Exit;
  end;
  var Base := UInt64(PSPDaysFromCivil(1601, 1, 1)) * PSPTicksPerDay;
  WriteTick(P, (PSPDateToTicks(D) - Base) * 10);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcSetWin32FileTime;
begin
  var Base := UInt64(PSPDaysFromCivil(1601, 1, 1)) * PSPTicksPerDay;
  WriteDate(FHLE.Arg(0), Base + FHLE.Arg64(2) div 10);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcGetAccumulativeTime;
begin
  FHLE.Result64(NowTicks);
end;

function FormatRFC2822(Ticks: UInt64; TzMinutes: Integer): string;
begin
  var T := UInt64(Int64(Ticks) + Int64(TzMinutes) * 60000000);
  var D := PSPTicksToDate(T);
  var Sign := '+';
  var Tz := TzMinutes;
  if Tz < 0 then
  begin
    Sign := '-';
    Tz := -Tz;
  end;
  var Mon := 'Jan';
  if (D.Month >= 1) and (D.Month <= 12) then
    Mon := MonthNames[D.Month];
  Result := Format('%s, %.2d %s %.4d %.2d:%.2d:%.2d %s%.2d%.2d', [WeekDayNames[TicksWeekDay(T)], D.Day, Mon, D.Year,
    D.Hour, D.Minute, D.Second, Sign, Tz div 60, Tz mod 60]);
end;

function FormatRFC3339(Ticks: UInt64; TzMinutes: Integer): string;
begin
  var T := UInt64(Int64(Ticks) + Int64(TzMinutes) * 60000000);
  var D := PSPTicksToDate(T);
  Result := Format('%.4d-%.2d-%.2dT%.2d:%.2d:%.2d.%.2d', [D.Year, D.Month, D.Day, D.Hour, D.Minute, D.Second,
    D.Microsecond div 10000]);
  if TzMinutes = 0 then
    Result := Result + 'Z'
  else
  begin
    var Sign := '+';
    var Tz := TzMinutes;
    if Tz < 0 then
    begin
      Sign := '-';
      Tz := -Tz;
    end;
    Result := Result + Format('%s%.2d:%.2d', [Sign, Tz div 60, Tz mod 60]);
  end;
end;

procedure TPSPSysLibs.hRtcFormatRFC2822;
begin
  FMemory.WriteString(FHLE.Arg(0), RawByteString(FormatRFC2822(ReadTick(FHLE.Arg(1)), FHLE.ArgInt(2))), 64);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcFormatRFC2822Local;
begin
  FMemory.WriteString(FHLE.Arg(0), RawByteString(FormatRFC2822(ReadTick(FHLE.Arg(1)),
    LocalOffsetTicks div 60000000)), 64);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcFormatRFC3339;
begin
  FMemory.WriteString(FHLE.Arg(0), RawByteString(FormatRFC3339(ReadTick(FHLE.Arg(1)), FHLE.ArgInt(2))), 64);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hRtcFormatRFC3339Local;
begin
  FMemory.WriteString(FHLE.Arg(0), RawByteString(FormatRFC3339(ReadTick(FHLE.Arg(1)),
    LocalOffsetTicks div 60000000)), 64);
  FHLE.Result(0);
end;

type
  TDateScanner = record
    S: string;
    P: Integer;
    function Done: Boolean;
    function Peek: Char;
    function Take(C: Char): Boolean;
    function Number(MinDigits, MaxDigits: Integer; out V: Integer): Boolean;
    function ReadWord(out W: string): Boolean;
  end;

function TDateScanner.Done: Boolean;
begin
  Result := P > Length(S);
end;

function TDateScanner.Peek: Char;
begin
  if Done then
    Result := #0
  else
    Result := S[P];
end;

function TDateScanner.Take(C: Char): Boolean;
begin
  Result := Peek = C;
  if Result then
    Inc(P);
end;

function TDateScanner.Number(MinDigits, MaxDigits: Integer; out V: Integer): Boolean;
begin
  V := 0;
  var N := 0;
  while (N < MaxDigits) and CharInSet(Peek, ['0'..'9']) do
  begin
    V := V * 10 + Ord(Peek) - Ord('0');
    Inc(P);
    Inc(N);
  end;
  Result := N >= MinDigits;
end;

function TDateScanner.ReadWord(out W: string): Boolean;
begin
  var Start := P;
  while CharInSet(Peek, ['A'..'Z', 'a'..'z']) do
    Inc(P);
  W := Copy(S, Start, P - Start);
  Result := W <> '';
end;

function ParseRFC3339(const Text: string; out Ticks: UInt64): Boolean;
begin
  var Sc: TDateScanner;
  Sc.S := Text;
  Sc.P := 1;
  var D := Default(TPSPDate);
  var Y, Mo, Dd, H, Mi, Se: Integer;
  Result := False;
  if not (Sc.Number(4, 4, Y) and Sc.Take('-') and Sc.Number(2, 2, Mo) and Sc.Take('-') and Sc.Number(2, 2, Dd)) then
    Exit;
  if not (Sc.Take('T') or Sc.Take('t')) then
    Exit;
  if not (Sc.Number(2, 2, H) and Sc.Take(':') and Sc.Number(2, 2, Mi) and Sc.Take(':') and Sc.Number(2, 2, Se)) then
    Exit;
  var Us := 0;
  if Sc.Take('.') then
  begin
    var Scale := 100000;
    var Digits := 0;
    while CharInSet(Sc.Peek, ['0'..'9']) do
    begin
      if Scale > 0 then
        Inc(Us, (Ord(Sc.Peek) - Ord('0')) * Scale);
      Scale := Scale div 10;
      Inc(Sc.P);
      Inc(Digits);
    end;
    if Digits = 0 then
      Exit;
  end;
  var Offset := 0;
  if Sc.Take('Z') or Sc.Take('z') then
  else if CharInSet(Sc.Peek, ['+', '-']) then
  begin
    var Neg := Sc.Peek = '-';
    Inc(Sc.P);
    var OH, OM: Integer;
    if not (Sc.Number(2, 2, OH) and Sc.Take(':') and Sc.Number(2, 2, OM)) then
      Exit;
    Offset := OH * 60 + OM;
    if Neg then
      Offset := -Offset;
  end
  else
    Exit;
  if not Sc.Done then
    Exit;
  D.Year := Y;
  D.Month := Mo;
  D.Day := Dd;
  D.Hour := H;
  D.Minute := Mi;
  D.Second := Se;
  D.Microsecond := Us;
  if PSPCheckDate(D) <> 0 then
    Exit;
  Ticks := UInt64(Int64(PSPDateToTicks(D)) - Int64(Offset) * 60000000);
  Result := True;
end;

function ParseRFC2822(const Text: string; out Ticks: UInt64): Boolean;
begin
  var Sc: TDateScanner;
  Sc.S := Text;
  Sc.P := 1;
  Result := False;
  var W: string;
  if not Sc.ReadWord(W) then
    Exit;
  var Known := False;
  for var I := 0 to 6 do
    if SameText(W, WeekDayNames[I]) or SameText(W, WeekDayLong[I]) then
      Known := True;
  if not Known or not Sc.Take(',') or not Sc.Take(' ') then
    Exit;
  var Dd, Y, H, Mi, Se, Tz: Integer;
  if not Sc.Number(1, 2, Dd) or not Sc.Take(' ') or not Sc.ReadWord(W) or not Sc.Take(' ') then
    Exit;
  var Mo := 0;
  for var I := 1 to 12 do
    if SameText(W, MonthNames[I]) then
      Mo := I;
  if Mo = 0 then
    Exit;
  if not (Sc.Number(4, 4, Y) and Sc.Take(' ') and Sc.Number(2, 2, H) and Sc.Take(':') and Sc.Number(2, 2, Mi) and
    Sc.Take(':') and Sc.Number(2, 2, Se) and Sc.Take(' ')) then
    Exit;
  if not CharInSet(Sc.Peek, ['+', '-']) then
    Exit;
  var Neg := Sc.Peek = '-';
  Inc(Sc.P);
  if not Sc.Number(4, 4, Tz) or not Sc.Done then
    Exit;
  var Offset := (Tz div 100) * 60 + Tz mod 100;
  if Neg then
    Offset := -Offset;
  var D := Default(TPSPDate);
  D.Year := Y;
  D.Month := Mo;
  D.Day := Dd;
  D.Hour := H;
  D.Minute := Mi;
  D.Second := Se;
  if PSPCheckDate(D) <> 0 then
    Exit;
  Ticks := UInt64(Int64(PSPDateToTicks(D)) - Int64(Offset) * 60000000);
  Result := True;
end;

procedure TPSPSysLibs.hRtcParseDateTime;
begin
  var Text := FMemory.ReadString(FHLE.Arg(1), 256);
  var T: UInt64;
  if ParseRFC3339(Text, T) or ParseRFC2822(Text, T) then
  begin
    WriteTick(FHLE.Arg(0), T);
    FHLE.Result(0);
  end
  else
    FHLE.Result($FFFFFFFF);
end;

procedure TPSPSysLibs.hRtcGetLastTime;
begin
  if FHLE.Arg(0) <> 0 then
    WriteTick(FHLE.Arg(0), EpochTicks);
  FHLE.Result(0);
end;
