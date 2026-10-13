unit GBA.Multiply;

interface

procedure ARM7MultiplyCarry(Multiplicand, Multiplier: Cardinal; Accumulator: UInt64; LongResult, SignedResult: Boolean; out Carry: Cardinal; out Cycles: Integer);

implementation

type
  TPair = record
    Lo, Hi: UInt64;
  end;

function Bit(V: UInt64; N: Integer): UInt64; inline;
begin
  Result := (V shr N) and 1;
end;

function ROR128(V: TPair; N: Integer): TPair;
begin
  Result.Lo := (V.Lo shr N) or (V.Hi shl (64 - N));
  Result.Hi := (V.Hi shr N) or (V.Lo shl (64 - N));
end;

procedure ARM7MultiplyCarry(Multiplicand, Multiplier: Cardinal; Accumulator: UInt64; LongResult, SignedResult: Boolean; out Carry: Cardinal; out Cycles: Integer);
const
  Correction: array[1..4] of Integer = (23, 15, 7, 31);
begin
  var M := UInt64(Multiplicand);
  var S := UInt64(Multiplier);
  if SignedResult then
  begin
    if M and $80000000 <> 0 then
      M := M or UInt64($300000000);
    if S and $80000000 <> 0 then
      S := S or UInt64($300000000);
  end;

  var Sum := Accumulator;
  var Car: UInt64 := 0;
  if S and 1 <> 0 then
    Car := not M;

  var AccShift := Accumulator shr 34;
  var Partial: TPair;
  Partial.Lo := Car and 1;
  Partial.Hi := 0;
  Sum := Sum shr 1;
  Car := Car shr 1;
  Partial := ROR128(Partial, 1);
  Cycles := 0;

  repeat
    var OutSum: UInt64 := 0;
    var OutCar: UInt64 := 0;
    for var i := 0 to 3 do
    begin
      var Addend: UInt64 := 0;
      var BoothCarry: UInt64 := 0;
      case (S shr (i * 2)) and 7 of
        1, 2:
          Addend := M;
        3:
          Addend := M shl 1;
        4:
          begin
            Addend := not (M shl 1);
            BoothCarry := 1;
          end;
        5, 6:
          begin
            Addend := not M;
            BoothCarry := 1;
          end;
      end;

      Addend := Addend and UInt64($3FFFFFFFF);
      Sum := Sum and UInt64($1FFFFFFFF);
      Car := Car and UInt64($1FFFFFFFF);
      var LowAddend := Addend and UInt64($1FFFFFFFF);
      var NextSum := Sum xor LowAddend xor Car;
      var NextCar := (((Sum and LowAddend) or (LowAddend and Car) or (Car and Sum)) shl 1) or BoothCarry;
      OutSum := OutSum or ((NextSum and 3) shl (i * 2));
      OutCar := OutCar or ((NextCar and 3) shl (i * 2));
      var Magic := Bit(AccShift, 0) + (1 - Bit(Car, 32)) + (1 - Bit(Addend, 33));
      Sum := (NextSum shr 2) or (Magic shl 31);
      Car := (NextCar shr 2) or ((1 - Bit(AccShift, 1)) shl 32);
      AccShift := AccShift shr 2;
    end;

    Sum := OutSum or (Sum shl 8);
    Car := OutCar or (Car shl 8);
    Partial.Lo := Partial.Lo or (Car and 255);
    Sum := Sum shr 8;
    Car := Car shr 8;
    Partial := ROR128(Partial, 8);
    if S and UInt64($100000000) <> 0 then
      S := (S shr 8) or UInt64($1FE000000)
    else
      S := S shr 8;
    S := S and UInt64($1FFFFFFFF);
    Inc(Cycles);
  until (S = 0) or (SignedResult and (S = UInt64($1FFFFFFFF)));

  Partial.Lo := Partial.Lo or Car;
  Partial := ROR128(Partial, Correction[Cycles]);

  if not LongResult and (Cycles = 4) then
    Carry := Cardinal(Bit(Partial.Hi, 31))
  else
    Carry := Cardinal(Bit(Partial.Hi, 63));
end;

end.

