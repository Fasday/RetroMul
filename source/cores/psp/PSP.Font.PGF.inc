// PGF files. All fields little-endian, bit fields LSB first. The header
// (0x188 bytes, more in later revisions) is followed by four tables of 32-bit
// (x, y) pairs the glyphs index their metrics into, then the shadow map (shadow
// id -> character), the charmap (character - first -> glyph index) and the
// glyph pointers (glyph index -> 32-bit words from the glyph data), each
// padded to 32 bits. A glyph is 14 bits of size in bytes, 7 bits each of
// width, height, left and top (signed), 6 bits of flags (bits 0-1: 1 rows,
// 2 columns; bits 2-5: dimension, x and y bearing, advance given as 8-bit
// table indices rather than inline pairs), 7 bits nobody reads, 9 bits of
// shadow id, the metrics and then the bitmap: run-length coded nibbles, a
// count c < 8 repeating the next nibble c + 1 times and c >= 8 introducing
// 16 - c literal ones. Its shadow follows it: the same first 48 bits, then
// its bitmap.

function Align32(Count, Bpe: Int64): Cardinal;
begin
  Result := Cardinal(((Count * Bpe + 31) div 32) * 4);
end;

function TPGFLayout.Read(const Header: TBytes): Boolean;
begin
  Result := False;
  if Length(Header) < $188 then
    Exit;
  if (Header[4] <> Ord('P')) or (Header[5] <> Ord('G')) or (Header[6] <> Ord('F')) or (Header[7] <> Ord('0')) then
    Exit;
  HeaderSize := PWord(@Header[2])^;
  if HeaderSize < $188 then
    HeaderSize := $188;
  Revision := PInteger(@Header[8])^;
  CharMapLength := PInteger(@Header[$10])^;
  CharPtrLength := PInteger(@Header[$14])^;
  CharMapBpe := PInteger(@Header[$18])^;
  CharPtrBpe := PInteger(@Header[$1C])^;
  ShadowMapLength := PInteger(@Header[$16C])^;
  ShadowMapBpe := PInteger(@Header[$170])^;
  if (CharMapLength < 0) or (CharMapLength > $110000) or (CharPtrLength < 0) or (CharPtrLength > $110000) or
    (ShadowMapLength < 0) or (ShadowMapLength > $110000) then
    Exit;
  if (CharMapBpe < 1) or (CharMapBpe > 32) or (CharPtrBpe < 1) or (CharPtrBpe > 32) then
    Exit;
  if (ShadowMapLength > 0) and ((ShadowMapBpe < 1) or (ShadowMapBpe > 32)) then
    Exit;
  var Pos: Int64 := HeaderSize;
  for var K := 0 to 3 do
  begin
    TableLength[K] := Header[$102 + K];
    Parts[K] := TableLength[K] * 8;
    Inc(Pos, Parts[K]);
  end;
  ShadowMapPos := Pos;
  Parts[4] := Align32(ShadowMapLength, ShadowMapBpe);
  Inc(Pos, Parts[4]);
  Parts[5] := 0;
  Parts[6] := 0;
  CharMapPos := Pos;
  Parts[7] := Align32(CharMapLength, CharMapBpe);
  Inc(Pos, Parts[7]);
  CharPtrPos := Pos;
  Parts[8] := Align32(CharPtrLength, CharPtrBpe);
  Inc(Pos, Parts[8]);
  GlyphPos := Pos;
  Result := True;
end;

{ TPGFGlyph }

function TPGFGlyph.Pixel(X, Y: Integer): Integer;
begin
  if (X < 0) or (Y < 0) or (X >= W) or (Y >= H) then
    Result := 0
  else
    Result := Pixels[Y * W + X];
end;

{ TPGFFont }

constructor TPGFFont.Create;
begin
  inherited Create;
  FGlyphs := TObjectDictionary<Integer, TPGFGlyph>.Create([doOwnsValues]);
  FShadows := TObjectDictionary<Integer, TPGFGlyph>.Create([doOwnsValues]);
  Bpp := 4;
end;

destructor TPGFFont.Destroy;
begin
  FGlyphs.Free;
  FShadows.Free;
  inherited;
end;

function TPGFFont.Glyph(Index: Integer): TPGFGlyph;
begin
  if Index < 0 then
    Exit(nil);
  if not FGlyphs.TryGetValue(Index, Result) then
  begin
    Result := DecodeGlyph(Index);
    if Result <> nil then
      FGlyphs.Add(Index, Result);
  end;
end;

function TPGFFont.Shadow(Index: Integer): TPGFGlyph;
begin
  if Index < 0 then
    Exit(nil);
  if not FShadows.TryGetValue(Index, Result) then
  begin
    Result := DecodeShadow(Index);
    if Result <> nil then
      FShadows.Add(Index, Result);
  end;
end;

{ TPGFFile }

class function TPGFFile.Parse(const Data: TBytes): TPGFFile;
begin
  var L: TPGFLayout;
  if not L.Read(Data) then
    Exit(nil);
  if Length(Data) < L.CharPtrPos + L.Parts[8] then
    Exit(nil);
  Result := TPGFFile.Create;
  var F := Result;
  F.FData := Data;
  F.FLayout := L;
  F.FileSize := Length(Data);
  SetLength(F.Parts, 9);
  for var K := 0 to 8 do
    F.Parts[K] := L.Parts[K];
  F.HSize := PInteger(@Data[$24])^;
  F.VSize := PInteger(@Data[$28])^;
  F.HRes := PInteger(@Data[$2C])^;
  F.VRes := PInteger(@Data[$30])^;
  if Data[$22] <> 0 then
    F.Bpp := Data[$22];
  F.FirstCode := PWord(@Data[$B6])^;
  F.LastCode := PWord(@Data[$B8])^;
  F.MaxAscender := PInteger(@Data[$D4])^;
  F.MaxDescender := PInteger(@Data[$D8])^;
  F.MaxLeftX := PInteger(@Data[$DC])^;
  F.MaxBaseY := PInteger(@Data[$E0])^;
  F.MinCenterX := PInteger(@Data[$E4])^;
  F.MaxTopY := PInteger(@Data[$E8])^;
  F.MaxAdvanceH := PInteger(@Data[$EC])^;
  F.MaxAdvanceV := PInteger(@Data[$F0])^;
  F.MaxSizeH := PInteger(@Data[$F4])^;
  F.MaxSizeV := PInteger(@Data[$F8])^;
  F.MaxGlyphWidth := PWord(@Data[$FC])^;
  F.MaxGlyphHeight := PWord(@Data[$FE])^;
  F.GlyphCount := L.CharPtrLength;
  var Pos: Int64 := L.HeaderSize;
  for var K := 0 to 3 do
  begin
    SetLength(F.FTables[K], L.TableLength[K]);
    for var I := 0 to L.TableLength[K] - 1 do
    begin
      F.FTables[K][I].X := PInteger(@Data[Pos])^;
      F.FTables[K][I].Y := PInteger(@Data[Pos + 4])^;
      Inc(Pos, 8);
    end;
  end;
  F.FShadowMap := F.ReadMap(L.ShadowMapPos, L.ShadowMapLength, L.ShadowMapBpe);
  F.FCharMap := F.ReadMap(L.CharMapPos, L.CharMapLength, L.CharMapBpe);
  F.FCharPtr := F.ReadMap(L.CharPtrPos, L.CharPtrLength, L.CharPtrBpe);
end;

function TPGFFile.Bits(BitPos: Int64; N: Integer): Cardinal;
begin
  // Up to 32 bits from any bit position; past the end reads zeros.
  var ByteIdx := BitPos shr 3;
  var Acc: UInt64 := 0;
  for var I := 0 to 4 do
    if ByteIdx + I < Length(FData) then
      Acc := Acc or (UInt64(FData[ByteIdx + I]) shl (8 * I));
  Acc := Acc shr (BitPos and 7);
  if N >= 32 then
    Result := Cardinal(Acc)
  else
    Result := Cardinal(Acc) and ((Cardinal(1) shl N) - 1);
end;

function TPGFFile.SBits(BitPos: Int64; N: Integer): Integer;
begin
  var V := Bits(BitPos, N);
  if (N < 32) and ((V and (Cardinal(1) shl (N - 1))) <> 0) then
    Result := Integer(V) - (1 shl N)
  else
    Result := Integer(V);
end;

function TPGFFile.ReadMap(Pos: Int64; Count, Bpe: Integer): TArray<Integer>;
begin
  SetLength(Result, Count);
  for var I := 0 to Count - 1 do
    Result[I] := Integer(Bits(Pos * 8 + Int64(I) * Bpe, Bpe));
end;

function TPGFFile.Lookup(Code: Integer): Integer;
begin
  if Code < FirstCode then
    Exit(PGFBelow);
  var I := Code - FirstCode;
  if (Code > LastCode) or (I >= Length(FCharMap)) then
    Exit(PGFMissing);
  Result := FCharMap[I];
  if (Result < 0) or (Result >= GlyphCount) then
    Result := PGFMissing;
end;

function TPGFFile.GlyphBitPos(Index: Integer): Int64;
begin
  Result := (FLayout.GlyphPos + Int64(Cardinal(FCharPtr[Index])) * 4) * 8;
end;

procedure TPGFFile.DecodeBitmap(G: TPGFGlyph; BitPos: Int64; Layout: Integer);
begin
  var N := G.W * G.H;
  SetLength(G.Pixels, N);
  if N = 0 then
    Exit;
  var Limit := Int64(Length(FData)) * 8;
  var I := 0;
  var P := BitPos;
  while (I < N) and (P < Limit) do
  begin
    var C := Integer(Bits(P, 4));
    Inc(P, 4);
    var Count, Literal: Integer;
    if C < 8 then
    begin
      Count := C + 1;
      Literal := 0;
    end
    else
    begin
      Count := 16 - C;
      Literal := 1;
    end;
    var V := 0;
    if Literal = 0 then
    begin
      V := Integer(Bits(P, 4));
      Inc(P, 4);
    end;
    for var K := 1 to Count do
    begin
      if I >= N then
        Break;
      if Literal <> 0 then
      begin
        V := Integer(Bits(P, 4));
        Inc(P, 4);
      end;
      if Layout = 2 then
        G.Pixels[(I mod G.H) * G.W + I div G.H] := V
      else
        G.Pixels[I] := V;
      Inc(I);
    end;
  end;
end;

function TPGFFile.DecodeGlyph(Index: Integer): TPGFGlyph;
begin
  if (Index < 0) or (Index >= GlyphCount) then
    Exit(nil);
  Result := TPGFGlyph.Create;
  var P := GlyphBitPos(Index);
  if P >= Int64(Length(FData)) * 8 then
    Exit;
  var G := Result;
  G.DataSize := Integer(Bits(P, 14));
  G.W := Integer(Bits(P + 14, 7));
  G.H := Integer(Bits(P + 21, 7));
  G.Left := SBits(P + 28, 7);
  G.Top := SBits(P + 35, 7);
  var Flags := Integer(Bits(P + 42, 6));
  var Q := P + 48 + 7;
  G.ShadowId := Integer(Bits(Q, 9));
  Inc(Q, 9);
  for var K := 0 to 3 do
  begin
    var M: TPGFMetric;
    if (Flags and (4 shl K)) <> 0 then
    begin
      var Idx := Integer(Bits(Q, 8));
      Inc(Q, 8);
      if Idx < Length(FTables[K]) then
        M := FTables[K][Idx]
      else
        M := Default(TPGFMetric);
    end
    else
    begin
      M.X := SBits(Q, 32);
      M.Y := SBits(Q + 32, 32);
      Inc(Q, 64);
    end;
    case K of
      0: G.Dim := M;
      1: G.BearingX := M;
      2: G.BearingY := M;
      3: G.Advance := M;
    end;
  end;
  G.ShadowFlags := $40 or Max(G.W, G.H);
  DecodeBitmap(G, Q, Flags and 3);
end;

function TPGFFile.DecodeShadow(Index: Integer): TPGFGlyph;
begin
  var G := Glyph(Index);
  if G = nil then
    Exit(nil);
  Result := TPGFGlyph.Create;
  if G.ShadowId >= Length(FShadowMap) then
    Exit;
  var Owner := Lookup(FShadowMap[G.ShadowId]);
  if Owner < 0 then
    Exit;
  var O := Glyph(Owner);
  if O = nil then
    Exit;
  var P := GlyphBitPos(Owner) + Int64(O.DataSize) * 8;
  if P >= Int64(Length(FData)) * 8 then
    Exit;
  var S := Result;
  S.DataSize := Integer(Bits(P, 14));
  S.W := Integer(Bits(P + 14, 7));
  S.H := Integer(Bits(P + 21, 7));
  S.Left := SBits(P + 28, 7);
  S.Top := SBits(P + 35, 7);
  DecodeBitmap(S, P + 48, Integer(Bits(P + 42, 6)) and 3);
end;
