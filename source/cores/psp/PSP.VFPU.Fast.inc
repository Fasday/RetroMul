{ Size-specialized arithmetic. Prefixes are runtime state even in a decoded block. }

procedure FloatBinary(C: TPSPCPU; Op: Cardinal; N, Kind: Integer); inline;
begin
  if (C.Ctx.VC[VFPU_PFXS] <> PFX_NONE) or (C.Ctx.VC[VFPU_PFXT] <> PFX_NONE) or
    (C.Ctx.VC[VFPU_PFXD] <> 0) then
  begin
    case Kind of
      0: OpVADD(C, Op);
      1: OpVSUB(C, Op);
      2: OpVMUL(C, Op);
    end;
    Exit;
  end;
  var S: PIdx4 := @VecIdx[N - 1, RegS(Op)];
  var T: PIdx4 := @VecIdx[N - 1, RegT(Op)];
  var D: PIdx4 := @VecIdx[N - 1, RegD(Op)];
  var R: TV4;
  for var I := 0 to N - 1 do
    case Kind of
      0: R[I] := VAdd(C.Ctx.V[S[I]], C.Ctx.V[T[I]]);
      1: R[I] := VSub(C.Ctx.V[S[I]], C.Ctx.V[T[I]]);
      2: R[I] := VMul(C.Ctx.V[S[I]], C.Ctx.V[T[I]]);
    end;
  for var I := 0 to N - 1 do
    C.Ctx.V[D[I]] := R[I];
end;

procedure OpVADD1(C: TPSPCPU; Op: Cardinal);
begin
  FloatBinary(C, Op, 1, 0);
end;

procedure OpVADD2(C: TPSPCPU; Op: Cardinal);
begin
  FloatBinary(C, Op, 2, 0);
end;

procedure OpVADD3(C: TPSPCPU; Op: Cardinal);
begin
  FloatBinary(C, Op, 3, 0);
end;

procedure OpVADD4(C: TPSPCPU; Op: Cardinal);
begin
  FloatBinary(C, Op, 4, 0);
end;

procedure OpVSUB1(C: TPSPCPU; Op: Cardinal);
begin
  FloatBinary(C, Op, 1, 1);
end;

procedure OpVSUB2(C: TPSPCPU; Op: Cardinal);
begin
  FloatBinary(C, Op, 2, 1);
end;

procedure OpVSUB3(C: TPSPCPU; Op: Cardinal);
begin
  FloatBinary(C, Op, 3, 1);
end;

procedure OpVSUB4(C: TPSPCPU; Op: Cardinal);
begin
  FloatBinary(C, Op, 4, 1);
end;

procedure OpVMUL1(C: TPSPCPU; Op: Cardinal);
begin
  FloatBinary(C, Op, 1, 2);
end;

procedure OpVMUL2(C: TPSPCPU; Op: Cardinal);
begin
  FloatBinary(C, Op, 2, 2);
end;

procedure OpVMUL3(C: TPSPCPU; Op: Cardinal);
begin
  FloatBinary(C, Op, 3, 2);
end;

procedure OpVMUL4(C: TPSPCPU; Op: Cardinal);
begin
  FloatBinary(C, Op, 4, 2);
end;

const
  FloatBinaryHandlers: array[0..2, 0..3] of TPSPOpHandler = (
    (OpVADD1, OpVADD2, OpVADD3, OpVADD4),
    (OpVSUB1, OpVSUB2, OpVSUB3, OpVSUB4),
    (OpVMUL1, OpVMUL2, OpVMUL3, OpVMUL4));
