// The built-in stand-ins for flash0's fonts: ASCII, Latin-1 and fullwidth Latin drawn from
// the Hershey strokes at the size and weight of the font they replace,
// antialiased to the 4-bit levels PGF glyphs have.

{$I PSP.Font.Hershey.inc}

type
  THSegment = record
    X0, Y0, X1, Y1: Single;
  end;

procedure HAdd(var Segments: TArray<THSegment>; const Points: array of Single);
begin
  for var I := 0 to Length(Points) div 2 - 2 do
  begin
    var S: THSegment;
    S.X0 := Points[I * 2];
    S.Y0 := Points[I * 2 + 1];
    S.X1 := Points[I * 2 + 2];
    S.Y1 := Points[I * 2 + 3];
    Segments := Segments + [S];
  end;
end;

// The strokes of an ASCII character in Hershey units (y up from the
// baseline); DotlessI drops the dot of i and j.
function HGlyph(C: Char; DotlessI: Boolean; out Width: Integer): TArray<THSegment>;
begin
  Result := nil;
  Width := 16;
  if (Ord(C) < 33) or (Ord(C) > 126) then
    Exit;
  var Data := HersheyStrokes[Ord(C)];
  Width := Ord(Data[1]) - Ord('R');
  var HaveLast := False;
  var LX := 0;
  var LY := 0;
  var I := 2;
  while I <= Length(Data) do
  begin
    if Data[I] = ' ' then
    begin
      HaveLast := False;
      Inc(I);
      Continue;
    end;
    var X := Ord(Data[I]) - Ord('R');
    var Y := Ord(Data[I + 1]) - Ord('R');
    Inc(I, 2);
    if HaveLast and not (DotlessI and (LY > 15) and (Y > 15)) then
      HAdd(Result, [LX, LY, X, Y]);
    LX := X;
    LY := Y;
    HaveLast := True;
  end;
end;

function HMarks(Mark: Char; CX, Top: Single): TArray<THSegment>;
begin
  Result := nil;
  case Mark of
    '`': HAdd(Result, [CX - 2, Top + 4, CX + 1, Top + 1]);
    '/': HAdd(Result, [CX + 2, Top + 4, CX - 1, Top + 1]);
    '^': HAdd(Result, [CX - 3, Top + 1, CX, Top + 4, CX + 3, Top + 1]);
    '~': HAdd(Result, [CX - 4, Top + 2, CX - 2, Top + 4, CX + 2, Top + 2, CX + 4, Top + 4]);
    ':':
      begin
        HAdd(Result, [CX - 3, Top + 2, CX - 3, Top + 3]);
        HAdd(Result, [CX + 3, Top + 2, CX + 3, Top + 3]);
      end;
    'o': HAdd(Result, [CX, Top + 1.5, CX + 1.5, Top + 2.5, CX + 1.5, Top + 3.5, CX, Top + 4.5,
      CX - 1.5, Top + 3.5, CX - 1.5, Top + 2.5, CX, Top + 1.5]);
    ',': HAdd(Result, [CX, 0, CX, -2, CX + 2, -3, CX - 1, -5]);
    '|': HAdd(Result, [CX - 6, -1, CX + 6, Top + 1]);
    'v': HAdd(Result, [CX, Top + 3, CX, -3]);
    '.': HAdd(Result, [CX, 9, CX, 10]);
  end;
end;

// Characters 20h..7Eh and A0h..FFh.
function HCharacter(Code: Integer; out Width: Integer): TArray<THSegment>;
begin
  Result := nil;
  Width := 16;
  if Code < $A0 then
  begin
    if Code > $20 then
      Result := HGlyph(Char(Code), False, Width);
    Exit;
  end;
  var Base := HersheyLatinBases[Code - $A0 + 1];
  var Mark := HersheyLatinMarks[Code - $A0 + 1];
  if Base <> ' ' then
    Result := HGlyph(Base, CharInSet(Base, ['i', 'j']) and (Mark <> '-'), Width);
  if Mark = '!' then
    // Inverted punctuation hangs below the baseline.
    for var K := 0 to High(Result) do
    begin
      Result[K].X0 := Width - Result[K].X0;
      Result[K].X1 := Width - Result[K].X1;
      Result[K].Y0 := 14 - Result[K].Y0;
      Result[K].Y1 := 14 - Result[K].Y1;
    end
  else if Mark <> '-' then
  begin
    var Top: Single := 14;
    if CharInSet(Base, ['A'..'Z']) then
      Top := 21
    else if Base = ' ' then
      Top := 16;
    Result := Result + HMarks(Mark, Width / 2, Top);
  end;
end;

{ TPGFBuiltin }

const
  BuiltinSamples = 4;

function BuiltinIndex(Code: Integer): Integer;
begin
  case Code of
    $20..$7E: Result := Code - $20;
    $A0..$FF: Result := 95 + Code - $A0;
    $FF01..$FF5E: Result := 191 + Code - $FF01;
    $3000: Result := 285;
  else
    Result := PGFMissing;
  end;
end;

function BuiltinRasterize(const Segments: TArray<THSegment>; Scale, XScale, Radius, Shear: Single): TPGFGlyph; forward;
function BuiltinShadow(G: TPGFGlyph): TPGFGlyph; forward;

constructor TPGFBuiltin.Create(Points: Single; Bold, Italic: Boolean);
begin
  inherited Create;
  var EmPx: Single := Points * 128 / 72;
  // Hershey capitals stand 21 units tall.
  var Scale := EmPx / 28;
  var XScale: Single := 0.9;
  var Radius: Single := 0.72 * EmPx / 18;
  if Bold then
    Radius := Radius * 1.6;
  if Radius < 0.55 then
    Radius := 0.55;
  var Shear: Single := 0;
  if Italic then
    Shear := 0.2;
  HSize := Round(Points * 64);
  VSize := HSize;
  HRes := 128 * 64;
  VRes := HRes;
  FirstCode := $20;
  LastCode := $FF5E;
  GlyphCount := 286;
  MaxAdvanceV := Round(EmPx * 64);
  MinCenterX := 0;
  MaxDescender := 0;
  for var Index := 0 to GlyphCount - 1 do
  begin
    var Code := Index + $20;
    if Index >= 285 then
      Code := $20
    else if Index >= 191 then
      Code := $21 + Index - 191
    else if Index >= 95 then
      Code := Index - 95 + $A0;
    var Width: Integer;
    var Segments := HCharacter(Code, Width);
    var G := BuiltinRasterize(Segments, Scale, XScale, Radius, Shear);
    G.Advance.X := Round(Width * Scale * XScale * 64);
    if Index >= 191 then
    begin
      G.Left := G.Left + Round((EmPx - Width * Scale * XScale) / 2);
      G.Advance.X := MaxAdvanceV;
    end;
    G.Advance.Y := MaxAdvanceV;
    G.Dim.X := G.W * 64;
    G.Dim.Y := G.H * 64;
    G.BearingX.X := G.Left * 64;
    G.BearingX.Y := -(G.W * 32);
    G.BearingY.X := G.Top * 64;
    G.BearingY.Y := 0;
    G.ShadowFlags := $40 or Max(G.W, G.H);
    G.ShadowId := Index;
    G.DataSize := (G.W * G.H + 1) div 2 + 12;
    FGlyphs.Add(Index, G);
    FShadows.Add(Index, BuiltinShadow(G));
    MaxSizeH := Max(MaxSizeH, G.Dim.X);
    MaxSizeV := Max(MaxSizeV, G.Dim.Y);
    MaxAscender := Max(MaxAscender, G.Top * 64);
    MaxDescender := Min(MaxDescender, (G.Top - G.H) * 64);
    MaxLeftX := Max(MaxLeftX, G.Left * 64);
    MinCenterX := Min(MinCenterX, -(G.W * 32));
    MaxAdvanceH := Max(MaxAdvanceH, G.Advance.X);
    MaxGlyphWidth := Max(MaxGlyphWidth, G.W);
    MaxGlyphHeight := Max(MaxGlyphHeight, G.H);
  end;
  MaxBaseY := MaxAscender;
  MaxTopY := 0;
end;

function BuiltinRasterize(const Segments: TArray<THSegment>; Scale, XScale, Radius, Shear: Single): TPGFGlyph;
begin
  Result := TPGFGlyph.Create;
  if Length(Segments) = 0 then
    Exit;
  // Pixel space: x right from the pen, y down from the baseline.
  var S := Copy(Segments);
  var MinX: Single := 1E9;
  var MaxX: Single := -1E9;
  var MinY: Single := 1E9;
  var MaxY: Single := -1E9;
  for var K := 0 to High(S) do
  begin
    var A := S[K];
    S[K].X0 := (A.X0 * XScale + A.Y0 * Shear) * Scale;
    S[K].Y0 := -A.Y0 * Scale;
    S[K].X1 := (A.X1 * XScale + A.Y1 * Shear) * Scale;
    S[K].Y1 := -A.Y1 * Scale;
    MinX := Min(MinX, Min(S[K].X0, S[K].X1));
    MaxX := Max(MaxX, Max(S[K].X0, S[K].X1));
    MinY := Min(MinY, Min(S[K].Y0, S[K].Y1));
    MaxY := Max(MaxY, Max(S[K].Y0, S[K].Y1));
  end;
  var X0 := Floor(MinX - Radius);
  var Y0 := Floor(MinY - Radius);
  var BW := Ceil(MaxX + Radius) - X0;
  var BH := Ceil(MaxY + Radius) - Y0;
  var Cover: TArray<Integer>;
  SetLength(Cover, BW * BH);
  var R2 := Radius * Radius;
  for var J := 0 to BH - 1 do
    for var I := 0 to BW - 1 do
    begin
      var Hits := 0;
      for var SY := 0 to BuiltinSamples - 1 do
        for var SX := 0 to BuiltinSamples - 1 do
        begin
          var PX: Single := X0 + I + (SX + 0.5) / BuiltinSamples;
          var PY: Single := Y0 + J + (SY + 0.5) / BuiltinSamples;
          for var K := 0 to High(S) do
          begin
            var DX := S[K].X1 - S[K].X0;
            var DY := S[K].Y1 - S[K].Y0;
            var Len := DX * DX + DY * DY;
            var T: Single := 0;
            if Len > 0 then
              T := EnsureRange(((PX - S[K].X0) * DX + (PY - S[K].Y0) * DY) / Len, 0, 1);
            var QX := S[K].X0 + T * DX - PX;
            var QY := S[K].Y0 + T * DY - PY;
            if QX * QX + QY * QY <= R2 then
            begin
              Inc(Hits);
              Break;
            end;
          end;
        end;
      Cover[J * BW + I] := (Hits * 15 + (BuiltinSamples * BuiltinSamples) div 2) div (BuiltinSamples * BuiltinSamples);
    end;
  // Crop to the inked pixels.
  var CropL := BW;
  var CropT := BH;
  var CropR := -1;
  var CropB := -1;
  for var J := 0 to BH - 1 do
    for var I := 0 to BW - 1 do
      if Cover[J * BW + I] <> 0 then
      begin
        CropL := Min(CropL, I);
        CropR := Max(CropR, I);
        CropT := Min(CropT, J);
        CropB := Max(CropB, J);
      end;
  if CropR < 0 then
    Exit;
  Result.W := CropR - CropL + 1;
  Result.H := CropB - CropT + 1;
  Result.Left := X0 + CropL;
  Result.Top := -(Y0 + CropT);
  SetLength(Result.Pixels, Result.W * Result.H);
  for var J := 0 to Result.H - 1 do
    for var I := 0 to Result.W - 1 do
      Result.Pixels[J * Result.W + I] := Cover[(CropT + J) * BW + CropL + I];
end;

function BuiltinShadow(G: TPGFGlyph): TPGFGlyph;
begin
  // A soft halo one pixel wider all round.
  Result := TPGFGlyph.Create;
  if G.W * G.H = 0 then
    Exit;
  Result.W := G.W + 2;
  Result.H := G.H + 2;
  Result.Left := G.Left - 1;
  Result.Top := G.Top + 1;
  SetLength(Result.Pixels, Result.W * Result.H);
  for var Y := 0 to Result.H - 1 do
    for var X := 0 to Result.W - 1 do
    begin
      var Sum := 0;
      for var DY := -1 to 1 do
        for var DX := -1 to 1 do
          Inc(Sum, G.Pixel(X - 1 + DX, Y - 1 + DY));
      Result.Pixels[Y * Result.W + X] := Min(15, (Sum + 2) div 3);
    end;
  Result.DataSize := (Result.W * Result.H + 1) div 2 + 6;
end;

function TPGFBuiltin.Lookup(Code: Integer): Integer;
begin
  if Code < FirstCode then
    Result := PGFBelow
  else
    Result := BuiltinIndex(Code);
end;

function TPGFBuiltin.DecodeGlyph(Index: Integer): TPGFGlyph;
begin
  Result := nil;
end;

function TPGFBuiltin.DecodeShadow(Index: Integer): TPGFGlyph;
begin
  Result := nil;
end;
