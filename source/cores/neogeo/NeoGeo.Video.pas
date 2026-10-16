unit NeoGeo.Video;

interface

uses
  System.SysUtils, System.Classes, System.UITypes, System.Math, NeoGeo.Cartridge,
  Core.Snapshots;

const
  NG_WIDTH = 320;
  NG_HEIGHT = 224;
  NG_LINES = 264;
  NG_LINE_CLOCKS = 1536;
  NG_FRAME_CLOCKS = NG_LINES * NG_LINE_CLOCKS;
  NG_FPS = 24000000.0 / NG_FRAME_CLOCKS;

type
  TNeoGeoVideo = class
  private
    FCart: TNeoGeoCartridge;
    FSpriteMask: Integer;
    FAddress, FModulo, FReadBuffer: Word;
    FAnimation, FAnimationDelay, FAnimationSpeed: Byte;
    FAnimationDisabled: Boolean;
    FPartialLine, FPartialCount: Integer;
    procedure RenderWholeLine(Line: Integer);
    function Color(Index: Integer): TAlphaColor;
    function SpriteHalf(Base: Integer): Cardinal;
  public
    VRAM: array[0..$87FF] of Word;
    Palette: array[0..$1FFF] of Word;
    PaletteBank: Integer;
    CartFixed, Shadow: Boolean;
    DisplayEnabled, SpritesEnabled, FixedEnabled: Boolean;
    Pixels: array[0..NG_WIDTH * 256 - 1] of TAlphaColor;
    constructor Create(Cart: TNeoGeoCartridge);
    procedure Reset;
    procedure ClearFrame;
    function StartupVideoReady: Boolean;
    procedure SetAddress(Value: Word);
    procedure WriteData(Value: Word);
    function ReadRegister(Index, Line: Integer): Word;
    procedure Control(Value: Word);
    procedure RenderLine(Line: Integer);
    procedure RenderUntil(Line, Count: Integer);
    procedure NextFrame;
    procedure SerializeState(State: TStateArchive);
    property Modulo: Word read FModulo write FModulo;
  end;

implementation

var
  // Derived solely from the DAC wiring and bitplane layout, never from ROM/RAM.
  ColorTable: array[0..1, 0..65535] of TAlphaColor;
  SpreadBits: array[0..255] of Cardinal;

// Hardware behavior cross-checked with NeoGeo Development Wiki and MAME's
// BSD-3-Clause neogeo_spr.cpp (Bryan McPhail, Ernesto Corvi, Andrew Prime,
// Zsolt Vasvari). All graphics access below uses checked array indices.

constructor TNeoGeoVideo.Create(Cart: TNeoGeoCartridge);
begin
  inherited Create;
  FCart := Cart;
  var Tiles := Length(Cart.SpriteROM) div 128;
  var Size := 1;
  while Size < Tiles do
    Size := Size * 2;
  FSpriteMask := Size - 1;
  Reset;
end;

procedure TNeoGeoVideo.Reset;
begin
  FillChar(VRAM, SizeOf(VRAM), 0);
  FillChar(Palette, SizeOf(Palette), 0);
  FAddress := 0;
  FModulo := 0;
  FReadBuffer := 0;
  FAnimation := 0;
  FAnimationDelay := 0;
  FAnimationSpeed := 0;
  FAnimationDisabled := False;
  PaletteBank := 0;
  CartFixed := FCart.AES;
  DisplayEnabled := True;
  SpritesEnabled := True;
  FixedEnabled := True;
  Shadow := False;
  ClearFrame;
end;

procedure TNeoGeoVideo.ClearFrame;
begin
  FPartialLine := -1;
  FPartialCount := 0;
  for var i := Low(Pixels) to High(Pixels) do
    Pixels[i] := $FF000000;
end;

function TNeoGeoVideo.StartupVideoReady: Boolean;
begin
  // AES startup menus and logos do not use the stock MVS RAM-test map.
  if FCart.AES then
    Exit(True);

  // Cartridge graphics, including the animated BIOS logo, are ready to show.
  if CartFixed then
    Exit(True);

  // The system FIX map is cleared to ASCII spaces before the BIOS displays
  // menus or errors. Reject the AA/55/address patterns left by its RAM tests.
  // Checking every visible entry also rejects a partially cleared test map.
  Result := False;
  for var Column := 0 to 39 do
    for var Row := 2 to 29 do
    begin
      var Code := VRAM[$7000 + Column * 32 + Row] and $FFF;
      if Code >= $100 then
        Exit(False);

      if Code = $20 then
        Result := True;
    end;
end;

procedure TNeoGeoVideo.SetAddress(Value: Word);
begin
  FAddress := Value;
  if (Value and $8000) <> 0 then
    FAddress := Value and $87FF;

  // LSPC fetches data when the address is latched, including after a write.
  FReadBuffer := VRAM[FAddress];
end;

procedure TNeoGeoVideo.WriteData(Value: Word);
begin
  VRAM[FAddress] := Value;
  SetAddress(Word((FAddress and $8000) or ((Integer(FAddress) + FModulo) and $7FFF)));
end;

function TNeoGeoVideo.ReadRegister(Index, Line: Integer): Word;
begin
  case Index and 3 of
    0, 1:
      Result := FReadBuffer;
    2:
      Result := FModulo;
  else
    var Counter := Line + $100;
    if Counter >= $200 then
      Dec(Counter, FCart.FrameLines);
    Result := Word(((Counter shl 7) or (Ord(FCart.PAL) shl 3) or (FAnimation and 7)) and $FFFF);
  end;
end;

procedure TNeoGeoVideo.Control(Value: Word);
begin
  FAnimationSpeed := Value shr 8;
  FAnimationDisabled := (Value and 8) <> 0;
end;

procedure TNeoGeoVideo.NextFrame;
begin
  if FAnimationDelay = 0 then
  begin
    FAnimationDelay := FAnimationSpeed;
    FAnimation := Byte((Integer(FAnimation) + 1) and $FF);
  end
  else
    Dec(FAnimationDelay);
end;

procedure InitializeVideoTables;
const
  // 5-bit RGB DAC: 3900/2200/1000/470/220 ohms. The dark bit adds
  // an 8200-ohm pulldown; screen shadow adds 150 ohms. Values use
  // the same normal-mode scale and nearest rounding as MAME neogeo_v.cpp.
  RGB: array[0..3, 0..31] of Byte = (
    (0, 8, 14, 22, 30, 38, 44, 52, 65, 73, 79, 86, 95, 103, 109, 117,
    138, 146, 152, 160, 169, 176, 182, 190, 203, 211, 217, 225, 233, 241, 247, 255),
    (0, 8, 14, 21, 30, 38, 44, 51, 64, 71, 77, 85, 94, 101, 107, 115,
    136, 144, 150, 158, 166, 174, 180, 188, 200, 208, 214, 221, 230, 238, 244, 251),
    (0, 4, 8, 12, 17, 21, 25, 29, 36, 40, 44, 48, 53, 57, 61, 65,
    77, 81, 85, 89, 94, 98, 102, 106, 113, 117, 121, 125, 130, 134, 138, 142),
    (0, 4, 8, 12, 17, 21, 24, 29, 36, 40, 43, 48, 53, 57, 60, 65,
    76, 81, 84, 88, 93, 98, 101, 105, 112, 116, 120, 124, 129, 133, 137, 141));
begin
  for var Shadow := 0 to 1 do
    for var Value := 0 to 65535 do
    begin
      var Mode := (Value shr 15) + 2 * Shadow;
      var R := RGB[Mode, ((Value shr 14) and 1) or ((Value shr 7) and $1E)];
      var G := RGB[Mode, ((Value shr 13) and 1) or ((Value shr 3) and $1E)];
      var B := RGB[Mode, ((Value shr 12) and 1) or ((Value shl 1) and $1E)];
      ColorTable[Shadow, Value] := $FF000000 or (Cardinal(R) shl 16) or
        (Cardinal(G) shl 8) or Cardinal(B);
    end;
  for var Value := 0 to 255 do
    for var Bit := 0 to 7 do
      SpreadBits[Value] := SpreadBits[Value] or (Cardinal((Value shr Bit) and 1) shl (Bit * 4));
end;

function TNeoGeoVideo.Color(Index: Integer): TAlphaColor;
begin
  Result := ColorTable[Ord(Shadow), Palette[PaletteBank * $1000 + (Index and $FFF)]];
end;

function TNeoGeoVideo.SpriteHalf(Base: Integer): Cardinal;
begin
  Result := 0;
  if Base + 3 >= Length(FCart.SpriteROM) then
    Exit;

  // Decode eight pixels at once. Read live RAM for CD uploads and bootlegs;
  // keeping decoded tiles across scanlines would require write invalidation.
  if FCart.Disc <> nil then
    Result := SpreadBits[FCart.SpriteROM[Base + 1]] or
      (SpreadBits[FCart.SpriteROM[Base]] shl 1) or
      (SpreadBits[FCart.SpriteROM[Base + 3]] shl 2) or
      (SpreadBits[FCart.SpriteROM[Base + 2]] shl 3)
  else
    Result := SpreadBits[FCart.SpriteROM[Base]] or
      (SpreadBits[FCart.SpriteROM[Base + 2]] shl 1) or
      (SpreadBits[FCart.SpriteROM[Base + 1]] shl 2) or
      (SpreadBits[FCart.SpriteROM[Base + 3]] shl 3);
end;

procedure TNeoGeoVideo.RenderWholeLine(Line: Integer);
const
  ZoomX: array[0..15] of Word = ($0080, $0880, $0888, $2888, $288A,
    $2A8A, $2AAA, $AAAA, $AAEA, $BAEA, $BAEB, $BBEB, $BBEF, $FBEF, $FBFF, $FFFF);
  FixOffsets: array[0..3] of Integer = ($10, $18, 0, 8);
begin
  if (Line < 0) or (Line >= FCart.FrameLines) then
    Exit;

  var Top := 16;
  if FCart.AES and FCart.PAL then
    Top := 0;
  var Visible := (Line >= Top) and (Line < Top + FCart.VideoHeight);
  var Row := (Line - Top) * NG_WIDTH;
  if Visible then
  begin
    var Background := Color($FFF);
    if not DisplayEnabled then
      Background := $FF000000;
    for var X := 0 to NG_WIDTH - 1 do
      Pixels[Row + X] := Background;
  end;

  if not DisplayEnabled then
    Exit;

  var X := 0;
  var Y := 0;
  var Rows := 0;
  var ZX := 0;
  var ZY := 0;
  var Active := 0;
  var List := $8600 + (Line and 1) * $80;

  // Neo Pong's background consumes the physical line limit before its UI.
  // Render these releases permissively while keeping the hardware sprite list bounded.
  var Permissive := (FCart.SetName = 'neopong') or (FCart.SetName = 'neopong10');
  if SpritesEnabled then
    for var Sprite := 0 to 380 do
    begin
      var Control := VRAM[$8200 + Sprite];
      var Zoom := VRAM[$8000 + Sprite];
      if (Control and $40) <> 0 then
      begin
        X := (X + ZX + 1) and $1FF;
        ZX := (Zoom shr 8) and 15;
      end
      else
      begin
        Y := $200 - (Control shr 7);
        X := VRAM[$8400 + Sprite] shr 7;
        Rows := Control and $3F;
        ZX := (Zoom shr 8) and 15;
        ZY := Zoom and $FF;
      end;
      var SpriteLine := (Line + $200 - Y) and $1FF;
      if (Rows = 0) or ((Rows < 32) and (SpriteLine >= Rows * 16)) then
        Continue;

      if Active < 96 then
      begin
        VRAM[List + Active] := Sprite;
        Inc(Active);
      end;
      if Visible and ((X < NG_WIDTH) or (X > $1F0)) then
      begin
        var ZoomLine := SpriteLine and $FF;
        var Invert := (SpriteLine and $100) <> 0;
        if Invert then
          ZoomLine := ZoomLine xor $FF;
        if Rows > 32 then
        begin
          ZoomLine := ZoomLine mod ((ZY + 1) * 2);
          if ZoomLine > ZY then
          begin
            ZoomLine := (ZY + 1) * 2 - 1 - ZoomLine;
            Invert := not Invert;
          end;
        end;
        var Encoded := FCart.ZoomROM[ZY * 256 + ZoomLine];
        var Tile := Encoded shr 4;
        var TY := Encoded and 15;
        if Invert then
        begin
          Tile := Tile xor 31;
          TY := TY xor 15;
        end;
        var Offset := Sprite * 64 + Tile * 2;
        var Attr := VRAM[Offset + 1];
        var Code := Integer(VRAM[Offset]) or ((Attr and $F0) shl 12);
        if not FAnimationDisabled then
        begin
          if (Attr and 8) <> 0 then
            Code := (Code and $FFFF8) or (FAnimation and 7)
          else if (Attr and 4) <> 0 then
            Code := (Code and $FFFFC) or (FAnimation and 3);
        end;
        if (Attr and 2) <> 0 then
          TY := TY xor 15;
        var Base := (Code and FSpriteMask) * 128 + TY * 4;
        var LeftHalf := SpriteHalf(Base + 64);
        var RightHalf := SpriteHalf(Base);
        var DX := X;
        for var SX := 0 to 15 do
          if (ZoomX[ZX] and (1 shl (15 - SX))) <> 0 then
          begin
            var TX := SX;
            if (Attr and 1) <> 0 then
              TX := 15 - TX;
            var PackedPixels := LeftHalf;
            if TX >= 8 then
              PackedPixels := RightHalf;
            var Pen := (PackedPixels shr ((TX and 7) * 4)) and 15;
            var ScreenX := DX;
            if X > $1F0 then
              ScreenX := DX - $200;
            if (Pen <> 0) and (ScreenX >= 0) and (ScreenX < NG_WIDTH) then
              Pixels[Row + ScreenX] := Color((Attr shr 8) * 16 + Pen);
            Inc(DX);
          end;
      end;
      if (Active = 96) and not Permissive then
        Break;
    end;

  for var i := Active to 96 do
    VRAM[List + i] := 0;
  if not Visible or not FixedEnabled then
    Exit;

  var FixedData := FCart.FixedBIOS;
  if CartFixed or FCart.AES then
    FixedData := FCart.FixedROM;
  var FixedBank := 0;
  if (CartFixed or FCart.AES) and (Length(FixedData) > $20000) and (FCart.FixedBankType = 1) then
  begin
    var Banks: array[0..33] of Integer;
    var K := 0;
    var BankRow := 0;
    var Bank := 0;
    while BankRow < 32 do
    begin
      if (VRAM[$7500 + K] = $0200) and ((VRAM[$7580 + K] and $FF00) = $FF00) then
      begin
        Bank := VRAM[$7580 + K] and 3;
        Banks[BankRow] := Bank;
        Inc(BankRow);
      end;
      Banks[BankRow] := Bank;
      Inc(BankRow);
      Inc(K, 2);
    end;
    FixedBank := $1000 * (Banks[((Line shr 3) - 2) and 31] xor 3);
  end;

  for var Column := 0 to 39 do
  begin
    var Entry := VRAM[$7000 + Column * 32 + (Line shr 3)];
    var Code := Entry and $FFF;
    Inc(Code, FixedBank);
    if (CartFixed or FCart.AES) and (Length(FixedData) > $20000) and (FCart.FixedBankType = 2) then
      Inc(Code, $1000 * (((VRAM[$7500 + (((Line shr 3) - 1) and 31) +
          32 * (Column div 6)] shr ((5 - (Column mod 6)) * 2)) and 3) xor 3));
    var Base := Code * 32 + (Line and 7);
    for var Pair := 0 to 3 do
    begin
      var Address := Base + FixOffsets[Pair];
      Address := Address mod Length(FixedData);
      var ByteValue := FixedData[Address];
      for var Nibble := 0 to 1 do
      begin
        var Pen := (ByteValue shr (Nibble * 4)) and 15;
        if Pen <> 0 then
          Pixels[Row + Column * 8 + Pair * 2 + Nibble] := Color((Entry shr 12) * 16 + Pen);
      end;
    end;
  end;
end;

procedure TNeoGeoVideo.RenderUntil(Line, Count: Integer);
var
  Prefix: array[0..NG_WIDTH - 1] of TAlphaColor;
begin
  var Top := 16;
  if FCart.AES and FCart.PAL then
    Top := 0;
  if (Line < Top) or (Line >= Top + FCart.VideoHeight) then
    Exit;

  Count := System.Math.EnsureRange(Count, 0, NG_WIDTH);
  if FPartialLine <> Line then
  begin
    FPartialLine := Line;
    FPartialCount := 0;
  end;
  if Count <= FPartialCount then
    Exit;

  var Row := (Line - Top) * NG_WIDTH;
  if FPartialCount > 0 then
    Move(Pixels[Row], Prefix[0], FPartialCount * SizeOf(TAlphaColor));
  RenderWholeLine(Line);
  if FPartialCount > 0 then
    Move(Prefix[0], Pixels[Row], FPartialCount * SizeOf(TAlphaColor));
  FPartialCount := Count;
end;

procedure TNeoGeoVideo.RenderLine(Line: Integer);
begin
  if FPartialLine = Line then
    RenderUntil(Line, NG_WIDTH)
  else
    RenderWholeLine(Line);
  FPartialLine := -1;
  FPartialCount := 0;
end;

procedure TNeoGeoVideo.SerializeState(State: TStateArchive);
begin
  State.Field(VRAM, SizeOf(VRAM));
  State.Field(Palette, SizeOf(Palette));
  State.Field(PaletteBank, SizeOf(PaletteBank));
  State.Field(CartFixed, SizeOf(CartFixed));
  State.Field(Shadow, SizeOf(Shadow));
  State.Field(Pixels, SizeOf(Pixels));
  State.Field(FAddress, SizeOf(FAddress));
  State.Field(FModulo, SizeOf(FModulo));
  State.Field(FReadBuffer, SizeOf(FReadBuffer));
  State.Field(FAnimation, SizeOf(FAnimation));
  State.Field(FAnimationDelay, SizeOf(FAnimationDelay));
  State.Field(FAnimationSpeed, SizeOf(FAnimationSpeed));
  State.Field(FAnimationDisabled, SizeOf(FAnimationDisabled));
  State.Field(FPartialLine, SizeOf(FPartialLine));
  State.Field(FPartialCount, SizeOf(FPartialCount));
  if State.Loading and ((FPartialLine < -1) or (FPartialLine >= FCart.FrameLines) or
    (FPartialCount < 0) or (FPartialCount > NG_WIDTH)) then
    raise EReadError.Create('Invalid Neo Geo raster snapshot');
end;

initialization
  InitializeVideoTables;

end.

