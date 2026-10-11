unit MD.Arithmetic;

interface

function Add32(A, B: Cardinal): Cardinal; inline;

function Sub32(A, B: Cardinal): Cardinal; inline;

function Mul32(A, B: Cardinal): Cardinal; inline;

function ArithmeticShiftRight(Value: Integer; Bits: Cardinal): Integer; inline;

implementation

// These three operations deliberately wrap modulo 2^32. Keep native-width
// arithmetic even in checked builds; restore this unit's original setting below.
{$IFOPT Q+}{$DEFINE MD_RESTORE_OVERFLOW_CHECKS}{$ENDIF}
{$Q-}

function Add32(A, B: Cardinal): Cardinal;
begin
  Result := A + B;
end;

function Sub32(A, B: Cardinal): Cardinal;
begin
  Result := A - B;
end;

function Mul32(A, B: Cardinal): Cardinal;
begin
  Result := A * B;
end;

{$IFDEF MD_RESTORE_OVERFLOW_CHECKS}{$Q+}{$UNDEF MD_RESTORE_OVERFLOW_CHECKS}{$ENDIF}

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

