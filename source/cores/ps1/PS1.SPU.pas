unit PS1.SPU;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, PS1.Types, PS1.Scheduler, PS1.DMA;

const
  PS1SoundRAMSize = $80000;

type
  // Sound processing unit registers and sound RAM transfers.
  TPS1SPU = class(TPS1DMADevice)
  private
    FScheduler: TPS1Scheduler;
    FIRQ: TPS1IRQRequest;
    FRegisters: array[0..$1FF] of Word;
    FTransferAddress: Cardinal;
    function Control: Word; inline;
  public
    RAM: array[0..PS1SoundRAMSize - 1] of Byte;
    constructor Create(Scheduler: TPS1Scheduler; const IRQ: TPS1IRQRequest);
    procedure Reset;
    function Read(Address: Cardinal): Word;
    procedure Write(Address: Cardinal; Value: Word);
    function DMARequest(Channel: Integer): Boolean; override;
    procedure DMAWrite(Channel: Integer; Data: PCardinal; Count: Integer); override;
    procedure DMARead(Channel: Integer; Data: PCardinal; Count: Integer); override;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

const
  RegTransferAddress = ($DA6 - $C00) div 2;
  RegTransferFIFO = ($DA8 - $C00) div 2;
  RegControl = ($DAA - $C00) div 2;
  RegStatus = ($DAE - $C00) div 2;

constructor TPS1SPU.Create(Scheduler: TPS1Scheduler; const IRQ: TPS1IRQRequest);
begin
  inherited Create;
  FScheduler := Scheduler;
  FIRQ := IRQ;
  Reset;
end;

procedure TPS1SPU.Reset;
begin
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FillChar(RAM, SizeOf(RAM), 0);
  FTransferAddress := 0;
end;

function TPS1SPU.Control: Word;
begin
  Result := FRegisters[RegControl];
end;

function TPS1SPU.Read(Address: Cardinal): Word;
begin
  var Index := (Address and $3FF) shr 1;
  if Index = RegStatus then
    // Mode bits mirror the control register; transfers complete at once.
    Result := Control and $3F
  else
    Result := FRegisters[Index];
end;

procedure TPS1SPU.Write(Address: Cardinal; Value: Word);
begin
  var Index := (Address and $3FF) shr 1;
  FRegisters[Index] := Value;
  case Index of
    RegTransferAddress:
      FTransferAddress := Cardinal(Value) * 8;
    RegTransferFIFO:
      begin
        PWord(@RAM[FTransferAddress and (PS1SoundRAMSize - 2)])^ := Value;
        FTransferAddress := (FTransferAddress + 2) and (PS1SoundRAMSize - 1);
      end;
  end;
end;

function TPS1SPU.DMARequest(Channel: Integer): Boolean;
begin
  Result := ((Control shr 4) and 3) in [2, 3];
end;

procedure TPS1SPU.DMAWrite(Channel: Integer; Data: PCardinal; Count: Integer);
begin
  for var I := 0 to Count - 1 do
  begin
    PCardinal(@RAM[FTransferAddress and (PS1SoundRAMSize - 4)])^ := Data^;
    FTransferAddress := (FTransferAddress + 4) and (PS1SoundRAMSize - 1);
    Inc(Data);
  end;
end;

procedure TPS1SPU.DMARead(Channel: Integer; Data: PCardinal; Count: Integer);
begin
  for var I := 0 to Count - 1 do
  begin
    Data^ := PCardinal(@RAM[FTransferAddress and (PS1SoundRAMSize - 4)])^;
    FTransferAddress := (FTransferAddress + 4) and (PS1SoundRAMSize - 1);
    Inc(Data);
  end;
end;

procedure TPS1SPU.SerializeState(State: TStateArchive);
begin
  State.Field(FRegisters, SizeOf(FRegisters));
  State.Field(FTransferAddress, SizeOf(FTransferAddress));
  State.Field(RAM, SizeOf(RAM));
end;

end.
