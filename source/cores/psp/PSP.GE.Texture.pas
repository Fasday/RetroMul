unit PSP.GE.Texture;

// Texture fetch and filtering as the GE samples: all pixel formats, CLUT
// lookups through the CLUT cache (shift, mask, offset), DXT1/3/5, swizzled
// layout, wrap and clamp, nearest and bilinear.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}

interface

uses
  System.SysUtils, System.Math, PSP.Types, PSP.Memory;

type
  TGETexLevel = record
    Addr: Cardinal;
    Width, Height: Integer;  // 1 shl size bits
    BufWidth: Integer;       // in texels
    // The level's bytes in host memory when they are contiguous there (nil
    // otherwise), for reads without the guest page table.
    Ptr: PByte;
    Size: Cardinal;
    // Every texel the sampler can address lies in Ptr's Size bytes (set by
    // GEFitLevel; False only costs speed).
    Fits: Boolean;
  end;

  PGETexLevel = ^TGETexLevel;

  TGETexture = record
    Memory: TPSPMemory;
    Format: Integer;
    Swizzle: Boolean;
    Levels: array[0..7] of TGETexLevel;
    LevelCount: Integer;
    Level: Integer;
    ClampU, ClampV: Boolean;
    // The magnification filter (and the only one when NeedLod is off).
    Linear: Boolean;
    // Level of detail: the minification filter (TEXFILTER's 0-7), the
    // highest level, TEXLEVEL's mode and bias (1/16 levels), TEXLODSLOPE.
    // NeedLod: the level or the filter depends on it.
    MinFilter, MaxLevel, LevelMode, LodBias: Integer;
    Slope: Single;
    NeedLod: Boolean;
    // CLUT cache as loaded, and the index transform.
    Clut: PByte;
    ClutFormat, ClutShift, ClutMask, ClutOffset: Integer;
  end;

function GESampleTexture(const T: TGETexture; S, TT: Single): Cardinal;
// With the level of detail Lod (1/16 levels, bias included).
function GESampleTextureLod(const T: TGETexture; S, TT: Single; Lod: Integer): Cardinal;
// log2 as the GE takes it: the exponent and 4 bits of mantissa, in 1/16.
function GELog16(V: Single): Integer;
function GEFetchTexel(const T: TGETexture; Level, X, Y: Integer): Cardinal;
function GEDecode16(Format: Integer; P: Cardinal): Cardinal;
// One past the furthest byte from a level's start the sampler may read
// (texel coordinates are wrapped or clamped into the level).
function GELevelReach(const T: TGETexture; const L: TGETexLevel): UInt64;
// Sets L.Fits.
procedure GEFitLevel(const T: TGETexture; var L: TGETexLevel);

var
  // Tests: every texel through the general fetch, the reference for the
  // sampler's fast path.
  GEGenericTexels: Boolean;

implementation

const
  // Bits a texel by texture format (DXT by their blocks).
  TexBits: array[0..15] of Integer = (16, 16, 16, 32, 4, 8, 16, 32, 4, 8, 8, 0, 0, 0, 0, 0);

function GELevelReach(const T: TGETexture; const L: TGETexLevel): UInt64;
begin
  var Bits := TexBits[T.Format and 15];
  var W := UInt64(Max(L.Width, 1));
  var H := UInt64(Max(L.Height, 1));
  var BW := UInt64(Max(L.BufWidth, 0));
  if T.Format >= 8 then
  begin
    var BlockBytes: UInt64 := 16;
    if T.Format = 8 then BlockBytes := 8;
    Result := (((H - 1) shr 2) * (BW div 4) + ((W - 1) shr 2)) * BlockBytes + BlockBytes;
  end
  else
  begin
    var RowBytes := (BW * UInt64(Bits)) div 8;
    var LastByte := ((W - 1) * UInt64(Bits)) div 8;
    if T.Swizzle then
      Result := ((((H - 1) shr 3) * (RowBytes shr 4) + (LastByte shr 4)) shl 7) + 128
    else
      Result := (H - 1) * RowBytes + LastByte + UInt64(Max(1, Bits div 8));
  end;
end;

procedure GEFitLevel(const T: TGETexture; var L: TGETexLevel);
begin
  L.Fits := (L.Ptr <> nil) and (T.Format <= 7) and (L.Width > 0) and (L.Height > 0) and (L.BufWidth >= 0) and
    (GELevelReach(T, L) <= L.Size);
end;

function Decode16(Format: Integer; P: Cardinal): Cardinal; inline;
begin
  case Format of
    0:
      begin
        var R := P and $1F; var G := (P shr 5) and $3F; var B := (P shr 11) and $1F;
        Result := $FF000000 or ((R shl 3) or (R shr 2)) or (((G shl 2) or (G shr 4)) shl 8) or (((B shl 3) or (B shr 2)) shl 16);
      end;
    1:
      begin
        var R := P and $1F; var G := (P shr 5) and $1F; var B := (P shr 10) and $1F;
        Result := ((R shl 3) or (R shr 2)) or (((G shl 3) or (G shr 2)) shl 8) or (((B shl 3) or (B shr 2)) shl 16);
        if (P and $8000) <> 0 then
          Result := Result or $FF000000;
      end;
  else
    begin
      var R := P and $F; var G := (P shr 4) and $F; var B := (P shr 8) and $F; var A := (P shr 12) and $F;
      Result := (R * 17) or ((G * 17) shl 8) or ((B * 17) shl 16) or ((A * 17) shl 24);
    end;
  end;
end;

function GEDecode16(Format: Integer; P: Cardinal): Cardinal;
begin
  Result := Decode16(Format, P);
end;

function ClutLookup(const T: TGETexture; Index: Cardinal): Cardinal; inline;
begin
  var I := ((Index shr T.ClutShift) and Cardinal(T.ClutMask)) or (Cardinal(T.ClutOffset) and $1FF);
  if T.ClutFormat = 3 then
    Result := PCardinal(T.Clut + (I and $FF) * 4)^
  else
    Result := Decode16(T.ClutFormat, PWord(T.Clut + (I and $1FF) * 2)^);
end;

// Byte offset of texel (X, Y) for a format of Bits per texel, swizzled or linear.
function TexelOffset(const T: TGETexture; const L: TGETexLevel; X, Y, Bits: Integer): Cardinal; inline;
begin
  var RowBytes := (L.BufWidth * Bits) div 8;
  var ByteX := (X * Bits) div 8;
  if T.Swizzle then
  begin
    // 16-byte by 8-row blocks laid out left to right, then down.
    var BlockX := ByteX shr 4;
    var BlockY := Y shr 3;
    var BlocksPerRow := RowBytes shr 4;
    Result := Cardinal(((BlockY * BlocksPerRow + BlockX) shl 7) + ((Y and 7) shl 4) + (ByteX and 15));
  end
  else
    Result := Cardinal(Y * RowBytes + ByteX);
end;

// A DXT colour block's texel. The end colours widen to 8 bits without
// repeating their top bits; when the first is not greater, the block has
// three colours and index 3 is transparent black (DXT3/5 take the alpha from
// their own data).
function DXTColor(C0, C1: Cardinal; Index: Integer): Cardinal;
  procedure Split(C: Cardinal; out R, G, B: Integer);
  begin
    R := ((C shr 11) and $1F) shl 3;
    G := ((C shr 5) and $3F) shl 2;
    B := (C and $1F) shl 3;
  end;
var
  R0, G0, B0, R1, G1, B1: Integer;
begin
  Split(C0, R0, G0, B0);
  Split(C1, R1, G1, B1);
  case Index of
    0: Result := Cardinal(R0) or (Cardinal(G0) shl 8) or (Cardinal(B0) shl 16) or $FF000000;
    1: Result := Cardinal(R1) or (Cardinal(G1) shl 8) or (Cardinal(B1) shl 16) or $FF000000;
    2:
      if C0 > C1 then
        Result := Cardinal((2 * R0 + R1) div 3) or (Cardinal((2 * G0 + G1) div 3) shl 8) or (Cardinal((2 * B0 + B1) div 3) shl 16) or $FF000000
      else
        Result := Cardinal((R0 + R1) div 2) or (Cardinal((G0 + G1) div 2) shl 8) or (Cardinal((B0 + B1) div 2) shl 16) or $FF000000;
  else
    if C0 > C1 then
      Result := Cardinal((R0 + 2 * R1) div 3) or (Cardinal((G0 + 2 * G1) div 3) shl 8) or (Cardinal((B0 + 2 * B1) div 3) shl 16) or $FF000000
    else
      Result := 0;
  end;
end;

function TexR8(const L: TGETexLevel; M: TPSPMemory; Off: Cardinal): Cardinal; inline;
begin
  if (L.Ptr <> nil) and (Off < L.Size) then
    Result := L.Ptr[Off]
  else
    Result := M.Read8(L.Addr + Off);
end;

function TexR16(const L: TGETexLevel; M: TPSPMemory; Off: Cardinal): Cardinal; inline;
begin
  if (L.Ptr <> nil) and (Off + 2 <= L.Size) then
    Result := PWord(L.Ptr + Off)^
  else
    Result := M.Read16(L.Addr + Off);
end;

function TexR32(const L: TGETexLevel; M: TPSPMemory; Off: Cardinal): Cardinal; inline;
begin
  if (L.Ptr <> nil) and (Off + 4 <= L.Size) then
    Result := PCardinal(L.Ptr + Off)^
  else
    Result := M.Read32(L.Addr + Off);
end;

function FetchTexel(const T: TGETexture; L: PGETexLevel; X, Y: Integer): Cardinal; forward;

function GEFetchTexel(const T: TGETexture; Level, X, Y: Integer): Cardinal;
begin
  Result := FetchTexel(T, @T.Levels[Level], X, Y);
end;

// The common formats from a level's contiguous bytes, inline in the sampler.
function FastTexel(const T: TGETexture; L: PGETexLevel; X, Y: Integer): Cardinal; inline;
begin
  if (L.Ptr <> nil) and (T.Format <= 7) then
  begin
    var Bits := 16;
    case T.Format of
      3, 7: Bits := 32;
      4: Bits := 4;
      5: Bits := 8;
    end;
    var Off := TexelOffset(T, L^, X, Y, Bits);
    if Off + Cardinal(Max(1, Bits shr 3)) <= L.Size then
      case T.Format of
        0, 1, 2: Exit(Decode16(T.Format, PWord(L.Ptr + Off)^));
        3: Exit(PCardinal(L.Ptr + Off)^);
        4:
          begin
            var B := Cardinal(L.Ptr[Off]);
            if (X and 1) <> 0 then
              B := B shr 4
            else
              B := B and $F;
            Exit(ClutLookup(T, B));
          end;
        5: Exit(ClutLookup(T, L.Ptr[Off]));
        6: Exit(ClutLookup(T, PWord(L.Ptr + Off)^));
      else
        Exit(ClutLookup(T, PCardinal(L.Ptr + Off)^));
      end;
  end;
  Result := FetchTexel(T, L, X, Y);
end;

function FetchTexel(const T: TGETexture; L: PGETexLevel; X, Y: Integer): Cardinal;
begin
  var M := T.Memory;
  case T.Format of
    0, 1, 2:
      Result := Decode16(T.Format, TexR16(L^, M, TexelOffset(T, L^, X, Y, 16)));
    3:
      Result := TexR32(L^, M, TexelOffset(T, L^, X, Y, 32));
    4:
      begin
        var B := TexR8(L^, M, TexelOffset(T, L^, X, Y, 4));
        if (X and 1) <> 0 then
          B := B shr 4
        else
          B := B and $F;
        Result := ClutLookup(T, B);
      end;
    5:
      Result := ClutLookup(T, TexR8(L^, M, TexelOffset(T, L^, X, Y, 8)));
    6:
      Result := ClutLookup(T, TexR16(L^, M, TexelOffset(T, L^, X, Y, 16)));
    7:
      Result := ClutLookup(T, TexR32(L^, M, TexelOffset(T, L^, X, Y, 32)));
    8, 9, 10:
      begin
        // 4x4 blocks in rows of BufWidth/4 blocks: the colour block (indices,
        // then the two colours), and for DXT3/5 the alpha data after it.
        var BlockBytes := 16;
        if T.Format = 8 then
          BlockBytes := 8;
        var BlocksPerRow := L.BufWidth div 4;
        var Block := Cardinal(((Y shr 2) * BlocksPerRow + (X shr 2)) * BlockBytes);
        var Bits := TexR32(L^, M, Block);
        var C0 := TexR16(L^, M, Block + 4);
        var C1 := TexR16(L^, M, Block + 6);
        var Pixel := (Y and 3) * 4 + (X and 3);
        Result := DXTColor(C0, C1, (Bits shr (Pixel * 2)) and 3);
        if T.Format = 9 then
        begin
          // 4 bits a texel, a row in 16 bits; widened without repeating.
          var AW := TexR16(L^, M, Block + 8 + Cardinal((Y and 3) * 2));
          var A := (AW shr ((X and 3) * 4)) and $F;
          Result := (Result and $FFFFFF) or ((A shl 4) shl 24);
        end
        else if T.Format = 10 then
        begin
          // 48 bits of 3-bit indices, then the two end alphas.
          var ABits := UInt64(TexR32(L^, M, Block + 8)) or (UInt64(TexR16(L^, M, Block + 12)) shl 32);
          var A0 := TexR8(L^, M, Block + 14);
          var A1 := TexR8(L^, M, Block + 15);
          var AI := (ABits shr (Pixel * 3)) and 7;
          var A: Cardinal;
          if A0 > A1 then
            case AI of
              0: A := A0;
              1: A := A1;
            else
              A := ((8 - AI) * A0 + (AI - 1) * A1) div 7;
            end
          else
            case AI of
              0: A := A0;
              1: A := A1;
              6: A := 0;
              7: A := 255;
            else
              A := ((6 - AI) * A0 + (AI - 1) * A1) div 5;
            end;
          Result := (Result and $FFFFFF) or (A shl 24);
        end;
      end;
  else
    Result := 0;
  end;
end;

// Floor() also calls Frac(). For ordinary texture coordinates a truncation
// and signed comparison are equivalent; retain its exceptional/range rules.
function TexFloor(X: Single): Integer; inline;
begin
  if (PCardinal(@X)^ and $7F800000) >= $4F000000 then
    Exit(Floor(X));
  Result := Trunc(X);
  if X < Result then Dec(Result);
end;

function WrapCoord(V, Size: Integer; Clamp: Boolean): Integer; inline;
begin
  if Clamp then
  begin
    if V < 0 then
      Result := 0
    else if V >= Size then
      Result := Size - 1
    else
      Result := V;
  end
  else
    Result := V and (Size - 1);
end;

// A texel of a level holding all its texels: its byte offset (as TexelOffset,
// for non-negative coordinates) and its colour (as FetchTexel, formats 0-7).
function FitOffset(Swizzle: Boolean; RowBytes, Bits, X, Y: Integer): Cardinal; inline;
begin
  var ByteX := (X * Bits) shr 3;
  if Swizzle then
    Result := Cardinal((((Y shr 3) * (RowBytes shr 4) + (ByteX shr 4)) shl 7) + ((Y and 7) shl 4) + (ByteX and 15))
  else
    Result := Cardinal(Y * RowBytes + ByteX);
end;

function FitTexel(const T: TGETexture; P: PByte; Off: Cardinal; X: Integer): Cardinal; inline;
begin
  case T.Format of
    0, 1, 2: Result := Decode16(T.Format, PWord(P + Off)^);
    3: Result := PCardinal(P + Off)^;
    4:
      begin
        var B := Cardinal(P[Off]);
        if (X and 1) <> 0 then
          B := B shr 4
        else
          B := B and $F;
        Result := ClutLookup(T, B);
      end;
    5: Result := ClutLookup(T, P[Off]);
    6: Result := ClutLookup(T, PWord(P + Off)^);
  else
    Result := ClutLookup(T, PCardinal(P + Off)^);
  end;
end;

// A texel of one level, nearest or bilinear (4-bit weights); S and TT are
// in texels of that level.
function SampleLevel(const T: TGETexture; Level: Integer; S, TT: Single; Linear: Boolean): Cardinal;
begin
  var L: PGETexLevel := @T.Levels[Level];
  if L.Fits and not GEGenericTexels then
  begin
    var Bits := TexBits[T.Format];
    var RowBytes := (L.BufWidth * Bits) shr 3;
    var P := L.Ptr;
    if not Linear then
    begin
      var X := WrapCoord(TexFloor(S), L.Width, T.ClampU);
      var Y := WrapCoord(TexFloor(TT), L.Height, T.ClampV);
      Exit(FitTexel(T, P, FitOffset(T.Swizzle, RowBytes, Bits, X, Y), X));
    end;
    var FS := S - 0.5;
    var FT := TT - 0.5;
    var X0 := TexFloor(FS);
    var Y0 := TexFloor(FT);
    var FracX := Trunc((FS - X0) * 16);
    var FracY := Trunc((FT - Y0) * 16);
    var XA := WrapCoord(X0, L.Width, T.ClampU);
    var XB := WrapCoord(X0 + 1, L.Width, T.ClampU);
    var YA := WrapCoord(Y0, L.Height, T.ClampV);
    var YB := WrapCoord(Y0 + 1, L.Height, T.ClampV);
    var Sw := T.Swizzle;
    var C00 := FitTexel(T, P, FitOffset(Sw, RowBytes, Bits, XA, YA), XA);
    var C10 := FitTexel(T, P, FitOffset(Sw, RowBytes, Bits, XB, YA), XB);
    var C01 := FitTexel(T, P, FitOffset(Sw, RowBytes, Bits, XA, YB), XA);
    var C11 := FitTexel(T, P, FitOffset(Sw, RowBytes, Bits, XB, YB), XB);
    Result := 0;
    for var Sh := 0 to 3 do
    begin
      var Shift := Sh * 8;
      var A := Integer((C00 shr Shift) and $FF);
      var B := Integer((C10 shr Shift) and $FF);
      var C := Integer((C01 shr Shift) and $FF);
      var D := Integer((C11 shr Shift) and $FF);
      var Top := A * (16 - FracX) + B * FracX;
      var Bottom := C * (16 - FracX) + D * FracX;
      var V := (Top * (16 - FracY) + Bottom * FracY) shr 8;
      Result := Result or (Cardinal(V) shl Shift);
    end;
    Exit;
  end;
  if not Linear then
  begin
    var X := WrapCoord(TexFloor(S), L.Width, T.ClampU);
    var Y := WrapCoord(TexFloor(TT), L.Height, T.ClampV);
    if not T.Swizzle and (L.Ptr <> nil) then
    begin
      var Pixel := Cardinal(Y * L.BufWidth + X);
      case T.Format of
        3: if UInt64(Pixel) * 4 + 4 <= L.Size then Exit(PCardinal(L.Ptr + Pixel * 4)^);
        5: if Pixel < L.Size then Exit(ClutLookup(T, L.Ptr[Pixel]));
        4:
          begin
            var Off := Cardinal(Y * (L.BufWidth div 2) + X div 2);
            if Off < L.Size then
            begin
              var B := L.Ptr[Off];
              if X and 1 <> 0 then B := B shr 4;
              Exit(ClutLookup(T, B and $F));
            end;
          end;
      end;
    end;
    Exit(FastTexel(T, L, X, Y));
  end;
  var FS := S - 0.5;
  var FT := TT - 0.5;
  var X0 := TexFloor(FS);
  var Y0 := TexFloor(FT);
  var FracX := Trunc((FS - X0) * 16);
  var FracY := Trunc((FT - Y0) * 16);
  var XA := WrapCoord(X0, L.Width, T.ClampU);
  var XB := WrapCoord(X0 + 1, L.Width, T.ClampU);
  var YA := WrapCoord(Y0, L.Height, T.ClampV);
  var YB := WrapCoord(Y0 + 1, L.Height, T.ClampV);
  var C00 := FastTexel(T, L, XA, YA);
  var C10 := FastTexel(T, L, XB, YA);
  var C01 := FastTexel(T, L, XA, YB);
  var C11 := FastTexel(T, L, XB, YB);
  Result := 0;
  for var Sh := 0 to 3 do
  begin
    var Shift := Sh * 8;
    var A := Integer((C00 shr Shift) and $FF);
    var B := Integer((C10 shr Shift) and $FF);
    var C := Integer((C01 shr Shift) and $FF);
    var D := Integer((C11 shr Shift) and $FF);
    var Top := A * (16 - FracX) + B * FracX;
    var Bottom := C * (16 - FracX) + D * FracX;
    var V := (Top * (16 - FracY) + Bottom * FracY) shr 8;
    Result := Result or (Cardinal(V) shl Shift);
  end;
end;

function GESampleTexture(const T: TGETexture; S, TT: Single): Cardinal;
begin
  Result := SampleLevel(T, T.Level, S, TT, T.Linear);
end;

function GELog16(V: Single): Integer;
begin
  if not (V > 0) then
    Exit(-$10000);
  var Bits := PCardinal(@V)^;
  Result := (Integer((Bits shr 23) and $FF) - 127) * 16 + Integer((Bits shr 19) and $F);
end;

// Texture coordinates in level 0 texels to those of a level.
function LevelSample(const T: TGETexture; Level: Integer; S, TT: Single; Linear: Boolean): Cardinal;
begin
  if Level > 0 then
  begin
    S := S * T.Levels[Level].Width / T.Levels[0].Width;
    TT := TT * T.Levels[Level].Height / T.Levels[0].Height;
  end;
  Result := SampleLevel(T, Level, S, TT, Linear);
end;

// Up to level 0 the magnification filter; past it the minification one,
// from the nearest level or, for the mipmap-linear filters, two levels
// mixed by the level's 4-bit fraction.
function GESampleTextureLod(const T: TGETexture; S, TT: Single; Lod: Integer): Cardinal;
begin
  if Lod <= 0 then
    Exit(SampleLevel(T, 0, S, TT, T.Linear));
  var Linear := (T.MinFilter and 1) <> 0;
  if (T.MinFilter < 4) or (T.MaxLevel = 0) then
    Exit(SampleLevel(T, 0, S, TT, Linear));
  if Lod > T.MaxLevel * 16 then
    Lod := T.MaxLevel * 16;
  var Level := Lod shr 4;
  var Frac := Lod and 15;
  if T.MinFilter < 6 then
  begin
    if Frac >= 8 then
      Inc(Level);
    if Level > T.MaxLevel then
      Level := T.MaxLevel;
    Exit(LevelSample(T, Level, S, TT, Linear));
  end;
  var C0 := LevelSample(T, Level, S, TT, Linear);
  if (Frac = 0) or (Level >= T.MaxLevel) then
    Exit(C0);
  var C1 := LevelSample(T, Level + 1, S, TT, Linear);
  Result := 0;
  for var Sh := 0 to 3 do
  begin
    var Shift := Sh * 8;
    var V := (Integer((C0 shr Shift) and $FF) * (16 - Frac) + Integer((C1 shr Shift) and $FF) * Frac) shr 4;
    Result := Result or (Cardinal(V) shl Shift);
  end;
end;

end.
