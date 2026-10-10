unit GBC.GPU;

interface

uses
  Core.Snapshots, System.Classes, GBC.InterruptManager, GB.GPU;

{$SCOPEDENUMS ON}

type
  TGPUMode = GB.GPU.TGPUMode;

type
  TScreenArray = GB.GPU.TScreenArray;

  TDrawCallback = GB.GPU.TDrawCallback;

  THBlankCallback = procedure of object;

  TScanlineRow = array[0..159] of Integer;

  TScanlinePriorityRow = array[0..159] of Boolean;

  TRGB32 = packed record
    B, G, R, A: Byte;
  end;

  TRGB32Array = packed array[0..MaxInt div SizeOf(TRGB32) - 1] of TRGB32;

  PRGB32Array = ^TRGB32Array;

type
  TSprite = record
    X: Integer;
    Y: Integer;
    TileNumber: Integer;
    BelowBackground: Boolean;
    IsXFlip: Boolean;
    IsYFlip: Boolean;
    IsPalette1: Boolean;
    PaletteIndex: Integer;
    VRAMBank: Integer;
  end;

type
  TGBCSprites = array[0..39] of TSprite;

type
  TGBCGPU = class(TGBVideo)
  private
    FHBlankCallback: THBlankCallback;

    FCGBMode: Boolean;
    FBootCompatibilityPalettes: Boolean;
    FVBK: Byte;
    FBGPaletteIndex, FOBJPaletteIndex: Byte;
    FBGPaletteRAM, FOBJPaletteRAM: array[0..63] of Byte;
    // Derived ARGB colors; rebuild after loading, never store in snapshots.
    FBGColors, FOBJColors: array[0..31] of Integer;
    procedure RebuildPaletteColors;
  protected
    function ColorRendering: Boolean; override;
    function CoordinatePriority: Boolean; override;
    function ReadDisplayByte(Bank, Address: Integer): Byte; override;
    function ResolvePixel(IsObject: Boolean; Attributes, Color: Integer): Integer; override;
    procedure HBlankStarted; override;
  private
    function CGBColor(const PaletteRAM: array of Byte; PaletteIndex, ColorIndex: Integer): Integer;
    function PixelColor(IsObject: Boolean; PaletteIndex, ColorIndex: Integer): Integer;

  public
    VRAMBank1: array[0..$2000 - 1] of Integer;
    TileSet: array[0..1, 0..383, 0..15, 0..7] of Integer;

    SpriteList: TGBCSprites;

    procedure Step(Cycle: Integer); override;

    procedure SetCGBMode(Value: Boolean);
    property BootCompatibilityPalettes: Boolean read FBootCompatibilityPalettes write FBootCompatibilityPalettes;
    procedure SetHBlankCallback(const Value: THBlankCallback);
    function CanAccessVRAM: Boolean; override;

    procedure UpdateTile(Address: Integer);
    procedure BuildSprite(Address, Value: Integer); override;
    function ReadVRAM(Address: Integer): Byte; override;
    procedure WriteVRAM(Address: Integer; Value: Byte); override;
    function GetVBK: Byte;
    procedure SetVBK(Value: Byte);
    function ReadCGBPalette(Address: Integer): Byte;
    procedure WriteCGBPalette(Address: Integer; Value: Byte);

    constructor Create(Callback: TDrawCallback); reintroduce;
    procedure SerializeState(State: TStateArchive); override;
  end;

implementation

const
  DefaultCGBColors: array[0..3] of Word = ($7FFF, $56B5, $294A, $0000);

function TGBCGPU.CGBColor(const PaletteRAM: array of Byte; PaletteIndex, ColorIndex: Integer): Integer;
var
  Value, R, G, B: Integer;
begin
  // CGB attributes carry only palette[2:0] and color[1:0].  Keep palette
  // RAM addressing inside its eight palettes even if a caller uses a wider
  // intermediate Integer while rendering a newly loaded screen.
  PaletteIndex := PaletteIndex and 7;
  ColorIndex := ColorIndex and 3;
  Value := PaletteRAM[(PaletteIndex * 8) + (ColorIndex * 2)] or (PaletteRAM[(PaletteIndex * 8) + (ColorIndex * 2) + 1] shl 8);
  R := (Value and $1F) * 255 div 31;
  G := ((Value shr 5) and $1F) * 255 div 31;
  B := ((Value shr 10) and $1F) * 255 div 31;
  // TScreenArray stores signed Integers.  Do not use $FF000000 here: with
  // range checks enabled Delphi treats that literal as an unsigned value and
  // raises ERangeError before the bit pattern can be assigned.  -$01000000
  // is the identical opaque-alpha ARGB bit pattern in the signed domain.
  Result := -$01000000 or (R shl 16) or (G shl 8) or B;
end;

procedure TGBCGPU.RebuildPaletteColors;
begin
  for var I := 0 to 31 do
  begin
    FBGColors[I] := CGBColor(FBGPaletteRAM, I shr 2, I and 3);
    FOBJColors[I] := CGBColor(FOBJPaletteRAM, I shr 2, I and 3);
  end;
end;

function TGBCGPU.PixelColor(IsObject: Boolean; PaletteIndex, ColorIndex: Integer): Integer;
const
  DMGR: array[0..3] of Integer = ($E0, $88, $34, $08);
  DMGG: array[0..3] of Integer = ($F8, $C0, $68, $18);
  DMGB: array[0..3] of Integer = ($D0, $70, $56, $20);
var
  Shade: Integer;
begin
  if FCGBMode then
  begin
    if IsObject then
      Result := FOBJColors[((PaletteIndex and 7) shl 2) or (ColorIndex and 3)]
    else
      Result := FBGColors[((PaletteIndex and 7) shl 2) or (ColorIndex and 3)];
    Exit;
  end;

  if IsObject then
  begin
    if PaletteIndex = 0 then
      Shade := SpritePalette[0][ColorIndex]
    else
      Shade := SpritePalette[1][ColorIndex];
  end
  else
    Shade := BackgroundPalette[ColorIndex];
  if FBootCompatibilityPalettes then
  begin
    if IsObject then
      Result := FOBJColors[((PaletteIndex and 1) shl 2) or Shade]
    else
      Result := FBGColors[Shade];
    Exit;
  end;

  Result := -$01000000 or (DMGR[Shade] shl 16) or (DMGG[Shade] shl 8) or DMGB[Shade];
end;

procedure TGBCGPU.SetCGBMode(Value: Boolean);
begin
  FCGBMode := Value;
  if not Value then
    Exit;

  for var PaletteIndex := 0 to 7 do
    for var ColorIndex := 0 to 3 do
    begin
      FBGPaletteRAM[PaletteIndex * 8 + ColorIndex * 2] := DefaultCGBColors[ColorIndex] and $FF;
      FBGPaletteRAM[PaletteIndex * 8 + ColorIndex * 2 + 1] := DefaultCGBColors[ColorIndex] shr 8;
      FOBJPaletteRAM[PaletteIndex * 8 + ColorIndex * 2] := DefaultCGBColors[ColorIndex] and $FF;
      FOBJPaletteRAM[PaletteIndex * 8 + ColorIndex * 2 + 1] := DefaultCGBColors[ColorIndex] shr 8;
    end;
  RebuildPaletteColors;
end;

function TGBCGPU.ReadVRAM(Address: Integer): Byte;
begin
  Address := Address and $1FFF;
  if (FVBK and 1) <> 0 then
    Result := VRAMBank1[Address]
  else
    Result := VRAM[Address];
end;

procedure TGBCGPU.WriteVRAM(Address: Integer; Value: Byte);
begin
  Address := Address and $1FFF;
  if (FVBK and 1) <> 0 then
    VRAMBank1[Address] := Value
  else
    VRAM[Address] := Value;
  // $1800..$1FFF is the tile-map area, not tile data.  UpdateTile has 384
  // decoded tile slots ($0000..$17FF), so map writes must not enter it.
  if Address <= $17FF then
    UpdateTile(Address);
end;

function TGBCGPU.GetVBK: Byte;
begin
  Result := $FE or (FVBK and 1);
end;

procedure TGBCGPU.SetVBK(Value: Byte);
begin
  FVBK := Value and 1;
end;

function TGBCGPU.ReadCGBPalette(Address: Integer): Byte;
begin
  case Address of
    $FF68:
      Result := FBGPaletteIndex or $40;
    $FF69:
      if CanAccessVRAM then
        Result := FBGPaletteRAM[FBGPaletteIndex and $3F]
      else
        Result := $FF;
    $FF6A:
      Result := FOBJPaletteIndex or $40;
  else
    if CanAccessVRAM then
      Result := FOBJPaletteRAM[FOBJPaletteIndex and $3F]
    else
      Result := $FF;
  end;
end;

procedure TGBCGPU.WriteCGBPalette(Address: Integer; Value: Byte);
begin
  case Address of
    $FF68:
      FBGPaletteIndex := Value and $BF;
    $FF69:
      begin
        if CanAccessVRAM then
        begin
          FBGPaletteRAM[FBGPaletteIndex and $3F] := Value;
          var Index := (FBGPaletteIndex and $3F) shr 1;
          FBGColors[Index] := CGBColor(FBGPaletteRAM, Index shr 2, Index and 3);
        end;
        if (FBGPaletteIndex and $80) <> 0 then
          FBGPaletteIndex := $80 or ((FBGPaletteIndex + 1) and $3F);
      end;
    $FF6A:
      FOBJPaletteIndex := Value and $BF;
    $FF6B:
      begin
        if CanAccessVRAM then
        begin
          FOBJPaletteRAM[FOBJPaletteIndex and $3F] := Value;
          var Index := (FOBJPaletteIndex and $3F) shr 1;
          FOBJColors[Index] := CGBColor(FOBJPaletteRAM, Index shr 2, Index and 3);
        end;
        if (FOBJPaletteIndex and $80) <> 0 then
          FOBJPaletteIndex := $80 or ((FOBJPaletteIndex + 1) and $3F);
      end;
  end;
end;

procedure TGBCGPU.SetHBlankCallback(const Value: THBlankCallback);
begin
  FHBlankCallback := Value;
end;

function TGBCGPU.CanAccessVRAM: Boolean;
begin
  // The CPU cannot use VRAM during pixel transfer (mode 3).  DMA uses
  // WriteVRAM directly and deliberately bypasses this CPU bus restriction.
  Result := (not FLCDEnabled) or (FCurrentMode <> TGPUMode.VRAMAccess);
end;

{ TGBGPU }

procedure TGBCGPU.BuildSprite(Address, Value: Integer);
begin
  RecordOAM(Address, Value);
  var SpriteNumber: Integer := Address shr 2;
  if SpriteNumber >= 40 then
    Exit;

  case Address and $3 of
    0: // Y-coordinate
      SpriteList[SpriteNumber].Y := Value - 16;
    1: // X-coordinate
      SpriteList[SpriteNumber].X := Value - 8;
    2: // Data tile
      SpriteList[SpriteNumber].TileNumber := Value;
    3: // Options
      begin
        SpriteList[SpriteNumber].IsPalette1 := (Value and $10) <> 0;
        SpriteList[SpriteNumber].IsXFlip := (Value and $20) <> 0;
        SpriteList[SpriteNumber].IsYFlip := (Value and $40) <> 0;
        SpriteList[SpriteNumber].BelowBackground := (Value and $80) <> 0;
        SpriteList[SpriteNumber].PaletteIndex := Value and 7;
        SpriteList[SpriteNumber].VRAMBank := (Value shr 3) and 1;
      end;
  end;
end;

constructor TGBCGPU.Create(Callback: TDrawCallback);
begin
  inherited Create(Callback, TGBCInterruptManager.Instance);
  FCGBMode := False;
  for var i := 0 to 39 do
    with SpriteList[i] do
    begin
      Y := -16; // Y-coordinate of top-left corner, (Value stored is Y-coordinate minus 16)
      X := -8;  // X-coordinate of top-left corner, (Value stored is X-coordinate minus 8)
      TileNumber := 0;
      BelowBackground := False; // false = above background, true = below background
      IsYFlip := False;
      IsXFlip := False;
      IsPalette1 := False; // false = palette 0, true = palette 1
      PaletteIndex := 0;
      VRAMBank := 0;
    end;
end;

procedure TGBCGPU.Step(Cycle: Integer);
begin
  inherited;
end;

function TGBCGPU.ColorRendering: Boolean;
begin
  Result := FCGBMode;
end;

function TGBCGPU.CoordinatePriority: Boolean;
begin
  Result := not FCGBMode;
end;

function TGBCGPU.ReadDisplayByte(Bank, Address: Integer): Byte;
begin
  if FPipeline.StopVRAM then
    Exit($FF);
  if Bank = 1 then
    Result := VRAMBank1[Address and $1FFF]
  else
    Result := VRAM[Address and $1FFF];
end;

function TGBCGPU.ResolvePixel(IsObject: Boolean; Attributes, Color: Integer): Integer;
begin
  if FPipeline.StopVRAM then
    Exit(Integer($FF000000));
  var PaletteIndex := Attributes and 7;
  if not FCGBMode then
    PaletteIndex := (Attributes shr 4) and 1;
  Result := PixelColor(IsObject, PaletteIndex, Color);
end;

procedure TGBCGPU.HBlankStarted;
begin
  if Assigned(FHBlankCallback) then
    FHBlankCallback;
end;

procedure TGBCGPU.UpdateTile(Address: Integer);
begin
  // get base address for this tile row
  Address := Address and $1FFE;
  // work out which tile and row was updated
  var Tile: Integer := (Address shr 4) and 511;
  var Y: Integer := (Address shr 1) and 7;
  for var i := 0 to 7 do
  begin
    // find bit index for this pixel
    var Sx: Integer := 1 shl (7 - i);
    var Tmp1, Tmp2: Integer;
    var TileLow, TileHigh: Integer;
    if FVBK and 1 <> 0 then
    begin
      TileLow := VRAMBank1[Address];
      TileHigh := VRAMBank1[Address + 1];
    end
    else
    begin
      TileLow := VRAM[Address];
      TileHigh := VRAM[Address + 1];
    end;
    if (TileLow and Sx) <> 0 then
      Tmp1 := 1
    else
      Tmp1 := 0;
    if (TileHigh and Sx) <> 0 then
      Tmp2 := 2
    else
      Tmp2 := 0;
    var Value := Tmp1 or Tmp2;
    TileSet[FVBK and 1][Tile][Y][i] := Value;
  end;
end;

procedure TGBCGPU.SerializeState(State: TStateArchive);
begin
  SerializePipeline(State);
  State.Field(FCurrentMode, SizeOf(FCurrentMode));
  State.Field(FWindowLine, SizeOf(FWindowLine));
  State.Field(FWindowTriggered, SizeOf(FWindowTriggered));
  State.Field(FSTATLineActive, SizeOf(FSTATLineActive));
  State.Field(FLYCInterruptEnabled, SizeOf(FLYCInterruptEnabled));
  State.Field(FOAMInterruptEnabled, SizeOf(FOAMInterruptEnabled));
  State.Field(FVBlankInterruptEnabled, SizeOf(FVBlankInterruptEnabled));
  State.Field(FHBlankInterruptEnabled, SizeOf(FHBlankInterruptEnabled));
  State.Field(FLineMatchesLYC, SizeOf(FLineMatchesLYC));
  State.Field(FLCDEnabled, SizeOf(FLCDEnabled));
  State.Field(FWindowTileMapHigh, SizeOf(FWindowTileMapHigh));
  State.Field(FWindowEnabled, SizeOf(FWindowEnabled));
  State.Field(FUnsignedTileData, SizeOf(FUnsignedTileData));
  State.Field(FBackgroundTileMapHigh, SizeOf(FBackgroundTileMapHigh));
  State.Field(FTallSprites, SizeOf(FTallSprites));
  State.Field(FSpritesEnabled, SizeOf(FSpritesEnabled));
  State.Field(FBackgroundEnabled, SizeOf(FBackgroundEnabled));
  State.Field(FCGBMode, SizeOf(FCGBMode));
  State.Field(FBootCompatibilityPalettes, SizeOf(FBootCompatibilityPalettes));
  State.Field(FVBK, SizeOf(FVBK));
  State.Field(FBGPaletteIndex, SizeOf(FBGPaletteIndex));
  State.Field(FOBJPaletteIndex, SizeOf(FOBJPaletteIndex));
  State.Field(FBGPaletteRAM, SizeOf(FBGPaletteRAM));
  State.Field(FOBJPaletteRAM, SizeOf(FOBJPaletteRAM));
  State.Field(ModeClock, SizeOf(ModeClock));
  State.Field(Width, SizeOf(Width));
  State.Field(Height, SizeOf(Height));
  State.Field(Line, SizeOf(Line));
  State.Field(LYC, SizeOf(LYC));
  State.Field(ScrollX, SizeOf(ScrollX));
  State.Field(ScrollY, SizeOf(ScrollY));
  State.Field(WindowX, SizeOf(WindowX));
  State.Field(WindowY, SizeOf(WindowY));
  State.Field(VRAM, SizeOf(VRAM));
  State.Field(VRAMBank1, SizeOf(VRAMBank1));
  State.Field(TileSet, SizeOf(TileSet));
  State.Field(Screen, SizeOf(Screen));
  State.Field(BackgroundPalette, SizeOf(BackgroundPalette));
  State.Field(SpritePalette, SizeOf(SpritePalette));
  State.Field(Palette, SizeOf(Palette));
  State.Field(SpriteList, SizeOf(SpriteList));
  if State.Loading then
    RebuildPaletteColors;
end;

end.

