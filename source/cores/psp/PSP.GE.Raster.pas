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
    S, T: Single;        // texture coordinates in texels (already / q)
    Fog: Single;         // 0 = fog colour, 1 = no fog
  end;
  PGEVertex = ^TGEVertex;

  TGERaster = record
    VRAM: PByte;
    FBAddr, FBStride, FBFormat: Cardinal;
    ZAddr, ZStride: Cardinal;
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
    Blend: Boolean;
    BlendOp, BlendSrc, BlendDst: Integer;
    FixA, FixB: Cardinal;
    Dither: Boolean;
    DitherMatrix: array[0..15] of Integer;
    LogicOp: Boolean;
    LogicFunc: Integer;
    MaskRGB: Cardinal;
    MaskA: Integer;
  end;

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

function BlendFactor(Kind: Integer; const Src: TGEFragment; DR, DG, DB, DA: Integer; Fix: Cardinal; IsSrc: Boolean;
  out FR, FG, FB: Integer): Boolean;
var
  OR_, OG, OB: Integer;
begin
  Result := True;
  // "Other" colour: the destination for the source factor, the source for the destination factor.
  if IsSrc then
  begin
    OR_ := DR; OG := DG; OB := DB;
  end
  else
  begin
    OR_ := Src.R; OG := Src.G; OB := Src.B;
  end;
  case Kind of
    0: begin FR := OR_; FG := OG; FB := OB; end;
    1: begin FR := 255 - OR_; FG := 255 - OG; FB := 255 - OB; end;
    2: begin FR := Src.A; FG := Src.A; FB := Src.A; end;
    3: begin FR := 255 - Src.A; FG := FR; FB := FR; end;
    4: begin FR := DA; FG := DA; FB := DA; end;
    5: begin FR := 255 - DA; FG := FR; FB := FR; end;
    6: begin FR := 2 * Src.A; FG := FR; FB := FR; end;
    7: begin FR := Max(0, 255 - 2 * Src.A); FG := FR; FB := FR; end;
    8: begin FR := 2 * DA; FG := FR; FB := FR; end;
    9: begin FR := Max(0, 255 - 2 * DA); FG := FR; FB := FR; end;
  else
    begin
      FR := Fix and $FF;
      FG := (Fix shr 8) and $FF;
      FB := (Fix shr 16) and $FF;
    end;
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

procedure ApplyTexture(const S: TGERaster; var F: TGEFragment);
var
  TR, TG, TB, TA: Integer;
begin
  var C := GESampleTexture(S.Tex, F.S, F.T);
  TR := C and $FF;
  TG := (C shr 8) and $FF;
  TB := (C shr 16) and $FF;
  TA := C shr 24;
  if not S.TexAlpha then
    TA := 255;
  case S.TexFunc of
    0: // modulate
      begin
        F.R := (F.R * TR) div 255;
        F.G := (F.G * TG) div 255;
        F.B := (F.B * TB) div 255;
        if S.TexAlpha then
          F.A := (F.A * TA) div 255;
      end;
    1: // decal
      begin
        if S.TexAlpha then
        begin
          F.R := (TR * TA + F.R * (255 - TA)) div 255;
          F.G := (TG * TA + F.G * (255 - TA)) div 255;
          F.B := (TB * TA + F.B * (255 - TA)) div 255;
        end
        else
        begin
          F.R := TR;
          F.G := TG;
          F.B := TB;
        end;
      end;
    2: // blend
      begin
        F.R := (F.R * (255 - TR) + S.EnvR * TR) div 255;
        F.G := (F.G * (255 - TG) + S.EnvG * TG) div 255;
        F.B := (F.B * (255 - TB) + S.EnvB * TB) div 255;
        if S.TexAlpha then
          F.A := (F.A * TA) div 255;
      end;
    3: // replace
      begin
        F.R := TR;
        F.G := TG;
        F.B := TB;
        if S.TexAlpha then
          F.A := TA;
      end;
  else // add
    begin
      F.R := Clamp255(F.R + TR);
      F.G := Clamp255(F.G + TG);
      F.B := Clamp255(F.B + TB);
      if S.TexAlpha then
        F.A := (F.A * TA) div 255;
    end;
  end;
  if S.ColorDouble then
  begin
    F.R := Clamp255(F.R * 2);
    F.G := Clamp255(F.G * 2);
    F.B := Clamp255(F.B * 2);
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
  var ZAddr := (S.ZAddr + (Cardinal(Y) * S.ZStride + Cardinal(X)) * 2) and (PSPVRAMSize - 1);
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
    var Keep := PixelKeepMask(S);
    if S.ClearColor then
      NewP := (NewP and not (EncodeColor(S.FBFormat, 255, 255, 255))) or EncodeColor(S.FBFormat, F.R, F.G, F.B);
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

  if not S.Through then
    if (Z < S.MinZ) or (Z > S.MaxZ) then
      Exit;

  if S.Textured then
    ApplyTexture(S, F);

  // Secondary colour.
  F.R := Clamp255(F.R + F.SR);
  F.G := Clamp255(F.G + F.SG);
  F.B := Clamp255(F.B + F.SB);

  if S.FogEnabled and not S.Through then
  begin
    var Fg := F.Fog;
    if Fg < 0 then Fg := 0;
    if Fg > 1 then Fg := 1;
    var FI := Trunc(Fg * 255);
    F.R := (F.R * FI + S.FogR * (255 - FI)) div 255;
    F.G := (F.G * FI + S.FogG * (255 - FI)) div 255;
    F.B := (F.B * FI + S.FogB * (255 - FI)) div 255;
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
        var Keep := PixelKeepMask(S);
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
          var Keep := PixelKeepMask(S);
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
    BlendFactor(S.BlendSrc, F, DR, DG, DB, DA, S.FixA, True, SFR, SFG, SFB);
    BlendFactor(S.BlendDst, F, DR, DG, DB, DA, S.FixB, False, DFR, DFG, DFB);
    case S.BlendOp of
      0:
        begin
          R := (F.R * SFR) div 255 + (DR * DFR) div 255;
          G := (F.G * SFG) div 255 + (DG * DFG) div 255;
          B := (F.B * SFB) div 255 + (DB * DFB) div 255;
        end;
      1:
        begin
          R := (F.R * SFR) div 255 - (DR * DFR) div 255;
          G := (F.G * SFG) div 255 - (DG * DFG) div 255;
          B := (F.B * SFB) div 255 - (DB * DFB) div 255;
        end;
      2:
        begin
          R := (DR * DFR) div 255 - (F.R * SFR) div 255;
          G := (DG * DFG) div 255 - (F.G * SFG) div 255;
          B := (DB * DFB) div 255 - (F.B * SFB) div 255;
        end;
      3:
        begin
          R := Min(F.R, DR);
          G := Min(F.G, DG);
          B := Min(F.B, DB);
        end;
      4:
        begin
          R := Max(F.R, DR);
          G := Max(F.G, DG);
          B := Max(F.B, DB);
        end;
    else
      begin
        R := Abs(F.R - DR);
        G := Abs(F.G - DG);
        B := Abs(F.B - DB);
      end;
    end;
  end;

  if S.Dither and (S.FBFormat <> 3) then
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
  var Keep := PixelKeepMask(S);
  NewP := (NewP and not Keep) or (Old and Keep);
  if Bpp = 4 then
    PCardinal(S.VRAM + PAddr)^ := NewP
  else
    PWord(S.VRAM + PAddr)^ := Word(NewP);
end;

procedure SetupFragment(var F: TGEFragment; const V: TGEVertex); inline;
begin
  F.R := V.R; F.G := V.G; F.B := V.B; F.A := V.A;
  F.SR := V.SR; F.SG := V.SG; F.SB := V.SB;
  F.Z := V.Z;
  F.S := V.S; F.T := V.T;
  F.Fog := V.Fog;
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
  for var PY := PY1 to PY2 do
  begin
    var SY := Int64(PY) * 16 + 8;
    for var PX := PX1 to PX2 do
    begin
      var SX := Int64(PX) * 16 + 8;
      var E0 := (SX - X1) * DY0 - (SY - Y1) * DX0;
      var E1 := (SX - X2) * DY1 - (SY - Y2) * DX1;
      var E2 := (SX - X0) * DY2 - (SY - Y0) * DX2;
      E0 := -E0; E1 := -E1; E2 := -E2;
      if (E0 + Bias0 < 0) or (E1 + Bias1 < 0) or (E2 + Bias2 < 0) then
        Continue;
      var W0 := E0 * FArea;
      var W1 := E1 * FArea;
      var W2 := E2 * FArea;
      if S.Flat or not S.Gouraud then
      begin
        F.R := V2.R; F.G := V2.G; F.B := V2.B; F.A := V2.A;
        F.SR := V2.SR; F.SG := V2.SG; F.SB := V2.SB;
      end
      else
      begin
        F.R := (A0.R * E0 + A1.R * E1 + A2.R * E2) div Area;
        F.G := (A0.G * E0 + A1.G * E1 + A2.G * E2) div Area;
        F.B := (A0.B * E0 + A1.B * E1 + A2.B * E2) div Area;
        F.A := (A0.A * E0 + A1.A * E1 + A2.A * E2) div Area;
        F.SR := Round(A0.SR * W0 + A1.SR * W1 + A2.SR * W2);
        F.SG := Round(A0.SG * W0 + A1.SG * W1 + A2.SG * W2);
        F.SB := Round(A0.SB * W0 + A1.SB * W1 + A2.SB * W2);
      end;
      F.Z := Round(A0.Z * W0 + A1.Z * W1 + A2.Z * W2);
      if S.Textured then
      begin
        var Q := A0.W * W0 + A1.W * W1 + A2.W * W2;
        if Q <> 0 then
        begin
          F.S := (A0.S * A0.W * W0 + A1.S * A1.W * W1 + A2.S * A2.W * W2) / Q;
          F.T := (A0.T * A0.W * W0 + A1.T * A1.W * W1 + A2.T * A2.W * W2) / Q;
        end
        else
        begin
          F.S := A0.S;
          F.T := A0.T;
        end;
      end;
      F.Fog := A0.Fog * W0 + A1.Fog * W1 + A2.Fog * W2;
      PlotPixel(S, PX, PY, F);
    end;
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
  SetupFragment(F, V1);
  var DS: Single := 0; var DT: Single := 0;
  if V1.X <> V0.X then DS := (V1.S - V0.S) / ((V1.X - V0.X) / 16);
  if V1.Y <> V0.Y then DT := (V1.T - V0.T) / ((V1.Y - V0.Y) / 16);
  for var PY := PY1 to PY2 do
    for var PX := PX1 to PX2 do
    begin
      SetupFragment(F, V1);
      if S.Textured then
      begin
        F.S := V0.S + DS * ((PX * 16 + 8 - V0.X) / 16);
        F.T := V0.T + DT * ((PY * 16 + 8 - V0.Y) / 16);
      end;
      PlotPixel(S, PX, PY, F);
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
      PY := (Y0 + Round(DY * T) + $100000) div 16 - $10000;
    end
    else
    begin
      T := (C - Y0) / D;
      PY := P;
      PX := (X0 + Round(DX * T) + $100000) div 16 - $10000;
    end;
    SetupFragment(F, V1);
    if not S.Flat and S.Gouraud then
    begin
      F.R := Round(V0.R + (V1.R - V0.R) * T);
      F.G := Round(V0.G + (V1.G - V0.G) * T);
      F.B := Round(V0.B + (V1.B - V0.B) * T);
      F.A := Round(V0.A + (V1.A - V0.A) * T);
    end;
    F.Z := Round(V0.Z + (V1.Z - V0.Z) * T);
    F.S := V0.S + (V1.S - V0.S) * T;
    F.T := V0.T + (V1.T - V0.T) * T;
    F.Fog := V0.Fog + (V1.Fog - V0.Fog) * T;
    PlotPixel(S, PX, PY, F);
  end;
end;

procedure GEDrawPoint(const S: TGERaster; const V: TGEVertex);
var
  F: TGEFragment;
begin
  SetupFragment(F, V);
  PlotPixel(S, (V.X + $100000) div 16 - $10000, (V.Y + $100000) div 16 - $10000, F);
end;

end.
