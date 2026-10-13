unit Core.Emulation.Timing;

interface

type
  // Worker throughput over wall time, independent of the hardware frame rate.
  // Reset at pause, reset or snapshot load so idle time does not lower the rate.
  TEmulationFrameRate = record
  private
    FStartFrame: UInt64;
    FStartTicks: Int64;
    FValue: Double;
  public
    procedure Reset(FrameNumber: UInt64; TimeStamp: Int64);
    function Update(FrameNumber: UInt64; TimeStamp, Frequency: Int64): Double;
    property Value: Double read FValue;
  end;


implementation

procedure TEmulationFrameRate.Reset(FrameNumber: UInt64; TimeStamp: Int64);
begin
  FStartFrame := FrameNumber;
  FStartTicks := TimeStamp;
  FValue := 0;
end;

function TEmulationFrameRate.Update(FrameNumber: UInt64; TimeStamp, Frequency: Int64): Double;
begin
  if (FrameNumber < FStartFrame) or (TimeStamp < FStartTicks) then
    Reset(FrameNumber, TimeStamp);
  var Elapsed := TimeStamp - FStartTicks;
  if (Frequency > 0) and (Elapsed > 0) and (Elapsed >= Frequency div 2) then
  begin
    FValue := (FrameNumber - FStartFrame) * (Frequency / Double(Elapsed));
    FStartFrame := FrameNumber;
    FStartTicks := TimeStamp;
  end;
  Result := FValue;
end;

end.
