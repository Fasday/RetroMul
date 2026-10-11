unit NES.Input;

interface

uses
  System.SysUtils, System.Generics.Collections, NES.Controller;

const
  INPUT_KEYBOARD = 0;
  INPUT_SCREEN_GAMEPAD = 1;
  INPUT_PLAYER_COUNT = 4;

type
  // Each physical device/backend owns a distinct source ID; 0 is the keyboard.
  // Releasing one source never releases a button held by another source.
  TNesInput = class
  private
    type
      TPlayerState = record
        Buttons, Turbo: Byte;
        Phase: array[TNesButton.A..TNesButton.B] of Byte;
      end;

      TPlayerStates = array[1..INPUT_PLAYER_COUNT] of TPlayerState;
  private
    FSources: TDictionary<UInt32, TPlayerStates>;
    procedure CheckPlayer(Player: Integer);
  public
    constructor Create;
    destructor Destroy; override;
    procedure SetButton(Source: UInt32; Player: Integer; Button: TNesButton; Pressed: Boolean);
    procedure SetTurboButton(Source: UInt32; Player: Integer; Button: TNesButton; Pressed: Boolean);
    // Advance once per completed emulated frame, never while paused.
    procedure AdvanceTurbo;
    procedure SetKey(Player: Integer; Code: UInt32; Pressed: Boolean; const Keys: TKeyMap);
    procedure ReleaseSource(Source: UInt32);
    procedure Clear;
    function IsPressed(Player: Integer; Button: TNesButton): Boolean;
    procedure Apply(Player: Integer; Controller: TController);
  end;

implementation

constructor TNesInput.Create;
begin
  inherited;
  FSources := TDictionary<UInt32, TPlayerStates>.Create;
end;

destructor TNesInput.Destroy;
begin
  FSources.Free;
  inherited;
end;

procedure TNesInput.CheckPlayer(Player: Integer);
begin
  if (Player < 1) or (Player > INPUT_PLAYER_COUNT) then
    raise EArgumentOutOfRangeException.Create('Invalid input player');
end;

procedure TNesInput.SetButton(Source: UInt32; Player: Integer; Button: TNesButton; Pressed: Boolean);
begin
  CheckPlayer(Player);
  var States: TPlayerStates;
  if not FSources.TryGetValue(Source, States) then
    FillChar(States, SizeOf(States), 0);
  var Mask: Byte := 1 shl Ord(Button);
  if Pressed then
    States[Player].Buttons := States[Player].Buttons or Mask
  else
    States[Player].Buttons := States[Player].Buttons and not Mask;
  FSources.AddOrSetValue(Source, States);
end;

procedure TNesInput.SetTurboButton(Source: UInt32; Player: Integer; Button: TNesButton; Pressed: Boolean);
begin
  CheckPlayer(Player);
  if not (Button in [TNesButton.A, TNesButton.B]) then
    raise EArgumentException.Create('Only A and B support turbo');

  var States: TPlayerStates;
  if not FSources.TryGetValue(Source, States) then
    FillChar(States, SizeOf(States), 0);
  var Mask: Byte := 1 shl Ord(Button);
  if Pressed then
  begin
    if (States[Player].Turbo and Mask) = 0 then
      States[Player].Phase[Button] := 0;
    States[Player].Turbo := States[Player].Turbo or Mask;
  end
  else
    States[Player].Turbo := States[Player].Turbo and not Mask;
  FSources.AddOrSetValue(Source, States);
end;

procedure TNesInput.AdvanceTurbo;
begin
  // Updating dictionary values invalidates its enumerator; use a key snapshot.
  for var Source in FSources.Keys.ToArray do
  begin
    var States := FSources[Source];
    var Changed := False;
    for var Player := 1 to INPUT_PLAYER_COUNT do
      for var Button := TNesButton.A to TNesButton.B do
        if (States[Player].Turbo and (1 shl Ord(Button))) <> 0 then
        begin
          States[Player].Phase[Button] := (States[Player].Phase[Button] + 1) mod 4;
          Changed := True;
        end;
    if Changed then
      FSources.AddOrSetValue(Source, States);
  end;
end;

procedure TNesInput.SetKey(Player: Integer; Code: UInt32; Pressed: Boolean; const Keys: TKeyMap);
begin
  CheckPlayer(Player);
  if Code = Keys.A then
    SetButton(INPUT_KEYBOARD, Player, TNesButton.A, Pressed);
  if Code = Keys.B then
    SetButton(INPUT_KEYBOARD, Player, TNesButton.B, Pressed);
  if Code = Keys.Select then
    SetButton(INPUT_KEYBOARD, Player, TNesButton.Select, Pressed);
  if Code = Keys.Start then
    SetButton(INPUT_KEYBOARD, Player, TNesButton.Start, Pressed);
  if Code = Keys.Up then
    SetButton(INPUT_KEYBOARD, Player, TNesButton.Up, Pressed);
  if Code = Keys.Down then
    SetButton(INPUT_KEYBOARD, Player, TNesButton.Down, Pressed);
  if Code = Keys.Left then
    SetButton(INPUT_KEYBOARD, Player, TNesButton.Left, Pressed);
  if Code = Keys.Right then
    SetButton(INPUT_KEYBOARD, Player, TNesButton.Right, Pressed);
end;

procedure TNesInput.ReleaseSource(Source: UInt32);
begin
  FSources.Remove(Source);
end;

procedure TNesInput.Clear;
begin
  FSources.Clear;
end;

function TNesInput.IsPressed(Player: Integer; Button: TNesButton): Boolean;
begin
  CheckPlayer(Player);
  for var Pair in FSources do
  begin
    var State := Pair.Value[Player];
    if (State.Buttons and (1 shl Ord(Button))) <> 0 then
      Exit(True);

    if (Button in [TNesButton.A, TNesButton.B]) and ((State.Turbo and (1 shl Ord(Button))) <> 0) then
      if State.Phase[Button] < 2 then
        Exit(True);
  end;

  Result := False;
end;

procedure TNesInput.Apply(Player: Integer; Controller: TController);
begin
  CheckPlayer(Player);
  for var Button := Low(TNesButton) to High(TNesButton) do
    Controller.SetButton(Button, IsPressed(Player, Button));
end;

end.

