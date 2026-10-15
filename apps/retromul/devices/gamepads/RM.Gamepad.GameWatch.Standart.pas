unit RM.Gamepad.GameWatch.Standart;

interface

uses
  RM.Gamepad.Base;

type
  TGamepadGameWatchStandart = class(TPlatformGamepad)
  protected
    procedure BuildLayout; override;
  end;

implementation

uses
  Core.Emulation, RM.VirtualController;

procedure TGamepadGameWatchStandart.BuildLayout;
begin
  AddPad;
  AddButton(TEmulatorButton.Select, 'TIME', TVirtualSide.Left, 136, 74, 88, 36, True);
  AddButton(TEmulatorButton.Start, 'GAME A', TVirtualSide.Right, 16, 74, 88, 36, True);
  AddButton(TEmulatorButton.X, 'GAME B', TVirtualSide.Right, 120, 74, 104, 36, True);
  AddButton(TEmulatorButton.Mode, 'START', TVirtualSide.Left, 136, 24, 88, 36, True);
  AddButton(TEmulatorButton.Y, 'ACL', TVirtualSide.Left, 24, 24, 88, 36, True);
  AddButton(TEmulatorButton.A, 'A', TVirtualSide.Right, 144, 220, 64, 64);
  AddButton(TEmulatorButton.B, 'B', TVirtualSide.Right, 52, 220, 64, 64);
  AddButton(TEmulatorButton.C, 'X', TVirtualSide.Right, 52, 140, 64, 64);
  AddButton(TEmulatorButton.Z, 'Y', TVirtualSide.Right, 144, 140, 64, 64);
end;

end.

