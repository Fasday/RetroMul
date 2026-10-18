unit CPS1.Sound;

// YM2151 register interpretation follows Yamaha's OPM application manual.
// Reuses RetroMul's native four-operator envelope and sine implementation.
interface

uses
  System.SysUtils, MD.Sound, Core.Snapshots;

type
  TOKIVoice = record
    Playing: Boolean;
    Position, Ending, Signal, Step, Volume, Output: Integer;
  end;

  TCPS1Sound = class
  private
    FROM: TBytes;
    FChannels: array[0..7] of TFMChannel;
    FRegs: array[0..255] of Byte;
    FVoices: array[0..3] of TOKIVoice;
    FPending: Integer;
    FPin7: Boolean;
    FFraction, FOutputPhase, FOKIPhase: Int64;
    FLFO, FNoise: Cardinal;
    FNoiseCounter, FNoiseState, FCount, FAMDepth, FPMDepth: Integer;
    FLeft, FRight, FOKIOutput: Integer;
    FKeyMask: array[0..7] of Byte;
    FCSM: Boolean;
    FBankStart, FBankSize, FBankOffset: Integer;
    FMasterClock: Integer;
    function SampleByte(Address: Integer): Byte;
    procedure Frequency(Channel, Modulation: Integer);
    procedure Tick;
    procedure OKITick;
  public
    Samples: TArray<SmallInt>;
    constructor Create(const ROM: TBytes; MasterClock: Integer = 3579545);
    procedure Reset;
    procedure BeginFrame;
    procedure EndFrame;
    procedure Advance(Cycles: Integer);
    procedure WriteYM(Address, Value: Byte);
    procedure CSM;
    procedure WriteOKI(Value: Byte);
    function OKIStatus: Byte;
    procedure SetPin7(Value: Boolean);
    procedure SetSampleBank(Start, Size, Offset: Integer);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Classes, System.Math;

const
  OPMSteps: array[0..767] of Cardinal = (
    41568, 41600, 41632, 41664, 41696, 41728, 41760, 41792, 41856, 41888, 41920, 41952, 42016, 42048, 42080, 42112,
    42176, 42208, 42240, 42272, 42304, 42336, 42368, 42400, 42464, 42496, 42528, 42560, 42624, 42656, 42688, 42720,
    42784, 42816, 42848, 42880, 42912, 42944, 42976, 43008, 43072, 43104, 43136, 43168, 43232, 43264, 43296, 43328,
    43392, 43424, 43456, 43488, 43552, 43584, 43616, 43648, 43712, 43744, 43776, 43808, 43872, 43904, 43936, 43968,
    44032, 44064, 44096, 44128, 44192, 44224, 44256, 44288, 44352, 44384, 44416, 44448, 44512, 44544, 44576, 44608,
    44672, 44704, 44736, 44768, 44832, 44864, 44896, 44928, 44992, 45024, 45056, 45088, 45152, 45184, 45216, 45248,
    45312, 45344, 45376, 45408, 45472, 45504, 45536, 45568, 45632, 45664, 45728, 45760, 45792, 45824, 45888, 45920,
    45984, 46016, 46048, 46080, 46144, 46176, 46208, 46240, 46304, 46336, 46368, 46400, 46464, 46496, 46528, 46560,
    46656, 46688, 46720, 46752, 46816, 46848, 46880, 46912, 46976, 47008, 47072, 47104, 47136, 47168, 47232, 47264,
    47328, 47360, 47392, 47424, 47488, 47520, 47552, 47584, 47648, 47680, 47744, 47776, 47808, 47840, 47904, 47936,
    48032, 48064, 48096, 48128, 48192, 48224, 48288, 48320, 48384, 48416, 48448, 48480, 48544, 48576, 48640, 48672,
    48736, 48768, 48800, 48832, 48896, 48928, 48992, 49024, 49088, 49120, 49152, 49184, 49248, 49280, 49344, 49376,
    49440, 49472, 49504, 49536, 49600, 49632, 49696, 49728, 49792, 49824, 49856, 49888, 49952, 49984, 50048, 50080,
    50144, 50176, 50208, 50240, 50304, 50336, 50400, 50432, 50496, 50528, 50560, 50592, 50656, 50688, 50752, 50784,
    50880, 50912, 50944, 50976, 51040, 51072, 51136, 51168, 51232, 51264, 51328, 51360, 51424, 51456, 51488, 51520,
    51616, 51648, 51680, 51712, 51776, 51808, 51872, 51904, 51968, 52000, 52064, 52096, 52160, 52192, 52224, 52256,
    52384, 52416, 52448, 52480, 52544, 52576, 52640, 52672, 52736, 52768, 52832, 52864, 52928, 52960, 52992, 53024,
    53120, 53152, 53216, 53248, 53312, 53344, 53408, 53440, 53504, 53536, 53600, 53632, 53696, 53728, 53792, 53824,
    53920, 53952, 54016, 54048, 54112, 54144, 54208, 54240, 54304, 54336, 54400, 54432, 54496, 54528, 54592, 54624,
    54688, 54720, 54784, 54816, 54880, 54912, 54976, 55008, 55072, 55104, 55168, 55200, 55264, 55296, 55360, 55392,
    55488, 55520, 55584, 55616, 55680, 55712, 55776, 55808, 55872, 55936, 55968, 56032, 56064, 56128, 56160, 56224,
    56288, 56320, 56384, 56416, 56480, 56512, 56576, 56608, 56672, 56736, 56768, 56832, 56864, 56928, 56960, 57024,
    57120, 57152, 57216, 57248, 57312, 57376, 57408, 57472, 57536, 57568, 57632, 57664, 57728, 57792, 57824, 57888,
    57952, 57984, 58048, 58080, 58144, 58208, 58240, 58304, 58368, 58400, 58464, 58496, 58560, 58624, 58656, 58720,
    58784, 58816, 58880, 58912, 58976, 59040, 59072, 59136, 59200, 59232, 59296, 59328, 59392, 59456, 59488, 59552,
    59648, 59680, 59744, 59776, 59840, 59904, 59936, 60000, 60064, 60128, 60160, 60224, 60288, 60320, 60384, 60416,
    60512, 60544, 60608, 60640, 60704, 60768, 60800, 60864, 60928, 60992, 61024, 61088, 61152, 61184, 61248, 61280,
    61376, 61408, 61472, 61536, 61600, 61632, 61696, 61760, 61824, 61856, 61920, 61984, 62048, 62080, 62144, 62208,
    62272, 62304, 62368, 62432, 62496, 62528, 62592, 62656, 62720, 62752, 62816, 62880, 62944, 62976, 63040, 63104,
    63200, 63232, 63296, 63360, 63424, 63456, 63520, 63584, 63648, 63680, 63744, 63808, 63872, 63904, 63968, 64032,
    64096, 64128, 64192, 64256, 64320, 64352, 64416, 64480, 64544, 64608, 64672, 64704, 64768, 64832, 64896, 64928,
    65024, 65056, 65120, 65184, 65248, 65312, 65376, 65408, 65504, 65536, 65600, 65664, 65728, 65792, 65856, 65888,
    65984, 66016, 66080, 66144, 66208, 66272, 66336, 66368, 66464, 66496, 66560, 66624, 66688, 66752, 66816, 66848,
    66944, 66976, 67040, 67104, 67168, 67232, 67296, 67328, 67424, 67456, 67520, 67584, 67648, 67712, 67776, 67808,
    67904, 67936, 68000, 68064, 68128, 68192, 68256, 68288, 68384, 68448, 68512, 68544, 68640, 68672, 68736, 68800,
    68896, 68928, 68992, 69056, 69120, 69184, 69248, 69280, 69376, 69440, 69504, 69536, 69632, 69664, 69728, 69792,
    69920, 69952, 70016, 70080, 70144, 70208, 70272, 70304, 70400, 70464, 70528, 70560, 70656, 70688, 70752, 70816,
    70912, 70976, 71040, 71104, 71136, 71232, 71264, 71360, 71424, 71488, 71552, 71616, 71648, 71744, 71776, 71872,
    71968, 72032, 72096, 72160, 72192, 72288, 72320, 72416, 72480, 72544, 72608, 72672, 72704, 72800, 72832, 72928,
    72992, 73056, 73120, 73184, 73216, 73312, 73344, 73440, 73504, 73568, 73632, 73696, 73728, 73824, 73856, 73952,
    74080, 74144, 74208, 74272, 74304, 74400, 74432, 74528, 74592, 74656, 74720, 74784, 74816, 74912, 74944, 75040,
    75136, 75200, 75264, 75328, 75360, 75456, 75488, 75584, 75648, 75712, 75776, 75840, 75872, 75968, 76000, 76096,
    76224, 76288, 76352, 76416, 76448, 76544, 76576, 76672, 76736, 76800, 76864, 76928, 77024, 77120, 77152, 77248,
    77344, 77408, 77472, 77536, 77568, 77664, 77696, 77792, 77856, 77920, 77984, 78048, 78144, 78240, 78272, 78368,
    78464, 78528, 78592, 78656, 78688, 78784, 78816, 78912, 78976, 79040, 79104, 79168, 79264, 79360, 79392, 79488,
    79616, 79680, 79744, 79808, 79840, 79936, 79968, 80064, 80128, 80192, 80256, 80320, 80416, 80512, 80544, 80640,
    80768, 80832, 80896, 80960, 80992, 81088, 81120, 81216, 81280, 81344, 81408, 81472, 81568, 81664, 81696, 81792,
    81952, 82016, 82080, 82144, 82176, 82272, 82304, 82400, 82464, 82528, 82592, 82656, 82752, 82848, 82880, 82976
  );
  OPMDetune: array[0..127] of Byte = (
    0, 0, 1, 2, 0, 0, 1, 2, 0, 0, 1, 2, 0, 0, 1, 2,
    0, 1, 2, 2, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3,
    0, 1, 2, 4, 0, 1, 3, 4, 0, 1, 3, 4, 0, 1, 3, 5,
    0, 2, 4, 5, 0, 2, 4, 6, 0, 2, 4, 6, 0, 2, 5, 7,
    0, 2, 5, 8, 0, 3, 6, 8, 0, 3, 6, 9, 0, 3, 7, 10,
    0, 4, 8, 11, 0, 4, 8, 12, 0, 4, 9, 13, 0, 5, 10, 14,
    0, 5, 11, 16, 0, 6, 12, 17, 0, 6, 13, 19, 0, 7, 14, 20,
    0, 8, 16, 22, 0, 8, 16, 22, 0, 8, 16, 22, 0, 8, 16, 22
  );

const
  OperatorMap: array[0..3] of Integer = (0, 2, 1, 3);
  Detune2: array[0..3] of Integer = (0, 384, 500, 608);
  Adjust: array[0..7] of Integer = (-1, -1, -1, -1, 2, 4, 6, 8);
  Steps: array[0..48] of Integer = (16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552);
  Volumes: array[0..15] of Integer = (256, 181, 128, 90, 64, 45, 32, 22, 16, 11, 8, 0, 0, 0, 0, 0);
  Routing: array[0..7, 1..3] of Byte = ((1, 2, 4), (0, 3, 4), (0, 2, 5), (1, 0, 6), (1, 0, 4), (1, 1, 1), (1, 0, 0), (0, 0, 0));
  Carriers: array[0..7] of Byte = (8, 8, 8, 8, 10, 14, 14, 15);

function ASR(Value: Int64; Bits: Integer): Int64; inline;
begin
  Result := Value div (Int64(1) shl Bits);
  if (Value < 0) and (Value and ((Int64(1) shl Bits) - 1) <> 0) then
    Dec(Result);
end;

function Signed14(Value: Cardinal): Integer; inline;
begin
  Result := Integer(Value and $1FFF) - Integer(Value and $2000);
end;

function Bits(Value: Integer): Cardinal; inline;
begin
  Result := Cardinal(Int64(Value) and $FFFFFFFF);
end;

constructor TCPS1Sound.Create(const ROM: TBytes; MasterClock: Integer);
begin
  inherited Create;
  if MasterClock <= 0 then
    raise EArgumentException.Create('Invalid CPS audio clock');

  FMasterClock := MasterClock;
  FROM := ROM;
  Reset;
end;

procedure TCPS1Sound.Reset;
begin
  FillChar(FChannels, SizeOf(FChannels), 0);
  FillChar(FRegs, SizeOf(FRegs), 0);
  FillChar(FVoices, SizeOf(FVoices), 0);
  for var i := 0 to 7 do
  begin
    FMChannelInitialise(FChannels[i]);
    FRegs[$20 + i] := $C0;
  end;
  FPending := -1;
  FPin7 := True;
  FFraction := 0;
  FOutputPhase := 0;
  FOKIPhase := 0;
  FLFO := 0;
  FNoise := 1;
  FNoiseCounter := 0;
  FNoiseState := 0;
  FAMDepth := 0;
  FPMDepth := 0;
  FLeft := 0;
  FRight := 0;
  FOKIOutput := 0;
  FillChar(FKeyMask, SizeOf(FKeyMask), 0);
  FCSM := False;
  BeginFrame;
end;

procedure TCPS1Sound.BeginFrame;
begin
  FCount := 0;
  SetLength(Samples, 2048);
end;

procedure TCPS1Sound.EndFrame;
begin
  SetLength(Samples, FCount);
end;

procedure TCPS1Sound.Frequency(Channel, Modulation: Integer);
begin
  var KC := FRegs[$28 + Channel];
  var Fraction := FRegs[$30 + Channel] shr 2;
  var Key := (KC shr 2) and 31;
  var PMS := (FRegs[$38 + Channel] shr 4) and 7;
  var PM := 0;
  if PMS > 0 then
    if PMS < 6 then
      PM := ASR(Modulation, 6 - PMS)
    else
      PM := Modulation * (1 shl (PMS - 5));
  for var Op := 0 to 3 do
  begin
    var At := Channel + OperatorMap[Op] * 8;
    var Delta := Detune2[FRegs[$C0 + At] shr 6] + PM;
    var Index := ((KC and 15) - ((KC and 15) shr 2)) * 64 + Fraction + Delta;
    var Block: Integer := (KC shr 4) and 7;
    while Index < 0 do
    begin
      Inc(Index, 768);
      Dec(Block);
    end;
    while Index >= 768 do
    begin
      Dec(Index, 768);
      Inc(Block);
    end;
    var Step: Integer;
    if Block < 0 then
      Step := OPMSteps[0] shr 7
    else if Block > 7 then
      Step := OPMSteps[767]
    else
      Step := OPMSteps[Index] shr (7 - Block);
    var DT := (FRegs[$40 + At] shr 4) and 7;
    var Fine := OPMDetune[Key * 4 + (DT and 3)];
    if DT and 4 <> 0 then
      Dec(Step, Fine)
    else
      Inc(Step, Fine);
    var Multiple := (FRegs[$40 + At] and 15) * 2;
    if Multiple = 0 then
      Multiple := 1;
    FChannels[Channel].Operators[Op].Phase.Step := Cardinal((Int64(Step) * Multiple div 2) and $FFFFFFFF);
    FChannels[Channel].Operators[Op].Phase.KeyCode := Key;
  end;
end;

procedure TCPS1Sound.WriteYM(Address, Value: Byte);
begin
  if Address = $19 then
  begin
    if Value and $80 <> 0 then
      FPMDepth := Value and $7F
    else
      FAMDepth := Value and $7F;
  end;
  FRegs[Address] := Value;
  var Ch := Address and 7;
  if Address = $08 then
  begin
    Ch := Value and 7;
    FKeyMask[Ch] := Value;
    for var Op := 0 to 3 do
      FMOperatorSetKeyOn(FChannels[Ch].Operators[Op], Ord(Value and (1 shl (3 + OperatorMap[Op])) <> 0));
  end
  else if (Address >= $20) and (Address <= $27) then
    FMChannelSetFeedbackAndAlgorithm(FChannels[Ch], (Value shr 3) and 7, Value and 7)
  else if Address >= $40 then
  begin
    var Op := OperatorMap[(Address shr 3) and 3];
    case Address and $E0 of
      $60:
        FMOperatorSetTotalLevel(FChannels[Ch].Operators[Op], Value and $7F);
      $80:
        FMOperatorSetKeyScaleAndAttackRate(FChannels[Ch].Operators[Op], Value shr 6, Value and 31);
      $A0:
        begin
          FChannels[Ch].Operators[Op].Rates[1] := Value and 31;
          FChannels[Ch].Operators[Op].AmplitudeModulationOn := Value shr 7;
        end;
      $C0:
        FChannels[Ch].Operators[Op].Rates[2] := Value and 31;
      $E0:
        FMOperatorSetSustainLevelAndReleaseRate(FChannels[Ch].Operators[Op], Value shr 4, Value and 15);
    end;
  end;
  if Address >= $28 then
    Frequency(Ch, 0);
end;

procedure TCPS1Sound.Tick;
begin
  for var i := 0 to 1 do
  begin
    FNoise := (FNoise shl 1) or (((FNoise shr 17) xor (FNoise shr 14) xor 1) and 1);
    if FNoiseCounter >= (FRegs[$0F] and 31 xor 31) then
    begin
      FNoiseCounter := 0;
      FNoiseState := (FNoise shr 17) and 1;
    end
    else
      Inc(FNoiseCounter);
  end;
  FLFO := Cardinal((UInt64(FLFO) + (Cardinal($10 or (FRegs[$18] and 15)) shl (FRegs[$18] shr 4))) and $FFFFFFFF);
  if FRegs[1] and 2 <> 0 then
    FLFO := 0;
  var X := Integer((FLFO shr 22) and 255);
  var AM := 0;
  var PM := 0;
  case FRegs[$1B] and 3 of
    0:
      begin
        AM := X xor 255;
        PM := X;
      end;
    1:
      begin
        if X and 128 <> 0 then
          AM := 0
        else
          AM := 255;
        PM := AM xor 128;
      end;
    2:
      begin
        if X and 128 <> 0 then
          AM := (X * 2) and 255
        else
          AM := ((X xor 255) * 2) and 255;
        if X and 64 <> 0 then
          PM := AM
        else
          PM := AM xor 255;
      end;
    3:
      begin
        AM := (FNoise shr 17) and 255;
        PM := AM;
      end;
  end;
  if PM >= 128 then
    Dec(PM, 256);
  PM := ASR(Int64(PM) * FPMDepth, 7);
  AM := AM * FAMDepth div 128;
  FLeft := 0;
  FRight := 0;
  for var Ch := 0 to 7 do
  begin
    Frequency(Ch, PM);
    var AMS := FRegs[$38 + Ch] and 3;
    var Modulation := 0;
    if AMS > 0 then
      Modulation := AM shl (AMS - 1);
    var Feedback := 0;
    var Divisor := FChannels[Ch].FeedbackDivisor;
    if Divisor <> 9 then
      Feedback := ASR(Signed14(FChannels[Ch].Operator1PreviousSamples[0]) +
        Signed14(FChannels[Ch].Operator1PreviousSamples[1]), Divisor);
    var Values: array[0..3] of Integer;
    Values[0] := Signed14(FMOperatorProcess(FChannels[Ch].Operators[0], Modulation, 0, Bits(Feedback)));
    var Algorithm := FChannels[Ch].Algorithm;
    for var Op := 1 to 3 do
    begin
      var M := 0;
      for var Source := 0 to Op - 1 do
        if Routing[Algorithm, Op] and (1 shl Source) <> 0 then
          Inc(M, Values[Source]);
      Values[Op] := Signed14(FMOperatorProcess(FChannels[Ch].Operators[Op], Modulation, 0, Bits(M)));
    end;
    if (Ch = 7) and (FRegs[$0F] and $80 <> 0) then
    begin
      var Att := GetEnvelopeAttenuation(FChannels[7].Operators[3], Modulation, 0);
      Values[3] := Integer($3FF - Min(Att, Cardinal($3FF))) * 2;
      if FNoiseState <> 0 then
        Values[3] := -Values[3];
    end;
    FChannels[Ch].Operator1PreviousSamples[1] := FChannels[Ch].Operator1PreviousSamples[0];
    FChannels[Ch].Operator1PreviousSamples[0] := Word(Values[0] and $FFFF);
    var Sample := 0;
    for var Op := 0 to 3 do
      if Carriers[Algorithm] and (1 shl Op) <> 0 then
        Inc(Sample, Values[Op]);
    if FRegs[$20 + Ch] and $40 <> 0 then
      Inc(FLeft, Sample);
    if FRegs[$20 + Ch] and $80 <> 0 then
      Inc(FRight, Sample);
  end;
  if FCSM then
  begin
    for var Ch := 0 to 7 do
      for var Op := 0 to 3 do
        FMOperatorSetKeyOn(FChannels[Ch].Operators[Op], Ord(FKeyMask[Ch] and (1 shl (3 + OperatorMap[Op])) <> 0));
    FCSM := False;
  end;
end;

procedure TCPS1Sound.CSM;
begin
  for var Ch := 0 to 7 do
    for var Op := 0 to 3 do
      FMOperatorSetKeyOn(FChannels[Ch].Operators[Op], 1);
  FCSM := True;
end;

procedure TCPS1Sound.SetPin7(Value: Boolean);
begin
  FPin7 := Value;
end;

procedure TCPS1Sound.SetSampleBank(Start, Size, Offset: Integer);
begin
  if (Start < 0) or (Size < 1) or (Int64(Start) + Size > $40000) or (Offset < 0) or
    (Int64(Offset) + Size > Length(FROM)) then
    raise EArgumentException.Create('Invalid OKI ROM bank');

  FBankStart := Start;
  FBankSize := Size;
  FBankOffset := Offset;
end;

function TCPS1Sound.SampleByte(Address: Integer): Byte;
begin
  if (FBankSize <> 0) and (Address >= FBankStart) and (Address < FBankStart + FBankSize) then
    Address := FBankOffset + Address - FBankStart;
  if (Address < 0) or (Address >= Length(FROM)) then
    Exit($FF);

  Result := FROM[Address];
end;

function TCPS1Sound.OKIStatus: Byte;
begin
  Result := $F0;
  for var i := 0 to 3 do
    if FVoices[i].Playing then
      Result := Result or (1 shl i);
end;

procedure TCPS1Sound.WriteOKI(Value: Byte);
begin
  if FPending >= 0 then
  begin
    var At := FPending * 8;
    if At + 5 < Length(FROM) then
    begin
      var Start := ((Integer(SampleByte(At)) shl 16) or (Integer(SampleByte(At + 1)) shl 8) or SampleByte(At + 2)) and $3FFFF;
      var Ending := ((Integer(SampleByte(At + 3)) shl 16) or (Integer(SampleByte(At + 4)) shl 8) or SampleByte(At + 5)) and $3FFFF;
      for var i := 0 to 3 do
        if (Value and (1 shl (4 + i)) <> 0) and not FVoices[i].Playing and (Start < Ending) then
        begin
          FVoices[i] := Default(TOKIVoice);
          FVoices[i].Playing := True;
          FVoices[i].Position := Start * 2;
          FVoices[i].Ending := (Ending + 1) * 2;
          FVoices[i].Signal := -2;
          FVoices[i].Volume := Volumes[Value and 15];
        end;
    end;
    FPending := -1;
  end
  else if Value and $80 <> 0 then
    FPending := Value and $7F
  else
    for var i := 0 to 3 do
      if Value and (1 shl (3 + i)) <> 0 then
      begin
        FVoices[i].Playing := False;
        FVoices[i].Output := 0;
      end;
end;

procedure TCPS1Sound.OKITick;
begin
  FOKIOutput := 0;
  for var i := 0 to 3 do
  begin
    var V: ^TOKIVoice;
    V := @FVoices[i];
    if not V.Playing then
      Continue;

    if (V.Position >= V.Ending) or (V.Position div 2 >= Length(FROM)) then
    begin
      V.Playing := False;
      V.Output := 0;
      Continue;
    end;

    var N := (SampleByte(V.Position div 2) shr ((1 - (V.Position and 1)) * 4)) and 15;
    var Step := Steps[V.Step];
    var Delta := Step div 8;
    if N and 1 <> 0 then
      Inc(Delta, Step div 4);
    if N and 2 <> 0 then
      Inc(Delta, Step div 2);
    if N and 4 <> 0 then
      Inc(Delta, Step);
    if N and 8 <> 0 then
      Delta := -Delta;
    V.Signal := EnsureRange(V.Signal + Delta, -2048, 2047);
    V.Step := EnsureRange(V.Step + Adjust[N and 7], 0, 48);
    V.Output := V.Signal * V.Volume div 16;
    Inc(V.Position);
    Inc(FOKIOutput, V.Output);
  end;
end;

procedure TCPS1Sound.Advance(Cycles: Integer);
begin
  while Cycles > 0 do
  begin
    var Divider := 132;
    if not FPin7 then
      Divider := 165;
    var N := Min(Int64(Cycles), Min(64 - FFraction, Min((Int64(FMasterClock) * Divider - FOKIPhase + 999999) div 1000000,
          (FMasterClock - FOutputPhase + 44099) div 44100)));
    if N <= 0 then
      N := 1;
    Dec(Cycles, N);
    Inc(FFraction, N);
    Inc(FOKIPhase, N * 1000000);
    Inc(FOutputPhase, N * 44100);
    if FFraction >= 64 then
    begin
      Dec(FFraction, 64);
      Tick;
    end;
    if FOKIPhase >= Int64(FMasterClock) * Divider then
    begin
      FOKIPhase := FOKIPhase mod (Int64(FMasterClock) * Divider);
      OKITick;
    end;
    if FOutputPhase >= FMasterClock then
    begin
      Dec(FOutputPhase, FMasterClock);
      if Length(Samples) < FCount + 2 then
        SetLength(Samples, FCount + 2048);
      Samples[FCount] := EnsureRange((FLeft + FOKIOutput * 3 div 10) div 2, -32768, 32767);
      Samples[FCount + 1] := EnsureRange((FRight + FOKIOutput * 3 div 10) div 2, -32768, 32767);
      Inc(FCount, 2);
    end;
  end;
end;

procedure TCPS1Sound.SerializeState(State: TStateArchive);
begin
  State.Field(FBankStart, SizeOf(FBankStart));
  State.Field(FBankSize, SizeOf(FBankSize));
  State.Field(FBankOffset, SizeOf(FBankOffset));
  if (FBankStart < 0) or (FBankSize < 0) or (Int64(FBankStart) + FBankSize > $40000) or
    (FBankOffset < 0) or (Int64(FBankOffset) + FBankSize > Length(FROM)) then
    raise EArgumentException.Create('Invalid OKI bank state');

  State.Field(FChannels, SizeOf(FChannels));
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FVoices, SizeOf(FVoices));
  State.Field(FPending, SizeOf(FPending));
  State.Field(FPin7, SizeOf(FPin7));
  State.Field(FFraction, SizeOf(FFraction));
  State.Field(FOutputPhase, SizeOf(FOutputPhase));
  State.Field(FOKIPhase, SizeOf(FOKIPhase));
  State.Field(FLFO, SizeOf(FLFO));
  State.Field(FNoise, SizeOf(FNoise));
  State.Field(FNoiseCounter, SizeOf(FNoiseCounter));
  State.Field(FNoiseState, SizeOf(FNoiseState));
  State.Field(FAMDepth, SizeOf(FAMDepth));
  State.Field(FPMDepth, SizeOf(FPMDepth));
  State.Field(FLeft, SizeOf(FLeft));
  State.Field(FRight, SizeOf(FRight));
  State.Field(FOKIOutput, SizeOf(FOKIOutput));
  State.Field(FKeyMask, SizeOf(FKeyMask));
  State.Field(FCSM, SizeOf(FCSM));
  if (FFraction < 0) or (FFraction >= 64) or (FOutputPhase < 0) or (FOutputPhase >= FMasterClock) or
    (FOKIPhase < 0) or (FOKIPhase >= Int64(FMasterClock) * 165) or (FPending < -1) or (FPending > 127) then
    raise EReadError.Create('Invalid CPS1 audio state');

  for var V in FVoices do
    if (V.Step < 0) or (V.Step > 48) then
      raise EReadError.Create('Invalid OKI state');

  for var Ch in FChannels do
    if (Ch.Algorithm > 7) or (Ch.FeedbackDivisor > 9) then
      raise EReadError.Create('Invalid OPM state');

  if State.Loading then
    BeginFrame;
end;

end.

