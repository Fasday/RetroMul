program T24Check;

// t24_check.py extracts the actual GE routines into T24.Actual.inc and
// compiles this test beside that include. The reference is the former
// implementation, including Ldexp(1, ..)'s Single overload in Add24.
{$APPTYPE CONSOLE}
{$O+}{$Q-}{$R-}

uses
  System.SysUtils, System.Math, System.Diagnostics;

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

{$I T24.Actual.inc}

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
  case Bits64 mod 10 of
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
    7: B := (Bits64 and $800FFFFFFFFFFFFF) or (UInt64(1 + Bits64 mod 30) shl 52);
    8: B := (Bits64 and $800FFFFFFFFFFFFF) or (UInt64(2046 - Bits64 mod 30) shl 52);
  else
    Exit(Single(Bits64 mod 2000) / 7 - 140);
  end;
  Result := PDouble(@B)^;
end;

function Same(A, B: Double): Boolean;
begin
  Result := (PUInt64(@A)^ = PUInt64(@B)^) or (IsNan(A) and IsNan(B));
end;

var
  Bad: Integer;

procedure Check(A, B: Double);
begin
  if not Same(T24(A), RefT24(A)) then
  begin
    Inc(Bad);
    if Bad < 10 then
      Writeln('T24 ', A);
  end;
  if not (IsNan(A) or IsInfinite(A)) and (Exp24(A) <> RefExp24(A)) then
  begin
    Inc(Bad);
    if Bad < 10 then
      Writeln('Exp24 ', A);
  end;
  var X := Add24(A, B);
  var Y := RefAdd24(A, B);
  if not Same(X, Y) then
  begin
    Inc(Bad);
    if Bad < 10 then
      Writeln(Format('Add24 %g %g: %g against %g', [A, B, X, Y]));
  end;
end;

begin
  var Specials: TArray<Double> := [0, -0.0, 1, -1, 0.5, Infinity, NegInfinity, NaN, MaxDouble, -MaxDouble,
    MinDouble, -MinDouble, 2.2250738585072014E-308, -2.2250738585072014E-308, 65535, 65536, 65537, 1E-300, -1E-300];
  for var A in Specials do
    for var B in Specials do
      Check(A, B);
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
  end;
  Writeln(Count, ' random pairs, ', Bad, ' differences');
  var W := TStopwatch.StartNew;
  var S: Double := 0;
  for var I := 1 to 10000000 do
    S := S + RefAdd24(I * 0.37, I * 1.3);
  Writeln(Format('reference %.1f ns per Add24', [W.Elapsed.TotalMilliseconds * 1E6 / 10000000]));
  W := TStopwatch.StartNew;
  for var I := 1 to 10000000 do
    S := S + Add24(I * 0.37, I * 1.3);
  Writeln(Format('fast %.1f ns per Add24 (%g)', [W.Elapsed.TotalMilliseconds * 1E6 / 10000000, S]));
  if Bad <> 0 then
    ExitCode := 1;
end.
