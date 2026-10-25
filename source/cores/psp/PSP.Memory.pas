unit PSP.Memory;

{$Q-}{$R-}{$POINTERMATH ON}

interface

uses System.SysUtils;

const
  PSPRAMBase = $08000000;
  PSPUserBase = $08800000;
  PSPThreadReturnTrampoline = $08000000;
  PSPCallbackReturnTrampoline = $08000010;
  PSPInterruptStackTop = $08002000;
  PSPVRAMBase = $04000000;
  PSPScratchBase = $00010000;
  PSPRAMSize = $02000000;
  PSPVRAMSize = $00200000;
  PSPScratchSize = $00004000;

type
  EPSPMemory = class(Exception);

  // Host pointers never escape the bus. Uncached/KSEG aliases share storage.
  TPSPMemory = class
  private
    FRAM, FVRAM, FScratch: TBytes;
    FWriteGeneration: UInt64;
    function Resolve(Address, Count: Cardinal): PByte; inline;
  public
    constructor Create;
    procedure Clear;
    function IsValid(Address, Count: Cardinal): Boolean;
    function Read8(Address: Cardinal): Byte; inline;
    function Read16(Address: Cardinal): Word; inline;
    function Read32(Address: Cardinal): Cardinal; inline;
    procedure Write8(Address: Cardinal; Value: Byte); inline;
    procedure Write16(Address: Cardinal; Value: Word); inline;
    procedure Write32(Address, Value: Cardinal); inline;
    function ReadBytes(Address,Count:Cardinal):TBytes;
    procedure Load(Address: Cardinal; const Data: TBytes);
    procedure Zero(Address, Count: Cardinal);
    procedure Fill(Address, Count: Cardinal; Value: Byte);
    // Count is a number of elements, not bytes. Mapping is checked once.
    procedure Fill16(Address,Count:Cardinal;Value:Word);
    procedure Fill32(Address,Count,Value:Cardinal);
    procedure CopyMemory(Destination, Source, Count: Cardinal);
    function ReadString(Address: Cardinal; Limit: Cardinal = 256): string;
    property WriteGeneration: UInt64 read FWriteGeneration;
  end;

implementation

constructor TPSPMemory.Create;
begin
  inherited;
  SetLength(FRAM, PSPRAMSize);
  SetLength(FVRAM, PSPVRAMSize);
  SetLength(FScratch, PSPScratchSize);
end;

procedure TPSPMemory.Clear;
begin
  Inc(FWriteGeneration);
  FillChar(FRAM[0], Length(FRAM), 0);
  FillChar(FVRAM[0], Length(FVRAM), 0);
  FillChar(FScratch[0], Length(FScratch), 0);
end;

function TPSPMemory.Resolve(Address, Count: Cardinal): PByte;
var
  Physical, Offset, Size: Cardinal;
begin
  Result := nil;
  Physical := Address and $3FFFFFFF;
  if (Physical >= PSPRAMBase) and (Physical < PSPRAMBase + PSPRAMSize) then
  begin
    Offset := Physical - PSPRAMBase;
    Size := Length(FRAM);
    Result := @FRAM[Offset];
  end
  else if (Physical >= PSPVRAMBase) and (Physical < PSPVRAMBase + $00800000) and
    (Physical and $00200000 = 0) then
  begin
    Offset := (Physical - PSPVRAMBase) and (PSPVRAMSize - 1);
    Size := Length(FVRAM);
    Result := @FVRAM[Offset];
  end
  else if (Physical >= PSPScratchBase) and (Physical < PSPScratchBase + PSPScratchSize) then
  begin
    Offset := Physical - PSPScratchBase;
    Size := Length(FScratch);
    Result := @FScratch[Offset];
  end
  else
    Exit;
  if Count > Size - Offset then
    Result := nil;
end;

function TPSPMemory.IsValid(Address, Count: Cardinal): Boolean;
begin
  Result := Resolve(Address, Count) <> nil;
end;

function TPSPMemory.Read8(Address: Cardinal): Byte;
begin
  var P := Resolve(Address, 1);
  if P = nil then
    raise EPSPMemory.CreateFmt('PSP: unmapped read at %.8x', [Address]);
  Result := P^;
end;

function TPSPMemory.Read16(Address: Cardinal): Word;
begin
  var P := Resolve(Address, 2);
  if P = nil then
    raise EPSPMemory.CreateFmt('PSP: unmapped halfword read at %.8x', [Address]);
  {$IFDEF ENDIAN_LITTLE}
  Result := PWord(P)^;
  {$ELSE}
  Result := Word(P[0]) or (Word(P[1]) shl 8);
  {$ENDIF}
end;

function TPSPMemory.Read32(Address: Cardinal): Cardinal;
begin
  var P := Resolve(Address, 4);
  if P = nil then
    raise EPSPMemory.CreateFmt('PSP: unmapped word read at %.8x', [Address]);
  {$IFDEF ENDIAN_LITTLE}
  Result := PCardinal(P)^;
  {$ELSE}
  Result := Cardinal(P[0]) or (Cardinal(P[1]) shl 8) or
    (Cardinal(P[2]) shl 16) or (Cardinal(P[3]) shl 24);
  {$ENDIF}
end;

procedure TPSPMemory.Write8(Address: Cardinal; Value: Byte);
begin
  var P := Resolve(Address, 1);
  if P = nil then
    raise EPSPMemory.CreateFmt('PSP: unmapped write at %.8x', [Address]);
  P^ := Value;
  Inc(FWriteGeneration);
end;

procedure TPSPMemory.Write16(Address: Cardinal; Value: Word);
begin
  var P := Resolve(Address, 2);
  if P = nil then
    raise EPSPMemory.CreateFmt('PSP: unmapped halfword write at %.8x', [Address]);
  {$IFDEF ENDIAN_LITTLE}
  PWord(P)^ := Value;
  {$ELSE}
  P[0] := Byte(Value and $FF);
  P[1] := Byte(Value shr 8);
  {$ENDIF}
  Inc(FWriteGeneration);
end;

procedure TPSPMemory.Write32(Address, Value: Cardinal);
begin
  var P := Resolve(Address, 4);
  if P = nil then
    raise EPSPMemory.CreateFmt('PSP: unmapped word write at %.8x', [Address]);
  {$IFDEF ENDIAN_LITTLE}
  PCardinal(P)^ := Value;
  {$ELSE}
  for var I := 0 to 3 do
    P[I] := Byte((Value shr (I * 8)) and $FF);
  {$ENDIF}
  Inc(FWriteGeneration);
end;

function TPSPMemory.ReadBytes(Address,Count:Cardinal):TBytes;
begin
  Result:=nil;
  if Count=0 then Exit;
  var Source:=Resolve(Address,Count);
  if Source=nil then raise EPSPMemory.CreateFmt('PSP: invalid read range at %.8x (%d bytes)',[Address,Count]);
  SetLength(Result,Count);
  Move(Source^,Result[0],Count);
end;

procedure TPSPMemory.Load(Address: Cardinal; const Data: TBytes);
begin
  if Length(Data) = 0 then Exit;
  var P := Resolve(Address, Length(Data));
  if P = nil then
    raise EPSPMemory.CreateFmt('PSP: invalid load range at %.8x (%d bytes)', [Address, Length(Data)]);
  Move(Data[0], P^, Length(Data));
  Inc(FWriteGeneration);
end;

procedure TPSPMemory.Zero(Address, Count: Cardinal);
begin
  Fill(Address,Count,0);
end;

procedure TPSPMemory.Fill(Address, Count: Cardinal; Value: Byte);
begin
  if Count = 0 then Exit;
  var P := Resolve(Address, Count);
  if P = nil then
    raise EPSPMemory.CreateFmt('PSP: invalid clear range at %.8x', [Address]);
  FillChar(P^, Count, Value);
  Inc(FWriteGeneration);
end;

procedure TPSPMemory.Fill16(Address,Count:Cardinal;Value:Word);
begin
  if Count=0 then Exit;
  if Count>High(Cardinal) div 2 then raise EPSPMemory.Create('PSP: invalid halfword fill size');
  var P:=Resolve(Address,Count*2);
  if P=nil then raise EPSPMemory.CreateFmt('PSP: invalid halfword fill at %.8x',[Address]);
  {$IFDEF ENDIAN_LITTLE}
  var Destination:=PWord(P);
  for var I:Cardinal:=0 to Count-1 do Destination[I]:=Value;
  {$ELSE}
  for var I:Cardinal:=0 to Count-1 do begin P[I*2]:=Byte(Value);P[I*2+1]:=Byte(Value shr 8) end;
  {$ENDIF}
  Inc(FWriteGeneration);
end;

procedure TPSPMemory.Fill32(Address,Count,Value:Cardinal);
begin
  if Count=0 then Exit;
  if Count>High(Cardinal) div 4 then raise EPSPMemory.Create('PSP: invalid word fill size');
  var P:=Resolve(Address,Count*4);
  if P=nil then raise EPSPMemory.CreateFmt('PSP: invalid word fill at %.8x',[Address]);
  {$IFDEF ENDIAN_LITTLE}
  var Destination:=PCardinal(P);
  for var I:Cardinal:=0 to Count-1 do Destination[I]:=Value;
  {$ELSE}
  for var I:Cardinal:=0 to Count-1 do for var B:=0 to 3 do P[I*4+Cardinal(B)]:=Byte(Value shr (B*8));
  {$ENDIF}
  Inc(FWriteGeneration);
end;

procedure TPSPMemory.CopyMemory(Destination, Source, Count: Cardinal);
begin
  if Count=0 then Exit;
  var A := Resolve(Destination,Count);
  var B := Resolve(Source,Count);
  if (A=nil) or (B=nil) then raise EPSPMemory.Create('PSP: invalid guest memory copy');
  Move(B^,A^,Count);
  Inc(FWriteGeneration);
end;

function TPSPMemory.ReadString(Address, Limit: Cardinal): string;
begin
  Result := '';
  for var I := 0 to Integer(Limit) - 1 do
  begin
    var C := Read8(Address + Cardinal(I));
    if C = 0 then Exit;
    Result := Result + Char(C);
  end;
  raise EPSPMemory.Create('PSP: unterminated guest string');
end;

end.
