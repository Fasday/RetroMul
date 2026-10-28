// The sceNetInet calls.

const
  // A connection the listener had no room for gets in on its SYN's retransmission.
  InetSynRetryNs = 3000000000;
  POLLIN = $1;
  POLLOUT = $4;
  POLLERR = $8;
  POLLHUP = $10;
  POLLNVAL = $20;
  POLLRDNORM = $40;

procedure TPSPNet.hInetInit;
begin
  FInetInited := True;
  FHLE.Result(0);
end;

procedure TPSPNet.hInetTerm;
begin
  for var S in FSockets.Values.ToArray do
    CloseSocket(S, False);
  FInetInited := False;
  FHLE.Result(0);
end;

procedure TPSPNet.hInetSocket;
begin
  var Domain := FHLE.ArgInt(0);
  var Kind := FHLE.ArgInt(1);
  var Protocol := FHLE.ArgInt(2);
  var Ok := Domain = INET_AF_INET;
  case Kind of
    1: Ok := Ok and (Protocol in [0, 6]);
    2: Ok := Ok and (Protocol in [0, 17]);
    3: ;
  else
    Ok := False;
  end;
  if not Ok then
  begin
    InetFail(EPROTONOSUPPORT);
    Exit;
  end;
  var Fd := NewFd;
  if Fd < 0 then
  begin
    InetFail(EMFILE);
    Exit;
  end;
  var S := NewSock(Kind);
  S.Fd := Fd;
  FSockets.Add(Fd, S);
  InetOk(Fd);
end;

procedure TPSPNet.hInetBind;
begin
  var S := SockOf(FHLE.ArgInt(0));
  var Addr := FHLE.Arg(1);
  var Len := FHLE.ArgInt(2);
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  if S.Bound or (Addr = 0) or (Len < 16) then
  begin
    InetFail(EINVAL);
    Exit;
  end;
  var IP: Cardinal;
  var Port: Integer;
  // The family is not looked at: an address of another kind is not the console's.
  if not ReadAddr(Addr, IP, Port) or ((IP <> 0) and (IP <> INET_LOOPBACK)) then
  begin
    InetFail(EADDRNOTAVAIL);
    Exit;
  end;
  if Port = 0 then
    Port := EphemeralPort(S.Kind)
  else if ((S.Options and $204) = 0) and PortInUse(S.Kind, IP, Port, S) then
  begin
    InetFail(EADDRINUSE);
    Exit;
  end;
  S.Bound := True;
  S.LocalIP := IP;
  S.LocalPort := Port;
  InetOk(0);
end;

procedure TPSPNet.hInetListen;
begin
  var S := SockOf(FHLE.ArgInt(0));
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  if S.Kind <> 1 then
  begin
    InetFail(EOPNOTSUPP);
    Exit;
  end;
  if not S.Bound then
  begin
    S.ListenFailed := True;
    InetFail(EINVAL);
    Exit;
  end;
  if S.State in [isConnecting, isEstablished] then
  begin
    InetFail(EINVAL);
    Exit;
  end;
  S.State := isListening;
  S.Backlog := FHLE.ArgInt(1);
  InetOk(0);
end;

procedure TPSPNet.hInetAccept;
begin
  var S := SockOf(FHLE.ArgInt(0));
  var Addr := FHLE.Arg(1);
  var LenPtr := FHLE.Arg(2);
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  if S.Kind <> 1 then
  begin
    InetFail(EOPNOTSUPP);
    Exit;
  end;
  if S.State <> isListening then
  begin
    InetFail(EINVAL);
    Exit;
  end;
  Run(S, 0, S.NBIO,
    function(Final: Boolean; out Ret, Err: Integer): Boolean
    begin
      Result := True;
      Ret := -1;
      if S.State <> isListening then
      begin
        Err := EINVAL;
        Exit;
      end;
      if S.AcceptQueue.Count = 0 then
      begin
        if Final then
          Err := EAGAIN
        else
          Result := False;
        Exit;
      end;
      var Fd := NewFd;
      if Fd < 0 then
      begin
        Err := EMFILE;
        Exit;
      end;
      var N := S.AcceptQueue[0];
      S.AcceptQueue.Delete(0);
      N.Fd := Fd;
      FSockets.Add(Fd, N);
      WriteAddr(Addr, LenPtr, N.PeerIP, N.PeerPort);
      if S.SynQueue.Count > 0 then
      begin
        var C := S.SynQueue[0];
        S.SynQueue.Delete(0);
        FKernel.AddTimer(FKernel.Scheduler.Now + InetSynRetryNs, Self,
          procedure
          begin
            if FPcbs.Contains(C) then
              Handshake(C);
            InetWake;
          end);
      end;
      Ret := Fd;
      Err := 0;
    end);
end;

procedure TPSPNet.hInetConnect;
begin
  var S := SockOf(FHLE.ArgInt(0));
  var Addr := FHLE.Arg(1);
  var Len := FHLE.ArgInt(2);
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  if (Addr = 0) or (Len < 16) then
  begin
    InetFail(EINVAL);
    Exit;
  end;
  var IP: Cardinal;
  var Port: Integer;
  if not ReadAddr(Addr, IP, Port) then
  begin
    InetFail(EAFNOSUPPORT);
    Exit;
  end;
  if S.Kind = 1 then
  begin
    if (S.State = isListening) or S.ListenFailed or S.ConnectFailed then
    begin
      InetFail(EINVAL);
      Exit;
    end;
    if S.State = isEstablished then
    begin
      InetFail(EISCONN);
      Exit;
    end;
    if S.State = isConnecting then
    begin
      InetFail(EALREADY);
      Exit;
    end;
  end;
  if (IP <> 0) and (IP shr 24 <> 127) then
  begin
    InetFail(EHOSTUNREACH);
    Exit;
  end;
  if not S.Bound then
  begin
    S.Bound := True;
    S.LocalPort := EphemeralPort(S.Kind);
  end;
  if S.LocalIP = 0 then
    S.LocalIP := INET_LOOPBACK;
  S.PeerIP := INET_LOOPBACK;
  S.PeerPort := Port;
  S.HasPeer := True;
  if S.Kind <> 1 then
  begin
    InetOk(0);
    Exit;
  end;
  S.State := isConnecting;
  Later(
    procedure
    begin
      Handshake(S);
    end);
  if S.NBIO then
  begin
    InetFail(EINPROGRESS);
    Exit;
  end;
  Run(S, 0, False,
    function(Final: Boolean; out Ret, Err: Integer): Boolean
    begin
      Result := True;
      Ret := -1;
      if S.State = isEstablished then
      begin
        Ret := 0;
        Err := 0;
      end
      else if S.State = isConnecting then
      begin
        Err := EAGAIN;
        Result := Final;
      end
      else
      begin
        Err := S.SoError;
        S.SoError := 0;
        if Err = 0 then
          Err := ECONNREFUSED;
      end;
    end);
end;

function GuestBytesOf(M: TPSPMemory; Addr: Cardinal; Len: Integer): TBytes;
begin
  SetLength(Result, Max(Len, 0));
  if Len > 0 then
    M.ReadBytes(Addr, Result[0], Len);
end;

procedure TPSPNet.hInetSend;
begin
  if FHLE.ArgInt(2) < 0 then
  begin
    InetFail(EINVAL);
    Exit;
  end;
  SendCall(FHLE.ArgInt(0), GuestBytesOf(FMemory, FHLE.Arg(1), FHLE.ArgInt(2)), FHLE.ArgInt(3), False, 0, 0);
end;

procedure TPSPNet.hInetSendto;
begin
  var Fd := FHLE.ArgInt(0);
  var Len := FHLE.ArgInt(2);
  var ToAddr := FHLE.Arg(4);
  if Len < 0 then
  begin
    InetFail(EINVAL);
    Exit;
  end;
  var IP: Cardinal := 0;
  var Port := 0;
  var S := SockOf(Fd);
  var HasTo := (ToAddr <> 0) and (S <> nil) and (S.Kind <> 1);
  if HasTo then
  begin
    if FHLE.ArgInt(5) < 16 then
    begin
      InetFail(EINVAL);
      Exit;
    end;
    if not ReadAddr(ToAddr, IP, Port) then
    begin
      InetFail(EAFNOSUPPORT);
      Exit;
    end;
  end;
  SendCall(Fd, GuestBytesOf(FMemory, FHLE.Arg(1), Len), FHLE.ArgInt(3), HasTo, IP, Port);
end;

procedure TPSPNet.hInetSendmsg;
begin
  var Fd := FHLE.ArgInt(0);
  var Msg := FHLE.Arg(1);
  var S := SockOf(Fd);
  if (S = nil) or (Msg = 0) then
  begin
    InetFail(EBADF);
    Exit;
  end;
  var Name := FMemory.Read32(Msg);
  var Iov := FMemory.Read32(Msg + 8);
  var IovLen := Integer(FMemory.Read32(Msg + 12));
  var Data: TBytes := nil;
  for var I := 0 to IovLen - 1 do
    Data := Data + GuestBytesOf(FMemory, FMemory.Read32(Iov + Cardinal(I * 8)),
      Integer(FMemory.Read32(Iov + Cardinal(I * 8) + 4)));
  var IP: Cardinal := 0;
  var Port := 0;
  var HasTo := (Name <> 0) and (S.Kind <> 1);
  if HasTo and not ReadAddr(Name, IP, Port) then
  begin
    InetFail(EAFNOSUPPORT);
    Exit;
  end;
  SendCall(Fd, Data, FHLE.ArgInt(2), HasTo, IP, Port);
end;

procedure TPSPNet.hInetRecv;
begin
  RecvCall(FHLE.ArgInt(0), [TPair<Cardinal, Integer>.Create(FHLE.Arg(1), Max(FHLE.ArgInt(2), 0))], FHLE.ArgInt(3),
    0, 0, 0);
end;

procedure TPSPNet.hInetRecvfrom;
begin
  RecvCall(FHLE.ArgInt(0), [TPair<Cardinal, Integer>.Create(FHLE.Arg(1), Max(FHLE.ArgInt(2), 0))], FHLE.ArgInt(3),
    FHLE.Arg(4), FHLE.Arg(5), 0);
end;

procedure TPSPNet.hInetRecvmsg;
begin
  var Msg := FHLE.Arg(1);
  if (SockOf(FHLE.ArgInt(0)) = nil) or (Msg = 0) then
  begin
    InetFail(EBADF);
    Exit;
  end;
  var Iov := FMemory.Read32(Msg + 8);
  var IovLen := Integer(FMemory.Read32(Msg + 12));
  var Segs: TArray<TPair<Cardinal, Integer>> := nil;
  for var I := 0 to IovLen - 1 do
    Segs := Segs + [TPair<Cardinal, Integer>.Create(FMemory.Read32(Iov + Cardinal(I * 8)),
      Integer(FMemory.Read32(Iov + Cardinal(I * 8) + 4)))];
  var Name := FMemory.Read32(Msg);
  var NameLenPtr: Cardinal := 0;
  if Name <> 0 then
    NameLenPtr := Msg + 4;
  RecvCall(FHLE.ArgInt(0), Segs, FHLE.ArgInt(2), Name, NameLenPtr, Msg + 24);
end;

procedure TPSPNet.hInetClose;
begin
  var S := SockOf(FHLE.ArgInt(0));
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  CloseSocket(S, False);
  InetOk(0);
end;

procedure TPSPNet.hInetCloseWithRST;
begin
  var S := SockOf(FHLE.ArgInt(0));
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  CloseSocket(S, True);
  InetOk(0);
end;

procedure TPSPNet.hInetShutdown;
begin
  var S := SockOf(FHLE.ArgInt(0));
  var How := FHLE.ArgInt(1);
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  if (How < 0) or (How > 2) then
  begin
    InetFail(EINVAL);
    Exit;
  end;
  if How <> 1 then
  begin
    S.ReadShut := True;
    S.CantRecvMore := True;
    S.RecvLen := 0;
    S.Datagrams.Clear;
    S.QueuedBytes := 0;
  end;
  if How <> 0 then
  begin
    S.WriteShut := True;
    if (S.Kind = 1) and (S.State = isEstablished) and not S.CantSendMore then
    begin
      S.CantSendMore := True;
      S.FinPending := True;
      ScheduleTransfer(S);
    end;
  end;
  InetOk(0);
  InetWake;
end;

procedure TPSPNet.hInetGetsockname;
begin
  var S := SockOf(FHLE.ArgInt(0));
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  WriteAddr(FHLE.Arg(1), FHLE.Arg(2), S.LocalIP, S.LocalPort);
  InetOk(0);
end;

procedure TPSPNet.hInetGetpeername;
begin
  var S := SockOf(FHLE.ArgInt(0));
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  var Connected := S.HasPeer;
  if S.Kind = 1 then
    Connected := Connected and (S.State in [isConnecting, isEstablished]);
  if not Connected then
  begin
    InetFail(ENOTCONN);
    Exit;
  end;
  WriteAddr(FHLE.Arg(1), FHLE.Arg(2), S.PeerIP, S.PeerPort);
  InetOk(0);
end;

procedure TPSPNet.hInetSetsockopt;
begin
  var S := SockOf(FHLE.ArgInt(0));
  var Level := FHLE.ArgInt(1);
  var Name := FHLE.ArgInt(2);
  var Val := FHLE.Arg(3);
  var Len := FHLE.ArgInt(4);
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  var V := 0;
  if Len >= 4 then
    V := Integer(FMemory.Read32(Val));
  case Level of
    $FFFF:
      case Name of
        $1, $4, $8, $10, $20, $100, $200, $80, $1001..$1006, $1009:
          begin
            if (Len < 4) or ((Name = $80) and (Len < 8)) then
            begin
              InetFail(EINVAL);
              Exit;
            end;
            case Name of
              $80:
                begin
                  if V <> 0 then
                    S.Options := S.Options or SO_LINGER
                  else
                    S.Options := S.Options and not Cardinal(SO_LINGER);
                  S.LingerTime := Integer(FMemory.Read32(Val + 4));
                end;
              $1001, $1002:
                begin
                  if V <= 0 then
                  begin
                    InetFail(EINVAL);
                    Exit;
                  end;
                  if V > InetMaxBuffer then
                  begin
                    InetFail(ENOBUFS);
                    Exit;
                  end;
                  if Name = $1001 then
                    S.SndBuf := V
                  else
                    S.RcvBuf := V;
                end;
              $1003: S.SndLowat := Max(1, Min(V, S.SndBuf));
              $1004: S.RcvLowat := Max(1, Min(V, S.RcvBuf));
              // A count of microseconds, kept in ticks.
              $1005: S.SndTimeo := Integer(Cardinal(V) div 10000);
              $1006: S.RcvTimeo := Integer(Cardinal(V) div 10000);
              $1009: S.NBIO := V <> 0;
            else
              if V <> 0 then
                S.Options := S.Options or Cardinal(Name)
              else
                S.Options := S.Options and not Cardinal(Name);
            end;
          end;
      else
        InetFail(ENOPROTOOPT);
        Exit;
      end;
    0:
      if Name = 4 then
      begin
        if Len < 4 then
        begin
          InetFail(EINVAL);
          Exit;
        end;
        S.TTL := V;
      end
      else
      begin
        InetFail(ENOPROTOOPT);
        Exit;
      end;
    6:
      begin
        if S.Kind <> 1 then
        begin
          InetFail(EINVAL);
          Exit;
        end;
        if Name <> 1 then
        begin
          InetFail(ENOPROTOOPT);
          Exit;
        end;
        if Len < 4 then
        begin
          InetFail(EINVAL);
          Exit;
        end;
        S.NoDelay := V <> 0;
      end;
  else
    InetFail(EINVAL);
    Exit;
  end;
  InetOk(0);
end;

procedure TPSPNet.hInetGetsockopt;
begin
  var S := SockOf(FHLE.ArgInt(0));
  var Level := FHLE.ArgInt(1);
  var Name := FHLE.ArgInt(2);
  var Val := FHLE.Arg(3);
  var LenPtr := FHLE.Arg(4);
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  var Words: TArray<Cardinal>;
  case Level of
    $FFFF:
      case Name of
        $1, $4, $8, $10, $20, $100, $200: Words := [S.Options and Cardinal(Name)];
        $80: Words := [S.Options and SO_LINGER, Cardinal(S.LingerTime)];
        $1001: Words := [Cardinal(S.SndBuf)];
        $1002: Words := [Cardinal(S.RcvBuf)];
        $1003: Words := [Cardinal(S.SndLowat)];
        $1004: Words := [Cardinal(S.RcvLowat)];
        $1005: Words := [Cardinal(S.SndTimeo)];
        $1006: Words := [Cardinal(S.RcvTimeo)];
        $1007:
          begin
            // A pending error reads as the stack's error code for it.
            if S.SoError <> 0 then
              Words := [$80010000 or Cardinal(S.SoError)]
            else
              Words := [0];
            S.SoError := 0;
          end;
        $1008: Words := [Cardinal(S.Kind)];
        $1009: Words := [Cardinal(Ord(S.NBIO) * $80)];
      else
        InetFail(ENOPROTOOPT);
        Exit;
      end;
    0:
      if Name = 4 then
        Words := [Cardinal(S.TTL)]
      else
      begin
        InetFail(ENOPROTOOPT);
        Exit;
      end;
    6:
      begin
        if S.Kind <> 1 then
        begin
          InetFail(EINVAL);
          Exit;
        end;
        if Name <> 1 then
        begin
          InetFail(ENOPROTOOPT);
          Exit;
        end;
        Words := [Cardinal(Ord(S.NoDelay) * 4)];
      end;
  else
    InetFail(EINVAL);
    Exit;
  end;
  var Bytes: TBytes;
  SetLength(Bytes, Length(Words) * 4);
  for var I := 0 to High(Words) do
    PCardinal(@Bytes[I * 4])^ := Words[I];
  var N := 0;
  if LenPtr <> 0 then
    N := EnsureRange(Integer(FMemory.Read32(LenPtr)), 0, Length(Bytes));
  if N > 0 then
    FMemory.WriteBytes(Val, Bytes[0], N);
  if LenPtr <> 0 then
    FMemory.Write32(LenPtr, Cardinal(N));
  InetOk(0);
end;

procedure TPSPNet.hInetSelect;
begin
  var NFds := EnsureRange(FHLE.ArgInt(0), 0, 256);
  var Sets: TArray<Cardinal> := [FHLE.Arg(1), FHLE.Arg(2), FHLE.Arg(3)];
  var Tv := FHLE.Arg(4);
  var TimeoutNs: Int64 := 0;
  var Poll := False;
  if Tv <> 0 then
  begin
    var Sec := Integer(FMemory.Read32(Tv));
    var USec := Integer(FMemory.Read32(Tv + 4));
    if (Sec < 0) or (USec < 0) or (USec >= 1000000) then
    begin
      InetFail(EINVAL);
      Exit;
    end;
    TimeoutNs := Int64(Sec) * 1000000000 + Int64(USec) * 1000;
    Poll := TimeoutNs = 0;
  end;
  var Want: array[0..2] of array[0..7] of Cardinal;
  for var K := 0 to 2 do
    for var I := 0 to 7 do
      if Sets[K] <> 0 then
        Want[K][I] := FMemory.Read32(Sets[K] + Cardinal(I * 4))
      else
        Want[K][I] := 0;
  for var Fd := 0 to NFds - 1 do
    for var K := 0 to 2 do
      if ((Want[K][Fd shr 5] shr (Fd and 31)) and 1 <> 0) and (SockOf(Fd) = nil) then
      begin
        InetFail(EBADF);
        Exit;
      end;
  Run(nil, TimeoutNs, Poll,
    function(Final: Boolean; out Ret, Err: Integer): Boolean
    begin
      var Got: array[0..2] of array[0..7] of Cardinal;
      FillChar(Got, SizeOf(Got), 0);
      var Count := 0;
      for var Fd := 0 to NFds - 1 do
        for var K := 0 to 1 do
          if (Want[K][Fd shr 5] shr (Fd and 31)) and 1 <> 0 then
          begin
            var S := SockOf(Fd);
            if (S <> nil) and (((K = 0) and Readable(S)) or ((K = 1) and Writable(S))) then
            begin
              Got[K][Fd shr 5] := Got[K][Fd shr 5] or (Cardinal(1) shl (Fd and 31));
              Inc(Count);
            end;
          end;
      Result := (Count > 0) or Final;
      if not Result then
        Exit;
      for var K := 0 to 2 do
        if Sets[K] <> 0 then
          for var I := 0 to 7 do
            FMemory.Write32(Sets[K] + Cardinal(I * 4), Got[K][I]);
      Ret := Count;
      Err := 0;
    end);
end;

procedure TPSPNet.hInetPoll;
begin
  var Fds := FHLE.Arg(0);
  var N := Max(FHLE.ArgInt(1), 0);
  var TimeoutMs := FHLE.ArgInt(2);
  var TimeoutNs: Int64 := 0;
  if TimeoutMs > 0 then
    TimeoutNs := Int64(TimeoutMs) * 1000000;
  Run(nil, TimeoutNs, TimeoutMs = 0,
    function(Final: Boolean; out Ret, Err: Integer): Boolean
    begin
      var R: TArray<Cardinal>;
      SetLength(R, N);
      var Count := 0;
      for var I := 0 to N - 1 do
      begin
        var E := FMemory.Read16(Fds + Cardinal(I * 8) + 4);
        var S := SockOf(Integer(FMemory.Read32(Fds + Cardinal(I * 8))));
        if S = nil then
          R[I] := POLLNVAL
        else
        begin
          if ((E and (POLLIN or POLLRDNORM)) <> 0) and Readable(S) then
            R[I] := R[I] or (E and (POLLIN or POLLRDNORM));
          if ((E and POLLOUT) <> 0) and Writable(S) then
            R[I] := R[I] or POLLOUT;
          if S.SoError <> 0 then
            R[I] := R[I] or POLLERR;
          if S.CantRecvMore and S.CantSendMore and (S.Kind = 1) and (S.State = isClosed) then
            R[I] := R[I] or POLLHUP;
        end;
        if R[I] <> 0 then
          Inc(Count);
      end;
      Result := (Count > 0) or Final;
      if not Result then
        Exit;
      for var I := 0 to N - 1 do
        FMemory.Write16(Fds + Cardinal(I * 8) + 6, R[I]);
      Ret := Count;
      Err := 0;
    end);
end;

procedure TPSPNet.hInetGetErrno;
begin
  var E := 0;
  if FKernel.Current <> nil then
    FErrno.TryGetValue(FKernel.Current.UID, E);
  FHLE.Result(Cardinal(E));
end;

procedure TPSPNet.hInetGetPspError;
begin
  FHLE.Result(0);
end;

procedure TPSPNet.hInetSocketAbort;
begin
  var S := SockOf(FHLE.ArgInt(0));
  if S = nil then
  begin
    InetFail(EBADF);
    Exit;
  end;
  for var W in FWaiters.ToArray do
    if W.Sock = S then
      InetAbortThread(W.Thread);
  InetOk(0);
end;

procedure TPSPNet.CbStat(Stream: Boolean);
begin
  // Newest first, each entry's first word pointing at the next.
  var SizePtr := FHLE.Arg(0);
  var Buf := FHLE.Arg(1);
  if SizePtr = 0 then
  begin
    InetFail(EINVAL);
    Exit;
  end;
  var Entry := 24;
  var Kind := 2;
  if Stream then
  begin
    Entry := 28;
    Kind := 1;
  end;
  var List: TArray<TInetSocket> := nil;
  for var S in FPcbs do
    if S.Kind = Kind then
      List := List + [S];
  var Need := Length(List) * Entry;
  if Buf <> 0 then
  begin
    var Fit := Min(Length(List), Integer(FMemory.Read32(SizePtr)) div Entry);
    for var I := 0 to Fit - 1 do
    begin
      var S := List[I];
      var P := Buf + Cardinal(I * Entry);
      FMemory.Fill(P, 0, Entry);
      if I < Fit - 1 then
        FMemory.Write32(P, P + Cardinal(Entry));
      if Stream then
      begin
        FMemory.Write32(P + 4, Cardinal(S.RecvLen));
        FMemory.Write32(P + 8, Cardinal(S.SendLen));
        FMemory.Write32(P + 24, Cardinal(Ord(S.State)));
      end
      else
        FMemory.Write32(P + 4, Cardinal(S.QueuedBytes));
      for var K := 0 to 3 do
      begin
        FMemory.Write8(P + 12 + Cardinal(K), (S.LocalIP shr (24 - 8 * K)) and $FF);
        FMemory.Write8(P + 16 + Cardinal(K), (S.PeerIP shr (24 - 8 * K)) and $FF);
      end;
      FMemory.Write8(P + 20, S.LocalPort shr 8);
      FMemory.Write8(P + 21, S.LocalPort and $FF);
      FMemory.Write8(P + 22, S.PeerPort shr 8);
      FMemory.Write8(P + 23, S.PeerPort and $FF);
    end;
  end;
  FMemory.Write32(SizePtr, Cardinal(Need));
  InetOk(0);
end;

procedure TPSPNet.hInetGetUdpcbstat;
begin
  CbStat(False);
end;

procedure TPSPNet.hInetGetTcpcbstat;
begin
  CbStat(True);
end;

{ Addresses }

// inet_aton: one to four parts, each decimal, octal or hex.
function InetAtonText(const S: RawByteString; out Addr: Cardinal): Boolean;
begin
  Result := False;
  var Parts: array[0..2] of Cardinal;
  var NParts := 0;
  var I := 1;
  var N := Length(S);
  var Val: Cardinal := 0;
  while True do
  begin
    if (I > N) or not CharInSet(S[I], ['0'..'9']) then
      Exit;
    Val := 0;
    var Base := 10;
    if S[I] = '0' then
    begin
      Inc(I);
      if (I <= N) and CharInSet(S[I], ['x', 'X']) then
      begin
        Base := 16;
        Inc(I);
      end
      else
        Base := 8;
    end;
    while I <= N do
    begin
      var C := S[I];
      if CharInSet(C, ['0'..'9']) then
        Val := Val * Cardinal(Base) + Cardinal(Ord(C) - Ord('0'))
      else if (Base = 16) and CharInSet(C, ['a'..'f']) then
        Val := (Val shl 4) or Cardinal(Ord(C) - Ord('a') + 10)
      else if (Base = 16) and CharInSet(C, ['A'..'F']) then
        Val := (Val shl 4) or Cardinal(Ord(C) - Ord('A') + 10)
      else
        Break;
      Inc(I);
    end;
    if (I <= N) and (S[I] = '.') then
    begin
      if NParts >= 3 then
        Exit;
      Parts[NParts] := Val;
      Inc(NParts);
      Inc(I);
    end
    else
      Break;
  end;
  if (I <= N) and not CharInSet(S[I], [#9, #10, #11, #12, #13, ' ']) then
    Exit;
  case NParts of
    1:
      begin
        if (Val > $FFFFFF) or (Parts[0] > $FF) then
          Exit;
        Val := Val or (Parts[0] shl 24);
      end;
    2:
      begin
        if (Val > $FFFF) or (Parts[0] > $FF) or (Parts[1] > $FF) then
          Exit;
        Val := Val or (Parts[0] shl 24) or (Parts[1] shl 16);
      end;
    3:
      begin
        if (Val > $FF) or (Parts[0] > $FF) or (Parts[1] > $FF) or (Parts[2] > $FF) then
          Exit;
        Val := Val or (Parts[0] shl 24) or (Parts[1] shl 16) or (Parts[2] shl 8);
      end;
  end;
  Addr := Val;
  Result := True;
end;

// inet_pton: four decimal parts without leading zeros.
function InetPtonText(const S: RawByteString; out Addr: Cardinal): Boolean;
begin
  Result := False;
  var I := 1;
  var N := Length(S);
  Addr := 0;
  for var Part := 0 to 3 do
  begin
    if Part > 0 then
    begin
      if (I > N) or (S[I] <> '.') then
        Exit;
      Inc(I);
    end;
    var Start := I;
    var V := 0;
    while (I <= N) and CharInSet(S[I], ['0'..'9']) do
    begin
      V := V * 10 + Ord(S[I]) - Ord('0');
      if V > 255 then
        Exit;
      Inc(I);
    end;
    if (I = Start) or ((I - Start > 1) and (S[Start] = '0')) then
      Exit;
    Addr := (Addr shl 8) or Cardinal(V);
  end;
  if (I <= N) and not CharInSet(S[I], [#9, #10, #11, #12, #13, ' ']) then
    Exit;
  Result := True;
end;

function NetOrder(Addr: Cardinal): Cardinal;
begin
  Result := (Addr shr 24) or ((Addr shr 8) and $FF00) or ((Addr shl 8) and $FF0000) or (Addr shl 24);
end;

procedure TPSPNet.hInetInetAddr;
begin
  var A: Cardinal;
  if InetAtonText(FMemory.ReadAnsi(FHLE.Arg(0), 256), A) then
    FHLE.Result(NetOrder(A))
  else
    FHLE.Result($FFFFFFFF);
end;

procedure TPSPNet.hInetInetAton;
begin
  var A: Cardinal;
  if InetAtonText(FMemory.ReadAnsi(FHLE.Arg(0), 256), A) then
  begin
    if FHLE.Arg(1) <> 0 then
      FMemory.Write32(FHLE.Arg(1), NetOrder(A));
    FHLE.Result(1);
  end
  else
    FHLE.Result(0);
end;

procedure TPSPNet.hInetInetPton;
begin
  if FHLE.ArgInt(0) <> INET_AF_INET then
  begin
    InetFail(EAFNOSUPPORT);
    Exit;
  end;
  var A: Cardinal;
  if InetPtonText(FMemory.ReadAnsi(FHLE.Arg(1), 256), A) then
  begin
    FMemory.Write32(FHLE.Arg(2), NetOrder(A));
    InetOk(1);
  end
  else
    InetOk(0);
end;

procedure TPSPNet.hInetInetNtop;
begin
  var Src := FHLE.Arg(1);
  var Dst := FHLE.Arg(2);
  var Size := FHLE.ArgInt(3);
  if FHLE.ArgInt(0) <> INET_AF_INET then
  begin
    InetFail(EAFNOSUPPORT);
    FHLE.Result(0);
    Exit;
  end;
  var S := RawByteString(Format('%d.%d.%d.%d', [FMemory.Read8(Src), FMemory.Read8(Src + 1), FMemory.Read8(Src + 2),
    FMemory.Read8(Src + 3)]));
  if Length(S) + 1 > Size then
  begin
    InetFail(ENOSPC);
    FHLE.Result(0);
    Exit;
  end;
  FMemory.WriteString(Dst, S, Length(S) + 1);
  InetOk(Integer(Dst));
end;

procedure TPSPNet.InetRegister;
const
  I = 'sceNetInet';
begin
  var X := FHLE;
  X.Register(I, $17943399, 'sceNetInetInit', hInetInit);
  X.Register(I, $A9ED66B9, 'sceNetInetTerm', hInetTerm);
  X.Register(I, $8B7B220F, 'sceNetInetSocket', hInetSocket);
  X.Register(I, $1A33F9AE, 'sceNetInetBind', hInetBind);
  X.Register(I, $D10A1A7A, 'sceNetInetListen', hInetListen);
  X.Register(I, $DB094E1B, 'sceNetInetAccept', hInetAccept);
  X.Register(I, $410B34AA, 'sceNetInetConnect', hInetConnect);
  X.Register(I, $7AA671BC, 'sceNetInetSend', hInetSend);
  X.Register(I, $05038FC7, 'sceNetInetSendto', hInetSendto);
  X.Register(I, $774E36F4, 'sceNetInetSendmsg', hInetSendmsg);
  X.Register(I, $CDA85C99, 'sceNetInetRecv', hInetRecv);
  X.Register(I, $C91142E4, 'sceNetInetRecvfrom', hInetRecvfrom);
  X.Register(I, $EECE61D2, 'sceNetInetRecvmsg', hInetRecvmsg);
  X.Register(I, $8D7284EA, 'sceNetInetClose', hInetClose);
  X.Register(I, $805502DD, 'sceNetInetCloseWithRST', hInetCloseWithRST);
  X.Register(I, $4CFE4E56, 'sceNetInetShutdown', hInetShutdown);
  X.Register(I, $162E6FD5, 'sceNetInetGetsockname', hInetGetsockname);
  X.Register(I, $E247B6D6, 'sceNetInetGetpeername', hInetGetpeername);
  X.Register(I, $2FE71FE7, 'sceNetInetSetsockopt', hInetSetsockopt);
  X.Register(I, $4A114C7C, 'sceNetInetGetsockopt', hInetGetsockopt);
  X.Register(I, $5BE8D595, 'sceNetInetSelect', hInetSelect);
  X.Register(I, $FAABB1DD, 'sceNetInetPoll', hInetPoll);
  X.Register(I, $FBABE411, 'sceNetInetGetErrno', hInetGetErrno);
  X.Register(I, $8CA3A97E, 'sceNetInetGetPspError', hInetGetPspError);
  X.Register(I, $80A21ABD, 'sceNetInetSocketAbort', hInetSocketAbort);
  X.Register(I, $39B0C7D3, 'sceNetInetGetUdpcbstat', hInetGetUdpcbstat);
  X.Register(I, $B3888AD4, 'sceNetInetGetTcpcbstat', hInetGetTcpcbstat);
  X.Register(I, $B75D5B0A, 'sceNetInetInetAddr', hInetInetAddr);
  X.Register(I, $1BDF5D13, 'sceNetInetInetAton', hInetInetAton);
  X.Register(I, $E30B8C19, 'sceNetInetInetPton', hInetInetPton);
  X.Register(I, $D0792666, 'sceNetInetInetNtop', hInetInetNtop);
  X.Register(I, $2D5868C0, 'sceNetInetDelArp', hZero);
  X.Register(I, $CCC18C45, 'sceNetInetAddArp', hZero);
end;
