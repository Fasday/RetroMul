unit PSP.GE.Backend;

// Where the GE's primitives are drawn. The engine hands every primitive with
// its complete raster state (a TGERaster snapshot and the vertices) to its
// backend; without one it draws them itself with PSP.GE.Raster. A backend
// may draw later or elsewhere (on the GPU), so the engine tells it when guest
// memory is used outside it and when the GE stops: from then on guest memory
// must hold everything drawn, exactly as if PSP.GE.Raster had drawn it.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  PSP.GE.Raster;

type
  TGERasterBackend = class
  public
    procedure DrawTriangle(const S: TGERaster; const V0, V1, V2: TGEVertex); virtual; abstract;
    procedure DrawSprite(const S: TGERaster; const V0, V1: TGEVertex); virtual; abstract;
    procedure DrawLine(const S: TGERaster; const V0, V1: TGEVertex); virtual; abstract;
    procedure DrawPoint(const S: TGERaster; const V: TGEVertex); virtual; abstract;
    // The engine is about to read (or write) guest memory from Address on
    // itself: CLUT loads, block transfers, vertex and index fetches.
    procedure Access(Address, Size: Cardinal; Write: Boolean); virtual;
    // Guest memory holds every primitive drawn so far.
    procedure Sync; virtual;
  end;

  // Draws at once with PSP.GE.Raster, as the engine does without a backend.
  TGECPUBackend = class(TGERasterBackend)
  public
    procedure DrawTriangle(const S: TGERaster; const V0, V1, V2: TGEVertex); override;
    procedure DrawSprite(const S: TGERaster; const V0, V1: TGEVertex); override;
    procedure DrawLine(const S: TGERaster; const V0, V1: TGEVertex); override;
    procedure DrawPoint(const S: TGERaster; const V: TGEVertex); override;
  end;

implementation

procedure TGERasterBackend.Access(Address, Size: Cardinal; Write: Boolean);
begin
end;

procedure TGERasterBackend.Sync;
begin
end;

procedure TGECPUBackend.DrawTriangle(const S: TGERaster; const V0, V1, V2: TGEVertex);
begin
  GEDrawTriangle(S, V0, V1, V2);
end;

procedure TGECPUBackend.DrawSprite(const S: TGERaster; const V0, V1: TGEVertex);
begin
  GEDrawSprite(S, V0, V1);
end;

procedure TGECPUBackend.DrawLine(const S: TGERaster; const V0, V1: TGEVertex);
begin
  GEDrawLine(S, V0, V1);
end;

procedure TGECPUBackend.DrawPoint(const S: TGERaster; const V: TGEVertex);
begin
  GEDrawPoint(S, V);
end;

end.
