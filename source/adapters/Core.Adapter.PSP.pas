unit Core.Adapter.PSP;

interface

uses System.SysUtils, System.Classes, System.IniFiles, System.SyncObjs,
  Core.Storage, Core.Emulation, PSP.Types, PSP.Media, PSP.Console, PCM.Audio;

type
  TPSPKeyMap = array[TEmulatorButton] of UInt32;

  TPSPConfig = class(TEmulatorConfigBase)
  private
    FKeys: TPSPKeyMap;
    FRecompiler: Boolean;
    FLanguage, FButtonSwap: Integer;
    FNickname: string;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const FileName: string; const Storage: IStorage);
    property Keys: TPSPKeyMap read FKeys;
    // The CPU through its recompiler (Emulation/Execution jit), else interpreted.
    property Recompiler: Boolean read FRecompiler write FRecompiler;
    property Language: Integer read FLanguage;
    property ButtonSwap: Integer read FButtonSwap;
    property Nickname: string read FNickname;
  end;

  TPSPWorker = class(TThread)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FConsole: TPSPConsole;
    FAudio: TPCMAudio;
    FAudioEnabled: Boolean;
    FVolume: Single;
    FInput: TEmulatorInput;
    FPaused, FReset, FAvailable: Boolean;
    FRecompiler: Boolean;
    FFrame: TEmulatorFrame;
    FError: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const ProgramData: TPSPProgram; const Storage: IStorage);
    destructor Destroy; override;
    procedure Configure(const Input: TEmulatorInput; Paused: Boolean; AudioEnabled: Boolean = True; Volume: Single = 1;
      Recompiler: Boolean = True);
    procedure RequestReset;
    procedure Join;
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
  end;

  TPSPCoreAdapter = class(TInterfacedObject, IEmulationCore)
  private
    FProgram: TPSPProgram;
    FStorage: IStorage;
    FConfig: IEmulatorConfig;
    FConfigObject: TPSPConfig;
    FWorker: TPSPWorker;
    FKeyboard, FGamepad: TEmulatorInput;
    FPaused: Boolean;
    FError: string;
    procedure Configure;
  public
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string);
    destructor Destroy; override;
    function GetName: string;
    function GetSystemId: string;
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
    function GetInputState: TEmulatorInput;
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function GetConfig: IEmulatorConfig;
    function IsPaused: Boolean;
  end;

implementation

uses System.UITypes, System.Diagnostics, System.Math, Core.PSP.Archive, PSP.Settings;

const
  KeyNames: array[TEmulatorButton] of string =
    ('Up','Down','Left','Right','A','B','Select','Start','C','X','Y','Z','Mode');

constructor TPSPConfig.Create(const FileName: string; const Storage: IStorage);
const
  DefaultKeys: TPSPKeyMap = (vkUp,vkDown,vkLeft,vkRight,vkZ,vkX,vkShift,vkReturn,vkQ,vkA,vkS,vkW,0);
begin
  inherited Create(FileName, Storage);
  FKeys := DefaultKeys;
  FRecompiler := True;
  FLanguage := 1;
  FButtonSwap := 1;
  FNickname := 'RetroMul';
end;

procedure TPSPConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
    FKeys[Button] := ReadEmulatorKey(Ini,'Keys',KeyNames[Button],FKeys[Button]);
  FRecompiler := not SameText(Ini.ReadString('Emulation', 'Execution', 'jit'), 'interpreter');
  FLanguage := EnsureRange(Ini.ReadInteger('System', 'Language', FLanguage), 0, 11);
  FButtonSwap := EnsureRange(Ini.ReadInteger('System', 'ButtonSwap', FButtonSwap), 0, 1);
  FNickname := Ini.ReadString('System', 'Nickname', FNickname);
end;

procedure TPSPConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
    Ini.WriteInteger('Keys',KeyNames[Button],FKeys[Button]);
  if FRecompiler then
    Ini.WriteString('Emulation', 'Execution', 'jit')
  else
    Ini.WriteString('Emulation', 'Execution', 'interpreter');
  Ini.WriteInteger('System', 'Language', FLanguage);
  Ini.WriteInteger('System', 'ButtonSwap', FButtonSwap);
  Ini.WriteString('System', 'Nickname', FNickname);
end;

constructor TPSPWorker.Create(const ProgramData: TPSPProgram; const Storage: IStorage);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil,False,False,'');
  FConsole := TPSPConsole.Create(ProgramData,Storage);
end;

destructor TPSPWorker.Destroy;
begin
  Join;
  inherited;
  FConsole.Free;
  FAudio.Free;
  FWake.Free;
  FLock.Free;
end;

procedure TPSPWorker.Join;
begin
  Terminate;
  if FWake <> nil then FWake.SetEvent;
  if Suspended then Start;
  WaitFor;
end;

procedure TPSPWorker.Configure(const Input: TEmulatorInput; Paused: Boolean; AudioEnabled: Boolean; Volume: Single;
  Recompiler: Boolean);
begin
  FLock.Acquire;
  try
    FInput := Input;
    FRecompiler := Recompiler;
    FPaused := Paused;
    FAudioEnabled := AudioEnabled;
    FVolume := EnsureRange(Volume,0.0,1.0);
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TPSPWorker.RequestReset;
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

procedure TPSPWorker.Execute;
begin
  try
    var AudioFormat := Default(TPCMAudioFormat);
    AudioFormat.SampleRate := 44100;
    AudioFormat.Channels := 2;
    AudioFormat.BlockFrames := 4096;
    AudioFormat.BlockCount := 8;
    FAudio := TPCMAudio.Create(AudioFormat);
    var Deadline := TStopwatch.GetTimeStamp / TStopwatch.Frequency;
    while not Terminated do
    begin
      var Paused, Reset: Boolean;
      var AudioEnabled: Boolean;
      var Volume: Single;
      var Input: TEmulatorInput;
      var Recompiler: Boolean;
      FLock.Acquire;
      try
        Recompiler := FRecompiler;
        Paused := FPaused;
        Reset := FReset;
        FReset := False;
        Input := FInput;
        AudioEnabled := FAudioEnabled;
        Volume := FVolume;
      finally
        FLock.Release;
      end;
      if Reset then begin FConsole.Reset; FAudio.Clear; end;
      FAudio.SetPaused(Paused);
      if Paused then
      begin
        FWake.WaitFor(20);
        Deadline := TStopwatch.GetTimeStamp / TStopwatch.Frequency;
        Continue;
      end;
      if FConsole.Recompiler <> nil then
        FConsole.Recompiler.Enabled := Recompiler;
      FConsole.Input := Input;
      var Frame: TEmulatorFrame;
      FConsole.RunFrame(Frame);
      if AudioEnabled then
      begin
        var Samples := FConsole.AudioSamples;
        if Volume<>1 then for var I := 0 to High(Samples) do Samples[I] := Round(Samples[I]*Volume);
        var Offset := 0;
        while Offset<Length(Samples) do
        begin
          var Count := Min(4096,(Length(Samples)-Offset) div 2);
          var Block := Copy(Samples,Offset,Count*2);
          FAudio.Submit(Block,Count);
          Inc(Offset,Count*2);
        end;
      end;
      FLock.Acquire;
      try
        FFrame := Frame;
        FAvailable := True;
      finally
        FLock.Release;
      end;
      Deadline := Deadline + 1 / PSPFrameRate;
      // Input updates can wake the worker but must not accelerate guest time.
      while not Terminated do
      begin
        var Remaining := Deadline - TStopwatch.GetTimeStamp / TStopwatch.Frequency;
        if Remaining <= 0 then Break;
        FWake.WaitFor(Cardinal(Max(1, Min(20, Trunc(Remaining * 1000)))));
      end;
      var Now := TStopwatch.GetTimeStamp / TStopwatch.Frequency;
      if Deadline < Now - 0.1 then Deadline := Now;
    end;
  except
    on E: Exception do
    begin
      FLock.Acquire;
      try
        FError := E.ClassName + ': ' + E.Message;
      finally
        FLock.Release;
      end;
    end;
  end;
end;

function TPSPWorker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
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

function TPSPWorker.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

constructor TPSPCoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string);
begin
  inherited Create;
  var ActualStorage := Storage;
  if ActualStorage = nil then ActualStorage := TStorage.Default;
  FStorage := ActualStorage;
  var SourceName := RomName;
  if SourceName.StartsWith('content://',True) then SourceName := ActualStorage.Describe(RomName).Name;
  if SameText(ExtractFileExt(SourceName),'.zip') then
    FProgram := ReadPSPArchive(Stream,ActualStorage,True)
  else
  begin
    FProgram := TPSPProgram.Read(Stream);
    if (FProgram.BootPath<>'') and (RomName<>'') then FProgram.MediaPath := RomName;
  end;
  // Reject unsupported executables during loading, before starting a worker.
  var Probe := TPSPConsole.Create(FProgram,FStorage);
  Probe.Free;
  FConfigObject := TPSPConfig.Create(ActualStorage.ConfigFile('psp'),ActualStorage);
  FConfig := FConfigObject;
  FConfig.Load;
end;

destructor TPSPCoreAdapter.Destroy;
begin
  Stop;
  if FProgram.TemporaryMedia and (FStorage<>nil) and FStorage.Exists(FProgram.MediaPath) then
    FStorage.Delete(FProgram.MediaPath);
  inherited;
end;

procedure TPSPCoreAdapter.Configure;
begin
  if FWorker <> nil then
    FWorker.Configure(GetInputState,FPaused,FConfig.AudioEnabled,FConfig.AudioVolume,FConfigObject.Recompiler);
end;

procedure TPSPCoreAdapter.Start;
begin
  if FWorker <> nil then Exit;
  FError := '';
  // The system settings the game reads (sceUtility, sceReg, sceImpose).
  PSPSettings.Language := FConfigObject.Language;
  PSPSettings.ButtonSwap := FConfigObject.ButtonSwap;
  PSPSettings.Nickname := FConfigObject.Nickname;
  FWorker := TPSPWorker.Create(FProgram,FStorage);
  Configure;
  FWorker.Start;
end;

procedure TPSPCoreAdapter.Stop;
begin
  if FWorker = nil then Exit;
  FWorker.Join;
  var Error := FWorker.TakeError;
  if Error <> '' then FError := Error;
  FreeAndNil(FWorker);
end;

procedure TPSPCoreAdapter.Pause;
begin
  FPaused := True;
  Configure;
end;

procedure TPSPCoreAdapter.Resume;
begin
  FPaused := False;
  Configure;
end;

procedure TPSPCoreAdapter.Reset;
begin
  if (FWorker <> nil) and FWorker.Finished then
  begin
    Stop;
    Start;
  end
  else if FWorker <> nil then FWorker.RequestReset;
end;

procedure TPSPCoreAdapter.ClearInput;
begin
  FKeyboard := Default(TEmulatorInput);
  FGamepad := Default(TEmulatorInput);
  Configure;
end;

procedure TPSPCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  if Code = 0 then Exit;
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
    if FConfigObject.Keys[Button] = Code then
      if Pressed then Include(FKeyboard.Buttons,Button) else Exclude(FKeyboard.Buttons,Button);
  Configure;
end;

procedure TPSPCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepad := Default(TEmulatorInput);
  FGamepad.Buttons := Input.Buttons;
  FGamepad.Analog[0] := Input.Analog[0];
  Configure;
end;

function TPSPCoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := FGamepad;
  Result.Buttons := Result.Buttons + FKeyboard.Buttons;
end;

function TPSPCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  Result := (FWorker <> nil) and FWorker.TryGetFrame(Frame);
end;

function TPSPCoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FWorker <> nil) then Result := FWorker.TakeError;
end;

function TPSPCoreAdapter.GetName: string;
begin
  Result := 'Sony PSP';
end;

function TPSPCoreAdapter.GetSystemId: string;
begin
  Result := 'psp';
end;

function TPSPCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := False;
end;

function TPSPCoreAdapter.GetUsesSuborKeyboard: Boolean;
begin
  Result := False;
end;

function TPSPCoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TPSPCoreAdapter.InsertCoin1;
begin
end;

procedure TPSPCoreAdapter.InsertCoin2;
begin
end;

procedure TPSPCoreAdapter.SaveSnapshot(const Name: string);
begin
  raise ENotSupportedException.Create('PSP save states are not implemented');
end;

procedure TPSPCoreAdapter.LoadSnapshot(const Name: string);
begin
  raise ENotSupportedException.Create('PSP save states are not implemented');
end;

function TPSPCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TPSPCoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

end.
