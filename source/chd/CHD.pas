unit CHD;

interface

uses
  System.SysUtils, System.Classes, CHD.Common;

type
  TCHDHeader = record
    Version, HeaderBytes, Flags: Cardinal;
    Codecs: array[0..3] of Cardinal;
    HunkBytes, HunkCount, UnitBytes: Cardinal;
    LogicalBytes, UnitCount, MapOffset, MetadataOffset: UInt64;
    MD5, ParentMD5: array[0..15] of Byte;
    SHA1, RawSHA1, ParentSHA1: array[0..19] of Byte;
    Cylinders, Heads, Sectors: Cardinal;
  end;

  TCHDMetadata = record
    Tag: Cardinal;
    Flags: Byte;
    Data: TBytes;
    function AsString: string;
  end;

  TCHDHunkInfo = record
    Codec: Cardinal;
    Offset: UInt64;
    StoredBytes: Cardinal;
    IsSelfReference, IsParentReference, IsMini, IsZero: Boolean;
  end;

  TCHDFile = class
  private
    type
      TMapEntry = record
        Offset: UInt64;
        Size, CRC: Cardinal;
        Kind: Byte; // 0..3 codec, 4 raw, 5 self, 6 parent units, 7 mini, 8 zero, 9 parent bytes
        CRCBits: Byte;
      end;
  private
    FStream: TStream;
    FOwnsStream: Boolean;
    FFileSize: UInt64;
    FParent: TCHDFile;
    FHeader: TCHDHeader;
    FMap: TArray<TMapEntry>;
    FMetadata: TArray<TCHDMetadata>;
    FCache: TBytes;
    FCachedHunk: Int64;
    function ReadPhysical(Offset: UInt64; Count: Integer): TBytes;
    procedure ParseHeader;
    procedure ParseMetadata;
    procedure ParseMap;
    procedure CheckParent;
    function DecodeHunk(Index: Cardinal): TBytes;
    function ReadInternal(Offset: UInt64; var Buffer: TBytes; BufferOffset, Count: Integer; Padded: Boolean): Integer;
    function GetMetadata: TArray<TCHDMetadata>;
  public
    // Parent is borrowed and must outlive this object. An owned stream is also
    // freed if construction raises. Input streams must support Size and Seek.
    constructor Create(Stream: TStream; OwnsStream: Boolean = False; Parent: TCHDFile = nil); overload;
    constructor Create(const FileName: string; Parent: TCHDFile = nil); overload;
    destructor Destroy; override;
    class function ReadHeader(Stream: TStream): TCHDHeader; static;
    function ReadHunk(Index: Cardinal): TBytes;
    function ReadAt(Offset: UInt64; var Buffer: TBytes; BufferOffset, Count: Integer): Integer;
    function FindMetadata(Tag, Index: Cardinal; out Value: TCHDMetadata): Boolean;
    function HunkInfo(Index: Cardinal): TCHDHunkInfo;
    procedure Precache;
    procedure ExtractTo(Destination: TStream);
    property Header: TCHDHeader read FHeader;
    property Metadata: TArray<TCHDMetadata> read GetMetadata;
    property SourceStream: TStream read FStream;
    property Parent: TCHDFile read FParent;
  end;

  TCHDStream = class(TStream)
  private
    FCHD: TCHDFile;
    FOwnsCHD: Boolean;
    FPosition: Int64;
  protected
    function GetSize: Int64; override;
  public
    constructor Create(CHDFile: TCHDFile; OwnsCHD: Boolean = False);
    destructor Destroy; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

implementation

uses
  System.Math, System.Generics.Collections, CHD.Codecs;

function HasBytes(const Value: array of Byte): Boolean;
begin
  for var B in Value do
    if B <> 0 then
      Exit(True);

  Result := False;
end;

function EqualBytes(const A, B: array of Byte): Boolean;
begin
  if Length(A) <> Length(B) then
    Exit(False);

  for var i := 0 to High(A) do
    if A[i] <> B[i] then
      Exit(False);

  Result := True;
end;

function TCHDMetadata.AsString: string;
var
  N: Integer;
begin
  N := Length(Data);
  while (N > 0) and (Data[N - 1] = 0) do
    Dec(N);
  Result := TEncoding.UTF8.GetString(Data, 0, N);
end;

constructor TCHDFile.Create(Stream: TStream; OwnsStream: Boolean; Parent: TCHDFile);
begin
  inherited Create;
  FStream := Stream;
  FOwnsStream := OwnsStream;
  FParent := Parent;
  FCachedHunk := -1;
  CHDRequire(Stream <> nil, 'A CHD source stream is required');
  CHDRequire(Stream.Size >= 16, 'Truncated CHD header', ceTruncated);
  FFileSize := Stream.Size;
  ParseHeader;
  ParseMetadata;
  CheckParent;
  ParseMap;
end;

constructor TCHDFile.Create(const FileName: string; Parent: TCHDFile);
begin
  Create(TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite), True, Parent);
end;

destructor TCHDFile.Destroy;
begin
  if FOwnsStream then
    FStream.Free;
  inherited;
end;

function TCHDFile.ReadPhysical(Offset: UInt64; Count: Integer): TBytes;
begin
  CHDRequire((Count >= 0) and (Offset <= FFileSize), 'CHD file range', ceTruncated);
  CHDRequire(UInt64(Count) <= FFileSize - Offset, 'CHD data extends beyond file', ceTruncated);
  FStream.Position := Int64(Offset);
  SetLength(Result, Count);
  if Count > 0 then
    FStream.ReadBuffer(Result, Count);
end;

procedure TCHDFile.ParseHeader;
const
  Sizes: array[1..5] of Integer = (76, 80, 120, 108, 124);
var
  B: TBytes;
  N, SectorSize: UInt64;
begin
  B := ReadPhysical(0, 16);
  CHDRequire(TEncoding.ASCII.GetString(B, 0, 8) = 'MComprHD', 'CHD signature');
  FHeader.HeaderBytes := CHDBE(B, 8, 4);
  FHeader.Version := CHDBE(B, 12, 4);
  CHDRequire((FHeader.Version >= 1) and (FHeader.Version <= 5), 'Unsupported CHD version', ceUnsupportedVersion);
  CHDRequire(FHeader.HeaderBytes = Cardinal(Sizes[FHeader.Version]), 'CHD header size');
  B := ReadPhysical(0, FHeader.HeaderBytes);

  if FHeader.Version < 5 then
  begin
    FHeader.Flags := CHDBE(B, 16, 4);
    FHeader.Codecs[0] := CHDBE(B, 20, 4);
    CHDRequire((FHeader.Flags and $FFFFFFFC) = 0, 'CHD header flags');
    CHDRequire(FHeader.Codecs[0] <= 3, 'Unsupported legacy CHD codec', ceUnsupportedCodec);
    if FHeader.Codecs[0] = 3 then
      FHeader.Codecs[0] := CHD_CODEC_AVHU
    else if FHeader.Codecs[0] <> 0 then
      FHeader.Codecs[0] := CHD_CODEC_ZLIB;
    FHeader.MapOffset := FHeader.HeaderBytes;
  end;

  case FHeader.Version of
    1, 2:
      begin
        FHeader.HunkCount := CHDBE(B, 28, 4);
        FHeader.Cylinders := CHDBE(B, 32, 4);
        FHeader.Heads := CHDBE(B, 36, 4);
        FHeader.Sectors := CHDBE(B, 40, 4);
        Move(B[44], FHeader.MD5, 16);
        Move(B[60], FHeader.ParentMD5, 16);
        if FHeader.Version = 1 then
          SectorSize := 512
        else
          SectorSize := CHDBE(B, 76, 4);
        N := CHDMul(CHDBE(B, 24, 4), SectorSize);
        CHDRequire((N > 0) and (N < 16 * 1024 * 1024), 'CHD legacy hunk size');
        FHeader.HunkBytes := N;
        FHeader.UnitBytes := SectorSize;
        FHeader.LogicalBytes := CHDMul(CHDMul(CHDMul(FHeader.Cylinders, FHeader.Heads), FHeader.Sectors), SectorSize);
      end;
    3, 4:
      begin
        FHeader.HunkCount := CHDBE(B, 24, 4);
        FHeader.LogicalBytes := CHDBE(B, 28, 8);
        FHeader.MetadataOffset := CHDBE(B, 36, 8);
        if FHeader.Version = 3 then
        begin
          Move(B[44], FHeader.MD5, 16);
          Move(B[60], FHeader.ParentMD5, 16);
          FHeader.HunkBytes := CHDBE(B, 76, 4);
          Move(B[80], FHeader.SHA1, 20);
          Move(B[100], FHeader.ParentSHA1, 20);
        end
        else
        begin
          FHeader.HunkBytes := CHDBE(B, 44, 4);
          Move(B[48], FHeader.SHA1, 20);
          Move(B[68], FHeader.ParentSHA1, 20);
          Move(B[88], FHeader.RawSHA1, 20);
        end;
        FHeader.UnitBytes := FHeader.HunkBytes;
      end;
    5:
      begin
        for var i := 0 to 3 do
        begin
          FHeader.Codecs[i] := CHDBE(B, 16 + i * 4, 4);
          CHDRequire(CHDCodecSupported(FHeader.Codecs[i]), Format('Unsupported CHD codec %.8x', [FHeader.Codecs[i]]), ceUnsupportedCodec);
        end;
        FHeader.LogicalBytes := CHDBE(B, 32, 8);
        FHeader.MapOffset := CHDBE(B, 40, 8);
        FHeader.MetadataOffset := CHDBE(B, 48, 8);
        FHeader.HunkBytes := CHDBE(B, 56, 4);
        FHeader.UnitBytes := CHDBE(B, 60, 4);
        Move(B[64], FHeader.RawSHA1, 20);
        Move(B[84], FHeader.SHA1, 20);
        Move(B[104], FHeader.ParentSHA1, 20);
        CHDRequire(FHeader.HunkBytes > 0, 'Zero CHD hunk size');
        N := FHeader.LogicalBytes div FHeader.HunkBytes;
        if FHeader.LogicalBytes mod FHeader.HunkBytes <> 0 then
          Inc(N);
        CHDRequire(N <= High(Cardinal), 'CHD hunk count exceeds format');
        FHeader.HunkCount := N;
      end;
  end;

  CHDRequire((FHeader.LogicalBytes > 0) and (FHeader.LogicalBytes <= UInt64(High(Int64))), 'CHD logical size');
  CHDRequire((FHeader.HunkBytes > 0) and (FHeader.HunkBytes < 128 * 1024 * 1024), 'CHD hunk size');
  if FHeader.Version < 5 then
    CHDRequire(FHeader.HunkBytes < 16 * 1024 * 1024, 'Legacy CHD hunk size');
  CHDRequire((FHeader.HunkCount > 0) and (UInt64(FHeader.HunkCount) <= UInt64(High(Integer)) div SizeOf(TMapEntry)), 'CHD map allocation size');
  CHDRequire(UInt64(FHeader.HunkCount) <= CHDMul(FFileSize, 8), 'CHD map larger than possible file');
  CHDRequire(FHeader.LogicalBytes <= CHDMul(FHeader.HunkCount, FHeader.HunkBytes), 'CHD logical data exceeds map');
  CHDRequire(FHeader.UnitBytes > 0, 'Zero CHD unit size');
  FHeader.UnitCount := FHeader.LogicalBytes div FHeader.UnitBytes;
  if FHeader.LogicalBytes mod FHeader.UnitBytes <> 0 then
    Inc(FHeader.UnitCount);
end;

procedure TCHDFile.ParseMetadata;
var
  Seen: TDictionary<UInt64, Byte>;
  Items: TList<TCHDMetadata>;
  Offset: UInt64;
  B: TBytes;
  Item: TCHDMetadata;
  SectorSize: Integer;
begin
  Seen := TDictionary<UInt64, Byte>.Create;
  Items := TList<TCHDMetadata>.Create;
  try
    Offset := FHeader.MetadataOffset;
    while Offset <> 0 do
    begin
      CHDRequire(not Seen.ContainsKey(Offset), 'Cyclic CHD metadata');
      Seen.Add(Offset, 0);
      B := ReadPhysical(Offset, 16);
      Item.Tag := CHDBE(B, 0, 4);
      Item.Flags := B[4];
      Item.Data := ReadPhysical(CHDAdd(Offset, 16), CHDBE(B, 5, 3));
      Items.Add(Item);
      Offset := CHDBE(B, 8, 8);
    end;

    if FHeader.Version < 3 then
    begin
      Item.Tag := CHDTag('GDDD');
      Item.Flags := 0;
      Item.Data := TEncoding.ASCII.GetBytes(Format('CYLS:%d,HEADS:%d,SECS:%d,BPS:%d',
          [FHeader.Cylinders, FHeader.Heads, FHeader.Sectors, FHeader.UnitBytes]) + #0);
      Items.Add(Item);
    end;

    FMetadata := Items.ToArray;
    if FHeader.Version in [3, 4] then
      for Item in FMetadata do
      begin
        if Item.Tag = CHDTag('GDDD') then
        begin
          var Text := Item.AsString;
          var P := Pos('BPS:', Text);
          if (P > 0) and TryStrToInt(Copy(Text, P + 4, MaxInt), SectorSize) and (SectorSize > 0) then
          begin
            FHeader.UnitBytes := SectorSize;
            Break;
          end;
        end;
        if (Item.Tag = CHDTag('CHCD')) or (Item.Tag = CHDTag('CHTR')) or
          (Item.Tag = CHDTag('CHT2')) or (Item.Tag = CHDTag('CHGT')) or (Item.Tag = CHDTag('CHGD')) then
          FHeader.UnitBytes := 2448;
      end;

    FHeader.UnitCount := FHeader.LogicalBytes div FHeader.UnitBytes;
    if FHeader.LogicalBytes mod FHeader.UnitBytes <> 0 then
      Inc(FHeader.UnitCount);
  finally
    Items.Free;
    Seen.Free;
  end;
end;

procedure TCHDFile.CheckParent;
begin
  if (FHeader.Version < 5) and ((FHeader.Flags and 1) <> 0) then
    CHDRequire(HasBytes(FHeader.ParentMD5) or HasBytes(FHeader.ParentSHA1), 'Missing parent identity');
  if ((FHeader.Version < 5) and ((FHeader.Flags and 1) <> 0)) or HasBytes(FHeader.ParentSHA1) then
    CHDRequire(FParent <> nil, 'CHD requires a parent image', ceRequiresParent);

  if FParent = nil then
    Exit;

  if HasBytes(FHeader.ParentMD5) and HasBytes(FParent.Header.MD5) then
    CHDRequire(EqualBytes(FHeader.ParentMD5, FParent.Header.MD5), 'CHD parent MD5 mismatch', ceInvalidParent);
  if HasBytes(FHeader.ParentSHA1) and HasBytes(FParent.Header.SHA1) then
    CHDRequire(EqualBytes(FHeader.ParentSHA1, FParent.Header.SHA1), 'CHD parent SHA1 mismatch', ceInvalidParent);
  CHDRequire(FParent.Header.UnitBytes = FHeader.UnitBytes, 'CHD parent unit size mismatch', ceInvalidParent);
end;

procedure TCHDFile.ParseMap;
var
  B, Raw: TBytes;
  Entry: TMapEntry;
  Bits: TCHDBits;
  Huff: TCHDHuffman;
  LengthBits, SelfBits, ParentBits, Run, Last, V, EntrySize, N, MapCRC: Integer;
  Offset, Current, LastSelf, LastParent: UInt64;
begin
  SetLength(FMap, FHeader.HunkCount);
  if FHeader.Version < 5 then
  begin
    if FHeader.Version < 3 then
      EntrySize := 8
    else
      EntrySize := 16;
    Offset := FHeader.MapOffset;
    for var i := 0 to High(FMap) do
    begin
      B := ReadPhysical(Offset, EntrySize);
      Inc(Offset, EntrySize);
      Entry := Default(TMapEntry);
      Entry.Offset := CHDBE(B, 0, 8);
      if EntrySize = 8 then
      begin
        Entry.Size := Entry.Offset shr 44;
        Entry.Offset := Entry.Offset and $FFFFFFFFFFF;
        if Entry.Size = FHeader.HunkBytes then
          Entry.Kind := 4
        else
          Entry.Kind := 0;
      end
      else
      begin
        Entry.CRC := CHDBE(B, 8, 4);
        Entry.Size := CHDBE(B, 12, 2) or (Cardinal(B[14]) shl 16);
        if (B[15] and 16) = 0 then
          Entry.CRCBits := 32;
        case B[15] and 15 of
          1:
            Entry.Kind := 0;
          2:
            begin
              Entry.Kind := 4;
              Entry.Size := FHeader.HunkBytes;
            end;
          3:
            Entry.Kind := 7;
          4:
            Entry.Kind := 5;
          5:
            begin
              CHDRequire(FParent <> nil, 'CHD map requires parent', ceRequiresParent);
              Entry.Kind := 9;
              Entry.Offset := CHDMul(Entry.Offset, FParent.Header.HunkBytes);
            end;
        else
          raise ECHDError.Create(ceUnsupportedCodec, 'Unsupported legacy CHD map entry');
        end;
      end;
      FMap[i] := Entry;
    end;

    B := ReadPhysical(Offset, EntrySize);
    Raw := TEncoding.ASCII.GetBytes('EndOfListCookie' + #0#0);
    for var i := 0 to EntrySize - 1 do
      CHDRequire(B[i] = Raw[i], 'CHD map end cookie');
  end
  else if FHeader.Codecs[0] = 0 then
  begin
    B := ReadPhysical(FHeader.MapOffset, Length(FMap) * 4);
    for var i := 0 to High(FMap) do
    begin
      Entry := Default(TMapEntry);
      Entry.Offset := CHDMul(CHDBE(B, i * 4, 4), FHeader.HunkBytes);
      Entry.Size := FHeader.HunkBytes;
      Entry.Kind := 4;
      if Entry.Offset = 0 then
        if FParent = nil then
          Entry.Kind := 8
        else
        begin
          Entry.Kind := 6;
          Entry.Offset := CHDMul(UInt64(i), FHeader.HunkBytes) div FHeader.UnitBytes;
        end;
      FMap[i] := Entry;
    end;
  end
  else
  begin
    B := ReadPhysical(FHeader.MapOffset, 16);
    CHDRequire(CHDBE(B, 0, 4) <= UInt64(High(Integer)), 'CHD compressed map size');
    N := CHDBE(B, 0, 4);
    Current := CHDBE(B, 4, 6);
    MapCRC := CHDBE(B, 10, 2);
    LengthBits := B[12];
    SelfBits := B[13];
    ParentBits := B[14];
    CHDRequire((LengthBits <= 24) and (SelfBits <= 32) and (ParentBits <= 48), 'CHD map bit widths');
    B := ReadPhysical(CHDAdd(FHeader.MapOffset, 16), N);
    Bits.Init(B);
    Huff.ImportRLE(Bits, 16, 8);
    Run := 0;
    Last := 0;
    for var i := 0 to High(FMap) do
    begin
      if Run > 0 then
      begin
        FMap[i].Kind := Byte(Last);
        Dec(Run);
      end
      else
      begin
        V := Huff.Decode(Bits);
        if V = 7 then
          Run := 2 + Huff.Decode(Bits)
        else if V = 8 then
        begin
          Run := 18 + Huff.Decode(Bits) * 16;
          Inc(Run, Huff.Decode(Bits));
        end
        else
          Last := V;
        CHDRequire(Run <= High(FMap) - i, 'CHD map RLE exceeds hunk count');
        FMap[i].Kind := Byte(Last);
      end;
    end;
    LastSelf := 0;
    LastParent := 0;
    SetLength(Raw, Length(FMap) * 12);
    for var i := 0 to High(FMap) do
    begin
      Entry := FMap[i];
      Entry.Offset := Current;
      case Entry.Kind of
        0..3:
          begin
            Entry.Size := Bits.Read(LengthBits);
            Entry.CRC := Bits.Read(16);
            Entry.CRCBits := 16;
            Current := CHDAdd(Current, Entry.Size);
          end;
        4:
          begin
            Entry.Size := FHeader.HunkBytes;
            Entry.CRC := Bits.Read(16);
            Entry.CRCBits := 16;
            Current := CHDAdd(Current, Entry.Size);
          end;
        5:
          begin
            Entry.Offset := Bits.Read(SelfBits);
            LastSelf := Entry.Offset;
          end;
        6:
          begin
            Entry.Offset := Bits.Read64(ParentBits);
            LastParent := Entry.Offset;
          end;
        9, 10:
          begin
            if Entry.Kind = 10 then
              LastSelf := CHDAdd(LastSelf, 1);
            Entry.Kind := 5;
            Entry.Offset := LastSelf;
          end;
        11:
          begin
            Entry.Kind := 6;
            Entry.Offset := CHDMul(UInt64(i), FHeader.HunkBytes) div FHeader.UnitBytes;
            LastParent := Entry.Offset;
          end;
        12, 13:
          begin
            if Entry.Kind = 13 then
              LastParent := CHDAdd(LastParent, FHeader.HunkBytes div FHeader.UnitBytes);
            Entry.Kind := 6;
            Entry.Offset := LastParent;
          end;
      else
        raise ECHDError.Create(ceInvalidData, 'Invalid CHD map compression type');
      end;

      FMap[i] := Entry;
      Raw[i * 12] := Entry.Kind;
      CHDPutBE(Raw, i * 12 + 1, 3, Entry.Size);
      CHDPutBE(Raw, i * 12 + 4, 6, Entry.Offset);
      CHDPutBE(Raw, i * 12 + 10, 2, Entry.CRC);
    end;
    CHDRequire(CHDCRC16(Raw) = MapCRC, 'CHD map CRC mismatch', ceChecksum);
  end;
  for Entry in FMap do
  begin
    if Entry.Kind <= 4 then
    begin
      CHDRequire((Entry.Size > 0) and (Entry.Size <= Cardinal(High(Integer))) and (Entry.Offset <= FFileSize), 'Invalid CHD block range');
      CHDRequire(Entry.Size <= FFileSize - Entry.Offset, 'CHD block exceeds file', ceTruncated);
      if Entry.Kind < 4 then
        CHDRequire(FHeader.Codecs[Entry.Kind] <> 0, 'CHD map references empty codec');
    end;
    if Entry.Kind = 5 then
      CHDRequire(Entry.Offset < FHeader.HunkCount, 'CHD self-reference bounds');
    if Entry.Kind in [6, 9] then
    begin
      CHDRequire(FParent <> nil, 'CHD map requires parent', ceRequiresParent);
      if Entry.Kind = 6 then
        Offset := CHDMul(Entry.Offset, FHeader.UnitBytes)
      else
        Offset := Entry.Offset;
      Current := CHDMul(FParent.Header.HunkCount, FParent.Header.HunkBytes);
      CHDRequire((Offset <= Current) and (UInt64(FHeader.HunkBytes) <= Current - Offset), 'CHD parent reference bounds');
    end;
  end;
end;

function TCHDFile.DecodeHunk(Index: Cardinal): TBytes;
var
  Entry: TMapEntry;
  Steps: Cardinal;
  Original: Cardinal;
begin
  CHDRequire(Index < FHeader.HunkCount, 'CHD hunk out of range', ceOutOfRange);
  Original := Index;
  Steps := 0;
  while FMap[Index].Kind = 5 do
  begin
    Inc(Steps);
    CHDRequire(Steps < FHeader.HunkCount, 'Cyclic CHD self-reference');
    Index := Cardinal(FMap[Index].Offset);
  end;
  Entry := FMap[Index];
  case Entry.Kind of
    0..3:
      Result := CHDDecode(FHeader.Codecs[Entry.Kind], ReadPhysical(Entry.Offset, Entry.Size), FHeader.HunkBytes);
    4:
      Result := ReadPhysical(Entry.Offset, FHeader.HunkBytes);
    6, 9:
      begin
        SetLength(Result, FHeader.HunkBytes);
        TMonitor.Enter(FParent);
        try
          if Entry.Kind = 6 then
            Entry.Offset := CHDMul(Entry.Offset, FHeader.UnitBytes);
          FParent.ReadInternal(Entry.Offset, Result, 0, Length(Result), True);
        finally
          TMonitor.Exit(FParent);
        end;
      end;
    7:
      begin
        SetLength(Result, FHeader.HunkBytes);
        for var i := 0 to High(Result) do
          Result[i] := Byte((Entry.Offset shr ((7 - i mod 8) * 8)) and 255);
      end;
    8:
      begin
        SetLength(Result, FHeader.HunkBytes);
        FillChar(Result[0], Length(Result), 0);
      end;
  else
    raise ECHDError.Create(ceInvalidData, 'Invalid CHD map entry');
  end;

  if Entry.CRCBits = 16 then
    CHDRequire(CHDCRC16(Result) = Entry.CRC, Format('CHD hunk %d CRC16 mismatch', [Index]), ceChecksum)
  else if Entry.CRCBits = 32 then
    CHDRequire(CHDCRC32(Result) = Entry.CRC, Format('CHD hunk %d CRC32 mismatch', [Index]), ceChecksum);
  if (Original <> Index) and (FMap[Original].CRCBits = 32) then
    CHDRequire(CHDCRC32(Result) = FMap[Original].CRC, 'CHD self hunk CRC32 mismatch', ceChecksum);
end;

function TCHDFile.ReadHunk(Index: Cardinal): TBytes;
begin
  TMonitor.Enter(Self);
  try
    if FCachedHunk <> Index then
    begin
      FCache := DecodeHunk(Index);
      FCachedHunk := Index;
    end;
    Result := Copy(FCache);
  finally
    TMonitor.Exit(Self);
  end;
end;

function TCHDFile.ReadInternal(Offset: UInt64; var Buffer: TBytes; BufferOffset, Count: Integer; Padded: Boolean): Integer;
var
  Size, Index: UInt64;
  Within, N: Integer;
begin
  CHDRange(Buffer, BufferOffset, Count);
  if Padded then
    Size := CHDMul(FHeader.HunkCount, FHeader.HunkBytes)
  else
    Size := FHeader.LogicalBytes;

  CHDRequire(Offset <= Size, 'CHD read position out of range', ceOutOfRange);
  Result := 0;
  Count := Integer(Min(UInt64(Count), Size - Offset));
  while Result < Count do
  begin
    Index := Offset div FHeader.HunkBytes;
    if FCachedHunk <> Int64(Index) then
    begin
      FCache := DecodeHunk(Cardinal(Index));
      FCachedHunk := Int64(Index);
    end;
    Within := Offset mod FHeader.HunkBytes;
    N := Min(Count - Result, Length(FCache) - Within);
    Move(FCache[Within], Buffer[BufferOffset + Result], N);
    Inc(Result, N);
    Inc(Offset, N);
  end;
end;

function TCHDFile.ReadAt(Offset: UInt64; var Buffer: TBytes; BufferOffset, Count: Integer): Integer;
begin
  TMonitor.Enter(Self);
  try
    Result := ReadInternal(Offset, Buffer, BufferOffset, Count, False);
  finally
    TMonitor.Exit(Self);
  end;
end;

function TCHDFile.FindMetadata(Tag, Index: Cardinal; out Value: TCHDMetadata): Boolean;
begin
  Value := Default(TCHDMetadata);
  for var M in FMetadata do
    if (Tag = 0) or (M.Tag = Tag) then
    begin
      if Index = 0 then
      begin
        Value := M;
        Value.Data := Copy(M.Data);
        Exit(True);
      end;
      Dec(Index);
    end;
  Result := False;
end;

function TCHDFile.GetMetadata: TArray<TCHDMetadata>;
begin
  Result := Copy(FMetadata);
  for var i := 0 to High(Result) do
    Result[i].Data := Copy(Result[i].Data);
end;

function TCHDFile.HunkInfo(Index: Cardinal): TCHDHunkInfo;
begin
  CHDRequire(Index < FHeader.HunkCount, 'CHD hunk info out of range', ceOutOfRange);
  Result := Default(TCHDHunkInfo);
  Result.Offset := FMap[Index].Offset;
  Result.StoredBytes := FMap[Index].Size;
  if FMap[Index].Kind < 4 then
    Result.Codec := FHeader.Codecs[FMap[Index].Kind];
  Result.IsSelfReference := FMap[Index].Kind = 5;
  Result.IsParentReference := FMap[Index].Kind in [6, 9];
  Result.IsMini := FMap[Index].Kind = 7;
  Result.IsZero := FMap[Index].Kind = 8;
end;

procedure TCHDFile.Precache;
var
  Memory: TMemoryStream;
begin
  TMonitor.Enter(Self);
  try
    CHDRequire(FFileSize <= UInt64(High(NativeInt)), 'CHD is too large to precache in this process');
    Memory := TMemoryStream.Create;
    try
      FStream.Position := 0;
      Memory.CopyFrom(FStream, Int64(FFileSize));
      Memory.Position := 0;
      if FOwnsStream then
        FStream.Free;
      FStream := Memory;
      FOwnsStream := True;
      Memory := nil;
    finally
      Memory.Free;
    end;
  finally
    TMonitor.Exit(Self);
  end;
end;

procedure TCHDFile.ExtractTo(Destination: TStream);
var
  B: TBytes;
  Remaining: UInt64;
  N: Integer;
begin
  CHDRequire(Destination <> nil, 'An extraction destination is required');
  Remaining := FHeader.LogicalBytes;
  for var i := Cardinal(0) to FHeader.HunkCount - 1 do
  begin
    if Remaining = 0 then
      Break;

    B := ReadHunk(i);
    N := Integer(Min(Remaining, UInt64(Length(B))));
    Destination.WriteBuffer(B, N);
    Dec(Remaining, N);
  end;
end;

class function TCHDFile.ReadHeader(Stream: TStream): TCHDHeader;
var
  Reader: TCHDFile;
  Saved: Int64;
begin
  CHDRequire(Stream <> nil, 'A header source stream is required');
  Saved := Stream.Position;
  Reader := TCHDFile.NewInstance as TCHDFile;
  try
    CHDRequire(Stream.Size >= 16, 'Truncated CHD header', ceTruncated);
    Reader.FStream := Stream;
    Reader.FFileSize := Stream.Size;
    Reader.ParseHeader;
    Reader.ParseMetadata;
    Result := Reader.FHeader;
  finally
    Reader.Free;
    Stream.Position := Saved;
  end;
end;

constructor TCHDStream.Create(CHDFile: TCHDFile; OwnsCHD: Boolean);
begin
  inherited Create;
  FCHD := CHDFile;
  FOwnsCHD := OwnsCHD;
  CHDRequire(FCHD <> nil, 'A CHD reader is required');
end;

destructor TCHDStream.Destroy;
begin
  if FOwnsCHD then
    FCHD.Free;
  inherited;
end;

function TCHDStream.GetSize: Int64;
begin
  Result := Int64(FCHD.Header.LogicalBytes);
end;

function TCHDStream.Read(var Buffer; Count: Longint): Longint;
var
  B: TBytes;
begin
  CHDRequire(Count >= 0, 'Negative stream read');
  if FPosition >= Size then
    Exit(0);

  Count := Integer(Min(Int64(Count), Size - FPosition));
  SetLength(B, Count);
  Result := FCHD.ReadAt(UInt64(FPosition), B, 0, Count);
  if Result > 0 then
    Move(B[0], Buffer, Result);
  Inc(FPosition, Result);
end;

function TCHDStream.Write(const Buffer; Count: Longint): Longint; noreturn;
begin
  raise EStreamError.Create('CHD stream is read-only');
end;

function TCHDStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
var
  Base: Int64;
begin
  case Origin of
    soBeginning:
      Base := 0;
    soCurrent:
      Base := FPosition;
    soEnd:
      Base := Size;
  else
    raise EStreamError.Create('Invalid seek origin');
  end;

  if Offset < 0 then
    CHDRequire(Offset >= -Base, 'Negative CHD stream position', ceOutOfRange)
  else
    CHDRequire(Offset <= High(Int64) - Base, 'CHD stream position overflow', ceOutOfRange);
  FPosition := Base + Offset;
  Result := FPosition;
end;

end.

