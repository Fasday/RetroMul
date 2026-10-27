unit PSP.Audio;

// sceAudio output mixing at 44.1 kHz. Placeholder: silence.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel, PSP.Scheduler;

type
  TPSPAudio = class
  private
    FKernel: TPSPKernel;
    FHLE: TPSPHLE;
    FSamples: TArray<SmallInt>;
    FProduced: Int64;
  public
    constructor Create(Kernel: TPSPKernel);
    procedure Reset;
    procedure Register;
    procedure OnEvent;
    // Stereo samples produced since the last call.
    function TakeSamples: TArray<SmallInt>;
  end;

implementation

constructor TPSPAudio.Create(Kernel: TPSPKernel);
begin
  inherited Create;
  FKernel := Kernel;
  FHLE := Kernel.HLE;
end;

procedure TPSPAudio.Reset;
begin
  FProduced := 0;
end;

procedure TPSPAudio.Register;
begin
end;

procedure TPSPAudio.OnEvent;
begin
end;

function TPSPAudio.TakeSamples: TArray<SmallInt>;
begin
  // Frames that fit in the elapsed time.
  var Total := FKernel.Scheduler.Now * PSPAudioRate div 1000000000;
  var N := Total - FProduced;
  if N < 0 then
    N := 0;
  FProduced := Total;
  SetLength(Result, N * 2);
  if N > 0 then
    FillChar(Result[0], N * 4, 0);
end;

end.
