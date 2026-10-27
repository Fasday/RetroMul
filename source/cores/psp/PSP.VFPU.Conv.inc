{ Float <-> integer }

// Mode 0 nearest even, 1 toward zero, 2 up, 3 down.
function FloatToInt(X: Cardinal; Scale: Integer; Mode: Integer): Cardinal;
begin
  if (X and $7FFFFFFF) > $7F800000 then
    Exit($7FFFFFFF);
  var E := Integer((X shr 23) and $FF);
  if E = 0 then
    Exit(0);
  var Neg := (X and $80000000) <> 0;
  var K := E - 150 + Scale;
  var Mag: UInt64;
  if K >= 8 then
    Mag := UInt64(1) shl 32
  else
  begin
    var M := UInt64((X and $7FFFFF) or $800000);
    if K >= 0 then
      Mag := M shl K
    else if K <= -26 then
    begin
      // Below one half: only rounding away from zero can make it 1.
      Mag := 0;
      if ((Mode = 2) and not Neg) or ((Mode = 3) and Neg) then
        Mag := 1;
    end
    else
    begin
      var Sh := -K;
      Mag := M shr Sh;
      var Rem := M and ((UInt64(1) shl Sh) - 1);
      var Half := UInt64(1) shl (Sh - 1);
      case Mode of
        0:
          if (Rem > Half) or ((Rem = Half) and ((Mag and 1) <> 0)) then
            Inc(Mag);
        2:
          if (Rem <> 0) and not Neg then
            Inc(Mag);
        3:
          if (Rem <> 0) and Neg then
            Inc(Mag);
      end;
    end;
  end;
  if Neg then
  begin
    if Mag >= UInt64($80000000) then
      Exit($80000000);
    Result := Cardinal(-Int64(Mag));
  end
  else
  begin
    if Mag >= UInt64($80000000) then
      Exit($7FFFFFFF);
    Result := Cardinal(Mag);
  end;
end;

procedure DoF2I(C: TPSPCPU; Op: Cardinal; Mode: Integer);
begin
  var N := VSz(Op);
  var S, D: TV4;
  var Z := ReadS(C, Op, N, S);
  var Scale := Integer((Op shr 16) and 31);
  for var I := 0 to N - 1 do
    D[I] := FloatToInt(S[I], Scale, Mode);
  WriteD(C, Op, N, D, Z);
  EatPfx(C);
end;

procedure OpVF2IN(C: TPSPCPU; Op: Cardinal);
begin
  DoF2I(C, Op, 0);
end;

procedure OpVF2IZ(C: TPSPCPU; Op: Cardinal);
begin
  DoF2I(C, Op, 1);
end;

procedure OpVF2IU(C: TPSPCPU; Op: Cardinal);
begin
  DoF2I(C, Op, 2);
end;

procedure OpVF2ID(C: TPSPCPU; Op: Cardinal);
begin
  DoF2I(C, Op, 3);
end;

procedure OpVI2F(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  var Z := ReadS(C, Op, N, S);
  var Scale := Integer((Op shr 16) and 31);
  for var I := 0 to N - 1 do
  begin
    var F: Single := Double(Integer(S[I])) * Power(2.0, -Scale);
    D[I] := VFlush(SingleToBits(F));
  end;
  WriteD(C, Op, N, D, Z);
  EatPfx(C);
end;

{ Half floats }

function FloatToHalf(X: Cardinal): Cardinal;
begin
  var Sign := (X shr 16) and $8000;
  var E := Integer((X shr 23) and $FF);
  var M := X and $7FFFFF;
  if E = $FF then
  begin
    if M <> 0 then
      Exit(Sign or $7C00 or (M and $3FF));
    Exit(Sign or $7C00);
  end;
  var HE := E - 127 + 15;
  if HE >= 31 then
    Exit(Sign or $7C00);
  if HE <= 0 then
    Exit(Sign);
  var HM := M shr 13;
  if (M and $1FFF) > $1000 then
  begin
    Inc(HM);
    if HM = $400 then
    begin
      HM := 0;
      Inc(HE);
      if HE >= 31 then
        Exit(Sign or $7C00);
    end;
  end;
  Result := Sign or (Cardinal(HE) shl 10) or HM;
end;

function HalfToFloat(H: Cardinal): Cardinal;
begin
  var Sign := (H and $8000) shl 16;
  var E := (H shr 10) and 31;
  var M := H and $3FF;
  if E = 31 then
    Result := Sign or $7F800000 or M
  else if E = 0 then
    Result := Sign
  else
    Result := Sign or ((E + 112) shl 23) or (M shl 13);
end;

procedure OpVF2H(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  ReadS(C, Op, N, S);
  var M := N div 2;
  for var I := 0 to M - 1 do
    D[I] := FloatToHalf(S[I * 2]) or (FloatToHalf(S[I * 2 + 1]) shl 16);
  if M > 0 then
    WriteD(C, Op, M, D, 0);
  EatPfx(C);
end;

procedure OpVH2F(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  if N > 2 then
    N := 2;
  var S, D: TV4;
  ReadS(C, Op, N, S);
  for var I := 0 to N - 1 do
  begin
    D[I * 2] := HalfToFloat(S[I] and $FFFF);
    D[I * 2 + 1] := HalfToFloat(S[I] shr 16);
  end;
  WriteD(C, Op, N * 2, D, 0);
  EatPfx(C);
end;

{ Packed integers }

procedure OpVUC2I(C: TPSPCPU; Op: Cardinal);
begin
  var S, D: TV4;
  ReadS(C, Op, 1, S);
  for var I := 0 to 3 do
    D[I] := (((S[0] shr (I * 8)) and $FF) * $01010101) shr 1;
  WriteD(C, Op, 4, D, 0);
  EatPfx(C);
end;

procedure OpVC2I(C: TPSPCPU; Op: Cardinal);
begin
  var S, D: TV4;
  ReadS(C, Op, 1, S);
  for var I := 0 to 3 do
    D[I] := ((S[0] shr (I * 8)) and $FF) shl 24;
  WriteD(C, Op, 4, D, 0);
  EatPfx(C);
end;

procedure OpVUS2I(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  if N > 2 then
    N := 2;
  var S, D: TV4;
  ReadS(C, Op, N, S);
  for var I := 0 to N - 1 do
  begin
    D[I * 2] := (S[I] and $FFFF) shl 15;
    D[I * 2 + 1] := (S[I] shr 16) shl 15;
  end;
  WriteD(C, Op, N * 2, D, 0);
  EatPfx(C);
end;

procedure OpVS2I(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  if N > 2 then
    N := 2;
  var S, D: TV4;
  ReadS(C, Op, N, S);
  for var I := 0 to N - 1 do
  begin
    D[I * 2] := (S[I] and $FFFF) shl 16;
    D[I * 2 + 1] := S[I] and $FFFF0000;
  end;
  WriteD(C, Op, N * 2, D, 0);
  EatPfx(C);
end;

procedure OpVI2UC(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  ReadS(C, Op, N, S);
  var R: Cardinal := 0;
  for var I := 0 to N - 1 do
    if Integer(S[I]) > 0 then
      R := R or (((S[I] shr 23) and $FF) shl (I * 8));
  D[0] := R;
  WriteD(C, Op, 1, D, 0);
  EatPfx(C);
end;

procedure OpVI2C(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  ReadS(C, Op, N, S);
  var R: Cardinal := 0;
  for var I := 0 to N - 1 do
    R := R or ((S[I] shr 24) shl (I * 8));
  D[0] := R;
  WriteD(C, Op, 1, D, 0);
  EatPfx(C);
end;

procedure OpVI2US(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  ReadS(C, Op, N, S);
  var M := N div 2;
  for var I := 0 to M - 1 do
  begin
    var Lo: Cardinal := 0;
    var Hi: Cardinal := 0;
    if Integer(S[I * 2]) > 0 then
      Lo := (S[I * 2] shr 15) and $FFFF;
    if Integer(S[I * 2 + 1]) > 0 then
      Hi := (S[I * 2 + 1] shr 15) and $FFFF;
    D[I] := Lo or (Hi shl 16);
  end;
  if M > 0 then
    WriteD(C, Op, M, D, 0);
  EatPfx(C);
end;

procedure OpVI2S(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S, D: TV4;
  ReadS(C, Op, N, S);
  var M := N div 2;
  for var I := 0 to M - 1 do
    D[I] := (S[I * 2] shr 16) or (S[I * 2 + 1] and $FFFF0000);
  if M > 0 then
    WriteD(C, Op, M, D, 0);
  EatPfx(C);
end;

{ Colours }

function Pack4444(X: Cardinal): Cardinal; inline;
begin
  Result := ((X shr 4) and $F) or ((X shr 8) and $F0) or ((X shr 12) and $F00) or ((X shr 16) and $F000);
end;

function Pack5551(X: Cardinal): Cardinal; inline;
begin
  Result := ((X shr 3) and $1F) or ((X shr 6) and $3E0) or ((X shr 9) and $7C00) or ((X shr 16) and $8000);
end;

function Pack5650(X: Cardinal): Cardinal; inline;
begin
  Result := ((X shr 3) and $1F) or ((X shr 5) and $7E0) or ((X shr 8) and $F800);
end;

procedure DoColor(C: TPSPCPU; Op: Cardinal; Kind: Integer);
begin
  var N := VSz(Op);
  var S, D: TV4;
  ReadS(C, Op, N, S);
  var M := N div 2;
  for var I := 0 to M - 1 do
    case Kind of
      0: D[I] := Pack4444(S[I * 2]) or (Pack4444(S[I * 2 + 1]) shl 16);
      1: D[I] := Pack5551(S[I * 2]) or (Pack5551(S[I * 2 + 1]) shl 16);
    else
      D[I] := Pack5650(S[I * 2]) or (Pack5650(S[I * 2 + 1]) shl 16);
    end;
  if M > 0 then
    WriteD(C, Op, M, D, 0);
  EatPfx(C);
end;

procedure OpVT4444(C: TPSPCPU; Op: Cardinal);
begin
  DoColor(C, Op, 0);
end;

procedure OpVT5551(C: TPSPCPU; Op: Cardinal);
begin
  DoColor(C, Op, 1);
end;

procedure OpVT5650(C: TPSPCPU; Op: Cardinal);
begin
  DoColor(C, Op, 2);
end;

{ Exponent tricks }

procedure OpVSBZ(C: TPSPCPU; Op: Cardinal);
begin
  var S, D: TV4;
  var Z := ReadS(C, Op, 1, S);
  D[0] := (S[0] and $807FFFFF) or $3F800000;
  WriteD(C, Op, 1, D, Z);
  EatPfx(C);
end;

procedure OpVLGB(C: TPSPCPU; Op: Cardinal);
begin
  var S, D: TV4;
  var Z := ReadS(C, Op, 1, S);
  var F: Single := Integer((S[0] shr 23) and $FF) - 127;
  D[0] := SingleToBits(F);
  WriteD(C, Op, 1, D, Z);
  EatPfx(C);
end;

procedure OpVWBN(C: TPSPCPU; Op: Cardinal);
begin
  var S, D: TV4;
  var Z := ReadS(C, Op, 1, S);
  D[0] := (S[0] and $807FFFFF) or (((Op shr 16) and $FF) shl 23);
  WriteD(C, Op, 1, D, Z);
  EatPfx(C);
end;

{ Constants and immediates }

const
  VcstTable: array[0..31] of Cardinal = (
    $00000000, $7F7FFFFF, $3FB504F3, $3F3504F3, $3F906EBB, $3F22F983, $3EA2F983, $3F490FDB,
    $3FC90FDB, $40490FDB, $402DF854, $3FB8AA3B, $3EDE5BD9, $3F317218, $40135D8E, $40C90FDB,
    $3F060A92, $3E9A209B, $40549A78, $3F5DB3D7, $00000000, $00000000, $00000000, $00000000,
    $00000000, $00000000, $00000000, $00000000, $00000000, $00000000, $00000000, $00000000);

procedure OpVCST(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var D: TV4;
  var V := VcstTable[(Op shr 16) and 31];
  for var I := 0 to 3 do
    D[I] := V;
  WriteD(C, Op, N, D, 0);
  EatPfx(C);
end;

procedure OpVIIM(C: TPSPCPU; Op: Cardinal);
begin
  var F: Single := SmallInt(Word(Op));
  C.Ctx.V[VecIdx[0, RegT(Op)][0]] := SingleToBits(F);
end;

procedure OpVFIM(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.V[VecIdx[0, RegT(Op)][0]] := HalfToFloat(Op and $FFFF);
end;

{ Conditional move }

procedure OpVCMOV(C: TPSPCPU; Op: Cardinal);
begin
  var N := VSz(Op);
  var S: TV4;
  var Z := ReadS(C, Op, N, S);
  var Imm := (Op shr 16) and 7;
  var IfFalse := ((Op shr 19) and 1) <> 0;
  var CC := C.Ctx.VC[VFPU_CC];
  var Keep: Cardinal := 0;
  for var I := 0 to N - 1 do
  begin
    var Cond: Boolean;
    if Imm < 6 then
      Cond := ((CC shr Imm) and 1) <> 0
    else if Imm = 6 then
      Cond := ((CC shr I) and 1) <> 0
    else
      Cond := False;
    if Cond = IfFalse then
      Keep := Keep or (Cardinal(1) shl (8 + I));
  end;
  WritePfx(C, RegD(Op), N, S, Z, C.Ctx.VC[VFPU_PFXD] or Keep);
  EatPfx(C);
end;

{ Random numbers }

function RndNext(C: TPSPCPU): Cardinal;
begin
  // Placeholder generator over RCX0..RCX7 until the hardware's is known.
  var X := C.Ctx.VC[VFPU_RCX0] xor (C.Ctx.VC[VFPU_RCX0 + 1] shl 7);
  X := X xor (X shr 9) xor (X shl 13);
  for var I := 7 downto 1 do
    C.Ctx.VC[VFPU_RCX0 + I] := C.Ctx.VC[VFPU_RCX0 + I - 1];
  C.Ctx.VC[VFPU_RCX0] := X;
  Result := X;
end;

procedure OpVRNDS(C: TPSPCPU; Op: Cardinal);
begin
  var Seed := C.Ctx.V[VecIdx[0, RegS(Op)][0]];
  for var I := 0 to 7 do
    C.Ctx.VC[VFPU_RCX0 + I] := $3F800000;
  C.Ctx.VC[VFPU_RCX0] := $3F800000 or (Seed and $FFFF);
  EatPfx(C);
end;

procedure DoRnd(C: TPSPCPU; Op: Cardinal; Kind: Integer);
begin
  var N := VSz(Op);
  var D: TV4;
  for var I := 0 to N - 1 do
  begin
    var X := RndNext(C);
    case Kind of
      0: D[I] := X;
      1: D[I] := $3F800000 or (X and $7FFFFF);
    else
      D[I] := $40000000 or (X and $7FFFFF);
    end;
  end;
  WriteD(C, Op, N, D, 0);
  EatPfx(C);
end;

procedure OpVRNDI(C: TPSPCPU; Op: Cardinal);
begin
  DoRnd(C, Op, 0);
end;

procedure OpVRNDF1(C: TPSPCPU; Op: Cardinal);
begin
  DoRnd(C, Op, 1);
end;

procedure OpVRNDF2(C: TPSPCPU; Op: Cardinal);
begin
  DoRnd(C, Op, 2);
end;

{ Control registers }

function ReadCtrl(C: TPSPCPU; Index: Cardinal): Cardinal; inline;
begin
  if Index < 16 then
    Result := C.Ctx.VC[Index]
  else
    Result := 0;
end;

procedure WriteCtrl(C: TPSPCPU; Index, Value: Cardinal);
begin
  case Index of
    0, 1: C.Ctx.VC[Index] := Value and $FFFFF;
    2: C.Ctx.VC[Index] := Value and $FFF;
    3: C.Ctx.VC[Index] := Value and $3F;
    4..6: C.Ctx.VC[Index] := Value;
    8..15: C.Ctx.VC[Index] := Value;
  end;
end;

procedure OpVMFVC(C: TPSPCPU; Op: Cardinal);
begin
  var D: TV4;
  D[0] := ReadCtrl(C, RegS(Op));
  WriteD(C, Op, 1, D, 0);
  EatPfx(C);
end;

procedure OpVMTVC(C: TPSPCPU; Op: Cardinal);
begin
  WriteCtrl(C, RegD(Op), C.Ctx.V[VecIdx[0, RegS(Op)][0]]);
  EatPfx(C);
end;
