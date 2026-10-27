unit PSP.Mpeg;

// sceMpeg / sceMpegbase / sceVideocodec: PSMF streams, H.264 video and its audio.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel, PSP.Scheduler, PSP.Service;

type
  TPSPMpeg = class(TPSPService)
  public
    procedure Register; override;
  end;

implementation

procedure TPSPMpeg.Register;
begin
end;

initialization
  RegisterPSPService(TPSPMpeg);

end.
