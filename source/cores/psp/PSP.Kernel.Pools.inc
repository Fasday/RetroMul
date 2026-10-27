{ PSP.Kernel: variable and fixed pools, thread-local storage pools. }

type
  // The pool's bookkeeping lives at the start of its memory, as the kernel
  // keeps it: +0 start, +4 start, +8 start + 7, +12 size - 8, +16 units in
  // use, +20 rover (a free block), +24 first block. Blocks are 8-byte units
  // with an 8-byte header (next, units); free blocks form a ring in address
  // order with a zero-sized block at the top that never merges. A used
  // block's next points at +8.
  TPSPVpl = class(TPSPWaitObject)
  public
    PartitionId: Integer;
    Block, Size, PoolSize: Cardinal;
    class function IdType: Integer; override;
    procedure Init;
    // Returns the user address, 0 when nothing fits.
    function Alloc(Bytes: Cardinal): Cardinal;
    function FreeBlock(Addr: Cardinal): Boolean;
    function FreeSize: Cardinal;
    function Retry(T: TPSPThread): Boolean;
    function MayAlloc(T: TPSPThread): Boolean;
    procedure WakeWaiters;
    procedure WaiterGone; override;
  end;

  TPSPFpl = class(TPSPWaitObject)
  public
    PartitionId: Integer;
    Block, BlockSize, Stride: Cardinal;
    Count, Next: Integer;
    Used: TArray<Boolean>;
    class function IdType: Integer; override;
    function Alloc(out Addr: Cardinal): Boolean;
    function FreeCount: Integer;
    function Retry(T: TPSPThread): Boolean;
  end;

  TPSPTlspl = class(TPSPWaitObject)
  public
    PartitionId: Integer;
    Index: Integer;
    Block, BlockSize, Stride: Cardinal;
    Count, Next: Integer;
    Owner: TArray<TPSPThread>;
    class function IdType: Integer; override;
    function Find(T: TPSPThread): Integer;
    function Alloc(T: TPSPThread; out Addr: Cardinal): Boolean;
    function FreeCount: Integer;
    function Retry(T: TPSPThread): Boolean;
    procedure Release(T: TPSPThread);
  end;

const
  PSPErrorUnknownTlsplId = Cardinal($800201D0);
  PSPErrorTlsplFull = Cardinal($800201D1);
  PSPErrorTlsplBusy = Cardinal($800201D2);

{ TPSPVpl }

class function TPSPVpl.IdType: Integer;
begin
  Result := 5;
end;

procedure TPSPVpl.Init;
begin
  var M := Kernel.Memory;
  var B := Block;
  var Top := B + Size - 8;
  M.Write32(B, B);
  M.Write32(B + 4, B);
  M.Write32(B + 8, B + 7);
  M.Write32(B + 12, Size - 8);
  M.Write32(B + 16, 0);
  M.Write32(B + 20, B + 24);
  M.Write32(B + 24, Top);
  M.Write32(B + 28, (Top - (B + 24)) div 8);
  M.Write32(Top, B + 24);
  M.Write32(Top + 4, 0);
end;

function TPSPVpl.Alloc(Bytes: Cardinal): Cardinal;
begin
  var M := Kernel.Memory;
  var Units := (Bytes + 7) div 8 + 1;
  var Prev := M.Read32(Block + 20);
  var Start := Prev;
  var P := M.Read32(Prev);
  for var Guard := 0 to 100000 do
  begin
    var PSize := M.Read32(P + 4);
    if PSize >= Units then
    begin
      if PSize = Units then
        M.Write32(Prev, M.Read32(P))
      else
      begin
        M.Write32(P + 4, PSize - Units);
        P := P + (PSize - Units) * 8;
        M.Write32(P + 4, Units);
      end;
      M.Write32(P, Block + 8);
      M.Write32(Block + 20, Prev);
      M.Write32(Block + 16, M.Read32(Block + 16) + Units);
      Exit(P + 8);
    end;
    if P = Start then
      Break;
    Prev := P;
    P := M.Read32(P);
  end;
  Result := 0;
end;

function TPSPVpl.FreeBlock(Addr: Cardinal): Boolean;
begin
  var M := Kernel.Memory;
  var Bp := Addr - 8;
  if (Addr < Block + 32) or (Addr >= Block + Size) or ((Addr and 7) <> 0) or (M.Read32(Bp) <> Block + 8) then
    Exit(False);
  var BpSize := M.Read32(Bp + 4);
  var Units := BpSize;
  var P := M.Read32(Block + 20);
  for var Guard := 0 to 100000 do
  begin
    var PNext := M.Read32(P);
    if (Bp > P) and (Bp < PNext) then
      Break;
    if (P >= PNext) and ((Bp > P) or (Bp < PNext)) then
      Break;
    P := PNext;
  end;
  var PNext := M.Read32(P);
  if (Bp + BpSize * 8 = PNext) and (M.Read32(PNext + 4) <> 0) then
  begin
    Inc(BpSize, M.Read32(PNext + 4));
    M.Write32(Bp + 4, BpSize);
    M.Write32(Bp, M.Read32(PNext));
  end
  else
    M.Write32(Bp, PNext);
  var PSize := M.Read32(P + 4);
  if P + PSize * 8 = Bp then
  begin
    M.Write32(P + 4, PSize + BpSize);
    M.Write32(P, M.Read32(Bp));
  end
  else
    M.Write32(P, Bp);
  M.Write32(Block + 20, P);
  M.Write32(Block + 16, M.Read32(Block + 16) - Units);
  Result := True;
end;

function TPSPVpl.FreeSize: Cardinal;
begin
  Result := PoolSize - Kernel.Memory.Read32(Block + 16) * 8;
end;

function TPSPVpl.Retry(T: TPSPThread): Boolean;
begin
  if not Kernel.FObjects.ContainsKey(UID) or (T.Wait.Obj <> Self) then
  begin
    T.SetResult(SCE_KERNEL_ERROR_WAIT_DELETE);
    Exit(True);
  end;
  Result := False;
  if (Waiters.Count > 0) and (Waiters.First <> T) and ((Attr and $200) = 0) then
    Exit;
  var A := Alloc(T.Wait.Data[0]);
  if A <> 0 then
  begin
    if T.Wait.Data[1] <> 0 then
      Kernel.Memory.Write32(T.Wait.Data[1], A);
    T.SetResult(0);
    Result := True;
  end;
end;

function TPSPVpl.MayAlloc(T: TPSPThread): Boolean;
begin
  // A newcomer goes first when it would head the queue; with attr $200 the
  // queue does not hold anyone back.
  Result := (Waiters.Count = 0) or ((Attr and $200) <> 0) or
    (Waiters.ByPriority and (T.Priority < Waiters.First.Priority));
end;

procedure TPSPVpl.WakeWaiters;
begin
  // Waiters are served in queue order; normally the first that does not fit
  // stops the rest, with attr $200 the later ones still get their turn.
  var I := 0;
  while I < Waiters.Count do
  begin
    var T := Waiters.Item(I);
    var A := Alloc(T.Wait.Data[0]);
    if A = 0 then
    begin
      if (Attr and $200) = 0 then
        Break;
      Inc(I);
      Continue;
    end;
    if T.Wait.Data[1] <> 0 then
      Kernel.Memory.Write32(T.Wait.Data[1], A);
    Kernel.EndWait(T, 0);
  end;
end;

procedure TPSPVpl.WaiterGone;
begin
  WakeWaiters;
end;

{ TPSPFpl }

class function TPSPFpl.IdType: Integer;
begin
  Result := 6;
end;

function TPSPFpl.Alloc(out Addr: Cardinal): Boolean;
begin
  // The search starts after the block handed out last.
  for var I := 0 to Count - 1 do
  begin
    var N := (Next + I) mod Count;
    if not Used[N] then
    begin
      Used[N] := True;
      Next := (N + 1) mod Count;
      Addr := Block + Cardinal(N) * Stride;
      Exit(True);
    end;
  end;
  Addr := 0;
  Result := False;
end;

function TPSPFpl.FreeCount: Integer;
begin
  Result := 0;
  for var U in Used do
    if not U then
      Inc(Result);
end;

function TPSPFpl.Retry(T: TPSPThread): Boolean;
begin
  if not Kernel.FObjects.ContainsKey(UID) or (T.Wait.Obj <> Self) then
  begin
    T.SetResult(SCE_KERNEL_ERROR_WAIT_DELETE);
    Exit(True);
  end;
  Result := False;
  if (Waiters.Count > 0) and (Waiters.First <> T) then
    Exit;
  var A: Cardinal;
  if Alloc(A) then
  begin
    if T.Wait.Data[0] <> 0 then
      Kernel.Memory.Write32(T.Wait.Data[0], A);
    T.SetResult(0);
    Result := True;
  end;
end;

{ TPSPTlspl }

class function TPSPTlspl.IdType: Integer;
begin
  Result := 14;
end;

function TPSPTlspl.Find(T: TPSPThread): Integer;
begin
  for var I := 0 to Count - 1 do
    if Owner[I] = T then
      Exit(I);
  Result := -1;
end;

function TPSPTlspl.Alloc(T: TPSPThread; out Addr: Cardinal): Boolean;
begin
  for var I := 0 to Count - 1 do
  begin
    var N := (Next + I) mod Count;
    if Owner[N] = nil then
    begin
      Owner[N] := T;
      Next := (N + 1) mod Count;
      Addr := Block + Cardinal(N) * Stride;
      // A block is cleared when a thread gets it and when it gives it back.
      Kernel.Memory.Fill(Addr, 0, BlockSize);
      T.TlsSlots[Index] := Addr;
      Exit(True);
    end;
  end;
  Addr := 0;
  Result := False;
end;

function TPSPTlspl.FreeCount: Integer;
begin
  Result := 0;
  for var O in Owner do
    if O = nil then
      Inc(Result);
end;

function TPSPTlspl.Retry(T: TPSPThread): Boolean;
begin
  if not Kernel.FObjects.ContainsKey(UID) or (T.Wait.Obj <> Self) then
  begin
    T.SetResult(SCE_KERNEL_ERROR_WAIT_DELETE);
    Exit(True);
  end;
  Result := False;
  if (Waiters.Count > 0) and (Waiters.First <> T) then
    Exit;
  var A: Cardinal;
  if Alloc(T, A) then
  begin
    if T.Wait.Data[0] <> 0 then
      Kernel.Memory.Write32(T.Wait.Data[0], A);
    if T.Wait.Data[1] <> 0 then
      T.SetResult(A)
    else
      T.SetResult(0);
    Result := True;
  end;
end;

procedure TPSPTlspl.Release(T: TPSPThread);
begin
  var I := Find(T);
  if I < 0 then
    Exit;
  Owner[I] := nil;
  T.TlsSlots[Index] := 0;
  Kernel.Memory.Fill(Block + Cardinal(I) * Stride, 0, BlockSize);
  while Waiters.Count > 0 do
  begin
    var W := Waiters.First;
    var A: Cardinal;
    if not Alloc(W, A) then
      Break;
    if W.Wait.Data[0] <> 0 then
      Kernel.Memory.Write32(W.Wait.Data[0], A);
    var IsGet := W.Wait.Data[1] <> 0;
    Kernel.EndWait(W, 0);
    if IsGet then
      W.SetResult(A);
  end;
end;

{ Pool memory }

function TPSPKernel.PoolPartition(PartId: Integer): TPSPPartition;
begin
  Result := Partition(PartId);
  if Result = nil then
    Result := FKernelPartition;
end;

{ HLE: variable pools }

procedure TPSPKernel.hCreateVpl;
begin
  var Name: string;
  if not ReadName(FHLE.Arg(0), Name) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ERROR); Exit; end;
  var PartId := FHLE.ArgInt(1);
  var Err := UserPartitionCheck(PartId);
  if Err <> 0 then
    begin FHLE.Result(Err); Exit; end;
  var Attr := FHLE.Arg(2);
  if (Attr and not Cardinal($43FF)) <> 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR); Exit; end;
  var Size := FHLE.Arg(3);
  if Size = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MEMSIZE); Exit; end;
  if Size > $7FFFFFF0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY); Exit; end;
  Size := AlignUp(Size, 8);
  if Size <= $30 then
    Size := $1000;
  var P := PoolPartition(PartId);
  var Block: Cardinal;
  if (Attr and $4000) <> 0 then
    Block := P.Alloc(Size, akHigh, 0, 256, 'vpl:' + Name)
  else
    Block := P.Alloc(Size, akLow, 0, 256, 'vpl:' + Name);
  if Block = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY); Exit; end;
  var V := TPSPVpl.Create;
  V.Name := Name;
  V.Attr := Attr;
  V.PartitionId := PartId;
  V.Block := Block;
  V.Size := Size;
  V.PoolSize := Size - $20;
  V.Waiters.ByPriority := (Attr and $100) <> 0;
  AddObject(V);
  V.Init;
  Spend(PSPSyncCallNs);
  FHLE.Result(V.UID);
end;

procedure TPSPKernel.hDeleteVpl;
begin
  var V := TPSPVpl(GetObject(FHLE.Arg(0), TPSPVpl));
  if V = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VPLID); Exit; end;
  FHLE.Result(0);
  while V.Waiters.Count > 0 do
    EndWait(V.Waiters.First, SCE_KERNEL_ERROR_WAIT_DELETE);
  PoolPartition(V.PartitionId).FreeBlock(V.Block);
  DeleteObject(V);
end;

// Mode: 0 waits, 1 waits with callbacks, 2 does not wait.
procedure TPSPKernel.AllocateVplCommon(Mode: Integer);
begin
  var V := TPSPVpl(GetObject(FHLE.Arg(0), TPSPVpl));
  if V = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VPLID); Exit; end;
  var Bytes := FHLE.Arg(1);
  var OutPtr := FHLE.Arg(2);
  var TimeoutPtr: Cardinal := 0;
  if Mode <> 2 then
    TimeoutPtr := FHLE.Arg(3);
  if (Bytes = 0) or (Bytes > V.PoolSize) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MEMSIZE); Exit; end;
  Spend(PSPSyncCallNs);
  // Trying never minds the queue.
  if (Mode = 2) or V.MayAlloc(FCurrent) then
  begin
    var A := V.Alloc(Bytes);
    if A <> 0 then
    begin
      if OutPtr <> 0 then
        FMemory.Write32(OutPtr, A);
      FHLE.Result(0);
      if Mode = 1 then
        CheckCallbacksNow;
      Exit;
    end;
  end;
  if Mode = 2 then
    begin FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY); Exit; end;
  if not CanWait then
    begin FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT); Exit; end;
  FHLE.Result(0);
  V.Waiters.Add(FCurrent);
  BeginWaitData(PSPWaitVpl, V, V.UID, TimeoutPtr, Mode = 1, V.Retry, [Bytes, OutPtr]);
end;

procedure TPSPKernel.hAllocateVpl;
begin
  AllocateVplCommon(0);
end;

procedure TPSPKernel.hAllocateVplCB;
begin
  AllocateVplCommon(1);
end;

procedure TPSPKernel.hTryAllocateVpl;
begin
  AllocateVplCommon(2);
end;

procedure TPSPKernel.hFreeVpl;
begin
  var Addr := FHLE.Arg(1);
  if (Addr and $80000000) <> 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR); Exit; end;
  var V := TPSPVpl(GetObject(FHLE.Arg(0), TPSPVpl));
  if V = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VPLID); Exit; end;
  if not V.FreeBlock(Addr) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MEMBLOCK); Exit; end;
  Spend(PSPSyncCallNs);
  FHLE.Result(0);
  V.WakeWaiters;
end;

procedure TPSPKernel.hCancelVpl;
begin
  var V := TPSPVpl(GetObject(FHLE.Arg(0), TPSPVpl));
  if V = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VPLID); Exit; end;
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), Cardinal(V.Waiters.Count));
  FHLE.Result(0);
  while V.Waiters.Count > 0 do
    EndWait(V.Waiters.First, SCE_KERNEL_ERROR_WAIT_CANCEL);
end;

procedure TPSPKernel.hReferVplStatus;
begin
  var V := TPSPVpl(GetObject(FHLE.Arg(0), TPSPVpl));
  if V = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VPLID); Exit; end;
  var Buf: array[0..$33] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var N := RawByteString(V.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  PCardinal(@Buf[$24])^ := V.Attr;
  PCardinal(@Buf[$28])^ := V.PoolSize;
  PCardinal(@Buf[$2C])^ := V.FreeSize;
  PCardinal(@Buf[$30])^ := Cardinal(V.Waiters.Count);
  WriteInfo(FHLE.Arg(1), Buf, $34);
  FHLE.Result(0);
end;

{ HLE: fixed pools }

function ValidPoolAlignment(A: Cardinal): Boolean;
begin
  Result := (A = 0) or ((A and (A - 1)) = 0) and (A <= $10000000);
end;

procedure TPSPKernel.hCreateFpl;
begin
  var Name: string;
  if not ReadName(FHLE.Arg(0), Name) then
    begin FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY); Exit; end;
  var PartId := FHLE.ArgInt(1);
  var Err := UserPartitionCheck(PartId);
  if Err <> 0 then
    begin FHLE.Result(Err); Exit; end;
  var Attr := FHLE.Arg(2);
  if (Attr and not Cardinal($41FF)) <> 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR); Exit; end;
  var BlockSize := FHLE.Arg(3);
  var Count := FHLE.Arg(4);
  if (BlockSize = 0) or (Integer(BlockSize) < 0) or (Count = 0) or (Integer(Count) < 0) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MEMSIZE); Exit; end;
  var Align: Cardinal := 4;
  var Opt := FHLE.Arg(5);
  if (Opt <> 0) and (FMemory.Read32(Opt) >= 8) then
  begin
    var A := FMemory.Read32(Opt + 4);
    if not ValidPoolAlignment(A) then
      begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ARGUMENT); Exit; end;
    if A > Align then
      Align := A;
  end;
  var Stride := AlignUp(BlockSize, Align);
  // The size is worked out in 32 bits: one that wraps to nothing is refused.
  var Total := Cardinal(UInt64(Stride) * Count);
  if Total = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MEMSIZE); Exit; end;
  var P := PoolPartition(PartId);
  var Block: Cardinal := 0;
  if UInt64(Stride) * Count <= $7FFFFFFF then
    if (Attr and $4000) <> 0 then
      Block := P.Alloc(Total, akHigh, 0, 256, 'fpl:' + Name)
    else
      Block := P.Alloc(Total, akLow, 0, 256, 'fpl:' + Name);
  if Block = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY); Exit; end;
  var F := TPSPFpl.Create;
  F.Name := Name;
  F.Attr := Attr;
  F.PartitionId := PartId;
  F.Block := Block;
  F.BlockSize := BlockSize;
  F.Stride := Stride;
  F.Count := Integer(Count);
  SetLength(F.Used, Count);
  F.Waiters.ByPriority := (Attr and $100) <> 0;
  Spend(PSPSyncCallNs);
  FHLE.Result(AddObject(F));
end;

procedure TPSPKernel.hDeleteFpl;
begin
  var F := TPSPFpl(GetObject(FHLE.Arg(0), TPSPFpl));
  if F = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_FPLID); Exit; end;
  FHLE.Result(0);
  while F.Waiters.Count > 0 do
    EndWait(F.Waiters.First, SCE_KERNEL_ERROR_WAIT_DELETE);
  PoolPartition(F.PartitionId).FreeBlock(F.Block);
  DeleteObject(F);
end;

procedure TPSPKernel.AllocateFplCommon(Mode: Integer);
begin
  var F := TPSPFpl(GetObject(FHLE.Arg(0), TPSPFpl));
  if F = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_FPLID); Exit; end;
  var OutPtr := FHLE.Arg(1);
  var TimeoutPtr: Cardinal := 0;
  if Mode <> 2 then
    TimeoutPtr := FHLE.Arg(2);
  Spend(PSPSyncCallNs);
  if F.Waiters.Count = 0 then
  begin
    var A: Cardinal;
    if F.Alloc(A) then
    begin
      if OutPtr <> 0 then
        FMemory.Write32(OutPtr, A);
      FHLE.Result(0);
      if Mode = 1 then
        CheckCallbacksNow;
      Exit;
    end;
  end;
  if Mode = 2 then
    begin FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY); Exit; end;
  if not CanWait then
    begin FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT); Exit; end;
  FHLE.Result(0);
  F.Waiters.Add(FCurrent);
  BeginWaitData(PSPWaitFpl, F, F.UID, TimeoutPtr, Mode = 1, F.Retry, [OutPtr]);
end;

procedure TPSPKernel.hAllocateFpl;
begin
  AllocateFplCommon(0);
end;

procedure TPSPKernel.hAllocateFplCB;
begin
  AllocateFplCommon(1);
end;

procedure TPSPKernel.hTryAllocateFpl;
begin
  AllocateFplCommon(2);
end;

procedure TPSPKernel.hFreeFpl;
begin
  var Addr := FHLE.Arg(1);
  if (Addr and $80000000) <> 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR); Exit; end;
  var F := TPSPFpl(GetObject(FHLE.Arg(0), TPSPFpl));
  if F = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_FPLID); Exit; end;
  if (Addr < F.Block) or ((Addr - F.Block) mod F.Stride <> 0) or (Integer((Addr - F.Block) div F.Stride) >= F.Count) or
    not F.Used[(Addr - F.Block) div F.Stride] then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MEMBLOCK); Exit; end;
  Spend(PSPSyncCallNs);
  FHLE.Result(0);
  var Index := (Addr - F.Block) div F.Stride;
  if F.Waiters.Count > 0 then
  begin
    // Straight to the first waiter.
    var T := F.Waiters.First;
    if T.Wait.Data[0] <> 0 then
      FMemory.Write32(T.Wait.Data[0], Addr);
    EndWait(T, 0);
    Exit;
  end;
  F.Used[Index] := False;
end;

procedure TPSPKernel.hCancelFpl;
begin
  var F := TPSPFpl(GetObject(FHLE.Arg(0), TPSPFpl));
  if F = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_FPLID); Exit; end;
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), Cardinal(F.Waiters.Count));
  FHLE.Result(0);
  while F.Waiters.Count > 0 do
    EndWait(F.Waiters.First, SCE_KERNEL_ERROR_WAIT_CANCEL);
end;

procedure TPSPKernel.hReferFplStatus;
begin
  var F := TPSPFpl(GetObject(FHLE.Arg(0), TPSPFpl));
  if F = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_FPLID); Exit; end;
  var Buf: array[0..$37] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var N := RawByteString(F.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  PCardinal(@Buf[$24])^ := F.Attr;
  PCardinal(@Buf[$28])^ := F.BlockSize;
  PCardinal(@Buf[$2C])^ := Cardinal(F.Count);
  PCardinal(@Buf[$30])^ := Cardinal(F.FreeCount);
  PCardinal(@Buf[$34])^ := Cardinal(F.Waiters.Count);
  WriteInfo(FHLE.Arg(1), Buf, $38);
  FHLE.Result(0);
end;

{ HLE: thread-local storage pools }

function TPSPKernel.TlsplOf(Id: Cardinal): TPSPKernelObject;
begin
  // Ids carry the pool's slot in bits 3..6; that is what the lookup uses.
  var Index := Integer((Id shr 3) and $F);
  for var O in FObjects.Values do
    if (O is TPSPTlspl) and (TPSPTlspl(O).Index = Index) then
      Exit(O);
  Result := nil;
end;

procedure TPSPKernel.hCreateTlspl;
begin
  var Name: string;
  if not ReadName(FHLE.Arg(0), Name) then
    begin FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY); Exit; end;
  var PartId := FHLE.ArgInt(1);
  var Err := UserPartitionCheck(PartId);
  if Err <> 0 then
    begin FHLE.Result(Err); Exit; end;
  var Attr := FHLE.Arg(2);
  if (Attr and not Cardinal($41FF)) <> 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR); Exit; end;
  var BlockSize := FHLE.Arg(3);
  var Count := FHLE.Arg(4);
  if (BlockSize = 0) or (Integer(BlockSize) < 0) or (Count = 0) or (Integer(Count) < 0) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MEMSIZE); Exit; end;
  var Align: Cardinal := 4;
  var Opt := FHLE.Arg(5);
  if (Opt <> 0) and (FMemory.Read32(Opt) >= 8) then
  begin
    var A := FMemory.Read32(Opt + 4);
    if not ValidPoolAlignment(A) then
      begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ARGUMENT); Exit; end;
    if A > Align then
      Align := A;
  end;
  var Used: array[0..15] of Boolean;
  FillChar(Used, SizeOf(Used), 0);
  for var O in FObjects.Values do
    if O is TPSPTlspl then
      Used[TPSPTlspl(O).Index] := True;
  var Index := -1;
  for var I := 0 to 15 do
    if not Used[I] then
    begin
      Index := I;
      Break;
    end;
  if Index < 0 then
    begin FHLE.Result(PSPErrorTlsplFull); Exit; end;
  var Stride := AlignUp(BlockSize, Align);
  var Total := UInt64(Stride) * Count;
  if Total > $7FFFFFFF then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MEMSIZE); Exit; end;
  var P := PoolPartition(PartId);
  var Block: Cardinal;
  if (Attr and $4000) <> 0 then
    Block := P.Alloc(Cardinal(Total), akHigh, 0, 256, 'tlspl:' + Name)
  else
    Block := P.Alloc(Cardinal(Total), akLow, 0, 256, 'tlspl:' + Name);
  if Block = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY); Exit; end;
  var L := TPSPTlspl.Create;
  L.Name := Name;
  L.Attr := Attr;
  L.PartitionId := PartId;
  L.Index := Index;
  L.Block := Block;
  L.BlockSize := BlockSize;
  L.Stride := Stride;
  L.Count := Integer(Count);
  SetLength(L.Owner, Count);
  L.Waiters.ByPriority := (Attr and $100) <> 0;
  // Pick an id whose slot bits say which pool it is.
  while ((FNextUID shr 3) and $F) <> Cardinal(Index) do
    Inc(FNextUID, 2);
  Spend(PSPSyncCallNs);
  FHLE.Result(AddObject(L));
end;

procedure TPSPKernel.hDeleteTlspl;
begin
  var L := TPSPTlspl(GetObject(FHLE.Arg(0), TPSPTlspl));
  if L = nil then
    begin FHLE.Result(PSPErrorUnknownTlsplId); Exit; end;
  // Blocks other threads still hold keep the pool alive.
  for var O in L.Owner do
    if (O <> nil) and (O <> FCurrent) then
      begin FHLE.Result(PSPErrorTlsplBusy); Exit; end;
  FHLE.Result(0);
  while L.Waiters.Count > 0 do
    EndWait(L.Waiters.First, SCE_KERNEL_ERROR_WAIT_DELETE);
  for var O in L.Owner do
    if O <> nil then
      O.TlsSlots[L.Index] := 0;
  PoolPartition(L.PartitionId).FreeBlock(L.Block);
  DeleteObject(L);
end;

// The thread's own block, or a free one; False when it has to wait.
function TPSPKernel.TlsTake(Obj: TPSPKernelObject; out Addr: Cardinal): Boolean;
begin
  var L := TPSPTlspl(Obj);
  var I := L.Find(FCurrent);
  if I >= 0 then
  begin
    Addr := L.Block + Cardinal(I) * L.Stride;
    Exit(True);
  end;
  Result := (L.Waiters.Count = 0) and L.Alloc(FCurrent, Addr);
end;

procedure TPSPKernel.hGetTlsAddr;
begin
  // The library keeps each thread's block by the pool's slot (bits 3..6 of
  // the id) and only asks the kernel when it has none.
  if (FCurrent = nil) or InInterrupt then
    begin FHLE.Result(0); Exit; end;
  var Cached := FCurrent.TlsSlots[(FHLE.Arg(0) shr 3) and $F];
  if Cached <> 0 then
    begin FHLE.Result(Cached); Exit; end;
  var L := TPSPTlspl(GetObject(FHLE.Arg(0), TPSPTlspl));
  if (L = nil) or not CanWait then
    begin FHLE.Result(0); Exit; end;
  var A: Cardinal;
  if TlsTake(L, A) then
    begin FHLE.Result(A); Exit; end;
  FHLE.Result(0);
  L.Waiters.Add(FCurrent);
  if BeginWaitData(PSPWaitTlspl, L, L.UID, 0, False, L.Retry, [0, 1]) then
    FCurrent.Wait.FailAsZero := True;
end;

procedure TPSPKernel.hAllocateTlspl;
begin
  var OutPtr := FHLE.Arg(1);
  var TimeoutPtr := FHLE.Arg(2);
  if not CanWait then
    begin FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT); Exit; end;
  if ((OutPtr and $80000000) <> 0) or ((TimeoutPtr and $80000000) <> 0) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR); Exit; end;
  var L := TPSPTlspl(GetObject(FHLE.Arg(0), TPSPTlspl));
  if L = nil then
    begin FHLE.Result(PSPErrorUnknownTlsplId); Exit; end;
  var A: Cardinal;
  if TlsTake(L, A) then
  begin
    if OutPtr <> 0 then
      FMemory.Write32(OutPtr, A);
    FHLE.Result(0);
    Exit;
  end;
  FHLE.Result(0);
  L.Waiters.Add(FCurrent);
  BeginWaitData(PSPWaitTlspl, L, L.UID, TimeoutPtr, False, L.Retry, [OutPtr, 0]);
end;

procedure TPSPKernel.hFreeTlspl;
begin
  var L := TPSPTlspl(GetObject(FHLE.Arg(0), TPSPTlspl));
  if L = nil then
    begin FHLE.Result(PSPErrorUnknownTlsplId); Exit; end;
  FHLE.Result(0);
  if FCurrent <> nil then
    L.Release(FCurrent);
end;

procedure TPSPKernel.hReferTlsplStatus;
begin
  var L := TPSPTlspl(GetObject(FHLE.Arg(0), TPSPTlspl));
  if L = nil then
    begin FHLE.Result(PSPErrorUnknownTlsplId); Exit; end;
  var Buf: array[0..$3B] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var N := RawByteString(L.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  PCardinal(@Buf[$24])^ := L.Attr;
  PCardinal(@Buf[$28])^ := Cardinal(L.Index);
  PCardinal(@Buf[$2C])^ := L.BlockSize;
  PCardinal(@Buf[$30])^ := Cardinal(L.Count);
  PCardinal(@Buf[$34])^ := Cardinal(L.FreeCount);
  PCardinal(@Buf[$38])^ := Cardinal(L.Waiters.Count);
  WriteInfo(FHLE.Arg(1), Buf, $3C);
  FHLE.Result(0);
end;

procedure TPSPKernel.ReleaseTlsOf(T: TPSPThread);
begin
  for var O in FObjects.Values.ToArray do
    if O is TPSPTlspl then
      TPSPTlspl(O).Release(T);
end;
