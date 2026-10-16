unit Saturn.Audio;

interface

uses
  System.SysUtils;

type
  // Host-side waveform-similarity overlap/add. Native PCM and emulated device
  // clocks remain unchanged. All buffered data is discarded on discontinuity.
  TSaturnAudioStretch = class
  private
    FInput: TArray<SmallInt>;
    FTail: array[0..511] of SmallInt;
    FFrames: Integer;
    FPosition: Double;
    FStarted: Boolean;
    function BestMatch(Center: Integer): Integer;
    procedure Emit(Start: Integer; var Output: TArray<SmallInt>);
  public
    procedure Reset;
    function Process(const Input: array of SmallInt; Frames: Integer; Ratio: Double; out Output: TArray<SmallInt>): Integer;
    property BufferedFrames: Integer read FFrames;
  end;

implementation

uses
  System.Math;

const
  WindowFrames = 1024;
  OverlapFrames = 256;
  HopFrames = 768;
  SearchFrames = 256;

procedure TSaturnAudioStretch.Reset;
begin
  FInput := nil;
  FFrames := 0;
  FPosition := 0;
  FStarted := False;
  FillChar(FTail, SizeOf(FTail), 0);
end;

function TSaturnAudioStretch.BestMatch(Center: Integer): Integer;

  function Score(Start: Integer): Double;
  begin
    var Dot: Int64 := 0;
    var Energy: Int64 := 0;
    for var i := 0 to OverlapFrames * 2 - 1 do
    begin
      var V: Integer := FInput[Start * 2 + i];
      Inc(Dot, Int64(V) * FTail[i]);
      Inc(Energy, Int64(V) * V);
    end;
    if Energy = 0 then
      Exit(0);

    Result := Dot / Sqrt(Energy);
  end;

begin
  Result := Center;
  var Best := Score(Center);
  var Low := Max(0, Center - SearchFrames);
  var High := Min(FFrames - WindowFrames, Center + SearchFrames);
  var At := Low;
  while At <= High do
  begin
    var V := Score(At);
    if V > Best then
    begin
      Best := V;
      Result := At;
    end;
    Inc(At, 4);
  end;
  var FineLow := Max(Low, Result - 3);
  var FineHigh := Min(High, Result + 3);
  for At := FineLow to FineHigh do
  begin
    var V := Score(At);
    if V > Best then
    begin
      Best := V;
      Result := At;
    end;
  end;
end;

procedure TSaturnAudioStretch.Emit(Start: Integer; var Output: TArray<SmallInt>);
begin
  var At := Length(Output);
  SetLength(Output, At + HopFrames * 2);
  if FStarted then
  begin
    for var i := 0 to OverlapFrames - 1 do
      for var Ch := 0 to 1 do
        Output[At + i * 2 + Ch] := (Integer(FTail[i * 2 + Ch]) * (OverlapFrames - i) +
          Integer(FInput[(Start + i) * 2 + Ch]) * i) div OverlapFrames;
    Move(FInput[(Start + OverlapFrames) * 2], Output[At + OverlapFrames * 2], (HopFrames - OverlapFrames) * 4);
  end
  else
    Move(FInput[Start * 2], Output[At], HopFrames * 4);
  Move(FInput[(Start + HopFrames) * 2], FTail[0], OverlapFrames * 4);
end;

function TSaturnAudioStretch.Process(const Input: array of SmallInt; Frames: Integer; Ratio: Double; out Output: TArray<SmallInt>): Integer;
begin
  if (Frames < 0) or (Frames > 65536) or (Frames > Length(Input) div 2) then
    raise EArgumentOutOfRangeException.Create('Invalid Saturn stretch PCM count');

  if IsNan(Ratio) or IsInfinite(Ratio) or (Ratio < 0.5) or (Ratio > 2) then
    raise EArgumentOutOfRangeException.Create('Invalid Saturn stretch ratio');

  Output := nil;
  SetLength(FInput, (FFrames + Frames) * 2);
  if Frames > 0 then
    Move(Input[0], FInput[FFrames * 2], Frames * 4);
  Inc(FFrames, Frames);
  if not FStarted and (FFrames >= WindowFrames) then
  begin
    Emit(0, Output);
    FStarted := True;
    FPosition := HopFrames / Ratio;
  end;
  while FStarted and (Trunc(FPosition) + SearchFrames + WindowFrames <= FFrames) do
  begin
    Emit(BestMatch(Trunc(FPosition)), Output);
    FPosition := FPosition + HopFrames / Ratio;
  end;
  if FStarted then
  begin
    var Drop := Min(FFrames, Max(0, Trunc(FPosition) - SearchFrames));
    if Drop > 0 then
    begin
      Dec(FFrames, Drop);
      if FFrames > 0 then
        Move(FInput[Drop * 2], FInput[0], FFrames * 4);
      FPosition := FPosition - Drop;
      SetLength(FInput, FFrames * 2);
    end;
  end;
  Result := Length(Output) div 2;
end;

end.

