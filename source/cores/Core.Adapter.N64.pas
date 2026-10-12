unit Core.Adapter.N64;
{$Q+}{$R+}

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, System.SyncObjs,
  Core.Storage, Core.Emulation, Core.Snapshots, N64.Console;

type
  TN64KeyMap = array[0..3, TEmulatorButton] of UInt32;

  TN64Config = class(TEmulatorConfigBase)
  private
    FKeys: TN64KeyMap;
    FLKeys: array[0..3] of UInt32;
    FConnected: array[0..3] of Boolean;
    FSaveType: TN64SaveType;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const FileName: string; const Storage: IStorage);
    property Keys: TN64KeyMap read FKeys;
    property SaveType: TN64SaveType read FSaveType write FSaveType;
    function LKey(Port: Integer): UInt32;
    function Connected(Port: Integer): Boolean;
  end;

  // Frontends with analog axes may supply the full N64 controller directly.
  IN64ControllerInput = interface
    ['{AC64141A-8A13-4833-A0A7-19386373C596}']
    procedure SetN64Controller(Port: Integer; const Pad: TN64Pad);
  end;

  TN64Worker = class(TThread)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FSnapshots: TSnapshotQueue;
    FStorage: IStorage;
    FData, FPendingBattery: TBytes;
    FSavePath, FSnapshotDirectory, FError, FAudioError: string;
    FInputs: TN64Pads;
    FPause, FReset, FAudioEnabled, FAvailable: Boolean;
    FVolume: Single;
    FSaveType: TN64SaveType;
    FFrame: TEmulatorFrame;
    procedure SaveBattery(Console: TN64Console);
  protected
    procedure Execute; override;
  public
    constructor Create(const Data: TBytes; const Storage: IStorage; const SavePath, SnapshotDirectory: string);
    destructor Destroy; override;
    procedure Configure(const Inputs: TN64Pads; Paused: Boolean; const Config: IEmulatorConfig);
    procedure RequestReset;
    procedure StopAndSave;
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError(Audio: Boolean): string;
    procedure Snapshot(const Name: string; Loading: Boolean);
  end;

  TN64CoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationSnapshotLocation, IEmulationAudioDiagnostics, IN64ControllerInput)
  private
    FStorage: IStorage;
    FConfig: IEmulatorConfig;
    FWorker: TN64Worker;
    FData: TBytes;
    FPendingSaveData: TBytes;
    FKeys: TN64KeyMap;
    FKeyboard, FGamepad: array[0..3] of TEmulatorButtons;
    FLPressed: array[0..3] of Boolean;
    FAnalog: TN64Pads;
    FPaused: Boolean;
    FSavePath, FSnapshotDirectory, FError: string;
    procedure Configure;
  public
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string);
    destructor Destroy; override;
    function GetName: string;
    function GetSupportsSnapshots: Boolean;
    function GetUsesSuborKeyboard: Boolean;
    function GetHasCoinAcceptor: Boolean;
    procedure InsertCoin1;
    procedure InsertCoin2;
    procedure Start;
    procedure Stop;
    procedure Pause;
    procedure Resume;
    procedure Reset;
    procedure ClearInput;
    procedure SetKeyState(Code: UInt32; Pressed: Boolean);
    procedure SetGamepadInput(const Input: TEmulatorInput);
    procedure SetN64Controller(Port: Integer; const Pad: TN64Pad);
    function GetInputState: TEmulatorInput;
    function GetSnapshotDirectory: string;
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function TakeAudioError: string;
    function GetConfig: IEmulatorConfig;
    function IsPaused: Boolean;
  end;

implementation

uses
  System.Math, System.Diagnostics, System.UITypes, Core.RomFormat,
  Core.SavePaths, PCM.Audio;

const
  KeyNames: array[TEmulatorButton] of string =
    ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Z', 'Start', 'CDown', 'CLeft', 'CUp', 'CRight', 'R');
  DefaultKeys: array[TEmulatorButton] of UInt32 =
    (vkUp, vkDown, vkLeft, vkRight, vkX, vkZ, vkSpace, vkReturn, vkS, vkA, vkW, vkD, vkE);

constructor TN64Config.Create(const FileName: string; const Storage: IStorage);
begin
  inherited Create(FileName, Storage);
  for var P := 0 to 3 do
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      if P = 0 then
        FKeys[P, B] := DefaultKeys[B]
      else
        FKeys[P, B] := 0;
  FLKeys[0] := vkQ;
  for var P := 0 to 3 do
    FConnected[P] := True;
end;

function TN64Config.LKey(Port: Integer): UInt32;
begin
  Result := FLKeys[Port]
end;

function TN64Config.Connected(Port: Integer): Boolean;
begin
  Result := FConnected[Port]
end;

procedure TN64Config.LoadCoreSettings(Ini: TCustomIniFile);
begin
  var Value := Ini.ReadInteger('Cartridge', 'SaveType', Ord(TN64SaveType.Auto));
  if (Value < Ord(Low(TN64SaveType))) or (Value > Ord(High(TN64SaveType))) then
    Value := 0;
  FSaveType := TN64SaveType(Value);
  for var P := 0 to 3 do
  begin
    var Section := 'Keys';
    if P > 0 then
      Section := Section + IntToStr(P + 1);
    FLKeys[P] := ReadEmulatorKey(Ini, Section, 'L', FLKeys[P]);
    FConnected[P] := not SameText(Ini.ReadString('Ports', 'Port' + IntToStr(P + 1), 'pad'), 'none');
  end;
  for var P := 0 to 3 do
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    begin
      var Section := 'Keys';
      if P > 0 then
        Section := Section + IntToStr(P + 1);
      FKeys[P, B] := ReadEmulatorKey(Ini, Section, KeyNames[B], FKeys[P, B]);
    end;
end;

procedure TN64Config.SaveCoreSettings(Ini: TCustomIniFile);
begin
  Ini.WriteInteger('Cartridge', 'SaveType', Ord(FSaveType));
  for var P := 0 to 3 do
  begin
    var Section := 'Keys';
    if P > 0 then
      Section := Section + IntToStr(P + 1);
    Ini.WriteInteger(Section, 'L', FLKeys[P]);
  end;
  for var P := 0 to 3 do
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    begin
      var Section := 'Keys';
      if P > 0 then
        Section := Section + IntToStr(P + 1);
      Ini.WriteInteger(Section, KeyNames[B], FKeys[P, B]);
    end;
end;

constructor TN64Worker.Create(const Data: TBytes; const Storage: IStorage; const SavePath, SnapshotDirectory: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FData := Copy(Data);
  FStorage := Storage;
  FSavePath := SavePath;
  FSnapshotDirectory := SnapshotDirectory;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FSnapshots := TSnapshotQueue.Create;
end;

destructor TN64Worker.Destroy;
begin
  Terminate;
  FWake.SetEvent;
  inherited Destroy;
  FSnapshots.Free;
  FWake.Free;
  FLock.Free;
end;

procedure TN64Worker.Configure(const Inputs: TN64Pads; Paused: Boolean; const Config: IEmulatorConfig);
begin
  var WakeNeeded: Boolean;
  FLock.Acquire;
  try
    WakeNeeded := FPause <> Paused;
    FInputs := Inputs;
    FPause := Paused;
    FAudioEnabled := Config.AudioEnabled;
    FVolume := Config.AudioVolume;
    FSaveType := (Config as TN64Config).SaveType;
  finally
    FLock.Release
  end;
  if WakeNeeded then
    FWake.SetEvent;
end;

procedure TN64Worker.RequestReset;
begin
  FLock.Acquire;
  try
    FReset := True;
    FAvailable := False
  finally
    FLock.Release
  end;
  FWake.SetEvent;
end;

function TN64Worker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  FLock.Acquire;
  try
    Result := FAvailable;
    if Result then
    begin
      Frame := FFrame;
      FAvailable := False
    end
  finally
    FLock.Release
  end;
end;

function TN64Worker.TakeError(Audio: Boolean): string;
begin
  FLock.Acquire;
  try
    if Audio then
    begin
      Result := FAudioError;
      FAudioError := ''
    end
    else
    begin
      Result := FError;
      FError := ''
    end
  finally
    FLock.Release
  end;
end;

procedure TN64Worker.Snapshot(const Name: string; Loading: Boolean);
begin
  FSnapshots.Execute(Self, Name, Loading)
end;

procedure TN64Worker.SaveBattery(Console: TN64Console);
begin
  if Console.SaveDirty then
    FPendingBattery := Console.SaveBattery;
  if Length(FPendingBattery) > 0 then
  begin
    FStorage.WriteBytes(FSavePath, FPendingBattery);
    FPendingBattery := nil
  end;
end;

procedure TN64Worker.StopAndSave;
begin
  Terminate;
  FWake.SetEvent;
  if Suspended then
    Start;
  WaitFor;
  if Length(FPendingBattery) > 0 then
  begin
    FStorage.WriteBytes(FSavePath, FPendingBattery);
    FPendingBattery := nil
  end;
end;

procedure TN64Worker.Execute;
begin
  var Console: TN64Console := nil;
  var Audio: TPCMAudio := nil;
  var AudioFailed := False;
  var WasPaused := False;
  var WasEnabled := False;
  var Rate: TEmulationFrameRate;
  var OldMask := SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  try
    try
      Console := TN64Console.Create(FData);
      FLock.Acquire;
      try
        Console.ConfigureSaveType(FSaveType)
      finally
        FLock.Release
      end;
      Rate.Reset(Console.FrameNumber, TStopwatch.GetTimeStamp);
      if FStorage.Exists(FSavePath) then
        Console.LoadBattery(FStorage.ReadBytes(FSavePath));
      var Deadline: Double := TStopwatch.GetTimeStamp;
      while not Terminated do
      begin
        FSnapshots.Process(
          procedure(const Name: string; Loading: Boolean)
          begin
            var Path := ResolveSnapshotPath(FSnapshotDirectory, Name);
            if Loading then
            begin
              var Candidate := TN64Console.Create(FData);
              try
                LoadCoreSnapshot(Path, 'N64', FData,
                  procedure(State: TStateArchive)
                  begin
                    Candidate.SerializeState(State)
                  end, FStorage);
                Console.Free;
                Console := Candidate;
                Candidate := nil;
              finally
                Candidate.Free
              end;
              if Audio <> nil then
                Audio.Clear;
              FLock.Acquire;
              try
                FFrame := Console.GetFrame;
                FAvailable := True
              finally
                FLock.Release
              end;
            end
            else
            begin
              SaveCoreSnapshot(Path, 'N64', FData,
                procedure(State: TStateArchive)
                begin
                  Console.SerializeState(State)
                end, FStorage);
              var Preview := Console.GetFrame;
              SaveSnapshotPreview(Path, Preview.Width, Preview.Height, Preview.Width, @Preview.Pixels[0], FStorage);
            end;
            Deadline := TStopwatch.GetTimeStamp;
            Rate.Reset(Console.FrameNumber, TStopwatch.GetTimeStamp);
          end);
        var Inputs: TN64Pads;
        var Paused, Enabled, ResetRequested: Boolean;
        var Volume: Single;
        FLock.Acquire;
        try
          Inputs := FInputs;
          Paused := FPause;
          Enabled := FAudioEnabled;
          Volume := FVolume;
          ResetRequested := FReset;
          FReset := False;
        finally
          FLock.Release
        end;
        if ResetRequested then
        begin
          SaveBattery(Console);
          Console.Reset;
          if Audio <> nil then
            Audio.Clear;
          Deadline := TStopwatch.GetTimeStamp;
          Rate.Reset(Console.FrameNumber, TStopwatch.GetTimeStamp)
        end;
        if Paused then
        begin
          if not WasPaused then
          begin
            SaveBattery(Console);
            if Audio <> nil then
              Audio.Clear
          end;
          Rate.Reset(Console.FrameNumber, TStopwatch.GetTimeStamp);
          WasPaused := True;
          FWake.WaitFor(10);
          Deadline := TStopwatch.GetTimeStamp;
          Continue;
        end;
        WasPaused := False;
        Console.SetInputs(Inputs);
        var StartFrame := Console.FrameNumber;
        // Stop/pause latency is bounded even when the ROM busy-waits forever.
        while not Terminated and (Console.FrameNumber = StartFrame) do
        begin
          Console.RunInstructions(4096);
          FLock.Acquire;
          try
            if FPause or FReset then
              Break
          finally
            FLock.Release
          end;
        end;
        if Terminated then
          Break;
        var Frame := Console.GetFrame;
        Frame.FramesPerSecond := Rate.Update(Console.FrameNumber, TStopwatch.GetTimeStamp, TStopwatch.Frequency);
        FLock.Acquire;
        try
          FFrame := Frame;
          FAvailable := True
        finally
          FLock.Release
        end;
        var Samples := Console.TakeSamples;
        if Enabled and not AudioFailed and (Length(Samples) > 0) then
        try
          if Audio = nil then
          begin
            var Format: TPCMAudioFormat;
            Format.SampleRate := 48000;
            Format.Channels := 2;
            Format.BlockFrames := 4096;
            Format.BlockCount := 4;
            Audio := TPCMAudio.Create(Format);
          end;
          for var I := 0 to High(Samples) do
            Samples[I] := Round(Samples[I] * Volume);
          Audio.Submit(Samples, Length(Samples) div 2);
          if Audio.Error <> '' then
            raise EInOutError.Create(Audio.Error);
        except
          on E: Exception do
          begin
            FLock.Acquire;
            try
              FAudioError := E.Message
            finally
              FLock.Release
            end;
            AudioFailed := True
          end;
        end;
        if WasEnabled and not Enabled and (Audio <> nil) then
          Audio.Clear;
        WasEnabled := Enabled;
        Deadline := Deadline + TStopwatch.Frequency / Console.FramesPerSecond;
        var Remaining := (Deadline - TStopwatch.GetTimeStamp) * 1000 / TStopwatch.Frequency;
        if Remaining > 0 then
          FWake.WaitFor(Min(100, Ceil(Remaining)))
        else
          Deadline := TStopwatch.GetTimeStamp;
      end;
    except
      on E: Exception do
      begin
        FLock.Acquire;
        try
          FError := E.ClassName + ': ' + E.Message
        finally
          FLock.Release
        end
      end;
    end;
    if Console <> nil then
    try
      SaveBattery(Console)
    except
      on E: Exception do
      begin
        FLock.Acquire;
        try
          FError := FError + #13#10 + 'N64 save: ' + E.Message
        finally
          FLock.Release
        end
      end
    end;
  finally
    Audio.Free;
    Console.Free;
    SetExceptionMask(OldMask)
  end;
end;

constructor TN64CoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string);
begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  FData := ReadRomData(Stream);
  var Format := DetectRom(FData);
  if Format.System = TRomSystem.N64 then
    FData := NormalizeRom(FData, Format);
  var Check := TN64Console.Create(FData);
  Check.Free;
  var Config := TN64Config.Create(FStorage.ConfigFile('n64'), FStorage);
  FConfig := Config;
  Config.Load;
  FKeys := Config.Keys;
  var Identity := SnapshotIdentity(FData);
  FSavePath := FStorage.GameSave('n64', RomName, Identity);
  FSnapshotDirectory := FStorage.GameSnapshots('n64', RomName, Identity);
end;

destructor TN64CoreAdapter.Destroy;
begin
  Stop;
  inherited
end;

procedure TN64CoreAdapter.Configure;
const
  Masks: array[TEmulatorButton] of Word =
    ($0800, $0400, $0200, $0100, $8000, $4000, $2000, $1000, $0004, $0002, $0008, $0001, $0010);
begin
  if FWorker = nil then
    Exit;
  var Pads := Default(TN64Pads);
  for var P := 0 to 3 do
  begin
    Pads[P] := FAnalog[P];
    Pads[P].Connected := (FConfig as TN64Config).Connected(P);
    var Buttons := FKeyboard[P] + FGamepad[P];
    if FLPressed[P] then
      Pads[P].Buttons := Pads[P].Buttons or $20;
    for var B in Buttons do
      Pads[P].Buttons := Pads[P].Buttons or Masks[B];
    if TEmulatorButton.Left in Buttons then
      Pads[P].StickX := -80;
    if TEmulatorButton.Right in Buttons then
      Pads[P].StickX := 80;
    if TEmulatorButton.Up in Buttons then
      Pads[P].StickY := 80;
    if TEmulatorButton.Down in Buttons then
      Pads[P].StickY := -80;
  end;
  FWorker.Configure(Pads, FPaused, FConfig);
end;

procedure TN64CoreAdapter.Start;
begin
  if FWorker <> nil then
    Exit;
  if Length(FPendingSaveData) > 0 then
  begin
    FStorage.WriteBytes(FSavePath, FPendingSaveData);
    FPendingSaveData := nil;
  end;
  FWorker := TN64Worker.Create(FData, FStorage, FSavePath, FSnapshotDirectory);
  Configure;
  FWorker.Start;
end;

procedure TN64CoreAdapter.Stop;
begin
  if FWorker = nil then
  begin
    if Length(FPendingSaveData) > 0 then
    try
      FStorage.WriteBytes(FSavePath, FPendingSaveData);
      FPendingSaveData := nil
    except
      on E: Exception do
        FError := E.Message
    end;
    Exit;
  end;
  try
    FWorker.StopAndSave
  except
    on E: Exception do
    begin
      FError := E.Message;
      FPendingSaveData := Copy(FWorker.FPendingBattery)
    end;
  end;
  var Error := FWorker.TakeError(False);
  if Error <> '' then
    FError := Error;
  FreeAndNil(FWorker);
end;

procedure TN64CoreAdapter.Pause;
begin
  FPaused := True;
  Configure
end;

procedure TN64CoreAdapter.Resume;
begin
  FPaused := False;
  Configure
end;

procedure TN64CoreAdapter.Reset;
begin
  if FWorker <> nil then
    FWorker.RequestReset
end;

procedure TN64CoreAdapter.ClearInput;
begin
  for var I := 0 to 3 do
  begin
    FKeyboard[I] := [];
    FGamepad[I] := [];
    FLPressed[I] := False;
    FAnalog[I] := Default(TN64Pad)
  end;
  Configure
end;

procedure TN64CoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  if Code = 0 then
    Exit;
  for var P := 0 to 3 do
    if (FConfig as TN64Config).LKey(P) = Code then
      FLPressed[P] := Pressed;
  for var P := 0 to 3 do
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      if FKeys[P, B] = Code then
        if Pressed then
          Include(FKeyboard[P], B)
        else
          Exclude(FKeyboard[P], B);
  Configure;
end;

procedure TN64CoreAdapter.SetN64Controller(Port: Integer; const Pad: TN64Pad);
begin
  if (Port < 0) or (Port > 3) then
    raise EArgumentOutOfRangeException.Create('N64 controller port');
  FAnalog[Port] := Pad;
  Configure;
end;

procedure TN64CoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepad[0] := Input.Buttons;
  FGamepad[1] := Input.Buttons2;
  FGamepad[2] := Input.Buttons3;
  FGamepad[3] := Input.Buttons4;
  Configure;
end;

function TN64CoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := Default(TEmulatorInput);
  Result.Buttons := FKeyboard[0] + FGamepad[0];
  Result.Buttons2 := FKeyboard[1] + FGamepad[1];
  Result.Buttons3 := FKeyboard[2] + FGamepad[2];
  Result.Buttons4 := FKeyboard[3] + FGamepad[3];
end;

function TN64CoreAdapter.GetName: string;
begin
  Result := '';
  for var I := $20 to $33 do
    if FData[I] in [32..126] then
      Result := Result + Char(FData[I]);
  Result := Result.Trim;
  if Result = '' then
    Result := 'Nintendo 64';
end;

function TN64CoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True
end;

function TN64CoreAdapter.GetUsesSuborKeyboard: Boolean;
begin
  Result := False
end;

function TN64CoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False
end;

procedure TN64CoreAdapter.InsertCoin1;
begin
end;

procedure TN64CoreAdapter.InsertCoin2;
begin
end;

function TN64CoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory
end;

procedure TN64CoreAdapter.SaveSnapshot(const Name: string);
begin
  if FWorker <> nil then
    FWorker.Snapshot(Name, False)
end;

procedure TN64CoreAdapter.LoadSnapshot(const Name: string);
begin
  if FWorker <> nil then
    FWorker.Snapshot(Name, True)
end;

function TN64CoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  Result := (FWorker <> nil) and FWorker.TryGetFrame(Frame)
end;

function TN64CoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FWorker <> nil) then
    Result := FWorker.TakeError(False)
end;

function TN64CoreAdapter.TakeAudioError: string;
begin
  Result := '';
  if FWorker <> nil then
    Result := FWorker.TakeError(True)
end;

function TN64CoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig
end;

function TN64CoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused
end;

end.

