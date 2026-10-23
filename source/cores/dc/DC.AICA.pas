unit DC.AICA;

// AICA in the console: 2 MiB wave RAM shared with the ARM7DI, the sound
// generator/DSP (DC.Sound.AICA, also used by the DSF player), the ARM reset
// control, SH-4 interrupt lines through G2 and the RTC. The ARM and sample
// generator run lazily up to the scheduler clock whenever the SH-4 touches
// AICA state, and at least every 16 samples.
// References: Neill Corlett's AICA notes, KallistiOS g2/spu sources.
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Math, Core.Snapshots, DC.Types, DC.Memory, DC.Scheduler, DC.Interrupts,
  DC.CPU.ARM7, DC.Sound.AICA, DC.GDROM;

const
  AICASampleRate = 44100;
  AICACyclesPerSample = 128; // ARM clocks per output sample, as in the DSF player
  AICAStepSamples = 16;

type
  TDCAICAState = record
    Clock: Int64;          // SH-4 clock of the last generated sample boundary
    Fraction: Int64;       // SH-4 clocks * 44100 accumulated remainder
    Debt: Integer;         // ARM clocks owed
    ARMReset: Boolean;
    RTC: Cardinal;         // seconds since 1950-01-01
    RTCWritable: Boolean;
    RTCSubsecond: Int64;   // SH-4 clocks into the current RTC second
    // SH-4 side interrupt enable/pending (MCIEB/MCIPD).
    MCIEB, MCIPD: Cardinal;
  end;

  TDCAICA = class
  private
    FMemory: TDCMemory;
    FScheduler: TDCScheduler;
    FInterrupts: TDCInterrupts;
    FAICA: TAICA;
    FARM: TARM7;
    FSamples: TArray<SmallInt>;
    FSampleCount: Integer;
    function SoundRead(Address: Cardinal): Byte;
    procedure SoundWrite(Address: Cardinal; Value: Byte);
    function ARMRead(Address: Cardinal; Size: Integer): Cardinal;
    procedure ARMWrite(Address, Value: Cardinal; Size: Integer);
    procedure GenerateSample;
    procedure UpdateSH4Interrupt;
  public
    S: TDCAICAState;
    // CD-DA source mixed into the output (not owned).
    GDROM: TDCGDROM;
    constructor Create(Memory: TDCMemory; Scheduler: TDCScheduler; Interrupts: TDCInterrupts);
    destructor Destroy; override;
    procedure Reset(RTCSeconds: Cardinal);
    // Generates samples up to the scheduler clock.
    procedure Sync;
    procedure Event;
    function ReadRegister(Offset: Cardinal; Size: Integer): Cardinal;
    procedure WriteRegister(Offset, Value: Cardinal; Size: Integer);
    function ReadRAM(Offset: Cardinal; Size: Integer): Cardinal;
    procedure WriteRAM(Offset, Value: Cardinal; Size: Integer);
    function ReadRTC(Offset: Cardinal): Cardinal;
    procedure WriteRTC(Offset, Value: Cardinal);
    // Stereo samples generated since the last call.
    function TakeSamples: TArray<SmallInt>;
    procedure SerializeState(Archive: TStateArchive);
  end;

implementation

const
  RegARMReset = $2C00;
  RegMCIEB = $28B4;
  RegMCIPD = $28B8;
  RegMCIRE = $28BC;

constructor TDCAICA.Create(Memory: TDCMemory; Scheduler: TDCScheduler; Interrupts: TDCInterrupts);
begin
  inherited Create;
  FMemory := Memory;
  FScheduler := Scheduler;
  FInterrupts := Interrupts;
  FAICA := TAICA.Create(SoundRead, SoundWrite);
  FARM := TARM7.Create(ARMRead, ARMWrite);
  Reset(0);
end;

destructor TDCAICA.Destroy;
begin
  FARM.Free;
  FAICA.Free;
  inherited;
end;

procedure TDCAICA.Reset(RTCSeconds: Cardinal);
begin
  FAICA.Reset;
  FARM.Reset;
  S := Default(TDCAICAState);
  S.Clock := FScheduler.Now;
  S.ARMReset := True;
  S.RTC := RTCSeconds;
  FSampleCount := 0;
  FScheduler.Schedule(TDCEvent.AICA, FScheduler.Now + Int64(AICAStepSamples) * DCCPUClock div AICASampleRate);
end;

function TDCAICA.SoundRead(Address: Cardinal): Byte;
begin
  Result := FMemory.ARAM[Address and (DCARAMSize - 1)];
end;

procedure TDCAICA.SoundWrite(Address: Cardinal; Value: Byte);
begin
  FMemory.ARAM[Address and (DCARAMSize - 1)] := Value;
end;

function TDCAICA.ARMRead(Address: Cardinal; Size: Integer): Cardinal;
begin
  // ARM7 view: wave RAM at 000000, registers at 800000.
  var Rotate := 0;
  if Size = 4 then
  begin
    Rotate := Integer(Address and 3) * 8;
    Address := Address and $FFFFFFFC;
  end;
  Result := 0;
  for var I := 0 to Size - 1 do
  begin
    var A := (Address + Cardinal(I)) and $FFFFFF;
    var V: Byte;
    if A < $800000 then
      V := FMemory.ARAM[A and (DCARAMSize - 1)]
    else if A < $808000 then
      V := FAICA.ReadRegister(A - $800000)
    else
      V := 0;
    Result := Result or (Cardinal(V) shl (I * 8));
  end;
  if Rotate <> 0 then
    Result := (Result shr Rotate) or (Result shl (32 - Rotate));
end;

procedure TDCAICA.ARMWrite(Address, Value: Cardinal; Size: Integer);
begin
  if Size = 4 then
    Address := Address and $FFFFFFFC;
  for var I := 0 to Size - 1 do
  begin
    var A := (Address + Cardinal(I)) and $FFFFFF;
    var V := Byte(Value shr (I * 8));
    if A < $800000 then
      FMemory.ARAM[A and (DCARAMSize - 1)] := V
    else if A < $808000 then
      FAICA.WriteRegister(A - $800000, V);
  end;
end;

procedure TDCAICA.GenerateSample;
begin
  if not S.ARMReset then
  begin
    Inc(S.Debt, AICACyclesPerSample);
    while S.Debt > 0 do
      Dec(S.Debt, FARM.Step(FAICA.FIQ));
  end;
  var L, R: SmallInt;
  FAICA.Sample(L, R);
  if GDROM <> nil then
  begin
    var CL, CR: SmallInt;
    GDROM.NextSample(CL, CR);
    L := SmallInt(EnsureRange(Integer(L) + CL, -32768, 32767));
    R := SmallInt(EnsureRange(Integer(R) + CR, -32768, 32767));
  end;
  if FSampleCount + 2 > Length(FSamples) then
    SetLength(FSamples, FSampleCount * 2 + 4096);
  FSamples[FSampleCount] := L;
  FSamples[FSampleCount + 1] := R;
  Inc(FSampleCount, 2);
end;

procedure TDCAICA.Sync;
begin
  // Samples fall on exact multiples of CPUClock/44100 since S.Clock.
  var Elapsed := FScheduler.Now - S.Clock;
  if Elapsed <= 0 then
    Exit;
  var Total := S.Fraction + Elapsed * AICASampleRate;
  var Count := Total div DCCPUClock;
  S.Fraction := Total mod DCCPUClock;
  S.Clock := FScheduler.Now;
  for var I := 1 to Count do
    GenerateSample;
  // RTC seconds.
  Inc(S.RTCSubsecond, Elapsed);
  while S.RTCSubsecond >= DCCPUClock do
  begin
    Dec(S.RTCSubsecond, DCCPUClock);
    Inc(S.RTC);
  end;
  UpdateSH4Interrupt;
end;

procedure TDCAICA.Event;
begin
  Sync;
  FScheduler.Schedule(TDCEvent.AICA, FScheduler.Now + Int64(AICAStepSamples) * DCCPUClock div AICASampleRate);
end;

procedure TDCAICA.UpdateSH4Interrupt;
begin
  FInterrupts.SetExternal(HollyExtAICA, (S.MCIEB and S.MCIPD) <> 0);
end;

function TDCAICA.ReadRegister(Offset: Cardinal; Size: Integer): Cardinal;
begin
  Sync;
  Offset := Offset and $7FFF;
  Result := 0;
  for var I := 0 to Size - 1 do
  begin
    var A := (Offset + Cardinal(I)) and $7FFF;
    var V: Cardinal;
    case A and $7FFE of
      RegARMReset:
        V := (Cardinal(Ord(S.ARMReset)) shr ((A and 1) * 8)) and $FF;
      RegMCIEB:
        V := (S.MCIEB shr ((A and 1) * 8)) and $FF;
      RegMCIPD:
        V := (S.MCIPD shr ((A and 1) * 8)) and $FF;
    else
      V := FAICA.ReadRegister(A);
    end;
    Result := Result or (V shl (I * 8));
  end;
end;

procedure TDCAICA.WriteRegister(Offset, Value: Cardinal; Size: Integer);
begin
  Sync;
  Offset := Offset and $7FFF;
  for var I := 0 to Size - 1 do
  begin
    var A := (Offset + Cardinal(I)) and $7FFF;
    var V := Byte(Value shr (I * 8));
    case A of
      RegARMReset:
        begin
          var Hold := (V and 1) <> 0;
          if S.ARMReset and not Hold then
          begin
            FARM.Reset;
            S.Debt := 0;
          end;
          S.ARMReset := Hold;
        end;
      RegARMReset + 1:
        ;
      RegMCIEB, RegMCIEB + 1:
        begin
          var Shift := (A and 1) * 8;
          S.MCIEB := (S.MCIEB and not ($FF shl Shift)) or (Cardinal(V) shl Shift);
          S.MCIEB := S.MCIEB and $7FF;
        end;
      RegMCIPD, RegMCIPD + 1:
        begin
          // Writing bit 5 raises the SH-4 interrupt from the SH-4 side.
          var Shift := (A and 1) * 8;
          S.MCIPD := S.MCIPD or ((Cardinal(V) shl Shift) and $20);
        end;
      RegMCIRE, RegMCIRE + 1:
        begin
          var Shift := (A and 1) * 8;
          S.MCIPD := S.MCIPD and not (Cardinal(V) shl Shift);
        end;
    else
      FAICA.WriteRegister(A, V);
    end;
  end;
  UpdateSH4Interrupt;
end;

function TDCAICA.ReadRAM(Offset: Cardinal; Size: Integer): Cardinal;
begin
  Sync;
  Offset := Offset and (DCARAMSize - 1);
  case Size of
    1: Result := FMemory.ARAM[Offset];
    2: Result := PWord(FMemory.ARAM + (Offset and not Cardinal(1)))^;
  else
    Result := PCardinal(FMemory.ARAM + (Offset and not Cardinal(3)))^;
  end;
end;

procedure TDCAICA.WriteRAM(Offset, Value: Cardinal; Size: Integer);
begin
  Sync;
  Offset := Offset and (DCARAMSize - 1);
  case Size of
    1: FMemory.ARAM[Offset] := Byte(Value);
    2: PWord(FMemory.ARAM + (Offset and not Cardinal(1)))^ := Word(Value);
  else
    PCardinal(FMemory.ARAM + (Offset and not Cardinal(3)))^ := Value;
  end;
end;

function TDCAICA.ReadRTC(Offset: Cardinal): Cardinal;
begin
  Sync;
  case Offset and $C of
    0: Result := S.RTC shr 16;
    4: Result := S.RTC and $FFFF;
  else
    Result := 0;
  end;
end;

procedure TDCAICA.WriteRTC(Offset, Value: Cardinal);
begin
  Sync;
  case Offset and $C of
    0:
      if S.RTCWritable then
        S.RTC := (S.RTC and $FFFF) or ((Value and $FFFF) shl 16);
    4:
      if S.RTCWritable then
      begin
        S.RTC := (S.RTC and $FFFF0000) or (Value and $FFFF);
        S.RTCSubsecond := 0;
        S.RTCWritable := False;
      end;
    8:
      S.RTCWritable := (Value and 1) <> 0;
  end;
end;

function TDCAICA.TakeSamples: TArray<SmallInt>;
begin
  Result := Copy(FSamples, 0, FSampleCount);
  FSampleCount := 0;
end;

procedure TDCAICA.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(S, SizeOf(S));
  // ARM and sound generator registers: through their public state.
  Archive.Field(FARM.R, SizeOf(FARM.R));
  Archive.Field(FARM.PSR, SizeOf(FARM.PSR));
  Archive.Field(FARM.SPSR, SizeOf(FARM.SPSR));
  FAICA.SerializeState(Archive);
  FARM.SerializeBanks(Archive);
end;

end.
