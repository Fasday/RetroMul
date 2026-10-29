unit PSP.Crypto.Keys;

// Numeric device data, kept separate from implementation. See
// PSP.Crypto.md for sources and the reproducible importer.
interface

uses System.SysUtils;

function PSPHex(const S: string): TBytes;
function PSPKirkSlot(Index: Integer): TBytes;
function PSPPrxSeed(const Name: string): TBytes;

implementation

type
  TPRXSeedData = record
    Name, Hex: string;
  end;

{$I PSP.Crypto.Keys.inc}

function PSPHex(const S: string): TBytes;
begin
  if Length(S) and 1 <> 0 then raise EArgumentException.Create('Odd hex length');
  SetLength(Result, Length(S) div 2);
  for var I := 0 to High(Result) do
    Result[I] := StrToInt('$' + Copy(S, I * 2 + 1, 2));
end;

function PSPKirkSlot(Index: Integer): TBytes;
begin
  if (Index < 0) or (Index > 127) then raise EArgumentOutOfRangeException.Create('KIRK AES slot');
  Result := PSPHex(KirkSlotHex[Index]);
end;

function PSPPrxSeed(const Name: string): TBytes;
begin
  for var Entry in PrxSeeds do
    if SameText(Entry.Name, Name) then Exit(PSPHex(Entry.Hex));
  Result := nil;
end;

end.
