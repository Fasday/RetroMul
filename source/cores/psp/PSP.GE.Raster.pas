unit PSP.GE.Raster;

// The GE back end: rasterization of points, lines, triangles and sprites
// and the pixel pipeline (texture, fog, tests, stencil, depth, blend,
// dither, logic op, masks). Everything here is a pure function of a
// TGERaster snapshot, the primitive's vertices and guest memory, so a
// primitive can be drawn by any thread for any band of rows, and the same
// integer arithmetic can run in a compute shader.
//
// Screen positions are 1/16 pixel fixed point relative to the drawing
// origin; a pixel is covered when its centre (x + 0.5, y + 0.5) is inside,
// with the top-left fill rule.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}

interface

uses
  System.SysUtils, System.Math, PSP.Types, PSP.Memory, PSP.GE.Texture;

type
  TGEVertex = record
    X, Y: Integer;       // 1/16 pixel, drawing area
    Z: Integer;          // depth as computed (may be outside 0..65535)
    W: Single;           // 1/w for perspective (1 in through mode)
    R, G, B, A: Integer; // primary colour, 0..255
    SR, SG, SB: Integer; // secondary (specular) colour
    S, T: Single;        // texture coordinates in texels, still to divide by Q
    Q: Single;           // texture projection divisor (1 but for TEXMAPMODE's matrix)
    Fog: Single;         // 0 = fog colour, 1 = no fog
  end;
  PGEVertex = ^TGEVertex;

  TGERaster = record
    VRAM: PByte;
    FBAddr, FBStride, FBFormat: Cardinal;
    ZAddr, ZStride: Cardinal;
    ZPermutation: Integer;
    ScissorX1, ScissorY1, ScissorX2, ScissorY2: Integer;
    // Rows this pass may touch (a band for a render thread).
    BandY1, BandY2: Integer;
    Through: Boolean;
    ClearMode: Boolean;
    ClearColor, ClearStencil, ClearDepth: Boolean;
    Flat: Boolean;
    Gouraud: Boolean;
    Textured: Boolean;
    Tex: TGETexture;
    TexFunc: Integer;
    TexAlpha: Boolean;
    ColorDouble: Boolean;
    EnvR, EnvG, EnvB: Integer;
    FogEnabled: Boolean;
    FogR, FogG, FogB: Integer;
    ColorTest: Boolean;
    ColorTestFunc: Integer;
    ColorRef, ColorMask: Cardinal;
    AlphaTest: Boolean;
    AlphaFunc, AlphaRef, AlphaMask: Integer;
    StencilTest: Boolean;
    StencilFunc, StencilRef, StencilMask: Integer;
    StencilFail, StencilZFail, StencilZPass: Integer;
    DepthTest: Boolean;
    DepthFunc: Integer;
    DepthWrite: Boolean;
    MinZ, MaxZ: Integer;
    DepthClamp: Boolean;
    Blend: Boolean;
    BlendOp, BlendSrc, BlendDst: Integer;
    FixA, FixB: Cardinal;
    Dither: Boolean;
    DitherMatrix: array[0..15] of Integer;
    LogicOp: Boolean;
    LogicFunc: Integer;
    MaskRGB: Cardinal;
    MaskA: Integer;
    // Derived by GEPrepareRaster: the pixel bits the masks keep.
    KeepMask: Cardinal;
  end;

// Fills in the fields derived from the others.
procedure GEPrepareRaster(var S: TGERaster);
procedure GEDrawTriangle(const S: TGERaster; const V0, V1, V2: TGEVertex);
procedure GEDrawSprite(const S: TGERaster; const V0, V1: TGEVertex);
procedure GEDrawLine(const S: TGERaster; const V0, V1: TGEVertex);
procedure GEDrawPoint(const S: TGERaster; const V: TGEVertex);

implementation

type
  TGEFragment = record
    R, G, B, A: Integer;
    SR, SG, SB: Integer;
    Z: Integer;
    S, T: Single;
    Fog: Single;
    // Level of detail in 1/16 levels when the texture needs it.
    Lod: Integer;
  end;

// The level of detail: TEXLEVEL's mode picks the texels per pixel (Scale,
// in level 0 texels), TEXLODSLOPE times w, or only the bias.
function TexLod(const S: TGERaster; Scale, W: Single): Integer;
begin
  case S.Tex.LevelMode of
    0: Result := GELog16(Scale) + S.Tex.LodBias;
    2: Result := GELog16(S.Tex.Slope * W) + 16 + S.Tex.LodBias;
  else
    Result := S.Tex.LodBias;
  end;
end;

// Raster interpolants are bounded to signed 32 bits. Use the SSE conversion
// directly, with the same rounding mode as Round(), without its Int64 helper.
function GERound(X: Double): Integer; {$IFDEF CPUX64}assembler;{$ELSE}inline;{$ENDIF}
{$IFDEF CPUX64}
asm
  .NOFRAME
  CVTSD2SI EAX, XMM0
end;
{$ELSE}
begin
  Result := Round(X);
end;
{$ENDIF}

function Clamp255(V: Integer): Integer; inline;
begin
  if V < 0 then
    Result := 0
  else if V > 255 then
    Result := 255
  else
    Result := V;
end;

function TestFunc(Func, A, B: Integer): Boolean; inline;
begin
  case Func of
    0: Result := False;
    1: Result := True;
    2: Result := A = B;
    3: Result := A <> B;
    4: Result := A < B;
    5: Result := A <= B;
    6: Result := A > B;
    7: Result := A >= B;
  else
    Result := True;
  end;
end;

// The framebuffer's alpha bits as an 8-bit stencil value.
function StencilOf(Format, Pixel: Cardinal): Integer; inline;
begin
  case Format of
    1: Result := Ord((Pixel and $8000) <> 0) * 255;
    2: Result := (Pixel shr 12) * 17;
    3: Result := Pixel shr 24;
  else
    Result := 0;
  end;
end;

function StencilOp(Op, Format, Old, Ref: Integer): Integer;
begin
  // Values are in the format's own stencil precision.
  var Max: Integer;
  case Format of
    1: Max := 1;
    2: Max := 15;
    3: Max := 255;
  else
    Max := 0;
  end;
  case Op of
    0: Result := Old;
    1: Result := 0;
    2:
      case Format of
        1: Result := Ref shr 7;
        2: Result := Ref shr 4;
      else
        Result := Ref;
      end;
    3: Result := (not Old) and Max;
    4: if Old < Max then Result := Old + 1 else Result := Max;
    5: if Old > 0 then Result := Old - 1 else Result := 0;
  else
    Result := Old;
  end;
end;

function RawStencil(Format, Pixel: Cardinal): Integer; inline;
begin
  case Format of
    1: Result := (Pixel shr 15) and 1;
    2: Result := (Pixel shr 12) and $F;
    3: Result := Pixel shr 24;
  else
    Result := 0;
  end;
end;

// One side of the blend equation: a colour times its factor. The colour
// counts as (c + 1) / 256; doubled factors double the product, "one minus
// double" factors clamp at zero.
function BlendTerm(Kind, C, Other, SA, DA, Fix: Integer): Integer; inline;
begin
  case Kind of
    0: Result := ((C + 1) * Other) shr 8;
    1: Result := ((C + 1) * (255 - Other)) shr 8;
    2: Result := ((C + 1) * SA) shr 8;
    3: Result := ((C + 1) * (255 - SA)) shr 8;
    4: Result := ((C + 1) * DA) shr 8;
    5: Result := ((C + 1) * (255 - DA)) shr 8;
    6: Result := (((C + 1) * SA) shr 8) * 2;
    7: Result := ((C + 1) * Max(0, 255 - 2 * SA)) shr 8;
    8: Result := (((C + 1) * DA) shr 8) * 2;
    9: Result := ((C + 1) * Max(0, 255 - 2 * DA)) shr 8;
  else
    Result := ((C + 1) * Fix) shr 8;
  end;
end;

function BlendChannel(const S: TGERaster; SC, DC, SA, DA, Shift: Integer): Integer; inline;
begin
  case S.BlendOp of
    0..2:
      begin
        var A := BlendTerm(S.BlendSrc, SC, DC, SA, DA, (S.FixA shr Shift) and $FF);
        var B := BlendTerm(S.BlendDst, DC, SC, SA, DA, (S.FixB shr Shift) and $FF);
        case S.BlendOp of
          0: Result := A + B;
          1: Result := A - B;
        else
          Result := B - A;
        end;
      end;
    3: Result := Min(SC, DC);
    4: Result := Max(SC, DC);
  else
    Result := Abs(SC - DC);
  end;
end;

procedure DecodePixel(Format, P: Cardinal; out R, G, B, A: Integer); inline;
begin
  case Format of
    0:
      begin
        R := P and $1F; R := (R shl 3) or (R shr 2);
        G := (P shr 5) and $3F; G := (G shl 2) or (G shr 4);
        B := (P shr 11) and $1F; B := (B shl 3) or (B shr 2);
        A := 0;
      end;
    1:
      begin
        R := P and $1F; R := (R shl 3) or (R shr 2);
        G := (P shr 5) and $1F; G := (G shl 3) or (G shr 2);
        B := (P shr 10) and $1F; B := (B shl 3) or (B shr 2);
        A := Ord((P and $8000) <> 0) * 255;
      end;
    2:
      begin
        R := (P and $F) * 17;
        G := ((P shr 4) and $F) * 17;
        B := ((P shr 8) and $F) * 17;
        A := ((P shr 12) and $F) * 17;
      end;
  else
    begin
      R := P and $FF;
      G := (P shr 8) and $FF;
      B := (P shr 16) and $FF;
      A := P shr 24;
    end;
  end;
end;

function EncodeColor(Format: Cardinal; R, G, B: Integer): Cardinal; inline;
begin
  case Format of
    0: Result := Cardinal(R shr 3) or (Cardinal(G shr 2) shl 5) or (Cardinal(B shr 3) shl 11);
    1: Result := Cardinal(R shr 3) or (Cardinal(G shr 3) shl 5) or (Cardinal(B shr 3) shl 10);
    2: Result := Cardinal(R shr 4) or (Cardinal(G shr 4) shl 4) or (Cardinal(B shr 4) shl 8);
  else
    Result := Cardinal(R) or (Cardinal(G) shl 8) or (Cardinal(B) shl 16);
  end;
end;

function StencilBits(Format: Cardinal; V: Integer): Cardinal; inline;
begin
  case Format of
    1: Result := Cardinal(V and 1) shl 15;
    2: Result := Cardinal(V and $F) shl 12;
    3: Result := Cardinal(V and $FF) shl 24;
  else
    Result := 0;
  end;
end;

// Write mask of a pixel: 1 bits are kept from the old pixel.
function PixelKeepMask(const S: TGERaster): Cardinal;
begin
  var M := S.MaskRGB;
  var A := Cardinal(S.MaskA);
  case S.FBFormat of
    0: Result := ((M shr 3) and $1F) or (((M shr 10) and $3F) shl 5) or (((M shr 19) and $1F) shl 11);
    1: Result := ((M shr 3) and $1F) or (((M shr 11) and $1F) shl 5) or (((M shr 19) and $1F) shl 10) or ((A shr 7) shl 15);
    2: Result := ((M shr 4) and $F) or (((M shr 12) and $F) shl 4) or (((M shr 20) and $F) shl 8) or ((A shr 4) shl 12);
  else
    Result := (M and $FFFFFF) or (A shl 24);
  end;
end;

procedure GEPrepareRaster(var S: TGERaster);
begin
  S.KeepMask := PixelKeepMask(S);
end;

// a * (255 - t) + b * t over 256, rounded up, doubled before the shift.
function TexLerp(A, B, T, Dbl: Integer): Integer; inline;
begin
  Result := Clamp255(((A * (255 - T) + B * T + 255) * Dbl) shr 8);
end;

// A colour times a texture colour: the colour counts as (c + 1) / 256.
function TexMul(C, T, Dbl: Integer): Integer; inline;
begin
  Result := Clamp255(((C + 1) * T * Dbl) shr 8);
end;

procedure ApplyTexture(const S: TGERaster; var F: TGEFragment);
var
  TR, TG, TB, TA: Integer;
begin
  var C: Cardinal;
  if S.Tex.NeedLod then
    C := GESampleTextureLod(S.Tex, F.S, F.T, F.Lod)
  else
    C := GESampleTexture(S.Tex, F.S, F.T);
  TR := C and $FF;
  TG := (C shr 8) and $FF;
  TB := (C shr 16) and $FF;
  TA := C shr 24;
  var Dbl := 1;
  if S.ColorDouble then
    Dbl := 2;
  case S.TexFunc of
    0: // modulate
      begin
        F.R := TexMul(F.R, TR, Dbl);
        F.G := TexMul(F.G, TG, Dbl);
        F.B := TexMul(F.B, TB, Dbl);
        if S.TexAlpha then
          F.A := TexMul(F.A, TA, 1);
      end;
    1: // decal
      if S.TexAlpha then
      begin
        F.R := TexLerp(F.R, TR, TA, Dbl);
        F.G := TexLerp(F.G, TG, TA, Dbl);
        F.B := TexLerp(F.B, TB, TA, Dbl);
      end
      else
      begin
        F.R := Clamp255(TR * Dbl);
        F.G := Clamp255(TG * Dbl);
        F.B := Clamp255(TB * Dbl);
      end;
    2: // blend
      begin
        F.R := TexLerp(F.R, S.EnvR, TR, Dbl);
        F.G := TexLerp(F.G, S.EnvG, TG, Dbl);
        F.B := TexLerp(F.B, S.EnvB, TB, Dbl);
        if S.TexAlpha then
          F.A := TexMul(F.A, TA, 1);
      end;
    3: // replace
      begin
        F.R := Clamp255(TR * Dbl);
        F.G := Clamp255(TG * Dbl);
        F.B := Clamp255(TB * Dbl);
        if S.TexAlpha then
          F.A := TA;
      end;
  else // add
    begin
      F.R := Clamp255((F.R + TR) * Dbl);
      F.G := Clamp255((F.G + TG) * Dbl);
      F.B := Clamp255((F.B + TB) * Dbl);
      if S.TexAlpha then
        F.A := TexMul(F.A, TA, 1);
    end;
  end;
end;

procedure PlotPixel(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
var
  DR, DG, DB, DA: Integer;
  SFR, SFG, SFB, DFR, DFG, DFB: Integer;
begin
  if (X < S.ScissorX1) or (X > S.ScissorX2) or (Y < S.ScissorY1) or (Y > S.ScissorY2) then
    Exit;
  if (Y < S.BandY1) or (Y > S.BandY2) then
    Exit;
  var Bpp: Cardinal := 2;
  if S.FBFormat = 3 then
    Bpp := 4;
  var PAddr := (S.FBAddr + (Cardinal(Y) * S.FBStride + Cardinal(X)) * Bpp) and (PSPVRAMSize - 1);
  var ZAddr := PSPDepthOffset(S.ZAddr + (Cardinal(Y) * S.ZStride + Cardinal(X)) * 2, S.ZPermutation);
  var Old: Cardinal;
  if Bpp = 4 then
    Old := PCardinal(S.VRAM + PAddr)^
  else
    Old := PWord(S.VRAM + PAddr)^;
  var Z := F.Z;
  if Z < 0 then Z := 0;
  if Z > 65535 then Z := 65535;

  if S.ClearMode then
  begin
    var NewP := Old;
    var Keep := S.KeepMask;
    if S.ClearColor then
    begin
      var CR := F.R; var CG := F.G; var CB := F.B;
      if S.Dither then
      begin
        var D := S.DitherMatrix[(Y and 3) * 4 + (X and 3)];
        CR := Clamp255(CR + D); CG := Clamp255(CG + D); CB := Clamp255(CB + D);
      end;
      NewP := (NewP and not (EncodeColor(S.FBFormat, 255, 255, 255))) or EncodeColor(S.FBFormat, CR, CG, CB);
    end;
    if S.ClearStencil then
    begin
      var SV: Integer;
      case S.FBFormat of
        1: SV := F.A shr 7;
        2: SV := F.A shr 4;
      else
        SV := F.A;
      end;
      NewP := (NewP and not StencilBits(S.FBFormat, $FF)) or StencilBits(S.FBFormat, SV);
    end;
    NewP := (NewP and not Keep) or (Old and Keep);
    if Bpp = 4 then
      PCardinal(S.VRAM + PAddr)^ := NewP
    else
      PWord(S.VRAM + PAddr)^ := Word(NewP);
    if S.ClearDepth then
      PWord(S.VRAM + ZAddr)^ := Word(Z);
    Exit;
  end;

  // The depth range test sees the depth clamped only with depth clamping on.
  if not S.Through then
    if S.DepthClamp then
    begin
      if (Z < S.MinZ) or (Z > S.MaxZ) then
        Exit;
    end
    else if (F.Z < S.MinZ) or (F.Z > S.MaxZ) then
      Exit;

  if S.Textured then
    ApplyTexture(S, F);

  // Secondary colour.
  F.R := Clamp255(F.R + F.SR);
  F.G := Clamp255(F.G + F.SG);
  F.B := Clamp255(F.B + F.SB);

  if S.FogEnabled then
  begin
    var Fg := F.Fog;
    if not (Fg > 0) then Fg := 0;
    if Fg > 1 then Fg := 1;
    var FI := Trunc(Fg * 255);
    F.R := TexLerp(S.FogR, F.R, FI, 1);
    F.G := TexLerp(S.FogG, F.G, FI, 1);
    F.B := TexLerp(S.FogB, F.B, FI, 1);
  end;

  if S.ColorTest then
  begin
    var C := Cardinal(F.R) or (Cardinal(F.G) shl 8) or (Cardinal(F.B) shl 16);
    var Pass: Boolean;
    case S.ColorTestFunc of
      0: Pass := False;
      1: Pass := True;
      2: Pass := (C and S.ColorMask) = (S.ColorRef and S.ColorMask);
    else
      Pass := (C and S.ColorMask) <> (S.ColorRef and S.ColorMask);
    end;
    if not Pass then
      Exit;
  end;

  if S.AlphaTest then
    if not TestFunc(S.AlphaFunc, F.A and S.AlphaMask, S.AlphaRef and S.AlphaMask) then
      Exit;

  var Stencil := RawStencil(S.FBFormat, Old);
  var NewStencil := Stencil;
  var StencilWrite := False;
  if S.StencilTest and (S.FBFormat <> 0) then
  begin
    var St8 := StencilOf(S.FBFormat, Old);
    if not TestFunc(S.StencilFunc, S.StencilRef and S.StencilMask, St8 and S.StencilMask) then
    begin
      NewStencil := StencilOp(S.StencilFail, S.FBFormat, Stencil, S.StencilRef);
      if NewStencil <> Stencil then
      begin
        var Keep := S.KeepMask;
        var NewP := (Old and not StencilBits(S.FBFormat, $FF)) or StencilBits(S.FBFormat, NewStencil);
        NewP := (NewP and not Keep) or (Old and Keep);
        if Bpp = 4 then PCardinal(S.VRAM + PAddr)^ := NewP else PWord(S.VRAM + PAddr)^ := Word(NewP);
      end;
      Exit;
    end;
    StencilWrite := True;
  end;

  if S.DepthTest then
  begin
    var OldZ := Integer(PWord(S.VRAM + ZAddr)^);
    if not TestFunc(S.DepthFunc, Z, OldZ) then
    begin
      if StencilWrite then
      begin
        NewStencil := StencilOp(S.StencilZFail, S.FBFormat, Stencil, S.StencilRef);
        if NewStencil <> Stencil then
        begin
          var Keep := S.KeepMask;
          var NewP := (Old and not StencilBits(S.FBFormat, $FF)) or StencilBits(S.FBFormat, NewStencil);
          NewP := (NewP and not Keep) or (Old and Keep);
          if Bpp = 4 then PCardinal(S.VRAM + PAddr)^ := NewP else PWord(S.VRAM + PAddr)^ := Word(NewP);
        end;
      end;
      Exit;
    end;
  end;
  if StencilWrite then
    NewStencil := StencilOp(S.StencilZPass, S.FBFormat, Stencil, S.StencilRef);
  if S.DepthWrite and S.DepthTest then
    PWord(S.VRAM + ZAddr)^ := Word(Z);

  var R := F.R;
  var G := F.G;
  var B := F.B;
  if S.Blend then
  begin
    DecodePixel(S.FBFormat, Old, DR, DG, DB, DA);
    if S.FBFormat = 0 then
      DA := 0;
    R := BlendChannel(S, F.R, DR, F.A, DA, 0);
    G := BlendChannel(S, F.G, DG, F.A, DA, 8);
    B := BlendChannel(S, F.B, DB, F.A, DA, 16);
  end;

  if S.Dither then
  begin
    var D := S.DitherMatrix[(Y and 3) * 4 + (X and 3)];
    R := R + D;
    G := G + D;
    B := B + D;
  end;
  R := Clamp255(R);
  G := Clamp255(G);
  B := Clamp255(B);

  var NewP := (Old and StencilBits(S.FBFormat, $FF)) or EncodeColor(S.FBFormat, R, G, B);
  if StencilWrite then
    NewP := (NewP and not StencilBits(S.FBFormat, $FF)) or StencilBits(S.FBFormat, NewStencil);
  if S.LogicOp then
  begin
    var Src := NewP;
    case S.LogicFunc of
      0: NewP := 0;
      1: NewP := Src and Old;
      2: NewP := Src and not Old;
      3: NewP := Src;
      4: NewP := not Src and Old;
      5: NewP := Old;
      6: NewP := Src xor Old;
      7: NewP := Src or Old;
      8: NewP := not (Src or Old);
      9: NewP := not (Src xor Old);
      10: NewP := not Old;
      11: NewP := Src or not Old;
      12: NewP := not Src;
      13: NewP := not Src or Old;
      14: NewP := not (Src and Old);
    else
      NewP := $FFFFFFFF;
    end;
    // The stencil channel follows the stencil operation, not the logic op.
    NewP := (NewP and not StencilBits(S.FBFormat, $FF)) or (Src and StencilBits(S.FBFormat, $FF));
  end;
  var Keep := S.KeepMask;
  NewP := (NewP and not Keep) or (Old and Keep);
  if Bpp = 4 then
    PCardinal(S.VRAM + PAddr)^ := NewP
  else
    PWord(S.VRAM + PAddr)^ := Word(NewP);
end;

// Pixel pipelines specialised on target format, texture, blend and depth.
{$I PSP.GE.PixelProcs.inc}

// A clear-mode sprite without dither: the same bits into every pixel, as
// PlotPixel's clear path writes them.
procedure ClearRect(const S: TGERaster; X1, Y1, X2, Y2: Integer; const V: TGEVertex);
begin
  var Fmt := S.FBFormat;
  var SetMask: Cardinal := 0;
  var SetBits: Cardinal := 0;
  if S.ClearColor then
  begin
    SetMask := EncodeColor(Fmt, 255, 255, 255);
    SetBits := EncodeColor(Fmt, V.R, V.G, V.B);
  end;
  if S.ClearStencil then
  begin
    var SV: Integer;
    case Fmt of
      1: SV := V.A shr 7;
      2: SV := V.A shr 4;
    else
      SV := V.A;
    end;
    SetMask := SetMask or StencilBits(Fmt, $FF);
    SetBits := SetBits or StencilBits(Fmt, SV);
  end;
  var W := SetMask and not S.KeepMask;
  SetBits := SetBits and W;
  var Z := V.Z;
  if Z < 0 then Z := 0;
  if Z > 65535 then Z := 65535;
  var Bpp: Cardinal := 2;
  if Fmt = 3 then
    Bpp := 4;
  for var Y := Y1 to Y2 do
  begin
    if W <> 0 then
    begin
      var A := S.FBAddr + (Cardinal(Y) * S.FBStride + Cardinal(X1)) * Bpp;
      for var X := X1 to X2 do
      begin
        var PA := A and (PSPVRAMSize - 1);
        if Bpp = 4 then
          PCardinal(S.VRAM + PA)^ := (PCardinal(S.VRAM + PA)^ and not W) or SetBits
        else
          PWord(S.VRAM + PA)^ := Word((PWord(S.VRAM + PA)^ and not W) or SetBits);
        Inc(A, Bpp);
      end;
    end;
    if S.ClearDepth then
    begin
      var A := S.ZAddr + (Cardinal(Y) * S.ZStride + Cardinal(X1)) * 2;
      for var X := X1 to X2 do
      begin
        PWord(S.VRAM + PSPDepthOffset(A, S.ZPermutation))^ := Word(Z);
        Inc(A, 2);
      end;
    end;
  end;
end;

procedure SetupFragment(var F: TGEFragment; const V: TGEVertex); inline;
begin
  F.R := V.R; F.G := V.G; F.B := V.B; F.A := V.A;
  F.SR := V.SR; F.SG := V.SG; F.SB := V.SB;
  F.Z := V.Z;
  F.S := V.S; F.T := V.T;
  F.Fog := V.Fog;
  F.Lod := 0;
end;

type
  // A colour channel as a plane from the anchor vertex: its value and its
  // steps per pixel in x and y, fixed point with GEPlaneBits fraction bits.
  TGEPlane = record
    C0, GX, GY: Int64;
  end;

const
  GEPlaneBits = 14;

// The colour planes start from the lowest vertex on screen (the rightmost
// of a lowest pair): A0, A1 or A2.
function PlaneAnchor(X0, Y0, X1, Y1, X2, Y2: Int64): Integer;
begin
  Result := 0;
  var BX := X0;
  var BY := Y0;
  if (Y1 > BY) or ((Y1 = BY) and (X1 > BX)) then
  begin
    Result := 1;
    BX := X1;
    BY := Y1;
  end;
  if (Y2 > BY) or ((Y2 = BY) and (X2 > BX)) then
    Result := 2;
end;

function MakePlane(C0, C1, C2: Integer; DX0, DY0, DX1, DY1, DX2, DY2, Area: Int64; Anchor: Integer): TGEPlane;
begin
  // dE_i/dx = -DY_i and dE_i/dy = DX_i per 1/16 pixel; per pixel times 16.
  var NX := -(C0 * DY0 + C1 * DY1 + C2 * DY2) * 16;
  var NY := (C0 * DX0 + C1 * DX1 + C2 * DX2) * 16;
  case Anchor of
    1: Result.C0 := Int64(C1) shl GEPlaneBits;
    2: Result.C0 := Int64(C2) shl GEPlaneBits;
  else
    Result.C0 := Int64(C0) shl GEPlaneBits;
  end;
  Result.GX := (NX shl GEPlaneBits) div Area;
  Result.GY := (NY shl GEPlaneBits) div Area;
end;

// The channel at (DX, DY) 1/16 pixels from the anchor.
function PlaneAt(const P: TGEPlane; DX, DY: Int64): Integer; inline;
begin
  var V := P.C0 + (P.GX * DX + P.GY * DY) div 16;
  if V < 0 then
    Exit(0);
  Result := V shr GEPlaneBits;
  if Result > 255 then
    Result := 255;
end;

// Intersect a row's x interval with E + Step * (x - Origin) >= 0.
procedure EdgeSpan(E, Step: Int64; Origin: Integer; var Lo, Hi: Integer); inline;
begin
  if Step > 0 then
  begin
    var N := -E;
    var Q := N div Step;
    if (N > 0) and (N mod Step <> 0) then Inc(Q);
    if Origin + Q > Lo then Lo := Origin + Q;
  end
  else if Step < 0 then
  begin
    var D := -Step;
    var Q := E div D;
    if (E < 0) and (E mod D <> 0) then Dec(Q);
    if Origin + Q < Hi then Hi := Origin + Q;
  end
  else if E < 0 then
    Hi := Lo - 1;
end;

function PlaneNumerator(C0, N: Int64): Integer; inline;
begin
  var V := C0 + N div 16;
  if V < 0 then Exit(0);
  Result := V shr GEPlaneBits;
  if Result > 255 then Result := 255;
end;

procedure GEDrawTriangle(const S: TGERaster; const V0, V1, V2: TGEVertex);
var
  F: TGEFragment;
begin
  var X0 := Int64(V0.X); var Y0 := Int64(V0.Y);
  var X1 := Int64(V1.X); var Y1 := Int64(V1.Y);
  var X2 := Int64(V2.X); var Y2 := Int64(V2.Y);
  var Area := (X1 - X0) * (Y2 - Y0) - (Y1 - Y0) * (X2 - X0);
  if Area = 0 then
    Exit;
  // Orient counter-clockwise in screen space (y down): make Area positive.
  var A0, A1, A2: PGEVertex;
  A0 := @V0; A1 := @V1; A2 := @V2;
  if Area < 0 then
  begin
    A1 := @V2; A2 := @V1;
    X1 := V2.X; Y1 := V2.Y; X2 := V1.X; Y2 := V1.Y;
    Area := -Area;
  end;
  var MinX := Min(X0, Min(X1, X2));
  var MaxX := Max(X0, Max(X1, X2));
  var MinY := Min(Y0, Min(Y1, Y2));
  var MaxY := Max(Y0, Max(Y1, Y2));
  // Pixel ranges whose centres can be inside.
  var PX1 := Integer((MinX - 8 + 15 + $100000) div 16) - $10000;
  var PX2 := Integer((MaxX - 8 + $100000) div 16) - $10000;
  var PY1 := Integer((MinY - 8 + 15 + $100000) div 16) - $10000;
  var PY2 := Integer((MaxY - 8 + $100000) div 16) - $10000;
  PX1 := Max(PX1, S.ScissorX1);
  PY1 := Max(PY1, Max(S.ScissorY1, S.BandY1));
  PX2 := Min(PX2, S.ScissorX2);
  PY2 := Min(PY2, Min(S.ScissorY2, S.BandY2));
  if (PX1 > PX2) or (PY1 > PY2) then
    Exit;
  // Edge functions for edges opposite each vertex. E_i >= 0 inside. Top-left
  // rule: pixels exactly on an edge belong to it only when the edge is a top
  // or left edge.
  var DX0 := X2 - X1; var DY0 := Y2 - Y1; // edge 1->2, opposite V0
  var DX1 := X0 - X2; var DY1 := Y0 - Y2; // edge 2->0, opposite V1
  var DX2 := X1 - X0; var DY2 := Y1 - Y0; // edge 0->1, opposite V2
  var Bias0: Int64 := 0; var Bias1: Int64 := 0; var Bias2: Int64 := 0;
  // With y down and positive area the triangle is clockwise on screen; an edge
  // is top-left when it goes up (dy < 0) or is horizontal going right (dy = 0, dx > 0).
  if not ((DY0 < 0) or ((DY0 = 0) and (DX0 > 0))) then Bias0 := -1;
  if not ((DY1 < 0) or ((DY1 = 0) and (DX1 > 0))) then Bias1 := -1;
  if not ((DY2 < 0) or ((DY2 = 0) and (DX2 > 0))) then Bias2 := -1;
  var FArea := 1.0 / Area;
  var PR, PG, PB, PA: TGEPlane;
  var AI := PlaneAnchor(X0, Y0, X1, Y1, X2, Y2);
  var AX := X0; var AY := Y0;
  if AI = 1 then
  begin
    AX := X1;
    AY := Y1;
  end
  else if AI = 2 then
  begin
    AX := X2;
    AY := Y2;
  end;
  if S.Gouraud and not S.Flat then
  begin
    PR := MakePlane(A0.R, A1.R, A2.R, DX0, DY0, DX1, DY1, DX2, DY2, Area, AI);
    PG := MakePlane(A0.G, A1.G, A2.G, DX0, DY0, DX1, DY1, DX2, DY2, Area, AI);
    PB := MakePlane(A0.B, A1.B, A2.B, DX0, DY0, DX1, DY1, DX2, DY2, Area, AI);
    PA := MakePlane(A0.A, A1.A, A2.A, DX0, DY0, DX1, DY1, DX2, DY2, Area, AI);
  end;
  // For the level of detail: per pixel, how S and T (perspective correct)
  // change along x and y, from the steps of the weights.
  var NeedLod := S.Textured and S.Tex.NeedLod;
  var NSX, NSY, NTX, NTY, DQX, DQY: Single;
  NSX := 0; NSY := 0; NTX := 0; NTY := 0; DQX := 0; DQY := 0;
  F.Lod := 0;
  if NeedLod then
  begin
    var BX0 := -16 * DY0 * FArea; var BY0 := 16 * DX0 * FArea;
    var BX1 := -16 * DY1 * FArea; var BY1 := 16 * DX1 * FArea;
    var BX2 := -16 * DY2 * FArea; var BY2 := 16 * DX2 * FArea;
    NSX := A0.S * A0.W * BX0 + A1.S * A1.W * BX1 + A2.S * A2.W * BX2;
    NSY := A0.S * A0.W * BY0 + A1.S * A1.W * BY1 + A2.S * A2.W * BY2;
    NTX := A0.T * A0.W * BX0 + A1.T * A1.W * BX1 + A2.T * A2.W * BX2;
    NTY := A0.T * A0.W * BY0 + A1.T * A1.W * BY1 + A2.T * A2.W * BY2;
    DQX := A0.Q * A0.W * BX0 + A1.Q * A1.W * BX1 + A2.Q * A2.W * BX2;
    DQY := A0.Q * A0.W * BY0 + A1.Q * A1.W * BY1 + A2.Q * A2.W * BY2;
  end;
  var Step0 := -16 * DY0; var Step1 := -16 * DY1; var Step2 := -16 * DY2;
  var OriginX := Int64(PX1) * 16 + 8;
  var OriginY := Int64(PY1) * 16 + 8;
  var Row0 := (OriginY - Y1) * DX0 - (OriginX - X1) * DY0;
  var Row1 := (OriginY - Y2) * DX1 - (OriginX - X2) * DY1;
  var Row2 := (OriginY - Y0) * DX2 - (OriginX - X0) * DY2;
  var Gouraud := S.Gouraud and not S.Flat and
    ((A0.R <> A1.R) or (A0.R <> A2.R) or (A0.G <> A1.G) or (A0.G <> A2.G) or
     (A0.B <> A1.B) or (A0.B <> A2.B) or (A0.A <> A1.A) or (A0.A <> A2.A) or
     (A0.SR <> A1.SR) or (A0.SR <> A2.SR) or (A0.SG <> A1.SG) or (A0.SG <> A2.SG) or
     (A0.SB <> A1.SB) or (A0.SB <> A2.SB));
  var Secondary := (A0.SR or A0.SG or A0.SB or A1.SR or A1.SG or A1.SB or A2.SR or A2.SG or A2.SB) <> 0;
  var ConstantZ := (A0.Z = A1.Z) and (A0.Z = A2.Z);
  var NeedWeights := S.Textured or S.FogEnabled or Secondary or not ConstantZ;
  var Plot := SelectPixel(S, Secondary);
  for var PY := PY1 to PY2 do
  begin
    var SY := Int64(PY) * 16 + 8;
    var Lo := PX1; var Hi := PX2;
    EdgeSpan(Row0 + Bias0, Step0, PX1, Lo, Hi);
    EdgeSpan(Row1 + Bias1, Step1, PX1, Lo, Hi);
    EdgeSpan(Row2 + Bias2, Step2, PX1, Lo, Hi);
    var E0 := Row0 + Step0 * (Lo - PX1);
    var E1 := Row1 + Step1 * (Lo - PX1);
    var E2 := Row2 + Step2 * (Lo - PX1);
    var NR, NG, NB, NA: Int64;
    NR := 0; NG := 0; NB := 0; NA := 0;
    if Gouraud then
    begin
      var DX := Int64(Lo) * 16 + 8 - AX;
      var DY := SY - AY;
      NR := PR.GX * DX + PR.GY * DY;
      NG := PG.GX * DX + PG.GY * DY;
      NB := PB.GX * DX + PB.GY * DY;
      NA := PA.GX * DX + PA.GY * DY;
    end;
    for var PX := Lo to Hi do
    begin
      var W0, W1, W2: Double;
      W0 := 0; W1 := 0; W2 := 0;
      if NeedWeights then
      begin
        W0 := E0 * FArea;
        W1 := E1 * FArea;
        W2 := E2 * FArea;
      end;
      if not Gouraud then
      begin
        F.R := V2.R; F.G := V2.G; F.B := V2.B; F.A := V2.A;
        F.SR := V2.SR; F.SG := V2.SG; F.SB := V2.SB;
      end
      else
      begin
        F.R := PlaneNumerator(PR.C0, NR);
        Inc(NR, PR.GX * 16);
        F.G := PlaneNumerator(PG.C0, NG);
        Inc(NG, PG.GX * 16);
        F.B := PlaneNumerator(PB.C0, NB);
        Inc(NB, PB.GX * 16);
        F.A := PlaneNumerator(PA.C0, NA);
        Inc(NA, PA.GX * 16);
        F.SR := 0; F.SG := 0; F.SB := 0;
        if Secondary then
        begin
          F.SR := GERound(A0.SR * W0 + A1.SR * W1 + A2.SR * W2);
          F.SG := GERound(A0.SG * W0 + A1.SG * W1 + A2.SG * W2);
          F.SB := GERound(A0.SB * W0 + A1.SB * W1 + A2.SB * W2);
        end;
      end;
      if ConstantZ then F.Z := A0.Z
      else F.Z := GERound(A0.Z * W0 + A1.Z * W1 + A2.Z * W2);
      if S.Textured then
      begin
        // S, T and Q go through the perspective (1/w) and then S and T are
        // divided by Q; where Q is not positive the GE takes the last texel.
        var Q := A0.Q * A0.W * W0 + A1.Q * A1.W * W1 + A2.Q * A2.W * W2;
        var IW := A0.W * W0 + A1.W * W1 + A2.W * W2;
        if (Q <> 0) and ((Q > 0) = (IW > 0)) then
        begin
          F.S := (A0.S * A0.W * W0 + A1.S * A1.W * W1 + A2.S * A2.W * W2) / Q;
          F.T := (A0.T * A0.W * W0 + A1.T * A1.W * W1 + A2.T * A2.W * W2) / Q;
          if NeedLod then
          begin
            var Scale := Max(Max(Abs(NSX - F.S * DQX), Abs(NSY - F.S * DQY)),
              Max(Abs(NTX - F.T * DQX), Abs(NTY - F.T * DQY))) / Abs(Q);
            var W: Single := 1;
            if IW <> 0 then
              W := 1 / IW;
            F.Lod := TexLod(S, Scale, W);
          end;
        end
        else
        begin
          F.S := S.Tex.Levels[0].Width - 0.5;
          F.T := S.Tex.Levels[0].Height - 0.5;
        end;
      end;
      if S.FogEnabled then
        F.Fog := A0.Fog * W0 + A1.Fog * W1 + A2.Fog * W2;
      Plot(S, PX, PY, F);
      Inc(E0, Step0); Inc(E1, Step1); Inc(E2, Step2);
    end;
    Inc(Row0, 16 * DX0); Inc(Row1, 16 * DX1); Inc(Row2, 16 * DX2);
  end;
end;

procedure GEDrawSprite(const S: TGERaster; const V0, V1: TGEVertex);
var
  F: TGEFragment;
begin
  var X1 := Min(V0.X, V1.X);
  var X2 := Max(V0.X, V1.X);
  var Y1 := Min(V0.Y, V1.Y);
  var Y2 := Max(V0.Y, V1.Y);
  // Pixels whose centre lies in [x1, x2) x [y1, y2).
  var PX1 := (X1 - 8 + 15 + 65536) div 16 - 4096;
  var PX2 := (X2 - 8 + 15 + 65536) div 16 - 4096 - 1;
  var PY1 := (Y1 - 8 + 15 + 65536) div 16 - 4096;
  var PY2 := (Y2 - 8 + 15 + 65536) div 16 - 4096 - 1;
  PX1 := Max(PX1, S.ScissorX1);
  PY1 := Max(PY1, Max(S.ScissorY1, S.BandY1));
  PX2 := Min(PX2, S.ScissorX2);
  PY2 := Min(PY2, Min(S.ScissorY2, S.BandY2));
  if (PX1 > PX2) or (PY1 > PY2) then
    Exit;
  if S.ClearMode and not S.Dither then
  begin
    ClearRect(S, PX1, PY1, PX2, PY2, V1);
    Exit;
  end;
  var Plot := SelectPixel(S, (V1.SR or V1.SG or V1.SB) <> 0);
  SetupFragment(F, V1);
  // S runs along x and T along y, except when the corners are flipped in
  // one axis only: then the texture is turned, S along y and T along x.
  var Turned := (V0.X > V1.X) <> (V0.Y > V1.Y);
  // Q goes with S, and divides both.
  var SX: Single := 0; var SY: Single := 0; var TX: Single := 0; var TY: Single := 0;
  var QX: Single := 0; var QY: Single := 0;
  if V1.X <> V0.X then
  begin
    if Turned then
      TX := (V1.T - V0.T) / ((V1.X - V0.X) / 16)
    else
    begin
      SX := (V1.S - V0.S) / ((V1.X - V0.X) / 16);
      QX := (V1.Q - V0.Q) / ((V1.X - V0.X) / 16);
    end;
  end;
  if V1.Y <> V0.Y then
  begin
    if Turned then
    begin
      SY := (V1.S - V0.S) / ((V1.Y - V0.Y) / 16);
      QY := (V1.Q - V0.Q) / ((V1.Y - V0.Y) / 16);
    end
    else
      TY := (V1.T - V0.T) / ((V1.Y - V0.Y) / 16);
  end;
  var Projected := (V0.Q <> 1) or (V1.Q <> 1);
  var Lod := 0;
  if S.Textured and S.Tex.NeedLod then
  begin
    var W: Single := 1;
    if V1.W > 0 then
      W := 1 / V1.W;
    Lod := TexLod(S, Max(Max(Abs(SX), Abs(SY)), Max(Abs(TX), Abs(TY))), W);
  end;
  for var PY := PY1 to PY2 do
    for var PX := PX1 to PX2 do
    begin
      SetupFragment(F, V1);
      F.Lod := Lod;
      if S.Textured then
      begin
        var FX := (PX * 16 + 8 - V0.X) / 16;
        var FY := (PY * 16 + 8 - V0.Y) / 16;
        F.S := V0.S + SX * FX + SY * FY;
        F.T := V0.T + TX * FX + TY * FY;
        if Projected then
        begin
          var Q := V0.Q + QX * FX + QY * FY;
          if Q <> 0 then
          begin
            F.S := F.S / Q;
            F.T := F.T / Q;
          end;
        end;
      end;
      Plot(S, PX, PY, F);
    end;
end;

procedure GEDrawLine(const S: TGERaster; const V0, V1: TGEVertex);
var
  F: TGEFragment;
begin
  var X0 := V0.X; var Y0 := V0.Y;
  var DX := V1.X - X0; var DY := V1.Y - Y0;
  if (DX = 0) and (DY = 0) then
    Exit;
  // Pixels whose centre on the major axis lies between the end points; the
  // minor axis is the containing pixel of the line there.
  var XMajor := Abs(DX) >= Abs(DY);
  var A0, A1, D: Integer;
  if XMajor then
  begin
    A0 := Min(V0.X, V1.X); A1 := Max(V0.X, V1.X); D := DX;
  end
  else
  begin
    A0 := Min(V0.Y, V1.Y); A1 := Max(V0.Y, V1.Y); D := DY;
  end;
  var P1 := (A0 - 8 + 15 + $100000) div 16 - $10000;
  var P2 := (A1 - 8 + 15 + $100000) div 16 - $10000 - 1;
  for var P := P1 to P2 do
  begin
    var C := P * 16 + 8;
    var T: Single;
    var PX, PY: Integer;
    if XMajor then
    begin
      T := (C - X0) / D;
      PX := P;
      PY := (Y0 + GERound(DY * T) + $100000) div 16 - $10000;
    end
    else
    begin
      T := (C - Y0) / D;
      PY := P;
      PX := (X0 + GERound(DX * T) + $100000) div 16 - $10000;
    end;
    SetupFragment(F, V1);
    if not S.Flat and S.Gouraud then
    begin
      F.R := GERound(V0.R + (V1.R - V0.R) * T);
      F.G := GERound(V0.G + (V1.G - V0.G) * T);
      F.B := GERound(V0.B + (V1.B - V0.B) * T);
      F.A := GERound(V0.A + (V1.A - V0.A) * T);
    end;
    F.Z := GERound(V0.Z + (V1.Z - V0.Z) * T);
    F.S := V0.S + (V1.S - V0.S) * T;
    F.T := V0.T + (V1.T - V0.T) * T;
    var Q := V0.Q + (V1.Q - V0.Q) * T;
    if (Q <> 1) and (Q <> 0) then
    begin
      F.S := F.S / Q;
      F.T := F.T / Q;
    end;
    F.Fog := V0.Fog + (V1.Fog - V0.Fog) * T;
    PlotPixel(S, PX, PY, F);
  end;
end;

procedure GEDrawPoint(const S: TGERaster; const V: TGEVertex);
var
  F: TGEFragment;
begin
  SetupFragment(F, V);
  if (V.Q <> 1) and (V.Q <> 0) then
  begin
    F.S := V.S / V.Q;
    F.T := V.T / V.Q;
  end;
  PlotPixel(S, (V.X + $100000) div 16 - $10000, (V.Y + $100000) div 16 - $10000, F);
end;

end.
