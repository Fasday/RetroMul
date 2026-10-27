unit PSP.VFPU;

// The VFPU (COP2): 128 single-precision registers in 8 4x4 matrices, prefixes,
// and its load/store instructions. Installs its decoder into PSP.CPU.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}

interface

uses
  System.SysUtils, System.Math, PSP.Types, PSP.Memory, PSP.CPU;

function DecodeVFPU(Op: Cardinal): TPSPOpHandler;

implementation

function DecodeVFPU(Op: Cardinal): TPSPOpHandler;
begin
  Result := OpReserved;
end;

initialization
  PSPVFPUDecoder := DecodeVFPU;

end.
