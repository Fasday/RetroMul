unit CHD.Zstd;

interface

uses
  System.SysUtils;

function CHDZstd(const Source: TBytes; OutputSize: Integer): TBytes;

implementation

uses
  CHD.Common, System.Math;

type
  TZTable = record
    Log: Integer;
    Symbols, Bits, Next: TArray<Integer>;
  end;

  TReverseBits = record
    Data: TBytes;
    Pos, First: Int64;
    procedure Init(const Source: TBytes; Start, Finish: Integer);
    function Peek(Count: Integer): Cardinal;
    function Read(Count: Integer): Cardinal;
  end;

function MSB(V: UInt64): Integer;
begin
  Result := -1;
  while V <> 0 do
  begin
    Inc(Result);
    V := V shr 1;
  end;
end;

function LowBits(const Data: TBytes; Position: Int64; Count: Integer): Cardinal;
begin
  CHDRequire((Count >= 0) and (Count <= 31) and (Position >= 0) and
    (Position + Count <= Int64(Length(Data)) * 8), 'Zstd bitstream bounds', ceTruncated);
  Result := 0;
  for var i := 0 to Count - 1 do
    Result := Result or (Cardinal((Data[Integer((Position + i) div 8)] shr ((Position + i) mod 8)) and 1) shl i);
end;

procedure TReverseBits.Init(const Source: TBytes; Start, Finish: Integer);
begin
  CHDRange(Source, Start, Finish - Start);
  CHDRequire(Finish > Start, 'Empty Zstd bitstream');
  CHDRequire(Source[Finish - 1] <> 0, 'Zstd end marker');
  Data := Source;
  First := Int64(Start) * 8;
  Pos := Int64(Finish - 1) * 8 + MSB(Source[Finish - 1]);
end;

function TReverseBits.Peek(Count: Integer): Cardinal;
var
  P: Int64;
begin
  CHDRequire((Count >= 0) and (Count <= 31), 'Zstd bit count');
  Result := 0;
  for var i := 0 to Count - 1 do
  begin
    P := Pos - Count + i;
    if P >= First then
      Result := Result or (Cardinal((Data[Integer(P div 8)] shr (P mod 8)) and 1) shl i);
  end;
end;

function TReverseBits.Read(Count: Integer): Cardinal;
begin
  CHDRequire(Count <= Pos - First, 'Truncated reverse Zstd bits', ceTruncated);
  Result := Peek(Count);
  Dec(Pos, Count);
end;

function ReadFSE(const Data: TBytes; var Offset: Integer; MaxLog: Integer): TZTable;
var
  P: Int64;
  Probs, Symbol, HighThreshold, Size, NBits, Mask, SmallMax, Value, Small, RepeatCount, Place, Step, NS, NB: Integer;
  Freq, State: array[0..255] of Integer;
begin
  CHDRange(Data, Offset, 1);
  Result.Log := (Data[Offset] and 15) + 5;
  CHDRequire(Result.Log <= MaxLog, 'Zstd FSE accuracy');
  Size := 1 shl Result.Log;
  SetLength(Result.Symbols, Size);
  SetLength(Result.Bits, Size);
  SetLength(Result.Next, Size);
  FillChar(Freq, SizeOf(Freq), 0);
  FillChar(State, SizeOf(State), 0);
  P := Int64(Offset) * 8 + 4;
  Probs := Size;
  Symbol := -1;
  HighThreshold := Size;
  while (Symbol < 255) and (Probs > 0) do
  begin
    NBits := MSB(Probs + 1);
    Mask := (1 shl (NBits + 1)) - 1;
    // The shorter representation may end exactly at the last byte.
    Small := LowBits(Data, P, NBits);
    SmallMax := Mask - Probs - 1;
    if Small < SmallMax then
    begin
      Value := Small;
      Inc(P, NBits);
    end
    else
    begin
      Value := LowBits(Data, P, NBits + 1);
      Inc(P, NBits + 1);
      if Value > (1 shl NBits) - 1 then
        Dec(Value, SmallMax);
    end;
    Inc(Symbol);
    Dec(Value);
    Freq[Symbol] := Value;
    if Value = -1 then
    begin
      Dec(Probs);
      Dec(HighThreshold);
      Result.Symbols[HighThreshold] := Symbol;
    end
    else
      Dec(Probs, Value);
    if Value = 0 then
      repeat
        RepeatCount := LowBits(Data, P, 2);
        Inc(P, 2);
        Inc(Symbol, RepeatCount);
        CHDRequire(Symbol <= 255, 'Zstd FSE zero run');
      until RepeatCount <> 3;
  end;
  CHDRequire((Probs = 0) and (Symbol <= 255), 'Zstd FSE distribution');
  Place := 0;
  Step := (Size div 2) + (Size div 8) + 3;
  for var S := 0 to Symbol do
  begin
    if Freq[S] < 1 then
    begin
      State[S] := -Freq[S];
      Continue;
    end;

    for var i := 1 to Freq[S] do
    begin
      Result.Symbols[Place] := S;
      repeat
        Place := (Place + Step) and (Size - 1);
      until Place < HighThreshold;
    end;
    State[S] := Freq[S];
  end;

  CHDRequire(Place = 0, 'Zstd FSE spread');
  for var i := 0 to Size - 1 do
  begin
    NS := State[Result.Symbols[i]];
    Inc(State[Result.Symbols[i]]);
    CHDRequire(NS > 0, 'Zstd FSE state');
    NB := Result.Log - MSB(NS);
    Result.Bits[i] := NB;
    Result.Next[i] := (NS shl NB) - Size;
  end;
  Offset := (P + 7) div 8;
end;

function ReadHuffman(const Data: TBytes; var Offset: Integer): TZTable;
var
  Weights: array[0..255] of Integer;
  Counts, Ranks: array[0..12] of Integer;
  Head, Finish, Count, S1, S2, B1, B2, Sum, Remaining, W, N, P: Integer;
  FSE: TZTable;
  Bits: TReverseBits;
begin
  CHDRange(Data, Offset, 1);
  Head := Data[Offset];
  Inc(Offset);
  Count := 0;
  FillChar(Weights, SizeOf(Weights), 0);
  FillChar(Counts, SizeOf(Counts), 0);
  FillChar(Ranks, SizeOf(Ranks), 0);
  if Head < 128 then
  begin
    CHDRange(Data, Offset, Head);
    Finish := Offset + Head;
    FSE := ReadFSE(Data, Offset, 6);
    Bits.Init(Data, Offset, Finish);
    S1 := 0;
    S2 := 0;
    B1 := FSE.Log;
    B2 := FSE.Log;
    while True do
    begin
      if B1 > Bits.Pos - Bits.First then
        Break;

      Inc(S1, Bits.Read(B1));
      CHDRequire(S1 < Length(FSE.Symbols), 'Zstd weight state');
      CHDRequire(Count < 255, 'Zstd weight count');
      Weights[Count] := FSE.Symbols[S1];
      Inc(Count);
      if B2 > Bits.Pos - Bits.First then
        Break;

      Inc(S2, Bits.Read(B2));
      CHDRequire(S2 < Length(FSE.Symbols), 'Zstd weight state');
      CHDRequire(Count < 255, 'Zstd weight count');
      Weights[Count] := FSE.Symbols[S2];
      Inc(Count);
      B1 := FSE.Bits[S1];
      S1 := FSE.Next[S1];
      B2 := FSE.Bits[S2];
      S2 := FSE.Next[S2];
    end;
    Offset := Finish;
  end
  else
  begin
    Count := Head - 127;
    CHDRange(Data, Offset, (Count + 1) div 2);
    for var i := 0 to Count - 1 do
      if Odd(i) then
        Weights[i] := Data[Offset + i div 2] and 15
      else
        Weights[i] := Data[Offset + i div 2] shr 4;
    Inc(Offset, (Count + 1) div 2);
  end;

  Sum := 0;
  for var i := 0 to Count - 1 do
  begin
    W := Weights[i];
    CHDRequire(W <= 11, 'Zstd Huffman weight');
    if W > 0 then
      Inc(Sum, 1 shl (W - 1));
  end;
  CHDRequire(Sum > 0, 'Empty Zstd Huffman table');
  Result.Log := MSB(Sum) + 1;
  CHDRequire(Result.Log <= 11, 'Zstd Huffman width');
  Remaining := (1 shl Result.Log) - Sum;
  CHDRequire((Remaining > 0) and ((Remaining and (Remaining - 1)) = 0), 'Zstd implicit Huffman weight');
  Weights[Count] := MSB(Remaining) + 1;
  Inc(Count);

  for var i := 0 to Count - 1 do
  begin
    if Weights[i] <> 0 then
      Weights[i] := Result.Log + 1 - Weights[i];
    Inc(Counts[Weights[i]]);
  end;

  SetLength(Result.Symbols, 1 shl Result.Log);
  SetLength(Result.Bits, Length(Result.Symbols));
  for var i := Result.Log downto 1 do
  begin
    P := Ranks[i];
    N := Counts[i] shl (Result.Log - i);
    Ranks[i - 1] := P + N;
    CHDRequire(P + N <= Length(Result.Bits), 'Zstd Huffman ranks');
    for var j := P to P + N - 1 do
      Result.Bits[j] := i;
  end;

  CHDRequire(Ranks[0] = Length(Result.Symbols), 'Zstd Huffman table size');
  for var i := 0 to Count - 1 do
  begin
    W := Weights[i];
    if W = 0 then
      Continue;

    P := Ranks[W];
    N := 1 shl (Result.Log - W);
    Inc(Ranks[W], N);
    for var j := P to P + N - 1 do
      Result.Symbols[j] := i;
  end;
end;

procedure DecodeHuffman(const Data: TBytes; First, Last: Integer; const Table: TZTable; var Dest: TBytes; Offset, Count: Integer);
var
  Bits: TReverseBits;
  S: Integer;
begin
  CHDRequire(Length(Table.Symbols) > 0, 'Missing Zstd Huffman table');
  CHDRange(Dest, Offset, Count);
  Bits.Init(Data, First, Last);
  for var i := 0 to Count - 1 do
  begin
    S := Bits.Peek(Table.Log);
    Dest[Offset + i] := Byte(Table.Symbols[S]);
    Bits.Read(Table.Bits[S]);
  end;
  CHDRequire(Bits.Pos = Bits.First, 'Zstd literal bitstream size');
end;

// Arithmetic modulo 2^64 is expressed using bounded limbs, with Q+ enabled.
function Add64(A, B: UInt64): UInt64;
var
  L, H: UInt64;
begin
  L := (A and $FFFFFFFF) + (B and $FFFFFFFF);
  H := (A shr 32) + (B shr 32) + (L shr 32);
  Result := ((H and $FFFFFFFF) shl 32) or (L and $FFFFFFFF);
end;

function Mul64(A, B: UInt64): UInt64;
var
  Carry: UInt64;
begin
  Result := 0;
  Carry := 0;
  for var i := 0 to 3 do
  begin
    for var j := 0 to i do
      Inc(Carry, ((A shr (j * 16)) and $FFFF) * ((B shr ((i - j) * 16)) and $FFFF));
    Result := Result or ((Carry and $FFFF) shl (i * 16));
    Carry := Carry shr 16;
  end;
end;

function Rol64(A: UInt64; N: Integer): UInt64;
begin
  Result := (A shl N) or (A shr (64 - N));
end;

function XXH64(const Data: TBytes; Offset, Count: Integer): UInt64;
const
  P1: UInt64 = $9E3779B185EBCA87;
  P2: UInt64 = $C2B2AE3D27D4EB4F;
  P3: UInt64 = $165667B19E3779F9;
  P4: UInt64 = $85EBCA77C2B2AE63;
  P5: UInt64 = $27D4EB2F165667C5;
var
  V: array[0..3] of UInt64;
  P, Finish: Integer;

  function Round(A, B: UInt64): UInt64;
  begin
    Result := Mul64(Rol64(Add64(A, Mul64(B, P2)), 31), P1);
  end;

begin
  CHDRange(Data, Offset, Count);
  P := Offset;
  Finish := Offset + Count;
  if Count >= 32 then
  begin
    V[0] := Add64(P1, P2);
    V[1] := P2;
    V[2] := 0;
    V[3] := Add64(not P1, 1);
    while Finish - P >= 32 do
      for var i := 0 to 3 do
      begin
        V[i] := Round(V[i], CHDLE(Data, P, 8));
        Inc(P, 8);
      end;
    Result := Add64(Add64(Rol64(V[0], 1), Rol64(V[1], 7)), Add64(Rol64(V[2], 12), Rol64(V[3], 18)));
    for var i := 0 to 3 do
      Result := Add64(Mul64(Result xor Round(0, V[i]), P1), P4);
  end
  else
    Result := P5;

  Result := Add64(Result, UInt64(Count));
  while Finish - P >= 8 do
  begin
    Result := Add64(Mul64(Rol64(Result xor Round(0, CHDLE(Data, P, 8)), 27), P1), P4);
    Inc(P, 8);
  end;
  if Finish - P >= 4 then
  begin
    Result := Add64(Mul64(Rol64(Result xor Mul64(CHDLE(Data, P, 4), P1), 23), P2), P3);
    Inc(P, 4);
  end;
  while P < Finish do
  begin
    Result := Mul64(Rol64(Result xor Mul64(Data[P], P5), 11), P1);
    Inc(P);
  end;

  Result := Mul64(Result xor (Result shr 33), P2);
  Result := Mul64(Result xor (Result shr 29), P3);
  Result := Result xor (Result shr 32);
end;

function CHDZstd(const Source: TBytes; OutputSize: Integer): TBytes;
const
  LLBits: array[0..35] of Integer = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16);
  MLBits: array[0..52] of Integer = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16);
var
  Default, Tables: array[0..2] of TZTable;
  Huff: TZTable;
  LLBase: array[0..35] of Integer;
  MLBase: array[0..52] of Integer;
  Reps: array[0..2] of Integer;
  Bits: TReverseBits;
  Literals: TBytes;
  P, Output, FrameOutput, Flags, Single, SizeFlag, DictBytes, SizeBytes, Header, BlockType, BlockSize, BlockEnd, LastBlock, BlockStart, LiteralType, SizeFormat, LiteralSize, CompressedSize, LitEnd, LitPos, StreamSize, PartSize, PartCount, Sequences, Modes, Mode, LS, MS, OS, LC, MC, OC, LL, ML, Distance, Index: Integer;
  FrameSize, OffValue, Magic: UInt64;
  HasSize, Checksum: Boolean;

  function ByteAt: Integer;
  begin
    CHDRange(Source, P, 1);
    Result := Source[P];
    Inc(P);
  end;

  procedure CopyLiterals(N: Integer);
  begin
    CHDRequire((N >= 0) and (N <= Length(Literals) - LitPos) and (N <= OutputSize - Output), 'Zstd literal bounds');
    if N > 0 then
      Move(Literals[LitPos], Result[Output], N);
    Inc(Output, N);
    Inc(LitPos, N);
  end;

begin
  CHDRequire(OutputSize >= 0, 'Negative Zstd output size');
  SetLength(Result, OutputSize);
  P := 0;
  Default[2] := ReadFSE(TBytes.Create(81, 16, 99, 140, 49, 198, 24, 99, 12, 33, 196, 24, 99, 102, 102, 134, 70, 146, 4, 0, 0), P, 6);
  P := 0;
  Default[0] := ReadFSE(TBytes.Create(33, 20, 196, 24, 99, 140, 33, 132, 16, 66, 8, 33, 132, 16, 66, 8, 33, 68, 68, 68, 68, 68, 68, 68, 68, 36, 9, 0, 0), P, 6);
  P := 0;
  Default[1] := ReadFSE(TBytes.Create(32, 132, 16, 66, 102, 70, 68, 68, 68, 68, 36, 73, 2, 0, 0), P, 5);
  LL := 0;
  for var i := 0 to 35 do
  begin
    LLBase[i] := LL;
    Inc(LL, 1 shl LLBits[i]);
  end;
  ML := 3;
  for var i := 0 to 52 do
  begin
    MLBase[i] := ML;
    Inc(ML, 1 shl MLBits[i]);
  end;
  P := 0;
  Output := 0;
  while P < Length(Source) do
  begin
    Magic := CHDLE(Source, P, 4);
    Inc(P, 4);
    if (Magic and $FFFFFFF0) = $184D2A50 then
    begin
      FrameSize := CHDLE(Source, P, 4);
      Inc(P, 4);
      CHDRequire(FrameSize <= UInt64(Length(Source) - P), 'Zstd skippable frame bounds');
      Inc(P, Integer(FrameSize));
      Continue;
    end;

    CHDRequire(Magic = $FD2FB528, 'Zstd frame magic');
    Flags := ByteAt;
    CHDRequire((Flags and $18) = 0, 'Zstd reserved frame bits');
    Single := (Flags shr 5) and 1;
    SizeFlag := Flags shr 6;
    Checksum := (Flags and 4) <> 0;
    if Single = 0 then
      ByteAt;
    DictBytes := Flags and 3;
    if DictBytes = 3 then
      DictBytes := 4;
    CHDRequire(CHDLE(Source, P, DictBytes) = 0, 'CHD Zstd cannot reference an external dictionary');
    Inc(P, DictBytes);
    if SizeFlag = 0 then
      SizeBytes := Single
    else
      SizeBytes := 1 shl SizeFlag;
    HasSize := SizeBytes <> 0;
    FrameSize := CHDLE(Source, P, SizeBytes);
    Inc(P, SizeBytes);
    if SizeFlag = 1 then
      Inc(FrameSize, 256);
    if HasSize then
      CHDRequire(FrameSize <= UInt64(OutputSize - Output), 'Zstd content size');
    FrameOutput := Output;
    Reps[0] := 1;
    Reps[1] := 4;
    Reps[2] := 8;
    Huff := System.Default(TZTable);
    for var i := 0 to 2 do
      Tables[i] := System.Default(TZTable);
    repeat
      Header := CHDLE(Source, P, 3);
      Inc(P, 3);
      LastBlock := Header and 1;
      BlockType := (Header shr 1) and 3;
      BlockSize := Header shr 3;
      CHDRequire(BlockSize <= 131072, 'Zstd maximum block size');
      BlockStart := Output;
      if BlockType = 1 then
      begin
        Index := ByteAt;
        CHDRequire(BlockSize <= OutputSize - Output, 'Zstd RLE output size');
        for var i := 1 to BlockSize do
        begin
          Result[Output] := Byte(Index);
          Inc(Output);
        end;
        Continue;
      end;

      CHDRange(Source, P, BlockSize);
      BlockEnd := P + BlockSize;
      if BlockType = 0 then
      begin
        CHDRequire(BlockSize <= OutputSize - Output, 'Zstd raw output size');
        if BlockSize > 0 then
          Move(Source[P], Result[Output], BlockSize);
        Inc(Output, BlockSize);
        P := BlockEnd;
        Continue;
      end;

      CHDRequire(BlockType = 2, 'Reserved Zstd block');
      Header := ByteAt;
      LiteralType := Header and 3;
      SizeFormat := (Header shr 2) and 3;
      LiteralSize := Header shr 4;
      CompressedSize := 0;
      if LiteralType < 2 then
      begin
        if Odd(SizeFormat) then
        begin
          LiteralSize := LiteralSize or (ByteAt shl 4);
          if SizeFormat = 3 then
            LiteralSize := LiteralSize or (ByteAt shl 12);
        end
        else
          LiteralSize := Header shr 3;
      end
      else if SizeFormat < 2 then
      begin
        Index := ByteAt;
        LiteralSize := LiteralSize or ((Index and 63) shl 4);
        CompressedSize := (Index shr 6) or (ByteAt shl 2);
      end
      else if SizeFormat = 2 then
      begin
        LiteralSize := LiteralSize or (ByteAt shl 4);
        Index := ByteAt;
        LiteralSize := LiteralSize or ((Index and 3) shl 12);
        CompressedSize := (Index shr 2) or (ByteAt shl 6);
      end
      else
      begin
        LiteralSize := LiteralSize or (ByteAt shl 4);
        Index := ByteAt;
        LiteralSize := LiteralSize or ((Index and 63) shl 12);
        CompressedSize := (Index shr 6) or (ByteAt shl 2);
        CompressedSize := CompressedSize or (ByteAt shl 10);
      end;
      CHDRequire((LiteralSize <= 131072) and (LiteralSize <= OutputSize - Output), 'Zstd literal size');
      SetLength(Literals, LiteralSize);
      LitPos := 0;
      if LiteralType = 0 then
      begin
        CHDRequire(LiteralSize <= BlockEnd - P, 'Zstd raw literals');
        if LiteralSize > 0 then
          Move(Source[P], Literals[0], LiteralSize);
        Inc(P, LiteralSize);
      end
      else if LiteralType = 1 then
      begin
        Index := ByteAt;
        for var i := 0 to LiteralSize - 1 do
          Literals[i] := Byte(Index);
      end
      else
      begin
        CHDRequire(CompressedSize <= BlockEnd - P, 'Zstd compressed literals');
        LitEnd := P + CompressedSize;
        if LiteralType = 2 then
          Huff := ReadHuffman(Source, P);
        CHDRequire(P <= LitEnd, 'Zstd Huffman description size');
        if SizeFormat = 0 then
          DecodeHuffman(Source, P, LitEnd, Huff, Literals, 0, LiteralSize)
        else
        begin
          CHDRequire(LitEnd - P >= 6, 'Zstd literal jump table');
          Header := P;
          Inc(P, 6);
          PartSize := (LiteralSize + 3) div 4;
          CHDRequire(PartSize * 3 <= LiteralSize, 'Zstd four-stream size');
          for var i := 0 to 3 do
          begin
            if i = 3 then
            begin
              StreamSize := LitEnd - P;
              PartCount := LiteralSize - 3 * PartSize;
            end
            else
            begin
              StreamSize := CHDLE(Source, Header + 2 * i, 2);
              PartCount := PartSize;
            end;
            CHDRequire(StreamSize <= LitEnd - P, 'Zstd literal stream size');
            DecodeHuffman(Source, P, P + StreamSize, Huff, Literals, i * PartSize, PartCount);
            Inc(P, StreamSize);
          end;
        end;
        P := LitEnd;
      end;
      CHDRequire(P < BlockEnd, 'Missing Zstd sequences');
      Sequences := ByteAt;
      if Sequences <> 0 then
      begin
        if Sequences = 255 then
        begin
          Sequences := CHDLE(Source, P, 2) + $7F00;
          Inc(P, 2);
        end
        else if Sequences > 127 then
          Sequences := (Sequences - 128) * 256 + ByteAt;
        Modes := ByteAt;
        CHDRequire((Modes and 3) = 0, 'Zstd reserved sequence modes');
        for var i := 2 downto 0 do
        begin
          Mode := (Modes shr (2 * i + 2)) and 3;
          case Mode of
            0:
              Tables[i] := Default[i];
            1:
              begin
                Tables[i] := System.Default(TZTable);
                Tables[i].Log := 0;
                Tables[i].Symbols := TArray<Integer>.Create(ByteAt);
                Tables[i].Bits := TArray<Integer>.Create(0);
                Tables[i].Next := TArray<Integer>.Create(0);
              end;
            2:
              Tables[i] := ReadFSE(Source, P, 9 - (i and 1));
            3:
              CHDRequire(Length(Tables[i].Symbols) > 0, 'Missing Zstd repeat FSE table');
          end;
        end;
        Bits.Init(Source, P, BlockEnd);
        LS := Bits.Read(Tables[2].Log);
        OS := Bits.Read(Tables[1].Log);
        MS := Bits.Read(Tables[0].Log);
        for var Seq := 1 to Sequences do
        begin
          LC := Tables[2].Symbols[LS];
          MC := Tables[0].Symbols[MS];
          OC := Tables[1].Symbols[OS];
          CHDRequire((LC <= 35) and (MC <= 52) and (OC <= 31), 'Zstd sequence symbol');
          OffValue := (UInt64(1) shl OC) + Bits.Read(OC);
          ML := MLBase[MC] + Integer(Bits.Read(MLBits[MC]));
          LL := LLBase[LC] + Integer(Bits.Read(LLBits[LC]));
          if Seq < Sequences then
          begin
            LS := Tables[2].Next[LS] + Integer(Bits.Read(Tables[2].Bits[LS]));
            MS := Tables[0].Next[MS] + Integer(Bits.Read(Tables[0].Bits[MS]));
            OS := Tables[1].Next[OS] + Integer(Bits.Read(Tables[1].Bits[OS]));
          end;
          if OffValue > 3 then
          begin
            Dec(OffValue, 3);
            CHDRequire(OffValue <= UInt64(High(Integer)), 'Zstd match distance');
            Distance := Integer(OffValue);
            Reps[2] := Reps[1];
            Reps[1] := Reps[0];
            Reps[0] := Distance;
          end
          else
          begin
            Index := Integer(OffValue);
            if LL <> 0 then
              Dec(Index);
            if Index = 0 then
              Distance := Reps[0]
            else
            begin
              if Index = 3 then
                Distance := Reps[0] - 1
              else
                Distance := Reps[Index];
              if Index > 1 then
                Reps[2] := Reps[1];
              Reps[1] := Reps[0];
              Reps[0] := Distance;
            end;
          end;
          CopyLiterals(LL);
          CHDRequire((Distance > 0) and (Distance <= Output - FrameOutput) and (ML <= OutputSize - Output), 'Zstd invalid backreference');
          for var i := 1 to ML do
          begin
            Result[Output] := Result[Output - Distance];
            Inc(Output);
          end;
        end;
        CHDRequire(Bits.Pos = Bits.First, 'Zstd sequence bitstream size');
      end
      else
        CHDRequire(P = BlockEnd, 'Trailing Zstd sequence bytes');
      CopyLiterals(Length(Literals) - LitPos);
      P := BlockEnd;
      CHDRequire(Output - BlockStart <= 131072, 'Zstd decompressed block size');
    until LastBlock <> 0;
    if HasSize then
      CHDRequire(UInt64(Output - FrameOutput) = FrameSize, 'Zstd frame size mismatch');
    if Checksum then
    begin
      CHDRequire(CHDLE(Source, P, 4) = (XXH64(Result, FrameOutput, Output - FrameOutput) and $FFFFFFFF), 'Zstd checksum', ceChecksum);
      Inc(P, 4);
    end;
  end;
  CHDRequire(Output = OutputSize, 'Zstd output size mismatch');
end;

end.

