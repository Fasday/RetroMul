unit CHD.Codecs;

// CD codec layout and ECC

interface

uses
  System.SysUtils;

const
  CHD_CODEC_NONE = 0;
  CHD_CODEC_ZLIB = $7A6C6962;
  CHD_CODEC_LZMA = $6C7A6D61;
  CHD_CODEC_HUFF = $68756666;
  CHD_CODEC_FLAC = $666C6163;
  CHD_CODEC_ZSTD = $7A737464;
  CHD_CODEC_CDZL = $63647A6C;
  CHD_CODEC_CDLZ = $63646C7A;
  CHD_CODEC_CDFL = $6364666C;
  CHD_CODEC_CDZS = $63647A73;
  CHD_CODEC_AVHU = $61766875;

function CHDCodecSupported(Codec: Cardinal): Boolean;

function CHDDecode(Codec: Cardinal; const Source: TBytes; OutputSize: Integer): TBytes;

procedure CHDGenerateECC(var Sector: TBytes; Offset: Integer = 0);

implementation

uses
  CHD.Common, CHD.Deflate, CHD.LZMA, CHD.FLAC, CHD.Zstd, CHD.AVHuff;

procedure CHDGenerateECC(var Sector: TBytes; Offset: Integer);
var
  ForwardTable, BackwardTable: array[0..255] of Byte;
  N: Integer;

  procedure Generate(MajorCount, MinorCount, MajorMult, MinorInc, Dest: Integer);
  var
    Index, A, B, V: Integer;
  begin
    for var Major := 0 to MajorCount - 1 do
    begin
      Index := (Major div 2) * MajorMult + (Major and 1);
      A := 0;
      B := 0;
      for var Minor := 0 to MinorCount - 1 do
      begin
        if (Sector[Offset + 15] = 2) and (Index < 4) then
          V := 0
        else
          V := Sector[Offset + 12 + Index];
        Index := (Index + MinorInc) mod (MajorCount * MinorCount);
        A := ForwardTable[A xor V];
        B := B xor V;
      end;
      A := BackwardTable[ForwardTable[A] xor B];
      Sector[Offset + Dest + Major] := Byte(A);
      Sector[Offset + Dest + Major + MajorCount] := Byte(A xor B);
    end;
  end;

begin
  CHDRange(Sector, Offset, 2352);
  for var i := 0 to 255 do
  begin
    N := i * 2;
    if (i and 128) <> 0 then
      N := N xor $11D;
    ForwardTable[i] := Byte(N);
    BackwardTable[i xor N] := Byte(i);
  end;
  Generate(86, 24, 2, 86, 2076);
  Generate(52, 43, 86, 88, 2248);
end;

function CHDCodecSupported(Codec: Cardinal): Boolean;
begin
  case Codec of
    CHD_CODEC_NONE, CHD_CODEC_ZLIB, CHD_CODEC_LZMA, CHD_CODEC_HUFF, CHD_CODEC_FLAC, CHD_CODEC_ZSTD, CHD_CODEC_CDZL, CHD_CODEC_CDLZ, CHD_CODEC_CDFL, CHD_CODEC_CDZS, CHD_CODEC_AVHU:
      Result := True;
  else
    Result := False;
  end;
end;

function CHDDecode(Codec: Cardinal; const Source: TBytes; OutputSize: Integer): TBytes;
var
  Bits: TCHDBits;
  Huff: TCHDHuffman;
  Main, Sub: TBytes;
  Used, Frames, ECCBytes, LengthBytes, HeaderBytes, MainSize: Integer;
  MainCodec, SubCodec: Cardinal;
begin
  CHDRequire(OutputSize >= 0, 'Negative codec output size');
  case Codec of
    CHD_CODEC_NONE:
      begin
        CHDRequire(Length(Source) = OutputSize, 'Uncompressed block size');
        Exit(Copy(Source));
      end;
    CHD_CODEC_ZLIB:
      Exit(CHDInflate(Source, OutputSize));
    CHD_CODEC_LZMA:
      Exit(CHDLZMA(Source, OutputSize));
    CHD_CODEC_ZSTD:
      Exit(CHDZstd(Source, OutputSize));
    CHD_CODEC_AVHU:
      Exit(CHDAVHuff(Source, OutputSize));
    CHD_CODEC_HUFF:
      begin
        Bits.Init(Source);
        Huff.ImportHuffman(Bits);
        SetLength(Result, OutputSize);
        for var i := 0 to OutputSize - 1 do
          Result[i] := Byte(Huff.Decode(Bits));
        CHDRequire(Bits.BytePosition = Length(Source), 'Trailing Huffman block data');
        Exit;
      end;
    CHD_CODEC_FLAC:
      begin
        CHDRange(Source, 0, 1);
        CHDRequire((Source[0] = Ord('L')) or (Source[0] = Ord('B')), 'FLAC byte order');
        Result := CHDFLAC(Source, 1, OutputSize, Source[0] = Ord('B'), Used);
        CHDRequire(Used = Length(Source) - 1, 'Trailing FLAC block data');
        Exit;
      end;
  end;

  CHDRequire((OutputSize > 0) and (OutputSize mod 2448 = 0), 'CD hunk geometry');
  Frames := OutputSize div 2448;
  if Codec = CHD_CODEC_CDFL then
  begin
    Main := CHDFLAC(Source, 0, Frames * 2352, True, Used);
    Sub := CHDInflate(Copy(Source, Used, Length(Source) - Used), Frames * 96);
  end
  else
  begin
    SubCodec := CHD_CODEC_ZLIB;
    case Codec of
      CHD_CODEC_CDZL:
        MainCodec := CHD_CODEC_ZLIB;
      CHD_CODEC_CDLZ:
        MainCodec := CHD_CODEC_LZMA;
      CHD_CODEC_CDZS:
        begin
          MainCodec := CHD_CODEC_ZSTD;
          SubCodec := CHD_CODEC_ZSTD;
        end;
    else
      raise ECHDError.Create(ceUnsupportedCodec, Format('Unsupported CHD codec %.8x', [Codec]));
    end;

    ECCBytes := (Frames + 7) div 8;
    if OutputSize < 65536 then
      LengthBytes := 2
    else
      LengthBytes := 3;
    HeaderBytes := ECCBytes + LengthBytes;
    CHDRange(Source, 0, HeaderBytes);
    MainSize := CHDBE(Source, ECCBytes, LengthBytes);
    CHDRange(Source, HeaderBytes, MainSize);
    Main := CHDDecode(MainCodec, Copy(Source, HeaderBytes, MainSize), Frames * 2352);
    Used := HeaderBytes + MainSize;
    Sub := CHDDecode(SubCodec, Copy(Source, Used, Length(Source) - Used), Frames * 96);
  end;

  SetLength(Result, OutputSize);
  for var i := 0 to Frames - 1 do
  begin
    Move(Main[i * 2352], Result[i * 2448], 2352);
    Move(Sub[i * 96], Result[i * 2448 + 2352], 96);
    if (Codec <> CHD_CODEC_CDFL) and ((Source[i div 8] and (1 shl (i mod 8))) <> 0) then
    begin
      Result[i * 2448] := 0;
      Result[i * 2448 + 11] := 0;
      for var j := 1 to 10 do
        Result[i * 2448 + j] := 255;
      CHDGenerateECC(Result, i * 2448);
    end;
  end;
end;

end.

