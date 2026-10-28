begin
  if not S.Through then
  begin
    var TestZ := F.Z;
    if S.DepthClamp then
    begin
      if TestZ < 0 then TestZ := 0;
      if TestZ > 65535 then TestZ := 65535;
    end;
    if (TestZ < S.MinZ) or (TestZ > S.MaxZ) then Exit;
  end;
{$IFDEF GEPIX_TEXTURE}
  ApplyTexture(S, F);
{$ENDIF}
  if S.AlphaTest then
    if not TestFunc(S.AlphaFunc, F.A and S.AlphaMask, S.AlphaRef and S.AlphaMask) then Exit;

{$IFDEF GEPIX_8888}
  var Addr := (S.FBAddr + (Cardinal(Y) * S.FBStride + Cardinal(X)) * 4) and (PSPVRAMSize - 1);
  var P := PCardinal(S.VRAM + Addr);
{$ELSE}
  var Addr := (S.FBAddr + (Cardinal(Y) * S.FBStride + Cardinal(X)) * 2) and (PSPVRAMSize - 1);
  var P := PWord(S.VRAM + Addr);
{$ENDIF}
  var Old := Cardinal(P^);
{$IFDEF GEPIX_DEPTH}
  var Z := F.Z;
  if Z < 0 then Z := 0;
  if Z > 65535 then Z := 65535;
  var ZA := (S.ZAddr + (Cardinal(Y) * S.ZStride + Cardinal(X)) * 2) and (PSPVRAMSize - 1);
  var ZP := PWord(S.VRAM + ZA);
  if not TestFunc(S.DepthFunc, Z, ZP^) then Exit;
  if S.DepthWrite then ZP^ := Word(Z);
{$ENDIF}

  var R := F.R; var G := F.G; var B := F.B;
{$IFDEF GEPIX_BLEND}
  var DR, DG, DB, DA: Integer;
{$IFDEF GEPIX_8888}
  DecodePixel(3, Old, DR, DG, DB, DA);
{$ELSEIF DEFINED(GEPIX_565)}
  DecodePixel(0, Old, DR, DG, DB, DA);
{$ELSEIF DEFINED(GEPIX_5551)}
  DecodePixel(1, Old, DR, DG, DB, DA);
{$ELSE}
  DecodePixel(2, Old, DR, DG, DB, DA);
{$ENDIF}
  R := BlendChannel(S, R, DR, F.A, DA, 0);
  G := BlendChannel(S, G, DG, F.A, DA, 8);
  B := BlendChannel(S, B, DB, F.A, DA, 16);
{$ENDIF}
  if S.Dither then
  begin
    var D := S.DitherMatrix[(Y and 3) * 4 + (X and 3)];
    Inc(R, D); Inc(G, D); Inc(B, D);
  end;
  R := Clamp255(R); G := Clamp255(G); B := Clamp255(B);
{$IFDEF GEPIX_8888}
  var C := (Old and $FF000000) or Cardinal(R) or (Cardinal(G) shl 8) or (Cardinal(B) shl 16);
{$ELSEIF DEFINED(GEPIX_565)}
  var C := Cardinal(R shr 3) or (Cardinal(G shr 2) shl 5) or (Cardinal(B shr 3) shl 11);
{$ELSEIF DEFINED(GEPIX_5551)}
  var C := (Old and $8000) or Cardinal(R shr 3) or (Cardinal(G shr 3) shl 5) or (Cardinal(B shr 3) shl 10);
{$ELSE}
  var C := (Old and $F000) or Cardinal(R shr 4) or (Cardinal(G shr 4) shl 4) or (Cardinal(B shr 4) shl 8);
{$ENDIF}
  C := (C and not S.KeepMask) or (Old and S.KeepMask);
{$IFDEF GEPIX_8888}
  P^ := C;
{$ELSE}
  P^ := Word(C);
{$ENDIF}
end;
