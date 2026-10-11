unit CHD.Common;

interface

uses
  System.SysUtils, System.Classes;

type
  TCHDError = (ceInvalidData, ceUnsupportedVersion, ceUnsupportedCodec,
    ceTruncated, ceChecksum, ceRequiresParent, ceInvalidParent, ceOutOfRange);

  ECHDError = class(Exception)
  private
    FCode: TCHDError;
  public
    constructor Create(Code: TCHDError; const Message: string);
    property Code: TCHDError read FCode;
  end;

  TCHDBits = record
  private
    FData: TBytes;
    FPosition: Int64;
    FEnd: Int64;
    FLittle: Boolean;
  public
    procedure Init(const Data: TBytes; LittleEndian: Boolean = False; Offset: Integer = 0; Count: Integer = -1);
    function Read(Count: Integer): Cardinal;
    function Read64(Count: Integer): UInt64;
    function ReadSigned(Count: Integer): Int64;
    procedure Align;
    function BytePosition: Integer;
    property Position: Int64 read FPosition;
  end;

  TCHDHuffman = record
  private
    FTable: TArray<Integer>;
    FMax: Integer;
  public
    procedure Build(const Lengths: TArray<Integer>; MaxBits: Integer; CHDOrder: Boolean);
    procedure ImportRLE(var Bits: TCHDBits; Symbols, MaxBits: Integer);
    procedure ImportHuffman(var Bits: TCHDBits);
    function Decode(var Bits: TCHDBits): Integer;
  end;

procedure CHDRequire(Condition: Boolean; const Message: string; Code: TCHDError = ceInvalidData);

procedure CHDRange(const Data: TBytes; Offset, Count: Integer);

function CHDBE(const Data: TBytes; Offset, Count: Integer): UInt64;

function CHDLE(const Data: TBytes; Offset, Count: Integer): UInt64;

procedure CHDPutBE(var Data: TBytes; Offset, Count: Integer; Value: UInt64);

function CHDCRC16(const Data: TBytes; Offset: Integer = 0; Count: Integer = -1): Word;

function CHDCRC32(const Data: TBytes): Cardinal;

function CHDAdd(A, B: UInt64): UInt64;

function CHDMul(A, B: UInt64): UInt64;

function CHDTag(const S: AnsiString): Cardinal;

implementation

var
  CRC16Table: array[0..255] of Word;
  CRC32Table: array[0..255] of Cardinal;

procedure InitCRCTables;
var
  C: Cardinal;
begin
  for var i := 0 to 255 do
  begin
    C := Cardinal(i) shl 8;
    for var J := 1 to 8 do
      if (C and $8000) <> 0 then
        C := ((C shl 1) xor $1021) and $FFFF
      else
        C := (C shl 1) and $FFFF;
    CRC16Table[i] := Word(C);
    C := i;
    for var J := 1 to 8 do
      if (C and 1) <> 0 then
        C := (C shr 1) xor $EDB88320
      else
        C := C shr 1;
    CRC32Table[i] := C;
  end;
end;

constructor ECHDError.Create(Code: TCHDError; const Message: string);
begin
  inherited Create(Message);
  FCode := Code;
end;

procedure CHDRequire(Condition: Boolean; const Message: string; Code: TCHDError);
begin
  if not Condition then
    raise ECHDError.Create(Code, Message);
end;

procedure CHDRange(const Data: TBytes; Offset, Count: Integer);
begin
  CHDRequire((Offset >= 0) and (Count >= 0) and (Offset <= Length(Data)), 'Invalid byte range', ceTruncated);
  CHDRequire(Count <= Length(Data) - Offset, 'Truncated byte range', ceTruncated);
end;

function CHDBE(const Data: TBytes; Offset, Count: Integer): UInt64;
begin
  CHDRange(Data, Offset, Count);
  CHDRequire(Count <= 8, 'Integer width');
  Result := 0;
  for var i := 0 to Count - 1 do
    Result := (Result shl 8) or Data[Offset + i];
end;

function CHDLE(const Data: TBytes; Offset, Count: Integer): UInt64;
begin
  CHDRange(Data, Offset, Count);
  CHDRequire(Count <= 8, 'Integer width');
  Result := 0;
  for var i := Count - 1 downto 0 do
    Result := (Result shl 8) or Data[Offset + i];
end;

procedure CHDPutBE(var Data: TBytes; Offset, Count: Integer; Value: UInt64);
begin
  CHDRange(Data, Offset, Count);
  for var i := Count - 1 downto 0 do
  begin
    Data[Offset + i] := Byte(Value and 255);
    Value := Value shr 8;
  end;
  CHDRequire(Value = 0, 'Integer does not fit field');
end;

function CHDAdd(A, B: UInt64): UInt64;
begin
  CHDRequire(B <= High(UInt64) - A, 'Offset overflow');
  Result := A + B;
end;

function CHDMul(A, B: UInt64): UInt64;
begin
  if A <> 0 then
    CHDRequire(B <= High(UInt64) div A, 'Size overflow');
  Result := A * B;
end;

function CHDTag(const S: AnsiString): Cardinal;
begin
  CHDRequire(Length(S) = 4, 'Tags contain four bytes');
  Result := 0;
  for var C in S do
    Result := (Result shl 8) or Ord(C);
end;

function CHDCRC16(const Data: TBytes; Offset, Count: Integer): Word;
begin
  CHDRequire((Offset >= 0) and (Offset <= Length(Data)), 'CRC byte offset');
  if Count < 0 then
    Count := Length(Data) - Offset;
  CHDRange(Data, Offset, Count);
  var C: Cardinal := $FFFF;
  for var i := Offset to Offset + Count - 1 do
    C := ((C shl 8) and $FFFF) xor CRC16Table[(C shr 8) xor Data[i]];
  Result := Word(C);
end;

function CHDCRC32(const Data: TBytes): Cardinal;
begin
  Result := $FFFFFFFF;
  for var B in Data do
    Result := (Result shr 8) xor CRC32Table[(Result xor B) and 255];
  Result := Result xor $FFFFFFFF;
end;

procedure TCHDBits.Init(const Data: TBytes; LittleEndian: Boolean; Offset, Count: Integer);
begin
  CHDRequire((Offset >= 0) and (Offset <= Length(Data)), 'Bitstream byte offset');
  if Count < 0 then
    Count := Length(Data) - Offset;
  CHDRange(Data, Offset, Count);
  FData := Data;
  FPosition := Int64(Offset) * 8;
  FEnd := Int64(Offset + Count) * 8;
  FLittle := LittleEndian;
end;

function TCHDBits.Read64(Count: Integer): UInt64;
var
  V, Available, Take, Shift: Integer;
begin
  CHDRequire((Count >= 0) and (Count <= 64), 'Bit width');
  CHDRequire(Count <= FEnd - FPosition, 'Truncated bitstream', ceTruncated);
  Result := 0;
  Shift := 0;
  while Count > 0 do
  begin
    Available := 8 - Integer(FPosition mod 8);
    Take := Count;
    if Take > Available then
      Take := Available;
    if FLittle then
    begin
      V := (FData[Integer(FPosition div 8)] shr (8 - Available)) and ((1 shl Take) - 1);
      Result := Result or (UInt64(V) shl Shift);
      Inc(Shift, Take);
    end
    else
    begin
      V := (FData[Integer(FPosition div 8)] shr (Available - Take)) and ((1 shl Take) - 1);
      Result := (Result shl Take) or UInt64(V);
    end;
    Inc(FPosition, Take);
    Dec(Count, Take);
  end;
end;

function TCHDBits.Read(Count: Integer): Cardinal;
begin
  CHDRequire(Count <= 32, 'Bit width exceeds 32');
  Result := Cardinal(Read64(Count));
end;

function TCHDBits.ReadSigned(Count: Integer): Int64;
begin
  CHDRequire((Count > 0) and (Count < 64), 'Signed bit width');
  var V := Read64(Count);
  if (V and (UInt64(1) shl (Count - 1))) <> 0 then
    Result := -Int64((UInt64(1) shl Count) - V)
  else
    Result := Int64(V);
end;

procedure TCHDBits.Align;
begin
  if FPosition mod 8 <> 0 then
    Read(8 - FPosition mod 8);
end;

function TCHDBits.BytePosition: Integer;
begin
  Result := Integer((FPosition + 7) div 8);
end;

procedure TCHDHuffman.Build(const Lengths: TArray<Integer>; MaxBits: Integer; CHDOrder: Boolean);
var
  Counts, Starts: array[0..24] of Integer;
  C, N, P, L: Integer;
begin
  CHDRequire((MaxBits > 0) and (MaxBits <= 24), 'Huffman width');
  FMax := MaxBits;
  FillChar(Counts, SizeOf(Counts), 0);
  FillChar(Starts, SizeOf(Starts), 0);
  for L in Lengths do
  begin
    CHDRequire((L >= 0) and (L <= MaxBits), 'Huffman code length');
    Inc(Counts[L]);
  end;
  C := 0;
  if CHDOrder then
    for L := MaxBits downto 1 do
    begin
      Starts[L] := C;
      N := C + Counts[L];
      CHDRequire((L = 1) or not Odd(N), 'Invalid CHD Huffman tree');
      C := N div 2;
    end
  else
    for L := 1 to MaxBits do
    begin
      if L > 1 then
        C := (C + Counts[L - 1]) * 2;
      Starts[L] := C;
      CHDRequire(C + Counts[L] <= (1 shl L), 'Oversubscribed Huffman tree');
    end;

  // Binary trie; -1 is missing, negative values below -1 encode leaves.
  SetLength(FTable, 2);
  FTable[0] := -1;
  FTable[1] := -1;
  for var S := 0 to High(Lengths) do
  begin
    L := Lengths[S];
    if L = 0 then
      Continue;

    C := Starts[L];
    Inc(Starts[L]);
    P := 0;
    CHDRequire(C < (1 shl L), 'Invalid Huffman code');
    for var B := L - 1 downto 0 do
    begin
      N := P + ((C shr B) and 1);
      if B = 0 then
      begin
        CHDRequire(FTable[N] = -1, 'Huffman collision');
        FTable[N] := -S - 2;
      end
      else
      begin
        if FTable[N] = -1 then
        begin
          P := Length(FTable);
          FTable[N] := P;
          SetLength(FTable, P + 2);
          FTable[P] := -1;
          FTable[P + 1] := -1;
        end
        else
        begin
          CHDRequire(FTable[N] >= 0, 'Huffman prefix collision');
          P := FTable[N];
        end;
      end;
    end;
  end;
end;

function TCHDHuffman.Decode(var Bits: TCHDBits): Integer;
var
  P: Integer;
begin
  P := 0;
  for var i := 1 to FMax do
  begin
    CHDRequire(Length(FTable) > 0, 'Missing Huffman tree');
    P := FTable[P + Integer(Bits.Read(1))];
    CHDRequire(P <> -1, 'Invalid Huffman symbol');
    if P < -1 then
      Exit(-P - 2);
  end;

  raise ECHDError.Create(ceInvalidData, 'Huffman code too long');
end;

procedure TCHDHuffman.ImportRLE(var Bits: TCHDBits; Symbols, MaxBits: Integer);
var
  L: TArray<Integer>;
  N, V, R, B: Integer;
begin
  SetLength(L, Symbols);
  N := 0;
  if MaxBits >= 16 then
    B := 5
  else if MaxBits >= 8 then
    B := 4
  else
    B := 3;
  while N < Symbols do
  begin
    V := Bits.Read(B);
    R := 1;
    if V = 1 then
    begin
      V := Bits.Read(B);
      if V <> 1 then
        R := Bits.Read(B) + 3;
    end;
    CHDRequire(R <= Symbols - N, 'Huffman run exceeds tree');
    for var i := 1 to R do
    begin
      L[N] := V;
      Inc(N);
    end;
  end;
  Build(L, MaxBits, True);
end;

procedure TCHDHuffman.ImportHuffman(var Bits: TCHDBits);
var
  Small: TCHDHuffman;
  L, Full: TArray<Integer>;
  Start, N, V, Last, R: Integer;
begin
  SetLength(L, 24);
  L[0] := Bits.Read(3);
  Start := Bits.Read(3) + 1;
  V := 0;
  for var i := 1 to 23 do
    if (i >= Start) and (V <> 7) then
    begin
      V := Bits.Read(3);
      if V <> 7 then
        L[i] := V;
    end;

  Small.Build(L, 6, True);
  SetLength(Full, 256);
  N := 0;
  Last := 0;
  while N < 256 do
  begin
    V := Small.Decode(Bits);
    R := 1;
    if V <> 0 then
      Last := V - 1
    else
    begin
      R := Bits.Read(3) + 2;
      if R = 9 then
        Inc(R, Bits.Read(8));
    end;
    CHDRequire(R <= 256 - N, 'Huffman run exceeds tree');
    for var i := 1 to R do
    begin
      Full[N] := Last;
      Inc(N);
    end;
  end;
  Build(Full, 16, True);
end;

initialization
  InitCRCTables;

end.

