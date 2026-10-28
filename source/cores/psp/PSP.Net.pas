unit PSP.Net;

// The network libraries as a PSP sees them with nowhere to connect to:
// sceNet, sceWlanDrv, sceNetApctl (no access points, no profiles),
// sceNetResolver (no DNS server), sceHttp and sceSsl, sceParseUri,
// sceNetInet with its loopback interface (sockets on 127.0.0.1 talk to each
// other as on hardware), ad hoc with nobody else around, and sceUsb with no
// cable. The libraries' own threads (apctl's and adhocctl's event threads)
// are guest threads running a stub that calls back into the service.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Math, System.Generics.Collections, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE,
  PSP.Kernel, PSP.Scheduler, PSP.Service;

type
  TNetCall = record
    Func: Cardinal;
    Args: TArray<Cardinal>;
  end;

  // Work for a library thread: changes its state, then returns the guest
  // calls (handlers) to make.
  TNetJob = reference to function: TArray<TNetCall>;

  TPSPNetWorker = class
  public
    Thread: TPSPThread;
    Jobs: TQueue<TNetJob>;
    Calls: TQueue<TNetCall>;
    constructor Create;
    destructor Destroy; override;
  end;

  TNetResolver = class
  public
    Id: Integer;
    // An async lookup's result waiting to be collected.
    Pending: Boolean;
    PendingResult: Cardinal;
  end;

  TNetHandler = record
    Used: Boolean;
    Func, Arg: Cardinal;
  end;

  TInetDatagram = record
    Data: TBytes;
    FromIP: Cardinal;
    FromPort: Integer;
  end;

  TInetState = (isClosed, isListening, isConnecting, isEstablished);

  TInetSocket = class
  public
    Fd: Integer;
    // 1 stream, 2 datagram, 3 raw.
    Kind: Integer;
    LocalIP: Cardinal;
    LocalPort: Integer;
    Bound: Boolean;
    PeerIP: Cardinal;
    PeerPort: Integer;
    HasPeer: Boolean;
    // SO_* flags as the stack keeps them.
    Options: Cardinal;
    LingerTime: Integer;
    SndBuf, RcvBuf, SndLowat, RcvLowat: Integer;
    // In ticks of 10 ms.
    SndTimeo, RcvTimeo: Integer;
    NBIO, NoDelay: Boolean;
    TTL: Integer;
    SoError: Integer;
    // The descriptor is closed; a connection can outlive it.
    Closed: Boolean;
    Datagrams: TQueue<TInetDatagram>;
    QueuedBytes: Integer;
    State: TInetState;
    ListenFailed, ConnectFailed: Boolean;
    Backlog: Integer;
    // Connections the listener has completed, and those waiting for room.
    AcceptQueue, SynQueue: TList<TInetSocket>;
    Peer: TInetSocket;
    RecvData, SendData: TBytes;
    RecvLen, SendLen: Integer;
    ReadShut, WriteShut, CantRecvMore, CantSendMore: Boolean;
    FinPending, FinReceived: Boolean;
    TransferScheduled: Boolean;
    constructor Create(AKind: Integer);
    destructor Destroy; override;
  end;

  // A thread blocked in a socket call; Attempt finishes the call when it can
  // (or must: on its timeout), giving the result and errno.
  TInetAttempt = reference to function(Final: Boolean; out Ret, Err: Integer): Boolean;

  TInetWaiter = class
  public
    Thread: TPSPThread;
    Sock: TInetSocket;
    Attempt: TInetAttempt;
    Timer: Int64;
  end;

  TAdhocMac = array[0..5] of Byte;

  TAdhocDatagram = record
    Data: TBytes;
    Port: Integer;
  end;

  // A PDP or PTP socket of sceNetAdhoc.
  TAdhocSocket = class
  public
    Id: Integer;
    Ptp: Boolean;
    Port: Integer;
    BufSize: Integer;
    Alert: Cardinal;
    Deleted: Boolean;
    Queue: TQueue<TAdhocDatagram>;
    QueuedBytes: Integer;
    // PTP: 0 closed, 1 listening, 2 SYN sent, 4 established.
    State: Integer;
    PeerMac: TAdhocMac;
    PeerPort: Integer;
    Pending: TList<TAdhocSocket>;
    Peer: TAdhocSocket;
    RecvData: TBytes;
    RecvLen: Integer;
    PeerClosed, Refused: Boolean;
    constructor Create;
    destructor Destroy; override;
  end;

  TMatchingContext = class
  public
    Id: Integer;
    Mode, MaxNum, Port: Integer;
    Running: Boolean;
    HelloOpt: TBytes;
  end;

  TPSPNet = class(TPSPService)
  private
    FWorkerIndex: Integer;
    FWorkerStub: Cardinal;
    FWorkers: TObjectList<TPSPNetWorker>;
    // sceNet
    FNetInited: Boolean;
    FPoolSize: Cardinal;
    // sceNetApctl
    FApctlInited: Boolean;
    FApctlState: Integer;
    FApctlHandlers: array[0..1] of TNetHandler;
    FApctlWorker: TPSPNetWorker;
    FScanning: Boolean;
    FScanTimer: Int64;
    // sceNetResolver
    FResolverInited: Boolean;
    FResolvers: TObjectDictionary<Integer, TNetResolver>;
    FNextResolver: Integer;
    // sceHttp
    FHttpInited: Boolean;
    FHttpIds: TDictionary<Cardinal, Integer>;
    FNextTemplate, FNextConnection, FNextRequest: Cardinal;
    // sceUsb
    FUsbStarted, FUsbActivated: Boolean;
    // sceNetInet
    FInetInited: Boolean;
    // Open descriptors; every socket the stack still has (closed ones
    // finishing their connection, accepted ones not yet handed out).
    FSockets: TDictionary<Integer, TInetSocket>;
    FPcbs: TList<TInetSocket>;
    // Sockets the stack is done with, kept until reset: pending events and
    // waiters may still look at them.
    FDeadPcbs: TObjectList<TInetSocket>;
    FWaiters: TObjectList<TInetWaiter>;
    FNextFd: Integer;
    FNextEphemeral: Integer;
    FErrno: TDictionary<Cardinal, Integer>;
    // sceNetAdhocctl
    FAdhocctlInited, FAdhocctlBroken: Boolean;
    FAdhocctlState: Integer;
    FAdhocctlWorker: TPSPNetWorker;
    FAdhocctlHandlers: array[0..3] of TNetHandler;
    FAdhocId: TBytes;
    FAdhocGroup: RawByteString;
    // The WLAN device has been brought up by a group operation.
    FAdhocDeviceUp: Boolean;
    FGameModePending: Boolean;
    FGameModeTimer: Int64;
    // sceNetAdhocDiscover
    FDiscoverStatus, FDiscoverPhase: Integer;
    FDiscoverParam: Cardinal;
    // sceNetAdhoc
    FAdhocInited: Boolean;
    FAdhocObjs: TList<TAdhocSocket>;
    FAdhocDead: TObjectList<TAdhocSocket>;
    FNextAdhocId: Integer;
    FNextAdhocPort: Integer;
    // sceNetAdhocMatching
    FMatchingInited: Boolean;
    FMatchingPool: Cardinal;
    FMatching: TObjectDictionary<Integer, TMatchingContext>;
    FLastMatchingId: Integer;
    procedure hWorker;
    function StartWorker(const Name: string; Priority: Integer; StackSize: Cardinal): TPSPNetWorker;
    procedure StopWorker(var W: TPSPNetWorker);
    procedure Post(W: TPSPNetWorker; const Job: TNetJob);
    function Calls(const Handlers: array of TNetHandler; const Args: array of Cardinal): TArray<TNetCall>;
    // sceParseUri
    procedure hUriParse;
    procedure hUriBuild;
    procedure hUriEscape;
    procedure hUriUnescape;
    // sceNet
    procedure hNetInit;
    procedure hNetTerm;
    procedure hNetEtherNtostr;
    procedure hNetEtherStrton;
    procedure hNetGetLocalEtherAddr;
    procedure hNetGetMallocStat;
    procedure hNetThreadAbort;
    procedure hNetFreeThreadinfo;
    // sceWlanDrv
    procedure hWlanGetSwitchState;
    procedure hWlanDevIsPowerOn;
    procedure hWlanGetEtherAddr;
    // sceNetApctl
    procedure ApctlSetState(NewState, Event: Integer);
    procedure hApctlInit;
    procedure hApctlTerm;
    procedure hApctlGetState;
    procedure hApctlGetInfo;
    procedure hApctlAddHandler;
    procedure hApctlDelHandler;
    procedure hApctlConnect;
    procedure hApctlDisconnect;
    procedure hApctlScanUser;
    procedure hApctlGetBSSDescIDListUser;
    procedure hApctlGetBSSDescEntryUser;
    procedure hNotExported;
    // sceNetResolver
    function ResolverOf(Id: Integer): TNetResolver;
    procedure hResolverInit;
    procedure hResolverTerm;
    procedure hResolverCreate;
    procedure hResolverDelete;
    procedure hResolverStartNtoA;
    procedure hResolverStartAtoN;
    procedure hResolverStartNtoAAsync;
    procedure hResolverStartAtoNAsync;
    procedure hResolverPollAsync;
    procedure hResolverWaitAsync;
    procedure hResolverStop;
    // sceHttp
    function HttpId(Kind: Integer; out Id: Cardinal): Boolean;
    procedure hHttpInit;
    procedure hHttpEnd;
    procedure hHttpCreateTemplate;
    procedure hHttpCreateConnection;
    procedure hHttpCreateRequest;
    procedure hHttpDeleteTemplate;
    procedure hHttpDeleteConnection;
    procedure hHttpDeleteRequest;
    procedure hHttpSendRequest;
    procedure hHttpGetContentLength;
    procedure hHttpGetStatusCode;
    procedure hHttpReadData;
    procedure hHttpSetting;
    procedure hZero;
    // sceUsb
    procedure hUsbStart;
    procedure hUsbActivate;
    procedure hUsbDeactivate;
    procedure hUsbGetState;
    procedure hUsbWaitState;
    // sceNetInet
    {$I PSP.Net.InetDecl.inc}
    // Ad hoc
    {$I PSP.Net.AdhocDecl.inc}
  public
    constructor Create(System: TPSPSystem); override;
    destructor Destroy; override;
    procedure Reset; override;
    procedure Register; override;
  end;

implementation

uses
  PSP.Settings;

const
  // The console's own MAC address.
  PSPEtherAddr: TAdhocMac = ($00, $1F, $A7, $52, $4D, $50);

  SCE_NET_ERROR_INVALID_ARG = Cardinal($80410103);
  SCE_NET_ERROR_INVALID_THREAD = Cardinal($80410104);

  SCE_NET_APCTL_ERROR_ALREADY_INITIALIZED = Cardinal($80410A01);
  SCE_NET_APCTL_ERROR_INVALID_CODE = Cardinal($80410A02);
  SCE_NET_APCTL_ERROR_INVALID_ARG = Cardinal($80410A03);
  SCE_NET_APCTL_ERROR_NOT_CONNECTED = Cardinal($80410A05);
  SCE_NET_APCTL_ERROR_HANDLER_NOT_FOUND = Cardinal($80410A09);
  SCE_NET_APCTL_ERROR_NOT_INITIALIZED = Cardinal($80410A0D);
  SCE_NET_APCTL_ERROR_TOO_MANY_HANDLERS = Cardinal($80410A0F);
  SCE_NET_APCTL_ERROR_BUSY = Cardinal($80410A80);
  SCE_NET_APCTL_ERROR_INVALID_ID = Cardinal($80410A82);
  SCE_UTILITY_ERROR_NETCONF_NO_PROFILE = Cardinal($80110601);
  SCE_UTILITY_ERROR_NETCONF_BAD_PROFILE = Cardinal($80110602);
  SCE_KERNEL_ERROR_LIBRARY_NOT_YET_LINKED = Cardinal($8002013A);

  SCE_NET_RESOLVER_ERROR_NO_DNS_SERVER = Cardinal($80410402);
  SCE_NET_RESOLVER_ERROR_INVALID_PTR = Cardinal($80410403);
  SCE_NET_RESOLVER_ERROR_INVALID_BUFLEN = Cardinal($80410404);
  SCE_NET_RESOLVER_ERROR_ID_NOT_FOUND = Cardinal($80410408);
  SCE_NET_RESOLVER_ERROR_BUSY = Cardinal($80410409);
  SCE_NET_RESOLVER_ERROR_NOT_RUNNING = Cardinal($8041040A);
  SCE_NET_RESOLVER_ERROR_EMPTY_NAME = Cardinal($80410418);
  SCE_NET_RESOLVER_ERROR_INVALID_STATUS_PTR = Cardinal($80410419);
  SCE_NET_RESOLVER_ERROR_NO_ASYNC = Cardinal($8041041A);
  SCE_KERNEL_ERROR_ALREADY = Cardinal($80000020);

  SCE_HTTP_ERROR_NO_RESPONSE = Cardinal($80431065);
  SCE_HTTP_ERROR_INVALID_ID = Cardinal($80431100);

  ApctlStateDisconnected = 0;
  ApctlStateScanning = 1;
  ApctlEventScanRequest = 1;
  ApctlEventScanComplete = 2;
  // How long a scan of every channel takes.
  ApctlScanNs = 1450000000;
  // Within the bounds the firmware keeps, as hardware reports them.
  NetPoolReserved = $20;
  NetPoolPeak = $3A00;
  NetPoolUsed = $2E40;

{$I PSP.Net.Uri.inc}
{$I PSP.Net.Inet.inc}
{$I PSP.Net.InetCalls.inc}
{$I PSP.Net.Adhoc.inc}
{$I PSP.Net.AdhocSock.inc}

{ TPSPNetWorker }

constructor TPSPNetWorker.Create;
begin
  inherited Create;
  Jobs := TQueue<TNetJob>.Create;
  Calls := TQueue<TNetCall>.Create;
end;

destructor TPSPNetWorker.Destroy;
begin
  Jobs.Free;
  Calls.Free;
  inherited;
end;

{ TPSPNet }

constructor TPSPNet.Create(System: TPSPSystem);
begin
  inherited Create(System);
  FWorkers := TObjectList<TPSPNetWorker>.Create;
  FResolvers := TObjectDictionary<Integer, TNetResolver>.Create([doOwnsValues]);
  FHttpIds := TDictionary<Cardinal, Integer>.Create;
  FSockets := TDictionary<Integer, TInetSocket>.Create;
  FPcbs := TList<TInetSocket>.Create;
  FDeadPcbs := TObjectList<TInetSocket>.Create;
  FWaiters := TObjectList<TInetWaiter>.Create;
  FErrno := TDictionary<Cardinal, Integer>.Create;
  FAdhocObjs := TList<TAdhocSocket>.Create;
  FAdhocDead := TObjectList<TAdhocSocket>.Create;
  FMatching := TObjectDictionary<Integer, TMatchingContext>.Create([doOwnsValues]);
end;

destructor TPSPNet.Destroy;
begin
  FWorkers.Free;
  FResolvers.Free;
  FHttpIds.Free;
  FWaiters.Free;
  FSockets.Free;
  for var S in FPcbs do
    if not FDeadPcbs.Contains(S) then
      FDeadPcbs.Add(S);
  FPcbs.Free;
  FDeadPcbs.Free;
  FErrno.Free;
  for var S in FAdhocObjs do
    if not FAdhocDead.Contains(S) then
      FAdhocDead.Add(S);
  FAdhocObjs.Free;
  FAdhocDead.Free;
  FMatching.Free;
  inherited;
end;

procedure TPSPNet.Reset;
begin
  FWorkers.Clear;
  FApctlWorker := nil;
  FNetInited := False;
  FApctlInited := False;
  FApctlState := ApctlStateDisconnected;
  FillChar(FApctlHandlers, SizeOf(FApctlHandlers), 0);
  FScanning := False;
  FResolverInited := False;
  FResolvers.Clear;
  FNextResolver := 1;
  FHttpInited := False;
  FHttpIds.Clear;
  FNextTemplate := 1;
  FNextConnection := $01000001;
  FNextRequest := $02000001;
  FUsbStarted := False;
  FUsbActivated := False;
  InetReset;
  AdhocReset;
  FWorkerStub := FKernel.AllocKernel(16, 'net thread');
end;

{ Library threads }

function TPSPNet.StartWorker(const Name: string; Priority: Integer; StackSize: Cardinal): TPSPNetWorker;
begin
  Result := nil;
  // The library threads loop on: syscall; j loop.
  FMemory.Write32(FWorkerStub, (Cardinal(FWorkerIndex) shl 6) or $0C);
  FMemory.Write32(FWorkerStub + 4, (2 shl 26) or ((FWorkerStub shr 2) and $03FFFFFF));
  FMemory.Write32(FWorkerStub + 8, 0);
  var T := FKernel.CreateThread(Name, FWorkerStub, Priority, Max(StackSize, $800), 0, FSystem.CPU.Ctx.GPR[28]);
  if T = nil then
    Exit;
  Result := TPSPNetWorker.Create;
  Result.Thread := T;
  FWorkers.Add(Result);
  FKernel.StartThread(T, 0, 0);
end;

procedure TPSPNet.StopWorker(var W: TPSPNetWorker);
begin
  if W = nil then
    Exit;
  var T := W.Thread;
  if T <> nil then
  begin
    if T <> FKernel.Current then
    begin
      FKernel.TerminateThread(T, 0);
      FKernel.DeleteThread(T);
    end;
  end;
  FWorkers.Remove(W);
  W := nil;
end;

procedure TPSPNet.Post(W: TPSPNetWorker; const Job: TNetJob);
begin
  if W = nil then
    Exit;
  W.Jobs.Enqueue(Job);
  var T := W.Thread;
  if T.IsWaiting and (T.Wait.HLETag = 'net thread') then
    FKernel.EndWait(T, 0);
end;

function TPSPNet.Calls(const Handlers: array of TNetHandler; const Args: array of Cardinal): TArray<TNetCall>;
begin
  Result := nil;
  for var H in Handlers do
    if H.Used then
    begin
      var C: TNetCall;
      C.Func := H.Func;
      SetLength(C.Args, Length(Args) + 1);
      for var I := 0 to High(Args) do
        C.Args[I] := Args[I];
      C.Args[Length(Args)] := H.Arg;
      Result := Result + [C];
    end;
end;

procedure TPSPNet.hWorker;
begin
  var T := FKernel.Current;
  var W: TPSPNetWorker := nil;
  for var X in FWorkers do
    if X.Thread = T then
      W := X;
  if W = nil then
  begin
    FKernel.ExitCurrent(0);
    Exit;
  end;
  while (W.Calls.Count = 0) and (W.Jobs.Count > 0) do
    for var C in W.Jobs.Dequeue()() do
      W.Calls.Enqueue(C);
  if W.Calls.Count > 0 then
  begin
    var C := W.Calls.Dequeue;
    FKernel.CallGuest(C.Func, C.Args, nil);
  end
  else
    FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, False, nil, nil, 'net thread');
end;

{ sceNet }

procedure TPSPNet.hNetInit;
begin
  FNetInited := True;
  FPoolSize := FHLE.Arg(0);
  FHLE.Result(0);
end;

procedure TPSPNet.hNetTerm;
begin
  FNetInited := False;
  FHLE.Result(0);
end;

procedure TPSPNet.hNetEtherNtostr;
const
  Hex: array[0..15] of AnsiChar = '0123456789abcdef';
begin
  var Mac := FHLE.Arg(0);
  var Name := FHLE.Arg(1);
  if (Mac = 0) or (Name = 0) then
  begin
    // The firmware returns the high half of its own data address here.
    FHLE.Result($09D40000);
    Exit;
  end;
  var S: RawByteString := '';
  for var I := 0 to 5 do
  begin
    var B := FMemory.Read8(Mac + Cardinal(I));
    if I > 0 then
      S := S + ':';
    S := S + Hex[B shr 4] + Hex[B and 15];
  end;
  FMemory.WriteString(Name, S, 18);
  FHLE.Result(Length(S));
end;

// The firmware's digit: a letter counts as a base-36 digit and anything
// else as 9999999, with no checking.
function EtherDigit(C: Cardinal): Integer;
begin
  case C of
    Ord('0')..Ord('9'): Result := Integer(C) - Ord('0');
    Ord('A')..Ord('Z'): Result := Integer(C) - Ord('A') + 10;
    Ord('a')..Ord('z'): Result := Integer(C) - Ord('a') + 10;
  else
    Result := 9999999;
  end;
end;

procedure TPSPNet.hNetEtherStrton;
begin
  // Two characters per byte and one separator after each, whatever they
  // are; it reads past the end of a short string.
  var Name := FHLE.Arg(0);
  var Mac := FHLE.Arg(1);
  if (Name = 0) or (Mac = 0) then
  begin
    FHLE.Result(0);
    Exit;
  end;
  var V := 0;
  for var I := 0 to 5 do
  begin
    var P := Name + Cardinal(I * 3);
    V := EtherDigit(FMemory.Read8(P)) * 16 + EtherDigit(FMemory.Read8(P + 1));
    FMemory.Write8(Mac + Cardinal(I), Cardinal(V) and $FF);
  end;
  FHLE.Result(Cardinal(V));
end;

procedure TPSPNet.hNetGetLocalEtherAddr;
begin
  // Known once a group or scan operation has brought the radio up.
  var Mac := FHLE.Arg(0);
  if Mac = 0 then
  begin
    FHLE.Result(SCE_NET_ERROR_INVALID_ARG);
    Exit;
  end;
  if not FAdhocDeviceUp then
  begin
    FHLE.Result($80410180);
    Exit;
  end;
  FMemory.WriteBytes(Mac, PSPEtherAddr[0], 6);
  FHLE.Result(0);
end;

procedure TPSPNet.hNetGetMallocStat;
begin
  var Stat := FHLE.Arg(0);
  if Stat = 0 then
  begin
    FHLE.Result(SCE_NET_ERROR_INVALID_ARG);
    Exit;
  end;
  var Pool := FPoolSize - NetPoolReserved;
  FMemory.Write32(Stat, Pool);
  FMemory.Write32(Stat + 4, Min(Pool, NetPoolPeak));
  FMemory.Write32(Stat + 8, Pool - Min(Pool div 2, NetPoolUsed));
  FHLE.Result(0);
end;

procedure TPSPNet.hNetThreadAbort;
begin
  var T: TPSPThread := nil;
  if FHLE.Arg(0) <> 0 then
    T := FKernel.ThreadById(FHLE.Arg(0));
  if T = nil then
  begin
    FHLE.Result(SCE_NET_ERROR_INVALID_THREAD);
    Exit;
  end;
  InetAbortThread(T);
  FHLE.Result(0);
end;

procedure TPSPNet.hNetFreeThreadinfo;
begin
  if (FHLE.Arg(0) = 0) or (FKernel.ThreadById(FHLE.Arg(0)) = nil) then
    FHLE.Result(SCE_NET_ERROR_INVALID_THREAD)
  else
  begin
    FErrno.Remove(FHLE.Arg(0));
    FHLE.Result(0);
  end;
end;

{ sceWlanDrv }

procedure TPSPNet.hWlanGetSwitchState;
begin
  FHLE.Result(1);
end;

procedure TPSPNet.hWlanDevIsPowerOn;
begin
  FHLE.Result(1);
end;

procedure TPSPNet.hWlanGetEtherAddr;
begin
  var Mac := FHLE.Arg(0);
  if Mac <> 0 then
    FMemory.WriteBytes(Mac, PSPEtherAddr[0], 6);
  FHLE.Result(0);
end;

{ sceNetApctl }

procedure TPSPNet.ApctlSetState(NewState, Event: Integer);
begin
  // On apctl's thread: the state changes, then the handlers hear of it.
  var Old := FApctlState;
  Post(FApctlWorker,
    function: TArray<TNetCall>
    begin
      FApctlState := NewState;
      Result := Calls(FApctlHandlers, [Cardinal(Old), Cardinal(NewState), Cardinal(Event), 0]);
    end);
end;

procedure TPSPNet.hApctlInit;
begin
  if FApctlInited then
  begin
    FHLE.Result(SCE_NET_APCTL_ERROR_ALREADY_INITIALIZED);
    Exit;
  end;
  FApctlWorker := StartWorker('SceNetApctl', FHLE.ArgInt(1), FHLE.Arg(0));
  FApctlInited := True;
  FApctlState := ApctlStateDisconnected;
  FScanning := False;
  FHLE.Result(0);
end;

procedure TPSPNet.hApctlTerm;
begin
  if FApctlInited then
  begin
    if FScanning then
      FKernel.CancelTimer(FScanTimer);
    StopWorker(FApctlWorker);
    FApctlInited := False;
    FScanning := False;
    FApctlState := ApctlStateDisconnected;
    FillChar(FApctlHandlers, SizeOf(FApctlHandlers), 0);
  end;
  FHLE.Result(0);
end;

procedure TPSPNet.hApctlGetState;
begin
  var P := FHLE.Arg(0);
  if not FApctlInited then
    FHLE.Result(SCE_NET_APCTL_ERROR_NOT_INITIALIZED)
  else if P = 0 then
    FHLE.Result(SCE_NET_APCTL_ERROR_INVALID_ARG)
  else
  begin
    FMemory.Write32(P, Cardinal(FApctlState));
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hApctlGetInfo;
begin
  if not FApctlInited then
    FHLE.Result(SCE_NET_APCTL_ERROR_NOT_INITIALIZED)
  else
    FHLE.Result(SCE_NET_APCTL_ERROR_NOT_CONNECTED);
end;

procedure TPSPNet.hApctlAddHandler;
begin
  if not FApctlInited then
  begin
    FHLE.Result(SCE_NET_APCTL_ERROR_NOT_INITIALIZED);
    Exit;
  end;
  for var I := 0 to High(FApctlHandlers) do
    if not FApctlHandlers[I].Used then
    begin
      if FHLE.Arg(0) = 0 then
        Break;
      FApctlHandlers[I].Used := True;
      FApctlHandlers[I].Func := FHLE.Arg(0);
      FApctlHandlers[I].Arg := FHLE.Arg(1);
      FHLE.Result(Cardinal(I));
      Exit;
    end;
  FHLE.Result(SCE_NET_APCTL_ERROR_TOO_MANY_HANDLERS);
end;

procedure TPSPNet.hApctlDelHandler;
begin
  var Id := FHLE.ArgInt(0);
  if (Id < 0) or (Id > High(FApctlHandlers)) then
    FHLE.Result(SCE_NET_APCTL_ERROR_INVALID_ID)
  else if not FApctlHandlers[Id].Used then
    FHLE.Result(SCE_NET_APCTL_ERROR_HANDLER_NOT_FOUND)
  else
  begin
    FApctlHandlers[Id].Used := False;
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hApctlConnect;
begin
  // No connection profile is set up on this console.
  if not FApctlInited then
    FHLE.Result(SCE_NET_APCTL_ERROR_NOT_INITIALIZED)
  else if FHLE.ArgInt(0) < 0 then
    FHLE.Result(SCE_UTILITY_ERROR_NETCONF_BAD_PROFILE)
  else
    FHLE.Result(SCE_UTILITY_ERROR_NETCONF_NO_PROFILE);
end;

procedure TPSPNet.hApctlDisconnect;
begin
  if not FApctlInited then
    FHLE.Result(SCE_NET_APCTL_ERROR_NOT_INITIALIZED)
  else
    FHLE.Result(0);
end;

procedure TPSPNet.hApctlScanUser;
begin
  if not FApctlInited then
  begin
    FHLE.Result(SCE_NET_APCTL_ERROR_NOT_INITIALIZED);
    Exit;
  end;
  if FScanning or (FApctlState <> ApctlStateDisconnected) then
  begin
    FHLE.Result(SCE_NET_APCTL_ERROR_BUSY);
    Exit;
  end;
  FScanning := True;
  ApctlSetState(ApctlStateScanning, ApctlEventScanRequest);
  FScanTimer := FKernel.AddTimer(FKernel.Scheduler.Now + ApctlScanNs, Self,
    procedure
    begin
      // Every channel, and nobody answered.
      Post(FApctlWorker,
        function: TArray<TNetCall>
        begin
          var Old := FApctlState;
          FApctlState := ApctlStateDisconnected;
          FScanning := False;
          Result := Calls(FApctlHandlers, [Cardinal(Old), ApctlStateDisconnected, ApctlEventScanComplete, 0]);
        end);
    end);
  FHLE.Result(0);
end;

procedure TPSPNet.hApctlGetBSSDescIDListUser;
begin
  var SizePtr := FHLE.Arg(0);
  if not FApctlInited then
    FHLE.Result(SCE_NET_APCTL_ERROR_NOT_INITIALIZED)
  else if SizePtr = 0 then
    FHLE.Result(SCE_NET_APCTL_ERROR_INVALID_ARG)
  else
  begin
    FMemory.Write32(SizePtr, 0);
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hApctlGetBSSDescEntryUser;
begin
  var Code := FHLE.ArgInt(1);
  if not FApctlInited then
    FHLE.Result(SCE_NET_APCTL_ERROR_NOT_INITIALIZED)
  else if (Code < 0) or (Code > 5) then
    FHLE.Result(SCE_NET_APCTL_ERROR_INVALID_CODE)
  else
    FHLE.Result(SCE_NET_APCTL_ERROR_INVALID_ID);
end;

procedure TPSPNet.hNotExported;
begin
  // Imported by programs but not in this firmware's library: the kernel's
  // unresolved stub answers.
  FHLE.Result(SCE_KERNEL_ERROR_LIBRARY_NOT_YET_LINKED);
end;

{ sceNetResolver }

function TPSPNet.ResolverOf(Id: Integer): TNetResolver;
begin
  if not FResolvers.TryGetValue(Id, Result) then
    Result := nil;
end;

procedure TPSPNet.hResolverInit;
begin
  if FResolverInited then
    FHLE.Result(SCE_KERNEL_ERROR_ALREADY)
  else
  begin
    FResolverInited := True;
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hResolverTerm;
begin
  FResolverInited := False;
  FResolvers.Clear;
  FHLE.Result(0);
end;

procedure TPSPNet.hResolverCreate;
begin
  var RidPtr := FHLE.Arg(0);
  var Buf := FHLE.Arg(1);
  var Len := FHLE.Arg(2);
  if (RidPtr = 0) or (Buf = 0) then
  begin
    FHLE.Result(SCE_NET_RESOLVER_ERROR_INVALID_PTR);
    Exit;
  end;
  if Len = 0 then
  begin
    FHLE.Result(SCE_NET_RESOLVER_ERROR_INVALID_BUFLEN);
    Exit;
  end;
  var R := TNetResolver.Create;
  R.Id := FNextResolver;
  Inc(FNextResolver);
  FResolvers.Add(R.Id, R);
  FMemory.Write32(RidPtr, Cardinal(R.Id));
  FHLE.Result(0);
end;

procedure TPSPNet.hResolverDelete;
begin
  var Id := FHLE.ArgInt(0);
  if not FResolverInited then
    FHLE.Result(0)
  else if ResolverOf(Id) = nil then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_ID_NOT_FOUND)
  else
  begin
    FResolvers.Remove(Id);
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hResolverStartNtoA;
begin
  // There is no DNS server to ask, not even for a dotted address.
  var R := ResolverOf(FHLE.ArgInt(0));
  var Name := FHLE.Arg(1);
  var Addr := FHLE.Arg(2);
  if not FResolverInited then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_NO_DNS_SERVER)
  else if R = nil then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_ID_NOT_FOUND)
  else if (Name = 0) or (Addr = 0) then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_INVALID_PTR)
  else if FMemory.Read8(Name) = 0 then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_EMPTY_NAME)
  else
    FHLE.Result(SCE_NET_RESOLVER_ERROR_NO_DNS_SERVER);
end;

procedure TPSPNet.hResolverStartAtoN;
begin
  var R := ResolverOf(FHLE.ArgInt(0));
  if not FResolverInited then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_NO_DNS_SERVER)
  else if R = nil then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_ID_NOT_FOUND)
  else if (FHLE.Arg(1) = 0) or (FHLE.Arg(2) = 0) then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_INVALID_PTR)
  else
    FHLE.Result(SCE_NET_RESOLVER_ERROR_NO_DNS_SERVER);
end;

procedure TPSPNet.hResolverStartNtoAAsync;
begin
  var R := ResolverOf(FHLE.ArgInt(0));
  if not FResolverInited then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_NO_DNS_SERVER)
  else if R = nil then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_ID_NOT_FOUND)
  else if (FHLE.Arg(1) = 0) or (FHLE.Arg(2) = 0) then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_INVALID_PTR)
  else if R.Pending then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_BUSY)
  else
  begin
    R.Pending := True;
    if FMemory.Read8(FHLE.Arg(1)) = 0 then
      R.PendingResult := SCE_NET_RESOLVER_ERROR_EMPTY_NAME
    else
      R.PendingResult := SCE_NET_RESOLVER_ERROR_NO_DNS_SERVER;
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hResolverStartAtoNAsync;
begin
  var R := ResolverOf(FHLE.ArgInt(0));
  if not FResolverInited then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_NO_DNS_SERVER)
  else if R = nil then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_ID_NOT_FOUND)
  else if (FHLE.Arg(1) = 0) or (FHLE.Arg(2) = 0) then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_INVALID_PTR)
  else if R.Pending then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_BUSY)
  else
  begin
    R.Pending := True;
    R.PendingResult := SCE_NET_RESOLVER_ERROR_NO_DNS_SERVER;
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hResolverPollAsync;
begin
  // The lookup has already failed: collecting it returns that failure.
  var R := ResolverOf(FHLE.ArgInt(0));
  if R = nil then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_ID_NOT_FOUND)
  else if FHLE.Arg(1) = 0 then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_INVALID_STATUS_PTR)
  else if not R.Pending then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_NO_ASYNC)
  else
  begin
    R.Pending := False;
    FHLE.Result(R.PendingResult);
  end;
end;

procedure TPSPNet.hResolverWaitAsync;
begin
  var R := ResolverOf(FHLE.ArgInt(0));
  if R = nil then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_ID_NOT_FOUND)
  else if FHLE.Arg(1) = 0 then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_INVALID_STATUS_PTR)
  else if not R.Pending then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_NO_ASYNC)
  else
  begin
    R.Pending := False;
    FHLE.Result(R.PendingResult);
  end;
end;

procedure TPSPNet.hResolverStop;
begin
  var R := ResolverOf(FHLE.ArgInt(0));
  if not FResolverInited then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_NOT_RUNNING)
  else if R = nil then
    FHLE.Result(SCE_NET_RESOLVER_ERROR_ID_NOT_FOUND)
  else
    FHLE.Result(SCE_NET_RESOLVER_ERROR_NOT_RUNNING);
end;

{ sceHttp }

function TPSPNet.HttpId(Kind: Integer; out Id: Cardinal): Boolean;
begin
  Id := FHLE.Arg(0);
  var K: Integer;
  Result := FHttpIds.TryGetValue(Id, K) and (K = Kind);
end;

procedure TPSPNet.hHttpInit;
begin
  FHttpInited := True;
  FHLE.Result(0);
end;

procedure TPSPNet.hHttpEnd;
begin
  FHttpInited := False;
  FHttpIds.Clear;
  FHLE.Result(0);
end;

procedure TPSPNet.hHttpCreateTemplate;
begin
  var Id := FNextTemplate;
  Inc(FNextTemplate);
  FHttpIds.AddOrSetValue(Id, 0);
  FHLE.Result(Id);
end;

procedure TPSPNet.hHttpCreateConnection;
begin
  var K: Integer;
  if not FHttpIds.TryGetValue(FHLE.Arg(0), K) or (K <> 0) then
  begin
    FHLE.Result(SCE_HTTP_ERROR_INVALID_ID);
    Exit;
  end;
  var Id := FNextConnection;
  Inc(FNextConnection);
  FHttpIds.AddOrSetValue(Id, 1);
  FHLE.Result(Id);
end;

procedure TPSPNet.hHttpCreateRequest;
begin
  var K: Integer;
  if not FHttpIds.TryGetValue(FHLE.Arg(0), K) or (K <> 1) then
  begin
    FHLE.Result(SCE_HTTP_ERROR_INVALID_ID);
    Exit;
  end;
  var Id := FNextRequest;
  Inc(FNextRequest);
  FHttpIds.AddOrSetValue(Id, 2);
  FHLE.Result(Id);
end;

procedure TPSPNet.hHttpDeleteTemplate;
begin
  var Id: Cardinal;
  if not HttpId(0, Id) then
    FHLE.Result(SCE_HTTP_ERROR_INVALID_ID)
  else
  begin
    FHttpIds.Remove(Id);
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hHttpDeleteConnection;
begin
  var Id: Cardinal;
  if not HttpId(1, Id) then
    FHLE.Result(SCE_HTTP_ERROR_INVALID_ID)
  else
  begin
    FHttpIds.Remove(Id);
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hHttpDeleteRequest;
begin
  var Id: Cardinal;
  if not HttpId(2, Id) then
    FHLE.Result(SCE_HTTP_ERROR_INVALID_ID)
  else
  begin
    FHttpIds.Remove(Id);
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hHttpSendRequest;
begin
  // The host name goes to the resolver, which has no server to ask.
  var Id: Cardinal;
  if not HttpId(2, Id) then
    FHLE.Result(SCE_HTTP_ERROR_INVALID_ID)
  else
    FHLE.Result(SCE_NET_RESOLVER_ERROR_NO_DNS_SERVER);
end;

procedure TPSPNet.hHttpGetContentLength;
begin
  var Id: Cardinal;
  if not HttpId(2, Id) then
    FHLE.Result(SCE_HTTP_ERROR_INVALID_ID)
  else
    FHLE.Result(SCE_HTTP_ERROR_NO_RESPONSE);
end;

procedure TPSPNet.hHttpGetStatusCode;
begin
  hHttpGetContentLength;
end;

procedure TPSPNet.hHttpReadData;
begin
  hHttpGetContentLength;
end;

procedure TPSPNet.hHttpSetting;
begin
  // Options on a template, connection or request.
  if FHttpIds.ContainsKey(FHLE.Arg(0)) then
    FHLE.Result(0)
  else
    FHLE.Result(SCE_HTTP_ERROR_INVALID_ID);
end;

procedure TPSPNet.hZero;
begin
  FHLE.Result(0);
end;

{ sceUsb: drivers start and activate, but no cable is ever plugged in. }

const
  PSP_USB_CONNECTION_NOT_ESTABLISHED = $001;
  PSP_USB_CABLE_DISCONNECTED = $010;
  PSP_USB_DEACTIVATED = $100;
  PSP_USB_ACTIVATED = $200;
  SCE_USB_ERROR_INVALID_ARGUMENT = Cardinal($80243002);
  SCE_KERNEL_ERROR_WAIT_TIMEOUT_USB = Cardinal($800201A8);

procedure TPSPNet.hUsbStart;
begin
  if FHLE.Arg(0) = 0 then
    FHLE.Result(SCE_USB_ERROR_INVALID_ARGUMENT)
  else
  begin
    FUsbStarted := True;
    FHLE.Result(0);
  end;
end;

procedure TPSPNet.hUsbActivate;
begin
  FUsbActivated := True;
  FHLE.Result(0);
end;

procedure TPSPNet.hUsbDeactivate;
begin
  FUsbActivated := False;
  FHLE.Result(0);
end;

function UsbState(Activated: Boolean): Cardinal;
begin
  Result := PSP_USB_CABLE_DISCONNECTED or PSP_USB_CONNECTION_NOT_ESTABLISHED;
  if Activated then
    Result := Result or PSP_USB_ACTIVATED
  else
    Result := Result or PSP_USB_DEACTIVATED;
end;

procedure TPSPNet.hUsbGetState;
begin
  FHLE.Result(UsbState(FUsbActivated));
end;

procedure TPSPNet.hUsbWaitState;
begin
  // Waits for any (mode 0) or all (mode 1) of the bits; the state never changes.
  var Want := FHLE.Arg(0);
  var State := UsbState(FUsbActivated);
  if ((FHLE.Arg(1) = 0) and ((State and Want) <> 0)) or ((FHLE.Arg(1) <> 0) and ((State and Want) = Want)) then
    FHLE.Result(State)
  else
    FHLE.Result(SCE_KERNEL_ERROR_WAIT_TIMEOUT_USB);
end;

procedure TPSPNet.Register;
const
  N = 'sceNet';
  W = 'sceWlanDrv';
  A = 'sceNetApctl';
  R = 'sceNetResolver';
  H = 'sceHttp';
  S = 'sceSsl';
  U = 'sceParseUri';
begin
  var X := FHLE;
  X.Register('RetroMulNet', 1, 'NetLibraryThread', hWorker);
  FWorkerIndex := X.Find('RetroMulNet', 1);

  X.Register(U, $568518C9, 'sceUriParse', hUriParse);
  X.Register(U, $7EE318AF, 'sceUriBuild', hUriBuild);
  X.Register(U, $49E950EC, 'sceUriEscape', hUriEscape);
  X.Register(U, $062BB07E, 'sceUriUnescape', hUriUnescape);

  X.Register(N, $39AF39A6, 'sceNetInit', hNetInit);
  X.Register(N, $281928A9, 'sceNetTerm', hNetTerm);
  X.Register(N, $89360950, 'sceNetEtherNtostr', hNetEtherNtostr);
  X.Register(N, $D27961C9, 'sceNetEtherStrton', hNetEtherStrton);
  X.Register(N, $0BF0A3AE, 'sceNetGetLocalEtherAddr', hNetGetLocalEtherAddr);
  X.Register(N, $CC393E48, 'sceNetGetMallocStat', hNetGetMallocStat);
  X.Register(N, $AD6844C6, 'sceNetThreadAbort', hNetThreadAbort);
  X.Register(N, $50647530, 'sceNetFreeThreadinfo', hNetFreeThreadinfo);

  X.Register(W, $D7763699, 'sceWlanGetSwitchState', hWlanGetSwitchState);
  X.Register(W, $93440B11, 'sceWlanDevIsPowerOn', hWlanDevIsPowerOn);
  X.Register(W, $0C622081, 'sceWlanGetEtherAddr', hWlanGetEtherAddr);

  X.Register(A, $E2F91F9B, 'sceNetApctlInit', hApctlInit);
  X.Register(A, $B3EDD0EC, 'sceNetApctlTerm', hApctlTerm);
  X.Register(A, $5DEAC81B, 'sceNetApctlGetState', hApctlGetState);
  X.Register(A, $2BEFDF23, 'sceNetApctlGetInfo', hApctlGetInfo);
  X.Register(A, $8ABADD51, 'sceNetApctlAddHandler', hApctlAddHandler);
  X.Register(A, $5963991B, 'sceNetApctlDelHandler', hApctlDelHandler);
  X.Register(A, $CFB957C6, 'sceNetApctlConnect', hApctlConnect);
  X.Register(A, $24FE91A1, 'sceNetApctlDisconnect', hApctlDisconnect);
  X.Register(A, $E9B2E5E6, 'sceNetApctlScanUser', hApctlScanUser);
  X.Register(A, $6BDDCB8C, 'sceNetApctlGetBSSDescIDListUser', hApctlGetBSSDescIDListUser);
  X.Register(A, $04776994, 'sceNetApctlGetBSSDescEntryUser', hApctlGetBSSDescEntryUser);
  X.Register(A, $B3CF6849, 'sceNetApctlScan', hNotExported);
  X.Register(A, $0C7FFA5C, 'sceNetApctlGetBSSDescIDList', hNotExported);
  X.Register(A, $96BEB231, 'sceNetApctlGetBSSDescEntry', hNotExported);

  X.Register(R, $F3370E61, 'sceNetResolverInit', hResolverInit);
  X.Register(R, $6138194A, 'sceNetResolverTerm', hResolverTerm);
  X.Register(R, $244172AF, 'sceNetResolverCreate', hResolverCreate);
  X.Register(R, $94523E09, 'sceNetResolverDelete', hResolverDelete);
  X.Register(R, $224C5F44, 'sceNetResolverStartNtoA', hResolverStartNtoA);
  X.Register(R, $629E2FB7, 'sceNetResolverStartAtoN', hResolverStartAtoN);
  X.Register(R, $14C17EF9, 'sceNetResolverStartNtoAAsync', hResolverStartNtoAAsync);
  X.Register(R, $AAC09184, 'sceNetResolverStartAtoNAsync', hResolverStartAtoNAsync);
  X.Register(R, $4EE99358, 'sceNetResolverPollAsync', hResolverPollAsync);
  X.Register(R, $12748EB9, 'sceNetResolverWaitAsync', hResolverWaitAsync);
  X.Register(R, $808F6063, 'sceNetResolverStop', hResolverStop);

  X.Register(H, $AB1ABE07, 'sceHttpInit', hHttpInit);
  X.Register(H, $D1C8945E, 'sceHttpEnd', hHttpEnd);
  X.Register(H, $9B1F1F36, 'sceHttpCreateTemplate', hHttpCreateTemplate);
  X.Register(H, $4E4A284A, 'sceHttpCloneTemplate', hHttpCreateTemplate);
  X.Register(H, $FCF8C055, 'sceHttpDeleteTemplate', hHttpDeleteTemplate);
  X.Register(H, $8EEFD953, 'sceHttpCreateConnection', hHttpCreateConnection);
  X.Register(H, $CDF8ECB9, 'sceHttpCreateConnectionWithURL', hHttpCreateConnection);
  X.Register(H, $5152773B, 'sceHttpDeleteConnection', hHttpDeleteConnection);
  X.Register(H, $47347B50, 'sceHttpCreateRequest', hHttpCreateRequest);
  X.Register(H, $B509B09E, 'sceHttpCreateRequestWithURL', hHttpCreateRequest);
  X.Register(H, $A5512E01, 'sceHttpDeleteRequest', hHttpDeleteRequest);
  X.Register(H, $BB70706F, 'sceHttpSendRequest', hHttpSendRequest);
  X.Register(H, $9AFC98B2, 'sceHttpSendRequestInCacheFirstMode', hHttpSendRequest);
  X.Register(H, $C10B6BD9, 'sceHttpAbortRequest', hHttpSetting);
  X.Register(H, $0282A3BD, 'sceHttpGetContentLength', hHttpGetContentLength);
  X.Register(H, $4CC7D78F, 'sceHttpGetStatusCode', hHttpGetStatusCode);
  X.Register(H, $EDEEB999, 'sceHttpReadData', hHttpReadData);
  X.Register(H, $3EABA285, 'sceHttpAddExtraHeader', hHttpSetting);
  X.Register(H, $15540184, 'sceHttpDeleteHeader', hHttpSetting);
  X.Register(H, $47940436, 'sceHttpSetResolveTimeOut', hHttpSetting);
  X.Register(H, $03D9526F, 'sceHttpSetResolveRetry', hHttpSetting);
  X.Register(H, $8ACD1F73, 'sceHttpSetConnectTimeOut', hHttpSetting);
  X.Register(H, $9988172D, 'sceHttpSetSendTimeOut', hHttpSetting);
  X.Register(H, $1F0FC3E3, 'sceHttpSetRecvTimeOut', hHttpSetting);
  X.Register(H, $78A0D3EC, 'sceHttpEnableKeepAlive', hHttpSetting);
  X.Register(H, $C7EF2559, 'sceHttpDisableKeepAlive', hHttpSetting);
  X.Register(H, $0809C831, 'sceHttpEnableRedirect', hHttpSetting);
  X.Register(H, $1A0EBB69, 'sceHttpDisableRedirect', hHttpSetting);
  X.Register(H, $0DAFA58F, 'sceHttpEnableCookie', hHttpSetting);
  X.Register(H, $0B12ABFB, 'sceHttpDisableCookie', hHttpSetting);
  X.Register(H, $9FC5F10D, 'sceHttpEnableAuth', hHttpSetting);
  X.Register(H, $AE948FEE, 'sceHttpDisableAuth', hHttpSetting);
  X.Register(H, $59E6D16F, 'sceHttpEnableCache', hHttpSetting);
  X.Register(H, $CCBD167A, 'sceHttpDisableCache', hHttpSetting);
  X.Register(H, $2A6C3296, 'sceHttpSetAuthInfoCB', hHttpSetting);
  X.Register(H, $A4496DE5, 'sceHttpSetRedirectCallback', hHttpSetting);
  X.Register(H, $9668864C, 'sceHttpSetRecvBlockSize', hHttpSetting);
  X.Register(H, $C98CBBA7, 'sceHttpSetResHeaderMaxSize', hHttpSetting);
  X.Register(H, $C6330B0D, 'sceHttpChangeHttpVersion', hHttpSetting);
  X.Register(H, $A6800C34, 'sceHttpInitCache', hZero);
  X.Register(H, $78B54C09, 'sceHttpEndCache', hZero);
  X.Register(H, $1CEDB9D4, 'sceHttpFlushCache', hZero);
  X.Register(H, $F1657B22, 'sceHttpLoadSystemCookie', hZero);
  X.Register(H, $76D1363B, 'sceHttpSaveSystemCookie', hZero);
  X.Register(H, $E4D21302, 'sceHttpsInit', hZero);
  X.Register(H, $68AB0F86, 'sceHttpsInitWithPath', hZero);
  X.Register(H, $F9D8EB63, 'sceHttpsEnd', hZero);
  X.Register(H, $87797BDD, 'sceHttpsLoadDefaultCert', hZero);

  X.Register(S, $957ECBE2, 'sceSslInit', hZero);
  X.Register(S, $191CDEFF, 'sceSslEnd', hZero);

  X.Register('sceUsb', $AE5DE6AF, 'sceUsbStart', hUsbStart);
  X.Register('sceUsb', $C2464FA0, 'sceUsbStop', hZero);
  X.Register('sceUsb', $586DB82C, 'sceUsbActivate', hUsbActivate);
  X.Register('sceUsb', $C572A9C8, 'sceUsbDeactivate', hUsbDeactivate);
  X.Register('sceUsb', $C21645A4, 'sceUsbGetState', hUsbGetState);
  X.Register('sceUsb', $112CC951, 'sceUsbGetDrvState', hZero);
  X.Register('sceUsb', $4E537366, 'sceUsbGetDrvList', hZero);
  X.Register('sceUsb', $5BE0E002, 'sceUsbWaitState', hUsbWaitState);
  X.Register('sceUsb', $1C360735, 'sceUsbWaitCancel', hZero);

  InetRegister;
  AdhocRegister;
end;

initialization
  RegisterPSPService(TPSPNet);

end.
