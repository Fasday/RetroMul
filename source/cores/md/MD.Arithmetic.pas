unit MD.Arithmetic;

interface

function Add32(A, B: Cardinal): Cardinal; inline;

function Sub32(A, B: Cardinal): Cardinal; inline;

function Mul32(A, B: Cardinal): Cardinal; inline;

function ArithmeticShiftRight(Value: Integer; Bits: Cardinal): Integer; inline;

implementation

// Explicit modulo arithmetic with wide intermediates; no disabled checks.

function Add32(A, B: Cardinal): Cardinal;
begin
  Result := Cardinal((UInt64(A) + UInt64(B)) and $FFFFFFFF);
end;

function Sub32(A, B: Cardinal): Cardinal;
begin
  Result := Cardinal((UInt64(A) + UInt64($100000000) - UInt64(B)) and $FFFFFFFF);
end;

function Mul32(A, B: Cardinal): Cardinal;
begin
  Result := Cardinal((UInt64(A) * UInt64(B)) and $FFFFFFFF);
end;

function ArithmeticShiftRight(Value: Integer; Bits: Cardinal): Integer;
begin
  if Bits = 0 then
    Exit(Value);

  if Bits >= 32 then
  begin
    if Value < 0 then
      Exit(-1);
    Exit(0);
  end;

  // Shifting the complemented value avoids signed overflow and negative masks.
  if Value < 0 then
    Result := not Integer(Cardinal(not Value) shr Bits)
  else
    Result := Value shr Bits;
end;

end.

