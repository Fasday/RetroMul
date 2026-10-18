unit CPS.QSound;

// Native DL-1425 HLE based on the DSP disassembly by superctr and
// Valley Bell, BSD-3-Clause. Filters/delays retain their sample history.
interface

uses
  System.SysUtils, Core.Snapshots;

type
  TQFilter = record
    Count, Position: Integer;
    Table: Word;
    Taps, History: array[0..94] of SmallInt;
  end;

  TQDelay = record
    Delay, Volume: SmallInt;
    WriteAt, ReadAt: Integer;
    History: array[0..50] of SmallInt;
  end;

  TQADPCMVoice = record
    Address: Word;
    Volume, Step: Integer;
  end;

  TCPSQSound = class
  private
    FRegs: array[0..255] of Word;
    FROM: TBytes;
    FFilter, FAlt: array[0..1] of TQFilter;
    FWet, FDry: array[0..1] of TQDelay;
    FADPCM: array[0..2] of TQADPCMVoice;
    FEcho: array[0..1023] of SmallInt;
    FEchoAt, FLastEcho, FCounter, FState, FNext, FReady: Integer;
    FOutput: array[0..18] of SmallInt;
    FLatch: Word;
    FNativePhase, FOutputPhase: Int64;
    FLeft, FRight: Integer;
    FCount: Integer;
    function ReadSample(Bank, Address: Word): Integer;
    procedure Tick;
    procedure Initialize(Mode: Integer);
    procedure Refresh;
    procedure Command(Address: Byte; Value: Word);
  public
    Samples: TArray<SmallInt>;
    constructor Create(const ROM: TBytes);
    procedure Reset;
    procedure BeginFrame;
    procedure EndFrame;
    procedure Advance(Cycles: Integer);
    procedure Write(Port: Integer; Value: Byte);
    function Status: Byte;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Classes, System.Math;

// QSound DSP data: superctr and Valley Bell, BSD-3-Clause. See CPS.LICENSE.
const
  QDry: array[0..32] of SmallInt = (
    -16384, -16384, -16384, -16384, -16384, -16384, -16384, -16384, -16384, -16384, -16384, -16384, -16384, -16384, -16384, -16384,
    -16384, -14746, -13107, -11633, -10486, -9175, -8520, -7209, -6226, -5226, -4588, -3768, -3277, -2703, -2130, -1802,
    0
  );
  QWet: array[0..32] of SmallInt = (
    0, -1638, -1966, -2458, -2949, -3441, -4096, -4669, -4915, -5120, -5489, -6144, -7537, -8831, -9339, -9830,
    -10240, -10322, -10486, -10568, -10650, -11796, -12288, -12288, -12534, -12648, -12780, -12829, -12943, -13107, -13418, -14090,
    -16384
  );
  QLinear: array[0..32] of SmallInt = (
    -16379, -16338, -16257, -16135, -15973, -15772, -15531, -15251, -14934, -14580, -14189, -13763, -13303, -12810, -12284, -11729,
    -11729, -11144, -10531, -9893, -9229, -8543, -7836, -7109, -6364, -5604, -4829, -4043, -3246, -2442, -1631, -817,
    0
  );
  QFilters: array[0..474] of SmallInt = (
    0, 0, 0, 6, 44, -24, -53, -10, 59, -40, -27, 1, 39, -27, 56, 127,
    174, 36, -13, 49, 212, 142, 143, -73, -20, 66, -108, -117, -399, -265, -392, -569,
    -473, -71, 95, -319, -218, -230, 331, 638, 449, 477, -180, 532, 1107, 750, 9899, 3828,
    -2418, 1071, -176, 191, -431, 64, 117, -150, -274, -97, -238, 165, 166, 250, -19, 4,
    37, 204, 186, -6, 140, -77, -1, 1, 18, -10, -151, -149, -103, -9, 55, 23,
    -102, -97, -11, 13, -48, -27, 5, 18, -61, -30, 64, 72, 0, 0, 0, 0,
    0, 0, 85, 24, -76, -123, -86, -29, -14, -20, -7, 6, -28, -87, -89, -5,
    100, 154, 160, 150, 118, 41, -48, -78, -23, 59, 83, -2, -176, -333, -344, -203,
    -66, -39, 2, 224, 495, 495, 280, 432, 1340, 2483, 5377, 1905, 658, 0, 97, 347,
    285, 35, -95, -78, -82, -151, -192, -171, -149, -147, -113, -22, 71, 118, 129, 127,
    110, 71, 31, 20, 36, 46, 23, -27, -63, -53, -21, -19, -60, -92, -69, -12,
    25, 29, 30, 40, 41, 29, 30, 46, 39, -15, -74, 0, 0, 0, 0, 0,
    0, 23, 42, 47, 29, 10, 2, -14, -54, -92, -93, -70, -64, -77, -57, 18,
    94, 113, 87, 69, 67, 50, 25, 29, 58, 62, 24, -39, -131, -256, -325, -234,
    -45, 58, 78, 223, 485, 496, 127, 6, 857, 2283, 2683, 4928, 1328, 132, 79, 314,
    189, -80, -90, 35, -21, -186, -195, -99, -136, -258, -189, 82, 257, 185, 53, 41,
    84, 68, 38, 63, 77, 14, -60, -71, -71, -120, -151, -84, 14, 29, -8, 7,
    66, 69, 12, -3, 54, 92, 52, -6, -15, -2, 0, 0, 0, 0, 0, 0,
    2, -28, -37, -17, 0, -9, -22, -3, 35, 52, 39, 20, 7, -6, 2, 55,
    121, 129, 67, 8, 1, 9, -6, -16, 16, 66, 96, 118, 130, 75, -47, -92,
    43, 223, 239, 151, 219, 440, 475, 226, 206, 940, 2100, 2663, 4980, 865, 49, -33,
    186, 231, 103, 42, 114, 191, 184, 116, 29, -47, -72, -21, 60, 96, 68, 31,
    32, 63, 87, 76, 39, 7, 14, 55, 85, 67, 18, -12, -3, 21, 34, 29,
    6, -27, -49, -37, -2, 16, 0, -21, -16, 0, 0, 0, 0, 0, 0, 48,
    7, -22, -29, -10, 24, 54, 59, 29, -36, -117, -185, -213, -185, -99, 13, 90,
    83, 24, -5, 23, 53, 47, 38, 56, 67, 57, 75, 107, 16, -242, -440, -355,
    -120, -33, -47, 152, 501, 472, -57, -292, 544, 1937, 2277, 6145, 1240, 153, 47, 200,
    152, 36, 64, 134, 74, -82, -208, -266, -268, -188, -42, 65, 74, 56, 89, 133,
    114, 44, -3, -1, 17, 29, 29, -2, -76, -156, -187, -151, -85, -31, -5, 7,
    20, 32, 24, -5, -20, 6, 48, 62, 0, 0, 0
  );
  QFilters2: array[0..208] of SmallInt = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -371,
    -196, -268, -512, -303, -315, -184, -76, 276, -256, 298, 196, 990, 236, 1114, -126, 4377,
    6549, 791, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, -16384, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0
  );
  QADPCM: array[0..15] of SmallInt = (
    154, 154, 128, 102, 77, 58, 58, 58, 58, 58, 58, 58, 77, 102, 128, 154
  );

function S16(Value: Int64): SmallInt; inline;
begin
  Result := SmallInt(Integer(Value and $7FFF) - Integer(Value and $8000));
end;

function S32(Value: Int64): Integer; inline;
begin
  Result := Integer(Value and $7FFFFFFF);
  if Value and $80000000 <> 0 then
    Result := Result - $40000000 - $40000000;
end;

function ASR(Value: Int64; Bits: Integer): Int64; inline;
begin
  Result := Value div (Int64(1) shl Bits);
  if (Value < 0) and (Value and ((Int64(1) shl Bits) - 1) <> 0) then
    Dec(Result);
end;

function FIR(var F: TQFilter; Input: SmallInt): Integer;
begin
  var Sum: Int64 := 0;
  for var i := 0 to F.Count - 2 do
  begin
    Dec(Sum, Int64(F.Taps[i]) * F.History[F.Position] * 4);
    F.Position := (F.Position + 1) mod (F.Count - 1);
  end;
  Dec(Sum, Int64(F.Taps[F.Count - 1]) * Input * 4);
  F.History[F.Position] := Input;
  F.Position := (F.Position + 1) mod (F.Count - 1);
  Result := S32(Sum);
end;

function Delay(var D: TQDelay; Input: Int64): Integer;
begin
  D.History[D.WriteAt] := S16(ASR(Input, 16));
  D.WriteAt := (D.WriteAt + 1) mod 51;
  Result := D.History[D.ReadAt] * D.Volume;
  D.ReadAt := (D.ReadAt + 1) mod 51;
end;

function FilterData(Address: Integer): SmallInt;
begin
  if (Address >= $D53) and (Address < $D53 + Length(QFilters)) then
    Exit(QFilters[Address - $D53]);

  if (Address >= $F2E) and (Address < $F2E + Length(QFilters2)) then
    Exit(QFilters2[Address - $F2E]);

  Result := 0;
end;

constructor TCPSQSound.Create(const ROM: TBytes);
begin
  inherited Create;
  FROM := ROM;
  Reset;
end;

procedure TCPSQSound.Reset;
begin
  FState := 0;
  FNext := 0;
  FCounter := 0;
  FReady := 0;
  FLatch := 0;
  FNativePhase := 0;
  FOutputPhase := 0;
  FLeft := 0;
  FRight := 0;
  BeginFrame;
end;

procedure TCPSQSound.BeginFrame;
begin
  FCount := 0;
  SetLength(Samples, 2048);
end;

procedure TCPSQSound.EndFrame;
begin
  SetLength(Samples, FCount);
end;

function TCPSQSound.ReadSample(Bank, Address: Word): Integer;
begin
  var At := (Cardinal(Bank and $7FFF) shl 16) or Address;
  if At >= Cardinal(Length(FROM)) then
    Exit(0);

  Result := (Integer(FROM[At] and $7F) - Integer(FROM[At] and $80)) * 256;
end;

procedure TCPSQSound.Write(Port: Integer; Value: Byte);
begin
  case Port of
    0:
      FLatch := (FLatch and $FF) or (Word(Value) shl 8);
    1:
      FLatch := (FLatch and $FF00) or Value;
    2:
      begin
        Command(Value, FLatch);
        FReady := 0;
      end;
  end;
end;

function TCPSQSound.Status: Byte;
begin
  Result := FReady;
end;

procedure TCPSQSound.Command(Address: Byte; Value: Word);
begin
  FRegs[Address] := Value;
  if Address = $E3 then
    FNext := Value;
  for var Ch := 0 to 1 do
  begin
    if Address = $DA + Ch * 2 then
      FFilter[Ch].Table := Value;
    if Address = $DB + Ch * 2 then
      FAlt[Ch].Table := Value;
    if Address = $DE + Ch * 2 then
      FWet[Ch].Delay := S16(Value);
    if Address = $DF + Ch * 2 then
      FDry[Ch].Delay := S16(Value);
    if Address = $E4 + Ch * 2 then
      FWet[Ch].Volume := S16(Value);
    if Address = $E5 + Ch * 2 then
      FDry[Ch].Volume := S16(Value);
  end;
end;

procedure TCPSQSound.Initialize(Mode: Integer);
begin
  FillChar(FRegs, SizeOf(FRegs), 0);
  FillChar(FFilter, SizeOf(FFilter), 0);
  FillChar(FAlt, SizeOf(FAlt), 0);
  FillChar(FWet, SizeOf(FWet), 0);
  FillChar(FDry, SizeOf(FDry), 0);
  FillChar(FADPCM, SizeOf(FADPCM), 0);
  FillChar(FEcho, SizeOf(FEcho), 0);
  FillChar(FOutput, SizeOf(FOutput), 0);
  FEchoAt := 0;
  FLastEcho := 0;
  for var i := 0 to 15 do
  begin
    FRegs[i * 8] := $8000;
    FRegs[$80 + i] := $120;
  end;
  for var i := 0 to 2 do
  begin
    FRegs[$CC + i * 4] := $8000;
    FRegs[$90 + i] := $120;
  end;
  if Mode = 0 then
  begin
    FDry[0].Delay := 46;
    FDry[1].Delay := 48;
    FFilter[0].Table := $DB2;
    FFilter[1].Table := $E11;
    FRegs[$D9] := $55A;
    FNext := $39;
  end
  else
  begin
    FWet[0].Delay := 1;
    FFilter[0].Table := $F73;
    FFilter[1].Table := $FA4;
    FAlt[0].Table := $F73;
    FAlt[1].Table := $FA4;
    FRegs[$D9] := $542;
    FNext := $4F;
  end;
  for var Ch := 0 to 1 do
  begin
    FWet[Ch].Volume := $3FFF;
    FDry[Ch].Volume := $3FFF;
  end;
  FRegs[$E2] := 1;
  FReady := 0;
  FCounter := 1;
end;

procedure TCPSQSound.Refresh;
begin
  for var Ch := 0 to 1 do
  begin
    FFilter[Ch].Position := 0;
    if FState = $39 then
      FFilter[Ch].Count := 95
    else
      FFilter[Ch].Count := 45;
    for var i := 0 to FFilter[Ch].Count - 1 do
      FFilter[Ch].Taps[i] := FilterData(FFilter[Ch].Table + i);
    if FState = $4F then
    begin
      FAlt[Ch].Count := 44;
      FAlt[Ch].Position := 0;
      for var i := 0 to 43 do
        FAlt[Ch].Taps[i] := FilterData(FAlt[Ch].Table + i);
    end;
  end;
  if FState = $39 then
    FState := $314
  else
    FState := $6B2;
  FNext := FState;
end;

procedure TCPSQSound.Tick;
begin
  if FState in [$39, $4F] then
  begin
    Refresh;
    Exit;
  end;

  if (FState <> $314) and (FState <> $6B2) then
  begin
    if FCounter = 0 then
      Initialize(Ord(FState = $61A))
    else if FCounter = 1 then
      Inc(FCounter)
    else
    begin
      FCounter := 0;
      FState := FNext;
    end;
    Exit;
  end;

  FReady := $80;
  var EchoIn: Int64 := 0;
  for var i := 0 to 15 do
  begin
    var R := i * 8;
    FOutput[i] := S16(ASR(Int64(S16(FRegs[R + 6])) * ReadSample(FRegs[((i + 15) and 15) * 8], FRegs[R + 1]), 14));
    Inc(EchoIn, Int64(FOutput[i]) * S16(FRegs[$BA + i]) * 4);
    var Phase := Integer(FRegs[R + 2]) + Integer(S16(FRegs[R + 1])) * 4096 + (FRegs[R + 3] shr 4);
    if ASR(Phase, 12) >= S16(FRegs[R + 5]) then
      Dec(Phase, Integer(S16(FRegs[R + 4])) * 4096);
    Phase := EnsureRange(Phase, -$8000000, $7FFFFFF);
    FRegs[R + 1] := Word(ASR(Phase, 12) and $FFFF);
    FRegs[R + 3] := Word((Int64(Phase) * 16) and $FFFF);
  end;
  var A := FCounter mod 3;
  var R := $CA + A * 4;
  if FCounter < 3 then
  begin
    if FADPCM[A].Address = FRegs[R + 1] then
      FADPCM[A].Volume := 0;
    if FRegs[$D6 + A] <> 0 then
    begin
      FRegs[$D6 + A] := 0;
      FOutput[16 + A] := 0;
      FADPCM[A].Step := 10;
      FADPCM[A].Volume := S16(FRegs[R + 3]);
      FADPCM[A].Address := FRegs[R];
    end;
  end;
  var N := ReadSample(FRegs[R + 2], FADPCM[A].Address) div 256;
  if FCounter < 3 then
    N := Integer(ASR(N, 4))
  else
  begin
    N := (N and 15);
    if N >= 8 then
      Dec(N, 16);
    FADPCM[A].Address := Word((Cardinal(FADPCM[A].Address) + 1) and $FFFF);
  end;
  var D := (1 + Abs(N * 2)) * FADPCM[A].Step div 2;
  if N <= 0 then
    D := -D;
  D := EnsureRange(D + FOutput[16 + A], -32768, 32767);
  FADPCM[A].Step := EnsureRange(QADPCM[8 + N] * FADPCM[A].Step div 64, 1, 2000);
  FOutput[16 + A] := S16(ASR(Int64(D) * FADPCM[A].Volume, 16));
  var Old := (Integer(FEcho[FEchoAt]) + FLastEcho) div 2;
  FLastEcho := FEcho[FEchoAt];
  FEcho[FEchoAt] := S16(ASR(S32(EchoIn + Int64(Old) * S16(FRegs[$93]) * 4), 16));
  var EchoLength := Integer(FRegs[$D9]) - $554;
  if FState = $6B2 then
    EchoLength := Integer(FRegs[$D9]) - $53C;
  Inc(FEchoAt);
  if FEchoAt >= EnsureRange(EchoLength, 0, 1024) then
    FEchoAt := 0;
  for var Ch := 0 to 1 do
  begin
    var Wet: Int64 := 0;
    var Dry: Int64 := 0;
    if Ch = 0 then
      Dry := Old * 16384
    else
      Wet := Old * 16384;
    for var i := 0 to 18 do
    begin
      var P := Integer(FRegs[$80 + i]);
      if i >= 16 then
        P := FRegs[$90 + i - 16];
      Dec(P, $110);
      if Ch = 1 then
      begin
        if P >= $30 then
          P := $50 - P
        else
          P := $20 - P;
      end;
      if (P >= 0) and (P <= 32) then
      begin
        Dec(Dry, Int64(FOutput[i]) * QDry[P]);
        Dec(Wet, Int64(FOutput[i]) * QWet[P]);
      end
      else if (P >= $30) and (P <= $50) then
        Dec(Dry, Int64(FOutput[i]) * QLinear[P - $30]);
    end;
    Dry := EnsureRange(Dry, Int64(-$1FFFFFFF), Int64($1FFFFFFF)) * 4;
    Wet := EnsureRange(Wet, Int64(-$1FFFFFFF), Int64($1FFFFFFF)) * 4;
    Wet := FIR(FFilter[Ch], S16(ASR(Wet, 16)));
    if FState = $6B2 then
      Dry := FIR(FAlt[Ch], S16(ASR(Dry, 16)));
    var OutSample := S32(Int64(Delay(FWet[Ch], Wet)) + Delay(FDry[Ch], Dry));
    var Value := EnsureRange(ASR(Int64(OutSample) + $2000, 14), Int64(-32767), Int64(32767));
    if Ch = 0 then
      FLeft := Value
    else
      FRight := Value;
    if FRegs[$E2] <> 0 then
    begin
      FWet[Ch].ReadAt := ((FWet[Ch].WriteAt - FWet[Ch].Delay) mod 51 + 51) mod 51;
      FDry[Ch].ReadAt := ((FDry[Ch].WriteAt - FDry[Ch].Delay) mod 51 + 51) mod 51;
    end;
  end;
  FRegs[$E2] := 0;
  Inc(FCounter);
  if FCounter >= 6 then
  begin
    FCounter := 0;
    FState := FNext;
  end;
end;

procedure TCPSQSound.Advance(Cycles: Integer);
begin
  // Z80 8MHz; DSP 60MHz/(2*1248), output 44.1kHz.
  while Cycles > 0 do
  begin
    var N := Min(Int64(Cycles), Min((Int64(8000000) * 2496 - FNativePhase + 59999999) div 60000000,
        (8000000 - FOutputPhase + 44099) div 44100));
    Dec(Cycles, N);
    Inc(FNativePhase, N * 60000000);
    Inc(FOutputPhase, N * 44100);
    if FNativePhase >= Int64(8000000) * 2496 then
    begin
      Dec(FNativePhase, Int64(8000000) * 2496);
      Tick;
    end;
    if FOutputPhase >= 8000000 then
    begin
      Dec(FOutputPhase, 8000000);
      if Length(Samples) < FCount + 2 then
        SetLength(Samples, FCount + 2048);
      Samples[FCount] := FLeft;
      Samples[FCount + 1] := FRight;
      Inc(FCount, 2);
    end;
  end;
end;

procedure TCPSQSound.SerializeState(State: TStateArchive);
begin
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FFilter, SizeOf(FFilter));
  State.Field(FAlt, SizeOf(FAlt));
  State.Field(FWet, SizeOf(FWet));
  State.Field(FDry, SizeOf(FDry));
  State.Field(FADPCM, SizeOf(FADPCM));
  State.Field(FEcho, SizeOf(FEcho));
  State.Field(FEchoAt, SizeOf(FEchoAt));
  State.Field(FLastEcho, SizeOf(FLastEcho));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FState, SizeOf(FState));
  State.Field(FNext, SizeOf(FNext));
  State.Field(FReady, SizeOf(FReady));
  State.Field(FOutput, SizeOf(FOutput));
  State.Field(FLatch, SizeOf(FLatch));
  State.Field(FNativePhase, SizeOf(FNativePhase));
  State.Field(FOutputPhase, SizeOf(FOutputPhase));
  State.Field(FLeft, SizeOf(FLeft));
  State.Field(FRight, SizeOf(FRight));
  if (FCounter < 0) or (FCounter > 5) or (FEchoAt < 0) or (FEchoAt > 1023) or
    (FNativePhase < 0) or (FNativePhase >= Int64(8000000) * 2496) or (FOutputPhase < 0) or (FOutputPhase >= 8000000) then
    raise EReadError.Create('Invalid QSound state');

  for var Ch := 0 to 1 do
    if (FFilter[Ch].Count < 0) or (FFilter[Ch].Count > 95) or (FFilter[Ch].Position < 0) or (FFilter[Ch].Position > 94) or
      (FAlt[Ch].Count < 0) or (FAlt[Ch].Count > 95) or (FAlt[Ch].Position < 0) or (FAlt[Ch].Position > 94) or
      (FWet[Ch].ReadAt < 0) or (FWet[Ch].ReadAt > 50) or (FWet[Ch].WriteAt < 0) or (FWet[Ch].WriteAt > 50) or
      (FDry[Ch].ReadAt < 0) or (FDry[Ch].ReadAt > 50) or (FDry[Ch].WriteAt < 0) or (FDry[Ch].WriteAt > 50) then
      raise EReadError.Create('Invalid QSound filter state');

  if State.Loading then
    BeginFrame;
end;

end.

