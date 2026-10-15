unit NGP.Sound;

interface

uses
  Core.Snapshots;

type
  // T6W28: shared tone/noise generators with independent stereo attenuation.
  TNGPSound = class
  private
    FRegisters: array[0..15] of Word;
    FLatch: array[0..1] of Byte;
    FCounter: array[0..3] of Integer;
    FOutput: array[0..3] of Boolean;
    FNoise: Word;
    FDivider: Integer;
    procedure Tick;
  public
    Enabled: Boolean;
    DACLeft, DACRight: Byte;
    procedure Reset;
    procedure Write(Port: Integer; Value: Byte);
    procedure Advance(Cycles: Integer);
    procedure Sample(out Left, Right: SmallInt);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

procedure TNGPSound.Reset;
begin
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  for var i := 0 to 7 do
    FRegisters[i * 2 + 1] := 15;
  FillChar(FLatch, SizeOf(FLatch), 0);
  FillChar(FCounter, SizeOf(FCounter), 0);
  FillChar(FOutput, SizeOf(FOutput), 0);
  FNoise := $8000;
  FDivider := 0;
  Enabled := False;
  DACLeft := $80;
  DACRight := $80;
end;

procedure TNGPSound.Write(Port: Integer; Value: Byte);
begin
  Port := Port and 1;
  if Value and $80 <> 0 then
    FLatch[Port] := (Value shr 4) and 7;
  var R := Port * 8 + FLatch[Port];
  if Odd(R) or (R and 7 = 6) then
    FRegisters[R] := Value and 15
  else if Value and $80 <> 0 then
    FRegisters[R] := (FRegisters[R] and $3F0) or (Value and 15)
  else
    FRegisters[R] := (FRegisters[R] and 15) or ((Value and $3F) shl 4);
  if (R and 7 = 6) and (Port = 0) then
    FNoise := $8000;
end;

procedure TNGPSound.Tick;
begin
  for var C := 0 to 2 do
  begin
    Dec(FCounter[C]);
    if FCounter[C] <= 0 then
    begin
      FCounter[C] := FRegisters[8 + C * 2];
      if FCounter[C] = 0 then
        FCounter[C] := 1;
      FOutput[C] := not FOutput[C];
    end;
  end;
  Dec(FCounter[3]);
  if FCounter[3] <= 0 then
  begin
    var N := FRegisters[6];
    if N and 3 = 3 then
      FCounter[3] := Integer(FRegisters[4]) * 2
    else
      FCounter[3] := 32 shl (N and 3);
    if FCounter[3] = 0 then
      FCounter[3] := 2;
    var Feedback: Integer;
    if N and 4 <> 0 then
      Feedback := ((FNoise shr 1) xor (FNoise shr 2)) and 1
    else
      Feedback := FNoise and 1;
    FNoise := (FNoise shr 1) or (Feedback shl 15);
    FOutput[3] := FNoise and 1 <> 0;
  end;
end;

procedure TNGPSound.Advance(Cycles: Integer);
begin
  Inc(FDivider, Cycles);
  while FDivider >= 32 do
  begin
    Dec(FDivider, 32);
    Tick;
  end;
end;

procedure TNGPSound.Sample(out Left, Right: SmallInt);
const
  Gain: array[0..15] of Integer = (4096, 3254, 2585, 2053, 1631, 1295, 1029, 817, 649, 516, 410, 325, 258, 205, 163, 0);
begin
  var L := (Integer(DACLeft) - 128) * 32;
  var R := (Integer(DACRight) - 128) * 32;
  if Enabled then
    for var C := 0 to 3 do
    begin
      var Sign: Integer;
      if FOutput[C] then
        Sign := 1
      else
        Sign := -1;
      Inc(L, Sign * Gain[FRegisters[9 + C * 2] and 15]);
      Inc(R, Sign * Gain[FRegisters[1 + C * 2] and 15]);
    end;
  Left := L;
  Right := R;
end;

procedure TNGPSound.SerializeState(State: TStateArchive);
begin
  State.Field(FRegisters, SizeOf(FRegisters));
  State.Field(FLatch, SizeOf(FLatch));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FOutput, SizeOf(FOutput));
  State.Field(FNoise, SizeOf(FNoise));
  State.Field(FDivider, SizeOf(FDivider));
  State.Field(Enabled, SizeOf(Enabled));
  State.Field(DACLeft, 1);
  State.Field(DACRight, 1);
end;

end.

