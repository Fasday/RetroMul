unit Saturn.SMPC;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots;

type
  TSaturnButton = (Up, Down, Left, Right, A, B, C, X, Y, Z, L, R, Start);

  TSaturnButtons = set of TSaturnButton;

  TSaturnPeripheral = record
    Kind: Byte; // 0 disconnected, 1 digital, 2 analog 3D pad
    Pad: Word;
    X, Y, RightTrigger, LeftTrigger: Byte;
  end;

  TSMPCCommand = procedure(Command: Byte) of object;

  TSMPCIRQ = procedure of object;

  TSaturnSMPC = class
  private
    FRegisters: array[0..127] of Byte;
    FRTC: array[0..6] of Byte;
    FMemory: array[0..3] of Byte;
    FPad: array[0..1] of Word;
    FConnected: array[0..1] of Boolean;
    FDevices: array[0..1, 0..5] of TSaturnPeripheral;
    FMultitap: array[0..1] of Boolean;
    FPacket: array[0..255] of Byte;
    FPacketLength, FPacketAt: Integer;
    FPacketReady: Boolean;
    FDirectAt: array[0..1] of Integer;
    FDirectData: array[0..1, 0..127] of Byte;
    FDirectLength: array[0..1] of Integer;
    FTime, FDeadline, FRTCPhase: Int64;
    FClock: Integer;
    FRegion: Byte;
    FResetDisabled, FClock352, FPeripheralPending, FSoundReleased, FCDReleased: Boolean;
    FCommand: TSMPCCommand;
    FIRQ: TSMPCIRQ;
    procedure BuildDirect(Port: Integer);
    procedure Complete;
    procedure PeripheralData;
    function PortRead(Port: Integer): Byte;
    procedure TickRTC;
  public
    constructor Create(Region: Byte; Command: TSMPCCommand; IRQ: TSMPCIRQ);
    procedure Reset;
    function Read(Address: Cardinal): Byte;
    procedure Write(Address: Cardinal; Value: Byte);
    procedure Advance(Target: Int64);
    procedure SetClock(Clock: Integer);
    procedure SetInput(Port: Integer; Buttons: TSaturnButtons; Connected: Boolean = True);
    procedure SetPeripheral(Port, Slot, Kind: Integer; Buttons: TSaturnButtons; X: Byte = 128; Y: Byte = 128; RightTrigger: Byte = 0; LeftTrigger: Byte = 0);
    procedure SetMultitap(Port: Integer; Enabled: Boolean);
    procedure SerializeState(Archive: TStateArchive);
    property Clock352: Boolean read FClock352;
  end;

implementation

uses
  System.DateUtils, System.Math;

function BCD(Value: Integer): Byte;
begin
  Result := (Value div 10) * 16 + Value mod 10;
end;

function Decimal(Value: Byte): Integer;
begin
  Result := (Value shr 4) * 10 + (Value and 15);
end;

constructor TSaturnSMPC.Create(Region: Byte; Command: TSMPCCommand; IRQ: TSMPCIRQ);
begin
  inherited Create;
  FRegion := Region;
  FCommand := Command;
  FIRQ := IRQ;
  FClock := 26846587;
  // Deterministic power-on calendar; battery-backed RTC survives system reset.
  FRTC[0] := $20;
  FRTC[1] := $26;
  FRTC[2] := $3A;
  FRTC[3] := $14;
  FRTC[4] := 0;
  FRTC[5] := 0;
  FRTC[6] := 0;
  Reset;
end;

procedure TSaturnSMPC.Reset;
begin
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FillChar(FMemory, SizeOf(FMemory), 0);
  FTime := 0;
  FDeadline := -1;
  FRTCPhase := 0;
  FResetDisabled := True;
  FClock352 := False;
  FPeripheralPending := False;
  FSoundReleased := False;
  FCDReleased := True;
  FPad[0] := $FFFF;
  FPad[1] := $FFFF;
  FConnected[0] := True;
  FConnected[1] := True;
  FillChar(FDevices, SizeOf(FDevices), 0);
  FillChar(FMultitap, SizeOf(FMultitap), 0);
  FillChar(FDirectAt, SizeOf(FDirectAt), 0);
  FPacketReady := False;
  FPacketAt := 0;
  FPacketLength := 0;
  FillChar(FPacket, SizeOf(FPacket), 0);
  FillChar(FDirectData, SizeOf(FDirectData), 0);
  FillChar(FDirectLength, SizeOf(FDirectLength), 0);
  FDirectAt[0] := -1;
  FDirectAt[1] := -1;
  SetPeripheral(0, 0, 1, []);
  SetPeripheral(1, 0, 1, []);
  FRegisters[$75] := $7F;
  FRegisters[$77] := $7F;
end;

procedure TSaturnSMPC.SetClock(Clock: Integer);
begin
  if Clock < 1000000 then
    raise EArgumentOutOfRangeException.Create('SMPC clock');
  if FClock > 0 then
    FRTCPhase := FRTCPhase * Clock div FClock;
  FClock := Clock;
end;

procedure TSaturnSMPC.SetInput(Port: Integer; Buttons: TSaturnButtons; Connected: Boolean);
begin
  SetPeripheral(Port, 0, Ord(Connected), Buttons);
end;

procedure TSaturnSMPC.SetMultitap(Port: Integer; Enabled: Boolean);
begin
  if not (Port in [0, 1]) then
    raise EArgumentOutOfRangeException.Create('Saturn multitap port');
  FMultitap[Port] := Enabled;
end;

procedure TSaturnSMPC.SetPeripheral(Port, Slot, Kind: Integer; Buttons: TSaturnButtons; X, Y, RightTrigger, LeftTrigger: Byte);
const
  Bits: array[TSaturnButton] of Byte = (4, 5, 6, 7, 2, 0, 1, 14, 13, 12, 11, 15, 3);
begin
  if not (Port in [0, 1]) or not (Slot in [0..5]) or not (Kind in [0..2]) then
    raise EArgumentOutOfRangeException.Create('Saturn peripheral');
  var Device := Default(TSaturnPeripheral);
  Device.Kind := Kind;
  Device.Pad := $FFFF;
  Device.X := X;
  Device.Y := Y;
  Device.RightTrigger := RightTrigger;
  Device.LeftTrigger := LeftTrigger;
  for var B := Low(TSaturnButton) to High(TSaturnButton) do
    if B in Buttons then
      Device.Pad := Device.Pad and not (Word(1) shl Bits[B]);
  if Kind = 2 then
  begin
    if X < 56 then
      Device.Pad := Device.Pad and not $40;
    if X > 200 then
      Device.Pad := Device.Pad and not $80;
    if Y < 56 then
      Device.Pad := Device.Pad and not $10;
    if Y > 200 then
      Device.Pad := Device.Pad and not $20;
    if RightTrigger >= 128 then
      Device.Pad := Device.Pad and not $8000;
    if LeftTrigger >= 128 then
      Device.Pad := Device.Pad and not $800;
  end;
  FDevices[Port, Slot] := Device;
  if Slot = 0 then
  begin
    FConnected[Port] := Kind <> 0;
    FPad[Port] := Device.Pad;
  end;
end;

function TSaturnSMPC.PortRead(Port: Integer): Byte;
begin
  var A: Integer := $75 + Port * 2;
  var Select: Integer := (FRegisters[A] shr 5) and 3;
  if FMultitap[Port] or (FDevices[Port, 0].Kind = 2) then
  begin
    var Data: Byte := 1;
    if (FRegisters[A] and $40 = 0) and (FDirectAt[Port] >= 0) then
    begin
      var Index := FDirectAt[Port] div 2;
      Data := $F;
      if Index < FDirectLength[Port] then
      begin
        Data := FDirectData[Port, Index];
        if not Odd(FDirectAt[Port]) then
          Data := Data shr 4
        else
          Data := Data and 15;
      end;
    end;
    Result := (FRegisters[A] and $60) or ((FRegisters[A] and $20) shr 1) or Data;
    var DDR := FRegisters[$79 + Port * 2];
    Result := (Result and not DDR) or (FRegisters[A] and DDR);
    Exit;
  end;
  var Data: Byte := $0F;
  if FConnected[Port] then
    case Select of
      0:
        Data := (FPad[Port] shr 12) and $F; // R/X/Y/Z
        1:
        Data := (FPad[Port] shr 4) and $F;  // Right/Left/Down/Up
        2:
        Data := FPad[Port] and $F;           // Start/A/C/B
        3:
        Data := 4 or (((FPad[Port] shr 11) and 1) shl 3); // L/1/0/0 ID phase
    end;
  Result := (FRegisters[A] and $60) or $10 or Data;
  var DDR := FRegisters[$79 + Port * 2];
  Result := (Result and not DDR) or (FRegisters[A] and DDR);
end;

procedure TSaturnSMPC.BuildDirect(Port: Integer);

  procedure Emit(Value: Byte);
  begin
    FDirectData[Port, FDirectLength[Port]] := Value;
    Inc(FDirectLength[Port]);
  end;

  procedure Pad(const Device: TSaturnPeripheral);
  begin
    if Device.Kind = 0 then
    begin
      Emit($FF);
      Exit;
    end;
    if Device.Kind = 2 then
      Emit($16)
    else
      Emit($02);
    Emit(Device.Pad and $FF);
    Emit(Device.Pad shr 8);
    if Device.Kind = 2 then
    begin
      Emit(Device.X);
      Emit(Device.Y);
      Emit(Device.RightTrigger);
      Emit(Device.LeftTrigger);
    end;
  end;

begin
  FDirectLength[Port] := 0;
  FDirectAt[Port] := -1;
  if FMultitap[Port] then
  begin
    Emit($41);
    Emit($60);
    for var Slot := 0 to 5 do
      Pad(FDevices[Port, Slot]);
  end
  else
    Pad(FDevices[Port, 0]);
end;

function TSaturnSMPC.Read(Address: Cardinal): Byte;
begin
  var A: Integer := Address and $7F;
  if not Odd(A) then
    Exit($FF);
  if (A = $75) or (A = $77) then
    Exit(PortRead((A - $75) div 2));
  Result := FRegisters[A];
end;

procedure TSaturnSMPC.PeripheralData;

  procedure Emit(Value: Byte);
  begin
    FPacket[FPacketLength] := Value;
    Inc(FPacketLength);
  end;

  procedure Device(const D: TSaturnPeripheral);
  begin
    if D.Kind = 0 then
    begin
      Emit($F0);
      Exit;
    end;
    if D.Kind = 2 then
      Emit($16)
    else
      Emit($02);
    Emit(D.Pad and $FF);
    Emit(D.Pad shr 8);
    if D.Kind = 2 then
    begin
      Emit(D.X);
      Emit(D.Y);
      Emit(D.RightTrigger);
      Emit(D.LeftTrigger);
    end;
  end;

begin
  if not FPacketReady then
  begin
    FPacketLength := 0;
    FPacketAt := 0;
    for var Port := 0 to 1 do
    begin
      var Mode: Integer := (FRegisters[$03] shr (4 + Port * 2)) and 3;
      var First := FPacketLength;
      if Mode = 3 then
      begin
        Emit($F0);
        Continue;
      end;
      if FMultitap[Port] then
      begin
        Emit($16);
        for var Slot := 0 to 5 do
          Device(FDevices[Port, Slot]);
      end
      else if not FConnected[Port] then
        Emit($F0)
      else
      begin
        Emit($F1);
        Device(FDevices[Port, 0]);
      end;
      if (Mode = 0) and (FPacketLength - First > 15) then
        FPacketLength := First + 15;
    end;
    FPacketReady := True;
  end;
  var First: Boolean := FPacketAt = 0;
  for var I := 0 to 31 do
  begin
    FRegisters[$21 + I * 2] := $FF;
    if FPacketAt < FPacketLength then
    begin
      FRegisters[$21 + I * 2] := FPacket[FPacketAt];
      Inc(FPacketAt);
    end;
  end;
  FPeripheralPending := FPacketAt < FPacketLength;
  FRegisters[$61] := $80 or (FRegisters[$03] shr 4);
  if First then
    FRegisters[$61] := FRegisters[$61] or $40;
  if FPeripheralPending then
    FRegisters[$61] := FRegisters[$61] or $20;
  FRegisters[$63] := 0;
  if Assigned(FIRQ) then
    FIRQ;
end;

procedure TSaturnSMPC.Complete;
begin
  var Cmd := FRegisters[$1F];
  FDeadline := -1;
  FRegisters[$63] := 0;
  FRegisters[$5F] := Cmd;
  case Cmd of
    $06:
      FSoundReleased := True;
    $07:
      FSoundReleased := False;
    $08:
      FCDReleased := True;
    $09:
      FCDReleased := False;
    $0E:
      begin
        FClock352 := True;
        FSoundReleased := False;
      end;
    $0F:
      begin
        FClock352 := False;
        FSoundReleased := False;
      end;
    $19:
      FResetDisabled := False;
    $1A:
      FResetDisabled := True;
    $16:
      begin
        for var I := 0 to 6 do
          FRTC[I] := FRegisters[1 + I * 2];
        FRTCPhase := 0;
      end;
    $17:
      for var I := 0 to 3 do
        FMemory[I] := FRegisters[1 + I * 2];
    $10:
      begin
        if FRegisters[$01] <> 0 then
          FPacketReady := False;
        FPeripheralPending := (FRegisters[$03] and 8 <> 0) or FPacketReady;
        if FRegisters[$01] and 1 <> 0 then
        begin
          FRegisters[$21] := $80 or (Byte(Ord(FResetDisabled)) shl 6);
          for var I := 0 to 6 do
            FRegisters[$23 + I * 2] := FRTC[I];
          FRegisters[$31] := 0;
          FRegisters[$33] := FRegion;
          FRegisters[$35] := $36 or Byte(Ord(FSoundReleased)) or (Byte(Ord(FClock352)) shl 6);
          FRegisters[$37] := Byte(Ord(FCDReleased)) shl 6;
          for var I := 0 to 3 do
            FRegisters[$39 + I * 2] := FMemory[I];
          FRegisters[$61] := $4F;
          if FPeripheralPending then
            FRegisters[$61] := FRegisters[$61] or $20;
          if Assigned(FIRQ) then
            FIRQ;
        end
        else if FPeripheralPending then
          PeripheralData;
      end;
  end;
  if Assigned(FCommand) then
    FCommand(Cmd);
end;

procedure TSaturnSMPC.Write(Address: Cardinal; Value: Byte);
begin
  var A: Integer := Address and $7F;
  if not Odd(A) then
    Exit;
  if A = $01 then
  begin
    FRegisters[A] := Value;
    if FPeripheralPending and (Value and $40 <> 0) then
    begin
      FPeripheralPending := False;
      FPacketReady := False;
      FRegisters[$61] := 0;
    end
    else if FPeripheralPending and (Value and $80 <> 0) then
    begin
      FRegisters[$63] := 1;
      FDeadline := FTime + Max(1, FClock div 1000);
      FRegisters[$1F] := $10;
      FRegisters[$01] := 0;
    end;
    Exit;
  end;
  if (A >= $21) and (A <= $61) then
    Exit;
  if (A = $75) or (A = $77) then
  begin
    var Port: Integer := (A - $75) div 2;
    if Value and $40 <> 0 then
      FDirectAt[Port] := -1
    else if FRegisters[A] and $40 <> 0 then
      BuildDirect(Port)
    else if ((Value xor FRegisters[A]) and $20 <> 0) and (FDirectAt[Port] < FDirectLength[Port] * 2) then
      Inc(FDirectAt[Port]);
  end;
  if A = $1F then
  begin
    if FDeadline >= 0 then
      Exit;
    FRegisters[A] := Value;
    FRegisters[$63] := 1;
    if Value = $10 then
    begin
      FPacketReady := False;
      FPacketAt := 0;
    end;
    var Micro: Integer := 30;
    case Value of
      $08, $09, $17:
        Micro := 40;
      $16:
        Micro := 70;
      $10:
        Micro := 1000;
      $0D, $0E, $0F:
        Micro := 100000;
    end;
    FDeadline := FTime + Int64(FClock) * Micro div 1000000;
    Exit;
  end;
  FRegisters[A] := Value;
end;

procedure TSaturnSMPC.TickRTC;
begin
  try
    var Date := EncodeDate(Decimal(FRTC[0]) * 100 + Decimal(FRTC[1]), FRTC[2] and $F, Decimal(FRTC[3])) + EncodeTime(Decimal(FRTC[4]), Decimal(FRTC[5]), Decimal(FRTC[6]), 0);
    Date := IncSecond(Date, 1);
    var Y, M, D, H, N, S, MS: Word;
    DecodeDate(Date, Y, M, D);
    DecodeTime(Date, H, N, S, MS);
    FRTC[0] := BCD(Y div 100);
    FRTC[1] := BCD(Y mod 100);
    FRTC[2] := ((DayOfWeek(Date) - 1) shl 4) or M;
    FRTC[3] := BCD(D);
    FRTC[4] := BCD(H);
    FRTC[5] := BCD(N);
    FRTC[6] := BCD(S);
  except
    on E: EConvertError do
      ;
  end;
end;

procedure TSaturnSMPC.Advance(Target: Int64);
begin
  if Target < FTime then
    raise EArgumentException.Create('SMPC time');
  Inc(FRTCPhase, Target - FTime);
  FTime := Target;
  while FRTCPhase >= FClock do
  begin
    Dec(FRTCPhase, FClock);
    TickRTC;
  end;
  if (FDeadline >= 0) and (Target >= FDeadline) then
    Complete;
end;

procedure TSaturnSMPC.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(FRegisters, SizeOf(FRegisters));
  Archive.Field(FRTC, SizeOf(FRTC));
  Archive.Field(FMemory, SizeOf(FMemory));
  Archive.Field(FPad, SizeOf(FPad));
  Archive.Field(FConnected, SizeOf(FConnected));
  Archive.Field(FTime, SizeOf(FTime));
  Archive.Field(FDevices, SizeOf(FDevices));
  Archive.Field(FMultitap, SizeOf(FMultitap));
  Archive.Field(FDirectAt, SizeOf(FDirectAt));
  Archive.Field(FDirectData, SizeOf(FDirectData));
  Archive.Field(FDirectLength, SizeOf(FDirectLength));
  Archive.Field(FPacket, SizeOf(FPacket));
  Archive.Field(FPacketLength, SizeOf(FPacketLength));
  Archive.Field(FPacketAt, SizeOf(FPacketAt));
  Archive.Field(FPacketReady, SizeOf(FPacketReady));
  Archive.Field(FDeadline, SizeOf(FDeadline));
  Archive.Field(FRTCPhase, SizeOf(FRTCPhase));
  Archive.Field(FClock, SizeOf(FClock));
  Archive.Field(FSoundReleased, SizeOf(FSoundReleased));
  Archive.Field(FCDReleased, SizeOf(FCDReleased));
  Archive.Field(FRegion, SizeOf(FRegion));
  Archive.Field(FResetDisabled, SizeOf(FResetDisabled));
  Archive.Field(FClock352, SizeOf(FClock352));
  Archive.Field(FPeripheralPending, SizeOf(FPeripheralPending));
  if (FClock < 20000000) or (FClock > 30000000) or (FTime < 0) or (FDeadline < -1) or (FRTCPhase < 0) or (FRTCPhase >= FClock) then
    raise EReadError.Create('Invalid SMPC timing state');
  if (FPacketLength < 0) or (FPacketLength > 256) or (FPacketAt < 0) or (FPacketAt > FPacketLength) then
    raise EReadError.Create('Invalid SMPC peripheral packet');
  for var Port := 0 to 1 do
  begin
    if (FDirectLength[Port] < 0) or (FDirectLength[Port] > 128) or (FDirectAt[Port] < -1) or (FDirectAt[Port] > FDirectLength[Port] * 2) then
      raise EReadError.Create('Invalid SMPC direct peripheral packet');
    for var Slot := 0 to 5 do
      if FDevices[Port, Slot].Kind > 2 then
        raise EReadError.Create('Invalid SMPC peripheral type');
  end;
end;

end.

