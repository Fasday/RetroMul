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
    FDMA: array[0..2] of TSCUDMA;
    FRead: TSH2Read;
    FWrite: TSH2Write;
    FUser: Pointer;
    FIRQ: TSaturnIRQ;
    FTime, FTimer1: Int64;
    FTimer0: Integer;
    FDelivered: Cardinal;
    FReserve: TSCUReserve;
    FReady: TSCUReady;
    procedure DSPDone;
    procedure UpdateIRQ;
    procedure StartDMA(Channel: Integer);
    procedure LoadDescriptor(Channel: Integer);
    procedure DMASlot(Channel: Integer);
  public
    constructor Create(Read: TSH2Read; Write: TSH2Write; User: Pointer; IRQ: TSaturnIRQ);
    destructor Destroy; override;
    procedure SetExternal(Index: Integer; Active: Boolean);
    property DSP: TSCUDSP read FDSP;
    property Reserve: TSCUReserve read FReserve write FReserve;
    property Ready: TSCUReady read FReady write FReady;
    procedure Reset;
    function ReadRegister(Address: Cardinal; Size: Integer): Cardinal;
    procedure WriteRegister(Address, Value: Cardinal; Size: Integer);
    procedure Signal(Bit: Integer);
    procedure Acknowledge(Vector: Integer);
    procedure VBlankOut;
    procedure HBlank;
    procedure Advance(Target: Int64);
    procedure SerializeState(Archive: TStateArchive);
  end;

implementation

uses
  System.Math;

{$Q-}{$R-}

const
  Levels: array[0..31] of Byte = (15, 14, 13, 12, 11, 10, 9, 8, 8, 6, 6, 5, 3, 2, 0, 0, 7, 7, 7, 7, 4, 4, 4, 4, 1, 1, 1, 1, 1, 1, 1, 1);

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
  FRegisters[$A0 div 4] := $BFFF;
  FRegisters[$C8 div 4] := 4;
  for var I := 0 to 2 do
  begin
    FRegisters[(I * $20 + $0C) div 4] := $101;
    FRegisters[(I * $20 + $14) div 4] := 7;
  end;
  FDSP.Reset;
  FExternal := 0;
  FTime := 0;
  FTimer0 := 0;
  FTimer1 := -1;
  FDelivered := 0;
  UpdateIRQ;
end;

procedure TSaturnSCU.UpdateIRQ;
begin
  var Pending := FRegisters[$A4 div 4] and not FRegisters[$A0 div 4] and not FDelivered;
  if FRegisters[$A0 div 4] and $8000 <> 0 then
    Pending := Pending and $FFFF;
  var Level: Integer := 0;
  var Vector: Integer := 0;
  for var I := 0 to 31 do
    if (Pending and (Cardinal(1) shl I) <> 0) and (Levels[I] > Level) then
    begin
      Level := Levels[I];
      Vector := $40 + I;
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
  for var I := 0 to 2 do
    if (FRegisters[(I * $20 + $10) div 4] and $100 <> 0) and
      (((FRegisters[(I * $20 + $14) div 4] and 7) = Cardinal(Bit)) and (Bit in [0, 1, 2, 3, 4]) or
      ((FRegisters[(I * $20 + $14) div 4] and 7 = 5) and (Bit = 6)) or
      ((FRegisters[(I * $20 + $14) div 4] and 7 = 6) and (Bit = 13))) then
      StartDMA(I);
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
  FDMA[Channel].Remaining := FRead(FUser, D and $1FFFFFFF, 4) and $FFFFF;
  FDMA[Channel].Dest := FRead(FUser, (D + 4) and $1FFFFFFF, 4) and $1FFFFFFF;
  var Source := FRead(FUser, (D + 8) and $1FFFFFFF, 4);
  FDMA[Channel].Source := Source and $1FFFFFFF;
  FDMA[Channel].LastDescriptor := Source and $80000000 <> 0;
  Inc(FDMA[Channel].Descriptor, 12);
  if FDMA[Channel].Remaining = 0 then
    FDMA[Channel].Remaining := $100000;
end;

procedure TSaturnSCU.StartDMA(Channel: Integer);
begin
  if FDMA[Channel].Active then
    Exit;
  var B := Channel * 8;
  FDMA[Channel].Active := True;
  FDMA[Channel].Next := FTime + 4;
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
end;

procedure TSaturnSCU.DMASlot(Channel: Integer);
begin
  var B := Channel * 8;
  var Mode := FRegisters[B + 5];
  var Add := FRegisters[B + 3];
  var Size: Integer := Min(4, Integer(FDMA[Channel].Remaining));
  if Size = 3 then
    Size := 2;
  var Source := FDMA[Channel].Source;
  var Dest := FDMA[Channel].Dest;
  if ((Source or Dest) and Cardinal(Size - 1) <> 0) or (Dest < $00200000) or ((Dest >= $02000000) and (Dest < $05A00000)) then
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
    Inc(FDMA[Channel].Dest, Step * 2);
  end
  else
  begin
    FWrite(FUser, Dest, Data, Size);
    Inc(FDMA[Channel].Dest, Step);
  end;
  // Fixed source is available only in A-bus CS2, e.g. the CD data FIFO.
  if (Add and $100 <> 0) or (Source < $04000000) or (Source >= $05A00000) then
    Inc(FDMA[Channel].Source, Size);
  Dec(FDMA[Channel].Remaining, Size);
  if FDMA[Channel].Remaining = 0 then
  begin
    if (Mode and $1000000 <> 0) and not FDMA[Channel].LastDescriptor then
      LoadDescriptor(Channel)
    else
    begin
      FDMA[Channel].Active := False;
      FRegisters[B + 4] := 0;
      if Mode and $10000 <> 0 then
        FRegisters[B] := FDMA[Channel].Source;
      if Mode and $100 <> 0 then
        FRegisters[B + 1] := FDMA[Channel].Dest;
      Signal(11 - Channel);
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
  // Only one DMA bus transaction per slot; level 2 has highest priority.
  while True do
  begin
    var Ch: Integer := -1;
    var Next: Int64 := High(Int64);
    for var I := 2 downto 0 do
      if FDMA[I].Active and (FDMA[I].Next < Next) then
      begin
        Ch := I;
        Next := FDMA[I].Next;
      end;
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
          DMASlot(Ch);
          FDMA[Ch].Phase := 0;
          FDMA[Ch].Next := Next;
        end;
    end;
    for var I := 0 to 2 do
      if (I <> Ch) and FDMA[I].Active then
        FDMA[I].Next := Max(FDMA[I].Next, FDMA[Ch].Next);
  end;
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
  for var I := 0 to Size - 1 do
  begin
    var A: Integer := (Address + Cardinal(I)) and $FF;
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
  for var I := 0 to Size - 1 do
  begin
    var A: Integer := (Address + Cardinal(I)) and $FF;
    var Shift: Integer := (3 - (A and 3)) * 8;
    if A and $FC in [$7C, $C8] then
      Continue;
    var Mask: Cardinal := $FF shl Shift;
    var Bits: Cardinal := ((Value shr ((Size - I - 1) * 8)) and $FF) shl Shift;
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
      StartDMA(Ch);
  end;
  if (Address and $FC = $60) and (FRegisters[$60 div 4] and 1 <> 0) then
    for var Ch := 0 to 2 do
      FDMA[Ch].Active := False;
  UpdateIRQ;
end;

procedure TSaturnSCU.SerializeState(Archive: TStateArchive);
begin
  FDSP.SerializeState(Archive);
  Archive.Field(FExternal, SizeOf(FExternal));
  Archive.Field(FRegisters, SizeOf(FRegisters));
  Archive.Field(FDMA, SizeOf(FDMA));
  Archive.Field(FTime, SizeOf(FTime));
  Archive.Field(FTimer0, SizeOf(FTimer0));
  Archive.Field(FTimer1, SizeOf(FTimer1));
  Archive.Field(FDelivered, SizeOf(FDelivered));
  if (FTime < 0) or (FTimer0 < 0) or (FTimer0 > 1024) or (FTimer1 < -1) then
    raise EReadError.Create('Invalid SCU timing state');
  for var I := 0 to 2 do
    if (FDMA[I].Remaining > $100000) or (FDMA[I].Source > $1FFFFFFF) or (FDMA[I].Dest > $1FFFFFFF) or (FDMA[I].Next < 0) or (FDMA[I].Phase > 2) then
      raise EReadError.Create('Invalid SCU DMA state');
end;

end.

