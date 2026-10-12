unit SG1000.Emulation;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, Core.Storage, Core.Emulation,
  Core.InputConfig, Core.Snapshots, SG1000.Console;

type
  TSGWorker = class(TThread)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FSnapshots: TSnapshotQueue;
    FStorage: IStorage;
    FData: TBytes;
    FSC3000, FPAL: Boolean;
    FInput: TEmulatorInput;
    FKeys: TSGHostKeys;
    FPause, FReset, FAudioEnabled, FAvailable: Boolean;
    FVolume: Single;
    FFrame: TEmulatorFrame;
    FError, FAudioError: string;
    procedure Publish(Console: TSGConsole);
  protected
    procedure Execute; override;
  public
    SnapshotDirectory: string;
    InputPorts: TCoreInputPorts;
    constructor Create(const Data: TBytes; SC3000, PAL: Boolean; const Storage: IStorage);
    destructor Destroy; override;
    procedure Configure(const Input: TEmulatorInput; const Keys: TSGHostKeys; Paused, AudioEnabled: Boolean; Volume: Single);
    procedure RequestReset;
    procedure StopAndSave;
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function TakeAudioError: string;
  end;

implementation

uses
  System.Diagnostics, System.Math, Core.SavePaths, Core.PerformanceHints,
  Core.RomFormat, PCM.Audio;

constructor TSGWorker.Create(const Data: TBytes; SC3000, PAL: Boolean; const Storage: IStorage);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FSnapshots := TSnapshotQueue.Create;
  FData := Copy(Data);
  FStorage := Storage;
  FSC3000 := SC3000;
  FPAL := PAL;
end;

destructor TSGWorker.Destroy;
begin
  Terminate;
  if FWake <> nil then
    FWake.SetEvent;

  // Join before freeing synchronization objects used by Execute.
  inherited;
  FSnapshots.Free;
  FWake.Free;
  FLock.Free;
end;

procedure TSGWorker.Configure(const Input: TEmulatorInput; const Keys: TSGHostKeys; Paused, AudioEnabled: Boolean; Volume: Single);
begin
  var Wake: Boolean;
  FLock.Acquire;
  try
    Wake := FPause <> Paused;
    FInput := Input;
    FKeys := Keys;
    FPause := Paused;
    FAudioEnabled := AudioEnabled;
    FVolume := EnsureRange(Volume, 0.0, 1.0);
  finally
    FLock.Release;
  end;
  if Wake then
    FWake.SetEvent;
end;

procedure TSGWorker.RequestReset;
begin
  FLock.Acquire;
  try
    FReset := True;
    FAvailable := False;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TSGWorker.StopAndSave;
begin
  Terminate;
  FWake.SetEvent;
  if Suspended then
    Start;
  WaitFor;
end;

procedure TSGWorker.SaveSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, False);
end;

procedure TSGWorker.LoadSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, True);
end;

function TSGWorker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  FLock.Acquire;
  try
    Result := FAvailable;
    if Result then
    begin
      Frame := FFrame;
      FAvailable := False;
    end;
  finally
    FLock.Release;
  end;
end;

function TSGWorker.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

function TSGWorker.TakeAudioError: string;
begin
  FLock.Acquire;
  try
    Result := FAudioError;
    FAudioError := '';
  finally
    FLock.Release;
  end;
end;

procedure TSGWorker.Publish(Console: TSGConsole);
begin
  var Frame: TEmulatorFrame;
  Frame.Width := 256;
  Frame.Height := 192;
  Frame.FrameNumber := Console.FrameNumber;
  Frame.FramesPerSecond := Console.FramesPerSecond;
  Frame.Pixels := Copy(Console.VDP.Pixels);
  FLock.Acquire;
  try
    FFrame := Frame;
    FAvailable := True;
  finally
    FLock.Release;
  end;
end;

procedure TSGWorker.Execute;
var
  Console: TSGConsole;
  Audio: TPCMAudio;
  Hints: TEmulationPerformanceHints;
  Input: TEmulatorInput;
  Keys: TSGHostKeys;
  Samples: TArray<SmallInt>;
  Paused, ResetRequested, Enabled, WasEnabled, WasPaused, AudioFailed: Boolean;
  Volume: Single;
  Deadline: Double;
  CoreId: string;
begin
  Console := nil;
  Audio := nil;
  Hints := nil;
  if FSC3000 then
    CoreId := ROM_CORE_ID_SC3000
  else
    CoreId := ROM_CORE_ID_SG1000;
  try
    try
      Console := TSGConsole.Create(FData, FSC3000, FPAL);
      Hints := TEmulationPerformanceHints.Create(Round(1000000000.0 / Console.FramesPerSecond), CoreId);
      var Format: TPCMAudioFormat;
      Format.SampleRate := 44100;
      Format.Channels := 2;
      Format.BlockFrames := 2048;
      Format.BlockCount := 4;
      Deadline := TStopwatch.GetTimeStamp;
      WasEnabled := False;
      WasPaused := False;
      AudioFailed := False;
      while not Terminated do
      begin
        FSnapshots.Process(
          procedure(const Name: string; Loading: Boolean)
          begin
            Hints.Pause;
            var Path := ResolveSnapshotPath(SnapshotDirectory, Name);
            var Transfer: TStateTransfer :=
              procedure(State: TStateArchive)
              begin
                Console.SerializeState(State);
              end;
            if Loading then
            begin
              LoadCoreSnapshot(Path, CoreId, FData, Transfer, FStorage);
              if Audio <> nil then
                Audio.Clear;
              Publish(Console);
            end
            else
            begin
              SaveCoreSnapshot(Path, CoreId, FData, Transfer, FStorage);
              SaveSnapshotPreview(Path, 256, 192, 256, @Console.VDP.Pixels[0], FStorage);
            end;
            Deadline := TStopwatch.GetTimeStamp;
          end);
        FLock.Acquire;
        try
          Input := FInput;
          Keys := FKeys;
          Paused := FPause;
          Enabled := FAudioEnabled;
          Volume := FVolume;
          ResetRequested := FReset;
          FReset := False;
        finally
          FLock.Release;
        end;
        if ResetRequested then
        begin
          Hints.Pause;
          Console.Reset;
          if Audio <> nil then
            Audio.Clear;
          Deadline := TStopwatch.GetTimeStamp;
        end;
        if Paused then
        begin
          Hints.Pause;
          if not WasPaused and (Audio <> nil) then
            Audio.Clear;
          WasPaused := True;
          FWake.WaitFor(10);
          Deadline := TStopwatch.GetTimeStamp;
          Continue;
        end;

        WasPaused := False;
        if InputPorts.Devices[0] = 'none' then
          Input.Buttons := [];
        if InputPorts.Devices[1] = 'none' then
          Input.Buttons2 := [];
        Hints.BeginWork;
        Console.SetInput(Input, Keys);
        Console.RunFrame;

        if Terminated then
          Break;

        Publish(Console);
        if Enabled and not AudioFailed then
        try
          if Audio = nil then
            Audio := TPCMAudio.Create(Format);
          SetLength(Samples, Console.SampleFrames * 2);
          for var I := 0 to High(Samples) do
            Samples[I] := Round(Console.Samples[I] * Volume);
          Audio.Submit(Samples, Console.SampleFrames);

          if Audio.Error <> '' then
            raise EInOutError.Create(Audio.Error);
        except
          on E: Exception do
          begin
            FLock.Acquire;
            try
              FAudioError := CoreId + ' audio: ' + E.Message;
            finally
              FLock.Release;
            end;
            FreeAndNil(Audio);
            AudioFailed := True;
          end;
        end
        else if not Enabled then
        begin
          if WasEnabled and (Audio <> nil) then
            Audio.Clear;
          AudioFailed := False;
        end;
        WasEnabled := Enabled;
        Hints.EndWork;
        Deadline := Deadline + TStopwatch.Frequency / Console.FramesPerSecond;
        if TStopwatch.GetTimeStamp - Deadline > TStopwatch.Frequency div 10 then
          Deadline := TStopwatch.GetTimeStamp;
        Hints.WaitUntil(FWake, Round(Deadline));
      end;
    except
      on E: Exception do
      begin
        FLock.Acquire;
        try
          FError := CoreId + ': ' + E.Message;
        finally
          FLock.Release;
        end;
      end;
    end;
  finally
    Hints.Free;
    Audio.Free;
    Console.Free;
  end;
end;

end.

