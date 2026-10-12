unit SMS.VDP;

interface

uses
  System.Math, System.SysUtils, System.Classes, System.UITypes, Core.Snapshots,
  SG1000.VDP;

type
  TSMSVDP = class(TSGVDP)
  private
    FExtra: array[0..7] of Byte;
    FCRAM: array[0..31] of Byte;
    FCode, FLineCounter, FYScroll: Byte;
    FLineIRQ, FOriginal: Boolean;
    function Reg(Index: Integer): Byte;
    function Palette(Index: Integer): TAlphaColor;
    function TilePixel(Tile, Row, Column: Integer; Sprite: Boolean): Integer;
  public
    constructor Create(OriginalVDP: Boolean = False);
    procedure Reset; override;
    function ReadStatus: Byte; override;
    procedure WriteData(Value: Byte); override;
    procedure WriteControl(Value: Byte); override;
    function Interrupt: Boolean; override;
    procedure RenderLine(Y: Integer); override;
    procedure EndLine(Line, TotalLines: Integer); override;
    function ScreenHeight: Integer; override;
    function VCounter(Line: Integer; PAL: Boolean): Byte;
    function HCounter(Cycles: Integer): Byte;
    procedure SerializeState(State: TStateArchive); override;
  end;

implementation

constructor TSMSVDP.Create(OriginalVDP: Boolean);
begin
  inherited Create;
  FOriginal := OriginalVDP;
end;

procedure TSMSVDP.Reset;
begin
  inherited;
  FillChar(FExtra, SizeOf(FExtra), 0);
  FillChar(FCRAM, SizeOf(FCRAM), 0);
  FCode := 0;
  FLineCounter := 0;
  FYScroll := 0;
  FLineIRQ := False;
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

function TSMSVDP.Palette(Index: Integer): TAlphaColor;
begin
  var Value := FCRAM[Index and 31];
  Result := $FF000000 or (Cardinal((Value and 3) * 85) shl 16) or
    (Cardinal(((Value shr 2) and 3) * 85) shl 8) or Cardinal(((Value shr 4) and 3) * 85);
end;

procedure TSMSVDP.WriteData(Value: Byte);
begin
  if FCode = 3 then
  begin
    FControlPending := False;
    FCRAM[FAddress and 31] := Value and $3F;
    FReadBuffer := Value;
    FAddress := (FAddress + 1) and $3FFF;
  end
  else
    inherited;
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
  Result := FStatus;
  FStatus := $1F;
  FLineIRQ := False;
  FControlPending := False;
end;

function TSMSVDP.Interrupt: Boolean;
begin
  Result := inherited Interrupt or (FLineIRQ and (FRegisters[0] and $10 <> 0));
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

function TSMSVDP.TilePixel(Tile, Row, Column: Integer; Sprite: Boolean): Integer;
begin
  Result := 0;
  for var Plane := 0 to 3 do
  begin
    var Address := Tile * 32 + Row * 4 + Plane;
    if FOriginal then
      if Sprite then
        Address := Address and ((Integer(FRegisters[6] and 3) shl 11) or $27FF)
      else if Plane < 2 then
        Address := Address and ((Integer(FRegisters[3]) shl 6) or $3F)
      else
        Address := Address and ((Integer(FRegisters[4] and 7) shl 11) or $7FF);
    if VRAM(Address) and ($80 shr Column) <> 0 then
      Result := Result or (1 shl Plane);
  end;
end;

procedure TSMSVDP.RenderLine(Y: Integer);
begin
  if FRegisters[0] and 4 = 0 then
  begin
    inherited;
    Exit;
  end;
  var Height := ScreenHeight;
  if (Y < 0) or (Y >= Height) then
    Exit;
  var Priority, Drawn: array[0..255] of Boolean;
  FillChar(Priority, SizeOf(Priority), 0);
  FillChar(Drawn, SizeOf(Drawn), 0);
  var Backdrop := Palette(16 + (FRegisters[7] and 15));
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
    for var X := 0 to 255 do
    begin
      var SX := (X - ScrollX) and 255;
      var SY := (Y + FYScroll) mod Wrap;
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
      if Attr and $200 <> 0 then
        Column := 7 - Column;
      var Pixel := TilePixel(Attr and $1FF, Row, Column, False);
      Priority[X] := (Attr and $1000 <> 0) and (Pixel <> 0);
      FPixels[Y * 256 + X] := Palette(Pixel + ((Attr and $800) shr 7));
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
  for var I := 0 to 63 do
  begin
    var SY := Integer(VRAM(Table + I));
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
    Visible[Count] := I;
    Inc(Count);
  end;
  for var V := 0 to Count - 1 do
  begin
    var I := Visible[V];
    var SY := Integer(VRAM(Table + I));
    if SY >= $F0 then
      Dec(SY, 256);
    Inc(SY);
    var AttrAddress := Table + $80 + I * 2;
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
    for var Column := 0 to 7 do
    begin
      var Pixel := TilePixel(Tile, Row, Column, True);
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
  State.Field(FExtra, SizeOf(FExtra));
  State.Field(FCRAM, SizeOf(FCRAM));
  State.Field(FCode, SizeOf(FCode));
  State.Field(FLineCounter, SizeOf(FLineCounter));
  State.Field(FYScroll, SizeOf(FYScroll));
  State.Field(FLineIRQ, SizeOf(FLineIRQ));
end;

end.

