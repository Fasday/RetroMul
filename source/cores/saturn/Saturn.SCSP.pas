unit Saturn.SCSP;

interface

uses
  System.SysUtils, System.Classes, Saturn.SCSP.DSP, Core.Snapshots;

type
  TSCSPVoice = record
    Active, Backward: Boolean;
    Position: Int64;
    Envelope, Stage: Integer;
    EnvelopeCounter, EnvelopeStep, EnvelopePattern: Cardinal;
    LFO: Cardinal;
  end;

  TSaturnSCSP = class
  private
    FRead: TSCSPRead;
    FWrite: TSCSPWrite;
    FDSP: TSCSPDSP;
    FRegisters: array[0..$5FF] of Byte;
    FVoices: array[0..31] of TSCSPVoice;
    FStack: array[0..63] of SmallInt;
    FStackAt: Integer;
    FNoise: Cardinal;
    class var
      FGain: array[0..2047] of Integer;
    class var
      FPan: array[0..15] of Integer;
    class var
      FLFOStep: array[0..31] of Cardinal;
    class var
      FPitchLFO: array[0..7, 0..255] of Integer;
    class var
      FAmpLFO: array[0..7, 0..255] of Integer;
    function Reg(Address: Integer): Word;
    procedure KeyExecute;
    function Rate(Channel, Value: Integer): Integer;
    procedure Envelope(Channel: Integer);
    function VoiceSample(Channel: Integer): Integer;
    function PCM(Channel, Position: Integer): Integer;
    procedure LoopPosition(Channel: Integer);
    procedure MixStereo(Sample, Level, Pan: Integer; var Left, Right: Int64);
  public
    class constructor Create;
    constructor Create(Read: TSCSPRead; Write: TSCSPWrite);
    destructor Destroy; override;
    procedure Reset;
    function ReadRegister(Address: Cardinal): Byte;
    procedure WriteRegister(Address: Cardinal; Value: Byte);
    procedure Sample(CDLeft, CDRight: Integer; out Left, Right: SmallInt);
    function VoiceState(Channel: Integer): TSCSPVoice;
    procedure SerializeState(Archive: TStateArchive);
    property DSP: TSCSPDSP read FDSP;
  end;

implementation

uses
  System.Math;

{$Q+}{$R+}

// Native sample-clocked Yamaha envelope sequencer; LFO shares AICA constants.
const
  LFOFrequency: array[0..31] of Double = (
    0.17, 0.19, 0.23, 0.27, 0.34, 0.39, 0.45, 0.55, 0.68, 0.78, 0.92, 1.10, 1.39, 1.60, 1.87, 2.27,
    2.87, 3.31, 3.92, 4.79, 6.15, 7.18, 8.60, 10.8, 14.4, 17.2, 21.5, 28.7, 43.1, 57.4, 86.1, 172.3);
  PitchDepth: array[0..7] of Double = (0, 7, 13.5, 27, 55, 112, 230, 494);
  AmpDepth: array[0..7] of Double = (0, 0.4, 0.8, 1.5, 3, 6, 12, 24);

class constructor TSaturnSCSP.Create;
begin
  for var I := 0 to 2047 do
    FGain[I] := Round(Power(10, -I * 3 / (32.0 * 20)) * 65536);
  for var I := 0 to 14 do
    FPan[I] := Round(Power(10, -I * 3 / 20.0) * 65536);
  FPan[15] := 0;
  for var I := 0 to 31 do
    FLFOStep[I] := Round(LFOFrequency[I] * 4294967296.0 / 44100);
  for var Depth := 0 to 7 do
    for var Wave := 0 to 255 do
    begin
      FPitchLFO[Depth, Wave] := Round(Power(2, (Wave - 128) * PitchDepth[Depth] / (128 * 1200.0)) * 65536);
      FAmpLFO[Depth, Wave] := Round(Power(10, -Wave * AmpDepth[Depth] / (255 * 20.0)) * 65536);
    end;
end;

constructor TSaturnSCSP.Create(Read: TSCSPRead; Write: TSCSPWrite);
begin
  inherited Create;
  FRead := Read;
  FWrite := Write;
  FDSP := TSCSPDSP.Create(Read, Write);
  Reset;
end;

destructor TSaturnSCSP.Destroy;
begin
  FDSP.Free;
  inherited;
end;

procedure TSaturnSCSP.Reset;
begin
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FillChar(FVoices, SizeOf(FVoices), 0);
  FillChar(FStack, SizeOf(FStack), 0);
  FStackAt := 0;
  FNoise := 1;
  FDSP.Reset;
end;

function TSaturnSCSP.Reg(Address: Integer): Word;
begin
  Result := (Word(FRegisters[Address]) shl 8) or FRegisters[Address + 1];
end;

procedure TSaturnSCSP.KeyExecute;
begin
  for var I := 0 to 31 do
  begin
    if Reg(I * $20) and $800 <> 0 then
    begin
      if not FVoices[I].Active or (FVoices[I].Stage = 3) then
      begin
        FVoices[I] := Default(TSCSPVoice);
        FVoices[I].Active := True;
        FVoices[I].Envelope := $280 * 65536;
        FVoices[I].Stage := 0;
      end;
    end
    else if FVoices[I].Active then
      FVoices[I].Stage := 3;
    FRegisters[I * $20] := FRegisters[I * $20] and not $10;
  end;
end;

function TSaturnSCSP.ReadRegister(Address: Cardinal): Byte;
begin
  var A: Integer := Address and $FFF;
  if A >= $700 then
    Exit(FDSP.ReadRegister(A));
  if (A >= $600) and (A < $680) then
  begin
    var V := Word(FStack[(A - $600) div 2]);
    if Odd(A) then
      Exit(V and $FF)
    else
      Exit(V shr 8);
  end;
  if (A = $408) or (A = $409) then
  begin
    var I: Integer := (Reg($408) shr 11) and 31;
    var V: Word := ((Integer(FVoices[I].Position shr 12) and 15) shl 7) or ((FVoices[I].Stage and 3) shl 5) or ((FVoices[I].Envelope shr 21) and 31);
    if Odd(A) then
      Exit(V and $FF)
    else
      Exit(V shr 8);
  end;
  Result := 0;
  if A < $600 then
    Result := FRegisters[A];
end;

procedure TSaturnSCSP.WriteRegister(Address: Cardinal; Value: Byte);
begin
  var A: Integer := Address and $FFF;
  if A >= $700 then
  begin
    FDSP.WriteRegister(A, Value);
    Exit;
  end;
  if A >= $600 then
    Exit;
  FRegisters[A] := Value;
  if (A < $400) and (A and $1F in [0, 1]) and (Reg(A and $3E0) and $1000 <> 0) then
    KeyExecute;
  if (A < $400) and (A and $1F in [$12, $13]) and (Reg((A and $3E0) + $12) and $8000 <> 0) then
    FVoices[A div $20].LFO := 0;
  if (A = $402) or (A = $403) then
  begin
    FDSP.RingBase := (Reg($402) and $7F) * 8192;
    FDSP.RingLength := 8192 shl ((Reg($402) shr 7) and 3);
  end;
end;

function TSaturnSCSP.Rate(Channel, Value: Integer): Integer;
begin
  var B := Channel * $20;
  var KRS: Integer := (Reg(B + $A) shr 10) and 15;
  var Key: Integer := 0;
  if KRS <> 15 then
  begin
    var Oct: Integer := (Reg(B + $10) shr 11) and 15;
    if Oct >= 8 then
      Dec(Oct, 16);
    Key := Oct + KRS * 2 + Ord(Reg(B + $10) and $200 <> 0);
  end;
  Result := EnsureRange(Value * 2 + Key, 0, 63);
end;

procedure TSaturnSCSP.Envelope(Channel: Integer);
const
  Periods: array[0..3, 0..6] of Integer = ((8192, 4096, 4096, 0, 0, 0, 0),
    (8192, 4096, 4096, 4096, 4096, 4096, 4096), (4096, 0, 0, 0, 0, 0, 0), (4096, 4096, 2048, 2048, 0, 0, 0));
  Counts: array[0..3] of Integer = (3, 7, 1, 4);
  Fraction: array[0..3, 0..3] of Integer = ((0, 0, 0, 0), (1, 0, 0, 0), (1, 0, 1, 0), (1, 1, 1, 0));
begin
  var B := Channel * $20;
  var V := FVoices[Channel];
  var E := Reg(B + 8);
  var R := Reg(B + 10);
  V.EnvelopeCounter := Cardinal((UInt64(V.EnvelopeCounter) + 1) and $FFFFFFFF);
  var Setting: Integer := E and 31;
  case V.Stage of
    1:
      Setting := (E shr 6) and 31;
    2:
      Setting := (E shr 11) and 31;
    3:
      Setting := R and 31;
  end;
  var Effective := Rate(Channel, Setting);
  var Pulse: Boolean := False;
  if (Setting <> 0) and (Effective >= 2) then
    if Effective >= 48 then
      Pulse := V.EnvelopeCounter and 1 = 0
    else
    begin
      var Group: Integer := (Effective - 2) and 3;
      var Shift: Integer := (Effective - 2) div 4;
      var Period := Max(1, Periods[Group, V.EnvelopeStep mod Cardinal(Counts[Group])] shr Shift);
      if V.EnvelopeCounter mod Cardinal(Period) = 0 then
      begin
        Pulse := True;
        V.EnvelopeStep := Cardinal((UInt64(V.EnvelopeStep) + 1) and $FFFFFFFF);
      end;
    end;
  if Pulse then
  begin
    var Att := V.Envelope shr 16;
    if V.Stage = 0 then
    begin
      var Shift: Integer := 4;
      if Effective >= 48 then
        Shift := Max(0, 4 - (Effective - 48) div 4 - Fraction[Effective and 3, V.EnvelopePattern and 3]);
      Att := Max(0, Att - (Att shr Shift) - 1);
      if Att = 0 then
        if R and $4000 = 0 then
        begin
          V.Stage := 1;
          V.EnvelopeStep := 0;
        end;
    end
    else
    begin
      var Step: Integer := 1;
      if Effective >= 48 then
        Step := (1 shl ((Effective - 48) div 4)) * (1 + Fraction[Effective and 3, V.EnvelopePattern and 3]);
      Att := Min(1023, Att + Step);
      if (V.Stage = 1) and (Att shr 5 >= ((R shr 5) and 31)) then
      begin
        V.Stage := 2;
        V.EnvelopeStep := 0;
      end;
    end;
    V.Envelope := Att * 65536;
    V.EnvelopePattern := Cardinal((UInt64(V.EnvelopePattern) + 1) and $FFFFFFFF);
  end;
  if V.Envelope >= 1023 * 65536 then
  begin
    V.Envelope := 1023 * 65536;
    if V.Stage = 3 then
    begin
      V.Active := False;
      FRegisters[B] := FRegisters[B] and not 8;
    end;
  end;
  FVoices[Channel] := V;
end;

function TSaturnSCSP.PCM(Channel, Position: Integer): Integer;
begin
  var B := Channel * $20;
  var Control := Reg(B);
  var Address: Cardinal := ((Cardinal(Control and 15) shl 16) or Reg(B + 2));
  if Control and $10 <> 0 then
    Result := ShortInt(FRead((Address + Cardinal(Position)) and $7FFFF)) * 256
  else
  begin
    Address := (Address + Cardinal(Position * 2)) and $7FFFF;
    Result := SmallInt((Word(FRead(Address)) shl 8) or FRead((Address + 1) and $7FFFF));
  end;
  case (Control shr 9) and 3 of
    1:
      Result := SmallInt(Word(Result) xor $7FFF);
    2:
      Result := SmallInt(Word(Result) xor $8000);
    3:
      Result := SmallInt(Word(Result) xor $FFFF);
  end;
end;

procedure TSaturnSCSP.LoopPosition(Channel: Integer);
begin
  var B := Channel * $20;
  var V := FVoices[Channel];
  var First: Int64 := Int64(Reg(B + 4)) shl 12;
  var Last: Int64 := Int64(Reg(B + 6)) shl 12;
  var Kind: Integer := (Reg(B) shr 5) and 3;
  if Last <= First then
    Last := First + 4096;
  if (Reg(B + 10) and $4000 <> 0) and (V.Stage = 0) and (V.Position >= First) then
    V.Stage := 1;
  case Kind of
    0:
      if V.Position >= Last then
      begin
        V.Active := False;
        FRegisters[B] := FRegisters[B] and not 8;
      end;
    1:
      if V.Position >= Last then
        V.Position := First + (V.Position - First) mod (Last - First);
    2:
      begin
        if not V.Backward and (V.Position >= First) then
        begin
          V.Backward := True;
          V.Position := Last - (V.Position - First);
        end;
        if V.Position < First then
          V.Position := Last - 1 - (First - 1 - V.Position) mod (Last - First);
      end;
    3:
      begin
        if not V.Backward and (V.Position >= Last) then
        begin
          V.Backward := True;
          V.Position := Last * 2 - 4096 - V.Position;
        end;
        if V.Backward and (V.Position < First) then
        begin
          V.Backward := False;
          V.Position := First * 2 - V.Position;
        end;
      end;
  end;
  FVoices[Channel] := V;
end;

function WaveValue(Kind, Phase, Noise: Integer): Integer;
begin
  case Kind of
    0:
      Result := Phase;
    1:
      if Phase < 128 then
        Result := 0
      else
        Result := 255;
    2:
      begin
        Result := Phase * 2;
        if Phase >= 128 then
          Result := 511 - Result;
      end;
  else
    Result := Noise and 255;
  end;
end;

function TSaturnSCSP.VoiceSample(Channel: Integer): Integer;
begin
  Result := 0;
  if not FVoices[Channel].Active then
  begin
    if Reg(Channel * $20 + $C) and $200 = 0 then
      FStack[(FStackAt + Channel) and 63] := 0;
    Exit;
  end;
  var B := Channel * $20;
  var Control := Reg(B);
  var V := FVoices[Channel];
  var Modulation := Reg(B + $E);
  var Offset: Int64 := 0;
  var Depth: Integer := Modulation shr 12;
  if Depth > 0 then
    Offset := Int64(Integer(FStack[(FStackAt + Channel + ((Modulation shr 6) and 63)) and 63]) + FStack[(FStackAt + Channel + (Modulation and 63)) and 63]) * (Int64(1) shl Depth) div 32;
  var Position := Max(Int64(0), V.Position + Offset);
  var Index: Integer := Position shr 12;
  var Source: Integer := (Control shr 7) and 3;
  case Source of
    0:
      begin
        var A := PCM(Channel, Index);
        var Next := Index + 1;
        var Last := Reg(B + 6);
        var First := Reg(B + 4);
        if (Next >= Last) and ((Control shr 5) and 3 <> 0) then
        begin
          if ((Control shr 5) and 3) = 1 then
            Next := First
          else
            Next := Max(Integer(First), Integer(Last) - 1);
        end;
        Result := A + Integer(Int64(PCM(Channel, Next) - A) * (Position and 4095) div 4096);
      end;
    1:
      Result := SmallInt(FNoise and $FFFF);
  end;
  var Pitch: Integer := Reg(B + $10);
  var Oct: Integer := (Pitch shr 11) and 15;
  if Oct >= 8 then
    Dec(Oct, 16);
  var Step: Int64 := (1024 + (Pitch and 1023)) * 4;
  if Oct >= 0 then
    Step := Step shl Oct
  else
    Step := Step shr  - Oct;
  var LFO := Reg(B + $12);
  var Phase: Integer := V.LFO shr 24;
  if LFO and $8000 = 0 then
    V.LFO := Cardinal((UInt64(V.LFO) + FLFOStep[(LFO shr 10) and 31]) and $FFFFFFFF)
  else
  begin
    V.LFO := 0;
    Phase := 0;
  end;
  Step := Step * FPitchLFO[(LFO shr 5) and 7, WaveValue((LFO shr 8) and 3, Phase, FNoise)] div 65536;
  if V.Backward then
    Dec(V.Position, Step)
  else
    Inc(V.Position, Step);
  FVoices[Channel] := V;
  LoopPosition(Channel);
  var Level := Reg(B + $C);
  var EnvelopeGain: Integer := 65536;
  Envelope(Channel);
  if Level and $100 = 0 then
  begin
    var Att: Integer := FVoices[Channel].Envelope shr 16;
    if (FVoices[Channel].Stage = 0) and (Reg(B + 8) and $20 <> 0) then
      Att := 0;
    EnvelopeGain := FGain[EnsureRange(Att + (Level and $FF) * 4, 0, 2047)];
    EnvelopeGain := Integer(Int64(EnvelopeGain) * FAmpLFO[LFO and 7, WaveValue((LFO shr 3) and 3, Phase, FNoise)] div 65536);
  end;
  Result := Integer(Int64(Result) * EnvelopeGain div 65536);
  if Level and $200 = 0 then
    FStack[(FStackAt + Channel) and 63] := EnsureRange(Result, -32768, 32767);
end;

procedure TSaturnSCSP.MixStereo(Sample, Level, Pan: Integer; var Left, Right: Int64);
begin
  if Level = 0 then
    Exit;
  var V: Int64 := Sample;
  if Level < 7 then
    V := V div (1 shl (7 - Level));
  var P := FPan[Pan and 15];
  if Pan and 16 = 0 then
  begin
    Inc(Left, V * P div 65536);
    Inc(Right, V);
  end
  else
  begin
    Inc(Left, V);
    Inc(Right, V * P div 65536);
  end;
end;

procedure TSaturnSCSP.Sample(CDLeft, CDRight: Integer; out Left, Right: SmallInt);
begin
  FNoise := (FNoise shr 1) xor (Cardinal(-Integer(FNoise and 1)) and $400181);
  var L, R: Int64;
  L := 0;
  R := 0;
  FDSP.external(EnsureRange(CDLeft, -32768, 32767), EnsureRange(CDRight, -32768, 32767));
  for var I := 0 to 31 do
  begin
    var V := VoiceSample(I);
    var B := I * $20;
    var Mix := Reg(B + $14);
    var OutReg := Reg(B + $16);
    var Send: Integer := Mix and 7;
    if Send > 0 then
      FDSP.Mix((Mix shr 3) and 15, V * 16 div (1 shl (7 - Send)));
    MixStereo(V, (OutReg shr 13) and 7, (OutReg shr 8) and 31, L, R);
  end;
  FDSP.Step;
  for var I := 0 to 15 do
  begin
    var OutReg := Reg(I * $20 + $16);
    MixStereo(FDSP.Effect(I), (OutReg shr 5) and 7, OutReg and 31, L, R);
  end;
  var OutReg := Reg(16 * $20 + $16);
  MixStereo(CDLeft, (OutReg shr 5) and 7, OutReg and 31, L, R);
  OutReg := Reg(17 * $20 + $16);
  MixStereo(CDRight, (OutReg shr 5) and 7, OutReg and 31, L, R);
  FStackAt := (FStackAt + 32) and 63;
  var Volume: Integer := Reg($400) and 15;
  if Volume = 0 then
  begin
    Left := 0;
    Right := 0;
  end
  else
  begin
    Left := EnsureRange(L * FGain[(15 - Volume) * 32] div 65536, Int64(-32768), Int64(32767));
    Right := EnsureRange(R * FGain[(15 - Volume) * 32] div 65536, Int64(-32768), Int64(32767));
  end;
end;

procedure TSaturnSCSP.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(FRegisters, SizeOf(FRegisters));
  Archive.Field(FVoices, SizeOf(FVoices));
  Archive.Field(FStack, SizeOf(FStack));
  Archive.Field(FStackAt, SizeOf(FStackAt));
  Archive.Field(FNoise, SizeOf(FNoise));
  FDSP.SerializeState(Archive);
  if (FStackAt <> 0) and (FStackAt <> 32) then
    raise EReadError.Create('Invalid SCSP stack state');
  for var I := 0 to 31 do
    if (FVoices[I].Stage < 0) or (FVoices[I].Stage > 3) or (FVoices[I].Envelope < 0) or (FVoices[I].Envelope > 1023 * 65536) then
      raise EReadError.Create('Invalid SCSP envelope state');
end;

function TSaturnSCSP.VoiceState(Channel: Integer): TSCSPVoice;
begin
  if not (Channel in [0..31]) then
    raise EArgumentOutOfRangeException.Create('SCSP slot');
  Result := FVoices[Channel];
end;

end.

