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
function VAdd(A, B: Cardinal): Cardinal;
function VSub(A, B: Cardinal): Cardinal;
function VMul(A, B: Cardinal): Cardinal;
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

const
  SumWindow = 24;

function VSum4(const A, B: array of Cardinal; Count: Integer; Skip: Cardinal): Cardinal;
var
  Sign: array[0..3] of Boolean;
  Mant: array[0..3] of UInt64;
  Expo: array[0..3] of Integer;
begin
  var HasNaN := False;
  var PosInf := False;
  var NegInf := False;
  var MaxE := -100000;
  var Used := 0;
  for var I := 0 to Count - 1 do
  begin
    if (Skip shr I) and 1 <> 0 then
      Continue;
    var X := VFlush(A[I]);
    var Y := VFlush(B[I]);
    var Neg := ((X xor Y) and $80000000) <> 0;
    var EX := (X shr 23) and $FF;
    var EY := (Y shr 23) and $FF;
    if (EX = $FF) or (EY = $FF) then
    begin
      if ((EX = $FF) and ((X and $7FFFFF) <> 0)) or ((EY = $FF) and ((Y and $7FFFFF) <> 0)) then
        HasNaN := True
      else if ((X and $7FFFFFFF) = 0) or ((Y and $7FFFFFFF) = 0) then
        HasNaN := True
      else if Neg then
        NegInf := True
      else
        PosInf := True;
      Continue;
    end;
    if (EX = 0) or (EY = 0) then
      Continue;
    // Exact 48-bit product of the two 24-bit mantissas.
    var M := UInt64((X and $7FFFFF) or $800000) * UInt64((Y and $7FFFFF) or $800000);
    var E := Integer(EX) + Integer(EY) - 127;
    // Normalise so the leading bit sits at bit 47.
    if (M and (UInt64(1) shl 47)) = 0 then
      M := M shl 1
    else
      Inc(E);
    Sign[Used] := Neg;
    Mant[Used] := M;
    Expo[Used] := E;
    if E > MaxE then
      MaxE := E;
    Inc(Used);
  end;
  if HasNaN or (PosInf and NegInf) then
    Exit(VF_NAN);
  if PosInf then
    Exit($7F800000);
  if NegInf then
    Exit($FF800000);
  if Used = 0 then
    Exit(0);
  // Align every term to the largest exponent, keeping SumWindow bits below the
  // leading bit of the largest one; the rest is truncated.
  var Total: Int64 := 0;
  for var I := 0 to Used - 1 do
  begin
    var Shift := 47 - SumWindow + (MaxE - Expo[I]);
    var V: Int64;
    if Shift >= 64 then
      V := 0
    else
      V := Int64(Mant[I] shr Shift);
    if Sign[I] then
      Total := Total - V
    else
      Total := Total + V;
  end;
  if Total = 0 then
    Exit(0);
  var Neg := Total < 0;
  var U: UInt64 := UInt64(Abs(Total));
  var Top := 63;
  while (U and (UInt64(1) shl Top)) = 0 do
    Dec(Top);
  var E := MaxE + (Top - SumWindow);
  // Round to 24 bits, nearest even.
  var Mant24: UInt64;
  if Top > 23 then
  begin
    var Drop := Top - 23;
    Mant24 := U shr Drop;
    var Rem := U and ((UInt64(1) shl Drop) - 1);
    var Half := UInt64(1) shl (Drop - 1);
    if (Rem > Half) or ((Rem = Half) and ((Mant24 and 1) <> 0)) then
    begin
      Inc(Mant24);
      if Mant24 = (UInt64(1) shl 24) then
      begin
        Mant24 := Mant24 shr 1;
        Inc(E);
      end;
    end;
  end
  else
    Mant24 := U shl (23 - Top);
  var SignBit: Cardinal := 0;
  if Neg then
    SignBit := $80000000;
  if E >= 255 then
    Exit(SignBit or $7F800000);
  if E <= 0 then
    Exit(SignBit);
  Result := SignBit or (Cardinal(E) shl 23) or (Cardinal(Mant24) and $7FFFFF);
end;

{ Function unit. Results carry 22 bits of mantissa. }

function Trunc22(D: Double): Cardinal;
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
  Result := Trunc22(1.0 / Double(BitsToSingle(X)));
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
  Result := Trunc22(1.0 / Sqrt(Double(BitsToSingle(X))));
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

// Angles are in quarter turns; the reduction keeps the quadrant exactly.
function SinQuarter(X: Cardinal; Cosine: Boolean): Cardinal;
begin
  X := VFlush(X);
  if (X and $7F800000) = $7F800000 then
  begin
    if Cosine then
      Exit(VF_NAN);
    Exit(NaNOf(X));
  end;
  var D: Double := BitsToSingle(X);
  if Cosine then
    D := D + 1.0;
  var R := D - 4.0 * Floor(D / 4.0);
  var Res: Double;
  if R = 0 then
    Res := 0
  else if R = 1 then
    Res := 1
  else if R = 2 then
    Res := 0
  else if R = 3 then
    Res := -1
  else
    Res := Sin(R * (Pi / 2));
  if Res = 0 then
  begin
    if Cosine then
    begin
      if R = 2 then
        Exit($80000000);
      Exit(0);
    end;
    Exit(X and $80000000);
  end;
  Result := Trunc22(Res);
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
  Result := Trunc22(ArcSin(Double(BitsToSingle(X))) / (Pi / 2));
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
  Result := Trunc22(Log2(Double(BitsToSingle(X))));
end;

end.
