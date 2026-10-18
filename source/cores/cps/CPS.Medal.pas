unit CPS.Medal;

interface

uses
  Core.Snapshots;

type
  // Virtual cabinet hopper. Motor and sensor are independent of player input.
  TCPSMedalHopper = class
  private
    FMotor, FEmpty, FStarted: Boolean;
    FPhase: Integer;
    FPaid: Int64;
    procedure SetMotor(Value: Boolean);
    function GetSensor: Boolean;
  public
    procedure Reset;
    procedure Advance(PixelClocks: Integer);
    procedure SerializeState(State: TStateArchive);
    property Motor: Boolean read FMotor write SetMotor;
    property Empty: Boolean read FEmpty write FEmpty;
    property Sensor: Boolean read GetSensor;
    property Paid: Int64 read FPaid;
  end;

implementation

uses
  System.SysUtils;

procedure TCPSMedalHopper.Reset;
begin
  FMotor := False;
  FStarted := False;
  FPhase := 0;
  FPaid := 0;
end;

procedure TCPSMedalHopper.SetMotor(Value: Boolean);
begin
  if FMotor <> Value then
  begin
    FPhase := 0;
    FStarted := False;
  end;
  FMotor := Value;
end;

procedure TCPSMedalHopper.Advance(PixelClocks: Integer);
begin
  if not FMotor or FEmpty then
    Exit;

  // A medal every 100 ms, with a 20 ms closure of the optical sensor.
  // Mechanical speed is a cabinet parameter, not a CPU instruction shortcut.
  Inc(FPhase, PixelClocks);
  while FPhase >= 800000 do
  begin
    Dec(FPhase, 800000);
    FStarted := True;
    Inc(FPaid);
  end;
end;

function TCPSMedalHopper.GetSensor: Boolean;
begin
  Result := FMotor and not FEmpty and FStarted and (FPhase < 160000);
end;

procedure TCPSMedalHopper.SerializeState(State: TStateArchive);
begin
  State.Field(FMotor, SizeOf(FMotor));
  State.Field(FEmpty, SizeOf(FEmpty));
  State.Field(FStarted, SizeOf(FStarted));
  State.Field(FPhase, SizeOf(FPhase));
  State.Field(FPaid, SizeOf(FPaid));

  if (FPhase < 0) or (FPhase >= 800000) or (FPaid < 0) then
    raise EArgumentException.Create('Invalid medal hopper state');
end;

end.

