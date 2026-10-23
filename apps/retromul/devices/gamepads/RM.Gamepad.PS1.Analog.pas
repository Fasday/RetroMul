unit RM.Gamepad.PS1.Analog;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadPS1Analog = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  System.Types, Core.Emulation, RM.VirtualController, Core.Adapter.PS1;

// As on a DualShock: shoulder buttons along the top, D-pad and face buttons
// above both sticks, which sit low towards the middle; SELECT and START
// between the halves, ANALOG below the D-pad.
procedure TGamepadPS1Analog.BuildLayout;
begin
  AddAuxiliaryButton(Ord(TPS1Extra.L2), 'L2', TVirtualSide.Left, RectF(16, 8, 112, 40));
  AddButton(TEmulatorButton.C, 'L1', TVirtualSide.Left, 16, 48, 96, 32, True);
  AddButton(TEmulatorButton.Select, 'SELECT', TVirtualSide.Left, 136, 48, 88, 32, True);
  AddPad;
  Find('dpad').Bounds := RectF(12, 88, 132, 208);
  AddStick(RectF(128, 208, 228, 308));
  AddAuxiliaryButton(Ord(TPS1Extra.Analog), 'ANALOG', TVirtualSide.Left, RectF(16, 268, 112, 300));

  AddButton(TEmulatorButton.Mode, 'R2', TVirtualSide.Right, 128, 8, 96, 32, True);
  AddButton(TEmulatorButton.Z, 'R1', TVirtualSide.Right, 128, 48, 96, 32, True);
  AddButton(TEmulatorButton.Start, 'START', TVirtualSide.Right, 16, 48, 88, 32, True);
  AddButton(TEmulatorButton.Y, 'Tri', TVirtualSide.Right, 139, 81, 54, 54);
  AddButton(TEmulatorButton.X, 'Sq', TVirtualSide.Right, 95, 125, 54, 54);
  AddButton(TEmulatorButton.B, 'O', TVirtualSide.Right, 183, 125, 54, 54);
  AddButton(TEmulatorButton.A, 'X', TVirtualSide.Right, 139, 169, 54, 54);
  AddRightStick(RectF(12, 208, 112, 308));
end;

end.
