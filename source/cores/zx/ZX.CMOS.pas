unit ZX.CMOS;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots;

type
  // MC146818/DS12887-compatible Gluk clock. Time advances on the 3.5 MHz bus.
  TZXCMOS = class
  private
    FRegisters: array[0..127] of Byte;
    FIndex: Byte;
    FDate: TDateTime;
    FPhase, FOscillator, FDivider, FWeekday: Integer;
    function Encode(Value: Integer): Byte;
    function Decode(Value: Byte): Integer;
    procedure UpdateRegisters;
    procedure CommitRegisters;
    procedure UpdateIRQ;
  public
    constructor Create;
    procedure SetDateTime(Value: TDateTime);
    procedure Select(Value: Byte);
    function ReadData: Byte;
    procedure WriteData(Value: Byte);
    procedure Tick;
    procedure ResetInterface;
    function SaveBattery: TBytes;
    procedure LoadBattery(const Data: TBytes; AdvanceWallClock: Boolean = True);
    procedure SerializeState(State: TStateArchive);
    property DateTime: TDateTime read FDate;
  end;

implementation

uses
  System.Math, System.DateUtils;

constructor TZXCMOS.Create;
begin
  inherited;
  FRegisters[$0A] := $26;
  FRegisters[$0B] := 2;
  FRegisters[$0D] := $80;
  SetDateTime(Now);
end;

function TZXCMOS.Encode(Value: Integer): Byte;
begin
  if (FRegisters[$0B] and 4) <> 0 then
    Result := Value
  else
    Result := (Value div 10) * 16 + Value mod 10;
end;

function TZXCMOS.Decode(Value: Byte): Integer;
begin
  if (FRegisters[$0B] and 4) <> 0 then
    Result := Value
  else
    Result := (Value shr 4) * 10 + (Value and 15);
end;

procedure TZXCMOS.SetDateTime(Value: TDateTime);
begin
  FDate := RecodeMilliSecond(Value, 0);
  FWeekday := DayOfWeek(FDate);
  FPhase := 0;
  UpdateRegisters;
end;

procedure TZXCMOS.UpdateRegisters;
var
  Y, M, D, H, N, S, MS: Word;
begin
  DecodeDate(FDate, Y, M, D);
  DecodeTime(FDate, H, N, S, MS);
  FRegisters[0] := Encode(S);
  FRegisters[2] := Encode(N);
  if (FRegisters[$0B] and 2) <> 0 then
    FRegisters[4] := Encode(H)
  else
  begin
    var Hour := H mod 12;
    if Hour = 0 then
      Hour := 12;
    FRegisters[4] := Encode(Hour);
    if H >= 12 then
      FRegisters[4] := FRegisters[4] or $80;
  end;
  FRegisters[6] := Encode(FWeekday);
  FRegisters[7] := Encode(D);
  FRegisters[8] := Encode(M);
  FRegisters[9] := Encode(Y mod 100);
  FRegisters[$32] := Encode(Y div 100);
end;

procedure TZXCMOS.CommitRegisters;
begin
  var Hour := Decode(FRegisters[4] and $7F);
  if (FRegisters[$0B] and 2) = 0 then
  begin
    if not InRange(Hour, 1, 12) then
      Exit;
    Hour := Hour mod 12;
    if (FRegisters[4] and $80) <> 0 then
      Inc(Hour, 12);
  end;
  var Year := Decode(FRegisters[$32]) * 100 + Decode(FRegisters[9]);
  if Year < 100 then
    Inc(Year, 2000);
  var DatePart, TimePart: TDateTime;
  if TryEncodeDate(Year, Decode(FRegisters[8]), Decode(FRegisters[7]), DatePart) and
    TryEncodeTime(Hour, Decode(FRegisters[2]), Decode(FRegisters[0]), 0, TimePart) then
  begin
    FDate := DatePart + TimePart;
    FPhase := 0;
    if InRange(Decode(FRegisters[6]), 1, 7) then
      FWeekday := Decode(FRegisters[6]);
  end;
end;

procedure TZXCMOS.Select(Value: Byte);
begin
  FIndex := Value and $7F;
end;

procedure TZXCMOS.UpdateIRQ;
begin
  FRegisters[$0C] := FRegisters[$0C] and $7F;
  if (FRegisters[$0C] and FRegisters[$0B] and $70) <> 0 then
    FRegisters[$0C] := FRegisters[$0C] or $80;
end;

function TZXCMOS.ReadData: Byte;
begin
  case FIndex of
    $0A:
      begin
        Result := FRegisters[$0A] and $7F;
        if ((FRegisters[$0B] and $80) = 0) and ((FRegisters[$0A] and $70) = $20) and
          (FPhase >= 3500000 - 854) then
          Result := Result or $80;
      end;
    $0C:
      begin
        Result := FRegisters[$0C];
        FRegisters[$0C] := 0;
      end;
    $0D:
      Result := $80;
  else
    Result := FRegisters[FIndex];
  end;
end;

procedure TZXCMOS.WriteData(Value: Byte);
begin
  case FIndex of
    $0C, $0D:
      Exit;
    $0A:
      begin
        FRegisters[$0A] := Value and $7F;
        if (Value and $60) = $60 then
        begin
          FPhase := 0;
          FOscillator := 0;
          FDivider := 0;
        end;
      end;
    $0B:
      begin
        var Old := FRegisters[$0B];
      // Hold a coherent clock image throughout a SET transaction.
        if ((Old and $80) = 0) and ((Value and $80) <> 0) then
          UpdateRegisters;
        FRegisters[$0B] := Value;
        if ((Old and $80) <> 0) and ((Value and $80) = 0) then
          CommitRegisters;
        if (Value and $80) = 0 then
          UpdateRegisters;
        UpdateIRQ;
      end;
  else
    FRegisters[FIndex] := Value;
    if (FIndex in [0, 2, 4, 6, 7, 8, 9, $32]) and ((FRegisters[$0B] and $80) = 0) then
      CommitRegisters;
  end;
end;

procedure TZXCMOS.Tick;
begin
  if (FRegisters[$0A] and $70) <> $20 then
    Exit;
  Inc(FOscillator, 32768);
  if FOscillator >= 3500000 then
  begin
    Dec(FOscillator, 3500000);
    Inc(FDivider);
    var Rate := FRegisters[$0A] and 15;
    if Rate in [1, 2] then
      Inc(Rate, 7);
    if (Rate >= 3) and ((FDivider and ((1 shl (Rate - 1)) - 1)) = 0) then
    begin
      FRegisters[$0C] := FRegisters[$0C] or $40;
      UpdateIRQ;
    end;
    FDivider := FDivider and $7FFF;
  end;
  if (FRegisters[$0B] and $80) <> 0 then
    Exit;
  Inc(FPhase);
  if FPhase < 3500000 then
    Exit;
  FPhase := 0;
  var OldDay := Trunc(FDate);
  FDate := IncSecond(FDate, 1);
  if Trunc(FDate) <> OldDay then
    FWeekday := FWeekday mod 7 + 1;
  UpdateRegisters;
  FRegisters[$0C] := FRegisters[$0C] or $10;
  var Alarm := True;
  for var I := 0 to 2 do
    if ((FRegisters[I * 2 + 1] and $C0) <> $C0) and
      (FRegisters[I * 2 + 1] <> FRegisters[I * 2]) then
      Alarm := False;
  if Alarm then
    FRegisters[$0C] := FRegisters[$0C] or $20;
  UpdateIRQ;
end;

procedure TZXCMOS.ResetInterface;
begin
  FIndex := 0;
  FRegisters[$0B] := FRegisters[$0B] and $8F;
  FRegisters[$0C] := 0;
end;

procedure TZXCMOS.SerializeState(State: TStateArchive);
begin
  State.Field(FRegisters, SizeOf(FRegisters));
  State.Field(FIndex, SizeOf(FIndex));
  State.Field(FDate, SizeOf(FDate));
  State.Field(FPhase, SizeOf(FPhase));
  State.Field(FOscillator, SizeOf(FOscillator));
  State.Field(FDivider, SizeOf(FDivider));
  State.Field(FWeekday, SizeOf(FWeekday));
  if State.Loading and ((FIndex > 127) or not InRange(FPhase, 0, 3499999) or
    not InRange(FOscillator, 0, 3499999) or not InRange(FDivider, 0, 32767) or not InRange(FWeekday, 1, 7) or
    IsNan(FDate) or IsInfinite(FDate) or (FDate < 1) or (FDate > 2958464)) then
    raise EReadError.Create('Invalid Gluk CMOS state');
end;

function TZXCMOS.SaveBattery: TBytes;
begin
  var Stream := TMemoryStream.Create;
  try
    var Magic: UInt64 := $31534F4D43585A;
    Stream.WriteBuffer(Magic, SizeOf(Magic));
    var SavedAt: TDateTime;
    SavedAt := Now;
    Stream.WriteBuffer(SavedAt, SizeOf(SavedAt));
    var State := TStateArchive.Create(Stream, False);
    try
      SerializeState(State);
    finally
      State.Free;
    end;
    SetLength(Result, Stream.Size);
    Move(Stream.Memory^, Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

procedure TZXCMOS.LoadBattery(const Data: TBytes; AdvanceWallClock: Boolean);
begin
  if Length(Data) <> 197 then
    raise EReadError.CreateFmt('Invalid Gluk CMOS battery size: %d', [Length(Data)]);
  var Stream := TBytesStream.Create(Data);
  var Restored := TZXCMOS.Create;
  try
    var Magic: UInt64;
    var SavedAt: TDateTime;
    Stream.ReadBuffer(Magic, SizeOf(Magic));
    Stream.ReadBuffer(SavedAt, SizeOf(SavedAt));
    if Magic <> $31534F4D43585A then
      raise EReadError.Create('Invalid Gluk CMOS battery file');
    var State := TStateArchive.Create(Stream, True);
    try
      Restored.SerializeState(State);
    finally
      State.Free;
    end;
    if Stream.Position <> Stream.Size then
      raise EReadError.Create('Trailing Gluk CMOS battery data');
    if IsNan(SavedAt) or IsInfinite(SavedAt) or (SavedAt < 1) or (SavedAt > 2958464) then
      raise EReadError.Create('Invalid CMOS host timestamp');
    FRegisters := Restored.FRegisters;
    FIndex := Restored.FIndex;
    FDate := Restored.FDate;
    FPhase := Restored.FPhase;
    FOscillator := Restored.FOscillator;
    FDivider := Restored.FDivider;
    FWeekday := Restored.FWeekday;
    if AdvanceWallClock and ((FRegisters[$0B] and $80) = 0) and
      ((FRegisters[$0A] and $70) = $20) then
    begin
      var Elapsed := Max(Int64(0), Trunc((Now - SavedAt) * SecsPerDay));
      var OldDay := Trunc(FDate);
      FDate := IncSecond(FDate, Elapsed);
      FWeekday := (FWeekday - 1 + Trunc(FDate) - OldDay) mod 7 + 1;
      UpdateRegisters;
    end;
  finally
    Restored.Free;
    Stream.Free;
  end;
end;

end.

