{ COP1 }

// The FPU is IEEE single precision with gradual underflow, the four rounding
// modes of FCR31 and its flags. Each result is first rounded to nearest by the
// host, then corrected for the guest's mode from the sign of the error, which
// is computed exactly in double precision. With FCR31.FS set, results that are
// tiny before rounding become zero; denormal operands are still used.

const
  FCR31_FS = 1 shl 24;
  FCR31_WRITABLE = $0181FFFF;
  FX_I = 1;
  FX_U = 2;
  FX_O = 4;
  FX_Z = 8;
  FX_V = 16;
  FPU_NAN = $7FC00000;
  FLT_MIN_D: Double = 1.1754943508222875E-38;

function FS(Op: Cardinal): Cardinal; inline;
begin
  Result := (Op shr 11) and 31;
end;

function FT(Op: Cardinal): Cardinal; inline;
begin
  Result := (Op shr 16) and 31;
end;

function FD(Op: Cardinal): Cardinal; inline;
begin
  Result := (Op shr 6) and 31;
end;

function F(C: TPSPCPU; Index: Cardinal): Single; inline;
begin
  Result := PSingle(@C.Ctx.FPR[Index])^;
end;

function BitsOf(X: Single): Cardinal; inline;
begin
  Result := PCardinal(@X)^;
end;

function IsNaNBits(X: Cardinal): Boolean; inline;
begin
  Result := (X and $7FFFFFFF) > $7F800000;
end;

function IsInfBits(X: Cardinal): Boolean; inline;
begin
  Result := (X and $7FFFFFFF) = $7F800000;
end;

function IsZeroBits(X: Cardinal): Boolean; inline;
begin
  Result := (X and $7FFFFFFF) = 0;
end;

// A NaN operand comes out quieted, the first one if both are; a signalling one is invalid.
function NaNOut(A, B: Cardinal; var Flags: Cardinal): Cardinal; inline;
begin
  Flags := 0;
  if IsNaNBits(A) then
  begin
    if (A and $400000) = 0 then
      Flags := FX_V;
    Result := A or $400000;
    if IsNaNBits(B) and ((B and $400000) = 0) then
      Flags := FX_V;
  end
  else
  begin
    if (B and $400000) = 0 then
      Flags := FX_V;
    Result := B or $400000;
  end;
end;

procedure FpuDone(C: TPSPCPU; D, Bits, Flags: Cardinal); inline;
begin
  C.Ctx.FPR[D] := Bits;
  C.Ctx.FCR31 := (C.Ctx.FCR31 and not Cardinal($3F000)) or (Flags shl 12) or (Flags shl 2);
end;

function NextUp(R: Cardinal): Cardinal; inline;
begin
  if (R and $80000000) = 0 then
  begin
    if R < $7F800000 then
      Result := R + 1
    else
      Result := R;
  end
  else if R = $80000000 then
    Result := 1
  else
    Result := R - 1;
end;

function NextDown(R: Cardinal): Cardinal; inline;
begin
  if (R and $80000000) <> 0 then
  begin
    if R < $FF800000 then
      Result := R + 1
    else
      Result := R;
  end
  else if R = 0 then
    Result := $80000001
  else
    Result := R - 1;
end;

// R is the nearest single to the exact result; Dir is the sign of exact - R.
function FpuRound(R: Cardinal; Dir: Integer; Mode: Cardinal): Cardinal; inline;
begin
  Result := R;
  if Dir = 0 then
    Exit;
  case Mode of
    1:
      if (((R and $80000000) = 0) and (Dir < 0)) or (((R and $80000000) <> 0) and (Dir > 0)) then
        if (R and $7FFFFFFF) <> 0 then
          Result := R - 1;
    2:
      if Dir > 0 then
        Result := NextUp(R);
    3:
      if Dir < 0 then
        Result := NextDown(R);
  end;
end;

function SignOf(D: Double): Integer; inline;
begin
  if D > 0 then
    Result := 1
  else if D < 0 then
    Result := -1
  else
    Result := 0;
end;

// Flags for a non-flushed result; Nearest is the result before the mode's correction.
function ResultFlags(Nearest, R: Cardinal; Dir: Integer; Tiny: Boolean): Cardinal; inline;
begin
  Result := 0;
  if Dir <> 0 then
  begin
    Result := FX_I;
    if Tiny then
      Result := Result or FX_U;
  end;
  if IsInfBits(Nearest) or IsInfBits(R) then
    Result := Result or FX_O or FX_I;
end;

procedure FpuAdd(C: TPSPCPU; Op: Cardinal; NegB: Cardinal);
begin
  var A := C.Ctx.FPR[FS(Op)];
  var B := C.Ctx.FPR[FT(Op)];
  var D := FD(Op);
  if IsNaNBits(A) or IsNaNBits(B) then
  begin
    var NF: Cardinal;
    var N := NaNOut(A, B, NF);
    FpuDone(C, D, N, NF);
    Exit;
  end;
  B := B xor NegB;
  if IsInfBits(A) or IsInfBits(B) then
  begin
    if IsInfBits(A) and IsInfBits(B) and (((A xor B) and $80000000) <> 0) then
      FpuDone(C, D, FPU_NAN, FX_V)
    else if IsInfBits(A) then
      FpuDone(C, D, A, 0)
    else
      FpuDone(C, D, B, 0);
    Exit;
  end;
  var Mode := C.Ctx.FCR31 and 3;
  var Flush := (C.Ctx.FCR31 and FCR31_FS) <> 0;
  if IsZeroBits(A) or IsZeroBits(B) then
  begin
    // A zero operand passes the other one through untouched.
    if IsZeroBits(A) and IsZeroBits(B) then
    begin
      if (A xor B) and $80000000 = 0 then
        FpuDone(C, D, A, 0)
      else if Mode = 3 then
        FpuDone(C, D, $80000000, 0)
      else
        FpuDone(C, D, 0, 0);
    end
    else if IsZeroBits(A) then
      FpuDone(C, D, B, 0)
    else
      FpuDone(C, D, A, 0);
    Exit;
  end;
  var X: Single := PSingle(@A)^;
  var Y: Single := PSingle(@B)^;
  var RS: Single := X + Y;
  var R := BitsOf(RS);
  var S: Double := Double(X) + Double(Y);
  if (R and $7FFFFFFF) = 0 then
  begin
    if Mode = 3 then
      FpuDone(C, D, $80000000, 0)
    else
      FpuDone(C, D, 0, 0);
    Exit;
  end;
  var Gap := Integer(A and $7F800000) - Integer(B and $7F800000);
  var E := R and $7F800000;
  if (Mode = 0) and (E <> 0) and (E <> $7F800000) then
  begin
    FpuDone(C, D, R, Ord((S <> Double(RS)) or (Abs(Gap) >= (30 shl 23))));
    Exit;
  end;
  var Dir := SignOf(S - Double(RS));
  // With at most 29 exponent bits between operands the double sum is exact.
  // Otherwise the single is the larger operand and the error has the smaller's sign.
  if Dir = 0 then
    if Gap >= (30 shl 23) then
      Dir := 1 - Integer(B shr 31) * 2
    else if Gap <= -(30 shl 23) then
      Dir := 1 - Integer(A shr 31) * 2;
  var Tiny := ((R and $7F800000) = 0) and ((R and $7FFFFF) <> 0);
  if Tiny and Flush then
  begin
    FpuDone(C, D, R and $80000000, FX_U or FX_I);
    Exit;
  end;
  var RN := R;
  R := FpuRound(R, Dir, Mode);
  FpuDone(C, D, R, ResultFlags(RN, R, Dir, Tiny));
end;

procedure OpADDS(C: TPSPCPU; Op: Cardinal);
begin
  FpuAdd(C, Op, 0);
end;

procedure OpSUBS(C: TPSPCPU; Op: Cardinal);
begin
  FpuAdd(C, Op, $80000000);
end;

procedure OpMULS(C: TPSPCPU; Op: Cardinal);
begin
  var A := C.Ctx.FPR[FS(Op)];
  var B := C.Ctx.FPR[FT(Op)];
  var D := FD(Op);
  var Sign := (A xor B) and $80000000;
  if IsNaNBits(A) or IsNaNBits(B) then
  begin
    var NF: Cardinal;
    var N := NaNOut(A, B, NF);
    FpuDone(C, D, N, NF);
    Exit;
  end;
  if IsInfBits(A) or IsInfBits(B) then
  begin
    if IsZeroBits(A) or IsZeroBits(B) then
      FpuDone(C, D, FPU_NAN, FX_V)
    else
      FpuDone(C, D, Sign or $7F800000, 0);
    Exit;
  end;
  if IsZeroBits(A) or IsZeroBits(B) then
  begin
    FpuDone(C, D, Sign, 0);
    Exit;
  end;
  var X: Single := PSingle(@A)^;
  var Y: Single := PSingle(@B)^;
  var P: Double := Double(X) * Double(Y);
  var RS: Single := P;
  var R := BitsOf(RS);
  var E := R and $7F800000;
  if (C.Ctx.FCR31 and 3 = 0) and (E > $00800000) and (E <> $7F800000) then
  begin
    FpuDone(C, D, R, Ord(P <> Double(RS)));
    Exit;
  end;
  var Dir := SignOf(P - Double(RS));
  var Tiny := Abs(P) < FLT_MIN_D;
  if Tiny and ((C.Ctx.FCR31 and FCR31_FS) <> 0) then
  begin
    FpuDone(C, D, Sign, FX_U or FX_I);
    Exit;
  end;
  var RN := R;
  R := FpuRound(R, Dir, C.Ctx.FCR31 and 3);
  FpuDone(C, D, R, ResultFlags(RN, R, Dir, Tiny));
end;

procedure OpDIVS(C: TPSPCPU; Op: Cardinal);
begin
  var A := C.Ctx.FPR[FS(Op)];
  var B := C.Ctx.FPR[FT(Op)];
  var D := FD(Op);
  var Sign := (A xor B) and $80000000;
  if IsNaNBits(A) or IsNaNBits(B) then
  begin
    var NF: Cardinal;
    var N := NaNOut(A, B, NF);
    FpuDone(C, D, N, NF);
    Exit;
  end;
  if IsInfBits(A) then
  begin
    if IsInfBits(B) then
      FpuDone(C, D, FPU_NAN, FX_V)
    else
      FpuDone(C, D, Sign or $7F800000, 0);
    Exit;
  end;
  if IsInfBits(B) then
  begin
    FpuDone(C, D, Sign, 0);
    Exit;
  end;
  if IsZeroBits(B) then
  begin
    if IsZeroBits(A) then
      FpuDone(C, D, FPU_NAN, FX_V)
    else
      FpuDone(C, D, Sign or $7F800000, FX_Z);
    Exit;
  end;
  if IsZeroBits(A) then
  begin
    FpuDone(C, D, Sign, 0);
    Exit;
  end;
  var X: Single := PSingle(@A)^;
  var Y: Single := PSingle(@B)^;
  var RS: Single := X / Y;
  var R := BitsOf(RS);
  var Dir: Integer;
  if IsInfBits(R) then
  begin
    if Sign = 0 then
      Dir := -1
    else
      Dir := 1;
  end
  else
  begin
    var Diff: Double := Double(X) - Double(RS) * Double(Y);
    Dir := SignOf(Diff);
    if Y < 0 then
      Dir := -Dir;
  end;
  var Tiny := Abs(Double(X)) < Abs(Double(Y)) * FLT_MIN_D;
  if Tiny and ((C.Ctx.FCR31 and FCR31_FS) <> 0) then
  begin
    FpuDone(C, D, Sign, FX_U or FX_I);
    Exit;
  end;
  var RN := R;
  R := FpuRound(R, Dir, C.Ctx.FCR31 and 3);
  FpuDone(C, D, R, ResultFlags(RN, R, Dir, Tiny));
end;

procedure OpSQRTS(C: TPSPCPU; Op: Cardinal);
begin
  var A := C.Ctx.FPR[FS(Op)];
  var D := FD(Op);
  if IsNaNBits(A) then
  begin
    var NF: Cardinal;
    var N := NaNOut(A, A, NF);
    FpuDone(C, D, N, NF);
    Exit;
  end;
  if IsZeroBits(A) then
  begin
    FpuDone(C, D, A, 0);
    Exit;
  end;
  if (A and $80000000) <> 0 then
  begin
    FpuDone(C, D, FPU_NAN, FX_V);
    Exit;
  end;
  if A = $7F800000 then
  begin
    FpuDone(C, D, A, 0);
    Exit;
  end;
  var X: Single := PSingle(@A)^;
  var RS: Single := Sqrt(Double(X));
  var Dir := SignOf(Double(X) - Double(RS) * Double(RS));
  var R := FpuRound(BitsOf(RS), Dir, C.Ctx.FCR31 and 3);
  FpuDone(C, D, R, ResultFlags(R, R, Dir, False));
end;

procedure OpABSS(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.FPR[FD(Op)] := C.Ctx.FPR[FS(Op)] and $7FFFFFFF;
end;

procedure OpMOVS(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.FPR[FD(Op)] := C.Ctx.FPR[FS(Op)];
end;

procedure OpNEGS(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.FPR[FD(Op)] := C.Ctx.FPR[FS(Op)] xor $80000000;
end;

// Float to word with the given rounding: 0 nearest even, 1 toward zero,
// 2 toward +inf, 3 toward -inf. NaN and positive overflow give 7FFFFFFF,
// negative overflow 80000000, both invalid.
function FloatToWord(X: Cardinal; Mode: Cardinal; var Flags: Cardinal): Cardinal;
begin
  Flags := 0;
  if IsNaNBits(X) then
  begin
    Flags := FX_V;
    Exit($7FFFFFFF);
  end;
  var Neg := (X and $80000000) <> 0;
  var E := Integer((X shr 23) and $FF);
  var M := UInt64(X and $7FFFFF);
  if E <> 0 then
    M := M or $800000
  else
    E := 1;
  if M = 0 then
    Exit(0);
  // Value = M * 2^(E - 150).
  var K := E - 150;
  var Mag: UInt64;
  if K >= 8 then
    Mag := UInt64(1) shl 32
  else if K >= 0 then
    Mag := M shl K
  else
  begin
    var Rem: UInt64;
    var Half: UInt64;
    if -K >= 40 then
    begin
      Mag := 0;
      Rem := M;
      Half := UInt64(1) shl 39;
    end
    else
    begin
      Mag := M shr (-K);
      Rem := M and ((UInt64(1) shl (-K)) - 1);
      Half := UInt64(1) shl (-K - 1);
    end;
    if Rem <> 0 then
    begin
      Flags := FX_I;
      case Mode of
        0:
          if (Rem > Half) or ((Rem = Half) and ((Mag and 1) <> 0)) then
            Inc(Mag);
        2:
          if not Neg then
            Inc(Mag);
        3:
          if Neg then
            Inc(Mag);
      end;
    end;
  end;
  if Neg then
  begin
    if Mag > UInt64($80000000) then
    begin
      Flags := FX_V;
      Exit($80000000);
    end;
    Result := Cardinal(-Int64(Mag));
  end
  else
  begin
    if Mag > UInt64($7FFFFFFF) then
    begin
      Flags := FX_V;
      Exit($7FFFFFFF);
    end;
    Result := Cardinal(Mag);
  end;
end;

procedure DoToWord(C: TPSPCPU; Op, Mode: Cardinal); inline;
begin
  var Flags: Cardinal;
  var R := FloatToWord(C.Ctx.FPR[FS(Op)], Mode, Flags);
  FpuDone(C, FD(Op), R, Flags);
end;

procedure OpROUNDWS(C: TPSPCPU; Op: Cardinal);
begin
  DoToWord(C, Op, 0);
end;

procedure OpTRUNCWS(C: TPSPCPU; Op: Cardinal);
begin
  DoToWord(C, Op, 1);
end;

procedure OpCEILWS(C: TPSPCPU; Op: Cardinal);
begin
  DoToWord(C, Op, 2);
end;

procedure OpFLOORWS(C: TPSPCPU; Op: Cardinal);
begin
  DoToWord(C, Op, 3);
end;

procedure OpCVTWS(C: TPSPCPU; Op: Cardinal);
begin
  DoToWord(C, Op, C.Ctx.FCR31 and 3);
end;

procedure OpCVTSW(C: TPSPCPU; Op: Cardinal);
begin
  var I := Integer(C.Ctx.FPR[FS(Op)]);
  var RS: Single := I;
  var Dir := SignOf(Double(I) - Double(RS));
  var R := FpuRound(BitsOf(RS), Dir, C.Ctx.FCR31 and 3);
  var Flags: Cardinal := 0;
  if Dir <> 0 then
    Flags := FX_I;
  FpuDone(C, FD(Op), R, Flags);
end;

procedure OpCCOND(C: TPSPCPU; Op: Cardinal);
begin
  var A := C.Ctx.FPR[FS(Op)];
  var B := C.Ctx.FPR[FT(Op)];
  var Cond := Op and 15;
  var R: Boolean;
  var Flags: Cardinal := 0;
  if IsNaNBits(A) or IsNaNBits(B) then
  begin
    R := (Cond and 1) <> 0;
    if (Cond and 8) <> 0 then
      Flags := FX_V;
  end
  else
  begin
    var X: Single := PSingle(@A)^;
    var Y: Single := PSingle(@B)^;
    R := (((Cond and 2) <> 0) and (X = Y)) or (((Cond and 4) <> 0) and (X < Y));
  end;
  // A branch right behind the compare still sees the old condition.
  C.FCmpPC := C.CurPC;
  C.FCmpOld := C.Ctx.FCR31 and FCR31_C;
  var V := C.Ctx.FCR31 and not Cardinal($3F000);
  if R then
    V := V or FCR31_C
  else
    V := V and not FCR31_C;
  C.Ctx.FCR31 := V or (Flags shl 12) or (Flags shl 2);
end;

function FpuCond(C: TPSPCPU): Boolean; inline;
begin
  if C.CurPC = C.FCmpPC + 4 then
    Result := C.FCmpOld <> 0
  else
    Result := (C.Ctx.FCR31 and FCR31_C) <> 0;
end;

procedure OpMFC1(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RT(Op)] := C.Ctx.FPR[FS(Op)];
end;

procedure OpCFC1(C: TPSPCPU; Op: Cardinal);
begin
  case FS(Op) of
    0: C.Ctx.GPR[RT(Op)] := $00003351;
    31: C.Ctx.GPR[RT(Op)] := C.Ctx.FCR31;
  else
    C.Ctx.GPR[RT(Op)] := 0;
  end;
end;

procedure OpMTC1(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.FPR[FS(Op)] := C.Ctx.GPR[RT(Op)];
end;

procedure OpCTC1(C: TPSPCPU; Op: Cardinal);
begin
  if FS(Op) = 31 then
  begin
    C.Ctx.FCR31 := C.Ctx.GPR[RT(Op)] and FCR31_WRITABLE;
    C.FCmpPC := 0;
  end;
end;

procedure OpBC1F(C: TPSPCPU; Op: Cardinal);
begin
  Branch(C, Op, not FpuCond(C));
end;

procedure OpBC1T(C: TPSPCPU; Op: Cardinal);
begin
  Branch(C, Op, FpuCond(C));
end;

procedure OpBC1FL(C: TPSPCPU; Op: Cardinal);
begin
  BranchLikely(C, Op, not FpuCond(C));
end;

procedure OpBC1TL(C: TPSPCPU; Op: Cardinal);
begin
  BranchLikely(C, Op, FpuCond(C));
end;
