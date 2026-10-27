unit PSP.GE;

// sceGe_user and the graphics engine. Placeholder: lists complete at once.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel, PSP.Scheduler;

type
  TPSPGE = class
  private
    FKernel: TPSPKernel;
    FHLE: TPSPHLE;
    FMemory: TPSPMemory;
    FNextList: Cardinal;
    procedure hEdramGetAddr;
    procedure hEdramGetSize;
    procedure hListEnQueue;
    procedure hListUpdateStallAddr;
    procedure hListSync;
    procedure hDrawSync;
    procedure hSetCallback;
    procedure hZero;
  public
    constructor Create(Kernel: TPSPKernel);
    procedure Reset;
    procedure Register;
    procedure OnEvent;
  end;

implementation

constructor TPSPGE.Create(Kernel: TPSPKernel);
begin
  inherited Create;
  FKernel := Kernel;
  FHLE := Kernel.HLE;
  FMemory := Kernel.Memory;
end;

procedure TPSPGE.Reset;
begin
  FNextList := 0;
end;

procedure TPSPGE.OnEvent;
begin
end;

procedure TPSPGE.hEdramGetAddr;
begin
  FHLE.Result(PSPVRAMBase);
end;

procedure TPSPGE.hEdramGetSize;
begin
  FHLE.Result(PSPVRAMSize);
end;

procedure TPSPGE.hListEnQueue;
begin
  Inc(FNextList);
  FHLE.Result(FNextList and 63);
end;

procedure TPSPGE.hListUpdateStallAddr;
begin
  FHLE.Result(0);
end;

procedure TPSPGE.hListSync;
begin
  FHLE.Result(0);
end;

procedure TPSPGE.hDrawSync;
begin
  FHLE.Result(0);
end;

procedure TPSPGE.hSetCallback;
begin
  FHLE.Result(0);
end;

procedure TPSPGE.hZero;
begin
  FHLE.Result(0);
end;

procedure TPSPGE.Register;
const
  G = 'sceGe_user';
begin
  var H := FHLE;
  H.Register(G, $E47E40E4, 'sceGeEdramGetAddr', hEdramGetAddr);
  H.Register(G, $1F6752AD, 'sceGeEdramGetSize', hEdramGetSize);
  H.Register(G, $AB49E76A, 'sceGeListEnQueue', hListEnQueue);
  H.Register(G, $1C0D95A6, 'sceGeListEnQueueHead', hListEnQueue);
  H.Register(G, $E0D68148, 'sceGeListUpdateStallAddr', hListUpdateStallAddr);
  H.Register(G, $03444EB4, 'sceGeListSync', hListSync);
  H.Register(G, $B287BD61, 'sceGeDrawSync', hDrawSync);
  H.Register(G, $A4FC06A4, 'sceGeSetCallback', hSetCallback);
  H.Register(G, $05DB22CE, 'sceGeUnsetCallback', hZero);
end;

end.
