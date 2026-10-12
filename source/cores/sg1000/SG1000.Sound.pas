unit SG1000.Sound;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots;

type
  // TI SN76489A, clocked directly by Z80 T states (not by host audio playback).
  TSGSound = class
  private
    FPeriod: array[0..2] of Integer;
    FCounter: array[0..3] of Integer;
    FOutput: array[0..3] of Boolean;
    FVolume: array[0..3] of Integer;
    FLatch, FNoise, FLFSR, FDivider: Integer;
    procedure Clock;
    function TonePeriod(Channel: Integer): Integer;
  public
    constructor Create;
    procedure Reset;
    procedure Write(Value: Byte);
    procedure Advance(Cycles: Integer);
    function Sample: SmallInt;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

constructor TSGSound.Create;
begin
  inherited;
  Reset;
end;

procedure TSGSound.Reset;
begin
  FillChar(FPeriod, SizeOf(FPeriod), 0);
  FillChar(FCounter, SizeOf(FCounter), 0);
  FillChar(FOutput, SizeOf(FOutput), 0);
  FillChar(FVolume, SizeOf(FVolume), 0);
  FLatch := 0;
  FNoise := 0;
  FLFSR := $10000;
  FDivider := 0;
end;

function TSGSound.TonePeriod(Channel: Integer): Integer;
begin
  Result := FPeriod[Channel];
  if Result = 0 then
    Result := $400;
end;

procedure TSGSound.Write(Value: Byte);
begin
  if Value and $80 <> 0 then
    FLatch := (Value shr 4) and 7;
  var Channel := FLatch div 2;
  if FLatch and 1 <> 0 then
    FVolume[Channel] := Value and 15
  else if Channel < 3 then
  begin
    if Value and $80 <> 0 then
      FPeriod[Channel] := (FPeriod[Channel] and $3F0) or (Value and 15)
    else
      FPeriod[Channel] := (FPeriod[Channel] and 15) or ((Value and 63) shl 4);
  end
  else
  begin
    FNoise := Value and 7;
    FLFSR := $10000;
    FOutput[3] := False;
  end;
end;

procedure TSGSound.Clock;
begin
  for var Channel := 0 to 2 do
  begin
    Dec(FCounter[Channel]);
    if FCounter[Channel] <= 0 then
    begin
      FCounter[Channel] := TonePeriod(Channel);
      FOutput[Channel] := not FOutput[Channel];
    end;
  end;
  Dec(FCounter[3]);
  if FCounter[3] <= 0 then
  begin
    if FNoise and 3 = 3 then
      FCounter[3] := TonePeriod(2) * 2
    else
      FCounter[3] := 32 shl (FNoise and 3);
    var Feedback := FLFSR and 1;
    if FNoise and 4 <> 0 then
      Feedback := ((FLFSR shr 2) xor (FLFSR shr 3)) and 1;
    FLFSR := (FLFSR shr 1) or (Feedback shl 16);
    FOutput[3] := FLFSR and 1 <> 0;
  end;
end;

procedure TSGSound.Advance(Cycles: Integer);
begin
  if (Cycles < 0) or (Cycles > 65535) then
    raise EArgumentOutOfRangeException.Create('Invalid PSG clock count');

  Inc(FDivider, Cycles);

  // TI counts at clock / 16; every tone edge occurs after Period ticks.
  while FDivider >= 16 do
  begin
    Dec(FDivider, 16);
    Clock;
  end;
end;

function TSGSound.Sample: SmallInt;
const
  Amplitudes: array[0..15] of Integer =
    (4096, 3254, 2584, 2053, 1631, 1295, 1029, 817,
    649, 516, 410, 326, 259, 206, 164, 0);
begin
  var Value := 0;
  for var Channel := 0 to 3 do
    if FOutput[Channel] then
      Inc(Value, Amplitudes[FVolume[Channel]])
    else
      Dec(Value, Amplitudes[FVolume[Channel]]);
  Result := SmallInt(Value);
end;

procedure TSGSound.SerializeState(State: TStateArchive);
begin
  State.Field(FPeriod, SizeOf(FPeriod));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FOutput, SizeOf(FOutput));
  State.Field(FVolume, SizeOf(FVolume));
  State.Field(FLatch, SizeOf(FLatch));
  State.Field(FNoise, SizeOf(FNoise));
  State.Field(FLFSR, SizeOf(FLFSR));
  State.Field(FDivider, SizeOf(FDivider));

  if State.Loading then
  begin
    if (FLatch < 0) or (FLatch > 7) or (FNoise < 0) or (FNoise > 7) or
      (FLFSR < 0) or (FLFSR > $1FFFF) or (FDivider < 0) or (FDivider > 15) then
      raise EReadError.Create('Invalid PSG snapshot');

    for var Channel := 0 to 3 do
    begin
      if (FVolume[Channel] < 0) or (FVolume[Channel] > 15) or
        (FCounter[Channel] < 0) or (FCounter[Channel] > 2048) then
        raise EReadError.Create('Invalid PSG channel snapshot');

      if (Channel < 3) and ((FPeriod[Channel] < 0) or (FPeriod[Channel] > 1023)) then
        raise EReadError.Create('Invalid PSG tone snapshot');
    end;
  end;
end;

end.

