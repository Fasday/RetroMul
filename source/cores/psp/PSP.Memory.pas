unit PSP.Memory;

// Guest address space. Every segment (KUSEG, the uncached 0x40000000 mirror,
// KSEG0, KSEG1) folds to one physical map through `and $1FFFFFFF`; the map is a
// table of 4 KB pages pointing into host buffers. Stores into pages that hold
// decoded code notify the CPU.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, PSP.Types;

const
  PSPPageShift = 12;
  PSPPageSize = 1 shl PSPPageShift;
  PSPPageMask = PSPPageSize - 1;
  PSPPageCount = $20000000 shr PSPPageShift;

type
  TPSPCodeWrite = procedure(Address, Size: Cardinal) of object;
  TPSPVRAMFault = procedure of object;

  TPSPMemory = class
  private
    FRAM: TBytes;
    FVRAM: TBytes;
    FScratch: TBytes;
    FPages: array[0..PSPPageCount - 1] of PByte;
    FCodePages: array[0..PSPPageCount - 1] of Byte;
    FOnCodeWrite: TPSPCodeWrite;
    FFaultAddress: Cardinal;
    FFaults: Integer;
    FHeld: array[0..PSPVRAMSize div PSPPageSize - 1] of Boolean;
    FHeldCount: Integer;
    FOnVRAMFault: TPSPVRAMFault;
    procedure MapRange(Physical, Size: Cardinal; Base: PByte);
    function Unmapped(Address: Cardinal; Write: Boolean): Cardinal;
    procedure CodeWrite(Address, Size: Cardinal);
    function Fault(Address: Cardinal): PByte;
    procedure FaultRange(Address, Size: Cardinal);
  public
    constructor Create;
    procedure Reset;
    function Read8(Address: Cardinal): Cardinal; inline;
    function Read16(Address: Cardinal): Cardinal; inline;
    function Read32(Address: Cardinal): Cardinal; inline;
    procedure Write8(Address, Value: Cardinal); inline;
    procedure Write16(Address, Value: Cardinal); inline;
    procedure Write32(Address, Value: Cardinal); inline;
    function ReadFloat(Address: Cardinal): Single; inline;
    procedure WriteFloat(Address: Cardinal; Value: Single); inline;
    // Host pointer for Size bytes starting at Address, or nil when the range
    // leaves its region.
    function Ptr(Address: Cardinal; Size: Cardinal = 1): PByte;
    function Valid(Address: Cardinal; Size: Cardinal = 1): Boolean;
    function PageBase(Address: Cardinal): PByte; inline;
    procedure ReadBytes(Address: Cardinal; var Buffer; Size: Cardinal);
    procedure WriteBytes(Address: Cardinal; const Buffer; Size: Cardinal);
    procedure Fill(Address: Cardinal; Value: Byte; Size: Cardinal);
    // Tells the CPU that a range was written behind its back (DMA, disc reads).
    procedure Touched(Address, Size: Cardinal);
    procedure Copy(Dest, Source, Size: Cardinal);
    function ReadString(Address: Cardinal; MaxLength: Integer = 1024): string;
    function ReadAnsi(Address: Cardinal; MaxLength: Integer = 1024): RawByteString;
    procedure WriteString(Address: Cardinal; const Value: RawByteString; Capacity: Integer);
    // Pages holding decoded code: stores into them call OnCodeWrite.
    procedure MarkCode(Address: Cardinal); inline;
    procedure ClearCodeMarks;
    function IsCode(Address: Cardinal): Boolean; inline;
    // VRAM pages a device (the GE's GPU renderer) has newer data for: any
    // access to a held page, in any mirror, first calls OnVRAMFault, which
    // must bring the data back and release every page.
    procedure HoldVRAM(Page: Integer);
    procedure ReleaseVRAM;
    function VRAMHeld(Page: Integer): Boolean; inline;
    property HeldVRAMPages: Integer read FHeldCount;
    property OnCodeWrite: TPSPCodeWrite read FOnCodeWrite write FOnCodeWrite;
    property OnVRAMFault: TPSPVRAMFault read FOnVRAMFault write FOnVRAMFault;
    property RAM: TBytes read FRAM;
    property VRAM: TBytes read FVRAM;
    property Scratch: TBytes read FScratch;
    property FaultAddress: Cardinal read FFaultAddress;
    property Faults: Integer read FFaults;
  end;

implementation

constructor TPSPMemory.Create;
begin
  inherited Create;
  SetLength(FRAM, PSPRAMSize);
  SetLength(FVRAM, PSPVRAMSize);
  SetLength(FScratch, PSPScratchSize);
  MapRange(PSPRAMBase, PSPRAMSize, @FRAM[0]);
  // VRAM 0x04000000 and its three mirrors up to 0x04800000.
  for var M := 0 to 3 do
    MapRange(PSPVRAMBase + Cardinal(M) * PSPVRAMSize, PSPVRAMSize, @FVRAM[0]);
  MapRange(PSPScratchBase, PSPScratchSize, @FScratch[0]);
end;

procedure TPSPMemory.MapRange(Physical, Size: Cardinal; Base: PByte);
begin
  var Page := Physical shr PSPPageShift;
  for var I := 0 to Integer(Size shr PSPPageShift) - 1 do
    FPages[Page + Cardinal(I)] := Base + NativeUInt(I) * PSPPageSize;
end;

procedure TPSPMemory.Reset;
begin
  if FHeldCount > 0 then
    FOnVRAMFault();
  FillChar(FRAM[0], Length(FRAM), 0);
  FillChar(FVRAM[0], Length(FVRAM), 0);
  FillChar(FScratch[0], Length(FScratch), 0);
  ClearCodeMarks;
  FFaults := 0;
  FFaultAddress := 0;
end;

function TPSPMemory.Unmapped(Address: Cardinal; Write: Boolean): Cardinal;
begin
  Inc(FFaults);
  FFaultAddress := Address;
  Result := 0;
end;

procedure TPSPMemory.CodeWrite(Address, Size: Cardinal);
begin
  if Assigned(FOnCodeWrite) then
    FOnCodeWrite(Address and $1FFFFFFF, Size);
end;

function TPSPMemory.PageBase(Address: Cardinal): PByte;
begin
  Result := FPages[(Address and $1FFFFFFF) shr PSPPageShift];
  if Result = nil then
    Result := Fault(Address);
end;

// The page of a held VRAM address once the device has given it back; nil for
// an unmapped address.
function TPSPMemory.Fault(Address: Cardinal): PByte;
begin
  var Physical := Address and $1FFFFFFF;
  if (FHeldCount = 0) or (Physical < PSPVRAMBase) or (Physical >= PSPVRAMBase + 4 * PSPVRAMSize) or
    not FHeld[(Physical and (PSPVRAMSize - 1)) shr PSPPageShift] then
    Exit(nil);
  FOnVRAMFault();
  Result := FPages[Physical shr PSPPageShift];
end;

procedure TPSPMemory.FaultRange(Address, Size: Cardinal);
begin
  var Lo := Int64(Address and $1FFFFFFF);
  var Hi := Lo + Size;
  if Size = 0 then
    Hi := Lo + 1;
  if Lo < PSPVRAMBase then
    Lo := PSPVRAMBase;
  if Hi > PSPVRAMBase + 4 * PSPVRAMSize then
    Hi := PSPVRAMBase + 4 * PSPVRAMSize;
  if Hi - Lo > PSPVRAMSize then
    Hi := Lo + PSPVRAMSize;
  var Page := Lo shr PSPPageShift;
  while Page < (Hi + PSPPageMask) shr PSPPageShift do
  begin
    if FHeld[Page and (PSPVRAMSize div PSPPageSize - 1)] then
    begin
      FOnVRAMFault();
      Exit;
    end;
    Inc(Page);
  end;
end;

procedure TPSPMemory.HoldVRAM(Page: Integer);
begin
  if FHeld[Page] then
    Exit;
  FHeld[Page] := True;
  Inc(FHeldCount);
  for var M := 0 to 3 do
    FPages[(PSPVRAMBase + Cardinal(M) * PSPVRAMSize) shr PSPPageShift + Cardinal(Page)] := nil;
end;

procedure TPSPMemory.ReleaseVRAM;
begin
  if FHeldCount = 0 then
    Exit;
  for var Page := 0 to High(FHeld) do
    if FHeld[Page] then
    begin
      FHeld[Page] := False;
      for var M := 0 to 3 do
        FPages[(PSPVRAMBase + Cardinal(M) * PSPVRAMSize) shr PSPPageShift + Cardinal(Page)] :=
          @FVRAM[Page * PSPPageSize];
    end;
  FHeldCount := 0;
end;

function TPSPMemory.VRAMHeld(Page: Integer): Boolean;
begin
  Result := FHeld[Page];
end;

function TPSPMemory.Read8(Address: Cardinal): Cardinal;
begin
  var P := FPages[(Address and $1FFFFFFF) shr PSPPageShift];
  if P = nil then
    P := Fault(Address);
  if P <> nil then
    Result := P[Address and PSPPageMask]
  else
    Result := Unmapped(Address, False);
end;

function TPSPMemory.Read16(Address: Cardinal): Cardinal;
begin
  var P := FPages[(Address and $1FFFFFFF) shr PSPPageShift];
  if P = nil then
    P := Fault(Address);
  if P <> nil then
    Result := PWord(P + (Address and PSPPageMask))^
  else
    Result := Unmapped(Address, False);
end;

function TPSPMemory.Read32(Address: Cardinal): Cardinal;
begin
  var P := FPages[(Address and $1FFFFFFF) shr PSPPageShift];
  if P = nil then
    P := Fault(Address);
  if P <> nil then
    Result := PCardinal(P + (Address and PSPPageMask))^
  else
    Result := Unmapped(Address, False);
end;

procedure TPSPMemory.Write8(Address, Value: Cardinal);
begin
  var Page := (Address and $1FFFFFFF) shr PSPPageShift;
  var P := FPages[Page];
  if P = nil then
    P := Fault(Address);
  if P <> nil then
  begin
    P[Address and PSPPageMask] := Byte(Value);
    if FCodePages[Page] <> 0 then
      CodeWrite(Address, 1);
  end
  else
    Unmapped(Address, True);
end;

procedure TPSPMemory.Write16(Address, Value: Cardinal);
begin
  var Page := (Address and $1FFFFFFF) shr PSPPageShift;
  var P := FPages[Page];
  if P = nil then
    P := Fault(Address);
  if P <> nil then
  begin
    PWord(P + (Address and PSPPageMask))^ := Word(Value);
    if FCodePages[Page] <> 0 then
      CodeWrite(Address, 2);
  end
  else
    Unmapped(Address, True);
end;

procedure TPSPMemory.Write32(Address, Value: Cardinal);
begin
  var Page := (Address and $1FFFFFFF) shr PSPPageShift;
  var P := FPages[Page];
  if P = nil then
    P := Fault(Address);
  if P <> nil then
  begin
    PCardinal(P + (Address and PSPPageMask))^ := Value;
    if FCodePages[Page] <> 0 then
      CodeWrite(Address, 4);
  end
  else
    Unmapped(Address, True);
end;

function TPSPMemory.ReadFloat(Address: Cardinal): Single;
begin
  var V := Read32(Address);
  Result := PSingle(@V)^;
end;

procedure TPSPMemory.WriteFloat(Address: Cardinal; Value: Single);
begin
  Write32(Address, PCardinal(@Value)^);
end;

function TPSPMemory.Ptr(Address: Cardinal; Size: Cardinal): PByte;
begin
  if FHeldCount > 0 then
    FaultRange(Address, Size);
  var Physical := Address and $1FFFFFFF;
  if Size = 0 then
    Size := 1;
  var Last := Physical + Size - 1;
  if (Last < Physical) or (Last > $1FFFFFFF) then
    Exit(nil);
  var P := FPages[Physical shr PSPPageShift];
  if P = nil then
    Exit(nil);
  // Regions are contiguous in host memory; verify the last page belongs to the
  // same buffer at the expected distance.
  var Q := FPages[Last shr PSPPageShift];
  if (Q = nil) or (NativeUInt(Q) - NativeUInt(P) <> NativeUInt((Last shr PSPPageShift) - (Physical shr PSPPageShift)) * PSPPageSize) then
    Exit(nil);
  Result := P + (Physical and PSPPageMask);
end;

function TPSPMemory.Valid(Address, Size: Cardinal): Boolean;
begin
  Result := Ptr(Address, Size) <> nil;
end;

procedure TPSPMemory.ReadBytes(Address: Cardinal; var Buffer; Size: Cardinal);
begin
  if Size = 0 then
    Exit;
  var P := Ptr(Address, Size);
  if P <> nil then
    Move(P^, Buffer, Size)
  else
    for var I := 0 to Size - 1 do
      PByte(@Buffer)[I] := Read8(Address + I);
end;

procedure TPSPMemory.WriteBytes(Address: Cardinal; const Buffer; Size: Cardinal);
begin
  if Size = 0 then
    Exit;
  var P := Ptr(Address, Size);
  if P <> nil then
  begin
    Move(Buffer, P^, Size);
    var First := (Address and $1FFFFFFF) shr PSPPageShift;
    var Last := ((Address and $1FFFFFFF) + Size - 1) shr PSPPageShift;
    for var Page := First to Last do
      if FCodePages[Page] <> 0 then
      begin
        CodeWrite(Address, Size);
        Break;
      end;
  end
  else
    for var I := 0 to Size - 1 do
      Write8(Address + I, PByte(@Buffer)[I]);
end;

procedure TPSPMemory.Fill(Address: Cardinal; Value: Byte; Size: Cardinal);
begin
  if Size = 0 then
    Exit;
  var P := Ptr(Address, Size);
  if P <> nil then
  begin
    FillChar(P^, Size, Value);
    var First := (Address and $1FFFFFFF) shr PSPPageShift;
    var Last := ((Address and $1FFFFFFF) + Size - 1) shr PSPPageShift;
    for var Page := First to Last do
      if FCodePages[Page] <> 0 then
      begin
        CodeWrite(Address, Size);
        Break;
      end;
  end
  else
    for var I := 0 to Size - 1 do
      Write8(Address + I, Value);
end;

procedure TPSPMemory.Touched(Address, Size: Cardinal);
begin
  if Size = 0 then
    Exit;
  var First := (Address and $1FFFFFFF) shr PSPPageShift;
  var Last := ((Address and $1FFFFFFF) + Size - 1) shr PSPPageShift;
  if Last >= PSPPageCount then
    Last := PSPPageCount - 1;
  for var Page := First to Last do
    if FCodePages[Page] <> 0 then
    begin
      CodeWrite(Address, Size);
      Break;
    end;
end;

procedure TPSPMemory.Copy(Dest, Source, Size: Cardinal);
begin
  if Size = 0 then
    Exit;
  var S := Ptr(Source, Size);
  var D := Ptr(Dest, Size);
  if (S <> nil) and (D <> nil) then
  begin
    Move(S^, D^, Size);
    var First := (Dest and $1FFFFFFF) shr PSPPageShift;
    var Last := ((Dest and $1FFFFFFF) + Size - 1) shr PSPPageShift;
    for var Page := First to Last do
      if FCodePages[Page] <> 0 then
      begin
        CodeWrite(Dest, Size);
        Break;
      end;
  end
  else
    for var I := 0 to Size - 1 do
      Write8(Dest + I, Read8(Source + I));
end;

function TPSPMemory.ReadAnsi(Address: Cardinal; MaxLength: Integer): RawByteString;
begin
  Result := '';
  if Address = 0 then
    Exit;
  var N := 0;
  while (N < MaxLength) and (Read8(Address + Cardinal(N)) <> 0) do
    Inc(N);
  SetLength(Result, N);
  if N > 0 then
    ReadBytes(Address, Result[1], N);
end;

function TPSPMemory.ReadString(Address: Cardinal; MaxLength: Integer): string;
begin
  Result := string(ReadAnsi(Address, MaxLength));
end;

procedure TPSPMemory.WriteString(Address: Cardinal; const Value: RawByteString; Capacity: Integer);
begin
  if (Address = 0) or (Capacity <= 0) then
    Exit;
  var N := Length(Value);
  if N > Capacity - 1 then
    N := Capacity - 1;
  if N > 0 then
    WriteBytes(Address, Value[1], N);
  Write8(Address + Cardinal(N), 0);
end;

procedure TPSPMemory.MarkCode(Address: Cardinal);
begin
  FCodePages[(Address and $1FFFFFFF) shr PSPPageShift] := 1;
end;

procedure TPSPMemory.ClearCodeMarks;
begin
  FillChar(FCodePages, SizeOf(FCodePages), 0);
end;

function TPSPMemory.IsCode(Address: Cardinal): Boolean;
begin
  Result := FCodePages[(Address and $1FFFFFFF) shr PSPPageShift] <> 0;
end;

end.
