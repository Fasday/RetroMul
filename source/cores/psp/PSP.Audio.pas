unit PSP.Audio;

// sceAudio: output channels mixed at 44.1 kHz on the master clock.
// Placeholder: silence. Other audio services mix in through TPSPService.Mix.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel, PSP.Scheduler, PSP.Service;

type
  TPSPAudio = class(TPSPService)
  private
    FProduced: Int64;
  public
    procedure Reset; override;
    procedure Register; override;
    // Stereo samples produced since the last call, up to the current guest time.
    function TakeSamples: TArray<SmallInt>;
  end;

implementation

procedure TPSPAudio.Reset;
begin
  FProduced := 0;
end;

procedure TPSPAudio.Register;
begin
end;

function TPSPAudio.TakeSamples: TArray<SmallInt>;
begin
  var Total := FKernel.Scheduler.Now * PSPAudioRate div 1000000000;
  var N := Total - FProduced;
  if N < 0 then
    N := 0;
  FProduced := Total;
  SetLength(Result, N * 2);
  if N > 0 then
    FillChar(Result[0], N * 4, 0);
end;

initialization
  RegisterPSPService(TPSPAudio);

end.
