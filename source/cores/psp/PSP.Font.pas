unit PSP.Font;

// sceLibFont: PGF fonts.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel, PSP.Scheduler, PSP.Service;

type
  TPSPFont = class(TPSPService)
  public
    procedure Register; override;
  end;

implementation

procedure TPSPFont.Register;
begin
end;

initialization
  RegisterPSPService(TPSPFont);

end.
