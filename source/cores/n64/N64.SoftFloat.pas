unit N64.SoftFloat;
{$Q+}{$R+}

interface

uses N64.Types;

const
  sfInexact = 1; sfUnderflow = 2; sfOverflow = 4; sfDivideZero = 8; sfInvalid = 16;

type
  TSoftFloatResult = record
    Bits: UInt64;
    Events: Cardinal;
  end;

function SFCalculate(A, B: UInt64; Format, Operation, Rounding: Integer): TSoftFloatResult;
function SFConvert(A: UInt64; SourceFormat, TargetFormat, Rounding: Integer): TSoftFloatResult;
procedure SFCompare(A, B: UInt64; Format: Integer; out Unordered, Equal, Less: Boolean);
function SFIsNaN(A: UInt64; Format: Integer): Boolean;
function SFIsSubnormal(A: UInt64; Format: Integer): Boolean;

implementation

type
  TNumber = record
    Negative: Boolean;
    Exponent: Integer;
    Significand: UInt64; // Normalized at bit 62; ten guard/sticky bits for binary64.
    Kind: Integer; // 0 finite, 1 infinity, 2 NaN.
  end;

function FractionBits(Format: Integer): Integer;
begin
  if Format = 16 then Result := 23 else Result := 52;
end;

function Bias(Format: Integer): Integer;
begin
  if Format = 16 then Result := 127 else Result := 1023;
end;

function SignMask(Format: Integer): UInt64;
begin
  if Format = 16 then Result := $80000000 else Result := UInt64(1) shl 63;
end;

function Infinity(Format: Integer): UInt64;
begin
  if Format = 16 then Result := $7F800000 else Result := $7FF0000000000000;
end;

function DefaultNaN(Format: Integer): UInt64;
begin
  // R4300 uses the pre-NaN2008 encoding (quiet bit clear).
  if Format = 16 then Result := $7FBFFFFF else Result := $7FF7FFFFFFFFFFFF;
end;

function SFIsNaN(A: UInt64; Format: Integer): Boolean;
begin
  Result := ((A and Infinity(Format)) = Infinity(Format)) and
    ((A and ((UInt64(1) shl FractionBits(Format)) - 1)) <> 0);
end;

function SFIsSubnormal(A: UInt64; Format: Integer): Boolean;
begin
  Result := ((A and Infinity(Format)) = 0) and
    ((A and ((UInt64(1) shl FractionBits(Format)) - 1)) <> 0);
end;

function ShiftJam(A: UInt64; N: Integer): UInt64;
begin
  if N <= 0 then Exit(A);
  if N >= 64 then Exit(Ord(A <> 0));
  Result := (A shr N) or UInt64(Ord((A shl (64 - N)) <> 0));
end;

procedure Product64(A, B: UInt64; out Hi, Lo: UInt64); inline;
begin
  // Four 32-bit products; carry sums are at most 34 bits. The high sum is
  // bounded by the true upper product, so every host addition is in range.
  var P0 := (A and $FFFFFFFF) * (B and $FFFFFFFF);
  var P1 := (A and $FFFFFFFF) * (B shr 32);
  var P2 := (A shr 32) * (B and $FFFFFFFF);
  var P3 := (A shr 32) * (B shr 32);
  var Middle := (P0 shr 32) + (P1 and $FFFFFFFF) + (P2 and $FFFFFFFF);
  Lo := ((Middle and $FFFFFFFF) shl 32) or (P0 and $FFFFFFFF);
  Hi := P3 + (P1 shr 32) + (P2 shr 32) + (Middle shr 32);
end;

function Decode(A: UInt64; Format: Integer): TNumber;
begin
  Result := Default(TNumber);
  Result.Negative := (A and SignMask(Format)) <> 0;
  var P := FractionBits(Format);
  var E := Integer((A and Infinity(Format)) shr P);
  var F := A and ((UInt64(1) shl P) - 1);
  if E = Bias(Format) * 2 + 1 then
  begin
    Result.Kind := 1 + Ord(F <> 0);
    Exit;
  end;
  Result.Exponent := E - Bias(Format);
  if E <> 0 then F := F or (UInt64(1) shl P)
  else Result.Exponent := 1 - Bias(Format);
  Result.Significand := F shl (62 - P);
  if F = 0 then Exit;
  while (Result.Significand and (UInt64(1) shl 62)) = 0 do
  begin
    Result.Significand := Result.Significand shl 1;
    Dec(Result.Exponent);
  end;
end;

function Pack(Negative: Boolean; Exponent: Integer; Sig: UInt64;
  Format, Rounding: Integer): TSoftFloatResult;
begin
  Result := Default(TSoftFloatResult);
  if Negative then Result.Bits := SignMask(Format);
  if Sig = 0 then Exit;
  if (Sig shr 63) <> 0 then
  begin
    Sig := ShiftJam(Sig, 1);
    Inc(Exponent);
  end;
  while (Sig and (UInt64(1) shl 62)) = 0 do
  begin
    Sig := Sig shl 1;
    Dec(Exponent);
  end;
  var B := Bias(Format);
  var P := FractionBits(Format);
  var Tiny := Exponent < 1 - B;
  if Tiny then
  begin
    Sig := ShiftJam(Sig, 1 - B - Exponent);
    Exponent := 1 - B;
  end;
  var Shift := 62 - P;
  var Remainder := Sig and ((UInt64(1) shl Shift) - 1);
  var Fraction := Sig shr Shift;
  var Increment := False;
  if Remainder <> 0 then
  begin
    Result.Events := sfInexact;
    case Rounding of
      0: Increment := (Remainder > (UInt64(1) shl (Shift - 1))) or
        ((Remainder = (UInt64(1) shl (Shift - 1))) and Odd(Fraction));
      2: Increment := not Negative;
      3: Increment := Negative;
    end;
  end;
  if Increment then Inc(Fraction);
  if Fraction >= (UInt64(1) shl (P + 1)) then
  begin
    Fraction := Fraction shr 1;
    Inc(Exponent);
  end;
  if Exponent > B then
  begin
    Result.Events := sfOverflow or sfInexact;
    var ToInfinity := (Rounding = 0) or ((Rounding = 2) and not Negative) or
      ((Rounding = 3) and Negative);
    if ToInfinity then Result.Bits := Result.Bits or Infinity(Format)
    else Result.Bits := Result.Bits or (Infinity(Format) - 1);
    Exit;
  end;
  var E := Exponent + B;
  if Fraction < (UInt64(1) shl P) then E := 0;
  if Tiny and (E = 0) and (Remainder <> 0) then
    Result.Events := Result.Events or sfUnderflow;
  Result.Bits := Result.Bits or (UInt64(E) shl P) or
    (Fraction and ((UInt64(1) shl P) - 1));
end;

function Invalid(Format: Integer): TSoftFloatResult;
begin
  Result.Bits := DefaultNaN(Format);
  Result.Events := sfInvalid;
end;

function SFCalculate(A, B: UInt64; Format, Operation, Rounding: Integer): TSoftFloatResult;
begin
  Result := Default(TSoftFloatResult);
  var X := Decode(A, Format);
  var Y := Decode(B, Format);
  if (X.Kind = 2) or ((Operation <= 3) and (Y.Kind = 2)) then Exit(Invalid(Format));
  if Operation = 1 then Y.Negative := not Y.Negative;
  var Negative := X.Negative xor Y.Negative;
  var Sig: UInt64;
  var E: Integer;
  case Operation of
    0, 1:
      begin
        if (X.Kind = 1) or (Y.Kind = 1) then
        begin
          if (X.Kind = 1) and (Y.Kind = 1) and (X.Negative <> Y.Negative) then Exit(Invalid(Format));
          if X.Kind <> 1 then X := Y;
          Result.Bits := Infinity(Format);
          if X.Negative then Result.Bits := Result.Bits or SignMask(Format);
          Exit;
        end;
        if (X.Exponent < Y.Exponent) or ((X.Exponent = Y.Exponent) and
          (X.Significand < Y.Significand)) then
        begin
          var Temp := X; X := Y; Y := Temp;
        end;
        Y.Significand := ShiftJam(Y.Significand, X.Exponent - Y.Exponent);
        if X.Negative = Y.Negative then Sig := X.Significand + Y.Significand
        else Sig := X.Significand - Y.Significand;
        Negative := X.Negative;
        if Sig = 0 then Negative := ((X.Negative = Y.Negative) and X.Negative) or
          ((X.Negative <> Y.Negative) and (Rounding = 3));
        Result := Pack(Negative, X.Exponent, Sig, Format, Rounding);
      end;
    2:
      begin
        if (X.Kind = 1) or (Y.Kind = 1) then
        begin
          if ((X.Kind = 0) and (X.Significand = 0)) or
            ((Y.Kind = 0) and (Y.Significand = 0)) then Exit(Invalid(Format));
          Result.Bits := Infinity(Format);
          if Negative then Result.Bits := Result.Bits or SignMask(Format);
          Exit;
        end;
        var Hi, Lo: UInt64;
        Product64(X.Significand shr 10, Y.Significand shr 10, Hi, Lo);
        E := X.Exponent + Y.Exponent;
        Sig := (Hi shl 22) or (Lo shr 42) or UInt64(Ord((Lo shl 22) <> 0));
        Result := Pack(Negative, E, Sig, Format, Rounding);
      end;
    3:
      begin
        if ((X.Kind = 1) and (Y.Kind = 1)) or ((X.Kind = 0) and (X.Significand = 0) and
          (Y.Kind = 0) and (Y.Significand = 0)) then Exit(Invalid(Format));
        if (X.Kind = 1) or ((Y.Kind = 0) and (Y.Significand = 0)) then
        begin
          Result.Bits := Infinity(Format);
          if X.Kind <> 1 then Result.Events := sfDivideZero;
        end
        else if (Y.Kind = 1) or (X.Significand = 0) then Result.Bits := 0
        else
        begin
          var R := X.Significand shr 10;
          var Divisor := Y.Significand shr 10;
          E := X.Exponent - Y.Exponent;
          if R < Divisor then begin R := R shl 1; Dec(E); end;
          Sig := 0;
          for var I := 62 downto 0 do
          begin
            if R >= Divisor then begin R := R - Divisor; Sig := Sig or (UInt64(1) shl I); end;
            R := R shl 1;
          end;
          if R <> 0 then Sig := Sig or 1;
          Exit(Pack(Negative, E, Sig, Format, Rounding));
        end;
        if Negative then Result.Bits := Result.Bits or SignMask(Format);
      end;
    4:
      begin
        if X.Negative and ((X.Kind = 1) or (X.Significand <> 0)) then Exit(Invalid(Format));
        if X.Kind = 1 then begin Result.Bits := A; Exit; end;
        if X.Significand = 0 then begin Result.Bits := A and SignMask(Format); Exit; end;
        E := X.Exponent;
        var OddExponent := Odd(E);
        if OddExponent then Dec(E);
        E := E div 2;
        // A 126-bit radicand and a 63-bit root. Trial squares avoid any
        // overflowing 65-bit remainder in a restoring square-root loop.
        var Shift := 72 + Ord(OddExponent);
        var RadHi := (X.Significand shr 10) shl (Shift - 64);
        var RadLo: UInt64 := 0;
        Sig := 0;
        for var I := 62 downto 0 do
        begin
          var Trial := Sig or (UInt64(1) shl I);
          var Hi, Lo: UInt64;
          Product64(Trial, Trial, Hi, Lo);
          if (Hi < RadHi) or ((Hi = RadHi) and (Lo <= RadLo)) then Sig := Trial;
        end;
        var Hi, Lo: UInt64;
        Product64(Sig, Sig, Hi, Lo);
        if (Hi <> RadHi) or (Lo <> RadLo) then Sig := Sig or 1;
        Result := Pack(False, E, Sig, Format, Rounding);
      end;
    5, 7:
      begin
        Result.Bits := A;
        if Operation = 5 then Result.Bits := A and not SignMask(Format)
        else Result.Bits := A xor SignMask(Format);
      end;
  end;
end;

function SFConvert(A: UInt64; SourceFormat, TargetFormat, Rounding: Integer): TSoftFloatResult;
begin
  Result := Default(TSoftFloatResult);
  if SourceFormat in [20, 21] then
  begin
    if SourceFormat = 20 then A := SX(A, 32);
    var Negative := (A shr 63) <> 0;
    if Negative then A := Sub64(0, A);
    var E := 62;
    if (A shr 63) <> 0 then begin A := ShiftJam(A, 1); Inc(E); end;
    Exit(Pack(Negative, E, A, TargetFormat, Rounding));
  end;
  var X := Decode(A, SourceFormat);
  if TargetFormat in [16, 17] then
  begin
    if X.Kind = 2 then Exit(Invalid(TargetFormat));
    if X.Kind = 1 then
    begin
      Result.Bits := Infinity(TargetFormat);
      if X.Negative then Result.Bits := Result.Bits or SignMask(TargetFormat);
      Exit;
    end;
    Exit(Pack(X.Negative, X.Exponent, X.Significand, TargetFormat, Rounding));
  end;
  var Width := 64;
  if TargetFormat = 20 then Width := 32;
  Result.Bits := UInt64(1) shl (Width - 1);
  if (X.Kind <> 0) or (X.Exponent > Width - 1) then begin Result.Events := sfInvalid; Exit; end;
  var Shift := 62 - X.Exponent;
  var Fraction: UInt64 := 0;
  var Remainder: UInt64 := X.Significand;
  var Half: UInt64 := 0;
  if Shift <= 0 then begin Fraction := X.Significand shl (-Shift); Remainder := 0; end
  else if Shift < 64 then
  begin
    Fraction := X.Significand shr Shift;
    Remainder := X.Significand and ((UInt64(1) shl Shift) - 1);
    Half := UInt64(1) shl (Shift - 1);
  end;
  var Increment := False;
  if Remainder <> 0 then
  begin
    Result.Events := sfInexact;
    case Rounding of
      0: Increment := (Half <> 0) and ((Remainder > Half) or ((Remainder = Half) and Odd(Fraction)));
      2: Increment := not X.Negative;
      3: Increment := X.Negative;
    end;
  end;
  if Increment then Fraction := Add64(Fraction, 1);
  var Limit := UInt64(1) shl (Width - 1);
  if (Fraction > Limit) or ((Fraction = Limit) and not X.Negative) then
  begin
    Result.Events := sfInvalid;
    Exit;
  end;
  if X.Negative then Fraction := Sub64(0, Fraction);
  if Width = 32 then Fraction := Fraction and $FFFFFFFF;
  Result.Bits := Fraction;
end;

procedure SFCompare(A, B: UInt64; Format: Integer; out Unordered, Equal, Less: Boolean);
begin
  Unordered := SFIsNaN(A, Format) or SFIsNaN(B, Format);
  Equal := False; Less := False;
  if Unordered then Exit;
  var Mask := SignMask(Format);
  if ((A and not Mask) = 0) and ((B and not Mask) = 0) then begin Equal := True; Exit; end;
  Equal := A = B;
  if ((A xor B) and Mask) <> 0 then Less := (A and Mask) <> 0
  else if (A and Mask) <> 0 then Less := A > B
  else Less := A < B;
end;

end.
