// sceNetInet: a BSD stack with only its loopback interface up. Segments and
// datagrams take a moment to cross it, and a TCP send buffer drains into
// the peer's receive buffer as that has room. errno is per thread and
// cleared by every call that succeeds.

const
  EINTR = 4;
  EBADF = 9;
  EAGAIN = 11;
  EINVAL = 22;
  EMFILE = 24;
  ENOSPC = 28;
  EPIPE = 32;
  EOPNOTSUPP = 95;
  ECONNRESET = 104;
  ENOBUFS = 105;
  EAFNOSUPPORT = 106;
  ENOPROTOOPT = 109;
  ECONNREFUSED = 111;
  EADDRINUSE = 112;
  EHOSTUNREACH = 118;
  EINPROGRESS = 119;
  EALREADY = 120;
  EDESTADDRREQ = 121;
  EMSGSIZE = 122;
  EPROTONOSUPPORT = 123;
  EADDRNOTAVAIL = 125;
  EISCONN = 127;
  ENOTCONN = 128;

  INET_AF_INET = 2;
  INET_LOOPBACK = $7F000001;
  INET_MSG_PEEK = $2;
  INET_MSG_TRUNC = $10;
  INET_MSG_WAITALL = $40;
  INET_MSG_DONTWAIT = $80;
  SO_LINGER = $80;
  // The stack's descriptors run 1..255.
  InetMaxFd = 255;
  // Loopback delivery.
  InetLatencyNs = 100000;
  InetTickNs = 10000000;
  // The largest buffer the stack reserves.
  InetMaxBuffer = 262144 * 2048 div 2176;

{ TInetSocket }

constructor TInetSocket.Create(AKind: Integer);
begin
  inherited Create;
  Kind := AKind;
  Datagrams := TQueue<TInetDatagram>.Create;
  AcceptQueue := TList<TInetSocket>.Create;
  SynQueue := TList<TInetSocket>.Create;
  if Kind = 1 then
  begin
    SndBuf := $4000;
    RcvBuf := $4000;
  end
  else
  begin
    SndBuf := $2400;
    RcvBuf := $A280;
  end;
  SndLowat := $800;
  RcvLowat := 1;
  TTL := 64;
end;

destructor TInetSocket.Destroy;
begin
  Datagrams.Free;
  AcceptQueue.Free;
  SynQueue.Free;
  inherited;
end;

{ State }

procedure TPSPNet.InetReset;
begin
  FWaiters.Clear;
  FSockets.Clear;
  for var S in FPcbs do
    if not FDeadPcbs.Contains(S) then
      FDeadPcbs.Add(S);
  FPcbs.Clear;
  FDeadPcbs.Clear;
  FErrno.Clear;
  FInetInited := False;
  FNextFd := 1;
  FNextEphemeral := 1024;
end;

procedure TPSPNet.SetErrnoOf(T: TPSPThread; Err: Integer);
begin
  if T <> nil then
    FErrno.AddOrSetValue(T.UID, Err);
end;

procedure TPSPNet.InetFail(Err: Integer);
begin
  SetErrnoOf(FKernel.Current, Err);
  FHLE.Result(Cardinal(-1));
end;

procedure TPSPNet.InetOk(Value: Integer);
begin
  SetErrnoOf(FKernel.Current, 0);
  FHLE.Result(Cardinal(Value));
end;

function TPSPNet.SockOf(Fd: Integer): TInetSocket;
begin
  if not FSockets.TryGetValue(Fd, Result) then
    Result := nil;
end;

function TPSPNet.NewFd: Integer;
begin
  // Handed out round, after the last one given.
  for var K := 0 to InetMaxFd - 1 do
  begin
    var Fd := (FNextFd - 1 + K) mod InetMaxFd + 1;
    if not FSockets.ContainsKey(Fd) then
    begin
      FNextFd := Fd mod InetMaxFd + 1;
      Exit(Fd);
    end;
  end;
  Result := -1;
end;

function TPSPNet.NewSock(Kind: Integer): TInetSocket;
begin
  Result := TInetSocket.Create(Kind);
  // The stack keeps its control blocks newest first.
  FPcbs.Insert(0, Result);
end;

procedure TPSPNet.DropPcb(S: TInetSocket);
begin
  if S.Fd > 0 then
    FSockets.Remove(S.Fd);
  for var W in FWaiters.ToArray do
    if W.Sock = S then
      W.Sock := nil;
  if FPcbs.Remove(S) >= 0 then
    FDeadPcbs.Add(S);
end;

function TPSPNet.EphemeralPort(Kind: Integer): Integer;
begin
  repeat
    Inc(FNextEphemeral);
    if FNextEphemeral > 5000 then
      FNextEphemeral := 1025;
  until not PortInUse(Kind, 0, FNextEphemeral, nil);
  Result := FNextEphemeral;
end;

function TPSPNet.PortInUse(Kind: Integer; IP: Cardinal; Port: Integer; Self_: TInetSocket): Boolean;
begin
  for var S in FPcbs do
    if (S <> Self_) and (S.Kind = Kind) and S.Bound and (S.LocalPort = Port) and
      ((S.LocalIP = 0) or (IP = 0) or (S.LocalIP = IP)) and not (S.Closed and (S.State = isClosed)) then
      Exit(True);
  Result := False;
end;

function TPSPNet.ReadAddr(Addr: Cardinal; out IP: Cardinal; out Port: Integer): Boolean;
begin
  Result := FMemory.Read8(Addr + 1) = INET_AF_INET;
  Port := Integer((FMemory.Read8(Addr + 2) shl 8) or FMemory.Read8(Addr + 3));
  IP := (FMemory.Read8(Addr + 4) shl 24) or (FMemory.Read8(Addr + 5) shl 16) or (FMemory.Read8(Addr + 6) shl 8) or
    FMemory.Read8(Addr + 7);
end;

procedure TPSPNet.WriteAddr(Addr, LenPtr: Cardinal; IP: Cardinal; Port: Integer);
begin
  // As much of the address as the length allows.
  if (Addr = 0) or (LenPtr = 0) then
    Exit;
  var Bytes: array[0..15] of Byte;
  FillChar(Bytes, SizeOf(Bytes), 0);
  Bytes[0] := 16;
  Bytes[1] := INET_AF_INET;
  Bytes[2] := Port shr 8;
  Bytes[3] := Port and $FF;
  Bytes[4] := IP shr 24;
  Bytes[5] := (IP shr 16) and $FF;
  Bytes[6] := (IP shr 8) and $FF;
  Bytes[7] := IP and $FF;
  var N := Integer(FMemory.Read32(LenPtr));
  if N < 0 then
    N := 0;
  if N > 16 then
    N := 16;
  if N > 0 then
    FMemory.WriteBytes(Addr, Bytes[0], N);
  FMemory.Write32(LenPtr, Cardinal(N));
end;

procedure TPSPNet.Later(const Event: TProc);
begin
  FKernel.AddTimer(FKernel.Scheduler.Now + InetLatencyNs, Self,
    procedure
    begin
      Event();
      InetWake;
    end);
end;

{ Blocking }

procedure TPSPNet.FinishWaiter(W: TInetWaiter; Final: Boolean);
begin
  var Ret, Err: Integer;
  if not W.Attempt(Final, Ret, Err) then
    Exit;
  var T := W.Thread;
  if W.Timer <> 0 then
    FKernel.CancelTimer(W.Timer);
  FWaiters.Remove(W);
  SetErrnoOf(T, Err);
  if T.IsWaiting and (T.Wait.HLETag = 'inet') then
    FKernel.EndWait(T, Cardinal(Ret));
end;

procedure TPSPNet.InetWake;
begin
  for var W in FWaiters.ToArray do
    if FWaiters.Contains(W) then
      FinishWaiter(W, False);
end;

procedure TPSPNet.InetWaitAbort(T: TPSPThread);
begin
  for var W in FWaiters.ToArray do
    if W.Thread = T then
    begin
      if W.Timer <> 0 then
        FKernel.CancelTimer(W.Timer);
      FWaiters.Remove(W);
    end;
end;

procedure TPSPNet.InetAbortThread(T: TPSPThread);
begin
  for var W in FWaiters.ToArray do
    if W.Thread = T then
    begin
      W.Attempt :=
        function(Final: Boolean; out Ret, Err: Integer): Boolean
        begin
          Ret := -1;
          Err := EINTR;
          Result := True;
        end;
      FinishWaiter(W, True);
    end;
end;

procedure TPSPNet.Run(S: TInetSocket; TimeoutNs: Int64; NonBlocking: Boolean; const Attempt: TInetAttempt);
begin
  // Done at once if it can be; otherwise EAGAIN for a non-blocking call, or
  // the thread waits for the stack (until the timeout, when there is one).
  var Ret, Err: Integer;
  if Attempt(NonBlocking or not FKernel.CanWait, Ret, Err) then
  begin
    SetErrnoOf(FKernel.Current, Err);
    FHLE.Result(Cardinal(Ret));
    Exit;
  end;
  var W := TInetWaiter.Create;
  W.Thread := FKernel.Current;
  W.Sock := S;
  W.Attempt := Attempt;
  FWaiters.Add(W);
  FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, False, nil, InetWaitAbort, 'inet');
  if TimeoutNs > 0 then
    W.Timer := FKernel.AddTimer(FKernel.Scheduler.Now + TimeoutNs, W.Thread,
      procedure
      begin
        W.Timer := 0;
        if FWaiters.Contains(W) then
          FinishWaiter(W, True);
      end);
end;

{ Streams }

procedure TPSPNet.ScheduleTransfer(S: TInetSocket);
begin
  if S.TransferScheduled then
    Exit;
  S.TransferScheduled := True;
  Later(
    procedure
    begin
      S.TransferScheduled := False;
      Transfer(S);
    end);
end;

procedure TPSPNet.PeerReset(S: TInetSocket);
begin
  // An RST: after the peer's FIN it reads as a broken pipe.
  if S.FinReceived then
    S.SoError := EPIPE
  else
    S.SoError := ECONNRESET;
  S.State := isClosed;
  S.CantRecvMore := True;
  S.CantSendMore := True;
  S.RecvLen := 0;
  S.SendLen := 0;
  S.FinPending := False;
  S.Peer := nil;
  if S.Closed then
    DropPcb(S);
end;

procedure TPSPNet.Transfer(S: TInetSocket);
begin
  var P := S.Peer;
  if (S.State <> isEstablished) or (P = nil) then
    Exit;
  if P.Closed and (S.SendLen > 0) then
  begin
    // Data for a socket that is gone: it answers with an RST.
    S.SendLen := 0;
    Later(
      procedure
      begin
        PeerReset(S);
      end);
    P.Peer := nil;
    DropPcb(P);
    Exit;
  end;
  if S.SendLen > 0 then
  begin
    var N := S.SendLen;
    if not P.ReadShut then
      N := Min(N, P.RcvBuf - P.RecvLen);
    if N > 0 then
    begin
      if not P.ReadShut then
      begin
        if Length(P.RecvData) < P.RecvLen + N then
          SetLength(P.RecvData, P.RecvLen + N);
        Move(S.SendData[0], P.RecvData[P.RecvLen], N);
        Inc(P.RecvLen, N);
      end;
      Move(S.SendData[N], S.SendData[0], S.SendLen - N);
      Dec(S.SendLen, N);
    end;
  end;
  if (S.SendLen = 0) and S.FinPending then
  begin
    S.FinPending := False;
    P.FinReceived := True;
    P.CantRecvMore := True;
    if P.Closed and S.Closed then
    begin
      DropPcb(P);
      DropPcb(S);
    end;
  end;
end;

function TPSPNet.FindListener(IP: Cardinal; Port: Integer): TInetSocket;
begin
  for var S in FPcbs do
    if (S.Kind = 1) and (S.State = isListening) and not S.Closed and (S.LocalPort = Port) and
      ((S.LocalIP = 0) or (S.LocalIP = IP)) then
      Exit(S);
  Result := nil;
end;

function TPSPNet.QueueRoom(L: TInetSocket): Boolean;
begin
  Result := L.AcceptQueue.Count < (3 * Max(L.Backlog, 0)) div 2 + 1;
end;

procedure TPSPNet.Establish(L, C: TInetSocket);
begin
  var N := NewSock(1);
  N.Bound := True;
  N.LocalIP := C.PeerIP;
  N.LocalPort := C.PeerPort;
  N.PeerIP := C.LocalIP;
  N.PeerPort := C.LocalPort;
  N.HasPeer := True;
  N.Options := L.Options and not Cardinal($2);
  N.SndBuf := L.SndBuf;
  N.RcvBuf := L.RcvBuf;
  N.NBIO := L.NBIO;
  N.NoDelay := L.NoDelay;
  N.State := isEstablished;
  N.Peer := C;
  C.Peer := N;
  C.State := isEstablished;
  L.AcceptQueue.Add(N);
end;

procedure TPSPNet.Handshake(C: TInetSocket);
begin
  if C.State <> isConnecting then
    Exit;
  var L := FindListener(C.PeerIP, C.PeerPort);
  if L = nil then
  begin
    C.State := isClosed;
    C.ConnectFailed := True;
    C.SoError := ECONNREFUSED;
    if C.Closed then
      DropPcb(C);
  end
  else if QueueRoom(L) then
    Establish(L, C)
  else if not L.SynQueue.Contains(C) then
    // Dropped for now; the retransmission gets in when there is room.
    L.SynQueue.Add(C);
end;

procedure TPSPNet.CloseSocket(S: TInetSocket; Reset: Boolean);
begin
  S.Closed := True;
  FSockets.Remove(S.Fd);
  S.Fd := 0;
  // Threads blocked on it give up.
  for var W in FWaiters.ToArray do
    if W.Sock = S then
    begin
      W.Attempt :=
        function(Final: Boolean; out Ret, Err: Integer): Boolean
        begin
          Ret := -1;
          Err := EBADF;
          Result := True;
        end;
      FinishWaiter(W, True);
    end;
  if S.Kind <> 1 then
  begin
    DropPcb(S);
    Exit;
  end;
  case S.State of
    isListening:
      begin
        for var N in S.AcceptQueue.ToArray do
        begin
          var C := N.Peer;
          N.Closed := True;
          DropPcb(N);
          if C <> nil then
            Later(
              procedure
              begin
                PeerReset(C);
              end);
        end;
        for var C in S.SynQueue.ToArray do
          Later(
            procedure
            begin
              Handshake(C);
            end);
        S.AcceptQueue.Clear;
        S.SynQueue.Clear;
        S.State := isClosed;
        DropPcb(S);
      end;
    isEstablished:
      begin
        var P := S.Peer;
        if Reset or (((S.Options and SO_LINGER) <> 0) and (S.LingerTime = 0)) then
        begin
          S.Peer := nil;
          DropPcb(S);
          if P <> nil then
          begin
            P.Peer := nil;
            Later(
              procedure
              begin
                PeerReset(P);
              end);
          end;
        end
        else
        begin
          S.FinPending := True;
          S.CantRecvMore := True;
          S.CantSendMore := True;
          ScheduleTransfer(S);
        end;
      end;
  else
    begin
      for var L in FPcbs do
        L.SynQueue.Remove(S);
      DropPcb(S);
    end;
  end;
end;

function TPSPNet.Readable(S: TInetSocket): Boolean;
begin
  if S.SoError <> 0 then
    Exit(True);
  if S.Kind = 1 then
    case S.State of
      isListening: Result := S.AcceptQueue.Count > 0;
      isEstablished: Result := (S.RecvLen >= S.RcvLowat) or S.CantRecvMore;
    else
      Result := S.CantRecvMore;
    end
  else
    Result := (S.Datagrams.Count > 0) or S.ReadShut;
end;

function TPSPNet.Writable(S: TInetSocket): Boolean;
begin
  if S.SoError <> 0 then
    Exit(True);
  if S.Kind = 1 then
    case S.State of
      isEstablished: Result := S.CantSendMore or (S.SndBuf - S.SendLen >= S.SndLowat);
      isConnecting, isListening: Result := False;
    else
      Result := S.ConnectFailed or S.CantSendMore;
    end
  else
    Result := True;
end;

{ Sending and receiving }

procedure TPSPNet.DeliverDatagram(S: TInetSocket; const Data: TBytes; ToIP: Cardinal; ToPort: Integer);
begin
  var FromIP := S.LocalIP;
  if FromIP = 0 then
    FromIP := INET_LOOPBACK;
  var FromPort := S.LocalPort;
  var Connected := S.HasPeer;
  Later(
    procedure
    begin
      var R: TInetSocket := nil;
      for var X in FPcbs do
        if (X.Kind = 2) and not X.Closed and X.Bound and (X.LocalPort = ToPort) and
          ((X.LocalIP = 0) or (X.LocalIP = ToIP) or (ToIP = 0)) then
        begin
          if X.HasPeer and ((X.PeerIP <> FromIP) or (X.PeerPort <> FromPort)) then
            Continue;
          R := X;
          Break;
        end;
      if R = nil then
      begin
        // Port unreachable: only a connected socket hears of it.
        if Connected and FPcbs.Contains(S) then
          S.SoError := ECONNREFUSED;
        Exit;
      end;
      if R.ReadShut or (R.QueuedBytes + Length(Data) > R.RcvBuf) then
        Exit;
      var D: TInetDatagram;
      D.Data := Data;
      D.FromIP := FromIP;
      D.FromPort := FromPort;
      R.Datagrams.Enqueue(D);
      Inc(R.QueuedBytes, Length(Data));
    end);
end;

procedure TPSPNet.SendCall(Fd: Integer; const Data: TBytes; Flags: Integer; HasTo: Boolean; ToIP: Cardinal;
  ToPort: Integer);
begin
  var S := SockOf(Fd);
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  var Len := Length(Data);
  if S.Kind <> 1 then
  begin
    if S.WriteShut then
    begin
      InetFail(EPIPE);
      Exit;
    end;
    if S.SoError <> 0 then
    begin
      var E := S.SoError;
      S.SoError := 0;
      InetFail(E);
      Exit;
    end;
    if HasTo and S.HasPeer then
    begin
      InetFail(EISCONN);
      Exit;
    end;
    if not HasTo then
    begin
      if not S.HasPeer then
      begin
        InetFail(EDESTADDRREQ);
        Exit;
      end;
      ToIP := S.PeerIP;
      ToPort := S.PeerPort;
    end;
    if Len > S.SndBuf then
    begin
      InetFail(EMSGSIZE);
      Exit;
    end;
    if (ToIP <> 0) and (ToIP shr 24 <> 127) then
    begin
      InetFail(EHOSTUNREACH);
      Exit;
    end;
    if not S.Bound then
    begin
      S.Bound := True;
      S.LocalIP := 0;
      S.LocalPort := EphemeralPort(S.Kind);
    end;
    if ToIP shr 24 = 127 then
      ToIP := INET_LOOPBACK;
    DeliverDatagram(S, Data, ToIP, ToPort);
    InetOk(Len);
    Exit;
  end;
  // A stream.
  var NonBlocking := S.NBIO or ((Flags and INET_MSG_DONTWAIT) <> 0);
  var Sent := 0;
  Run(S, Int64(S.SndTimeo) * InetTickNs, NonBlocking,
    function(Final: Boolean; out Ret, Err: Integer): Boolean
    begin
      Result := True;
      Ret := -1;
      if S.CantSendMore or S.WriteShut then
      begin
        Err := EPIPE;
        if S.SoError <> 0 then
        begin
          Err := S.SoError;
          S.SoError := 0;
        end;
        Exit;
      end;
      if S.SoError <> 0 then
      begin
        Err := S.SoError;
        S.SoError := 0;
        Exit;
      end;
      if S.State <> isEstablished then
      begin
        Err := ENOTCONN;
        Exit;
      end;
      var Room := S.SndBuf - S.SendLen;
      var N := Min(Room, Len - Sent);
      if N > 0 then
      begin
        if Length(S.SendData) < S.SendLen + N then
          SetLength(S.SendData, S.SendLen + N);
        Move(Data[Sent], S.SendData[S.SendLen], N);
        Inc(S.SendLen, N);
        Inc(Sent, N);
        ScheduleTransfer(S);
      end;
      if (Sent = Len) or (Final and (Sent > 0)) then
      begin
        Ret := Sent;
        Err := 0;
      end
      else if Final then
        Err := EAGAIN
      else
        Result := False;
    end);
end;

procedure TPSPNet.RecvCall(Fd: Integer; const Segs: TArray<TPair<Cardinal, Integer>>; Flags: Integer;
  FromPtr, FromLenPtr, MsgFlagsPtr: Cardinal);
begin
  var S := SockOf(Fd);
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  var Len := 0;
  for var P in Segs do
    Inc(Len, P.Value);
  var Peek := (Flags and INET_MSG_PEEK) <> 0;
  var NonBlocking := S.NBIO or ((Flags and INET_MSG_DONTWAIT) <> 0);
  var Scatter: TProc<TBytes, Integer> :=
    procedure(Src: TBytes; Count: Integer)
    begin
      var Done := 0;
      for var P in Segs do
      begin
        if Done >= Count then
          Break;
        var N := Min(P.Value, Count - Done);
        if N > 0 then
          FMemory.WriteBytes(P.Key, Src[Done], N);
        Inc(Done, N);
      end;
    end;
  if S.Kind <> 1 then
  begin
    Run(S, Int64(S.RcvTimeo) * InetTickNs, NonBlocking,
      function(Final: Boolean; out Ret, Err: Integer): Boolean
      begin
        Result := True;
        Ret := -1;
        if S.SoError <> 0 then
        begin
          Err := S.SoError;
          S.SoError := 0;
          Exit;
        end;
        if S.Datagrams.Count > 0 then
        begin
          var D := S.Datagrams.Peek;
          if not Peek then
          begin
            S.Datagrams.Dequeue;
            Dec(S.QueuedBytes, Length(D.Data));
          end;
          var N := Min(Len, Length(D.Data));
          Scatter(D.Data, N);
          WriteAddr(FromPtr, FromLenPtr, D.FromIP, D.FromPort);
          if MsgFlagsPtr <> 0 then
            if N < Length(D.Data) then
              FMemory.Write32(MsgFlagsPtr, INET_MSG_TRUNC)
            else
              FMemory.Write32(MsgFlagsPtr, 0);
          Ret := N;
          Err := 0;
          Exit;
        end;
        if S.ReadShut then
        begin
          Ret := 0;
          Err := 0;
          Exit;
        end;
        if Final then
          Err := EAGAIN
        else
          Result := False;
      end);
    Exit;
  end;
  var WaitAll := (Flags and INET_MSG_WAITALL) <> 0;
  Run(S, Int64(S.RcvTimeo) * InetTickNs, NonBlocking,
    function(Final: Boolean; out Ret, Err: Integer): Boolean
    begin
      Result := True;
      Ret := -1;
      if S.SoError <> 0 then
      begin
        Err := S.SoError;
        S.SoError := 0;
        Exit;
      end;
      if (S.State in [isClosed, isListening, isConnecting]) and not S.CantRecvMore then
      begin
        Err := ENOTCONN;
        Exit;
      end;
      if S.ReadShut then
      begin
        Ret := 0;
        Err := 0;
        Exit;
      end;
      if (S.RecvLen > 0) and ((Len = 0) or not WaitAll or (S.RecvLen >= Len) or S.CantRecvMore) then
      begin
        var N := Min(Len, S.RecvLen);
        Scatter(S.RecvData, N);
        if not Peek and (N > 0) then
        begin
          Move(S.RecvData[N], S.RecvData[0], S.RecvLen - N);
          Dec(S.RecvLen, N);
          // The window opens again for the peer.
          var P := S.Peer;
          if (P <> nil) and (P.SendLen > 0) then
            ScheduleTransfer(P);
        end;
        if MsgFlagsPtr <> 0 then
          FMemory.Write32(MsgFlagsPtr, 0);
        Ret := N;
        Err := 0;
        Exit;
      end;
      if S.CantRecvMore or (Len = 0) then
      begin
        Ret := 0;
        Err := 0;
        Exit;
      end;
      if Final then
        Err := EAGAIN
      else
        Result := False;
    end);
end;
