unit PSP.Console;

// The PSP: wires the CPU, kernel and services, boots a program and runs it
// one display field at a time on the master clock.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Generics.Collections, Core.Emulation.Types, Core.Storage,
  PSP.Types, PSP.Memory, PSP.Scheduler, PSP.CPU, PSP.HLE, PSP.Kernel, PSP.Media, PSP.IO, PSP.Loader,
  PSP.Display, PSP.Service, PSP.Audio;

type
  TPSPConsole = class
  private
    FMemory: TPSPMemory;
    FScheduler: TPSPScheduler;
    FCPU: TPSPCPU;
    FHLE: TPSPHLE;
    FKernel: TPSPKernel;
    FIO: TPSPIO;
    FLoader: TPSPLoader;
    FDisplay: TPSPDisplay;
    FSystem: TPSPSystem;
    FAudio: TPSPAudio;
    FStorage: IStorage;
    FProgram: TPSPProgram;
    FDiscStream: TStream;
    FDisc: TPSPDisc;
    FInput: TEmulatorInput;
    FAudioSamples: TArray<SmallInt>;
    FFrameNumber: UInt64;
    FRunDeadline: Int64;
    FLog: TStringList;
    FOnLog: TPSPLogEvent;
    FOutput: TStringBuilder;
    FMemstickRoot, FHostRoot, FFlashRoot: string;
    FPendingExec: string;
    FPendingExecArgs: TBytes;
    FBooted: Boolean;
    FStopAtFrame: Boolean;
    FExecuted: Int64;
    procedure ResetServices;
    procedure ResetMachine(KeepClock: Boolean);
    procedure Syscall(C: TPSPCPU; Code: Cardinal);
    procedure Break_(C: TPSPCPU; Code: Cardinal);
    procedure SyncTime;
    procedure HandleLog(const Text: string);
    procedure HandleOutput(const Text: RawByteString);
    procedure HandleLoadExec(const Path: string; ArgSize, ArgPtr: Cardinal);
    procedure DispatchEvent(E: TPSPEvent);
    procedure MountDisc;
    procedure Boot(const Executable: TBytes; const Path: string);
  public
    constructor Create(const ProgramData: TPSPProgram; const Storage: IStorage = nil; const HostRoot: string = '';
      const MemstickRoot: string = '');
    destructor Destroy; override;
    procedure Reset;
    procedure RunFrame(out Frame: TEmulatorFrame);
    // Runs until the guest time reaches At (ns) or the program exits.
    procedure RunUntil(At: Int64);
    function TakeOutput: string;
    function TakeLog: string;
    property Input: TEmulatorInput read FInput write FInput;
    property Memory: TPSPMemory read FMemory;
    property CPU: TPSPCPU read FCPU;
    property Kernel: TPSPKernel read FKernel;
    property HLE: TPSPHLE read FHLE;
    property IO: TPSPIO read FIO;
    property Loader: TPSPLoader read FLoader;
    property Display: TPSPDisplay read FDisplay;
    property System: TPSPSystem read FSystem;
    property Scheduler: TPSPScheduler read FScheduler;
    property AudioSamples: TArray<SmallInt> read FAudioSamples;
    property FrameNumber: UInt64 read FFrameNumber;
    // CPU cycles run (instructions plus HLE costs), for speed measurements.
    property Executed: Int64 read FExecuted;
    property OnLog: TPSPLogEvent read FOnLog write FOnLog;
  end;

implementation

uses
  System.Math, PSP.VFPU, PSP.GE, PSP.SysLibs, PSP.SAS, PSP.Atrac, PSP.MP3, PSP.AudioCodec, PSP.Mpeg, PSP.Psmf,
<<<<<<< HEAD
  PSP.Utility, PSP.Font, PSP.Misc, PSP.Jpeg;
=======
  PSP.Utility, PSP.Font, PSP.Misc, PSP.Settings;
>>>>>>> psp/util

constructor TPSPConsole.Create(const ProgramData: TPSPProgram; const Storage: IStorage; const HostRoot, MemstickRoot: string);
begin
  inherited Create;
  FProgram := ProgramData;
  FStorage := Storage;
  FHostRoot := HostRoot;
  FLog := TStringList.Create;
  FOutput := TStringBuilder.Create;
  FMemstickRoot := MemstickRoot;
  if (FMemstickRoot = '') and (Storage <> nil) then
    FMemstickRoot := TPath.Combine(Storage.SaveRoot, 'psp-memstick');
  if FMemstickRoot <> '' then
  begin
    ForceDirectories(TPath.Combine(FMemstickRoot, 'PSP' + PathDelim + 'SAVEDATA'));
    ForceDirectories(TPath.Combine(FMemstickRoot, 'PSP' + PathDelim + 'GAME'));
    FFlashRoot := TPath.Combine(ExtractFileDir(ExcludeTrailingPathDelimiter(FMemstickRoot)), 'psp-flash0');
  end;
  FMemory := TPSPMemory.Create;
  FScheduler := TPSPScheduler.Create;
  FCPU := TPSPCPU.Create(FMemory);
  FCPU.OnSyscall := Syscall;
  FCPU.OnBreak := Break_;
  FHLE := TPSPHLE.Create(FCPU, FMemory);
  FHLE.OnLog := HandleLog;
  FKernel := TPSPKernel.Create(FCPU, FMemory, FHLE, FScheduler);
  FKernel.OnSyncTime := SyncTime;
  FIO := TPSPIO.Create(FKernel);
  FIO.OnOutput := HandleOutput;
  FLoader := TPSPLoader.Create(FKernel, FIO);
  FLoader.OnLoadExec := HandleLoadExec;
  FDisplay := TPSPDisplay.Create(FKernel);
  FSystem := TPSPSystem.Create;
  FSystem.Memory := FMemory;
  FSystem.CPU := FCPU;
  FSystem.HLE := FHLE;
  FSystem.Kernel := FKernel;
  FSystem.Scheduler := FScheduler;
  FSystem.IO := FIO;
  FSystem.Loader := FLoader;
  FSystem.Display := FDisplay;
  FSystem.FlashRoot := FFlashRoot;
  FSystem.Services := TObjectList<TPSPService>.Create;
  for var Cls in PSPServiceClasses do
    FSystem.Services.Add(Cls.Create(FSystem));
  FAudio := TPSPAudio(FSystem.Find(TPSPAudio));
  MountDisc;
  Reset;
end;

destructor TPSPConsole.Destroy;
begin
  FSystem.Services.Free;
  FSystem.Free;
  FDisplay.Free;
  FLoader.Free;
  FIO.Free;
  FKernel.Free;
  FHLE.Free;
  FCPU.Free;
  FScheduler.Free;
  FMemory.Free;
  FDisc.Free;
  FDiscStream.Free;
  FOutput.Free;
  FLog.Free;
  inherited;
end;

procedure TPSPConsole.MountDisc;
begin
  if FProgram.MediaPath = '' then
    Exit;
  if FStorage <> nil then
    FDiscStream := FStorage.OpenRead(FProgram.MediaPath)
  else
    FDiscStream := TFileStream.Create(FProgram.MediaPath, fmOpenRead or fmShareDenyWrite);
  FDisc := TPSPDisc.Create(FDiscStream);
end;

procedure TPSPConsole.HandleLog(const Text: string);
begin
  if FLog.Count < 20000 then
    FLog.Add(Text);
  if Assigned(FOnLog) then
    FOnLog(Text);
end;

procedure TPSPConsole.HandleOutput(const Text: RawByteString);
begin
  FOutput.Append(string(Text));
end;

function TPSPConsole.TakeOutput: string;
begin
  Result := FOutput.ToString + FKernel.TakeDebugOutput;
  FOutput.Clear;
end;

function TPSPConsole.TakeLog: string;
begin
  Result := FLog.Text;
  FLog.Clear;
end;

procedure TPSPConsole.HandleLoadExec(const Path: string; ArgSize, ArgPtr: Cardinal);
begin
  FPendingExec := Path;
  SetLength(FPendingExecArgs, ArgSize);
  if ArgSize > 0 then
    FMemory.ReadBytes(ArgPtr, FPendingExecArgs[0], ArgSize);
  FCPU.Stop;
end;

procedure TPSPConsole.ResetServices;
begin
  for var S in FSystem.Services do
  begin
    S.Reset;
    S.Register;
  end;
end;

procedure TPSPConsole.ResetMachine(KeepClock: Boolean);
begin
  FMemory.Reset;
  FCPU.Reset;
  if not KeepClock then
    FScheduler.Reset;
  FKernel.Reset;
  FIO.Reset;
  FIO.Disc := FDisc;
  FIO.MemstickRoot := FMemstickRoot;
  FIO.FlashRoot := FFlashRoot;
  FIO.HostDirectory := FHostRoot;
  FIO.Register;
  FLoader.Reset;
  FLoader.Register;
  FDisplay.Reset;
  FDisplay.Register;
  ResetServices;
  FPendingExec := '';
  FBooted := False;
end;

procedure TPSPConsole.Reset;
begin
  ResetMachine(False);
  FFrameNumber := 0;
  var Path := FProgram.BootPath;
  if Path = '' then
  begin
    if FHostRoot <> '' then
      Path := 'host0:/' + 'program.prx'
    else
      Path := 'ms0:/PSP/GAME/APP/EBOOT.PBP';
  end;
  Boot(FProgram.Executable, Path);
end;

procedure TPSPConsole.Boot(const Executable: TBytes; const Path: string);
begin
  var M: TPSPModule;
  var Err := FLoader.Load(Executable, Path, M);
  if Err <> 0 then
    raise EPSPError.CreateFmt('PSP: the program cannot be loaded (%.8x)', [Err]);
  if M.Fake then
    raise EPSPError.Create('PSP: the program is a firmware module');
  var Dir := Path;
  var Slash := Dir.LastIndexOf('/');
  if Slash > 0 then
    Dir := Dir.Substring(0, Slash);
  FIO.Cwd := Dir;
  FLoader.StartMain(M, Path);
  FBooted := True;
end;

procedure TPSPConsole.SyncTime;
begin
  var N := FCPU.TakeCycles;
  if N > 0 then
  begin
    FScheduler.AddCycles(N);
    if FKernel.Current <> nil then
      Inc(FKernel.Current.RunClocks, N);
  end;
end;

procedure TPSPConsole.Syscall(C: TPSPCPU; Code: Cardinal);
begin
  SyncTime;
  if Code < PSPTrapCount then
    FKernel.Trap(Code)
  else if not FHLE.Call(Code) then
    raise EPSPGuestFault.CreateFmt('PSP: unknown syscall %x at %.8x', [Code, C.CurPC]);
  FKernel.AfterSyscall;
  // HLE costs are not in the CPU's budget: a loop of calls must still stop at the deadline.
  if (FScheduler.NextDue < FRunDeadline) or (FScheduler.Now >= FRunDeadline) then
    C.Stop;
end;

procedure TPSPConsole.Break_(C: TPSPCPU; Code: Cardinal);
begin
  HandleLog(Format('break %x at %.8x in %s', [Code, C.CurPC, PSPThreadName(FKernel.Current)]));
  // A break stops the thread on hardware (the debugger owns it); exit it.
  if FKernel.Current <> nil then
  begin
    FKernel.ExitCurrent(SCE_KERNEL_ERROR_ERROR);
    FKernel.Reschedule;
  end;
end;

procedure TPSPConsole.DispatchEvent(E: TPSPEvent);
begin
  case E of
    TPSPEvent.VBlank: FDisplay.OnEvent;
    TPSPEvent.Kernel: FKernel.OnTimerEvent;
  else
    for var S in FSystem.Services do
      S.OnEvent(E);
  end;
  FKernel.AfterSyscall;
end;

procedure TPSPConsole.RunUntil(At: Int64);
begin
  while True do
  begin
    // Events that fell due during the last run are handled before returning.
    var E: TPSPEvent;
    while FScheduler.TakeDue(E) do
      DispatchEvent(E);
    if FKernel.Exited or (FScheduler.Now >= At) or (FStopAtFrame and FDisplay.FrameDone) then
      Break;
    if FPendingExec <> '' then
    begin
      var Path := FPendingExec;
      FPendingExec := '';
      var Data: TBytes;
      if FIO.ReadAll(Path, Data) = 0 then
      begin
        // The new program starts on a freshly reset machine; time goes on.
        ResetMachine(True);
        Boot(Data, Path);
      end
      else
        HandleLog('loadexec: cannot read ' + Path);
      Continue;
    end;
    FKernel.ProcessInterrupts;
    var Deadline := Min(FScheduler.NextDue, At);
    if not FKernel.InInterrupt and (FScheduler.Now < FKernel.BusyUntil) then
      FScheduler.AdvanceTo(Min(Deadline, FKernel.BusyUntil))
    else if FKernel.HasRunnable then
    begin
      var Budget := FScheduler.CyclesUntil(Deadline);
      if Budget > 4000000 then
        Budget := 4000000;
      if Budget < 1 then
        Budget := 1;
      FRunDeadline := Deadline;
      var Used := FCPU.Run(Budget);
      Inc(FExecuted, Used);
      FScheduler.AddCycles(Used);
      if FKernel.Current <> nil then
        Inc(FKernel.Current.RunClocks, Used);
      FRunDeadline := PSPNever;
    end
    else
      FScheduler.AdvanceTo(Deadline);
  end;
<<<<<<< HEAD
  // HLE call costs can carry a run past At: events it overshot are still due.
  var Late: TPSPEvent;
  while not FKernel.Exited and FScheduler.TakeDue(Late) do
    DispatchEvent(Late);
=======
  // A slice can overshoot At by the cost of its last HLE call; events due by
  // then must not wait for a call whose target is already behind.
  var Due: TPSPEvent;
  while not FKernel.Exited and FScheduler.TakeDue(Due) do
    DispatchEvent(Due);
>>>>>>> psp/util
end;

procedure TPSPConsole.RunFrame(out Frame: TEmulatorFrame);
begin
  FDisplay.SetInput(FInput);
  FDisplay.FrameDone := False;
  FStopAtFrame := True;
  try
    RunUntil(FScheduler.Now + Int64(PSPFrameNs) * 2);
  finally
    FStopAtFrame := False;
  end;
  Inc(FFrameNumber);
  Frame := Default(TEmulatorFrame);
  FDisplay.Render(Frame);
  Frame.FrameNumber := FFrameNumber;
  Frame.FramesPerSecond := PSPFrameRate;
  FAudioSamples := FAudio.TakeSamples;
end;

end.
