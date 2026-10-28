unit Core.PSP.Renderer;

// Owned by the PSP worker, inside Execute. The console and its memory outlive
// this session; Reset and LoadExec keep the same GE engine and memory objects.
interface

uses
  System.SysUtils, PSP.Console, PSP.GE.Backend;

type
  TPSPRendererSession = class
  private
    FConsole: TPSPConsole;
    FBackend: TGERasterBackend;
    FDescription: string;
  public
    constructor Create(Console: TPSPConsole; Vulkan: Boolean);
    destructor Destroy; override;
    function Status: string;
  end;

implementation

uses
  PSP.GE
  {$IF (Defined(MSWINDOWS) or Defined(LINUX) or Defined(ANDROID)) and not Defined(CPUX86)}
  , PSP.GE.GPU
  {$ENDIF}
  ;

constructor TPSPRendererSession.Create(Console: TPSPConsole; Vulkan: Boolean);
begin
  inherited Create;
  FConsole := Console;
  FDescription := 'cpu';
  if not Vulkan then
    Exit;
  var Reason: string;
  {$IF (Defined(MSWINDOWS) or Defined(LINUX) or Defined(ANDROID)) and not Defined(CPUX86)}
  var Backend: TGEGPUBackend;
  if CreateGEGPUBackend(Console.Memory, False, Backend, Reason) then
  begin
    FBackend := Backend;
    Backend.OnMessage :=
      procedure(const Text: string)
      begin
        FConsole.HLE.Log(Text);
      end;
    TPSPGE(Console.System.Find(TPSPGE)).Engine.Backend := Backend;
    FDescription := 'vulkan: ' + Backend.Compute.Name;
    Console.HLE.Log('gpu: ' + FDescription);
    Exit;
  end;
  {$ELSE}
  Reason := 'this host is not qualified for Vulkan GE rendering';
  {$ENDIF}
  FDescription := 'cpu: Vulkan unavailable (' + Reason + ')';
  Console.HLE.Log('gpu: unavailable (' + Reason + '), the GE draws on the CPU');
end;

destructor TPSPRendererSession.Destroy;
begin
  if FBackend <> nil then
  begin
    var GE := TPSPGE(FConsole.System.Find(TPSPGE));
    if GE.Engine.Backend = FBackend then
      GE.Engine.Backend := nil;
    FBackend.Free;
  end;
  inherited;
end;

function TPSPRendererSession.Status: string;
begin
  Result := FDescription;
  {$IF (Defined(MSWINDOWS) or Defined(LINUX) or Defined(ANDROID)) and not Defined(CPUX86)}
  if FBackend <> nil then
  begin
    var S := TGEGPUBackend(FBackend).Stats;
    Result := Result + Format(' (%d batches, %d GPU primitives, %d CPU fallbacks)', [S.Batches, S.Prims, S.Fallbacks]);
  end;
  {$ENDIF}
end;

end.
