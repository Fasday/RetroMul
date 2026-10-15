unit Saturn.VDP2;

interface

uses
  System.SysUtils, System.Classes, System.UITypes, Saturn.VDP1, Core.Snapshots;

type
  TSaturnVDP2 = class
  private
    FVRAM: array[0..$7FFFF] of Byte;
    FCRAM: array[0..$FFF] of Byte;
    FRegisters: array[0..255] of Word;
    FLine, FHorizontal: Integer;
    FVBlank, FHBlank, FField, FPAL: Boolean;
    FSpriteWindow: Boolean;
    FCoefficientColor: array[0..1] of Integer;
    FLastParameter: Integer;
    function VRWord(Address: Cardinal): Word;
    function VRLong(Address: Cardinal): Cardinal;
    function Reg(Address: Integer): Word;
    function Palette(Index: Integer): TAlphaColor;
    function PaletteMSB(Index: Integer): Boolean;
    function Dot(Base: Cardinal; Pixel, Kind, PaletteBase: Integer; Opaque: Boolean; out Color: TAlphaColor): Boolean;
    function Coefficient(Table: Cardinal; Parameter, X, Y: Integer; out Value: Double): Boolean;
    function RotationPoint(Layer, X, Y: Integer; out RX, RY, Parameter: Integer): Boolean;
    function Background(Layer, X, Y: Integer; out Color: TAlphaColor): Boolean;
    function WindowVisible(Layer, X, Y: Integer): Boolean;
    function ColorOffset(Color: TAlphaColor; Layer: Integer): TAlphaColor;
  public
    constructor Create(PAL: Boolean);
    procedure Reset;
    function ReadVRAM(Address: Cardinal; Size: Integer): Cardinal;
    procedure WriteVRAM(Address, Value: Cardinal; Size: Integer);
    function ReadCRAM(Address: Cardinal; Size: Integer): Cardinal;
    procedure WriteCRAM(Address, Value: Cardinal; Size: Integer);
    function ReadRegister(Address: Cardinal; Size: Integer): Cardinal;
    procedure WriteRegister(Address, Value: Cardinal; Size: Integer);
    procedure SetRaster(Line, Horizontal: Integer; HBlank, VBlank: Boolean);
    procedure NewField;
    procedure RenderLine(Line: Integer; VDP1: TSaturnVDP1; var Pixels: TArray<TAlphaColor>; Offset: Integer);
    function Width: Integer;
    function Height: Integer;
    function Clock352: Boolean;
    function ScanHeight: Integer;
    property Field: Boolean read FField;
    procedure SerializeState(Archive: TStateArchive);
  end;

function SaturnRGB555(Value: Word): TAlphaColor;

implementation

uses
  System.Math;

{$Q+}{$R+}

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
  var R: Cardinal := Value and 31;
  var G: Cardinal := (Value shr 5) and 31;
  var B: Cardinal := (Value shr 10) and 31;
  Result := $FF000000 or (((R shl 3) or (R shr 2)) shl 16) or (((G shl 3) or (G shr 2)) shl 8) or ((B shl 3) or (B shr 2));
end;

constructor TSaturnVDP2.Create(PAL: Boolean);
begin
  inherited Create;
  FPAL := PAL;
  Reset;
end;

procedure TSaturnVDP2.Reset;
begin
  FillChar(FVRAM, SizeOf(FVRAM), 0);
  FillChar(FCRAM, SizeOf(FCRAM), 0);
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FRegisters[$78 div 2] := 1;
  FRegisters[$7C div 2] := 1;
  FRegisters[$88 div 2] := 1;
  FRegisters[$8C div 2] := 1;
  FLine := 0;
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
  for var I := 0 to Size - 1 do
    Result := (Result shl 8) or FVRAM[(UInt64(Address) + Cardinal(I)) and $7FFFF];
end;

procedure TSaturnVDP2.WriteVRAM(Address, Value: Cardinal; Size: Integer);
begin
  for var I := 0 to Size - 1 do
    FVRAM[(UInt64(Address) + Cardinal(I)) and $7FFFF] := (Value shr ((Size - I - 1) * 8)) and $FF;
end;

function TSaturnVDP2.ReadCRAM(Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := 0;
  if Size = 1 then
    Exit($FF);
  for var I := 0 to Size - 1 do
    Result := (Result shl 8) or FCRAM[(UInt64(Address) + Cardinal(I)) and $FFF];
end;

procedure TSaturnVDP2.WriteCRAM(Address, Value: Cardinal; Size: Integer);
begin
  if Size = 1 then
    Exit;
  for var I := 0 to Size - 1 do
  begin
    var A: Integer := (UInt64(Address) + Cardinal(I)) and $FFF;
    var B: Byte := (Value shr ((Size - I - 1) * 8)) and $FF;
    FCRAM[A] := B;
    if (Reg($0E) shr 12) and 3 = 0 then
    begin
      FCRAM[A and $7FF] := B;
      FCRAM[(A and $7FF) or $800] := B;
    end;
  end;
end;

function TSaturnVDP2.Palette(Index: Integer): TAlphaColor;
begin
  var Mode: Integer := (Reg($0E) shr 12) and 3;
  if Mode = 2 then
  begin
    var A: Integer := (Index * 4) and $FFF;
    Result := $FF000000 or (Cardinal(FCRAM[A + 3]) shl 16) or (Cardinal(FCRAM[A + 2]) shl 8) or FCRAM[A + 1];
  end
  else
  begin
    var A: Integer := (Index * 2) and $FFF;
    if Mode = 0 then
      A := A and $7FF;
    Result := SaturnRGB555((Word(FCRAM[A]) shl 8) or FCRAM[A + 1]);
  end;
end;

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

function TSaturnVDP2.WindowVisible(Layer, X, Y: Integer): Boolean;
begin
  var Control: Integer := (Reg($D0 + (Layer div 2) * 2) shr ((Layer and 1) * 8)) and $FF;
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
        var Shift: Integer := Ord(Width <= 352);
        var StartX: Integer := Reg($C0 + W * 8) shr Shift;
        var EndX: Integer := Reg($C4 + W * 8) shr Shift;
        var WY := Y;
        if Height > 256 then
          WY := WY div 2;
        var Table: Cardinal := (Cardinal(Reg($D8 + W * 4)) shl 16) or Reg($DA + W * 4);
        if Table and $80000000 <> 0 then
        begin
          Table := (Table and $7FFFE) * 2 + Cardinal(WY * 4);
          StartX := VRWord(Table) shr Shift;
          EndX := VRWord(Table + 2) shr Shift;
        end;
        var YShift := Ord(Height > 256);
        Inside := (X >= StartX) and (X <= EndX) and (WY >= Integer(Reg($C2 + W * 8) shr YShift)) and (WY <= Integer(Reg($C6 + W * 8) shr YShift));
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
  Result := not Have or Visible;
end;

function TSaturnVDP2.Coefficient(Table: Cardinal; Parameter, X, Y: Integer; out Value: Double): Boolean;
begin
  FCoefficientColor[Parameter] := -1;
  if Height > 256 then
    Y := Y div 2;
  var Control: Integer := (Reg($B4) shr (Parameter * 8)) and $1F;
  var Index: Int64 := Int64(VRLong(Table + $54)) + Int64(SignedParameter(VRLong(Table + $58), 26, True)) * Y + Int64(SignedParameter(VRLong(Table + $5C), 26, True)) * X;
  var Size: Integer := 4;
  if Control and 2 <> 0 then
    Size := 2;
  var Base: Cardinal := Cardinal((Reg($B6) shr (Parameter * 8)) and 7) * Cardinal(Size * $10000);
  var Address: Cardinal := Base + Cardinal(Index shr 16) * Cardinal(Size);
  var Raw: Cardinal;
  if Reg($0E) and $8000 <> 0 then
  begin
    Raw := (Cardinal(FCRAM[$800 + (Address and $7FF)]) shl 8) or FCRAM[$800 + ((UInt64(Address) + 1) and $7FF)];
    if Size = 4 then
      Raw := (Raw shl 16) or (Cardinal(FCRAM[$800 + ((UInt64(Address) + 2) and $7FF)]) shl 8) or FCRAM[$800 + ((Address + 3) and $7FF)];
  end
  else
  begin
    if Size = 2 then
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

function TSaturnVDP2.RotationPoint(Layer, X, Y: Integer; out RX, RY, Parameter: Integer): Boolean;
begin
  var Table: Cardinal := (((Cardinal(Reg($BC) and 7) shl 16) or Reg($BE)) * 2) and $7FF80;
  if (Layer = 0) and (Reg($20) and $20 <> 0) and (Reg($B4) and $11 = $11) then
  begin
    var Ignored: Double;
    Coefficient(Table, 0, X, Y, Ignored);
  end;
  Parameter := 0;
  var Mode: Integer := Reg($B0) and 3;
  if (Layer = 0) or (Mode = 1) then
    Parameter := 1
  else if (Mode = 3) and not WindowVisible(6, X, Y) then
    Parameter := 1;
  var K: Double := 0;
  if (Mode = 2) and (Layer = 4) and (Reg($B4) and 1 <> 0) and not Coefficient(Table, 0, X, Y, K) then
    Parameter := 1;
  Inc(Table, Cardinal(Parameter * $80));
  var Control: Integer := (Reg($B4) shr (Parameter * 8)) and $1F;
  if (Control and 1 <> 0) and not Coefficient(Table, Parameter, X, Y, K) then
    Exit(False);
  FLastParameter := Parameter;
  var Xst: Double := SignedParameter(VRLong(Table), 29, True) / 65536.0;
  var Yst: Double := SignedParameter(VRLong(Table + 4), 29, True) / 65536.0;
  var Zst: Double := SignedParameter(VRLong(Table + 8), 29, True) / 65536.0;
  var DXst: Double := SignedParameter(VRLong(Table + $0C), 19, True) / 65536.0;
  var DYst: Double := SignedParameter(VRLong(Table + $10), 19, True) / 65536.0;
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
  var ScreenY: Double := Y;
  if Height > 256 then
    ScreenY := Y div 2;
  RX := Floor(KX * (A * (Xst + ScreenY * DXst - PX) + B * (Yst + ScreenY * DYst - PY) + C * (Zst - PZ) + (A * DX + B * DY) * ScreenX) + A * (PX - CX) + B * (PY - CY) + C * (PZ - CZ) + CX + MX);
  RY := Floor(KY * (D * (Xst + ScreenY * DXst - PX) + E * (Yst + ScreenY * DYst - PY) + F * (Zst - PZ) + (D * DX + E * DY) * ScreenX) + D * (PX - CX) + E * (PY - CY) + F * (PZ - CZ) + CY + MY);
  if (Control and 1 <> 0) and ((Control shr 2) and 3 = 3) then
    RX := Floor(K);
  Result := True;
end;

function TSaturnVDP2.Background(Layer, X, Y: Integer; out Color: TAlphaColor): Boolean;
begin
  Result := False;
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
  var ScrollX, ScrollY: Integer;
  var ZoomX, ZoomY: Cardinal;
  if Layer < 2 then
  begin
    var B: Integer := $70 + Layer * $10;
    ScrollX := Reg(B) and $7FF;
    ScrollY := Reg(B + 4) and $7FF;
    ZoomX := (Cardinal(Reg(B + 8) and 7) shl 16) or Reg(B + 10);
    ZoomY := (Cardinal(Reg(B + 12) and 7) shl 16) or Reg(B + 14);
    var LineControl: Integer := (Reg($9A) shr (Layer * 8)) and $FF;
    var Count: Integer := Ord(LineControl and 2 <> 0) + Ord(LineControl and 4 <> 0) + Ord(LineControl and 8 <> 0);
    if LineControl and 1 <> 0 then
    begin
      var Table: Cardinal := ((Cardinal(Reg($9C) and 7) shl 16) or Reg($9E)) * 2;
      var Columns: Integer := Ord(Reg($9A) and 1 <> 0) + Ord(Reg($9A) and $100 <> 0);
      var Entry: Integer := (X div 8) * Columns;
      if (Layer = 1) and (Reg($9A) and 1 <> 0) then
        Inc(Entry);
      Inc(ScrollY, SmallInt(VRLong(Table + Cardinal(Entry * 4)) shr 16));
    end;
    if Count > 0 then
    begin
      var Table: Cardinal := ((Cardinal(Reg($A0 + Layer * 4) and 7) shl 16) or Reg($A2 + Layer * 4)) * 2;
      Inc(Table, Cardinal((Y shr ((LineControl shr 4) and 3)) * Count * 4));
      if LineControl and 2 <> 0 then
      begin
        ScrollX := SmallInt(VRLong(Table) shr 16);
        Inc(Table, 4);
      end;
      if LineControl and 4 <> 0 then
      begin
        ScrollY := SmallInt(VRLong(Table) shr 16);
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
    ScrollX := Reg($90 + (Layer - 2) * 4) and $7FF;
    ScrollY := Reg($92 + (Layer - 2) * 4) and $7FF;
    ZoomX := $10000;
    ZoomY := $10000;
  end;
  if Reg($22) and (1 shl Layer) <> 0 then
  begin
    var MX: Integer := ((Reg($22) shr 8) and 15) + 1;
    var MY: Integer := ((Reg($22) shr 12) and 15) + 1;
    X := X - X mod MX;
    Y := Y - Y mod MY;
  end;
  X := ScrollX + Integer((Int64(X) * ZoomX) shr 16);
  Y := ScrollY + Integer((Int64(Y) * ZoomY) shr 16);
  var Parameter: Integer := 0;
  var Rotation: Boolean := (Layer = 4) or ((Layer = 0) and (Reg($20) and $20 <> 0));
  if Rotation and not RotationPoint(Layer, ScreenX, ScreenY, X, Y, Parameter) then
    Exit;

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
    X := X and (BW - 1);
    Y := Y and (BH - 1);
    var Pal: Integer := ((Reg($2C) shr (Layer * 8)) and 7) * 256;
    if Layer = 4 then
      Pal := (Reg($2E) and 7) * 256;
    Result := Dot(Cardinal(Offset) * $20000, Y * BW + X, Kind, Pal + PaletteOffset, Opaque, Color);
    Exit;
  end;
  var CellSize: Integer := 8;
  if Config and 1 <> 0 then
    CellSize := 16;
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
  if Rotation then
  begin
    var Over: Integer := (Reg($3A) shr (10 + Parameter * 4)) and 3;
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
  var Character: Integer;
  var Pal: Integer;
  var Flip: Integer := 0;
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
  X := X mod CellSize;
  Y := Y mod CellSize;
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
  Result := Dot(Base, (Y and 7) * 8 + (X and 7), Kind, Pal * 16 + PaletteOffset, Opaque, Color);
end;

function TSaturnVDP2.ColorOffset(Color: TAlphaColor; Layer: Integer): TAlphaColor;
begin
  Result := Color;
  if Reg($110) and (1 shl Layer) = 0 then
    Exit;
  var Bank: Integer := 0;
  if Reg($112) and (1 shl Layer) <> 0 then
    Bank := 6;
  var NewColor: Cardinal := $FF000000;
  for var I := 0 to 2 do
  begin
    var Delta: Integer := Reg($114 + Bank + I * 2) and $1FF;
    if Delta and $100 <> 0 then
      Dec(Delta, $200);
    NewColor := NewColor or (Cardinal(EnsureRange(Integer((Color shr ((2 - I) * 8)) and $FF) + Delta, 0, 255)) shl ((2 - I) * 8));
  end;
  Result := NewColor;
end;

procedure TSaturnVDP2.RenderLine(Line: Integer; VDP1: TSaturnVDP1; var Pixels: TArray<TAlphaColor>; Offset: Integer);
const
  ColorMasks: array[0..15] of Word = ($7FF, $7FF, $7FF, $7FF, $3FF, $7FF, $3FF, $1FF, $7F, $3F, $3F, $3F, $FF, $FF, $FF, $FF);
  PriorityShifts: array[0..15] of Byte = (14, 13, 14, 13, 13, 14, 12, 12, 7, 7, 6, 0, 7, 7, 6, 0);
  PriorityMasks: array[0..15] of Byte = (3, 7, 1, 3, 3, 1, 7, 7, 1, 1, 3, 0, 1, 1, 3, 0);
  RatioShifts: array[0..15] of Byte = (11, 11, 11, 11, 10, 11, 10, 9, 0, 6, 0, 6, 0, 6, 0, 6);
  RatioMasks: array[0..15] of Byte = (7, 3, 7, 3, 7, 7, 3, 7, 0, 1, 0, 3, 0, 1, 0, 3);
  BackgroundOrder: array[0..4] of Byte = (3, 2, 1, 0, 4);
begin
  var W := Width;
  if (Line < 0) or (Line >= Height) or (Offset < 0) or (Offset + W > Length(Pixels)) then
    Exit;
  var BackAddress: Cardinal := ((Cardinal(Reg($AC) and 7) shl 16) or Reg($AE)) * 2;
  if Reg($AC) and $8000 <> 0 then
    Inc(BackAddress, Cardinal(Line * 2));
  var Back := ColorOffset(SaturnRGB555(VRWord(BackAddress)), 5);
  for var X := 0 to W - 1 do
  begin
    var Sprite := VDP1.DisplayPixel(X, Line);
    var TypeNo: Integer := Reg($E0) and 15;
    var HasMSB: Boolean := (TypeNo >= 2) and (TypeNo <= 7) and (Reg($E0) and $20 = 0) and (Sprite and $8000 <> 0);
    FSpriteWindow := HasMSB and (Reg($E0) and $10 <> 0);
    FCoefficientColor[0] := -1;
    FCoefficientColor[1] := -1;
    var Colors: array[0..7] of TAlphaColor;
    var Layers: array[0..7] of Integer;
    var SecondColors: array[0..7] of TAlphaColor;
    var SecondLayers: array[0..7] of Integer;
    var CoeffColors: array[0..4] of Integer;
    for var I := 0 to 4 do
      CoeffColors[I] := -1;
    for var I := 0 to 7 do
    begin
      Colors[I] := Back;
      Layers[I] := 5;
      SecondColors[I] := Back;
      SecondLayers[I] := -1;
    end;
    if Reg(0) and $8000 = 0 then
    begin
      Pixels[Offset + X] := $FF000000;
      Continue;
    end;
    for var Order := 0 to 4 do
    begin
      var Layer: Integer := BackgroundOrder[Order];
      var Priority: Integer := (Reg($F8 + (Layer div 2) * 2) shr ((Layer and 1) * 8)) and 7;
      var C: TAlphaColor;
      if (Priority > 0) and Background(Layer, X, Line, C) then
      begin
        if Layers[Priority] <> 5 then
        begin
          SecondColors[Priority] := Colors[Priority];
          SecondLayers[Priority] := Layers[Priority];
        end;
        Colors[Priority] := ColorOffset(C, Layer);
        Layers[Priority] := Layer;
        if (Layer = 4) or ((Layer = 0) and (Reg($20) and $20 <> 0)) then
        begin
          var Parameter := FLastParameter;
          if (Reg($B0) and 3 = 2) or (Reg($20) and $20 <> 0) then
            Parameter := 0;
          CoeffColors[Layer] := FCoefficientColor[Parameter];
        end;
      end;
    end;
    var ShadowPriority: Integer := -1;
    var TransparentShadow: Boolean := False;
    var SpriteRatio: Integer := 0;
    var SpritePriority: Integer := 0;
    var SpriteColorMSB: Boolean := False;
    if (Sprite <> 0) and WindowVisible(5, X, Line) then
    begin
      var Priority: Integer;
      var C: TAlphaColor;
      if (Sprite and $8000 <> 0) and (Reg($E0) and $20 <> 0) then
      begin
        Priority := Reg($F0) and 7;
        C := SaturnRGB555(Sprite);
        SpriteColorMSB := True;
      end
      else
      begin
        var Index: Integer := (Sprite shr PriorityShifts[TypeNo]) and PriorityMasks[TypeNo];
        Priority := (Reg($F0 + (Index div 2) * 2) shr ((Index and 1) * 8)) and 7;
        var PaletteIndex: Integer := (Sprite and ColorMasks[TypeNo]) + ((Reg($E6) shr 4) and 7) * 256;
        C := Palette(PaletteIndex);
        SpriteColorMSB := PaletteMSB(PaletteIndex);
      end;
      var DotColor := Sprite and ColorMasks[TypeNo];
      SpritePriority := Priority;
      var RatioIndex: Integer := (Sprite shr RatioShifts[TypeNo]) and RatioMasks[TypeNo];
      SpriteRatio := (Reg($100 + (RatioIndex div 2) * 2) shr ((RatioIndex and 1) * 8)) and 31;
      var RGB: Boolean := (Sprite and $8000 <> 0) and (Reg($E0) and $20 <> 0);
      var NormalShadow: Boolean := not RGB and (DotColor = ColorMasks[TypeNo] - 1);
      var MSBShadow: Boolean := HasMSB and (Reg($E0) and $10 = 0);
      TransparentShadow := MSBShadow and (Sprite and $7FFF = 0);
      if NormalShadow or TransparentShadow then
      begin
        if NormalShadow or (Reg($E2) and $100 <> 0) then
          ShadowPriority := Priority;
      end
      else if (Priority > 0) and (RGB or (DotColor <> 0)) then
      begin
        if MSBShadow then
          C := $FF000000 or ((C and $FEFEFE) shr 1);
        if Layers[Priority] <> 5 then
        begin
          SecondColors[Priority] := Colors[Priority];
          SecondLayers[Priority] := Layers[Priority];
        end;
        Colors[Priority] := ColorOffset(C, 6);
        Layers[Priority] := 6;
      end;
    end;
    var Top: Integer := 0;
    for var I := 1 to 7 do
      if Layers[I] <> 5 then
        Top := I;
    var ResultColor := Colors[Top];
    var Layer := Layers[Top];
    var CalculationAllowed := True;
    if Layer = 6 then
    begin
      var Condition: Integer := (Reg($E0) shr 12) and 3;
      var Number: Integer := (Reg($E0) shr 8) and 7;
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
    if CalculationAllowed and (Top > 0) and WindowVisible(7, X, Line) and (Reg($EC) and (1 shl Layer) <> 0) then
    begin
      var Below: Integer := 0;
      for var I := 1 to Top - 1 do
        if Layers[I] <> 5 then
          Below := I;
      var BelowColor := Colors[Below];
      if SecondLayers[Top] >= 0 then
        BelowColor := SecondColors[Top];
      var Ratio: Integer := 0;
      if Layer < 4 then
        Ratio := (Reg($108 + (Layer div 2) * 2) shr ((Layer and 1) * 8)) and 31
      else if Layer = 4 then
        Ratio := Reg($10C) and 31
      else if Layer = 6 then
        Ratio := SpriteRatio;
      if Reg($E8) and (1 shl Layer) <> 0 then
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
      var Mixed: Cardinal := $FF000000;
      for var I := 0 to 2 do
      begin
        var A: Integer := (ResultColor shr (I * 8)) and 255;
        var B: Integer := (BelowColor shr (I * 8)) and 255;
        var Value: Integer := (A * (31 - Ratio) + B * (Ratio + 1)) div 32;
        if Reg($EC) and $100 <> 0 then
          Value := Min(255, A + B);
        Mixed := Mixed or (Cardinal(Value) shl (I * 8));
      end;
      ResultColor := Mixed;
    end;
    if (ShadowPriority > 0) and (ShadowPriority >= Top) and (Layer <= 5) and (Reg($E2) and (1 shl Layer) <> 0) then
      ResultColor := $FF000000 or ((ResultColor and $FEFEFE) shr 1);
    Pixels[Offset + X] := ResultColor;
  end;
end;

function TSaturnVDP2.Width: Integer;
begin
  Result := 320;
  if Reg(0) and 1 <> 0 then
    Result := 352;
  if Reg(0) and 2 <> 0 then
    Result := Result * 2;
end;

function TSaturnVDP2.Height: Integer;
begin
  Result := 224;
  case (Reg(0) shr 4) and 3 of
    1:
      Result := 240;
    2:
      Result := 256;
  end;
  if (Reg(0) shr 6) and 3 = 3 then
    Result := Result * 2;
end;

function TSaturnVDP2.ScanHeight: Integer;
begin
  Result := Height;
  if (Reg(0) shr 6) and 3 = 3 then
    Result := Result div 2;
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

procedure TSaturnVDP2.NewField;
begin
  if Reg(0) and $80 <> 0 then
    FField := not FField
  else
    FField := True;
end;

function TSaturnVDP2.ReadRegister(Address: Cardinal; Size: Integer): Cardinal;
begin
  if Size = 1 then
    Exit($FF);
  Result := 0;
  for var I := 0 to Size div 2 - 1 do
  begin
    var A: Integer := (Address + Cardinal(I * 2)) and $1FE;
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

procedure TSaturnVDP2.WriteRegister(Address, Value: Cardinal; Size: Integer);
begin
  if Size = 1 then
    Exit;
  for var I := 0 to Size div 2 - 1 do
  begin
    var A: Integer := (Address + Cardinal(I * 2)) and $1FE;
    if A in [4, 8, 10] then
      Continue;
    FRegisters[A div 2] := (Value shr ((Size div 2 - I - 1) * 16)) and $FFFF;
  end;
end;

procedure TSaturnVDP2.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(FVRAM, SizeOf(FVRAM));
  Archive.Field(FCRAM, SizeOf(FCRAM));
  Archive.Field(FRegisters, SizeOf(FRegisters));
  Archive.Field(FLine, SizeOf(FLine));
  Archive.Field(FHorizontal, SizeOf(FHorizontal));
  Archive.Field(FVBlank, SizeOf(FVBlank));
  Archive.Field(FHBlank, SizeOf(FHBlank));
  Archive.Field(FField, SizeOf(FField));
  Archive.Field(FPAL, SizeOf(FPAL));
  if (FLine < 0) or (FLine > 312) or (FHorizontal < 0) or (FHorizontal > 2047) then
    raise EReadError.Create('Invalid VDP2 raster state');
end;

end.

