unit PS1.GTE;

interface

uses
  System.SysUtils, Core.Snapshots, PS1.Types;

type
  // Coprocessor 2 register file. Command execution is added with the GTE.
  TPS1GTE = class
  private
    FData: array[0..31] of Cardinal;
    FControl: array[0..31] of Cardinal;
  public
    procedure Reset;
    function ReadData(Index: Integer): Cardinal;
    procedure WriteData(Index: Integer; Value: Cardinal);
    function ReadControl(Index: Integer): Cardinal;
    procedure WriteControl(Index: Integer; Value: Cardinal);
    // Returns the command latency in CPU cycles.
    function Execute(Command: Cardinal): Integer;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

procedure TPS1GTE.Reset;
begin
  FillChar(FData, SizeOf(FData), 0);
  FillChar(FControl, SizeOf(FControl), 0);
end;

function TPS1GTE.ReadData(Index: Integer): Cardinal;
begin
  Result := FData[Index and 31];
end;

procedure TPS1GTE.WriteData(Index: Integer; Value: Cardinal);
begin
  FData[Index and 31] := Value;
end;

function TPS1GTE.ReadControl(Index: Integer): Cardinal;
begin
  Result := FControl[Index and 31];
end;

procedure TPS1GTE.WriteControl(Index: Integer; Value: Cardinal);
begin
  FControl[Index and 31] := Value;
end;

function TPS1GTE.Execute(Command: Cardinal): Integer;
begin
  Result := 1;
end;

procedure TPS1GTE.SerializeState(State: TStateArchive);
begin
  State.Field(FData, SizeOf(FData));
  State.Field(FControl, SizeOf(FControl));
end;

end.
