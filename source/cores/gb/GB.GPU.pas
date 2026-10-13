unit GB.GPU;

interface

uses
  Core.Snapshots, System.Classes, GB.InterruptManager, GB.Palettes;

{$SCOPEDENUMS ON}

type
  TGPUMode = (HBlank, VBlank, OAMAccess, VRAMAccess);

type
  TScreenArray = array[0..23039] of Integer;

  TDrawCallback = reference to procedure(const Value: TScreenArray);

  TScanlineRow = array[0..159] of Integer;

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
  end;

type
  TGBSprites = array[0..39] of TSprite;

type
  TGBFifoPixel = packed record
    Color, Attributes: Byte;
  end;

  TGBPixelPipeline = record
    Dot, X, Discard, Startup, FetchTick, FetchStage, TileX: Integer;
    TileAddress, TileIndex, TileAttributes, LowByte, HighByte: Integer;
    Head, Count, SpriteCount, SpriteStall, PendingSprite: Integer;
    ObjectLowByte, ObjectHighByte, WindowStartX: Integer;
    WindowActive, WindowDrawn, TileGlitch, StopVRAM, StopOAM, FirstLine: Boolean;
    FIFO: array[0..15] of TGBFifoPixel;
    OAM: array[0..159] of Byte;
    Selected: array[0..39] of Integer;
    Fetched: array[0..39] of Boolean;
    Objects: array[0..15] of TGBFifoPixel;
    ObjectRank: array[0..15] of Integer;
  end;

  // Shared bus and clock contract; each renderer retains its own state layout.
  TGBVideo = class abstract
  protected
    FPipeline: TGBPixelPipeline;
    FDrawCallback: TDrawCallback;
    function ColorRendering: Boolean; virtual;
    function CoordinatePriority: Boolean; virtual;
    function ReadDisplayByte(Bank, Address: Integer): Byte; virtual;
    function ResolvePixel(IsObject: Boolean; Attributes, Color: Integer): Integer; virtual;
    procedure HBlankStarted; virtual;
    procedure BeginPixelTransfer;
    procedure ClockPixelTransfer;
    procedure ClockTileFetcher;
    procedure PushBackground;
    function ReadObjectData(Index: Integer; HighByte: Boolean): Byte;
    procedure FetchObject(Index: Integer);
    procedure RecordOAM(Address, Value: Integer);
    procedure SerializePipeline(State: TStateArchive);
  protected
    FCurrentMode: TGPUMode;
    FWindowLine: Integer;
    FWindowTriggered: Boolean;
    FSTATLineActive: Boolean;
    FLYCInterruptEnabled: Boolean;
    FOAMInterruptEnabled: Boolean;
    FVBlankInterruptEnabled: Boolean;
    FHBlankInterruptEnabled: Boolean;
    FLineMatchesLYC: Boolean;
    FLCDEnabled: Boolean;
    FWindowTileMapHigh: Boolean;
    FWindowEnabled: Boolean;
    FUnsignedTileData: Boolean;
    FBackgroundTileMapHigh: Boolean;
    FTallSprites: Boolean;
    FSpritesEnabled: Boolean;
    FBackgroundEnabled: Boolean;
    FInterruptManager: TGBInterruptManager;
    function GetSpriteHeight: Integer;
  public
    RuntimeOptions: TGBRuntimeOptions;
    TagMonochromePixels: Boolean;
    ModeClock: Integer;
    Width, Height: Integer;
    Line, LYC: Integer;
    ScrollX, ScrollY: Integer;
    WindowX, WindowY: Integer;
    VRAM: array[0..$2000 - 1] of Integer;
    Screen: TScreenArray;
    BackgroundPalette: array[0..3] of Integer;
    SpritePalette: array[0..1, 0..3] of Integer;
    Palette: array[0..3] of Integer;
    procedure ProcessLCDStatus;
    constructor Create(Callback: TDrawCallback; InterruptManager: TGBInterruptManager);
    procedure Step(Cycle: Integer); virtual;
    function GetLCDStatus: Integer;
    procedure SetLCDStatus(Value: Integer);
    procedure SetLCDControl(Value: Integer);
    function GetLCDControl: Integer;
    procedure BuildSprite(Address, Value: Integer); virtual; abstract;
    function ReadVRAM(Address: Integer): Byte; virtual; abstract;
    procedure WriteVRAM(Address: Integer; Value: Byte); virtual; abstract;
    function CanAccessVRAM: Boolean; virtual;
    function CanAccessOAM: Boolean;
    function OAMCorruptionRow: Integer;
    procedure SetTileFetchGlitch;
    procedure SetCPUStop(Value: Boolean);
    procedure SerializeState(State: TStateArchive); virtual; abstract;
  end;

  TGBGPU = class(TGBVideo)
  private
  public
    TileSet: array[0..383, 0..15, 0..7] of Integer;

    SpriteList: TGBSprites;

    procedure Step(Cycle: Integer); override;

    function ReadVRAM(Address: Integer): Byte; override;
    procedure WriteVRAM(Address: Integer; Value: Byte); override;
    function CanAccessVRAM: Boolean; override;
    procedure UpdateTile(Address: Integer);
    procedure BuildSprite(Address, Value: Integer); override;

    constructor Create(Callback: TDrawCallback); reintroduce;
    procedure SerializeState(State: TStateArchive); override;
  end;

implementation

function TGBVideo.ColorRendering: Boolean;
begin
  Result := False;
end;

function TGBVideo.CoordinatePriority: Boolean;
begin
  Result := True;
end;

function TGBVideo.ReadDisplayByte(Bank, Address: Integer): Byte;
begin
  if FPipeline.StopVRAM then
    Exit($FF);

  Result := VRAM[Address and $1FFF];
end;

function TGBVideo.ResolvePixel(IsObject: Boolean; Attributes, Color: Integer): Integer;
begin
  if IsObject then
    Result := SpritePalette[(Attributes shr 4) and 1][Color]
  else
    Result := BackgroundPalette[Color];
  if IsObject and TagMonochromePixels then
    Result := Result or ((((Attributes shr 4) and 1) + 1) shl 2);
end;

procedure TGBVideo.HBlankStarted;
begin
end;

procedure TGBVideo.RecordOAM(Address, Value: Integer);
begin
  if (Address >= 0) and (Address < 160) then
    FPipeline.OAM[Address] := Value;
end;

function TGBVideo.CanAccessVRAM: Boolean;
begin
  Result := not FLCDEnabled or (FCurrentMode <> TGPUMode.VRAMAccess);
end;

function TGBVideo.CanAccessOAM: Boolean;
begin
  Result := not FLCDEnabled or (FCurrentMode in [TGPUMode.HBlank, TGPUMode.VBlank]);
end;

function TGBVideo.OAMCorruptionRow: Integer;
begin
  Result := -1;
  if FLCDEnabled and (FCurrentMode = TGPUMode.OAMAccess) and (FPipeline.Dot >= 4) and (FPipeline.Dot < 80) then
    Result := FPipeline.Dot div 4;
end;

procedure TGBVideo.SetTileFetchGlitch;
begin
  FPipeline.TileGlitch := True;
end;

procedure TGBVideo.BeginPixelTransfer;
begin
  FCurrentMode := TGPUMode.VRAMAccess;
  ModeClock := 0;
  FPipeline.X := 0;
  FPipeline.Discard := ScrollX and 7;
  FPipeline.Startup := 12;
  FPipeline.FetchTick := 0;
  FPipeline.FetchStage := 0;
  FPipeline.TileX := 0;
  FPipeline.Count := 0;
  FPipeline.Head := 0;
  FPipeline.WindowActive := False;
  FPipeline.WindowDrawn := False;
  FPipeline.SpriteStall := 0;
  FPipeline.PendingSprite := -1;
  FPipeline.TileGlitch := False;
  FillChar(FPipeline.Fetched, SizeOf(FPipeline.Fetched), 0);
  FillChar(FPipeline.Objects, SizeOf(FPipeline.Objects), 0);
  for var i := 0 to 15 do
    FPipeline.ObjectRank[i] := MaxInt;
end;

procedure TGBVideo.ClockTileFetcher;
begin
  Inc(FPipeline.FetchTick);
  if FPipeline.FetchTick < 2 then
    Exit;

  FPipeline.FetchTick := 0;
  case FPipeline.FetchStage of
    0:
      begin
        var Y := (Line + ScrollY) and $FF;
        var Map := $1800;
        if FPipeline.WindowActive then
        begin
          Y := FWindowLine;
          if FWindowTileMapHigh then
            Map := $1C00;
        end
        else if FBackgroundTileMapHigh then
          Map := $1C00;
        var X := FPipeline.TileX;
        if not FPipeline.WindowActive then
          Inc(X, ScrollX shr 3);
        Map := Map + ((Y shr 3) and 31) * 32 + (X and 31);
        FPipeline.TileIndex := ReadDisplayByte(0, Map);
        FPipeline.TileAttributes := 0;
        if ColorRendering then
          FPipeline.TileAttributes := ReadDisplayByte(1, Map);
        var Row := Y and 7;
        if (FPipeline.TileAttributes and $40) <> 0 then
          Row := 7 - Row;
        if FUnsignedTileData then
          FPipeline.TileAddress := FPipeline.TileIndex * 16 + Row * 2
        else
          FPipeline.TileAddress := $1000 + ShortInt(Byte(FPipeline.TileIndex)) * 16 + Row * 2;
      end;
    1:
      if FPipeline.TileGlitch then
        FPipeline.LowByte := FPipeline.TileIndex
      else
        FPipeline.LowByte := ReadDisplayByte((FPipeline.TileAttributes shr 3) and 1, FPipeline.TileAddress);
    2:
      begin
        if FPipeline.TileGlitch then
          FPipeline.HighByte := FPipeline.TileIndex
        else
          FPipeline.HighByte := ReadDisplayByte((FPipeline.TileAttributes shr 3) and 1, FPipeline.TileAddress + 1);
        if FPipeline.WindowActive and (FPipeline.TileX = 0) and (FPipeline.Count = 0) then
        begin
          PushBackground;
          FPipeline.FetchStage := 3;
        end;
      end;
    3:
      begin
        if FPipeline.Count > 8 then
          Exit;

        PushBackground;
      end;
  end;
  FPipeline.FetchStage := (FPipeline.FetchStage + 1) and 3;
end;

procedure TGBVideo.SetCPUStop(Value: Boolean);
begin
  FPipeline.StopVRAM := Value and (FCurrentMode in [TGPUMode.HBlank, TGPUMode.VBlank]);
  FPipeline.StopOAM := Value and (FCurrentMode <> TGPUMode.VRAMAccess);
end;

procedure TGBVideo.PushBackground;
begin
  for var i := 0 to 7 do
  begin
    var Bit := 7 - i;
    if (FPipeline.TileAttributes and $20) <> 0 then
      Bit := i;
    var Tail := (FPipeline.Head + FPipeline.Count) and 15;
    FPipeline.FIFO[Tail].Color := ((FPipeline.LowByte shr Bit) and 1) or (((FPipeline.HighByte shr Bit) and 1) shl 1);
    FPipeline.FIFO[Tail].Attributes := FPipeline.TileAttributes;
    Inc(FPipeline.Count);
  end;
  Inc(FPipeline.TileX);
  FPipeline.TileGlitch := False;
end;

function TGBVideo.ReadObjectData(Index: Integer; HighByte: Boolean): Byte;
begin
  var Offset := FPipeline.Selected[Index] * 4;
  var Row := Line - (Integer(FPipeline.OAM[Offset]) - 16);
  var Attributes := FPipeline.OAM[Offset + 3];
  if (Attributes and $40) <> 0 then
    Row := GetSpriteHeight - 1 - Row;
  var Tile := Integer(FPipeline.OAM[Offset + 2]);
  if FTallSprites then
    Tile := (Tile and $FE) + (Row shr 3);
  var Bank := 0;
  if ColorRendering then
    Bank := (Attributes shr 3) and 1;
  Result := ReadDisplayByte(Bank, Tile * 16 + (Row and 7) * 2 + Ord(HighByte));
end;

procedure TGBVideo.FetchObject(Index: Integer);
begin
  var Offset := FPipeline.Selected[Index] * 4;
  var X := Integer(FPipeline.OAM[Offset + 1]) - 8;
  var Attributes := FPipeline.OAM[Offset + 3];
  var Low := FPipeline.ObjectLowByte;
  var High := FPipeline.ObjectHighByte;
  var Rank := FPipeline.Selected[Index];
  if CoordinatePriority then
    Rank := (X + 8) * 40 + Rank;
  for var i := 0 to 7 do
  begin
    var Destination := X + i;
    if (Destination < FPipeline.X) or (Destination >= 160) then
      Continue;

    var Bit := 7 - i;
    if (Attributes and $20) <> 0 then
      Bit := i;
    var Color := ((Low shr Bit) and 1) or (((High shr Bit) and 1) shl 1);
    Destination := Destination and 15;
    if (Color = 0) or (Rank >= FPipeline.ObjectRank[Destination]) then
      Continue;

    FPipeline.ObjectRank[Destination] := Rank;
    FPipeline.Objects[Destination].Color := Color;
    FPipeline.Objects[Destination].Attributes := Attributes;
  end;
end;

procedure TGBVideo.ClockPixelTransfer;
begin
  if FPipeline.SpriteStall > 0 then
  begin
    Dec(FPipeline.SpriteStall);
    if FPipeline.SpriteStall = 2 then
      FPipeline.ObjectLowByte := ReadObjectData(FPipeline.PendingSprite, False);
    if FPipeline.SpriteStall = 1 then
      FPipeline.ObjectHighByte := ReadObjectData(FPipeline.PendingSprite, True);
    if FPipeline.SpriteStall = 0 then
      FetchObject(FPipeline.PendingSprite);
    Exit;
  end;

  if FPipeline.Startup > 0 then
  begin
    ClockTileFetcher;
    Dec(FPipeline.Startup);
    Exit;
  end;

  var IsColor := ColorRendering;
  if FWindowEnabled and FWindowTriggered and (WindowX <= 166) and
    (IsColor or FBackgroundEnabled) and not FPipeline.WindowActive and
    (FPipeline.X >= WindowX - 7) then
  begin
    FPipeline.WindowActive := True;
    FPipeline.WindowStartX := WindowX;
    FPipeline.WindowDrawn := True;
    FPipeline.Head := 0;
    FPipeline.Count := 0;
    FPipeline.TileX := 0;
    FPipeline.FetchStage := 0;
    FPipeline.FetchTick := 0;
    FPipeline.Startup := 5;
    FPipeline.Discard := 0;
    if WindowX < 7 then
      FPipeline.Discard := 7 - WindowX;

    // Window restart takes six dots; fetch and push the first tile in them.
    ClockTileFetcher;
    Exit;
  end;

  if (FSpritesEnabled or IsColor) and not FPipeline.StopOAM then
    for var i := 0 to FPipeline.SpriteCount - 1 do
    begin
      if FPipeline.Fetched[i] then
        Continue;
      var SX := Integer(FPipeline.OAM[FPipeline.Selected[i] * 4 + 1]) - 8;
      if (SX > FPipeline.X) or (SX >= 160) then
        Continue;

      FPipeline.Fetched[i] := True;
      if i >= 10 then
      begin
        // Additional host sprites do not extend mode 3 or alter hardware DMA/STAT timing.
        FPipeline.ObjectLowByte := ReadObjectData(i, False);
        FPipeline.ObjectHighByte := ReadObjectData(i, True);
        FetchObject(i);
        Continue;
      end;

      FPipeline.PendingSprite := i;
      var Alignment := (SX + ScrollX) and 7;
      if Alignment > 5 then
        Alignment := 5;
      FPipeline.SpriteStall := 10 - Alignment;
      Exit;
    end;

  if FPipeline.Count > 0 then
  begin
    var BG := FPipeline.FIFO[FPipeline.Head];
    FPipeline.Head := (FPipeline.Head + 1) and 15;
    Dec(FPipeline.Count);
    if FPipeline.Discard > 0 then
      Dec(FPipeline.Discard)
    else
    begin
      if not IsColor and not FBackgroundEnabled then
        BG.Color := 0;
      var Obj := FPipeline.Objects[FPipeline.X and 15];
      FPipeline.Objects[FPipeline.X and 15] := Default(TGBFifoPixel);
      FPipeline.ObjectRank[FPipeline.X and 15] := MaxInt;
      if FPipeline.WindowActive and (WindowX <> FPipeline.WindowStartX) and (FPipeline.X = WindowX - 7) then
        BG.Color := 0;
      if FPipeline.StopVRAM then
      begin
        BG.Color := 3;
        Obj.Color := 0;
      end;
      if (FPipeline.WindowActive and not RuntimeOptions.ShowWindow) or
        (not FPipeline.WindowActive and not RuntimeOptions.ShowBackground) then
      begin
        BG.Color := 0;
        BG.Attributes := 0;
      end;
      var DrawObject := FSpritesEnabled and RuntimeOptions.ShowSprites and (Obj.Color <> 0);
      if BG.Color <> 0 then
      begin
        if IsColor then
          DrawObject := DrawObject and (not FBackgroundEnabled or
            (((BG.Attributes or Obj.Attributes) and $80) = 0))
        else
          DrawObject := DrawObject and ((Obj.Attributes and $80) = 0);
      end;
      if DrawObject then
        Screen[Line * 160 + FPipeline.X] := ResolvePixel(True, Obj.Attributes, Obj.Color)
      else
        Screen[Line * 160 + FPipeline.X] := ResolvePixel(False, BG.Attributes, BG.Color);
      Inc(FPipeline.X);
      if FPipeline.X = 160 then
      begin
        if FPipeline.WindowDrawn then
          Inc(FWindowLine);
        FCurrentMode := TGPUMode.HBlank;
        ModeClock := 0;
        ProcessLCDStatus;
        HBlankStarted;
        Exit;
      end;
    end;
  end;
  ClockTileFetcher;
end;

procedure TGBVideo.Step(Cycle: Integer);
begin
  for var Tick := 1 to Cycle do
  begin
    if not FLCDEnabled then
      Exit;

    if (FPipeline.Dot = 0) and (FCurrentMode = TGPUMode.OAMAccess) then
    begin
      FPipeline.SpriteCount := 0;
      if Line = WindowY then
        FWindowTriggered := True;
    end;
    Inc(FPipeline.Dot);
    Inc(ModeClock);
    if FPipeline.FirstLine then
    begin
      // The first line after LCD enable skips OAM search and starts mode 3 later.
      if FPipeline.Dot = 84 then
        BeginPixelTransfer
      else if FCurrentMode = TGPUMode.VRAMAccess then
        ClockPixelTransfer;
    end
    else if FCurrentMode = TGPUMode.OAMAccess then
    begin
      if (FPipeline.Dot and 1) = 0 then
      begin
        var Index := FPipeline.Dot div 2 - 1;
        var Y := Integer(FPipeline.OAM[Index * 4]) - 16;
        if (FPipeline.SpriteCount < 10 + Ord(RuntimeOptions.RemoveSpriteLimit) * 30) and (Line >= Y) and (Line < Y + GetSpriteHeight) then
        begin
          FPipeline.Selected[FPipeline.SpriteCount] := Index;
          Inc(FPipeline.SpriteCount);
        end;
      end;
      if FPipeline.Dot = 80 then
        BeginPixelTransfer;
    end
    else if FCurrentMode = TGPUMode.VRAMAccess then
      ClockPixelTransfer
    else if (FCurrentMode = TGPUMode.VBlank) and (Line = 153) and (FPipeline.Dot = 4) then
      Line := 0;
    if FPipeline.Dot = 456 then
    begin
      FPipeline.FirstLine := False;
      FPipeline.Dot := 0;
      ModeClock := 0;
      if (FCurrentMode = TGPUMode.VBlank) and (Line = 0) then
      begin
        FWindowLine := 0;
        FWindowTriggered := False;
        FCurrentMode := TGPUMode.OAMAccess;
      end
      else
      begin
        Inc(Line);
        if Line = 144 then
        begin
          FCurrentMode := TGPUMode.VBlank;
          FInterruptManager.RaiseInterruptByIndex(4);
          ProcessLCDStatus;
          if Assigned(FDrawCallback) then
            FDrawCallback(Screen);
        end
        else if Line < 144 then
          FCurrentMode := TGPUMode.OAMAccess;
      end;
    end;
    ProcessLCDStatus;

    // The LCDC.4 bus glitch lasts one PPU clock, not an entire tile fetch.
    FPipeline.TileGlitch := False;
  end;
end;

procedure TGBVideo.SerializePipeline(State: TStateArchive);
begin
  State.Field(FPipeline, SizeOf(FPipeline));
end;

constructor TGBVideo.Create(Callback: TDrawCallback; InterruptManager: TGBInterruptManager);
begin
  inherited Create;
  FInterruptManager := InterruptManager;
  FDrawCallback := Callback;
  RuntimeOptions := TGBRuntimeOptions.Defaults;
  Width := 160;
  Height := 144;

  FSTATLineActive := False;
  FLYCInterruptEnabled := False;
  FOAMInterruptEnabled := False;
  FVBlankInterruptEnabled := False;
  FHBlankInterruptEnabled := False;
  FLineMatchesLYC := False;

  FLCDEnabled := True;             //Bit 7 - LCD Display Enable             (0=Off, 1=On)
  FWindowTileMapHigh := False;     //Bit 6 - Window Tile Map Display Select (0=9800-9BFF, 1=9C00-9FFF)
  FWindowEnabled := False;         //Bit 5 - Window Display Enable          (0=Off, 1=On)
  FUnsignedTileData := False;      //Bit 4 - BG & Window Tile Data Select   (0=8800-97FF, 1=8000-8FFF)
  FBackgroundTileMapHigh := False; //Bit 3 - BG Tile Map Display Select     (0=9800-9BFF, 1=9C00-9FFF)
  FTallSprites := False;           //Bit 2 - OBJ (Sprite) Size              (0=8x8, 1=8x16)
  FSpritesEnabled := False;        //Bit 1 - OBJ (Sprite) Display Enable    (0=Off, 1=On)
  FBackgroundEnabled := False;     //Bit 0 - BG/Window Display/Priority     (0=Off, 1=On)

  BackgroundPalette[0] := 0;
  BackgroundPalette[1] := 3;
  BackgroundPalette[2] := 3;
  BackgroundPalette[3] := 3;

  SpritePalette[0][0] := 0;
  SpritePalette[0][1] := 3;
  SpritePalette[0][2] := 3;
  SpritePalette[0][3] := 3;
  SpritePalette[1][0] := 0;
  SpritePalette[1][1] := 3;
  SpritePalette[1][2] := 3;
  SpritePalette[1][3] := 3;

  Palette[0] := 0;
  Palette[1] := 1;
  Palette[2] := 2;
  Palette[3] := 3;

  ModeClock := 0;
  FCurrentMode := TGPUMode.OAMAccess;
  SetLCDControl($91);
end;

function TGBVideo.GetSpriteHeight: Integer;
begin
  if FTallSprites then
    Result := 16
  else
    Result := 8;
end;

function TGBVideo.GetLCDControl: Integer;
begin
  Result :=
    (Ord(FLCDEnabled) shl 7) or
    (Ord(FWindowTileMapHigh) shl 6) or
    (Ord(FWindowEnabled) shl 5) or
    (Ord(FUnsignedTileData) shl 4) or
    (Ord(FBackgroundTileMapHigh) shl 3) or
    (Ord(FTallSprites) shl 2) or
    (Ord(FSpritesEnabled) shl 1) or Ord(FBackgroundEnabled);
end;

function TGBVideo.GetLCDStatus: Integer;
begin
  // Bit 7 is unused and always reads as 1.
  Result := $80 or
    (Ord(FLYCInterruptEnabled) shl 6) or
    (Ord(FOAMInterruptEnabled) shl 5) or
    (Ord(FVBlankInterruptEnabled) shl 4) or
    (Ord(FHBlankInterruptEnabled) shl 3) or
    (Ord(Line = LYC) shl 2) or Ord(FCurrentMode);
end;

procedure TGBVideo.SetLCDControl(Value: Integer);
begin
  var NewLCDEnable: Boolean := Value and $80 <> 0;
  var NewWndTileMapDisplaySelect: Boolean := Value and $40 <> 0;
  var NewWndDisplayEnable: Boolean := Value and $20 <> 0;
  var NewBGAndWndTileDataSelect: Boolean := Value and $10 <> 0;
  var NewBGTileMapDisplaySelect: Boolean := Value and $8 <> 0;
  var NewTallSpriteMode: Boolean := Value and $4 <> 0;
  var NewSpriteDisplayEnable: Boolean := Value and $2 <> 0;
  var NewBGWndDisplayPriority: Boolean := Value and $1 <> 0;

  if FLCDEnabled <> NewLCDEnable then
  begin
    Line := 0;
    ModeClock := 0;
    FPipeline.Dot := 0;
    FPipeline.Count := 0;
    FPipeline.SpriteCount := 0;
    FWindowLine := 0;
    FWindowTriggered := False;
    FSTATLineActive := False;
    if NewLCDEnable then
    begin
      // LCD enable starts four base clocks into the first scanline.
      FPipeline.Dot := 4;
      FPipeline.FirstLine := True;
      FWindowTriggered := WindowY = 0;
      FCurrentMode := TGPUMode.HBlank;
    end
    else
    begin
      FPipeline.FirstLine := False;
      FCurrentMode := TGPUMode.HBlank;
      FillChar(Screen, SizeOf(Screen), 0);
    end;
  end;

  FLCDEnabled := NewLCDEnable;
  FWindowTileMapHigh := NewWndTileMapDisplaySelect;
  FWindowEnabled := NewWndDisplayEnable;
  FUnsignedTileData := NewBGAndWndTileDataSelect;
  FBackgroundTileMapHigh := NewBGTileMapDisplaySelect;
  FTallSprites := NewTallSpriteMode;
  FSpritesEnabled := NewSpriteDisplayEnable;
  FBackgroundEnabled := NewBGWndDisplayPriority;
end;

procedure TGBVideo.SetLCDStatus(Value: Integer);
begin
  // bit 6 is ly==lyc enable
  FLYCInterruptEnabled := (Value and $40) <> 0;
  // bit 5 is mode 2 enable
  FOAMInterruptEnabled := (Value and $20) <> 0;
  // bit 4 is mode 1 enable
  FVBlankInterruptEnabled := (Value and $10) <> 0;
  // bit 3 is mode 0 enable
  FHBlankInterruptEnabled := (Value and $8) <> 0;
end;

procedure TGBVideo.ProcessLCDStatus;
begin
  if not FLCDEnabled then
  begin
    FSTATLineActive := False;
    Exit;
  end;

  FLineMatchesLYC := Line = LYC;
  // from The Cycle Accurate Game Boy Document (TCAGBD.pdf)
  if (FLineMatchesLYC and FLYCInterruptEnabled) or
    ((Ord(FCurrentMode) = 0) and FHBlankInterruptEnabled) or
    ((Ord(FCurrentMode) = 2) and FOAMInterruptEnabled) or
    ((Ord(FCurrentMode) = 1) and (FOAMInterruptEnabled or FVBlankInterruptEnabled)) then
  begin
    if not FSTATLineActive then
    begin
      FSTATLineActive := True;
      FInterruptManager.RaiseInterruptByIndex(3); // LCDC_STATUS
    end;
  end
  else
    FSTATLineActive := False;
end;

function TGBGPU.ReadVRAM(Address: Integer): Byte;
begin
  Result := VRAM[Address and $1FFF];
end;

procedure TGBGPU.WriteVRAM(Address: Integer; Value: Byte);
begin
  Address := Address and $1FFF;
  VRAM[Address] := Value;
  if Address <= $17FF then
    UpdateTile(Address);
end;

function TGBGPU.CanAccessVRAM: Boolean;
begin
  Result := inherited CanAccessVRAM;
end;

{ TGBGPU }

procedure TGBGPU.BuildSprite(Address, Value: Integer);
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
      end;
  end;
end;

constructor TGBGPU.Create(Callback: TDrawCallback);
begin
  inherited Create(Callback, TGBInterruptManager.Instance);

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
    end;
end;

procedure TGBGPU.Step(Cycle: Integer);
begin
  inherited;
end;

procedure TGBGPU.UpdateTile(Address: Integer);
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
    if (VRAM[Address] and Sx) <> 0 then
      Tmp1 := 1
    else
      Tmp1 := 0;
    if (VRAM[Address + 1] and Sx) <> 0 then
      Tmp2 := 2
    else
      Tmp2 := 0;
    var Value := Tmp1 or Tmp2;
    TileSet[Tile][Y][i] := Value;
  end;
end;

procedure TGBGPU.SerializeState(State: TStateArchive);
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
  State.Field(TileSet, SizeOf(TileSet));
  State.Field(Screen, SizeOf(Screen));
  State.Field(BackgroundPalette, SizeOf(BackgroundPalette));
  State.Field(SpritePalette, SizeOf(SpritePalette));
  State.Field(Palette, SizeOf(Palette));
  State.Field(SpriteList, SizeOf(SpriteList));
end;

end.

