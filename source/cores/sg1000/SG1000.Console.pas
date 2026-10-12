unit SG1000.Console;

interface

uses
  System.SysUtils, System.Classes, System.UITypes, Core.Emulation,
  Core.Snapshots, MD.Z80, SG1000.Cartridge, SG1000.VDP, SG1000.Sound;

type
  TSGHostKeys = array[0..255] of Boolean;

  TSGConsole = class
  private
    FCPU: TZ80State;
    FCallbacks: TZ80ReadAndWriteCallbacks;
    FCartridge: TSGCartridge;
    FVDP: TSGVDP;
    FSound: TSGSound;
    FRAM: array[0..$7FF] of Byte;
    FKeys: TSGHostKeys;
    FInput: TEmulatorInput;
    FSC3000, FPAL, FHold: Boolean;
    FPPI: array[0..2] of Byte;
    FPPIControl: Byte;
    FLine, FLineCycles, FSamplePhase, FSampleCount: Integer;
    FFrameNumber: UInt64;
    FSamples: TArray<SmallInt>;
    function KeyboardPort(Port: Integer): Byte;
    function JoystickPort(Port: Integer): Byte;
    procedure Advance(Cycles: Integer);
    function GetCPUClock: Integer;
    function GetFPS: Double;
  public
    constructor Create(const Data: TBytes; SC3000: Boolean; PAL: Boolean = False);
    destructor Destroy; override;
    procedure Reset;
    procedure SetInput(const Input: TEmulatorInput; const Keys: TSGHostKeys);
    function ReadMemory(Address: Word): Byte;
    procedure WriteMemory(Address: Word; Value: Byte);
    function ReadPort(Address: Word): Byte;
    procedure WritePort(Address: Word; Value: Byte);
    function Step: Integer;
    procedure RunFrame;
    procedure SerializeState(State: TStateArchive);
    property VDP: TSGVDP read FVDP;
    property CPU: TZ80State read FCPU;
    property FrameNumber: UInt64 read FFrameNumber;
    property FramesPerSecond: Double read GetFPS;
    property Samples: TArray<SmallInt> read FSamples;
    property SampleFrames: Integer read FSampleCount;
  end;

implementation

function ReadBus(UserData: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TSGConsole(UserData).ReadMemory(Word(Address and $FFFF));
end;

procedure WriteBus(UserData: Pointer; Address, Value: Cardinal);
begin
  TSGConsole(UserData).WriteMemory(Word(Address and $FFFF), Byte(Value and $FF));
end;

function ReadIO(UserData: Pointer; Address: Cardinal): Cardinal;
begin
  Result := TSGConsole(UserData).ReadPort(Word(Address and $FFFF));
end;

procedure WriteIO(UserData: Pointer; Address, Value: Cardinal);
begin
  TSGConsole(UserData).WritePort(Word(Address and $FFFF), Byte(Value and $FF));
end;

constructor TSGConsole.Create(const Data: TBytes; SC3000, PAL: Boolean);
begin
  inherited Create;
  FSC3000 := SC3000;
  FPAL := PAL;
  FCartridge := TSGCartridge.Create(Data);
  FVDP := TSGVDP.Create;
  FSound := TSGSound.Create;
  SetLength(FSamples, 2048 * 2);
  FCallbacks.ReadCallback := ReadBus;
  FCallbacks.WriteCallback := WriteBus;
  FCallbacks.PortReadCallback := ReadIO;
  FCallbacks.PortWriteCallback := WriteIO;
  FCallbacks.UserData := Self;
  Reset;
end;

destructor TSGConsole.Destroy;
begin
  FSound.Free;
  FVDP.Free;
  FCartridge.Free;
  inherited;
end;

function TSGConsole.GetCPUClock: Integer;
begin
  if FPAL then
    Result := 3546893
  else
    Result := 3579545;
end;

function TSGConsole.GetFPS: Double;
begin
  if FPAL then
    Result := GetCPUClock / (228.0 * 313)
  else
    Result := GetCPUClock / (228.0 * 262);
end;

procedure TSGConsole.Reset;
begin
  FCPU := Default(TZ80State);
  Z80StateInitialise(FCPU);
  FCPU.StackPointer := $FFFF;
  FillChar(FRAM, SizeOf(FRAM), 0);
  FCartridge.Reset;
  FVDP.Reset;
  FSound.Reset;
  FillChar(FPPI, SizeOf(FPPI), 0);
  FPPIControl := $9B;
  FLine := 0;
  FLineCycles := 0;
  FSamplePhase := 0;
  FSampleCount := 0;
  FFrameNumber := 0;
  FHold := False;
end;

procedure TSGConsole.SetInput(const Input: TEmulatorInput; const Keys: TSGHostKeys);
begin
  FInput := Input;
  FKeys := Keys;
  var Hold := TEmulatorButton.Start in Input.Buttons;
  if Hold and not FHold then
    Z80NonMaskableInterrupt(FCPU);
  FHold := Hold;
end;

function TSGConsole.ReadMemory(Address: Word): Byte;
begin
  if (Address < $C000) or FCartridge.OverridesSystemRAM then
    Exit(FCartridge.Read(Address));

  if FSC3000 then
    Result := FRAM[Address and $7FF]
  else
    Result := FRAM[Address and $3FF];
end;

procedure TSGConsole.WriteMemory(Address: Word; Value: Byte);
begin
  FCartridge.Write(Address, Value);
  if (Address >= $C000) and not FCartridge.OverridesSystemRAM then
  begin
    if FSC3000 then
      FRAM[Address and $7FF] := Value
    else
      FRAM[Address and $3FF] := Value;
  end;
end;

function TSGConsole.JoystickPort(Port: Integer): Byte;
const
  Buttons: array[0..5] of TEmulatorButton =
    (TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
    TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B);
begin
  var First := $3F;
  var Second := $3F;
  for var i := 0 to 5 do
  begin
    if Buttons[i] in FInput.Buttons then
      First := First and ($3F xor (1 shl i));
    if Buttons[i] in FInput.Buttons2 then
      Second := Second and ($3F xor (1 shl i));
  end;
  if Port = 0 then
    Result := First or ((Second and 3) shl 6)
  else
    Result := $F0 or (Second shr 2);
end;

function TSGConsole.KeyboardPort(Port: Integer): Byte;
const
  // SC-3000/SK-1100 contacts, host virtual-key codes. $FF is an unused contact.
  PA: array[0..6, 0..7] of Byte = (
    ($31, $51, $41, $5A, $A5, $BC, $4B, $49),
    ($32, $57, $53, $58, $20, $BE, $4C, $4F),
    ($33, $45, $44, $43, $2D, $BF, $BA, $50),
    ($34, $52, $46, $56, $2E, $E2, $DE, $C0),
    ($35, $54, $47, $42, $FF, $28, $DD, $DB),
    ($36, $59, $48, $4E, $FF, $25, $0D, $FF),
    ($37, $55, $4A, $4D, $FF, $27, $26, $FF));
  PB: array[0..6, 0..3] of Byte = (
    ($38, $FF, $FF, $FF), ($39, $FF, $FF, $FF), ($30, $FF, $FF, $FF),
    ($BD, $FF, $FF, $FF), ($BB, $FF, $FF, $FF), ($DC, $FF, $FF, $09),
    ($1B, $12, $11, $10));
begin
  var Row := FPPI[2] and 7;
  if Row = 7 then
    Exit(JoystickPort(Port));

  if Port = 0 then
  begin
    Result := $FF;
    for var i := 0 to 7 do
      if (PA[Row, i] <> $FF) and FKeys[PA[Row, i]] then
        Result := Result and ($FF xor (1 shl i));
  end
  else
  begin
    // No cassette signal; printer is idle, /CONT and /FAULT are high.
    Result := $3F;
    for var i := 0 to 3 do
      if (PB[Row, i] <> $FF) and FKeys[PB[Row, i]] then
        Result := Result and ($FF xor (1 shl i));
  end;
end;

function TSGConsole.ReadPort(Address: Word): Byte;
begin
  var Port := Address and $FF;
  Result := $FF;
  if (Port >= $80) and (Port <= $BF) then
  begin
    if Port and 1 = 0 then
      Result := FVDP.ReadData
    else
      Result := FVDP.ReadStatus;
    Exit;
  end;

  if (Port < $DC) or (Port > $DF) then
    Exit;

  if not FSC3000 then
  begin
    Result := JoystickPort(Port and 1);
    Exit;
  end;

  case Port and 3 of
    0:
      if FPPIControl and $10 <> 0 then
        Result := KeyboardPort(0)
      else
        Result := FPPI[0];
    1:
      if FPPIControl and 2 <> 0 then
        Result := KeyboardPort(1)
      else
        Result := FPPI[1];
    2:
      begin
        Result := FPPI[2];
        if FPPIControl and 8 <> 0 then
          Result := Result or $F0;
        if FPPIControl and 1 <> 0 then
          Result := Result or $0F;
      end;
    3:
      Result := $FF; // 8255 control register is write-only.
  end;
end;

procedure TSGConsole.WritePort(Address: Word; Value: Byte);
begin
  var Port := Address and $FF;
  if (Port >= $40) and (Port <= $7F) then
    FSound.Write(Value)
  else if (Port >= $80) and (Port <= $BF) then
  begin
    if Port and 1 = 0 then
      FVDP.WriteData(Value)
    else
      FVDP.WriteControl(Value);
  end
  else if FSC3000 and (Port >= $DC) and (Port <= $DF) then
    case Port and 3 of
      0, 1:
        FPPI[Port and 3] := Value;
      2:
        FPPI[2] := Value;
      3:
        if Value and $80 <> 0 then
        begin
          FPPIControl := Value;
          FillChar(FPPI, SizeOf(FPPI), 0);
        end
        else
        begin
          var Bit := (Value shr 1) and 7;
          if Value and 1 <> 0 then
            FPPI[2] := FPPI[2] or (1 shl Bit)
          else
            FPPI[2] := FPPI[2] and ($FF xor (1 shl Bit));
        end;
    end;
end;

procedure TSGConsole.Advance(Cycles: Integer);
begin
  // Advance only to the next raster/audio event; retain exact T-state phases
  // and instruction overshoot without looping through every individual clock.
  while Cycles > 0 do
  begin
    var Chunk := Cycles;
    if Chunk > 228 - FLineCycles then
      Chunk := 228 - FLineCycles;
    var ToSample := (GetCPUClock - FSamplePhase + 44099) div 44100;
    if Chunk > ToSample then
      Chunk := ToSample;
    Dec(Cycles, Chunk);
    FSound.Advance(Chunk);
    Inc(FSamplePhase, Chunk * 44100);
    if FSamplePhase >= GetCPUClock then
    begin
      Dec(FSamplePhase, GetCPUClock);
      if FSampleCount >= Length(FSamples) div 2 then
        raise EInvalidOpException.Create('SG-1000 audio frame buffer exhausted');

      var Sample := FSound.Sample;
      FSamples[FSampleCount * 2] := Sample;
      FSamples[FSampleCount * 2 + 1] := Sample;
      Inc(FSampleCount);
    end;
    Inc(FLineCycles, Chunk);
    if FLineCycles = 228 then
    begin
      FLineCycles := 0;
      if FLine < 192 then
        FVDP.RenderLine(FLine);
      if FLine = 193 then
        FVDP.VBlank;
      Inc(FLine);
      if ((not FPAL) and (FLine = 262)) or (FPAL and (FLine = 313)) then
      begin
        FLine := 0;
        // Explicit modulo arithmetic also works with overflow checking enabled.
        if FFrameNumber = High(UInt64) then
          FFrameNumber := 0
        else
          Inc(FFrameNumber);
      end;
    end;
  end;
end;

function TSGConsole.Step: Integer;
begin
  Z80Interrupt(FCPU, Ord(FVDP.Interrupt));
  Result := Z80DoInstruction(FCPU, FCallbacks);
  Advance(Result);
end;

procedure TSGConsole.RunFrame;
begin
  FSampleCount := 0;
  var Frame := FFrameNumber;
  repeat
    Step
  until FFrameNumber <> Frame;
end;

procedure TSGConsole.SerializeState(State: TStateArchive);
begin
  var Region := FPAL;
  State.Field(Region, SizeOf(Region));
  if State.Loading and (Region <> FPAL) then
    raise EReadError.Create('Snapshot TV region differs from the current configuration');

  State.Field(FCPU, SizeOf(FCPU));
  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FPPI, SizeOf(FPPI));
  State.Field(FPPIControl, SizeOf(FPPIControl));
  State.Field(FHold, SizeOf(FHold));
  State.Field(FLine, SizeOf(FLine));
  State.Field(FLineCycles, SizeOf(FLineCycles));
  State.Field(FSamplePhase, SizeOf(FSamplePhase));
  State.Field(FFrameNumber, SizeOf(FFrameNumber));
  FCartridge.SerializeState(State);
  FVDP.SerializeState(State);
  FSound.SerializeState(State);

  if State.Loading then
  begin
    FSampleCount := 0;
    if (FLine < 0) or (FLine >= 262 + Ord(FPAL) * 51) or
      (FLineCycles < 0) or (FLineCycles >= 228) or
      (FSamplePhase < 0) or (FSamplePhase >= GetCPUClock) or
      (FCPU.RegisterMode > 2) or (FCPU.InterruptMode > 2) then
      raise EReadError.Create('Invalid SG-1000/SC-3000 snapshot state');
  end;
end;

initialization
  MD.Z80.ConstantInitialise;

end.

