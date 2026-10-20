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
  TN64EventArray = array[0..31] of TN64Event;
  TN64Timeline = class
  private
    FNow, FSequence: UInt64;
    FCount: Integer;
    // Stored latest-first, so the next queued event is FEvents[FCount - 1].
    // Equal due times keep scheduling order: the earlier sequence pops first.
    // Snapshots use the earliest-first layout (see SerializeState).
    FEvents: TN64EventArray;
    // The RSP clock is rescheduled every one or two PClocks; it lives in a
    // dedicated slot ordered against FEvents by (Due, Sequence).
    FFast: TN64Event;
    FFastActive: Boolean;
    // Queued events per kind, including the fast slot.
    FKindCount: array[TN64EventKind] of Integer;
    // NextDue, kept up to date by every change of the queue or the fast slot.
    FNextDue: UInt64;
    class procedure RaiseBackwards; static;
    procedure CountKinds;
    function FastFirst: Boolean; inline;
    procedure UpdateNext; inline;
  public
    procedure Reset;
    procedure Schedule(Kind: TN64EventKind; Delay: UInt64);
    procedure Cancel(Kind: TN64EventKind);
    function Pending(Kind: TN64EventKind): Boolean; inline;
    function Count(Kind: TN64EventKind): Integer; inline;
    function NextDue: UInt64; inline;
    procedure AdvanceTo(Tick: UInt64); inline;
    function Pop(out Event: TN64Event): Boolean;
    procedure SerializeState(State: TStateArchive);
    property Now: UInt64 read FNow;
  end;

implementation

procedure TN64Timeline.UpdateNext;
begin
  var Next := High(UInt64);
  if FCount > 0 then
    Next := FEvents[FCount - 1].Due;
  if FFastActive and (FFast.Due < Next) then
    Next := FFast.Due;
  FNextDue := Next;
end;

procedure TN64Timeline.Reset;
begin
  FNow := 0; FSequence := 0; FCount := 0;
  for var I := 0 to High(FEvents) do FEvents[I] := Default(TN64Event);
  FFast := Default(TN64Event); FFastActive := False;
  CountKinds;
  UpdateNext;
end;

procedure TN64Timeline.CountKinds;
begin
  for var Kind := Low(TN64EventKind) to High(TN64EventKind) do FKindCount[Kind] := 0;
  for var I := 0 to FCount - 1 do Inc(FKindCount[FEvents[I].Kind]);
  if FFastActive then Inc(FKindCount[FFast.Kind]);
end;

function TN64Timeline.FastFirst: Boolean;
begin
  // True when the fast slot is the earliest queued event.
  Result := FFastActive and ((FCount = 0) or (FFast.Due < FEvents[FCount - 1].Due) or
    ((FFast.Due = FEvents[FCount - 1].Due) and (FFast.Sequence < FEvents[FCount - 1].Sequence)));
end;

procedure TN64Timeline.Schedule(Kind: TN64EventKind; Delay: UInt64);
begin
  if (Delay >= High(UInt64) - FNow) or (FSequence = High(UInt64)) then
    raise ERangeError.Create('N64 guest timeline exceeds representable time');
  if FCount + Ord(FFastActive) = Length(FEvents) then raise ERangeError.Create('N64 event queue is full');
  Inc(FKindCount[Kind]);
  if (Kind = TN64EventKind.RSPClock) and FFastActive then
    raise EInvalidOpException.Create('N64 RSP clock scheduled twice');
  if (Kind = TN64EventKind.RSPClock) and not FFastActive then
  begin
    // An inactive slot is all zero (Reset/Pop/Cancel), padding included.
    FFast.Due := FNow + Delay; FFast.Sequence := FSequence; FFast.Kind := Kind;
    FFastActive := True;
    Inc(FSequence);
    UpdateNext;
    Exit;
  end;
  var E := Default(TN64Event);
  E.Due := FNow + Delay; E.Sequence := FSequence; E.Kind := Kind;
  Inc(FSequence);
  // The new event has the largest sequence, so it pops after every queued
  // event due at the same time and goes below them in this latest-first array.
  var I := FCount;
  while (I > 0) and (FEvents[I - 1].Due <= E.Due) do
  begin FEvents[I] := FEvents[I - 1]; Dec(I) end;
  FEvents[I] := E; Inc(FCount);
  UpdateNext;
end;

procedure TN64Timeline.Cancel(Kind: TN64EventKind);
begin
  if FKindCount[Kind] = 0 then Exit;
  if FFastActive and (FFast.Kind = Kind) then
  begin
    FFast := Default(TN64Event); FFastActive := False;
  end;
  var N := 0;
  for var I := 0 to FCount - 1 do
    if FEvents[I].Kind <> Kind then
    begin FEvents[N] := FEvents[I]; Inc(N) end;
  for var I := N to FCount - 1 do FEvents[I] := Default(TN64Event);
  FCount := N;
  FKindCount[Kind] := 0;
  UpdateNext;
end;

function TN64Timeline.Pending(Kind: TN64EventKind): Boolean;
begin
  Result := FKindCount[Kind] > 0;
end;

function TN64Timeline.Count(Kind: TN64EventKind): Integer;
begin
  Result := FKindCount[Kind];
end;

function TN64Timeline.NextDue: UInt64;
begin
  Result := FNextDue;
end;

class procedure TN64Timeline.RaiseBackwards;
begin
  raise ERangeError.Create('N64 timeline cannot run backwards');
end;

procedure TN64Timeline.AdvanceTo(Tick: UInt64);
begin
  if Tick < FNow then RaiseBackwards;
  FNow := Tick;
end;

function TN64Timeline.Pop(out Event: TN64Event): Boolean;
begin
  if FastFirst then
  begin
    Result := FFast.Due <= FNow;
    if not Result then begin Event := Default(TN64Event); Exit end;
    Event := FFast;
    FFast.Due := 0; FFast.Sequence := 0; FFast.Kind := Low(TN64EventKind);
    FFastActive := False;
  end
  else
  begin
    Result := (FCount > 0) and (FEvents[FCount - 1].Due <= FNow);
    if not Result then begin Event := Default(TN64Event); Exit end;
    Dec(FCount);
    Event := FEvents[FCount];
    FEvents[FCount] := Default(TN64Event);
  end;
  Dec(FKindCount[Event.Kind]);
  UpdateNext;
end;

procedure TN64Timeline.SerializeState(State: TStateArchive);
begin
  var Ordered: TN64EventArray;
  for var I := 0 to High(Ordered) do Ordered[I] := Default(TN64Event);
  var Total := FCount;
  if not State.Loading then
  begin
    // Earliest first; the fast slot takes its (Due, Sequence) position.
    var N := 0;
    var FastPending := FFastActive;
    for var I := FCount - 1 downto 0 do
    begin
      if FastPending and ((FFast.Due < FEvents[I].Due) or
        ((FFast.Due = FEvents[I].Due) and (FFast.Sequence < FEvents[I].Sequence))) then
      begin
        Ordered[N] := FFast; Inc(N); FastPending := False;
      end;
      Ordered[N] := FEvents[I]; Inc(N);
    end;
    if FastPending then begin Ordered[N] := FFast; Inc(N) end;
    Total := N;
  end;
  State.Field(FNow, SizeOf(FNow)); State.Field(FSequence, SizeOf(FSequence));
  State.Field(Total, SizeOf(Total)); State.Field(Ordered, SizeOf(Ordered));
  if State.Loading then
  begin
    if (Total < 0) or (Total > Length(Ordered)) then
      raise EReadError.Create('Invalid N64 event count');
    for var I := 0 to Total - 1 do
    begin
      var KindValue: Cardinal := 0;
      Move(Ordered[I].Kind, KindValue, SizeOf(Ordered[I].Kind));
      if (KindValue > Cardinal(Ord(High(TN64EventKind)))) or
        (Ordered[I].Due < FNow) or (Ordered[I].Due = High(UInt64)) or
        (Ordered[I].Sequence >= FSequence) then
        raise EReadError.Create('Invalid N64 event');
      for var J := 0 to I - 1 do
        if Ordered[I].Sequence = Ordered[J].Sequence then
          raise EReadError.Create('Duplicate N64 event sequence');
      if I > 0 then
        if (Ordered[I].Due < Ordered[I - 1].Due) or
          ((Ordered[I].Due = Ordered[I - 1].Due) and
          (Ordered[I].Sequence <= Ordered[I - 1].Sequence)) then
          raise EReadError.Create('Invalid N64 event order');
    end;
    // Restored events all go to the queue; the next RSP clock refills the slot.
    FCount := Total;
    for var I := 0 to High(FEvents) do FEvents[I] := Default(TN64Event);
    for var I := 0 to FCount - 1 do FEvents[I] := Ordered[FCount - 1 - I];
    FFast := Default(TN64Event); FFastActive := False;
    CountKinds;
    UpdateNext;
  end;
end;

end.
