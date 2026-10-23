unit DC.Console;

// The Dreamcast machine: owns the SH-4 and every device, decodes the
// physical address map for device accesses and runs one video field per
// RunFrame. Emulated time only advances through the scheduler.
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, HW.SH4, HW.SH4.Periph, DC.Types, DC.Memory, DC.Scheduler,
  DC.Interrupts, DC.PVR, DC.PVR.TA, DC.GDROM, DC.AICA, DC.Maple, DC.Holly, DC.Boot;

type
  TDCConsoleConfig = record
    // Empty: high-level boot. Otherwise a 2 MiB boot ROM image.
    BootROM: TBytes;
    Flash: TBytes;
    Region: TDCRegion;
    Cable: TDCCable;
    PAL: Boolean;
    RTCSeconds: Cardinal; // seconds since 1950-01-01
  end;

  TDCConsole = class
  private
    FConfig: TDCConsoleConfig;
    FFrameDone: Boolean;
    FHalted: Boolean;
    FFrameCount: Int64;
    procedure DispatchEvent(Event: TDCEvent);
    procedure Build;
  public
    Memory: TDCMemory;
    Scheduler: TDCScheduler;
    CPU: TSH4;
    Periph: TSH4Periph;
    Interrupts: TDCInterrupts;
    PVR: TDCPVR;
    TA: TDCTA;
    GDROM: TDCGDROM;
    AICA: TDCAICA;
    Maple: TDCMaple;
    Holly: TDCHolly;
    Boot: TDCBoot;
    constructor Create(const Config: TDCConsoleConfig);
    destructor Destroy; override;
    procedure Reset;
    // Loads a homebrew program (ELF or raw binary) and enters it.
    procedure LoadProgram(const Data: TBytes);
    procedure RunFrame;
    function ReadBus(Address: Cardinal; Size: Integer): UInt64;
    procedure WriteBus(Address: Cardinal; Value: UInt64; Size: Integer);
    procedure SerializeState(Archive: TStateArchive);
    property FrameCount: Int64 read FFrameCount;
    property Halted: Boolean read FHalted;
    property Config: TDCConsoleConfig read FConfig;
  end;

implementation

uses
  DC.ELF;

function BusRead(User: Pointer; Address: Cardinal; Size: Integer): UInt64;
begin
  Result := TDCConsole(User).ReadBus(Address, Size);
end;

procedure BusWrite(User: Pointer; Address: Cardinal; Value: UInt64; Size: Integer);
begin
  TDCConsole(User).WriteBus(Address, Value, Size);
end;

procedure BusBurst(User: Pointer; Address: Cardinal; Data: PCardinal; Count: Integer);
begin
  var Console := TDCConsole(User);
  if (Address shr 26) = 4 then
    Console.Holly.WriteArea4(Address, Data, Count)
  else
    for var I := 0 to Count - 1 do
      Console.WriteBus(Address + Cardinal(I) * 4, Data[I], 4);
end;

function OnChipRead(User: Pointer; Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := TDCConsole(User).Periph.Read(Address, Size);
end;

procedure OnChipWrite(User: Pointer; Address, Value: Cardinal; Size: Integer);
begin
  TDCConsole(User).Periph.Write(Address, Value, Size);
end;

procedure PeriphSchedule(User: Pointer; At: Int64);
begin
  var Console := TDCConsole(User);
  if At = SH4Never then
    Console.Scheduler.Cancel(TDCEvent.Periph)
  else
    Console.Scheduler.Schedule(TDCEvent.Periph, At);
end;

procedure IRLChanged(User: Pointer; Level: Integer);
begin
  var Console := TDCConsole(User);
  if Console.Periph <> nil then
    Console.Periph.SetIRL(Level);
end;

procedure DMACopy(User: Pointer; Source, Dest: Cardinal; UnitSize: Integer; Count: Cardinal; SourceStep, DestStep: Integer);
begin
  var Console := TDCConsole(User);
  for var I := 0 to Int64(Count) - 1 do
  begin
    var Offset := 0;
    while Offset < UnitSize do
    begin
      var Size := UnitSize - Offset;
      if Size > 4 then
        Size := 4;
      var V := Console.ReadBus(Source + Cardinal(Offset), Size);
      Console.WriteBus(Dest + Cardinal(Offset), V, Size);
      Inc(Offset, Size);
    end;
    Source := Source + Cardinal(SourceStep);
    Dest := Dest + Cardinal(DestStep);
  end;
end;

{ TDCConsole }

constructor TDCConsole.Create(const Config: TDCConsoleConfig);
begin
  inherited Create;
  FConfig := Config;
  if (Length(Config.BootROM) <> 0) and (Length(Config.BootROM) <> DCBootSize) then
    raise EArgumentException.Create('Dreamcast boot ROM must contain 2 MiB');
  if (Length(Config.Flash) <> 0) and (Length(Config.Flash) <> DCFlashSize) then
    raise EArgumentException.Create('Dreamcast flash ROM must contain 128 KiB');
  Build;
  Reset;
end;

procedure TDCConsole.Build;
begin
  Memory := TDCMemory.Create;
  Scheduler := TDCScheduler.Create;
  var Bus := Default(TSH4Bus);
  Bus.User := Self;
  Bus.Read := BusRead;
  Bus.Write := BusWrite;
  Bus.Burst := BusBurst;
  Bus.OnChipRead := OnChipRead;
  Bus.OnChipWrite := OnChipWrite;
  Bus.OnChipUser := Self;
  Bus.ReadPages := @Memory.ReadPages;
  Bus.WritePages := @Memory.WritePages;
  Bus.Gens := @Memory.Gens;
  CPU := TSH4.Create(Bus, @Scheduler.Now, @Scheduler.NextDue);
  Periph := TSH4Periph.Create(CPU, @Scheduler.Now, DMACopy, PeriphSchedule, Self);
  Interrupts := TDCInterrupts.Create(IRLChanged, Self);
  PVR := TDCPVR.Create(Memory, Scheduler, Interrupts);
  TA := TDCTA.Create(Memory, Interrupts, PVR);
  PVR.TA := TA;
  GDROM := TDCGDROM.Create(Scheduler, Interrupts);
  AICA := TDCAICA.Create(Memory, Scheduler, Interrupts);
  Maple := TDCMaple.Create(Memory);
  Holly := TDCHolly.Create(Memory, Scheduler, Interrupts, Periph, PVR, GDROM, AICA, Maple);
  Boot := TDCBoot.Create(CPU, Memory, Periph, PVR);
end;

destructor TDCConsole.Destroy;
begin
  Boot.Free;
  Holly.Free;
  Maple.Free;
  AICA.Free;
  GDROM.Free;
  TA.Free;
  PVR.Free;
  Interrupts.Free;
  Periph.Free;
  CPU.Free;
  Scheduler.Free;
  Memory.Free;
  inherited;
end;

procedure TDCConsole.Reset;
begin
  Scheduler.Reset;
  FillChar(Memory.RAM^, DCRAMSize, 0);
  FillChar(Memory.VRAM^, DCVRAMSize, 0);
  FillChar(Memory.ARAM^, DCARAMSize, 0);
  FillChar(Memory.Boot^, DCBootSize, 0);
  if Length(FConfig.BootROM) = DCBootSize then
    Move(FConfig.BootROM[0], Memory.Boot^, DCBootSize);
  if Length(FConfig.Flash) = DCFlashSize then
    Move(FConfig.Flash[0], Memory.Flash^, DCFlashSize)
  else
    FillChar(Memory.Flash^, DCFlashSize, $FF);
  for var I := 0 to High(Memory.RAMGens) do
    Inc(Memory.RAMGens[I]);
  for var I := 0 to High(Memory.VRAMGens) do
    Inc(Memory.VRAMGens[I]);
  CPU.Reset;
  Periph.Reset;
  Periph.CableType := Ord(FConfig.Cable);
  if FConfig.Cable = TDCCable.VGA then
    Periph.CableType := 0
  else if FConfig.Cable = TDCCable.RGB then
    Periph.CableType := 2
  else
    Periph.CableType := 3;
  Interrupts.Reset;
  PVR.Reset(FConfig.PAL);
  TA.Reset;
  GDROM.Reset;
  AICA.Reset(FConfig.RTCSeconds);
  Holly.Reset;
  FHalted := False;
  FFrameCount := 0;
  Boot.VGA := FConfig.Cable = TDCCable.VGA;
  Boot.PAL := FConfig.PAL;
  if Length(FConfig.BootROM) = 0 then
  begin
    // High-level boot: vectors installed, CPU waits for a program.
    CPU.SetIllegalHook(DCBootIllegalHook, Boot);
    Boot.Install;
  end
  else
    CPU.SetIllegalHook(nil, nil);
end;

procedure TDCConsole.LoadProgram(const Data: TBytes);
begin
  var Entry: Cardinal;
  if IsDCELF(Data) then
    Entry := LoadDCELF(Data, Memory)
  else
    Entry := LoadDCBinary(Data, Memory);
  CPU.InvalidateBlocks;
  Boot.EnterProgram(Entry);
end;

function TDCConsole.ReadBus(Address: Cardinal; Size: Integer): UInt64;
begin
  if Size = 8 then
  begin
    Result := ReadBus(Address, 4) or (ReadBus(Address + 4, 4) shl 32);
    Exit;
  end;
  Address := Address and $1FFFFFFF;
  Result := 0;
  case Address shr 26 of
    0:
      begin
        var A := Address and $01FFFFFF;
        if A < $00200000 then
          Result := PCardinal(Memory.Boot + (A and $1FFFFC))^ shr ((A and 3) * 8)
        else if A < $00220000 then
          Result := PCardinal(Memory.Flash + (A and $1FFFC))^ shr ((A and 3) * 8)
        else if (A >= $005F7000) and (A < $005F7100) then
          Result := GDROM.Read(A - $005F7000, Size)
        else if (A >= $005F6800) and (A < $005F8000) then
          Result := Holly.Read(A, Size)
        else if (A >= $005F8000) and (A < $005FA000) then
          Result := PVR.ReadRegister(A - $005F8000) shr ((A and 3) * 8)
        else if (A >= $00700000) and (A < $00708000) then
          Result := AICA.ReadRegister(A - $00700000, Size)
        else if (A >= $00710000) and (A < $00710010) then
          Result := AICA.ReadRTC(A - $00710000)
        else if (A >= $00800000) and (A < $01000000) then
          Result := AICA.ReadRAM(A - $00800000, Size);
      end;
    1:
      if (Address and $01000000) = 0 then
        Result := Memory.VRAMRead64Path(Address and $7FFFFF, Size)
      else
      begin
        var A := Address and $7FFFFF;
        case Size of
          1: Result := Memory.VRAM[A];
          2: Result := PWord(Memory.VRAM + (A and $7FFFFE))^;
        else
          Result := PCardinal(Memory.VRAM + (A and $7FFFFC))^;
        end;
      end;
    3:
      begin
        var A := Address and (DCRAMSize - 1);
        case Size of
          1: Result := Memory.RAM[A];
          2: Result := PWord(Memory.RAM + (A and not Cardinal(1)))^;
        else
          Result := PCardinal(Memory.RAM + (A and not Cardinal(3)))^;
        end;
      end;
    4:
      Result := Holly.ReadArea4(Address, Size);
  end;
  case Size of
    1: Result := Result and $FF;
    2: Result := Result and $FFFF;
    4: Result := Result and $FFFFFFFF;
  end;
end;

procedure TDCConsole.WriteBus(Address: Cardinal; Value: UInt64; Size: Integer);
begin
  if Size = 8 then
  begin
    if (Address shr 26) and 7 = 4 then
    begin
      var Words: array[0..1] of Cardinal;
      Words[0] := Cardinal(Value);
      Words[1] := Cardinal(Value shr 32);
      Holly.WriteArea4(Address, @Words[0], 2);
      Exit;
    end;
    WriteBus(Address, Cardinal(Value), 4);
    WriteBus(Address + 4, Cardinal(Value shr 32), 4);
    Exit;
  end;
  Address := Address and $1FFFFFFF;
  case Address shr 26 of
    0:
      begin
        var A := Address and $01FFFFFF;
        if (A >= $005F7000) and (A < $005F7100) then
          GDROM.Write(A - $005F7000, Cardinal(Value), Size)
        else if (A >= $005F6800) and (A < $005F8000) then
          Holly.Write(A, Cardinal(Value), Size)
        else if (A >= $005F8000) and (A < $005FA000) then
          PVR.WriteRegister(A - $005F8000, Cardinal(Value))
        else if (A >= $00700000) and (A < $00708000) then
          AICA.WriteRegister(A - $00700000, Cardinal(Value), Size)
        else if (A >= $00710000) and (A < $00710010) then
          AICA.WriteRTC(A - $00710000, Cardinal(Value))
        else if (A >= $00800000) and (A < $01000000) then
          AICA.WriteRAM(A - $00800000, Cardinal(Value), Size);
      end;
    1:
      if (Address and $01000000) = 0 then
        Memory.VRAMWrite64Path(Address and $7FFFFF, Value, Size)
      else
      begin
        var A := Address and $7FFFFF;
        case Size of
          1: Memory.VRAM[A] := Byte(Value);
          2: PWord(Memory.VRAM + (A and $7FFFFE))^ := Word(Value);
        else
          PCardinal(Memory.VRAM + (A and $7FFFFC))^ := Cardinal(Value);
        end;
        Memory.TouchVRAM(A, Size);
      end;
    3:
      begin
        var A := Address and (DCRAMSize - 1);
        case Size of
          1: Memory.RAM[A] := Byte(Value);
          2: PWord(Memory.RAM + (A and not Cardinal(1)))^ := Word(Value);
        else
          PCardinal(Memory.RAM + (A and not Cardinal(3)))^ := Cardinal(Value);
        end;
        Inc(Memory.RAMGens[A shr 12]);
      end;
    4:
      begin
        var Word_ := Cardinal(Value);
        Holly.WriteArea4(Address, @Word_, 1);
      end;
  end;
end;

procedure TDCConsole.DispatchEvent(Event: TDCEvent);
begin
  case Event of
    TDCEvent.Periph:
      Periph.Update;
    TDCEvent.SPGLine:
      begin
        var Before := PVR.VBlankCount;
        PVR.LineEvent;
        if PVR.VBlankCount <> Before then
        begin
          Inc(FFrameCount);
          FFrameDone := True;
          Holly.VBlank;
        end;
      end;
    TDCEvent.Render:
      ;
    TDCEvent.Ch2DMA, TDCEvent.SortDMA, TDCEvent.PVRDMA, TDCEvent.MapleDMA, TDCEvent.GDDMA, TDCEvent.G2DMA:
      Holly.Event(Event);
    TDCEvent.GDROM:
      GDROM.Event;
    TDCEvent.AICA:
      AICA.Event;
  end;
end;

procedure TDCConsole.RunFrame;
begin
  FFrameDone := False;
  var Guard := 0;
  repeat
    if Scheduler.NextDue > Scheduler.Now then
      CPU.Run;
    var Event: TDCEvent;
    var At: Int64;
    while Scheduler.TakeDue(Event, At) do
      DispatchEvent(Event);
    if Boot.TakeRequest = TDCBootRequest.ExitToMenu then
      FHalted := True;
    Inc(Guard);
  until FFrameDone or FHalted or (Guard > 10000000);
end;

procedure TDCConsole.SerializeState(Archive: TStateArchive);
begin
  Scheduler.SerializeState(Archive);
  Memory.SerializeState(Archive);
  CPU.SerializeState(Archive);
  Periph.SerializeState(Archive);
  Interrupts.SerializeState(Archive);
  PVR.SerializeState(Archive);
  GDROM.SerializeState(Archive);
  AICA.SerializeState(Archive);
  Maple.SerializeState(Archive);
  Holly.SerializeState(Archive);
  Archive.Field(FFrameCount, SizeOf(FFrameCount));
  Archive.Field(FHalted, SizeOf(FHalted));
end;

end.
