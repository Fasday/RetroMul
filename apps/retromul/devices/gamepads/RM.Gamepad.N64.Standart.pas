unit RM.Gamepad.N64.Standart;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadN64Standart = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  Core.Emulation, RM.VirtualController;

procedure TGamepadN64Standart.BuildLayout;
begin
  AddPad;
  AddStick;
  AddButton(TEmulatorButton.Select, 'Z', TVirtualSide.Left, 164, 20, 60, 44, True);
  AddButton(TEmulatorButton.Start, 'START', TVirtualSide.Left, 136, 80, 88, 36, True);
  AddButton(TEmulatorButton.Mode, 'R', TVirtualSide.Right, 112, 20, 104, 36, True);
  AddButton(TEmulatorButton.B, 'B', TVirtualSide.Right, 12, 180, 60, 60);
  AddButton(TEmulatorButton.A, 'A', TVirtualSide.Right, 72, 244, 64, 64);
  AddButton(TEmulatorButton.X, 'C-L', TVirtualSide.Right, 86, 134, 40, 40);
  AddButton(TEmulatorButton.Y, 'C-U', TVirtualSide.Right, 130, 90, 40, 40);
  AddButton(TEmulatorButton.Z, 'C-R', TVirtualSide.Right, 174, 134, 40, 40);
  AddButton(TEmulatorButton.C, 'C-D', TVirtualSide.Right, 130, 178, 40, 40);
end;

end.

