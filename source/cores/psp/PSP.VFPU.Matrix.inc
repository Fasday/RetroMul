{ Matrices }

type
  TM4 = array[0..3] of TV4;

procedure LoadM(C: TPSPCPU; Reg: Cardinal; N: Integer; var M: TM4);
begin
  for var K := 0 to 3 do
    for var I := 0 to 3 do
      if (K < N) and (I < N) then
        M[K][I] := C.Ctx.V[MatIdx[N - 1, Reg, K][I]]
      else
        M[K][I] := 0;
end;

procedure StoreM(C: TPSPCPU; Reg: Cardinal; N: Integer; const M: TM4);
begin
  for var K := 0 to N - 1 do
    for var I := 0 to N - 1 do
      C.Ctx.V[MatIdx[N - 1, Reg, K][I]] := M[K][I];
end;

procedure OpVMMUL(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, T, D: TM4;
  LoadM(C, RegS(Op), N, S);
  LoadM(C, RegT(Op), N, T);
  for var I := 0 to N - 1 do
    for var J := 0 to N - 1 do
      D[I][J] := VSum4(S[J], T[I], N, 0);
  StoreM(C, RegD(Op), N, D);
  EatPfx(C);
end;

// vtfmN/vhtfmN: the function picks the matrix size, the size field how much
// of the vector is real; a short vector is padded with zeros and a final 1.
procedure OpVTFM(C: TPSPCPU; Op: Cardinal);
begin
  var N := Integer((Op shr 23) and 7) + 1;
  var Sz := VSz(Op);
  var M: TM4;
  var T, Raw, D: TV4;
  LoadM(C, RegS(Op), N, M);
  var Real := Sz;
  if Real > N then
    Real := N;
  LoadV(C, RegT(Op), Real, Raw);
  for var K := 0 to 3 do
    if K < Real then
      T[K] := Raw[K]
    else
      T[K] := 0;
  if Sz < N then
    T[N - 1] := VF_ONE;
  for var I := 0 to N - 2 do
    D[I] := VSum4(M[I], T, N, 0);
  var PS := C.Ctx.VC[VFPU_PFXS];
  var PT := C.Ctx.VC[VFPU_PFXT];
  if (PS = PFX_NONE) and (PT = PFX_NONE) then
    D[N - 1] := VSum4(M[N - 1], T, N, 0)
  else
  begin
    var S2, T2: TV4;
    var Z := ApplyPfx(M[N - 1], N, PS, S2) or ApplyPfx(T, N, PT, T2);
    D[N - 1] := VSum4(S2, T2, N, Z);
  end;
  WriteLast(C, RegD(Op), N, D, False);
  EatPfx(C);
end;

procedure OpVMSCL(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TM4;
  LoadM(C, RegS(Op), N, S);
  var T := C.Ctx.V[VecIdx[0, RegT(Op)][0]];
  for var K := 0 to N - 1 do
    for var I := 0 to N - 1 do
      D[K][I] := VMul(S[K][I], T);
  StoreM(C, RegD(Op), N, D);
  EatPfx(C);
end;

function Sum2(A, B, X, Y: Cardinal): Cardinal; inline;
var
  P, Q: TV4;
begin
  P[0] := A;
  P[1] := X;
  Q[0] := B;
  Q[1] := Y;
  Result := VSum4(P, Q, 2, 0);
end;

procedure OpVCRSPQMUL(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, T, D: TV4;
  LoadV(C, RegS(Op), N, S);
  LoadV(C, RegT(Op), N, T);
  var Zero := False;
  LastIn(C.Ctx.VC[VFPU_PFXS], 0, Zero);
  LastIn(C.Ctx.VC[VFPU_PFXT], 0, Zero);
  case N of
    3:
      begin
        // Lane by lane, z first, each from the register file as it stands.
        var P: PIdx4 := @VecIdx[2, RegD(Op)];
        var DPfx := C.Ctx.VC[VFPU_PFXD];
        var Z := Sum2(S[0], T[1], S[1] xor $80000000, T[0]);
        if Zero then
          Z := 0;
        if (DPfx and $100) = 0 then
          C.Ctx.V[P[2]] := SatLane(Z, DPfx and 3);
        LoadV(C, RegS(Op), N, S);
        LoadV(C, RegT(Op), N, T);
        C.Ctx.V[P[1]] := Sum2(S[2], T[0], S[0] xor $80000000, T[2]);
        LoadV(C, RegS(Op), N, S);
        LoadV(C, RegT(Op), N, T);
        C.Ctx.V[P[0]] := Sum2(S[1], T[2], S[2] xor $80000000, T[1]);
        EatPfx(C);
        Exit;
      end;
    4:
      begin
        var P, Q: TV4;
        P[0] := S[0]; P[1] := S[1]; P[2] := S[2] xor $80000000; P[3] := S[3];
        Q[0] := T[3]; Q[1] := T[2]; Q[2] := T[1]; Q[3] := T[0];
        D[0] := VSum4(P, Q, 4, 0);
        P[0] := S[0] xor $80000000; P[1] := S[1]; P[2] := S[2]; P[3] := S[3];
        Q[0] := T[2]; Q[1] := T[3]; Q[2] := T[0]; Q[3] := T[1];
        D[1] := VSum4(P, Q, 4, 0);
        P[0] := S[0]; P[1] := S[1] xor $80000000; P[2] := S[2]; P[3] := S[3];
        Q[0] := T[1]; Q[1] := T[0]; Q[2] := T[3]; Q[3] := T[2];
        D[2] := VSum4(P, Q, 4, 0);
        P[0] := S[0] xor $80000000; P[1] := S[1] xor $80000000; P[2] := S[2] xor $80000000; P[3] := S[3];
        Q[0] := T[0]; Q[1] := T[1]; Q[2] := T[2]; Q[3] := T[3];
        D[3] := VSum4(P, Q, 4, 0);
      end;
  else
    D := Default(TV4);
    Zero := False;
  end;
  WriteLast(C, RegD(Op), N, D, Zero);
  EatPfx(C);
end;

procedure OpVMMOV(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S: TM4;
  LoadM(C, RegS(Op), N, S);
  StoreM(C, RegD(Op), N, S);
  EatPfx(C);
end;

procedure DoMatFill(C: TPSPCPU; Op: Cardinal; Kind: Integer);
begin
  var N := VSz(Op);
  var D: TM4;
  for var K := 0 to 3 do
    for var I := 0 to 3 do
      case Kind of
        0: D[K][I] := 0;
        1: D[K][I] := VF_ONE;
      else
        if K = I then
          D[K][I] := VF_ONE
        else
          D[K][I] := 0;
      end;
  StoreM(C, RegD(Op), N, D);
  EatPfx(C);
end;

procedure OpVMIDT(C: TPSPCPU; Op: Cardinal);
begin
  DoMatFill(C, Op, 2);
end;

procedure OpVMZERO(C: TPSPCPU; Op: Cardinal);
begin
  DoMatFill(C, Op, 0);
end;

procedure OpVMONE(C: TPSPCPU; Op: Cardinal);
begin
  DoMatFill(C, Op, 1);
end;

// The sine lanes (and zeros) are written first, the cosine after, from the
// angle register as it is then.
procedure OpVROT(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var AngleIdx := VecIdx[0, RegS(Op)][0];
  var Imm := (Op shr 16) and 31;
  var Zero := False;
  var SA := LastIn(C.Ctx.VC[VFPU_PFXS], C.Ctx.V[AngleIdx], Zero);
  var Si: Cardinal := 0;
  if not Zero then
    Si := VSin(SA);
  if (Imm and 16) <> 0 then
    Si := Si xor $80000000;
  var CL := Integer(Imm and 3);
  var SL := Integer((Imm shr 2) and 3);
  var D: TV4;
  for var I := 0 to 3 do
    if (SL = CL) or (I = SL) then
      D[I] := Si
    else
      D[I] := 0;
  StoreV(C, RegD(Op), N, D);
  if CL < N then
    C.Ctx.V[VecIdx[N - 1, RegD(Op)][CL]] := VCos(C.Ctx.V[AngleIdx]);
  EatPfx(C);
end;

{ Prefixes and no-ops }

procedure OpVPFXS(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.VC[VFPU_PFXS] := Op and $FFFFF;
end;

procedure OpVPFXT(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.VC[VFPU_PFXT] := Op and $FFFFF;
end;

procedure OpVPFXD(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.VC[VFPU_PFXD] := Op and $FFF;
end;

procedure OpVNOP(C: TPSPCPU; Op: Cardinal);
begin
end;

{ Loads and stores }

procedure OpLVS(C: TPSPCPU; Op: Cardinal);
begin
  var Reg := ((Op shr 16) and $1F) or ((Op and 3) shl 5);
  C.Ctx.V[VecIdx[0, Reg][0]] := C.Memory.Read32(GPRs(C, Op) + Imm16(Op));
end;

procedure OpSVS(C: TPSPCPU; Op: Cardinal);
begin
  var Reg := ((Op shr 16) and $1F) or ((Op and 3) shl 5);
  C.Memory.Write32(GPRs(C, Op) + Imm16(Op), C.Ctx.V[VecIdx[0, Reg][0]]);
end;

function QuadReg(Op: Cardinal): Cardinal; inline;
begin
  Result := ((Op shr 16) and $1F) or ((Op and 1) shl 5);
end;

procedure OpLVQ(C: TPSPCPU; Op: Cardinal);
begin
  var A := GPRs(C, Op) + Imm16(Op);
  var P: PIdx4 := @VecIdx[3, QuadReg(Op)];
  for var I := 0 to 3 do
    C.Ctx.V[P[I]] := C.Memory.Read32(A + Cardinal(I) * 4);
end;

procedure OpSVQ(C: TPSPCPU; Op: Cardinal);
begin
  var A := GPRs(C, Op) + Imm16(Op);
  var P: PIdx4 := @VecIdx[3, QuadReg(Op)];
  for var I := 0 to 3 do
    C.Memory.Write32(A + Cardinal(I) * 4, C.Ctx.V[P[I]]);
end;

procedure OpLVLRQ(C: TPSPCPU; Op: Cardinal);
begin
  var A := GPRs(C, Op) + Imm16(Op);
  var P: PIdx4 := @VecIdx[3, QuadReg(Op)];
  var K := Integer((A shr 2) and 3);
  if (Op and 2) = 0 then
  begin
    var Base := A and not Cardinal($F);
    for var I := 0 to K do
      C.Ctx.V[P[3 - K + I]] := C.Memory.Read32(Base + Cardinal(I) * 4);
  end
  else
    for var I := 0 to 3 - K do
      C.Ctx.V[P[I]] := C.Memory.Read32(A + Cardinal(I) * 4);
end;

procedure OpSVLRQ(C: TPSPCPU; Op: Cardinal);
begin
  var A := GPRs(C, Op) + Imm16(Op);
  var P: PIdx4 := @VecIdx[3, QuadReg(Op)];
  var K := Integer((A shr 2) and 3);
  if (Op and 2) = 0 then
  begin
    var Base := A and not Cardinal($F);
    for var I := 0 to K do
      C.Memory.Write32(Base + Cardinal(I) * 4, C.Ctx.V[P[3 - K + I]]);
  end
  else
    for var I := 0 to 3 - K do
      C.Memory.Write32(A + Cardinal(I) * 4, C.Ctx.V[P[I]]);
end;

{ COP2 moves and branches }

// mfvc right behind a vcmp still reads the CC from before it.
procedure OpMFV(C: TPSPCPU; Op: Cardinal);
begin
  var T := (Op shr 16) and 31;
  if T = 0 then
    Exit;
  if (Op and $80) = 0 then
    C.Ctx.GPR[T] := C.Ctx.V[VecIdx[0, Op and $7F][0]]
  else if ((Op and $7F) = VFPU_CC) and (C.CurPC = C.VcmpPC + 4) then
    C.Ctx.GPR[T] := C.VcmpOld
  else
    C.Ctx.GPR[T] := ReadCtrl(C, Op and $7F);
end;

// A CC written with mtvc reaches the branch unit a few instructions later,
// unless a vcmp right before it holds the pipeline.
procedure OpMTV(C: TPSPCPU; Op: Cardinal);
begin
  var V := C.Ctx.GPR[(Op shr 16) and 31];
  if (Op and $80) = 0 then
    C.Ctx.V[VecIdx[0, Op and $7F][0]] := V
  else
  begin
    if (Op and $7F) = VFPU_CC then
    begin
      if C.CurPC = C.VcmpPC + 4 then
        C.VccWritePC := 0
      else
      begin
        C.VccWritePC := C.CurPC;
        C.VccWriteOld := C.Ctx.VC[VFPU_CC];
      end;
    end;
    WriteCtrl(C, Op and $7F, V);
  end;
end;

procedure OpBVC(C: TPSPCPU; Op: Cardinal);
begin
  var CC := C.Ctx.VC[VFPU_CC];
  if (C.VccWritePC <> 0) and (C.CurPC - C.VccWritePC <= 12) then
    CC := C.VccWriteOld;
  var Bit := ((CC shr ((Op shr 18) and 7)) and 1) <> 0;
  var Kind := (Op shr 16) and 3;
  var Taken := Bit = ((Kind and 1) <> 0);
  if Taken then
    C.Ctx.NPC := C.CurPC + 4 + (Cardinal(Integer(SmallInt(Word(Op)))) shl 2)
  else if (Kind and 2) <> 0 then
  begin
    C.Ctx.PC := C.Ctx.NPC;
    C.Ctx.NPC := C.Ctx.NPC + 4;
  end;
end;
