unit ZX.Timex;

interface

uses
  System.SysUtils, Core.Snapshots;

type
  // Three 64 KiB banks, independently selected in eight 8 KiB chunks.
  // Absent HOME chunks fall through to the motherboard ROM/DRAM.
  TZXTimexMemory = class
  private
    FFlags: array[0..2, 0..7] of Byte;
    FData: array[0..2, 0..65535] of Byte;
    function Bank(Address: Word): Integer;
  public
    HSR, DEC: Byte;
    procedure Reset(const EXROM: TBytes);
    procedure LoadDCK(const Data: TBytes);
    function ReadMemory(Address: Word; out Value: Byte): Boolean;
    function WriteMemory(Address: Word; Value: Byte): Boolean;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Classes;

procedure TZXTimexMemory.Reset(const EXROM: TBytes);
begin
  FillChar(FFlags, SizeOf(FFlags), 0);
  FillChar(FData, SizeOf(FData), $FF);
  HSR := 0;
  DEC := 0;
  if Length(EXROM) = 8192 then
    for var i := 0 to 7 do
    begin
      FFlags[2, i] := 2;
      Move(EXROM[0], FData[2, i * 8192], 8192);
    end;
end;

function TZXTimexMemory.Bank(Address: Word): Integer;
begin
  Result := 0;
  if (HSR and (1 shl (Address shr 13))) <> 0 then
    if (DEC and $80) <> 0 then
      Result := 2
    else
      Result := 1;
end;

function TZXTimexMemory.ReadMemory(Address: Word; out Value: Byte): Boolean;
begin
  var B := Bank(Address);
  Result := (B <> 0) or (FFlags[B, Address shr 13] <> 0);
  if Result then
    Value := FData[B, Address];
end;

function TZXTimexMemory.WriteMemory(Address: Word; Value: Byte): Boolean;
begin
  var B := Bank(Address);
  var Flags := FFlags[B, Address shr 13];
  Result := (B <> 0) or (Flags <> 0);
  if Result and ((Flags and 1) <> 0) then
    FData[B, Address] := Value;
end;

procedure TZXTimexMemory.LoadDCK(const Data: TBytes);
var
  Flags: array[0..2, 0..7] of Byte;
  Memory: array[0..2, 0..65535] of Byte;
begin
  // Parse transactionally; malformed images must not partially replace a cartridge.
  Move(FFlags, Flags, SizeOf(Flags));
  Move(FData, Memory, SizeOf(Memory));
  var Seen: set of Byte;
  Seen := [];
  var P := 0;
  if Length(Data) = 0 then
    raise EReadError.Create('Empty Timex DCK cartridge');
  while P < Length(Data) do
  begin
    if Length(Data) - P < 9 then
      raise EReadError.Create('Truncated DCK header');
    var B: Integer;
    case Data[P] of
      255:
        B := 0;
      0:
        B := 1;
      254:
        B := 2;
    else
      raise EReadError.Create('Unsupported DCK bank');
    end;
    if B in Seen then
      raise EReadError.Create('Duplicate DCK bank');
    Include(Seen, B);
    for var i := 0 to 7 do
    begin
      var F := Data[P + 1 + i];
      if F > 3 then
        raise EReadError.Create('Invalid DCK chunk flags');
      if F <> 0 then
        Flags[B, i] := F;
    end;
    var Header := P;
    Inc(P, 9);
    for var i := 0 to 7 do
    begin
      var F := Data[Header + 1 + i];
      if (F and 2) <> 0 then
      begin
        if Length(Data) - P < 8192 then
          raise EReadError.Create('Truncated DCK chunk');
        Move(Data[P], Memory[B, i * 8192], 8192);
        Inc(P, 8192);
      end
      else if F = 1 then
        FillChar(Memory[B, i * 8192], 8192, 0);
    end;
  end;
  Move(Flags, FFlags, SizeOf(Flags));
  Move(Memory, FData, SizeOf(Memory));
end;

procedure TZXTimexMemory.SerializeState(State: TStateArchive);
begin
  State.Field(HSR, 1);
  State.Field(DEC, 1);
  State.Field(FFlags, SizeOf(FFlags));
  for var B := 0 to 2 do
    for var i := 0 to 7 do
      if FFlags[B, i] > 3 then
        raise EReadError.Create('Invalid Timex cartridge state');
  State.Field(FData, SizeOf(FData));
end;

end.

