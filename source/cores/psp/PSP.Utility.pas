unit PSP.Utility;

// sceUtility: savedata, dialogs, on-screen keyboard, system parameters, modules.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel, PSP.Scheduler, PSP.Service;

type
  TPSPUtility = class(TPSPService)
  public
    procedure Register; override;
  end;

implementation

procedure TPSPUtility.Register;
begin
end;

initialization
  RegisterPSPService(TPSPUtility);

end.
