unit PS1.CDROM;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, PS1.Types, PS1.Scheduler, PS1.DMA;

type
  // CD-ROM controller host interface (no drive attached yet).
  TPS1CDROM = class(TPS1DMADevice)
  private
    FScheduler: TPS1Scheduler;
    FIRQ: TPS1IRQRequest;
    FIndex: Byte;
    FInterruptEnable, FInterruptFlag: Byte;
  public
    constructor Create(Scheduler: TPS1Scheduler; const IRQ: TPS1IRQRequest);
    procedure Reset;
    function Read(Address: Cardinal): Byte;
    procedure Write(Address: Cardinal; Value: Byte);
    procedure Event(Time: Int64);
    function DMARequest(Channel: Integer): Boolean; override;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

constructor TPS1CDROM.Create(Scheduler: TPS1Scheduler; const IRQ: TPS1IRQRequest);
begin
  inherited Create;
  FScheduler := Scheduler;
  FIRQ := IRQ;
  Reset;
end;

procedure TPS1CDROM.Reset;
begin
  FIndex := 0;
  FInterruptEnable := 0;
  FInterruptFlag := 0;
end;

function TPS1CDROM.Read(Address: Cardinal): Byte;
begin
  case Address and 3 of
    // Parameter FIFO empty and not full; no response or data.
    0: Result := FIndex or $18;
    3:
      if (FIndex and 1) = 0 then
        Result := FInterruptEnable or $E0
      else
        Result := FInterruptFlag or $E0;
  else
    Result := 0;
  end;
end;

procedure TPS1CDROM.Write(Address: Cardinal; Value: Byte);
begin
  case Address and 3 of
    0: FIndex := Value and 3;
    2:
      if FIndex = 1 then
        FInterruptEnable := Value and $1F;
    3:
      if FIndex = 1 then
        FInterruptFlag := FInterruptFlag and not (Value and $1F);
  end;
end;

procedure TPS1CDROM.Event(Time: Int64);
begin
end;

function TPS1CDROM.DMARequest(Channel: Integer): Boolean;
begin
  Result := False;
end;

procedure TPS1CDROM.SerializeState(State: TStateArchive);
begin
  State.Field(FIndex, SizeOf(FIndex));
  State.Field(FInterruptEnable, SizeOf(FInterruptEnable));
  State.Field(FInterruptFlag, SizeOf(FInterruptFlag));
end;

end.
