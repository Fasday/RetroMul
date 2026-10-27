unit PSP.AudioCodec;

// sceAudiocodec: low-level audio frame decoding.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel, PSP.Scheduler, PSP.Service;

type
  TPSPAudioCodec = class(TPSPService)
  public
    procedure Register; override;
  end;

implementation

procedure TPSPAudioCodec.Register;
begin
end;

initialization
  RegisterPSPService(TPSPAudioCodec);

end.
