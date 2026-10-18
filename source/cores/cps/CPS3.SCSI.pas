unit CPS3.SCSI;

// WD33C93A host registers, polled initiator interface and SCSI CD target.
// Register/command semantics: Western Digital WD33C93A data sheet (1991).
interface

uses
  System.SysUtils, Core.CD.Disc, Core.Snapshots;

type
  TCPS3SCSI = class
  private
    FDisc: TCDDisc; // borrowed, accessed exclusively by the emulation worker
    FRegs: array[0..31] of Byte;
    FAddress, FAux, FSense, FASC, FStatus: Byte;
    FBuffer: TBytes;
    FAt, FLength, FLBA, FBlocks, FRemaining, FCommandAt, FPhase: Integer;
    FWriteData, FCombined, FDisconnectPending: Boolean;
    FCommands, FReadSectors: Int64;
    FTrace: array[0..127] of Cardinal;
    FTraceAt: Integer;
    procedure Complete(Status: Byte);
    procedure Execute(Command: Byte);
    procedure TargetCommand;
    procedure CountDown;
    function ReadData: Byte;
    procedure WriteData(Value: Byte);
    procedure SetCount(Value: Integer);
  public
    constructor Create(Disc: TCDDisc);
    procedure Reset;
    function Read(Port: Integer): Byte;
    procedure Write(Port: Integer; Value: Byte);
    procedure SerializeState(State: TStateArchive);
    function DebugState: string;
    property Commands: Int64 read FCommands;
    property ReadSectors: Int64 read FReadSectors;
  end;

implementation

uses
  System.Classes, System.Math;

constructor TCPS3SCSI.Create(Disc: TCDDisc);
begin
  inherited Create;
  FDisc := Disc;
  Reset;
end;

procedure TCPS3SCSI.Reset;
begin
  FillChar(FRegs, SizeOf(FRegs), 0);
  FAddress := 0;
  FAux := $80;
  FSense := 0;
  FASC := 0;
  FStatus := 0;
  FAt := 0;
  FLength := 0;
  FLBA := 0;
  FBlocks := 0;
  FRemaining := 0;
  FCommandAt := 0;
  FPhase := 0;
  FWriteData := False;
  FCombined := False;
  FDisconnectPending := False;
  FCommands := 0;
  FReadSectors := 0;
  SetLength(FBuffer, 2048);
end;

procedure TCPS3SCSI.SetCount(Value: Integer);
begin
  FRegs[$12] := Byte((Value shr 16) and $FF);
  FRegs[$13] := Byte((Value shr 8) and $FF);
  FRegs[$14] := Byte(Value and $FF);
end;

procedure TCPS3SCSI.CountDown;
begin
  if FRemaining > 0 then
    Dec(FRemaining);
  SetCount(FRemaining);
end;

procedure TCPS3SCSI.Complete(Status: Byte);
begin
  FRegs[$17] := Status;
  FAux := $80;
  FDisconnectPending := (Status = $16) and FCombined and (FRegs[1] and 8 = 0);
  FRegs[$0F] := FStatus;
end;

function TCPS3SCSI.Read(Port: Integer): Byte;
begin
  if Port = 0 then
    Exit(FAux);

  if FAddress = $19 then
    Exit(ReadData);

  if FAddress = $1F then
    Exit(FAux);

  Result := FRegs[FAddress];
  if FAddress = $17 then
  begin
    FAux := FAux and $7F;
    if FDisconnectPending then
    begin
      FDisconnectPending := False;
      FRegs[$17] := $85;
      FAux := FAux or $80;
    end;
  end;
  if FAddress <> $18 then
    FAddress := (FAddress + 1) and 31;
end;

procedure TCPS3SCSI.Write(Port: Integer; Value: Byte);
begin
  if FTraceAt < Length(FTrace) then
  begin
    FTrace[FTraceAt] := (Cardinal(Port) shl 24) or (Cardinal(FAddress) shl 8) or Value;
    Inc(FTraceAt);
  end;
  if Port = 0 then
  begin
    FAddress := Value and 31;
    Exit;
  end;

  if FAddress = $18 then
  begin
    FRegs[$18] := Value;
    Execute(Value);
    Exit;
  end;

  if FAddress = $19 then
  begin
    WriteData(Value);
    Exit;
  end;

  if FAddress >= $17 then
    Exit;

  FRegs[FAddress] := Value;
  FAddress := (FAddress + 1) and 31;
end;

procedure TCPS3SCSI.Execute(Command: Byte);
begin
  Inc(FCommands);
  FRemaining := (Integer(FRegs[$12]) shl 16) or (Integer(FRegs[$13]) shl 8) or FRegs[$14];
  if Command and $80 <> 0 then
    FRemaining := 1;
  case Command and $7F of
    $00:
      begin
        var OwnID := FRegs[0];
        Reset;
        FRegs[0] := OwnID;
        FRegs[$17] := Ord(OwnID and 8 <> 0);
      end;
    $01:
      begin
        FBlocks := 0;
        FLength := 0;
        Complete($28);
      end;
    $04:
      begin
        FBlocks := 0;
        FLength := 0;
        Complete($85);
      end;
    $06, $07:
      begin
        if FRegs[$15] and 7 <> 1 then
        begin
          Complete($42);
          Exit;
        end;

        FPhase := 2;
        FCommandAt := 0;
        FCombined := False;
        Complete($11);
      end;
    $08, $09:
      begin
        if FRegs[$15] and 7 <> 1 then
        begin
          Complete($42);
          Exit;
        end;

        FCombined := True;
        TargetCommand;
        if FLength + FBlocks > 0 then
          FAux := $21
        else
        begin
          FRegs[$10] := $60;
          Complete($16);
        end;
      end;
    $20:
      begin
        if FPhase = 3 then
        begin
          FBuffer[0] := FStatus;
          FLength := 1;
          FAt := 0;
          FAux := $21;
          FWriteData := False;
        end
        else if FPhase = 7 then
        begin
          FBuffer[0] := 0;
          FLength := 1;
          FAt := 0;
          FAux := $21;
          FWriteData := False;
        end
        else
        begin
          FWriteData := FPhase = 2;
          FAux := $21;
        end;
      end;
    $19:
      begin
        SetCount(0);
        Complete($18);
      end;
    $02, $03:
      Complete($18);
  else
    Complete($40);
  end;
end;

procedure TCPS3SCSI.TargetCommand;

  procedure DataLength(Count: Integer);
  begin
    FLength := Min(Count, Length(FBuffer));
  end;

  procedure Store32(At: Integer; Value: Cardinal);
  begin
    FBuffer[At] := Byte(Value shr 24);
    FBuffer[At + 1] := Byte((Value shr 16) and $FF);
    FBuffer[At + 2] := Byte((Value shr 8) and $FF);
    FBuffer[At + 3] := Byte(Value and $FF);
  end;

begin
  FAt := 0;
  FLength := 0;
  FBlocks := 0;
  FStatus := 0;
  FWriteData := False;
  FPhase := 1;
  FillChar(FBuffer[0], Length(FBuffer), 0);
  var C := FRegs[3];
  if (FDisc = nil) and not (C in [$03, $12]) then
  begin
    FSense := 2;
    FASC := $3A;
    FStatus := 2;
    Exit;
  end;

  case C of
    $00, $1B, $1E, $2B:
      ; // ready, start/stop, prevent/allow, seek
      $03:
      begin
        FBuffer[0] := $70;
        FBuffer[2] := FSense;
        FBuffer[7] := 10;
        FBuffer[12] := FASC;
        DataLength(Min(18, Integer(FRegs[7])));
        FSense := 0;
        FASC := 0;
      end;
    $12:
      begin
        FBuffer[0] := 5;
        FBuffer[1] := $80;
        FBuffer[2] := 2;
        FBuffer[3] := 2;
        FBuffer[4] := 31;
        var ID: AnsiString := 'MATSHITA' + 'CD-ROM CR-504   ' + '1.0 ';
        Move(ID[1], FBuffer[8], Length(ID));
        DataLength(Min(36, Integer(FRegs[7])));
      end;
    $25:
      begin
        Store32(0, FDisc.LeadOut - 1);
        Store32(4, 2048);
        DataLength(8);
      end;
    $08, $28, $A8:
      begin
        if C = $08 then
        begin
          FLBA := ((Integer(FRegs[4]) and 31) shl 16) or (Integer(FRegs[5]) shl 8) or FRegs[6];
          FBlocks := FRegs[7];
          if FBlocks = 0 then
            FBlocks := 256;
        end
        else
        begin
          var LBA := (Cardinal(FRegs[5]) shl 24) or (Cardinal(FRegs[6]) shl 16) or (Cardinal(FRegs[7]) shl 8) or FRegs[8];
          if LBA > Cardinal(High(Integer)) then
            FLBA := High(Integer)
          else
            FLBA := LBA;
          if C = $28 then
            FBlocks := (Integer(FRegs[10]) shl 8) or FRegs[11]
          else
            FBlocks := (Integer(FRegs[9]) shl 24) or (Integer(FRegs[10]) shl 16) or (Integer(FRegs[11]) shl 8) or FRegs[12];
        end;
        if (FLBA < 0) or (FBlocks < 0) or (Int64(FLBA) + FBlocks > FDisc.LeadOut) then
        begin
          FBlocks := 0;
          FSense := 5;
          FASC := $21;
          FStatus := 2;
        end;
      end;
    $1A:
      begin
        FBuffer[0] := 11;
        FBuffer[3] := 8;
        FBuffer[9] := 8;
        DataLength(Min(12, Integer(FRegs[7])));
      end;
    $15, $55:
      begin
        FWriteData := True;
        FPhase := 0;
        if C = $15 then
          DataLength(FRegs[7])
        else
          DataLength((Integer(FRegs[10]) shl 8) or FRegs[11]);
      end;
    $43:
      begin
        FBuffer[1] := 18;
        FBuffer[2] := 1;
        FBuffer[3] := 1;
        FBuffer[5] := $14;
        FBuffer[6] := 1;
        FBuffer[13] := $14;
        FBuffer[14] := $AA;
        Store32(16, FDisc.LeadOut);
        if FRegs[4] and 2 <> 0 then
        begin
          var T := FDisc.LeadOut + 150;
          FBuffer[17] := T div 4500;
          FBuffer[18] := (T div 75) mod 60;
          FBuffer[19] := T mod 75;
          FBuffer[10] := 2;
        end;
        DataLength(Min(20, (Integer(FRegs[10]) shl 8) or FRegs[11]));
      end;
  else
    begin
      FSense := 5;
      FASC := $20;
      FStatus := 2;
    end;
  end;
end;

function TCPS3SCSI.ReadData: Byte;
begin
  Result := 0;
  if FRemaining <= 0 then
    Exit;

  if (FAt >= FLength) and (FBlocks > 0) then
  begin
    FDisc.ReadData(FLBA, FBuffer);
    Inc(FLBA);
    Dec(FBlocks);
    Inc(FReadSectors);
    FAt := 0;
    FLength := Length(FBuffer);
  end;
  if FAt < FLength then
  begin
    Result := FBuffer[FAt];
    Inc(FAt);
  end;
  CountDown;
  if (FRemaining = 0) or ((FAt >= FLength) and (FBlocks = 0)) then
  begin
    if FCombined then
    begin
      FRegs[$10] := $60;
      Complete($16);
    end
    else
    begin
      Complete($18);
      if FPhase = 3 then
        FPhase := 7
      else
        FPhase := 3;
    end;
  end;
end;

procedure TCPS3SCSI.WriteData(Value: Byte);
begin
  if FRemaining <= 0 then
    Exit;

  if FPhase = 2 then
  begin
    if FCommandAt < 12 then
      FRegs[3 + FCommandAt] := Value;
    Inc(FCommandAt);
  end;
  CountDown;
  if FRemaining = 0 then
  begin
    if FPhase = 2 then
      TargetCommand
    else
      FPhase := 3;
    Complete($18);
  end;
end;

procedure TCPS3SCSI.SerializeState(State: TStateArchive);
begin
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FAddress, SizeOf(FAddress));
  State.Field(FAux, SizeOf(FAux));
  State.Field(FSense, SizeOf(FSense));
  State.Field(FASC, SizeOf(FASC));
  State.Field(FStatus, SizeOf(FStatus));
  State.Field(FBuffer[0], Length(FBuffer));
  State.Field(FAt, SizeOf(FAt));
  State.Field(FLength, SizeOf(FLength));
  State.Field(FLBA, SizeOf(FLBA));
  State.Field(FBlocks, SizeOf(FBlocks));
  State.Field(FRemaining, SizeOf(FRemaining));
  State.Field(FCommandAt, SizeOf(FCommandAt));
  State.Field(FPhase, SizeOf(FPhase));
  State.Field(FWriteData, SizeOf(FWriteData));
  State.Field(FCombined, SizeOf(FCombined));
  State.Field(FDisconnectPending, SizeOf(FDisconnectPending));
  State.Field(FCommands, SizeOf(FCommands));
  State.Field(FReadSectors, SizeOf(FReadSectors));

  if (FAddress > 31) or (FAt < 0) or (FAt > 2048) or (FLength < 0) or (FLength > 2048) or
    (FLBA < 0) or (FBlocks < 0) or (FBlocks > $1000000) or (FRemaining < 0) or (FRemaining > $FFFFFF) or
    (FCommandAt < 0) or (FCommandAt > 12) then
    raise EReadError.Create('Invalid CPS3 SCSI state');
end;

function TCPS3SCSI.DebugState: string;
begin
  Result := Format('addr=%x aux=%x remaining=%d buffer=%d/%d phase=%d regs=', [FAddress, FAux, FRemaining, FAt, FLength, FPhase]);
  for var R in FRegs do
    Result := Result + IntToHex(R, 2);
  Result := Result + ' trace=';
  for var i := 0 to FTraceAt - 1 do
    Result := Result + IntToHex(FTrace[i], 8) + ' ';
end;

end.

