unit PSP.Utility;

// sceUtility: savedata, dialogs, on-screen keyboard, system parameters, modules.
// One dialog type is current at a time (the last one started); its status runs
// NONE -> INIT -> RUNNING -> FINISHED -> SHUTDOWN -> NONE on the master clock.
// Nothing is drawn: a TPSPDialogView can be attached to draw running dialogs
// and supply the buttons they react to. Without one, message dialogs answer
// themselves after a while so programs do not stall.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE,
  PSP.Kernel, PSP.Scheduler, PSP.Service;

const
  PSPDialogNone = 0;
  PSPDialogInit = 1;
  PSPDialogRunning = 2;
  PSPDialogFinished = 3;
  PSPDialogShutdown = 4;

type
  TPSPDialogType = (dtNone, dtMsg, dtSavedata, dtOsk, dtNetconf, dtGameSharing, dtScreenshot, dtInstall, dtNpSignin,
    dtHtml);

  TPSPDialog = class
  public
    Kind: TPSPDialogType;
    Status: Cardinal;
    Params: Cardinal;
    Size: Cardinal;
    Updates: Integer;
    InitAt, RunningAt: Int64;
    // An Update arrived while initialising.
    Pumped: Boolean;
    Aborted: Boolean;
    // A result the dialog finishes with on its own (bad parameters).
    Error: Cardinal;
    // Savedata work done on the first Update.
    Done: Boolean;
  end;

  // Draws a running dialog and returns the buttons (PSP_CTRL_*) held for it.
  TPSPDialogView = class
  public
    function Update(Dialog: TPSPDialog; Memory: TPSPMemory): Cardinal; virtual; abstract;
  end;

  TPSPUtility = class(TPSPService)
  private
    FCurrent: TPSPDialogType;
    FDialogs: array[TPSPDialogType] of TPSPDialog;
    FHtmlStarted: Boolean;
    FHtmlMemory: Cardinal;
    FModules: TList<Cardinal>;
    FDelayWord: Cardinal;
    FView: TPSPDialogView;
    FLastButtons: Cardinal;
    // The dialog's own threads, as one guest thread that keeps the CPU until FWorkUntil.
    FWorkIndex: Integer;
    FWorkStub: Cardinal;
    FWorkThread: TPSPThread;
    FWorkUntil: Int64;
    procedure Work(D: TPSPDialog; Ns: Int64);
    procedure hDialogThread;
    function Dialog(Kind: TPSPDialogType): TPSPDialog; inline;
    function Busy: Boolean;
    procedure Yield(Us: Cardinal);
    procedure At(Delay: Int64; D: TPSPDialog; const Event: TPSPTimerEvent);
    procedure EnterRunning(D: TPSPDialog);
    procedure Finish(D: TPSPDialog);
    procedure InitStart(Kind: TPSPDialogType; const Sizes: array of Cardinal);
    procedure GetStatus(Kind: TPSPDialogType);
    procedure Update(Kind: TPSPDialogType);
    procedure ShutdownStart(Kind: TPSPDialogType);
    procedure Step(D: TPSPDialog);
    procedure StepMsg(D: TPSPDialog);
    procedure StepOsk(D: TPSPDialog);
    procedure StepOther(D: TPSPDialog);
    procedure CheckMsgParams(D: TPSPDialog);
    function Pressed(D: TPSPDialog): Cardinal;
    // Savedata
    procedure StepSavedata(D: TPSPDialog);
    // Modules
    procedure ModuleLoad(Id: Cardinal; Valid: Boolean; ErrBase: Cardinal);
    procedure ModuleUnload(Id: Cardinal; Valid: Boolean; ErrBase: Cardinal);
    // HLE
    procedure hMsgInitStart;
    procedure hMsgGetStatus;
    procedure hMsgUpdate;
    procedure hMsgShutdownStart;
    procedure hMsgAbort;
    procedure hSavedataInitStart;
    procedure hSavedataGetStatus;
    procedure hSavedataUpdate;
    procedure hSavedataShutdownStart;
    procedure hOskInitStart;
    procedure hOskGetStatus;
    procedure hOskUpdate;
    procedure hOskShutdownStart;
    procedure hNetconfInitStart;
    procedure hNetconfGetStatus;
    procedure hNetconfUpdate;
    procedure hNetconfShutdownStart;
    procedure hSharingInitStart;
    procedure hSharingGetStatus;
    procedure hSharingUpdate;
    procedure hSharingShutdownStart;
    procedure hScreenshotInitStart;
    procedure hScreenshotGetStatus;
    procedure hScreenshotUpdate;
    procedure hScreenshotShutdownStart;
    procedure hScreenshotContStart;
    procedure hInstallInitStart;
    procedure hInstallGetStatus;
    procedure hNpSigninInitStart;
    procedure hNpSigninGetStatus;
    procedure hNpSigninUpdate;
    procedure hNpSigninShutdownStart;
    procedure hHtmlInitStart;
    procedure hHtmlGetStatus;
    procedure hHtmlUpdate;
    procedure hHtmlShutdownStart;
    procedure hGetSystemParamInt;
    procedure hGetSystemParamString;
    procedure hSetSystemParamInt;
    procedure hSetSystemParamString;
    procedure hCheckNetParam;
    procedure hGetNetParam;
    procedure hLoadModule;
    procedure hUnloadModule;
    procedure hLoadNetModule;
    procedure hUnloadNetModule;
    procedure hLoadAvModule;
    procedure hUnloadAvModule;
    procedure hLoadUsbModule;
    procedure hUnloadUsbModule;
  public
    constructor Create(System: TPSPSystem); override;
    destructor Destroy; override;
    procedure Reset; override;
    procedure Register; override;
    property View: TPSPDialogView read FView write FView;
  end;

const
  SCE_UTILITY_ERROR_INVALID_STATUS = Cardinal($80110001);
  SCE_UTILITY_ERROR_INVALID_PARAM_SIZE = Cardinal($80110004);
  SCE_UTILITY_ERROR_WRONG_TYPE = Cardinal($80110005);

implementation

uses
  System.Math, System.IOUtils, System.Hash, PSP.SysMem, PSP.IO, PSP.SFO, PSP.Settings;

const
  // A message dialog leaves INIT this long after InitStart, or sooner when the
  // program pumps it with Update meanwhile.
  MsgInitNs = 650000000;
  MsgPumpedInitNs = 540000000;
  MsgFadeUpdates = 8;
  DialogShutdownNs = 25000000;
  DialogShutdownWorkNs = 8000000;
  SavedataInitNs = 33000000;
  SavedataShutdownNs = 500000;
  // The utility's own thread runs at this priority: a caller below it never sees SHUTDOWN.
  UtilityThreadPriority = 32;
  HeadlessAnswerNs: Int64 = 3000000000;
  UpdateYieldUs = 100;
  PSP_CTRL_CROSS = $4000;
  PSP_CTRL_CIRCLE = $2000;

{$I PSP.Utility.Dialogs.inc}
{$I PSP.Utility.Savedata.inc}

constructor TPSPUtility.Create(System: TPSPSystem);
begin
  inherited Create(System);
  for var K := Low(TPSPDialogType) to High(TPSPDialogType) do
  begin
    FDialogs[K] := TPSPDialog.Create;
    FDialogs[K].Kind := K;
  end;
  FModules := TList<Cardinal>.Create;
end;

destructor TPSPUtility.Destroy;
begin
  for var K := Low(TPSPDialogType) to High(TPSPDialogType) do
    FDialogs[K].Free;
  FModules.Free;
  inherited;
end;

procedure TPSPUtility.Reset;
begin
  FCurrent := dtNone;
  for var K := Low(TPSPDialogType) to High(TPSPDialogType) do
  begin
    var D := FDialogs[K];
    D.Status := PSPDialogNone;
    D.Params := 0;
    D.Updates := 0;
    D.Done := False;
  end;
  FHtmlStarted := False;
  FHtmlMemory := 0;
  FModules.Clear;
  FDelayWord := FKernel.AllocKernel(16, 'utility delay');
  FLastButtons := 0;
  FWorkStub := FKernel.AllocKernel(16, 'utility thread');
  FWorkThread := nil;
  FWorkUntil := 0;
end;

procedure TPSPUtility.Work(D: TPSPDialog; Ns: Int64);
begin
  // At the priority the program gave the dialog's threads.
  var Prio := 0;
  if D.Params <> 0 then
    for var K := 0 to 3 do
    begin
      var P := Integer(FMemory.Read32(D.Params + 12 + Cardinal(K * 4)));
      if (P > 0) and ((Prio = 0) or (P < Prio)) then
        Prio := P;
    end;
  if Prio = 0 then
    Exit;
  FWorkUntil := FKernel.Scheduler.Now + Ns;
  if (FWorkThread = nil) or (FKernel.ThreadById(FWorkThread.UID) <> FWorkThread) then
  begin
    // The thread loops on: syscall; j loop.
    FMemory.Write32(FWorkStub, (Cardinal(FWorkIndex) shl 6) or $0C);
    FMemory.Write32(FWorkStub + 4, (2 shl 26) or ((FWorkStub shr 2) and $03FFFFFF));
    FMemory.Write32(FWorkStub + 8, 0);
    FWorkThread := FKernel.CreateThread('SceUtilityDialog', FWorkStub, Prio, $800, 0, FSystem.CPU.Ctx.GPR[28]);
    if FWorkThread <> nil then
      FKernel.StartThread(FWorkThread, 0, 0);
    Exit;
  end;
  if FWorkThread.Priority <> Prio then
    FKernel.ChangePriority(FWorkThread, Prio);
  if FWorkThread.IsWaiting and (FWorkThread.Wait.HLETag = 'utility thread') then
    FKernel.EndWait(FWorkThread, 0);
end;

procedure TPSPUtility.hDialogThread;
begin
  var Left := FWorkUntil - FKernel.Scheduler.Now;
  if Left > 0 then
    // Busy: a slice of computing, then round again.
    FSystem.CPU.AddCycles(Integer(Min(Left, Int64(100000)) * FKernel.Scheduler.MHz div 1000))
  else
    FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, False, nil, nil, 'utility thread');
end;

function TPSPUtility.Dialog(Kind: TPSPDialogType): TPSPDialog;
begin
  Result := FDialogs[Kind];
end;

function TPSPUtility.Busy: Boolean;
begin
  Result := (FCurrent <> dtNone) and (FDialogs[FCurrent].Status <> PSPDialogNone);
end;

procedure TPSPUtility.Yield(Us: Cardinal);
begin
  if not FKernel.CanWait then
    Exit;
  FMemory.Write32(FDelayWord, Us);
  FKernel.BeginWait(PSPWaitDelay, nil, 0, FDelayWord, False, nil, nil, 'utility');
end;

procedure TPSPUtility.At(Delay: Int64; D: TPSPDialog; const Event: TPSPTimerEvent);
begin
  FKernel.AddTimer(FKernel.Scheduler.Now + Delay, D, Event);
end;

procedure TPSPUtility.EnterRunning(D: TPSPDialog);
begin
  if D.Status <> PSPDialogInit then
    Exit;
  D.Status := PSPDialogRunning;
  D.RunningAt := FKernel.Scheduler.Now;
  D.Updates := 0;
end;

procedure TPSPUtility.Finish(D: TPSPDialog);
begin
  D.Status := PSPDialogFinished;
end;

procedure TPSPUtility.InitStart(Kind: TPSPDialogType; const Sizes: array of Cardinal);
begin
  var P := FHLE.Arg(0);
  if Busy then
    begin FHLE.Result(SCE_UTILITY_ERROR_INVALID_STATUS); Exit; end;
  var Size: Cardinal := 0;
  if P <> 0 then
    Size := FMemory.Read32(P);
  var Ok := False;
  for var S in Sizes do
    if S = Size then
      Ok := True;
  if not Ok then
    begin FHLE.Result(SCE_UTILITY_ERROR_INVALID_PARAM_SIZE); Exit; end;
  FCurrent := Kind;
  var D := FDialogs[Kind];
  FKernel.CancelTimersOf(D);
  D.Status := PSPDialogInit;
  D.Params := P;
  D.Size := Size;
  D.Updates := 0;
  D.InitAt := FKernel.Scheduler.Now;
  D.Pumped := False;
  D.Aborted := False;
  D.Error := 0;
  D.Done := False;
  FHLE.Result(0);
  case Kind of
    dtMsg:
      begin
        CheckMsgParams(D);
        At(MsgPumpedInitNs, D,
          procedure
          begin
            if D.Pumped then
              EnterRunning(D);
          end);
        At(MsgInitNs, D,
          procedure
          begin
            EnterRunning(D);
          end);
      end;
  else
    At(SavedataInitNs, D,
      procedure
      begin
        EnterRunning(D);
      end);
  end;
end;

procedure TPSPUtility.GetStatus(Kind: TPSPDialogType);
begin
  if FCurrent <> Kind then
    FHLE.Result(SCE_UTILITY_ERROR_WRONG_TYPE)
  else
    FHLE.Result(FDialogs[Kind].Status);
end;

procedure TPSPUtility.Update(Kind: TPSPDialogType);
begin
  if FCurrent <> Kind then
    begin FHLE.Result(SCE_UTILITY_ERROR_WRONG_TYPE); Exit; end;
  var D := FDialogs[Kind];
  if D.Status = PSPDialogInit then
    D.Pumped := True;
  if D.Status <> PSPDialogRunning then
    begin FHLE.Result(SCE_UTILITY_ERROR_INVALID_STATUS); Exit; end;
  Inc(D.Updates);
  FHLE.Result(0);
  Step(D);
  // Update hands the frame to the dialog's threads and waits for them.
  Yield(UpdateYieldUs);
end;

procedure TPSPUtility.ShutdownStart(Kind: TPSPDialogType);
begin
  if FCurrent <> Kind then
    begin FHLE.Result(SCE_UTILITY_ERROR_WRONG_TYPE); Exit; end;
  var D := FDialogs[Kind];
  if D.Status <> PSPDialogFinished then
    begin FHLE.Result(SCE_UTILITY_ERROR_INVALID_STATUS); Exit; end;
  FHLE.Result(0);
  D.Status := PSPDialogShutdown;
  var Delay: Int64 := DialogShutdownNs;
  if Kind = dtSavedata then
  begin
    // Savedata shuts down on the utility thread; a caller it preempts finds it done.
    if (FKernel.Current <> nil) and (FKernel.Current.Priority > UtilityThreadPriority) then
    begin
      D.Status := PSPDialogNone;
      Exit;
    end;
    Delay := SavedataShutdownNs;
  end
  else
    // Its threads spend part of the shutdown computing.
    Work(D, DialogShutdownWorkNs);
  At(Delay, D,
    procedure
    begin
      if D.Status = PSPDialogShutdown then
        D.Status := PSPDialogNone;
    end);
end;

procedure TPSPUtility.Step(D: TPSPDialog);
begin
  case D.Kind of
    dtMsg: StepMsg(D);
    dtSavedata: StepSavedata(D);
    dtOsk: StepOsk(D);
  else
    StepOther(D);
  end;
end;

function TPSPUtility.Pressed(D: TPSPDialog): Cardinal;
begin
  Result := 0;
  if FView = nil then
    Exit;
  var Buttons := FView.Update(D, FMemory);
  Result := Buttons and not FLastButtons;
  FLastButtons := Buttons;
end;

{ Message dialog, OSK and the rest: PSP.Utility.Dialogs.inc }

procedure TPSPUtility.Register;
const
  U = 'sceUtility';
begin
  var H := FHLE;
  H.Register('RetroMulUtility', 1, 'UtilityDialogThread', hDialogThread);
  FWorkIndex := H.Find('RetroMulUtility', 1);
  H.Register(U, $2AD8E239, 'sceUtilityMsgDialogInitStart', hMsgInitStart);
  H.Register(U, $9A1C91D7, 'sceUtilityMsgDialogGetStatus', hMsgGetStatus);
  H.Register(U, $95FC253B, 'sceUtilityMsgDialogUpdate', hMsgUpdate);
  H.Register(U, $67AF3428, 'sceUtilityMsgDialogShutdownStart', hMsgShutdownStart);
  H.Register(U, $4928BD96, 'sceUtilityMsgDialogAbort', hMsgAbort);
  H.Register(U, $50C4CD57, 'sceUtilitySavedataInitStart', hSavedataInitStart);
  H.Register(U, $8874DBE0, 'sceUtilitySavedataGetStatus', hSavedataGetStatus);
  H.Register(U, $D4B95FFB, 'sceUtilitySavedataUpdate', hSavedataUpdate);
  H.Register(U, $9790B33C, 'sceUtilitySavedataShutdownStart', hSavedataShutdownStart);
  H.Register(U, $F6269B82, 'sceUtilityOskInitStart', hOskInitStart);
  H.Register(U, $F3F76017, 'sceUtilityOskGetStatus', hOskGetStatus);
  H.Register(U, $4B85C861, 'sceUtilityOskUpdate', hOskUpdate);
  H.Register(U, $3DFAEBA9, 'sceUtilityOskShutdownStart', hOskShutdownStart);
  H.Register(U, $4DB1E739, 'sceUtilityNetconfInitStart', hNetconfInitStart);
  H.Register(U, $6332AA39, 'sceUtilityNetconfGetStatus', hNetconfGetStatus);
  H.Register(U, $91E70E35, 'sceUtilityNetconfUpdate', hNetconfUpdate);
  H.Register(U, $F88155F6, 'sceUtilityNetconfShutdownStart', hNetconfShutdownStart);
  H.Register(U, $C492F751, 'sceUtilityGameSharingInitStart', hSharingInitStart);
  H.Register(U, $946963F3, 'sceUtilityGameSharingGetStatus', hSharingGetStatus);
  H.Register(U, $7853182D, 'sceUtilityGameSharingUpdate', hSharingUpdate);
  H.Register(U, $EFC6F80F, 'sceUtilityGameSharingShutdownStart', hSharingShutdownStart);
  H.Register(U, $0251B134, 'sceUtilityScreenshotInitStart', hScreenshotInitStart);
  H.Register(U, $D81957B7, 'sceUtilityScreenshotGetStatus', hScreenshotGetStatus);
  H.Register(U, $AB083EA9, 'sceUtilityScreenshotUpdate', hScreenshotUpdate);
  H.Register(U, $F9E0008C, 'sceUtilityScreenshotShutdownStart', hScreenshotShutdownStart);
  H.Register(U, $86A03A27, 'sceUtilityScreenshotContStart', hScreenshotContStart);
  H.Register(U, $24AC31EB, 'sceUtilityGamedataInstallInitStart', hInstallInitStart);
  H.Register(U, $B57E95D9, 'sceUtilityGamedataInstallGetStatus', hInstallGetStatus);
  H.Register(U, $16D02AF0, 'sceUtilityNpSigninInitStart', hNpSigninInitStart);
  H.Register(U, $86ABDB1B, 'sceUtilityNpSigninGetStatus', hNpSigninGetStatus);
  H.Register(U, $F3FBC572, 'sceUtilityNpSigninUpdate', hNpSigninUpdate);
  H.Register(U, $E19C97D6, 'sceUtilityNpSigninShutdownStart', hNpSigninShutdownStart);
  H.Register(U, $CDC3AA41, 'sceUtilityHtmlViewerInitStart', hHtmlInitStart);
  H.Register(U, $BDA7D894, 'sceUtilityHtmlViewerGetStatus', hHtmlGetStatus);
  H.Register(U, $05AFB9E4, 'sceUtilityHtmlViewerUpdate', hHtmlUpdate);
  H.Register(U, $F5CE1134, 'sceUtilityHtmlViewerShutdownStart', hHtmlShutdownStart);
  H.Register(U, $A5DA2406, 'sceUtilityGetSystemParamInt', hGetSystemParamInt);
  H.Register(U, $34B78343, 'sceUtilityGetSystemParamString', hGetSystemParamString);
  H.Register(U, $45C18506, 'sceUtilitySetSystemParamInt', hSetSystemParamInt);
  H.Register(U, $41E30674, 'sceUtilitySetSystemParamString', hSetSystemParamString);
  H.Register(U, $5EEE6548, 'sceUtilityCheckNetParam', hCheckNetParam);
  H.Register(U, $434D4B3A, 'sceUtilityGetNetParam', hGetNetParam);
  H.Register(U, $2A2B3DE0, 'sceUtilityLoadModule', hLoadModule);
  H.Register(U, $E49BFE92, 'sceUtilityUnloadModule', hUnloadModule);
  H.Register(U, $1579A159, 'sceUtilityLoadNetModule', hLoadNetModule);
  H.Register(U, $64D50C56, 'sceUtilityUnloadNetModule', hUnloadNetModule);
  H.Register(U, $C629AF26, 'sceUtilityLoadAvModule', hLoadAvModule);
  H.Register(U, $F7D8D092, 'sceUtilityUnloadAvModule', hUnloadAvModule);
  H.Register(U, $0D5BC6D2, 'sceUtilityLoadUsbModule', hLoadUsbModule);
  H.Register(U, $F64910F0, 'sceUtilityUnloadUsbModule', hUnloadUsbModule);
end;

initialization
  RegisterPSPService(TPSPUtility);

end.
