unit CPS.Kabuki;

interface

uses
  System.SysUtils;

// CPS1 Kabuki encrypts the fixed 32 KiB only; banks are plain music data.
procedure DecodeKabuki(const Source: TBytes; const Family: string; out Data, Opcodes: TBytes);

implementation

function SwapPairs(Value: Byte; Key, Select: Cardinal; Reverse: Boolean): Byte;
begin
  Result := Value;
  for var Pair := 0 to 3 do
  begin
    var N := Pair;
    if Reverse then
      N := 3 - Pair;
    if Select and (Cardinal(1) shl ((Key shr (N * 4)) and 7)) <> 0 then
    begin
      var Shift := Pair * 2;
      var Bits := (Result shr Shift) and 3;
      Result := Byte((Result and not (3 shl Shift)) or (((Bits shr 1) or ((Bits and 1) shl 1)) shl Shift));
    end;
  end;
end;

function Rotate(Value: Byte): Byte; inline;
begin
  Result := Byte(((Cardinal(Value) shl 1) or (Value shr 7)) and $FF);
end;

function Decode(Value: Byte; K1, K2, Select: Cardinal; X: Byte): Byte;
begin
  Value := Rotate(SwapPairs(Value, K1 and $FFFF, Select and $FF, False));
  Value := SwapPairs(Value, K1 shr 16, Select and $FF, True) xor X;
  Value := Rotate(Value);
  Value := Rotate(SwapPairs(Value, K2 and $FFFF, Select shr 8, True));
  Result := SwapPairs(Value, K2 shr 16, Select shr 8, False);
end;

procedure DecodeKabuki(const Source: TBytes; const Family: string; out Data, Opcodes: TBytes);
begin
  var K1, K2, A: Cardinal;
  var X: Byte;
  if Family = 'wof' then
  begin
    K1 := $01234567;
    K2 := $54163072;
    A := $5151;
    X := $51;
  end
  else if Family = 'dino' then
  begin
    K1 := $76543210;
    K2 := $24601357;
    A := $4343;
    X := $43;
  end
  else if Family = 'punisher' then
  begin
    K1 := $67452103;
    K2 := $75316024;
    A := $2222;
    X := $22;
  end
  else if Family = 'slammast' then
  begin
    K1 := $54321076;
    K2 := $65432107;
    A := $3131;
    X := $19;
  end
  else
    raise EArgumentException.Create('Unknown CPS1 Kabuki key: ' + Family);

  if Length(Source) < $8000 then
    raise EArgumentException.Create('Truncated Kabuki ROM');

  Data := Copy(Source);
  SetLength(Opcodes, $8000);
  for var i := 0 to $7FFF do
  begin
    Opcodes[i] := Decode(Source[i], K1, K2, Cardinal(i) + A, X);
    Data[i] := Decode(Source[i], K1, K2, Cardinal(i xor $1FC0) + A + 1, X);
  end;
end;

end.

