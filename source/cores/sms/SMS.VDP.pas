unit SMS.VDP;

interface

uses
  System.Math, System.SysUtils, System.Classes, System.UITypes, Core.Snapshots,
  SG1000.VDP;

type
  TSMSPixelRow = array[0..7] of Byte;

  TSMSVDP = class(TSGVDP)
  private
    FExtra: array[0..7] of Byte;
    FCRAM: array[0..31] of Byte;
    FCode, FLineCounter, FYScroll: Byte;
    FLineIRQ, FOriginal, FGameGear: Boolean;
    FGGCRAM: array[0..63] of Byte;
    FCRAMLatch: Byte;
    FPaletteColors: array[0..31] of TAlphaColor;
    FTileRows: array[0..4095] of TSMSPixelRow;
    FTileDirty: array[0..4095] of Boolean;
    FRasterY, FRenderedX: Integer;
    procedure RenderLineContent(Y: Integer);
    procedure UpdatePalette(Index: Integer);
    procedure RebuildPalette;
    function DecodeRow(Tile, Row: Integer; Sprite: Boolean): TSMSPixelRow;
    function Reg(Index: Integer): Byte;
    function Palette(Index: Integer): TAlphaColor; inline;
  protected
    function Color(Index: Integer): TAlphaColor; override;
  public
    constructor Create(OriginalVDP: Boolean = False; GameGear: Boolean = False);
    procedure Reset; override;
    function ReadStatus: Byte; override;
    procedure WriteData(Value: Byte); override;
    procedure WriteControl(Value: Byte); override;
    function Interrupt: Boolean; override;
    function InterruptAt(Line, LineCycles: Integer): Boolean;
    procedure RenderLine(Y: Integer); override;
    procedure FlushPalette(Line, LineCycles: Integer);
    procedure EndLine(Line, TotalLines: Integer); override;
    function ScreenHeight: Integer; override;
    function ViewportTop: Integer;
    function VCounter(Line: Integer; PAL: Boolean): Byte;
    function HCounter(Cycles: Integer): Byte;
    procedure SerializeState(State: TStateArchive); override;
  end;

implementation

var
  // Each byte holds one pixel's bit. Shifting combines the four bitplanes
  // without testing every source bit on each dirty row (also used by SMS1).
  PlanePixels: array[0..255] of UInt64;

procedure InitializePlanePixels;
begin
  for var Bits := 0 to 255 do
  begin
    var Pixels: TSMSPixelRow;
    for var Column := 0 to 7 do
      Pixels[Column] := (Bits shr (7 - Column)) and 1;
    Move(Pixels, PlanePixels[Bits], SizeOf(Pixels));
  end;
end;

constructor TSMSVDP.Create(OriginalVDP, GameGear: Boolean);
begin
  inherited Create;
  FOriginal := OriginalVDP;
  FGameGear := GameGear;
end;

procedure TSMSVDP.Reset;
begin
  inherited;
  FillChar(FExtra, SizeOf(FExtra), 0);
  FillChar(FCRAM, SizeOf(FCRAM), 0);
  FCode := 0;
  FillChar(FGGCRAM, SizeOf(FGGCRAM), 0);
  FCRAMLatch := 0;
  FLineCounter := 0;
  FYScroll := 0;
  FLineIRQ := False;
  FRasterY := -1;
  FRenderedX := 0;
  FillChar(FTileDirty, SizeOf(FTileDirty), 1);
  RebuildPalette;
end;

function TSMSVDP.Reg(Index: Integer): Byte;
begin
  if Index < 8 then
    Result := FRegisters[Index]
  else
    Result := FExtra[Index - 8];
end;

function TSMSVDP.ScreenHeight: Integer;
begin
  Result := 192;
  if FOriginal or (FRegisters[0] and 6 <> 6) then
    Exit;

  if FRegisters[1] and $18 = $10 then
    Result := 224;
  if FRegisters[1] and $18 = 8 then
    Result := 240;
end;

function TSMSVDP.ViewportTop: Integer;
begin
  Result := (ScreenHeight - 144) div 2;
end;

function TSMSVDP.Color(Index: Integer): TAlphaColor;
const
  Legacy: array[0..15] of Byte = ($00, $00, $08, $0C, $10, $30, $01, $3C, $02, $03, $05, $0F, $04, $33, $15, $3F);
begin
  Index := Index and 15;
  if Index = 0 then
    Index := FRegisters[7] and 15;
  if FGameGear then
    Exit(Palette(Index));

  var Value := Legacy[Index];
  Result := $FF000000 or (Cardinal((Value and 3) * 85) shl 16) or
    (Cardinal(((Value shr 2) and 3) * 85) shl 8) or Cardinal(((Value shr 4) and 3) * 85);
end;

procedure TSMSVDP.UpdatePalette(Index: Integer);
begin
  if FGameGear then
  begin
    var Offset := (Index and 31) * 2;
    var RGB := Integer(FGGCRAM[Offset]) or (Integer(FGGCRAM[Offset + 1]) shl 8);
    FPaletteColors[Index] := $FF000000 or (Cardinal((RGB and 15) * 17) shl 16) or
      (Cardinal(((RGB shr 4) and 15) * 17) shl 8) or Cardinal(((RGB shr 8) and 15) * 17);
    Exit;
  end;

  var Value := FCRAM[Index and 31];
  FPaletteColors[Index] := $FF000000 or (Cardinal((Value and 3) * 85) shl 16) or
    (Cardinal(((Value shr 2) and 3) * 85) shl 8) or Cardinal(((Value shr 4) and 3) * 85);
end;

procedure TSMSVDP.RebuildPalette;
begin
  for var i := 0 to 31 do
    UpdatePalette(i);
end;

function TSMSVDP.Palette(Index: Integer): TAlphaColor;
begin
  Result := FPaletteColors[Index and 31];
end;

procedure TSMSVDP.WriteData(Value: Byte);
begin
  if FCode = 3 then
  begin
    FControlPending := False;
    if FGameGear then
    begin
      if FAddress and 1 = 0 then
        FCRAMLatch := Value
      else
      begin
        FGGCRAM[(FAddress and 63) - 1] := FCRAMLatch;
        FGGCRAM[FAddress and 63] := Value and 15;
        UpdatePalette((FAddress and 63) shr 1);
      end;
    end
    else
    begin
      FCRAM[FAddress and 31] := Value and $3F;
      UpdatePalette(FAddress and 31);
    end;
    FReadBuffer := Value;
    FAddress := (FAddress + 1) and $3FFF;
  end
  else
  begin
    FTileDirty[FAddress shr 2] := True;
    inherited;
  end;
end;

procedure TSMSVDP.WriteControl(Value: Byte);
begin
  if not FControlPending then
  begin
    FAddress := (FAddress and $3F00) or Value;
    FControlPending := True;
    Exit;
  end;

  FCode := Value shr 6;
  FControlPending := False;
  FAddress := ((Integer(Value) shl 8) or (FAddress and $FF)) and $3FFF;
  if FCode = 2 then
  begin
    if Value and 15 < 8 then
      FRegisters[Value and 7] := FAddress and $FF
    else
      FExtra[(Value and 15) - 8] := FAddress and $FF;
    var Height := ScreenHeight;
    // A mode change can crop away a line whose palette prefix was flushed.
    // Do not retain a prefix pointing beyond the resized frame buffer.
    if FRasterY >= Height then
    begin
      FRasterY := -1;
      FRenderedX := 0;
    end;
    if Length(FPixels) <> Height * 256 then
      SetLength(FPixels, Height * 256);
  end
  else if FCode = 0 then
  begin
    FReadBuffer := VRAM(FAddress);
    FAddress := (FAddress + 1) and $3FFF;
  end;
end;

function TSMSVDP.ReadStatus: Byte;
begin
  // Mode 4 has no TMS9918 fifth-sprite index in bits 0..4. These unused
  // bus bits are modeled low; retaining the inherited $1F can trap software
  // probing the VDP in a DMA-busy loop before it switches back to Mode 4.
  Result := FStatus;
  if FRegisters[0] and 4 <> 0 then
    Result := Result and $E0;
  FStatus := $1F;
  FLineIRQ := False;
  FControlPending := False;
end;

function TSMSVDP.Interrupt: Boolean;
begin
  Result := inherited Interrupt or (FLineIRQ and (FRegisters[0] and $10 <> 0));
end;

function TSMSVDP.InterruptAt(Line, LineCycles: Integer): Boolean;
begin
  // The status flag becomes visible before the CPU accepts the raster IRQ.
  // Keep that short window in the instruction-granular scheduler. Otherwise
  // a polling IN immediately loses VBlank to the interrupt handler (Chess).
  // Phase is derived from the raster; no additional snapshot state is needed.
  var FrameIRQ := inherited Interrupt;
  if (Line = ScreenHeight + 2) and (LineCycles < 7) then
    FrameIRQ := False;
  Result := FrameIRQ or (FLineIRQ and (FRegisters[0] and $10 <> 0));
end;

procedure TSMSVDP.EndLine(Line, TotalLines: Integer);
begin
  if Line <= ScreenHeight then
  begin
    if FLineCounter = 0 then
    begin
      FLineCounter := Reg(10);
      FLineIRQ := True;
    end
    else
      Dec(FLineCounter);
  end
  else
    FLineCounter := Reg(10);
  if Line = TotalLines - 1 then
    FYScroll := Reg(9);
end;

function TSMSVDP.DecodeRow(Tile, Row: Integer; Sprite: Boolean): TSMSPixelRow;
begin
  var Index := Tile * 8 + Row;

  // SMS1's register masks can alias different planes of a row; decode those
  // on demand. SMS2/GG rows map directly to four consecutive VRAM bytes.
  if not FOriginal and not FTileDirty[Index] then
    Exit(FTileRows[Index]);

  var Address := Index * 4;
  var PackedPixels: UInt64;
  if not FOriginal then
    PackedPixels := PlanePixels[FVRAM[Address]] or
      (PlanePixels[FVRAM[Address + 1]] shl 1) or
      (PlanePixels[FVRAM[Address + 2]] shl 2) or
      (PlanePixels[FVRAM[Address + 3]] shl 3)
  else
  begin
    PackedPixels := 0;
    for var Plane := 0 to 3 do
    begin
      var PlaneAddress := Address + Plane;
      if Sprite then
        PlaneAddress := PlaneAddress and ((Integer(FRegisters[6] and 3) shl 11) or $27FF)
      else if Plane < 2 then
        PlaneAddress := PlaneAddress and ((Integer(FRegisters[3]) shl 6) or $3F)
      else
        PlaneAddress := PlaneAddress and ((Integer(FRegisters[4] and 7) shl 11) or $7FF);
      PackedPixels := PackedPixels or (PlanePixels[FVRAM[PlaneAddress]] shl Plane);
    end;
  end;
  Move(PackedPixels, Result, SizeOf(Result));
  if not FOriginal then
  begin
    FTileRows[Index] := Result;
    FTileDirty[Index] := False;
  end;
end;

procedure TSMSVDP.FlushPalette(Line, LineCycles: Integer);
begin
  if (FCode <> 3) or (FRegisters[0] and 4 = 0) or
    (Line < 0) or (Line >= ScreenHeight) then
    Exit;
  var X := Min(256, LineCycles * 3 div 2);
  if FRasterY <> Line then
  begin
    FRasterY := Line;
    FRenderedX := 0;
  end;
  if X <= FRenderedX then
    Exit;
  // Preserve the pixels preceding this CRAM write with the old palette.
  // The rest will be rendered again at the next write or scanline boundary.
  // Speculative future sprite pixels must not raise collision/overflow early.
  var Status := FStatus;
  RenderLine(Line);
  FStatus := Status;
  FRasterY := Line;
  FRenderedX := X;
end;

procedure TSMSVDP.RenderLine(Y: Integer);
begin
  var Prefix := 0;
  if Y = FRasterY then
    Prefix := FRenderedX;
  var Saved: array[0..255] of TAlphaColor;
  if Prefix > 0 then
    Move(FPixels[Y * 256], Saved[0], Prefix * SizeOf(TAlphaColor));
  RenderLineContent(Y);
  if Prefix > 0 then
    Move(Saved[0], FPixels[Y * 256], Prefix * SizeOf(TAlphaColor));
  if Y = FRasterY then
  begin
    FRasterY := -1;
    FRenderedX := 0;
  end;
end;

procedure TSMSVDP.RenderLineContent(Y: Integer);
begin
  if FRegisters[0] and 4 = 0 then
  begin
    inherited RenderLine(Y);
    Exit;
  end;

  var Height := ScreenHeight;
  if (Y < 0) or (Y >= Height) then
    Exit;

  var Priority, Drawn: array[0..255] of Boolean;
  FillChar(Priority, SizeOf(Priority), 0);
  FillChar(Drawn, SizeOf(Drawn), 0);
  var Backdrop := Palette(16 + (FRegisters[7] and 15));
  // The enabled background covers the whole scanline, including color zero.
  // Fill the backdrop only when that pass will not run.
  if not FShowBackground or (FRegisters[1] and $40 = 0) then
    for var X := 0 to 255 do
      FPixels[Y * 256 + X] := Backdrop;
  if FRegisters[1] and $40 = 0 then
    Exit;

  var Base := (FRegisters[2] and $0E) * $400;
  var Wrap := 224;
  if Height > 192 then
  begin
    Base := (FRegisters[2] and $0C) * $400 + $700;
    Wrap := 256;
  end;
  var ScrollX := Integer(Reg(8));
  if (FRegisters[0] and $40 <> 0) and (Y < 16) then
    ScrollX := 0;
  if FShowBackground then
  begin
    var ScrolledY := (Y + FYScroll) mod Wrap;
    var X := 0;
    while X < 256 do
    begin
      var SX := (X - ScrollX) and 255;
      var SY := ScrolledY;
      if (FRegisters[0] and $80 <> 0) and (X >= 192) then
        SY := Y;
      var Address := Base + ((SY div 8) * 32 + (SX div 8)) * 2;
      if FOriginal and (FRegisters[2] and 1 = 0) then
        Address := Address and $3BFF;
      var Attr := Integer(VRAM(Address)) or (Integer(VRAM(Address + 1)) shl 8);
      var Row := SY and 7;
      var Column := SX and 7;
      if Attr and $400 <> 0 then
        Row := 7 - Row;
      var Pixels := DecodeRow(Attr and $1FF, Row, False);
      var Span := Min(8 - Column, 256 - X);
      if (X < 192) and (X + Span > 192) then
        Span := 192 - X;
      var PaletteBase := (Attr and $800) shr 7;
      var TilePriority := Attr and $1000 <> 0;
      for var Offset := 0 to Span - 1 do
      begin
        var Source := Column + Offset;
        if Attr and $200 <> 0 then
          Source := 7 - Source;
        var Pixel := Pixels[Source];
        Priority[X + Offset] := TilePriority and (Pixel <> 0);
        FPixels[Y * 256 + X + Offset] := FPaletteColors[Pixel + PaletteBase];
      end;
      Inc(X, Span);
    end;
  end;
  var Table := (FRegisters[5] and $7E) * 128;
  var Tall := 8;
  var Zoom := 1;
  if FRegisters[1] and 2 <> 0 then
    Tall := 16;
  if FRegisters[1] and 1 <> 0 then
    Zoom := 2;
  var Count := 0;
  var Visible: array[0..63] of Integer;
  for var i := 0 to 63 do
  begin
    var SY := Integer(VRAM(Table + i));
    if (Height = 192) and (SY = $D0) then
      Break;

    if SY >= $F0 then
      Dec(SY, 256);
    Inc(SY);
    if (Y < SY) or (Y >= SY + Tall * Zoom) then
      Continue;

    if Count = 8 then
    begin
      FStatus := FStatus or $40;
      if not FRemoveSpriteLimit then
        Break;
    end;

    Visible[Count] := i;
    Inc(Count);
  end;
  for var V := 0 to Count - 1 do
  begin
    var i := Visible[V];
    var SY := Integer(VRAM(Table + i));
    if SY >= $F0 then
      Dec(SY, 256);
    Inc(SY);
    var AttrAddress := Table + $80 + i * 2;
    if FOriginal and (FRegisters[5] and 1 = 0) then
      AttrAddress := AttrAddress and $3F7F;
    var SX := Integer(VRAM(AttrAddress));
    if FRegisters[0] and 8 <> 0 then
      Dec(SX, 8);
    var Tile := Integer(VRAM(AttrAddress + 1)) or ((FRegisters[6] and 4) shl 6);
    if Tall = 16 then
      Tile := Tile and $1FE;
    var Row := (Y - SY) div Zoom;
    Inc(Tile, Row div 8);
    Row := Row and 7;
    var XZoom := Zoom;
    if FOriginal and (V >= Min(Count, 8) - 4) and (V < 8) then
      XZoom := 1;
    var Pixels := DecodeRow(Tile, Row, True);
    for var Column := 0 to 7 do
    begin
      var Pixel := Pixels[Column];
      if Pixel = 0 then
        Continue;

      for var Z := 0 to XZoom - 1 do
      begin
        var X := SX + Column * XZoom + Z;
        if (X < 0) or (X >= 256) then
          Continue;

        if Drawn[X] and (V < 8) then
          FStatus := FStatus or $20
        else if FShowSprites and not Drawn[X] and not Priority[X] then
          FPixels[Y * 256 + X] := Palette(16 + Pixel);
        Drawn[X] := True;
      end;
    end;
  end;
  if FRegisters[0] and $20 <> 0 then
    for var X := 0 to 7 do
      FPixels[Y * 256 + X] := Backdrop;
end;

function TSMSVDP.VCounter(Line: Integer; PAL: Boolean): Byte;
begin
  var Height := ScreenHeight;
  if PAL then
  begin
    if (Height = 192) and (Line > 242) then
      Dec(Line, 57);
    if (Height = 224) and (Line > 258) then
      Dec(Line, 57);
    if (Height = 240) and (Line > 266) then
      Dec(Line, 57);
  end
  else
  begin
    if (Height = 192) and (Line > 218) then
      Dec(Line, 6);
    if (Height = 224) and (Line > 234) then
      Dec(Line, 6);
  end;
  Result := Line and $FF;
end;

function TSMSVDP.HCounter(Cycles: Integer): Byte;
begin
  var Value := (Cycles * 3 div 4) mod 171;
  if Value > $93 then
    Inc(Value, $55);
  Result := Value;
end;

procedure TSMSVDP.SerializeState(State: TStateArchive);
begin
  if State.Loading then
    SetLength(FPixels, ScreenHeight * 256);
  inherited;
  if FGameGear then
  begin
    State.Field(FGGCRAM, SizeOf(FGGCRAM));
    State.Field(FCRAMLatch, SizeOf(FCRAMLatch));
  end;
  State.Field(FExtra, SizeOf(FExtra));
  State.Field(FCRAM, SizeOf(FCRAM));
  State.Field(FCode, SizeOf(FCode));
  State.Field(FLineCounter, SizeOf(FLineCounter));
  State.Field(FYScroll, SizeOf(FYScroll));
  State.Field(FLineIRQ, SizeOf(FLineIRQ));
  // Already flushed pixels are in the serialized frame buffer. Preserve the
  // prefix boundary too, so a mid-scanline load keeps the palette transition.
  State.Field(FRasterY, SizeOf(FRasterY));
  State.Field(FRenderedX, SizeOf(FRenderedX));
  if State.Loading and ((FRasterY < -1) or (FRasterY >= ScreenHeight) or
    (FRenderedX < 0) or (FRenderedX > 256) or
    ((FRasterY = -1) and (FRenderedX <> 0))) then
    raise EReadError.Create('Invalid SMS raster palette prefix');
  if State.Loading then
  begin
    RebuildPalette;
    FillChar(FTileDirty, SizeOf(FTileDirty), 1);
  end;
end;

initialization
  InitializePlanePixels;

end.
