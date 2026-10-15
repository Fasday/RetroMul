unit NGP.Video;

interface

uses
  System.SysUtils, System.UITypes, Core.Snapshots;

const
  NGP_WIDTH = 160;
  NGP_HEIGHT = 152;
  NGP_LINES = 199;

type
  TNGPVideo = class
  private
    FVRAM: array[0..$3FFF] of Byte;
    FPixels: TArray<TAlphaColor>;
    FColor: Boolean;
    FWindowX, FWindowY, FWindowW, FWindowH: Integer;
    function WordAt(Address: Integer): Word;
    function Palette(Index: Integer; Mono: Boolean): TAlphaColor;
    function TilePixel(Tile, X, Y: Integer): Integer;
    procedure Plane(Line, PlaneIndex: Integer);
    procedure Sprites(Line, Priority: Integer);
  public
    constructor Create(Color: Boolean);
    procedure Reset;
    function ReadByte(Address: Cardinal; Line, Cycle: Integer): Byte;
    procedure WriteByte(Address: Cardinal; Value: Byte);
    procedure BeginLine(Line: Integer);
    procedure DrawLine(Line: Integer);
    procedure SerializeState(State: TStateArchive);
    property Pixels: TArray<TAlphaColor> read FPixels;
    function HBlankEnabled: Boolean;
    function VBlankEnabled: Boolean;
  end;

implementation

constructor TNGPVideo.Create(Color: Boolean);
begin
  inherited Create;
  FColor := Color;
  SetLength(FPixels, NGP_WIDTH * NGP_HEIGHT);
  Reset;
end;

procedure TNGPVideo.Reset;
begin
  FillChar(FVRAM, SizeOf(FVRAM), 0);
  FVRAM[4] := $FF;
  FVRAM[5] := $FF;
  FVRAM[7] := $C6;
  FVRAM[$101] := 7;
  FVRAM[$102] := 7;
  FVRAM[$103] := 7;
  FVRAM[$105] := 7;
  FVRAM[$106] := 7;
  FVRAM[$107] := 7;
  for var i := $108 to $117 do
    FVRAM[i] := 7;
  FVRAM[$400] := 7;
  FVRAM[$402] := $80;
  FVRAM[$7F0] := $AA;
  FWindowX := 0;
  FWindowY := 0;
  FWindowW := 255;
  FWindowH := 255;
  for var i := 0 to High(FPixels) do
    FPixels[i] := $FFFFFFFF;
end;

function TNGPVideo.WordAt(Address: Integer): Word;
begin
  Result := FVRAM[Address] or (Word(FVRAM[Address + 1]) shl 8);
end;

function TNGPVideo.ReadByte(Address: Cardinal; Line, Cycle: Integer): Byte;
begin
  Address := Address and $3FFF;
  case Address of
    8:
      Result := Cycle div 4;
    9:
      Result := Line;
  else
    Result := FVRAM[Address];
  end;
end;

procedure TNGPVideo.WriteByte(Address: Cardinal; Value: Byte);
begin
  Address := Address and $3FFF;
  case Address of
    7, 8, 9, $10:
      Exit;
    $30:
      Value := Value and $80;
    $100..$117:
      Value := Value and 7;
    $7E2:
      begin
        if FVRAM[$7F0] <> $AA then
          Exit;
        Value := Value and $80;
      end;
  end;
  if FColor and (Address >= $200) and (Address < $400) and Odd(Address) then
    Value := Value and 15;
  FVRAM[Address] := Value;
end;

function TNGPVideo.HBlankEnabled: Boolean;
begin
  Result := FVRAM[0] and $40 <> 0;
end;

function TNGPVideo.VBlankEnabled: Boolean;
begin
  Result := FVRAM[0] and $80 <> 0;
end;

procedure TNGPVideo.BeginLine(Line: Integer);
begin
  if Line = 0 then
  begin
    FVRAM[$10] := FVRAM[$10] and $BF;
    FWindowX := FVRAM[2];
    FWindowY := FVRAM[3];
    FWindowW := FVRAM[4];
    FWindowH := FVRAM[5];
  end
  else if Line = 152 then
    FVRAM[$10] := FVRAM[$10] or $40;
end;

function TNGPVideo.Palette(Index: Integer; Mono: Boolean): TAlphaColor;
begin
  if not FColor then
  begin
    var Shade: Integer;
    if Mono then
      Shade := FVRAM[$100 + Index] and 7
    else
      Shade := Index and 7;
    if FVRAM[$12] and $80 <> 0 then
      Shade := 7 - Shade;
    Shade := 255 - Shade * 255 div 7;
    Result := $FF000000 or Cardinal(Shade * $10101);
  end
  else
  begin
    var Color: Word;
    if Mono then
      Color := WordAt($380 + (Index div 4) * 16 + (FVRAM[$100 + Index] and 7) * 2)
    else
      Color := WordAt($200 + Index * 2);
    Result := $FF000000 or (Cardinal((Color and 15) * 17) shl 16) or
      (Cardinal(((Color shr 4) and 15) * 17) shl 8) or Cardinal(((Color shr 8) and 15) * 17);
  end;
end;

function TNGPVideo.TilePixel(Tile, X, Y: Integer): Integer;
begin
  if Tile and $8000 <> 0 then
    X := 7 - X;
  if Tile and $4000 <> 0 then
    Y := 7 - Y;
  Result := (WordAt($2000 + (Tile and $1FF) * 16 + Y * 2) shr ((7 - X) * 2)) and 3;
end;

procedure TNGPVideo.Plane(Line, PlaneIndex: Integer);
begin
  var SX := FVRAM[$32 + PlaneIndex * 2];
  var SY := (Line + FVRAM[$33 + PlaneIndex * 2]) and 255;
  var Mono := not FColor or (FVRAM[$7E2] and $80 <> 0);
  for var X := 0 to 159 do
  begin
    var PX := (X + SX) and 255;
    var Tile := WordAt($1000 + PlaneIndex * $800 + (SY div 8) * 64 + (PX div 8) * 2);
    var C := TilePixel(Tile, PX and 7, SY and 7);
    if C = 0 then
      Continue;

    var P: Integer;
    if Mono then
      P := 8 + PlaneIndex * 8 + ((Tile shr 13) and 1) * 4
    else
      P := $40 + PlaneIndex * $40 + ((Tile shr 9) and 15) * 4;
    FPixels[Line * 160 + X] := Palette(P + C, Mono);
  end;
end;

procedure TNGPVideo.Sprites(Line, Priority: Integer);
type
  TSprite = record
    X, Y, Tile, Index: Integer;
  end;
var
  Visible: array[0..63] of TSprite;
begin
  var Count := 0;
  var SX := 0;
  var SY := 0;
  for var i := 0 to 63 do
  begin
    var Tile := WordAt($800 + i * 4);
    if Tile and $400 <> 0 then
      SX := (SX + FVRAM[$802 + i * 4]) and 255
    else
      SX := (FVRAM[$20] + FVRAM[$802 + i * 4]) and 255;
    if Tile and $200 <> 0 then
      SY := (SY + FVRAM[$803 + i * 4]) and 255
    else
      SY := (FVRAM[$21] + FVRAM[$803 + i * 4]) and 255;
    if ((Tile shr 11) and 3 = Priority) and (((Line - SY) and 255) < 8) then
    begin
      Visible[Count].X := SX;
      Visible[Count].Y := SY;
      Visible[Count].Tile := Tile;
      Visible[Count].Index := i;
      Inc(Count);
    end;
  end;
  var Mono := not FColor or (FVRAM[$7E2] and $80 <> 0);
  for var i := Count - 1 downto 0 do
    for var DX := 0 to 7 do
    begin
      var X := (Visible[i].X + DX) and 255;
      if X >= 160 then
        Continue;

      var Tile := Visible[i].Tile;
      var C := TilePixel(Tile, DX, (Line - Visible[i].Y) and 7);
      if C = 0 then
        Continue;

      var P: Integer;
      if Mono then
        P := ((Tile shr 13) and 1) * 4
      else
        P := (FVRAM[$C00 + Visible[i].Index] and 15) * 4;
      FPixels[Line * 160 + X] := Palette(P + C, Mono);
    end;
end;

procedure TNGPVideo.DrawLine(Line: Integer);
begin
  if (Line < 0) or (Line >= 152) then
    Exit;

  var Bg := 0;
  if FVRAM[$118] and $C0 = $80 then
    Bg := FVRAM[$118] and 7;
  var OOW := FVRAM[$12] and 7;
  var BGC, OOWC: TAlphaColor;
  if FColor then
  begin
    BGC := Palette($F0 + Bg, False);
    OOWC := Palette($F8 + OOW, False);
  end
  else
  begin
    BGC := Palette(Bg, False);
    OOWC := Palette(OOW, False);
  end;
  for var X := 0 to 159 do
    FPixels[Line * 160 + X] := BGC;
  Sprites(Line, 1);
  if FVRAM[$30] and $80 <> 0 then
    Plane(Line, 0)
  else
    Plane(Line, 1);
  Sprites(Line, 2);
  if FVRAM[$30] and $80 <> 0 then
    Plane(Line, 1)
  else
    Plane(Line, 0);
  Sprites(Line, 3);
  for var X := 0 to 159 do
    if (Line < FWindowY) or (Line >= FWindowY + FWindowH) or (X < FWindowX) or (X >= FWindowX + FWindowW) then
      FPixels[Line * 160 + X] := OOWC;
end;

procedure TNGPVideo.SerializeState(State: TStateArchive);
begin
  State.Field(FVRAM, SizeOf(FVRAM));
  State.Field(FWindowX, SizeOf(FWindowX));
  State.Field(FWindowY, SizeOf(FWindowY));
  State.Field(FWindowW, SizeOf(FWindowW));
  State.Field(FWindowH, SizeOf(FWindowH));
  State.Field(FPixels[0], Length(FPixels) * SizeOf(TAlphaColor));
end;

end.

