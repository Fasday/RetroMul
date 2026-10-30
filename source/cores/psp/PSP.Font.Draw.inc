// Font information, drawing glyphs, the font list and its searches.

function TPSPFont.Resolve(Slot: TPSPFontSlot; Code: Integer): Integer;
begin
  var Font := Slot.Data.Font;
  Result := Font.Lookup(Code);
  if Result = PGFMissing then
  begin
    Result := Font.Lookup(FMemory.Read16(Slot.Lib.Addr + $48));
    if Result < 0 then
      Result := PGFBelow;
  end;
end;

procedure TPSPFont.hGetFontInfo;
begin
  var Slot := SlotOf(FHLE.Arg(0));
  var Info := FHLE.Arg(1);
  if (Slot = nil) or (Slot.Data = nil) or (Info = 0) then
  begin
    FHLE.Result(SCE_FONT_ERROR_ARG);
    Exit;
  end;
  var F := Slot.Data.Font;
  var Ints: TArray<Integer> := [F.MaxSizeH, F.MaxSizeV, F.MaxAscender, F.MaxDescender, F.MaxLeftX,
    F.MaxBaseY, F.MinCenterX, F.MaxTopY, F.MaxAdvanceH, F.MaxAdvanceV];
  for var I := 0 to 9 do
  begin
    FMemory.Write32(Info + Cardinal(I * 4), Cardinal(Ints[I]));
    FMemory.WriteFloat(Info + 40 + Cardinal(I * 4), Ints[I] / 64);
  end;
  FMemory.Write16(Info + 80, Word(F.MaxGlyphWidth));
  FMemory.Write16(Info + 82, Word(F.MaxGlyphHeight));
  FMemory.Write32(Info + 84, Cardinal(F.GlyphCount));
  FMemory.Write32(Info + 88, 0);
  // Of the style only the size and resolution are the font's.
  FMemory.Fill(Info + 92, 0, FontStyleSize);
  FMemory.WriteFloat(Info + 92, F.HSize / 64);
  FMemory.WriteFloat(Info + 96, F.VSize / 64);
  FMemory.WriteFloat(Info + 100, F.HRes / 64);
  FMemory.WriteFloat(Info + 104, F.VRes / 64);
  FMemory.Write8(Info + 260, Byte(F.Bpp));
  FHLE.Result(0);
end;

procedure TPSPFont.WriteCharInfo(Addr: Cardinal; G, Bitmap: TPGFGlyph);
begin
  FMemory.Fill(Addr, 0, 60);
  if G = nil then
    Exit;
  if Bitmap <> nil then
  begin
    FMemory.Write32(Addr, Cardinal(Bitmap.W));
    FMemory.Write32(Addr + 4, Cardinal(Bitmap.H));
    FMemory.Write32(Addr + 8, Cardinal(Bitmap.Left));
    FMemory.Write32(Addr + 12, Cardinal(Bitmap.Top));
  end;
  FMemory.Write32(Addr + 16, Cardinal(G.Dim.X));
  FMemory.Write32(Addr + 20, Cardinal(G.Dim.Y));
  FMemory.Write32(Addr + 24, Cardinal(G.BearingY.X));
  FMemory.Write32(Addr + 28, Cardinal(G.BearingY.X - G.Dim.Y));
  FMemory.Write32(Addr + 32, Cardinal(G.BearingX.X));
  FMemory.Write32(Addr + 36, Cardinal(G.BearingY.X));
  FMemory.Write32(Addr + 40, Cardinal(G.BearingX.Y));
  FMemory.Write32(Addr + 44, Cardinal(G.BearingY.Y));
  FMemory.Write32(Addr + 48, Cardinal(G.Advance.X));
  FMemory.Write32(Addr + 52, Cardinal(G.Advance.Y));
  FMemory.Write16(Addr + 56, Word(G.ShadowFlags));
  FMemory.Write16(Addr + 58, Word(G.ShadowId));
end;

procedure TPSPFont.InfoCall(Shadow: Boolean);
begin
  var Slot := SlotOf(FHLE.Arg(0));
  var Code := Integer(FHLE.Arg(1) and $FFFF);
  var Info := FHLE.Arg(2);
  if (Slot = nil) or (Slot.Data = nil) or (Info = 0) then
  begin
    FHLE.Result(SCE_FONT_ERROR_ARG);
    Exit;
  end;
  var Index := Resolve(Slot, Code);
  var G := Slot.Data.Font.Glyph(Index);
  var Bitmap := G;
  if Shadow then
    Bitmap := Slot.Data.Font.Shadow(Index);
  WriteCharInfo(Info, G, Bitmap);
  if Slot.Data.FirstLook(Index) then
    Finish(0, FileYieldUs)
  else
    FHLE.Result(0);
end;

procedure TPSPFont.hGetCharInfo;
begin
  InfoCall(False);
end;

procedure TPSPFont.hGetShadowInfo;
begin
  InfoCall(True);
end;

procedure TPSPFont.RectCall(Shadow: Boolean);
begin
  var Slot := SlotOf(FHLE.Arg(0));
  var Code := Integer(FHLE.Arg(1) and $FFFF);
  var Rect := FHLE.Arg(2);
  if (Slot = nil) or (Slot.Data = nil) or (Rect = 0) then
  begin
    FHLE.Result(SCE_FONT_ERROR_ARG);
    Exit;
  end;
  var Index := Resolve(Slot, Code);
  var G: TPGFGlyph;
  if Shadow then
    G := Slot.Data.Font.Shadow(Index)
  else
    G := Slot.Data.Font.Glyph(Index);
  if G = nil then
    FMemory.Write32(Rect, 0)
  else
  begin
    FMemory.Write16(Rect, Word(G.W));
    FMemory.Write16(Rect + 2, Word(G.H));
  end;
  if Slot.Data.FirstLook(Index) then
    Finish(0, FileYieldUs)
  else
    FHLE.Result(0);
end;

procedure TPSPFont.hGetCharImageRect;
begin
  RectCall(False);
end;

procedure TPSPFont.hGetShadowImageRect;
begin
  RectCall(True);
end;

{ Drawing }

procedure TPSPFont.Draw(G: TPGFGlyph; Image: Cardinal; ClipX, ClipY, ClipW, ClipH: Integer);
begin
  // The glyph's top left goes at the pen; a fraction of a pixel in x splits
  // each column over two, the near part rounded up and the far one down, and
  // the result adds to what the buffer holds, saturating. Only the 4 and
  // 8 bit formats draw.
  var Format := FMemory.Read32(Image);
  if (Format <> 0) and (Format <> 2) then
    Exit;
  var XPos := Integer(FMemory.Read32(Image + 4));
  var YPos := Integer(FMemory.Read32(Image + 8));
  var BufW := Integer(FMemory.Read16(Image + 12));
  var BufH := Integer(FMemory.Read16(Image + 14));
  var Pitch := Integer(SmallInt(FMemory.Read16(Image + 16)));
  var Buf := FMemory.Read32(Image + 20);
  var X0 := XPos div 64;
  if (XPos < 0) and (XPos mod 64 <> 0) then
    Dec(X0);
  var Frac := XPos - X0 * 64;
  var Y0 := YPos div 64;
  if (YPos < 0) and (YPos mod 64 <> 0) then
    Dec(Y0);
  var Cols := G.W;
  if Frac <> 0 then
    Inc(Cols);
  var Scale := 1;
  if Format = 2 then
    Scale := 17;
  for var R := 0 to G.H - 1 do
  begin
    var DY := Y0 + R;
    if (DY < 0) or (DY >= BufH) or (Cardinal(DY - ClipY) >= Cardinal(ClipH)) then
      Continue;
    for var C := 0 to Cols - 1 do
    begin
      var DX := X0 + C;
      if (DX < 0) or (DX >= BufW) or (Cardinal(DX - ClipX) >= Cardinal(ClipW)) then
        Continue;
      var Cur := G.Pixel(C, R) * Scale;
      var Prev := G.Pixel(C - 1, R) * Scale;
      var V := Cur - (Cur * Frac) shr 6 + (Prev * Frac) shr 6;
      if V = 0 then
        Continue;
      if Format = 2 then
      begin
        var A := Cardinal(Int64(Buf) + Int64(DY) * Pitch + DX);
        FMemory.Write8(A, Min(255, Integer(FMemory.Read8(A)) + V));
      end
      else
      begin
        var A := Cardinal(Int64(Buf) + Int64(DY) * Pitch + DX div 2);
        var B := FMemory.Read8(A);
        var Shift := (DX and 1) * 4;
        var N := Min(15, Integer((B shr Shift) and $F) + V);
        FMemory.Write8(A, (B and not Cardinal($F shl Shift)) or Cardinal(N shl Shift));
      end;
    end;
  end;
end;

procedure TPSPFont.DrawCall(Shadow, Clip: Boolean);
begin
  var Slot := SlotOf(FHLE.Arg(0));
  var Code := Integer(FHLE.Arg(1) and $FFFF);
  var Image := FHLE.Arg(2);
  var ClipX := 0;
  var ClipY := 0;
  var ClipW := -1;
  var ClipH := -1;
  if Clip then
  begin
    ClipX := FHLE.ArgInt(3);
    ClipY := FHLE.ArgInt(4);
    ClipW := FHLE.ArgInt(5);
    ClipH := FHLE.ArgInt(6);
  end;
  if (Slot = nil) or (Slot.Data = nil) or (Image = 0) then
  begin
    FHLE.Result(SCE_FONT_ERROR_ARG);
    Exit;
  end;
  FHLE.Result(0);
  var D := Slot.Data;
  var Index := Resolve(Slot, Code);
  var G: TPGFGlyph;
  if Shadow then
    G := D.Font.Shadow(Index)
  else
    G := D.Font.Glyph(Index);
  var Fresh := D.FirstLook(Index);
  if (G = nil) or (G.W * G.H = 0) then
  begin
    if Fresh then
      Finish(0, FileYieldUs);
    Exit;
  end;
  var Key := Index * 2 + Ord(Shadow);
  if not D.Streamed or (D.CacheKey = Key) or (D.Refs = 0) then
  begin
    Draw(G, Image, ClipX, ClipY, ClipW, ClipH);
    if Fresh then
      Finish(0, FileYieldUs);
    Exit;
  end;
  // A mode 0 font loads the glyph it draws: its bytes and its bitmap.
  var Old := D.Cache;
  D.Cache := nil;
  D.CacheKey := -1;
  var Lib := Slot.Lib;
  var CacheSize := G.DataSize;
  if G.CacheDataSize > 0 then CacheSize := G.CacheDataSize;
  FreeBlocks(Lib, Old,
    procedure
    begin
      AllocBlocks(Lib, [Cardinal(CacheSize), Cardinal(G.W * G.H)],
        procedure(const Addrs: TArray<Cardinal>; Ok: Boolean)
        begin
          if not Ok then
          begin
            FHLE.Result(SCE_FONT_ERROR_NOMEMORY);
            Exit;
          end;
          D.Cache := Copy(Addrs);
          D.CacheKey := Key;
          Draw(G, Image, ClipX, ClipY, ClipW, ClipH);
          Finish(0, FileYieldUs);
        end);
    end);
end;

procedure TPSPFont.hGetCharGlyphImage;
begin
  DrawCall(False, False);
end;

procedure TPSPFont.hGetCharGlyphImageClip;
begin
  DrawCall(False, True);
end;

procedure TPSPFont.hGetShadowGlyphImage;
begin
  DrawCall(True, False);
end;

procedure TPSPFont.hGetShadowGlyphImageClip;
begin
  DrawCall(True, True);
end;

{ The font list }

procedure TPSPFont.hGetNumFontList;
begin
  var Lib := LibOf(FHLE.Arg(0));
  var ErrPtr := FHLE.Arg(1);
  if Lib = nil then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_LIBID);
    FHLE.Result(0);
    Exit;
  end;
  SetError(ErrPtr, 0);
  if Lib.Done then
    FHLE.Result(0)
  else
    FHLE.Result(Length(InternalFonts));
end;

procedure TPSPFont.hGetFontList;
begin
  var Lib := LibOf(FHLE.Arg(0));
  var List := FHLE.Arg(1);
  var Num := FHLE.ArgInt(2);
  if Lib = nil then
  begin
    FHLE.Result(SCE_FONT_ERROR_LIBID);
    Exit;
  end;
  if List = 0 then
  begin
    FHLE.Result(SCE_FONT_ERROR_ARG);
    Exit;
  end;
  if not Lib.Done then
    for var I := 0 to Min(Num, Length(InternalFonts)) - 1 do
      WriteStyle(List + Cardinal(I * FontStyleSize), I);
  Finish(0, ListYieldUs);
end;

procedure TPSPFont.hGetFontInfoByIndexNumber;
begin
  var Lib := LibOf(FHLE.Arg(0));
  var Style := FHLE.Arg(1);
  var Index := FHLE.ArgInt(2);
  if Lib = nil then
  begin
    FHLE.Result(SCE_FONT_ERROR_LIBID);
    Exit;
  end;
  if Lib.Done or (Style = 0) or (Index < 0) or (Index > High(InternalFonts)) then
  begin
    FHLE.Result(SCE_FONT_ERROR_ARG);
    Exit;
  end;
  WriteStyle(Style, Index);
  FHLE.Result(0);
end;

function TPSPFont.Match(Lib: TPSPFontLib; Style: Cardinal; Optimum: Boolean): Integer;
begin
  // Sizes are asked for at a resolution (the style's, or the library's) and
  // measured against the fonts' at 128 dpi; the firmware compares the fonts'
  // vertical size with the requested horizontal one. FindFont wants the
  // first exact match. FindOptimumFont takes the nearest size, the first of
  // equals, except that among fonts matching a requested attribute the last
  // of equals wins; nothing matching leaves font 0.
  var H := FMemory.ReadFloat(Style);
  var V := FMemory.ReadFloat(Style + 4);
  var StyleHRes := FMemory.ReadFloat(Style + 8);
  var StyleVRes := FMemory.ReadFloat(Style + 12);
  var Family := FMemory.Read16(Style + 20);
  var Kind := FMemory.Read16(Style + 22);
  var Language := FMemory.Read16(Style + 26);
  var Country := FMemory.Read16(Style + 30);
  var Name := FMemory.ReadString(Style + 32, 64);
  var FileName := FMemory.ReadString(Style + 96, 64);
  var ResH := FMemory.ReadFloat(Lib.Addr + $38);
  var ResV := FMemory.ReadFloat(Lib.Addr + $3C);
  if StyleHRes > 0 then
    ResH := StyleHRes;
  if StyleVRes > 0 then
    ResV := StyleVRes;
  var UseH := H > 0;
  var UseV := V > 0;
  var TargetH: Single := H * ResH / 128;
  var TargetV: Single := H * ResV / 128;
  var AnyAttr := (Family <> 0) or (Kind <> 0) or (Language <> 0) or (Country <> 0) or (Name <> '') or
    (FileName <> '');
  if Optimum then
    Result := 0
  else
    Result := -1;
  var BestDiff: Single := Infinity;
  for var I := 0 to High(InternalFonts) do
  begin
    var E := InternalFonts[I];
    if ((Family <> 0) and (E.Family <> Family)) or ((Kind <> 0) and (E.Style <> Kind)) or
      ((Language <> 0) and (E.Language <> Language)) or ((Country <> 0) and (E.Country <> Country)) or
      ((Name <> '') and (E.Name <> Name)) or ((FileName <> '') and (E.FileName <> FileName)) then
      Continue;
    var Size: Single := E.Points;
    if not Optimum then
    begin
      if (UseH and (Size <> TargetH)) or (UseV and (Size <> TargetV)) then
        Continue;
      Exit(I);
    end;
    var Diff: Single := 0;
    if UseH or UseV then
    begin
      Diff := Infinity;
      if UseH then
        Diff := Min(Diff, Abs(Size - TargetH));
      if UseV then
        Diff := Min(Diff, Abs(Size - TargetV));
    end;
    if (AnyAttr and (Diff <= BestDiff)) or (not AnyAttr and (Diff < BestDiff)) then
    begin
      Result := I;
      BestDiff := Diff;
    end;
  end;
end;

procedure TPSPFont.hFindOptimumFont;
begin
  var Lib := LibOf(FHLE.Arg(0));
  var Style := FHLE.Arg(1);
  var ErrPtr := FHLE.Arg(2);
  if (Lib = nil) or (Style = 0) then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_LIBID);
    FHLE.Result(0);
    Exit;
  end;
  SetError(ErrPtr, 0);
  FHLE.Result(Cardinal(Match(Lib, Style, True)));
end;

procedure TPSPFont.hFindFont;
begin
  var Lib := LibOf(FHLE.Arg(0));
  var Style := FHLE.Arg(1);
  var ErrPtr := FHLE.Arg(2);
  if Lib = nil then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_LIBID);
    FHLE.Result(0);
    Exit;
  end;
  if Style = 0 then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_ARG);
    FHLE.Result(0);
    Exit;
  end;
  SetError(ErrPtr, 0);
  FHLE.Result(Cardinal(Match(Lib, Style, False)));
end;

{ Library settings }

procedure TPSPFont.hSetAltCharacterCode;
begin
  var Lib := LibOf(FHLE.Arg(0));
  if Lib = nil then
  begin
    FHLE.Result(SCE_FONT_ERROR_LIBID);
    Exit;
  end;
  FMemory.Write16(Lib.Addr + $48, FHLE.Arg(1) and $FFFF);
  FHLE.Result(0);
end;

procedure TPSPFont.hSetResolution;
begin
  var Lib := LibOf(FHLE.Arg(0));
  var H := FHLE.ArgFloat(0);
  var V := FHLE.ArgFloat(1);
  if Lib = nil then
  begin
    FHLE.Result(SCE_FONT_ERROR_LIBID);
    Exit;
  end;
  if not (H > 0) or not (V > 0) then
  begin
    FHLE.Result(SCE_FONT_ERROR_ARG);
    Exit;
  end;
  FMemory.WriteFloat(Lib.Addr + $38, H);
  FMemory.WriteFloat(Lib.Addr + $3C, V);
  FHLE.Result(0);
end;

procedure TPSPFont.Convert(Vertical, ToPoints: Boolean);
begin
  var Lib := LibOf(FHLE.Arg(0));
  var Value := FHLE.ArgFloat(0);
  var ErrPtr := FHLE.Arg(1);
  if Lib = nil then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_LIBID);
    FHLE.ResultFloat(0);
    Exit;
  end;
  var Res := FMemory.ReadFloat(Lib.Addr + $38);
  if Vertical then
    Res := FMemory.ReadFloat(Lib.Addr + $3C);
  var R: Single;
  if ToPoints then
    R := Value * 72 / Res
  else
    R := Value * Res / 72;
  SetError(ErrPtr, 0);
  FHLE.ResultFloat(R);
end;

procedure TPSPFont.hPixelToPointH;
begin
  Convert(False, True);
end;

procedure TPSPFont.hPixelToPointV;
begin
  Convert(True, True);
end;

procedure TPSPFont.hPointToPixelH;
begin
  Convert(False, False);
end;

procedure TPSPFont.hPointToPixelV;
begin
  Convert(True, False);
end;

procedure TPSPFont.hFlush;
begin
  if SlotOf(FHLE.Arg(0)) = nil then
    FHLE.Result(SCE_FONT_ERROR_ARG)
  else
    FHLE.Result(0);
end;

procedure TPSPFont.Register;
const
  L = 'sceLibFont';
begin
  var H := FHLE;
  H.Register(L, $67F17ED7, 'sceFontNewLib', hNewLib);
  H.Register(L, $574B6FBC, 'sceFontDoneLib', hDoneLib);
  H.Register(L, $A834319D, 'sceFontOpen', hOpen);
  H.Register(L, $BB8E7FE6, 'sceFontOpenUserMemory', hOpenUserMemory);
  H.Register(L, $57FCB733, 'sceFontOpenUserFile', hOpenUserFile);
  H.Register(L, $3AEA8CB6, 'sceFontClose', hClose);
  H.Register(L, $27F6E642, 'sceFontGetNumFontList', hGetNumFontList);
  H.Register(L, $BC75D85B, 'sceFontGetFontList', hGetFontList);
  H.Register(L, $099EF33C, 'sceFontFindOptimumFont', hFindOptimumFont);
  H.Register(L, $681E61A7, 'sceFontFindFont', hFindFont);
  H.Register(L, $0DA7535E, 'sceFontGetFontInfo', hGetFontInfo);
  H.Register(L, $5333322D, 'sceFontGetFontInfoByIndexNumber', hGetFontInfoByIndexNumber);
  H.Register(L, $DCC80C2F, 'sceFontGetCharInfo', hGetCharInfo);
  H.Register(L, $AA3DE7B5, 'sceFontGetShadowInfo', hGetShadowInfo);
  H.Register(L, $5C3E4A9E, 'sceFontGetCharImageRect', hGetCharImageRect);
  H.Register(L, $48B06520, 'sceFontGetShadowImageRect', hGetShadowImageRect);
  H.Register(L, $980F4895, 'sceFontGetCharGlyphImage', hGetCharGlyphImage);
  H.Register(L, $CA1E6945, 'sceFontGetCharGlyphImage_Clip', hGetCharGlyphImageClip);
  H.Register(L, $568BE516, 'sceFontGetShadowGlyphImage', hGetShadowGlyphImage);
  H.Register(L, $5DCF6858, 'sceFontGetShadowGlyphImage_Clip', hGetShadowGlyphImageClip);
  H.Register(L, $EE232411, 'sceFontSetAltCharacterCode', hSetAltCharacterCode);
  H.Register(L, $48293280, 'sceFontSetResolution', hSetResolution);
  H.Register(L, $74B21701, 'sceFontPixelToPointH', hPixelToPointH);
  H.Register(L, $F8F0752E, 'sceFontPixelToPointV', hPixelToPointV);
  H.Register(L, $472694CD, 'sceFontPointToPixelH', hPointToPixelH);
  H.Register(L, $3C4B7E82, 'sceFontPointToPixelV', hPointToPixelV);
  H.Register(L, $02D7F94B, 'sceFontFlush', hFlush);
end;
