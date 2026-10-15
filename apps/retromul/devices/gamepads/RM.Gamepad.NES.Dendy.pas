unit RM.Gamepad.NES.Dendy;

interface

uses
  RM.Gamepad.NES.Standart;

type
  TGamepadNESDendy = class(TGamepadNESStandart)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  Core.Emulation, RM.VirtualController;

procedure TGamepadNESDendy.BuildLayout;
begin
  inherited;
  AddButton(TEmulatorButton.X, 'TB', TVirtualSide.Right, 52, 124, 64, 64);
  AddButton(TEmulatorButton.Y, 'TA', TVirtualSide.Right, 144, 88, 64, 64);
end;

end.

