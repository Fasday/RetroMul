unit CPS.Video;

interface

uses
  System.SysUtils, System.UITypes, CPS.RomSets, Core.Snapshots;

const
  CPS_WIDTH = 384;
  CPS_HEIGHT = 224;
  CPS_FPS = 8000000.0 / (512 * 262);

type
  TCPSVideo = class
  private
    FGfx: TBytes;
    FGfxOffset, FGfxLength: Integer;
    FStars: TBytes;
    FBoard: TCPSBoard;
    FPalette: array[0..$BFF] of TAlphaColor;
    FObjects: array[0..$1FFF] of Word;
    FBootleg: Boolean;
    FBootNoBrightness: Boolean;
    FBootRAM: TArray<Word>;
    FBootScroll: array[0..2] of Integer;
    FBootSpriteBase, FBootMarker, FBootXOffset, FBootSpriteMode: Integer;
    FCPS2: Boolean;
    FScrollOffset: Integer;
    FAddressMask: Integer;
    FDepth: array[0..CPS_WIDTH * CPS_HEIGHT - 1] of Byte;
    FSpritePriorityMask: array[0..7] of Byte;
    FDrawingPriority: Byte;
    FPixels: TArray<TAlphaColor>;
    FPartial: TArray<TAlphaColor>;
    FRendered: Integer;
    FHigh: array[0..CPS_WIDTH * CPS_HEIGHT - 1] of Boolean;
    FSpriteDrawn: array[0..CPS_WIDTH * CPS_HEIGHT - 1] of Boolean;
    function MapCode(Kind, Code: Integer): Integer;
    function Pen(Code, Size, X, Y, Half: Integer): Byte;
    procedure Layer(LayerNo: Integer; HighOnly: Boolean);
    procedure Objects;
    procedure Stars;
    procedure BootlegFrame;
    function Base(Reg, Align: Integer): Integer;
  public
    FrameNumber: Int64;
    RAM: array[0..$17FFF] of Word;
    A, B: array[0..31] of Word;
    Output: array[0..5] of Word;
    procedure ConfigureGraphicsMapper(const Board: TCPSBoard);
    procedure ConfigureScrollOffset(X: Integer);
    procedure ConfigureAddressMask(Mask: Integer);
    procedure SetStars(const Data: TBytes);
    procedure SelectGraphicsWindow(Offset, Size: Integer);
    procedure ConfigureBootleg(Control: Integer; const Priorities: array of Integer; Scroll1, Scroll2, Scroll3, SpriteBase, Marker: Integer; NoBrightness: Boolean = False; XOffset: Integer = 0; SpriteMode: Integer = 0);
    procedure SetBootlegSpriteBase(Address: Integer);
    procedure BindBootlegSprites(const Data: TArray<Word>);
    constructor Create(const Gfx: TBytes; const Board: TCPSBoard; CPS2: Boolean = False);
    procedure SerializeState(State: TStateArchive);
    procedure Reset;
    procedure PaletteDMA;
    procedure Render;
    procedure BeginRaster;
    procedure RenderTo(LastLine: Integer);
    procedure LatchObjects;
    procedure LatchCPS2(const Data: array of Word);
    property Pixels: TArray<TAlphaColor> read FPixels;
    function ReadB(Offset: Integer): Word;
  end;

implementation

procedure TCPSVideo.ConfigureBootleg(Control: Integer; const Priorities: array of Integer; Scroll1, Scroll2, Scroll3, SpriteBase, Marker: Integer; NoBrightness: Boolean; XOffset, SpriteMode: Integer);
begin
  FBootleg := True;
  FBoard.LayerControl := Control;

  // Generic original-video bootleg flags must not be applied a second time
  // after this board's explicit scroll and sprite wiring has been decoded.
  FBoard.VideoFlags := 0;
  for var i := 0 to 3 do
    FBoard.Priority[i] := Priorities[i];
  FBootScroll[0] := Scroll1;
  FBootScroll[1] := Scroll2;
  FBootScroll[2] := Scroll3;
  FBootSpriteBase := SpriteBase div 2;
  FBootMarker := Marker;
  FBootNoBrightness := NoBrightness;
  FBootXOffset := XOffset;
  FBootSpriteMode := SpriteMode;
end;

procedure TCPSVideo.SetBootlegSpriteBase(Address: Integer);
begin
  FBootSpriteBase := Address div 2;
end;

procedure TCPSVideo.BindBootlegSprites(const Data: TArray<Word>);
begin
  FBootRAM := Data;
end;

procedure TCPSVideo.BootlegFrame;

  function SpriteWord(Index: Integer): Word;
  begin
    if Length(FBootRAM) > 0 then
    begin
      if (Index < 0) or (Index >= Length(FBootRAM)) then
        Exit($FFFF);

      Result := FBootRAM[Index];
    end
    else
    begin
      if (Index < 0) or (Index >= Length(RAM)) then
        Exit($FFFF);

      Result := RAM[Index];
    end;
  end;

begin
  var Source := Base(5, $400);
  for var i := 0 to $BFF do
  begin
    var V := RAM[(Source + i) mod Length(RAM)];
    var Bright := $F + (V shr 12) * 2;
    if FBootNoBrightness then
      Bright := 45;
    FPalette[i] := $FF000000 or Cardinal(((V shr 8) and 15) * 17 * Bright div 45 shl 16) or
      Cardinal(((V shr 4) and 15) * 17 * Bright div 45 shl 8) or Cardinal((V and 15) * 17 * Bright div 45);
  end;
  FillChar(FObjects, SizeOf(FObjects), $FF);
  var SpriteBase := FBootSpriteBase;
  if FBootSpriteMode = 1 then
    if SpriteWord(0) <> 0 then
      SpriteBase := $3000 div 2
    else
      SpriteBase := $1000 div 2;
  var Last := $1FFC;
  for var j := ($1FFC - SpriteBase) div 4 downto 0 do
  begin
    var Index := SpriteBase + j * 4 - 1;
    if SpriteWord(Index) = FBootMarker then
      Last := j * 4;
  end;
  if FBootSpriteMode = 1 then
  begin
    Last := 0;
    for var j := 1 to $FE do
      if SpriteWord(SpriteBase + j * 4 + 3) = FBootMarker then
      begin
        Last := j * 4;
        Break;
      end;
  end;

  var Dest := 0;
  for var j := Last div 4 downto 0 do
  begin
    var Index := SpriteBase + j * 4;
    if (Index < 1) or (Index + 2 >= Length(RAM)) or (Dest + 3 >= Length(FObjects)) then
      Continue;

    if (Length(FBootRAM) > 0) and (Index + 2 >= Length(FBootRAM)) then
      Continue;

    FObjects[Dest] := (Integer(SpriteWord(Index + 2)) + 49 + FBootXOffset) and $1FF;
    FObjects[Dest + 1] := (240 - Integer(SpriteWord(Index - 1))) and $1FF;
    FObjects[Dest + 2] := SpriteWord(Index);
    FObjects[Dest + 3] := SpriteWord(Index + 1) and $7F;
    if FBootSpriteMode = 1 then
      FObjects[Dest + 2] := FObjects[Dest + 2] and $7FFF;
    Inc(Dest, 4);
  end;
end;

procedure TCPSVideo.ConfigureGraphicsMapper(const Board: TCPSBoard);
begin
  FBoard.BankSize := Board.BankSize;
  FBoard.Ranges := Copy(Board.Ranges);
end;

procedure TCPSVideo.ConfigureScrollOffset(X: Integer);
begin
  FScrollOffset := X;
end;

procedure TCPSVideo.ConfigureAddressMask(Mask: Integer);
begin
  if (Mask < 0) or (Int64(Mask) + 1 <> Length(FGfx)) or ((Mask and (Mask + 1)) <> 0) then
    raise EArgumentException.Create('Invalid CPS graphics address mask');

  FAddressMask := Mask;
end;

procedure TCPSVideo.SetStars(const Data: TBytes);
begin
  FStars := Data;
end;

procedure TCPSVideo.SelectGraphicsWindow(Offset, Size: Integer);
begin
  if (Offset < 0) or (Size <= 0) or (Int64(Offset) + Size > Length(FGfx)) then
    raise EArgumentException.Create('Invalid CPS graphics bank');

  FGfxOffset := Offset;
  FGfxLength := Size;
end;

procedure TCPSVideo.Stars;
begin
  if Length(FStars) < $8000 then
    Exit;
  for var Plane := 0 to 1 do
  begin
    if B[FBoard.LayerControl div 2] and FBoard.LayerEnable[3 + Plane] = 0 then
      Continue;

    var Offset := 4;
    if Plane = 1 then
      Offset := 0;
    var Scroll := 14;
    if Plane = 1 then
      Scroll := 12;
    for var i := 0 to $FFF do
    begin
      var C := Integer(FStars[i * 8 + Offset]);
      if C and $1F = $F then
        Continue;

      var X := ((i div 256) * 32 - Integer(A[Scroll]) + (C and $1F)) and $1FF;
      var Y := ((i mod 256) - Integer(A[Scroll + 1])) and $FF;
      var Period := 16;
      if C and $80 <> 0 then
        Period := 15;
      C := ((C and $E0) shr 1) + Integer((FrameNumber div 16) mod Period);
      var PaletteBase := $A00;
      if Plane = 1 then
        PaletteBase := $800;
      X := X - 64;
      Y := Y - 16;
      if (X >= 0) and (X < CPS_WIDTH) and (Y >= 0) and (Y < CPS_HEIGHT) then
        FPixels[Y * CPS_WIDTH + X] := FPalette[PaletteBase + C];
    end;
  end;
end;

constructor TCPSVideo.Create(const Gfx: TBytes; const Board: TCPSBoard; CPS2: Boolean);

  procedure Unshuffle(Start, Count: Integer);
  begin
    if Count = 2 then
      Exit;

    Count := Count div 2;
    Unshuffle(Start, Count);
    Unshuffle(Start + Count * 8, Count);
    for var i := 0 to Count div 2 * 8 - 1 do
    begin
      var V := FGfx[Start + Count div 2 * 8 + i];
      FGfx[Start + Count div 2 * 8 + i] := FGfx[Start + Count * 8 + i];
      FGfx[Start + Count * 8 + i] := V;
    end;
  end;

begin
  inherited Create;
  FGfx := Gfx;
  FCPS2 := CPS2;
  if CPS2 then
  begin
    FGfx := Copy(Gfx);
    if Length(FGfx) mod $200000 <> 0 then
      raise EArgumentException.Create('Invalid CPS2 graphics size');

    for var i := 0 to Length(FGfx) div $200000 - 1 do
      Unshuffle(i * $200000, $200000 div 8);
  end;
  FBoard := Board;
  SetLength(FPixels, CPS_WIDTH * CPS_HEIGHT);
  SetLength(FPartial, CPS_WIDTH * CPS_HEIGHT);
  Reset;
end;

procedure TCPSVideo.Reset;
begin
  FillChar(RAM, SizeOf(RAM), 0);
  FillChar(A, SizeOf(A), 0);
  FillChar(B, SizeOf(B), 0);
  FillChar(FObjects, SizeOf(FObjects), 0);
  FillChar(Output, SizeOf(Output), 0);
  for var i := 0 to High(FPalette) do
    FPalette[i] := $FF000000;
  A[0] := $9200;
  A[1] := $9000;
  A[2] := $9040;
  A[3] := $9080;
  A[4] := $9100;
  A[5] := $90C0;
  B[FBoard.PaletteControl div 2] := $3F;
end;

function TCPSVideo.Base(Reg, Align: Integer): Integer;
begin
  Result := ((Integer(A[Reg]) shl 8) and ($3FFFF and not (Align - 1))) div 2;
end;

procedure TCPSVideo.PaletteDMA;
begin
  var Source := Base(5, $400);
  var Start := Source;
  for var Page := 0 to 5 do
    if B[FBoard.PaletteControl div 2] and (1 shl Page) <> 0 then
    begin
      for var i := 0 to $1FF do
      begin
        var Value: Word := 0;
        if (Source >= 0) and (Source < Length(RAM)) then
          Value := RAM[Source];
        Inc(Source);
        var Bright := $F + (Value shr 12) * 2;
        var R := ((Value shr 8) and 15) * 17 * Bright div 45;
        var G := ((Value shr 4) and 15) * 17 * Bright div 45;
        var Blue := (Value and 15) * 17 * Bright div 45;
        FPalette[Page * $200 + i] := $FF000000 or Cardinal(R shl 16) or Cardinal(G shl 8) or Cardinal(Blue);
      end;
    end
    else if Source <> Start then
      Inc(Source, $200);
end;

function TCPSVideo.ReadB(Offset: Integer): Word;
begin
  if FBootleg then
    Exit(B[Offset div 2]);

  if Offset = FBoard.IDRegister then
    Exit(Word(FBoard.IDValue and $FFFF));

  if (FBoard.Multiply1 >= 0) and (FBoard.Multiply2 >= 0) then
  begin
    var Product := Cardinal(B[FBoard.Multiply1 div 2]) * Cardinal(B[FBoard.Multiply2 div 2]);
    if Offset = FBoard.ProductLow then
      Exit(Word(Product and $FFFF));

    if Offset = FBoard.ProductHigh then
      Exit(Word(Product shr 16));
  end;

  Result := B[Offset div 2];
end;

function TCPSVideo.MapCode(Kind, Code: Integer): Integer;
begin
  var Shift := 0;
  case Kind of
    1, 4:
      Shift := 1;
    8:
      Shift := 3;
  end;
  var Address := Code shl Shift;
  if FCPS2 then
  begin
    if Kind = 1 then
      Exit(Code);

    if Address > $1FFFF then
      Exit(-1);

    Exit(($20000 + Address) shr Shift);
  end;

  for var Range in FBoard.Ranges do
    if (Range.Mask and Kind <> 0) and (Address >= Range.First) and (Address <= Range.Last) then
    begin
      var BankBase := 0;
      for var i := 0 to Range.Bank - 1 do
        Inc(BankBase, FBoard.BankSize[i]);
      Exit((BankBase + (Address and (FBoard.BankSize[Range.Bank] - 1))) shr Shift);
    end;

  // CPS2 uses a flat graphics address space. CPS1 requires a PAL match.
  if Length(FBoard.Ranges) = 0 then
    Exit(Code);

  Result := -1;
end;

function TCPSVideo.Pen(Code, Size, X, Y, Half: Integer): Byte;
begin
  Result := 15;
  if Code < 0 then
    Exit;

  var RowStride := Size div 2;
  var TileStride := Size * Size div 2;
  if Size = 8 then
  begin
    RowStride := 8;
    TileStride := 64;
  end;
  var Offset := Code * TileStride + Y * RowStride + (X div 8) * 4;
  if Size = 8 then
    Inc(Offset, Half * 4);
  if FAddressMask <> 0 then
    Offset := Offset and FAddressMask;
  var Limit := FGfxLength;
  if Limit = 0 then
    Limit := Length(FGfx);
  if (Offset < 0) or (Offset + 3 >= Limit) then
    Exit;

  Result := 0;
  for var P := 0 to 3 do
    Result := Result or Byte(((FGfx[FGfxOffset + Offset + P] shr (7 - (X and 7))) and 1) shl P);
end;

procedure TCPSVideo.Layer(LayerNo: Integer; HighOnly: Boolean);
begin
  var LayerCtrl := B[FBoard.LayerControl div 2];
  if not FBootleg and (LayerCtrl and FBoard.LayerEnable[LayerNo - 1] = 0) then
    Exit;

  if not FBootleg and (LayerNo > 1) and (A[$22 div 2] and (1 shl LayerNo) = 0) then
    Exit;

  var TileSize := 4 shl LayerNo;
  var Mask := TileSize * 64 - 1;
  var Address := Base(LayerNo, $4000);
  for var Y := 0 to CPS_HEIGHT - 1 do
  begin
    var ScreenY := Y + 16;
    var ScrollX := Integer(A[6 + (LayerNo - 1) * 2]) + FScrollOffset;
    if FBootleg then
      Dec(ScrollX, FBootScroll[LayerNo - 1]);
    case FBoard.VideoFlags and 15 of
      1:
        Dec(ScrollX, 10 + LayerNo * 2);
      2:
        Dec(ScrollX, 16);
      3:
        case LayerNo of
          1:
            Dec(ScrollX, 8);
          2:
            Dec(ScrollX, 11);
          3:
            Dec(ScrollX, 12);
        end;
      14:
        if LayerNo = 2 then
          Dec(ScrollX, 64)
        else
          Dec(ScrollX, 70);
      15:
        Dec(ScrollX, 64);
    end;
    if (LayerNo = 2) and (A[$22 div 2] and 1 <> 0) then
    begin
      var RowAddress := Base(4, $800) + ((ScreenY + A[$20 div 2]) and $3FF);
      if RowAddress < Length(RAM) then
        Inc(ScrollX, RAM[RowAddress]);
    end;
    var TY := (ScreenY + Integer(A[7 + (LayerNo - 1) * 2])) and Mask;
    var Row := TY div TileSize;
    for var X := 0 to CPS_WIDTH - 1 do
    begin
      var TX := (X + 64 + ScrollX) and Mask;
      var Col := TX div TileSize;
      var Index: Integer;
      case LayerNo of
        1:
          Index := (Row and $1F) + ((Col and $3F) shl 5) + ((Row and $20) shl 6);
        2:
          Index := (Row and $F) + ((Col and $3F) shl 4) + ((Row and $30) shl 6);
      else
        Index := (Row and 7) + ((Col and $3F) shl 3) + ((Row and $38) shl 6);
      end;
      var Pos := Address + Index * 2;
      if Pos + 1 >= Length(RAM) then
        Continue;

      var Attr := RAM[Pos + 1];
      var TileCode := Integer(RAM[Pos]);
      if LayerNo = 3 then
        TileCode := TileCode and $3FFF;
      var Code := MapCode(1 shl LayerNo, TileCode);
      var PX := TX and (TileSize - 1);
      var PY := TY and (TileSize - 1);
      if Attr and $20 <> 0 then
        PX := TileSize - 1 - PX;
      if Attr and $40 <> 0 then
        PY := TileSize - 1 - PY;
      var Colour := Pen(Code, TileSize, PX, PY, (Index shr 5) and 1);
      if Colour = 15 then
        Continue;

      var Pixel := Y * CPS_WIDTH + X;
      if HighOnly then
      begin
        var PriorityReg := FBoard.Priority[(Attr shr 7) and 3];
        if (PriorityReg >= 0) and (B[PriorityReg div 2] and (1 shl Colour) <> 0) then
          FHigh[Pixel] := True;
      end
      else
      begin
        FPixels[Pixel] := FPalette[LayerNo * $200 + (Attr and $1F) * 16 + Colour];
        if FCPS2 then
          FDepth[Pixel] := FDepth[Pixel] or FDrawingPriority;
      end;
    end;
  end;
end;

procedure TCPSVideo.Objects;
begin
  var Count := $100;
  if FCPS2 then
    Count := $400;
  if FBootleg then
    Count := $800;
  for var j := 0 to Count - 1 do
    if (FObjects[j * 4 + 3] and $FF00 = $FF00) or ((FCPS2 or (FBoard.VideoFlags and 15 = 3)) and (FObjects[j * 4 + 1] >= $8000)) then
    begin
      Count := j;
      Break;
    end;

  // Traverse front to back. Even an opaque sprite hidden by a tile owns its
  // pixel, preventing sprites behind it from leaking through the background.
  FillChar(FSpriteDrawn, SizeOf(FSpriteDrawn), 0);
  for var j := 0 to Count - 1 do
  begin
    var i := j;
    if FCPS2 or (FBoard.VideoFlags and $40 <> 0) then
      i := Count - 1 - j;
    var Attr := FObjects[i * 4 + 3];
    if Attr and $FF00 = $FF00 then
      Break;

    var Code := Integer(FObjects[i * 4 + 2]);
    if FCPS2 then
      Inc(Code, (FObjects[i * 4 + 1] and $6000) shl 3);
    Code := MapCode(1, Code);
    if Code < 0 then
      Continue;

    var NX := ((Attr shr 8) and 15) + 1;
    var NY := (Attr shr 12) + 1;
    for var BY := 0 to NY - 1 do
      for var BX := 0 to NX - 1 do
      begin
        var CX := BX;
        var CY := BY;
        if Attr and $20 <> 0 then
          CX := NX - 1 - BX;
        if Attr and $40 <> 0 then
          CY := NY - 1 - BY;
        var Tile := (Code and not 15) + ((Code + CX) and 15) + CY * 16;
        for var PY := 0 to 15 do
        begin
          var YOff := 0;
          var XOff := 0;
          if FCPS2 then
          begin
            XOff := 64 - Output[4];
            YOff := 16 - Output[5];
          end;
          if FCPS2 and (Attr and $80 <> 0) then
          begin
            Inc(XOff, Output[4]);
            Inc(YOff, Output[5]);
          end;
          var Y := ((FObjects[i * 4 + 1] + BY * 16 + PY + YOff) and $1FF) - 16;
          if (Y < 0) or (Y >= CPS_HEIGHT) then
            Continue;

          for var PX := 0 to 15 do
          begin
            var X := ((FObjects[i * 4] + BX * 16 + PX + XOff) and $1FF) - 64;
            if (X < 0) or (X >= CPS_WIDTH) then
              Continue;

            var DX := PX;
            var DY := PY;
            if Attr and $20 <> 0 then
              DX := 15 - DX;
            if Attr and $40 <> 0 then
              DY := 15 - DY;
            var Colour := Pen(Tile, 16, DX, DY, 0);
            var Pixel := Y * CPS_WIDTH + X;
            if (Colour = 15) or FSpriteDrawn[Pixel] then
              Continue;
            FSpriteDrawn[Pixel] := True;
            var Visible := not FHigh[Pixel];
            if FCPS2 then
              Visible := (FSpritePriorityMask[(FObjects[i * 4] shr 13) and 7] and
                (1 shl FDepth[Y * CPS_WIDTH + X])) = 0;
            if (Colour <> 15) and Visible then
              FPixels[Y * CPS_WIDTH + X] := FPalette[(Attr and 31) * 16 + Colour];
          end;
        end;
      end;
  end;
end;

procedure TCPSVideo.Render;
begin
  if FBootleg then
    BootlegFrame;
  if FBoard.VideoFlags and $80 <> 0 then
    PaletteDMA;
  for var i := 0 to High(FPixels) do
    FPixels[i] := FPalette[$BFF];
  Stars;
  FillChar(FHigh, SizeOf(FHigh), 0);
  FillChar(FDepth, SizeOf(FDepth), 0);
  var Previous := 0;
  if FCPS2 then
  begin
    var Layers: array[0..2] of Integer;
    var Priorities: array[0..2] of Integer;
    var Count := 0;
    for var i := 0 to 3 do
    begin
      var LayerNo := (B[FBoard.LayerControl div 2] shr (6 + i * 2)) and 3;
      if (LayerNo <> 0) and (Count < 3) then
      begin
        Layers[Count] := LayerNo;
        Priorities[Count] := (Output[2] shr (LayerNo * 4)) and 15;
        Inc(Count);
      end;
    end;
    if Count = 3 then
    begin
      var Mask0 := $AA;
      var Mask1 := $CC;
      if Priorities[0] > Priorities[1] then
        Mask0 := Mask0 and $77;
      if Priorities[0] > Priorities[2] then
        Mask0 := Mask0 and $5F;
      if Priorities[1] > Priorities[2] then
        Mask1 := Mask1 and $3F;
      FSpritePriorityMask[0] := $FF;
      for var i := 1 to 7 do
      begin
        var Mask := 0;
        if i <= Priorities[0] then
          Mask := Mask or Mask0;
        if i <= Priorities[1] then
          Mask := Mask or Mask1;
        if i <= Priorities[2] then
          Mask := Mask or $F0;
        if (i <= Priorities[0]) and (i <= Priorities[1]) and (i <= Priorities[2]) then
          Mask := $FE;
        FSpritePriorityMask[i] := Mask;
      end;
      for var i := 0 to 2 do
      begin
        FDrawingPriority := 1 shl i;
        Layer(Layers[i], False);
      end;
      Objects;
    end;
  end;
  if not FCPS2 then
    for var i := 0 to 3 do
    begin
      var LayerNo := (B[FBoard.LayerControl div 2] shr (6 + i * 2)) and 3;
      if LayerNo = 0 then
      begin
        if not FCPS2 then
        begin
          if Previous <> 0 then
            Layer(Previous, True);
          Objects;
        end;
      end
      else
        Layer(LayerNo, False);
      Previous := LayerNo;
    end;
  if A[$22 div 2] and $8000 <> 0 then
    for var i := 0 to Length(FPixels) div 2 - 1 do
    begin
      var Colour := FPixels[i];
      FPixels[i] := FPixels[High(FPixels) - i];
      FPixels[High(FPixels) - i] := Colour;
    end;
end;

procedure TCPSVideo.LatchObjects;
begin
  if (FBoard.VideoFlags and 15) in [1, 2] then
    A[0] := $9100;
  var Source := Base(0, $800);
  FillChar(FObjects, SizeOf(FObjects), 0);
  if Source + $400 <= Length(RAM) then
    Move(RAM[Source], FObjects, $800);
end;

procedure TCPSVideo.BeginRaster;
begin
  FRendered := 0;
end;

procedure TCPSVideo.RenderTo(LastLine: Integer);
begin
  if LastLine >= CPS_HEIGHT then
    LastLine := CPS_HEIGHT - 1;
  if LastLine < FRendered then
    Exit;

  Render;
  Move(FPixels[FRendered * CPS_WIDTH], FPartial[FRendered * CPS_WIDTH],
    (LastLine + 1 - FRendered) * CPS_WIDTH * SizeOf(TAlphaColor));
  FRendered := LastLine + 1;
  Move(FPartial[0], FPixels[0], FRendered * CPS_WIDTH * SizeOf(TAlphaColor));
end;

procedure TCPSVideo.LatchCPS2(const Data: array of Word);
begin
  if Length(Data) <> $1000 then
    raise EArgumentException.Create('Invalid CPS2 object RAM');

  Move(Data[0], FObjects, Length(Data) * SizeOf(Word));
end;

procedure TCPSVideo.SerializeState(State: TStateArchive);
begin
  State.Field(FrameNumber, SizeOf(FrameNumber));
  State.Field(FRendered, SizeOf(FRendered));
  State.Field(FPartial[0], Length(FPartial) * SizeOf(FPartial[0]));
  if (FRendered < 0) or (FRendered > CPS_HEIGHT) then
    raise EArgumentException.Create('Invalid CPS raster state');

  State.Field(RAM, SizeOf(RAM));
  State.Field(A, SizeOf(A));
  State.Field(B, SizeOf(B));
  State.Field(Output, SizeOf(Output));
  State.Field(FPalette, SizeOf(FPalette));
  State.Field(FObjects, SizeOf(FObjects));
  State.Field(FPixels[0], Length(FPixels) * SizeOf(FPixels[0]));
end;

end.

