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
  PSPWaitTlspl = 14;

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
    // A waiter left on its own (timeout, release, terminate): the ones behind
    // it may be satisfiable now.
    procedure WaiterGone; virtual;
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
    // When the timeout fires (ns); PSPNever for none.
    Deadline: Int64;
    // The end the caller asked for, for the time left written back.
    TimeoutEnd: Int64;
    TimeoutPtr: Cardinal;
    AllowCB: Boolean;
    Retry: TPSPWaitRetry;
    Abort: TPSPWaitAbort;
    Data: array[0..7] of Cardinal;
    HLETag: string;
    // The call returns an address: a wait that fails gives 0.
    FailAsZero: Boolean;
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
    // Callbacks run on the way out of a call that did not wait: its result stays.
    KeepResult: Boolean;
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
    // Stacks added by sceKernelExtendThreadStack, innermost last.
    ExtraStacks: TList<Cardinal>;
    ModuleId: Cardinal;
    CallbacksPending: Boolean;
    SuspendedWhileWaiting: Boolean;
    // The first wait after a start goes down a slower path.
    Fresh: Boolean;
    StackPartition: TPSPPartition;
    // The thread's block in each TLS pool, by the pool's slot.
    TlsSlots: array[0..15] of Cardinal;
    ReleaseCount, PreemptCount, IntrPreemptCount: Cardinal;
    Seq: Int64;
    // Runs once when the thread exits or is terminated.
    OnExit: TProc<TPSPThread>;
    // Deleted as soon as it exits by itself (a module's start thread).
    DeleteOnExit: Boolean;
    constructor Create;
    destructor Destroy; override;
    class function IdType: Integer; override;
    procedure RemoveWaiter(T: TPSPThread); override;
    procedure AddWaiter(T: TPSPThread); override;
    function IsWaiting: Boolean; inline;
    function IsDormant: Boolean; inline;
    function IsKernel: Boolean; inline;
    // Where a wait result goes: the thread's context, or the context a callback
    // frame will restore.
    procedure SetResult(Value: Cardinal);
    function HasPendingCallbacks: Boolean;
    function InCallback: Boolean;
    // A blocking CB wait inside a callback runs callbacks too, one level deep.
    function CallbackDepth: Integer;
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
    function Contains(T: TPSPThread): Boolean;
    procedure Clear;
    property ByPriority: Boolean read FByPriority write FByPriority;
  end;

  // An object with one wait queue, ordered by priority when Attr has $100.
  TPSPWaitObject = class(TPSPKernelObject)
  public
    Attr: Cardinal;
    Waiters: TPSPWaitQueue;
    constructor Create;
    destructor Destroy; override;
    procedure RemoveWaiter(T: TPSPThread); override;
    procedure AddWaiter(T: TPSPThread); override;
  end;

  TPSPSema = class(TPSPWaitObject)
  public
    Count, MaxCount, InitCount: Integer;
    class function IdType: Integer; override;
    function TryTake(T: TPSPThread): Boolean;
    procedure WakeWaiters;
    procedure WaiterGone; override;
  end;

  TPSPEventFlag = class(TPSPWaitObject)
  public
    Pattern, InitPattern: Cardinal;
    class function IdType: Integer; override;
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
    // Main interrupt handlers; the firmware's drivers hold some from the start.
    FIntrHandlers: array[0..67] of TPSPInterruptHandler;
    FTrapBase: Cardinal;
    FIntStack: Cardinal;
    FDispatchSuspended: Boolean;
    FIntrSuspendLevel: Integer;
    FUserPartition, FKernelPartition, FVolatilePartition, FStackPartition: TPSPPartition;
    FBlocks: TDictionary<Cardinal, TPSPKernelObject>;
    FOnExit: TPSPExitEvent;
    FOnSyncTime: TPSPTimeSync;
    FExited: Boolean;
    FExitCallback: Cardinal;
    FCompiledSdkVersion, FCompilerVersion: Cardinal;
    FSdkVersionSet: Boolean;
    FDebugOut: TStringBuilder;
    FIdle: Boolean;
    FTrace: Boolean;
    FVolatileLocked: Boolean;
    FVolatileWaiters: TList<TPSPThread>;
    FEventHandlers: TList<TPSPKernelObject>;
    FIdleThreadIds: array[0..1] of Cardinal;
    FTlsplCount: Integer;
    // How far into the next wait call its timeout is looked at (0: the usual).
    FWaitCheckNs: Int64;
    procedure T_(const Fmt: string; const Args: array of const);
    procedure ScheduleTimerEvent;
    procedure PushReady(T: TPSPThread; Front: Boolean);
    procedure RemoveReady(T: TPSPThread);
    function BestReady: TPSPThread;
    procedure SwitchTo(T: TPSPThread);
    procedure DispatchThread(T: TPSPThread);
    procedure StartCallbacks(T: TPSPThread; KeepResult: Boolean = False);
    function RunNextCallback(T: TPSPThread; var Frame: TPSPFrame): Boolean;
    procedure FinishCallbackFrame(T: TPSPThread);
    procedure ReturnTrap;
    procedure ThreadExitTrap;
    procedure StartNextInterrupt;
    procedure EnterGuest(Func, SP, GP: Cardinal; const Args: array of Cardinal);
    procedure WakeEndWaiters(T: TPSPThread);
    procedure KillThreadFrames(T: TPSPThread);
    procedure DropWaitTimer(T: TPSPThread);
    procedure RegisterAll;
    procedure RegisterKernelAliases;
    procedure hIoForKernel;
    function WaitDeadline(TimeoutPtr: Cardinal; out TimeoutEnd: Int64): Int64;
    procedure WriteRemaining(T: TPSPThread);
    procedure FreeThreadStacks(T: TPSPThread);
    procedure NotifyThreadEvent(Kind: Cardinal; T: TPSPThread);
    function ReadName(Ptr: Cardinal; out Name: string): Boolean;
    function ValidPriorityFor(P: Integer): Boolean;
    procedure YieldCurrent;
    function ValidUserAddress(Address: Cardinal): Boolean;
    function WriteInfo(Ptr: Cardinal; const Buf; StructSize: Cardinal): Boolean;
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
    procedure hExtendThreadStack;
    procedure hReferThreadProfiler;
    procedure hDonateWakeupThread;
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
    procedure WaitSemaCommon(AllowCB: Boolean);
    procedure WaitEventFlagCommon(AllowCB: Boolean);
    // Mutexes
    procedure hCreateMutex;
    procedure hDeleteMutex;
    procedure hLockMutex;
    procedure hLockMutexCB;
    procedure hTryLockMutex;
    procedure hUnlockMutex;
    procedure hCancelMutex;
    procedure hReferMutexStatus;
    procedure LockMutexCommon(AllowCB: Boolean);
    procedure hCreateLwMutex;
    procedure hDeleteLwMutex;
    procedure hLockLwMutex;
    procedure hLockLwMutexCB;
    procedure hTryLockLwMutex;
    procedure hTryLockLwMutex600;
    procedure hUnlockLwMutex;
    procedure hReferLwMutexStatus;
    procedure hReferLwMutexStatusByID;
    procedure LockLwMutexCommon(AllowCB, IsTry: Boolean; TryError: Cardinal);
    procedure ReferLwMutex(Obj: TPSPKernelObject; InfoPtr: Cardinal);
    procedure ReleaseMutexesOf(T: TPSPThread);
    // Message boxes and pipes
    procedure hCreateMbx;
    procedure hDeleteMbx;
    procedure hSendMbx;
    procedure hReceiveMbx;
    procedure hReceiveMbxCB;
    procedure hPollMbx;
    procedure hCancelReceiveMbx;
    procedure hReferMbxStatus;
    procedure ReceiveMbxCommon(AllowCB: Boolean);
    procedure hCreateMsgPipe;
    procedure hDeleteMsgPipe;
    procedure hSendMsgPipe;
    procedure hSendMsgPipeCB;
    procedure hTrySendMsgPipe;
    procedure hReceiveMsgPipe;
    procedure hReceiveMsgPipeCB;
    procedure hTryReceiveMsgPipe;
    procedure hCancelMsgPipe;
    procedure hReferMsgPipeStatus;
    function UserPartitionCheck(PartId: Integer): Cardinal;
    procedure SendMsgPipeCommon(Mode: Integer);
    procedure ReceiveMsgPipeCommon(Mode: Integer);
    // Pools
    procedure hCreateVpl;
    procedure hDeleteVpl;
    procedure hAllocateVpl;
    procedure hAllocateVplCB;
    procedure hTryAllocateVpl;
    procedure hFreeVpl;
    procedure hCancelVpl;
    procedure hReferVplStatus;
    function PoolPartition(PartId: Integer): TPSPPartition;
    function TlsplOf(Id: Cardinal): TPSPKernelObject;
    function TlsTake(Obj: TPSPKernelObject; out Addr: Cardinal): Boolean;
    procedure ReleaseTlsOf(T: TPSPThread);
    procedure AllocateVplCommon(Mode: Integer);
    procedure hCreateFpl;
    procedure hDeleteFpl;
    procedure hAllocateFpl;
    procedure hAllocateFplCB;
    procedure hTryAllocateFpl;
    procedure hFreeFpl;
    procedure hCancelFpl;
    procedure hReferFplStatus;
    procedure AllocateFplCommon(Mode: Integer);
    procedure hCreateTlspl;
    procedure hDeleteTlspl;
    procedure hGetTlsAddr;
    procedure hAllocateTlspl;
    procedure hFreeTlspl;
    procedure hReferTlsplStatus;
    // Alarms, virtual timers, thread event handlers
    procedure hSetAlarm;
    procedure hSetSysClockAlarm;
    procedure hCancelAlarm;
    procedure hReferAlarmStatus;
    procedure SetAlarmCommon(Us: UInt64);
    procedure ArmAlarm(Obj: TPSPKernelObject; FireAt: Int64);
    procedure ArmVTimer(Obj: TPSPKernelObject);
    function VTimerOf(Id: Cardinal): TPSPKernelObject;
    procedure SetVTimerTimeTo(Obj: TPSPKernelObject; Value: UInt64);
    procedure SetVTimerHandlerCommon(Schedule: UInt64; Handler, Common: Cardinal);
    procedure hCreateVTimer;
    procedure hDeleteVTimer;
    procedure hGetVTimerBase;
    procedure hGetVTimerBaseWide;
    procedure hGetVTimerTime;
    procedure hGetVTimerTimeWide;
    procedure hSetVTimerTime;
    procedure hSetVTimerTimeWide;
    procedure hStartVTimer;
    procedure hStopVTimer;
    procedure hSetVTimerHandler;
    procedure hSetVTimerHandlerWide;
    procedure hCancelVTimerHandler;
    procedure hReferVTimerStatus;
    procedure hRegisterThreadEventHandler;
    procedure hReleaseThreadEventHandler;
    procedure hReferThreadEventHandlerStatus;
    // Time
    procedure hGetSystemTime;
    procedure hGetSystemTimeWide;
    procedure hGetSystemTimeLow;
    procedure hUSec2SysClock;
    procedure hUSec2SysClockWide;
    procedure hSysClock2USec;
    procedure hSysClock2USecWide;
    // Interrupts
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
    procedure hQueryIntrHandlerInfo;
    function IntrHandlerCheck(I: Integer): Cardinal;
    procedure hEnableIntr;
    procedure hDisableIntr;
    procedure hRegisterIntrHandler;
    procedure hReleaseIntrHandler;
    // System memory
    procedure hAllocPartitionMemory;
    procedure hFreePartitionMemory;
    procedure hGetBlockHeadAddr;
    procedure hMaxFreeMemSize;
    procedure hTotalFreeMemSize;
    procedure hTotalMemSize;
    procedure hPartitionTotalFreeMemSize;
    procedure hQueryMemoryInfo;
    procedure hAllocMemoryBlock;
    procedure hFreeMemoryBlock;
    procedure hGetMemoryBlockPtr;
    procedure hDevkitVersion;
    procedure hSetCompiledSdkVersion;
    procedure hGetCompiledSdkVersion;
    procedure hSetCompilerVersion;
    procedure hPrintf;
    procedure hCreateHeap;
    procedure hDeleteHeap;
    procedure hAllocHeapMemory;
    procedure hAllocHeapMemoryWithOption;
    procedure hFreeHeapMemory;
    procedure hExitGame;
    procedure hRegisterExitCallback;
    procedure hVolatileMemLock;
    procedure hVolatileMemTryLock;
    procedure hVolatileMemUnlock;
    procedure hReturnZero;
    procedure hMemcpy;
    procedure hMemset;
    function VolatileRetry(T: TPSPThread): Boolean;
    function SleepRetry(T: TPSPThread): Boolean;
    function DelayRetry(T: TPSPThread): Boolean;
    function ThreadEndRetry(T: TPSPThread): Boolean;
    procedure DelayCurrent(Microseconds: Int64; AllowCB: Boolean);
    function SemaRetry(T: TPSPThread): Boolean;
    function EventFlagRetry(T: TPSPThread): Boolean;
    procedure EventFlagAbort(T: TPSPThread);
    function CheckCallbacksNow(KeepResult: Boolean = True): Boolean;
    function AllocPartitionBlock(PartId: Integer; const Name: string; Kind: Integer; Size, Addr: Cardinal; out Err: Cardinal): Cardinal;
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
    // The same with wait data set before callbacks can run. Returns False when
    // the wait timed out at once (the result is set then).
    function BeginWaitData(Kind: Integer; Obj: TPSPKernelObject; Id, TimeoutPtr: Cardinal; AllowCB: Boolean;
      Retry: TPSPWaitRetry; const Data: array of Cardinal; Abort: TPSPWaitAbort = nil; const Tag: string = ''): Boolean;
    procedure EndWait(T: TPSPThread; Result: Cardinal);
    procedure WakeThread(T: TPSPThread);
    // A wait with an absolute deadline in ns (PSPNever for none).
    procedure SetWaitDeadline(T: TPSPThread; Deadline: Int64);
    // Sets a wait's data on the thread, or on the wait its callback frame keeps.
    procedure SetWaitData(T: TPSPThread; Index: Integer; Value: Cardinal);
    procedure Reschedule;
    procedure RequestReschedule; inline;
    procedure AfterSyscall;
    function CanWait: Boolean;
    // Sets the error and returns True when the current context may not block.
    function RefuseWait: Boolean;
    // Guest time the kernel spends in a call (ns), on the current CPU clock.
    procedure Spend(Ns: Int64);
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
{$I PSP.Kernel.Mutex.inc}
{$I PSP.Kernel.Messages.inc}
{$I PSP.Kernel.Pools.inc}
{$I PSP.Kernel.Timers.inc}
{$I PSP.Kernel.Misc.inc}

end.
