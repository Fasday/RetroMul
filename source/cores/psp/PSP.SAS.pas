unit PSP.SAS;

// sceSasCore: the SAS voice synthesizer (VAG ADPCM, PCM, noise, envelopes, reverb).
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel, PSP.Scheduler, PSP.Service;

type
  TPSPSasCore = class(TPSPService)
  public
    procedure Register; override;
  end;

implementation

procedure TPSPSasCore.Register;
begin
end;

initialization
  RegisterPSPService(TPSPSasCore);

end.
