unit SG1000.Cassette;

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots;

type
  TSGCassette = class
  private
    FPCM: TArray<SmallInt>;
    FRate, FPosition, FPhase: Integer;
    FPlaying, FRecording, FOutput: Boolean;
  public
    constructor Create;
    procedure LoadWAV(const Data: TBytes);
    function SaveWAV: TBytes;
    procedure Rewind;
    procedure Play;
    procedure RecordTape;
    procedure Stop;
    procedure SetOutput(Value: Boolean);
    function Input: Boolean;
    procedure Advance(Cycles, CPUClock: Integer);
    procedure SerializeState(State: TStateArchive);
    property Position: Integer read FPosition;
    property SampleRate: Integer read FRate;
    property Playing: Boolean read FPlaying;
    property Recording: Boolean read FRecording;
  end;

implementation

constructor TSGCassette.Create;
begin
  inherited;
  FRate := 44100;
end;

procedure TSGCassette.LoadWAV(const Data: TBytes);

  function UInt16(Offset: Integer): Integer;
  begin
    Result := Integer(Data[Offset]) or (Integer(Data[Offset + 1]) shl 8);
  end;

  function UInt32(Offset: Integer): Cardinal;
  begin
    Result := Cardinal(UInt16(Offset)) or (Cardinal(UInt16(Offset + 2)) shl 16);
  end;

  function Four(Offset: Integer; const Text: AnsiString): Boolean;
  begin
    Result := Offset + 4 <= Length(Data);
    if Result then
      for var i := 0 to 3 do
        if Data[Offset + i] <> Ord(Text[i + 1]) then
          Exit(False);
  end;

begin
  if (Length(Data) < 44) or not Four(0, 'RIFF') or not Four(8, 'WAVE') then
    raise EReadError.Create('Cassette input must be a PCM WAV file');

  var Channels := 0;
  var Bits := 0;
  var Rate := 0;
  var Audio := -1;
  var AudioSize := 0;
  var Offset := 12;
  while Offset + 8 <= Length(Data) do
  begin
    var Size := UInt32(Offset + 4);
    if UInt64(Offset) + 8 + Size > UInt64(Length(Data)) then
      raise EReadError.Create('Truncated WAV chunk');

    if Four(Offset, 'fmt ') then
    begin
      if (Size < 16) or (UInt16(Offset + 8) <> 1) then
        raise EReadError.Create('WAV cassette must use integer PCM');

      Channels := UInt16(Offset + 10);
      Rate := Integer(UInt32(Offset + 12));
      Bits := UInt16(Offset + 22);
    end;
    if Four(Offset, 'data') then
    begin
      Audio := Offset + 8;
      AudioSize := Integer(Size);
    end;
    Offset := Offset + 8 + Integer(Size) + Integer(Size and 1);
  end;
  if not (Channels in [1, 2]) or not (Bits in [8, 16]) or (Rate < 8000) or (Rate > 192000) or (Audio < 0) then
    raise EReadError.Create('Unsupported cassette WAV geometry');

  var Stride := Channels * Bits div 8;
  if AudioSize mod Stride <> 0 then
    raise EReadError.Create('Truncated WAV sample');

  var PCM: TArray<SmallInt>;
  SetLength(PCM, AudioSize div Stride);
  for var i := 0 to High(PCM) do
  begin
    var Sum := 0;
    for var C := 0 to Channels - 1 do
      if Bits = 8 then
        Inc(Sum, (Integer(Data[Audio + i * Stride + C]) - 128) * 256)
      else
      begin
        var Value := UInt16(Audio + i * Stride + C * 2);
        if Value >= $8000 then
          Dec(Value, $10000);
        Inc(Sum, Value);
      end;
    PCM[i] := Sum div Channels;
  end;
  FPCM := PCM;
  FRate := Rate;
  Rewind;
  FPlaying := False;
  FRecording := False;
end;

function TSGCassette.SaveWAV: TBytes;

  procedure Put16(Offset, Value: Integer);
  begin
    Result[Offset] := Value and $FF;
    Result[Offset + 1] := (Value shr 8) and $FF;
  end;

  procedure Put32(Offset, Value: Integer);
  begin
    Put16(Offset, Value and $FFFF);
    Put16(Offset + 2, (Value shr 16) and $FFFF);
  end;

  procedure Four(Offset: Integer; const Text: AnsiString);
  begin
    for var i := 0 to 3 do
      Result[Offset + i] := Ord(Text[i + 1]);
  end;

begin
  SetLength(Result, 44 + Length(FPCM) * 2);
  Four(0, 'RIFF');
  Put32(4, Length(Result) - 8);
  Four(8, 'WAVE');
  Four(12, 'fmt ');
  Put32(16, 16);
  Put16(20, 1);
  Put16(22, 1);
  Put32(24, FRate);
  Put32(28, FRate * 2);
  Put16(32, 2);
  Put16(34, 16);
  Four(36, 'data');
  Put32(40, Length(FPCM) * 2);
  for var i := 0 to High(FPCM) do
    Put16(44 + i * 2, Integer(FPCM[i]) and $FFFF);
end;

procedure TSGCassette.Rewind;
begin
  FPosition := 0;
  FPhase := 0;
end;

procedure TSGCassette.Play;
begin
  FPlaying := True;
  FRecording := False;
end;

procedure TSGCassette.RecordTape;
begin
  FPCM := nil;
  Rewind;
  FRate := 44100;
  FPlaying := False;
  FRecording := True;
end;

procedure TSGCassette.Stop;
begin
  FPlaying := False;
  FRecording := False;
end;

procedure TSGCassette.SetOutput(Value: Boolean);
begin
  FOutput := Value;
end;

function TSGCassette.Input: Boolean;
begin
  Result := FPlaying and (FPosition < Length(FPCM)) and (FPCM[FPosition] > 0);
end;

procedure TSGCassette.Advance(Cycles, CPUClock: Integer);
begin
  if not (FPlaying or FRecording) then
    Exit;

  if (Cycles < 0) or (Cycles > 65535) or (CPUClock < 1000000) then
    raise EArgumentOutOfRangeException.Create('Cassette clocks');

  var Phase := Int64(FPhase) + Int64(Cycles) * FRate;
  var Count := Integer(Phase div CPUClock);
  FPhase := Integer(Phase mod CPUClock);
  if FRecording then
  begin
    var Offset := Length(FPCM);
    if Offset + Count > 44100 * 60 * 60 then
      raise EWriteError.Create('Cassette recording exceeds one hour');

    SetLength(FPCM, Offset + Count);
    for var i := Offset to High(FPCM) do
      if FOutput then
        FPCM[i] := 24576
      else
        FPCM[i] := -24576;
    FPosition := Length(FPCM);
  end
  else
  begin
    FPosition := System.Math.Min(FPosition + Count, Length(FPCM));
    if FPosition = Length(FPCM) then
      FPlaying := False;
  end;
end;

procedure TSGCassette.SerializeState(State: TStateArchive);
begin
  var Size := Length(FPCM);
  State.Field(Size, SizeOf(Size));
  if (Size < 0) or (Size > 44100 * 60 * 60) then
    raise EReadError.Create('Invalid cassette snapshot size');

  if State.Loading then
    SetLength(FPCM, Size);
  if Size > 0 then
    State.Field(FPCM[0], Size * SizeOf(SmallInt));
  State.Field(FRate, SizeOf(FRate));
  State.Field(FPosition, SizeOf(FPosition));
  State.Field(FPhase, SizeOf(FPhase));
  State.Field(FPlaying, SizeOf(FPlaying));
  State.Field(FRecording, SizeOf(FRecording));
  State.Field(FOutput, SizeOf(FOutput));
  if State.Loading and ((FRate < 8000) or (FRate > 192000) or (FPosition < 0) or
    (FPosition > Size) or (FPhase < 0) or (FPhase >= 4000000)) then
    raise EReadError.Create('Invalid cassette snapshot position');
end;

end.

