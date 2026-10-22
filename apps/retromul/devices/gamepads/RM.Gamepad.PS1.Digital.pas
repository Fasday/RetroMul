unit RM.Gamepad.PS1.Digital;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadPS1Digital = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  System.Types, Core.Emulation, RM.VirtualController;

procedure TGamepadPS1Digital.BuildLayout;
begin
  AddPad;
  AddMenus;
  // Face buttons in the PlayStation diamond; L1/R1 on top, L2/R2 above them.
  AddButton(TEmulatorButton.Y, 'Tri', TVirtualSide.Right, 88, 136, 60, 60);
  AddButton(TEmulatorButton.X, 'Sq', TVirtualSide.Right, 16, 200, 60, 60);
  AddButton(TEmulatorButton.B, 'O', TVirtualSide.Right, 160, 200, 60, 60);
  AddButton(TEmulatorButton.A, 'X', TVirtualSide.Right, 88, 264, 60, 60);
  AddButton(TEmulatorButton.C, 'L1', TVirtualSide.Left, 16, 20, 104, 36, True);
  AddButton(TEmulatorButton.Z, 'R1', TVirtualSide.Right, 120, 20, 104, 36, True);
  AddAuxiliaryButton(0, 'L2', TVirtualSide.Left, RectF(128, 20, 216, 56));
  AddButton(TEmulatorButton.Mode, 'R2', TVirtualSide.Right, 24, 20, 88, 36, True);
end;

end.
