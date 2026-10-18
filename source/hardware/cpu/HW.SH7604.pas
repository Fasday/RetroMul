unit HW.SH7604;

interface

uses
  System.SysUtils, System.Classes, HW.SH2, Core.Snapshots;

type
  TSH7604Wait = function(User: Pointer; Address: Cardinal; Size: Integer; Writing: Boolean): Integer;

  TSH7604DMAReserve = function(User: Pointer; At: Int64; Address: Cardinal; Size: Integer; Writing: Boolean): Int64;

  TSH7604DMAReady = function(User: Pointer; Address: Cardinal; Size: Integer; Writing: Boolean): Boolean;

  TSH7604State = record
    CacheRAM: array[0..4095] of Byte;
    Peripheral: array[0..511] of Byte;
    CacheTag: array[0..3, 0..63] of Cardinal;
    CacheLRU: array[0..63] of Byte;
    FRC, FRTPhase, ICR: Word;
    OCR: array[0..1] of Word;
    FRTTemp, FRTReadFlags, WDTReadFlags: Byte;
    Time, DMANext, DIVUntil: Int64;
    WDTPhase: Integer;
    DMAPriority: Integer;
    DREQ: array[0..1] of Boolean;
    DIVQuotient, DIVRemainder: Cardinal;
    DIVOverflow: Boolean;
    DMAPhase, DMABlockUnit, DMASize: array[0..1] of Byte;
    DMAValue, DMAControl, DMASource, DMADest: array[0..1] of Cardinal;
  end;

  // SH7604 on-chip devices shared by Saturn and other SH-2 boards.
  // Cache/FRT/DMAC algorithms originate in RetroMul's MD.Mars implementation.
  // Bus callbacks receive physical addresses; DMA never snoops the CPU cache.
  TSH7604 = class
  private
    FCPU: TSH2;
    FState: TSH7604State;
    FRead: TSH2Read;
    FReadDMA: TSH2Read;
    FWrite: TSH2Write;
    FWait: TSH7604Wait;
    FReserveDMA: TSH7604DMAReserve;
    FDMAReady: TSH7604DMAReady;
    FUser: Pointer;
    FAccessWait, FExternalLevel, FExternalVector: Integer;
    FExecuting, FNMI: Boolean;
    FFetchLine: Cardinal;
    FFetchData: Pointer;
    FFetchLRU: PByte;
    FFetchLRUMask, FFetchLRUBits: Byte;
    FCacheBank: TSH2CacheBank;
    FDataCache: array[0..63] of TSH2DataCacheView; // derived last selected data line for each hardware cache index
    FPeripheralAt, FPeripheralNext: Int64; // derived timer synchronization, not serialized
    FIRQDirty: Boolean; // derived pending-interrupt cache, not hardware state
    FExternalSelected, FExternalAccepted: Boolean;
    FSlaveMode: Boolean;
    function StepChecked: Integer;
    function Peek(Index, Size: Integer): Cardinal; inline;
    procedure Store(Index: Integer; Value: Cardinal; Size: Integer); inline;
    function PeripheralRead(Address: Cardinal; Size: Integer): Cardinal;
    procedure PeripheralWrite(Address, Value: Cardinal; Size: Integer);
    procedure UpdateIRQ;
    procedure SynchronizePeripherals(Force: Boolean = False);
    procedure SchedulePeripherals;
    procedure AdvanceFRTBatch(Ticks: Int64);
    procedure AdvanceDMA(Target: Int64);
    function RunDMA(Channel: Integer): Boolean;
    procedure StartDivision(Is64: Boolean);
    procedure WaitDivision;
    procedure FinishDivision;
    procedure BusWait(Address: Cardinal; Size: Integer; Writing: Boolean);
    function FetchInstruction(Address: Cardinal): Cardinal; inline;
    function GetState: TSH2State;
    procedure SetState(const Value: TSH2State);
  public
    constructor Create(Read: TSH2Read; Write: TSH2Write; User: Pointer; Wait: TSH7604Wait = nil; SlaveMode: Boolean = False);
    destructor Destroy; override;
    procedure Reset;
    procedure SetOpcodeDecoder(Decoder: TSH2OpcodeDecoder);
    procedure Hold(Clocks: Integer);
    function Step: Integer;
    // Issue only through the cache/internal fast path while another master
    // owns the external bus. Zero leaves the instruction pending.
    function StepBusReleased: Integer;
    procedure Advance(Target: Int64); inline;
    // Board scheduler only: Target is already known to be monotonic.
    procedure AdvanceForward(Target: Int64); inline;
    function Read(Address: Cardinal; Size: Integer; Instruction: Boolean = False): Cardinal;
    procedure Write(Address, Value: Cardinal; Size: Integer);
    procedure Interrupt(Level, Vector: Integer);
    procedure NMI;
    procedure InputCapture;
    procedure ExternalClock;
    procedure SetDREQ(Channel: Integer; Value: Boolean);
    procedure SerializeState(Archive: TStateArchive);
    property State: TSH2State read GetState write SetState;
    property ExternalInterruptAccepted: Boolean read FExternalAccepted;
    property ReserveDMA: TSH7604DMAReserve read FReserveDMA write FReserveDMA;
    property DMAReady: TSH7604DMAReady read FDMAReady write FDMAReady;
    property DMARead: TSH2Read read FReadDMA write FReadDMA;
  end;

procedure SH7604TouchLRU(var Value: Byte; Way: Integer); inline;

implementation

uses
  System.Math;

// Fixed-width architectural wrap is intentional. Public ranges are checked.
{$Q+}{$R+}

procedure SH7604TouchLRU(var Value: Byte; Way: Integer);
begin
  case Way of
    0:
      Value := Value and $07;
    1:
      Value := (Value and $19) or $20;
    2:
      Value := (Value and $2A) or $14;
    3:
      Value := (Value and $34) or $0B;
  end;
end;

// These derived pointers address this CPU's own cache arrays. Cache tag,
// register and snapshot changes invalidate the selected line before reuse.
{$Q-}{$R-}
function TSH7604.FetchInstruction(Address: Cardinal): Cardinal;
begin
  // Sequential instruction fetches reuse the selected hardware cache line.
  // Every fill/tag write/purge/CCR write invalidates this derived shortcut;
  // data writes remain visible because instruction bytes are read from CacheRAM.
  if Address and $FFFFFFF0 = FFetchLine then
  begin
    FFetchLRU^ := (FFetchLRU^ and FFetchLRUMask) or FFetchLRUBits;
    Exit(Swap(PWord(NativeUInt(FFetchData) + (Address and 15))^));
  end;
  Result := Read(Address, 2, True);
end;

{$Q+}{$R+}

function CPURead(User: Pointer; Address: Cardinal; Size: Integer): Cardinal;
begin
  var Device := TSH7604(User);
  // The interpreter has already checked alignment. TCSR polling only latches
  // the read-to-clear flags; Advance commits timer transitions at deadlines.
  if (Address = $FFFFFE11) and (Size = 1) then
  begin
    Result := Device.FState.Peripheral[$11];
    Device.FState.FRTReadFlags := Result;
    Exit;
  end;
  Result := Device.Read(Address, Size);
end;

function CPUFetch(User: Pointer; Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := TSH7604(User).FetchInstruction(Address);
end;

procedure CPUWrite(User: Pointer; Address, Value: Cardinal; Size: Integer);
begin
  TSH7604(User).Write(Address, Value, Size);
end;

constructor TSH7604.Create(Read: TSH2Read; Write: TSH2Write; User: Pointer; Wait: TSH7604Wait; SlaveMode: Boolean);
begin
  inherited Create;
  if not Assigned(Read) or not Assigned(Write) then
    raise EArgumentException.Create('SH7604 requires a bus');
  FRead := Read;
  FReadDMA := Read;
  FWrite := Write;
  FUser := User;
  FWait := Wait;
  FSlaveMode := SlaveMode;
  FFetchLine := High(Cardinal);
  if FCPU <> nil then
    FCPU.InvalidateInstructionLine;
  FillChar(FDataCache, SizeOf(FDataCache), $FF);
  FCPU := TSH2.Create(CPURead, CPUWrite, Self, CPUFetch);
  // Advance commits flag transitions before instruction issue. TCSR byte
  // reads only copy those flags into FRTReadFlags, without a bus transfer.
  FCPU.SetByteReadLatch($FFFFFE11, @FState.Peripheral[$11], @FState.FRTReadFlags);
  FCPU.SetDataCacheView(@FDataCache[0], True);
  FCacheBank.Tags := @FState.CacheTag[0, 0];
  FCacheBank.RAM := @FState.CacheRAM[0];
  FCacheBank.LRU := @FState.CacheLRU[0];
  FCacheBank.CCR := @FState.Peripheral[$92];
  FCPU.SetCacheBank(@FCacheBank);
end;

destructor TSH7604.Destroy;
begin
  FCPU.Free;
  inherited;
end;

function TSH7604.GetState: TSH2State;
begin
  Result := FCPU.State;
end;

procedure TSH7604.SetState(const Value: TSH2State);
begin
  FCPU.State := Value;
end;

procedure TSH7604.SetOpcodeDecoder(Decoder: TSH2OpcodeDecoder);
begin
  FCPU.SetOpcodeDecoder(Decoder, FUser);
end;

procedure TSH7604.Reset;
begin
  FFetchLine := High(Cardinal);
  if FCPU <> nil then
    FCPU.InvalidateInstructionLine;
  FillChar(FDataCache, SizeOf(FDataCache), $FF);
  FExternalAccepted := False;
  FIRQDirty := True;
  FState := Default(TSH7604State);
  FExternalLevel := 0;
  FExternalVector := 0;
  FNMI := False;
  FState.OCR[0] := $FFFF;
  FState.OCR[1] := $FFFF;
  FState.Peripheral[$10] := 1;
  FState.Peripheral[$17] := $E0;
  FState.Peripheral[$04] := $84; // SCI idle TDRE/TEND
  FState.Peripheral[$80] := $18;
  FState.Peripheral[$82] := $1F;
  Store($1E0, $03F0 or (Cardinal(Ord(FSlaveMode)) shl 15), 4);
  Store($1E4, $00FC, 4);
  Store($1E8, $AAFF, 4);
  FState.DMAPriority := 1;
  FExecuting := False;
  FAccessWait := 0;
  FCPU.Reset;
  FPeripheralAt := FState.Time;
  SchedulePeripherals;
end;

// Private register access wraps within the 512-byte on-chip register file.
// Aligned words/longwords use the same packed big-endian path as Saturn RAM.
{$Q-}{$R-}
function TSH7604.Peek(Index, Size: Integer): Cardinal;
begin
  var At := Index and $1FF;
  case Size of
    1:
      Exit(FState.Peripheral[At]);
    2:
      if At <= $1FE then
        Exit(Swap(PWord(@FState.Peripheral[At])^));
    4:
      if At <= $1FC then
      begin
        var V := PCardinal(@FState.Peripheral[At])^;
        Exit((V shl 24) or ((V and $FF00) shl 8) or
          ((V shr 8) and $FF00) or (V shr 24));
      end;
  end;
  Result := 0;
  for var I := 0 to Size - 1 do
    Result := (Result shl 8) or FState.Peripheral[(Index + I) and $1FF];
end;

procedure TSH7604.Store(Index: Integer; Value: Cardinal; Size: Integer);
begin
  var At := Index and $1FF;
  case Size of
    1:
      begin
        var B := Byte(Value);
        if FState.Peripheral[At] <> B then
        begin
          FState.Peripheral[At] := B;
          FIRQDirty := True;
        end;
        Exit;
      end;
    2:
      if At <= $1FE then
      begin
        var W := Swap(Word(Value));
        if PWord(@FState.Peripheral[At])^ <> W then
        begin
          PWord(@FState.Peripheral[At])^ := W;
          FIRQDirty := True;
        end;
        Exit;
      end;
    4:
      if At <= $1FC then
      begin
        var V := (Value shl 24) or ((Value and $FF00) shl 8) or
          ((Value shr 8) and $FF00) or (Value shr 24);
        if PCardinal(@FState.Peripheral[At])^ <> V then
        begin
          PCardinal(@FState.Peripheral[At])^ := V;
          FIRQDirty := True;
        end;
        Exit;
      end;
  end;
  for var I := 0 to Size - 1 do
  begin
    At := (Index + I) and $1FF;
    var B := Byte(Value shr ((Size - I - 1) * 8));
    if FState.Peripheral[At] <> B then
    begin
      FState.Peripheral[At] := B;
      FIRQDirty := True;
    end;
  end;
end;
{$Q+}{$R+}

procedure TSH7604.BusWait(Address: Cardinal; Size: Integer; Writing: Boolean);
begin
  if FExecuting and Assigned(FWait) then
    Inc(FAccessWait, Max(0, FWait(FUser, Address and $1FFFFFFF, Size, Writing) - 1));
end;

// The caller checks size/alignment before entering this native cache path.
{$Q-}{$R-}
function CacheValue(Data: Pointer; Size: Integer): Cardinal; inline;
begin
  case Size of
    1:
      Result := PByte(Data)^;
    2:
      Result := Swap(PWord(Data)^);
  else
    var V := PCardinal(Data)^;
    Result := (V shl 24) or ((V and $FF00) shl 8) or
      ((V shr 8) and $FF00) or (V shr 24);
  end;
end;

// Width/alignment are validated explicitly; cache ways and offsets are masked.
{$Q-}{$R-}
function TSH7604.Read(Address: Cardinal; Size: Integer; Instruction: Boolean): Cardinal;
begin
  if not (Size in [1, 2, 4]) then
    raise EArgumentException.Create('SH7604 access size');
  if Address and Cardinal(Size - 1) <> 0 then
    raise EArgumentException.Create('Unaligned SH7604 access');
  if Address >= $FFFFFE00 then
  begin
    // Advance already commits timer flag/IRQ transitions at their deadline.
    // Only reads of live counters need to bring the fractional phase forward;
    // polling TCSR/WTCSR or fixed registers must not repeatedly reschedule FRT.
    if (Address = $FFFFFE11) and (Size = 1) then
    begin
      Result := FState.Peripheral[$11];
      FState.FRTReadFlags := Result;
      Exit;
    end;
    var Index := Address and $1FF;
    if ((Index <= $12) and (Index + Cardinal(Size) > $12)) or
      ((Index <= $81) and (Index + Cardinal(Size) > $81)) or
      ((Index >= $100) and (Index <= $11F)) then
      SynchronizePeripherals;
    if (Address >= $FFFFFF00) and (Address <= $FFFFFF1F) then
      WaitDivision;
    Exit(PeripheralRead(Address, Size));
  end;
  var Entry: Integer := (Address shr 4) and 63;
  // A data read can reuse its last selected hardware cache line. The
  // pointer addresses live cache RAM, so CPU/debug writes remain visible.
  // Evictions, tags, CCR/purge and state load invalidate both shortcuts.
  if not Instruction and (Address and $FFFFFFF0 = FDataCache[Entry].Line) then
  begin
    FDataCache[Entry].LRU^ := (FDataCache[Entry].LRU^ and FDataCache[Entry].Mask) or FDataCache[Entry].Bits;
    Exit(CacheValue(Pointer(NativeUInt(FDataCache[Entry].Data) + (Address and 15)), Size));
  end;
  var Area := Address shr 29;
  var CCR := FState.Peripheral[$92];
  if Area = 3 then
    Exit(FState.CacheTag[(CCR shr 6) and 3, Entry] or (Cardinal(FState.CacheLRU[Entry]) shl 4));
  if Area = 6 then
  begin
    Result := 0;
    for var I := 0 to Size - 1 do
      Result := (Result shl 8) or FState.CacheRAM[(UInt64(Address) + Cardinal(I)) and $FFF];
    Exit;
  end;
  if (Area = 0) and (CCR and 1 <> 0) then
  begin
    var Tag: Cardinal := (Address and $1FFFFC00) or 2;
    var Way: Integer := -1;
    // Preserve the former last-match rule for debug-created duplicate tags.
    if FState.CacheTag[3, Entry] = Tag then
      Way := 3
    else if FState.CacheTag[2, Entry] = Tag then
      Way := 2
    else if FState.CacheTag[1, Entry] = Tag then
      Way := 1
    else if FState.CacheTag[0, Entry] = Tag then
      Way := 0;
    if (Way < 0) and (CCR and (4 shr Ord(Instruction)) = 0) then
    begin
      var LRU := FState.CacheLRU[Entry];
      if CCR and 8 <> 0 then
        Way := 2 + Ord(LRU and 1 = 0)
      else if LRU and $38 = $38 then
        Way := 0
      else if LRU and $26 = $06 then
        Way := 1
      else if LRU and $15 = $01 then
        Way := 2
      else
        Way := 3;
      var Base := Address and $1FFFFFF0;
      BusWait(Base, 16, False);
      for var I := 0 to 3 do
      begin
        var V := FRead(FUser, Base + Cardinal(I * 4), 4);
        PCardinal(@FState.CacheRAM[Way * 1024 + Entry * 16 + I * 4])^ :=
          (V shl 24) or ((V and $FF00) shl 8) or ((V shr 8) and $FF00) or (V shr 24);
      end;
      // Only the affected cache index can evict the selected code line.
      if (FFetchLine shr 4) and 63 = Cardinal(Entry) then
      begin
        FFetchLine := High(Cardinal);
      end;
      // The interpreter can select another valid instruction line itself.
      if FCPU <> nil then
        FCPU.InvalidateInstructionLine;
      FDataCache[Entry].Line := High(Cardinal);
      FState.CacheTag[Way, Entry] := Tag;
    end;
    if Way >= 0 then
    begin
      SH7604TouchLRU(FState.CacheLRU[Entry], Way);
      var At := Way * 1024 + Entry * 16 + Integer(Address and 15);
      if Instruction then
      begin
        FFetchLine := Address and $FFFFFFF0;
        FFetchData := @FState.CacheRAM[Way * 1024 + Entry * 16];
        FFetchLRU := @FState.CacheLRU[Entry];
        case Way of
          0:
            begin
              FFetchLRUMask := $07;
              FFetchLRUBits := $00;
            end;
          1:
            begin
              FFetchLRUMask := $19;
              FFetchLRUBits := $20;
            end;
          2:
            begin
              FFetchLRUMask := $2A;
              FFetchLRUBits := $14;
            end;
          3:
            begin
              FFetchLRUMask := $34;
              FFetchLRUBits := $0B;
            end;
        end;
        FCPU.SetInstructionLine(FFetchLine, FFetchData, FFetchLRU, FFetchLRUMask, FFetchLRUBits);
      end;
      if not Instruction then
      begin
        FDataCache[Entry].Line := Address and $FFFFFFF0;
        FDataCache[Entry].Data := @FState.CacheRAM[Way * 1024 + Entry * 16];
        FDataCache[Entry].LRU := @FState.CacheLRU[Entry];
        case Way of
          0:
            begin
              FDataCache[Entry].Mask := $07;
              FDataCache[Entry].Bits := $00;
            end;
          1:
            begin
              FDataCache[Entry].Mask := $19;
              FDataCache[Entry].Bits := $20;
            end;
          2:
            begin
              FDataCache[Entry].Mask := $2A;
              FDataCache[Entry].Bits := $14;
            end;
          3:
            begin
              FDataCache[Entry].Mask := $34;
              FDataCache[Entry].Bits := $0B;
            end;
        end;
      end;
      Result := CacheValue(@FState.CacheRAM[At], Size);
      Exit;
    end;
  end;
  BusWait(Address, Size, False);
  Result := FRead(FUser, Address and $1FFFFFFF, Size);
end;

procedure TSH7604.Write(Address, Value: Cardinal; Size: Integer);
begin
  if not (Size in [1, 2, 4]) then
    raise EArgumentException.Create('SH7604 access size');

  if Address and Cardinal(Size - 1) <> 0 then
    raise EArgumentException.Create('Unaligned SH7604 access');

  if Address >= $FFFFFE00 then
  begin
    SynchronizePeripherals;
    if (Address >= $FFFFFF00) and (Address <= $FFFFFF1F) then
      WaitDivision;
    PeripheralWrite(Address, Value, Size);
    SchedulePeripherals;
    Exit;
  end;

  var Area := Address shr 29;
  var Entry: Integer := (Address shr 4) and 63;
  var Tag := Address and $1FFFFC00;
  var CCR := FState.Peripheral[$92];
  if Area = 2 then
  begin
    FFetchLine := High(Cardinal);
    if FCPU <> nil then
      FCPU.InvalidateInstructionLine;
    FDataCache[Entry].Line := High(Cardinal);
    for var I := 0 to 3 do
      if FState.CacheTag[I, Entry] and $1FFFFC00 = Tag then
        FState.CacheTag[I, Entry] := 0;
    Exit;
  end;

  if Area = 3 then
  begin
    FFetchLine := High(Cardinal);
    if FCPU <> nil then
      FCPU.InvalidateInstructionLine;
    FDataCache[Entry].Line := High(Cardinal);
    FState.CacheTag[(CCR shr 6) and 3, Entry] := Tag or ((Address shr 1) and 2);
    FState.CacheLRU[Entry] := (Value shr 4) and 63;
    Exit;
  end;

  if Area = 6 then
  begin
    for var I := 0 to Size - 1 do
      FState.CacheRAM[(UInt64(Address) + Cardinal(I)) and $FFF] := (Value shr ((Size - I - 1) * 8)) and $FF;
    Exit;
  end;

  if (Area = 0) and (CCR and 1 <> 0) then
    for var Way := 0 to 3 do
      if FState.CacheTag[Way, Entry] = (Tag or 2) then
      begin
        var Data := @FState.CacheRAM[Way * 1024 + Entry * 16 + Integer(Address and 15)];
        case Size of
          1:
            PByte(Data)^ := Byte(Value);
          2:
            PWord(Data)^ := Swap(Word(Value));
          4:
            PCardinal(Data)^ := (Value shl 24) or ((Value and $FF00) shl 8) or
              ((Value shr 8) and $FF00) or (Value shr 24);
        end;
        SH7604TouchLRU(FState.CacheLRU[Entry], Way);
      end;
  BusWait(Address, Size, True);
  FWrite(FUser, Address and $1FFFFFFF, Value, Size);
end;

{$Q+}{$R+}

function TSH7604.PeripheralRead(Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := 0;
  for var I := 0 to Size - 1 do
  begin
    var Index: Integer := (UInt64(Address) + Cardinal(I)) and $1FF;
    var Value := FState.Peripheral[Index];
    case Index of
      $11:
        FState.FRTReadFlags := Value;
      $12:
        begin
          Value := FState.FRC shr 8;
          FState.FRTTemp := FState.FRC and $FF;
        end;
      $13:
        Value := FState.FRTTemp;
      $14:
        begin
          Value := FState.OCR[Ord(FState.Peripheral[$17] and $10 <> 0)] shr 8;
          FState.FRTTemp := FState.OCR[Ord(FState.Peripheral[$17] and $10 <> 0)] and $FF;
        end;
      $15:
        Value := FState.FRTTemp;
      $18:
        begin
          Value := FState.ICR shr 8;
          FState.FRTTemp := FState.ICR and $FF;
        end;
      $19:
        Value := FState.FRTTemp;
      $80:
        begin
          FState.WDTReadFlags := Value;
          Value := Value or $18; // WTCSR reserved bits 4 and 3 always read as one.
        end;
    end;
    Result := (Result shl 8) or Value;
  end;
end;

procedure TSH7604.FinishDivision;
begin
  Store($104, FState.DIVQuotient, 4);
  Store($114, FState.DIVQuotient, 4);
  Store($11C, FState.DIVQuotient, 4);
  Store($110, FState.DIVRemainder, 4);
  Store($118, FState.DIVRemainder, 4);
  if FState.DIVOverflow then
    Store($10B, Peek($10B, 1) or 1, 1);
  FState.DIVUntil := 0;
end;

procedure TSH7604.WaitDivision;
begin
  // SH7604 manual 10.4.1: every DIVU access extends the issuing CPU
  // instruction until the current division completes. Debug reads do not
  // advance emulated time. The scheduler charges the stall to this CPU.
  if FExecuting and (FState.DIVUntil <> 0) then
  begin
    Inc(FAccessWait, Integer(Max(Int64(0), FState.DIVUntil - FState.Time - FAccessWait)));
    FinishDivision;
  end;
end;

procedure TSH7604.StartDivision(Is64: Boolean);
begin
  var Divisor := Integer(Peek($100, 4));
  var Dividend: Int64 := Integer(Peek($104, 4));
  if Is64 then
    Dividend := Int64((UInt64(Peek($110, 4)) shl 32) or Peek($114, 4));
  var Q: Int64;
  var R: Int64 := 0;
  if (Divisor = 0) or ((Dividend = Low(Int64)) and (Divisor = -1)) then
    Q := Int64(High(Integer)) + 1
  else
  begin
    Q := Dividend div Divisor;
    R := Dividend mod Divisor;
  end;
  FState.DIVOverflow := (Q < Low(Integer)) or (Q > High(Integer));
  if FState.DIVOverflow then
  begin
    Q := High(Integer);
    if Dividend < 0 then
      Q := Low(Integer);
  end;
  FState.DIVQuotient := Cardinal(Q);
  FState.DIVRemainder := Cardinal(R);
  FState.DIVUntil := FState.Time + 39;
  if FExecuting then
    Inc(FState.DIVUntil, FAccessWait);
end;

procedure TSH7604.PeripheralWrite(Address, Value: Cardinal; Size: Integer);
begin
  // MOV.W passes the complete source register, including sign-extended bits.
  // Keyed WDT/BSC registers see only the bits driven by that bus access.
  case Size of
    1:
      Value := Value and $FF;
    2:
      Value := Value and $FFFF;
  end;
  // FRT/DIVU/etc. cannot alter cache tags/storage. CCR can disable or purge.
  if (Address and $1FF <= $92) and ((Address and $1FF) + Cardinal(Size) > $92) then
  begin
    FFetchLine := High(Cardinal);
    if FCPU <> nil then
      FCPU.InvalidateInstructionLine;
    FillChar(FDataCache, SizeOf(FDataCache), $FF);
  end;
  var Index: Integer := Address and $1FF;
  if (Index >= $1E0) and (Index <= $1FB) then
  begin
    var Base := Index and not 3;
    var Current: Cardinal;
    if Size = 4 then
    begin
      if Value shr 16 <> $A55A then
        Exit;
      Current := Value and $FFFF;
    end
    else if (Size = 2) and (Index and 3 = 2) then
      Current := Value
    else
      Exit;
    if Base = $1E0 then
      Current := (Current and $1FF7) or (Cardinal(Ord(FSlaveMode)) shl 15);
    Store(Base, Current and $FFFF, 4);
    Exit;
  end;
  if Index in [$80, $82] then
  begin
    if Size <> 2 then
      Exit;
    if (Index = $80) and (Value shr 8 = $5A) then
      Store($81, Value, 1)
    else if (Index = $80) and (Value shr 8 = $A5) then
    begin
      var Control := (Value and $7F) or (Peek($80, 1) and $80 and not (Cardinal(FState.WDTReadFlags) and not Value));
      if Control and $20 = 0 then
      begin
        // Stopping WDT also cancels a pending interval interrupt, even when
        // software has not read OVF before writing WTCSR.
        Control := Control and $7F;
        FState.WDTPhase := 0;
        Store($81, 0, 1);
      end;
      Store($80, Control, 1);
    end
    else if (Index = $82) and (Value shr 8 = $A5) then
      Store($82, (Peek($82, 1) and $80) or (Value and $60) or $1F, 1)
    else if (Index = $82) and (Value shr 8 = $5A) and (Value and $80 = 0) then
      Store($82, Peek($82, 1) and $7F, 1);
    Exit;
  end;
  for var I := 0 to Size - 1 do
  begin
    var R: Integer := (Index + I) and $1FF;
    var B: Byte := (Value shr ((Size - 1 - I) * 8)) and $FF;
    case R of
      $10:
        Store(R, (B and $8E) or 1, 1);
      $11:
        begin
          Store(R, (Peek(R, 1) and ($8E and not (Cardinal(FState.FRTReadFlags) and not B))) or (B and 1), 1);
          FState.FRTReadFlags := 0;
        end;
      $12, $14:
        FState.FRTTemp := B;
      $13:
        FState.FRC := (Word(FState.FRTTemp) shl 8) or B;
      $15:
        FState.OCR[Ord(Peek($17, 1) and $10 <> 0)] := (Word(FState.FRTTemp) shl 8) or B;
      $16:
        Store(R, B and $83, 1);
      $17:
        Store(R, (B and $13) or $E0, 1);
      $18, $19:
        ;
      $92:
        begin
          if B and $10 <> 0 then
          begin
            FillChar(FState.CacheTag, SizeOf(FState.CacheTag), 0);
            FillChar(FState.CacheLRU, SizeOf(FState.CacheLRU), 0);
          end;
          Store(R, B and $CF, 1);
        end;
    else
      Store(R, B, 1);
    end;
  end;
  if (Size = 4) and ((Index = $104) or (Index = $114)) then
    StartDivision(Index = $114);
  UpdateIRQ;
end;

procedure TSH7604.UpdateIRQ;
begin
  if not FIRQDirty then
    Exit;
  FIRQDirty := False;
  var Level := FExternalLevel;
  var Vector := FExternalVector;
  FExternalSelected := Level > 0;
  var Flags := Peek($10, 1) and Peek($11, 1) and $8E;
  var Priority: Integer := Peek($60, 1) and 15;
  if (Flags <> 0) and (Priority > Level) then
  begin
    Level := Priority;
    if Flags and $80 <> 0 then
      Vector := Peek($66, 1) and $7F
    else if Flags and $C <> 0 then
      Vector := Peek($67, 1) and $7F
    else
      Vector := Peek($68, 1) and $7F;
    FExternalSelected := False;
  end;
  Priority := Peek($E2, 1) and 15;
  for var I := 0 to 1 do
    if (Peek($18C + I * 16, 4) and 6 = 6) and (Priority > Level) then
    begin
      Level := Priority;
      Vector := Peek($1A0 + I * 8, 4) and $7F;
      FExternalSelected := False;
    end;
  Priority := Peek($E2, 1) shr 4;
  if (Peek($10B, 1) and 3 = 3) and (Priority > Level) then
  begin
    Level := Priority;
    Vector := Peek($10C, 4) and $7F;
    FExternalSelected := False;
  end;
  Priority := Peek($E3, 1) shr 4;
  if (Peek($80, 1) and $80 <> 0) and (Priority > Level) then
  begin
    Level := Priority;
    Vector := Peek($E4, 1) and $7F;
    FExternalSelected := False;
  end;
  if FNMI then
  begin
    Level := 16;
    Vector := 11;
    FExternalSelected := False;
  end;
  FCPU.Interrupt(Level, Vector);
end;

procedure TSH7604.Interrupt(Level, Vector: Integer);
begin
  if (FExternalLevel <> Level) or (FExternalVector <> Vector) then
    FIRQDirty := True;
  FExternalLevel := Level;
  FExternalVector := Vector;
  UpdateIRQ;
end;

procedure TSH7604.NMI;
begin
  FNMI := True;
  FIRQDirty := True;
  UpdateIRQ;
end;

procedure TSH7604.InputCapture;
begin
  SynchronizePeripherals;
  FState.ICR := FState.FRC;
  Store($11, Peek($11, 1) or $80, 1);
  UpdateIRQ;
end;

procedure TSH7604.ExternalClock;
begin
  SynchronizePeripherals;
  if Peek($16, 1) and 3 <> 3 then
    Exit;
  FState.FRC := Word((Cardinal(FState.FRC) + 1) and $FFFF);
  var Flags := Peek($11, 1);
  if FState.FRC = 0 then
    Flags := Flags or 2;
  if FState.FRC = FState.OCR[1] then
    Flags := Flags or 4;
  if FState.FRC = FState.OCR[0] then
  begin
    Flags := Flags or 8;
    if Flags and 1 <> 0 then
      FState.FRC := 0;
  end;
  Store($11, Flags, 1);
  SchedulePeripherals;
  UpdateIRQ;
end;

procedure TSH7604.SetDREQ(Channel: Integer; Value: Boolean);
begin
  if not (Channel in [0, 1]) then
    raise EArgumentOutOfRangeException.Create('DREQ channel');
  FState.DREQ[Channel] := Value;
end;

{$Q-}{$R-}
function TSH7604.RunDMA(Channel: Integer): Boolean;
begin
  Result := False;
  if Peek($1B0, 4) and 7 <> 1 then
    Exit;
  var Base: Integer := $180 + Channel * 16;
  var Control := Peek(Base + 12, 4);
  if Control and 3 <> 1 then
  begin
    FState.DMAPhase[Channel] := 0;
    FState.DMABlockUnit[Channel] := 0;
    Exit;
  end;
  if (FState.DMAPhase[Channel] = 0) and (Control and $200 = 0) and not FState.DREQ[Channel] then
    Exit;
  // Only the address phase samples SAR/DAR. The read phase uses the
  // already latched request; completion alone consumes TCR.
  var Source, Dest, Count: Cardinal;
  var Block: Boolean := (Control shr 10) and 3 = 3;
  var Size: Integer := 1 shl ((Control shr 10) and 3);
  if Block then
    Size := 4;
  case FState.DMAPhase[Channel] of
    0:
      begin
        Source := Peek(Base, 4);
        Dest := Peek(Base + 4, 4);
        if ((Source or Dest) and Cardinal(Size - 1) <> 0) or
          (Block and (FState.DMABlockUnit[Channel] = 0) and ((Source or Dest) and 15 <> 0)) then
        begin
          Store($1B0, Peek($1B0, 4) or 4, 4);
          Exit;
        end;
        FState.DMASource[Channel] := Source;
        FState.DMADest[Channel] := Dest;
        FState.DMASize[Channel] := Size;
        FState.DMAControl[Channel] := Control;
        FState.DMAPhase[Channel] := 1;
        if Assigned(FReserveDMA) then
          FState.DMANext := FReserveDMA(FUser, FState.DMANext, Source and $1FFFFFFF, Size, False)
        else
          Inc(FState.DMANext, 2);
      end;
    1:
      begin
        if Assigned(FDMAReady) and not FDMAReady(FUser, FState.DMASource[Channel] and $1FFFFFFF, FState.DMASize[Channel], False) then
        begin
          Inc(FState.DMANext, 2);
          Exit(True);
        end;
        FState.DMAValue[Channel] := FReadDMA(FUser, FState.DMASource[Channel] and $1FFFFFFF, FState.DMASize[Channel]);
        FState.DMAPhase[Channel] := 2;
        if Assigned(FReserveDMA) then
          FState.DMANext := FReserveDMA(FUser, FState.DMANext, FState.DMADest[Channel] and $1FFFFFFF, FState.DMASize[Channel], True)
        else
          Inc(FState.DMANext, 2);
      end;
    2:
      begin
        if Assigned(FDMAReady) and not FDMAReady(FUser, FState.DMADest[Channel] and $1FFFFFFF, FState.DMASize[Channel], True) then
        begin
          Inc(FState.DMANext, 2);
          Exit(True);
        end;
        Source := FState.DMASource[Channel];
        Dest := FState.DMADest[Channel];
        Size := FState.DMASize[Channel];
        Control := FState.DMAControl[Channel];
        FWrite(FUser, Dest and $1FFFFFFF, FState.DMAValue[Channel], Size);
        if Block then
          Source := Cardinal((Int64(Source) + 4) and $FFFFFFFF)
        else
          case (Control shr 12) and 3 of
            1:
              Source := Cardinal((Int64(Source) + Size) and $FFFFFFFF);
            2:
              Source := Cardinal((Int64(Source) - Size) and $FFFFFFFF);
          end;
        case (Control shr 14) and 3 of
          1:
            Dest := Cardinal((Int64(Dest) + Size) and $FFFFFFFF);
          2:
            Dest := Cardinal((Int64(Dest) - Size) and $FFFFFFFF);
        end;
        Count := Peek(Base + 8, 4) and $FFFFFF;
        if Count = 0 then
          Count := $1000000;
        Dec(Count);
        if Block then
          FState.DMABlockUnit[Channel] := (FState.DMABlockUnit[Channel] + 1) and 3;
        Store(Base, Source, 4);
        Store(Base + 4, Dest, 4);
        Store(Base + 8, Count, 4);
        if Count = 0 then
          Store(Base + 12, Control or 2, 4);
        FState.DMAPhase[Channel] := 0;
        Inc(FState.DMANext, 1);
      end;
  end;
  Result := True;
end;

{$Q+}{$R+}

procedure TSH7604.AdvanceFRTBatch(Ticks: Int64);
begin
  // The counter runs modulo 65536 until compare A optionally clears it.
  // Detect first crossings, then reduce full clear-on-A periods arithmetically.
  var Counter: Integer := FState.FRC;
  var UntilA := (Integer(FState.OCR[0]) - Counter) and $FFFF;
  var UntilB := (Integer(FState.OCR[1]) - Counter) and $FFFF;
  if UntilA = 0 then
    UntilA := $10000;
  if UntilB = 0 then
    UntilB := $10000;
  var UntilOverflow := $10000 - Counter;
  var Flags := Peek($11, 1);
  if (Flags and 1 <> 0) and (FState.OCR[0] <> 0) and (Ticks >= UntilA) then
  begin
    Flags := Flags or 8;
    if UntilB <= UntilA then
      Flags := Flags or 4;
    if UntilOverflow <= UntilA then
      Flags := Flags or 2;
    var Remaining := Ticks - UntilA;
    if (FState.OCR[1] > 0) and (FState.OCR[1] <= FState.OCR[0]) and
      (Remaining >= FState.OCR[1]) then
      Flags := Flags or 4;
    FState.FRC := Remaining mod FState.OCR[0];
  end
  else
  begin
    if Ticks >= UntilA then
      Flags := Flags or 8;
    if Ticks >= UntilB then
      Flags := Flags or 4;
    if Ticks >= UntilOverflow then
      Flags := Flags or 2;
    FState.FRC := (Counter + Ticks) and $FFFF;
  end;
  Store($11, Flags, 1);
end;

procedure TSH7604.SynchronizePeripherals(Force: Boolean);
const
  WDTDividers: array[0..7] of Integer = (2, 64, 128, 256, 512, 1024, 4096, 8192);
  Shifts: array[0..7] of Byte = (1, 6, 7, 8, 9, 10, 12, 13);
begin
  if not Force and (FPeripheralAt = FState.Time) then
    Exit;
  var Target := FState.Time;
  // Before the scheduled flag/division deadline no observable event can
  // change. A counter read can update only count/fraction, keeping the same
  // absolute deadline. Clear-on-compare retains the general executor.
  if not Force and (Target < FPeripheralNext) and (FState.Peripheral[$11] and 1 = 0) then
  begin
    var Elapsed := Target - FPeripheralAt;
    var Select := FState.Peripheral[$16] and 3;
    if Select <> 3 then
    begin
      var Shift := 3 + Select * 2;
      var Phase := Elapsed + FState.FRTPhase;
      FState.FRC := (Int64(FState.FRC) + (Phase shr Shift)) and $FFFF;
      FState.FRTPhase := Phase and ((1 shl Shift) - 1);
    end;
    if FState.Peripheral[$80] and $20 <> 0 then
    begin
      var Shift := Shifts[FState.Peripheral[$80] and 7];
      var Phase := Elapsed + FState.WDTPhase;
      FState.Peripheral[$81] := (Int64(FState.Peripheral[$81]) + (Phase shr Shift)) and $FF;
      FState.WDTPhase := Phase and ((1 shl Shift) - 1);
    end;
    FPeripheralAt := Target;
    Exit;
  end;
  var Elapsed := Target - FPeripheralAt;
  FPeripheralAt := Target;
  var Select := Peek($16, 1) and 3;
  if Select <> 3 then
  begin
    var Divider: Integer := 8 shl (Select * 2);
    var Phase := Elapsed + FState.FRTPhase;
    var Ticks: Int64 := Phase shr (3 + Select * 2);
    FState.FRTPhase := Phase and (Divider - 1);
    if Ticks > 16 then
      AdvanceFRTBatch(Ticks)
    else
      while Ticks > 0 do
      begin
        FState.FRC := Word((Cardinal(FState.FRC) + 1) and $FFFF);
        var Flags := Peek($11, 1);
        if FState.FRC = 0 then
          Flags := Flags or 2;
        if FState.FRC = FState.OCR[1] then
          Flags := Flags or 4;
        if FState.FRC = FState.OCR[0] then
        begin
          Flags := Flags or 8;
          if Flags and 1 <> 0 then
            FState.FRC := 0;
        end;
        Store($11, Flags, 1);
        Dec(Ticks);
      end;
  end;
  if Peek($80, 1) and $20 <> 0 then
  begin
    var Divider := WDTDividers[Peek($80, 1) and 7];
    var Ticks: Int64 := (Elapsed + FState.WDTPhase) div Divider;
    FState.WDTPhase := (Elapsed + FState.WDTPhase) mod Divider;
    if Ticks + Peek($81, 1) > 255 then
    begin
      if Peek($80, 1) and $40 = 0 then
        Store($80, Peek($80, 1) or $80, 1)
      else
      begin
        Store($82, Peek($82, 1) or $80, 1);
        if Peek($82, 1) and $40 <> 0 then
        begin
          FCPU.Reset;
          FIRQDirty := True;
        end;
      end;
    end;
    Store($81, (Ticks + Peek($81, 1)) and $FF, 1);
  end
  else
  begin
    Store($81, 0, 1);
    FState.WDTPhase := 0;
  end;
  if (FState.DIVUntil <> 0) and (Target >= FState.DIVUntil) then
    FinishDivision;
  SchedulePeripherals;
end;

procedure TSH7604.SchedulePeripherals;
const
  WDTDividers: array[0..7] of Integer = (2, 64, 128, 256, 512, 1024, 4096, 8192);

  procedure Due(Delta: Int64);
  begin
    Delta := Max(Int64(0), Delta);
    if Delta <= High(Int64) - FState.Time then
      FPeripheralNext := Min(FPeripheralNext, FState.Time + Delta);
  end;

begin
  FPeripheralNext := High(Int64);
  if FState.DIVUntil <> 0 then
    FPeripheralNext := FState.DIVUntil;
  var Select := Peek($16, 1) and 3;
  if Select <> 3 then
  begin
    var Divider: Integer := 8 shl (Select * 2);
    var Flags := Peek($11, 1);
    for var Event := 0 to 2 do
      if Flags and (2 shl Event) = 0 then
      begin
        var Compare: Integer := 0;
        if Event = 1 then
          Compare := FState.OCR[1]
        else if Event = 2 then
          Compare := FState.OCR[0];
        var Distance := (Compare - Integer(FState.FRC)) and $FFFF;
        if Distance = 0 then
          Distance := $10000;
        Due(Int64(Distance) * Divider - FState.FRTPhase);
      end;
  end;
  if Peek($80, 1) and $20 <> 0 then
    Due(Int64(256 - Peek($81, 1)) * WDTDividers[Peek($80, 1) and 7] - FState.WDTPhase)
  else if (Peek($81, 1) <> 0) or (FState.WDTPhase <> 0) then
    Due(0);
end;

procedure TSH7604.Advance(Target: Int64);
begin
  if Target < FState.Time then
    raise EArgumentException.Create('SH7604 time cannot run backwards');
  AdvanceForward(Target);
end;

procedure TSH7604.AdvanceForward(Target: Int64);
begin
  FState.Time := Target;
  if Target >= FPeripheralNext then
    SynchronizePeripherals(True);
  if FState.DMANext <= Target then
  begin
    if FState.Peripheral[$1B3] and 7 <> 1 then
      FState.DMANext := Target + 4
    else
      AdvanceDMA(Target);
  end;
  if FIRQDirty then
    UpdateIRQ;
end;

procedure TSH7604.AdvanceDMA(Target: Int64);
begin
  // CHCR.DE/TE are in the low register byte. Disabled channels cannot issue
  // bus transfers; preserve the same phase cleanup and next polling time.
  if (FState.DMANext <= Target) and
    (FState.Peripheral[$1B3] and 7 = 1) and
    (FState.Peripheral[$18F] and 3 <> 1) and
    (FState.Peripheral[$19F] and 3 <> 1) then
  begin
    FState.DMAPhase[0] := 0;
    FState.DMAPhase[1] := 0;
    FState.DMABlockUnit[0] := 0;
    FState.DMABlockUnit[1] := 0;
    FState.DMANext := Target + 4;
    Exit;
  end;
  while FState.DMANext <= Target do
  begin
    var Channel: Integer := 0;
    if Peek($1B0, 4) and 8 <> 0 then
      Channel := FState.DMAPriority;
    var Moved := RunDMA(Channel);
    if not Moved then
    begin
      Channel := Channel xor 1;
      Moved := RunDMA(Channel);
    end;
    if not Moved then
    begin
      FState.DMANext := Target + 4;
      Break;
    end;
    FState.DMAPriority := Channel xor 1;
  end;
end;

procedure TSH7604.Hold(Clocks: Integer);
begin
  if Clocks < 0 then
    raise EArgumentException.Create('Negative SH7604 hold');
  FCPU.AddWaitCycles(Clocks);
end;

function TSH7604.Step: Integer;
begin
  FAccessWait := 0;
  FExternalAccepted := False;
  Result := FCPU.StepCached;
  if Result = 0 then
    Result := StepChecked;
end;

function TSH7604.StepBusReleased: Integer;
begin
  FAccessWait := 0;
  FExternalAccepted := False;
  // SH7604 hardware manual 7.10: the dedicated cache bus remains usable
  // during external bus ownership. Never fall back to a bus transaction.
  Result := FCPU.StepCached;
end;

function TSH7604.StepChecked: Integer;
begin
  FExecuting := True;
  FAccessWait := 0;
  var ExternalSelected := FExternalSelected;
  FExternalAccepted := False;
  var TakingNMI: Boolean := FNMI and not FCPU.State.DelayPending;
  try
    var Issued := FCPU.StepChecked;
    FExternalAccepted := ExternalSelected and FCPU.InterruptAccepted;
    Result := Issued + FAccessWait;
  finally
    FExecuting := False;
  end;
  if TakingNMI then
  begin
    FNMI := False;
    FIRQDirty := True;
    UpdateIRQ;
  end;
  // A cached instruction with no bus wait already has its final cycle count.
  if FAccessWait <> 0 then
  begin
    FCPU.AddWaitCycles(FAccessWait);
  end;
end;

procedure TSH7604.SerializeState(Archive: TStateArchive);
begin
  if not Archive.Loading then
    SynchronizePeripherals;
  FCPU.SerializeState(Archive);
  Archive.Field(FState, SizeOf(FState));
  Archive.Field(FExternalLevel, SizeOf(FExternalLevel));
  Archive.Field(FExternalVector, SizeOf(FExternalVector));
  Archive.Field(FNMI, SizeOf(FNMI));
  if Archive.Loading then
    FIRQDirty := True;
  if (FState.Time < 0) or (FState.DMANext < 0) or (FState.DIVUntil < 0) or (FState.FRTPhase > 127) or (FState.WDTPhase < 0) or (FState.WDTPhase > 8191) or (FState.DMAPriority < 0) or (FState.DMAPriority > 1) or
    (FExternalLevel < 0) or (FExternalLevel > 15) or (FExternalVector < 0) or (FExternalVector > 255) then
    raise EReadError.Create('Invalid SH7604 state');
  for var I := 0 to 1 do
    if (FState.DMAPhase[I] > 2) or (FState.DMABlockUnit[I] > 3) or
      ((FState.DMAPhase[I] > 0) and not (FState.DMASize[I] in [1, 2, 4])) then
      raise EReadError.Create('Invalid SH7604 DMA phase');
  if Archive.Loading then
  begin
    FFetchLine := High(Cardinal);
    if FCPU <> nil then
      FCPU.InvalidateInstructionLine;
    FillChar(FDataCache, SizeOf(FDataCache), $FF);
    FPeripheralAt := FState.Time;
    SchedulePeripherals;
    UpdateIRQ;
    FExternalAccepted := False;
  end;
end;

end.

