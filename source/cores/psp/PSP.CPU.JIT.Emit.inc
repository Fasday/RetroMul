{ Writing a block's code. Registers: Self the CPU, Ctx the recompiler, S0
  the memory's page table, S1 its code marks, S2 a jump's target (JR, JALR, a
  handler's branch) across its delay slot. }

function G(R: Cardinal): TJitOp; inline;
begin
  Result := JMem(jrSelf, OffGPR + Integer(R) * 4);
end;

function FieldRS(Op: Cardinal): Cardinal; inline;
begin
  Result := (Op shr 21) and 31;
end;

function FieldRT(Op: Cardinal): Cardinal; inline;
begin
  Result := (Op shr 16) and 31;
end;

function FieldRD(Op: Cardinal): Cardinal; inline;
begin
  Result := (Op shr 11) and 31;
end;

function FieldSA(Op: Cardinal): Cardinal; inline;
begin
  Result := (Op shr 6) and 31;
end;

function FieldSImm(Op: Cardinal): Integer; inline;
begin
  Result := SmallInt(Word(Op));
end;

procedure TPSPRecompiler.WriteState(const At: TPSPJitAt);
begin
  // PC, NPC and CurPC as the interpreter has them while (and after) it runs
  // the instruction.
  if At.Dynamic then
  begin
    FJ.Move(jw32, JMem(jrSelf, OffPC), JTarget);
    FJ.Move(jw32, JT0, JTarget);
    FJ.Alu(jaAdd, jw32, JT0, JImm(4));
    FJ.Move(jw32, JMem(jrSelf, OffNPC), JT0);
  end
  else
  begin
    FJ.Move(jw32, JMem(jrSelf, OffPC), JImm(At.Next));
    FJ.Move(jw32, JMem(jrSelf, OffNPC), JImm(Cardinal(At.Next + 4)));
  end;
  FJ.Move(jw32, JMem(jrSelf, OffCurPC), JImm(At.Addr));
end;

function TPSPRecompiler.HitExit(const At: TPSPJitAt): TJitLabel;
begin
  var H: TPSPJitHitExit;
  H.L := FJ.NewLabel;
  H.At := At;
  FHitExits.Add(H);
  Result := H.L;
end;

procedure TPSPRecompiler.EmitCall(const At: TPSPJitAt; Op: Cardinal; Handler: Pointer);
begin
  WriteState(At);
  FJ.Call(Handler, [JSelf, JImm(Op)]);
  if MayStore(Op) then
    FJ.BranchTest(jcNe, jw8, JMem(jrCtx, OffHit), JImm($FF), HitExit(At));
end;

procedure TPSPRecompiler.EmitLoad(Op: Cardinal; Kind: Integer);
begin
  // As TPSPMemory.ReadN: the page's host memory at the address's offset
  // (aligned or not), else the routine (no page).
  var J := FJ;
  var K := TJitKind(Kind);
  var S: TPSPJitSlow;
  S.Slow := J.NewLabel;
  S.Back := J.NewLabel;
  S.Store := False;
  S.Rt := FieldRT(Op);
  S.Hit := -1;
  case K of
    jkLB, jkLBU: S.Routine := @JitRead8;
    jkLH, jkLHU: S.Routine := @JitRead16;
  else
    S.Routine := @JitRead32;
  end;
  J.Move(jw32, JT0, G(FieldRS(Op)));
  if FieldSImm(Op) <> 0 then
    J.Alu(jaAdd, jw32, JT0, JImm(FieldSImm(Op)));
  J.Move(jw32, JT1, JT0);
  J.Alu(jaAnd, jw32, JT1, JImm($1FFFF000));
  J.Shift(jsShr, jw32, jrT1, 9);
  J.Alu(jaAdd, jw64, JT1, JPages);
  J.Move(jw64, JT1, JMem(jrT1, 0));
  J.BranchTest(jcEq, jw64, JT1, JT1, S.Slow);
  J.Move(jw32, JT2, JT0);
  J.Alu(jaAnd, jw32, JT2, JImm(PSPPageMask));
  J.Alu(jaAdd, jw64, JT1, JT2);
  case K of
    jkLB, jkLBU:
      J.Move(jw8, JT0, JMem(jrT1, 0));
    jkLH, jkLHU:
      begin
        J.Move(jw8, JT0, JMem(jrT1, 0));
        J.Move(jw8, JT2, JMem(jrT1, 1));
        J.Shift(jsShl, jw32, jrT2, 8);
        J.Alu(jaOr, jw32, JT0, JT2);
      end;
  else
    J.Move(jw32, JT0, JMem(jrT1, 0));
  end;
  J.Bind(S.Back);
  case K of
    jkLB:
      J.SignExtend(jw8, jrT0);
    jkLH:
      begin
        J.Shift(jsShl, jw32, jrT0, 16);
        J.Shift(jsSar, jw32, jrT0, 16);
      end;
  end;
  J.Move(jw32, G(S.Rt), JT0);
  FSlow.Add(S);
end;

procedure TPSPRecompiler.EmitStore(const At: TPSPJitAt; Op: Cardinal; Kind: Integer);
begin
  // As TPSPMemory.WriteN where the page is not code: its host memory; else
  // the routine (which re-decodes, and the block may have to stop).
  var J := FJ;
  var K := TJitKind(Kind);
  var S: TPSPJitSlow;
  S.Slow := J.NewLabel;
  S.Back := J.NewLabel;
  S.Store := True;
  S.Rt := FieldRT(Op);
  S.Hit := HitExit(At);
  case K of
    jkSB: S.Routine := @JitWrite8;
    jkSH: S.Routine := @JitWrite16;
  else
    S.Routine := @JitWrite32;
  end;
  J.Move(jw32, JT0, G(FieldRS(Op)));
  if FieldSImm(Op) <> 0 then
    J.Alu(jaAdd, jw32, JT0, JImm(FieldSImm(Op)));
  J.Move(jw32, JT1, JT0);
  J.Alu(jaAnd, jw32, JT1, JImm($1FFFF000));
  J.Shift(jsShr, jw32, jrT1, PSPPageShift);
  J.Move(jw64, JT2, JT1);
  J.Alu(jaAdd, jw64, JT2, JMarks);
  J.Move(jw8, JT2, JMem(jrT2, 0));
  J.BranchTest(jcNe, jw32, JT2, JT2, S.Slow);
  J.Shift(jsShl, jw32, jrT1, 3);
  J.Alu(jaAdd, jw64, JT1, JPages);
  J.Move(jw64, JT1, JMem(jrT1, 0));
  J.BranchTest(jcEq, jw64, JT1, JT1, S.Slow);
  J.Move(jw32, JT2, JT0);
  J.Alu(jaAnd, jw32, JT2, JImm(PSPPageMask));
  J.Alu(jaAdd, jw64, JT1, JT2);
  J.Move(jw32, JT2, G(S.Rt));
  case K of
    jkSB:
      J.Move(jw8, JMem(jrT1, 0), JT2);
    jkSH:
      begin
        J.Move(jw8, JMem(jrT1, 0), JT2);
        J.Shift(jsShr, jw32, jrT2, 8);
        J.Move(jw8, JMem(jrT1, 1), JT2);
      end;
  else
    J.Move(jw32, JMem(jrT1, 0), JT2);
  end;
  J.Bind(S.Back);
  FSlow.Add(S);
end;

function TPSPRecompiler.EmitInstr(const At: TPSPJitAt; Op: Cardinal; Kind: Integer; Handler: Pointer): Boolean;
var
  J: TJitAsm;

  // GPR[D] := GPR[S] op GPR[T].
  procedure Three(A: TJitAlu);
  begin
    J.Move(jw32, JT0, G(FieldRS(Op)));
    J.Alu(A, jw32, JT0, G(FieldRT(Op)));
    J.Move(jw32, G(FieldRD(Op)), JT0);
  end;

  // GPR[T] := GPR[S] op a constant.
  procedure WithImm(A: TJitAlu; Value: Int64);
  begin
    if FieldRS(Op) = FieldRT(Op) then
      J.Alu(A, jw32, G(FieldRT(Op)), JImm(Value))
    else
    begin
      J.Move(jw32, JT0, G(FieldRS(Op)));
      J.Alu(A, jw32, JT0, JImm(Value));
      J.Move(jw32, G(FieldRT(Op)), JT0);
    end;
  end;

  // R := Ord(GPR[S] Cond B).
  procedure SetIf(Cond: TJitCond; const B: TJitOp; R: Cardinal);
  begin
    var L := J.NewLabel;
    J.Move(jw32, JT1, G(FieldRS(Op)));
    J.Move(jw32, JT0, JImm(1));
    J.Branch(Cond, jw32, JT1, B, L);
    J.Move(jw32, JT0, JImm(0));
    J.Bind(L);
    J.Move(jw32, G(R), JT0);
  end;

  // GPR[D] := GPR[T] shifted.
  procedure ShiftBy(S: TJitShift);
  begin
    J.Move(jw32, JT0, G(FieldRT(Op)));
    if FieldSA(Op) <> 0 then
      J.Shift(S, jw32, jrT0, FieldSA(Op));
    J.Move(jw32, G(FieldRD(Op)), JT0);
  end;

  // GPR[D] := GPR[S] where GPR[T] meets Cond with 0.
  procedure MoveIf(Skip: TJitCond);
  begin
    var L := J.NewLabel;
    J.Branch(Skip, jw32, G(FieldRT(Op)), JImm(0), L);
    J.Move(jw32, JT0, G(FieldRS(Op)));
    J.Move(jw32, G(FieldRD(Op)), JT0);
    J.Bind(L);
  end;

  // GPR[D] := the larger (Keep jcGt) or smaller (jcLt) of GPR[S], GPR[T].
  procedure Pick(Keep: TJitCond);
  begin
    var L := J.NewLabel;
    J.Move(jw32, JT0, G(FieldRS(Op)));
    J.Branch(Keep, jw32, JT0, G(FieldRT(Op)), L);
    J.Move(jw32, JT0, G(FieldRT(Op)));
    J.Bind(L);
    J.Move(jw32, G(FieldRD(Op)), JT0);
  end;

  procedure Copy(const Dst, Src: TJitOp);
  begin
    J.Move(jw32, JT0, Src);
    J.Move(jw32, Dst, JT0);
  end;

begin
  // One instruction (not a branch) as its handler does it; True: it ended
  // the block (its handler calls the kernel or raises), the code leaves.
  J := FJ;
  Result := False;
  case TJitKind(Kind) of
    jkNop:
      ;
    jkEnd:
      begin
        WriteState(At);
        J.Call(Handler, [JSelf, JImm(Op)]);
        J.JumpTo(FExit);
        Result := True;
      end;
    jkHandler:
      EmitCall(At, Op, Handler);
    jkSLL:
      ShiftBy(jsShl);
    jkSRL:
      ShiftBy(jsShr);
    jkSRA:
      ShiftBy(jsSar);
    jkROTR:
      begin
        var S := FieldSA(Op);
        if S = 0 then
          Copy(G(FieldRD(Op)), G(FieldRT(Op)))
        else
        begin
          J.Move(jw32, JT0, G(FieldRT(Op)));
          J.Move(jw32, JT1, JT0);
          J.Shift(jsShr, jw32, jrT0, S);
          J.Shift(jsShl, jw32, jrT1, 32 - S);
          J.Alu(jaOr, jw32, JT0, JT1);
          J.Move(jw32, G(FieldRD(Op)), JT0);
        end;
      end;
    jkMOVZ:
      MoveIf(jcNe);
    jkMOVN:
      MoveIf(jcEq);
    jkMFHI:
      Copy(G(FieldRD(Op)), JMem(jrSelf, OffHI));
    jkMTHI:
      Copy(JMem(jrSelf, OffHI), G(FieldRS(Op)));
    jkMFLO:
      Copy(G(FieldRD(Op)), JMem(jrSelf, OffLO));
    jkMTLO:
      Copy(JMem(jrSelf, OffLO), G(FieldRS(Op)));
    jkADDU:
      Three(jaAdd);
    jkSUBU:
      Three(jaSub);
    jkAND:
      Three(jaAnd);
    jkOR:
      Three(jaOr);
    jkXOR:
      Three(jaXor);
    jkNOR:
      begin
        J.Move(jw32, JT0, G(FieldRS(Op)));
        J.Alu(jaOr, jw32, JT0, G(FieldRT(Op)));
        J.Alu(jaXor, jw32, JT0, JImm(-1));
        J.Move(jw32, G(FieldRD(Op)), JT0);
      end;
    jkSLT:
      SetIf(jcLt, G(FieldRT(Op)), FieldRD(Op));
    jkSLTU:
      SetIf(jcBelow, G(FieldRT(Op)), FieldRD(Op));
    jkMAX:
      Pick(jcGt);
    jkMIN:
      Pick(jcLt);
    jkADDIU:
      WithImm(jaAdd, FieldSImm(Op));
    jkSLTI:
      SetIf(jcLt, JImm(FieldSImm(Op)), FieldRT(Op));
    jkSLTIU:
      SetIf(jcBelow, JImm(FieldSImm(Op)), FieldRT(Op));
    jkANDI:
      WithImm(jaAnd, Op and $FFFF);
    jkORI:
      WithImm(jaOr, Op and $FFFF);
    jkXORI:
      WithImm(jaXor, Op and $FFFF);
    jkLUI:
      J.Move(jw32, G(FieldRT(Op)), JImm(Cardinal(Op shl 16)));
    jkMFC0:
      J.Move(jw32, G(FieldRT(Op)), JImm(0));
    jkEXT:
      begin
        var Pos := FieldSA(Op);
        var Size := FieldRD(Op) + 1;
        J.Move(jw32, JT0, G(FieldRS(Op)));
        if Pos <> 0 then
          J.Shift(jsShr, jw32, jrT0, Pos);
        if Size < 32 then
          J.Alu(jaAnd, jw32, JT0, JImm((Cardinal(1) shl Size) - 1));
        J.Move(jw32, G(FieldRT(Op)), JT0);
      end;
    jkINS:
      begin
        var Lsb := FieldSA(Op);
        var Msb := FieldRD(Op);
        if Msb >= Lsb then
        begin
          var Size := Msb - Lsb + 1;
          var Mask: Cardinal;
          if Size >= 32 then
            Mask := $FFFFFFFF
          else
            Mask := ((Cardinal(1) shl Size) - 1) shl Lsb;
          J.Move(jw32, JT0, G(FieldRS(Op)));
          if Lsb <> 0 then
            J.Shift(jsShl, jw32, jrT0, Lsb);
          J.Alu(jaAnd, jw32, JT0, JImm(Mask));
          J.Move(jw32, JT1, G(FieldRT(Op)));
          J.Alu(jaAnd, jw32, JT1, JImm(not Mask));
          J.Alu(jaOr, jw32, JT0, JT1);
          J.Move(jw32, G(FieldRT(Op)), JT0);
        end;
      end;
    jkWSBH:
      begin
        J.Move(jw32, JT0, G(FieldRT(Op)));
        J.Move(jw32, JT1, JT0);
        J.Alu(jaAnd, jw32, JT0, JImm($00FF00FF));
        J.Shift(jsShl, jw32, jrT0, 8);
        J.Alu(jaAnd, jw32, JT1, JImm($FF00FF00));
        J.Shift(jsShr, jw32, jrT1, 8);
        J.Alu(jaOr, jw32, JT0, JT1);
        J.Move(jw32, G(FieldRD(Op)), JT0);
      end;
    jkWSBW:
      begin
        J.Move(jw32, JT1, G(FieldRT(Op)));
        J.Move(jw32, JT0, JT1);
        J.Shift(jsShl, jw32, jrT0, 24);
        J.Move(jw32, JT2, JT1);
        J.Alu(jaAnd, jw32, JT2, JImm($FF00));
        J.Shift(jsShl, jw32, jrT2, 8);
        J.Alu(jaOr, jw32, JT0, JT2);
        J.Move(jw32, JT2, JT1);
        J.Shift(jsShr, jw32, jrT2, 8);
        J.Alu(jaAnd, jw32, JT2, JImm($FF00));
        J.Alu(jaOr, jw32, JT0, JT2);
        J.Shift(jsShr, jw32, jrT1, 24);
        J.Alu(jaOr, jw32, JT0, JT1);
        J.Move(jw32, G(FieldRD(Op)), JT0);
      end;
    jkSEB:
      begin
        J.Move(jw32, JT0, G(FieldRT(Op)));
        J.SignExtend(jw8, jrT0);
        J.Move(jw32, G(FieldRD(Op)), JT0);
      end;
    jkSEH:
      begin
        J.Move(jw32, JT0, G(FieldRT(Op)));
        J.Shift(jsShl, jw32, jrT0, 16);
        J.Shift(jsSar, jw32, jrT0, 16);
        J.Move(jw32, G(FieldRD(Op)), JT0);
      end;
    jkLB, jkLH, jkLW, jkLBU, jkLHU:
      EmitLoad(Op, Kind);
    jkSB, jkSH, jkSW:
      EmitStore(At, Op, Kind);
  else
    raise EInvalidOpException.Create('PSP JIT: a branch as an instruction');
  end;
end;

procedure TPSPRecompiler.EmitStatic(Target, Last: Cardinal; Refund: Integer);
begin
  // The block's end towards Target (Last the instruction that ran last): a
  // jump that goes to its stub until linked.
  if Refund <> 0 then
    FJ.Alu(jaAdd, jw32, JMem(jrSelf, OffRemaining), JImm(Refund));
  FJ.Move(jw32, JMem(jrSelf, OffCurPC), JImm(Last));
  var E: PPSPJitExit;
  New(E);
  E.Block := FBlock;
  E.Target := Target;
  E.Site := FJ.JumpSite(FExit);
  E.Stub := -1;
  E.Linked := nil;
  FStatic.Add(E);
  FAllExits.Add(E);
  FBlock.Exits := FBlock.Exits + [E];
end;

procedure TPSPRecompiler.EmitDelay(A: Cardinal; Op: Cardinal; Kind: Integer; Handler: Pointer; Dynamic: Boolean;
  Next: Cardinal);
begin
  // A branch's delay slot at A, then the block's end towards Next (or the
  // Target register).
  var At: TPSPJitAt;
  At.Addr := A;
  At.Next := Next;
  At.Dynamic := Dynamic;
  At.Refund := 0;
  if EmitInstr(At, Op, Kind, Handler) then
    Exit;
  if Dynamic then
  begin
    FJ.Move(jw32, JMem(jrSelf, OffCurPC), JImm(A));
    FJ.JumpTo(FLookup);
  end
  else
    EmitStatic(Next, A, 0);
end;
