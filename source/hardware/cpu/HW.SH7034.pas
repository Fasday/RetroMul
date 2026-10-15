unit HW.SH7034;

interface

uses
  System.SysUtils, System.Classes, HW.SH2, Core.Snapshots;

type
  TSH1DMAReady = function(Channel: Integer; Source, Dest: Cardinal): Boolean of object;

  TSH1DMAInput = function(Channel, Size: Integer): Cardinal of object;

  TSH1DMAOutput = procedure(Channel, Size: Integer; Value: Cardinal) of object;

  TSH1Serial = procedure(Channel: Integer; Value: Byte) of object;

  TSH1InstructionObserver = reference to procedure(const State: TSH2State);
  // SH-1 CPU and the SH7032/7034 peripheral register map. SH-1 instructions
  // share the existing interpreter; the on-chip devices are independent.

  TSH7034 = class
  private
    FCPU: TSH2;
    FRead: TSH2Read;
    FWrite: TSH2Write;
    FUser: Pointer;
    FRegisters: array[0..511] of Byte;
    FRAM: array[0..4095] of Byte;
    FTime: Int64;
    FTimerPhase: array[0..4] of Integer;
    FDMAPhase: Integer;
    FExecuting: Boolean;
    FAccessWait: Integer;
    FExternal: Byte;
    FPortBInputs: Word;
    FSerial: TSH1Serial;
    FDMAReady: TSH1DMAReady;
    FDMAInput: TSH1DMAInput;
    FDMAOutput: TSH1DMAOutput;
    FInstructionObserver: TSH1InstructionObserver;
    function R(Address, Size: Integer): Cardinal;
    procedure W(Address: Integer; Value: Cardinal; Size: Integer);
    procedure Tick(Cycles: Integer);
    procedure IRQ;
    function GetState: TSH2State;
  public
    constructor Create(Read: TSH2Read; Write: TSH2Write; User: Pointer);
    destructor Destroy; override;
    procedure Reset;
    function Read(Address: Cardinal; Size: Integer): Cardinal;
    procedure Write(Address, Value: Cardinal; Size: Integer);
    function Step: Integer;
    procedure Advance(Target: Int64);
    procedure SetIRQ(Line: Integer; Active: Boolean);
    procedure Receive(Channel: Integer; Value: Byte);
    procedure Capture(Channel: Integer; B: Boolean);
    function TransferDMA(Channel: Integer): Boolean;
    procedure SerializeState(Archive: TStateArchive);
    property State: TSH2State read GetState;
    property Time: Int64 read FTime;
    property Serial: TSH1Serial read FSerial write FSerial;
    property DMAReady: TSH1DMAReady read FDMAReady write FDMAReady;
    property DMAInput: TSH1DMAInput read FDMAInput write FDMAInput;
    property DMAOutput: TSH1DMAOutput read FDMAOutput write FDMAOutput;
    property InstructionObserver: TSH1InstructionObserver read FInstructionObserver write FInstructionObserver;
    property PortBInputs: Word read FPortBInputs write FPortBInputs;
  end;

implementation

{$Q-}{$R-}

const
  TimerBase: array[0..4] of Integer = ($104, $10E, $118, $122, $132);

function CPURead(User: Pointer; Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := TSH7034(User).Read(Address, Size);
end;

procedure CPUWrite(User: Pointer; Address, Value: Cardinal; Size: Integer);
begin
  TSH7034(User).Write(Address, Value, Size);
end;

constructor TSH7034.Create(Read: TSH2Read; Write: TSH2Write; User: Pointer);
begin
  inherited Create;
  FRead := Read;
  FWrite := Write;
  FUser := User;
  FCPU := TSH2.Create(CPURead, CPUWrite, Self, nil, True);
end;

destructor TSH7034.Destroy;
begin
  FCPU.Free;
  inherited;
end;

function TSH7034.GetState: TSH2State;
begin
  Result := FCPU.State;
end;

function TSH7034.R(Address, Size: Integer): Cardinal;
begin
  Result := 0;
  for var I := 0 to Size - 1 do
    Result := (Result shl 8) or FRegisters[(Address + I) and 511];
end;

procedure TSH7034.W(Address: Integer; Value: Cardinal; Size: Integer);
begin
  for var I := 0 to Size - 1 do
    FRegisters[(Address + I) and 511] := (Value shr ((Size - I - 1) * 8)) and $FF;
end;

procedure TSH7034.Reset;
begin
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FillChar(FRAM, SizeOf(FRAM), 0);
  FillChar(FTimerPhase, SizeOf(FTimerPhase), 0);
  FDMAPhase := 0;
  FExternal := 0;
  FTime := 0;
  FPortBInputs := $0400;
  for var B in [$C0, $C8] do
  begin
    W(B + 1, $FF, 1);
    W(B + 4, $84, 1);
  end;
  for var B in TimerBase do
  begin
    W(B + 1, 8, 1);
    W(B + 2, $F8, 1);
    W(B + 3, $F8, 1);
    W(B + 6, $FFFF, 2);
    W(B + 8, $FFFF, 2);
  end;
  FCPU.Reset;
end;

function TSH7034.Read(Address: Cardinal; Size: Integer): Cardinal;
begin
  Address := Address and $0FFFFFFF;
  if FExecuting and (Address < $0F000000) and ((Address >= $09000000) or (Address and $07000000 = $01000000)) then
    Inc(FAccessWait, ((Size + 1) div 2) * 2);
  if (Address >= $05FFFE00) and (Address <= $05FFFFFF) then
  begin
    Result := 0;
    var Direction := R($1C6, 2);
    var Pins: Word := (R($1C2, 2) and Direction) or (FPortBInputs and not Direction);
    for var I := 0 to Size - 1 do
    begin
      var A: Integer := (Address + Cardinal(I)) and $1FF;
      var V := R(A, 1);
      if A = $1C2 then
        V := Pins shr 8
      else if A = $1C3 then
        V := Pins and $FF;
      Result := (Result shl 8) or V;
    end;
    Exit;
  end;
  Result := 0;
  if Address >= $0F000000 then
    for var I := 0 to Size - 1 do
      Result := (Result shl 8) or FRAM[(Address + Cardinal(I)) and $FFF]
  else
    Result := FRead(FUser, Address, Size);
end;

procedure TSH7034.Write(Address, Value: Cardinal; Size: Integer);
begin
  Address := Address and $0FFFFFFF;
  if FExecuting and (Address < $0F000000) and ((Address >= $09000000) or (Address and $07000000 = $01000000)) then
    Inc(FAccessWait, ((Size + 1) div 2) * 2);
  if (Address >= $05FFFE00) and (Address <= $05FFFFFF) then
  begin
    var A: Integer := Address and $1FF;
    // ITU status bits are cleared by writing zero, never set by software.
    for var B in TimerBase do
      if A = B + 3 then
      begin
        W(A, R(A, 1) and (Value or $F8), 1);
        Exit;
      end;
    W(A, Value, Size);
    for var C := 0 to 1 do
    begin
      var B: Integer := $C0 + C * 8;
      if A = B + 3 then
      begin
        W(B + 4, R(B + 4, 1) or $84, 1);
        if Assigned(FSerial) and (R(B + 2, 1) and $20 <> 0) then
          FSerial(C, Value);
      end;
    end;
    IRQ;
    Exit;
  end;
  if Address >= $0F000000 then
    for var I := 0 to Size - 1 do
      FRAM[(Address + Cardinal(I)) and $FFF] := (Value shr ((Size - I - 1) * 8)) and $FF
  else
    FWrite(FUser, Address, Value, Size);
end;

procedure TSH7034.Receive(Channel: Integer; Value: Byte);
begin
  if not (Channel in [0, 1]) then
    raise EArgumentOutOfRangeException.Create('SH-1 SCI');
  var B: Integer := $C0 + Channel * 8;
  W(B + 5, Value, 1);
  W(B + 4, R(B + 4, 1) or $40, 1);
  IRQ;
end;

procedure TSH7034.Capture(Channel: Integer; B: Boolean);
begin
  if not (Channel in [0..4]) then
    raise EArgumentOutOfRangeException.Create('SH-1 input capture');
  var Base := TimerBase[Channel];
  W(Base + 6 + Ord(B) * 2, R(Base + 4, 2), 2);
  W(Base + 3, R(Base + 3, 1) or (1 shl Ord(B)), 1);
  IRQ;
end;

procedure TSH7034.SetIRQ(Line: Integer; Active: Boolean);
begin
  if not (Line in [0..7]) then
    raise EArgumentOutOfRangeException.Create('SH-1 IRQ');
  if Active then
    FExternal := FExternal or (1 shl Line)
  else
    FExternal := FExternal and not (1 shl Line);
  IRQ;
end;

procedure TSH7034.IRQ;
var
  Level, Vector: Integer;

  procedure Consider(L, V: Integer);
  begin
    if (L > Level) or ((L = Level) and (L > 0) and (V < Vector)) then
    begin
      Level := L;
      Vector := V;
    end;
  end;

begin
  Level := 0;
  Vector := 0;
  for var I := 0 to 7 do
    if FExternal and (1 shl I) <> 0 then
      Consider((R($184 + (I div 4) * 2, 2) shr ((3 - (I and 3)) * 4)) and 15, 64 + I);
  for var I := 0 to 3 do
    if R($14E + I * 16, 2) and 6 = 6 then
      Consider((R($188, 2) shr (12 - (I div 2) * 4)) and 15, 72 + I * 2);
  for var I := 0 to 4 do
  begin
    var B := TimerBase[I];
    var Pending := R(B + 2, 1) and R(B + 3, 1) and 7;
    var L: Integer;
    if I < 2 then
      L := (R($188, 2) shr (4 - I * 4)) and 15
    else
      L := (R($18A, 2) shr (20 - I * 4)) and 15;
    for var Bit := 0 to 2 do
      if Pending and (1 shl Bit) <> 0 then
        Consider(L, 80 + I * 4 + Bit);
  end;
  for var I := 0 to 1 do
    if (R($C2 + I * 8, 1) and $40 <> 0) and (R($C4 + I * 8, 1) and $40 <> 0) then
    begin
      var L: Integer;
      if I = 0 then
        L := R($18A, 2) and 15
      else
        L := (R($18C, 2) shr 12) and 15;
      Consider(L, 101 + I * 4);
    end;
  FCPU.Interrupt(Level, Vector);
end;

procedure TSH7034.Tick(Cycles: Integer);
begin
  Inc(FTime, Cycles);
  for var I := 0 to 4 do
    if R($100, 1) and (1 shl I) <> 0 then
    begin
      var B := TimerBase[I];
      var Control := R(B, 1);
      var Scale := Control and 7;
      if Scale > 3 then
        Continue;
      var Divider := 1 shl Scale;
      Inc(FTimerPhase[I], Cycles);
      while FTimerPhase[I] >= Divider do
      begin
        Dec(FTimerPhase[I], Divider);
        var Count: Word := (R(B + 4, 2) + 1) and $FFFF;
        var Flags := R(B + 3, 1);
        if Count = 0 then
          Flags := Flags or 4;
        if Count = R(B + 6, 2) then
        begin
          Flags := Flags or 1;
          if (Control shr 5) and 3 = 1 then
            Count := 0;
        end;
        if Count = R(B + 8, 2) then
        begin
          Flags := Flags or 2;
          if (Control shr 5) and 3 = 2 then
            Count := 0;
        end;
        W(B + 4, Count, 2);
        W(B + 3, Flags, 1);
      end;
    end;
  Inc(FDMAPhase, Cycles);
  while FDMAPhase >= 2 do
  begin
    Dec(FDMAPhase, 2);
    if R($148, 2) and 7 <> 1 then
      Continue;
    for var I := 0 to 3 do
      if TransferDMA(I) then
        Break;
  end;
  IRQ;
end;

function TSH7034.TransferDMA(Channel: Integer): Boolean;
begin
  if not (Channel in [0..3]) then
    raise EArgumentOutOfRangeException.Create('SH-1 DMA channel');
  Result := False;
  if R($148, 2) and 7 <> 1 then
    Exit;
  var B: Integer := $140 + Channel * 16;
  var Control := R(B + 14, 2);
  if Control and 3 <> 1 then
    Exit;
  var Source := R(B, 4);
  var Dest := R(B + 4, 4);
  if Assigned(FDMAReady) and not FDMAReady(Channel, Source, Dest) then
    Exit;
  var Size: Integer := 1;
  if Control and 8 <> 0 then
    Size := 2;
  var Resource: Integer := (Control shr 8) and 15;
  var Address := Source or Dest;
  if Resource = 3 then
    Address := Dest
  else if Resource = 2 then
    Address := Source;
  if Address and Cardinal(Size - 1) <> 0 then
  begin
    W($148, R($148, 2) or 4, 2);
    IRQ;
    Exit;
  end;
  // In single-address mode the DACK endpoint is not addressed by SAR/DAR.
  var Data: Cardinal;
  if (Resource = 3) and Assigned(FDMAInput) then
    Data := FDMAInput(Channel, Size)
  else
    Data := Read(Source, Size);
  if (Resource = 2) and Assigned(FDMAOutput) then
    FDMAOutput(Channel, Size, Data)
  else
    Write(Dest, Data, Size);
  case (Control shr 12) and 3 of
    1:
      Inc(Source, Size);
    2:
      Dec(Source, Size);
  end;
  case (Control shr 14) and 3 of
    1:
      Inc(Dest, Size);
    2:
      Dec(Dest, Size);
  end;
  W(B, Source, 4);
  W(B + 4, Dest, 4);
  var Count: Word := (R(B + 10, 2) - 1) and $FFFF;
  W(B + 10, Count, 2);
  if Count = 0 then
    W(B + 14, Control or 2, 2);
  IRQ;
  Result := True;
end;

function TSH7034.Step: Integer;
begin
  if Assigned(FInstructionObserver) then
    FInstructionObserver(FCPU.State);
  FAccessWait := 0;
  FExecuting := True;
  try
    Result := FCPU.Step + FAccessWait;
  finally
    FExecuting := False;
  end;
  Tick(Result);
end;

procedure TSH7034.Advance(Target: Int64);
begin
  if Target < FTime - 16 then
    raise EArgumentOutOfRangeException.Create('SH-1 time');
  while FTime < Target do
    Step;
end;

procedure TSH7034.SerializeState(Archive: TStateArchive);
begin
  FCPU.SerializeState(Archive);
  Archive.Field(FRegisters, SizeOf(FRegisters));
  Archive.Field(FRAM, SizeOf(FRAM));
  Archive.Field(FTime, SizeOf(FTime));
  Archive.Field(FTimerPhase, SizeOf(FTimerPhase));
  Archive.Field(FDMAPhase, SizeOf(FDMAPhase));
  Archive.Field(FExternal, SizeOf(FExternal));
  Archive.Field(FPortBInputs, SizeOf(FPortBInputs));
  if FTime < 0 then
    raise EReadError.Create('Invalid SH-1 timing state');
  if Archive.Loading then
    IRQ;
end;

end.

