unit PSP.Misc;

// Small libraries: sceCcc, sceJpeg, sceReg, sceNet*, sceHttp, sceSsl, sceUsb and friends.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel, PSP.Scheduler, PSP.Service;

type
  TPSPMisc = class(TPSPService)
  public
    procedure Register; override;
  end;

implementation

procedure TPSPMisc.Register;
begin
end;

initialization
  RegisterPSPService(TPSPMisc);

end.
