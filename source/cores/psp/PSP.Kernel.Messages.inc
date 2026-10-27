{ PSP.Kernel: message boxes and message pipes. }

type
  // Messages stay in the guest: a ring linked through each packet's first word,
  // the box keeping the last one (whose next is the first).
  TPSPMbx = class(TPSPWaitObject)
  public
    Tail: Cardinal;
    Count: Integer;
    class function IdType: Integer; override;
    function First: Cardinal;
    function Retry(T: TPSPThread): Boolean;
    // Takes the first message: 0 when it worked, else the error.
    function Take(out Msg: Cardinal): Cardinal;
    function Contains(Msg: Cardinal): Boolean;
    procedure Put(Msg: Cardinal);
  end;

  TPSPMsgPipe = class(TPSPKernelObject)
  public
    Attr: Cardinal;
    PartitionId: Integer;
    Block: Cardinal;
    BufSize: Cardinal;
    Data: TBytes;
    Used: Cardinal;
    Senders, Receivers: TPSPWaitQueue;
    constructor Create;
    destructor Destroy; override;
    class function IdType: Integer; override;
    procedure RemoveWaiter(T: TPSPThread); override;
    procedure AddWaiter(T: TPSPThread); override;
    procedure WaiterGone; override;
    function FreeSize: Cardinal;
    procedure PushBytes(Src, N: Cardinal);
    procedure PopBytes(Dst, N: Cardinal);
    // Moves data between the buffer and the waiting threads until nothing
    // more can move; wakes those that are done.
    procedure Settle;
    function SendRetry(T: TPSPThread): Boolean;
    function ReceiveRetry(T: TPSPThread): Boolean;
    procedure WaitAbort(T: TPSPThread);
  end;

{ TPSPMbx }

class function TPSPMbx.IdType: Integer;
begin
  Result := 4;
end;

function TPSPMbx.First: Cardinal;
begin
  if Tail = 0 then
    Result := 0
  else
    Result := Kernel.Memory.Read32(Tail);
end;

function TPSPMbx.Contains(Msg: Cardinal): Boolean;
begin
  var P := First;
  for var I := 1 to Count do
  begin
    if P = 0 then
      Break;
    if P = Msg then
      Exit(True);
    P := Kernel.Memory.Read32(P);
  end;
  Result := False;
end;

procedure TPSPMbx.Put(Msg: Cardinal);
begin
  var M := Kernel.Memory;
  if Tail = 0 then
  begin
    M.Write32(Msg, Msg);
    Tail := Msg;
  end
  else if (Attr and $400) <> 0 then
  begin
    // By message priority, lower first; equal ones keep their order.
    var Prio := M.Read8(Msg + 4);
    var Prev := Tail;
    var P := M.Read32(Tail);
    var Placed := False;
    for var I := 1 to Count do
    begin
      if M.Read8(P + 4) > Prio then
      begin
        M.Write32(Msg, P);
        M.Write32(Prev, Msg);
        Placed := True;
        Break;
      end;
      if P = Tail then
        Break;
      Prev := P;
      P := M.Read32(P);
    end;
    if not Placed then
    begin
      M.Write32(Msg, M.Read32(Tail));
      M.Write32(Tail, Msg);
      Tail := Msg;
    end;
  end
  else
  begin
    M.Write32(Msg, M.Read32(Tail));
    M.Write32(Tail, Msg);
    Tail := Msg;
  end;
  Inc(Count);
end;

function TPSPMbx.Take(out Msg: Cardinal): Cardinal;
begin
  var M := Kernel.Memory;
  Msg := First;
  if Msg = 0 then
    Exit(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
  if Msg = Tail then
  begin
    if Count > 1 then
      Exit(SCE_KERNEL_ERROR_MESSAGEBOX_DUPLICATE_MESSAGE);
    Tail := 0;
  end
  else
    M.Write32(Tail, M.Read32(Msg));
  Dec(Count);
  Result := 0;
end;

function TPSPMbx.Retry(T: TPSPThread): Boolean;
begin
  if not Kernel.FObjects.ContainsKey(UID) or (T.Wait.Obj <> Self) then
  begin
    T.SetResult(SCE_KERNEL_ERROR_WAIT_DELETE);
    Exit(True);
  end;
  Result := (Count > 0) and ((Waiters.Count = 0) or (Waiters.First = T));
  if Result then
  begin
    var Msg: Cardinal;
    var Err := Take(Msg);
    if (Err = 0) and (T.Wait.Data[0] <> 0) then
      Kernel.Memory.Write32(T.Wait.Data[0], Msg);
    T.SetResult(Err);
  end;
end;

{ TPSPMsgPipe }

constructor TPSPMsgPipe.Create;
begin
  inherited Create;
  Senders := TPSPWaitQueue.Create(False);
  Receivers := TPSPWaitQueue.Create(False);
end;

destructor TPSPMsgPipe.Destroy;
begin
  Senders.Free;
  Receivers.Free;
  inherited;
end;

class function TPSPMsgPipe.IdType: Integer;
begin
  Result := 7;
end;

procedure TPSPMsgPipe.RemoveWaiter(T: TPSPThread);
begin
  Senders.Remove(T);
  Receivers.Remove(T);
end;

procedure TPSPMsgPipe.AddWaiter(T: TPSPThread);
begin
  if T.Wait.Data[4] = 1 then
    Senders.Add(T)
  else
    Receivers.Add(T);
end;

procedure TPSPMsgPipe.WaiterGone;
begin
  Settle;
end;

function TPSPMsgPipe.FreeSize: Cardinal;
begin
  Result := BufSize - Used;
end;

procedure TPSPMsgPipe.PushBytes(Src, N: Cardinal);
begin
  if N = 0 then
    Exit;
  Kernel.Memory.ReadBytes(Src, Data[Used], N);
  Inc(Used, N);
end;

procedure TPSPMsgPipe.PopBytes(Dst, N: Cardinal);
begin
  if N = 0 then
    Exit;
  Kernel.Memory.WriteBytes(Dst, Data[0], N);
  if Used > N then
    Move(Data[N], Data[0], Used - N);
  Dec(Used, N);
end;

// Wait data: [0] buffer, [1] size, [2] mode, [3] done so far, [4] 1 = sending,
// [5] result pointer.

function PipeDone(T: TPSPThread): Boolean;
begin
  if T.Wait.Data[2] = 1 then
    Result := T.Wait.Data[3] > 0
  else
    Result := T.Wait.Data[3] >= T.Wait.Data[1];
end;

procedure PipeFinish(K: TPSPKernel; T: TPSPThread);
begin
  if T.Wait.Data[5] <> 0 then
    K.Memory.Write32(T.Wait.Data[5], T.Wait.Data[3]);
end;

procedure TPSPMsgPipe.Settle;
begin
  var M := Kernel.Memory;
  repeat
    var Moved := False;
    // Waiting receivers take from the buffer, first come first.
    while (Receivers.Count > 0) and (Used > 0) do
    begin
      var R := Receivers.First;
      var Want := R.Wait.Data[1] - R.Wait.Data[3];
      var N := Want;
      if N > Used then
        N := Used;
      PopBytes(R.Wait.Data[0] + R.Wait.Data[3], N);
      Inc(R.Wait.Data[3], N);
      Moved := Moved or (N > 0);
      if PipeDone(R) then
      begin
        PipeFinish(Kernel, R);
        Kernel.EndWait(R, 0);
      end
      else
        Break;
    end;
    // Then the waiting senders, straight to waiting receivers, then into the buffer.
    while Senders.Count > 0 do
    begin
      var S := Senders.First;
      var Left := S.Wait.Data[1] - S.Wait.Data[3];
      while (Left > 0) and (Receivers.Count > 0) and (Used = 0) do
      begin
        var R := Receivers.First;
        var N := R.Wait.Data[1] - R.Wait.Data[3];
        if N > Left then
          N := Left;
        var Tmp: TBytes;
        SetLength(Tmp, N);
        if N > 0 then
        begin
          M.ReadBytes(S.Wait.Data[0] + S.Wait.Data[3], Tmp[0], N);
          M.WriteBytes(R.Wait.Data[0] + R.Wait.Data[3], Tmp[0], N);
        end;
        Inc(S.Wait.Data[3], N);
        Inc(R.Wait.Data[3], N);
        Dec(Left, N);
        Moved := Moved or (N > 0);
        if PipeDone(R) then
        begin
          PipeFinish(Kernel, R);
          Kernel.EndWait(R, 0);
        end
        else
          Break;
      end;
      if Left > 0 then
      begin
        var N := FreeSize;
        if (S.Wait.Data[2] = 0) and (N < Left) then
          N := 0;
        if N > Left then
          N := Left;
        if N > 0 then
        begin
          PushBytes(S.Wait.Data[0] + S.Wait.Data[3], N);
          Inc(S.Wait.Data[3], N);
          Dec(Left, N);
          Moved := True;
        end;
      end;
      if (Left = 0) or ((S.Wait.Data[2] = 1) and (S.Wait.Data[3] > 0)) then
      begin
        PipeFinish(Kernel, S);
        Kernel.EndWait(S, 0);
      end
      else
        Break;
    end;
    if not Moved then
      Break;
  until False;
end;

function TPSPMsgPipe.SendRetry(T: TPSPThread): Boolean;
begin
  if not Kernel.FObjects.ContainsKey(UID) or (T.Wait.Obj <> Self) then
  begin
    PipeFinish(Kernel, T);
    T.SetResult(SCE_KERNEL_ERROR_WAIT_DELETE);
    Exit(True);
  end;
  Result := False;
  if Senders.Count > 0 then
    Exit;
  var Left := T.Wait.Data[1] - T.Wait.Data[3];
  var N := FreeSize;
  if (T.Wait.Data[2] = 0) and (N < Left) then
    N := 0;
  if N > Left then
    N := Left;
  if N > 0 then
  begin
    PushBytes(T.Wait.Data[0] + T.Wait.Data[3], N);
    Inc(T.Wait.Data[3], N);
  end;
  Result := PipeDone(T);
  if Result then
  begin
    PipeFinish(Kernel, T);
    T.SetResult(0);
    Settle;
  end;
end;

function TPSPMsgPipe.ReceiveRetry(T: TPSPThread): Boolean;
begin
  if not Kernel.FObjects.ContainsKey(UID) or (T.Wait.Obj <> Self) then
  begin
    PipeFinish(Kernel, T);
    T.SetResult(SCE_KERNEL_ERROR_WAIT_DELETE);
    Exit(True);
  end;
  Result := False;
  if Receivers.Count > 0 then
    Exit;
  var N := T.Wait.Data[1] - T.Wait.Data[3];
  if N > Used then
    N := Used;
  if (T.Wait.Data[2] = 0) and (BufSize > 0) and (Used < T.Wait.Data[1] - T.Wait.Data[3]) then
    N := 0;
  if N > 0 then
  begin
    PopBytes(T.Wait.Data[0] + T.Wait.Data[3], N);
    Inc(T.Wait.Data[3], N);
  end;
  Result := PipeDone(T);
  if Result then
  begin
    PipeFinish(Kernel, T);
    T.SetResult(0);
    Settle;
  end;
end;

procedure TPSPMsgPipe.WaitAbort(T: TPSPThread);
begin
  PipeFinish(Kernel, T);
end;

{ HLE: message boxes }

procedure TPSPKernel.hCreateMbx;
begin
  var Name: string;
  if not ReadName(FHLE.Arg(0), Name) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ERROR); Exit; end;
  var Attr := FHLE.Arg(1);
  if (Attr and not Cardinal($5FF)) <> 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR); Exit; end;
  var B := TPSPMbx.Create;
  B.Name := Name;
  B.Attr := Attr;
  B.Waiters.ByPriority := (Attr and $100) <> 0;
  Spend(PSPSyncCallNs);
  FHLE.Result(AddObject(B));
end;

procedure TPSPKernel.hDeleteMbx;
begin
  var B := TPSPMbx(GetObject(FHLE.Arg(0), TPSPMbx));
  if B = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MBXID); Exit; end;
  FHLE.Result(0);
  while B.Waiters.Count > 0 do
    EndWait(B.Waiters.First, SCE_KERNEL_ERROR_WAIT_DELETE);
  DeleteObject(B);
end;

procedure TPSPKernel.hSendMbx;
begin
  var B := TPSPMbx(GetObject(FHLE.Arg(0), TPSPMbx));
  if B = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MBXID); Exit; end;
  var Msg := FHLE.Arg(1);
  Spend(PSPSyncCallNs);
  if B.Waiters.Count > 0 then
  begin
    // Straight to the first receiver; the packet is not linked.
    var T := B.Waiters.First;
    if T.Wait.Data[0] <> 0 then
      FMemory.Write32(T.Wait.Data[0], Msg);
    FHLE.Result(0);
    EndWait(T, 0);
    Exit;
  end;
  if B.Contains(Msg) then
    begin FHLE.Result(SCE_KERNEL_ERROR_MESSAGEBOX_DUPLICATE_MESSAGE); Exit; end;
  B.Put(Msg);
  FHLE.Result(0);
end;

procedure TPSPKernel.ReceiveMbxCommon(AllowCB: Boolean);
begin
  var B := TPSPMbx(GetObject(FHLE.Arg(0), TPSPMbx));
  if B = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MBXID); Exit; end;
  var OutPtr := FHLE.Arg(1);
  Spend(PSPSyncCallNs);
  if B.Count > 0 then
  begin
    var Msg: Cardinal;
    var Err := B.Take(Msg);
    if (Err = 0) and (OutPtr <> 0) then
      FMemory.Write32(OutPtr, Msg);
    FHLE.Result(Err);
    if (Err = 0) and AllowCB then
      CheckCallbacksNow;
    Exit;
  end;
  if not CanWait then
    begin FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT); Exit; end;
  FHLE.Result(0);
  B.Waiters.Add(FCurrent);
  BeginWaitData(PSPWaitMbx, B, B.UID, FHLE.Arg(2), AllowCB, B.Retry, [OutPtr]);
end;

procedure TPSPKernel.hReceiveMbx;
begin
  ReceiveMbxCommon(False);
end;

procedure TPSPKernel.hReceiveMbxCB;
begin
  ReceiveMbxCommon(True);
end;

procedure TPSPKernel.hPollMbx;
begin
  var B := TPSPMbx(GetObject(FHLE.Arg(0), TPSPMbx));
  if B = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MBXID); Exit; end;
  if B.Count = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_MBOX_NOMSG); Exit; end;
  var Msg: Cardinal;
  var Err := B.Take(Msg);
  if (Err = 0) and (FHLE.Arg(1) <> 0) then
    FMemory.Write32(FHLE.Arg(1), Msg);
  FHLE.Result(Err);
end;

procedure TPSPKernel.hCancelReceiveMbx;
begin
  var B := TPSPMbx(GetObject(FHLE.Arg(0), TPSPMbx));
  if B = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MBXID); Exit; end;
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), Cardinal(B.Waiters.Count));
  FHLE.Result(0);
  while B.Waiters.Count > 0 do
    EndWait(B.Waiters.First, SCE_KERNEL_ERROR_WAIT_CANCEL);
end;

procedure TPSPKernel.hReferMbxStatus;
begin
  var B := TPSPMbx(GetObject(FHLE.Arg(0), TPSPMbx));
  if B = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MBXID); Exit; end;
  var Buf: array[0..$33] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var N := RawByteString(B.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  PCardinal(@Buf[$24])^ := B.Attr;
  PCardinal(@Buf[$28])^ := Cardinal(B.Waiters.Count);
  PCardinal(@Buf[$2C])^ := Cardinal(B.Count);
  PCardinal(@Buf[$30])^ := B.First;
  WriteInfo(FHLE.Arg(1), Buf, $34);
  FHLE.Result(0);
end;

{ HLE: message pipes }

function TPSPKernel.UserPartitionCheck(PartId: Integer): Cardinal;
begin
  // What a user module may create objects in.
  case PartId of
    2, 5, 6: Result := 0;
    1, 3, 4: if (FCurrent <> nil) and FCurrent.IsKernel then Result := 0 else Result := SCE_KERNEL_ERROR_ILLEGAL_PERM;
  else
    Result := SCE_KERNEL_ERROR_ILLEGAL_ARGUMENT;
  end;
end;

procedure TPSPKernel.hCreateMsgPipe;
begin
  var Name: string;
  if not ReadName(FHLE.Arg(0), Name) then
    begin FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY); Exit; end;
  var PartId := FHLE.ArgInt(1);
  var Err := UserPartitionCheck(PartId);
  if Err <> 0 then
    begin FHLE.Result(Err); Exit; end;
  var Attr := FHLE.Arg(2);
  if (Attr and not Cardinal($51FF)) <> 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR); Exit; end;
  var Size := FHLE.Arg(3);
  var P := Partition(PartId);
  if P = nil then
    P := FKernelPartition;
  var Block: Cardinal := 0;
  if Size > 0 then
  begin
    if Size > $7FFFFFFF then
      begin FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY); Exit; end;
    if (Attr and $4000) <> 0 then
      Block := P.Alloc(Size, akHigh, 0, 256, 'msgpipe:' + Name)
    else
      Block := P.Alloc(Size, akLow, 0, 256, 'msgpipe:' + Name);
    if Block = 0 then
      begin FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY); Exit; end;
  end;
  var MP := TPSPMsgPipe.Create;
  MP.Name := Name;
  MP.Attr := Attr;
  MP.PartitionId := PartId;
  MP.Block := Block;
  MP.BufSize := Size;
  SetLength(MP.Data, Size);
  MP.Senders.ByPriority := (Attr and $100) <> 0;
  MP.Receivers.ByPriority := (Attr and $1000) <> 0;
  Spend(PSPSyncCallNs);
  FHLE.Result(AddObject(MP));
end;

procedure TPSPKernel.hDeleteMsgPipe;
begin
  var MP := TPSPMsgPipe(GetObject(FHLE.Arg(0), TPSPMsgPipe));
  if MP = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MPPID); Exit; end;
  FHLE.Result(0);
  while MP.Senders.Count > 0 do
    EndWait(MP.Senders.First, SCE_KERNEL_ERROR_WAIT_DELETE);
  while MP.Receivers.Count > 0 do
    EndWait(MP.Receivers.First, SCE_KERNEL_ERROR_WAIT_DELETE);
  if MP.Block <> 0 then
  begin
    var P := Partition(MP.PartitionId);
    if P = nil then
      P := FKernelPartition;
    P.FreeBlock(MP.Block);
  end;
  DeleteObject(MP);
end;

// Mode: 0 waits, 1 waits with callbacks, 2 does not wait.
procedure TPSPKernel.SendMsgPipeCommon(Mode: Integer);
begin
  var MP := TPSPMsgPipe(GetObject(FHLE.Arg(0), TPSPMsgPipe));
  if MP = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MPPID); Exit; end;
  var Buf := FHLE.Arg(1);
  var Size := FHLE.Arg(2);
  var WaitMode := FHLE.Arg(3);
  var ResultPtr := FHLE.Arg(4);
  var TimeoutPtr: Cardinal := 0;
  if Mode <> 2 then
    TimeoutPtr := FHLE.Arg(5);
  if Integer(Size) < 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR); Exit; end;
  if WaitMode > 1 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MODE); Exit; end;
  if (MP.BufSize > 0) and (Size > MP.BufSize) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_SIZE); Exit; end;
  Spend(PSPSyncCallNs);
  var Done: Cardinal := 0;
  if MP.Senders.Count = 0 then
  begin
    // First straight to receivers already waiting, then into the buffer.
    while (Done < Size) and (MP.Receivers.Count > 0) and (MP.Used = 0) do
    begin
      var R := MP.Receivers.First;
      var N := R.Wait.Data[1] - R.Wait.Data[3];
      if N > Size - Done then
        N := Size - Done;
      if N > 0 then
        FMemory.Copy(R.Wait.Data[0] + R.Wait.Data[3], Buf + Done, N);
      Inc(R.Wait.Data[3], N);
      Inc(Done, N);
      if PipeDone(R) then
      begin
        PipeFinish(Self, R);
        EndWait(R, 0);
      end
      else
        Break;
    end;
    if Done < Size then
    begin
      var N := MP.FreeSize;
      if (WaitMode = 0) and (N < Size - Done) then
        N := 0;
      if N > Size - Done then
        N := Size - Done;
      if N > 0 then
      begin
        MP.PushBytes(Buf + Done, N);
        Inc(Done, N);
        MP.Settle;
      end;
    end;
  end;
  if (Done = Size) or ((WaitMode = 1) and (Done > 0)) then
  begin
    if ResultPtr <> 0 then
      FMemory.Write32(ResultPtr, Done);
    FHLE.Result(0);
    if Mode = 1 then
      CheckCallbacksNow;
    Exit;
  end;
  if Mode = 2 then
  begin
    if ResultPtr <> 0 then
      FMemory.Write32(ResultPtr, Done);
    FHLE.Result(SCE_KERNEL_ERROR_MPP_FULL);
    Exit;
  end;
  if not CanWait then
    begin FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT); Exit; end;
  FHLE.Result(0);
  MP.Senders.Add(FCurrent);
  BeginWaitData(PSPWaitMsgPipe, MP, MP.UID, TimeoutPtr, Mode = 1, MP.SendRetry,
    [Buf, Size, WaitMode, Done, 1, ResultPtr], MP.WaitAbort);
end;

procedure TPSPKernel.hSendMsgPipe;
begin
  SendMsgPipeCommon(0);
end;

procedure TPSPKernel.hSendMsgPipeCB;
begin
  SendMsgPipeCommon(1);
end;

procedure TPSPKernel.hTrySendMsgPipe;
begin
  SendMsgPipeCommon(2);
end;

procedure TPSPKernel.ReceiveMsgPipeCommon(Mode: Integer);
begin
  var MP := TPSPMsgPipe(GetObject(FHLE.Arg(0), TPSPMsgPipe));
  if MP = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MPPID); Exit; end;
  var Buf := FHLE.Arg(1);
  var Size := FHLE.Arg(2);
  var WaitMode := FHLE.Arg(3);
  var ResultPtr := FHLE.Arg(4);
  var TimeoutPtr: Cardinal := 0;
  if Mode <> 2 then
    TimeoutPtr := FHLE.Arg(5);
  if Integer(Size) < 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR); Exit; end;
  if WaitMode > 1 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MODE); Exit; end;
  if (MP.BufSize > 0) and (Size > MP.BufSize) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_SIZE); Exit; end;
  Spend(PSPSyncCallNs);
  var Done: Cardinal := 0;
  if MP.Receivers.Count = 0 then
  begin
    // The buffer first; senders waiting refill it as it empties.
    repeat
      var N := Size - Done;
      if N > MP.Used then
        N := MP.Used;
      if (WaitMode = 0) and (MP.BufSize > 0) and (Done = 0) and (MP.Used < Size) and (MP.Senders.Count = 0) then
        N := 0;
      if N > 0 then
      begin
        MP.PopBytes(Buf + Done, N);
        Inc(Done, N);
      end;
      if (Done < Size) and (MP.Senders.Count > 0) then
      begin
        var S := MP.Senders.First;
        var Before := S.Wait.Data[3];
        if MP.BufSize = 0 then
        begin
          // No buffer: straight from the sender.
          var M := Size - Done;
          if M > S.Wait.Data[1] - S.Wait.Data[3] then
            M := S.Wait.Data[1] - S.Wait.Data[3];
          if M > 0 then
            FMemory.Copy(Buf + Done, S.Wait.Data[0] + S.Wait.Data[3], M);
          Inc(S.Wait.Data[3], M);
          Inc(Done, M);
          if PipeDone(S) then
          begin
            PipeFinish(Self, S);
            EndWait(S, 0);
          end;
        end
        else
          MP.Settle;
        if (S.Wait.Data[3] = Before) and (MP.Used = 0) then
          Break;
      end
      else
        Break;
    until Done >= Size;
    MP.Settle;
  end;
  if (Done = Size) or ((WaitMode = 1) and (Done > 0)) then
  begin
    if ResultPtr <> 0 then
      FMemory.Write32(ResultPtr, Done);
    FHLE.Result(0);
    if Mode = 1 then
      CheckCallbacksNow;
    Exit;
  end;
  if Mode = 2 then
  begin
    if ResultPtr <> 0 then
      FMemory.Write32(ResultPtr, Done);
    FHLE.Result(SCE_KERNEL_ERROR_MPP_EMPTY);
    Exit;
  end;
  if not CanWait then
    begin FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT); Exit; end;
  FHLE.Result(0);
  MP.Receivers.Add(FCurrent);
  BeginWaitData(PSPWaitMsgPipe, MP, MP.UID, TimeoutPtr, Mode = 1, MP.ReceiveRetry,
    [Buf, Size, WaitMode, Done, 0, ResultPtr], MP.WaitAbort);
end;

procedure TPSPKernel.hReceiveMsgPipe;
begin
  ReceiveMsgPipeCommon(0);
end;

procedure TPSPKernel.hReceiveMsgPipeCB;
begin
  ReceiveMsgPipeCommon(1);
end;

procedure TPSPKernel.hTryReceiveMsgPipe;
begin
  ReceiveMsgPipeCommon(2);
end;

procedure TPSPKernel.hCancelMsgPipe;
begin
  var MP := TPSPMsgPipe(GetObject(FHLE.Arg(0), TPSPMsgPipe));
  if MP = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MPPID); Exit; end;
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), Cardinal(MP.Senders.Count));
  if FHLE.Arg(2) <> 0 then
    FMemory.Write32(FHLE.Arg(2), Cardinal(MP.Receivers.Count));
  FHLE.Result(0);
  while MP.Senders.Count > 0 do
    EndWait(MP.Senders.First, SCE_KERNEL_ERROR_WAIT_CANCEL);
  while MP.Receivers.Count > 0 do
    EndWait(MP.Receivers.First, SCE_KERNEL_ERROR_WAIT_CANCEL);
  MP.Used := 0;
end;

procedure TPSPKernel.hReferMsgPipeStatus;
begin
  var MP := TPSPMsgPipe(GetObject(FHLE.Arg(0), TPSPMsgPipe));
  if MP = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MPPID); Exit; end;
  var Buf: array[0..$37] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var N := RawByteString(MP.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  PCardinal(@Buf[$24])^ := MP.Attr;
  PCardinal(@Buf[$28])^ := MP.BufSize;
  PCardinal(@Buf[$2C])^ := MP.FreeSize;
  PCardinal(@Buf[$30])^ := Cardinal(MP.Senders.Count);
  PCardinal(@Buf[$34])^ := Cardinal(MP.Receivers.Count);
  WriteInfo(FHLE.Arg(1), Buf, $38);
  FHLE.Result(0);
end;
