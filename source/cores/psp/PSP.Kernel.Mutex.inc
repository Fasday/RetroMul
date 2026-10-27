{ PSP.Kernel: mutexes and lightweight mutexes. }

type
  TPSPMutex = class(TPSPWaitObject)
  public
    InitCount, LockCount: Integer;
    Owner: TPSPThread;
    class function IdType: Integer; override;
    function Recursive: Boolean; inline;
    function Retry(T: TPSPThread): Boolean;
    // Hands the mutex to the first waiter that can take it.
    procedure WakeWaiters;
    procedure WaiterGone; override;
  end;

  // The lock state lives in the guest's workarea:
  // +0 lock count, +4 owner, +8 attr, +12 waiting threads, +16 uid, +20..31 0.
  TPSPLwMutex = class(TPSPWaitObject)
  public
    Workarea: Cardinal;
    InitCount: Integer;
    class function IdType: Integer; override;
    procedure RemoveWaiter(T: TPSPThread); override;
    procedure AddWaiter(T: TPSPThread); override;
    procedure SyncWaiting;
    function Retry(T: TPSPThread): Boolean;
    procedure WakeWaiters;
    procedure WaiterGone; override;
  end;

const
  PSPMutexRecursive = $200;

{ TPSPMutex }

class function TPSPMutex.IdType: Integer;
begin
  Result := 12;
end;

function TPSPMutex.Recursive: Boolean;
begin
  Result := (Attr and PSPMutexRecursive) <> 0;
end;

function TPSPMutex.Retry(T: TPSPThread): Boolean;
begin
  if not Kernel.FObjects.ContainsKey(UID) or (T.Wait.Obj <> Self) then
  begin
    T.SetResult(SCE_KERNEL_ERROR_WAIT_DELETE);
    Exit(True);
  end;
  Result := (Owner = nil) and ((Waiters.Count = 0) or (Waiters.First = T));
  if Result then
  begin
    Owner := T;
    LockCount := Integer(T.Wait.Data[0]);
    T.SetResult(0);
  end;
end;

procedure TPSPMutex.WakeWaiters;
begin
  if (Owner <> nil) or (Waiters.Count = 0) then
    Exit;
  var T := Waiters.First;
  Owner := T;
  LockCount := Integer(T.Wait.Data[0]);
  Kernel.EndWait(T, 0);
end;

procedure TPSPMutex.WaiterGone;
begin
  WakeWaiters;
end;

{ TPSPLwMutex }

class function TPSPLwMutex.IdType: Integer;
begin
  Result := 13;
end;

procedure TPSPLwMutex.SyncWaiting;
begin
  // The workarea counts the threads waiting in the kernel.
  Kernel.Memory.Write32(Workarea + 12, Cardinal(Waiters.Count));
end;

procedure TPSPLwMutex.RemoveWaiter(T: TPSPThread);
begin
  inherited;
  SyncWaiting;
end;

procedure TPSPLwMutex.AddWaiter(T: TPSPThread);
begin
  inherited;
  SyncWaiting;
end;

function TPSPLwMutex.Retry(T: TPSPThread): Boolean;
begin
  if not Kernel.FObjects.ContainsKey(UID) or (T.Wait.Obj <> Self) then
  begin
    T.SetResult(SCE_KERNEL_ERROR_WAIT_DELETE);
    Exit(True);
  end;
  var M := Kernel.Memory;
  Result := (M.Read32(Workarea) = 0) and ((Waiters.Count = 0) or (Waiters.First = T));
  if Result then
  begin
    M.Write32(Workarea, T.Wait.Data[0]);
    M.Write32(Workarea + 4, T.UID);
    T.SetResult(0);
  end;
end;

procedure TPSPLwMutex.WakeWaiters;
begin
  var M := Kernel.Memory;
  if (M.Read32(Workarea) <> 0) or (Waiters.Count = 0) then
    Exit;
  var T := Waiters.First;
  M.Write32(Workarea, T.Wait.Data[0]);
  M.Write32(Workarea + 4, T.UID);
  Kernel.EndWait(T, 0);
end;

procedure TPSPLwMutex.WaiterGone;
begin
  WakeWaiters;
end;

{ Mutex owners }

procedure TPSPKernel.ReleaseMutexesOf(T: TPSPThread);
begin
  // A thread that ends hands its kernel mutexes on.
  for var O in FObjects.Values.ToArray do
    if (O is TPSPMutex) and (TPSPMutex(O).Owner = T) then
    begin
      TPSPMutex(O).Owner := nil;
      TPSPMutex(O).LockCount := 0;
      TPSPMutex(O).WakeWaiters;
    end;
end;

{ HLE: mutexes }

procedure TPSPKernel.hCreateMutex;
begin
  var Name: string;
  if not ReadName(FHLE.Arg(0), Name) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ERROR); Exit; end;
  var Attr := FHLE.Arg(1);
  var Count := FHLE.ArgInt(2);
  if (Attr and not Cardinal($BFF)) <> 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR); Exit; end;
  if (Count < 0) or ((Count > 1) and ((Attr and PSPMutexRecursive) = 0)) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_COUNT); Exit; end;
  var M := TPSPMutex.Create;
  M.Name := Name;
  M.Attr := Attr;
  M.InitCount := Count;
  M.LockCount := Count;
  if Count > 0 then
    M.Owner := FCurrent;
  M.Waiters.ByPriority := (Attr and $100) <> 0;
  Spend(PSPSyncCallNs);
  FHLE.Result(AddObject(M));
end;

procedure TPSPKernel.hDeleteMutex;
begin
  var M := TPSPMutex(GetObject(FHLE.Arg(0), TPSPMutex));
  if M = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_MUTEX_NOT_FOUND); Exit; end;
  FHLE.Result(0);
  while M.Waiters.Count > 0 do
    EndWait(M.Waiters.First, SCE_KERNEL_ERROR_WAIT_DELETE);
  DeleteObject(M);
end;

function MutexCountError(M: TPSPMutex; Count: Integer): Cardinal;
begin
  if (Count <= 0) or ((Count > 1) and not M.Recursive) then
    Result := SCE_KERNEL_ERROR_ILLEGAL_COUNT
  else
    Result := 0;
end;

procedure TPSPKernel.LockMutexCommon(AllowCB: Boolean);
begin
  var M := TPSPMutex(GetObject(FHLE.Arg(0), TPSPMutex));
  if M = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_MUTEX_NOT_FOUND); Exit; end;
  var Count := FHLE.ArgInt(1);
  var Err := MutexCountError(M, Count);
  if Err <> 0 then
    begin FHLE.Result(Err); Exit; end;
  Spend(PSPSyncCallNs);
  FHLE.Result(0);
  if M.Owner = FCurrent then
  begin
    if not M.Recursive then
      begin FHLE.Result(SCE_KERNEL_ERROR_MUTEX_RECURSIVE_NOT_ALLOWED); Exit; end;
    if Int64(M.LockCount) + Count > High(Integer) then
      begin FHLE.Result(SCE_KERNEL_ERROR_MUTEX_LOCK_OVERFLOW); Exit; end;
    Inc(M.LockCount, Count);
    if AllowCB then
      CheckCallbacksNow;
    Exit;
  end;
  if (M.Owner = nil) and (M.Waiters.Count = 0) then
  begin
    M.Owner := FCurrent;
    M.LockCount := Count;
    if AllowCB then
      CheckCallbacksNow;
    Exit;
  end;
  if not CanWait then
    begin FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT); Exit; end;
  M.Waiters.Add(FCurrent);
  BeginWaitData(PSPWaitMutex, M, M.UID, FHLE.Arg(2), AllowCB, M.Retry, [Cardinal(Count)]);
end;

procedure TPSPKernel.hLockMutex;
begin
  LockMutexCommon(False);
end;

procedure TPSPKernel.hLockMutexCB;
begin
  LockMutexCommon(True);
end;

procedure TPSPKernel.hTryLockMutex;
begin
  var M := TPSPMutex(GetObject(FHLE.Arg(0), TPSPMutex));
  if M = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_MUTEX_NOT_FOUND); Exit; end;
  var Count := FHLE.ArgInt(1);
  var Err := MutexCountError(M, Count);
  if Err <> 0 then
    begin FHLE.Result(Err); Exit; end;
  FHLE.Result(0);
  if M.Owner = FCurrent then
  begin
    if not M.Recursive then
      begin FHLE.Result(SCE_KERNEL_ERROR_MUTEX_RECURSIVE_NOT_ALLOWED); Exit; end;
    if Int64(M.LockCount) + Count > High(Integer) then
      begin FHLE.Result(SCE_KERNEL_ERROR_MUTEX_LOCK_OVERFLOW); Exit; end;
    Inc(M.LockCount, Count);
    Exit;
  end;
  if (M.Owner = nil) and (M.Waiters.Count = 0) then
  begin
    M.Owner := FCurrent;
    M.LockCount := Count;
    Exit;
  end;
  FHLE.Result(SCE_KERNEL_ERROR_MUTEX_LOCKED);
end;

procedure TPSPKernel.hUnlockMutex;
begin
  var M := TPSPMutex(GetObject(FHLE.Arg(0), TPSPMutex));
  if M = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_MUTEX_NOT_FOUND); Exit; end;
  var Count := FHLE.ArgInt(1);
  var Err := MutexCountError(M, Count);
  if Err <> 0 then
    begin FHLE.Result(Err); Exit; end;
  if (M.Owner = nil) or (M.Owner <> FCurrent) then
    begin FHLE.Result(SCE_KERNEL_ERROR_MUTEX_UNLOCKED); Exit; end;
  if Count > M.LockCount then
    begin FHLE.Result(SCE_KERNEL_ERROR_MUTEX_UNLOCK_UNDERFLOW); Exit; end;
  Spend(PSPSyncCallNs);
  FHLE.Result(0);
  Dec(M.LockCount, Count);
  if M.LockCount = 0 then
  begin
    M.Owner := nil;
    M.WakeWaiters;
  end;
end;

procedure TPSPKernel.hCancelMutex;
begin
  var M := TPSPMutex(GetObject(FHLE.Arg(0), TPSPMutex));
  if M = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_MUTEX_NOT_FOUND); Exit; end;
  var Count := FHLE.ArgInt(1);
  if (Count > 1) and not M.Recursive then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_COUNT); Exit; end;
  if FHLE.Arg(2) <> 0 then
    FMemory.Write32(FHLE.Arg(2), Cardinal(M.Waiters.Count));
  FHLE.Result(0);
  while M.Waiters.Count > 0 do
    EndWait(M.Waiters.First, SCE_KERNEL_ERROR_WAIT_CANCEL);
  if Count <= 0 then
  begin
    M.Owner := nil;
    M.LockCount := 0;
  end
  else
  begin
    M.Owner := FCurrent;
    M.LockCount := Count;
  end;
end;

procedure TPSPKernel.hReferMutexStatus;
begin
  var M := TPSPMutex(GetObject(FHLE.Arg(0), TPSPMutex));
  if M = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_MUTEX_NOT_FOUND); Exit; end;
  var Buf: array[0..$37] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var N := RawByteString(M.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  PCardinal(@Buf[$24])^ := M.Attr;
  PCardinal(@Buf[$28])^ := Cardinal(M.InitCount);
  PCardinal(@Buf[$2C])^ := Cardinal(M.LockCount);
  if M.Owner <> nil then
    PCardinal(@Buf[$30])^ := M.Owner.UID
  else
    PCardinal(@Buf[$30])^ := $FFFFFFFF;
  PCardinal(@Buf[$34])^ := Cardinal(M.Waiters.Count);
  WriteInfo(FHLE.Arg(1), Buf, $38);
  FHLE.Result(0);
end;

{ HLE: lightweight mutexes }

procedure TPSPKernel.hCreateLwMutex;
begin
  var W := FHLE.Arg(0);
  var Name: string;
  if not ReadName(FHLE.Arg(1), Name) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ERROR); Exit; end;
  var Attr := FHLE.Arg(2);
  var Count := FHLE.ArgInt(3);
  if (Attr and not Cardinal($3FF)) <> 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR); Exit; end;
  if (Count < 0) or ((Count > 1) and ((Attr and PSPMutexRecursive) = 0)) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_COUNT); Exit; end;
  var L := TPSPLwMutex.Create;
  L.Name := Name;
  L.Attr := Attr;
  L.Workarea := W;
  L.InitCount := Count;
  L.Waiters.ByPriority := (Attr and $100) <> 0;
  AddObject(L);
  FMemory.Write32(W, Cardinal(Count));
  if (Count > 0) and (FCurrent <> nil) then
    FMemory.Write32(W + 4, FCurrent.UID)
  else
    FMemory.Write32(W + 4, 0);
  FMemory.Write32(W + 8, Attr);
  FMemory.Write32(W + 12, 0);
  FMemory.Write32(W + 16, L.UID);
  FMemory.Write32(W + 20, 0);
  FMemory.Write32(W + 24, 0);
  FMemory.Write32(W + 28, 0);
  FHLE.Result(0);
end;

procedure TPSPKernel.hDeleteLwMutex;
begin
  var W := FHLE.Arg(0);
  if (W = 0) or not ValidUserAddress(W) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR); Exit; end;
  var L := TPSPLwMutex(GetObject(FMemory.Read32(W + 16), TPSPLwMutex));
  if (L = nil) or (L.Workarea <> W) then
    begin FHLE.Result(SCE_KERNEL_ERROR_LWMUTEX_NOT_FOUND); Exit; end;
  FHLE.Result(0);
  while L.Waiters.Count > 0 do
    EndWait(L.Waiters.First, SCE_KERNEL_ERROR_WAIT_DELETE);
  FMemory.Write32(W + 12, 0);
  FMemory.Write32(W + 16, $FFFFFFFF);
  DeleteObject(L);
end;

// Errors from the lock paths: TryLock before 6.00 reports every failure as
// MUTEX_LOCKED.
procedure TPSPKernel.LockLwMutexCommon(AllowCB, IsTry: Boolean; TryError: Cardinal);

  procedure Fail(Code: Cardinal);
  begin
    if IsTry and (TryError <> 0) then
      FHLE.Result(TryError)
    else
      FHLE.Result(Code);
  end;

begin
  var W := FHLE.Arg(0);
  var Count := FHLE.ArgInt(1);
  var TimeoutPtr: Cardinal := 0;
  if not IsTry then
    TimeoutPtr := FHLE.Arg(2);
  var Attr := FMemory.Read32(W + 8);
  var Recursive := (Attr and PSPMutexRecursive) <> 0;
  if (Count <= 0) or ((Count > 1) and not Recursive) then
    begin Fail(SCE_KERNEL_ERROR_ILLEGAL_COUNT); Exit; end;
  if FMemory.Read32(W + 16) = $FFFFFFFF then
    begin Fail(SCE_KERNEL_ERROR_LWMUTEX_NOT_FOUND); Exit; end;
  var Level := Integer(FMemory.Read32(W));
  var Me: Cardinal := 0;
  if FCurrent <> nil then
    Me := FCurrent.UID;
  FHLE.Result(0);
  if Level = 0 then
  begin
    FMemory.Write32(W, Cardinal(Count));
    FMemory.Write32(W + 4, Me);
    if AllowCB then
      CheckCallbacksNow;
    Exit;
  end;
  if FMemory.Read32(W + 4) = Me then
  begin
    if not Recursive then
      begin Fail(SCE_KERNEL_ERROR_LWMUTEX_RECURSIVE_NOT_ALLOWED); Exit; end;
    if Int64(Level) + Count > High(Integer) then
      begin Fail(SCE_KERNEL_ERROR_LWMUTEX_LOCK_OVERFLOW); Exit; end;
    FMemory.Write32(W, Cardinal(Level + Count));
    if AllowCB then
      CheckCallbacksNow;
    Exit;
  end;
  if IsTry then
    begin Fail(SCE_KERNEL_ERROR_LWMUTEX_LOCKED); Exit; end;
  // Held by another thread: the kernel side waits on the object.
  Spend(PSPSyncCallNs);
  var L := TPSPLwMutex(GetObject(FMemory.Read32(W + 16), TPSPLwMutex));
  if L = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_LWMUTEX_NOT_FOUND); Exit; end;
  if not CanWait then
    begin FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT); Exit; end;
  L.AddWaiter(FCurrent);
  BeginWaitData(PSPWaitLwMutex, L, L.UID, TimeoutPtr, AllowCB, L.Retry, [Cardinal(Count)]);
end;

procedure TPSPKernel.hLockLwMutex;
begin
  LockLwMutexCommon(False, False, 0);
end;

procedure TPSPKernel.hLockLwMutexCB;
begin
  LockLwMutexCommon(True, False, 0);
end;

procedure TPSPKernel.hTryLockLwMutex;
begin
  LockLwMutexCommon(False, True, SCE_KERNEL_ERROR_MUTEX_LOCKED);
end;

procedure TPSPKernel.hTryLockLwMutex600;
begin
  LockLwMutexCommon(False, True, 0);
end;

procedure TPSPKernel.hUnlockLwMutex;
begin
  var W := FHLE.Arg(0);
  var Count := FHLE.ArgInt(1);
  var Attr := FMemory.Read32(W + 8);
  var Recursive := (Attr and PSPMutexRecursive) <> 0;
  if (Count <= 0) or ((Count > 1) and not Recursive) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_COUNT); Exit; end;
  if FMemory.Read32(W + 16) = $FFFFFFFF then
    begin FHLE.Result(SCE_KERNEL_ERROR_LWMUTEX_NOT_FOUND); Exit; end;
  var Level := Integer(FMemory.Read32(W));
  var Me: Cardinal := 0;
  if FCurrent <> nil then
    Me := FCurrent.UID;
  if (Level = 0) or (FMemory.Read32(W + 4) <> Me) then
    begin FHLE.Result(SCE_KERNEL_ERROR_LWMUTEX_UNLOCKED); Exit; end;
  if Count > Level then
    begin FHLE.Result(SCE_KERNEL_ERROR_LWMUTEX_UNLOCK_UNDERFLOW); Exit; end;
  FHLE.Result(0);
  Dec(Level, Count);
  FMemory.Write32(W, Cardinal(Level));
  if Level > 0 then
    Exit;
  FMemory.Write32(W + 4, 0);
  if FMemory.Read32(W + 12) = 0 then
    Exit;
  // Somebody waits: the kernel hands the lock on.
  Spend(PSPSyncCallNs);
  var L := TPSPLwMutex(GetObject(FMemory.Read32(W + 16), TPSPLwMutex));
  if L <> nil then
    L.WakeWaiters;
end;

procedure TPSPKernel.ReferLwMutex(Obj: TPSPKernelObject; InfoPtr: Cardinal);
begin
  var L := TPSPLwMutex(Obj);
  var Buf: array[0..$3F] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var N := RawByteString(L.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  var W := L.Workarea;
  var Level := FMemory.Read32(W);
  PCardinal(@Buf[$24])^ := L.Attr;
  PCardinal(@Buf[$28])^ := L.UID;
  PCardinal(@Buf[$2C])^ := W;
  PCardinal(@Buf[$30])^ := Cardinal(L.InitCount);
  PCardinal(@Buf[$34])^ := Level;
  if Level <> 0 then
    PCardinal(@Buf[$38])^ := FMemory.Read32(W + 4)
  else
    PCardinal(@Buf[$38])^ := $FFFFFFFF;
  PCardinal(@Buf[$3C])^ := FMemory.Read32(W + 12);
  WriteInfo(InfoPtr, Buf, $40);
end;

procedure TPSPKernel.hReferLwMutexStatus;
begin
  var W := FHLE.Arg(0);
  var L := TPSPLwMutex(GetObject(FMemory.Read32(W + 16), TPSPLwMutex));
  if L = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_LWMUTEX_NOT_FOUND); Exit; end;
  ReferLwMutex(L, FHLE.Arg(1));
  FHLE.Result(0);
end;

procedure TPSPKernel.hReferLwMutexStatusByID;
begin
  var L := TPSPLwMutex(GetObject(FHLE.Arg(0), TPSPLwMutex));
  if L = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_LWMUTEX_NOT_FOUND); Exit; end;
  ReferLwMutex(L, FHLE.Arg(1));
  FHLE.Result(0);
end;
