unit Saturn.VDP2;

interface

uses
  System.SysUtils, System.Classes, System.UITypes, Saturn.VDP1, Core.Snapshots;

type
  TVDP2RasterSync = procedure of object;

  TSaturnVDP2 = class
  private
    type
      TRotationLatch = record
        X, Y, K: Int64; // 16 fractional bits; K includes KTAOF
      end;

      TRotationRender = record
        Xsp, Ysp, DX, DY, Xp, KX, KY: Double;
        Yp: array[0..4] of Double;
        CoefficientDX: Int64;
        Control, FrameX, FrameY, FrameDX, FrameDY: Integer;
      end;

      TBackgroundLine = record
        Config, Kind, MosaicWidth, ColumnWidth, ColumnStride, ColumnSlot: Integer;
        ColumnTable, ZoomX: Cardinal;
        ScrollX, ScrollY: Int64;
        ColumnScroll: Boolean;
      end;

      TBackgroundSpan = record
        FirstX, LastX: Integer;
        Dots: array[0..7] of TAlphaColor; // zero denotes a transparent dot
      end;

      TTileName = record
        Valid: Boolean;
        X, Y, Parameter, Character, Pal, Flip: Integer;
      end;
  private
    FRotation: array[0..1] of TRotationLatch;
    FRotationLine: Integer;
    FBackgroundLine: array[0..4] of TBackgroundLine;
    FTileName: array[0..4] of TTileName;
    FBackgroundSpan: array[0..4] of TBackgroundSpan;
    // Derived once per RenderLine; rebuilt after writes/restores, not serialized.
    FRotationRender: array[0..1] of TRotationRender;
    FCoefficientPerDot, FCoefficientCRAM: Boolean;
    FCoefficientBanks: array[0..3] of Boolean;
    FSpriteWindow: Boolean;
    FCoefficientColor: array[0..1] of Integer;
    FLastParameter: Integer;
    FVRAM: array[0..$7FFFF] of Byte;
    FCRAM: array[0..$FFF] of Byte;
    FPaletteColors: array[0..2047] of TAlphaColor;
    FPaletteValid: array[0..2047] of Boolean;
    FPaletteMode: Integer;
    FWidth, FHeight, FScanHeight: Integer;
    FWindowControls: array[0..7] of Byte;
    FWindowStart, FWindowEnd: array[0..1] of Integer;
    FWindowLine: array[0..1] of Boolean;
    FOffsetsDirty: Boolean;
    FOffsetBank: array[0..6] of ShortInt;
    FOffsetColors: array[0..1, 0..2, 0..255] of Cardinal;
    FRegisters: array[0..255] of Word;
    FLine, FHorizontal: Integer;
    FRasterSync: TVDP2RasterSync;
    FVBlank, FHBlank, FField, FPAL: Boolean;
    procedure PrepareRotationLine(Line: Integer; FramebufferRotation: Boolean);
    procedure PrepareRotationRender;
    function CoefficientBank(Address: Cardinal): Boolean;
    function VRWord(Address: Cardinal): Word; inline;
    function VRLong(Address: Cardinal): Cardinal; inline;
    function Reg(Address: Integer): Word; inline;
    function Palette(Index: Integer): TAlphaColor;
    function PaletteMSB(Index: Integer): Boolean;
    function Dot(Base: Cardinal; Pixel, Kind, PaletteBase: Integer; Opaque: Boolean; out Color: TAlphaColor): Boolean;
    function Coefficient(Parameter, X: Integer; out Value: Double): Boolean;
    function RotationPoint(Layer, X, Y: Integer; out RX, RY, Parameter: Integer): Boolean;
    procedure UpdateResolution;
    procedure RemapCRAM(OldMode: Integer);
    procedure PrepareWindows(Line: Integer);
    procedure PrepareBackgroundLine(Line: Integer);
    function Background(Layer, X, Y: Integer; out Color: TAlphaColor): Boolean;
    function DecodeBackgroundSpan(Layer, X: Integer; Base: Cardinal; Pixel, Step, Count, Kind, PaletteBase: Integer; Opaque: Boolean; out Color: TAlphaColor): Boolean;
    function SpritePixel(X, Y: Integer; VDP1: TSaturnVDP1): Word;
    function WindowVisible(Layer, X, Y: Integer): Boolean;
    procedure PrepareColorOffsets;
    function ColorOffset(Color: TAlphaColor; Layer: Integer): TAlphaColor;
  public
    constructor Create(PAL: Boolean);
    procedure Reset(Cold: Boolean = True);
    function ReadVRAM(Address: Cardinal; Size: Integer): Cardinal;
    procedure WriteVRAM(Address, Value: Cardinal; Size: Integer);
    function ReadCRAM(Address: Cardinal; Size: Integer): Cardinal;
    procedure WriteCRAM(Address, Value: Cardinal; Size: Integer);
    function ReadRegister(Address: Cardinal; Size: Integer): Cardinal;
    procedure WriteRegister(Address, Value: Cardinal; Size: Integer);
    procedure SetRaster(Line, Horizontal: Integer; HBlank, VBlank: Boolean); inline;
    procedure NewField;
    procedure LatchLine(Line: Integer; FramebufferRotation: Boolean);
    procedure RenderLine(Line: Integer; VDP1: TSaturnVDP1; var Pixels: TArray<TAlphaColor>; Offset: Integer; Latched: Boolean = False);
    function Width: Integer; inline;
    function Height: Integer; inline;
    function Clock352: Boolean;
    function ScanHeight: Integer;
    function FieldLines: Integer; inline;
    property Field: Boolean read FField;
    property RasterSync: TVDP2RasterSync read FRasterSync write FRasterSync;
    procedure SerializeState(Archive: TStateArchive; Extended: Boolean = True);
  end;

function SaturnRGB555(Value: Word): TAlphaColor;

implementation

uses
  System.Math;

{$Q+}{$R+}

var
  RGB555Colors: array[0..32767] of TAlphaColor;

// Same negative-fraction rule as Math.Floor, without a second Frac call.
function FloorCoordinate(Value: Double): Integer; inline;
begin
  var Whole := Trunc(Value);
  Result := Integer(Whole);
  if Value < Whole then
    Dec(Result);
end;

function SignedParameter(Value: Cardinal; Bits: Integer; DropLowSix: Boolean = False): Integer;
begin
  Value := Value and ((Cardinal(1) shl Bits) - 1);
  if DropLowSix then
    Value := Value and not Cardinal(63);
  Result := Integer(Value);
  if Value and (Cardinal(1) shl (Bits - 1)) <> 0 then
    Dec(Result, Cardinal(1) shl Bits);
end;

function SaturnRGB555(Value: Word): TAlphaColor;
begin
  Result := RGB555Colors[Value and $7FFF];
end;

procedure InitializeRGB555;
begin
  for var Value := 0 to 32767 do
  begin
    var R: Cardinal := Value and 31;
    var G: Cardinal := (Value shr 5) and 31;
    var B: Cardinal := (Value shr 10) and 31;
    RGB555Colors[Value] := $FF000000 or (((R shl 3) or (R shr 2)) shl 16) or (((G shl 3) or (G shr 2)) shl 8) or ((B shl 3) or (B shr 2));
  end;
end;

constructor TSaturnVDP2.Create(PAL: Boolean);
begin
  inherited Create;
  FPAL := PAL;
  Reset;
end;

procedure TSaturnVDP2.Reset(Cold: Boolean);
begin
  if Cold then
  begin
    FillChar(FVRAM, SizeOf(FVRAM), 0);
    FillChar(FCRAM, SizeOf(FCRAM), 0);
  end;
  FPaletteMode := 0;
  FillChar(FPaletteValid, SizeOf(FPaletteValid), 0);
  FOffsetsDirty := True;
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  UpdateResolution;
  FRegisters[$78 div 2] := 1;
  FRegisters[$7C div 2] := 1;
  FRegisters[$88 div 2] := 1;
  FRegisters[$8C div 2] := 1;
  FLine := 0;
  FRotationLine := -1;
  FillChar(FRotation, SizeOf(FRotation), 0);
  FHorizontal := 0;
  FVBlank := False;
  FHBlank := False;
  FField := False;
end;

function TSaturnVDP2.Reg(Address: Integer): Word;
begin
  Result := FRegisters[(Address and $1FF) div 2];
end;

function TSaturnVDP2.VRWord(Address: Cardinal): Word;
begin
  Result := (Word(FVRAM[Address and $7FFFF]) shl 8) or FVRAM[(UInt64(Address) + 1) and $7FFFF];
end;

function TSaturnVDP2.VRLong(Address: Cardinal): Cardinal;
begin
  Result := (Cardinal(VRWord(Address)) shl 16) or VRWord(Cardinal((UInt64(Address) + 2) and $FFFFFFFF));
end;

function TSaturnVDP2.ReadVRAM(Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := 0;
  for var i := 0 to Size - 1 do
    Result := (Result shl 8) or FVRAM[(UInt64(Address) + Cardinal(i)) and $7FFFF];
end;

procedure TSaturnVDP2.WriteVRAM(Address, Value: Cardinal; Size: Integer);
begin
  for var i := 0 to Size - 1 do
    FVRAM[(UInt64(Address) + Cardinal(i)) and $7FFFF] := (Value shr ((Size - i - 1) * 8)) and $FF;
end;

function TSaturnVDP2.ReadCRAM(Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := 0;
  for var i := 0 to Size - 1 do
    Result := (Result shl 8) or FCRAM[(UInt64(Address) + Cardinal(i)) and $FFF];
end;

procedure TSaturnVDP2.WriteCRAM(Address, Value: Cardinal; Size: Integer);
begin
  for var i := 0 to Size - 1 do
  begin
    var A: Integer := (UInt64(Address) + Cardinal(i)) and $FFF;
    var B: Byte := (Value shr ((Size - i - 1) * 8)) and $FF;
    FCRAM[A] := B;
    var Mode := (Reg($0E) shr 12) and 3;
    var Entry := A shr 1;
    if Mode = 2 then
      Entry := A shr 2
    else if Mode = 0 then
      Entry := (A and $7FF) shr 1;
    FPaletteValid[Entry] := False;
    if (Reg($0E) shr 12) and 3 = 0 then
    begin
      FCRAM[A and $7FF] := B;
      FCRAM[(A and $7FF) or $800] := B;
    end;
  end;
end;

{$Q-}{$R-}
// Private pixel paths use masked hardware indices; public bus accesses stay checked.
function TSaturnVDP2.Palette(Index: Integer): TAlphaColor;
begin
  var Mode := FPaletteMode;
  Index := Index and $7FF;
  if Mode and 1 = 0 then
    Index := Index and $3FF;
  if not FPaletteValid[Index] then
  begin
    if Mode = 2 then
    begin
      var A := Index * 4;
      FPaletteColors[Index] := $FF000000 or (Cardinal(FCRAM[A + 3]) shl 16) or
        (Cardinal(FCRAM[A + 2]) shl 8) or FCRAM[A + 1];
    end
    else
    begin
      var A := Index * 2;
      FPaletteColors[Index] := SaturnRGB555((Word(FCRAM[A]) shl 8) or FCRAM[A + 1]);
    end;
    FPaletteValid[Index] := True;
  end;
  Result := FPaletteColors[Index];
end;

// Private pixel paths use masked hardware indices; public bus accesses stay checked.
function TSaturnVDP2.PaletteMSB(Index: Integer): Boolean;
begin
  if (Reg($0E) shr 12) and 3 = 2 then
    Result := FCRAM[(Index * 4) and $FFF] and $80 <> 0
  else
  begin
    var Address: Integer := (Index * 2) and $FFF;
    if (Reg($0E) shr 12) and 3 = 0 then
      Address := Address and $7FF;
    Result := FCRAM[Address] and $80 <> 0;
  end;
end;
{$Q+}{$R+}

{$Q-}{$R-}

// Private pixel paths use masked hardware indices; public bus accesses stay checked.

function TSaturnVDP2.Dot(Base: Cardinal; Pixel, Kind, PaletteBase: Integer; Opaque: Boolean; out Color: TAlphaColor): Boolean;
begin
  var Value: Cardinal;
  case Kind of
    0:
      begin
        Value := FVRAM[(Base + Cardinal(Pixel div 2)) and $7FFFF];
        if not Odd(Pixel) then
          Value := Value shr 4
        else
          Value := Value and 15;
      end;
    1:
      Value := FVRAM[(Base + Cardinal(Pixel)) and $7FFFF];
    2, 3:
      Value := VRWord(Base + Cardinal(Pixel * 2));
    4:
      Value := VRLong(Base + Cardinal(Pixel * 4));
  else
    Exit(False);
  end;

  if not Opaque then
  begin
    if (Kind < 3) and (Value = 0) then
      Exit(False);

    if (Kind = 3) and (Value and $8000 = 0) then
      Exit(False);

    if (Kind = 4) and (Value and $80000000 = 0) then
      Exit(False);
  end;

  case Kind of
    0:
      Color := Palette(PaletteBase + Integer(Value and 15));
    1:
      Color := Palette((PaletteBase and not 255) + Integer(Value and 255));
    2:
      Color := Palette((PaletteBase and not 2047) + Integer(Value and 2047));
    3:
      Color := SaturnRGB555(Value);
    4:
      Color := $FF000000 or ((Value and $FF) shl 16) or (Value and $FF00) or ((Value shr 16) and $FF);
  end;
  Result := True;
end;

{$Q+}{$R+}

procedure TSaturnVDP2.PrepareWindows(Line: Integer);
begin
  for var Layer := 0 to 7 do
    FWindowControls[Layer] := (Reg($D0 + (Layer div 2) * 2) shr ((Layer and 1) * 8)) and $FF;
  var Shift := Ord(FWidth <= 352);
  var WY := Line;
  if FHeight > 256 then
    WY := WY div 2;
  var YShift := Ord(FHeight > 256);
  for var W := 0 to 1 do
  begin
    FWindowStart[W] := Reg($C0 + W * 8) shr Shift;
    FWindowEnd[W] := Reg($C4 + W * 8) shr Shift;
    var Table: Cardinal := (Cardinal(Reg($D8 + W * 4)) shl 16) or Reg($DA + W * 4);
    if Table and $80000000 <> 0 then
    begin
      Table := (Table and $7FFFE) * 2 + Cardinal(WY * 4);
      FWindowStart[W] := VRWord(Table) shr Shift;
      FWindowEnd[W] := VRWord(Table + 2) shr Shift;
    end;
    FWindowLine[W] := (WY >= Integer(Reg($C2 + W * 8) shr YShift)) and
      (WY <= Integer(Reg($C6 + W * 8) shr YShift));
  end;
end;

// Private pixel paths use masked hardware indices; public bus accesses stay checked.
{$Q-}{$R-}
function TSaturnVDP2.WindowVisible(Layer, X, Y: Integer): Boolean;
begin
  var Control: Integer := FWindowControls[Layer];
  if Control and $2A = 0 then
    Exit(Control and $80 = 0);

  var Have: Boolean := False;
  var Visible: Boolean := Control and $80 <> 0;
  for var W := 0 to 2 do
    if (Control and (2 shl (W * 2)) <> 0) and ((W < 2) or (Layer <> 6)) then
    begin
      var Inside: Boolean;
      if W = 2 then
        Inside := FSpriteWindow
      else
      begin
        Inside := FWindowLine[W] and (X >= FWindowStart[W]) and (X <= FWindowEnd[W]);
      end;
      if Control and (1 shl (W * 2)) <> 0 then
        Inside := not Inside;
      if not Have then
        Visible := Inside
      else if Control and $80 <> 0 then
        Visible := Visible and Inside
      else
        Visible := Visible or Inside;
      Have := True;
    end;

  // WCTL selects the area processed by the window, not the area displayed.
  // Transparency removes that area; the color-calculation window inhibits
  // blending there, and the rotation window selects parameter B there.
  // With no window inputs, OR has no active pixels and AND is active everywhere.
  Result := not Visible;
end;
{$Q+}{$R+}

procedure TSaturnVDP2.PrepareRotationLine(Line: Integer; FramebufferRotation: Boolean);
begin
  if (Reg($20) and $30 = 0) and not FramebufferRotation then
    Exit;

  if (FRotationLine = Line) and (Line <> 0) and (Reg($B2) and $707 = 0) then
    Exit;

  var Y := Line;
  var Previous := FRotationLine;
  if Height > 256 then
  begin
    Y := Y div 2;
    if Previous >= 0 then
      Previous := Previous div 2;
  end;
  var First := (FRotationLine < 0) or (Line = 0) or (Line < FRotationLine);
  var Steps := Max(0, Y - Previous);
  if First then
    Steps := Y;
  var Table := (((Cardinal(Reg($BC) and 7) shl 16) or Reg($BE)) * 2) and $7FF7C;
  for var P := 0 to 1 do
  begin
    var Base := Table + Cardinal(P * $80);
    var Control := (Reg($B2) shr (P * 8)) and 7;
    var DX := SignedParameter(VRLong(Base + $0C), 19, True);
    var DY := SignedParameter(VRLong(Base + $10), 19, True);
    var DK := SignedParameter(VRLong(Base + $58), 26, True);
    if First or (Control and 1 <> 0) then
      FRotation[P].X := SignedParameter(VRLong(Base), 29, True)
    else
      Inc(FRotation[P].X, Int64(DX) * Steps);
    if First or (Control and 2 <> 0) then
      FRotation[P].Y := SignedParameter(VRLong(Base + 4), 29, True)
    else
      Inc(FRotation[P].Y, Int64(DY) * Steps);
    if First or (Control and 4 <> 0) then
      FRotation[P].K := (Int64((Reg($B6) shr (P * 8)) and 7) shl 32) + (VRLong(Base + $54) and $FFFFFFC0)
    else
      Inc(FRotation[P].K, Int64(DK) * Steps);

    // A direct render/import beginning mid-field has no preceding latch.
    if First then
    begin
      Inc(FRotation[P].X, Int64(DX) * Steps);
      Inc(FRotation[P].Y, Int64(DY) * Steps);
      Inc(FRotation[P].K, Int64(DK) * Steps);
    end;
    FRotation[P].X := SignedParameter(Cardinal(FRotation[P].X and $1FFFFFFF), 29);
    FRotation[P].Y := SignedParameter(Cardinal(FRotation[P].Y and $1FFFFFFF), 29);
    FRotation[P].K := FRotation[P].K and $7FFFFFFFF;
  end;
  FRegisters[$B2 div 2] := Reg($B2) and not $707;
  FRotationLine := Line;
end;

function TSaturnVDP2.CoefficientBank(Address: Cardinal): Boolean;
begin
  var Bank := Integer((Address shr 17) and 3);

  // An unsplit A/B bank takes the role of its first half.
  if Reg($0E) and (1 shl (8 + (Bank div 2))) = 0 then
    Bank := Bank and 2;
  Result := (Reg($0E) shr (Bank * 2)) and 3 = 1;
end;

procedure TSaturnVDP2.PrepareRotationRender;
begin
  FCoefficientCRAM := Reg($0E) and $8000 <> 0;
  FCoefficientPerDot := FCoefficientCRAM;
  for var Bank := 0 to 3 do
  begin
    FCoefficientBanks[Bank] := CoefficientBank(Cardinal(Bank) shl 17);
    FCoefficientPerDot := FCoefficientPerDot or FCoefficientBanks[Bank];
  end;
  var Base := (((Cardinal(Reg($BC) and 7) shl 16) or Reg($BE)) * 2) and $7FF7C;
  for var P := 0 to 1 do
  begin
    var Table := Base + Cardinal(P * $80);
    var Xst: Double := FRotation[P].X / 65536.0;
    var Yst: Double := FRotation[P].Y / 65536.0;
    var Zst: Double := SignedParameter(VRLong(Table + 8), 29, True) / 65536.0;
    var DX: Double := SignedParameter(VRLong(Table + $14), 19, True) / 65536.0;
    var DY: Double := SignedParameter(VRLong(Table + $18), 19, True) / 65536.0;
    var A: Double := SignedParameter(VRLong(Table + $1C), 20, True) / 65536.0;
    var B: Double := SignedParameter(VRLong(Table + $20), 20, True) / 65536.0;
    var C: Double := SignedParameter(VRLong(Table + $24), 20, True) / 65536.0;
    var D: Double := SignedParameter(VRLong(Table + $28), 20, True) / 65536.0;
    var E: Double := SignedParameter(VRLong(Table + $2C), 20, True) / 65536.0;
    var F: Double := SignedParameter(VRLong(Table + $30), 20, True) / 65536.0;
    var PX: Double := SmallInt(VRWord(Table + $34) shl 2) div 4;
    var PY: Double := SmallInt(VRWord(Table + $36) shl 2) div 4;
    var PZ: Double := SmallInt(VRWord(Table + $38) shl 2) div 4;
    var CX: Double := SmallInt(VRWord(Table + $3C) shl 2) div 4;
    var CY: Double := SmallInt(VRWord(Table + $3E) shl 2) div 4;
    var CZ: Double := SmallInt(VRWord(Table + $40) shl 2) div 4;
    var MX: Double := SignedParameter(VRLong(Table + $44), 30, True) / 65536.0;
    var MY: Double := SignedParameter(VRLong(Table + $48), 30, True) / 65536.0;
    var KX: Double := SignedParameter(VRLong(Table + $4C), 24, False) / 65536.0;
    var KY: Double := SignedParameter(VRLong(Table + $50), 24, False) / 65536.0;
    FRotationRender[P].Xsp := A * (Xst - PX) + B * (Yst - PY) + C * (Zst - PZ);
    FRotationRender[P].Ysp := D * (Xst - PX) + E * (Yst - PY) + F * (Zst - PZ);
    FRotationRender[P].DX := A * DX + B * DY;
    FRotationRender[P].DY := D * DX + E * DY;
    FRotationRender[P].Xp := A * (PX - CX) + B * (PY - CY) + C * (PZ - CZ) + CX + MX;
    FRotationRender[P].Yp[0] := D * (PX - CX);
    FRotationRender[P].Yp[1] := E * (PY - CY);
    FRotationRender[P].Yp[2] := F * (PZ - CZ);
    FRotationRender[P].Yp[3] := CY;
    FRotationRender[P].Yp[4] := MY;
    FRotationRender[P].KX := KX;
    FRotationRender[P].KY := KY;
    FRotationRender[P].Control := (Reg($B4) shr (P * 8)) and $1F;
    FRotationRender[P].CoefficientDX := SignedParameter(VRLong(Table + $5C), 26, True);
    FRotationRender[P].FrameX := SignedParameter(Cardinal((FRotation[P].X shr 7) and $FFFFF), 20);
    FRotationRender[P].FrameY := SignedParameter(Cardinal((FRotation[P].Y shr 7) and $FFFFF), 20);
    FRotationRender[P].FrameDX := SignedParameter(VRLong(Table + $14) shr 7, 12);
    FRotationRender[P].FrameDY := SignedParameter(VRLong(Table + $18) shr 7, 12);
  end;
end;

{$Q-}{$R-}

// Private pixel paths use masked hardware indices; public bus accesses stay checked.
function TSaturnVDP2.Coefficient(Parameter, X: Integer; out Value: Double): Boolean;
begin
  FCoefficientColor[Parameter] := -1;
  var Control := FRotationRender[Parameter].Control;
  var Index := FRotation[Parameter].K;
  if FCoefficientPerDot then
    Inc(Index, FRotationRender[Parameter].CoefficientDX * X);
  var Size: Integer := 4;
  if Control and 2 <> 0 then
    Size := 2;

  // A negative delta may take the coefficient index below zero. Address
  // arithmetic wraps on the VRAM address pins; do it before narrowing to
  // Cardinal so checked builds do not overflow on a valid negative index.
  var Address: Cardinal := Cardinal(((Index shr 16) * Size) and $7FFFF);
  var Raw: Cardinal;
  if FCoefficientCRAM then
  begin
    Raw := (Cardinal(FCRAM[$800 + (Address and $7FF)]) shl 8) or FCRAM[$800 + ((UInt64(Address) + 1) and $7FF)];
    if Size = 4 then
      Raw := (Raw shl 16) or (Cardinal(FCRAM[$800 + ((UInt64(Address) + 2) and $7FF)]) shl 8) or FCRAM[$800 + ((Address + 3) and $7FF)];
  end
  else
  begin
    if FCoefficientPerDot and not FCoefficientBanks[(Address shr 17) and 3] then
      Raw := 0
    else if Size = 2 then
      Raw := VRWord(Address)
    else
      Raw := VRLong(Address);
  end;
  if Size = 2 then
  begin
    Result := Raw and $8000 = 0;
    var Signed: Integer := Raw and $7FFF;
    if Signed and $4000 <> 0 then
      Dec(Signed, $8000);
    var Divisor: Double := 1024;
    if (Control shr 2) and 3 = 3 then
      Divisor := 4;
    Value := Signed / Divisor;
  end
  else
  begin
    if Control and $10 <> 0 then
      FCoefficientColor[Parameter] := (Raw shr 24) and $7F;
    Result := Raw and $80000000 = 0;
    var Signed: Integer := Raw and $FFFFFF;
    if Signed and $800000 <> 0 then
      Dec(Signed, $1000000);
    var Divisor: Double := 65536;
    if (Control shr 2) and 3 = 3 then
      Divisor := 256;
    Value := Signed / Divisor;
  end;
end;
{$Q+}{$R+}

{$Q-}{$R-}
// Private pixel paths use masked hardware indices; public bus accesses stay checked.

function TSaturnVDP2.RotationPoint(Layer, X, Y: Integer; out RX, RY, Parameter: Integer): Boolean;
begin
  if (Layer = 0) and (Reg($20) and $20 <> 0) and (Reg($B4) and $11 = $11) then
  begin
    var Ignored: Double;
    Coefficient(0, X, Ignored);
  end;
  Parameter := 0;
  var Mode: Integer := Reg($B0) and 3;
  if (Layer = 0) or (Mode = 1) then
    Parameter := 1
  else if (Mode = 3) and not WindowVisible(6, X, Y) then
    Parameter := 1;
  var K: Double := 0;
  if (Mode = 2) and (Layer = 4) and (Reg($B4) and 1 <> 0) and not Coefficient(0, X, K) then
    Parameter := 1;
  var Control := FRotationRender[Parameter].Control;
  if (Control and 1 <> 0) and not Coefficient(Parameter, X, K) then
    Exit(False);

  FLastParameter := Parameter;
  var KX := FRotationRender[Parameter].KX;
  var KY := FRotationRender[Parameter].KY;
  if Control and 1 <> 0 then
    case (Control shr 2) and 3 of
      0:
        begin
          KX := K;
          KY := K;
        end;
      1:
        KX := K;
      2:
        KY := K;
    end;
  var ScreenX: Double := X;
  var ViewX := FRotationRender[Parameter].Xp;

  // Coefficient mode 3 replaces the transformed viewpoint Xp only. The
  // scaled screen coordinate still contributes to the displayed X position.
  if (Control and 1 <> 0) and ((Control shr 2) and 3 = 3) then
    ViewX := K;
  RX := FloorCoordinate(KX * (FRotationRender[Parameter].Xsp + FRotationRender[Parameter].DX * ScreenX) + ViewX);

  // Keep the original addition order so floor sees the same rounding.
  RY := FloorCoordinate(KY * (FRotationRender[Parameter].Ysp + FRotationRender[Parameter].DY * ScreenX) +
    FRotationRender[Parameter].Yp[0] + FRotationRender[Parameter].Yp[1] +
    FRotationRender[Parameter].Yp[2] + FRotationRender[Parameter].Yp[3] + FRotationRender[Parameter].Yp[4]);
  Result := True;
end;
{$Q+}{$R+}

procedure TSaturnVDP2.PrepareBackgroundLine(Line: Integer);
begin
  for var Layer := 0 to 4 do
  begin
    var Y := Line;
    FBackgroundLine[Layer].MosaicWidth := 1;
    FBackgroundLine[Layer].ColumnScroll := False;
    FTileName[Layer].Valid := False;
    FBackgroundSpan[Layer].LastX := -1;
    var Config: Integer;
    var Kind: Integer;
    if Layer < 2 then
    begin
      Config := (Reg($28) shr (Layer * 8)) and $FF;
      Kind := (Config shr 4) and 7;
    end
    else if Layer < 4 then
    begin
      Config := (Reg($2A) shr ((Layer - 2) * 4)) and 3;
      Kind := (Config shr 1) and 1;
    end
    else
    begin
      Config := (Reg($2A) shr 8) and $FF;
      Kind := (Config shr 4) and 7;
    end;
    var ScrollX, ScrollY: Int64;
    var ZoomX, ZoomY: Cardinal;
    if Layer < 2 then
    begin
      var B: Integer := $70 + Layer * $10;
      ScrollX := (Int64(Reg(B) and $7FF) shl 16) or (Reg(B + 2) and $FF00);
      ScrollY := (Int64(Reg(B + 4) and $7FF) shl 16) or (Reg(B + 6) and $FF00);
      ZoomX := (Cardinal(Reg(B + 8) and 7) shl 16) or Reg(B + 10);
      ZoomY := (Cardinal(Reg(B + 12) and 7) shl 16) or Reg(B + 14);
      var LineControl: Integer := (Reg($9A) shr (Layer * 8)) and $FF;
      var Count: Integer := Ord(LineControl and 2 <> 0) + Ord(LineControl and 4 <> 0) + Ord(LineControl and 8 <> 0);
      FBackgroundLine[Layer].ColumnScroll := (LineControl and 1 <> 0) and (Reg($22) and (1 shl Layer) = 0);
      FBackgroundLine[Layer].ColumnTable := ((Cardinal(Reg($9C) and 7) shl 16) or Reg($9E)) * 2;
      FBackgroundLine[Layer].ColumnStride := Ord(Reg($9A) and 1 <> 0) + Ord(Reg($9A) and $100 <> 0);
      FBackgroundLine[Layer].ColumnWidth := 8;
      if Config and 3 = 1 then
        FBackgroundLine[Layer].ColumnWidth := 16;
      FBackgroundLine[Layer].ColumnSlot := Ord((Layer = 1) and (Reg($9A) and 1 <> 0));
      if Count > 0 then
      begin
        var Table: Cardinal := ((Cardinal(Reg($A0 + Layer * 4) and 7) shl 16) or Reg($A2 + Layer * 4)) * 2;
        Inc(Table, Cardinal((Y shr ((LineControl shr 4) and 3)) * Count * 4));
        if LineControl and 2 <> 0 then
        begin
          Inc(ScrollX, VRLong(Table) and $07FFFF00);
          Inc(Table, 4);
        end;
        if LineControl and 4 <> 0 then
        begin
          Inc(ScrollY, VRLong(Table) and $07FFFF00);
          Inc(Table, 4);

          // The table supplies an absolute vertical coordinate for the first
          // line in each group; only intervening lines add coordinate increments.
          Y := Y and ((1 shl ((LineControl shr 4) and 3)) - 1);
        end;
        if LineControl and 8 <> 0 then
          ZoomX := VRLong(Table) and $7FFFF;
      end;
    end
    else
    begin
      ScrollX := Int64(Reg($90 + (Layer - 2) * 4) and $7FF) shl 16;
      ScrollY := Int64(Reg($92 + (Layer - 2) * 4) and $7FF) shl 16;
      ZoomX := $10000;
      ZoomY := $10000;
    end;
    if Reg($22) and (1 shl Layer) <> 0 then
    begin
      var MX: Integer := ((Reg($22) shr 8) and 15) + 1;
      var MY: Integer := ((Reg($22) shr 12) and 15) + 1;
      FBackgroundLine[Layer].MosaicWidth := MX;
      Y := Y - Y mod MY;
    end;
    FBackgroundLine[Layer].Config := Config;
    FBackgroundLine[Layer].Kind := Kind;
    FBackgroundLine[Layer].ScrollX := ScrollX;
    FBackgroundLine[Layer].ScrollY := ScrollY + Int64(Y) * ZoomY;
    FBackgroundLine[Layer].ZoomX := ZoomX;
  end;
end;

{$Q-}{$R-}
// Private pixel paths use masked hardware indices; public bus accesses stay checked.
function TSaturnVDP2.DecodeBackgroundSpan(Layer, X: Integer; Base: Cardinal; Pixel, Step, Count, Kind, PaletteBase: Integer; Opaque: Boolean; out Color: TAlphaColor): Boolean;
begin
  FBackgroundSpan[Layer].FirstX := X;
  FBackgroundSpan[Layer].LastX := X + Count - 1;
  for var i := 0 to Count - 1 do
  begin
    var C: TAlphaColor;
    if Dot(Base, Pixel + i * Step, Kind, PaletteBase, Opaque, C) then
      FBackgroundSpan[Layer].Dots[i] := C
    else
      FBackgroundSpan[Layer].Dots[i] := 0;
  end;
  Color := FBackgroundSpan[Layer].Dots[0];
  Result := Color <> 0;
end;

function TSaturnVDP2.Background(Layer, X, Y: Integer; out Color: TAlphaColor): Boolean;
begin
  Result := False;

  // A scanline is traversed left-to-right and VRAM/register writes are
  // synchronized with its renderer. Windows remain a per-dot decision.
  if X <= FBackgroundSpan[Layer].LastX then
  begin
    Color := FBackgroundSpan[Layer].Dots[X - FBackgroundSpan[Layer].FirstX];
    Result := (Color <> 0) and WindowVisible(Layer, X, Y);
    Exit;
  end;

  var Enabled: Integer := 1 shl Layer;
  if (Layer = 0) and (Reg($20) and $20 <> 0) then
    Enabled := $20;
  if (Layer in [1, 2, 3]) and (Reg($20) and $20 <> 0) then
    Exit;

  if (Reg($20) and Enabled = 0) or not WindowVisible(Layer, X, Y) then
    Exit;

  var ScreenX: Integer := X;
  var ScreenY: Integer := Y;
  var Opaque: Boolean := Reg($20) and ($100 shl Layer) <> 0;
  var Config := FBackgroundLine[Layer].Config;
  var Kind := FBackgroundLine[Layer].Kind;
  var Parameter: Integer := 0;
  var Rotation: Boolean := (Layer = 4) or ((Layer = 0) and (Reg($20) and $20 <> 0));
  var Cacheable := not Rotation and (FBackgroundLine[Layer].ZoomX = $10000) and
    (FBackgroundLine[Layer].MosaicWidth = 1) and not FBackgroundLine[Layer].ColumnScroll;
  if Rotation then
  begin
    if not RotationPoint(Layer, ScreenX, ScreenY, X, Y, Parameter) then
      Exit;
  end
  else
  begin
    var Row := FBackgroundLine[Layer].ScrollY;
    if FBackgroundLine[Layer].ColumnScroll then
    begin
      var Entry := (X div FBackgroundLine[Layer].ColumnWidth) * FBackgroundLine[Layer].ColumnStride + FBackgroundLine[Layer].ColumnSlot;
      Inc(Row, VRLong(FBackgroundLine[Layer].ColumnTable + Cardinal(Entry * 4)) and $07FFFF00);
    end;
    if FBackgroundLine[Layer].MosaicWidth > 1 then
      X := X - X mod FBackgroundLine[Layer].MosaicWidth;
    X := Integer((FBackgroundLine[Layer].ScrollX + Int64(X) * FBackgroundLine[Layer].ZoomX) shr 16);
    Y := Integer(Row shr 16);
  end;

  var Offset: Integer := ((Reg($3C) shr (Layer * 4)) and 7);
  if Rotation then
    Offset := (Reg($3E) shr (Parameter * 4)) and 7;
  var PaletteOffset: Integer := ((Reg($E4) shr (Layer * 4)) and 7) * 256;
  if Layer = 4 then
    PaletteOffset := (Reg($E6) and 7) * 256;
  if ((Layer < 2) or (Layer = 4)) and (Config and 2 <> 0) then
  begin
    var BW: Integer := 512;
    if Config and 8 <> 0 then
      BW := 1024;
    var BH: Integer := 256;
    if Config and 4 <> 0 then
      BH := 512;
    if Rotation then
    begin
      var Over := (Reg($3A) shr (10 + Parameter * 4)) and 3;
      if (Over = 2) and ((X < 0) or (X >= BW) or (Y < 0) or (Y >= BH)) then
        Exit;

      if (Over = 3) and ((X < 0) or (X >= 512) or (Y < 0) or (Y >= 512)) then
        Exit;
    end;

    X := X and (BW - 1);
    Y := Y and (BH - 1);
    var Pal: Integer := ((Reg($2C) shr (Layer * 8)) and 7) * 256;
    if Layer = 4 then
      Pal := (Reg($2E) and 7) * 256;
    if Cacheable then
      Result := DecodeBackgroundSpan(Layer, ScreenX, Cardinal(Offset) * $20000, Y * BW + X, 1,
        8 - (X and 7), Kind, Pal + PaletteOffset, Opaque, Color)
    else
      Result := Dot(Cardinal(Offset) * $20000, Y * BW + X, Kind, Pal + PaletteOffset, Opaque, Color);
    Exit;
  end;
  var CellSize: Integer := 8;
  if Config and 1 <> 0 then
    CellSize := 16;
  var TileX := X shr (3 + Ord(CellSize = 16));
  var TileY := Y shr (3 + Ord(CellSize = 16));
  var Character, Pal, Flip: Integer;
  if FTileName[Layer].Valid and (FTileName[Layer].X = TileX) and
    (FTileName[Layer].Y = TileY) and (FTileName[Layer].Parameter = Parameter) then
  begin
    Character := FTileName[Layer].Character;
    Pal := FTileName[Layer].Pal;
    Flip := FTileName[Layer].Flip;
  end
  else
  begin
    var PN := Reg($30 + Layer * 2);
    var Words: Integer := 2;
    if PN and $8000 <> 0 then
      Words := 1;
    var PSize: Integer := (Reg($3A) shr (Layer * 2)) and 3;
    if Rotation then
      PSize := (Reg($3A) shr (8 + Parameter * 4)) and 3;
    var PagesX: Integer := 1;
    var PagesY: Integer := 1;
    if PSize <> 0 then
      PagesX := 2;
    if PSize and 2 <> 0 then
      PagesY := 2;
    var PlaneWidth: Integer := PagesX * 512;
    var PlaneHeight: Integer := PagesY * 512;
    var PlaneCount: Integer := 2;
    if Rotation then
      PlaneCount := 4;
    var OverPattern := False;
    if Rotation then
    begin
      var Over: Integer := (Reg($3A) shr (10 + Parameter * 4)) and 3;
      OverPattern := (Over = 1) and ((X < 0) or (X >= PlaneWidth * 4) or
        (Y < 0) or (Y >= PlaneHeight * 4));
      if (Over = 3) and ((X < 0) or (X >= 512) or (Y < 0) or (Y >= 512)) then
        Exit;

      if (Over = 2) and ((X < 0) or (X >= PlaneWidth * 4) or (Y < 0) or (Y >= PlaneHeight * 4)) then
        Exit;
    end;

    X := X and (PlaneWidth * PlaneCount - 1);
    Y := Y and (PlaneHeight * PlaneCount - 1);
    var Plane: Integer := (Y div PlaneHeight) * PlaneCount + X div PlaneWidth;
    X := X mod PlaneWidth;
    Y := Y mod PlaneHeight;
    var MapBase: Integer := $40 + Layer * 4;
    if Rotation then
      MapBase := $50 + Parameter * $10;
    var Map: Integer := (Reg(MapBase + (Plane div 2) * 2) shr ((Plane and 1) * 8)) and 63;
    Map := Map or (Offset shl 6);
    var Cells: Integer := 512 div CellSize;
    var PageBytes: Integer := Cells * Cells * Words * 2;
    var Address: Cardinal := Cardinal(Map and not (PagesX * PagesY - 1)) * Cardinal(PageBytes);
    Inc(Address, Cardinal(((Y div 512) * PagesX + X div 512) * PageBytes));
    Inc(Address, Cardinal(((Y mod 512) div CellSize * Cells + (X mod 512) div CellSize) * Words * 2));
    var Pattern := VRWord(Address);
    if OverPattern then
    begin
      // The screen-over name is always the one-word format, including its
      // supplement bits, even when the ordinary map uses two-word names.
      Pattern := Reg($B8 + Parameter * 2);
      Words := 1;
    end;
    Flip := 0;
    if Words = 2 then
    begin
      Character := VRWord(UInt64(Address) + 2) and $7FFF;
      Pal := Pattern and $7F;
      Flip := (Pattern shr 14) and 3;
    end
    else
    begin
      if Kind = 0 then
        Pal := ((Pattern shr 12) and 15) or ((PN shr 1) and $70)
      else
        Pal := (Pattern shr 8) and $70;
      if PN and $4000 = 0 then
      begin
        Character := Pattern and $3FF;
        Flip := (Pattern shr 10) and 3;
      end
      else
        Character := Pattern and $FFF;
      if CellSize = 8 then
      begin
        if PN and $4000 = 0 then
          Character := Character or ((PN and 31) shl 10)
        else
          Character := Character or ((PN and $1C) shl 10);
      end
      else
      begin
        var Supplement: Integer := PN and $1C;
        if PN and $4000 <> 0 then
          Supplement := Supplement and $10;
        Character := (Character shl 2) or (PN and 3) or (Supplement shl 10);
      end;
    end;
    FTileName[Layer].X := TileX;
    FTileName[Layer].Y := TileY;
    FTileName[Layer].Parameter := Parameter;
    FTileName[Layer].Character := Character;
    FTileName[Layer].Pal := Pal;
    FTileName[Layer].Flip := Flip;
    FTileName[Layer].Valid := True;
  end;
  var RemainingDots := 8 - (X and 7);
  X := X and (CellSize - 1);
  Y := Y and (CellSize - 1);
  if Flip and 1 <> 0 then
    X := CellSize - 1 - X;
  if Flip and 2 <> 0 then
    Y := CellSize - 1 - Y;
  var CellBytes: Integer := 32;
  case Kind of
    1:
      CellBytes := 64;
    2, 3:
      CellBytes := 128;
    4:
      CellBytes := 256;
  end;
  var Base: Cardinal := Cardinal(Character) * 32 + Cardinal(((Y div 8) * 2 + X div 8) * CellBytes);
  if Cacheable then
  begin
    var Step := 1;
    if Flip and 1 <> 0 then
      Step := -1;
    Result := DecodeBackgroundSpan(Layer, ScreenX, Base, (Y and 7) * 8 + (X and 7), Step,
      RemainingDots, Kind, Pal * 16 + PaletteOffset, Opaque, Color);
  end
  else
    Result := Dot(Base, (Y and 7) * 8 + (X and 7), Kind, Pal * 16 + PaletteOffset, Opaque, Color);
end;
{$Q+}{$R+}

procedure TSaturnVDP2.PrepareColorOffsets;
begin
  if not FOffsetsDirty then
    Exit;

  for var Layer := 0 to 6 do
  begin
    FOffsetBank[Layer] := -1;
    if Reg($110) and (1 shl Layer) <> 0 then
      FOffsetBank[Layer] := Ord(Reg($112) and (1 shl Layer) <> 0);
  end;
  for var Bank := 0 to 1 do
    for var Channel := 0 to 2 do
    begin
      var Delta := Integer(Reg($114 + Bank * 6 + Channel * 2) and $1FF);
      if Delta and $100 <> 0 then
        Dec(Delta, $200);
      for var Value := 0 to 255 do
        FOffsetColors[Bank, Channel, Value] := Cardinal(EnsureRange(Value + Delta, 0, 255)) shl ((2 - Channel) * 8);
    end;
  FOffsetsDirty := False;
end;

{$Q-}{$R-}
// Private pixel paths use masked hardware indices; public bus accesses stay checked.
function TSaturnVDP2.ColorOffset(Color: TAlphaColor; Layer: Integer): TAlphaColor;
begin
  var Bank := FOffsetBank[Layer];
  if Bank < 0 then
    Exit(Color);
  Result := $FF000000 or FOffsetColors[Bank, 0, (Color shr 16) and $FF] or
    FOffsetColors[Bank, 1, (Color shr 8) and $FF] or FOffsetColors[Bank, 2, Color and $FF];
end;

function TSaturnVDP2.SpritePixel(X, Y: Integer; VDP1: TSaturnVDP1): Word;
begin
  if not VDP1.RotationEnabled then
    Exit(VDP1.DisplayPixel(X, Y));
  // VDP2 manual 6.3: framebuffer rotation always uses parameter A's TV
  // coordinates/increments, independently of RPMD, matrices and coefficients.
  Result := VDP1.DisplayPixel(FloorCoordinate((Int64(FRotationRender[0].FrameX) + Int64(X) * FRotationRender[0].FrameDX) / 512.0),
    FloorCoordinate((Int64(FRotationRender[0].FrameY) + Int64(X) * FRotationRender[0].FrameDY) / 512.0));
end;

procedure TSaturnVDP2.RenderLine(Line: Integer; VDP1: TSaturnVDP1; var Pixels: TArray<TAlphaColor>; Offset: Integer; Latched: Boolean);
const
  ColorMasks: array[0..15] of Word = ($7FF, $7FF, $7FF, $7FF, $3FF, $7FF, $3FF, $1FF, $7F, $3F, $3F, $3F, $FF, $FF, $FF, $FF);
  PriorityShifts: array[0..15] of Byte = (14, 13, 14, 13, 13, 12, 12, 12, 7, 7, 6, 0, 7, 7, 6, 0);
  PriorityMasks: array[0..15] of Byte = (3, 7, 1, 3, 3, 7, 7, 7, 1, 1, 3, 0, 1, 1, 3, 0);
  RatioShifts: array[0..15] of Byte = (11, 11, 11, 11, 10, 11, 10, 9, 0, 6, 0, 6, 0, 6, 0, 6);
  RatioMasks: array[0..15] of Byte = (7, 3, 7, 3, 7, 1, 3, 7, 0, 1, 0, 3, 0, 1, 0, 3);
  BackgroundOrder: array[0..4] of Byte = (3, 2, 1, 0, 4);
begin
  var W := Width;
  if (Line < 0) or (Line >= Height) or (Offset < 0) or (W > Length(Pixels)) or (Offset > Length(Pixels) - W) then
    Exit;

  if not Latched then
    PrepareRotationLine(Line, VDP1.RotationEnabled);
  if (Reg($20) and $30 <> 0) or VDP1.RotationEnabled then
    PrepareRotationRender;
  PrepareColorOffsets;
  PrepareWindows(Line);
  PrepareBackgroundLine(Line);
  var BackAddress: Cardinal := ((Cardinal(Reg($AC) and 7) shl 16) or Reg($AE)) * 2;
  if Reg($AC) and $8000 <> 0 then
    Inc(BackAddress, Cardinal(Line * 2));
  var Back := ColorOffset(SaturnRGB555(VRWord(BackAddress)), 5);
  var ActiveLayers, ActivePriorities: array[0..4] of Integer;
  var ActiveCount := 0;
  var Enabled: Integer := Reg($20);
  for var Order := 0 to 4 do
  begin
    var Layer: Integer := BackgroundOrder[Order];
    var Bit := 1 shl Layer;
    if Enabled and $20 <> 0 then
    begin
      if Layer = 0 then
        Bit := $20
      else if Layer in [1, 2, 3] then
        Continue;
    end;

    var Priority: Integer := (Reg($F8 + (Layer div 2) * 2) shr ((Layer and 1) * 8)) and 7;
    if (Enabled and Bit <> 0) and (Priority > 0) then
    begin
      // Visit foreground first. Later entries in the hardware tie order
      // win equal priorities, so insert them before earlier equal entries.
      var At := ActiveCount;
      while (At > 0) and (Priority >= ActivePriorities[At - 1]) do
      begin
        ActiveLayers[At] := ActiveLayers[At - 1];
        ActivePriorities[At] := ActivePriorities[At - 1];
        Dec(At);
      end;
      ActiveLayers[At] := Layer;
      ActivePriorities[At] := Priority;
      Inc(ActiveCount);
    end;
  end;
  var SpriteControl: Integer := Reg($E0);
  var ColorControl: Integer := Reg($EC);
  var ShadowControl: Integer := Reg($E2);
  var LineColorControl: Integer := Reg($E8);
  var RotationMode: Integer := Reg($B0) and 3;
  var TypeNo: Integer := SpriteControl and 15;
  var DotMask: Integer := ColorMasks[TypeNo];
  var PriorityShift: Integer := PriorityShifts[TypeNo];
  var PriorityMask: Integer := PriorityMasks[TypeNo];
  var RatioShift: Integer := RatioShifts[TypeNo];
  var RatioMask: Integer := RatioMasks[TypeNo];
  var SpritePaletteBase: Integer := ((Reg($E6) shr 4) and 7) * 256;
  var SpritePriorities, SpriteRatios: array[0..7] of Integer;
  for var i := 0 to 7 do
  begin
    SpritePriorities[i] := (Reg($F0 + (i div 2) * 2) shr ((i and 1) * 8)) and 7;
    SpriteRatios[i] := (Reg($100 + (i div 2) * 2) shr ((i and 1) * 8)) and 31;
  end;
  var SpriteRotated := VDP1.RotationEnabled;
  var SpriteWidth: Integer;
  var Sprite8Bit: Boolean;
  var SpriteRow: PByte := nil;
  if not SpriteRotated then
    SpriteRow := VDP1.DisplayRow(Line, SpriteWidth, Sprite8Bit)
  else
  begin
    SpriteWidth := 0;
    Sprite8Bit := False;
  end;
  var DisplayEnabled := Reg(0) and $8000 <> 0;
  for var X := 0 to W - 1 do
  begin
    var Sprite: Word;
    if SpriteRotated then
      Sprite := SpritePixel(X, Line, VDP1)
    else if X >= SpriteWidth then
      Sprite := 0
    else if Sprite8Bit then
      Sprite := PByte(NativeUInt(SpriteRow) + NativeUInt(X))^
    else
      Sprite := Swap(PWord(NativeUInt(SpriteRow) + NativeUInt(X) * 2)^);
    var HasMSB: Boolean := (TypeNo >= 2) and (TypeNo <= 7) and (SpriteControl and $20 = 0) and (Sprite and $8000 <> 0);
    FSpriteWindow := HasMSB and (SpriteControl and $10 <> 0);
    FCoefficientColor[0] := -1;
    FCoefficientColor[1] := -1;
    var Top := 0;
    var Below := 0;
    var TopLayer := 5;
    var ResultColor := Back;
    var BelowColor := Back;
    var CoeffColors: array[0..4] of Integer;
    for var i := 0 to 4 do
      CoeffColors[i] := -1;
    if not DisplayEnabled then
    begin
      Pixels[Offset + X] := $FF000000;
      Continue;
    end;
    var BackgroundCount := 0;
    for var Order := 0 to ActiveCount - 1 do
    begin
      var Layer := ActiveLayers[Order];
      var Priority := ActivePriorities[Order];
      var C: TAlphaColor;
      if (Priority > 0) and Background(Layer, X, Line, C) then
      begin
        C := ColorOffset(C, Layer);
        if BackgroundCount = 0 then
        begin
          Top := Priority;
          ResultColor := C;
          TopLayer := Layer;
        end
        else
        begin
          Below := Priority;
          BelowColor := C;
        end;
        Inc(BackgroundCount);
        if (Layer = 4) or ((Layer = 0) and (Reg($20) and $20 <> 0)) then
        begin
          var Parameter := FLastParameter;
          if (RotationMode = 2) or (Reg($20) and $20 <> 0) then
            Parameter := 0;
          CoeffColors[Layer] := FCoefficientColor[Parameter];
        end;

        // Only two visible backgrounds can contribute. Without background
        // color calculation, the top background alone is sufficient even
        // when a sprite later becomes the top or second candidate.
        if (BackgroundCount = 2) or (ColorControl and (1 shl TopLayer) = 0) then
          Break;
      end;
    end;
    var ShadowPriority: Integer := -1;
    var TransparentShadow: Boolean;
    var SpriteRatio: Integer := 0;
    var SpritePriority: Integer := 0;
    var SpriteColorMSB: Boolean := False;
    if (Sprite <> 0) and WindowVisible(5, X, Line) then
    begin
      var Priority: Integer;
      var C: TAlphaColor;
      if (Sprite and $8000 <> 0) and (SpriteControl and $20 <> 0) then
      begin
        Priority := SpritePriorities[0];
        C := SaturnRGB555(Sprite);
        SpriteColorMSB := True;
      end
      else
      begin
        var Index: Integer := (Sprite shr PriorityShift) and PriorityMask;
        Priority := SpritePriorities[Index];
        var PaletteIndex: Integer := (Sprite and DotMask) + SpritePaletteBase;
        C := Palette(PaletteIndex);
        SpriteColorMSB := PaletteMSB(PaletteIndex);
      end;
      var DotColor := Sprite and DotMask;
      SpritePriority := Priority;
      var RatioIndex: Integer := (Sprite shr RatioShift) and RatioMask;
      SpriteRatio := SpriteRatios[RatioIndex];
      var RGB: Boolean := (Sprite and $8000 <> 0) and (SpriteControl and $20 <> 0);
      var NormalShadow: Boolean := not RGB and (DotColor = DotMask - 1);
      var MSBShadow: Boolean := HasMSB and (SpriteControl and $10 = 0);
      TransparentShadow := MSBShadow and (Sprite and $7FFF = 0);
      if NormalShadow or TransparentShadow then
      begin
        if NormalShadow or (ShadowControl and $100 <> 0) then
          ShadowPriority := Priority;
      end
      else if (Priority > 0) and (RGB or (DotColor <> 0)) then
      begin
        if MSBShadow then
          C := $FF000000 or ((C and $FEFEFE) shr 1);
        C := ColorOffset(C, 6);
        if Priority >= Top then
        begin
          BelowColor := ResultColor;
          Top := Priority;
          ResultColor := C;
          TopLayer := 6;
        end
        else if Priority >= Below then
        begin
          BelowColor := C;
        end;
      end;
    end;
    var Layer := TopLayer;
    var CalculationAllowed := True;
    if Layer = 6 then
    begin
      var Condition: Integer := (SpriteControl shr 12) and 3;
      var Number: Integer := (SpriteControl shr 8) and 7;
      case Condition of
        0:
          CalculationAllowed := SpritePriority <= Number;
        1:
          CalculationAllowed := SpritePriority = Number;
        2:
          CalculationAllowed := SpritePriority >= Number;
        3:
          CalculationAllowed := SpriteColorMSB;
      end;
    end;
    if CalculationAllowed and (Top > 0) and WindowVisible(7, X, Line) and (ColorControl and (1 shl Layer) <> 0) then
    begin

      var Ratio: Integer := 0;
      if Layer < 4 then
        Ratio := (Reg($108 + (Layer div 2) * 2) shr ((Layer and 1) * 8)) and 31
      else if Layer = 4 then
        Ratio := Reg($10C) and 31
      else if Layer = 6 then
        Ratio := SpriteRatio;
      if LineColorControl and (1 shl Layer) <> 0 then
      begin
        var Table: Cardinal := ((Cardinal(Reg($A8) and 7) shl 16) or Reg($AA)) * 2;
        var TableY := Line;
        if Height > 256 then
          TableY := TableY div 2;
        if Reg($A8) and $8000 <> 0 then
          Inc(Table, Cardinal(TableY * 2));
        var Entry: Integer := VRWord(Table) and $7FF;
        if (Layer < 5) and (CoeffColors[Layer] >= 0) then
          Entry := (Entry and $780) or CoeffColors[Layer];
        BelowColor := Palette(Entry);
      end;
      if ColorControl and $100 <> 0 then
      begin
        var RB := (ResultColor and $FF00FF) + (BelowColor and $FF00FF);
        var G := (ResultColor and $FF00) + (BelowColor and $FF00);
        var CarryRB := RB and $1000100;
        var CarryG := G and $10000;
        ResultColor := $FF000000 or (RB and $FF00FF) or (G and $FF00) or
          (CarryRB - (CarryRB shr 8)) or (CarryG - (CarryG shr 8));
      end
      else
      begin
        // Independent 16-bit lanes cannot carry into one another: weights sum to 32.
        var RB := ((ResultColor and $FF00FF) * Cardinal(31 - Ratio) +
          (BelowColor and $FF00FF) * Cardinal(Ratio + 1)) shr 5;
        var G := ((ResultColor and $FF00) * Cardinal(31 - Ratio) +
          (BelowColor and $FF00) * Cardinal(Ratio + 1)) shr 5;
        ResultColor := $FF000000 or (RB and $FF00FF) or (G and $FF00);
      end;
    end;
    if (ShadowPriority > 0) and (ShadowPriority >= Top) and (Layer <= 5) and (ShadowControl and (1 shl Layer) <> 0) then
      ResultColor := $FF000000 or ((ResultColor and $FEFEFE) shr 1);
    Pixels[Offset + X] := ResultColor;
  end;
end;

{$Q+}{$R+}

procedure TSaturnVDP2.UpdateResolution;
begin
  FWidth := 320;
  if Reg(0) and 1 <> 0 then
    FWidth := 352;
  if Reg(0) and 2 <> 0 then
    FWidth := FWidth * 2;
  FHeight := 224;
  case (Reg(0) shr 4) and 3 of
    1:
      FHeight := 240;
    2:
      FHeight := 256;
  end;
  if (Reg(0) shr 6) and 3 = 3 then
    FHeight := FHeight * 2;
  FScanHeight := FHeight;
  if (Reg(0) shr 6) and 3 = 3 then
    FScanHeight := FScanHeight div 2;
end;

function TSaturnVDP2.Width: Integer;
begin
  Result := FWidth;
end;

function TSaturnVDP2.Height: Integer;
begin
  Result := FHeight;
end;

function TSaturnVDP2.ScanHeight: Integer;
begin
  Result := FScanHeight;
end;

function TSaturnVDP2.FieldLines: Integer;
begin
  Result := 263;
  if FPAL then
    Result := 313;
  if (Reg(0) and $80 <> 0) and FField then
    Dec(Result);
end;

function TSaturnVDP2.Clock352: Boolean;
begin
  Result := Reg(0) and 1 <> 0;
end;

procedure TSaturnVDP2.SetRaster(Line, Horizontal: Integer; HBlank, VBlank: Boolean);
begin
  FLine := Line;
  FHorizontal := Horizontal;
  FHBlank := HBlank;
  FVBlank := VBlank;
end;

procedure TSaturnVDP2.LatchLine(Line: Integer; FramebufferRotation: Boolean);
begin
  // RPRCTL readback and rotation accumulators belong to the raster event,
  // independently of when an asynchronous pixel renderer completes.
  PrepareRotationLine(Line, FramebufferRotation);
end;

procedure TSaturnVDP2.NewField;
begin
  FRotationLine := -1;
  if Reg(0) and $80 <> 0 then
    FField := not FField
  else
    FField := True;
end;

function TSaturnVDP2.ReadRegister(Address: Cardinal; Size: Integer): Cardinal;
begin
  if (Address and $1FE <= 10) and Assigned(FRasterSync) then
    FRasterSync;
  if Size = 1 then
    Exit($FF);

  Result := 0;
  for var i := 0 to Size div 2 - 1 do
  begin
    var A: Integer := (Address + Cardinal(i * 2)) and $1FE;
    var Value := Reg(A);
    case A of
      4:
        Value := Word(Ord(FPAL)) or (Word(Ord(FField)) shl 1) or (Word(Ord(FHBlank)) shl 2) or (Word(Ord(FVBlank or (Reg(0) and $8000 = 0))) shl 3);
      8:
        Value := FHorizontal and $3FF;
      10:
        begin
          var V := FLine;
          var VSync: Integer := 237;
          var Total: Integer := 263;
          if ScanHeight = 240 then
            VSync := 245;
          if FPAL then
          begin
            Total := 313;
            VSync := 259 + (ScanHeight - 224) div 2;
          end;
          if V >= VSync then
            Inc(V, 512 - Total);
          if Height > 256 then
            V := V * 2 + Ord(not FField);
          Value := V and $3FF;
        end;
    end;
    Result := (Result shl 16) or Value;
  end;
end;

procedure TSaturnVDP2.RemapCRAM(OldMode: Integer);
var
  Converted: array[0..$FFF] of Byte;
begin
  // Keep the archive's CPU-visible CRAM byte order. RGB888 accesses select
  // alternating physical 16-bit banks; a mode switch must preserve those
  // banks, rather than reinterpreting adjacent RGB888 words as RGB555.
  // Cross-checked with Ymir MapCRAMAddress and Beetle VDP2 MemW.
  for var Address := 0 to $FFF do
  begin
    var At: Integer;
    if OldMode >= 2 then
      At := (Address and 1) or ((Address and $FFC) shr 1) or ((Address and 2) shl 10)
    else
      At := (Address and 1) or ((Address and $7FE) shl 1) or ((Address and $800) shr 10);
    Converted[At] := FCRAM[Address];
  end;
  Move(Converted, FCRAM, SizeOf(FCRAM));
end;

procedure TSaturnVDP2.WriteRegister(Address, Value: Cardinal; Size: Integer);
begin
  if Size = 1 then
    Exit;

  for var i := 0 to Size div 2 - 1 do
  begin
    var A: Integer := (Address + Cardinal(i * 2)) and $1FE;
    if A in [4, 8, 10] then
      Continue;

    if (A >= $110) and (A <= $11E) then
      FOffsetsDirty := True;
    FRegisters[A div 2] := (Value shr ((Size div 2 - i - 1) * 16)) and $FFFF;
    if A = 0 then
      UpdateResolution;
    if (A = $0E) and (FPaletteMode <> (Reg($0E) shr 12) and 3) then
    begin
      var Mode := (Reg($0E) shr 12) and 3;
      if FPaletteMode shr 1 <> Mode shr 1 then
        RemapCRAM(FPaletteMode);
      FPaletteMode := Mode;
      FillChar(FPaletteValid, SizeOf(FPaletteValid), 0);
    end;
  end;
end;

procedure TSaturnVDP2.SerializeState(Archive: TStateArchive; Extended: Boolean);
begin
  if not Archive.Loading and Assigned(FRasterSync) then
    FRasterSync;
  Archive.Field(FVRAM, SizeOf(FVRAM));
  Archive.Field(FCRAM, SizeOf(FCRAM));
  Archive.Field(FRegisters, SizeOf(FRegisters));
  if Archive.Loading then
  begin
    FPaletteMode := (Reg($0E) shr 12) and 3;
    FillChar(FPaletteValid, SizeOf(FPaletteValid), 0);
    FOffsetsDirty := True;
    UpdateResolution;
  end;
  Archive.Field(FLine, SizeOf(FLine));
  Archive.Field(FHorizontal, SizeOf(FHorizontal));
  Archive.Field(FVBlank, SizeOf(FVBlank));
  Archive.Field(FHBlank, SizeOf(FHBlank));
  Archive.Field(FField, SizeOf(FField));
  Archive.Field(FPAL, SizeOf(FPAL));
  if Extended then
  begin
    Archive.Field(FRotation, SizeOf(FRotation));
    Archive.Field(FRotationLine, SizeOf(FRotationLine));
    if (FRotationLine < -1) or (FRotationLine >= 512) then
      raise EReadError.Create('Invalid VDP2 rotation latch');
  end
  else if Archive.Loading then
    FRotationLine := -1;
  if (FLine < 0) or (FLine > 312) or (FHorizontal < 0) or (FHorizontal > 2047) then
    raise EReadError.Create('Invalid VDP2 raster state');
end;

initialization
  InitializeRGB555;

end.

