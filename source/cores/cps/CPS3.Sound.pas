unit CPS3.Sound;

// PCM register layout and key-on semantics
interface

uses
  System.SysUtils, System.Classes, Core.Snapshots;

type
  TCPS3Voice = record
    Regs: array[0..7] of Cardinal;
    Position, Fraction: Cardinal;
  end;

  TCPS3Sound = class
  private
    FROM: TBytes;
    FVoices: array[0..15] of TCPS3Voice;
    FKeys: Word;
    FNativePhase, FOutputPhase, FTime: Int64;
    FLeft, FRight: Integer;
    FCount: Integer;
    procedure Tick;
  public
    Samples: TArray<SmallInt>;
    constructor Create(const ROM: TBytes);
    procedure Reset;
    procedure BeginFrame;
    procedure AdvanceTo(Time: Int64);
    function Read(Offset: Cardinal): Cardinal;
    procedure Write(Offset, Value, Mask: Cardinal);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Math;

constructor TCPS3Sound.Create(const ROM: TBytes);
begin
  inherited Create;
  FROM := ROM;
  Reset;
end;

procedure TCPS3Sound.Reset;
begin
  FillChar(FVoices, SizeOf(FVoices), 0);
  FKeys := 0;
  FTime := 0;
  FNativePhase := 0;
  FOutputPhase := 0;
  FLeft := 0;
  FRight := 0;
  BeginFrame;
end;

procedure TCPS3Sound.BeginFrame;
begin
  FCount := 0;
  SetLength(Samples, 0);
end;

procedure TCPS3Sound.Tick;
begin
  FLeft := 0;
  FRight := 0;
  for var i := 0 to 15 do
    if FKeys and (1 shl i) <> 0 then
    begin
      var V: ^TCPS3Voice;
      V := @FVoices[i];
      var Start := (V.Regs[1] shr 16) or (V.Regs[1] shl 16);
      var Ending := (V.Regs[5] shr 16) or (V.Regs[5] shl 16);
      var LoopAt := (V.Regs[3] and $FFFF) or (V.Regs[4] shl 16);

      // Address bits 22..0 identify the sample; subtracting the $400000
      // base must precede bounds checks (invalid voices produce silence).
      var At := Int64(Start) - $400000 + V.Position + (V.Fraction shr 12);
      V.Position := Cardinal((UInt64(V.Position) + (V.Fraction shr 12)) and $FFFFFFFF);
      V.Fraction := V.Fraction and $FFF;
      if At >= Int64(Ending) - $400000 then
      begin
        if V.Regs[2] and 1 = 0 then
          Continue;

        At := At + Int64(LoopAt) - Ending;
        V.Position := Cardinal((Int64(V.Position) + LoopAt - Ending) and $FFFFFFFF);
      end;
      if (At < 0) or (At >= Length(FROM)) then
        Continue;

      // PCM exchanges the halfwords relative to character DMA. The ROM
      // array stores flash bus order (chip0 even, chip1 even, chip0 odd,
      // chip1 odd); the PCM address order starts with the odd pair.
      var Sample := Integer(FROM[At xor 2]);
      if Sample >= 128 then
        Dec(Sample, 256);
      var VL := Integer(V.Regs[7] and $7FFF) - Integer(V.Regs[7] and $8000);
      var VR := Integer((V.Regs[7] shr 16) and $7FFF) - Integer((V.Regs[7] shr 16) and $8000);
      Inc(FLeft, Sample * VL div 256);
      Inc(FRight, Sample * VR div 256);
      Inc(V.Fraction, V.Regs[3] shr 16);
    end;
end;

procedure TCPS3Sound.AdvanceTo(Time: Int64);
begin
  if Time < FTime then
    raise EInvalidOpException.Create('CPS3 audio clock reversed');

  // SH-2 25 MHz, PCM 42.954545 MHz / 3 / 384. Keep both rational
  // clocks across frames, rather than rounding samples per video frame.
  while FTime < Time do
  begin
    var Delta := Min(Time - FTime, Min((Int64(25000000) * 1152 - FNativePhase + 42954544) div 42954545,
        (25000000 - FOutputPhase + 44099) div 44100));
    Inc(FTime, Delta);
    Inc(FNativePhase, Delta * 42954545);
    Inc(FOutputPhase, Delta * 44100);
    if FNativePhase >= Int64(25000000) * 1152 then
    begin
      Dec(FNativePhase, Int64(25000000) * 1152);
      Tick;
    end;
    if FOutputPhase >= 25000000 then
    begin
      Dec(FOutputPhase, 25000000);
      if Length(Samples) < FCount + 2 then
        SetLength(Samples, FCount + 2048);
      Samples[FCount] := EnsureRange(FLeft, -32768, 32767);
      Samples[FCount + 1] := EnsureRange(FRight, -32768, 32767);
      Inc(FCount, 2);
    end;
  end;
  SetLength(Samples, FCount);
end;

function TCPS3Sound.Read(Offset: Cardinal): Cardinal;
begin
  if Offset < $200 then
    Exit(FVoices[Offset div 32].Regs[(Offset div 4) and 7]);

  if Offset = $200 then
    Exit(Cardinal(FKeys) shl 16);

  Result := 0;
end;

procedure TCPS3Sound.Write(Offset, Value, Mask: Cardinal);
begin
  if Offset < $200 then
  begin
    var R: PCardinal;
    R := @FVoices[Offset div 32].Regs[(Offset div 4) and 7];
    R^ := (R^ and not Mask) or (Value and Mask);
  end
  else if (Offset = $200) and (Mask and $FFFF0000 <> 0) then
  begin
    var Keys := Word(((Cardinal(FKeys) shl 16 and not Mask) or (Value and Mask)) shr 16);
    for var i := 0 to 15 do
      if (Keys and (1 shl i) <> 0) and (FKeys and (1 shl i) = 0) then
      begin
        FVoices[i].Position := 0;
        FVoices[i].Fraction := 0;
      end;
    FKeys := Keys;
  end;
end;

procedure TCPS3Sound.SerializeState(State: TStateArchive);
begin
  State.Field(FVoices, SizeOf(FVoices));
  State.Field(FKeys, SizeOf(FKeys));
  State.Field(FTime, SizeOf(FTime));
  State.Field(FNativePhase, SizeOf(FNativePhase));
  State.Field(FOutputPhase, SizeOf(FOutputPhase));
  State.Field(FLeft, SizeOf(FLeft));
  State.Field(FRight, SizeOf(FRight));

  if (FTime < 0) or (FNativePhase < 0) or (FNativePhase >= Int64(25000000) * 1152) or
    (FOutputPhase < 0) or (FOutputPhase >= 25000000) then
    raise EReadError.Create('Invalid CPS3 audio state');

  if State.Loading then
    BeginFrame;
end;

end.

