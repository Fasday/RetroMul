program T24Check;

// t24_check.py extracts the actual GE vertex arithmetic into T24.Actual.inc
// (T24, Exp24, Add24, Recip24, FloorInt, MaxS, MinS) and GEPow.Actual.inc and
// compiles this test beside them. The references are the former
// implementations (Frexp, Int, Ldexp, Floor, System.Math's Max and Min; the
// matrix rows on GEFloats of the registers, as ClipPosition did them).
{$APPTYPE CONSOLE}
{$O+}{$Q-}{$R-}
{$EXCESSPRECISION OFF}

uses
  System.SysUtils, System.Math, System.Diagnostics, PSP.GE.Types;

function RefT24(V: Double): Double;
var
  E: Integer;
  M: Double;
begin
  if (V = 0) or IsNan(V) or IsInfinite(V) then
    Exit(V);
  Frexp(V, M, E);
  Result := Ldexp(Int(M * 65536), E - 16);
end;

function RefExp24(V: Double): Integer;
var
  M: Double;
begin
  Frexp(V, M, Result);
end;

function RefAdd24(A, B: Double): Double;
begin
  if A = 0 then
    Exit(RefT24(B));
  if B = 0 then
    Exit(RefT24(A));
  var E := Max(RefExp24(A), RefExp24(B));
  var Ulp := Ldexp(1, E - 16);
  Result := RefT24(Int(A / Ulp) * Ulp + Int(B / Ulp) * Ulp);
end;

function RefRecip24(V: Double): Double;
var
  M: Double;
  E: Integer;
begin
  if V = 0 then
    Exit(Infinity);
  if IsNan(V) or IsInfinite(V) then
    Exit(0);
  Frexp(Abs(V), M, E);
  M := M * 2;
  Dec(E);
  var K := Trunc((M - 1) * 128);
  var T := (M - 1) * 128 - K;
  var R0 := 1 / (1 + K / 128);
  var R1 := 1 / (1 + (K + 1) / 128);
  Result := RefT24(Ldexp(R0 + (R1 - R0) * T, -E));
  if V < 0 then
    Result := -Result;
end;

function RefGEPow(X, E: Single): Single;
begin
  if not (X > 0) then
  begin
    if E = 0 then
      Exit(1);
    Exit(0);
  end;
  var Bits := PCardinal(@X)^;
  var L2: Double := Integer((Bits shr 23) and $FF) - 127 + (Bits and $7FFFFF) / 8388608.0;
  var Y: Double := L2 * E;
  if IsNan(Y) then
    Exit(1);
  if Y > 127 then
    Exit(Infinity);
  if Y < -127 then
    Exit(0);
  var F := Floor(Y);
  Result := Ldexp(1 + (Y - F), F);
end;

function RefRow24(M0, M1, M2, T: Cardinal; X, Y, Z: Double): Double;
begin
  Result := RefAdd24(RefT24(GEFloat(M0) * X + GEFloat(M1) * Y + GEFloat(M2) * Z), GEFloat(T));
end;

function RefRow24P(M0, M1, M2, M3: Cardinal; X, Y, Z, W: Double): Double;
begin
  Result := RefAdd24(RefT24(GEFloat(M0) * X + GEFloat(M1) * Y + GEFloat(M2) * Z), RefT24(GEFloat(M3) * W));
end;

function RefMaxS(A, B: Single): Single;
begin
  Result := Max(A, B);
end;

function RefMinS(A, B: Single): Single;
begin
  Result := Min(A, B);
end;

{$I T24.Actual.inc}
{$I GEPow.Actual.inc}

var
  Seed: UInt64 = 88172645463325252;

function Bits64: UInt64;
begin
  Seed := Seed xor (Seed shl 13);
  Seed := Seed xor (Seed shr 7);
  Seed := Seed xor (Seed shl 17);
  Result := Seed;
end;

function RandomDouble: Double;
begin
  var B: UInt64;
  case Bits64 mod 12 of
    0: B := Bits64;
    1:
      begin
        var S: Single := Single(Integer(Bits64 shr 40) - 8388608) / (1 shl (Bits64 mod 24));
        Exit(S);
      end;
    2:
      begin
        var S := Cardinal(Bits64);
        Exit(PSingle(@S)^);
      end;
    3: Exit(Integer(Bits64 shr 48) - 32768);
    4: B := (Bits64 and $800FFFFFFFFFFFFF) or (UInt64(1023 + Integer(Bits64 mod 60) - 30) shl 52);
    5: B := (Bits64 and $800FFFFFE0000000) or (UInt64(1023 + Integer(Bits64 mod 40) - 20) shl 52);
    6: B := Bits64 and $800FFFFFFFFFFFFF;
    7: B := (Bits64 and $800FFFFFFFFFFFFF) or (UInt64(1 + Bits64 mod 70) shl 52);
    8: B := (Bits64 and $800FFFFFFFFFFFFF) or (UInt64(2046 - Bits64 mod 70) shl 52);
    9: Exit(0 * (1 - 2 * Integer(Bits64 mod 2)));
    10: B := (Bits64 and $800FFFFFFFFFFFFF) or (UInt64(1023 + Integer(Bits64 mod 1000) - 500) shl 52);
  else
    Exit(Single(Bits64 mod 2000) / 7 - 140);
  end;
  Result := PDouble(@B)^;
end;

function RandomSingle: Single;
begin
  var D := RandomDouble;
  if Bits64 mod 4 = 0 then
  begin
    var S := Cardinal(Bits64);
    Exit(PSingle(@S)^);
  end;
  Result := D;
end;

function Pick24: Cardinal;
const
  // 0, -0, 1, -1, infinities (and the NaN encodings GEFloat makes them), denormals.
  Values: array[0..9] of Cardinal = ($000000, $800000, $3F8000, $BF8000, $7F8000, $FF8000, $7FC000, $FFFFFF,
    $000001, $807FFF);
begin
  Result := Values[Bits64 mod 10];
end;

// A GE register value: a 24-bit float, now and then one of the special ones.
function RandomReg: Cardinal;
begin
  case Bits64 mod 8 of
    0: Result := Cardinal(Bits64) and $FFFFFF;
    1: Result := Pick24;
  else
    begin
      var S: Single := (Integer(Bits64 mod 20001) - 10000) / (1 + Bits64 mod 300);
      Result := PCardinal(@S)^ shr 8;
    end;
  end;
end;

function Same(A, B: Double): Boolean;
begin
  Result := (PUInt64(@A)^ = PUInt64(@B)^) or (IsNan(A) and IsNan(B));
end;

function SameS(A, B: Single): Boolean;
begin
  Result := (PCardinal(@A)^ = PCardinal(@B)^) or (IsNan(A) and IsNan(B));
end;

var
  Bad: Integer;
  RowsChecked, PortsChecked: Int64;
  // Batches the Win64 assembler finished itself.
  FastRows, FastPorts: Int64;
  Specials: TArray<Double>;

procedure Fail(const What: string);
begin
  Inc(Bad);
  if Bad < 12 then
    Writeln(What);
end;

procedure Check(A, B: Double);
begin
  if not Same(T24(A), RefT24(A)) then
    Fail(Format('T24 %g', [A]));
  if not (IsNan(A) or IsInfinite(A)) and (Exp24(A) <> RefExp24(A)) then
    Fail(Format('Exp24 %g', [A]));
  var X := Add24(A, B);
  var Y := RefAdd24(A, B);
  if not Same(X, Y) then
    Fail(Format('Add24 %g %g: %g against %g', [A, B, X, Y]));
  X := Recip24(A);
  Y := RefRecip24(A);
  if not Same(X, Y) then
    Fail(Format('Recip24 %g: %g against %g', [A, X, Y]));
  if Abs(A) < 2E9 then
    if FloorInt(A) <> Floor(A) then
      Fail(Format('FloorInt %g', [A]));
end;

procedure CheckSingles(A, B: Single);
begin
  if not SameS(MaxS(A, B), RefMaxS(A, B)) then
    Fail(Format('MaxS %g %g', [A, B]));
  if not SameS(MinS(A, B), RefMinS(A, B)) then
    Fail(Format('MinS %g %g', [A, B]));
  if not SameS(MaxS(A, 0), RefMaxS(A, 0)) then
    Fail(Format('MaxS %g 0', [A]));
  if not SameS(MinS(A, 1), RefMinS(A, 1)) then
    Fail(Format('MinS %g 1', [A]));
  var E := B;
  if Bits64 mod 2 = 0 then
    E := (Bits64 mod 4000) / 16;
  if not SameS(GEPow(A, E), RefGEPow(A, E)) then
    Fail(Format('GEPow %g %g: %g against %g', [A, E, GEPow(A, E), RefGEPow(A, E)]));
end;

procedure CheckRows;
begin
  // As ClipPosition: the row's GEFloats as Doubles, the translation (w = 1)
  // as T24 of it.
  var M0 := RandomReg; var M1 := RandomReg; var M2 := RandomReg; var M3 := RandomReg;
  var X := RandomDouble; var Y := RandomDouble; var Z := RandomDouble;
  if Bits64 mod 2 = 0 then
  begin
    X := RefT24(Single(RandomDouble)); Y := RefT24(Single(RandomDouble)); Z := RefT24(Single(RandomDouble));
  end;
  var D0: Double := GEFloat(M0);
  var D1: Double := GEFloat(M1);
  var D2: Double := GEFloat(M2);
  var D3: Double := GEFloat(M3);
  var R := Add24(T24(D0 * X + D1 * Y + D2 * Z), D3);
  var Q := RefRow24(M0, M1, M2, M3, X, Y, Z);
  if not Same(R, Q) then
    Fail(Format('Row24 %x %x %x %x %g %g %g: %g against %g', [M0, M1, M2, M3, X, Y, Z, R, Q]));
  R := Add24(T24(D0 * X + D1 * Y + D2 * Z), T24(D3));
  Q := RefRow24P(M0, M1, M2, M3, X, Y, Z, 1);
  if not Same(R, Q) then
    Fail(Format('Row24P %x %x %x %x %g %g %g: %g against %g', [M0, M1, M2, M3, X, Y, Z, R, Q]));
  // Rows24 (in registers where it can) on four rows: plain and with the
  // projection's T24'd term.
  var Rows: array[0..3] of TGERow24;
  var Raw: array[0..3, 0..3] of Cardinal;
  for var K := 0 to 3 do
  begin
    for var J := 0 to 3 do
    begin
      Raw[K, J] := RandomReg;
      Rows[K][J] := GEFloat(Raw[K, J]);
    end;
    if K = 3 then
      Rows[K][3] := T24(Rows[K][3]);
  end;
  var Res: array[0..3] of Double;
  {$IF Defined(CPUX64) and Defined(MSWINDOWS)}
  if Rows24Fast(@Rows[0], X, Y, Z, @Res[0], 4) then
    Inc(FastRows);
  {$ENDIF}
  Rows24(@Rows[0], X, Y, Z, @Res[0], 4);
  for var K := 0 to 3 do
  begin
    if K = 3 then
      Q := RefRow24P(Raw[K, 0], Raw[K, 1], Raw[K, 2], Raw[K, 3], X, Y, Z, 1)
    else
      Q := RefRow24(Raw[K, 0], Raw[K, 1], Raw[K, 2], Raw[K, 3], X, Y, Z);
    if not Same(Res[K], Q) then
      Fail(Format('Rows24 row %d %x %x %x %x %g %g %g: %g against %g', [K, Raw[K, 0], Raw[K, 1], Raw[K, 2],
        Raw[K, 3], X, Y, Z, Res[K], Q]));
  end;
  Inc(RowsChecked, 4);
end;

procedure CheckPort;
begin
  // As Project: clip coordinates times 1/w, to the viewport's GEFloats.
  var V: array[0..2] of Double;
  var Port: array[0..5] of Double;
  var Raw: array[0..5] of Cardinal;
  for var K := 0 to 2 do
  begin
    V[K] := RandomDouble;
    if Bits64 mod 2 = 0 then
      V[K] := RefT24(Single(RandomDouble));
  end;
  for var K := 0 to 5 do
  begin
    Raw[K] := RandomReg;
    Port[K] := GEFloat(Raw[K]);
  end;
  var RW := RandomDouble;
  if Bits64 mod 2 = 0 then
    RW := RefRecip24(RandomDouble);
  var Res: array[0..2] of Double;
  {$IF Defined(CPUX64) and Defined(MSWINDOWS)}
  if Port24Fast(@V[0], RW, @Port[0], @Res[0]) then
    Inc(FastPorts);
  {$ENDIF}
  Port24(@V[0], RW, @Port[0], @Res[0]);
  for var K := 0 to 2 do
  begin
    var Q := RefAdd24(RefT24(RefT24(V[K] * RW) * GEFloat(Raw[K * 2])), GEFloat(Raw[K * 2 + 1]));
    if not Same(Res[K], Q) then
      Fail(Format('Port24 %d %g %g %x %x: %g against %g', [K, V[K], RW, Raw[K * 2], Raw[K * 2 + 1], Res[K], Q]));
  end;
  Inc(PortsChecked, 3);
end;

begin
  Specials := [0, -0.0, 1, -1, 0.5, Infinity, NegInfinity, NaN, MaxDouble, -MaxDouble, MinDouble, -MinDouble,
    2.2250738585072014E-308, -2.2250738585072014E-308, 65535, 65536, 65537, 1E-300, -1E-300, 1E30, 3.4E38, 1E-38,
    1E-45, 2147483647.5, -2147483648.0, 127, -127, 126.99999, -126.5];
  for var A in Specials do
    for var B in Specials do
    begin
      Check(A, B);
      CheckSingles(A, B);
    end;
  var Count := 50000000;
  if ParamCount > 0 then
    Count := StrToInt(ParamStr(1));
  for var I := 1 to Count do
  begin
    var A := RandomDouble;
    var B := RandomDouble;
    if Bits64 mod 4 = 0 then
      B := A * (1 + (Bits64 mod 100) / 37) * (1 - 2 * Integer(Bits64 mod 2));
    Check(A, B);
    if I mod 4 = 0 then
      CheckSingles(RandomSingle, RandomSingle);
    if I mod 4 = 1 then
      CheckRows;
    if I mod 4 = 2 then
      CheckPort;
  end;
  Writeln(Count, ' random pairs (and singles), ', RowsChecked, ' Rows24 rows, ', PortsChecked, ' Port24 values, ',
    Bad, ' differences');
  {$IF Defined(CPUX64) and Defined(MSWINDOWS)}
  Writeln(Format('in assembler: %.1f%% of Rows24 batches, %.1f%% of Port24 batches',
    [100 * FastRows / Max(RowsChecked div 4, 1), 100 * FastPorts / Max(PortsChecked div 3, 1)]));
  {$ENDIF}
  var W := TStopwatch.StartNew;
  var S: Double := 0;
  for var I := 1 to 10000000 do
    S := S + RefAdd24(I * 0.37, I * 1.3) + RefRecip24(I * 0.37);
  Writeln(Format('reference %.1f ns per Add24 + Recip24', [W.Elapsed.TotalMilliseconds * 1E6 / 10000000]));
  W := TStopwatch.StartNew;
  for var I := 1 to 10000000 do
    S := S + Add24(I * 0.37, I * 1.3) + Recip24(I * 0.37);
  Writeln(Format('actual %.1f ns per Add24 + Recip24 (%g)', [W.Elapsed.TotalMilliseconds * 1E6 / 10000000, S]));
  if Bad <> 0 then
    ExitCode := 1;
end.
