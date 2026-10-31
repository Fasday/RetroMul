unit PSP.VFPU.Math;

// VFPU arithmetic on raw single bit patterns, as the hardware rounds it:
// denormal operands and results are flushed to signed zero, NaNs come out as
// 7F800001 (with the product's sign for multiply/divide), sums of products are
// aligned to the largest term before they are added.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}

interface

const
  VF_ONE = $3F800000;
  VF_NAN = $7F800001;

function VFlush(X: Cardinal): Cardinal; inline;
function VIsNaN(X: Cardinal): Boolean; inline;
function VAdd(A, B: Cardinal): Cardinal; inline;
function VSub(A, B: Cardinal): Cardinal; inline;
function VMul(A, B: Cardinal): Cardinal; inline;
function VDiv(A, B: Cardinal): Cardinal;
// Sum of up to four exact products (or plain terms), with the VFPU's alignment.
function VSum4(const A, B: array of Cardinal; Count: Integer; Skip: Cardinal): Cardinal;
function VSat0(X: Cardinal): Cardinal; inline;
function VSat1(X: Cardinal): Cardinal; inline;
// Ordering key used by vmin/vmax/sorts: denormals and zeros equal, NaNs past infinity.
function VKey(X: Cardinal): Integer; inline;

function VRcp(X: Cardinal): Cardinal;
function VRsq(X: Cardinal): Cardinal;
function VSqrt(X: Cardinal): Cardinal;
function VSin(X: Cardinal): Cardinal;
function VCos(X: Cardinal): Cardinal;
function VAsin(X: Cardinal): Cardinal;
function VExp2(X: Cardinal): Cardinal;
function VLog2(X: Cardinal): Cardinal;
function VNRcp(X: Cardinal): Cardinal;
function VNSin(X: Cardinal): Cardinal;
function VRExp2(X: Cardinal): Cardinal;

function BitsToSingle(X: Cardinal): Single; inline;
function SingleToBits(X: Single): Cardinal; inline;

implementation

uses
  System.Math;

function BitsToSingle(X: Cardinal): Single;
begin
  Result := PSingle(@X)^;
end;

function SingleToBits(X: Single): Cardinal;
begin
  Result := PCardinal(@X)^;
end;

function VFlush(X: Cardinal): Cardinal;
begin
  if (X and $7F800000) = 0 then
    Result := X and $80000000
  else
    Result := X;
end;

function VIsNaN(X: Cardinal): Boolean;
begin
  Result := (X and $7FFFFFFF) > $7F800000;
end;

function VKey(X: Cardinal): Integer;
begin
  if (X and $7F800000) = 0 then
    Result := 0
  else if (X and $80000000) <> 0 then
    Result := -Integer(X and $7FFFFFFF)
  else
    Result := Integer(X);
end;

function VSat0(X: Cardinal): Cardinal;
begin
  if (X and $7FFFFFFF) > $7F800000 then
    Result := X
  else if (X and $80000000) <> 0 then
    Result := 0
  else if X > VF_ONE then
    Result := VF_ONE
  else
    Result := X;
end;

function VSat1(X: Cardinal): Cardinal;
begin
  if (X and $7FFFFFFF) > $7F800000 then
    Result := X
  else if (X and $7FFFFFFF) > VF_ONE then
    Result := (X and $80000000) or VF_ONE
  else
    Result := X;
end;

function VAdd(A, B: Cardinal): Cardinal;
begin
  var X: Single := BitsToSingle(VFlush(A));
  var Y: Single := BitsToSingle(VFlush(B));
  var R: Single := X + Y;
  Result := SingleToBits(R);
  if (Result and $7F800000) = $7F800000 then
  begin
    if (Result and $007FFFFF) <> 0 then
      Result := VF_NAN;
  end
  else if (Result and $7F800000) = 0 then
    Result := Result and $80000000;
end;

function VSub(A, B: Cardinal): Cardinal;
begin
  Result := VAdd(A, B xor $80000000);
end;

function VMul(A, B: Cardinal): Cardinal;
begin
  A := VFlush(A);
  B := VFlush(B);
  var X: Single := BitsToSingle(A);
  var Y: Single := BitsToSingle(B);
  var R: Single := X * Y;
  Result := SingleToBits(R);
  var E := Result and $7F800000;
  if E = $7F800000 then
  begin
    if (Result and $007FFFFF) <> 0 then
      Result := VF_NAN or ((A xor B) and $80000000);
  end
  else if E <= $00800000 then
  begin
    // Underflow is decided on the exact product, before rounding.
    var D: Double := Double(X) * Double(Y);
    if Abs(D) < 1.1754943508222875E-38 then
      Result := Result and $80000000;
  end;
end;

function VDiv(A, B: Cardinal): Cardinal;
begin
  A := VFlush(A);
  B := VFlush(B);
  var X: Single := BitsToSingle(A);
  var Y: Single := BitsToSingle(B);
  var R: Single := X / Y;
  Result := SingleToBits(R);
  var E := Result and $7F800000;
  if E = $7F800000 then
  begin
    if (Result and $007FFFFF) <> 0 then
      Result := VF_NAN or ((A xor B) and $80000000);
  end
  else if E <= $00800000 then
  begin
    var D: Double := Double(X) / Double(Y);
    if Abs(D) < 1.1754943508222875E-38 then
      Result := Result and $80000000;
  end;
end;

function TopBit32(X: Cardinal): Integer;
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
asm
  BSR EAX, ECX
end;
{$ELSEIF Defined(CPUX86)}
asm
  BSR EAX, EAX
end;
{$ELSE}
begin
  Result := 0;
  if X >= $10000 then begin X := X shr 16; Inc(Result, 16); end;
  if X >= $100 then begin X := X shr 8; Inc(Result, 8); end;
  if X >= $10 then begin X := X shr 4; Inc(Result, 4); end;
  if X >= 4 then begin X := X shr 2; Inc(Result, 2); end;
  if X >= 2 then Inc(Result);
end;
{$ENDIF}

// The dot product unit adds the products in lane order. Each step aligns the
// running sum and the next product to the larger of their exponents (for the
// product, the sum of its operands' exponents), keeps 25 bits below that,
// truncating, and truncates the sum back to 24 bits.
function VSum4(const A, B: array of Cardinal; Count: Integer; Skip: Cardinal): Cardinal;
begin
  var InfSigns: Cardinal := 0;
  var AccNeg := False;
  var AccM: Cardinal := 0;
  var AccE: Integer := 0;
  for var I := 0 to Count - 1 do
  begin
    if (Skip shr I) and 1 <> 0 then
      Continue;
    var X := A[I];
    var Y := B[I];
    var Neg := ((X xor Y) and $80000000) <> 0;
    var EX := Integer((X shr 23) and $FF);
    var EY := Integer((Y shr 23) and $FF);
    if (EX = $FF) or (EY = $FF) then
    begin
      if ((EX = $FF) and ((X and $7FFFFF) <> 0)) or ((EY = $FF) and ((Y and $7FFFFF) <> 0)) or
        (EX = 0) or (EY = 0) then
        Exit(VF_NAN);
      if Neg then
        InfSigns := InfSigns or 2
      else
        InfSigns := InfSigns or 1;
      if InfSigns = 3 then
        Exit(VF_NAN);
      Continue;
    end;
    if (EX = 0) or (EY = 0) then
      Continue;
    // Product = M * 2^(RP - 46), M in [2^46, 2^48).
    var M := UInt64((X and $7FFFFF) or $800000) * UInt64((Y and $7FFFFF) or $800000);
    var RP := EX + EY - 254;
    var R := RP;
    if (AccM <> 0) and (AccE > R) then
      R := AccE;
    var PSh := 21 + R - RP;
    // Both aligned terms fit in 27 bits; only the exact product needs UInt64.
    var PQ: Integer := 0;
    if PSh < 48 then
      PQ := Integer(M shr PSh);
    var AQ: Integer := 0;
    if AccM <> 0 then
    begin
      var D := R - AccE;
      if D <= 2 then
        AQ := Integer(AccM shl (2 - D))
      else if D < 26 then
        AQ := Integer(AccM shr (D - 2));
    end;
    if AccNeg then
      AQ := -AQ;
    if Neg then
      PQ := -PQ;
    var S := AQ + PQ;
    if S = 0 then
    begin
      AccM := 0;
      AccNeg := False;
      Continue;
    end;
    AccNeg := S < 0;
    var U := Cardinal(Abs(S));
    var Top := TopBit32(U);
    // Leading bit Top in units of 2^(R - 25): exponent R - 25 + Top.
    AccE := R - 25 + Top;
    if Top > 23 then
      AccM := U shr (Top - 23)
    else
      AccM := U shl (23 - Top);
  end;
  if InfSigns = 1 then
    Exit($7F800000);
  if InfSigns = 2 then
    Exit($FF800000);
  if AccM = 0 then
    Exit(0);
  var SignBit: Cardinal := 0;
  if AccNeg then
    SignBit := $80000000;
  var BE := AccE + 127;
  if BE >= 255 then
    Exit(SignBit or $7F800000);
  if BE <= 0 then
    Exit(SignBit);
  Result := SignBit or (Cardinal(BE) shl 23) or (Cardinal(AccM) and $7FFFFF);
end;

{ Function unit. Results carry 22 bits of mantissa. }

function Trunc22(D: Double): Cardinal;
begin
  var Q := PUInt64(@D)^;
  var Sign := Cardinal(Q shr 32) and $80000000;
  var E := Integer((Q shr 52) and $7FF) - 1023 + 127;
  if E <= 0 then
    Exit(Sign);
  if E >= 255 then
    Exit(Sign or $7F800000);
  Result := Sign or (Cardinal(E) shl 23) or (Cardinal(Q shr 29) and $7FFFFC);
end;

// Rounded to single first: closer to what the reciprocal, reciprocal square
// root and logarithm units give than the plain truncation.
function Round22(D: Double): Cardinal;
begin
  var S: Single := D;
  Result := SingleToBits(S);
  if (Result and $7F800000) = 0 then
    Exit(Result and $80000000);
  Result := Result and $FFFFFFFC;
end;

function NaNOf(X: Cardinal): Cardinal; inline;
begin
  Result := (X and $80000000) or VF_NAN;
end;

function VRcp(X: Cardinal): Cardinal;
begin
  X := VFlush(X);
  if VIsNaN(X) then
    Exit(NaNOf(X));
  if (X and $7FFFFFFF) = 0 then
    Exit((X and $80000000) or $7F800000);
  if (X and $7FFFFFFF) = $7F800000 then
    Exit(X and $80000000);
  Result := Round22(1.0 / Double(BitsToSingle(X)));
end;

function VNRcp(X: Cardinal): Cardinal;
begin
  Result := VRcp(X) xor $80000000;
end;

function VRsq(X: Cardinal): Cardinal;
begin
  X := VFlush(X);
  if VIsNaN(X) then
    Exit(NaNOf(X));
  if (X and $7FFFFFFF) = 0 then
    Exit((X and $80000000) or $7F800000);
  if (X and $80000000) <> 0 then
    Exit($FF800001);
  if X = $7F800000 then
    Exit(0);
  Result := Round22(1.0 / Sqrt(Double(BitsToSingle(X))));
end;

function VSqrt(X: Cardinal): Cardinal;
begin
  X := VFlush(X);
  if VIsNaN(X) then
    Exit(VF_NAN);
  if (X and $7FFFFFFF) = 0 then
    Exit(0);
  if (X and $80000000) <> 0 then
    Exit(VF_NAN);
  if X = $7F800000 then
    Exit($7F800000);
  Result := Trunc22(Sqrt(Double(BitsToSingle(X))));
end;

var
  SinNodes: array[0..256] of Double;

// Angles are in quarter turns, taken as a magnitude in fixed point with 23
// fraction bits (truncated) modulo four turns. From 2^32 on the shifter takes
// the exponent modulo 32 as 1 to 32 (2^32, 2^64 and 2^96 shift everything
// out); recorded on a PSP-E1000 over a million random inputs.
function FixedAngle(X: Cardinal): Cardinal;
begin
  var E := Integer((X shr 23) and $FF) - 127;
  if E = -127 then
    Exit(0);
  if E >= 32 then
    E := ((E - 1) and 31) + 1;
  var M := (X and $7FFFFF) or $800000;
  if E >= 0 then
    Result := Cardinal(UInt64(M) shl E) and $1FFFFFF
  else if E > -24 then
    Result := M shr (-E)
  else
    Result := 0;
end;

// Sine of a first-quadrant angle in (0, 1): a quadratic through the ends and
// middle of each of 128 segments, floored to 28 fraction bits.
function SinFrac(Fr: Cardinal): Cardinal;
begin
  var K := (Fr shr 16) * 2;
  var U: Double := (Fr and $FFFF) / 32768.0;
  var YA := SinNodes[K];
  var YM := SinNodes[K + 1];
  var YB := SinNodes[K + 2];
  var V := YA + (YM - YA) * U + (YB - 2 * YM + YA) * 0.5 * U * (U - 1);
  Result := Trunc22(Floor(V * 268435456.0) / 268435456.0);
end;

function SinQuarter(X: Cardinal; Cosine: Boolean): Cardinal;
begin
  X := VFlush(X);
  if (X and $7F800000) = $7F800000 then
  begin
    if Cosine then
      Exit(VF_NAN);
    Exit(NaNOf(X));
  end;
  var A := FixedAngle(X);
  if Cosine then
    A := (A + $800000) and $1FFFFFF;
  var Q := A shr 23;
  var Fr := A and $7FFFFF;
  if Fr = 0 then
  begin
    case Q of
      0: Result := 0;
      1: Result := VF_ONE;
      2: Result := $80000000;
    else
      Result := $BF800000;
    end;
  end
  else
  begin
    if (Q and 1) <> 0 then
      Fr := $800000 - Fr;
    Result := SinFrac(Fr);
    if Q >= 2 then
      Result := Result or $80000000;
  end;
  if not Cosine and ((X and $80000000) <> 0) then
    Result := Result xor $80000000;
end;

function VSin(X: Cardinal): Cardinal;
begin
  Result := SinQuarter(X, False);
end;

function VCos(X: Cardinal): Cardinal;
begin
  Result := SinQuarter(X, True);
end;

function VNSin(X: Cardinal): Cardinal;
begin
  Result := VSin(X) xor $80000000;
end;

function VAsin(X: Cardinal): Cardinal;
begin
  X := VFlush(X);
  if VIsNaN(X) then
    Exit(NaNOf(X));
  if (X and $7FFFFFFF) > VF_ONE then
    Exit(NaNOf(X));
  if (X and $7FFFFFFF) = 0 then
    Exit(X);
  // The input is taken in fixed point with 23 fraction bits, the result
  // floored to 29.
  var A: Double := Int(Abs(Double(BitsToSingle(X))) * 8388608.0) / 8388608.0;
  Result := Trunc22(Floor(ArcSin(A) / (Pi / 2) * 536870912.0) / 536870912.0) or
    (X and $80000000);
end;

function VExp2(X: Cardinal): Cardinal;
begin
  X := VFlush(X);
  if VIsNaN(X) then
    Exit(VF_NAN);
  if X = $7F800000 then
    Exit($7F800000);
  if X = $FF800000 then
    Exit(0);
  var D: Double := BitsToSingle(X);
  if D >= 128 then
    Exit($7F800000);
  if D < -126 then
    Exit(0);
  // The exponent is taken in fixed point with 23 fraction bits.
  D := Floor(D * 8388608.0) / 8388608.0;
  Result := Trunc22(Power(2.0, D));
end;

function VRExp2(X: Cardinal): Cardinal;
begin
  Result := VExp2(X xor $80000000);
end;

function VLog2(X: Cardinal): Cardinal;
begin
  X := VFlush(X);
  if VIsNaN(X) then
    Exit(VF_NAN);
  if (X and $7FFFFFFF) = 0 then
    Exit($FF800000);
  if (X and $80000000) <> 0 then
    Exit(VF_NAN);
  if X = $7F800000 then
    Exit($7F800000);
  Result := Round22(Log2(Double(BitsToSingle(X))));
end;

procedure InitSinNodes;
begin
  for var K := 0 to 256 do
    SinNodes[K] := Sin(K * (Pi / 512));
end;

initialization
  InitSinNodes;

end.
