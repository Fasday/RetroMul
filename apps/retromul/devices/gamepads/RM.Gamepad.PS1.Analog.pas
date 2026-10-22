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

procedure TGamepadPS1Analog.BuildLayout;
begin
  // Left stick above the D-pad; L1/L2 beside it, SELECT and ANALOG below.
  AddPad;
  Find('dpad').Bounds := RectF(28, 132, 172, 276);
  AddStick;
  AddButton(TEmulatorButton.C, 'L1', TVirtualSide.Left, 136, 20, 88, 36, True);
  AddAuxiliaryButton(Ord(TPS1Extra.L2), 'L2', TVirtualSide.Left, RectF(136, 64, 224, 100));
  AddButton(TEmulatorButton.Select, 'SELECT', TVirtualSide.Left, 16, 284, 88, 36, True);
  AddAuxiliaryButton(Ord(TPS1Extra.Analog), 'ANALOG', TVirtualSide.Left, RectF(112, 284, 200, 320));
  AddButton(TEmulatorButton.Start, 'START', TVirtualSide.Right, 136, 74, 88, 36, True);
  AddButton(TEmulatorButton.Y, 'Tri', TVirtualSide.Right, 88, 120, 60, 60);
  AddButton(TEmulatorButton.X, 'Sq', TVirtualSide.Right, 16, 184, 60, 60);
  AddButton(TEmulatorButton.B, 'O', TVirtualSide.Right, 160, 184, 60, 60);
  AddButton(TEmulatorButton.A, 'X', TVirtualSide.Right, 88, 248, 60, 60);
  AddButton(TEmulatorButton.Z, 'R1', TVirtualSide.Right, 120, 20, 104, 36, True);
  AddButton(TEmulatorButton.Mode, 'R2', TVirtualSide.Right, 24, 20, 88, 36, True);
end;

end.
