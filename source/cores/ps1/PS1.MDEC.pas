unit PS1.MDEC;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, PS1.Types, PS1.DMA;

type
  // Macroblock decoder registers.
  TPS1MDEC = class(TPS1DMADevice)
  private
    FControl: Cardinal;
  public
    procedure Reset;
    function Read(Address: Cardinal): Cardinal;
    procedure Write(Address, Value: Cardinal);
    function DMARequest(Channel: Integer): Boolean; override;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

procedure TPS1MDEC.Reset;
begin
  FControl := 0;
end;

function TPS1MDEC.Read(Address: Cardinal): Cardinal;
begin
  if (Address and 4) = 0 then
    Result := 0
  else
    // Data-out FIFO empty, current block 4 (Y1), no parameters pending.
    Result := $80040000;
end;

procedure TPS1MDEC.Write(Address, Value: Cardinal);
begin
  if (Address and 4) <> 0 then
  begin
    FControl := Value;
    if (Value and $80000000) <> 0 then
      Reset;
  end;
end;

function TPS1MDEC.DMARequest(Channel: Integer): Boolean;
begin
  Result := False;
end;

procedure TPS1MDEC.SerializeState(State: TStateArchive);
begin
  State.Field(FControl, SizeOf(FControl));
end;

end.
