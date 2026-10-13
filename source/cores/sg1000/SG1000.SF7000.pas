unit SG1000.SF7000;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, SG1000.Disk, SG1000.FDC;

type
  TSF7000State = record
    RAM: array[0..$FFFF] of Byte;
    PPI: array[0..2] of Byte;
    Control, SerialMode, SerialCommand, SerialErrors, SerialData: Byte;
    ExpectSerialMode, SerialBusy: Boolean;
    SerialCycles: Integer;
  end;

  TSF7000 = class
  private
    FIPL: TBytes;
    FDisk: TSGDisk;
    FFDC: TSGFDC;
    FState: TSF7000State;
    FPrinter, FSerialOut, FSerialIn: TBytes;
    procedure ApplyControl(Previous: Byte);
    procedure Append(var Buffer: TBytes; Value: Byte);
  public
    constructor Create(const IPL, Image: TBytes; protected: Boolean = False);
    destructor Destroy; override;
    procedure Reset;
    procedure Advance(Cycles: Integer);
    function ReadMemory(Address: Word): Byte;
    procedure WriteMemory(Address: Word; Value: Byte);
    function ReadPort(Port: Byte): Byte;
    procedure WritePort(Port, Value: Byte);
    procedure Mount(const Image: TBytes; protected: Boolean);
    procedure ReceiveSerial(const Data: TBytes);
    function TakeSerial: TBytes;
    function TakePrinter: TBytes;
    procedure SerializeState(State: TStateArchive);
    property Disk: TSGDisk read FDisk;
    property FDC: TSGFDC read FFDC;
  end;

implementation

constructor TSF7000.Create(const IPL, Image: TBytes; protected: Boolean);
begin
  inherited Create;
  if Length(IPL) <> $2000 then
    raise EReadError.Create('SF-7000 IPL must contain 8192 bytes');

  FIPL := Copy(IPL);
  FFDC := TSGFDC.Create;
  Mount(Image, protected);
  Reset;
end;

destructor TSF7000.Destroy;
begin
  FFDC.Free;
  FDisk.Free;
  inherited;
end;

procedure TSF7000.Mount(const Image: TBytes; protected: Boolean);
begin
  var Disk: TSGDisk := nil;
  if Length(Image) > 0 then
    Disk := TSGDisk.Create(Image, protected);
  FFDC.Mount(Disk);
  FDisk.Free;
  FDisk := Disk;
end;

procedure TSF7000.Reset;
begin
  FState := Default(TSF7000State);
  FState.Control := $9B;
  FState.PPI[2] := $8F;
  FState.ExpectSerialMode := True;
  FPrinter := nil;
  FSerialOut := nil;
  FSerialIn := nil;
  FFDC.Reset;
  ApplyControl($8F);
end;

procedure TSF7000.Append(var Buffer: TBytes; Value: Byte);
begin
  if Length(Buffer) >= 1024 * 1024 then
    raise EWriteError.Create('SF-7000 output queue exceeds 1 MiB');

  var Size := Length(Buffer);
  SetLength(Buffer, Size + 1);
  Buffer[Size] := Value;
end;

procedure TSF7000.ApplyControl(Previous: Byte);
begin
  var C := FState.PPI[2];
  FFDC.SetLines(C and 1 = 0, C and 2 = 0, C and 8 <> 0, C and 4 <> 0);
  if (Previous and $80 <> 0) and (C and $80 = 0) then
    Append(FPrinter, FState.PPI[1]);
end;

function TSF7000.ReadMemory(Address: Word): Byte;
begin
  if (Address < $4000) and (FState.PPI[2] and $40 = 0) then
  begin
    if Address < Length(FIPL) then
      Result := FIPL[Address]
    else
      Result := 0;
  end
  else
    Result := FState.RAM[Address];
end;

procedure TSF7000.WriteMemory(Address: Word; Value: Byte);
begin
  // IPL only overlays reads: writes always reach the underlying 64 KiB RAM.
  FState.RAM[Address] := Value;
end;

function TSF7000.ReadPort(Port: Byte): Byte;
begin
  Result := $FF;
  case Port of
    $E0:
      Result := FFDC.ReadStatus;
    $E1:
      Result := FFDC.ReadData;
    $E4:
      if FState.Control and $10 <> 0 then
        Result := Ord(FFDC.Interrupt) or (Ord(FFDC.IndexPulse) shl 2)
      else
        Result := FState.PPI[0];
    $E5:
      Result := FState.PPI[1];
    $E6:
      begin
        Result := FState.PPI[2];
        if FState.Control and 8 <> 0 then
          Result := Result or $F0;
        if FState.Control and 1 <> 0 then
          Result := Result or $0F;
      end;
    $E8:
      if (Length(FSerialIn) > 0) and (FState.SerialCommand and 4 <> 0) then
      begin
        Result := FSerialIn[0];
        FSerialIn := Copy(FSerialIn, 1, Length(FSerialIn) - 1);
      end;
    $E9:
      begin
        Result := $80 or FState.SerialErrors;
        if not FState.SerialBusy then
          Result := Result or 5;
        if (Length(FSerialIn) > 0) and (FState.SerialCommand and 4 <> 0) then
          Result := Result or 2;
      end;
  end;
end;

procedure TSF7000.WritePort(Port, Value: Byte);
begin
  case Port of
    $E1:
      FFDC.WriteData(Value);
    $E4, $E5:
      FState.PPI[Port - $E4] := Value;
    $E6, $E7:
      begin
        var Previous := FState.PPI[2];
        if Port = $E6 then
          FState.PPI[2] := Value
        else if Value and $80 <> 0 then
        begin
          FState.Control := Value;
          FillChar(FState.PPI, SizeOf(FState.PPI), 0);
        end
        else
        begin
          var Bit := (Value shr 1) and 7;
          if Value and 1 <> 0 then
            FState.PPI[2] := FState.PPI[2] or (1 shl Bit)
          else
            FState.PPI[2] := FState.PPI[2] and ($FF xor (1 shl Bit));
        end;
        ApplyControl(Previous);
      end;
    $E8:
      if (FState.SerialCommand and 1 <> 0) and not FState.SerialBusy then
      begin
        FState.SerialData := Value;
        FState.SerialBusy := True;
        FState.SerialCycles := 119318; // 300 baud, 10-bit asynchronous character.
      end;
    $E9:
      if FState.ExpectSerialMode then
      begin
        FState.SerialMode := Value;
        FState.ExpectSerialMode := False;
      end
      else if Value and $40 <> 0 then
      begin
        FState.ExpectSerialMode := True;
        FState.SerialCommand := 0;
        FState.SerialBusy := False;
      end
      else
      begin
        FState.SerialCommand := Value;
        if Value and $10 <> 0 then
          FState.SerialErrors := 0;
      end;
  end;
end;

procedure TSF7000.Advance(Cycles: Integer);
begin
  FFDC.Advance(Cycles);
  if FState.SerialBusy then
  begin
    Dec(FState.SerialCycles, Cycles);
    if FState.SerialCycles <= 0 then
    begin
      Append(FSerialOut, FState.SerialData);
      FState.SerialBusy := False;
    end;
  end;
end;

procedure TSF7000.ReceiveSerial(const Data: TBytes);
begin
  for var Value in Data do
    Append(FSerialIn, Value);
end;

function TSF7000.TakeSerial: TBytes;
begin
  Result := FSerialOut;
  FSerialOut := nil;
end;

function TSF7000.TakePrinter: TBytes;
begin
  Result := FPrinter;
  FPrinter := nil;
end;

procedure TSF7000.SerializeState(State: TStateArchive);

  procedure Bytes(var Buffer: TBytes);
  begin
    var Size := Length(Buffer);
    State.Field(Size, SizeOf(Size));
    if (Size < 0) or (Size > 1024 * 1024) then
      raise EReadError.Create('Invalid SF-7000 queue snapshot');

    if State.Loading then
      SetLength(Buffer, Size);
    if Size > 0 then
      State.Field(Buffer[0], Size);
  end;

begin
  State.Field(FState, SizeOf(FState));
  FFDC.SerializeState(State);
  var Present := FDisk <> nil;
  State.Field(Present, SizeOf(Present));
  if State.Loading and Present and (FDisk = nil) then
  begin
    var Blank: TBytes;
    SetLength(Blank, 163840);
    Mount(Blank, False);
  end;
  if Present then
    FDisk.SerializeState(State)
  else if State.Loading then
    Mount(nil, False);
  Bytes(FPrinter);
  Bytes(FSerialIn);
  Bytes(FSerialOut);
end;

end.

