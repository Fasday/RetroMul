unit CHD.LZMA;

// LZMA SDK decoding model (Igor Pavlov, public domain), CHD properties lc=3/lp=0/pb=2.

interface

uses
  System.SysUtils;

function CHDLZMA(const Source: TBytes; OutputSize: Integer): TBytes;

implementation

uses
  CHD.Common, System.Math;

function CHDLZMA(const Source: TBytes; OutputSize: Integer): TBytes;
var
  RangeValue, CodeValue: Cardinal;
  Input, Output, State, PosState, Sym, MatchByte, MatchBit, B, Len, Slot, DirectBits: Integer;
  Rep0, Rep1, Rep2, Rep3, Distance: Cardinal;
  IsMatch: array[0..191] of Word;
  IsRep, IsRepG0, IsRepG1, IsRepG2: array[0..11] of Word;
  IsRep0Long: array[0..191] of Word;
  PosSlot: array[0..255] of Word;
  PosDec: array[0..113] of Word;
  Align: array[0..15] of Word;
  Literal: array[0..6143] of Word;
  LenProbs, RepLenProbs: array[0..513] of Word;

  procedure Normalize;
  begin
    if RangeValue < $1000000 then
    begin
      CHDRequire(Input < Length(Source), 'Truncated LZMA', ceTruncated);
      RangeValue := RangeValue shl 8;
      CodeValue := Cardinal(((UInt64(CodeValue) shl 8) or Source[Input]) and $FFFFFFFF);
      Inc(Input);
    end;
  end;

  function Bit(var Probability: Word): Integer;
  var
    Bound: Cardinal;
  begin
    Normalize;
    Bound := (RangeValue shr 11) * Cardinal(Probability);
    if CodeValue < Bound then
    begin
      RangeValue := Bound;
      Probability := Probability + (2048 - Probability) div 32;
      Result := 0;
    end
    else
    begin
      Dec(RangeValue, Bound);
      Dec(CodeValue, Bound);
      Probability := Probability - Probability div 32;
      Result := 1;
    end;
  end;

  function Tree(var Probs: array of Word; Base, Bits: Integer; Reverse: Boolean = False): Cardinal;
  var
    S, V: Integer;
  begin
    S := 1;
    Result := 0;
    for var i := 0 to Bits - 1 do
    begin
      CHDRequire((Base + S >= 0) and (Base + S < Length(Probs)), 'LZMA probability index');
      V := Bit(Probs[Base + S]);
      S := S * 2 + V;
      if Reverse then
        Result := Result or (Cardinal(V) shl i);
    end;
    if not Reverse then
      Result := S - (1 shl Bits);
  end;

  function DecodeLength(var Probs: array of Word): Integer;
  begin
    if Bit(Probs[0]) = 0 then
      Exit(Integer(Tree(Probs, 2 + PosState * 8, 3)) + 2);

    if Bit(Probs[1]) = 0 then
      Exit(Integer(Tree(Probs, 130 + PosState * 8, 3)) + 10);

    Result := Integer(Tree(Probs, 258, 8)) + 18;
  end;

  procedure Init(var Probs: array of Word);
  begin
    for var i := 0 to High(Probs) do
      Probs[i] := 1024;
  end;

begin
  CHDRequire(OutputSize >= 0, 'Negative LZMA size');
  CHDRange(Source, 0, 5);
  CHDRequire(Source[0] = 0, 'LZMA range header');
  RangeValue := $FFFFFFFF;
  CodeValue := Cardinal(CHDBE(Source, 1, 4));
  Input := 5;
  Init(IsMatch);
  Init(IsRep);
  Init(IsRepG0);
  Init(IsRepG1);
  Init(IsRepG2);
  Init(IsRep0Long);
  Init(PosSlot);
  Init(PosDec);
  Init(Align);
  Init(Literal);
  Init(LenProbs);
  Init(RepLenProbs);
  SetLength(Result, OutputSize);
  Output := 0;
  State := 0;
  Rep0 := 0;
  Rep1 := 0;
  Rep2 := 0;
  Rep3 := 0;

  while Output < OutputSize do
  begin
    PosState := Output and 3;
    if Bit(IsMatch[State * 16 + PosState]) = 0 then
    begin
      if Output = 0 then
        B := 0
      else
        B := (Result[Output - 1] shr 5) * 768;
      Sym := 1;
      if State >= 7 then
      begin
        CHDRequire(Rep0 < Cardinal(Output), 'LZMA literal match distance');
        MatchByte := Result[Output - Integer(Rep0) - 1];
        repeat
          MatchBit := (MatchByte shr 7) and 1;
          MatchByte := (MatchByte shl 1) and 255;
          var V := Bit(Literal[B + (1 + MatchBit) * 256 + Sym]);
          Sym := Sym * 2 + V;
          if MatchBit <> V then
            Break;
        until Sym >= 256;
      end;
      while Sym < 256 do
        Sym := Sym * 2 + Bit(Literal[B + Sym]);
      Result[Output] := Byte(Sym - 256);
      Inc(Output);
      if State < 4 then
        State := 0
      else if State < 10 then
        Dec(State, 3)
      else
        Dec(State, 6);
      Continue;
    end;

    if Bit(IsRep[State]) <> 0 then
    begin
      Len := 0;
      if Bit(IsRepG0[State]) = 0 then
      begin
        if Bit(IsRep0Long[State * 16 + PosState]) = 0 then
        begin
          if State < 7 then
            State := 9
          else
            State := 11;
          Len := 1;
        end;
      end
      else
      begin
        if Bit(IsRepG1[State]) = 0 then
          Distance := Rep1
        else
        begin
          if Bit(IsRepG2[State]) = 0 then
            Distance := Rep2
          else
          begin
            Distance := Rep3;
            Rep3 := Rep2;
          end;
          Rep2 := Rep1;
        end;
        Rep1 := Rep0;
        Rep0 := Distance;
      end;
      if Len = 0 then
      begin
        Len := DecodeLength(RepLenProbs);
        if State < 7 then
          State := 8
        else
          State := 11;
      end;
    end
    else
    begin
      Rep3 := Rep2;
      Rep2 := Rep1;
      Rep1 := Rep0;
      Len := DecodeLength(LenProbs);
      if State < 7 then
        State := 7
      else
        State := 10;
      Slot := Tree(PosSlot, Min(Len - 2, 3) * 64, 6);
      if Slot < 4 then
        Rep0 := Slot
      else
      begin
        DirectBits := Slot div 2 - 1;
        Rep0 := Cardinal(2 or (Slot and 1)) shl DirectBits;
        if Slot < 14 then
          Inc(Rep0, Tree(PosDec, Integer(Rep0) - Slot - 1, DirectBits, True))
        else
        begin
          Distance := 0;
          for var i := 1 to DirectBits - 4 do
          begin
            Normalize;
            RangeValue := RangeValue shr 1;
            Distance := Distance shl 1;
            if CodeValue >= RangeValue then
            begin
              Dec(CodeValue, RangeValue);
              Distance := Distance or 1;
            end;
          end;
          Rep0 := Rep0 or (Distance shl 4) or Tree(Align, 0, 4, True);
        end;
      end;
    end;

    CHDRequire((Rep0 < Cardinal(Output)) and (Len <= OutputSize - Output), 'Invalid LZMA match');
    for var i := 1 to Len do
    begin
      Result[Output] := Result[Output - Integer(Rep0) - 1];
      Inc(Output);
    end;
  end;
end;

end.

