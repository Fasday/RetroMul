unit CPS.Timekeeper;

interface

uses
  System.SysUtils, Core.Snapshots;

type
  TCPSM48T35 = class
  private
    FRAM: TBytes;
    FDate: TDateTime;
    FPhase: Int64;
    FStopped: Boolean;
    procedure UpdateRegisters;
    procedure CommitRegisters;
  public
    constructor Create(const Initial: TBytes);
    function Read(Address: Word): Byte;
    procedure Write(Address: Word; Value: Byte);
    procedure Advance(Cycles, Clock: Integer);
    function Battery: TBytes;
    procedure LoadBattery(const Data: TBytes);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

function BCD(V: Integer): Byte; inline;
begin
  Result := Byte((V div 10) * 16 + V mod 10);
end;

function UnBCD(V: Byte): Integer; inline;
begin
  Result := (V shr 4) * 10 + (V and 15);
end;

constructor TCPSM48T35.Create(const Initial: TBytes);
begin
  inherited Create;
  SetLength(FRAM, $8000);
  FDate := Now;
  if Length(Initial) = $8000 then
  begin
    FRAM := Copy(Initial);
    CommitRegisters;
  end;
  UpdateRegisters;
end;

procedure TCPSM48T35.UpdateRegisters;
begin
  if FRAM[$7FF8] and $C0 <> 0 then
    Exit;

  var Y, M, D, H, N, S, MS: Word;
  DecodeDate(FDate, Y, M, D);
  DecodeTime(FDate, H, N, S, MS);
  FRAM[$7FF9] := BCD(S) or (Ord(FStopped) shl 7);
  FRAM[$7FFA] := BCD(N);
  FRAM[$7FFB] := BCD(H);
  FRAM[$7FFC] := (FRAM[$7FFC] and $F8) or Byte(DayOfWeek(FDate));
  FRAM[$7FFD] := BCD(D);
  FRAM[$7FFE] := BCD(M);
  FRAM[$7FFF] := BCD(Y mod 100);
end;

procedure TCPSM48T35.CommitRegisters;
begin
  var DatePart, TimePart: TDateTime;
  if TryEncodeDate(2000 + UnBCD(FRAM[$7FFF]), UnBCD(FRAM[$7FFE] and $1F), UnBCD(FRAM[$7FFD] and $3F), DatePart) and
    TryEncodeTime(UnBCD(FRAM[$7FFB] and $3F), UnBCD(FRAM[$7FFA] and $7F), UnBCD(FRAM[$7FF9] and $7F), 0, TimePart) then
    FDate := DatePart + TimePart;
  FStopped := FRAM[$7FF9] and $80 <> 0;
end;

function TCPSM48T35.Read(Address: Word): Byte;
begin
  Address := Address and $7FFF;
  if Address >= $7FF8 then
    UpdateRegisters;
  Result := FRAM[Address];
end;

procedure TCPSM48T35.Write(Address: Word; Value: Byte);
begin
  Address := Address and $7FFF;
  if Address = $7FF8 then
  begin
    UpdateRegisters;
    if (FRAM[$7FF8] and $80 <> 0) and (Value and $80 = 0) then
      CommitRegisters;
    FRAM[Address] := Value;
    UpdateRegisters;
  end
  else if (Address < $7FF9) or (FRAM[$7FF8] and $80 <> 0) then
    FRAM[Address] := Value;
end;

procedure TCPSM48T35.Advance(Cycles, Clock: Integer);
begin
  if FStopped or (FRAM[$7FF8] and $80 <> 0) then
    Exit;

  Inc(FPhase, Cycles);
  while FPhase >= Clock do
  begin
    Dec(FPhase, Clock);
    FDate := FDate + 1 / 86400;
  end;
end;

function TCPSM48T35.Battery: TBytes;
begin
  UpdateRegisters;
  SetLength(Result, $8000 + SizeOf(TDateTime));
  Move(FRAM[0], Result[0], $8000);
  var SavedAt := Now;
  Move(SavedAt, Result[$8000], SizeOf(SavedAt));
end;

procedure TCPSM48T35.LoadBattery(const Data: TBytes);
begin
  if (Length(Data) <> $8000) and (Length(Data) <> $8000 + SizeOf(TDateTime)) then
    raise EArgumentException.Create('Invalid M48T35 battery');

  Move(Data[0], FRAM[0], $8000);
  CommitRegisters;
  FPhase := 0;
  if (Length(Data) > $8000) and not FStopped then
  begin
    var SavedAt: TDateTime;
    Move(Data[$8000], SavedAt, SizeOf(SavedAt));
    if (SavedAt > EncodeDate(1980, 1, 1)) and (SavedAt <= Now) then
      FDate := FDate + (Now - SavedAt);
  end;
  UpdateRegisters;
end;

procedure TCPSM48T35.SerializeState(State: TStateArchive);
begin
  State.Field(FRAM[0], $8000);
  State.Field(FDate, SizeOf(FDate));
  State.Field(FPhase, SizeOf(FPhase));
  State.Field(FStopped, SizeOf(FStopped));

  if (FDate < 0) or (FDate > EncodeDate(9999, 12, 31)) or (FPhase < 0) then
    raise EArgumentException.Create('Invalid M48T35 state');
end;

end.

