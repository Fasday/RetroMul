unit ZX.DivStorage;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, ZX.BlockImage, ZX.Machine;

type
  TZXDivState = record
    Control, Select, SPIByte: Byte;
    AutoMap, PendingMap, MapPending: Boolean;
    ATA: array[0..7] of Byte;
    ATACommand, ATAHigh, ATALow: Byte;
    ATAOdd: Boolean;
    ATAPosition, ATARemaining: Integer;
    ATALBA: Cardinal;
    ATABuffer: array[0..511] of Byte;
    SDCommand: array[0..5] of Byte;
    SDCount, SDResponsePosition, SDResponseCount, SDWritePosition: Integer;
    SDResponse: array[0..519] of Byte;
    SDBuffer: array[0..513] of Byte;
    SDIdle, SDApp, SDHC, SDCRC, SDReadMultiple, SDWriteMultiple: Boolean;
    SDWriting, SDBusy: Byte;
    SDLBA: Cardinal;
    RAM: array[0..63, 0..8191] of Byte;
  end;

  TZXDivStorage = class
  private
    FKind: TZXDivType;
    FBanks: Integer;
    FROM: array[0..8191] of Byte;
    FState: TZXDivState;
    FDisk: TZXBlockImage;
    function MemoryBank(Address: Word): Integer;
    procedure ATACommand(Value: Byte);
    procedure ATAError(Code: Byte);
    procedure ATASector;
    procedure ATANext;
    procedure SDReply(const Bytes: array of Byte);
    procedure SDCommand;
    procedure SDData(const Data: TBytes);
    function SPI(Value: Byte): Byte;
    function CRC16(const Data: TBytes): Word;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Configure(Kind: TZXDivType; RAMKB: Integer = 128; const Firmware: TBytes = nil);
    procedure Mount(Source: TStream; const KnownHash: TBytes = nil);
    procedure Reset(PowerOn: Boolean);
    function Mapped: Boolean;
    procedure BeforeFetch(Address: Word);
    procedure AfterFetch(Address: Word);
    procedure Refresh;
    function ReadMemory(Address: Word): Byte;
    procedure WriteMemory(Address: Word; Value: Byte);
    function ReadPort(Address: Word; out Value: Byte): Boolean;
    procedure WritePort(Address: Word; Value: Byte);
    procedure SerializeState(State: TStateArchive);
    property Kind: TZXDivType read FKind;
    property Banks: Integer read FBanks;
    property Disk: TZXBlockImage read FDisk;
  end;

implementation

uses
  System.Math;

constructor TZXDivStorage.Create;
begin
  inherited;
  FBanks := 4;
  Reset(True);
end;

destructor TZXDivStorage.Destroy;
begin
  FDisk.Free;
  inherited;
end;

procedure TZXDivStorage.Configure(Kind: TZXDivType; RAMKB: Integer; const Firmware: TBytes);
begin
  if not ((RAMKB = 0) or (RAMKB = 128) or (RAMKB = 512)) then
    raise EArgumentException.Create('DivMMC RAM must be 128 or 512 KiB');
  FKind := Kind;
  FBanks := 4;
  if Kind = zdMMC then
  begin
    FBanks := 16;
    if RAMKB = 512 then
      FBanks := 64;
  end;
  if Kind <> zdNone then
  begin
    var Data := Firmware;
    if Length(Data) = 0 then
    begin
      var Name := 'ZX_ESXIDE';
      if Kind = zdMMC then
        Name := 'ZX_ESXMMC';
      var S := TResourceStream.Create(HInstance, Name, PChar(10));
      try
        SetLength(Data, S.Size);
        if S.Size > 0 then
          S.ReadBuffer(Data[0], Length(Data));
      finally
        S.Free;
      end;
    end;
    if Length(Data) <> 8192 then
      raise EReadError.Create('DivIDE/DivMMC firmware must be exactly 8 KiB');
    Move(Data[0], FROM[0], 8192);
  end;
  Reset(True);
end;

procedure TZXDivStorage.Mount(Source: TStream; const KnownHash: TBytes);
begin
  var Disk := TZXBlockImage.Create(Source, KnownHash);
  FDisk.Free;
  FDisk := Disk;
end;

procedure TZXDivStorage.Reset(PowerOn: Boolean);
begin
  if PowerOn then
    FillChar(FState, SizeOf(FState), 0)
  else
  begin
    FState.Control := FState.Control and $40;
    FState.AutoMap := False;
    FState.MapPending := False;
  end;
  FState.Select := 3;
  FState.SPIByte := $FF;
  FillChar(FState.ATA, SizeOf(FState.ATA), 0);
  FState.ATA[2] := 1;
  FState.ATA[3] := 1;
  FState.ATA[7] := $50;
  FState.ATAOdd := False;
  FState.ATACommand := 0;
  FState.ATAPosition := 0;
  FState.ATARemaining := 0;
  FState.SDIdle := True;
  FState.SDApp := False;
  FState.SDHC := False;
  FState.SDCRC := False;
  FState.SDCount := 0;
  FState.SDResponseCount := 0;
  FState.SDResponsePosition := 0;
  FState.SDWriting := 0;
  FState.SDWritePosition := 0;
  FState.SDBusy := 0;
  FState.SDReadMultiple := False;
  FState.SDWriteMultiple := False;
end;

function TZXDivStorage.Mapped: Boolean;
begin
  Result := (FKind <> zdNone) and (FState.AutoMap or ((FState.Control and $80) <> 0));
end;

procedure TZXDivStorage.BeforeFetch(Address: Word);
begin
  if (FKind <> zdNone) and ((Address and $FF00) = $3D00) then
    FState.AutoMap := True;
end;

procedure TZXDivStorage.AfterFetch(Address: Word);
begin
  if FKind = zdNone then
    Exit;
  if (Address = $0000) or (Address = $0008) or (Address = $0038) or (Address = $0066) or
    (Address = $04C6) or (Address = $0562) then
  begin
    FState.PendingMap := True;
    FState.MapPending := True;
  end
  else if (Address and $FFF8) = $1FF8 then
  begin
    FState.PendingMap := False;
    FState.MapPending := True;
  end;
end;

procedure TZXDivStorage.Refresh;
begin
  if FState.MapPending then
  begin
    FState.AutoMap := FState.PendingMap;
    FState.MapPending := False;
  end;
end;

function TZXDivStorage.MemoryBank(Address: Word): Integer;
begin
  if Address < $2000 then
  begin
    if (FState.Control and $C0) = $40 then
      Result := 3
    else
      Result := -1;
  end
  else
    Result := FState.Control and (FBanks - 1);
end;

function TZXDivStorage.ReadMemory(Address: Word): Byte;
begin
  var B := MemoryBank(Address);
  if B < 0 then
    Result := FROM[Address and $1FFF]
  else
    Result := FState.RAM[B, Address and $1FFF];
end;

procedure TZXDivStorage.WriteMemory(Address: Word; Value: Byte);
begin
  var B := MemoryBank(Address);
  if (Address >= $2000) and ((FState.Control and $C0) <> $40) then
    FState.RAM[B, Address and $1FFF] := Value
  else if (Address >= $2000) and (B <> 3) then
    FState.RAM[B, Address and $1FFF] := Value;
end;

procedure TZXDivStorage.ATAError(Code: Byte);
begin
  FState.ATA[1] := Code;
  FState.ATA[7] := $51;
  FState.ATACommand := 0;
end;

procedure TZXDivStorage.ATASector;
begin
  FState.ATAPosition := 0;
  if (FDisk = nil) or (FState.ATALBA >= FDisk.Sectors) then
  begin
    ATAError($10);
    Exit;
  end;
  var Data: TBytes;
  if not FDisk.ReadSector(FState.ATALBA, Data) then
  begin
    ATAError($10);
    Exit;
  end;
  Move(Data[0], FState.ATABuffer[0], 512);
  FState.ATA[7] := $58;
end;

procedure TZXDivStorage.ATANext;
begin
  Dec(FState.ATARemaining);
  Inc(FState.ATALBA);
  FState.ATA[2] := FState.ATARemaining and 255;
  if (FState.ATA[6] and $40) <> 0 then
  begin
    FState.ATA[3] := FState.ATALBA and 255;
    FState.ATA[4] := (FState.ATALBA shr 8) and 255;
    FState.ATA[5] := (FState.ATALBA shr 16) and 255;
    FState.ATA[6] := (FState.ATA[6] and $F0) or ((FState.ATALBA shr 24) and 15);
  end
  else
  begin
    FState.ATA[3] := FState.ATALBA mod 63 + 1;
    FState.ATA[6] := (FState.ATA[6] and $F0) or ((FState.ATALBA div 63) mod 16);
    var Cylinder := FState.ATALBA div 1008;
    FState.ATA[4] := Cylinder and 255;
    FState.ATA[5] := (Cylinder shr 8) and 255;
  end;
  if FState.ATARemaining > 0 then
    ATASector
  else
  begin
    FState.ATA[7] := $50;
    FState.ATACommand := 0;
  end;
end;

procedure TZXDivStorage.ATACommand(Value: Byte);
begin
  FState.ATACommand := Value;
  FState.ATAOdd := False;
  FState.ATA[1] := 0;
  if (FDisk = nil) or ((FState.ATA[6] and $10) <> 0) then
  begin
    ATAError(4);
    Exit;
  end;
  FState.ATARemaining := FState.ATA[2];
  if FState.ATARemaining = 0 then
    FState.ATARemaining := 256;
  if (FState.ATA[6] and $40) <> 0 then
    FState.ATALBA := Cardinal(FState.ATA[3]) or (Cardinal(FState.ATA[4]) shl 8) or
      (Cardinal(FState.ATA[5]) shl 16) or (Cardinal(FState.ATA[6] and 15) shl 24)
  else
  begin
    if not (FState.ATA[3] in [1..63]) then
    begin
      ATAError($10);
      Exit;
    end;
    FState.ATALBA := ((Cardinal(FState.ATA[4]) or (Cardinal(FState.ATA[5]) shl 8)) * 16 +
      (FState.ATA[6] and 15)) * 63 + FState.ATA[3] - 1;
  end;
  case Value of
    $20, $21:
      ATASector;
    $30, $31:
      if FDisk.WriteProtected then
        ATAError(4)
      else
        ATASector;
    $EC:
      begin
        FillChar(FState.ATABuffer, 512, 0);
        FState.ATAPosition := 0;
        FState.ATABuffer[0] := $40;
        FState.ATABuffer[2] := $FF;
        FState.ATABuffer[3] := $3F;
        FState.ATABuffer[6] := 16;
        FState.ATABuffer[12] := 63;
        FState.ATABuffer[99] := 2;
        FState.ATABuffer[106] := 1;
        FState.ATABuffer[120] := FDisk.Sectors and 255;
        FState.ATABuffer[121] := (FDisk.Sectors shr 8) and 255;
        FState.ATABuffer[122] := (FDisk.Sectors shr 16) and 255;
        FState.ATABuffer[123] := FDisk.Sectors shr 24;
        var Model: AnsiString := 'RETROMUL NATIVE CF                      ';
        for var i := 0 to 39 do
          FState.ATABuffer[54 + (i xor 1)] := Ord(Model[i + 1]);
        FState.ATA[7] := $58;
      end;
    $E7, $EF, $91, $10..$1F:
      begin
        FState.ATACommand := 0;
        FState.ATA[7] := $50;
      end;
  else
    ATAError(4);
  end;
end;

function TZXDivStorage.ReadPort(Address: Word; out Value: Byte): Boolean;
begin
  Result := False;
  Value := $FF;
  if FKind = zdNone then
    Exit;
  var P := Byte(Address and 255);
  if P = $E3 then
  begin
    FState.ATAOdd := False;
    Exit;
  end;
  if FKind = zdMMC then
  begin
    Result := P = $EB;
    if Result then
    begin
      Value := FState.SPIByte;
      FState.SPIByte := SPI($FF);
    end;
    Exit;
  end;
  Result := (P and $E3) = $A3;
  if not Result then
    Exit;
  var R := (P shr 2) and 7;
  if R <> 0 then
  begin
    FState.ATAOdd := False;
    Value := FState.ATA[R];
    if (FState.ATA[6] and $10) <> 0 then
      Value := 0;
  end
  else if FState.ATAOdd then
  begin
    Value := FState.ATAHigh;
    FState.ATAOdd := False;
  end
  else if (FState.ATA[7] and 8) <> 0 then
  begin
    Value := FState.ATABuffer[FState.ATAPosition];
    FState.ATAHigh := FState.ATABuffer[FState.ATAPosition + 1];
    Inc(FState.ATAPosition, 2);
    FState.ATAOdd := True;
    if FState.ATAPosition = 512 then
      if FState.ATACommand = $EC then
      begin
        FState.ATA[7] := $50;
        FState.ATACommand := 0;
      end
      else
        ATANext;
  end;
end;

procedure TZXDivStorage.WritePort(Address: Word; Value: Byte);
begin
  if FKind = zdNone then
    Exit;
  var P := Byte(Address and 255);
  if P = $E3 then
  begin
    FState.Control := Value or (FState.Control and $40);
    FState.ATAOdd := False;
    Exit;
  end;
  if FKind = zdMMC then
  begin
    if P = $E7 then
    begin
      FState.Select := Value and 3;
      if FState.Select <> 2 then
      begin
        FState.SPIByte := $FF;
        FState.SDCount := 0;
        FState.SDResponseCount := 0;
        FState.SDResponsePosition := 0;
        FState.SDWriting := 0;
        FState.SDReadMultiple := False;
        FState.SDWriteMultiple := False;
      end;
    end;
    if P = $EB then
      FState.SPIByte := SPI(Value);
    Exit;
  end;
  if (P and $E3) <> $A3 then
    Exit;
  var R := (P shr 2) and 7;
  if R <> 0 then
  begin
    FState.ATAOdd := False;
    if R = 7 then
      ATACommand(Value)
    else
      FState.ATA[R] := Value;
  end
  else if (FState.ATA[7] and 8) <> 0 then
  begin
    if not FState.ATAOdd then
    begin
      FState.ATALow := Value;
      FState.ATAOdd := True;
    end
    else
    begin
      FState.ATAOdd := False;
      if not (FState.ATACommand in [$30, $31]) then
        Exit;
      FState.ATABuffer[FState.ATAPosition] := FState.ATALow;
      FState.ATABuffer[FState.ATAPosition + 1] := Value;
      Inc(FState.ATAPosition, 2);
      if FState.ATAPosition = 512 then
      begin
        var Data: TBytes;
        SetLength(Data, 512);
        Move(FState.ATABuffer[0], Data[0], 512);
        if not FDisk.WriteSector(FState.ATALBA, Data) then
          ATAError(4)
        else
          ATANext;
      end;
    end;
  end;
end;

function TZXDivStorage.CRC16(const Data: TBytes): Word;
begin
  var C: Cardinal := 0;
  for var B in Data do
  begin
    C := C xor (Cardinal(B) shl 8);
    for var i := 0 to 7 do
      if (C and $8000) <> 0 then
        C := ((C shl 1) xor $1021) and $FFFF
      else
        C := (C shl 1) and $FFFF;
  end;
  Result := C;
end;

procedure TZXDivStorage.SDReply(const Bytes: array of Byte);
begin
  FState.SDResponsePosition := 0;
  FState.SDResponseCount := Length(Bytes);
  for var i := 0 to High(Bytes) do
    FState.SDResponse[i] := Bytes[i];
end;

procedure TZXDivStorage.SDData(const Data: TBytes);
begin
  var P := FState.SDResponseCount;
  FState.SDResponse[P] := $FF;
  FState.SDResponse[P + 1] := $FE;
  for var i := 0 to High(Data) do
    FState.SDResponse[P + 2 + i] := Data[i];
  var CRC := CRC16(Data);
  FState.SDResponse[P + 2 + Length(Data)] := CRC shr 8;
  FState.SDResponse[P + 3 + Length(Data)] := CRC and 255;
  Inc(FState.SDResponseCount, Length(Data) + 4);
end;

procedure TZXDivStorage.SDCommand;
begin
  var Cmd := FState.SDCommand[0] and 63;
  var Arg: Cardinal := (Cardinal(FState.SDCommand[1]) shl 24) or (Cardinal(FState.SDCommand[2]) shl 16) or
    (Cardinal(FState.SDCommand[3]) shl 8) or FState.SDCommand[4];
  var Idle := Byte(Ord(FState.SDIdle));
  var App := FState.SDApp;
  FState.SDApp := False;
  if FState.SDCRC or (Cmd in [0, 8]) then
  begin
    var CRC: Byte := 0;
    for var i := 0 to 4 do
      for var Bit := 7 downto 0 do
      begin
        var Feedback := ((CRC shr 6) xor (FState.SDCommand[i] shr Bit)) and 1;
        CRC := (CRC shl 1) and $7F;
        if Feedback <> 0 then
          CRC := CRC xor 9;
      end;
    if FState.SDCommand[5] <> ((CRC shl 1) or 1) then
    begin
      SDReply([Idle or 8]);
      Exit;
    end;
  end;
  case Cmd of
    0:
      begin
        FState.SDIdle := True;
        FState.SDHC := False;
        FState.SDCRC := False;
        FState.SDReadMultiple := False;
        FState.SDWriteMultiple := False;
        SDReply([1]);
      end;
    1:
      begin
        FState.SDIdle := False;
        SDReply([0]);
      end;
    8:
      SDReply([Idle, 0, 0, (Arg shr 8) and 255, Arg and 255]);
    55:
      begin
        FState.SDApp := True;
        SDReply([Idle]);
      end;
    41:
      if App then
      begin
        FState.SDIdle := False;
        FState.SDHC := ((Arg and $40000000) <> 0) and (FDisk.Sectors >= 4194304);
        SDReply([0]);
      end
      else
        SDReply([Idle or 4]);
    58:
      SDReply([Idle, $80 or (Ord(FState.SDHC) shl 6), $FF, $80, 0]);
    59:
      begin
        FState.SDCRC := (Arg and 1) <> 0;
        SDReply([Idle]);
      end;
    12:
      begin
        FState.SDReadMultiple := False;
        SDReply([$FF, 0]);
      end;
  else
    if FState.SDIdle then
    begin
      SDReply([1]);
      Exit;
    end;
    case Cmd of
      9, 10:
        begin
          var Data: TBytes;
          SetLength(Data, 16);
          if Cmd = 10 then
          begin
            Data[0] := 1;
            Data[1] := Ord('R');
            Data[2] := Ord('M');
            Data[3] := Ord('S');
            Data[4] := Ord('D');
            Data[5] := Ord('0');
            Data[6] := Ord('1');
          end
          else
          begin
            Data[1] := $0E;
            Data[2] := 0;
            Data[3] := $32;
            Data[4] := $5B;
            Data[5] := $59;
            if FState.SDHC then
            begin
              var Size := FDisk.Sectors div 1024 - 1;
              Data[0] := $40;
              Data[7] := (Size shr 16) and 63;
              Data[8] := (Size shr 8) and 255;
              Data[9] := Size and 255;
            end
            else
            begin
              var Mult := 0;
              while (FDisk.Sectors shr (Mult + 2)) > 4096 do
                Inc(Mult);
              var Size := Max(Cardinal(1), FDisk.Sectors shr (Mult + 2)) - 1;
              Data[6] := (Size shr 10) and 3;
              Data[7] := (Size shr 2) and 255;
              Data[8] := (Size and 3) shl 6;
              Data[9] := Mult shr 1;
              Data[10] := (Mult and 1) shl 7;
            end;
            Data[10] := Data[10] or $7F;
            Data[11] := $80;
            Data[12] := $0A;
            Data[13] := $40;
          end;
          Data[15] := 1;
          SDReply([0]);
          SDData(Data);
        end;
      13:
        SDReply([0, 0]);
      16:
        if Arg = 512 then
          SDReply([0])
        else
          SDReply([$40]);
      17, 18, 24, 25:
        begin
          if not FState.SDHC and ((Arg and 511) <> 0) then
          begin
            SDReply([$40]);
            Exit;
          end;
          var LBA := Arg;
          if not FState.SDHC then
            LBA := LBA div 512;
          if LBA >= FDisk.Sectors then
          begin
            SDReply([$20]);
            Exit;
          end;
          FState.SDLBA := LBA;
          if Cmd in [17, 18] then
          begin
            var Data: TBytes;
            FDisk.ReadSector(LBA, Data);
            SDReply([0]);
            SDData(Data);
            FState.SDReadMultiple := Cmd = 18;
            Inc(FState.SDLBA);
          end
          else
          begin
            SDReply([0]);
            FState.SDWriting := 1;
            FState.SDWriteMultiple := Cmd = 25;
          end;
        end;
      23:
        if App then
          SDReply([0])
        else
          SDReply([4]);
    else
      SDReply([4]);
    end;
  end;
end;

function TZXDivStorage.SPI(Value: Byte): Byte;
begin
  Result := $FF;
  if (FDisk = nil) or (FState.Select <> 2) then
    Exit;
  if FState.SDBusy <> 0 then
  begin
    Dec(FState.SDBusy);
    Exit(0);
  end;
  // CMD12 is received over MOSI while the multi-read data stream drives MISO.
  if FState.SDReadMultiple and ((FState.SDCount > 0) or ((Value and $C0) = $40)) then
  begin
    FState.SDCommand[FState.SDCount] := Value;
    Inc(FState.SDCount);
    if FState.SDCount = 6 then
    begin
      FState.SDCount := 0;
      SDCommand;
    end;
    Exit;
  end;
  if FState.SDResponsePosition < FState.SDResponseCount then
  begin
    Result := FState.SDResponse[FState.SDResponsePosition];
    Inc(FState.SDResponsePosition);
    Exit;
  end;
  if FState.SDWriting <> 0 then
  begin
    if FState.SDWriting = 1 then
    begin
      if FState.SDWriteMultiple and (Value = $FD) then
      begin
        FState.SDWriting := 0;
        FState.SDBusy := 1;
        Exit;
      end;
      if (Value = $FE) or (FState.SDWriteMultiple and (Value = $FC)) then
      begin
        FState.SDWriting := 2;
        FState.SDWritePosition := 0;
      end;
    end
    else
    begin
      FState.SDBuffer[FState.SDWritePosition] := Value;
      Inc(FState.SDWritePosition);
      if FState.SDWritePosition = 514 then
      begin
        var Data: TBytes;
        SetLength(Data, 512);
        Move(FState.SDBuffer[0], Data[0], 512);
        var Code: Byte := $05;
        if FState.SDCRC and (CRC16(Data) <> ((Word(FState.SDBuffer[512]) shl 8) or FState.SDBuffer[513])) then
          Code := $0B
        else if not FDisk.WriteSector(FState.SDLBA, Data) then
          Code := $0D;
        SDReply([Code, 0, $FF]);
        Inc(FState.SDLBA);
        if FState.SDWriteMultiple then
          FState.SDWriting := 1
        else
          FState.SDWriting := 0;
      end;
    end;
    Exit;
  end;
  if FState.SDCount = 0 then
  begin
    if (Value and $C0) = $40 then
    begin
      FState.SDCommand[0] := Value;
      FState.SDCount := 1;
    end
    else if FState.SDReadMultiple then
    begin
      var Data: TBytes;
      SDReply([]);
      if FDisk.ReadSector(FState.SDLBA, Data) then
        SDData(Data)
      else
        SDReply([8]);
      Inc(FState.SDLBA);
    end;
  end
  else
  begin
    FState.SDCommand[FState.SDCount] := Value;
    Inc(FState.SDCount);
    if FState.SDCount = 6 then
    begin
      FState.SDCount := 0;
      SDCommand;
    end;
  end;
end;

procedure TZXDivStorage.SerializeState(State: TStateArchive);
begin
  var Kind: Integer := Ord(FKind);
  var Banks := FBanks;
  State.Field(Kind, 4);
  State.Field(Banks, 4);
  if (Kind < 0) or (Kind > Ord(High(TZXDivType))) or not (Banks in [4, 16, 64]) or
    ((Kind = Ord(zdMMC)) and (Banks = 4)) or ((Kind <> Ord(zdMMC)) and (Banks <> 4)) then
    raise EReadError.Create('Invalid DivIDE/DivMMC hardware state');
  if State.Loading then
  begin
    FKind := TZXDivType(Kind);
    FBanks := Banks;
  end;
  State.Field(FROM, SizeOf(FROM));
  State.Field(FState, SizeOf(FState));
  var HasDisk := FDisk <> nil;
  State.Field(HasDisk, SizeOf(HasDisk));
  if State.Loading and (HasDisk <> (FDisk <> nil)) then
    raise EReadError.Create('CF/SD source image must be mounted before loading state');
  if HasDisk then
    FDisk.SerializeState(State);
  if State.Loading and ((FState.ATAPosition < 0) or (FState.ATAPosition > 512) or (FState.ATAPosition mod 2 <> 0) or
    ((FState.ATA[7] and 8 <> 0) and (FState.ATAPosition = 512)) or
    (FState.ATARemaining < 0) or (FState.ATARemaining > 256) or (FState.SDCount < 0) or (FState.SDCount > 5) or
    (FState.SDResponseCount < 0) or (FState.SDResponseCount > 520) or (FState.SDResponsePosition < 0) or
    (FState.SDResponsePosition > FState.SDResponseCount) or (FState.SDWriting > 2) or
    (FState.SDWritePosition < 0) or (FState.SDWritePosition > 514) or
    ((FState.SDWriting = 2) and (FState.SDWritePosition = 514))) then
    raise EReadError.Create('Invalid DivIDE/DivMMC transfer state');
end;

end.

