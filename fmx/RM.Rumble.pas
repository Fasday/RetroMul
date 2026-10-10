unit RM.Rumble;

interface

uses
  FMXInput;

type
  // Allows lifecycle and pacing to be verified without vibrating real hardware.
  IRumbleDevice = interface
    ['{6AFC833F-E9D9-4CBA-B3EB-91642E1F563A}']
    function Supported: Boolean;
    function CanCancel: Boolean;
    function Pulse(Duration: UInt16; Intensity: Byte): Boolean;
    procedure Cancel;
  end;

  TRumblePlayer = class
  private
    FDevice: IRumbleDevice;
    FLevel: Byte;
    FActive, FFailed, FHasPulse, FChecked: Boolean;
    FLastPulse: UInt64;
  public
    constructor Create(const Device: IRumbleDevice = nil);
    destructor Destroy; override;
    procedure SetDevice(const Device: IRumbleDevice);
    procedure Update(Level: Byte; Tick: UInt64);
    procedure Stop;
    procedure Reset;
  end;

function CreateGamepadRumbleDevice(Input: TInputManager; const DeviceId: string): IRumbleDevice;

implementation

uses
  System.SysUtils, FMX.Vibrate;

type
  TGamepadRumbleDevice = class(TInterfacedObject, IRumbleDevice)
    Input: TInputManager; // Non-owning; player must be destroyed before Input.
    DeviceId: string;
    function Supported: Boolean;
    function CanCancel: Boolean;
    function Pulse(Duration: UInt16; Intensity: Byte): Boolean;
    procedure Cancel;
  end;

  TNativeRumbleDevice = class(TInterfacedObject, IRumbleDevice)
    function Supported: Boolean;
    function CanCancel: Boolean;
    function Pulse(Duration: UInt16; Intensity: Byte): Boolean;
    procedure Cancel;
  end;

function CreateGamepadRumbleDevice(Input: TInputManager; const DeviceId: string): IRumbleDevice;
begin
  var Device := TGamepadRumbleDevice.Create;
  Device.Input := Input;
  Device.DeviceId := DeviceId;
  Result := Device;
end;

function TGamepadRumbleDevice.Supported: Boolean;
begin
  Result := False;
  if Input = nil then
    Exit;
  for var Device in Input.Devices do
    if (Device.Id = DeviceId) and Device.Available and Device.RumbleSupported then
      Exit(True);
end;

function TGamepadRumbleDevice.CanCancel: Boolean;
begin
  Result := True;
end;

function TGamepadRumbleDevice.Pulse(Duration: UInt16; Intensity: Byte): Boolean;
begin
  Result := (Input <> nil) and Input.SetRumble(DeviceId,
    Word(Intensity) * 257, Word(Intensity) * 257, Duration);
end;

procedure TGamepadRumbleDevice.Cancel;
begin
  if Input <> nil then
    Input.StopRumble(DeviceId);
end;

function TNativeRumbleDevice.Supported: Boolean;
begin
  Result := VibrationSupported;
end;

function TNativeRumbleDevice.CanCancel: Boolean;
begin
  Result := CanCancelVibration;
end;

function TNativeRumbleDevice.Pulse(Duration: UInt16; Intensity: Byte): Boolean;
begin
  Result := TryVibrate(Duration, Intensity);
end;

procedure TNativeRumbleDevice.Cancel;
begin
  CancelVibration;
end;

constructor TRumblePlayer.Create(const Device: IRumbleDevice);
begin
  inherited Create;
  FDevice := Device;
  if FDevice = nil then
    FDevice := TNativeRumbleDevice.Create;
end;

procedure TRumblePlayer.SetDevice(const Device: IRumbleDevice);
begin
  Reset; // Stop the previous device before releasing it; discard pacing/failure state.
  FDevice := Device;
  if FDevice = nil then
    FDevice := TNativeRumbleDevice.Create;
end;

destructor TRumblePlayer.Destroy;
begin
  Stop;
  inherited;
end;

procedure TRumblePlayer.Stop;
begin
  if FActive and FDevice.CanCancel then
    FDevice.Cancel;
  FActive := False;
  FLevel := 0;
end;

procedure TRumblePlayer.Reset;
begin
  Stop;
  FFailed := False;
  FChecked := False;
  FHasPulse := False;
  FLastPulse := 0;
end;

procedure TRumblePlayer.Update(Level: Byte; Tick: UInt64);
begin
  if Level = 0 then
  begin
    Stop;
    Exit;
  end;
  var Rising := FLevel = 0;
  FLevel := Level;
  if FFailed then
    Exit;
  if not FChecked then
  begin
    FChecked := True;
    FFailed := not FDevice.Supported;
    if FFailed then
      Exit;
  end;
  var Repeatable := FDevice.CanCancel;
  var Interval: UInt64 := 40;
  if not Repeatable then
    Interval := 250;
  // AudioServices cannot cancel/renew a motor: one system pulse per rising
  // burst, with a cooldown for games that PWM the rumble line rapidly.
  if not Repeatable and not Rising then
    Exit;
  if FHasPulse and (Tick >= FLastPulse) and (Tick - FLastPulse < Interval) then
    Exit;
  FLastPulse := Tick;
  FHasPulse := True;
  // Never leave an indefinite effect behind if rendering stalls or exits.
  FActive := FDevice.Pulse(40, Level);
  FFailed := not FActive;
end;

end.

