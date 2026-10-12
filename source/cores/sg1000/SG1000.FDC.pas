unit SG1000.FDC;

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots, SG1000.Disk;

type
  TSGFDCState = record
    Phase, CommandCount, CommandSize, ResultCount, ResultIndex: Integer;
    Command: array[0..15] of Byte;
    Results: array[0..6] of Byte;
    Cylinder: array[0..3] of Byte;
    PendingST0: array[0..3] of Byte;
    Pending: Byte;
    SeekDrive, SeekTarget, SeekDelay, Delay, Position, IDPosition: Integer;
    C, H, R, N, EOT, LastC, LastH, LastR, LastN: Byte;
    ST0, ST1, ST2, Specify1, Specify2: Byte;
    IRQ, Selected, Motor, ResetLine, TC, ScanEqual, ScanLess, ScanGreater, NextPending: Boolean;
    Rotation: Integer;
  end;

  TSGFDC = class
  private
    FState: TSGFDCState;
    FBuffer: TBytes;
    FDisk: TSGDisk;
    procedure ResultBytes(const Bytes: array of Byte; IRQ: Boolean = False);
    procedure Complete;
    procedure ExecuteCommand;
    procedure Sector;
    procedure NextSector;
    function Ready: Boolean;
    function GetInterrupt: Boolean;
    function CommandLength(Command: Byte): Integer;
  public
    procedure Reset;
    procedure Mount(Disk: TSGDisk);
    procedure SetLines(Selected, Motor, ResetLine, TerminalCount: Boolean);
    procedure Advance(Cycles: Integer);
    function ReadStatus: Byte;
    function ReadData: Byte;
    procedure WriteData(Value: Byte);
    procedure SerializeState(State: TStateArchive);
    function IndexPulse: Boolean;
    property Interrupt: Boolean read GetInterrupt;
    property Disk: TSGDisk read FDisk;
  end;

implementation

const
  phIdle = 0;
  phCommand = 1;
  phRead = 2;
  phWrite = 3;
  phFormat = 4;
  phScan = 5;
  phResult = 6;
  ByteCycles = 114; // 250 kbit/s MFM data rate at the Z80 clock.

procedure TSGFDC.Reset;
begin
  var Selected := FState.Selected;
  var Motor := FState.Motor;
  var ResetLine := FState.ResetLine;
  FState := Default(TSGFDCState);
  FState.Selected := Selected;
  FState.Motor := Motor;
  FState.ResetLine := ResetLine;
  FBuffer := nil;
end;

procedure TSGFDC.Mount(Disk: TSGDisk);
begin
  FDisk := Disk;
end;

function TSGFDC.GetInterrupt: Boolean;
begin
  Result := FState.IRQ;
end;

function TSGFDC.Ready: Boolean;
begin
  Result := FState.Selected and FState.Motor and (FDisk <> nil) and
    (FState.Command[1] and 3 = 0);
end;

procedure TSGFDC.SetLines(Selected, Motor, ResetLine, TerminalCount: Boolean);
begin
  FState.Selected := Selected;
  FState.Motor := Motor;
  if ResetLine and not FState.ResetLine then
    Reset;
  if not ResetLine and FState.ResetLine then
  begin
    // Only the wired SF-7000 drive produces a ready-change interrupt.
    FState.Pending := 1;
    FState.PendingST0[0] := $C0;
    FState.IRQ := True;
  end;
  FState.ResetLine := ResetLine;
  if TerminalCount and not FState.TC and (FState.Phase in [phRead, phWrite, phScan]) then
    Complete;
  FState.TC := TerminalCount;
end;

function TSGFDC.CommandLength(Command: Byte): Integer;
begin
  case Command and $1F of
    $02, $05, $06, $09, $0C, $11, $19, $1D:
      Result := 9;
    $03, $0F:
      Result := 3;
    $04, $07, $0A:
      Result := 2;
    $0D:
      Result := 6;
  else
    Result := 1;
  end;
end;

procedure TSGFDC.ResultBytes(const Bytes: array of Byte; IRQ: Boolean);
begin
  FState.Phase := phResult;
  FState.ResultIndex := 0;
  FState.ResultCount := Length(Bytes);
  for var I := 0 to High(Bytes) do
    FState.Results[I] := Bytes[I];
  FState.IRQ := IRQ or (FState.Pending <> 0);
  FState.Delay := 0;
end;

procedure TSGFDC.Complete;
begin
  FState.NextPending := False;
  if FState.ST1 <> 0 then
    FState.ST0 := FState.ST0 or $40;
  if (FState.ST2 and $BF) <> 0 then
    FState.ST0 := FState.ST0 or $40;
  ResultBytes([FState.ST0, FState.ST1, FState.ST2, FState.LastC,
      FState.LastH, FState.LastR, FState.LastN], True);
end;

procedure TSGFDC.Sector;
begin
  FState.Position := 0;
  FState.LastC := FState.C;
  FState.LastH := FState.H;
  FState.LastR := FState.R;
  FState.LastN := FState.N;
  if not Ready then
  begin
    FState.ST0 := FState.ST0 or $48;
    FState.ST1 := 4;
    Complete;
    Exit;
  end;
  if FState.Cylinder[0] <> FState.C then
  begin
    FState.ST1 := 4;
    FState.ST2 := $10;
    Complete;
    Exit;
  end;
  if not FDisk.Read(FState.C, FState.H, FState.R, FState.N, FBuffer, FState.ST1, FState.ST2) then
  begin
    Complete;
    Exit;
  end;
  var Op := FState.Command[0] and $1F;
  if Op in [$05, $09] then
  begin
    if FDisk.WriteProtected then
    begin
      FState.ST1 := 2;
      Complete;
      Exit;
    end;
    FState.ST1 := 0;
    FState.ST2 := 0;
    // Length N=0 uses DTL; ordinary transfers use the recorded size.
    if (FState.N = 0) and (FState.Command[8] <> 0) then
      SetLength(FBuffer, FState.Command[8]);
    FState.Phase := phWrite;
  end
  else if Op in [$11, $19, $1D] then
  begin
    FState.Phase := phScan;
    FState.ScanEqual := True;
    FState.ScanLess := False;
    FState.ScanGreater := False;
  end
  else
  begin
    if (Op = $0C) <> (FState.ST2 and $40 <> 0) then
    begin
      if FState.Command[0] and $20 <> 0 then
      begin
        NextSector;
        Exit;
      end;
      FState.ST2 := FState.ST2 or $40;
    end
    else
      FState.ST2 := FState.ST2 and $BF;
    if (FState.N = 0) and (FState.Command[8] <> 0) and (Length(FBuffer) > FState.Command[8]) then
      SetLength(FBuffer, FState.Command[8]);
    FState.Phase := phRead;
  end;
  FState.Delay := ByteCycles;
end;

procedure TSGFDC.NextSector;
begin
  if (FState.R >= FState.EOT) or (FState.R = $FF) then
  begin
    if (FState.Command[0] and $80 <> 0) and (FState.H = 0) then
    begin
      FState.H := 1;
      FState.R := 1;
      Sector;
      Exit;
    end;
    FState.ST1 := FState.ST1 or $80;
    Complete;
  end
  else
  begin
    Inc(FState.R);
    Sector;
  end;
end;

procedure TSGFDC.ExecuteCommand;
begin
  var Op := FState.Command[0] and $1F;
  var Drive := FState.Command[1] and 3;
  var Head := (FState.Command[1] shr 2) and 1;
  FState.ST0 := FState.Command[1] and 7;
  FState.ST1 := 0;
  FState.ST2 := 0;
  case Op of
    $03:
      begin
        FState.Specify1 := FState.Command[1];
        FState.Specify2 := FState.Command[2];
        FState.Phase := phIdle;
      end;
    $04:
      begin
        var ST3 := FState.Command[1] and 7;
        if Ready then
          ST3 := ST3 or $20;
        if FState.Cylinder[Drive] = 0 then
          ST3 := ST3 or $10;
        if (FDisk <> nil) and FDisk.WriteProtected then
          ST3 := ST3 or $40;
        ResultBytes([ST3]);
      end;
    $07, $0F:
      begin
        FState.SeekDrive := Drive;
        FState.SeekTarget := 0;
        if Op = $0F then
          FState.SeekTarget := FState.Command[2];
        FState.SeekDelay := 7000 + Abs(FState.SeekTarget - FState.Cylinder[Drive]) * 3500;
        FState.Pending := FState.Pending and ($0F xor (1 shl Drive));
        FState.IRQ := FState.Pending <> 0;
        FState.Phase := phIdle;
      end;
    $08:
      begin
        if FState.Pending = 0 then
          ResultBytes([$80])
        else
          for var I := 0 to 3 do
            if FState.Pending and (1 shl I) <> 0 then
            begin
              FState.Pending := FState.Pending and ($0F xor (1 shl I));
              ResultBytes([FState.PendingST0[I], FState.Cylinder[I]]);
              Break;
            end;
      end;
    $0A:
      begin
        var ID := Default(TSGSector);
        if Ready and FDisk.ReadID(FState.Cylinder[Drive], Head, FState.IDPosition, ID) then
        begin
          Inc(FState.IDPosition);
          if FState.IDPosition >= 256 then
            FState.IDPosition := 0;
          FState.LastC := ID.Cylinder;
          FState.LastH := ID.Head;
          FState.LastR := ID.ID;
          FState.LastN := ID.SizeCode;
          FState.ST1 := ID.Status1;
          FState.ST2 := ID.Status2;
        end
        else
        begin
          FState.ST0 := FState.ST0 or $48;
          FState.ST1 := 4;
        end;
        Complete;
      end;
    $0D:
      begin
        FState.LastC := FState.Cylinder[Drive];
        FState.LastH := Head;
        FState.LastR := 0;
        FState.LastN := FState.Command[2];
        if not Ready then
        begin
          FState.ST0 := FState.ST0 or $48;
          Complete;
          Exit;
        end;
        if FDisk.WriteProtected then
        begin
          FState.ST1 := 2;
          Complete;
          Exit;
        end;
        if (FState.Command[3] = 0) or (FState.Command[3] > 29) then
        begin
          FState.ST1 := 4;
          Complete;
          Exit;
        end;
        SetLength(FBuffer, FState.Command[3] * 4);
        FState.Position := 0;
        FState.Phase := phFormat;
        FState.Delay := ByteCycles;
      end;
    $02, $05, $06, $09, $0C, $11, $19, $1D:
      begin
        FState.C := FState.Command[2];
        FState.H := FState.Command[3];
        FState.R := FState.Command[4];
        FState.N := FState.Command[5];
        FState.EOT := FState.Command[6];
        Sector;
      end;
  else
    ResultBytes([$80]);
  end;
end;

procedure TSGFDC.Advance(Cycles: Integer);
begin
  if Cycles < 0 then
    raise EArgumentOutOfRangeException.Create('FDC clocks');
  FState.Rotation := (FState.Rotation + Cycles) mod 715909;
  if FState.ResetLine then
    Exit;
  if FState.Delay > 0 then
    FState.Delay := System.Math.Max(0, FState.Delay - Cycles);
  if (FState.Delay = 0) and FState.NextPending then
  begin
    FState.NextPending := False;
    NextSector;
  end;
  if FState.SeekDelay > 0 then
  begin
    FState.SeekDelay := System.Math.Max(0, FState.SeekDelay - Cycles);
    if FState.SeekDelay = 0 then
    begin
      var Drive := FState.SeekDrive;
      FState.Cylinder[Drive] := FState.SeekTarget;
      FState.PendingST0[Drive] := $20 or Drive;
      if Drive <> 0 then
        FState.PendingST0[Drive] := FState.PendingST0[Drive] or $48;
      FState.Pending := FState.Pending or (1 shl Drive);
      FState.IRQ := True;
    end;
  end;
end;

function TSGFDC.IndexPulse: Boolean;
begin
  Result := FState.Selected and FState.Motor and (FDisk <> nil) and (FState.Rotation < 14000);
end;

function TSGFDC.ReadStatus: Byte;
begin
  Result := $80;
  if FState.Delay > 0 then
    Result := 0;
  if FState.Phase <> phIdle then
    Result := Result or $10;
  if FState.Phase in [phRead, phResult] then
    Result := Result or $40;
  if FState.Phase in [phRead, phWrite, phFormat, phScan] then
    Result := Result or $20;
  if FState.SeekDelay > 0 then
    Result := Result or (1 shl FState.SeekDrive);
end;

function TSGFDC.ReadData: Byte;
begin
  Result := $FF;
  if FState.ResetLine or (FState.Delay > 0) then
    Exit;
  if FState.Phase = phResult then
  begin
    Result := FState.Results[FState.ResultIndex];
    Inc(FState.ResultIndex);
    FState.IRQ := FState.Pending <> 0;
    if FState.ResultIndex = FState.ResultCount then
      FState.Phase := phIdle;
  end
  else if FState.Phase = phRead then
  begin
    Result := FBuffer[FState.Position];
    Inc(FState.Position);
    FState.Delay := ByteCycles;
    if FState.Position = Length(FBuffer) then
    begin
      if (FState.ST1 <> 0) or (FState.ST2 <> 0) then
        Complete
      else
        FState.NextPending := True;
    end;
  end;
end;

procedure TSGFDC.WriteData(Value: Byte);
begin
  if FState.ResetLine or (FState.Delay > 0) then
    Exit;
  if FState.Phase in [phIdle, phCommand] then
  begin
    if FState.Phase = phIdle then
    begin
      FState.Phase := phCommand;
      FState.CommandCount := 0;
      FState.CommandSize := CommandLength(Value);
      FState.IRQ := FState.Pending <> 0;
    end;
    FState.Command[FState.CommandCount] := Value;
    Inc(FState.CommandCount);
    if FState.CommandCount = FState.CommandSize then
      ExecuteCommand;
  end
  else if FState.Phase in [phWrite, phFormat, phScan] then
  begin
    if FState.Phase = phScan then
    begin
      var DiskValue := FBuffer[FState.Position];
      if (Value <> $FF) and (DiskValue <> Value) then
        FState.ScanEqual := False;
      if (Value <> $FF) and not FState.ScanLess and not FState.ScanGreater then
      begin
        FState.ScanLess := DiskValue < Value;
        FState.ScanGreater := DiskValue > Value;
      end;
    end
    else
      FBuffer[FState.Position] := Value;
    Inc(FState.Position);
    FState.Delay := ByteCycles;
    if FState.Position < Length(FBuffer) then
      Exit;
    if FState.Phase = phFormat then
    begin
      FDisk.Format(FState.LastC, FState.LastH, FBuffer, FState.Command[5]);
      FState.LastC := FBuffer[Length(FBuffer) - 4];
      FState.LastH := FBuffer[Length(FBuffer) - 3];
      FState.LastR := FBuffer[Length(FBuffer) - 2];
      FState.LastN := FBuffer[Length(FBuffer) - 1];
      Complete;
    end
    else if FState.Phase = phScan then
    begin
      var Op := FState.Command[0] and $1F;
      if FState.ScanEqual or ((Op = $19) and FState.ScanLess) or ((Op = $1D) and FState.ScanGreater) then
      begin
        FState.ST2 := Ord(FState.ScanEqual) * 8;
        Complete;
      end
      else if FState.R >= FState.EOT then
      begin
        FState.ST2 := 4;
        Complete;
      end
      else
        FState.NextPending := True;
    end
    else
    begin
      if not FDisk.Write(FState.C, FState.H, FState.R, FState.N, FBuffer,
        FState.Command[0] and $1F = $09) then
      begin
        FState.ST1 := 2;
        Complete;
      end
      else
        NextSector;
    end;
  end;
end;

procedure TSGFDC.SerializeState(State: TStateArchive);
begin
  State.Field(FState, SizeOf(FState));
  var Size := Length(FBuffer);
  State.Field(Size, SizeOf(Size));
  if (Size < 0) or (Size > 65536) then
    raise EReadError.Create('Invalid FDC snapshot buffer');
  if State.Loading then
    SetLength(FBuffer, Size);
  if Size > 0 then
    State.Field(FBuffer[0], Size);
  if State.Loading and ((FState.Phase < 0) or (FState.Phase > phResult) or
    (FState.Position < 0) or (FState.Position > Size) or
    (FState.ResultIndex < 0) or (FState.ResultCount < 0) or (FState.ResultCount > 7) or
    (FState.ResultIndex > FState.ResultCount) or (FState.SeekDrive < 0) or (FState.SeekDrive > 3) or
    (FState.CommandCount < 0) or (FState.CommandCount > 16)) then
    raise EReadError.Create('Invalid FDC snapshot state');
end;

end.

