unit GW.BZip2;

// Native bounded bzip2 decoder for MGW containers. No external runtime.

interface

uses
  System.SysUtils;

function DecodeGWBZip2(const Data: TBytes; MaxOutput: Integer = 64 * 1024 * 1024): TBytes;

implementation

uses
  System.Classes, System.Math;

type
  THuffman = record
    Counts, First, Offsets: array[0..20] of Integer;
    Symbols: array[0..257] of Integer;
  end;

procedure Check(Condition: Boolean; const Message: string);
begin
  if not Condition then
    raise EReadError.Create('MGW bzip2: ' + Message);
end;

function DecodeGWBZip2(const Data: TBytes; MaxOutput: Integer): TBytes;
var
  BitPos, BlockLimit, Used, Groups, SelectorCount, Selector, Remaining, TableIndex, N, OutCount: Integer;
  Tables: array[0..5] of THuffman;
  Selectors: TBytes;
  Alphabet, MTF: array[0..255] of Byte;
  GroupMTF: array[0..5] of Byte;
  Lengths: array[0..257] of Byte;
  Block: TBytes;
  Next: TArray<Integer>;
  Counts, Starts: array[0..255] of Integer;
  CRCTable: array[0..255] of Cardinal;
  CRC, Combined: Cardinal;

  function Bits(Count: Integer): Cardinal;
  begin
    Check((Count >= 0) and (Int64(BitPos) + Count <= Int64(Length(Data)) * 8), 'truncated stream');
    Result := 0;
    for var i := 1 to Count do
    begin
      Result := (Result shl 1) or ((Data[BitPos shr 3] shr (7 - (BitPos and 7))) and 1);
      Inc(BitPos);
    end;
  end;

  function Symbol: Integer;
  begin
    if Remaining = 0 then
    begin
      Check(Selector < SelectorCount, 'missing Huffman selector');
      TableIndex := Selectors[Selector];
      Inc(Selector);
      Remaining := 50;
    end;
    Dec(Remaining);
    var Code := 0;
    for var L := 1 to 20 do
    begin
      Code := (Code shl 1) or Integer(Bits(1));
      var Index := Code - Tables[TableIndex].First[L];
      if (Index >= 0) and (Index < Tables[TableIndex].Counts[L]) then
        Exit(Tables[TableIndex].Symbols[Tables[TableIndex].Offsets[L] + Index]);
    end;

    raise EReadError.Create('MGW bzip2: invalid Huffman code');
  end;

  procedure Append(Value: Byte);
  begin
    Check(OutCount < MaxOutput, 'output limit exceeded');
    if OutCount = Length(Result) then
      SetLength(Result, Min(Int64(MaxOutput), Int64(OutCount) + 1024 * 1024));
    Result[OutCount] := Value;
    Inc(OutCount);
    CRC := (CRC shl 8) xor CRCTable[(CRC shr 24) xor Value];
  end;

begin
  Check((Length(Data) >= 4) and (Data[0] = Ord('B')) and (Data[1] = Ord('Z')) and
    (Data[2] = Ord('h')) and (Data[3] >= Ord('1')) and (Data[3] <= Ord('9')), 'invalid header');
  Check(MaxOutput > 0, 'invalid output limit');
  BlockLimit := (Data[3] - Ord('0')) * 100000;
  SetLength(Block, BlockLimit);
  SetLength(Next, BlockLimit);
  BitPos := 32;
  OutCount := 0;
  Combined := 0;
  Result := nil;
  for var i := 0 to 255 do
  begin
    var C: Cardinal := Cardinal(i) shl 24;
    for var J := 1 to 8 do
      if (C and $80000000) <> 0 then
        C := (C shl 1) xor $04C11DB7
      else
        C := C shl 1;
    CRCTable[i] := C;
  end;
  while True do
  begin
    var Magic := UInt64(Bits(24)) shl 24;
    Magic := Magic or Bits(24);
    if Magic = $177245385090 then
    begin
      Check(Bits(32) = Combined, 'stream checksum mismatch');
      Break;
    end;

    Check(Magic = $314159265359, 'invalid block header');
    var ExpectedCRC := Bits(32);
    Check(Bits(1) = 0, 'obsolete randomized blocks are unsupported');
    var Original := Integer(Bits(24));
    var UsedGroups := Bits(16);
    Used := 0;
    for var i := 0 to 15 do
      if (UsedGroups and (Cardinal(1) shl (15 - i))) <> 0 then
        for var J := 0 to 15 do
          if Bits(1) <> 0 then
          begin
            Alphabet[Used] := i * 16 + J;
            Inc(Used);
          end;
    Check(Used > 0, 'empty alphabet');
    Groups := Bits(3);
    Check((Groups >= 2) and (Groups <= 6), 'invalid Huffman group count');
    SelectorCount := Bits(15);
    Check((SelectorCount > 0) and (SelectorCount <= 18002), 'invalid selector count');
    SetLength(Selectors, SelectorCount);
    for var i := 0 to Groups - 1 do
      GroupMTF[i] := i;
    for var i := 0 to SelectorCount - 1 do
    begin
      var Index := 0;
      while Bits(1) <> 0 do
      begin
        Inc(Index);
        Check(Index < Groups, 'invalid selector');
      end;
      var Value := GroupMTF[Index];
      while Index > 0 do
      begin
        GroupMTF[Index] := GroupMTF[Index - 1];
        Dec(Index);
      end;
      GroupMTF[0] := Value;
      Selectors[i] := Value;
    end;
    for var T := 0 to Groups - 1 do
    begin
      Tables[T] := Default(THuffman);
      var L := Integer(Bits(5));
      for var i := 0 to Used + 1 do
      begin
        Check((L >= 1) and (L <= 20), 'invalid code length');
        while Bits(1) <> 0 do
        begin
          if Bits(1) = 0 then
            Inc(L)
          else
            Dec(L);
          Check((L >= 1) and (L <= 20), 'invalid code length');
        end;
        Lengths[i] := L;
        Inc(Tables[T].Counts[L]);
      end;
      var Offset := 0;
      var Code := 0;
      for var Len := 1 to 20 do
      begin
        Tables[T].First[Len] := Code;
        Tables[T].Offsets[Len] := Offset;
        Check(Code + Tables[T].Counts[Len] <= 1 shl Len, 'oversubscribed Huffman table');
        for var i := 0 to Used + 1 do
          if Lengths[i] = Len then
          begin
            Tables[T].Symbols[Offset] := i;
            Inc(Offset);
          end;
        Code := (Code + Tables[T].Counts[Len]) * 2;
      end;
    end;
    for var i := 0 to Used - 1 do
      MTF[i] := Alphabet[i];
    Selector := 0;
    Remaining := 0;
    N := 0;
    var S := Symbol;
    while S <> Used + 1 do
    begin
      if S <= 1 then
      begin
        var Run := 0;
        var Weight := 1;
        repeat
          Check(Weight <= BlockLimit, 'invalid run');
          Inc(Run, (S + 1) * Weight);
          Check(Run <= BlockLimit - N, 'block overrun');
          Weight := Weight * 2;
          S := Symbol;
        until S > 1;
        FillChar(Block[N], Run, MTF[0]);
        Inc(N, Run);
      end
      else
      begin
        var Index := S - 1;
        Check((Index > 0) and (Index < Used), 'invalid MTF symbol');
        var Value := MTF[Index];
        while Index > 0 do
        begin
          MTF[Index] := MTF[Index - 1];
          Dec(Index);
        end;
        MTF[0] := Value;
        Check(N < BlockLimit, 'block overrun');
        Block[N] := Value;
        Inc(N);
        S := Symbol;
      end;
    end;
    Check((Original >= 0) and (Original < N), 'invalid BWT pointer');
    FillChar(Counts, SizeOf(Counts), 0);
    for var i := 0 to N - 1 do
      Inc(Counts[Block[i]]);
    var Start := 0;
    for var i := 0 to 255 do
    begin
      Starts[i] := Start;
      Inc(Start, Counts[i]);
    end;
    for var i := 0 to N - 1 do
    begin
      Next[Starts[Block[i]]] := i;
      Inc(Starts[Block[i]]);
    end;
    var Position := Next[Original];
    var Previous := -1;
    var Repeated := 0;
    CRC := $FFFFFFFF;
    for var i := 0 to N - 1 do
    begin
      var Value := Block[Position];
      Position := Next[Position];
      if Repeated = 4 then
      begin
        for var J := 1 to Value do
          Append(Previous);
        Previous := -1;
        Repeated := 0;
      end
      else
      begin
        Append(Value);
        if Value = Previous then
          Inc(Repeated)
        else
        begin
          Previous := Value;
          Repeated := 1;
        end;
      end;
    end;
    Check(Repeated <> 4, 'truncated byte run');
    CRC := not CRC;
    Check(CRC = ExpectedCRC, 'block checksum mismatch');
    Combined := ((Combined shl 1) or (Combined shr 31)) xor CRC;
  end;
  SetLength(Result, OutCount);
end;

end.

