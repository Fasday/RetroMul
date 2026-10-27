unit PSP.Atrac;

// sceAtrac3plus: ATRAC3 / ATRAC3+ playback buffers decoded with source/hardware/audio.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel, PSP.Scheduler, PSP.Service;

type
  TPSPAtrac = class(TPSPService)
  public
    procedure Register; override;
  end;

implementation

procedure TPSPAtrac.Register;
begin
end;

initialization
  RegisterPSPService(TPSPAtrac);

end.
