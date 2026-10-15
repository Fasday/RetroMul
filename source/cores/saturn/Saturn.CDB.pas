unit Saturn.CDB;

interface

uses
  System.SysUtils, System.Classes, HW.SH2, HW.SH7034, Core.Snapshots,
  Core.CD.Disc;

type
  TCDBIRQ = procedure(Active: Boolean) of object;

  TCDBSerialObserver = reference to procedure(At: Int64; Slot: Integer; TX, RX: Byte);

  TCDBBridgeObserver = reference to procedure(PC, Address, Value: Cardinal; Size: Integer; Writing: Boolean);
  // The SH-1 owns the command dispatcher, buffers and RTOS. This device is
  // the external bridge/DRAM/drive mechanism attached to the SH-1 pins.

  TSaturnCDB = class
  private
    FCPU: TSH7034;
    FROM: TBytes;
    FDRAM: array[0..$7FFFF] of Byte;
    FRegisters: array[0..15] of Word;
    FCommands, FResponses: array[0..3] of Word;
    FMask: Word;
    FFIFO: array[0..5] of Word;
    FFIFORead, FFIFOWrite, FFIFOCount: Integer;
    FSerialAt: Integer;
    FTX, FRX: array[0..11] of Byte;
    FDriveSlotAt, FSerialDue: Int64;
    FSerialByte: Byte;
    FSerialBytes: UInt64;
    FMechanismStatus: Byte;
    FMechanismReport: array[0..10] of Byte;
    FProtection: Boolean;
    FDecoded: TBytes;
    FDecodedAt: Integer;
    FDecoderIRQPending: Boolean;
    FDriveFAD, FDriveTarget: Cardinal;
    FDrivePlaying: Boolean;
    FDriveSeekAt, FSectorAt: Int64;
    FTOCEntry, FTOCRepeat, FReadSpeed: Integer;
    FTrayStartup: Boolean;
    FAudio: array[0..2351] of Byte;
    FAudioAt: Integer;
    FSerialObserver: TCDBSerialObserver;
    FBridgeObserver: TCDBBridgeObserver;
    FDisc: TCDDisc;
    FIRQ: TCDBIRQ;
    procedure DriveCommand;
    procedure DriveReport;
    procedure SetProtection(Value: Boolean);
    procedure DriveSector;
    procedure UpdateIRQ;
    procedure Serial(Channel: Integer; Value: Byte);
    function DMAReady(Channel: Integer; Source, Dest: Cardinal): Boolean;
    function DMAInput(Channel, Size: Integer): Cardinal;
    procedure DMAOutput(Channel, Size: Integer; Value: Cardinal);
    function PullFIFO: Word;
    procedure PushFIFO(Value: Word);
  public
    constructor Create(const Firmware: TBytes; Disc: TCDDisc; IRQ: TCDBIRQ);
    destructor Destroy; override;
    procedure Reset;
    procedure Advance(Cycles: Int64);
    procedure SetMechanismReport(const Report: TBytes);
    procedure AudioSample(out Left, Right: Integer);
    function Read(Address: Cardinal; Size: Integer): Cardinal;
    procedure Write(Address, Value: Cardinal; Size: Integer);
    function HostRead(Address: Cardinal; Size: Integer): Cardinal;
    function HostReady(Size: Integer; Writing: Boolean): Boolean;
    procedure HostWrite(Address, Value: Cardinal; Size: Integer);
    procedure SerializeState(Archive: TStateArchive);
    property CPU: TSH7034 read FCPU;
    property SerialBytes: UInt64 read FSerialBytes;
    property FAD: Cardinal read FDriveFAD;
    property SerialObserver: TCDBSerialObserver read FSerialObserver write FSerialObserver;
    property BridgeObserver: TCDBBridgeObserver read FBridgeObserver write FBridgeObserver;
    property MechanismStatus: Byte read FMechanismStatus write FMechanismStatus;
    property Protection: Boolean read FProtection write SetProtection;
  end;

implementation

uses
  System.Hash;
{$Q+}{$R+}

function SyntheticRingSector(FAD: Cardinal): TBytes;
begin
  // Decoded-sector model of the alternating optical pattern, provided only
  // when physical protection is explicitly disabled. Original SH-1 code
  // performs the verification. This is not a capture of physical optics.
  SetLength(Result, 2352);
  var Shift: Word := 1;
  for var I := 12 to 2351 do
  begin
    var Bits: Byte := $A8;
    if Odd(I) then
      Bits := $59;
    for var B := 0 to 7 do
    begin
      Bits := Bits xor (Shift and 1);
      Bits := Byte(((Bits shr 1) or (Bits shl 7)) and $FF);
      var Feedback: Cardinal := (Shift shr 1) xor Shift;
      Shift := Word(((Cardinal(Shift) or (Feedback shl 15)) shr 1) and $FFFF);
    end;
    Result[I] := Bits;
  end;
  for var I := 1 to 10 do
    Result[I] := $FF;
  var M := FAD div 4500;
  var S := (FAD div 75) mod 60;
  var F := FAD mod 75;
  Result[12] := (M div 10) * 16 + M mod 10;
  Result[13] := (S div 10) * 16 + S mod 10;
  Result[14] := (F div 10) * 16 + F mod 10;
  Result[15] := 2;
  Result[16] := 0;
  Result[17] := 0;
  Result[18] := $1C;
  Result[19] := 0;
  Move(Result[16], Result[20], 4);
  var EDC := CDDataEDC(Result, 2064);
  for var I := 0 to 3 do
    Result[2348 + I] := (EDC shr (I * 8)) and $FF;
end;

function ReadCPU(User: Pointer; Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := TSaturnCDB(User).Read(Address, Size);
end;

procedure WriteCPU(User: Pointer; Address, Value: Cardinal; Size: Integer);
begin
  TSaturnCDB(User).Write(Address, Value, Size);
end;

constructor TSaturnCDB.Create(const Firmware: TBytes; Disc: TCDDisc; IRQ: TCDBIRQ);
begin
  inherited Create;
  if Length(Firmware) <> 65536 then
    raise EReadError.Create('SH-1 CD firmware must contain 64 KiB');
  FROM := Copy(Firmware);
  FDisc := Disc;
  FIRQ := IRQ;
  FCPU := TSH7034.Create(ReadCPU, WriteCPU, Self);
  FCPU.Serial := Serial;
  FCPU.DMAReady := DMAReady;
  FCPU.DMAInput := DMAInput;
  FCPU.DMAOutput := DMAOutput;
  Reset;
end;

destructor TSaturnCDB.Destroy;
begin
  FCPU.Free;
  inherited;
end;

procedure TSaturnCDB.Reset;
begin
  FillChar(FDRAM, SizeOf(FDRAM), 0);
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FillChar(FCommands, SizeOf(FCommands), 0);
  FillChar(FResponses, SizeOf(FResponses), 0);
  FillChar(FFIFO, SizeOf(FFIFO), $FF);
  FFIFORead := 0;
  FFIFOWrite := 0;
  FFIFOCount := 0;
  FMask := 0;
  FSerialAt := 0;
  FDriveSlotAt := 100000;
  FSerialDue := -1;
  FSerialByte := 0;
  FSerialBytes := 0;
  FMechanismStatus := $80;
  if FDisc <> nil then
    FMechanismStatus := $90;
  FillChar(FMechanismReport, SizeOf(FMechanismReport), 0);
  FDecoded := nil;
  FDecodedAt := 0;
  FDecoderIRQPending := False;
  FDriveFAD := 150;
  FDriveTarget := 150;
  FDrivePlaying := False;
  FDriveSeekAt := -1;
  FSectorAt := -1;
  FAudioAt := 2352;
  FillChar(FAudio, SizeOf(FAudio), 0);
  FTOCEntry := 0;
  FTOCRepeat := 0;
  FReadSpeed := 2;
  FTrayStartup := FDisc <> nil;
  if FTrayStartup then
    FMechanismStatus := $80;
  FillChar(FTX, SizeOf(FTX), 0);
  FillChar(FRX, SizeOf(FRX), 0);
  FCPU.Reset;
  UpdateIRQ;
end;

procedure TSaturnCDB.SetProtection(Value: Boolean);
begin
  if Value = FProtection then
    Exit;
  FProtection := Value;
  Reset;
end;

procedure TSaturnCDB.UpdateIRQ;
begin
  FCPU.SetIRQ(6, FRegisters[2] and FRegisters[4] and 1 <> 0);
  FCPU.SetIRQ(7, FRegisters[3] and FRegisters[5] <> 0);
  if Assigned(FIRQ) then
    FIRQ(FRegisters[15] and FMask <> 0);
end;

function TSaturnCDB.DMAReady(Channel: Integer; Source, Dest: Cardinal): Boolean;
begin
  Result := True;
  if (Channel = 0) and ((FCPU.Read($05FFFF4E, 2) shr 8) and 15 = 3) then
    Exit(FDecodedAt < Length(FDecoded));
  if Channel = 1 then
  begin
    var Resource: Integer := (FCPU.Read($05FFFF5E, 2) shr 8) and 15;
    if Resource = 3 then
      Exit((FRegisters[1] and 5 = 5) and (FFIFOCount > 0));
    if Resource = 2 then
      Exit((FRegisters[1] and 5 = 4) and (FFIFOCount < Length(FFIFO)));
  end;
  if Source = $0A000000 then
    Result := FFIFOCount > 0;
  if Source = $0A000018 then
    Result := (FDecodedAt < Length(FDecoded)) and (FRegisters[13] and $80 <> 0);
  if Dest = $0A000000 then
    Result := FFIFOCount < Length(FFIFO);
end;

function TSaturnCDB.DMAInput(Channel, Size: Integer): Cardinal;
begin
  if Channel = 1 then
    Exit(Read($0A000000, Size));
  Result := 0;
  for var I := 0 to Size - 1 do
  begin
    Result := Result shl 8;
    if (Channel = 0) and (FDecodedAt < Length(FDecoded)) then
    begin
      Result := Result or FDecoded[FDecodedAt];
      Inc(FDecodedAt);
    end
    else
      Result := Result or $FF;
  end;
end;

procedure TSaturnCDB.DMAOutput(Channel, Size: Integer; Value: Cardinal);
begin
  if Channel = 1 then
    Write($0A000000, Value, Size);
end;

function TSaturnCDB.PullFIFO: Word;
begin
  Result := FFIFO[FFIFORead];
  FFIFORead := (FFIFORead + 1) mod Length(FFIFO);
  if (FRegisters[1] and 5 = 1) and (FFIFOCount = 1) then
    FRegisters[1] := FRegisters[1] or 4;
  if FFIFOCount > 0 then
    Dec(FFIFOCount);
end;

procedure TSaturnCDB.PushFIFO(Value: Word);
begin
  if FFIFOCount = Length(FFIFO) then
    Exit;
  FFIFO[FFIFOWrite] := Value;
  FFIFOWrite := (FFIFOWrite + 1) mod Length(FFIFO);
  Inc(FFIFOCount);
end;

function TSaturnCDB.Read(Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := $FFFFFFFF;
  if Address < $10000 then
  begin
    Result := 0;
    for var I := 0 to Size - 1 do
      Result := (Result shl 8) or FROM[(Address + Cardinal(I)) and $FFFF];
  end
  else if (Address and $07000000 = $01000000) then
  begin
    Result := 0;
    for var I := 0 to Size - 1 do
      Result := (Result shl 8) or FDRAM[(Address + Cardinal(I)) and $7FFFF];
  end
  else if (Address >= $0A000000) and (Address < $0A000020) then
  begin
    var A: Integer := Address and $1E;
    var V: Word := FRegisters[A div 2];
    if A = $00 then
      V := PullFIFO;
    if A = $18 then
    begin
      V := 0;
      for var I := 0 to 1 do
      begin
        V := V shl 8;
        if FDecodedAt < Length(FDecoded) then
        begin
          V := V or FDecoded[FDecodedAt];
          Inc(FDecodedAt);
        end
        else
          V := V or $FF;
      end;
    end;
    if (A >= $10) and (A <= $16) then
      V := FCommands[(A - $10) div 2];
    if Size = 1 then
    begin
      if Odd(Address) then
        Result := V and $FF
      else
        Result := V shr 8;
    end
    else
      Result := V;
    if Size = 4 then
    begin
      if A = 0 then
        Result := (Result shl 16) or Read(Address, 2)
      else
        Result := (Result shl 16) or Read(Address + 2, 2);
    end;
    if Assigned(FBridgeObserver) then
      FBridgeObserver(FCPU.State.PC, Address, Result, Size, False);
  end
  else if (Address = $0A100002) then
    Result := $006C;
end;

procedure TSaturnCDB.Write(Address, Value: Cardinal; Size: Integer);
begin
  if (Address and $07000000 = $01000000) then
    for var I := 0 to Size - 1 do
      FDRAM[(Address + Cardinal(I)) and $7FFFF] := (Value shr ((Size - I - 1) * 8)) and $FF
  else if (Address >= $0A000000) and (Address < $0A000020) then
  begin
    if Size = 4 then
    begin
      Write(Address, Value shr 16, 2);
      if Address = $0A000000 then
        Write(Address, Value and $FFFF, 2)
      else
        Write(Address + 2, Value and $FFFF, 2);
      Exit;
    end;
    var A: Integer := Address and $1E;
    var V: Word := Word(Value and $FFFF);
    if Assigned(FBridgeObserver) then
      FBridgeObserver(FCPU.State.PC, Address, Value, Size, True);
    if Size = 1 then
    begin
      V := FRegisters[A div 2];
      if Odd(Address) then
        V := (V and $FF00) or (Value and $FF)
      else
        V := (V and $FF) or (Value shl 8);
    end;
    if A = 0 then
    begin
      PushFIFO(V);
      if FRegisters[1] and 5 = 5 then
        FRegisters[1] := FRegisters[1] and not 4;
    end
    else if A = $06 then
      FRegisters[3] := FRegisters[3] and V
    else if A = $02 then
    begin
      FRegisters[1] := V and 15;
      // Resetting the FIFO pointers does not erase its storage. In the
      // SH-1 self-test DIR changes to read back the words just written.
      if V and 2 <> 0 then
      begin
        FFIFORead := 0;
        FFIFOWrite := 0;
        FFIFOCount := 0;
      end;
    end
    else if A = $1E then
      FRegisters[15] := FRegisters[15] or (V and $3FFF)
    else if (A >= $10) and (A <= $16) then
      FResponses[(A - $10) div 2] := V
    else
      FRegisters[A div 2] := V;
    UpdateIRQ;
  end;
end;

procedure TSaturnCDB.Serial(Channel: Integer; Value: Byte);
begin
  if Channel <> 0 then
    Exit;
  Inc(FSerialBytes);
  var Slot := FSerialAt;
  if FSerialAt = 0 then
  begin
    DriveReport;
    var Sum: Byte := 0;
    for var I := 0 to 10 do
      Sum := Byte((Integer(Sum) + FRX[I]) and $FF);
    FRX[11] := Byte((not Sum) and $FF);
  end;
  if FSerialAt < 12 then
  begin
    FTX[FSerialAt] := Value;
    FSerialByte := FRX[FSerialAt];
    Inc(FSerialAt);
    FCPU.PortBInputs := $0404;
  end
  else
  begin
    FSerialAt := 0;
    FSerialByte := 0;
    FCPU.PortBInputs := $0400;
    var Sum: Byte := 0;
    for var I := 0 to 11 do
      Sum := Byte((Integer(Sum) + FTX[I]) and $FF);
    if (Value = 0) and (Sum = $FF) then
      DriveCommand;
    // A report period includes the thirteen clocked bytes, rather than
    // adding a full sector period after the final byte.
    FDriveSlotAt := FCPU.Time + 20000000 div (75 * FReadSpeed) - 12 * 1600;
  end;
  FSerialDue := FCPU.Time + 1200;
  if Assigned(FSerialObserver) then
    FSerialObserver(FCPU.Time, Slot, Value, FSerialByte);
end;

procedure TSaturnCDB.DriveReport;

  function BCD(Value: Integer): Byte;
  begin
    Result := (Value div 10) * 16 + Value mod 10;
  end;

begin
  Move(FMechanismReport, FRX, SizeOf(FMechanismReport));
  FRX[0] := Byte((FMechanismStatus) and $FF);
  if FDisc = nil then
    Exit;
  FillChar(FRX[1], 10, 0);
  if FMechanismStatus = $B6 then
  begin
    FRX[1] := Byte(($44) and $FF);
    FRX[2] := Byte(($F1) and $FF);
    FRX[3] := Byte((FDriveTarget shr 16) and $FF);
    FRX[4] := Byte((FDriveTarget shr 8) and $FF);
    FRX[5] := Byte((FDriveTarget) and $FF);
    for var I := 6 to 9 do
      FRX[I] := Byte((9) and $FF);
    FRX[10] := Byte((FDriveTarget mod 75) and $FF);
    Exit;
  end;
  if FMechanismStatus = $04 then
  begin
    // Lead-in Q records, repeated three times before advancing. The SH-1
    // firmware, rather than the host, assembles these records into its TOC.
    FRX[1] := Byte(($41) and $FF);
    if FTOCEntry < FDisc.TrackCount then
    begin
      var Track := FDisc.Track(FTOCEntry + 1);
      if Track.Audio then
        FRX[1] := Byte((1) and $FF);
      FRX[3] := Byte((BCD(Track.Number)) and $FF);
      var FAD := Track.StartLBA + 150;
      FRX[8] := Byte((BCD(FAD div 4500)) and $FF);
      FRX[9] := Byte((BCD((FAD div 75) mod 60)) and $FF);
      FRX[10] := Byte((BCD(FAD mod 75)) and $FF);
    end
    else
      case FTOCEntry - FDisc.TrackCount of
        0:
          begin
            FRX[3] := Byte(($A0) and $FF);
            FRX[8] := Byte((BCD(FDisc.Track(1).Number)) and $FF);
          end;
        1:
          begin
            FRX[3] := Byte(($A1) and $FF);
            FRX[8] := Byte((BCD(FDisc.Track(FDisc.TrackCount).Number)) and $FF);
          end;
        2:
          begin
            FRX[3] := Byte(($A2) and $FF);
            var FAD := FDisc.LeadOut + 150;
            FRX[8] := Byte((BCD(FAD div 4500)) and $FF);
            FRX[9] := Byte((BCD((FAD div 75) mod 60)) and $FF);
            FRX[10] := Byte((BCD(FAD mod 75)) and $FF);
          end;
      end;
    Inc(FTOCRepeat);
    if FTOCRepeat = 3 then
    begin
      FTOCRepeat := 0;
      Inc(FTOCEntry);
    end;
    Exit;
  end;
  if FDriveFAD >= Cardinal(FDisc.LeadOut + 150) then
  begin
    FRX[1] := Byte((1) and $FF);
    FRX[2] := Byte(($AA) and $FF);
    FRX[3] := Byte((1) and $FF);
    FRX[7] := Byte((4) and $FF);
    FRX[8] := Byte((BCD(FDriveFAD div 4500)) and $FF);
    FRX[9] := Byte((BCD((FDriveFAD div 75) mod 60)) and $FF);
    FRX[10] := Byte((BCD(FDriveFAD mod 75)) and $FF);
  end
  else if FDriveFAD < 150 then
  begin
    FRX[1] := Byte(($41) and $FF);
    FRX[2] := Byte((1) and $FF);
    FRX[3] := Byte((0) and $FF);
    FRX[7] := Byte((4) and $FF);
    FRX[8] := Byte((BCD(FDriveFAD div 4500)) and $FF);
    FRX[9] := Byte((BCD((FDriveFAD div 75) mod 60)) and $FF);
    FRX[10] := Byte((BCD(FDriveFAD mod 75)) and $FF);
  end
  else
  begin
    var Q: TBytes;
    FDisc.ReadSubQ(Integer(FDriveFAD) - 150, Q);
    FRX[1] := Byte((Q[0]) and $FF);
    FRX[2] := Byte((Q[1]) and $FF);
    FRX[3] := Byte((Q[2]) and $FF);
    Move(Q[3], FRX[4], 3);
    FRX[7] := Byte((4) and $FF);
    Move(Q[7], FRX[8], 3);
  end;
end;

procedure TSaturnCDB.DriveCommand;
begin
  if FDisc = nil then
  begin
    FMechanismStatus := $80;
    Exit;
  end;
  if FTrayStartup then
  begin
    FTrayStartup := False;
    FMechanismStatus := $30;
    Exit;
  end;
  if FTX[0] <> 0 then
  begin
    FReadSpeed := 2;
    if FTX[10] = 1 then
      FReadSpeed := 1;
  end;
  case FTX[0] of
    $00:
      begin
        if (FMechanismStatus = $04) and (FTOCEntry >= FDisc.TrackCount + 3) then
          FMechanismStatus := $46
        else if FMechanismStatus = $46 then
        begin
          Inc(FDriveFAD);
          if FDriveFAD > FDriveTarget + 1 then
            FDriveFAD := FDriveTarget - 4;
        end;
      end;
    $03:
      begin
        FTOCEntry := 0;
        FTOCRepeat := 0;
        FMechanismStatus := $04;
        FDrivePlaying := False;
        FSectorAt := -1;
      end;
    $06, $09:
      begin
        FDriveTarget := (Cardinal(FTX[1]) shl 16) or (Cardinal(FTX[2]) shl 8) or FTX[3];
      // Firmware deliberately requests FAD 149 while priming the decoder.
      // Clamping it to the first user sector shifts every incoming header.
        if FDriveTarget < 4 then
          FDriveTarget := 4;
        FDrivePlaying := FTX[0] = $06;
      // Mechanical latency is a nominal distance-dependent model; it is
      // deliberately asynchronous and is not calibrated to a captured drive.
        var Distance := Abs(Int64(FDriveTarget) - Int64(FDriveFAD));
        if Distance > FDisc.LeadOut then
          Distance := FDisc.LeadOut;
        FDriveSeekAt := FCPU.Time + 800000 + Distance * 2000000 div (FDisc.LeadOut + 1);
        FMechanismStatus := $22;
        FSectorAt := -1;
      end;
    $04, $05:
      begin
        FDrivePlaying := False;
        FDriveSeekAt := -1;
        FSectorAt := -1;
        FMechanismStatus := $12;
      end;
    $08:
      begin
        FDrivePlaying := False;
        FDriveSeekAt := -1;
        FSectorAt := -1;
        FMechanismStatus := $46;
      end;
    $02:
      begin
        FDrivePlaying := False;
        FSectorAt := -1;
        if FProtection then
        begin
          FDriveSeekAt := -1;
          FMechanismStatus := $83;
        end
        else
        begin
          FDriveTarget := (Cardinal(FTX[1]) shl 16) or (Cardinal(FTX[2]) shl 8) or FTX[3];
          FDriveSeekAt := FCPU.Time + 800000;
          FMechanismStatus := $B6;
        end;
      end;
    $0C:
      begin
        FDrivePlaying := False;
        FDriveSeekAt := -1;
        FSectorAt := -1;
        FMechanismStatus := $30;
      end;
  end;
end;

procedure TSaturnCDB.DriveSector;
begin
  if (FDisc = nil) or not FDrivePlaying then
    Exit;
  if FProtection and (FDriveFAD >= Cardinal(FDisc.LeadOut + 150)) then
  begin
    FDrivePlaying := False;
    FMechanismStatus := $00;
    Exit;
  end;
  if (FDriveFAD < 150) or (FDriveFAD >= Cardinal(FDisc.LeadOut + 150)) or FDisc.IsData(Integer(FDriveFAD) - 150) then
  begin
    var Raw: TBytes;
    if FDriveFAD >= Cardinal(FDisc.LeadOut + 150) then
      Raw := SyntheticRingSector(FDriveFAD)
    else if FDriveFAD >= 150 then
      FDisc.ReadRawData(Integer(FDriveFAD) - 150, Raw)
    else
    begin
      SetLength(Raw, 2352);
      Raw[12] := (FDriveFAD div 4500 div 10) * 16 + (FDriveFAD div 4500) mod 10;
      var S: Cardinal := (FDriveFAD div 75) mod 60;
      Raw[13] := (S div 10) * 16 + S mod 10;
      var F: Cardinal := FDriveFAD mod 75;
      Raw[14] := (F div 10) * 16 + F mod 10;
      Raw[15] := 1;
    end;
    FDecoded := Copy(Raw, 12, 2340);
    FDecodedAt := 0;
    FRegisters[14] := 0;
    FDecoderIRQPending := True;
  end
  else
  begin
    var Raw: TBytes;
    FDisc.ReadAudio(Integer(FDriveFAD) - 150, Raw);
    Move(Raw[0], FAudio, 2352);
    FAudioAt := 0;
  end;
  Inc(FDriveFAD);
end;

procedure TSaturnCDB.AudioSample(out Left, Right: Integer);
begin
  Left := 0;
  Right := 0;
  if FAudioAt >= 2352 then
    Exit;
  Left := SmallInt(Word(FAudio[FAudioAt]) or (Word(FAudio[FAudioAt + 1]) shl 8));
  Right := SmallInt(Word(FAudio[FAudioAt + 2]) or (Word(FAudio[FAudioAt + 3]) shl 8));
  Inc(FAudioAt, 4);
end;

procedure TSaturnCDB.SetMechanismReport(const Report: TBytes);
begin
  if Length(Report) <> 11 then
    raise EArgumentException.Create('CD mechanism report must contain eleven bytes');
  Move(Report[0], FMechanismReport, 11);
  FMechanismStatus := Report[0];
end;

procedure TSaturnCDB.Advance(Cycles: Int64);
begin
  while FCPU.Time < Cycles do
  begin
    if FDecoderIRQPending and ((FDecodedAt = Length(FDecoded)) or (FCPU.Read($05FFFF4E, 2) and 3 <> 1)) then
    begin
      FDecoderIRQPending := False;
      FRegisters[3] := FRegisters[3] or $10;
      UpdateIRQ;
    end;
    if (FDriveSeekAt >= 0) and (FCPU.Time >= FDriveSeekAt) then
    begin
      FDriveSeekAt := -1;
      FDriveFAD := FDriveTarget - 4;
      FMechanismStatus := $46;
      if FDrivePlaying then
      begin
        FMechanismStatus := $36;
        if (FDriveFAD >= 150) and (FDriveFAD < Cardinal(FDisc.LeadOut + 150)) and not FDisc.IsData(Integer(FDriveFAD) - 150) then
          FMechanismStatus := $34;
        FSectorAt := FCPU.Time + 20000000 div (75 * FReadSpeed);
      end;
    end;
    if FDrivePlaying and (FSectorAt >= 0) and (FCPU.Time >= FSectorAt) then
    begin
      DriveSector;
      var Rate: Integer := 75 * FReadSpeed;
      if (FDisc <> nil) and (FDriveFAD >= 150) and (FDriveFAD < Cardinal(FDisc.LeadOut + 150)) and not FDisc.IsData(Integer(FDriveFAD) - 150) then
        Rate := 75;
      Inc(FSectorAt, 20000000 div Rate);
    end;
    if (FSerialDue >= 0) and (FCPU.Time >= FSerialDue) then
    begin
      FSerialDue := -1;
      FCPU.Receive(0, FSerialByte);
    end;
    if FCPU.Time >= FDriveSlotAt then
    begin
      Inc(FDriveSlotAt, 1600);
      FCPU.Capture(3, True);
    end;
    FCPU.Step;
  end;
end;

function TSaturnCDB.HostReady(Size: Integer; Writing: Boolean): Boolean;
begin
  var Words: Integer := (Size + 1) div 2;
  // DACK can refill an active unit directly. At a sector boundary the SH-1
  // must run its completion handler and arm the next buffer before the host
  // consumes more words. A waiting DMA keeps its read phase intact.
  if Writing then
  begin
    if FRegisters[1] and 1 = 0 then
      Exit(False);
    while (FFIFOCount + Words > Length(FFIFO)) and FCPU.TransferDMA(1) do
      ;
    Result := FFIFOCount + Words <= Length(FFIFO);
  end
  else
  begin
    if FRegisters[1] and 1 <> 0 then
      Exit(False);
    while (FFIFOCount < Words) and FCPU.TransferDMA(1) do
      ;
    Result := FFIFOCount >= Words;
  end;
end;

function TSaturnCDB.HostRead(Address: Cardinal; Size: Integer): Cardinal;
begin
  var A := Address and $FFFFF;
  var V: Word := $FFFF;
  case A and $FFFFC of
    $90008:
      V := FRegisters[15];
    $9000C:
      V := FMask;
    $90018, $9001C, $90020, $90024:
      begin
        V := FResponses[((A and $3C) - $18) div 4];
        if A and $3C = $24 then
        begin
          FRegisters[2] := FRegisters[2] or 2;
          UpdateIRQ;
        end;
      end;
    $18000, $98000:
      begin
        V := 0;
        if FRegisters[1] and 1 = 0 then
        begin
          if FFIFOCount = 0 then
            FCPU.TransferDMA(1);
          V := Read($0A000000, 2);
        end;
      end;
  end;
  if Size = 1 then
  begin
    if Odd(A) then
      Result := V and $FF
    else
      Result := V shr 8;
  end
  else
    Result := V;
  if Size = 4 then
  begin
    if (A = $18000) or (A = $98000) then
      Result := (Result shl 16) or HostRead(Address, 2)
    else
      Result := (Result shl 16) or V;
  end;
end;

procedure TSaturnCDB.HostWrite(Address, Value: Cardinal; Size: Integer);
begin
  var A := Address and $FFFFF;
  if (A = $18000) or (A = $98000) then
  begin
    if Size = 4 then
    begin
      HostWrite(Address, Value shr 16, 2);
      HostWrite(Address, Value and $FFFF, 2);
    end
    else if FRegisters[1] and 1 <> 0 then
    begin
      if FFIFOCount = Length(FFIFO) then
        FCPU.TransferDMA(1);
      PushFIFO(Word(Value));
    end;
    Exit;
  end;
  if Size = 4 then
    Value := Value shr 16;
  case A and $FFFFC of
    $90008:
      FRegisters[15] := FRegisters[15] and Word(Value);
    $9000C:
      FMask := Value;
    $90018, $9001C, $90020, $90024:
      begin
        var I := ((A and $3C) - $18) div 4;
        FCommands[I] := Value;
        if I = 3 then
        begin
          FRegisters[2] := FRegisters[2] or 1;
          FRegisters[15] := FRegisters[15] and not 1;
        end;
      end;
  end;
  UpdateIRQ;
end;

procedure TSaturnCDB.SerializeState(Archive: TStateArchive);
begin
  var Hash := THashSHA2.Create;
  Hash.Update(FROM);
  var Digest := Hash.HashAsBytes;
  var Expected := Copy(Digest);
  Archive.Field(Digest[0], Length(Digest));
  if Archive.Loading and not CompareMem(@Digest[0], @Expected[0], Length(Digest)) then
    raise EReadError.Create('SH-1 firmware mismatch');
  FCPU.SerializeState(Archive);
  Archive.Field(FDRAM, SizeOf(FDRAM));
  Archive.Field(FRegisters, SizeOf(FRegisters));
  Archive.Field(FCommands, SizeOf(FCommands));
  Archive.Field(FResponses, SizeOf(FResponses));
  Archive.Field(FMask, SizeOf(FMask));
  Archive.Field(FFIFO, SizeOf(FFIFO));
  Archive.Field(FFIFORead, SizeOf(FFIFORead));
  Archive.Field(FFIFOWrite, SizeOf(FFIFOWrite));
  Archive.Field(FFIFOCount, SizeOf(FFIFOCount));
  Archive.Field(FSerialAt, SizeOf(FSerialAt));
  Archive.Field(FTX, SizeOf(FTX));
  Archive.Field(FRX, SizeOf(FRX));
  Archive.Field(FDriveSlotAt, SizeOf(FDriveSlotAt));
  Archive.Field(FSerialDue, SizeOf(FSerialDue));
  Archive.Field(FSerialByte, SizeOf(FSerialByte));
  Archive.Field(FSerialBytes, SizeOf(FSerialBytes));
  Archive.Field(FMechanismStatus, SizeOf(FMechanismStatus));
  Archive.Field(FMechanismReport, SizeOf(FMechanismReport));
  Archive.Field(FDriveFAD, SizeOf(FDriveFAD));
  Archive.Field(FDriveTarget, SizeOf(FDriveTarget));
  Archive.Field(FDrivePlaying, SizeOf(FDrivePlaying));
  Archive.Field(FDriveSeekAt, SizeOf(FDriveSeekAt));
  Archive.Field(FSectorAt, SizeOf(FSectorAt));
  Archive.Field(FTOCEntry, SizeOf(FTOCEntry));
  Archive.Field(FTOCRepeat, SizeOf(FTOCRepeat));
  Archive.Field(FReadSpeed, SizeOf(FReadSpeed));
  Archive.Field(FTrayStartup, SizeOf(FTrayStartup));
  var Bytes := Length(FDecoded);
  Archive.Field(Bytes, SizeOf(Bytes));
  if (Bytes < 0) or (Bytes > 2352) then
    raise EReadError.Create('Invalid CD decoder state');
  SetLength(FDecoded, Bytes);
  if Bytes > 0 then
    Archive.Field(FDecoded[0], Bytes);
  Archive.Field(FDecodedAt, SizeOf(FDecodedAt));
  Archive.Field(FDecoderIRQPending, SizeOf(FDecoderIRQPending));
  Archive.Field(FAudio, SizeOf(FAudio));
  Archive.Field(FAudioAt, SizeOf(FAudioAt));
  var Protection := FProtection;
  Archive.Field(Protection, SizeOf(Protection));
  if Protection <> FProtection then
    raise EReadError.Create('SH-1 optical protection setting mismatch');
  if (FFIFORead < 0) or (FFIFORead >= Length(FFIFO)) or (FFIFOWrite < 0) or (FFIFOWrite >= Length(FFIFO)) or (FFIFOCount < 0) or (FFIFOCount > Length(FFIFO)) or (FSerialAt < 0) or (FSerialAt > 12) then
    raise EReadError.Create('Invalid CDB transfer state');
  if (FDecodedAt < 0) or (FDecodedAt > Bytes) or (FAudioAt < 0) or (FAudioAt > 2352) or (FAudioAt mod 4 <> 0) or
    (FTOCEntry < 0) or (FTOCEntry > 102) or (FTOCRepeat < 0) or (FTOCRepeat > 2) or
    (FReadSpeed < 1) or (FReadSpeed > 2) then
    raise EReadError.Create('Invalid CDB mechanism state');
  if Archive.Loading then
    UpdateIRQ;
end;

end.

