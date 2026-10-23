unit DC.PVR.Render;

// Software CORE (ISP/TSP) for PowerVR2: walks the region array, renders each
// 32x32 tile from the decoded display lists and writes it to the framebuffer.
// Per tile: opaque and punch-through lists with depth test and deferred
// shading, opaque modifier volumes, then translucent lists either presorted
// or sorted per pixel back to front (depth peeling), translucent modifier
// volumes, fog, blending and the framebuffer packing with optional dither.
// Tiles are independent; a render prepares triangles and textures first so
// tiles can run on worker threads.
// References: Marcus Comstedt's PowerVR pages, KallistiOS pvr headers.
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}
{$TYPEDADDRESS ON}
{$EXCESSPRECISION OFF}

interface

uses
  System.SysUtils, System.Math, System.Classes, DC.Types, DC.Memory, DC.PVR, DC.PVR.TA, DC.PVR.Texture;

const
  TileSize = 32;

type
  // A triangle ready for rasterization: edge and plane equations in pixel
  // space (pixel centres at +0.5).
  TRenderTri = record
    Poly: Integer;
    V0, V1, V2: Integer;          // vertex indices in the context
    EA, EB, EC: array[0..2] of Single;
    ZA, ZB, ZC: Single;           // 1/w plane: Z = ZC + ZA * (x - X0) + ZB * (y - Y0)
    X0, Y0: Single;
    InvArea: Single;
    MinX, MinY, MaxX, MaxY: Integer;
    // Modifier volume membership.
    Volume: Integer;
  end;
  PRenderTri = ^TRenderTri;

  TRenderPoly = record
    Texture, Texture1: TPVRTexture;
    Shadow: Boolean;              // affected by modifier volumes
    Translucent, PunchThrough: Boolean;
  end;

  PRenderPoly = ^TRenderPoly;

  TTileBuffers = record
    Depth: array[0..TileSize * TileSize - 1] of Single;
    Tag: array[0..TileSize * TileSize - 1] of Integer;   // triangle index, -1 background
    Color: array[0..TileSize * TileSize - 1] of Cardinal;
    Modified: array[0..TileSize * TileSize - 1] of Byte; // modifier volume result
    Stencil: array[0..TileSize * TileSize - 1] of Byte;
    Fresh: array[0..TileSize * TileSize - 1] of Byte;    // shaded in this entry
    PeelDepth: array[0..TileSize * TileSize - 1] of Single;
    PeelTag: array[0..TileSize * TileSize - 1] of Integer;
    BestDepth: array[0..TileSize * TileSize - 1] of Single;
    BestTag: array[0..TileSize * TileSize - 1] of Integer;
  end;
  PTileBuffers = ^TTileBuffers;

  TRegionEntry = record
    Control: Cardinal;
    Lists: array[0..4] of Cardinal;
    Pass: Integer;
  end;

  TDCRenderer = class
  private
    FMemory: TDCMemory;
    FPVR: TDCPVR;
    FTA: TDCTA;
    FTextures: TPVRTextureCache;
    FContext: TPVRContext;
    FTris: TArray<TRenderTri>;
    FTriCount: Integer;
    FPolys: TArray<TRenderPoly>;
    // Triangles per tile and list: Bins[tile][list] -> indices.
    FBinStart: TArray<Integer>;
    FBinCount: TArray<Integer>;
    FBinItems: TArray<Integer>;
    FTilesX, FTilesY: Integer;
    FEntries: TArray<TRegionEntry>;
    FBackground: Cardinal;
    FBackgroundDepth: Single;
    FPalette: array[0..1023] of Cardinal;
    FPaletteGen: Cardinal;
    FPaletteHash: UInt64;
    FFogTable: array[0..127] of Word;
    FBuffers: TArray<TTileBuffers>;
    FScaleX: Integer;
    procedure Prepare;
    procedure AddTriangle(Poly: Integer; I0, I1, I2: Integer; Volume: Integer);
    procedure Bin;
    procedure ReadRegions;
    procedure ReadBackground;
    function ShadePixel(Tri: Integer; PX, PY: Single; Modified: Boolean; Dest: Cardinal; out Alpha: Integer): Cardinal;
    function Fog(Color: Cardinal; TSP: Cardinal; Z: Single; const V: TPVRVertex): Cardinal;
    procedure RasterOpaque(B: PTileBuffers; TileX, TileY, List, Pass: Integer);
    procedure ApplyVolumes(B: PTileBuffers; TileX, TileY, List, Pass: Integer; Translucent: Boolean);
    procedure ShadeOpaque(B: PTileBuffers; TileX, TileY: Integer);
    procedure RasterTranslucent(B: PTileBuffers; TileX, TileY, Pass: Integer; Presort: Boolean);
    procedure WriteTile(B: PTileBuffers; TileX, TileY: Integer);
    function Covers(const T: TRenderTri; PX, PY: Single; out Z: Single): Boolean;
    function DepthPass(Mode: Cardinal; Z, Stored: Single): Boolean; inline;
  public
    PolygonsRendered: Integer;
    constructor Create(Memory: TDCMemory; PVR: TDCPVR; TA: TDCTA);
    destructor Destroy; override;
    // Renders the scene selected by PARAM_BASE/REGION_BASE; returns the
    // number of tiles drawn.
    function Render: Integer;
    // Tiles of the current render for worker threads (0..TileCount-1).
    procedure RenderTiles(First, Count, Slot: Integer);
    function TileCount: Integer;
  end;

implementation

const
  PVRISPBackgndD = $088;
  PVRISPBackgndT = $08C;
  PVRFPUShadScale = $074;
  PVRFPUCullVal = $078;
  PVRFPUParamCfg = $07C;
  PVRHalfOffset = $080;
  PVRFogColRAM = $0B0;
  PVRFogColVert = $0B4;
  PVRFogDensity = $0B8;
  PVRTextControl = $0E4;
  PVRPTAlphaRef = $11C;
  PVRScalerCtlReg = $0F4;
  PVRFogTable = $200;
  PVRPalette = $1000;
  DitherMatrix: array[0..15] of Integer = (0, 4, 1, 5, 6, 2, 7, 3, 1, 5, 0, 4, 7, 3, 6, 2);

function ARGB(A, R, G, B: Integer): Cardinal; inline;
begin
  Result := (Cardinal(A) shl 24) or (Cardinal(R) shl 16) or (Cardinal(G) shl 8) or Cardinal(B);
end;

function Clamp255(V: Integer): Integer; inline;
begin
  if V < 0 then
    Result := 0
  else if V > 255 then
    Result := 255
  else
    Result := V;
end;

function Lerp8(A, B, T: Integer): Integer; inline;
begin
  Result := A + ((B - A) * T + 127) div 255;
end;

{ TDCRenderer }

constructor TDCRenderer.Create(Memory: TDCMemory; PVR: TDCPVR; TA: TDCTA);
begin
  inherited Create;
  FMemory := Memory;
  FPVR := PVR;
  FTA := TA;
  FTextures := TPVRTextureCache.Create(Memory);
  SetLength(FBuffers, 1);
end;

destructor TDCRenderer.Destroy;
begin
  FTextures.Free;
  inherited;
end;

function TDCRenderer.TileCount: Integer;
begin
  Result := Length(FEntries);
end;

procedure TDCRenderer.AddTriangle(Poly: Integer; I0, I1, I2: Integer; Volume: Integer);
begin
  var V := FContext.Vertices;
  var X0 := V[I0].X;
  var Y0 := V[I0].Y;
  var X1 := V[I1].X;
  var Y1 := V[I1].Y;
  var X2 := V[I2].X;
  var Y2 := V[I2].Y;
  if FScaleX = 2 then
  begin
    X0 := X0 * 2;
    X1 := X1 * 2;
    X2 := X2 * 2;
  end;
  var Area := (X1 - X0) * (Y2 - Y0) - (X2 - X0) * (Y1 - Y0);
  if IsNan(Area) or (Abs(Area) < 1E-12) then
    Exit;
  var P := FContext.Polys[Poly];
  // Culling: 2 culls counter-clockwise (screen, y down), 3 clockwise.
  if P.Kind <> PolyModifier then
  begin
    var Cull := (P.ISP shr 27) and 3;
    var CullValue := PSingle(@FPVR.R[PVRFPUCullVal shr 2])^;
    if (Cull = 1) and (Abs(Area) < CullValue) then
      Exit;
    if (Cull = 2) and (Area < 0) then
      Exit;
    if (Cull = 3) and (Area > 0) then
      Exit;
  end;
  if FTriCount >= Length(FTris) then
    SetLength(FTris, Max(4096, Length(FTris) * 2));
  var T: PRenderTri := @FTris[FTriCount];
  T.Poly := Poly;
  T.V0 := I0;
  T.V1 := I1;
  T.V2 := I2;
  T.Volume := Volume;
  // Orient edges so inside is positive.
  var S: Single := 1;
  if Area < 0 then
    S := -1;
  T.EA[0] := (Y1 - Y2) * S; T.EB[0] := (X2 - X1) * S; T.EC[0] := (X1 * Y2 - X2 * Y1) * S;
  T.EA[1] := (Y2 - Y0) * S; T.EB[1] := (X0 - X2) * S; T.EC[1] := (X2 * Y0 - X0 * Y2) * S;
  T.EA[2] := (Y0 - Y1) * S; T.EB[2] := (X1 - X0) * S; T.EC[2] := (X0 * Y1 - X1 * Y0) * S;
  T.InvArea := 1 / Abs(Area);
  // Z plane from the barycentric weights.
  var Z0 := V[I0].Z;
  var Z1 := V[I1].Z;
  var Z2 := V[I2].Z;
  // Relative to vertex 0, so a constant depth stays exact.
  T.ZA := ((Z1 - Z0) * (Y2 - Y0) - (Z2 - Z0) * (Y1 - Y0)) / Area;
  T.ZB := ((Z2 - Z0) * (X1 - X0) - (Z1 - Z0) * (X2 - X0)) / Area;
  T.ZC := Z0;
  T.X0 := X0;
  T.Y0 := Y0;
  var MinXF := Min(X0, Min(X1, X2));
  var MaxXF := Max(X0, Max(X1, X2));
  var MinYF := Min(Y0, Min(Y1, Y2));
  var MaxYF := Max(Y0, Max(Y1, Y2));
  var Width := FTilesX * TileSize;
  var Height := FTilesY * TileSize;
  if (MaxXF < 0) or (MaxYF < 0) or (MinXF > Width) or (MinYF > Height) then
    Exit;
  T.MinX := EnsureRange(Floor(MinXF), 0, Width - 1);
  T.MaxX := EnsureRange(Ceil(MaxXF), 0, Width - 1);
  T.MinY := EnsureRange(Floor(MinYF), 0, Height - 1);
  T.MaxY := EnsureRange(Ceil(MaxYF), 0, Height - 1);
  Inc(FTriCount);
end;

procedure TDCRenderer.Prepare;
begin
  FTriCount := 0;
  SetLength(FPolys, FContext.PolyCount);
  var Volume := 0;
  var Stride := Integer(FPVR.R[PVRTextControl shr 2] and 31) * 32;
  var PalFormat := FPVR.R[PVRPalRamCtrl shr 2] and 3;
  for var I := 0 to FContext.PolyCount - 1 do
  begin
    var P := FContext.Polys[I];
    var RP := Default(TRenderPoly);
    RP.Translucent := P.List = TAListTranslucent;
    RP.PunchThrough := P.List = TAListPunchThrough;
    RP.Shadow := (P.PCW and $80) <> 0;
    if (P.Kind <> PolyModifier) and ((P.ISP and $02000000) <> 0) then
    begin
      RP.Texture := FTextures.Get(P.TCW, P.TSP, FPalette, PalFormat, FPaletteGen, Stride);
      if P.TwoVolume then
        RP.Texture1 := FTextures.Get(P.TCW1, P.TSP1, FPalette, PalFormat, FPaletteGen, Stride);
    end;
    FPolys[I] := RP;
    case P.Kind of
      PolyStrip:
        // Every other strip triangle is reversed to keep one winding;
        // the newest vertex stays last (flat shading uses it).
        for var K := 2 to P.Count - 1 do
          if Odd(K) then
            AddTriangle(I, P.First + K - 1, P.First + K - 2, P.First + K, 0)
          else
            AddTriangle(I, P.First + K - 2, P.First + K - 1, P.First + K, 0);
      PolySprite:
        begin
          AddTriangle(I, P.First, P.First + 1, P.First + 2, 0);
          AddTriangle(I, P.First, P.First + 2, P.First + 3, 0);
        end;
      PolyModifier:
        begin
          AddTriangle(I, P.First, P.First + 1, P.First + 2, Volume);
          if P.VolumeEnd <> 0 then
            Inc(Volume);
        end;
    end;
  end;
  FTextures.Trim(4096);
end;

procedure TDCRenderer.Bin;
begin
  // Counting sort of triangles into (tile, list) bins, in submission order.
  var Tiles := FTilesX * FTilesY;
  SetLength(FBinCount, Tiles * 5);
  SetLength(FBinStart, Tiles * 5 + 1);
  FillChar(FBinCount[0], Length(FBinCount) * SizeOf(Integer), 0);
  for var I := 0 to FTriCount - 1 do
  begin
    var T: PRenderTri := @FTris[I];
    var List := FContext.Polys[T.Poly].List;
    for var TY := T.MinY div TileSize to T.MaxY div TileSize do
      for var TX := T.MinX div TileSize to T.MaxX div TileSize do
        Inc(FBinCount[(TY * FTilesX + TX) * 5 + List]);
  end;
  var Sum := 0;
  for var I := 0 to High(FBinCount) do
  begin
    FBinStart[I] := Sum;
    Inc(Sum, FBinCount[I]);
    FBinCount[I] := 0;
  end;
  FBinStart[High(FBinStart)] := Sum;
  SetLength(FBinItems, Sum);
  for var I := 0 to FTriCount - 1 do
  begin
    var T: PRenderTri := @FTris[I];
    var List := FContext.Polys[T.Poly].List;
    for var TY := T.MinY div TileSize to T.MaxY div TileSize do
      for var TX := T.MinX div TileSize to T.MaxX div TileSize do
      begin
        var Bin := (TY * FTilesX + TX) * 5 + List;
        FBinItems[FBinStart[Bin] + FBinCount[Bin]] := I;
        Inc(FBinCount[Bin]);
      end;
  end;
end;

procedure TDCRenderer.ReadRegions;
begin
  // Region array (32-bit VRAM view): control word then five list pointers,
  // or six with FPU_PARAM_CFG bit 21. Repeated tiles are further passes.
  SetLength(FEntries, 0);
  var Address := FPVR.R[PVRRegionBase shr 2] and $7FFFFC;
  var Words := 6;
  if (FPVR.R[PVRFPUParamCfg shr 2] and $200000) <> 0 then
    Words := 6;
  var Seen: TArray<Integer>;
  SetLength(Seen, 64 * 64);
  var Count := 0;
  for var Guard := 0 to 64 * 64 * 4 - 1 do
  begin
    var Control := FMemory.VRAMRead32(Address);
    var E: TRegionEntry;
    E.Control := Control;
    for var L := 0 to 4 do
      E.Lists[L] := FMemory.VRAMRead32(Address + Cardinal(4 + L * 4));
    var TX := Integer((Control shr 2) and $3F);
    var TY := Integer((Control shr 8) and $3F);
    // Entries without lists (such as KallistiOS's initial tile) are not passes.
    E.Pass := Seen[TY * 64 + TX];
    var HasLists := False;
    for var L := 0 to 4 do
      if (E.Lists[L] and $80000000) = 0 then
        HasLists := True;
    if HasLists then
      Inc(Seen[TY * 64 + TX]);
    if Count >= Length(FEntries) then
      SetLength(FEntries, Count * 2 + 64);
    FEntries[Count] := E;
    Inc(Count);
    Inc(Address, Cardinal(Words) * 4);
    if (Control and $80000000) <> 0 then
      Break;
  end;
  SetLength(FEntries, Count);
end;

procedure TDCRenderer.ReadBackground;
begin
  // ISP_BACKGND_T: parameter word offset (bits 23..3) from PARAM_BASE and
  // extra words per vertex (26..24). The plane takes its first vertex colour.
  var Tag := FPVR.R[PVRISPBackgndT shr 2];
  var Base := (FPVR.R[PVRParamBase shr 2] and $F00000) + ((Tag shr 3) and $1FFFFF) * 4;
  var ISP := FMemory.VRAMRead32(Base);
  var Skip := (Tag shr 24) and 7;
  var VertexWords := 3 + Skip;
  var Textured := (ISP and $02000000) <> 0;
  if Textured then
    Inc(VertexWords, 0);
  // Colour follows X, Y, Z (and UV when textured).
  var ColorWord := 3;
  if Textured then
    ColorWord := 5;
  FBackground := FMemory.VRAMRead32(Base + 12 + Cardinal(ColorWord) * 4);
  if (FPVR.R[PVRFPUParamCfg shr 2] and 0) <> 0 then
    FBackground := 0;
  FBackgroundDepth := PSingle(@FPVR.R[PVRISPBackgndD shr 2])^;
end;

function TDCRenderer.Render: Integer;
begin
  Result := 0;
  PolygonsRendered := 0;
  FContext := FTA.Find(FPVR.R[PVRParamBase shr 2] and $7FFFFF);
  // Palette and fog table snapshots.
  var Hash: UInt64 := FPVR.R[PVRPalRamCtrl shr 2];
  for var I := 0 to 1023 do
  begin
    FPalette[I] := FPVR.R[(PVRPalette shr 2) + I];
    Hash := Hash * 1099511628211 + FPalette[I];
  end;
  if Hash <> FPaletteHash then
  begin
    FPaletteHash := Hash;
    Inc(FPaletteGen);
  end;
  for var I := 0 to 127 do
    FFogTable[I] := Word(FPVR.R[(PVRFogTable shr 2) + I]);
  FScaleX := 1;
  if (FPVR.R[PVRScalerCtlReg shr 2] and $10000) <> 0 then
    FScaleX := 2;
  ReadRegions;
  ReadBackground;
  var MaxX := 0;
  var MaxY := 0;
  for var E in FEntries do
  begin
    MaxX := Max(MaxX, Integer((E.Control shr 2) and $3F));
    MaxY := Max(MaxY, Integer((E.Control shr 8) and $3F));
  end;
  FTilesX := MaxX + 1;
  FTilesY := MaxY + 1;
  if FContext <> nil then
  begin
    Prepare;
    Bin;
    PolygonsRendered := FContext.PolyCount;
  end
  else
    FTriCount := 0;
  Result := Length(FEntries);
end;

function TDCRenderer.Covers(const T: TRenderTri; PX, PY: Single; out Z: Single): Boolean;
begin
  // Top-left rule approximated by a closed edge on the inside.
  Result := (T.EA[0] * PX + T.EB[0] * PY + T.EC[0] >= 0) and (T.EA[1] * PX + T.EB[1] * PY + T.EC[1] >= 0) and
    (T.EA[2] * PX + T.EB[2] * PY + T.EC[2] >= 0);
  Z := T.ZC + T.ZA * (PX - T.X0) + T.ZB * (PY - T.Y0);
end;

function TDCRenderer.DepthPass(Mode: Cardinal; Z, Stored: Single): Boolean;
begin
  case Mode of
    0: Result := False;
    1: Result := Z < Stored;
    2: Result := Z = Stored;
    3: Result := Z <= Stored;
    4: Result := Z > Stored;
    5: Result := Z <> Stored;
    6: Result := Z >= Stored;
  else
    Result := True;
  end;
end;

function TDCRenderer.Fog(Color: Cardinal; TSP: Cardinal; Z: Single; const V: TPVRVertex): Cardinal;
begin
  Result := Color;
  case (TSP shr 22) and 3 of
    0, 3:
      begin
        // Look-up table indexed by FOG_DENSITY * (1/w) on a log scale.
        var DensityReg := FPVR.R[PVRFogDensity shr 2];
        var Mantissa := ((DensityReg shr 8) and $FF) / 128.0;
        var Exponent := ShortInt(DensityReg and $FF);
        var X := Mantissa * Power(2, Exponent) * Z;
        var Index := 0;
        var Fraction := 0;
        if X >= 1 then
        begin
          var E := Floor(Log2(X));
          var M := X / Power(2, E);
          var Position := E * 16 + (M - 1) * 16;
          Index := EnsureRange(Floor(Position), 0, 127);
          Fraction := EnsureRange(Round((Position - Floor(Position)) * 255), 0, 255);
        end;
        var Entry := FFogTable[Index];
        var Factor := Lerp8(Entry shr 8, Entry and $FF, Fraction);
        var FogColor := FPVR.R[PVRFogColRAM shr 2];
        if ((TSP shr 22) and 3) = 3 then
        begin
          Result := (Cardinal(Factor) shl 24) or (FogColor and $FFFFFF);
          Exit;
        end;
        Result := ARGB(Color shr 24,
          Lerp8((Color shr 16) and $FF, (FogColor shr 16) and $FF, Factor),
          Lerp8((Color shr 8) and $FF, (FogColor shr 8) and $FF, Factor),
          Lerp8(Color and $FF, FogColor and $FF, Factor));
      end;
    1:
      begin
        // Per vertex: the offset colour's alpha blends towards FOG_COL_VERT.
        var Factor := Integer(V.Offset shr 24);
        var FogColor := FPVR.R[PVRFogColVert shr 2];
        Result := ARGB(Color shr 24,
          Lerp8((Color shr 16) and $FF, (FogColor shr 16) and $FF, Factor),
          Lerp8((Color shr 8) and $FF, (FogColor shr 8) and $FF, Factor),
          Lerp8(Color and $FF, FogColor and $FF, Factor));
      end;
  end;
end;

function SampleTexture(T: TPVRTexture; U, V: Single; TSP: Cardinal; Level: Integer): Cardinal;
var
  W, H: Integer;

  function Wrap(C, Size: Integer; Clamp, Flip: Boolean): Integer;
  begin
    if Clamp then
      Exit(EnsureRange(C, 0, Size - 1));
    if Flip then
    begin
      var Period := C mod (Size * 2);
      if Period < 0 then
        Inc(Period, Size * 2);
      if Period >= Size then
        Result := Size * 2 - 1 - Period
      else
        Result := Period;
    end
    else
    begin
      Result := C mod Size;
      if Result < 0 then
        Inc(Result, Size);
    end;
  end;

  function Fetch(X, Y: Integer): Cardinal;
  begin
    X := Wrap(X, W, (TSP and $10000) <> 0, (TSP and $40000) <> 0);
    Y := Wrap(Y, H, (TSP and $8000) <> 0, (TSP and $20000) <> 0);
    Result := T.Texels[T.LevelOffset[Level] + Y * W + X];
  end;

begin
  if Level >= T.Levels then
    Level := T.Levels - 1;
  W := Max(1, T.Width shr Level);
  H := Max(1, T.Height shr Level);
  var FU := U * W;
  var FV := V * H;
  if IsNan(FU) or IsNan(FV) or (Abs(FU) > 1E8) or (Abs(FV) > 1E8) then
    Exit(T.Texels[0]);
  if ((TSP shr 13) and 3) = 0 then
    Exit(Fetch(Floor(FU), Floor(FV)));
  // Bilinear (trilinear passes are treated as bilinear on one level).
  FU := FU - 0.5;
  FV := FV - 0.5;
  var X0 := Floor(FU);
  var Y0 := Floor(FV);
  var FX := Round((FU - X0) * 256);
  var FY := Round((FV - Y0) * 256);
  var C00 := Fetch(X0, Y0);
  var C10 := Fetch(X0 + 1, Y0);
  var C01 := Fetch(X0, Y0 + 1);
  var C11 := Fetch(X0 + 1, Y0 + 1);
  Result := 0;
  for var Shift := 0 to 3 do
  begin
    var S := Shift * 8;
    var A := Integer((C00 shr S) and $FF) * (256 - FX) + Integer((C10 shr S) and $FF) * FX;
    var B := Integer((C01 shr S) and $FF) * (256 - FX) + Integer((C11 shr S) and $FF) * FX;
    var C := (A * (256 - FY) + B * FY + 32768) shr 16;
    Result := Result or (Cardinal(Clamp255(C)) shl S);
  end;
end;

function TDCRenderer.ShadePixel(Tri: Integer; PX, PY: Single; Modified: Boolean; Dest: Cardinal; out Alpha: Integer): Cardinal;
begin
  var T: PRenderTri := @FTris[Tri];
  var P: PPVRPoly := @FContext.Polys[T.Poly];
  var RP: PRenderPoly := @FPolys[T.Poly];
  var Vs := FContext.Vertices;
  var VA: PPVRVertex := @Vs[T.V0];
  var VB: PPVRVertex := @Vs[T.V1];
  var VC: PPVRVertex := @Vs[T.V2];
  // Perspective-correct barycentrics from screen weights and 1/w.
  var W0 := (T.EA[0] * PX + T.EB[0] * PY + T.EC[0]) * T.InvArea;
  var W1 := (T.EA[1] * PX + T.EB[1] * PY + T.EC[1]) * T.InvArea;
  var W2 := 1 - W0 - W1;
  var Z := W0 * VA.Z + W1 * VB.Z + W2 * VC.Z;
  var P0, P1, P2: Single;
  if (Z <> 0) and not IsNan(Z) and (VA.Z > 0) and (VB.Z > 0) and (VC.Z > 0) then
  begin
    P0 := W0 * VA.Z / Z;
    P1 := W1 * VB.Z / Z;
    P2 := W2 * VC.Z / Z;
  end
  else
  begin
    P0 := W0;
    P1 := W1;
    P2 := W2;
  end;
  // Second parameter set inside a modifier volume (two-volume polygons).
  var UseSecond := Modified and RP.Shadow and P.TwoVolume;
  var TSP := P.TSP;
  var Texture := RP.Texture;
  if UseSecond then
  begin
    TSP := P.TSP1;
    Texture := RP.Texture1;
  end;
  var Base, Offset: Cardinal;
  var Gouraud := (P.ISP and $00800000) <> 0;
  if UseSecond then
  begin
    if Gouraud then
    begin
      Base := 0;
      Offset := 0;
      for var S := 0 to 3 do
      begin
        var Sh := S * 8;
        Base := Base or (Cardinal(Clamp255(Round(((VA.Base1 shr Sh) and $FF) * P0 + ((VB.Base1 shr Sh) and $FF) * P1 +
          ((VC.Base1 shr Sh) and $FF) * P2))) shl Sh);
        Offset := Offset or (Cardinal(Clamp255(Round(((VA.Offset1 shr Sh) and $FF) * P0 + ((VB.Offset1 shr Sh) and $FF) * P1 +
          ((VC.Offset1 shr Sh) and $FF) * P2))) shl Sh);
      end;
    end
    else
    begin
      Base := VC.Base1;
      Offset := VC.Offset1;
    end;
  end
  else if Gouraud and (P.Kind = PolyStrip) then
  begin
    Base := 0;
    Offset := 0;
    for var S := 0 to 3 do
    begin
      var Sh := S * 8;
      Base := Base or (Cardinal(Clamp255(Round(((VA.Base shr Sh) and $FF) * P0 + ((VB.Base shr Sh) and $FF) * P1 +
        ((VC.Base shr Sh) and $FF) * P2))) shl Sh);
      Offset := Offset or (Cardinal(Clamp255(Round(((VA.Offset shr Sh) and $FF) * P0 + ((VB.Offset shr Sh) and $FF) * P1 +
        ((VC.Offset shr Sh) and $FF) * P2))) shl Sh);
    end;
  end
  else
  begin
    Base := VC.Base;
    Offset := VC.Offset;
  end;
  var Color := Base;
  if Texture <> nil then
  begin
    var U, V: Single;
    if UseSecond then
    begin
      U := VA.U1 * P0 + VB.U1 * P1 + VC.U1 * P2;
      V := VA.V1 * P0 + VB.V1 * P1 + VC.V1 * P2;
    end
    else
    begin
      U := VA.U * P0 + VB.U * P1 + VC.U * P2;
      V := VA.V * P0 + VB.V * P1 + VC.V * P2;
    end;
    // Mipmap level from the texel footprint of one pixel.
    var Level := 0;
    if Texture.Levels > 1 then
    begin
      var DUX := (VA.U * T.EA[0] + VB.U * T.EA[1] - VC.U * (T.EA[0] + T.EA[1])) * T.InvArea * Texture.Width;
      var DVY := (VA.V * T.EB[0] + VB.V * T.EB[1] - VC.V * (T.EB[0] + T.EB[1])) * T.InvArea * Texture.Height;
      var Footprint := Max(Abs(DUX), Abs(DVY));
      var DAdjust := ((TSP shr 8) and 15) / 4.0;
      if DAdjust = 0 then
        DAdjust := 1;
      Footprint := Footprint * DAdjust;
      if Footprint > 1 then
        Level := EnsureRange(Floor(Log2(Footprint)), 0, Texture.Levels - 1);
    end;
    var Tex := SampleTexture(Texture, U, V, TSP, Level);
    if (TSP and $80000) <> 0 then
      Tex := Tex or $FF000000;
    var TA_ := Integer(Tex shr 24);
    var TR := Integer((Tex shr 16) and $FF);
    var TG := Integer((Tex shr 8) and $FF);
    var TB := Integer(Tex and $FF);
    var CA := Integer(Base shr 24);
    var CR := Integer((Base shr 16) and $FF);
    var CG := Integer((Base shr 8) and $FF);
    var CB := Integer(Base and $FF);
    var A, R, G, B: Integer;
    case (TSP shr 6) and 3 of
      0:
        begin
          R := TR; G := TG; B := TB; A := TA_;
        end;
      1:
        begin
          R := (CR * TR + 127) div 255; G := (CG * TG + 127) div 255; B := (CB * TB + 127) div 255; A := TA_;
        end;
      2:
        begin
          R := (TR * TA_ + CR * (255 - TA_) + 127) div 255;
          G := (TG * TA_ + CG * (255 - TA_) + 127) div 255;
          B := (TB * TA_ + CB * (255 - TA_) + 127) div 255;
          A := CA;
        end;
    else
      begin
        R := (CR * TR + 127) div 255; G := (CG * TG + 127) div 255; B := (CB * TB + 127) div 255;
        A := (CA * TA_ + 127) div 255;
      end;
    end;
    if (P.ISP and $01000000) <> 0 then
    begin
      R := Clamp255(R + Integer((Offset shr 16) and $FF));
      G := Clamp255(G + Integer((Offset shr 8) and $FF));
      B := Clamp255(B + Integer(Offset and $FF));
    end;
    Color := ARGB(A, R, G, B);
  end;
  if (TSP and $100000) = 0 then
    Color := Color or $FF000000;
  // Cheap shadow: polygons with the shadow bit are darkened inside volumes.
  if Modified and RP.Shadow and not P.TwoVolume then
  begin
    var Scale := FPVR.R[PVRFPUShadScale shr 2];
    if (Scale and $100) <> 0 then
    begin
      var F := Integer(Scale and $FF);
      Color := ARGB(Color shr 24, ((Color shr 16) and $FF) * F div 256, ((Color shr 8) and $FF) * F div 256,
        (Color and $FF) * F div 256);
    end;
  end;
  Color := Fog(Color, TSP, Z, VC^);
  Alpha := Integer(Color shr 24);
  Result := Color;
end;

procedure TDCRenderer.RasterOpaque(B: PTileBuffers; TileX, TileY, List, Pass: Integer);
begin
  var Bin := (TileY * FTilesX + TileX) * 5 + List;
  var PTRef := Integer(FPVR.R[PVRPTAlphaRef shr 2] and $FF);
  for var K := FBinStart[Bin] to FBinStart[Bin] + FBinCount[Bin] - 1 do
  begin
    var Index := FBinItems[K];
    var T: PRenderTri := @FTris[Index];
    var P: PPVRPoly := @FContext.Polys[T.Poly];
    if P.Pass <> Pass then
      Continue;
    var Mode := P.ISP shr 29;
    var ZWrite := (P.ISP and $04000000) = 0;
    var X0 := Max(T.MinX - TileX * TileSize, 0);
    var X1 := Min(T.MaxX - TileX * TileSize, TileSize - 1);
    var Y0 := Max(T.MinY - TileY * TileSize, 0);
    var Y1 := Min(T.MaxY - TileY * TileSize, TileSize - 1);
    for var Y := Y0 to Y1 do
    begin
      var PY := TileY * TileSize + Y + 0.5;
      for var X := X0 to X1 do
      begin
        var PX := TileX * TileSize + X + 0.5;
        var Z: Single;
        if not Covers(T^, PX, PY, Z) then
          Continue;
        var I := Y * TileSize + X;
        // Depth equal to the background plane passes greater-than tests.
        if not DepthPass(Mode, Z, B.Depth[I]) and not ((B.Tag[I] < 0) and (Mode in [4, 6]) and (Z = B.Depth[I])) then
          Continue;
        if List = TAListPunchThrough then
        begin
          var Alpha: Integer;
          ShadePixel(Index, PX, PY, False, 0, Alpha);
          if Alpha < PTRef then
            Continue;
        end;
        if ZWrite then
          B.Depth[I] := Z;
        B.Tag[I] := Index;
        B.Fresh[I] := 1;
      end;
    end;
  end;
end;

procedure TDCRenderer.ApplyVolumes(B: PTileBuffers; TileX, TileY, List, Pass: Integer; Translucent: Boolean);
begin
  // Parity of volume faces in front of the stored depth marks pixels inside;
  // the closing triangle's instruction decides inside/outside modification.
  var Bin := (TileY * FTilesX + TileX) * 5 + List;
  if FBinCount[Bin] = 0 then
    Exit;
  FillChar(B.Stencil, SizeOf(B.Stencil), 0);
  for var K := FBinStart[Bin] to FBinStart[Bin] + FBinCount[Bin] - 1 do
  begin
    var Index := FBinItems[K];
    var T: PRenderTri := @FTris[Index];
    var P: PPVRPoly := @FContext.Polys[T.Poly];
    if P.Pass <> Pass then
      Continue;
    var X0 := Max(T.MinX - TileX * TileSize, 0);
    var X1 := Min(T.MaxX - TileX * TileSize, TileSize - 1);
    var Y0 := Max(T.MinY - TileY * TileSize, 0);
    var Y1 := Min(T.MaxY - TileY * TileSize, TileSize - 1);
    for var Y := Y0 to Y1 do
      for var X := X0 to X1 do
      begin
        var Z: Single;
        var I := Y * TileSize + X;
        if Covers(T^, TileX * TileSize + X + 0.5, TileY * TileSize + Y + 0.5, Z) and (Z > B.Depth[I]) then
          B.Stencil[I] := B.Stencil[I] xor 1;
      end;
    if P.VolumeEnd <> 0 then
    begin
      for var I := 0 to TileSize * TileSize - 1 do
      begin
        var Inside := B.Stencil[I] <> 0;
        if ((P.VolumeEnd = 1) and Inside) or ((P.VolumeEnd = 2) and not Inside) then
          B.Modified[I] := 1;
      end;
      FillChar(B.Stencil, SizeOf(B.Stencil), 0);
    end;
  end;
end;

procedure TDCRenderer.ShadeOpaque(B: PTileBuffers; TileX, TileY: Integer);
begin
  for var Y := 0 to TileSize - 1 do
    for var X := 0 to TileSize - 1 do
    begin
      var I := Y * TileSize + X;
      if B.Fresh[I] = 0 then
        Continue;
      B.Fresh[I] := 0;
      var Tag := B.Tag[I];
      if Tag < 0 then
      begin
        B.Color[I] := FBackground;
        Continue;
      end;
      var Alpha: Integer;
      B.Color[I] := ShadePixel(Tag, TileX * TileSize + X + 0.5, TileY * TileSize + Y + 0.5, B.Modified[I] <> 0, B.Color[I], Alpha);
    end;
end;

function BlendFactor(Instr: Cardinal; Src, Dst: Cardinal; Channel: Integer; Other: Cardinal): Integer; inline;
begin
  case Instr of
    0: Result := 0;
    1: Result := 255;
    2: Result := Integer((Other shr Channel) and $FF);
    3: Result := 255 - Integer((Other shr Channel) and $FF);
    4: Result := Integer(Src shr 24);
    5: Result := 255 - Integer(Src shr 24);
    6: Result := Integer(Dst shr 24);
  else
    Result := 255 - Integer(Dst shr 24);
  end;
end;

function Blend(Src, Dst, TSP: Cardinal): Cardinal;
begin
  var SrcInstr := TSP shr 29;
  var DstInstr := (TSP shr 26) and 7;
  Result := 0;
  for var S := 0 to 3 do
  begin
    var Sh := S * 8;
    // The source factor's "other" colour is the destination and vice versa.
    var FS := BlendFactor(SrcInstr, Src, Dst, Sh, Dst);
    var FD := BlendFactor(DstInstr, Src, Dst, Sh, Src);
    var V := (Integer((Src shr Sh) and $FF) * FS + Integer((Dst shr Sh) and $FF) * FD + 127) div 255;
    Result := Result or (Cardinal(Clamp255(V)) shl Sh);
  end;
end;

procedure TDCRenderer.RasterTranslucent(B: PTileBuffers; TileX, TileY, Pass: Integer; Presort: Boolean);
begin
  var Bin := (TileY * FTilesX + TileX) * 5 + TAListTranslucent;
  if FBinCount[Bin] = 0 then
    Exit;
  if Presort then
  begin
    for var K := FBinStart[Bin] to FBinStart[Bin] + FBinCount[Bin] - 1 do
    begin
      var Index := FBinItems[K];
      var T: PRenderTri := @FTris[Index];
      var P: PPVRPoly := @FContext.Polys[T.Poly];
      if P.Pass <> Pass then
        Continue;
      var Mode := P.ISP shr 29;
      var ZWrite := (P.ISP and $04000000) = 0;
      var X0 := Max(T.MinX - TileX * TileSize, 0);
      var X1 := Min(T.MaxX - TileX * TileSize, TileSize - 1);
      var Y0 := Max(T.MinY - TileY * TileSize, 0);
      var Y1 := Min(T.MaxY - TileY * TileSize, TileSize - 1);
      for var Y := Y0 to Y1 do
        for var X := X0 to X1 do
        begin
          var PX := TileX * TileSize + X + 0.5;
          var PY := TileY * TileSize + Y + 0.5;
          var Z: Single;
          if not Covers(T^, PX, PY, Z) then
            Continue;
          var I := Y * TileSize + X;
          if not DepthPass(Mode, Z, B.Depth[I]) then
            Continue;
          if ZWrite then
            B.Depth[I] := Z;
          var Alpha: Integer;
          var Src := ShadePixel(Index, PX, PY, B.Modified[I] <> 0, B.Color[I], Alpha);
          B.Color[I] := Blend(Src, B.Color[I], P.TSP);
        end;
    end;
    Exit;
  end;
  // Autosort: repeatedly pick, per pixel, the farthest fragment behind the
  // previous layer (smaller 1/w is farther); ties follow submission order.
  for var I := 0 to TileSize * TileSize - 1 do
  begin
    B.PeelDepth[I] := -1E30;
    B.PeelTag[I] := -1;
  end;
  for var Layer := 0 to 255 do
  begin
    var Any := False;
    for var I := 0 to TileSize * TileSize - 1 do
    begin
      B.BestDepth[I] := 1E30;
      B.BestTag[I] := -1;
    end;
    for var K := FBinStart[Bin] to FBinStart[Bin] + FBinCount[Bin] - 1 do
    begin
      var Index := FBinItems[K];
      var T: PRenderTri := @FTris[Index];
      var P: PPVRPoly := @FContext.Polys[T.Poly];
      if P.Pass <> Pass then
        Continue;
      var X0 := Max(T.MinX - TileX * TileSize, 0);
      var X1 := Min(T.MaxX - TileX * TileSize, TileSize - 1);
      var Y0 := Max(T.MinY - TileY * TileSize, 0);
      var Y1 := Min(T.MaxY - TileY * TileSize, TileSize - 1);
      for var Y := Y0 to Y1 do
        for var X := X0 to X1 do
        begin
          var Z: Single;
          if not Covers(T^, TileX * TileSize + X + 0.5, TileY * TileSize + Y + 0.5, Z) then
            Continue;
          var I := Y * TileSize + X;
          // In front of the opaque surface.
          if Z < B.Depth[I] then
            Continue;
          // Strictly after the previous layer in (depth, order).
          if (Z < B.PeelDepth[I]) or ((Z = B.PeelDepth[I]) and (Index <= B.PeelTag[I])) then
            Continue;
          if (Z < B.BestDepth[I]) or ((Z = B.BestDepth[I]) and (Index < B.BestTag[I])) then
          begin
            B.BestDepth[I] := Z;
            B.BestTag[I] := Index;
          end;
        end;
    end;
    for var I := 0 to TileSize * TileSize - 1 do
    begin
      var Tag := B.BestTag[I];
      if Tag < 0 then
        Continue;
      Any := True;
      B.PeelDepth[I] := B.BestDepth[I];
      B.PeelTag[I] := Tag;
      var X := I mod TileSize;
      var Y := I div TileSize;
      var Alpha: Integer;
      var Src := ShadePixel(Tag, TileX * TileSize + X + 0.5, TileY * TileSize + Y + 0.5, B.Modified[I] <> 0, B.Color[I], Alpha);
      B.Color[I] := Blend(Src, B.Color[I], FContext.Polys[FTris[Tag].Poly].TSP);
    end;
    if not Any then
      Break;
  end;
end;

procedure TDCRenderer.WriteTile(B: PTileBuffers; TileX, TileY: Integer);
begin
  var Ctrl := FPVR.R[PVRFBWCtrl shr 2];
  var Pack := Ctrl and 7;
  var Dither := (Ctrl and 8) <> 0;
  var KVal := (Ctrl shr 8) and $FF;
  var AlphaThreshold := (Ctrl shr 16) and $FF;
  var Stride := (FPVR.R[PVRFBWLineStride shr 2] and $1FF) * 8;
  var Base := FPVR.R[PVRFBWSOF1 shr 2] and $1FFFFFF;
  var ToTexture := (Base and $1000000) <> 0;
  var ClipX := FPVR.R[PVRFBXClip shr 2];
  var ClipY := FPVR.R[PVRFBYClip shr 2];
  var MinX := Integer(ClipX and $7FF);
  var MaxX := Integer((ClipX shr 16) and $7FF);
  var MinY := Integer(ClipY and $3FF);
  var MaxY := Integer((ClipY shr 16) and $3FF);
  var Bytes: Integer;
  case Pack of
    0..3: Bytes := 2;
    4: Bytes := 3;
  else
    Bytes := 4;
  end;
  var Width := TileSize div FScaleX;
  for var Y := 0 to TileSize - 1 do
  begin
    var SY := TileY * TileSize + Y;
    if (SY < MinY) or (SY > MaxY) then
      Continue;
    for var X := 0 to Width - 1 do
    begin
      var SX := TileX * Width + X;
      if (SX < MinX) or (SX > MaxX) then
        Continue;
      var C: Cardinal;
      if FScaleX = 2 then
      begin
        // Horizontal 2x supersampling: average neighbouring samples.
        var C0 := B.Color[Y * TileSize + X * 2];
        var C1 := B.Color[Y * TileSize + X * 2 + 1];
        C := (((C0 shr 1) and $7F7F7F7F) + ((C1 shr 1) and $7F7F7F7F));
      end
      else
        C := B.Color[Y * TileSize + X];
      var A := Integer(C shr 24);
      var R := Integer((C shr 16) and $FF);
      var G := Integer((C shr 8) and $FF);
      var BB := Integer(C and $FF);
      if Dither and (Bytes = 2) then
      begin
        // 4x4 ordered dither before truncation to 5/6 bits.
        var D := DitherMatrix[(SY and 3) * 4 + (SX and 3)];
        R := Min(255, R + D);
        G := Min(255, G + D shr 1);
        BB := Min(255, BB + D);
      end;
      var V: Cardinal;
      case Pack of
        0: V := (Cardinal(R shr 3) shl 10) or (Cardinal(G shr 3) shl 5) or Cardinal(BB shr 3) or ((KVal shr 7) shl 15);
        1: V := (Cardinal(R shr 3) shl 11) or (Cardinal(G shr 2) shl 5) or Cardinal(BB shr 3);
        2: V := (Cardinal(A shr 4) shl 12) or (Cardinal(R shr 4) shl 8) or (Cardinal(G shr 4) shl 4) or Cardinal(BB shr 4);
        3:
          begin
            V := (Cardinal(R shr 3) shl 10) or (Cardinal(G shr 3) shl 5) or Cardinal(BB shr 3);
            if Cardinal(A) >= AlphaThreshold then
              V := V or $8000;
          end;
        4, 5: V := (Cardinal(R) shl 16) or (Cardinal(G) shl 8) or Cardinal(BB) or (KVal shl 24);
      else
        V := C;
      end;
      var Offset := Base + Cardinal(SY) * Stride + Cardinal(SX * Bytes);
      if ToTexture then
      begin
        if Bytes = 2 then
          FMemory.VRAMWrite64Path(Offset and $7FFFFF, V, 2)
        else
          FMemory.VRAMWrite64Path(Offset and $7FFFFF, V, 4);
        Continue;
      end;
      var P := FMemory.VRAM + (Offset and $7FFFFF);
      case Bytes of
        2: PWord(FMemory.VRAM + (Offset and $7FFFFE))^ := Word(V);
        3:
          begin
            P^ := Byte(V);
            (FMemory.VRAM + ((Offset + 1) and $7FFFFF))^ := Byte(V shr 8);
            (FMemory.VRAM + ((Offset + 2) and $7FFFFF))^ := Byte(V shr 16);
          end;
      else
        PCardinal(FMemory.VRAM + (Offset and $7FFFFC))^ := V;
      end;
    end;
  end;
end;

procedure TDCRenderer.RenderTiles(First, Count, Slot: Integer);
begin
  if Slot >= Length(FBuffers) then
    Exit;
  var B: PTileBuffers := @FBuffers[Slot];
  var LastTile := -1;
  for var N := First to First + Count - 1 do
  begin
    var E := FEntries[N];
    var TX := Integer((E.Control shr 2) and $3F);
    var TY := Integer((E.Control shr 8) and $3F);
    if (TX >= FTilesX) or (TY >= FTilesY) then
      Continue;
    var Tile := TY * FTilesX + TX;
    // Depth clears unless z_keep (bit 30); colour persists within a tile.
    if Tile <> LastTile then
    begin
      for var I := 0 to TileSize * TileSize - 1 do
        B.Color[I] := FBackground;
      LastTile := Tile;
    end;
    if (E.Control and $40000000) = 0 then
      for var I := 0 to TileSize * TileSize - 1 do
      begin
        B.Depth[I] := FBackgroundDepth;
        B.Tag[I] := -1;
        B.Fresh[I] := 1;
      end;
    FillChar(B.Modified, SizeOf(B.Modified), 0);
    if FContext <> nil then
    begin
      if (E.Lists[0] and $80000000) = 0 then
        RasterOpaque(B, TX, TY, TAListOpaque, E.Pass);
      if (E.Lists[4] and $80000000) = 0 then
        RasterOpaque(B, TX, TY, TAListPunchThrough, E.Pass);
      if (E.Lists[1] and $80000000) = 0 then
        ApplyVolumes(B, TX, TY, TAListOpaqueMod, E.Pass, False);
    end;
    ShadeOpaque(B, TX, TY);
    if (FContext <> nil) and ((E.Lists[2] and $80000000) = 0) then
    begin
      FillChar(B.Modified, SizeOf(B.Modified), 0);
      if (E.Lists[3] and $80000000) = 0 then
        ApplyVolumes(B, TX, TY, TAListTranslucentMod, E.Pass, True);
      RasterTranslucent(B, TX, TY, E.Pass, (E.Control and $20000000) <> 0);
    end;
    // no_writeout (bit 28) keeps the tile for a following pass.
    if (E.Control and $10000000) = 0 then
      WriteTile(B, TX, TY);
  end;
end;

end.
