unit Core.Adapter.SG1000;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, Core.Storage, Core.Emulation,
  Core.InputConfig, SG1000.Console, SG1000.Emulation;

type
  ISGKeyboardCore = interface
    ['{EFD61C7F-7A61-4F3A-A792-A0D5D6C237ED}']
    procedure SetScreenKeys(const Keys: TSGHostKeys);
    function GetHasKeyboard: Boolean;
    property HasKeyboard: Boolean read GetHasKeyboard;
  end;

  TSGButton = (Up, Down, Left, Right, A, B, Start);

  TSGButtons = set of TSGButton;

  TSGKeyMap = array[TSGButton] of UInt32;

  TSGConfig = class(TEmulatorConfigBase)
  private
    FKeys, FKeys2: TSGKeyMap;
    FSystemId: string;
    FPAL: Boolean;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const FileName: string; const Storage: IStorage = nil; const SystemId: string = 'sg1000');
    property SystemId: string read FSystemId;
    property PAL: Boolean read FPAL;
    property Keys: TSGKeyMap read FKeys;
    property Keys2: TSGKeyMap read FKeys2;
  end;

  TSGCoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationSnapshotLocation, IEmulationAudioDiagnostics, ISGKeyboardCore)
  private
    FThread: TSGWorker;
    FData: TBytes;
    FSnapshotDirectory: string;
    FStorage: IStorage;
    FError: string;
    FSC3000: Boolean;
    FHostKeys, FScreenKeys: TSGHostKeys;
    FConfig: IEmulatorConfig;
    FKeys, FKeys2: TSGKeyMap;
    FKeyboard, FGamepad, FKeyboard2, FGamepad2: TSGButtons;
    FPaused: Boolean;
    procedure ApplySettings;
  public
    constructor Create(const FileName: string); overload;
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string; SC3000: Boolean = False); overload;
    destructor Destroy; override;
    procedure SetScreenKeys(const Keys: TSGHostKeys);
    function GetHasKeyboard: Boolean;
    function GetName: string;
    function GetSupportsSnapshots: Boolean;
    function GetUsesSuborKeyboard: Boolean;
    function GetHasCoinAcceptor: Boolean;
    procedure InsertCoin1;
    procedure InsertCoin2;
    property HasCoinAcceptor: Boolean read GetHasCoinAcceptor;
    procedure Start;
    procedure Stop;
    procedure Pause;
    procedure Resume;
    procedure Reset;
    procedure ClearInput;
    procedure SetKeyState(Code: UInt32; Pressed: Boolean);
    procedure SetGamepadInput(const Input: TEmulatorInput);
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
  System.IOUtils, System.UITypes, System.Hash, SG1000.Cartridge, Core.RomFormat;

const
  KeyNames: array[TSGButton] of string = ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Start');

{ TSGConfig }

constructor TSGConfig.Create(const FileName: string; const Storage: IStorage; const SystemId: string);
const
  Defaults: TSGKeyMap = (vkUp, vkDown, vkLeft, vkRight, vkZ, vkX, vkReturn);
  Defaults2: TSGKeyMap = (vkNumpad8, vkNumpad5, vkNumpad4, vkNumpad6,
    vkNumpad1, vkNumpad2, vkNumpad0);
begin
  inherited Create(FileName, Storage);
  FSystemId := SystemId;
  FKeys := Defaults;
  FKeys2 := Defaults2;
end;

procedure TSGConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  FPAL := SameText(Ini.ReadString('Video', 'Region', 'NTSC'), 'PAL');
  for var Button := Low(TSGButton) to High(TSGButton) do
  begin
    FKeys[Button] := ReadEmulatorKey(Ini, 'Keys', KeyNames[Button], FKeys[Button]);
    FKeys2[Button] := ReadEmulatorKey(Ini, 'Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

procedure TSGConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  if FPAL then
    Ini.WriteString('Video', 'Region', 'PAL')
  else
    Ini.WriteString('Video', 'Region', 'NTSC');
  for var Button := Low(TSGButton) to High(TSGButton) do
  begin
    Ini.WriteInteger('Keys', KeyNames[Button], FKeys[Button]);
    Ini.WriteInteger('Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

{ TSGCoreAdapter }

constructor TSGCoreAdapter.Create(const FileName: string);
begin
  var Storage := TStorage.Default;
  var Stream := Storage.OpenRead(FileName);
  try
    Create(Stream, Storage, FileName, SameText(ExtractFileExt(FileName), ROM_EXTENSION_SC));
  finally
    Stream.Free;
  end;
end;

constructor TSGCoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string; SC3000: Boolean);
var
  Cart: TSGCartridge;
  Config: TSGConfig;
  Hash: THashSHA2;
begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  var Data := ReadRomData(Stream);
  Cart := TSGCartridge.Create(Data);
  Cart.Free;
  FData := Copy(Data);
  FSC3000 := SC3000;
  var SystemId := ROM_SYSTEM_SG1000;
  if FSC3000 then
    SystemId := ROM_SYSTEM_SC3000;
  Config := TSGConfig.Create(FStorage.ConfigFile(SystemId), FStorage, SystemId);
  FConfig := Config;
  Config.Load;
  FKeys := Config.Keys;
  FKeys2 := Config.Keys2;
  Hash := THashSHA2.Create;
  Hash.Update(FData);
  FSnapshotDirectory := FStorage.GameSnapshots(SystemId, RomName, Hash.HashAsString);
end;

destructor TSGCoreAdapter.Destroy;
begin
  // The worker joins before releasing its console and synchronization objects.
  FThread.Free;
  inherited;
end;

procedure TSGCoreAdapter.ApplySettings;
begin
  if FThread <> nil then
  begin
    var Keys := FHostKeys;
    for var i := 0 to High(Keys) do
      Keys[i] := Keys[i] or FScreenKeys[i];
    FThread.Configure(GetInputState, Keys, FPaused, FConfig.AudioEnabled, FConfig.AudioVolume);
  end;
end;

procedure TSGCoreAdapter.Start;
begin
  if FThread <> nil then
    Exit;

  FThread := TSGWorker.Create(FData, FSC3000, TSGConfig(FConfig).PAL, FStorage);
  FThread.SnapshotDirectory := FSnapshotDirectory;
  FThread.InputPorts := LoadCoreInputPorts(FStorage, TSGConfig(FConfig).SystemId);
  ApplySettings;
  FThread.Start;
end;

procedure TSGCoreAdapter.Stop;
begin
  if FThread = nil then
    Exit;

  FThread.StopAndSave;
  FError := FThread.TakeError;
  FreeAndNil(FThread);
end;

procedure TSGCoreAdapter.Pause;
begin
  FPaused := True;
  ApplySettings;
end;

procedure TSGCoreAdapter.Resume;
begin
  FPaused := False;
  ApplySettings;
end;

procedure TSGCoreAdapter.Reset;
begin
  FPaused := False;
  if FThread <> nil then
    FThread.RequestReset;
  ApplySettings;
end;

procedure TSGCoreAdapter.ClearInput;
begin
  FillChar(FHostKeys, SizeOf(FHostKeys), 0);
  FillChar(FScreenKeys, SizeOf(FScreenKeys), 0);
  FKeyboard := [];
  FGamepad := [];
  FKeyboard2 := [];
  FGamepad2 := [];
  ApplySettings;
end;

procedure TSGCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
var
  Button: TSGButton;
begin
  if FSC3000 then
  begin
    if Code <= High(FHostKeys) then
      FHostKeys[Code] := Pressed;

    // FMX can report either generic or left/right modifier virtual keys.
    if Code in [vkLShift, vkRShift] then
      FHostKeys[vkShift] := FHostKeys[vkLShift] or FHostKeys[vkRShift];
    if Code in [vkLControl, vkRControl] then
      FHostKeys[vkControl] := FHostKeys[vkLControl] or FHostKeys[vkRControl];
    if Code in [vkLMenu, vkRMenu] then
      FHostKeys[vkMenu] := FHostKeys[vkLMenu];
    ApplySettings;
    Exit;
  end;

  for Button := Low(TSGButton) to High(TSGButton) do
  begin
    if Code = FKeys[Button] then
      if Pressed then
        Include(FKeyboard, Button)
      else
        Exclude(FKeyboard, Button);
    if Code = FKeys2[Button] then
      if Pressed then
        Include(FKeyboard2, Button)
      else
        Exclude(FKeyboard2, Button);
  end;
  ApplySettings;
end;

function TSGCoreAdapter.GetInputState: TEmulatorInput;
const
  Mapping: array[TSGButton] of TEmulatorButton =
    (TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
    TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B,
    TEmulatorButton.Start);
begin
  Result := Default(TEmulatorInput);
  for var Button := Low(TSGButton) to High(TSGButton) do
  begin
    if Button in (FKeyboard + FGamepad) then
      Include(Result.Buttons, Mapping[Button]);
    if Button in (FKeyboard2 + FGamepad2) then
      Include(Result.Buttons2, Mapping[Button]);
  end;
end;

procedure TSGCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
const
  Mapping: array[TSGButton] of TEmulatorButton =
    (TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
    TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Start);
begin
  FGamepad := [];
  FGamepad2 := [];
  for var Button := Low(TSGButton) to High(TSGButton) do
  begin
    if Mapping[Button] in Input.Buttons then
      Include(FGamepad, Button);
    if Mapping[Button] in Input.Buttons2 then
      Include(FGamepad2, Button);
  end;
  ApplySettings;
end;

function TSGCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  ApplySettings;
  Result := (FThread <> nil) and FThread.TryGetFrame(Frame);
end;

function TSGCoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FThread <> nil) then
    Result := FThread.TakeError;
end;

function TSGCoreAdapter.TakeAudioError: string;
begin
  Result := '';
  if FThread <> nil then
    Result := FThread.TakeAudioError;
end;

function TSGCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

procedure TSGCoreAdapter.SetScreenKeys(const Keys: TSGHostKeys);
begin
  FScreenKeys := Keys;
  ApplySettings;
end;

function TSGCoreAdapter.GetHasKeyboard: Boolean;
begin
  Result := FSC3000;
end;

function TSGCoreAdapter.GetName: string;
begin
  if FSC3000 then
    Result := 'SEGA SC-3000'
  else
    Result := 'SEGA SG-1000';
end;

function TSGCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TSGCoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TSGCoreAdapter.InsertCoin1;
begin
end;

procedure TSGCoreAdapter.InsertCoin2;
begin
end;

function TSGCoreAdapter.GetUsesSuborKeyboard: Boolean;
begin
  Result := False;
end;

function TSGCoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

function TSGCoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

procedure TSGCoreAdapter.SaveSnapshot(const Name: string);
begin
  if FThread = nil then
    raise EInvalidOpException.Create('Emulation worker is not running');

  FThread.SaveSnapshot(Name);
end;

procedure TSGCoreAdapter.LoadSnapshot(const Name: string);
begin
  if FThread = nil then
    raise EInvalidOpException.Create('Emulation worker is not running');

  FThread.LoadSnapshot(Name);
end;

end.

