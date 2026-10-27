unit PSP.MP3;

// sceMp3: MP3 stream playback buffers.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel, PSP.Scheduler, PSP.Service;

type
  TPSPMp3 = class(TPSPService)
  public
    procedure Register; override;
  end;

implementation

procedure TPSPMp3.Register;
begin
end;

initialization
  RegisterPSPService(TPSPMp3);

end.
