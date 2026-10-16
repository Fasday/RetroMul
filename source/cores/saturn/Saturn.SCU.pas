unit Saturn.SCU;

interface

uses
  System.SysUtils, System.Classes, HW.SH2, Core.Snapshots, Saturn.SCUDSP;

type
  TSaturnIRQ = procedure(Level, Vector: Integer) of object;

  TSCUReserve = function(At: Int64; Address: Cardinal; Size: Integer; Writing: Boolean): Int64 of object;

  TSCUReady = function(Address: Cardinal; Size: Integer; Writing: Boolean): Boolean of object;

  TSCUDMA = record
    Source, Dest, Remaining, Descriptor: Cardinal;
    Active, LastDescriptor: Boolean;
    Next: Int64;
    Phase: Byte;
    Data: Cardinal;
  end;

  TSaturnSCU = class
  private
    FDSP: TSCUDSP;
    FExternal: Cardinal;
    FRegisters: array[0..63] of Cardinal;
    // Transfer controls belong to the in-flight DMA, independently of the
    // next register setup (Ymir curr*AddrInc / Mednafen DMA level controls).
    FActiveAdd, FActiveMode: array[0..2] of Cardinal;
    FStartPending: array[0..2] of Boolean;
    FDMA: array[0..2] of TSCUDMA;
    FRead: TSH2Read;
    FWrite: TSH2Write;
    FUser: Pointer;
    FIRQ: TSaturnIRQ;
    FTime, FTimer1: Int64;
    FCPUHalted: Boolean;
    FNextDMA: Int64; // derived earliest active bus phase
    FTimer0: Integer;
    FDelivered: Cardinal;
    FReserve: TSCUReserve;
    FReady: TSCUReady;
    procedure UpdateCPUHalt;
    function GetVDP1BusBusy: Boolean;
    procedure DSPDone;
    procedure UpdateIRQ;
    procedure StartDMA(Channel: Integer; QueueIfActive: Boolean = False; At: Int64 = -1);
    procedure LoadDescriptor(Channel: Integer);
    procedure DMASlot(Channel: Integer);
    procedure AdvanceDMA(Target: Int64);
  public
    constructor Create(Read: TSH2Read; Write: TSH2Write; User: Pointer; IRQ: TSaturnIRQ);
    destructor Destroy; override;
    procedure SetExternal(Index: Integer; Active: Boolean);
    property DSP: TSCUDSP read FDSP;
    property CPUHalted: Boolean read FCPUHalted;
    property CPUBusBusy: Boolean read FCPUHalted;
    property VDP1BusBusy: Boolean read GetVDP1BusBusy;
    property NextDMA: Int64 read FNextDMA;
    property Reserve: TSCUReserve read FReserve write FReserve;
    property Ready: TSCUReady read FReady write FReady;
    procedure Reset;
    function ReadRegister(Address: Cardinal; Size: Integer): Cardinal;
    procedure WriteRegister(Address, Value: Cardinal; Size: Integer);
    procedure Signal(Bit: Integer);
    procedure Acknowledge(Vector: Integer);
    procedure VBlankOut;
    procedure HBlank;
    procedure Advance(Target: Int64); inline;
    // Board scheduler only: Target is already known to be monotonic.
    procedure AdvanceForward(Target: Int64); inline;
    procedure SerializeState(Archive: TStateArchive; LatchedDMA: Boolean = True);
  end;

implementation

uses
  System.Math;

{$Q+}{$R+}

const
  Levels: array[0..31] of Byte = (
    15, 14, 13, 12, 11, 10, 9, 8, 8, 6, 6, 5, 3, 2, 0, //
    0, 7, 7, 7, 7, 4, 4, 4, 4, 1, 1, 1, 1, 1, 1, 1, 1);

constructor TSaturnSCU.Create(Read: TSH2Read; Write: TSH2Write; User: Pointer; IRQ: TSaturnIRQ);
begin
  inherited Create;
  FRead := Read;
  FWrite := Write;
  FUser := User;
  FIRQ := IRQ;
  FDSP := TSCUDSP.Create(Read, Write, User, DSPDone);
  Reset;
end;

destructor TSaturnSCU.Destroy;
begin
  FDSP.Free;
  inherited;
end;

procedure TSaturnSCU.DSPDone;
begin
  Signal(5);
end;

procedure TSaturnSCU.SetExternal(Index: Integer; Active: Boolean);
begin
  var Bit: Cardinal := Cardinal(1) shl (16 + Index);
  if Active and (FExternal and Bit = 0) then
    Signal(16 + Index);
  if Active then
    FExternal := FExternal or Bit
  else
    FExternal := FExternal and not Bit;
end;

procedure TSaturnSCU.Reset;
begin
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FillChar(FDMA, SizeOf(FDMA), 0);
  FillChar(FActiveAdd, SizeOf(FActiveAdd), 0);
  FillChar(FActiveMode, SizeOf(FActiveMode), 0);
  FillChar(FStartPending, SizeOf(FStartPending), 0);
  FRegisters[$A0 div 4] := $BFFF;
  FRegisters[$C8 div 4] := 4;
  for var i := 0 to 2 do
  begin
    FRegisters[(i * $20 + $0C) div 4] := $101;
    FRegisters[(i * $20 + $14) div 4] := 7;
  end;
  FDSP.Reset;
  FExternal := 0;
  FTime := 0;
  FNextDMA := High(Int64);
  FCPUHalted := False;
  FTimer0 := 0;
  FTimer1 := -1;
  FDelivered := 0;
  UpdateIRQ;
end;

function TSaturnSCU.GetVDP1BusBusy: Boolean;
begin
  // SCU bursts have priority over VDP1 drawing (VDP1 manual, section 2.1).
  // Keep ownership across the CPU-side reads and indirect descriptor fetches:
  // letting drawing run between burst words exposes a partly uploaded list.
  Result := False;
  for var Ch := 0 to 2 do
    if FDMA[Ch].Active and
      (((FDMA[Ch].Source >= $05C00000) and (FDMA[Ch].Source < $05D00000)) or
      ((FDMA[Ch].Dest >= $05C00000) and (FDMA[Ch].Dest < $05D00000))) then
      Exit(True);
end;

procedure TSaturnSCU.UpdateCPUHalt;
begin
  FCPUHalted := False;

  // A burst involving the CPU bus retains ownership between its read/write
  // phases. Releasing it after each word lets SH-2 overwrite the source while
  // DMA is copying it. The dedicated cache bus remains usable by both CPUs.
  for var Ch := 2 downto 0 do
    if FDMA[Ch].Active then
    begin
      if FDMA[Ch].Phase >= 3 then
        FCPUHalted := (FDMA[Ch].Descriptor < $02000000) or (FDMA[Ch].Descriptor >= $06000000)
      else
        FCPUHalted := (FDMA[Ch].Source < $02000000) or (FDMA[Ch].Source >= $06000000) or
          (FDMA[Ch].Dest < $02000000) or (FDMA[Ch].Dest >= $06000000);
      // A higher-priority channel cannot release an already reserved
      // transaction belonging to another active channel.
      if FCPUHalted then
        Exit;
    end;
end;

procedure TSaturnSCU.UpdateIRQ;
begin
  // IMS has one shared mask (bit 15) for all A-bus interrupt inputs.
  // Its reserved upper bits do not individually mask IST bits 16..31.
  var Pending := FRegisters[$A4 div 4] and not FDelivered;
  Pending := (Pending and $FFFF0000) or (Pending and $FFFF and not FRegisters[$A0 div 4]);
  if FRegisters[$A0 div 4] and $8000 <> 0 then
    Pending := Pending and $FFFF;
  var Level: Integer := 0;
  var Vector: Integer := 0;
  for var i := 0 to 31 do
    if (Pending and (Cardinal(1) shl i) <> 0) and (Levels[i] > Level) then
    begin
      Level := Levels[i];
      Vector := $40 + i;
    end;
  if Assigned(FIRQ) then
    FIRQ(Level, Vector);
end;

procedure TSaturnSCU.Signal(Bit: Integer);
begin
  if (Bit < 0) or (Bit > 31) then
    raise EArgumentOutOfRangeException.Create('SCU IRQ');

  FRegisters[$A4 div 4] := FRegisters[$A4 div 4] or (Cardinal(1) shl Bit);
  FDelivered := FDelivered and not (Cardinal(1) shl Bit);
  for var i := 0 to 2 do
    if (FRegisters[(i * $20 + $10) div 4] and $100 <> 0) and
      (((FRegisters[(i * $20 + $14) div 4] and 7) = Cardinal(Bit)) and (Bit in [0, 1, 2, 3, 4]) or
      ((FRegisters[(i * $20 + $14) div 4] and 7 = 5) and (Bit = 6)) or
      ((FRegisters[(i * $20 + $14) div 4] and 7 = 6) and (Bit = 13))) then
      StartDMA(i);
  UpdateIRQ;
end;

procedure TSaturnSCU.Acknowledge(Vector: Integer);
begin
  if (Vector >= $40) and (Vector <= $5F) then
    FDelivered := FDelivered or (Cardinal(1) shl (Vector - $40));
  UpdateIRQ;
end;

procedure TSaturnSCU.LoadDescriptor(Channel: Integer);
begin
  var D := FDMA[Channel].Descriptor;
  if D and 3 <> 0 then
  begin
    FDMA[Channel].Active := False;
    Signal(12);
    Exit;
  end;

  // Descriptor words use the same bus arbitration and readiness checks as data.
  // Phase and partially fetched fields are already part of the saved DMA record.
  FDMA[Channel].Phase := 3;
end;

procedure TSaturnSCU.StartDMA(Channel: Integer; QueueIfActive: Boolean; At: Int64);
begin
  if FDMA[Channel].Active then
  begin
    if QueueIfActive then
      FStartPending[Channel] := True;
    Exit;
  end;

  FStartPending[Channel] := False;
  if At < 0 then
    At := FTime;
  var B := Channel * 8;
  FActiveAdd[Channel] := FRegisters[B + 3];
  FActiveMode[Channel] := FRegisters[B + 5];
  FDMA[Channel].Active := True;
  FDMA[Channel].Next := At + 4;
  FDMA[Channel].Phase := 0;
  FDMA[Channel].Source := FRegisters[B] and $1FFFFFFF;
  FDMA[Channel].Dest := FRegisters[B + 1] and $1FFFFFFF;
  FDMA[Channel].Remaining := FRegisters[B + 2] and $FFFFF;
  if Channel > 0 then
    FDMA[Channel].Remaining := FDMA[Channel].Remaining and $FFF;
  if FDMA[Channel].Remaining = 0 then
  begin
    if Channel = 0 then
      FDMA[Channel].Remaining := $100000
    else
      FDMA[Channel].Remaining := $1000;
  end;
  if FRegisters[B + 5] and $1000000 <> 0 then
  begin
    FDMA[Channel].Descriptor := FRegisters[B + 1];
    LoadDescriptor(Channel);
  end;
  if FDMA[Channel].Active then
    FNextDMA := Min(FNextDMA, FDMA[Channel].Next);
  UpdateCPUHalt;
end;

procedure TSaturnSCU.DMASlot(Channel: Integer);
begin
  var B := Channel * 8;
  var Mode := FActiveMode[Channel];
  var Add := FActiveAdd[Channel];
  var Size: Integer := Min(4, Integer(FDMA[Channel].Remaining));
  if Size = 3 then
    Size := 2;
  var Source := FDMA[Channel].Source;
  var Dest := FDMA[Channel].Dest;

  // A-bus cartridge RAM is a legal destination from the CPU/B bus. Only
  // transfers within the A bus are illegal; rejecting every A-bus write
  // prevented games from uploading data to the expansion DRAM cartridge.
  if (Dest < $00200000) or
    ((Dest >= $02000000) and (Dest < $05A00000) and
    ((Dest >= $05900000) or ((Source >= $02000000) and (Source < $05A00000)))) then
  begin
    FDMA[Channel].Active := False;
    Signal(12);
    Exit;
  end;

  var Step: Cardinal := 0;
  if Add and 7 <> 0 then
    Step := Cardinal(1) shl (Add and 7);
  var Data := FDMA[Channel].Data;
  if (Dest >= $05A00000) and (Dest < $05FE0000) and (Size = 4) then
  begin
    FWrite(FUser, Dest, Data shr 16, 2);
    FWrite(FUser, Dest + Step, Data and $FFFF, 2);
    FDMA[Channel].Dest := Cardinal((Int64(FDMA[Channel].Dest) + Step * 2) and $FFFFFFFF);
  end
  else
  begin
    // The CPU bus accepts arbitrary byte boundaries (SCU manual section 2.1).
    // Break an unaligned write into byte cycles; do not report DMA illegal.
    if Dest and Cardinal(Size - 1) <> 0 then
      for var i := 0 to Size - 1 do
        FWrite(FUser, (Dest + Cardinal(i)) and $1FFFFFFF, (Data shr ((Size - i - 1) * 8)) and $FF, 1)
    else
      FWrite(FUser, Dest, Data, Size);
    if (Dest < $05A00000) or (Dest >= $05FE0000) then
      Step := Min(Step, Cardinal(Size));
    FDMA[Channel].Dest := Cardinal((Int64(FDMA[Channel].Dest) + Step) and $FFFFFFFF);
  end;

  // Honor the latched read-add bit for WRAM fills as well as the CD FIFO.
  // Forcing WRAM to advance copies following program/data bytes into CRAM.
  if Add and $100 <> 0 then
    FDMA[Channel].Source := Cardinal((Int64(FDMA[Channel].Source) + Size) and $FFFFFFFF);
  Dec(FDMA[Channel].Remaining, Size);
  if FDMA[Channel].Remaining = 0 then
  begin
    if (Mode and $1000000 <> 0) and not FDMA[Channel].LastDescriptor then
      LoadDescriptor(Channel)
    else
    begin
      FDMA[Channel].Active := False;
      FRegisters[B + 4] := FRegisters[B + 4] and $100;
      if Mode and $10000 <> 0 then
        FRegisters[B] := FDMA[Channel].Source;
      if Mode and $100 <> 0 then
        FRegisters[B + 1] := FDMA[Channel].Dest;
      Signal(11 - Channel);
      if FStartPending[Channel] then
        StartDMA(Channel, False, FDMA[Channel].Next);
    end;
  end;
end;

procedure TSaturnSCU.Advance(Target: Int64);
begin
  if Target < FTime then
    raise EArgumentException.Create('SCU time');

  FTime := Target;
  FDSP.Advance(Target);
  if (FTimer1 >= 0) and (Target >= FTimer1) then
  begin
    FTimer1 := -1;
    Signal(4);
  end;
  if FNextDMA <= Target then
    AdvanceDMA(Target);
end;

procedure TSaturnSCU.AdvanceForward(Target: Int64);
begin
  FTime := Target;
  FDSP.AdvanceForward(Target);
  if (FTimer1 >= 0) and (Target >= FTimer1) then
  begin
    FTimer1 := -1;
    Signal(4);
  end;
  if FNextDMA <= Target then
    AdvanceDMA(Target);
end;

procedure TSaturnSCU.AdvanceDMA(Target: Int64);
begin
  // Only one DMA bus transaction per slot; level 2 has highest priority.
  while True do
  begin
    var Ch: Integer := -1;
    var Next: Int64 := High(Int64);
    for var i := 2 downto 0 do
      if FDMA[i].Active and (FDMA[i].Next < Next) then
      begin
        Ch := i;
        Next := FDMA[i].Next;
      end;
    FNextDMA := Next;
    if (Ch < 0) or (Next > Target) then
      Break;

    var Size := Min(4, Integer(FDMA[Ch].Remaining));
    if Size = 3 then
      Size := 2;
    case FDMA[Ch].Phase of
      0:
        begin
          FDMA[Ch].Phase := 1;
          if Assigned(FReserve) then
            FDMA[Ch].Next := FReserve(Next, FDMA[Ch].Source, Size, False)
          else
            FDMA[Ch].Next := Next + 2;
        end;
      1:
        begin
          if Assigned(FReady) and not FReady(FDMA[Ch].Source, Size, False) then
          begin
            FDMA[Ch].Next := Next + 2;
            Continue;
          end;

          // Unaligned source/end bytes are legal, including the halfword-aligned
          // command records used by SGL's indirect VDP1 uploads.
          if FDMA[Ch].Source and Cardinal(Size - 1) <> 0 then
          begin
            FDMA[Ch].Data := 0;
            for var i := 0 to Size - 1 do
              FDMA[Ch].Data := (FDMA[Ch].Data shl 8) or (FRead(FUser, (FDMA[Ch].Source + Cardinal(i)) and $1FFFFFFF, 1) and $FF);
          end
          else
            FDMA[Ch].Data := FRead(FUser, FDMA[Ch].Source, Size);
          FDMA[Ch].Phase := 2;
          if Assigned(FReserve) then
            FDMA[Ch].Next := FReserve(Next, FDMA[Ch].Dest, Size, True)
          else
            FDMA[Ch].Next := Next + 2;
        end;
      2:
        begin
          if ((FDMA[Ch].Dest >= $00200000) and ((FDMA[Ch].Dest < $02000000) or (FDMA[Ch].Dest >= $05A00000))) and
            Assigned(FReady) and not FReady(FDMA[Ch].Dest, Size, True) then
          begin
            FDMA[Ch].Next := Next + 2;
            Continue;
          end;

          FDMA[Ch].Phase := 0;
          DMASlot(Ch);
        end;
      3, 5, 7:
        begin
          var Address := (FDMA[Ch].Descriptor + Cardinal((FDMA[Ch].Phase - 3) div 2) * 4) and $1FFFFFFF;
          Inc(FDMA[Ch].Phase);
          if Assigned(FReserve) then
            FDMA[Ch].Next := FReserve(Next, Address, 4, False)
          else
            FDMA[Ch].Next := Next + 2;
        end;
      4, 6, 8:
        begin
          var Address := (FDMA[Ch].Descriptor + Cardinal((FDMA[Ch].Phase - 4) div 2) * 4) and $1FFFFFFF;
          if Assigned(FReady) and not FReady(Address, 4, False) then
          begin
            FDMA[Ch].Next := Next + 2;
            Continue;
          end;

          var Value := FRead(FUser, Address, 4);
          case FDMA[Ch].Phase of
            4:
              begin
                FDMA[Ch].Remaining := Value and $FFFFF;
                if FDMA[Ch].Remaining = 0 then
                  FDMA[Ch].Remaining := $100000;
              end;
            6:
              FDMA[Ch].Dest := Value and $1FFFFFFF;
            8:
              begin
                FDMA[Ch].Source := Value and $1FFFFFFF;
                FDMA[Ch].LastDescriptor := Value and $80000000 <> 0;
                FDMA[Ch].Descriptor := Cardinal((UInt64(FDMA[Ch].Descriptor) + 12) and $FFFFFFFF);
              end;
          end;
          if FDMA[Ch].Phase = 8 then
            FDMA[Ch].Phase := 0
          else
            Inc(FDMA[Ch].Phase);
          FDMA[Ch].Next := Next;
        end;
    end;
    for var i := 0 to 2 do
      if (i <> Ch) and FDMA[i].Active then
        FDMA[i].Next := Max(FDMA[i].Next, FDMA[Ch].Next);
  end;
  UpdateCPUHalt;
end;

procedure TSaturnSCU.VBlankOut;
begin
  FTimer0 := 0;
  Signal(1);
end;

procedure TSaturnSCU.HBlank;
begin
  Signal(2);
  Inc(FTimer0);
  if (FRegisters[$98 div 4] and 1 <> 0) and (FTimer0 = Integer(FRegisters[$90 div 4] and $3FF)) then
    Signal(3);
  if (FRegisters[$98 div 4] and 1 <> 0) and ((FRegisters[$98 div 4] and $100 = 0) or (FTimer0 = Integer(FRegisters[$90 div 4] and $3FF))) then
    FTimer1 := FTime + Int64(FRegisters[$94 div 4] and $1FF) * 4;
end;

function TSaturnSCU.ReadRegister(Address: Cardinal; Size: Integer): Cardinal;
begin
  if (Address and $FC in [$80, $84, $88, $8C]) then
  begin
    var V := FDSP.ReadPort(Address);
    if Size = 4 then
      Exit(V);

    Exit((V shr ((4 - Integer(Address and 3) - Size) * 8)) and ((Cardinal(1) shl (Size * 8)) - 1));
  end;

  Result := 0;
  for var i := 0 to Size - 1 do
  begin
    var A: Integer := (UInt64(Address) + Cardinal(i)) and $FF;
    var V := FRegisters[A div 4];
    if A and $FC = $7C then
    begin
      V := Ord(FDSP.DMAActive);
      for var Ch := 0 to 2 do
        if FDMA[Ch].Active then
          V := V or (Cardinal($10) shl (Ch * 4));
    end;
    Result := (Result shl 8) or ((V shr ((3 - (A and 3)) * 8)) and $FF);
  end;
end;

procedure TSaturnSCU.WriteRegister(Address, Value: Cardinal; Size: Integer);
begin
  if Address and $FC in [$80, $84, $88, $8C] then
  begin
    if Size = 4 then
      FDSP.WritePort(Address, Value);
    Exit;
  end;

  for var i := 0 to Size - 1 do
  begin
    var A: Integer := (UInt64(Address) + Cardinal(i)) and $FF;
    var Shift: Integer := (3 - (A and 3)) * 8;
    if A and $FC in [$7C, $C8] then
      Continue;

    var Mask: Cardinal := $FF shl Shift;
    var Bits: Cardinal := ((Value shr ((Size - i - 1) * 8)) and $FF) shl Shift;
    if A and $FC = $A4 then
    begin
      FRegisters[$A4 div 4] := FRegisters[$A4 div 4] and (Bits or not Mask);
      FDelivered := FDelivered and FRegisters[$A4 div 4];
    end
    else
      FRegisters[A div 4] := (FRegisters[A div 4] and not Mask) or Bits;
  end;
  for var Ch := 0 to 2 do
  begin
    var B := Ch * 8;
    if (Address and $FC = Cardinal(Ch * $20 + $10)) and (FRegisters[B + 4] and 1 <> 0) and (FRegisters[B + 5] and 7 = 7) then
    begin
      StartDMA(Ch, True);

      // GO is a write strobe. EN remains set after completion; a GO issued
      // during a transfer starts the next register setup when it finishes.
      FRegisters[B + 4] := FRegisters[B + 4] and $100;
    end;
  end;
  if (Address and $FC = $60) and (FRegisters[$60 div 4] and 1 <> 0) then
  begin
    for var Ch := 0 to 2 do
      FDMA[Ch].Active := False;
    FillChar(FStartPending, SizeOf(FStartPending), 0);
    FNextDMA := High(Int64);
    UpdateCPUHalt;
  end;
  UpdateIRQ;
end;

procedure TSaturnSCU.SerializeState(Archive: TStateArchive; LatchedDMA: Boolean);
begin
  FDSP.SerializeState(Archive);
  Archive.Field(FExternal, SizeOf(FExternal));
  Archive.Field(FRegisters, SizeOf(FRegisters));
  Archive.Field(FDMA, SizeOf(FDMA));
  Archive.Field(FTime, SizeOf(FTime));
  Archive.Field(FTimer0, SizeOf(FTimer0));
  Archive.Field(FTimer1, SizeOf(FTimer1));
  Archive.Field(FDelivered, SizeOf(FDelivered));
  if LatchedDMA then
  begin
    Archive.Field(FActiveAdd, SizeOf(FActiveAdd));
    Archive.Field(FActiveMode, SizeOf(FActiveMode));
    Archive.Field(FStartPending, SizeOf(FStartPending));
  end
  else if Archive.Loading then
    for var i := 0 to 2 do
    begin
      FActiveAdd[i] := FRegisters[i * 8 + 3];
      FActiveMode[i] := FRegisters[i * 8 + 5];
      FStartPending[i] := False;
    end;
  if (FTime < 0) or (FTimer0 < 0) or (FTimer0 > 1024) or (FTimer1 < -1) then
    raise EReadError.Create('Invalid SCU timing state');

  for var i := 0 to 2 do
    if (FDMA[i].Remaining > $100000) or (FDMA[i].Source > $1FFFFFFF) or (FDMA[i].Dest > $1FFFFFFF) or (FDMA[i].Next < 0) or (FDMA[i].Phase > 8) then
      raise EReadError.Create('Invalid SCU DMA state');

  if Archive.Loading then
  begin
    FNextDMA := High(Int64);
    for var Ch := 0 to 2 do
      if FDMA[Ch].Active then
        FNextDMA := Min(FNextDMA, FDMA[Ch].Next);
    UpdateCPUHalt;
  end;
end;

end.

