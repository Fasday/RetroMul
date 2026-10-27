{ Element-wise arithmetic }

procedure DoBinary(C: TPSPCPU; Op: Cardinal; Fn: TBinFn);
begin
  var N := VSz(Op);
  var S, T, D: TV4;
  var Z := ReadS(C, Op, N, S) or ReadT(C, Op, N, T);
  for var I := 0 to N - 1 do
    D[I] := Fn(S[I], T[I]);
  WriteD(C, Op, N, D, Z);
  EatPfx(C);
end;

function FnMin(A, B: Cardinal): Cardinal;
begin
  if VKey(A) < VKey(B) then
    Result := A
  else
    Result := B;
end;

function FnMax(A, B: Cardinal): Cardinal;
begin
  if VKey(A) > VKey(B) then
    Result := A
  else
    Result := B;
end;

function FnSge(A, B: Cardinal): Cardinal;
begin
  if not VIsNaN(A) and not VIsNaN(B) and (VKey(A) >= VKey(B)) then
    Result := VF_ONE
  else
    Result := 0;
end;

function FnSlt(A, B: Cardinal): Cardinal;
begin
  if not VIsNaN(A) and not VIsNaN(B) and (VKey(A) < VKey(B)) then
    Result := VF_ONE
  else
    Result := 0;
end;

function FnScmp(A, B: Cardinal): Cardinal;
begin
  var KA := VKey(A);
  var KB := VKey(B);
  if KA > KB then
    Result := VF_ONE
  else if KA < KB then
    Result := $BF800000
  else
    Result := 0;
end;

function FnSbn(A, B: Cardinal): Cardinal;
begin
  Result := (A and $807FFFFF) or ((Cardinal(127 + Integer(B)) and $FF) shl 23);
end;

procedure OpVADD(C: TPSPCPU; Op: Cardinal);
begin
  DoBinary(C, Op, VAdd);
end;

procedure OpVSUB(C: TPSPCPU; Op: Cardinal);
begin
  DoBinary(C, Op, VSub);
end;

procedure OpVMUL(C: TPSPCPU; Op: Cardinal);
begin
  DoBinary(C, Op, VMul);
end;

procedure OpVMIN(C: TPSPCPU; Op: Cardinal);
begin
  DoBinary(C, Op, FnMin);
end;

procedure OpVMAX(C: TPSPCPU; Op: Cardinal);
begin
  DoBinary(C, Op, FnMax);
end;

procedure OpVSGE(C: TPSPCPU; Op: Cardinal);
begin
  DoBinary(C, Op, FnSge);
end;

procedure OpVSLT(C: TPSPCPU; Op: Cardinal);
begin
  DoBinary(C, Op, FnSlt);
end;

procedure OpVSCMP(C: TPSPCPU; Op: Cardinal);
begin
  DoBinary(C, Op, FnScmp);
end;

procedure OpVSBN(C: TPSPCPU; Op: Cardinal);
begin
  DoBinary(C, Op, FnSbn);
end;

procedure OpVDIV(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, T, D: TV4;
  LoadV(C, RegS(Op), N, S);
  LoadV(C, RegT(Op), N, T);
  for var I := 0 to N - 2 do
    D[I] := VDiv(S[I], T[I]);
  var Zero := False;
  var A := LastIn(C.Ctx.VC[VFPU_PFXS], S[N - 1], Zero);
  var B := LastIn(C.Ctx.VC[VFPU_PFXT], T[N - 1], Zero);
  D[N - 1] := VDiv(A, B);
  WriteLast(C, RegD(Op), N, D, Zero);
  EatPfx(C);
end;

procedure OpVSCL(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, T, Raw, D: TV4;
  var Z := ReadS(C, Op, N, S);
  LoadV(C, RegT(Op), 1, Raw);
  Z := Z or ApplyPfx(Raw, 1, C.Ctx.VC[VFPU_PFXT] and not Cardinal($FF), T);
  for var I := 0 to N - 1 do
    D[I] := VMul(S[I], T[I]);
  WriteD(C, Op, N, D, Z);
  EatPfx(C);
end;

procedure OpVCRS(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, T, D: TV4;
  var Z := ReadPfx(C, RegS(Op), N, (C.Ctx.VC[VFPU_PFXS] and not Cardinal($3F)) or $09, S) or
    ReadPfx(C, RegT(Op), N, (C.Ctx.VC[VFPU_PFXT] and not Cardinal($3F)) or $12, T);
  for var I := 0 to N - 1 do
    D[I] := VMul(S[I], T[I]);
  WriteD(C, Op, N, D, Z);
  EatPfx(C);
end;

{ Sums of products }

procedure OpVDOT(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, T, D: TV4;
  var Z := ReadS(C, Op, N, S) or ReadT(C, Op, N, T);
  D[0] := VSum4(S, T, 4, Z);
  WriteD(C, Op, 1, D, 0);
  EatPfx(C);
end;

procedure OpVHDP(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, T, D: TV4;
  var ZS := ReadS(C, Op, N, S);
  var ZT := ReadT(C, Op, N, T);
  S[N - 1] := VF_ONE;
  ZS := ZS and not (Cardinal(1) shl (N - 1));
  D[0] := VSum4(S, T, 4, ZS or ZT);
  WriteD(C, Op, 1, D, 0);
  EatPfx(C);
end;

procedure OpVDET(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, T, D: TV4;
  var Z := ReadPfx(C, RegS(Op), N, C.Ctx.VC[VFPU_PFXS] xor $20000, S) or
    ReadPfx(C, RegT(Op), N, (C.Ctx.VC[VFPU_PFXT] and not Cardinal($F)) or $1, T);
  D[0] := VSum4(S, T, 4, Z);
  WriteD(C, Op, 1, D, 0);
  EatPfx(C);
end;

procedure OpVFAD(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  var Z := ReadS(C, Op, N, S);
  D[0] := VSum4(S, Ones, 4, Z);
  WriteD(C, Op, 1, D, 0);
  EatPfx(C);
end;

procedure OpVAVG(C: TPSPCPU; Op: Cardinal);
const
  Counts: array[1..4] of Cardinal = ($3F800000, $40000000, $40400000, $40800000);
begin
  var N := VSz(Op);
  var S, D: TV4;
  var Z := ReadS(C, Op, N, S);
  D[0] := VDiv(VSum4(S, Ones, 4, Z), Counts[N]);
  WriteD(C, Op, 1, D, 0);
  EatPfx(C);
end;

{ Compare }

function CmpTest(Cond, A, B: Cardinal): Boolean;
begin
  A := VFlush(A);
  B := VFlush(B);
  case Cond of
    0: Result := False;
    1: Result := not VIsNaN(A) and not VIsNaN(B) and (VKey(A) = VKey(B));
    2: Result := not VIsNaN(A) and not VIsNaN(B) and (VKey(A) < VKey(B));
    3: Result := not VIsNaN(A) and not VIsNaN(B) and (VKey(A) <= VKey(B));
    4: Result := True;
    5: Result := VIsNaN(A) or VIsNaN(B) or (VKey(A) <> VKey(B));
    6: Result := not VIsNaN(A) and not VIsNaN(B) and (VKey(A) >= VKey(B));
    7: Result := not VIsNaN(A) and not VIsNaN(B) and (VKey(A) > VKey(B));
    8: Result := (A and $7FFFFFFF) = 0;
    9: Result := VIsNaN(A);
    10: Result := (A and $7FFFFFFF) = $7F800000;
    11: Result := (A and $7F800000) = $7F800000;
    12: Result := (A and $7FFFFFFF) <> 0;
    13: Result := not VIsNaN(A);
    14: Result := (A and $7FFFFFFF) <> $7F800000;
  else
    Result := (A and $7F800000) <> $7F800000;
  end;
end;

procedure OpVCMP(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, T: TV4;
  ReadS(C, Op, N, S);
  ReadT(C, Op, N, T);
  var Cond := Op and 15;
  var Bits: Cardinal := 0;
  for var I := 0 to N - 1 do
    if CmpTest(Cond, S[I], T[I]) then
      Bits := Bits or (Cardinal(1) shl I);
  var All := (Cardinal(1) shl N) - 1;
  if Bits <> 0 then
    Bits := Bits or $10;
  if (Bits and All) = All then
    Bits := Bits or $20;
  C.Ctx.VC[VFPU_CC] := Bits;
  EatPfx(C);
end;

{ Moves }

procedure DoMove(C: TPSPCPU; Op, SPfx, DPfx: Cardinal);
begin
  var N := VSz(Op);
  var S: TV4;
  var Z := ReadPfx(C, RegS(Op), N, SPfx, S);
  WritePfx(C, RegD(Op), N, S, Z, DPfx);
  EatPfx(C);
end;

procedure OpVMOV(C: TPSPCPU; Op: Cardinal);
begin
  DoMove(C, Op, C.Ctx.VC[VFPU_PFXS], C.Ctx.VC[VFPU_PFXD]);
end;

procedure OpVABS(C: TPSPCPU; Op: Cardinal);
begin
  DoMove(C, Op, C.Ctx.VC[VFPU_PFXS] or $F00, C.Ctx.VC[VFPU_PFXD]);
end;

procedure OpVNEG(C: TPSPCPU; Op: Cardinal);
begin
  DoMove(C, Op, C.Ctx.VC[VFPU_PFXS] or $F0000, C.Ctx.VC[VFPU_PFXD]);
end;

procedure OpVSAT0(C: TPSPCPU; Op: Cardinal);
begin
  DoMove(C, Op, C.Ctx.VC[VFPU_PFXS], (C.Ctx.VC[VFPU_PFXD] and $F00) or $55);
end;

procedure OpVSAT1(C: TPSPCPU; Op: Cardinal);
begin
  DoMove(C, Op, C.Ctx.VC[VFPU_PFXS], (C.Ctx.VC[VFPU_PFXD] and $F00) or $FF);
end;

procedure DoConst(C: TPSPCPU; Op: Cardinal; const V: TV4);
begin
  var N := VSz(Op);
  var D: TV4;
  var P := C.Ctx.VC[VFPU_PFXS];
  for var I := 0 to 3 do
    if ((P shr (16 + I)) and 1) <> 0 then
      D[I] := V[I] xor $80000000
    else
      D[I] := V[I];
  WriteD(C, Op, N, D, 0);
  EatPfx(C);
end;

procedure OpVZERO(C: TPSPCPU; Op: Cardinal);
const
  Z: TV4 = (0, 0, 0, 0);
begin
  DoConst(C, Op, Z);
end;

procedure OpVONE(C: TPSPCPU; Op: Cardinal);
begin
  DoConst(C, Op, Ones);
end;

procedure OpVIDT(C: TPSPCPU; Op: Cardinal);
begin
  var V: TV4 := Default(TV4);
  var K: Cardinal;
  if VSz(Op) = 2 then
    K := RegD(Op) and 1
  else
    K := RegD(Op) and 3;
  V[K] := VF_ONE;
  DoConst(C, Op, V);
end;

{ Function unit }

procedure DoFunc(C: TPSPCPU; Op: Cardinal; Fn: TUnFn);
begin
  var N := VSz(Op);
  var S, D: TV4;
  LoadV(C, RegS(Op), N, S);
  for var I := 0 to N - 2 do
    D[I] := Fn(S[I]);
  var Zero := False;
  var A := LastIn(C.Ctx.VC[VFPU_PFXS], S[N - 1], Zero);
  D[N - 1] := Fn(A);
  WriteLast(C, RegD(Op), N, D, Zero);
  EatPfx(C);
end;

procedure OpVRCP(C: TPSPCPU; Op: Cardinal);
begin
  DoFunc(C, Op, VRcp);
end;

procedure OpVRSQ(C: TPSPCPU; Op: Cardinal);
begin
  DoFunc(C, Op, VRsq);
end;

procedure OpVSIN(C: TPSPCPU; Op: Cardinal);
begin
  DoFunc(C, Op, VSin);
end;

procedure OpVCOS(C: TPSPCPU; Op: Cardinal);
begin
  DoFunc(C, Op, VCos);
end;

procedure OpVEXP2(C: TPSPCPU; Op: Cardinal);
begin
  DoFunc(C, Op, VExp2);
end;

procedure OpVLOG2(C: TPSPCPU; Op: Cardinal);
begin
  DoFunc(C, Op, VLog2);
end;

procedure OpVSQRT(C: TPSPCPU; Op: Cardinal);
begin
  DoFunc(C, Op, VSqrt);
end;

procedure OpVASIN(C: TPSPCPU; Op: Cardinal);
begin
  DoFunc(C, Op, VAsin);
end;

procedure OpVNRCP(C: TPSPCPU; Op: Cardinal);
begin
  DoFunc(C, Op, VNRcp);
end;

procedure OpVNSIN(C: TPSPCPU; Op: Cardinal);
begin
  DoFunc(C, Op, VNSin);
end;

procedure OpVREXP2(C: TPSPCPU; Op: Cardinal);
begin
  DoFunc(C, Op, VRExp2);
end;

{ Lane shuffles }

procedure OpVBFY1(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  var Z := ReadS(C, Op, N, S);
  D[0] := VAdd(S[0], S[1]);
  D[1] := VSub(S[0], S[1]);
  D[2] := VAdd(S[2], S[3]);
  D[3] := VSub(S[2], S[3]);
  WriteD(C, Op, N, D, Z);
  EatPfx(C);
end;

procedure OpVBFY2(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  var Z := ReadS(C, Op, N, S);
  D[0] := VAdd(S[0], S[2]);
  D[1] := VAdd(S[1], S[3]);
  D[2] := VSub(S[0], S[2]);
  D[3] := VSub(S[1], S[3]);
  WriteD(C, Op, N, D, Z);
  EatPfx(C);
end;

function SortMin(A, B: Cardinal): Cardinal; inline;
begin
  if VKey(A) <= VKey(B) then
    Result := A
  else
    Result := B;
end;

function SortMax(A, B: Cardinal): Cardinal; inline;
begin
  if VKey(A) >= VKey(B) then
    Result := A
  else
    Result := B;
end;

procedure OpVSRT1(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  var Z := ReadS(C, Op, N, S);
  D[0] := SortMin(S[0], S[1]);
  D[1] := SortMax(S[0], S[1]);
  D[2] := SortMin(S[2], S[3]);
  D[3] := SortMax(S[2], S[3]);
  WriteD(C, Op, N, D, Z);
  EatPfx(C);
end;

procedure OpVSRT2(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  var Z := ReadS(C, Op, N, S);
  D[0] := SortMin(S[0], S[3]);
  D[1] := SortMin(S[1], S[2]);
  D[2] := SortMax(S[1], S[2]);
  D[3] := SortMax(S[0], S[3]);
  WriteD(C, Op, N, D, Z);
  EatPfx(C);
end;

procedure OpVSRT3(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  var Z := ReadS(C, Op, N, S);
  D[0] := SortMax(S[1], S[0]);
  D[1] := SortMin(S[1], S[0]);
  D[2] := SortMax(S[3], S[2]);
  D[3] := SortMin(S[3], S[2]);
  WriteD(C, Op, N, D, Z);
  EatPfx(C);
end;

procedure OpVSRT4(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  var Z := ReadS(C, Op, N, S);
  D[0] := SortMax(S[3], S[0]);
  D[1] := SortMax(S[2], S[1]);
  D[2] := SortMin(S[2], S[1]);
  D[3] := SortMin(S[3], S[0]);
  WriteD(C, Op, N, D, Z);
  EatPfx(C);
end;

procedure OpVOCP(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  var Z := ReadPfx(C, RegS(Op), N, C.Ctx.VC[VFPU_PFXS] or $F0000, S);
  for var I := 0 to N - 1 do
    D[I] := VAdd(S[I], VF_ONE);
  WriteD(C, Op, N, D, Z);
  EatPfx(C);
end;

procedure OpVSOCP(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  ReadS(C, Op, N, S);
  var M := N * 2;
  if M > 4 then
    M := 4;
  for var I := 0 to (M div 2) - 1 do
  begin
    D[I * 2] := VSat0(VSub(VF_ONE, S[I]));
    D[I * 2 + 1] := VSat0(VAdd(S[I], 0));
  end;
  WriteD(C, Op, M, D, 0);
  EatPfx(C);
end;

procedure OpVSGN(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  var Z := ReadS(C, Op, N, S);
  for var I := 0 to N - 1 do
  begin
    var K := VKey(S[I]);
    if K > 0 then
      D[I] := VF_ONE
    else if K < 0 then
      D[I] := $BF800000
    else
      D[I] := 0;
  end;
  WriteD(C, Op, N, D, Z);
  EatPfx(C);
end;
