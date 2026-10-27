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
  end;

  TGETexture = record
    Memory: TPSPMemory;
    Format: Integer;
    Swizzle: Boolean;
    Levels: array[0..7] of TGETexLevel;
    LevelCount: Integer;
    Level: Integer;
    ClampU, ClampV: Boolean;
    Linear: Boolean;
    // CLUT cache as loaded, and the index transform.
    Clut: PByte;
    ClutFormat, ClutShift, ClutMask, ClutOffset: Integer;
  end;

function GESampleTexture(const T: TGETexture; S, TT: Single): Cardinal;
function GEFetchTexel(const T: TGETexture; Level, X, Y: Integer): Cardinal;
function GEDecode16(Format: Integer; P: Cardinal): Cardinal;

implementation

function GEDecode16(Format: Integer; P: Cardinal): Cardinal;
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

function ClutLookup(const T: TGETexture; Index: Cardinal): Cardinal;
begin
  var I := ((Index shr T.ClutShift) and Cardinal(T.ClutMask)) or (Cardinal(T.ClutOffset) and $1FF);
  if T.ClutFormat = 3 then
    Result := PCardinal(T.Clut + (I and $FF) * 4)^
  else
    Result := GEDecode16(T.ClutFormat, PWord(T.Clut + (I and $1FF) * 2)^);
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

function GEFetchTexel(const T: TGETexture; Level, X, Y: Integer): Cardinal;
begin
  var L := T.Levels[Level];
  var M := T.Memory;
  case T.Format of
    0, 1, 2:
      Result := GEDecode16(T.Format, M.Read16(L.Addr + TexelOffset(T, L, X, Y, 16)));
    3:
      Result := M.Read32(L.Addr + TexelOffset(T, L, X, Y, 32));
    4:
      begin
        var B := M.Read8(L.Addr + TexelOffset(T, L, X, Y, 4));
        if (X and 1) <> 0 then
          B := B shr 4
        else
          B := B and $F;
        Result := ClutLookup(T, B);
      end;
    5:
      Result := ClutLookup(T, M.Read8(L.Addr + TexelOffset(T, L, X, Y, 8)));
    6:
      Result := ClutLookup(T, M.Read16(L.Addr + TexelOffset(T, L, X, Y, 16)));
    7:
      Result := ClutLookup(T, M.Read32(L.Addr + TexelOffset(T, L, X, Y, 32)));
    8, 9, 10:
      begin
        // 4x4 blocks in rows of BufWidth/4 blocks: the colour block (indices,
        // then the two colours), and for DXT3/5 the alpha data after it.
        var BlockBytes := 16;
        if T.Format = 8 then
          BlockBytes := 8;
        var BlocksPerRow := L.BufWidth div 4;
        var Block := L.Addr + Cardinal(((Y shr 2) * BlocksPerRow + (X shr 2)) * BlockBytes);
        var Bits := M.Read32(Block);
        var C0 := M.Read16(Block + 4);
        var C1 := M.Read16(Block + 6);
        var Pixel := (Y and 3) * 4 + (X and 3);
        Result := DXTColor(C0, C1, (Bits shr (Pixel * 2)) and 3);
        if T.Format = 9 then
        begin
          // 4 bits a texel, a row in 16 bits; widened without repeating.
          var AW := M.Read16(Block + 8 + Cardinal((Y and 3) * 2));
          var A := (AW shr ((X and 3) * 4)) and $F;
          Result := (Result and $FFFFFF) or ((A shl 4) shl 24);
        end
        else if T.Format = 10 then
        begin
          // 48 bits of 3-bit indices, then the two end alphas.
          var ABits := UInt64(M.Read32(Block + 8)) or (UInt64(M.Read16(Block + 12)) shl 32);
          var A0 := M.Read8(Block + 14);
          var A1 := M.Read8(Block + 15);
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

function GESampleTexture(const T: TGETexture; S, TT: Single): Cardinal;
begin
  var L := T.Levels[T.Level];
  if not T.Linear then
  begin
    var X := WrapCoord(Floor(S), L.Width, T.ClampU);
    var Y := WrapCoord(Floor(TT), L.Height, T.ClampV);
    Exit(GEFetchTexel(T, T.Level, X, Y));
  end;
  var FS := S - 0.5;
  var FT := TT - 0.5;
  var X0 := Floor(FS);
  var Y0 := Floor(FT);
  var FracX := Trunc((FS - X0) * 16);
  var FracY := Trunc((FT - Y0) * 16);
  var XA := WrapCoord(X0, L.Width, T.ClampU);
  var XB := WrapCoord(X0 + 1, L.Width, T.ClampU);
  var YA := WrapCoord(Y0, L.Height, T.ClampV);
  var YB := WrapCoord(Y0 + 1, L.Height, T.ClampV);
  var C00 := GEFetchTexel(T, T.Level, XA, YA);
  var C10 := GEFetchTexel(T, T.Level, XB, YA);
  var C01 := GEFetchTexel(T, T.Level, XA, YB);
  var C11 := GEFetchTexel(T, T.Level, XB, YB);
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

end.
