unit CHD.AVHuff;

interface

uses
  System.SysUtils;

function CHDAVHuff(const Source: TBytes; OutputSize: Integer): TBytes;

implementation

uses
  CHD.Common, CHD.FLAC;

function CHDAVHuff(const Source: TBytes; OutputSize: Integer): TBytes;
var
  MetaSize, Channels, Samples, Width, Height, TreeSize, P, Dest, Size, Used, Previous, Delta: Integer;
  Audio: TBytes;
  Bits: TCHDBits;
  Trees: array[0..4] of TCHDHuffman;
  Prev, Runs: array[0..4] of Integer;

  function DeltaByte(Tree: Integer): Byte;
  var
    V: Integer;
  begin
    if Runs[Tree] > 0 then
      Dec(Runs[Tree])
    else
    begin
      V := Trees[Tree].Decode(Bits);
      if V < 256 then
        Prev[Tree] := (Prev[Tree] + V) and 255
      else
      begin
        if V <= $107 then
          Runs[Tree] := 8 + V - $100
        else
          Runs[Tree] := 16 shl (V - $108);
        Dec(Runs[Tree]);
      end;
    end;
    Result := Byte(Prev[Tree]);
  end;

begin
  CHDRange(Source, 0, 10);
  MetaSize := Source[0];
  Channels := Source[1];
  Samples := CHDBE(Source, 2, 2);
  Width := CHDBE(Source, 4, 2);
  Height := CHDBE(Source, 6, 2);
  TreeSize := CHDBE(Source, 8, 2);
  CHDRequire(Channels <= 16, 'AVHuff channel count');
  CHDRequire(not Odd(Width), 'AVHuff video width must be even');
  CHDRequire((OutputSize >= 12) and (UInt64(12 + MetaSize + 2 * Channels * Samples) + UInt64(2) * UInt64(Width) * UInt64(Height) <= UInt64(OutputSize)), 'AVHuff output size');
  P := 10 + 2 * Channels;
  CHDRange(Source, 0, P + MetaSize);
  SetLength(Result, OutputSize);
  FillChar(Result[0], OutputSize, 0);
  Result[0] := Ord('c');
  Result[1] := Ord('h');
  Result[2] := Ord('a');
  Result[3] := Ord('v');
  Move(Source[0], Result[4], 8);
  Dest := 12;

  if MetaSize > 0 then
    Move(Source[P], Result[Dest], MetaSize);
  Inc(P, MetaSize);
  Inc(Dest, MetaSize);

  if (Channels > 0) and (TreeSize <> 0) and (TreeSize <> $FFFF) then
  begin
    Bits.Init(Source, False, P, TreeSize);
    Trees[3].ImportRLE(Bits, 272, 16);
    Bits.Align;
    Trees[4].ImportRLE(Bits, 272, 16);
    Bits.Align;
    CHDRequire(Bits.BytePosition = P + TreeSize, 'AVHuff audio tree size');
    Inc(P, TreeSize);
  end;

  for var Ch := 0 to Channels - 1 do
  begin
    Size := CHDBE(Source, 10 + 2 * Ch, 2);
    CHDRange(Source, P, Size);
    if TreeSize = $FFFF then
    begin
      Audio := CHDFLAC(Copy(Source, P, Size), 0, Samples * 2, True, Used, 1);
      CHDRequire(Used = Size, 'AVHuff FLAC channel size');
      if Length(Audio) > 0 then
        Move(Audio[0], Result[Dest], Length(Audio));
      Inc(Dest, Length(Audio));
    end
    else
    begin
      Previous := 0;
      Prev[3] := 0;
      Prev[4] := 0;
      Runs[3] := 0;
      Runs[4] := 0;
      Bits.Init(Source, False, P, Size);
      for var I := 0 to Samples - 1 do
      begin
        if TreeSize = 0 then
          Delta := Bits.Read(16)
        else
        begin
          Delta := Integer(DeltaByte(3)) shl 8;
          Delta := Delta or DeltaByte(4);
        end;
        Previous := (Previous + Delta) and $FFFF;
        Result[Dest] := Byte(Previous shr 8);
        Result[Dest + 1] := Byte(Previous and 255);
        Inc(Dest, 2);
      end;
    end;
    Inc(P, Size);
  end;

  if (Width > 0) and (Height > 0) then
  begin
    Bits.Init(Source, False, P);
    CHDRequire((Bits.Read(8) and $80) <> 0, 'Unsupported lossy AVHuff video', ceUnsupportedCodec);
    for var I := 0 to 2 do
    begin
      Trees[I].ImportRLE(Bits, 272, 16);
      Bits.Align;
      Prev[I] := 0;
      Runs[I] := 0;
    end;
    for var Y := 0 to Height - 1 do
    begin
      for var X := 0 to Width div 2 - 1 do
      begin
        Result[Dest] := DeltaByte(0);
        Result[Dest + 1] := DeltaByte(1);
        Result[Dest + 2] := DeltaByte(0);
        Result[Dest + 3] := DeltaByte(2);
        Inc(Dest, 4);
      end;
      Runs[0] := 0;
      Runs[1] := 0;
      Runs[2] := 0;
    end;
    CHDRequire(Bits.BytePosition = Length(Source), 'AVHuff video size');
  end;
end;

end.

