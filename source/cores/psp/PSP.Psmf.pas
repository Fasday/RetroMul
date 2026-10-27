unit PSP.Psmf;

// scePsmf / scePsmfPlayer: PSMF headers and the movie player.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel, PSP.Scheduler, PSP.Service;

type
  TPSPPsmf = class(TPSPService)
  public
    procedure Register; override;
  end;

implementation

procedure TPSPPsmf.Register;
begin
end;

initialization
  RegisterPSPService(TPSPPsmf);

end.
