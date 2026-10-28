// Ad hoc on a console alone: adhocctl can create and join groups (nobody
// else is ever in them), scan (and find nobody), discover and wait for game
// mode members who never come. Its handlers run on adhocctl's own thread.

const
  SCE_NET_ADHOCCTL_ERROR_BUSY = Cardinal($80410B02);
  SCE_NET_ADHOCCTL_ERROR_INVALID_ARG = Cardinal($80410B04);
  SCE_NET_ADHOCCTL_ERROR_TIMEOUT = Cardinal($80410B05);
  SCE_NET_ADHOCCTL_ERROR_INVALID_ID = Cardinal($80410B06);
  SCE_NET_ADHOCCTL_ERROR_ALREADY_INITIALIZED = Cardinal($80410B07);
  SCE_NET_ADHOCCTL_ERROR_NOT_INITIALIZED = Cardinal($80410B08);
  SCE_NET_ADHOCCTL_ERROR_NOT_CONNECTED = Cardinal($80410B09);
  SCE_NET_ADHOCCTL_ERROR_NOT_IN_GAMEMODE = Cardinal($80410B0B);
  SCE_NET_ADHOCCTL_ERROR_NOT_ENTER_GAMEMODE = Cardinal($80410B0C);
  SCE_NET_ADHOCCTL_ERROR_HANDLER_MAX = Cardinal($80410B12);
  SCE_NET_ADHOCCTL_ERROR_STACKSIZE_TOO_SHORT = Cardinal($80410B13);
  SCE_NET_ADHOCCTL_ERROR_WLAN_FAILED = Cardinal($80410601);
  SCE_KERNEL_ERROR_ILLEGAL_PRIORITY = Cardinal($80020193);
  SCE_NET_ERROR_NO_ETHER = Cardinal($80410180);
  SCE_NET_ADHOC_ERROR_NO_PEER_LIST = Cardinal($80410682);
  SCE_NET_ADHOC_ERROR_NO_ENTRY = Cardinal($80410716);
  SCE_NET_ADHOC_ERROR_INVALID_MAC = Cardinal($80410702);
  SCE_NET_ADHOC_ERROR_NOT_IN_GAMEMODE = Cardinal($8041071B);
  SCE_NET_ADHOC_ERROR_NOT_CREATED = Cardinal($8041071C);
  SCE_NET_ADHOC_DISCOVER_ERROR_ALREADY_STARTED = Cardinal($80411301);
  SCE_NET_ADHOC_DISCOVER_ERROR_NOT_SUPPORTED = Cardinal($80411303);

  AdhocctlDisconnected = 0;
  AdhocctlConnected = 1;
  AdhocctlDiscovering = 4;
  AdhocEventError = 0;
  AdhocEventConnect = 1;
  AdhocEventDisconnect = 2;
  AdhocEventScan = 3;
  // How long the radio takes for each operation, as hardware measures them.
  AdhocCreateNs = 1115000000;
  AdhocDisconnectNs = 105900000;
  AdhocScanNs = 991800000;
  AdhocQuickNs = 5000000;
  // GetParameter asks the WLAN driver and waits for it.
  AdhocParameterNs = 13700000;

procedure TPSPNet.AdhocReset;
begin
  FAdhocctlInited := False;
  FAdhocctlBroken := False;
  FAdhocctlState := AdhocctlDisconnected;
  FAdhocctlWorker := nil;
  FillChar(FAdhocctlHandlers, SizeOf(FAdhocctlHandlers), 0);
  FAdhocId := nil;
  FAdhocGroup := '';
  FAdhocDeviceUp := False;
  FGameModePending := False;
  FDiscoverStatus := 0;
  FDiscoverPhase := 0;
  FAdhocInited := False;
  for var S in FAdhocObjs do
    if not FAdhocDead.Contains(S) then
      FAdhocDead.Add(S);
  FAdhocObjs.Clear;
  FAdhocDead.Clear;
  FNextAdhocId := 0;
  FNextAdhocPort := $1000;
  FMatchingInited := False;
  FMatching.Clear;
  FLastMatchingId := 0;
end;

procedure TPSPNet.AdhocctlEvent(Event: Integer; Error: Cardinal; DelayNs: Int64; const Change: TProc);
begin
  // The radio does its part, then the handlers hear of it on adhocctl's thread.
  var W := FAdhocctlWorker;
  FKernel.AddTimer(FKernel.Scheduler.Now + DelayNs, Self,
    procedure
    begin
      if (W = nil) or (W <> FAdhocctlWorker) then
        Exit;
      if Assigned(Change) then
        Change();
      if Event >= 0 then
        Post(W,
          function: TArray<TNetCall>
          begin
            Result := Calls(FAdhocctlHandlers, [Cardinal(Event), Error]);
          end);
    end);
end;

function TPSPNet.AdhocctlReady: Boolean;
begin
  if FAdhocctlInited then
    Result := True
  else
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_NOT_INITIALIZED);
    Result := False;
  end;
end;

function TPSPNet.ValidGroupName(Ptr: Cardinal; out Name: RawByteString): Boolean;
begin
  // Up to eight letters and digits.
  Name := '';
  if Ptr = 0 then
    Exit(True);
  for var I := 0 to 7 do
  begin
    var C := AnsiChar(FMemory.Read8(Ptr + Cardinal(I)));
    if C = #0 then
      Break;
    if not CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9']) then
      Exit(False);
    Name := Name + C;
  end;
  Result := True;
end;

function TPSPNet.ReadMac(Addr: Cardinal): TAdhocMac;
begin
  for var I := 0 to 5 do
    Result[I] := FMemory.Read8(Addr + Cardinal(I));
end;

function TPSPNet.IsLocalMac(const M: TAdhocMac): Boolean;
begin
  Result := CompareMem(@M[0], @PSPEtherAddr[0], 6);
end;

// 0 zero, 1 broadcast, 2 multicast, 3 unicast.
function TPSPNet.MacKind(const M: TAdhocMac): Integer;
begin
  var Zero := True;
  var Ones := True;
  for var B in M do
  begin
    Zero := Zero and (B = 0);
    Ones := Ones and (B = $FF);
  end;
  if Zero then
    Result := 0
  else if Ones then
    Result := 1
  else if (M[0] and 1) <> 0 then
    Result := 2
  else
    Result := 3;
end;

{ sceNetAdhocctl }

procedure TPSPNet.hAdhocctlInit;
begin
  var Stack := FHLE.Arg(0);
  var Prio := FHLE.ArgInt(1);
  var Id := FHLE.Arg(2);
  if FAdhocctlBroken then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_WLAN_FAILED);
    Exit;
  end;
  if FAdhocctlInited then
  begin
    // A second Init takes the library down with it.
    StopWorker(FAdhocctlWorker);
    FAdhocctlInited := False;
    FAdhocctlBroken := True;
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_ALREADY_INITIALIZED);
    Exit;
  end;
  if Stack < $C00 then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_STACKSIZE_TOO_SHORT);
    Exit;
  end;
  if (Prio < 1) or (Prio > $7F) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_PRIORITY);
    Exit;
  end;
  if (Id = 0) or (FMemory.Read32(Id) > 2) then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  SetLength(FAdhocId, 16);
  FMemory.ReadBytes(Id, FAdhocId[0], 16);
  FAdhocctlWorker := StartWorker('SceNetAdhocctl', Prio, Stack);
  FAdhocctlInited := True;
  FAdhocctlState := AdhocctlDisconnected;
  FAdhocDeviceUp := False;
  FHLE.Result(0);
end;

procedure TPSPNet.hAdhocctlTerm;
begin
  if FAdhocctlInited then
  begin
    if FGameModePending then
      FKernel.CancelTimer(FGameModeTimer);
    StopWorker(FAdhocctlWorker);
  end;
  FAdhocctlInited := False;
  FAdhocctlBroken := False;
  FAdhocctlState := AdhocctlDisconnected;
  FGameModePending := False;
  FillChar(FAdhocctlHandlers, SizeOf(FAdhocctlHandlers), 0);
  FHLE.Result(0);
end;

procedure TPSPNet.hAdhocctlAddHandler;
begin
  if not AdhocctlReady then
    Exit;
  if FHLE.Arg(0) = 0 then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  for var I := 0 to High(FAdhocctlHandlers) do
    if not FAdhocctlHandlers[I].Used then
    begin
      FAdhocctlHandlers[I].Used := True;
      FAdhocctlHandlers[I].Func := FHLE.Arg(0);
      FAdhocctlHandlers[I].Arg := FHLE.Arg(1);
      FHLE.Result(Cardinal(I));
      Exit;
    end;
  FHLE.Result(SCE_NET_ADHOCCTL_ERROR_HANDLER_MAX);
end;

procedure TPSPNet.hAdhocctlDelHandler;
begin
  if not AdhocctlReady then
    Exit;
  var Id := FHLE.ArgInt(0);
  if (Id < 0) or (Id > High(FAdhocctlHandlers)) or not FAdhocctlHandlers[Id].Used then
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ID)
  else
  begin
    FAdhocctlHandlers[Id].Used := False;
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hAdhocctlGetState;
begin
  if not AdhocctlReady then
    Exit;
  if FHLE.Arg(0) = 0 then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  FMemory.Write32(FHLE.Arg(0), Cardinal(FAdhocctlState));
  FHLE.Result(0);
end;

procedure TPSPNet.hAdhocctlCreate;
begin
  // Nobody has the group, so joining it creates it too.
  if not AdhocctlReady then
    Exit;
  var Name: RawByteString;
  if not ValidGroupName(FHLE.Arg(0), Name) then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  FHLE.Result(0);
  if FAdhocctlState <> AdhocctlDisconnected then
  begin
    AdhocctlEvent(AdhocEventError, SCE_NET_ADHOCCTL_ERROR_BUSY, AdhocQuickNs, nil);
    Exit;
  end;
  FAdhocDeviceUp := True;
  AdhocctlEvent(AdhocEventConnect, 0, AdhocCreateNs,
    procedure
    begin
      FAdhocctlState := AdhocctlConnected;
      FAdhocGroup := Name;
    end);
end;

procedure TPSPNet.hAdhocctlConnect;
begin
  hAdhocctlCreate;
end;

procedure TPSPNet.hAdhocctlJoin;
begin
  if not AdhocctlReady then
    Exit;
  var Info := FHLE.Arg(0);
  if Info = 0 then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  var Name: RawByteString;
  ValidGroupName(Info + 8, Name);
  FHLE.Result(0);
  if FAdhocctlState <> AdhocctlDisconnected then
  begin
    AdhocctlEvent(AdhocEventError, SCE_NET_ADHOCCTL_ERROR_BUSY, AdhocQuickNs, nil);
    Exit;
  end;
  FAdhocDeviceUp := True;
  AdhocctlEvent(AdhocEventConnect, 0, AdhocCreateNs,
    procedure
    begin
      FAdhocctlState := AdhocctlConnected;
      FAdhocGroup := Name;
    end);
end;

procedure TPSPNet.hAdhocctlScan;
begin
  if not AdhocctlReady then
    Exit;
  FHLE.Result(0);
  if FAdhocctlState <> AdhocctlDisconnected then
  begin
    AdhocctlEvent(AdhocEventError, SCE_NET_ADHOCCTL_ERROR_BUSY, AdhocQuickNs, nil);
    Exit;
  end;
  FAdhocDeviceUp := True;
  AdhocctlEvent(AdhocEventScan, 0, AdhocScanNs, nil);
end;

procedure TPSPNet.hAdhocctlDisconnect;
begin
  // Once the radio is up, leaving reports itself even with nothing to leave.
  if not AdhocctlReady then
    Exit;
  FHLE.Result(0);
  if FGameModePending then
  begin
    FKernel.CancelTimer(FGameModeTimer);
    FGameModePending := False;
  end;
  if (FAdhocctlState <> AdhocctlDisconnected) or FAdhocDeviceUp then
    AdhocctlEvent(AdhocEventDisconnect, 0, AdhocDisconnectNs,
      procedure
      begin
        FAdhocctlState := AdhocctlDisconnected;
        FAdhocGroup := '';
      end);
end;

procedure TPSPNet.hAdhocctlGetParameter;
begin
  if not AdhocctlReady then
    Exit;
  var P := FHLE.Arg(0);
  if FAdhocctlState <> AdhocctlConnected then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_NOT_CONNECTED);
    Exit;
  end;
  if P = 0 then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  FMemory.Fill(P, 0, 148);
  FMemory.Write32(P, 1);
  for var I := 1 to Length(FAdhocGroup) do
    FMemory.Write8(P + 3 + Cardinal(I), Ord(FAdhocGroup[I]));
  FMemory.WriteString(P + 12, UTF8Encode(PSPSettings.Nickname), 128);
  // The group's BSSID: a locally administered address the host makes up.
  var Bssid := PSPEtherAddr;
  Bssid[0] := (Bssid[0] or 2) and not 1;
  Bssid[5] := Bssid[5] xor $5A;
  FMemory.WriteBytes(P + 140, Bssid[0], 6);
  Run(nil, AdhocParameterNs, False,
    function(Final: Boolean; out Ret, Err: Integer): Boolean
    begin
      Ret := 0;
      Err := 0;
      Result := Final;
    end);
end;

procedure TPSPNet.hAdhocctlGetPeerList;
begin
  // Nobody else is ever in the group.
  if not AdhocctlReady then
    Exit;
  var SizePtr := FHLE.Arg(0);
  if SizePtr = 0 then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  FMemory.Write32(SizePtr, 0);
  if FAdhocctlState <> AdhocctlConnected then
    FHLE.Result(SCE_NET_ADHOC_ERROR_NO_PEER_LIST)
  else
    FHLE.Result(0);
end;

procedure TPSPNet.hAdhocctlGetPeerInfo;
begin
  if not AdhocctlReady then
    Exit;
  FHLE.Result(SCE_NET_ADHOC_ERROR_NO_ENTRY);
end;

procedure TPSPNet.hAdhocctlGetScanInfo;
begin
  if not AdhocctlReady then
    Exit;
  var SizePtr := FHLE.Arg(0);
  if SizePtr = 0 then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  FMemory.Write32(SizePtr, 0);
  FHLE.Result(0);
end;

procedure TPSPNet.hAdhocctlGetAdhocId;
begin
  if not AdhocctlReady then
    Exit;
  if FHLE.Arg(0) = 0 then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  FMemory.WriteBytes(FHLE.Arg(0), FAdhocId[0], Length(FAdhocId));
  FHLE.Result(0);
end;

procedure TPSPNet.hAdhocctlGetNameByAddr;
begin
  if not AdhocctlReady then
    Exit;
  var Mac := FHLE.Arg(0);
  var Nick := FHLE.Arg(1);
  if (Mac = 0) or (Nick = 0) then
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG)
  else if IsLocalMac(ReadMac(Mac)) then
  begin
    FMemory.WriteString(Nick, UTF8Encode(PSPSettings.Nickname), 128);
    FHLE.Result(0);
  end
  else
    FHLE.Result(SCE_NET_ADHOC_ERROR_NO_ENTRY);
end;

procedure TPSPNet.hAdhocctlGetAddrByName;
begin
  if not AdhocctlReady then
    Exit;
  if FHLE.Arg(1) = 0 then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  FMemory.Write32(FHLE.Arg(1), 0);
  FHLE.Result(0);
end;

{ Game mode }

procedure TPSPNet.GameModeEnter(Group: Cardinal; TimeoutUs: Cardinal; const Members: TAdhocMac; HasMembers: Boolean);
begin
  FHLE.Result(0);
  if FAdhocctlState <> AdhocctlDisconnected then
  begin
    AdhocctlEvent(AdhocEventError, SCE_NET_ADHOCCTL_ERROR_BUSY, AdhocQuickNs, nil);
    Exit;
  end;
  FAdhocDeviceUp := True;
  // A master stays in its game mode group until it exits it; a member that
  // found no master has nothing to leave.
  FGameModePending := HasMembers;
  if HasMembers and not IsLocalMac(Members) then
  begin
    AdhocctlEvent(AdhocEventError, SCE_NET_ADHOC_ERROR_INVALID_MAC, AdhocQuickNs, nil);
    Exit;
  end;
  // The other members never answer.
  var W := FAdhocctlWorker;
  FGameModeTimer := FKernel.AddTimer(FKernel.Scheduler.Now + Int64(TimeoutUs) * 1000, Self,
    procedure
    begin
      if (W = nil) or (W <> FAdhocctlWorker) then
        Exit;
      Post(W,
        function: TArray<TNetCall>
        begin
          Result := Calls(FAdhocctlHandlers, [AdhocEventError, SCE_NET_ADHOCCTL_ERROR_TIMEOUT]);
        end);
    end);
end;

function GameModeMaxMembers(Kind: Integer): Integer;
begin
  case Kind of
    1: Result := 4;
    2: Result := 8;
  else
    Result := 16;
  end;
end;

procedure TPSPNet.hAdhocctlCreateEnterGameMode;
begin
  if not AdhocctlReady then
    Exit;
  var Name: RawByteString;
  var Kind := FHLE.ArgInt(1);
  var Num := FHLE.ArgInt(2);
  var Macs := FHLE.Arg(3);
  if (FHLE.Arg(0) = 0) or not ValidGroupName(FHLE.Arg(0), Name) or (Macs = 0) or (Kind < 1) or (Kind > 3) or
    (Num < 2) or (Num > GameModeMaxMembers(Kind)) then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  GameModeEnter(FHLE.Arg(0), FHLE.Arg(4), ReadMac(Macs), True);
end;

procedure TPSPNet.hAdhocctlCreateEnterGameModeMin;
begin
  if not AdhocctlReady then
    Exit;
  var Name: RawByteString;
  var Kind := FHLE.ArgInt(1);
  var MinNum := FHLE.ArgInt(2);
  var Num := FHLE.ArgInt(3);
  var Macs := FHLE.Arg(4);
  if (FHLE.Arg(0) = 0) or not ValidGroupName(FHLE.Arg(0), Name) or (Macs = 0) or (Kind < 1) or (Kind > 3) or
    (MinNum < 2) or (MinNum > Num) or (Num > GameModeMaxMembers(Kind)) then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  GameModeEnter(FHLE.Arg(0), FHLE.Arg(5), ReadMac(Macs), True);
end;

procedure TPSPNet.hAdhocctlJoinEnterGameMode;
begin
  if not AdhocctlReady then
    Exit;
  var Name: RawByteString;
  if (FHLE.Arg(0) = 0) or not ValidGroupName(FHLE.Arg(0), Name) or (FHLE.Arg(1) = 0) then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_INVALID_ARG);
    Exit;
  end;
  GameModeEnter(FHLE.Arg(0), FHLE.Arg(2), PSPEtherAddr, False);
end;

procedure TPSPNet.hAdhocctlExitGameMode;
begin
  if not AdhocctlReady then
    Exit;
  if FAdhocctlState = AdhocctlConnected then
  begin
    FHLE.Result(SCE_NET_ADHOCCTL_ERROR_NOT_IN_GAMEMODE);
    Exit;
  end;
  FHLE.Result(0);
  if FGameModePending then
  begin
    FKernel.CancelTimer(FGameModeTimer);
    FGameModePending := False;
    AdhocctlEvent(AdhocEventDisconnect, 0, AdhocQuickNs, nil);
  end;
end;

procedure TPSPNet.hAdhocctlGetGameModeInfo;
begin
  FHLE.Result(SCE_NET_ADHOCCTL_ERROR_NOT_ENTER_GAMEMODE);
end;

procedure TPSPNet.hGameModeNotInMode;
begin
  FHLE.Result(SCE_NET_ADHOC_ERROR_NOT_IN_GAMEMODE);
end;

procedure TPSPNet.hGameModeDeleteNotInMode;
begin
  FHLE.Result(SCE_NET_ADHOC_ERROR_NOT_CREATED);
end;

{ sceNetAdhocDiscover }

// Phases: 0 started, 1 discovering, 2 stop asked, 3 leaving, 4 left.
procedure TPSPNet.hDiscoverInitStart;
begin
  if FDiscoverStatus <> 0 then
  begin
    FHLE.Result(SCE_NET_ADHOC_DISCOVER_ERROR_ALREADY_STARTED);
    Exit;
  end;
  FDiscoverStatus := 1;
  FDiscoverPhase := 0;
  FDiscoverParam := FHLE.Arg(0);
  FHLE.Result(0);
end;

procedure TPSPNet.hDiscoverUpdate;
begin
  // The discovery advances as the program pumps it.
  FHLE.Result(0);
  if FDiscoverStatus <> 1 then
    Exit;
  case FDiscoverPhase of
    0:
      begin
        FDiscoverPhase := 1;
        FAdhocDeviceUp := True;
        AdhocctlEvent(-1, 0, AdhocQuickNs,
          procedure
          begin
            if FDiscoverStatus = 1 then
              FAdhocctlState := AdhocctlDiscovering;
          end);
      end;
    2:
      begin
        FDiscoverPhase := 3;
        AdhocctlEvent(AdhocEventDisconnect, 0, AdhocQuickNs,
          procedure
          begin
            if FAdhocctlState = AdhocctlDiscovering then
              FAdhocctlState := AdhocctlDisconnected;
          end);
      end;
    3:
      if FAdhocctlState <> AdhocctlDiscovering then
        FDiscoverPhase := 4;
    4:
      begin
        FDiscoverStatus := 2;
        if FDiscoverParam <> 0 then
          FMemory.Write32(FDiscoverParam + 16, 1);
      end;
  end;
end;

procedure TPSPNet.hDiscoverGetStatus;
begin
  FHLE.Result(Cardinal(FDiscoverStatus));
end;

procedure TPSPNet.hDiscoverStop;
begin
  if (FDiscoverStatus = 1) and (FDiscoverPhase < 2) then
    FDiscoverPhase := 2;
  FHLE.Result(0);
end;

procedure TPSPNet.hDiscoverTerm;
begin
  if FAdhocctlState = AdhocctlDiscovering then
    FAdhocctlState := AdhocctlDisconnected;
  FDiscoverStatus := 0;
  FDiscoverPhase := 0;
  FHLE.Result(0);
end;

procedure TPSPNet.hDiscoverRequestSuspend;
begin
  FHLE.Result(SCE_NET_ADHOC_DISCOVER_ERROR_NOT_SUPPORTED);
end;
