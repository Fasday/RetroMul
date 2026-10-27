{ Blocks: made, linked, dropped, run. }

procedure TPSPRecompiler.EmitShared;
begin
  // The entry (Invoke'd with the CPU, the recompiler, the prologue and the
  // block's code), the prologue (the tables' registers), the way back to
  // Run, and the look-up of a jump's target (in S2) among the blocks.
  var J := FJ;
  J.ForgetLabels;
  J.Align(16);
  FEnter := J.Offset;
  J.EnterJump;
  J.Align(16);
  FPrologue := J.Offset;
  J.Move(jw64, JPages, JImm(Int64(NativeUInt(FMemory.PageTable))));
  J.Move(jw64, JMarks, JImm(Int64(NativeUInt(FMemory.CodeMarks))));
  J.JumpIndirect(JT1);
  J.Align(16);
  FExit := J.Offset;
  J.Leave(JImm(0));
  J.Align(16);
  FLookup := J.Offset;
  var Miss := J.NewLabel;
  J.Move(jw32, JT0, JTarget);
  J.BranchTest(jcNe, jw32, JT0, JImm(3), Miss);
  J.Move(jw32, JT1, JT0);
  J.Alu(jaAnd, jw32, JT1, JImm($1FFFF000));
  J.Shift(jsShr, jw32, jrT1, PSPPageShift - PtrShift);
  J.Move(jw64, JT2, JImm(Int64(NativeUInt(@FPages[0]))));
  J.Alu(jaAdd, jw64, JT1, JT2);
  J.Move(JPtr, JT1, JMem(jrT1, 0));
  J.BranchTest(jcEq, JPtr, JT1, JT1, Miss);
  J.Move(jw32, JT2, JT0);
  J.Alu(jaAnd, jw32, JT2, JImm(PSPPageMask and not 3));
  if PtrShift > 2 then
    J.Shift(jsShl, jw32, jrT2, PtrShift - 2);
  J.Alu(jaAdd, jw64, JT1, JT2);
  J.Move(JPtr, JT1, JMem(jrT1, 0));
  J.BranchTest(jcEq, JPtr, JT1, JT1, Miss);
  J.Branch(jcNe, jw32, JMem(jrT1, OffBlockPC), JT0, Miss);
  J.Move(JPtr, JT1, JMem(jrT1, OffBlockCode));
  J.BranchTest(jcEq, JPtr, JT1, JT1, Miss);
  J.JumpIndirect(JT1);
  J.Bind(Miss);
  J.Move(jw32, JMem(jrSelf, OffPC), JTarget);
  J.Move(jw32, JT0, JTarget);
  J.Alu(jaAdd, jw32, JT0, JImm(4));
  J.Move(jw32, JMem(jrSelf, OffNPC), JT0);
  J.JumpTo(FExit);
  J.ForgetLabels;
  J.Flush;
end;

function TPSPRecompiler.PageOf(PC: Cardinal): PPSPJitPage;
begin
  var Index := (PC and $1FFFFFFF) shr PSPPageShift;
  Result := FPages[Index];
  if Result = nil then
  begin
    New(Result);
    FillChar(Result^, SizeOf(TPSPJitPage), 0);
    Result.Blocks := TList<PPSPJitBlock>.Create;
    FPages[Index] := Result;
  end;
end;

function TPSPRecompiler.Scan(PC: Cardinal): Integer;
begin
  // A block's instructions from PC: up to a branch and its delay slot (not
  // where the slot is on the next page or is a branch too: the block ends
  // before the branch), an instruction that ends one, the page's end.
  var Words := Integer((PSPPageSize - (PC and PSPPageMask)) div 4);
  var H: Pointer;
  Result := 0;
  while (Result < Words) and (Result < PSPJitMaxBlock) do
  begin
    var K := Classify(FCPU.Decoded(PC + Cardinal(Result) * 4).Op, H);
    if IsBranch(K) then
    begin
      if (Result + 1 >= Words) or (Result + 2 > PSPJitMaxBlock) then
        Exit;
      if IsBranch(Classify(FCPU.Decoded(PC + Cardinal(Result + 1) * 4).Op, H)) then
        Exit;
      Exit(Result + 2);
    end;
    Inc(Result);
    if K = jkEnd then
      Exit;
  end;
end;

function TPSPRecompiler.Lookup(PC: Cardinal): PPSPJitBlock;
begin
  // The block at PC, made (cold) if there is none.
  var P := FPages[(PC and $1FFFFFFF) shr PSPPageShift];
  var Index := (PC and PSPPageMask) shr 2;
  if P <> nil then
  begin
    Result := P.Entries[Index];
    if (Result <> nil) and (Result.PC = PC) then
      Exit;
    if Result <> nil then
      Kill(Result);
  end;
  var Count := Scan(PC);
  P := PageOf(PC);
  New(Result);
  FillChar(Result^, SizeOf(TPSPJitBlock), 0);
  Result.PC := PC;
  Result.Physical := PC and $1FFFFFFF;
  Result.Count := Count;
  if Count = 0 then
    Result.State := bsNone
  else
    Result.State := bsCold;
  P.Entries[Index] := Result;
  P.Blocks.Add(Result);
  FAll.Add(Result);
end;

procedure TPSPRecompiler.Cover(Page: PPSPJitPage; B: PPSPJitBlock);
begin
  var First := Integer((B.Physical and PSPPageMask) shr 2);
  for var W := First to First + B.Count - 1 do
    Page.Covered[W shr 5] := Page.Covered[W shr 5] or (Cardinal(1) shl (W and 31));
end;

procedure TPSPRecompiler.Recover(Page: PPSPJitPage);
begin
  FillChar(Page.Covered, SizeOf(Page.Covered), 0);
  for var B in Page.Blocks do
    if B.State = bsCompiled then
      Cover(Page, B);
end;

procedure TPSPRecompiler.Link(E: PPSPJitExit; B: PPSPJitBlock);
begin
  FJ.Redirect(E.Site, NativeInt(NativeUInt(B.Code) - NativeUInt(FJ.Base)));
  E.Linked := B;
  if B.Incoming = nil then
    B.Incoming := TList<PPSPJitExit>.Create;
  B.Incoming.Add(E);
  Inc(FLinks);
end;

procedure TPSPRecompiler.Kill(B: PPSPJitBlock);
begin
  // B no longer runs: no jumps into it, no look-up finds it.
  if B.State = bsDead then
    Exit;
  if B.State = bsCompiled then
  begin
    if B.Incoming <> nil then
    begin
      for var E in B.Incoming do
        if E.Linked = B then
        begin
          FJ.Redirect(E.Site, E.Stub);
          E.Linked := nil;
        end;
      B.Incoming.Clear;
    end;
    for var E in B.Exits do
      if E.Linked <> nil then
      begin
        if E.Linked.Incoming <> nil then
          E.Linked.Incoming.Remove(E);
        E.Linked := nil;
      end;
    FHit := 1;
    Inc(FKills);
  end;
  var P := FPages[B.Physical shr PSPPageShift];
  var Index := (B.Physical and PSPPageMask) shr 2;
  if P.Entries[Index] = B then
    P.Entries[Index] := nil;
  P.Blocks.Remove(B);
  B.State := bsDead;
  B.Code := nil;
  Inc(FDead);
end;

procedure TPSPRecompiler.KillAll;
begin
  for var P in FPages do
    if P <> nil then
    begin
      for var I := P.Blocks.Count - 1 downto 0 do
        Kill(P.Blocks[I]);
      FillChar(P.Covered, SizeOf(P.Covered), 0);
    end;
end;

procedure TPSPRecompiler.ResetCode;
begin
  // All blocks and their code dropped (never while code runs).
  for var B in FAll do
  begin
    B.Incoming.Free;
    Dispose(B);
  end;
  FAll.Clear;
  for var E in FAllExits do
    Dispose(E);
  FAllExits.Clear;
  for var I := 0 to High(FPages) do
    if FPages[I] <> nil then
    begin
      FPages[I].Blocks.Free;
      Dispose(FPages[I]);
      FPages[I] := nil;
    end;
  FResetPending := False;
  FDead := 0;
  if FJ <> nil then
  begin
    FJ.Reset;
    EmitShared;
    Inc(FResets);
  end;
end;

procedure TPSPRecompiler.CodeWritten(Address, Size: Cardinal);
begin
  // Blocks with a word in the range are dropped (FHit: the code running
  // stops after its store).
  if Size = 0 then
    Exit;
  var First := Address and $1FFFFFFF and not Cardinal(3);
  var Last := UInt64(Address and $1FFFFFFF) + Size - 1;
  if Last > $1FFFFFFF then
    Last := $1FFFFFFF;
  for var Page := First shr PSPPageShift to Cardinal(Last shr PSPPageShift) do
  begin
    var P := FPages[Page];
    if (P = nil) or (P.Blocks.Count = 0) then
      Continue;
    var Lo := 0;
    if Page = First shr PSPPageShift then
      Lo := Integer((First and PSPPageMask) shr 2);
    var Hi := PSPPageSize div 4 - 1;
    if Page = Cardinal(Last shr PSPPageShift) then
      Hi := Integer((Cardinal(Last) and PSPPageMask) shr 2);
    var Any := False;
    for var W := Lo to Hi do
      if (P.Covered[W shr 5] and (Cardinal(1) shl (W and 31))) <> 0 then
      begin
        Any := True;
        Break;
      end;
    if not Any then
      Continue;
    for var I := P.Blocks.Count - 1 downto 0 do
    begin
      var B := P.Blocks[I];
      var BFirst := Integer((B.Physical and PSPPageMask) shr 2);
      if (B.State = bsCompiled) and (BFirst <= Hi) and (BFirst + B.Count - 1 >= Lo) then
        Kill(B);
    end;
    Recover(P);
  end;
end;

procedure TPSPRecompiler.Flushed;
begin
  if FInCode or FInRun then
  begin
    KillAll;
    FResetPending := True;
  end
  else
    ResetCode;
end;

procedure TPSPRecompiler.Compile(B: PPSPJitBlock);
var
  Ops: array[0..PSPJitMaxBlock - 1] of Cardinal;
  Kinds: array[0..PSPJitMaxBlock - 1] of TJitKind;
  Handlers: array[0..PSPJitMaxBlock - 1] of Pointer;
  J: TJitAsm;

  procedure Cond(K: TJitKind; Op, A: Cardinal; Taken: TJitLabel);
  begin
    // To Taken where the branch is taken (its registers as before its slot).
    var S := G(FieldRS(Op));
    case K of
      jkBEQ, jkBEQL, jkBNE, jkBNEL:
        begin
          J.Move(jw32, JT0, S);
          if K in [jkBEQ, jkBEQL] then
            J.Branch(jcEq, jw32, JT0, G(FieldRT(Op)), Taken)
          else
            J.Branch(jcNe, jw32, JT0, G(FieldRT(Op)), Taken);
        end;
      jkBLEZ, jkBLEZL:
        J.Branch(jcLe, jw32, S, JImm(0), Taken);
      jkBGTZ, jkBGTZL:
        J.Branch(jcGt, jw32, S, JImm(0), Taken);
      jkBLTZ, jkBLTZL:
        J.Branch(jcLt, jw32, S, JImm(0), Taken);
      jkBGEZ, jkBGEZL:
        J.Branch(jcGe, jw32, S, JImm(0), Taken);
      jkBLTZAL, jkBLTZALL, jkBGEZAL, jkBGEZALL:
        begin
          J.Move(jw32, JT0, S);
          J.Move(jw32, G(31), JImm(Cardinal(A + 8)));
          if K in [jkBLTZAL, jkBLTZALL] then
            J.Branch(jcLt, jw32, JT0, JImm(0), Taken)
          else
            J.Branch(jcGe, jw32, JT0, JImm(0), Taken);
        end;
    end;
  end;

  procedure EmitBranch(I: Integer; A: Cardinal);
  begin
    // The branch at A (step I), its slot (step I + 1) on each way.
    var Op := Ops[I];
    var K := Kinds[I];
    var DOp := Ops[I + 1];
    var DK := Ord(Kinds[I + 1]);
    var DH := Handlers[I + 1];
    var Slot := A + 4;
    var Taken := Cardinal(A + 4 + Cardinal(FieldSImm(Op) * 4));
    var Fall := Cardinal(A + 8);
    case K of
      jkJ, jkJAL:
        begin
          Taken := ((A + 4) and $F0000000) or ((Op and $03FFFFFF) shl 2);
          if K = jkJAL then
            J.Move(jw32, G(31), JImm(Fall));
          EmitDelay(Slot, DOp, DK, DH, False, Taken);
        end;
      jkB:
        EmitDelay(Slot, DOp, DK, DH, False, Taken);
      jkJR, jkJALR:
        begin
          J.Move(jw32, JTarget, G(FieldRS(Op)));
          if (K = jkJALR) and (FieldRD(Op) <> 0) then
            J.Move(jw32, G(FieldRD(Op)), JImm(Fall));
          EmitDelay(Slot, DOp, DK, DH, True, 0);
        end;
      jkHBranch:
        begin
          // Its handler as the interpreter runs it; then where it left PC
          // and NPC: PC moved on (a likely branch not taken), or the slot
          // and NPC the next PC.
          var At: TPSPJitAt;
          At.Addr := A;
          At.Next := Slot;
          At.Dynamic := False;
          At.Refund := 1;
          WriteState(At);
          J.Call(Handlers[I], [JSelf, JImm(Op)]);
          var Nullified := J.NewLabel;
          J.Branch(jcNe, jw32, JMem(jrSelf, OffPC), JImm(Slot), Nullified);
          J.Move(jw32, JTarget, JMem(jrSelf, OffNPC));
          var Other := J.NewLabel;
          J.Branch(jcNe, jw32, JTarget, JImm(Taken), Other);
          EmitDelay(Slot, DOp, DK, DH, False, Taken);
          J.Bind(Other);
          EmitDelay(Slot, DOp, DK, DH, True, 0);
          J.Bind(Nullified);
          J.Alu(jaAdd, jw32, JMem(jrSelf, OffRemaining), JImm(1));
          J.JumpTo(FExit);
        end;
    else
      begin
        var L := J.NewLabel;
        Cond(K, Op, A, L);
        if IsLikely(K) then
          EmitStatic(Fall, A, 1)
        else
          EmitDelay(Slot, DOp, DK, DH, False, Fall);
        J.Bind(L);
        EmitDelay(Slot, DOp, DK, DH, False, Taken);
      end;
    end;
  end;

begin
  // B's code (the room for it there).
  var Count := Scan(B.PC);
  B.Count := Count;
  if Count = 0 then
  begin
    B.State := bsNone;
    Exit;
  end;
  for var I := 0 to Count - 1 do
  begin
    Ops[I] := FCPU.Decoded(B.PC + Cardinal(I) * 4).Op;
    Kinds[I] := Classify(Ops[I], Handlers[I]);
  end;
  J := FJ;
  FBlock := B;
  FSlow.Clear;
  FHitExits.Clear;
  FStatic.Clear;
  J.ForgetLabels;
  J.Align(16);
  var Code := J.Here;
  var NoBudget := J.NewLabel;
  J.Branch(jcLt, jw32, JMem(jrSelf, OffRemaining), JImm(Count), NoBudget);
  J.Alu(jaSub, jw32, JMem(jrSelf, OffRemaining), JImm(Count));
  var Branchy := (Count >= 2) and IsBranch(Kinds[Count - 2]);
  var Body := Count;
  if Branchy then
    Body := Count - 2;
  var Ended := False;
  for var I := 0 to Body - 1 do
  begin
    var At: TPSPJitAt;
    At.Addr := B.PC + Cardinal(I) * 4;
    At.Next := At.Addr + 4;
    At.Dynamic := False;
    At.Refund := Count - I - 1;
    if EmitInstr(At, Ops[I], Ord(Kinds[I]), Handlers[I]) then
    begin
      Ended := True;
      Break;
    end;
  end;
  if Branchy then
    EmitBranch(Count - 2, B.PC + Cardinal(Count - 2) * 4)
  else if not Ended then
    EmitStatic(B.PC + Cardinal(Count) * 4, B.PC + Cardinal(Count - 1) * 4, 0);

  // Out of line: too few cycles left, the accesses' slow ways, the ways out
  // after a store that dropped a block, the stubs of the ends.
  J.Bind(NoBudget);
  J.Move(jw32, JMem(jrSelf, OffPC), JImm(B.PC));
  J.Move(jw32, JMem(jrSelf, OffNPC), JImm(Cardinal(B.PC + 4)));
  J.JumpTo(FExit);
  for var S in FSlow do
  begin
    J.Bind(S.Slow);
    if S.Store then
    begin
      J.Move(jw32, JT5, S.Reg);
      J.Call(S.Routine, [JCtx, JT0, JT5]);
      J.BranchTest(jcNe, jw32, JT0, JT0, S.Hit);
    end
    else
      J.Call(S.Routine, [JImm(Int64(NativeUInt(FMemory))), JT0]);
    J.Jump(S.Back);
  end;
  for var H in FHitExits do
  begin
    J.Bind(H.L);
    WriteState(H.At);
    if H.At.Refund <> 0 then
      J.Alu(jaAdd, jw32, JMem(jrSelf, OffRemaining), JImm(H.At.Refund));
    J.JumpTo(FExit);
  end;
  for var E in FStatic do
  begin
    E.Stub := J.Offset;
    J.Move(jw32, JMem(jrSelf, OffPC), JImm(E.Target));
    J.Move(jw32, JMem(jrSelf, OffNPC), JImm(Cardinal(E.Target + 4)));
    J.Move(jw64, JT0, JImm(Int64(NativeUInt(E))));
    J.Move(JPtr, JMem(jrCtx, OffLastExit), JT0);
    J.JumpTo(FExit);
  end;
  J.ForgetLabels;
  J.Flush;
  for var E in FStatic do
    J.Redirect(E.Site, E.Stub);
  B.Code := Code;
  B.State := bsCompiled;
  Cover(FPages[B.Physical shr PSPPageShift], B);
  Inc(FCompiled);
  // Into blocks there already.
  for var E in FStatic do
  begin
    var P := FPages[(E.Target and $1FFFFFFF) shr PSPPageShift];
    if P = nil then
      Continue;
    var T := P.Entries[(E.Target and PSPPageMask) shr 2];
    if (T <> nil) and (T.PC = E.Target) and (T.State = bsCompiled) then
      Link(E, T);
  end;
end;

procedure TPSPRecompiler.Execute(B: PPSPJitBlock);
begin
  FHit := 0;
  FLastExit := nil;
  FInCode := True;
  Inc(FInvokes);
  try
    FJ.Invoke(FJ.Base + FEnter, NativeUInt(FCPU), NativeUInt(Self), NativeUInt(FJ.Base + FPrologue), NativeUInt(B.Code));
  finally
    FInCode := False;
  end;
end;

procedure TPSPRecompiler.Interpret(Steps: Integer);
begin
  // The interpreter's loop (TPSPCPU.Run), Steps instructions at most.
  var C := FCPU;
  while (C.FRemaining > 0) and (Steps > 0) do
  begin
    var PC := C.Ctx.PC;
    var Entry := C.Decoded(PC);
    C.CurPC := PC;
    C.Ctx.PC := C.Ctx.NPC;
    C.Ctx.NPC := C.Ctx.NPC + 4;
    Dec(C.FRemaining);
    Inc(FInterpreted);
    Entry.Handler(C, Entry.Op);
    if C.Stopping then
      Break;
    Dec(Steps);
  end;
end;

procedure TPSPRecompiler.Run(C: TPSPCPU);
begin
  if not FEnabled then
  begin
    Interpret(MaxInt);
    Exit;
  end;
  if FResetPending then
    ResetCode;
  FInRun := True;
  try
    RunBlocks(C);
  finally
    FInRun := False;
  end;
end;

procedure TPSPRecompiler.RunBlocks(C: TPSPCPU);
begin
  // The exit the code left by last (to link once its target is code).
  var Pending: PPSPJitExit := nil;
  while C.FRemaining > 0 do
  begin
    // (Dropped blocks' records and code are freed all at once.)
    if FResetPending or (FDead > MaxDead) then
    begin
      ResetCode;
      Pending := nil;
    end;
    var PC := C.Ctx.PC;
    if (C.Ctx.NPC = PC + 4) and ((PC and 3) = 0) then
    begin
      var B := Lookup(PC);
      if B.State = bsCold then
      begin
        Inc(B.Heat);
        if B.Heat >= PSPJitHot then
        begin
          if not FJ.Room(8192 + B.Count * 1536) then
          begin
            ResetCode;
            Pending := nil;
            B := Lookup(PC);
          end;
          Compile(B);
        end;
      end;
      if B.State = bsCompiled then
      begin
        if B.Count > C.FRemaining then
        begin
          // The budget ends within it.
          Interpret(MaxInt);
          Break;
        end;
        if (Pending <> nil) and (Pending.Target = PC) and (Pending.Linked = nil) and
          (Pending.Block.State = bsCompiled) then
          Link(Pending, B);
        Execute(B);
        Pending := FLastExit;
        if C.Stopping then
          Break;
        Continue;
      end;
      Pending := nil;
      if B.State = bsCold then
      begin
        // Its instructions by the interpreter while they follow on.
        var Expected := PC;
        for var K := 1 to B.Count do
        begin
          if C.Ctx.PC <> Expected then
            Break;
          Interpret(1);
          if C.Stopping or (C.FRemaining <= 0) then
            Break;
          Inc(Expected, 4);
        end;
        if C.Stopping then
          Break;
        Continue;
      end;
    end
    else
      Pending := nil;
    Interpret(1);
    if C.Stopping then
      Break;
  end;
end;

procedure TPSPRecompiler.SetEnabled(Value: Boolean);
begin
  FEnabled := Value and (FJ <> nil);
end;

constructor TPSPRecompiler.Create(CPU: TPSPCPU; Options: TPSPJitOptions);
begin
  inherited Create;
  PrepareKinds;
  FCPU := CPU;
  FMemory := CPU.Memory;
  FOptions := Options;
  SetLength(FPages, PSPPageCount);
  FAll := TList<PPSPJitBlock>.Create;
  FAllExits := TList<PPSPJitExit>.Create;
  FSlow := TList<TPSPJitSlow>.Create;
  FHitExits := TList<TPSPJitHitExit>.Create;
  FStatic := TList<PPSPJitExit>.Create;
  if joModel in Options then
    FJ := CreateJitModel(JitBufferSize)
  else
    FJ := CreateJitAsm(JitBufferSize);
  FEnabled := FJ <> nil;
  if FJ <> nil then
    EmitShared;
  CPU.Runner := Self;
end;

destructor TPSPRecompiler.Destroy;
begin
  if (FCPU <> nil) and (FCPU.Runner = Self) then
    FCPU.Runner := nil;
  if (joStats in FOptions) and IsConsole then
    Writeln(ErrOutput, Format('PSP JIT: %d blocks compiled, %d runs of code, %d instructions interpreted, ' +
      '%d links, %d blocks dropped, %d resets', [FCompiled, FInvokes, FInterpreted, FLinks, FKills, FResets]));
  FInCode := False;
  ResetCode;
  FAll.Free;
  FAllExits.Free;
  FSlow.Free;
  FHitExits.Free;
  FStatic.Free;
  FJ.Free;
  inherited;
end;

function PSPJitOptions(out Off: Boolean): TPSPJitOptions;
begin
  Result := [];
  Off := False;
  for var S in GetEnvironmentVariable('PSPJIT').ToLower.Split([',', ' ', ';']) do
    if S = 'off' then
      Off := True
    else if S = 'model' then
      Include(Result, joModel)
    else if S = 'stats' then
      Include(Result, joStats);
end;

function CreatePSPRecompiler(CPU: TPSPCPU): TPSPRecompiler;
begin
  var Off: Boolean;
  var Options := PSPJitOptions(Off);
  if Off or (not JitSupported and not (joModel in Options)) then
    Exit(nil);
  Result := TPSPRecompiler.Create(CPU, Options);
  if Result.FJ = nil then
    FreeAndNil(Result);
end;
