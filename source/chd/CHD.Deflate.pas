unit CHD.Deflate;

// RFC 1951 raw inflate, implemented with indexed Pascal buffers.

interface

uses
  System.SysUtils;

function CHDInflate(const Source: TBytes; OutputSize: Integer): TBytes;

implementation

uses
  CHD.Common;

function CHDInflate(const Source: TBytes; OutputSize: Integer): TBytes;
const
  Order: array[0..18] of Integer = (16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15);
  LB: array[0..28] of Integer = (3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258);
  LE: array[0..28] of Integer = (0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0);
  DB: array[0..29] of Integer = (1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577);
  DE: array[0..29] of Integer = (0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13);
var
  Bits: TCHDBits;
  Lit, Dist, Codes: TCHDHuffman;
  L, D, C, All: TArray<Integer>;
  FinalBlock, Kind, N, NN, NL, ND, NC, S, Run, Value, Len, Distance: Integer;
begin
  CHDRequire(OutputSize >= 0, 'Negative output size');
  SetLength(Result, OutputSize);
  N := 0;
  Bits.Init(Source, True);
  repeat
    FinalBlock := Bits.Read(1);
    Kind := Bits.Read(2);
    if Kind = 0 then
    begin
      Bits.Align;
      Len := Bits.Read(16);
      NN := Bits.Read(16);
      CHDRequire((Len xor NN) = $FFFF, 'Deflate stored length');
      CHDRequire(Len <= OutputSize - N, 'Deflate output overflow');
      for var i := 1 to Len do
      begin
        Result[N] := Byte(Bits.Read(8));
        Inc(N);
      end;
      Continue;
    end;

    CHDRequire(Kind <> 3, 'Reserved Deflate block');
    if Kind = 1 then
    begin
      SetLength(L, 288);
      SetLength(D, 32);
      for var i := 0 to 287 do
        if i <= 143 then
          L[i] := 8
        else if i <= 255 then
          L[i] := 9
        else if i <= 279 then
          L[i] := 7
        else
          L[i] := 8;
      for var i := 0 to 31 do
        D[i] := 5;
    end
    else
    begin
      NL := Bits.Read(5) + 257;
      ND := Bits.Read(5) + 1;
      NC := Bits.Read(4) + 4;
      CHDRequire(NL <= 286, 'Deflate literal count');
      C := nil;
      SetLength(C, 19);
      for var i := 0 to NC - 1 do
        C[Order[i]] := Bits.Read(3);
      Codes.Build(C, 7, False);
      SetLength(All, NL + ND);
      NN := 0;
      while NN < Length(All) do
      begin
        S := Codes.Decode(Bits);
        Run := 1;
        Value := S;
        case S of
          16:
            begin
              CHDRequire(NN > 0, 'Deflate missing previous length');
              Value := All[NN - 1];
              Run := Bits.Read(2) + 3;
            end;
          17:
            begin
              Value := 0;
              Run := Bits.Read(3) + 3;
            end;
          18:
            begin
              Value := 0;
              Run := Bits.Read(7) + 11;
            end;
        end;
        CHDRequire(Run <= Length(All) - NN, 'Deflate length run');
        for var i := 1 to Run do
        begin
          All[NN] := Value;
          Inc(NN);
        end;
      end;
      L := Copy(All, 0, NL);
      D := Copy(All, NL, ND);
    end;

    CHDRequire(L[256] <> 0, 'Deflate end marker missing');
    Lit.Build(L, 15, False);
    Dist.Build(D, 15, False);
    while True do
    begin
      S := Lit.Decode(Bits);
      if S = 256 then
        Break;

      if S < 256 then
      begin
        CHDRequire(N < OutputSize, 'Deflate output overflow');
        Result[N] := Byte(S);
        Inc(N);
      end
      else
      begin
        CHDRequire(S <= 285, 'Deflate length symbol');
        Dec(S, 257);
        Len := LB[S] + Integer(Bits.Read(LE[S]));
        S := Dist.Decode(Bits);
        CHDRequire(S < 30, 'Deflate distance symbol');
        Distance := DB[S] + Integer(Bits.Read(DE[S]));
        CHDRequire((Distance <= N) and (Len <= OutputSize - N), 'Deflate invalid match');
        for var i := 1 to Len do
        begin
          Result[N] := Result[N - Distance];
          Inc(N);
        end;
      end;
    end;
  until FinalBlock <> 0;
  CHDRequire(N = OutputSize, 'Deflate output size mismatch');
  CHDRequire(Bits.BytePosition = Length(Source), 'Trailing Deflate data');
end;

end.

