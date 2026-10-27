unit PSP.Kernel;

// Kernel objects, threads and the scheduler. One guest thread owns the CPU at a
// time; the others keep their context here. Waits are records on the thread
// plus a place in the waited object's queue; a timeout is a kernel timer.
// Guest code called by the kernel (callbacks, interrupt handlers, alarms, HLE
// continuations) runs in frames that end at the return trap.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Generics.Collections, System.Generics.Defaults,
  PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Scheduler, PSP.SysMem;

const
  PSPThreadRunning = 1;
  PSPThreadReady = 2;
  PSPThreadWaiting = 4;
  PSPThreadSuspended = 8;
  PSPThreadDormant = 16;
  PSPThreadDead = 32;

  PSPInterruptGE = 25;
  PSPInterruptVBlank = 30;

  // Guest-visible wait types (sceKernelReferThreadStatus).
  PSPWaitNone = 0;
  PSPWaitSleep = 1;
  PSPWaitDelay = 2;
  PSPWaitSema = 3;
  PSPWaitEventFlag = 4;
  PSPWaitMbx = 5;
  PSPWaitVpl = 6;
  PSPWaitFpl = 7;
  PSPWaitMsgPipe = 8;
  PSPWaitThreadEnd = 9;
  PSPWaitEventHandler = 10;
  PSPWaitCallback = 11;
  PSPWaitMutex = 12;
  PSPWaitLwMutex = 13;

type
  TPSPKernel = class;
  TPSPThread = class;

  TPSPKernelObject = class
  public
    UID: Cardinal;
    Name: string;
    Kernel: TPSPKernel;
    // ThreadManForUser id type (sceKernelGetThreadmanIdType); 0 for others.
    class function IdType: Integer; virtual;
    // A waiting thread leaves this object's queue (timeout, cancel, delete).
    procedure RemoveWaiter(T: TPSPThread); virtual;
    // Puts a thread back in the queue after its callbacks ran.
    procedure AddWaiter(T: TPSPThread); virtual;
    destructor Destroy; override;
  end;
  TPSPKernelObjectClass = class of TPSPKernelObject;

  // Tries to satisfy a wait again (after callbacks ran on the thread). On
  // success it sets the thread's result and returns True.
  TPSPWaitRetry = function(T: TPSPThread): Boolean of object;
  // Called when a wait ends without the object (timeout, release, delete):
  // lets an HLE subsystem forget the thread.
  TPSPWaitAbort = procedure(T: TPSPThread) of object;

  TPSPWait = record
    Kind: Integer;
    Id: Cardinal;
    Obj: TPSPKernelObject;
    Deadline: Int64;
    TimeoutPtr: Cardinal;
    AllowCB: Boolean;
    Retry: TPSPWaitRetry;
    Abort: TPSPWaitAbort;
    Data: array[0..5] of Cardinal;
    HLETag: string;
  end;

  TPSPCallback = class(TPSPKernelObject)
  public
    Thread: TPSPThread;
    Func, Common, GP: Cardinal;
    NotifyCount, NotifyArg: Cardinal;
    class function IdType: Integer; override;
  end;

  TPSPFrameKind = (fkCallback, fkHLE, fkInterrupt, fkThreadStart);

  TPSPGuestReturn = reference to procedure(Value: Cardinal);

  TPSPFrame = record
    Kind: TPSPFrameKind;
    Saved: TPSPContext;
    SavedWait: TPSPWait;
    WasWaiting: Boolean;
    Callback: TPSPCallback;
    OnReturn: TPSPGuestReturn;
    CallbacksRan: Integer;
  end;

  TPSPThread = class(TPSPKernelObject)
  public
    Ctx: TPSPContext;
    Status: Cardinal;
    Priority, InitPriority: Integer;
    Attr, Entry, StackBlock, StackSize, StackTop, GP: Cardinal;
    Wait: TPSPWait;
    WakeupCount: Integer;
    ExitStatus: Cardinal;
    RunClocks: Int64;
    Callbacks: TList<TPSPCallback>;
    Frames: TList<TPSPFrame>;
    EndWaiters: TList<TPSPThread>;
    ModuleId: Cardinal;
    CallbacksPending: Boolean;
    SuspendedWhileWaiting: Boolean;
    ReleaseCount, PreemptCount: Cardinal;
    Seq: Int64;
    // Runs once when the thread exits or is terminated.
    OnExit: TProc<TPSPThread>;
    constructor Create;
    destructor Destroy; override;
    class function IdType: Integer; override;
    procedure RemoveWaiter(T: TPSPThread); override;
    procedure AddWaiter(T: TPSPThread); override;
    function IsWaiting: Boolean; inline;
    // Where a wait result goes: the thread's context, or the context a callback
    // frame will restore.
    procedure SetResult(Value: Cardinal);
    function HasPendingCallbacks: Boolean;
  end;

  // Threads waiting on an object, FIFO or by priority.
  TPSPWaitQueue = class
  private
    FItems: TList<TPSPThread>;
    FByPriority: Boolean;
  public
    constructor Create(ByPriority: Boolean);
    destructor Destroy; override;
    procedure Add(T: TPSPThread);
    procedure Remove(T: TPSPThread);
    function First: TPSPThread;
    function Count: Integer;
    function Item(I: Integer): TPSPThread;
    procedure Clear;
    property ByPriority: Boolean read FByPriority write FByPriority;
  end;

  TPSPSema = class(TPSPKernelObject)
  public
    Attr: Cardinal;
    Count, MaxCount, InitCount: Integer;
    Waiters: TPSPWaitQueue;
    constructor Create;
    destructor Destroy; override;
    class function IdType: Integer; override;
    procedure RemoveWaiter(T: TPSPThread); override;
    procedure AddWaiter(T: TPSPThread); override;
    function TryTake(T: TPSPThread): Boolean;
    procedure WakeWaiters;
  end;

  TPSPEventFlag = class(TPSPKernelObject)
  public
    Attr: Cardinal;
    Pattern, InitPattern: Cardinal;
    Waiters: TPSPWaitQueue;
    constructor Create;
    destructor Destroy; override;
    class function IdType: Integer; override;
    procedure RemoveWaiter(T: TPSPThread); override;
    procedure AddWaiter(T: TPSPThread); override;
    function Matches(Bits, Mode: Cardinal): Boolean;
    function TryTake(T: TPSPThread): Boolean;
    procedure WakeWaiters;
  end;

  TPSPInterruptHandler = record
    Handler, Arg, GP: Cardinal;
    Enabled: Boolean;
  end;

  TPSPPendingInterrupt = record
    Func, A0, A1, A2, A3, GP: Cardinal;
    OnReturn: TPSPGuestReturn;
  end;

  TPSPTimerKind = (tkWait, tkCustom);

  TPSPTimerEvent = reference to procedure;

  TPSPTimer = record
    At: Int64;
    Seq: Int64;
    Kind: TPSPTimerKind;
    Thread: TPSPThread;
    Owner: TObject;
    Event: TPSPTimerEvent;
  end;

  TPSPExitEvent = procedure(Status: Cardinal) of object;
  TPSPTimeSync = procedure of object;

  TPSPKernel = class
  private
    FCPU: TPSPCPU;
    FMemory: TPSPMemory;
    FHLE: TPSPHLE;
    FScheduler: TPSPScheduler;
    FObjects: TDictionary<Cardinal, TPSPKernelObject>;
    FNextUID: Cardinal;
    FReady: array[0..127] of TList<TPSPThread>;
    FCurrent: TPSPThread;
    FThreads: TList<TPSPThread>;
    FTimers: TList<TPSPTimer>;
    FTimerSeq: Int64;
    FThreadSeq: Int64;
    FRescheduleNeeded: Boolean;
    FIntFrames: TList<TPSPFrame>;
    FPendingInts: TQueue<TPSPPendingInterrupt>;
    FSubIntr: array[0..66, 0..31] of TPSPInterruptHandler;
    FTrapBase: Cardinal;
    FIntStack: Cardinal;
    FDispatchSuspended: Boolean;
    FIntrSuspendLevel: Integer;
    FUserPartition, FKernelPartition, FVolatilePartition: TPSPPartition;
    FBlocks: TDictionary<Cardinal, TPSPKernelObject>;
    FOnExit: TPSPExitEvent;
    FOnSyncTime: TPSPTimeSync;
    FExited: Boolean;
    FExitCallback: Cardinal;
    FCompiledSdkVersion, FCompilerVersion: Cardinal;
    FDebugOut: TStringBuilder;
    FIdle: Boolean;
    FTrace: Boolean;
    procedure T_(const Fmt: string; const Args: array of const);
    procedure ScheduleTimerEvent;
    procedure PushReady(T: TPSPThread; Front: Boolean);
    procedure RemoveReady(T: TPSPThread);
    function BestReady: TPSPThread;
    procedure SwitchTo(T: TPSPThread);
    procedure DispatchThread(T: TPSPThread);
    procedure StartCallbacks(T: TPSPThread);
    function RunNextCallback(T: TPSPThread; var Frame: TPSPFrame): Boolean;
    procedure FinishCallbackFrame(T: TPSPThread);
    procedure ReturnTrap;
    procedure ThreadExitTrap;
    procedure StartNextInterrupt;
    procedure EnterGuest(Func, SP, GP: Cardinal; const Args: array of Cardinal);
    procedure WakeEndWaiters(T: TPSPThread);
    procedure KillThreadFrames(T: TPSPThread);
    procedure RegisterAll;
    function WaitTimeoutValue(TimeoutPtr: Cardinal): Int64;
    procedure WriteRemaining(T: TPSPThread);
    // HLE handlers
    procedure hCreateThread;
    procedure hStartThread;
    procedure hExitThread;
    procedure hExitDeleteThread;
    procedure hDeleteThread;
    procedure hTerminateThread;
    procedure hTerminateDeleteThread;
    procedure hGetThreadId;
    procedure hGetThreadCurrentPriority;
    procedure hChangeThreadPriority;
    procedure hRotateThreadReadyQueue;
    procedure hReferThreadStatus;
    procedure hReferThreadRunStatus;
    procedure hGetThreadExitStatus;
    procedure hSleepThread;
    procedure hSleepThreadCB;
    procedure hWakeupThread;
    procedure hCancelWakeupThread;
    procedure hSuspendThread;
    procedure hResumeThread;
    procedure hWaitThreadEnd;
    procedure hWaitThreadEndCB;
    procedure hDelayThread;
    procedure hDelayThreadCB;
    procedure hDelaySysClockThread;
    procedure hDelaySysClockThreadCB;
    procedure hReleaseWaitThread;
    procedure hGetThreadStackFreeSize;
    procedure hCheckThreadStack;
    procedure hChangeCurrentThreadAttr;
    procedure hGetThreadmanIdType;
    procedure hGetThreadmanIdList;
    procedure hSuspendDispatchThread;
    procedure hResumeDispatchThread;
    procedure hReferSystemStatus;
    procedure hCreateCallback;
    procedure hDeleteCallback;
    procedure hNotifyCallback;
    procedure hCancelCallback;
    procedure hGetCallbackCount;
    procedure hCheckCallback;
    procedure hReferCallbackStatus;
    procedure hCreateSema;
    procedure hDeleteSema;
    procedure hSignalSema;
    procedure hWaitSema;
    procedure hWaitSemaCB;
    procedure hPollSema;
    procedure hCancelSema;
    procedure hReferSemaStatus;
    procedure hCreateEventFlag;
    procedure hDeleteEventFlag;
    procedure hSetEventFlag;
    procedure hClearEventFlag;
    procedure hWaitEventFlag;
    procedure hWaitEventFlagCB;
    procedure hPollEventFlag;
    procedure hCancelEventFlag;
    procedure hReferEventFlagStatus;
    procedure hGetSystemTime;
    procedure hGetSystemTimeWide;
    procedure hGetSystemTimeLow;
    procedure hUSec2SysClock;
    procedure hUSec2SysClockWide;
    procedure hSysClock2USec;
    procedure hSysClock2USecWide;
    procedure hCpuSuspendIntr;
    procedure hCpuResumeIntr;
    procedure hIsCpuIntrEnable;
    procedure hIsCpuIntrSuspended;
    procedure hRegisterSubIntrHandler;
    procedure hReleaseSubIntrHandler;
    procedure hEnableSubIntr;
    procedure hDisableSubIntr;
    procedure hSuspendSubIntr;
    procedure hResumeSubIntr;
    procedure hIsSubInterruptOccurred;
    procedure hRegisterUserSpaceIntrStack;
    procedure hAllocPartitionMemory;
    procedure hFreePartitionMemory;
    procedure hGetBlockHeadAddr;
    procedure hMaxFreeMemSize;
    procedure hTotalFreeMemSize;
    procedure hDevkitVersion;
    procedure hSetCompiledSdkVersion;
    procedure hGetCompiledSdkVersion;
    procedure hSetCompilerVersion;
    procedure hPrintf;
    procedure hExitGame;
    procedure hRegisterExitCallback;
    procedure hVolatileMemLock;
    procedure hVolatileMemTryLock;
    procedure hVolatileMemUnlock;
    procedure hReturnZero;
    procedure WaitCurrentKind(Kind: Integer; Obj: TPSPKernelObject; Id, TimeoutPtr: Cardinal; AllowCB: Boolean; Retry: TPSPWaitRetry);
    function SleepRetry(T: TPSPThread): Boolean;
    function DelayRetry(T: TPSPThread): Boolean;
    function ThreadEndRetry(T: TPSPThread): Boolean;
    function NoRetry(T: TPSPThread): Boolean;
    procedure DelayCurrent(Microseconds: Int64; AllowCB: Boolean);
    function SemaRetry(T: TPSPThread): Boolean;
    function EventFlagRetry(T: TPSPThread): Boolean;
    function CheckCallbacksNow: Boolean;
  public
    constructor Create(CPU: TPSPCPU; Memory: TPSPMemory; HLE: TPSPHLE; Scheduler: TPSPScheduler);
    destructor Destroy; override;
    procedure Reset;
    // Objects
    function AddObject(Obj: TPSPKernelObject): Cardinal;
    procedure DeleteObject(Obj: TPSPKernelObject);
    function GetObject(UID: Cardinal; Cls: TPSPKernelObjectClass): TPSPKernelObject;
    function ThreadById(UID: Cardinal): TPSPThread;
    // Threads
    function CreateThread(const Name: string; Entry: Cardinal; Priority: Integer; StackSize, Attr, GP: Cardinal; ModuleId: Cardinal = 0): TPSPThread;
    procedure StartThread(T: TPSPThread; ArgSize, ArgPtr: Cardinal; const ArgData: TBytes = nil);
    procedure ExitCurrent(Status: Cardinal);
    procedure TerminateThread(T: TPSPThread; Status: Cardinal);
    procedure DeleteThread(T: TPSPThread);
    procedure ChangePriority(T: TPSPThread; Priority: Integer);
    // Waits. BeginWait blocks the current thread; the result is set at EndWait.
    procedure BeginWait(Kind: Integer; Obj: TPSPKernelObject; Id, TimeoutPtr: Cardinal; AllowCB: Boolean;
      Retry: TPSPWaitRetry; Abort: TPSPWaitAbort = nil; const Tag: string = '');
    procedure EndWait(T: TPSPThread; Result: Cardinal);
    procedure WakeThread(T: TPSPThread);
    // A wait with an absolute deadline in ns (PSPNever for none).
    procedure SetWaitDeadline(T: TPSPThread; Deadline: Int64);
    procedure Reschedule;
    procedure RequestReschedule; inline;
    procedure AfterSyscall;
    function CanWait: Boolean;
    // Timers in guest ns. Returns a handle (sequence number) for CancelTimer.
    function AddTimer(At: Int64; Owner: TObject; const Event: TPSPTimerEvent): Int64;
    procedure CancelTimer(Handle: Int64);
    procedure CancelTimersOf(Owner: TObject);
    procedure OnTimerEvent;
    // Guest calls
    procedure CallGuest(Func: Cardinal; const Args: array of Cardinal; const OnReturn: TPSPGuestReturn; GP: Cardinal = 0);
    procedure QueueInterrupt(Func: Cardinal; const Args: array of Cardinal; GP: Cardinal; const OnReturn: TPSPGuestReturn = nil);
    procedure TriggerInterrupt(IntNo: Integer; SubNo: Integer = -1; Arg2: Cardinal = 0);
    procedure ProcessInterrupts;
    procedure Trap(Code: Cardinal);
    procedure NotifyCallback(CB: TPSPCallback; Arg: Cardinal);
    // Runs the current thread's pending callbacks now (CB variants of calls
    // that did not need to wait).
    function CheckCallbacks: Boolean;
    function InInterrupt: Boolean; inline;
    function HasRunnable: Boolean;
    function NowUs: Int64;
    // Memory
    function AllocUser(Size: Cardinal; High: Boolean; const Tag: string): Cardinal;
    function AllocKernel(Size: Cardinal; const Tag: string): Cardinal;
    function Partition(Id: Integer): TPSPPartition;
    procedure DebugWrite(const S: RawByteString);
    function TakeDebugOutput: string;
    function DescribeThreads: string;
    property Current: TPSPThread read FCurrent;
    property CPU: TPSPCPU read FCPU;
    property Memory: TPSPMemory read FMemory;
    property HLE: TPSPHLE read FHLE;
    property Scheduler: TPSPScheduler read FScheduler;
    property Threads: TList<TPSPThread> read FThreads;
    property TrapReturnAddress: Cardinal read FTrapBase;
    property UserPartition: TPSPPartition read FUserPartition;
    property KernelPartition: TPSPPartition read FKernelPartition;
    property OnExit: TPSPExitEvent read FOnExit write FOnExit;
    property OnSyncTime: TPSPTimeSync read FOnSyncTime write FOnSyncTime;
    property Exited: Boolean read FExited;
    property CompiledSdkVersion: Cardinal read FCompiledSdkVersion;
    property ExitCallback: Cardinal read FExitCallback;
    property Idle: Boolean read FIdle;
    property Trace: Boolean read FTrace write FTrace;
  end;

function PSPThreadName(T: TPSPThread): string;

implementation

{$I PSP.Kernel.Core.inc}
{$I PSP.Kernel.Threads.inc}
{$I PSP.Kernel.Sync.inc}
{$I PSP.Kernel.Misc.inc}

end.
