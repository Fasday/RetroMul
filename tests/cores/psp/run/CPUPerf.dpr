program CPUPerf;

{$APPTYPE CONSOLE}
{$O+}{$Q-}{$R-}
{$EXCESSPRECISION OFF}
{$POINTERMATH ON}

uses
  System.SysUtils, System.Math, System.Diagnostics, PSP.Types, PSP.Memory,
  PSP.CPU, PSP.VFPU, PSP.VFPU.Math;

type
  TVec = array[0..3] of Cardinal;

var
  Seed: Cardinal = $12345678;
  Hash: UInt64;
  M: TPSPMemory;
  C: TPSPCPU;

function Next: Cardinal;
begin
  Seed := Seed xor (Seed shl 13);
  Seed := Seed xor (Seed shr 17);
  Seed := Seed xor (Seed shl 5);
  Result := Seed;
end;

function Value: Cardinal;
begin
  Result := Next;
  case Result and 7 of
    0: Result := Result and $80000000;
    1: Result := (Result and $80000000) or $7F800000;
    2: Result := Result and $807FFFFF;
    3: Result := (Result and $807FFFFF) or $7F800000;
    4, 5: Result := (Result and $807FFFFF) or $3F000000;
  end;
end;

procedure Mix(const Data; Size: Integer);
begin
  var P := PCardinal(@Data);
  for var I := 0 to Size div 4 - 1 do
    Hash := (Hash xor P[I]) * UInt64(1099511628211);
end;

procedure FillState;
begin
  for var I := 0 to 127 do
    C.Ctx.V[I] := Value;
  for var I := 0 to 31 do
    C.Ctx.FPR[I] := Value;
  for var I := 0 to 3 do
    C.VLatch[I] := Next;
  C.Ctx.VC[0] := $E4;
  C.Ctx.VC[1] := $E4;
  C.Ctx.VC[2] := 0;
  C.Ctx.VC[3] := Next and $3F;
  C.Ctx.FCR31 := Next and $0181FFFF;
end;

procedure Differential;
const
  Ops: array[0..32] of Cardinal = (
    $60000000, $60800000, $63800000, $64000000, $64800000, $65000000,
    $66000000, $67000000, $6D000000, $6D800000, $6E800000, $6F000000,
    $6F800000, $D0000000, $D0010000, $D0020000, $D0040000, $D0050000,
    $D0100000, $D0110000, $D0120000, $D0130000, $D0460000, $D0470000,
    $F0000000, $F0800000, $F1000000, $F1800000, $F2000000, $F2800000,
    $F3800000, $F3830000, $F3A00000);
begin
  Hash := $CBF29CE484222325;
  Seed := $12345678;
  var A, B: TVec;
  for var I := 1 to 1000000 do
  begin
    for var J := 0 to 3 do
    begin
      A[J] := Value;
      B[J] := Value;
    end;
    var N := 1 + Integer(Next and 3);
    var Skip := Next and 15;
    var R := VSum4(A, B, N, Skip);
    Mix(R, 4);
  end;
  Writeln('dot ', IntToHex(Hash, 16));
  for var Base in Ops do
  begin
    Hash := $CBF29CE484222325;
    for var I := 1 to 16384 do
    begin
      FillState;
      var Mask: Cardinal := $007F7F7F;
      if (Base shr 26 = $34) or (Base >= $F3800000) then
        Mask := $00007F7F;
      var Op := Base or (Next and Mask);
      var N := 1 + Integer(Next and 3);
      Op := Op or (Cardinal((N - 1) and 1) shl 7) or (Cardinal((N - 1) and 2) shl 14);
      if I and 3 <> 0 then
      begin
        C.Ctx.VC[0] := Next and $FFFFF;
        C.Ctx.VC[1] := Next and $FFFFF;
        C.Ctx.VC[2] := Next and $FFF;
      end;
      var H := DecodeOp(Op);
      H(C, Op);
      Mix(C.Ctx.V, SizeOf(C.Ctx.V));
      Mix(C.Ctx.VC, SizeOf(C.Ctx.VC));
      Mix(C.VLatch, SizeOf(C.VLatch));
    end;
    Writeln(IntToHex(Base, 8), ' ', IntToHex(Hash, 16));
  end;
  for var Func := 0 to 3 do
  begin
    Hash := $CBF29CE484222325;
    for var I := 1 to 200000 do
    begin
      FillState;
      var Op := $46000000 or (Next and $001FFFC0) or Cardinal(Func);
      var H := DecodeOp(Op);
      H(C, Op);
      Mix(C.Ctx.FPR, SizeOf(C.Ctx.FPR));
      Mix(C.Ctx.FCR31, 4);
    end;
    Writeln('fpu', Func, ' ', IntToHex(Hash, 16));
  end;
end;

procedure Bench(const Name: string; Op: Cardinal; Count: Integer);
begin
  FillState;
  for var I := 0 to 127 do
    C.Ctx.V[I] := $3E800001 + Cardinal(I) * 33041;
  for var I := 0 to 31 do
    C.Ctx.FPR[I] := $3E800001 + Cardinal(I) * 33041;
  C.Ctx.FCR31 := 0;
  var H := DecodeOp(Op);
  var T := TStopwatch.StartNew;
  for var I := 1 to Count do
    H(C, Op);
  T.Stop;
  Writeln(Name:14, ' ', FormatFloat('0.000', T.Elapsed.TotalSeconds), 's ',
    FormatFloat('0.0', Count / T.Elapsed.TotalSeconds / 1E6), ' Mops');
end;

procedure Interpreter;
const
  Base = $08804000;
  Count = 100000000;
begin
  for var I := 0 to 1021 do
    case I and 3 of
      0: M.Write32(Base + Cardinal(I) * 4, $25080001);
      1: M.Write32(Base + Cardinal(I) * 4, $01094826);
      2: M.Write32(Base + Cardinal(I) * 4, $00094A02);
      3: M.Write32(Base + Cardinal(I) * 4, $352A0001);
    end;
  M.Write32(Base + 1022 * 4, $1000FC01);
  M.Write32(Base + 1023 * 4, 0);
  C.SetPC(Base);
  var T := TStopwatch.StartNew;
  C.Run(Count);
  T.Stop;
  Writeln('integer loop  ', FormatFloat('0.000', T.Elapsed.TotalSeconds), 's ',
    FormatFloat('0.0', Count / T.Elapsed.TotalSeconds / 1E6), ' Mops');
end;

begin
  SetExceptionMask(exAllArithmeticExceptions);
  SetRoundMode(rmNearest);
  M := TPSPMemory.Create;
  C := TPSPCPU.Create(M);
  try
    if (ParamCount > 0) and (ParamStr(1) = '-diff') then
      Differential
    else
    begin
      Bench('vadd.q', $60088480, 10000000);
      Bench('vmul.q', $64088480, 10000000);
      Bench('vmov.q', $D0008480, 10000000);
      Bench('vdot.q', $64888480, 5000000);
      Bench('vmmul.q', $F0088480, 1000000);
      Bench('vtfm4.q', $F1888480, 3000000);
      Bench('add.s', $46020800, 10000000);
      Bench('mul.s', $46020802, 10000000);
      Bench('div.s', $46020803, 10000000);
      Interpreter;
    end;
  finally
    C.Free;
    M.Free;
  end;
end.
