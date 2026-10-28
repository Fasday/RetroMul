// sceNetAdhoc sockets in a group of one: PDP datagrams and PTP connections
// reach this console's own sockets (broadcasts are not looped back), and
// whatever goes to another address is lost. Socket alerts make the calls
// they name fail at once, and wake the threads blocked in them.

const
  SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID = Cardinal($80410701);
  SCE_NET_ADHOC_ERROR_INVALID_PORT = Cardinal($80410703);
  SCE_NET_ADHOC_ERROR_INVALID_DATALEN = Cardinal($80410705);
  SCE_NET_ADHOC_ERROR_SOCKET_DELETED = Cardinal($80410707);
  SCE_NET_ADHOC_ERROR_SOCKET_ALERTED = Cardinal($80410708);
  SCE_NET_ADHOC_ERROR_WOULD_BLOCK = Cardinal($80410709);
  SCE_NET_ADHOC_ERROR_PORT_IN_USE = Cardinal($8041070A);
  SCE_NET_ADHOC_ERROR_NOT_CONNECTED = Cardinal($8041070B);
  SCE_NET_ADHOC_ERROR_DISCONNECTED = Cardinal($8041070C);
  SCE_NET_ADHOC_ERROR_NOT_LISTENED = Cardinal($8040070E);
  SCE_NET_ADHOC_ERROR_SOCKET_ID_NOT_AVAIL = Cardinal($8041070F);
  SCE_NET_ADHOC_ERROR_INVALID_ARG = Cardinal($80410711);
  SCE_NET_ADHOC_ERROR_NOT_INITIALIZED = Cardinal($80410712);
  SCE_NET_ADHOC_ERROR_ALREADY_INITIALIZED = Cardinal($80410713);
  SCE_NET_ADHOC_ERROR_TIMEOUT = Cardinal($80410715);
  SCE_NET_ADHOC_ERROR_EXCEPTION_EVENT = Cardinal($80410717);
  SCE_NET_ADHOC_ERROR_CONNECTION_REFUSED = Cardinal($80410718);
  SCE_NET_ADHOC_ERROR_NOT_ENOUGH_SPACE = Cardinal($80400706);
  SCE_NET_ADHOC_MATCHING_ERROR_INVALID_MODE = Cardinal($80410801);
  SCE_NET_ADHOC_MATCHING_ERROR_INVALID_MAXNUM = Cardinal($80410803);
  SCE_NET_ADHOC_MATCHING_ERROR_RXBUF_TOO_SHORT = Cardinal($80410804);
  SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ARG = Cardinal($80410806);
  SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ID = Cardinal($80410807);
  SCE_NET_ADHOC_MATCHING_ERROR_ID_NOT_AVAIL = Cardinal($80410808);
  SCE_NET_ADHOC_MATCHING_ERROR_IS_RUNNING = Cardinal($8041080A);
  SCE_NET_ADHOC_MATCHING_ERROR_NOT_RUNNING = Cardinal($8041080B);
  SCE_NET_ADHOC_MATCHING_ERROR_UNKNOWN_TARGET = Cardinal($8041080C);
  SCE_NET_ADHOC_MATCHING_ERROR_ALREADY_INITIALIZED = Cardinal($80410812);
  SCE_NET_ADHOC_MATCHING_ERROR_NOT_INITIALIZED = Cardinal($80410813);
  SCE_NET_ADHOC_MATCHING_ERROR_PORT_IN_USE = Cardinal($80410814);
  SCE_NET_ADHOC_MATCHING_ERROR_STACKSIZE_TOO_SHORT = Cardinal($80410815);

  AlertSend = $10;
  AlertRecv = $20;
  AlertPoll = $40;
  AlertConnect = $80;
  AlertAccept = $100;
  AlertFlush = $200;
  AlertMask = $3F0;
  EvSend = $1;
  EvRecv = $2;
  EvConnect = $4;
  EvAccept = $8;
  EvFlush = $10;
  EvInvalid = $100;
  EvAlert = $400;
  EvError = $800;
  AdhocMaxSockets = 255;
  AdhocMaxDatagram = 65523;
  MatchingMaxContexts = 15;

{ TAdhocSocket }

constructor TAdhocSocket.Create;
begin
  inherited Create;
  Queue := TQueue<TAdhocDatagram>.Create;
  Pending := TList<TAdhocSocket>.Create;
end;

destructor TAdhocSocket.Destroy;
begin
  Queue.Free;
  Pending.Free;
  inherited;
end;

{ Sockets }

function TPSPNet.AdhocObj(Id: Integer): TAdhocSocket;
begin
  if Id > 0 then
    for var S in FAdhocObjs do
      if S.Id = Id then
        Exit(S);
  Result := nil;
end;

function TPSPNet.AdhocNewId: Integer;
begin
  Inc(FNextAdhocId);
  Result := FNextAdhocId;
end;

function TPSPNet.AdhocCount: Integer;
begin
  Result := 0;
  for var S in FAdhocObjs do
    if S.Id > 0 then
      Inc(Result);
end;

function TPSPNet.AdhocPortUsed(Ptp: Boolean; Port: Integer): Boolean;
begin
  for var S in FAdhocObjs do
    if (S.Ptp = Ptp) and (S.Port = Port) and (S.Id > 0) and (not Ptp or (S.State = 1)) then
      Exit(True);
  Result := False;
end;

function TPSPNet.PtpListenerFor(Port: Integer): TAdhocSocket;
begin
  for var S in FAdhocObjs do
    if S.Ptp and (S.State = 1) and (S.Port = Port) and not S.Deleted then
      Exit(S);
  Result := nil;
end;

procedure TPSPNet.AdhocDrop(S: TAdhocSocket);
begin
  S.Deleted := True;
  if S.Peer <> nil then
  begin
    S.Peer.PeerClosed := True;
    S.Peer.State := 0;
    S.Peer.Peer := nil;
    S.Peer := nil;
  end;
  for var P in S.Pending.ToArray do
    AdhocDrop(P);
  S.Pending.Clear;
  InetWake;
  if FAdhocObjs.Remove(S) >= 0 then
    FAdhocDead.Add(S);
end;

procedure TPSPNet.AdhocWait(TimeoutUs: Cardinal; NonBlocking: Boolean; const Attempt: TInetAttempt);
begin
  Run(nil, Int64(TimeoutUs) * 1000, NonBlocking, Attempt);
end;

procedure TPSPNet.hAdhocInit;
begin
  if FAdhocInited then
    FHLE.Result(SCE_NET_ADHOC_ERROR_ALREADY_INITIALIZED)
  else
  begin
    FAdhocInited := True;
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hAdhocTerm;
begin
  for var S in FAdhocObjs.ToArray do
    if FAdhocObjs.Contains(S) then
      AdhocDrop(S);
  FAdhocInited := False;
  FHLE.Result(0);
end;

function NextAdhocPort(Net: TPSPNet; Ptp: Boolean): Integer;
begin
  repeat
    Inc(Net.FNextAdhocPort);
    if Net.FNextAdhocPort > $7FFF then
      Net.FNextAdhocPort := $1001;
  until not Net.AdhocPortUsed(Ptp, Net.FNextAdhocPort);
  Result := Net.FNextAdhocPort;
end;

procedure TPSPNet.hPdpCreate;
begin
  var MacPtr := FHLE.Arg(0);
  var Port := Integer(FHLE.Arg(1) and $FFFF);
  var BufSize := FHLE.ArgInt(2);
  var Flag := FHLE.ArgInt(3);
  if not FAdhocInited then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_NOT_INITIALIZED);
    Exit;
  end;
  if (Flag <> 0) or (MacPtr = 0) then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG);
    Exit;
  end;
  if FAdhocctlState <> AdhocctlConnected then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_MAC);
    Exit;
  end;
  // The id is taken before the address is looked at.
  var Id := AdhocNewId;
  if not IsLocalMac(ReadMac(MacPtr)) then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_MAC)
  else if Port = $FFFF then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_PORT)
  else if (Port <> 0) and AdhocPortUsed(False, Port) then
    FHLE.Result(SCE_NET_ADHOC_ERROR_PORT_IN_USE)
  else if AdhocCount >= AdhocMaxSockets then
    FHLE.Result(SCE_NET_ADHOC_ERROR_SOCKET_ID_NOT_AVAIL)
  else
  begin
    if Port = 0 then
      Port := NextAdhocPort(Self, False);
    var S := TAdhocSocket.Create;
    S.Id := Id;
    S.Port := Port;
    S.BufSize := BufSize;
    FAdhocObjs.Add(S);
    FHLE.Result(Cardinal(Id));
  end;
end;

procedure TPSPNet.hPdpSend;
begin
  var S := AdhocObj(FHLE.ArgInt(0));
  var Dst := FHLE.Arg(1);
  var Port := Integer(FHLE.Arg(2) and $FFFF);
  var Data := FHLE.Arg(3);
  var Len := FHLE.ArgInt(4);
  var Flag := FHLE.ArgInt(6);
  if ((Flag and not 1) <> 0) or (Dst = 0) then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG);
    Exit;
  end;
  if (S = nil) or S.Ptp then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID);
    Exit;
  end;
  var Mac := ReadMac(Dst);
  var Kind := MacKind(Mac);
  if Kind in [0, 2] then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_MAC)
  else if (Port = 0) or (Port = $FFFF) then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_PORT)
  else if (Len < 0) or (Len > AdhocMaxDatagram) or ((Data = 0) and (Len > 0)) then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_DATALEN)
  else if (S.Alert and AlertSend) <> 0 then
    FHLE.Result(SCE_NET_ADHOC_ERROR_SOCKET_ALERTED)
  else
  begin
    if (Kind = 3) and IsLocalMac(Mac) then
      for var R in FAdhocObjs do
        if not R.Ptp and (R.Port = Port) and (R.Id > 0) then
        begin
          var D: TAdhocDatagram;
          SetLength(D.Data, Len);
          if Len > 0 then
            FMemory.ReadBytes(Data, D.Data[0], Len);
          D.Port := S.Port;
          R.Queue.Enqueue(D);
          Inc(R.QueuedBytes, Len);
          InetWake;
          Break;
        end;
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hPdpRecv;
begin
  var S := AdhocObj(FHLE.ArgInt(0));
  var MacPtr := FHLE.Arg(1);
  var PortPtr := FHLE.Arg(2);
  var Buf := FHLE.Arg(3);
  var LenPtr := FHLE.Arg(4);
  var Timeout := FHLE.Arg(5);
  var Flag := FHLE.ArgInt(6);
  if ((Flag and not 1) <> 0) or (Buf = 0) or (LenPtr = 0) then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG);
    Exit;
  end;
  if (S = nil) or S.Ptp then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID);
    Exit;
  end;
  var NonBlocking := Flag <> 0;
  AdhocWait(Timeout, NonBlocking,
    function(Final: Boolean; out Ret, Err: Integer): Boolean
    begin
      Result := True;
      Err := 0;
      if S.Deleted then
        Ret := Integer(SCE_NET_ADHOC_ERROR_SOCKET_DELETED)
      else if (S.Alert and AlertRecv) <> 0 then
        Ret := Integer(SCE_NET_ADHOC_ERROR_SOCKET_ALERTED)
      else if S.Queue.Count > 0 then
      begin
        var D := S.Queue.Peek;
        var Len := Integer(FMemory.Read32(LenPtr));
        if MacPtr <> 0 then
          FMemory.WriteBytes(MacPtr, PSPEtherAddr[0], 6);
        if PortPtr <> 0 then
          FMemory.Write16(PortPtr, Cardinal(D.Port));
        FMemory.Write32(LenPtr, Cardinal(Length(D.Data)));
        if Length(D.Data) > Len then
        begin
          // Left queued; the length says how much room it needs.
          Ret := Integer(SCE_NET_ADHOC_ERROR_NOT_ENOUGH_SPACE);
          Exit;
        end;
        S.Queue.Dequeue;
        Dec(S.QueuedBytes, Length(D.Data));
        if Length(D.Data) > 0 then
          FMemory.WriteBytes(Buf, D.Data[0], Length(D.Data));
        Ret := 0;
      end
      else if Final then
      begin
        if NonBlocking then
          Ret := Integer(SCE_NET_ADHOC_ERROR_WOULD_BLOCK)
        else
          Ret := Integer(SCE_NET_ADHOC_ERROR_TIMEOUT);
      end
      else
        Result := False;
    end);
end;

procedure TPSPNet.hPdpDelete;
begin
  var S := AdhocObj(FHLE.ArgInt(0));
  if FHLE.ArgInt(1) <> 0 then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG)
  else if (S = nil) or S.Ptp then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID)
  else
  begin
    AdhocDrop(S);
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hGetPdpStat;
begin
  // Oldest first; the size comes back as what was written.
  var SizePtr := FHLE.Arg(0);
  var Buf := FHLE.Arg(1);
  if SizePtr = 0 then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG);
    Exit;
  end;
  var List: TArray<TAdhocSocket> := nil;
  for var S in FAdhocObjs do
    if not S.Ptp and (S.Id > 0) then
      List := List + [S];
  if Buf = 0 then
  begin
    FMemory.Write32(SizePtr, Cardinal(Length(List) * 20));
    FHLE.Result(0);
    Exit;
  end;
  var Fit := Min(Length(List), Integer(FMemory.Read32(SizePtr)) div 20);
  for var I := 0 to Fit - 1 do
  begin
    var P := Buf + Cardinal(I * 20);
    if I < Fit - 1 then
      FMemory.Write32(P, P + 20)
    else
      FMemory.Write32(P, 0);
    FMemory.Write32(P + 4, Cardinal(List[I].Id));
    FMemory.WriteBytes(P + 8, PSPEtherAddr[0], 6);
    FMemory.Write16(P + 14, Cardinal(List[I].Port));
    FMemory.Write32(P + 16, Cardinal(List[I].QueuedBytes));
  end;
  FMemory.Write32(SizePtr, Cardinal(Fit * 20));
  FHLE.Result(0);
end;

procedure TPSPNet.hPtpOpen;
begin
  var MacPtr := FHLE.Arg(0);
  var Port := Integer(FHLE.Arg(1) and $FFFF);
  var Dst := FHLE.Arg(2);
  var DPort := Integer(FHLE.Arg(3) and $FFFF);
  var BufSize := FHLE.ArgInt(4);
  var Flag := FHLE.ArgInt(7);
  if not FAdhocInited then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_NOT_INITIALIZED);
    Exit;
  end;
  if (Flag <> 0) or (MacPtr = 0) or (Dst = 0) then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG);
    Exit;
  end;
  if FAdhocctlState <> AdhocctlConnected then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_MAC);
    Exit;
  end;
  var Id := AdhocNewId;
  var DstMac := ReadMac(Dst);
  if not IsLocalMac(ReadMac(MacPtr)) or (MacKind(DstMac) in [0, 2]) then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_MAC)
  else if (DPort = 0) or (DPort = $FFFF) or (Port = $FFFF) then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_PORT)
  else if AdhocCount >= AdhocMaxSockets then
    FHLE.Result(SCE_NET_ADHOC_ERROR_SOCKET_ID_NOT_AVAIL)
  else
  begin
    if Port = 0 then
      Port := NextAdhocPort(Self, True);
    var S := TAdhocSocket.Create;
    S.Id := Id;
    S.Ptp := True;
    S.Port := Port;
    S.BufSize := BufSize;
    S.PeerMac := DstMac;
    S.PeerPort := DPort;
    S.State := 2;
    FAdhocObjs.Add(S);
    if IsLocalMac(DstMac) then
    begin
      // The SYN reaches this console at once.
      var L := PtpListenerFor(DPort);
      if L = nil then
      begin
        S.State := 0;
        S.Refused := True;
      end
      else
      begin
        var A := TAdhocSocket.Create;
        A.Id := -1;
        A.Ptp := True;
        A.Port := DPort;
        A.BufSize := L.BufSize;
        A.PeerMac := PSPEtherAddr;
        A.PeerPort := Port;
        A.State := 4;
        A.Peer := S;
        S.Peer := A;
        S.State := 4;
        L.Pending.Add(A);
        FAdhocObjs.Add(A);
      end;
      InetWake;
    end;
    FHLE.Result(Cardinal(Id));
  end;
end;

procedure TPSPNet.hPtpListen;
begin
  var MacPtr := FHLE.Arg(0);
  var Port := Integer(FHLE.Arg(1) and $FFFF);
  var BufSize := FHLE.ArgInt(2);
  var Flag := FHLE.ArgInt(6);
  if not FAdhocInited then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_NOT_INITIALIZED);
    Exit;
  end;
  if (Flag <> 0) or (MacPtr = 0) then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG);
    Exit;
  end;
  if FAdhocctlState <> AdhocctlConnected then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_MAC);
    Exit;
  end;
  var Id := AdhocNewId;
  if not IsLocalMac(ReadMac(MacPtr)) then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_MAC)
  else if Port = $FFFF then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_PORT)
  else if (Port <> 0) and AdhocPortUsed(True, Port) then
    FHLE.Result(SCE_NET_ADHOC_ERROR_PORT_IN_USE)
  else if AdhocCount >= AdhocMaxSockets then
    FHLE.Result(SCE_NET_ADHOC_ERROR_SOCKET_ID_NOT_AVAIL)
  else
  begin
    if Port = 0 then
      Port := NextAdhocPort(Self, True);
    var S := TAdhocSocket.Create;
    S.Id := Id;
    S.Ptp := True;
    S.Port := Port;
    S.BufSize := BufSize;
    S.State := 1;
    FAdhocObjs.Add(S);
    FHLE.Result(Cardinal(Id));
  end;
end;

procedure TPSPNet.hPtpConnect;
begin
  var S := AdhocObj(FHLE.ArgInt(0));
  var Timeout := FHLE.Arg(1);
  var Flag := FHLE.ArgInt(2);
  if (Flag and not 1) <> 0 then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG);
    Exit;
  end;
  if (S = nil) or not S.Ptp then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID);
    Exit;
  end;
  if S.State = 1 then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_NOT_CONNECTED);
    Exit;
  end;
  var NonBlocking := Flag <> 0;
  AdhocWait(Timeout, NonBlocking,
    function(Final: Boolean; out Ret, Err: Integer): Boolean
    begin
      Result := True;
      Err := 0;
      if S.State = 4 then
        Ret := 0
      else if S.Refused then
        Ret := Integer(SCE_NET_ADHOC_ERROR_CONNECTION_REFUSED)
      else if S.Deleted then
        Ret := Integer(SCE_NET_ADHOC_ERROR_SOCKET_DELETED)
      else if S.PeerClosed then
        Ret := Integer(SCE_NET_ADHOC_ERROR_DISCONNECTED)
      else if (S.Alert and AlertConnect) <> 0 then
        Ret := Integer(SCE_NET_ADHOC_ERROR_SOCKET_ALERTED)
      else if Final then
      begin
        if NonBlocking then
          Ret := Integer(SCE_NET_ADHOC_ERROR_WOULD_BLOCK)
        else
          Ret := Integer(SCE_NET_ADHOC_ERROR_TIMEOUT);
      end
      else
        Result := False;
    end);
end;

procedure TPSPNet.hPtpAccept;
begin
  var S := AdhocObj(FHLE.ArgInt(0));
  var MacPtr := FHLE.Arg(1);
  var PortPtr := FHLE.Arg(2);
  var Timeout := FHLE.Arg(3);
  var Flag := FHLE.ArgInt(4);
  if (Flag and not 1) <> 0 then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG);
    Exit;
  end;
  if (S = nil) or not S.Ptp then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID);
    Exit;
  end;
  if S.State <> 1 then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_NOT_LISTENED);
    Exit;
  end;
  var NonBlocking := Flag <> 0;
  AdhocWait(Timeout, NonBlocking,
    function(Final: Boolean; out Ret, Err: Integer): Boolean
    begin
      Result := True;
      Err := 0;
      if S.Deleted then
        Ret := Integer(SCE_NET_ADHOC_ERROR_SOCKET_DELETED)
      else if (S.Alert and AlertAccept) <> 0 then
        Ret := Integer(SCE_NET_ADHOC_ERROR_SOCKET_ALERTED)
      else if S.Pending.Count > 0 then
      begin
        var A := S.Pending[0];
        S.Pending.Delete(0);
        A.Id := AdhocNewId;
        if MacPtr <> 0 then
          FMemory.WriteBytes(MacPtr, A.PeerMac[0], 6);
        if PortPtr <> 0 then
          FMemory.Write16(PortPtr, Cardinal(A.PeerPort));
        Ret := A.Id;
      end
      else if Final then
      begin
        if NonBlocking then
          Ret := Integer(SCE_NET_ADHOC_ERROR_WOULD_BLOCK)
        else
          Ret := Integer(SCE_NET_ADHOC_ERROR_TIMEOUT);
      end
      else
        Result := False;
    end);
end;

procedure TPSPNet.hPtpSend;
begin
  var S := AdhocObj(FHLE.ArgInt(0));
  var Data := FHLE.Arg(1);
  var LenPtr := FHLE.Arg(2);
  var Flag := FHLE.ArgInt(4);
  if ((Flag and not 1) <> 0) or (LenPtr = 0) then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG);
    Exit;
  end;
  if (S = nil) or not S.Ptp then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID);
    Exit;
  end;
  if S.State = 1 then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_NOT_CONNECTED);
    Exit;
  end;
  var Len := Integer(FMemory.Read32(LenPtr));
  if (Len < 0) or ((Data = 0) and (Len > 0)) then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_DATALEN);
    Exit;
  end;
  if S.PeerClosed or S.Refused or (S.State = 0) then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_DISCONNECTED);
    Exit;
  end;
  if (S.Alert and AlertSend) <> 0 then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_SOCKET_ALERTED);
    Exit;
  end;
  if S.State <> 4 then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_NOT_CONNECTED);
    Exit;
  end;
  var P := S.Peer;
  if (P <> nil) and (Len > 0) then
  begin
    if Length(P.RecvData) < P.RecvLen + Len then
      SetLength(P.RecvData, P.RecvLen + Len);
    FMemory.ReadBytes(Data, P.RecvData[P.RecvLen], Len);
    Inc(P.RecvLen, Len);
    InetWake;
  end;
  FHLE.Result(0);
end;

procedure TPSPNet.hPtpRecv;
begin
  var S := AdhocObj(FHLE.ArgInt(0));
  var Buf := FHLE.Arg(1);
  var LenPtr := FHLE.Arg(2);
  var Timeout := FHLE.Arg(3);
  var Flag := FHLE.ArgInt(4);
  if ((Flag and not 1) <> 0) or (Buf = 0) or (LenPtr = 0) then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG);
    Exit;
  end;
  if (S = nil) or not S.Ptp then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID);
    Exit;
  end;
  if S.State = 1 then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_NOT_CONNECTED);
    Exit;
  end;
  var NonBlocking := Flag <> 0;
  AdhocWait(Timeout, NonBlocking,
    function(Final: Boolean; out Ret, Err: Integer): Boolean
    begin
      Result := True;
      Err := 0;
      if S.Deleted then
        Ret := Integer(SCE_NET_ADHOC_ERROR_SOCKET_DELETED)
      else if (S.Alert and AlertRecv) <> 0 then
        Ret := Integer(SCE_NET_ADHOC_ERROR_SOCKET_ALERTED)
      else if S.RecvLen > 0 then
      begin
        var N := Min(Integer(FMemory.Read32(LenPtr)), S.RecvLen);
        if N < 0 then
          N := 0;
        if N > 0 then
          FMemory.WriteBytes(Buf, S.RecvData[0], N);
        Move(S.RecvData[N], S.RecvData[0], S.RecvLen - N);
        Dec(S.RecvLen, N);
        FMemory.Write32(LenPtr, Cardinal(N));
        Ret := 0;
      end
      else if S.PeerClosed or S.Refused then
        Ret := Integer(SCE_NET_ADHOC_ERROR_DISCONNECTED)
      else if Final then
      begin
        if NonBlocking then
          Ret := Integer(SCE_NET_ADHOC_ERROR_WOULD_BLOCK)
        else
          Ret := Integer(SCE_NET_ADHOC_ERROR_TIMEOUT);
      end
      else
        Result := False;
    end);
end;

procedure TPSPNet.hPtpFlush;
begin
  var S := AdhocObj(FHLE.ArgInt(0));
  if (FHLE.ArgInt(2) and not 1) <> 0 then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG)
  else if (S = nil) or not S.Ptp then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID)
  else if S.State = 1 then
    FHLE.Result(SCE_NET_ADHOC_ERROR_NOT_CONNECTED)
  else if S.PeerClosed or S.Refused then
    FHLE.Result(SCE_NET_ADHOC_ERROR_DISCONNECTED)
  else
    // Everything sent has already arrived.
    FHLE.Result(0);
end;

procedure TPSPNet.hPtpClose;
begin
  var S := AdhocObj(FHLE.ArgInt(0));
  if FHLE.ArgInt(1) <> 0 then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG)
  else if (S = nil) or not S.Ptp then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID)
  else
  begin
    AdhocDrop(S);
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hGetPtpStat;
begin
  var SizePtr := FHLE.Arg(0);
  var Buf := FHLE.Arg(1);
  if SizePtr = 0 then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG);
    Exit;
  end;
  var List: TArray<TAdhocSocket> := nil;
  for var S in FAdhocObjs do
    if S.Ptp then
      List := List + [S];
  if Buf = 0 then
  begin
    FMemory.Write32(SizePtr, Cardinal(Length(List) * 36));
    FHLE.Result(0);
    Exit;
  end;
  var Fit := Min(Length(List), Integer(FMemory.Read32(SizePtr)) div 36);
  for var I := 0 to Fit - 1 do
  begin
    var S := List[I];
    var P := Buf + Cardinal(I * 36);
    FMemory.Fill(P, 0, 36);
    if I < Fit - 1 then
      FMemory.Write32(P, P + 36);
    FMemory.Write32(P + 4, Cardinal(S.Id));
    FMemory.WriteBytes(P + 8, PSPEtherAddr[0], 6);
    if S.State <> 1 then
    begin
      FMemory.WriteBytes(P + 14, S.PeerMac[0], 6);
      FMemory.Write16(P + 22, Cardinal(S.PeerPort));
    end;
    FMemory.Write16(P + 20, Cardinal(S.Port));
    FMemory.Write32(P + 28, Cardinal(S.RecvLen));
    FMemory.Write32(P + 32, Cardinal(S.State));
  end;
  FMemory.Write32(SizePtr, Cardinal(Fit * 36));
  FHLE.Result(0);
end;

procedure TPSPNet.hSetSocketAlert;
begin
  var S := AdhocObj(FHLE.ArgInt(0));
  if S = nil then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID);
    Exit;
  end;
  S.Alert := FHLE.Arg(1) and AlertMask;
  FHLE.Result(0);
  InetWake;
end;

procedure TPSPNet.hGetSocketAlert;
begin
  var S := AdhocObj(FHLE.ArgInt(0));
  if S = nil then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID)
  else if FHLE.Arg(1) = 0 then
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG)
  else
  begin
    FMemory.Write32(FHLE.Arg(1), S.Alert);
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hPollSocket;
begin
  var Sds := FHLE.Arg(0);
  var Count := FHLE.ArgInt(1);
  var Timeout := FHLE.Arg(2);
  var Flag := FHLE.ArgInt(3);
  if ((Flag and not 1) <> 0) or (Count <= 0) or (Sds = 0) then
  begin
    FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_ARG);
    Exit;
  end;
  for var I := 0 to Count - 1 do
    if AdhocObj(Integer(FMemory.Read32(Sds + Cardinal(I * 12)))) = nil then
    begin
      // The firmware marks the first entry, whichever was bad.
      FMemory.Write32(Sds + 8, EvInvalid);
      FHLE.Result(SCE_NET_ADHOC_ERROR_INVALID_SOCKET_ID);
      Exit;
    end;
  var NonBlocking := Flag <> 0;
  AdhocWait(Timeout, NonBlocking,
    function(Final: Boolean; out Ret, Err: Integer): Boolean
    begin
      Err := 0;
      var R: TArray<Cardinal>;
      SetLength(R, Count);
      var Ready := 0;
      var Failed := False;
      for var I := 0 to Count - 1 do
      begin
        var S := AdhocObj(Integer(FMemory.Read32(Sds + Cardinal(I * 12))));
        var Events := FMemory.Read32(Sds + Cardinal(I * 12) + 4);
        if (S = nil) or S.Deleted then
        begin
          R[I] := EvInvalid;
          Failed := True;
          Continue;
        end;
        if (S.Alert and AlertPoll) <> 0 then
        begin
          R[I] := EvAlert;
          Failed := True;
          Continue;
        end;
        var V: Cardinal := 0;
        if not S.Ptp then
        begin
          V := EvSend;
          if S.Queue.Count > 0 then
            V := V or EvRecv;
        end
        else
          case S.State of
            1:
              begin
                V := EvSend or EvFlush;
                if S.Pending.Count > 0 then
                  V := V or EvAccept;
              end;
            4:
              if S.PeerClosed then
                V := EvError
              else
              begin
                V := EvSend or EvConnect or EvFlush;
                if S.RecvLen > 0 then
                  V := V or EvRecv;
              end;
            0: V := EvError;
          end;
        if (V and EvError) <> 0 then
        begin
          R[I] := EvError;
          Failed := True;
          Continue;
        end;
        R[I] := V and Events;
        if R[I] <> 0 then
          Inc(Ready);
      end;
      Result := Failed or (Ready > 0) or Final;
      if not Result then
        Exit;
      for var I := 0 to Count - 1 do
        FMemory.Write32(Sds + Cardinal(I * 12) + 8, R[I]);
      if Failed then
        Ret := Integer(SCE_NET_ADHOC_ERROR_EXCEPTION_EVENT)
      else if (Ready = 0) and not NonBlocking then
        Ret := Integer(SCE_NET_ADHOC_ERROR_TIMEOUT)
      else
        Ret := Ready;
    end);
end;

{ sceNetAdhocMatching }

procedure TPSPNet.hMatchingInit;
begin
  if FMatchingInited then
  begin
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_ALREADY_INITIALIZED);
    Exit;
  end;
  FMatchingInited := True;
  FMatchingPool := FHLE.Arg(0);
  FHLE.Result(0);
end;

procedure TPSPNet.hMatchingTerm;
begin
  FMatchingInited := False;
  FMatching.Clear;
  FHLE.Result(0);
end;

procedure TPSPNet.hMatchingCreate;
begin
  var Mode := FHLE.ArgInt(0);
  var MaxNum := FHLE.ArgInt(1);
  var Port := Integer(FHLE.Arg(2) and $FFFF);
  var RxBufLen := FHLE.ArgInt(3);
  var Hello := FHLE.Arg(4);
  var KeepAlive := FHLE.Arg(5);
  var Count := FHLE.ArgInt(6);
  var Rexmt := FHLE.Arg(7);
  if not FMatchingInited then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_NOT_INITIALIZED)
  else if (Mode < 1) or (Mode > 3) then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_MODE)
  else if (MaxNum < 2) or (MaxNum > 16) then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_MAXNUM)
  else if RxBufLen < 6 * MaxNum + 4 then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_RXBUF_TOO_SHORT)
  else if (Rexmt = 0) or (Count < 0) or ((Mode <> 2) and ((Hello = 0) or (KeepAlive = 0))) then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ARG)
  else
  begin
    for var C in FMatching.Values do
      if C.Port = Port then
      begin
        FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_PORT_IN_USE);
        Exit;
      end;
    if FMatching.Count >= MatchingMaxContexts then
    begin
      FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_ID_NOT_AVAIL);
      Exit;
    end;
    // Ids go round 1..15.
    var Id := FLastMatchingId;
    repeat
      Id := Id mod MatchingMaxContexts + 1;
    until not FMatching.ContainsKey(Id);
    FLastMatchingId := Id;
    var C := TMatchingContext.Create;
    C.Id := Id;
    C.Mode := Mode;
    C.MaxNum := MaxNum;
    C.Port := Port;
    FMatching.Add(Id, C);
    FHLE.Result(Cardinal(Id));
  end;
end;

procedure TPSPNet.MatchingStart(Id, StackA, StackB: Integer; PartA, PartB: Integer; OptLen: Integer; Opt: Cardinal);
begin
  var C: TMatchingContext;
  if not FMatching.TryGetValue(Id, C) then
  begin
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ID);
    Exit;
  end;
  if (StackA < $200) or (StackB < $200) then
  begin
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_STACKSIZE_TOO_SHORT);
    Exit;
  end;
  if not (PartA in [2, 5, 6]) or not (PartB in [2, 5, 6]) then
  begin
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ID);
    Exit;
  end;
  if C.Running then
  begin
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_IS_RUNNING);
    Exit;
  end;
  C.Running := True;
  SetLength(C.HelloOpt, Max(OptLen, 0));
  if (OptLen > 0) and (Opt <> 0) then
    FMemory.ReadBytes(Opt, C.HelloOpt[0], OptLen);
  // Its threads would report peers; there never are any.
  FHLE.Result(0);
end;

procedure TPSPNet.hMatchingStart;
begin
  MatchingStart(FHLE.ArgInt(0), FHLE.ArgInt(2), FHLE.ArgInt(4), 2, 2, FHLE.ArgInt(5), FHLE.Arg(6));
end;

procedure TPSPNet.hMatchingStart2;
begin
  // The ninth argument is on the stack.
  var Opt := FMemory.Read32(FSystem.CPU.Ctx.GPR[29]);
  MatchingStart(FHLE.ArgInt(0), FHLE.ArgInt(2), FHLE.ArgInt(5), FHLE.ArgInt(3), FHLE.ArgInt(6), FHLE.ArgInt(7),
    Opt);
end;

procedure TPSPNet.hMatchingStop;
begin
  var C: TMatchingContext;
  if not FMatching.TryGetValue(FHLE.ArgInt(0), C) then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ID)
  else
  begin
    C.Running := False;
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hMatchingDelete;
begin
  var C: TMatchingContext;
  if not FMatching.TryGetValue(FHLE.ArgInt(0), C) then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ID)
  else if C.Running then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_IS_RUNNING)
  else
  begin
    FMatching.Remove(C.Id);
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hMatchingRunning;
begin
  // The calls about a target: nobody is ever a known one.
  var C: TMatchingContext;
  if not FMatching.TryGetValue(FHLE.ArgInt(0), C) then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ID)
  else if not C.Running then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_NOT_RUNNING)
  else
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_UNKNOWN_TARGET);
end;

procedure TPSPNet.hMatchingSetHelloOpt;
begin
  var C: TMatchingContext;
  var Len := FHLE.ArgInt(1);
  if not FMatching.TryGetValue(FHLE.ArgInt(0), C) then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ID)
  else if not C.Running then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_NOT_RUNNING)
  else
  begin
    SetLength(C.HelloOpt, Max(Len, 0));
    if (Len > 0) and (FHLE.Arg(2) <> 0) then
      FMemory.ReadBytes(FHLE.Arg(2), C.HelloOpt[0], Len);
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hMatchingGetHelloOpt;
begin
  // Copies as much as asked for out of the context, where the data is
  // followed by the context's mode; the length is left as the caller gave it.
  var C: TMatchingContext;
  var LenPtr := FHLE.Arg(1);
  if not FMatching.TryGetValue(FHLE.ArgInt(0), C) then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ID)
  else if not C.Running then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_NOT_RUNNING)
  else if LenPtr = 0 then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ARG)
  else
  begin
    var Stored := C.HelloOpt + [Byte(C.Mode)];
    var N := EnsureRange(Integer(FMemory.Read32(LenPtr)), 0, 256);
    SetLength(Stored, Max(N, Length(Stored)));
    if (N > 0) and (FHLE.Arg(2) <> 0) then
      FMemory.WriteBytes(FHLE.Arg(2), Stored[0], N);
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hMatchingGetMembers;
begin
  // Only this console.
  var C: TMatchingContext;
  var SizePtr := FHLE.Arg(1);
  var Buf := FHLE.Arg(2);
  if not FMatching.TryGetValue(FHLE.ArgInt(0), C) then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ID)
  else if not C.Running then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_NOT_RUNNING)
  else if SizePtr = 0 then
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ARG)
  else
  begin
    if (Buf <> 0) and (Integer(FMemory.Read32(SizePtr)) >= 12) then
    begin
      FMemory.Fill(Buf, 0, 12);
      FMemory.WriteBytes(Buf + 4, PSPEtherAddr[0], 6);
    end;
    FMemory.Write32(SizePtr, 12);
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hMatchingGetPoolMaxAlloc;
begin
  FHLE.Result(0);
end;

procedure TPSPNet.hMatchingGetPoolStat;
begin
  var P := FHLE.Arg(0);
  if P = 0 then
  begin
    FHLE.Result(SCE_NET_ADHOC_MATCHING_ERROR_INVALID_ARG);
    Exit;
  end;
  var Pool := FMatchingPool - NetPoolReserved;
  FMemory.Write32(P, Pool);
  FMemory.Write32(P + 4, 0);
  FMemory.Write32(P + 8, Pool);
  FHLE.Result(0);
end;

procedure TPSPNet.AdhocRegister;
const
  C = 'sceNetAdhocctl';
  A = 'sceNetAdhoc';
  M = 'sceNetAdhocMatching';
  D = 'sceNetAdhocDiscover';
begin
  var X := FHLE;
  X.Register(C, $E26F226E, 'sceNetAdhocctlInit', hAdhocctlInit);
  X.Register(C, $9D689E13, 'sceNetAdhocctlTerm', hAdhocctlTerm);
  X.Register(C, $20B317A0, 'sceNetAdhocctlAddHandler', hAdhocctlAddHandler);
  X.Register(C, $6402490B, 'sceNetAdhocctlDelHandler', hAdhocctlDelHandler);
  X.Register(C, $75ECD386, 'sceNetAdhocctlGetState', hAdhocctlGetState);
  X.Register(C, $EC0635C1, 'sceNetAdhocctlCreate', hAdhocctlCreate);
  X.Register(C, $0AD043ED, 'sceNetAdhocctlConnect', hAdhocctlConnect);
  X.Register(C, $5E7F79C9, 'sceNetAdhocctlJoin', hAdhocctlJoin);
  X.Register(C, $08FFF7A0, 'sceNetAdhocctlScan', hAdhocctlScan);
  X.Register(C, $34401D65, 'sceNetAdhocctlDisconnect', hAdhocctlDisconnect);
  X.Register(C, $DED9D28E, 'sceNetAdhocctlGetParameter', hAdhocctlGetParameter);
  X.Register(C, $E162CB14, 'sceNetAdhocctlGetPeerList', hAdhocctlGetPeerList);
  X.Register(C, $8DB83FDC, 'sceNetAdhocctlGetPeerInfo', hAdhocctlGetPeerInfo);
  X.Register(C, $81AEE1BE, 'sceNetAdhocctlGetScanInfo', hAdhocctlGetScanInfo);
  X.Register(C, $362CBE8F, 'sceNetAdhocctlGetAdhocId', hAdhocctlGetAdhocId);
  X.Register(C, $8916C003, 'sceNetAdhocctlGetNameByAddr', hAdhocctlGetNameByAddr);
  X.Register(C, $99560ABE, 'sceNetAdhocctlGetAddrByName', hAdhocctlGetAddrByName);
  X.Register(C, $A5C055CE, 'sceNetAdhocctlCreateEnterGameMode', hAdhocctlCreateEnterGameMode);
  X.Register(C, $B0B80E80, 'sceNetAdhocctlCreateEnterGameModeMin', hAdhocctlCreateEnterGameModeMin);
  X.Register(C, $1FF89745, 'sceNetAdhocctlJoinEnterGameMode', hAdhocctlJoinEnterGameMode);
  X.Register(C, $CF8E084D, 'sceNetAdhocctlExitGameMode', hAdhocctlExitGameMode);
  X.Register(C, $5A014CE0, 'sceNetAdhocctlGetGameModeInfo', hAdhocctlGetGameModeInfo);

  X.Register(A, $E1D621D7, 'sceNetAdhocInit', hAdhocInit);
  X.Register(A, $A62C6F57, 'sceNetAdhocTerm', hAdhocTerm);
  X.Register(A, $6F92741B, 'sceNetAdhocPdpCreate', hPdpCreate);
  X.Register(A, $ABED3790, 'sceNetAdhocPdpSend', hPdpSend);
  X.Register(A, $DFE53E03, 'sceNetAdhocPdpRecv', hPdpRecv);
  X.Register(A, $7F27BB5E, 'sceNetAdhocPdpDelete', hPdpDelete);
  X.Register(A, $C7C1FC57, 'sceNetAdhocGetPdpStat', hGetPdpStat);
  X.Register(A, $877F6D66, 'sceNetAdhocPtpOpen', hPtpOpen);
  X.Register(A, $E08BDAC1, 'sceNetAdhocPtpListen', hPtpListen);
  X.Register(A, $FC6FC07B, 'sceNetAdhocPtpConnect', hPtpConnect);
  X.Register(A, $9DF81198, 'sceNetAdhocPtpAccept', hPtpAccept);
  X.Register(A, $4DA4C788, 'sceNetAdhocPtpSend', hPtpSend);
  X.Register(A, $8BEA2B3E, 'sceNetAdhocPtpRecv', hPtpRecv);
  X.Register(A, $9AC2EEAC, 'sceNetAdhocPtpFlush', hPtpFlush);
  X.Register(A, $157E6225, 'sceNetAdhocPtpClose', hPtpClose);
  X.Register(A, $B9685118, 'sceNetAdhocGetPtpStat', hGetPtpStat);
  X.Register(A, $73BFD52D, 'sceNetAdhocSetSocketAlert', hSetSocketAlert);
  X.Register(A, $4D2CE199, 'sceNetAdhocGetSocketAlert', hGetSocketAlert);
  X.Register(A, $7A662D6B, 'sceNetAdhocPollSocket', hPollSocket);
  X.Register(A, $7F75C338, 'sceNetAdhocGameModeCreateMaster', hGameModeNotInMode);
  X.Register(A, $98C204C8, 'sceNetAdhocGameModeUpdateMaster', hGameModeNotInMode);
  X.Register(A, $A0229362, 'sceNetAdhocGameModeDeleteMaster', hGameModeDeleteNotInMode);
  X.Register(A, $3278AB0C, 'sceNetAdhocGameModeCreateReplica', hGameModeNotInMode);
  X.Register(A, $FA324B4E, 'sceNetAdhocGameModeUpdateReplica', hGameModeNotInMode);
  X.Register(A, $0B2228E9, 'sceNetAdhocGameModeDeleteReplica', hGameModeDeleteNotInMode);

  X.Register(M, $2A2A1E07, 'sceNetAdhocMatchingInit', hMatchingInit);
  X.Register(M, $7945ECDA, 'sceNetAdhocMatchingTerm', hMatchingTerm);
  X.Register(M, $CA5EDA6F, 'sceNetAdhocMatchingCreate', hMatchingCreate);
  X.Register(M, $93EF3843, 'sceNetAdhocMatchingStart', hMatchingStart);
  X.Register(M, $E8454C65, 'sceNetAdhocMatchingStart2', hMatchingStart2);
  X.Register(M, $32B156B3, 'sceNetAdhocMatchingStop', hMatchingStop);
  X.Register(M, $F16EAF4F, 'sceNetAdhocMatchingDelete', hMatchingDelete);
  X.Register(M, $5E3D4B79, 'sceNetAdhocMatchingSelectTarget', hMatchingRunning);
  X.Register(M, $EA3C6108, 'sceNetAdhocMatchingCancelTarget', hMatchingRunning);
  X.Register(M, $8F58BEDF, 'sceNetAdhocMatchingCancelTargetWithOpt', hMatchingRunning);
  X.Register(M, $F79472D7, 'sceNetAdhocMatchingSendData', hMatchingRunning);
  X.Register(M, $EC19337D, 'sceNetAdhocMatchingAbortSendData', hMatchingRunning);
  X.Register(M, $B58E61B7, 'sceNetAdhocMatchingSetHelloOpt', hMatchingSetHelloOpt);
  X.Register(M, $B5D96C2A, 'sceNetAdhocMatchingGetHelloOpt', hMatchingGetHelloOpt);
  X.Register(M, $C58BCD9E, 'sceNetAdhocMatchingGetMembers', hMatchingGetMembers);
  X.Register(M, $40F8F435, 'sceNetAdhocMatchingGetPoolMaxAlloc', hMatchingGetPoolMaxAlloc);
  X.Register(M, $9C5CFB7D, 'sceNetAdhocMatchingGetPoolStat', hMatchingGetPoolStat);

  X.Register(D, $941B3877, 'sceNetAdhocDiscoverInitStart', hDiscoverInitStart);
  X.Register(D, $52DE1B97, 'sceNetAdhocDiscoverUpdate', hDiscoverUpdate);
  X.Register(D, $944DDBC6, 'sceNetAdhocDiscoverGetStatus', hDiscoverGetStatus);
  X.Register(D, $A2246614, 'sceNetAdhocDiscoverTerm', hDiscoverTerm);
  X.Register(D, $F7D13214, 'sceNetAdhocDiscoverStop', hDiscoverStop);
  X.Register(D, $A423A21B, 'sceNetAdhocDiscoverRequestSuspend', hDiscoverRequestSuspend);
end;
