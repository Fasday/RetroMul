unit Saturn.Console;

interface

uses
  System.SysUtils, System.Classes, System.UITypes, HW.SH2, HW.SH7604, MD.M68k,
  Saturn.SCU, Saturn.SMPC, Saturn.VDP1, Saturn.VDP2, Core.Snapshots,
  Core.CD.Disc, Saturn.CD, Saturn.SCSP, Saturn.Cartridge;

type
  TSaturnBusObserver = reference to procedure(Address, Value: Cardinal; Size: Integer);

  TSaturnInstructionObserver = reference to procedure(CPU: Integer; const State: TSH2State);

  TSaturnConsole = class
  private
    type
      TPort = record
        Owner: TSaturnConsole;
        Index: Integer;
      end;

      PPort = ^TPort;
  private
    FBIOS: TBytes;
    FWorkLow, FWorkHigh: array[0..$FFFFF] of Byte;
    FBackup: array[0..$7FFF] of Byte;
    FSound: array[0..$7FFFF] of Byte;
    FSoundRegisters: array[0..$FFF] of Byte;
    FSoundCPU: TM68kState;
    FSoundCallbacks: TM68kReadWriteCallbacks;
    FSoundAt, FSamplePhase: Int64;
    FSoundFraction: Int64;
    FTimerPhase: array[0..2] of Integer;
    FSoundDMAActive: Boolean;
    FSoundDMANext: Int64;
    FSoundDMAMemory, FSoundDMARegister: Cardinal;
    FSoundDMACount: Integer;
    FSoundDMAControl: Word;
    FSoundPending, FMainSoundPending: Word;
    procedure SoundTick;
    procedure SoundIRQ;
    procedure SoundRegisterWrite(Address: Cardinal; Value: Byte);
    function SoundRegisterRead(Address: Cardinal): Byte;
  private
    FCPU: array[0..1] of TSH7604;
    FPort: array[0..1] of TPort;
    FSCU: TSaturnSCU;
    FSMPC: TSaturnSMPC;
    FVDP1: TSaturnVDP1;
    FVDP2: TSaturnVDP2;
    FCPUTime: array[0..1] of Int64;
    FTime, FNextRaster, FLineStart: Int64;
    FRasterPhase: Integer;
    FLine, FClock: Integer;
    FHBlank, FSlaveOn, FSoundOn, FResetPending, FPAL: Boolean;
    FFrames: UInt64;
    FPixels: TArray<TAlphaColor>;
    FFrameWidth, FFrameHeight: Integer;
    FCD: TSaturnCD;
    FSCSP: TSaturnSCSP;
    FCartridge: TSaturnCartridge;
    FSamples: TArray<SmallInt>;
    FSampleFrames: Integer;
    procedure CDIRQ(Active: Boolean);
    function SoundRAMRead(Address: Cardinal): Byte;
    procedure SoundRAMWrite(Address: Cardinal; Value: Byte);
    procedure SoundDMA(Target: Int64);
  private
    FBusUntil: Int64;
    FIRQLevel, FIRQVector: Integer;
    FBackupDirty: Boolean;
    FBusObserver: TSaturnBusObserver;
    FInstructionObserver: TSaturnInstructionObserver;
    procedure RasterEvent;
    procedure AdvanceDevices(Target: Int64);
    procedure SCUIRQ(Level, Vector: Integer);
    procedure SMPCCommand(Command: Byte);
    procedure SMPCIRQ;
    procedure DrawIRQ;
    function ReadByte(Address: Cardinal): Byte;
    procedure WriteByte(Address: Cardinal; Value: Byte);
    function Wait(CPU: Integer; Address: Cardinal; Size: Integer; Writing: Boolean): Integer;
    function ReserveDMA(At: Int64; Address: Cardinal; Size: Integer; Writing: Boolean): Int64;
    function DMAReady(Address: Cardinal; Size: Integer; Writing: Boolean): Boolean;
  public
    constructor Create(const BIOS: TBytes; Region: Byte = 4; PAL: Boolean = False; Disc: TCDDisc = nil; RAMCart: Integer = 0; const CartROM: TBytes = nil);
    destructor Destroy; override;
    procedure Reset;
    function ReadBus(Address: Cardinal; Size: Integer): Cardinal;
    procedure WriteBus(Address, Value: Cardinal; Size: Integer);
    function ReadCPU(CPU: Integer; Address: Cardinal; Size: Integer): Cardinal;
    procedure WriteCPU(CPU: Integer; Address, Value: Cardinal; Size: Integer);
    function CPUState(CPU: Integer): TSH2State;
    procedure SetCPUState(CPU: Integer; const State: TSH2State);
    procedure RunCycles(Cycles: Int64);
    procedure RunFrame;
    procedure SetInput(Port: Integer; Buttons: TSaturnButtons; Connected: Boolean = True);
    procedure LoadBackup(const Data: TBytes);
    function Backup: TBytes;
    function FramesPerSecond: Double;
    procedure SerializeState(Archive: TStateArchive);
    property SoundState: TM68kState read FSoundCPU;
    property SoundOn: Boolean read FSoundOn;
    property CD: TSaturnCD read FCD;
    property SCSP: TSaturnSCSP read FSCSP;
    property Cartridge: TSaturnCartridge read FCartridge;
    property Samples: TArray<SmallInt> read FSamples;
    property SampleFrames: Integer read FSampleFrames;
    property VDP1: TSaturnVDP1 read FVDP1;
    property VDP2: TSaturnVDP2 read FVDP2;
    property SCU: TSaturnSCU read FSCU;
    property SMPC: TSaturnSMPC read FSMPC;
    property Pixels: TArray<TAlphaColor> read FPixels;
    property FrameWidth: Integer read FFrameWidth;
    property FrameHeight: Integer read FFrameHeight;
    property FrameNumber: UInt64 read FFrames;
    property Time: Int64 read FTime;
    property SlaveOn: Boolean read FSlaveOn;
    property BackupDirty: Boolean read FBackupDirty write FBackupDirty;
    property InstructionObserver: TSaturnInstructionObserver read FInstructionObserver write FInstructionObserver;
    property BusObserver: TSaturnBusObserver read FBusObserver write FBusObserver;
  end;

implementation

uses
  System.Math, System.Hash;
{$Q+}{$R+}

function CPURead(User: Pointer; Address: Cardinal; Size: Integer): Cardinal;
begin
  var Port := TSaturnConsole.PPort(User)^;
  Result := Port.Owner.ReadBus(Address, Size);
end;

procedure CPUWrite(User: Pointer; Address, Value: Cardinal; Size: Integer);
begin
  var Port := TSaturnConsole.PPort(User)^;
  Port.Owner.WriteBus(Address, Value, Size);
end;

function CPUWait(User: Pointer; Address: Cardinal; Size: Integer; Writing: Boolean): Integer;
begin
  var Port := TSaturnConsole.PPort(User)^;
  Result := Port.Owner.Wait(Port.Index, Address, Size, Writing);
end;

function CPUDMAReserve(User: Pointer; At: Int64; Address: Cardinal; Size: Integer; Writing: Boolean): Int64;
begin
  var Port := TSaturnConsole.PPort(User)^;
  Result := Port.Owner.ReserveDMA(At, Address, Size, Writing);
end;

function CPUDMAReady(User: Pointer; Address: Cardinal; Size: Integer; Writing: Boolean): Boolean;
begin
  var Port := TSaturnConsole.PPort(User)^;
  Result := Port.Owner.DMAReady(Address, Size, Writing);
end;

function SoundRead(User: Pointer; Address: Cardinal; Hi, Lo: Byte; Cycle: Cardinal; var Early: Byte): Cardinal;
begin
  var Board := TSaturnConsole(User);
  var A: Cardinal := (Address * 2) and $FFFFFF;
  Result := $FFFF;
  if A < $100000 then
    Result := Board.ReadBus($05A00000 + (A and $7FFFF), 2)
  else if (A >= $100000) and (A < $101000) then
    Result := Board.ReadBus($05B00000 + (A and $FFF), 2);
end;

procedure SoundWrite(User: Pointer; Address: Cardinal; Hi, Lo: Byte; Cycle: Cardinal; var Early: Byte; Value: Cardinal);
begin
  var Board := TSaturnConsole(User);
  var A: Cardinal := (Address * 2) and $FFFFFF;
  if A < $100000 then
    A := $05A00000 + (A and $7FFFF)
  else if (A >= $100000) and (A < $101000) then
    A := $05B00000 + (A and $FFF)
  else
    Exit;
  if Hi <> 0 then
    Board.WriteBus(A, (Value shr 8) and $FF, 1);
  if Lo <> 0 then
    Board.WriteBus(A + 1, Value and $FF, 1);
end;

procedure SoundAck(User: Pointer);
begin
  TSaturnConsole(User).SoundIRQ;
end;

function SCURead(User: Pointer; Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := TSaturnConsole(User).ReadBus(Address, Size);
end;

procedure SCUWrite(User: Pointer; Address, Value: Cardinal; Size: Integer);
begin
  TSaturnConsole(User).WriteBus(Address, Value, Size);
end;

constructor TSaturnConsole.Create(const BIOS: TBytes; Region: Byte; PAL: Boolean; Disc: TCDDisc; RAMCart: Integer; const CartROM: TBytes);
begin
  inherited Create;
  if Length(BIOS) <> $80000 then
    raise EReadError.Create('Saturn BIOS must contain exactly 512 KiB');
  FBIOS := Copy(BIOS);
  FPAL := PAL;
  FSoundCallbacks.UserData := Self;
  FSoundCallbacks.ReadCallback := SoundRead;
  FSoundCallbacks.WriteCallback := SoundWrite;
  FSoundCallbacks.InterruptAcknowledgeCallback := SoundAck;
  for var I := 0 to 1 do
  begin
    FPort[I].Owner := Self;
    FPort[I].Index := I;
    FCPU[I] := TSH7604.Create(CPURead, CPUWrite, @FPort[I], CPUWait, I = 1);
  end;
  for var I := 0 to 1 do
  begin
    FCPU[I].ReserveDMA := CPUDMAReserve;
    FCPU[I].DMAReady := CPUDMAReady;
  end;
  FSCU := TSaturnSCU.Create(SCURead, SCUWrite, Self, SCUIRQ);
  FSCU.Reserve := ReserveDMA;
  FSCU.Ready := DMAReady;
  FSMPC := TSaturnSMPC.Create(Region, SMPCCommand, SMPCIRQ);
  FVDP1 := TSaturnVDP1.Create(DrawIRQ);
  FVDP2 := TSaturnVDP2.Create(PAL);
  FCD := TSaturnCD.Create(Disc, CDIRQ);
  FSCSP := TSaturnSCSP.Create(SoundRAMRead, SoundRAMWrite);
  FCartridge := TSaturnCartridge.Create(RAMCart, CartROM);
  SetLength(FSamples, 8192);
  // New backup RAM has the BIOS format signature and free block headers.
  FillChar(FBackup, SizeOf(FBackup), 0);
  var Header: AnsiString := 'BackUpRam Format';
  for var RepeatIndex := 0 to 3 do
    Move(Header[1], FBackup[RepeatIndex * 16], 16);
  Reset;
end;

destructor TSaturnConsole.Destroy;
begin
  FCartridge.Free;
  FSCSP.Free;
  FCD.Free;
  FCPU[0].Free;
  FCPU[1].Free;
  FVDP1.Free;
  FVDP2.Free;
  FSMPC.Free;
  FSCU.Free;
  inherited;
end;

procedure TSaturnConsole.Reset;
begin
  FillChar(FWorkLow, SizeOf(FWorkLow), 0);
  FillChar(FWorkHigh, SizeOf(FWorkHigh), 0);
  FillChar(FSound, SizeOf(FSound), 0);
  FillChar(FSoundRegisters, SizeOf(FSoundRegisters), 0);
  FSoundCPU := Default(TM68kState);
  FSoundAt := 0;
  FSoundFraction := 0;
  FSamplePhase := 0;
  FSoundDMAActive := False;
  FSoundDMANext := 0;
  FSoundDMAMemory := 0;
  FSoundDMARegister := 0;
  FSoundDMACount := 0;
  FSoundDMAControl := 0;
  FillChar(FTimerPhase, SizeOf(FTimerPhase), 0);
  FSoundPending := 0;
  FMainSoundPending := 0;
  FTime := 0;
  FBusUntil := 0;
  FFrames := 0;
  FSlaveOn := False;
  FSoundOn := False;
  FResetPending := False;
  FCPUTime[0] := 0;
  FCPUTime[1] := 0;
  FLine := 0;
  FHBlank := False;
  FClock := 26846587;
  if FPAL then
    FClock := 26656400;
  FIRQLevel := 0;
  FIRQVector := 0;
  FSCU.Reset;
  FSMPC.Reset;
  FSMPC.SetClock(FClock);
  FVDP1.Reset;
  FVDP2.Reset;
  FCPU[0].Reset;
  FCPU[1].Reset;
  FCD.Reset(FClock);
  FSCSP.Reset;
  FSampleFrames := 0;
  FCartridge.Reset;
  FFrameWidth := 320;
  FFrameHeight := 224;
  SetLength(FPixels, FFrameWidth * FFrameHeight);
  FLineStart := 0;
  FRasterPhase := 0;
  FNextRaster := 1280;
end;

procedure TSaturnConsole.SCUIRQ(Level, Vector: Integer);
begin
  FIRQLevel := Level;
  FIRQVector := Vector;
  if FCPU[0] <> nil then
    FCPU[0].Interrupt(Level, Vector);
end;

procedure TSaturnConsole.SMPCIRQ;
begin
  FSCU.Signal(7);
end;

procedure TSaturnConsole.DrawIRQ;
begin
  FSCU.Signal(13);
end;

procedure TSaturnConsole.SMPCCommand(Command: Byte);
begin
  case Command of
    $02:
      begin
        FCPU[1].Reset;
        FCPUTime[1] := FTime;
        FCPU[1].Advance(FTime);
        FSlaveOn := True;
      end;
    $03:
      FSlaveOn := False;
    $06:
      begin
        Clown68000Reset(FSoundCPU, FSoundCallbacks);
        FSoundAt := FTime;
        FSoundOn := True;
      end;
    $07:
      FSoundOn := False;
    $08:
      FCD.SetPower(True, FTime);
    $09:
      FCD.SetPower(False, FTime);
    $0D:
      FResetPending := True;
    $0E, $0F:
      begin
        var OldClock := FClock;
        FClock := 26846587;
        if FPAL then
          FClock := 26656400;
        if Command = $0E then
        begin
          FClock := 28636360;
          if FPAL then
            FClock := 28437500;
        end;
        FSamplePhase := FSamplePhase * FClock div OldClock;
        FSMPC.SetClock(FClock);
        FCD.SetClock(FClock);
        FSlaveOn := False;
        FSoundOn := False;
      // The boot ROM clock-change contract resets these LSIs, retaining the
      // CD block and work RAM. Sound RAM remains backed by its own DRAM.
        FSCU.Reset;
        FSCSP.Reset;
        FVDP1.Reset;
        FVDP2.Reset;
        FillChar(FSoundRegisters, SizeOf(FSoundRegisters), 0);
        FillChar(FTimerPhase, SizeOf(FTimerPhase), 0);
        FSoundPending := 0;
        FMainSoundPending := 0;
        FSoundFraction := 0;
        FLine := 0;
        FHBlank := False;
        FRasterPhase := 0;
        FLineStart := FTime;
        FNextRaster := FTime + 1280;
        if FSMPC.Clock352 then
          FNextRaster := FTime + 1408;
        FSoundDMAActive := False;
        FFrameWidth := 320;
        FFrameHeight := 224;
        SetLength(FPixels, FFrameWidth * FFrameHeight);
        FCPU[0].NMI;
      end;
    $18:
      FCPU[0].NMI;
  end;
end;

function TSaturnConsole.SoundRegisterRead(Address: Cardinal): Byte;
begin
  var A: Integer := Address and $FFF;
  if (A < $400) or (A >= $600) or ((A >= $400) and (A <= $403)) or (A = $408) or (A = $409) then
    Exit(FSCSP.ReadRegister(A));
  case A of
    $404:
      Result := $09; // MIDI input empty, output FIFO empty
      $420:
      Result := FSoundPending shr 8;
    $421:
      Result := FSoundPending and $FF;
    $42C:
      Result := FMainSoundPending shr 8;
    $42D:
      Result := FMainSoundPending and $FF;
  else
    Result := FSoundRegisters[A];
  end;
end;

procedure TSaturnConsole.SoundIRQ;
begin
  var Enable: Word := (Word(FSoundRegisters[$41E]) shl 8) or FSoundRegisters[$41F];
  var Pending := FSoundPending and Enable;
  var Level: Integer := 0;
  for var I := 0 to 10 do
    if Pending and (1 shl I) <> 0 then
    begin
      var B := Min(I, 7);
      Level := Ord(FSoundRegisters[$425] and (1 shl B) <> 0) or (Ord(FSoundRegisters[$427] and (1 shl B) <> 0) shl 1) or (Ord(FSoundRegisters[$429] and (1 shl B) <> 0) shl 2);
      Break;
    end;
  Clown68000Interrupt(FSoundCPU, Level);
  Enable := (Word(FSoundRegisters[$42A]) shl 8) or FSoundRegisters[$42B];
  if FMainSoundPending and Enable <> 0 then
    FSCU.Signal(6);
end;

procedure TSaturnConsole.SoundRegisterWrite(Address: Cardinal; Value: Byte);
begin
  var A: Integer := Address and $FFF;
  FSoundRegisters[A] := Value;
  FSCSP.WriteRegister(A, Value);
  case A of
    $421:
      FSoundPending := FSoundPending or (Value and $20);
    $423:
      FSoundPending := FSoundPending and not ((Word(FSoundRegisters[$422]) shl 8) or Value);
    $42D:
      FMainSoundPending := FMainSoundPending or (Value and $20);
    $42F:
      FMainSoundPending := FMainSoundPending and not ((Word(FSoundRegisters[$42E]) shl 8) or Value);
  end;
  if (A >= $41E) and (A <= $42F) then
    SoundIRQ;
end;

procedure TSaturnConsole.SoundTick;
begin
  var CDLeft, CDRight: Integer;
  var Left, Right: SmallInt;
  FCD.AudioSample(CDLeft, CDRight);
  FSCSP.Sample(CDLeft, CDRight, Left, Right);
  if FSampleFrames < 4096 then
  begin
    FSamples[FSampleFrames * 2] := Left;
    FSamples[FSampleFrames * 2 + 1] := Right;
    Inc(FSampleFrames);
  end;
  for var T := 0 to 2 do
  begin
    var A: Integer := $418 + T * 2;
    var Divider: Integer := 1 shl (FSoundRegisters[A] and 7);
    Inc(FTimerPhase[T]);
    if FTimerPhase[T] >= Divider then
    begin
      FTimerPhase[T] := 0;
      FSoundRegisters[A + 1] := Byte((Integer(FSoundRegisters[A + 1]) + 1) and $FF);
      if FSoundRegisters[A + 1] = 0 then
      begin
        FSoundPending := FSoundPending or (Word(1) shl (6 + T));
        FMainSoundPending := FMainSoundPending or (Word(1) shl (6 + T));
      end;
    end;
  end;
  SoundIRQ;
end;

procedure TSaturnConsole.CDIRQ(Active: Boolean);
begin
  FSCU.SetExternal(0, Active);
end;

function TSaturnConsole.SoundRAMRead(Address: Cardinal): Byte;
begin
  Result := FSound[Address and $7FFFF];
end;

procedure TSaturnConsole.SoundRAMWrite(Address: Cardinal; Value: Byte);
begin
  FSound[Address and $7FFFF] := Value;
end;

procedure TSaturnConsole.SoundDMA(Target: Int64);
begin
  if not FSoundDMAActive then
  begin
    FSoundDMAControl := (Word(FSoundRegisters[$416]) shl 8) or FSoundRegisters[$417];
    if FSoundDMAControl and $1000 = 0 then
      Exit;
    FSoundDMAMemory := ((Cardinal(FSoundRegisters[$414] and $F0) shl 12) or (Cardinal(FSoundRegisters[$412]) shl 8) or FSoundRegisters[$413]) and $7FFFE;
    FSoundDMARegister := ((Cardinal(FSoundRegisters[$414] and 15) shl 8) or FSoundRegisters[$415]) and $FFE;
    FSoundDMACount := (FSoundDMAControl and $FFE) div 2;
    FSoundDMAActive := True;
    FSoundDMANext := FTime + 4;
  end;
  while FSoundDMAActive and (FSoundDMANext <= Target) do
  begin
    var V: Word := 0;
    var RegisterAddress := FSoundDMARegister;
    var Memory := FSoundDMAMemory;
    // The DMA register block cannot itself be a DMA source/destination.
    var ValidRegister: Boolean := (RegisterAddress < $412) or (RegisterAddress > $416);
    if (FSoundDMACount > 0) and (FSoundDMAControl and $2000 <> 0) then
    begin
      if (FSoundDMAControl and $4000 = 0) and ValidRegister then
        V := (Word(SoundRegisterRead(RegisterAddress)) shl 8) or SoundRegisterRead(RegisterAddress + 1);
      FSound[Memory] := V shr 8;
      FSound[(Memory + 1) and $7FFFF] := V and $FF;
    end
    else if FSoundDMACount > 0 then
    begin
      if FSoundDMAControl and $4000 = 0 then
        V := (Word(FSound[Memory]) shl 8) or FSound[(Memory + 1) and $7FFFF];
      if ValidRegister then
      begin
        SoundRegisterWrite(RegisterAddress, V shr 8);
        SoundRegisterWrite(RegisterAddress + 1, V and $FF);
      end;
    end;
    FSoundDMAMemory := (Memory + 2) and $7FFFF;
    FSoundDMARegister := (RegisterAddress + 2) and $FFE;
    Dec(FSoundDMACount);
    Inc(FSoundDMANext, 4);
    // Shared sound bus ownership delays simultaneous SH-2 transactions.
    FBusUntil := Max(FBusUntil, FSoundDMANext);
    if FSoundDMACount <= 0 then
    begin
      FSoundDMAActive := False;
      FSoundDMACount := 0;
      FSoundRegisters[$416] := FSoundRegisters[$416] and not $10;
      FSoundPending := FSoundPending or $10;
      FMainSoundPending := FMainSoundPending or $10;
      SoundIRQ;
    end;
  end;
end;

function TSaturnConsole.ReadByte(Address: Cardinal): Byte;
begin
  Result := $FF;
  case Address of
    $00000000..$000FFFFF:
      Result := FBIOS[Address and $7FFFF];
    $00100000..$0017FFFF:
      Result := FSMPC.Read(Address);
    $00180000..$001FFFFF:
      if Odd(Address) then
        Result := FBackup[(Address shr 1) and $7FFF];
    $00200000..$002FFFFF:
      Result := FWorkLow[Address and $FFFFF];
    $02000000..$04FFFFFF:
      Result := FCartridge.Read(Address);
    $05A00000..$05AFFFFF:
      Result := FSound[Address and $7FFFF];
    $05B00000..$05BFFFFF:
      Result := SoundRegisterRead(Address);
    $05C00000..$05C7FFFF:
      Result := FVDP1.ReadVRAM(Address, 1);
    $05C80000..$05CFFFFF:
      Result := FVDP1.ReadBuffer(Address, 1);
    $06000000..$07FFFFFF:
      Result := FWorkHigh[Address and $FFFFF];
  end;
end;

procedure TSaturnConsole.WriteByte(Address: Cardinal; Value: Byte);
begin
  case Address of
    $00100000..$0017FFFF:
      FSMPC.Write(Address, Value);
    $00180000..$001FFFFF:
      if Odd(Address) then
      begin
        var At := (Address shr 1) and $7FFF;
        if FBackup[At] <> Value then
        begin
          FBackup[At] := Value;
          FBackupDirty := True;
        end;
      end;
    $00200000..$002FFFFF:
      FWorkLow[Address and $FFFFF] := Value;
    $01000000..$017FFFFF:
      FCPU[1].InputCapture;
    $01800000..$01FFFFFF:
      FCPU[0].InputCapture;
    $02000000..$04FFFFFF:
      FCartridge.Write(Address, Value);
    $05A00000..$05AFFFFF:
      FSound[Address and $7FFFF] := Value;
    $05B00000..$05BFFFFF:
      SoundRegisterWrite(Address, Value);
    $05C00000..$05C7FFFF:
      FVDP1.WriteVRAM(Address, Value, 1);
    $05C80000..$05CFFFFF:
      FVDP1.WriteBuffer(Address, Value, 1);
    $06000000..$07FFFFFF:
      FWorkHigh[Address and $FFFFF] := Value;
  end;
end;

function TSaturnConsole.ReadBus(Address: Cardinal; Size: Integer): Cardinal;
begin
  if not (Size in [1, 2, 4]) then
    raise EArgumentException.Create('Saturn bus size');
  Address := Address and $1FFFFFFF;
  case Address of
    $05800000..$058FFFFF:
      Exit(FCD.Read(Address, Size));
    $05D00000..$05D7FFFF:
      Exit(FVDP1.ReadRegister(Address, Size));
    $05E00000..$05EFFFFF:
      Exit(FVDP2.ReadVRAM(Address, Size));
    $05F00000..$05F7FFFF:
      Exit(FVDP2.ReadCRAM(Address, Size));
    $05F80000..$05FBFFFF:
      Exit(FVDP2.ReadRegister(Address, Size));
    $05FE0000..$05FEFFFF:
      Exit(FSCU.ReadRegister(Address, Size));
  end;
  Result := 0;
  for var I := 0 to Size - 1 do
    Result := (Result shl 8) or ReadByte(Address + Cardinal(I));
end;

procedure TSaturnConsole.WriteBus(Address, Value: Cardinal; Size: Integer);
begin
  if not (Size in [1, 2, 4]) then
    raise EArgumentException.Create('Saturn bus size');
  Address := Address and $1FFFFFFF;
  if Assigned(FBusObserver) then
    FBusObserver(Address, Value, Size);
  case Address of
    $05800000..$058FFFFF:
      begin
        FCD.Write(Address, Value, Size);
        Exit;
      end;
    $05D00000..$05D7FFFF:
      begin
        FVDP1.WriteRegister(Address, Value, Size);
        Exit;
      end;
    $05E00000..$05EFFFFF:
      begin
        FVDP2.WriteVRAM(Address, Value, Size);
        Exit;
      end;
    $05F00000..$05F7FFFF:
      begin
        FVDP2.WriteCRAM(Address, Value, Size);
        Exit;
      end;
    $05F80000..$05FBFFFF:
      begin
        FVDP2.WriteRegister(Address, Value, Size);
        Exit;
      end;
    $05FE0000..$05FEFFFF:
      begin
        FSCU.WriteRegister(Address, Value, Size);
        Exit;
      end;
  end;
  for var I := 0 to Size - 1 do
    WriteByte(Address + Cardinal(I), (Value shr ((Size - I - 1) * 8)) and $FF);
end;

function TSaturnConsole.Wait(CPU: Integer; Address: Cardinal; Size: Integer; Writing: Boolean): Integer;
begin
  // Nominal bus cycles; shared transactions serialize at their start times.
  var Clocks: Integer := 1;
  case Address of
    $00000000..$000FFFFF:
      Clocks := Max(1, (Size + 1) div 2) * 3;
    $00100000..$001FFFFF:
      Clocks := Max(1, (Size + 1) div 2) * 8;
    $00200000..$002FFFFF:
      Clocks := Max(1, (Size + 1) div 2) * 4;
    $02000000..$05FFFFFF:
      Clocks := Max(1, (Size + 1) div 2) * 4;
    $06000000..$07FFFFFF:
      if Writing then
        Clocks := Max(1, (Size + 3) div 4) * 2
      else
      begin
        if Size = 16 then
          Clocks := 8
        else
          Clocks := 3;
      end;
  end;
  var Start := Max(FCPUTime[CPU], FBusUntil);
  Result := Integer(Min(Int64(4096), Start - FCPUTime[CPU])) + Clocks;
  var CDWait := FCD.WaitHost(Address, Size, Writing);
  Inc(Result, CDWait);
  Inc(Clocks, CDWait);
  FBusUntil := Start + Clocks;
end;

function TSaturnConsole.DMAReady(Address: Cardinal; Size: Integer; Writing: Boolean): Boolean;
begin
  Address := Address and $1FFFFFFF;
  Result := True;
  if (FCD.SH1 <> nil) and ((Address = $05818000) or (Address = $05898000)) then
    Result := FCD.SH1.HostReady(Size, Writing);
end;

function TSaturnConsole.ReserveDMA(At: Int64; Address: Cardinal; Size: Integer; Writing: Boolean): Int64;
begin
  var Clocks: Integer := 4;
  case Address of
    $00200000..$002FFFFF:
      Clocks := ((Size + 1) div 2) * 4;
    $02000000..$059FFFFF:
      Clocks := ((Size + 1) div 2) * 4;
    $05A00000..$05FDFFFF:
      Clocks := ((Size + 1) div 2) * 2;
    $06000000..$07FFFFFF:
      begin
        if Writing then
          Clocks := 2
        else
          Clocks := 3;
      end;
  end;
  Result := Max(At, FBusUntil) + Clocks;
  FBusUntil := Result;
end;

function TSaturnConsole.ReadCPU(CPU: Integer; Address: Cardinal; Size: Integer): Cardinal;
begin
  if not (CPU in [0, 1]) then
    raise EArgumentOutOfRangeException.Create('Saturn CPU');
  Result := FCPU[CPU].Read(Address, Size);
end;

procedure TSaturnConsole.WriteCPU(CPU: Integer; Address, Value: Cardinal; Size: Integer);
begin
  if not (CPU in [0, 1]) then
    raise EArgumentOutOfRangeException.Create('Saturn CPU');
  FCPU[CPU].Write(Address, Value, Size);
end;

function TSaturnConsole.CPUState(CPU: Integer): TSH2State;
begin
  if not (CPU in [0, 1]) then
    raise EArgumentOutOfRangeException.Create('Saturn CPU');
  Result := FCPU[CPU].State;
end;

procedure TSaturnConsole.SetCPUState(CPU: Integer; const State: TSH2State);
begin
  if not (CPU in [0, 1]) then
    raise EArgumentOutOfRangeException.Create('Saturn CPU');
  FCPU[CPU].State := State;
end;

procedure TSaturnConsole.RasterEvent;
begin
  var Active: Integer := 1280;
  var Sync: Integer := 1388;
  var Total: Integer := 1708;
  if FSMPC.Clock352 then
  begin
    Active := 1408;
    Sync := 1500;
    Total := 1820;
  end;
  case FRasterPhase of
    0:
      begin
        FHBlank := True;
        var RenderY: Integer := FLine;
        if FFrameHeight > 256 then
          RenderY := FLine * 2 + Ord(FVDP2.Field);
        if (FLine < FVDP2.ScanHeight) and (RenderY < FFrameHeight) then
          FVDP2.RenderLine(RenderY, FVDP1, FPixels, RenderY * FFrameWidth);
        FSCU.HBlank;
        FRasterPhase := 1;
        FNextRaster := FLineStart + Sync;
      end;
    1:
      begin
        Inc(FLine);
        if FLine = FVDP2.ScanHeight then
        begin
          FSCU.Signal(0);
          FVDP1.VBlank;
        end;
        var Lines: Integer := 263;
        if FPAL then
          Lines := 313;
        if (FVDP2.ReadRegister(0, 2) and $80 <> 0) and FVDP2.Field then
          Dec(Lines);
        if FLine >= Lines then
        begin
          FLine := 0;
          Inc(FFrames);
          FVDP2.NewField;
          FSCU.VBlankOut;
          FFrameWidth := FVDP2.Width;
          FFrameHeight := FVDP2.Height;
          SetLength(FPixels, FFrameWidth * FFrameHeight);
        end;
        FRasterPhase := 2;
        FNextRaster := FLineStart + Total;
      end;
    2:
      begin
        FHBlank := False;
        FLineStart := FNextRaster;
        FRasterPhase := 0;
        FNextRaster := FLineStart + Active;
      end;
  end;
  FVDP2.SetRaster(FLine, 0, FHBlank, FLine >= FVDP2.ScanHeight);
end;

procedure TSaturnConsole.AdvanceDevices(Target: Int64);
begin
  SoundDMA(Target);
  Inc(FSamplePhase, (Target - FTime) * 44100);
  while FSamplePhase >= FClock do
  begin
    Dec(FSamplePhase, FClock);
    SoundTick;
  end;
  FTime := Target;
  FCPU[0].Advance(Target);
  if FSlaveOn then
    FCPU[1].Advance(Target);
  FSCU.Advance(Target);
  FSMPC.Advance(Target);
  FVDP1.Advance(Target);
  FCD.Advance(Target);
  while FNextRaster <= Target do
    RasterEvent;
  var Dot: Integer := Max(0, Integer(Target - FLineStart)) div 4;
  var TotalDots: Integer := 427;
  var SyncDot: Integer := 347;
  if FSMPC.Clock352 then
  begin
    TotalDots := 455;
    SyncDot := 375;
  end;
  if Dot >= SyncDot then
    Inc(Dot, 512 - TotalDots);
  FVDP2.SetRaster(FLine, (Dot * 2) and $3FF, FHBlank, FLine >= FVDP2.ScanHeight);
end;

procedure TSaturnConsole.RunCycles(Cycles: Int64);
begin
  if (Cycles < 0) or (Cycles > Int64(FClock) * 60) then
    raise EArgumentOutOfRangeException.Create('Saturn run interval');
  var Target := FTime + Cycles;
  while FTime < Target do
  begin
    var CPU: Integer := 0;
    if FSlaveOn and (FCPUTime[1] < FCPUTime[0]) then
      CPU := 1;
    var Due := FCPUTime[CPU];
    if FSoundOn and (FSoundAt < Due) then
    begin
      CPU := 2;
      Due := FSoundAt;
    end;
    var Next := Min(Target, Min(FNextRaster, Due));
    if Next > FTime then
      AdvanceDevices(Next);
    if FResetPending then
    begin
      Reset;
      Exit;
    end;
    if FTime >= Target then
      Break;
    if Due > FTime then
      Continue;
    if CPU = 2 then
    begin
      var Used := Clown68000DoCycles(FSoundCPU, FSoundCallbacks, 1);
      Inc(FSoundFraction, Int64(Used) * FClock);
      Inc(FSoundAt, FSoundFraction div 11289600);
      FSoundFraction := FSoundFraction mod 11289600;
      Continue;
    end;
    // Events are visible to both CPUs before the next instruction is issued.
    var Before := FCPU[CPU].State;
    if Assigned(FInstructionObserver) then
      FInstructionObserver(CPU, Before);
    var WasIRQ: Boolean := (CPU = 0) and not Before.DelayPending and (FIRQLevel > Integer((Before.SR shr 4) and 15));
    var Vector := FIRQVector;
    var Spent := FCPU[CPU].Step;
    Inc(FCPUTime[CPU], Spent);
    if WasIRQ and (FCPU[CPU].State.R[15] = Before.R[15] - 8) then
      FSCU.Acknowledge(Vector);
  end;
end;

procedure TSaturnConsole.RunFrame;
begin
  FSampleFrames := 0;
  var Frame := FFrames;
  while FFrames = Frame do
    RunCycles(1708);
end;

procedure TSaturnConsole.SetInput(Port: Integer; Buttons: TSaturnButtons; Connected: Boolean);
begin
  FSMPC.SetInput(Port, Buttons, Connected);
end;

procedure TSaturnConsole.LoadBackup(const Data: TBytes);
begin
  if Length(Data) <> SizeOf(FBackup) then
    raise EReadError.Create('Saturn backup RAM size');
  Move(Data[0], FBackup, SizeOf(FBackup));
  FBackupDirty := False;
end;

function TSaturnConsole.Backup: TBytes;
begin
  SetLength(Result, SizeOf(FBackup));
  Move(FBackup, Result[0], SizeOf(FBackup));
end;

function TSaturnConsole.FramesPerSecond: Double;
begin
  var Lines: Double := 263;
  if FPAL then
    Lines := 313;
  if FVDP2.ReadRegister(0, 2) and $80 <> 0 then
    Lines := Lines - 0.5;
  var LineClocks: Integer := 1708;
  if FSMPC.Clock352 then
    LineClocks := 1820;
  Result := FClock / (LineClocks * Lines);
end;

procedure TSaturnConsole.SerializeState(Archive: TStateArchive);
begin
  var Version: Cardinal := $53415404;
  Archive.Field(Version, SizeOf(Version));
  if Version <> $53415404 then
    raise EReadError.Create('Unsupported Saturn snapshot format; a current Saturn snapshot is required');
  var Hash := THashSHA2.Create;
  Hash.Update(FBIOS);
  var Identity := Hash.HashAsBytes;
  var Expected := Copy(Identity);
  Archive.Field(Identity[0], Length(Identity));
  if Archive.Loading and not CompareMem(@Identity[0], @Expected[0], Length(Identity)) then
    raise EReadError.Create('Saturn snapshot BIOS mismatch');
  SetLength(Identity, 32);
  FillChar(Identity[0], 32, 0);
  if FCD.Disc <> nil then
  begin
    Hash := THashSHA2.Create;
    Hash.Update(FCD.Disc.Identity);
    Identity := Hash.HashAsBytes;
  end;
  Expected := Copy(Identity);
  Archive.Field(Identity[0], Length(Identity));
  if Archive.Loading and not CompareMem(@Identity[0], @Expected[0], Length(Identity)) then
    raise EReadError.Create('Saturn snapshot disc mismatch');
  Archive.Field(FWorkLow, SizeOf(FWorkLow));
  Archive.Field(FWorkHigh, SizeOf(FWorkHigh));
  Archive.Field(FBackup, SizeOf(FBackup));
  Archive.Field(FSoundCPU, SizeOf(FSoundCPU));
  Archive.Field(FSoundAt, SizeOf(FSoundAt));
  Archive.Field(FSoundFraction, SizeOf(FSoundFraction));
  Archive.Field(FSoundDMAActive, SizeOf(FSoundDMAActive));
  Archive.Field(FSoundDMANext, SizeOf(FSoundDMANext));
  Archive.Field(FSoundDMAMemory, SizeOf(FSoundDMAMemory));
  Archive.Field(FSoundDMARegister, SizeOf(FSoundDMARegister));
  Archive.Field(FSoundDMACount, SizeOf(FSoundDMACount));
  Archive.Field(FSoundDMAControl, SizeOf(FSoundDMAControl));
  Archive.Field(FSamplePhase, SizeOf(FSamplePhase));
  Archive.Field(FTimerPhase, SizeOf(FTimerPhase));
  Archive.Field(FSoundPending, SizeOf(FSoundPending));
  Archive.Field(FMainSoundPending, SizeOf(FMainSoundPending));
  Archive.Field(FSound, SizeOf(FSound));
  Archive.Field(FSoundRegisters, SizeOf(FSoundRegisters));
  FCPU[0].SerializeState(Archive);
  FCPU[1].SerializeState(Archive);
  FSCU.SerializeState(Archive);
  FSMPC.SerializeState(Archive);
  FVDP1.SerializeState(Archive);
  FVDP2.SerializeState(Archive);
  Archive.Field(FCPUTime, SizeOf(FCPUTime));
  Archive.Field(FTime, SizeOf(FTime));
  Archive.Field(FNextRaster, SizeOf(FNextRaster));
  Archive.Field(FLineStart, SizeOf(FLineStart));
  Archive.Field(FRasterPhase, SizeOf(FRasterPhase));
  Archive.Field(FLine, SizeOf(FLine));
  Archive.Field(FClock, SizeOf(FClock));
  Archive.Field(FHBlank, SizeOf(FHBlank));
  Archive.Field(FSlaveOn, SizeOf(FSlaveOn));
  Archive.Field(FSoundOn, SizeOf(FSoundOn));
  Archive.Field(FResetPending, SizeOf(FResetPending));
  Archive.Field(FPAL, SizeOf(FPAL));
  Archive.Field(FFrames, SizeOf(FFrames));
  Archive.Field(FFrameWidth, SizeOf(FFrameWidth));
  Archive.Field(FFrameHeight, SizeOf(FFrameHeight));
  FCD.SerializeState(Archive);
  FSCSP.SerializeState(Archive);
  FCartridge.SerializeState(Archive);
  Archive.Field(FSampleFrames, SizeOf(FSampleFrames));
  if (FSampleFrames < 0) or (FSampleFrames > 4096) then
    raise EReadError.Create('Saturn snapshot audio size');
  if FSampleFrames > 0 then
    Archive.Field(FSamples[0], FSampleFrames * 4);
  Archive.Field(FBusUntil, SizeOf(FBusUntil));
  Archive.Field(FIRQLevel, SizeOf(FIRQLevel));
  Archive.Field(FIRQVector, SizeOf(FIRQVector));
  if (FTime < 0) or (FNextRaster < FTime) or (FCPUTime[0] < FTime) or (FSlaveOn and (FCPUTime[1] < FTime)) or (FClock < 20000000) or (FClock > 30000000) or (FSoundFraction < 0) or (FSoundFraction >= 11289600) or (FSamplePhase < 0) or (FSamplePhase >= FClock) or (FFrameWidth < 320) or (FFrameWidth > 704) or (FFrameHeight < 224) or (FFrameHeight > 512) or (FLine < 0) or (FLine > 312) or
    (FRasterPhase < 0) or (FRasterPhase > 2) or (FLineStart < 0) or (FLineStart > FTime) or
    (FSoundDMACount < 0) or (FSoundDMACount > $FFE) or (FSoundDMAActive and ((FSoundDMACount = 0) or (FSoundDMANext < FTime))) then
    raise EReadError.Create('Saturn state timing');
  SetLength(FPixels, FFrameWidth * FFrameHeight);
  Archive.Field(FPixels[0], Length(FPixels) * SizeOf(TAlphaColor));
  if Archive.Loading then
    FBackupDirty := True;
end;

end.

