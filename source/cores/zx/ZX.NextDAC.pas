unit ZX.NextDAC;

interface

uses
  Core.Snapshots;

type
  // Audio-only component of the Next FPGA 3.02.03. Does not identify the
  // motherboard as a Next or implement the rest of its NextReg bank.
  TZXNextDAC = class
  private
    FChannels: array[0..3] of Byte; // A/B left, C/D right
    FSelect, FPorts: Byte;
    FEnabled: Boolean;
    procedure Silence;
  public
    constructor Create;
    procedure Reset;
    procedure ConfigureStartup(Enabled: Boolean; Ports: Byte);
    function WritePort(Address: Word; Value: Byte): Boolean;
    function ReadPort(Address: Word; out Value: Byte): Boolean;
    procedure WriteRegister(Index, Value: Byte);
    function ReadRegister(Index: Byte; out Value: Byte): Boolean;
    procedure Levels(out Left, Right: Double);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.SysUtils, System.Classes;

constructor TZXNextDAC.Create;
begin
  inherited;
  Reset;
end;

procedure TZXNextDAC.Silence;
begin
  FillChar(FChannels, SizeOf(FChannels), $80);
end;

procedure TZXNextDAC.Reset;
begin
  Silence;
  FSelect := $24; // protected unused index at reset, as in the FPGA
  FPorts := $FE; // own DAC enables only; AY bit 0 belongs to the motherboard
  FEnabled := False;
end;

procedure TZXNextDAC.ConfigureStartup(Enabled: Boolean; Ports: Byte);
begin
  // Host compatibility preference, applied only when opening/resetting media.
  // A physical Next powers up disabled until firmware enables NR08 bit 3.
  Silence;
  FPorts := Ports and $FE;
  FEnabled := Enabled;
end;

procedure TZXNextDAC.WriteRegister(Index, Value: Byte);
begin
  case Index of
    $08:
      begin
        FEnabled := (Value and 8) <> 0;
        if not FEnabled then
          Silence;
      end;
    $84:
      FPorts := Value and $FE;
    $2C:
      if FEnabled then
        FChannels[1] := Value;
    $2D:
      if FEnabled then
      begin
        FChannels[0] := Value;
        FChannels[3] := Value;
      end;
    $2E:
      if FEnabled then
        FChannels[2] := Value;
  end;
end;

function TZXNextDAC.ReadRegister(Index: Byte; out Value: Byte): Boolean;
begin
  Result := True;
  case Index of
    $08:
      Value := Ord(FEnabled) * 8;
    $84:
      Value := FPorts;
    // These are Pi I2S sample reads, not DAC latch readbacks. No external
    // Pi/I2S source is connected, so both the MSBs and latched LSBs are zero.
      $2C..$2E:
      Value := 0;
  else
    Value := $FF;
    Result := False;
  end;
end;

function TZXNextDAC.WritePort(Address: Word; Value: Byte): Boolean;
var
  Mask: Byte;
begin
  Result := True;
  case Address of
    $243B:
      begin
        FSelect := Value;
        Exit;
      end;
    $253B:
      begin
        WriteRegister(FSelect, Value);
        Exit;
      end;
  end;
  Mask := 0;
  // Port aliases are decoded by the low byte only. Gates can overlap.
  case Address and $FF of
    $1F:
      if (FPorts and 2) <> 0 then
        Mask := 1;
    $0F:
      if (FPorts and $12) <> 0 then
        Mask := 2;
    $4F:
      if (FPorts and $12) <> 0 then
        Mask := 4;
    $5F:
      if (FPorts and $0A) <> 0 then
        Mask := 8;
    $F1:
      if (FPorts and 4) <> 0 then
        Mask := 1;
    $F3:
      if (FPorts and 4) <> 0 then
        Mask := 2;
    $F9:
      if (FPorts and 4) <> 0 then
        Mask := 4;
    $3F:
      if (FPorts and 8) <> 0 then
        Mask := 1;
    $DF:
      if (FPorts and $80) <> 0 then
        Mask := 9;
    $B3:
      if (FPorts and $40) <> 0 then
        Mask := 6;
    $FB:
      // Soundrive 2 takes precedence over the Pentagon mono A+D alias.
      if (FPorts and 4) <> 0 then
        Mask := 8
      else if (FPorts and $20) <> 0 then
        Mask := 9;
  end;
  Result := Mask <> 0;
  if FEnabled then
    for var C := 0 to 3 do
      if (Mask and (1 shl C)) <> 0 then
        FChannels[C] := Value;
end;

function TZXNextDAC.ReadPort(Address: Word; out Value: Byte): Boolean;
begin
  Value := $FF;
  case Address of
    $243B:
      begin
        Value := FSelect;
        Exit(True);
      end;
    $253B:
      Exit(ReadRegister(FSelect, Value));
  end;
  Result := False; // classic DAC ports are write-only
end;

procedure TZXNextDAC.Levels(out Left, Right: Double);
begin
  // The FPGA sums each pair as 9 unsigned bits. Remove the $100 bias,
  // normalize and use the same nominal expansion gain as existing DACs.
  Left := (Integer(FChannels[0]) + FChannels[1] - 256) / 256.0 * 0.25;
  Right := (Integer(FChannels[2]) + FChannels[3] - 256) / 256.0 * 0.25;
end;

procedure TZXNextDAC.SerializeState(State: TStateArchive);
begin
  State.Field(FChannels, SizeOf(FChannels));
  State.Field(FSelect, SizeOf(FSelect));
  State.Field(FPorts, SizeOf(FPorts));
  State.Field(FEnabled, SizeOf(FEnabled));
  if (FPorts and 1) <> 0 then
    raise EReadError.Create('Invalid Next-DAC port gates');
  if not FEnabled then
    for var C := 0 to 3 do
      if FChannels[C] <> $80 then
        raise EReadError.Create('Invalid disabled Next-DAC state');
end;

end.

