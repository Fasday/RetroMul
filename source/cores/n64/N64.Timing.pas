unit N64.Timing;
{$Q+}{$R+}

interface

uses System.SysUtils, System.Classes, Core.Snapshots;

type
  TN64EventKind = (VIHalfLine, OutputSample, AIConsume, SPTransfer,
    PITransfer, SITransfer, RSPClock, DPInterrupt);
  TN64Event = record
    Due, Sequence: UInt64;
    Kind: TN64EventKind;
  end;
  TN64Timeline = class
  private
    FNow, FSequence: UInt64;
    FCount: Integer;
    FEvents: array[0..31] of TN64Event;
  public
    procedure Reset;
    procedure Schedule(Kind: TN64EventKind; Delay: UInt64);
    procedure Cancel(Kind: TN64EventKind);
    function Pending(Kind: TN64EventKind): Boolean;
    function Count(Kind: TN64EventKind): Integer;
    function NextDue: UInt64;
    procedure AdvanceTo(Tick: UInt64);
    function Pop(out Event: TN64Event): Boolean;
    procedure SerializeState(State: TStateArchive);
    property Now: UInt64 read FNow;
  end;

implementation

procedure TN64Timeline.Reset;
begin
  FNow := 0; FSequence := 0; FCount := 0;
  for var I := 0 to High(FEvents) do FEvents[I] := Default(TN64Event);
end;

procedure TN64Timeline.Schedule(Kind: TN64EventKind; Delay: UInt64);
begin
  if (Delay >= High(UInt64) - FNow) or (FSequence = High(UInt64)) then
    raise ERangeError.Create('N64 guest timeline exceeds representable time');
  if FCount = Length(FEvents) then raise ERangeError.Create('N64 event queue is full');
  var E := Default(TN64Event);
  E.Due := FNow + Delay; E.Sequence := FSequence; E.Kind := Kind;
  Inc(FSequence);
  var I := FCount;
  while (I > 0) and (FEvents[I - 1].Due > E.Due) do
  begin FEvents[I] := FEvents[I - 1]; Dec(I) end;
  FEvents[I] := E; Inc(FCount);
end;

procedure TN64Timeline.Cancel(Kind: TN64EventKind);
begin
  var N := 0;
  for var I := 0 to FCount - 1 do
    if FEvents[I].Kind <> Kind then
    begin FEvents[N] := FEvents[I]; Inc(N) end;
  for var I := N to FCount - 1 do FEvents[I] := Default(TN64Event);
  FCount := N;
end;

function TN64Timeline.Pending(Kind: TN64EventKind): Boolean;
begin
  for var I := 0 to FCount - 1 do if FEvents[I].Kind = Kind then Exit(True);
  Result := False;
end;

function TN64Timeline.Count(Kind: TN64EventKind): Integer;
begin
  Result := 0;
  for var I := 0 to FCount - 1 do
    if FEvents[I].Kind = Kind then Inc(Result);
end;

function TN64Timeline.NextDue: UInt64;
begin
  if FCount = 0 then Exit(High(UInt64));
  Result := FEvents[0].Due;
end;

procedure TN64Timeline.AdvanceTo(Tick: UInt64);
begin
  if Tick < FNow then raise ERangeError.Create('N64 timeline cannot run backwards');
  FNow := Tick;
end;

function TN64Timeline.Pop(out Event: TN64Event): Boolean;
begin
  Result := (FCount > 0) and (FEvents[0].Due <= FNow);
  if not Result then begin Event := Default(TN64Event); Exit end;
  Event := FEvents[0]; Dec(FCount);
  for var I := 0 to FCount - 1 do FEvents[I] := FEvents[I + 1];
  FEvents[FCount] := Default(TN64Event);
end;

procedure TN64Timeline.SerializeState(State: TStateArchive);
begin
  State.Field(FNow, SizeOf(FNow)); State.Field(FSequence, SizeOf(FSequence));
  State.Field(FCount, SizeOf(FCount)); State.Field(FEvents, SizeOf(FEvents));
  if State.Loading then
  begin
    if (FCount < 0) or (FCount > Length(FEvents)) then
      raise EReadError.Create('Invalid N64 event count');
    for var I := 0 to FCount - 1 do
    begin
      var KindValue: Cardinal := 0;
      Move(FEvents[I].Kind, KindValue, SizeOf(FEvents[I].Kind));
      if (KindValue > Ord(High(TN64EventKind))) or
        (FEvents[I].Due < FNow) or (FEvents[I].Due = High(UInt64)) or
        (FEvents[I].Sequence >= FSequence) then
        raise EReadError.Create('Invalid N64 event');
      for var J := 0 to I - 1 do
        if FEvents[I].Sequence = FEvents[J].Sequence then
          raise EReadError.Create('Duplicate N64 event sequence');
      if I > 0 then
        if (FEvents[I].Due < FEvents[I - 1].Due) or
          ((FEvents[I].Due = FEvents[I - 1].Due) and
          (FEvents[I].Sequence <= FEvents[I - 1].Sequence)) then
          raise EReadError.Create('Invalid N64 event order');
    end;
  end;
end;

end.
