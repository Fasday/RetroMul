unit RM.Controllers.Base;

interface

uses
  RM.Main.View, RM.Main.State;

type
  TMainController = class
  protected
    // Non-owning references; the form outlives its controllers.
    FView: TMainView;
    FState: TMainState;
  public
    constructor Create(AView: TMainView);
  end;

implementation

constructor TMainController.Create(AView: TMainView);
begin
  inherited Create;
  FView := AView;
  FState := AView.State;
end;

end.
