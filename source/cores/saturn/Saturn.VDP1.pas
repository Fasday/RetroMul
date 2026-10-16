unit Saturn.VDP1;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots;

type
  TVDP1IRQ = procedure of object;

  TSaturnVDP1 = class
  private
    FTime, FNext: Int64;
    FSchedulePadding: array[0..63] of Byte;
    FDisplay, FDisplayWidth, FDisplayHeight: Integer;
    FDisplay8Bit, FDisplayInterlace, FDisplayRotated: Boolean;
    FDisplayPadding: array[0..64] of Byte; // preserve word alignment after the flag bytes
    FVRAM: array[0..$7FFFF] of Byte;
    FBuffer: array[0..1, 0..$3FFFF] of Byte;
    FRegisters: array[0..11] of Word;
    FDraw, FLocalX, FLocalY, FSystemX, FSystemY: Integer;
    FClipX0, FClipY0, FClipX1, FClipY1: Integer;
    FAddress, FReturn: Cardinal;
    FBusy, FHasReturn, FChange: Boolean;
    FCommandCount: Integer;
    FCommandCost: Integer;
    FEraseLine: Integer;
    FEraseRegisters: array[0..2] of Word;
    FEraseMode: Word;
    FEraseVBlank: Boolean;
    FIRQ: TVDP1IRQ;
    FTextureKind, FTextureMask, FTextureBank, FTextureEnd: Integer;
    FTextureLUT: array[0..15] of Word; // command-local decode, not serialized
    procedure PrepareTexture(Mode, Color: Word);
    class var
      FGouraud: array[0..1023] of Byte;
    function BufferWidth: Integer; inline;
    function BufferHeight: Integer; inline;
    function VRWord(Address: Cardinal): Word; inline;
    function Texture(Source: Cardinal; Width, U, V: Integer; Mode, Color: Word): Integer;
    procedure Plot(X, Y: Integer; Color, Mode: Word; Shade: Integer = $4210);
    procedure Line(X0, Y0, X1, Y1: Integer; Color, Mode: Word; Shade0, Shade1: Word);
    procedure Quad(const X, Y, U, V: array of Integer; Source: Cardinal; Width: Integer; Color, Mode: Word; Textured: Boolean; const Shades: array of Word);
    procedure Command;
    procedure AdvanceCommands(Target: Int64);
    procedure UpdateDisplayMode;
    procedure Start;
    procedure Erase(BufferIndex: Integer; FirstLine: Integer = 0; LastLine: Integer = 511);
  public
    class constructor Create;
    constructor Create(IRQ: TVDP1IRQ);
    procedure Reset(Cold: Boolean = True);
    function ReadVRAM(Address: Cardinal; Size: Integer): Cardinal;
    procedure WriteVRAM(Address, Value: Cardinal; Size: Integer);
    function ReadBuffer(Address: Cardinal; Size: Integer): Cardinal;
    procedure WriteBuffer(Address, Value: Cardinal; Size: Integer);
    function ReadRegister(Address: Cardinal; Size: Integer): Cardinal;
    procedure WriteRegister(Address, Value: Cardinal; Size: Integer);
    procedure Advance(Target: Int64); inline;
    // Board scheduler only: Target is already known to be monotonic.
    procedure AdvanceForward(Target: Int64; BusBusy: Boolean = False); inline;
    procedure VBlank;
    procedure VBlankIn;
    procedure ScanLine;
    function DisplayPixel(X, Y: Integer): Word;
    // Read-only row view for the scanline renderer; hold only until its barrier.
    function DisplayRow(Y: Integer; out Width: Integer; out EightBit: Boolean): PByte;
    function RotationEnabled: Boolean;
    procedure SerializeState(Archive: TStateArchive; HasScanErase: Boolean = True);
    property Busy: Boolean read FBusy;
  end;

implementation

uses
  System.Math;

{$Q+}{$R+}

function CoordinateValid(Value: Integer): Boolean; inline;
begin
  Result := (Value >= -1024) and (Value <= 1023);
end;

function Coordinate(Value: Word): Integer;
begin
  Result := Integer(Value and $7FF);
  if Result and $400 <> 0 then
    Dec(Result, $800);
end;

class constructor TSaturnVDP1.Create;
begin
  for var Color := 0 to 31 do
    for var Shade := 0 to 31 do
      FGouraud[Color * 32 + Shade] := EnsureRange(Color + Shade - 16, 0, 31);
end;

constructor TSaturnVDP1.Create(IRQ: TVDP1IRQ);
begin
  inherited Create;
  FIRQ := IRQ;
  Reset;
end;

procedure TSaturnVDP1.UpdateDisplayMode;
begin
  FDisplayWidth := BufferWidth;
  FDisplayHeight := BufferHeight;
  FDisplayInterlace := FRegisters[1] and 8 <> 0;
  FDisplay8Bit := FRegisters[0] and 1 <> 0;
  FDisplayRotated := FRegisters[0] and 2 <> 0;
  if FDisplayInterlace then
    FDisplayHeight := FDisplayHeight * 2;
end;

procedure TSaturnVDP1.Reset(Cold: Boolean);
begin
  FillChar(FSchedulePadding, SizeOf(FSchedulePadding), 0);
  FillChar(FDisplayPadding, SizeOf(FDisplayPadding), 0);
  if Cold then
  begin
    FillChar(FVRAM, SizeOf(FVRAM), 0);
    FillChar(FBuffer, SizeOf(FBuffer), 0);
  end;
  var SavedErase: array[0..2] of Word;
  Move(FRegisters[3], SavedErase, SizeOf(SavedErase));
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  if not Cold then
    Move(SavedErase, FRegisters[3], SizeOf(SavedErase));
  UpdateDisplayMode;
  FDraw := 0;
  FDisplay := 1;
  if Cold then
  begin
    FLocalX := 0;
    FLocalY := 0;
    FSystemX := 511;
    FSystemY := 255;
    FClipX0 := 0;
    FClipY0 := 0;
    FClipX1 := 511;
    FClipY1 := 255;
  end;
  FTime := 0;
  FNext := 0;
  FAddress := 0;
  FReturn := 0;
  FBusy := False;
  FHasReturn := False;
  FChange := False;
  FCommandCount := 0;
  FEraseLine := -1;
  FillChar(FEraseRegisters, SizeOf(FEraseRegisters), 0);
  FEraseMode := 0;
  FEraseVBlank := False;
end;

function TSaturnVDP1.VRWord(Address: Cardinal): Word;
begin
  if Address and 1 = 0 then
    Result := Swap(PWord(@FVRAM[Address and $7FFFF])^)
  else
    Result := (Word(FVRAM[Address and $7FFFF]) shl 8) or FVRAM[(UInt64(Address) + 1) and $7FFFF];
end;

function TSaturnVDP1.ReadVRAM(Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := 0;
  for var i := 0 to Size - 1 do
    Result := (Result shl 8) or FVRAM[(UInt64(Address) + Cardinal(i)) and $7FFFF];
end;

procedure TSaturnVDP1.WriteVRAM(Address, Value: Cardinal; Size: Integer);
begin
  for var i := 0 to Size - 1 do
    FVRAM[(UInt64(Address) + Cardinal(i)) and $7FFFF] := (Value shr ((Size - i - 1) * 8)) and $FF;
end;

function TSaturnVDP1.ReadBuffer(Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := 0;
  for var i := 0 to Size - 1 do
    Result := (Result shl 8) or FBuffer[FDraw, (UInt64(Address) + Cardinal(i)) and $3FFFF];
end;

procedure TSaturnVDP1.WriteBuffer(Address, Value: Cardinal; Size: Integer);
begin
  for var i := 0 to Size - 1 do
    FBuffer[FDraw, (UInt64(Address) + Cardinal(i)) and $3FFFF] := (Value shr ((Size - i - 1) * 8)) and $FF;
end;

function TSaturnVDP1.BufferWidth: Integer;
begin
  Result := 512;
  if FRegisters[0] and 3 = 1 then
    Result := 1024;
end;

function TSaturnVDP1.BufferHeight: Integer;
begin
  Result := 256;
  if FRegisters[0] and 3 = 3 then
    Result := 512;
end;

function TSaturnVDP1.RotationEnabled: Boolean;
begin
  Result := FDisplayRotated;
end;

function TSaturnVDP1.DisplayPixel(X, Y: Integer): Word;
begin
  Result := 0;
  var Width := FDisplayWidth;
  var MaxY := FDisplayHeight;
  if (Cardinal(X) >= Cardinal(Width)) or (Cardinal(Y) >= Cardinal(MaxY)) then
    Exit;

  if FDisplayInterlace then
    Y := Y div 2;
  var At := Y * Width + X;
  if FDisplay8Bit then
    Result := FBuffer[FDisplay, At and $3FFFF]
  else
    Result := (Word(FBuffer[FDisplay, At * 2]) shl 8) or FBuffer[FDisplay, At * 2 + 1];
end;

function TSaturnVDP1.DisplayRow(Y: Integer; out Width: Integer; out EightBit: Boolean): PByte;
begin
  Width := 0;
  EightBit := FDisplay8Bit;
  Result := nil;
  if Cardinal(Y) >= Cardinal(FDisplayHeight) then
    Exit;

  if FDisplayInterlace then
    Y := Y div 2;
  Width := FDisplayWidth;
  var At := Y * Width;
  if not EightBit then
    At := At * 2;
  Result := @FBuffer[FDisplay, At];
end;

{$Q-}{$R-}
procedure TSaturnVDP1.PrepareTexture(Mode, Color: Word);
const
  Masks: array[0..7] of Word = ($F, $F, $3F, $7F, $FF, $FFFF, 0, 0);
begin
  // VRAM is stable while an atomic command is rasterized. Decode the color
  // bank/LUT once, as the reference rasterizers do for each primitive.
  FTextureKind := (Mode shr 3) and 7;
  FTextureMask := Masks[FTextureKind];
  FTextureBank := Color and not FTextureMask;
  if FTextureKind < 2 then
    FTextureEnd := $F
  else if FTextureKind = 5 then
    FTextureEnd := $7FFF
  else
    FTextureEnd := $FF;
  if FTextureKind = 1 then
    for var i := 0 to 15 do
      FTextureLUT[i] := VRWord(Cardinal(Color) * 8 + Cardinal(i) * 2);
end;

function TSaturnVDP1.Texture(Source: Cardinal; Width, U, V: Integer; Mode, Color: Word): Integer;
begin
  var Kind: Integer := FTextureKind;
  var Dot: Integer;
  Inc(FCommandCost);
  var At: Cardinal := Cardinal(V * Width + U);
  case Kind of
    0, 1:
      begin
        Dot := FVRAM[(Source + At div 2) and $7FFFF];
        if not Odd(At) then
          Dot := Dot shr 4
        else
          Dot := Dot and 15;
      end;
    2, 3, 4:
      Dot := FVRAM[(Source + At) and $7FFFF];
    5:
      Dot := VRWord(Source + At * 2);
  else
    Exit(-1);
  end;

  if (Mode and $1080 = 0) and (Dot = FTextureEnd) then
    Exit(-2);

  // RGB data with MSB clear is transparent, including the undocumented
  // palette-like codes observed on hardware (Ymir's illegal-color tests).
  if (Mode and $40 = 0) and ((Dot = 0) or ((Kind = 5) and (Dot and $8000 = 0))) then
    Exit(-1);

  case Kind of
    0, 2, 3, 4:
      Result := FTextureBank or (Dot and FTextureMask);
    1:
      Result := FTextureLUT[Dot];
  else
    Result := Dot;
  end;
end;

{$Q-}{$R-}
procedure TSaturnVDP1.Plot(X, Y: Integer; Color, Mode: Word; Shade: Integer);
begin
  var Width := BufferWidth;
  var MaxY := BufferHeight;
  if FRegisters[1] and 8 <> 0 then
    MaxY := MaxY * 2;
  if (Cardinal(X) >= Cardinal(Width)) or (Cardinal(Y) >= Cardinal(MaxY)) or (X > FSystemX) or (Y > FSystemY) then
    Exit;

  if Mode and $400 <> 0 then
  begin
    var Inside: Boolean := (X >= FClipX0) and (X <= FClipX1) and (Y >= FClipY0) and (Y <= FClipY1);
    if Inside = (Mode and $200 <> 0) then
      Exit;
  end;

  if (Mode and $100 <> 0) and Odd(X xor Y) then
    Exit;

  Inc(FCommandCost);
  if Mode and 7 <> 0 then
    Inc(FCommandCost);
  if FRegisters[1] and 8 <> 0 then
  begin
    if (Y and 1) <> ((FRegisters[1] shr 2) and 1) then
      Exit;

    Y := Y div 2;
  end;
  var At: Integer := (Y * Width + X) * 2;
  if FRegisters[0] and 1 <> 0 then
  begin
    FBuffer[FDraw, At div 2] := Color and $FF;
    Exit;
  end;

  if (Mode and $8007 = 0) or ((Mode and $8007 = 4) and ((Color and $8000 = 0) or (Shade and $7FFF = $4210))) then
  begin
    PWord(@FBuffer[FDraw, At])^ := Swap(Color);
    Exit;
  end;

  var Old: Word := 0;
  if (Mode and $8000 <> 0) or ((Mode and 3) in [1, 3]) then
    Old := Swap(PWord(@FBuffer[FDraw, At])^);
  if Mode and $8000 <> 0 then
  begin
    FBuffer[FDraw, At] := (Old shr 8) or $80;
    Exit;
  end;

  var Calc: Integer := Mode and 7;
  if (Calc >= 4) and (Color and $8000 <> 0) and (Shade and $7FFF <> $4210) then
    Color := $8000 or FGouraud[(Color and 31) * 32 + (Shade and 31)] or
      (Word(FGouraud[((Color shr 5) and 31) * 32 + ((Shade shr 5) and 31)]) shl 5) or
      (Word(FGouraud[((Color shr 10) and 31) * 32 + ((Shade shr 10) and 31)]) shl 10);
  case Calc and 3 of
    1:
      begin
        if Old and $8000 = 0 then
          Exit;

        Color := $8000 or ((Old and $7BDE) shr 1);
      end;
    2:
      if Color and $8000 <> 0 then
        Color := $8000 or ((Color and $7BDE) shr 1);
    3:
      if (Color and Old and $8000) <> 0 then
        Color := $8000 or ((Color and $7BDE) shr 1) + ((Old and $7BDE) shr 1);
  end;
  if Mode and $8000 <> 0 then
    Color := Color or $8000;
  PWord(@FBuffer[FDraw, At])^ := Swap(Color);
end;

{$Q-}{$R-}
procedure TSaturnVDP1.Line(X0, Y0, X1, Y1: Integer; Color, Mode: Word; Shade0, Shade1: Word);
begin
  var DX := Abs(X1 - X0);
  var DY: Integer := -Abs(Y1 - Y0);
  var SX: Integer := 1;
  var SY: Integer := 1;
  if X0 > X1 then
    SX := -1;
  if Y0 > Y1 then
    SY := -1;
  var Error := DX + DY;
  var Length := Max(1, Max(DX, -DY));
  var At := 0;
  while True do
  begin
    var Shade: Integer := 0;
    for var C := 0 to 2 do
    begin
      var A: Integer := (Shade0 shr (C * 5)) and 31;
      var B: Integer := (Shade1 shr (C * 5)) and 31;
      Shade := Shade or ((A + (B - A) * At div Length) shl (C * 5));
    end;
    Plot(X0, Y0, Color, Mode, Shade);
    if (X0 = X1) and (Y0 = Y1) then
      Break;

    Inc(At);
    var E := Error * 2;
    if E >= DY then
    begin
      Inc(Error, DY);
      Inc(X0, SX);
    end;
    if E <= DX then
    begin
      Inc(Error, DX);
      Inc(Y0, SY);
    end;
  end;
end;

// Preserve truncation toward zero; exact unit/zero gradients need no division.
function Interpolate(Start, Delta, At, Denominator: Integer): Integer; inline;
begin
  if Delta = 0 then
    Result := Start
  else if Delta = Denominator then
    Result := Start + At
  else if Delta = -Denominator then
    Result := Start - At
  else
    Result := Start + Delta * At div Denominator;
end;

type
  TQuadStepper = record
    Value, Whole, Remainder, Error, Denominator, Direction: Integer;
    procedure Init(Start, Delta, Span: Integer); inline;
    procedure Advance; inline;
  end;

procedure TQuadStepper.Init(Start, Delta, Span: Integer);
begin
  Value := Start;
  Denominator := Span;
  Error := 0;
  if Delta = 0 then
    Whole := 0
  else if Delta = Span then
    Whole := 1
  else if Delta = -Span then
    Whole := -1
  else
    Whole := Delta div Span;
  Remainder := Abs(Delta - Whole * Span);
  if Delta < 0 then
    Direction := -1
  else
    Direction := 1;
end;

procedure TQuadStepper.Advance;
begin
  Inc(Value, Whole);
  Inc(Error, Remainder);
  if Error >= Denominator then
  begin
    Dec(Error, Denominator);
    Inc(Value, Direction);
  end;
end;

// VDP1 steps source texels independently of destination dots. During
// shrinking all intermediate texels must still be visited for end codes;
// during enlargement one source end code is counted only once.
// Algorithm cross-checked with Ymir TextureStepper and Sega VDP1 section 6.3.
type
  TTextureStepper = record
    Value, Numerator, Denominator, Error, Direction: Integer;
    procedure Init(Count, First, Last: Integer; HSS: Boolean = False; Select: Integer = 0); inline;
    procedure AdvanceTexel; inline;
    procedure AdvancePixel; inline;
  end;

procedure TTextureStepper.Init(Count, First, Last: Integer; HSS: Boolean; Select: Integer);
begin
  if HSS then
  begin
    First := First shr 1;
    Last := Last shr 1;
  end;
  var Delta := Last - First;
  var Distance := Abs(Delta);
  Value := First;
  if Delta < 0 then
    Direction := -1
  else
    Direction := 1;
  if HSS then
  begin
    Value := (Value shl 1) or Select;
    Direction := Direction * 2;
  end;
  Numerator := Distance;
  Denominator := Count;
  if Count <= Distance then
  begin
    Inc(Numerator);
    Error := Distance - Count * 2;
    if Delta >= 0 then
      Inc(Error);
  end
  else
  begin
    Dec(Denominator);
    Error := -Count;
    if Delta < 0 then
      Inc(Error);
  end;
  Numerator := Numerator * 2;
  Denominator := Denominator * 2;
end;

procedure TTextureStepper.AdvanceTexel;
begin
  Inc(Value, Direction);
  Dec(Error, Denominator);
end;

procedure TTextureStepper.AdvancePixel;
begin
  Inc(Error, Numerator);
end;

// VDP1 fills diagonal steps with a second copy of the current dot (Sega
// ST-013-R3, Fig. 1.6). This is coverage, not filtered antialiasing.
// Edge and line error/tie rules checked against Ymir's VDP1 steppers.
type
  TVDP1Edge = record
    X, Y, XInc, YInc, XNum, YNum, Den, XError, YError: Integer;
    XTarget, YTarget, Num, RowDen, RowError, RowTarget: Integer;
    procedure Init(X0, Y0, X1, Y1, Rows: Integer); inline;
    procedure Advance; inline;
  end;

  TVDP1Span = record
    X, Y, MajorX, MajorY, MinorX, MinorY, AAX, AAY: Integer;
    Num, Den, Error: Integer;
    procedure Init(X0, Y0, X1, Y1: Integer); inline;
    function Advance: Boolean; inline;
  end;

procedure TVDP1Edge.Init(X0, Y0, X1, Y1, Rows: Integer);
begin
  X := X0;
  Y := Y0;
  var DX := X1 - X0;
  var DY := Y1 - Y0;
  var ADX := Abs(DX);
  var ADY := Abs(DY);
  var Major := ADX;
  if ADY > Major then
    Major := ADY;
  XInc := 1;
  if DX < 0 then
    XInc := -1;
  YInc := 1;
  if DY < 0 then
    YInc := -1;
  XNum := ADX * 2;
  YNum := ADY * 2;
  Den := Major * 2;
  XError := -Major - 1;
  YError := XError;
  XTarget := 0;
  if DY < 0 then
    XTarget := -1;
  YTarget := 0;
  if DX < 0 then
    YTarget := -1;
  Num := Den;
  RowDen := Rows * 2;
  RowError := -Rows - 1;
  if ADX >= ADY then
    RowTarget := YTarget
  else
    RowTarget := XTarget;
end;

procedure TVDP1Edge.Advance;
begin
  Inc(RowError, Num);
  if RowError < RowTarget then
    Exit;

  Dec(RowError, RowDen);
  Inc(XError, XNum);
  if XError >= XTarget then
  begin
    Dec(XError, Den);
    Inc(X, XInc);
  end;
  Inc(YError, YNum);
  if YError >= YTarget then
  begin
    Dec(YError, Den);
    Inc(Y, YInc);
  end;
end;

procedure TVDP1Span.Init(X0, Y0, X1, Y1: Integer);
begin
  X := X0;
  Y := Y0;
  var DX := X1 - X0;
  var DY := Y1 - Y0;
  var ADX := Abs(DX);
  var ADY := Abs(DY);
  var SX := 1;
  if DX < 0 then
    SX := -1;
  var SY := 1;
  if DY < 0 then
    SY := -1;
  var SameSign := (DX < 0) = (DY < 0);
  MajorX := 0;
  MajorY := 0;
  MinorX := 0;
  MinorY := 0;
  AAX := 0;
  AAY := 0;
  if ADX >= ADY then
  begin
    MajorX := SX;
    MinorY := SY;
    Num := ADY * 2;
    Den := ADX * 2;
    Error := ADX;
    if SameSign then
      AAY := -SY
    else
      AAX := -SX;
  end
  else
  begin
    MajorY := SY;
    MinorX := SX;
    Num := ADX * 2;
    Den := ADY * 2;
    Error := ADY;
    if SameSign then
      AAY := -SY
    else
      AAX := -SX;
  end;
end;

function TVDP1Span.Advance: Boolean;
begin
  Inc(X, MajorX);
  Inc(Y, MajorY);
  Dec(Error, Num);
  Result := Error < 0;
  if Result then
  begin
    Inc(Error, Den);
    Inc(X, MinorX);
    Inc(Y, MinorY);
  end;
end;

procedure TSaturnVDP1.Quad(const X, Y, U, V: array of Integer; Source: Cardinal; Width: Integer; Color, Mode: Word; Textured: Boolean; const Shades: array of Word);
begin
  // VDP1 fills lines between the A-D and B-C edges. Unlike two triangles,
  // this also covers concave, crossed and degenerate four-point commands.
  var Rows := Max(Max(Abs(X[3] - X[0]), Abs(Y[3] - Y[0])), Max(Abs(X[2] - X[1]), Abs(Y[2] - Y[1])));
  var Den := Max(1, Rows);
  var TextureV: TTextureStepper;
  if Textured then
    TextureV.Init(Rows + 1, V[0], V[3]);
  var EdgeL, EdgeR: TVDP1Edge;
  EdgeL.Init(X[0], Y[0], X[3], Y[3], Rows);
  EdgeR.Init(X[1], Y[1], X[2], Y[2], Rows);
  for var Row := 0 to Rows do
  begin
    var AX := EdgeL.X;
    var AY := EdgeL.Y;
    var BX := EdgeR.X;
    var BY := EdgeR.Y;
    EdgeL.Advance;
    EdgeR.Advance;
    var AU := Interpolate(U[0], U[3] - U[0], Row, Den);
    var BU := Interpolate(U[1], U[2] - U[1], Row, Den);
    var Length := Max(Abs(BX - AX), Abs(BY - AY));
    var Span := Max(1, Length);
    var LeftShade, RightShade: array[0..2] of Integer;
    var Gouraud := Mode and 4 <> 0;
    if Gouraud then
      for var Component := 0 to 2 do
      begin
        var SA: Integer := (Shades[0] shr (Component * 5)) and 31;
        var SD: Integer := (Shades[3] shr (Component * 5)) and 31;
        var SB: Integer := (Shades[1] shr (Component * 5)) and 31;
        var SC: Integer := (Shades[2] shr (Component * 5)) and 31;
        LeftShade[Component] := Interpolate(SA, SD - SA, Row, Den);
        RightShade[Component] := Interpolate(SB, SC - SB, Row, Den);
      end;

    // Walk the major axis and fill each diagonal corner with the same dot.
    // Texture and shade advance once per major-axis step, not per write.
    var SpanPixels: TVDP1Span;
    var TextureU: TTextureStepper;
    var SS: array[0..2] of TQuadStepper;
    SpanPixels.Init(AX, AY, BX, BY);
    var FillCorner := False;
    var TextureMode := Mode and not Word($1000);
    var TV: Integer := 0;
    var Dot: Integer := Color;
    var Ends: Integer := 0;
    if Textured then
    begin
      // HSS disables end codes only while shrinking, not while enlarging.
      var HSS := (Mode and $1000 <> 0) and (Length < Abs(BU - AU));
      if HSS then
        TextureMode := TextureMode or $80;
      TextureU.Init(Length + 1, AU, BU, HSS, (FRegisters[1] shr 4) and 1);
      while TextureV.Error >= 0 do
        TextureV.AdvanceTexel;
      TV := Max(0, TextureV.Value);
      TextureV.AdvancePixel;
      Dot := Texture(Source, Width, EnsureRange(TextureU.Value, 0, Width - 1), TV, TextureMode, Color);
      if Dot = -2 then
        Inc(Ends);
    end;
    if Gouraud then
      for var Component := 0 to 2 do
        SS[Component].Init(LeftShade[Component], RightShade[Component] - LeftShade[Component], Span);
    for var Pixel := 0 to Length do
    begin
      if Pixel <> 0 then
      begin
        FillCorner := SpanPixels.Advance;
        if Gouraud then
          for var Component := 0 to 2 do
            SS[Component].Advance;
      end;
      var PX := SpanPixels.X;
      var PY := SpanPixels.Y;
      if Textured then
      begin
        while TextureU.Error >= 0 do
        begin
          TextureU.AdvanceTexel;
          Dot := Texture(Source, Width, EnsureRange(TextureU.Value, 0, Width - 1), TV, TextureMode, Color);
          if Dot = -2 then
            Inc(Ends);
          if Ends >= 2 then
            Break;
        end;

        if Ends >= 2 then
          Break;

        TextureU.AdvancePixel;
      end;
      if Dot < 0 then
        Continue;

      var Shade: Integer := 0;
      if Gouraud and (Dot and $8000 <> 0) then
        for var Component := 0 to 2 do
          Shade := Shade or (EnsureRange(SS[Component].Value, 0, 31) shl (Component * 5));
      Plot(PX, PY, Dot, Mode, Shade);
      if FillCorner then
        Plot(PX + SpanPixels.AAX, PY + SpanPixels.AAY, Dot, Mode, Shade);
    end;
  end;
end;

{$Q+}{$R+}
procedure TSaturnVDP1.Start;
begin
  FAddress := 0;
  FHasReturn := False;
  FBusy := True;
  FRegisters[8] := FRegisters[8] and 1;
  FNext := FTime + 16;
  FCommandCount := 0;
end;
{$Q-}{$R-}

procedure TSaturnVDP1.Command;
begin
  FCommandCost := 16;
  if FAddress > $7FFE0 then
  begin
    FBusy := False;
    Exit;
  end;

  var Control := VRWord(FAddress);
  FRegisters[10] := FAddress shr 3;
  if Control and $8000 <> 0 then
  begin
    FBusy := False;
    FRegisters[8] := FRegisters[8] or 2;
    if Assigned(FIRQ) then
      FIRQ;
    Exit;
  end;

  var Mode := VRWord(FAddress + 4);
  var Color := VRWord(FAddress + 6);
  var X, Y: array[0..3] of Integer;
  var Shades: array[0..3] of Word;
  for var i := 0 to 3 do
  begin
    X[i] := Coordinate(VRWord(FAddress + 12 + Cardinal(i * 4))) + FLocalX;
    Y[i] := Coordinate(VRWord(FAddress + 14 + Cardinal(i * 4))) + FLocalY;
    Shades[i] := VRWord(Cardinal(VRWord(FAddress + 28)) * 8 + Cardinal(i * 2));
  end;
  if Control and $4000 = 0 then
    case Control and 15 of
      0, 1, 2, 4:
        begin
          var Source: Cardinal := Cardinal(VRWord(FAddress + 8)) * 8;
          var Size := VRWord(FAddress + 10);
          var Width: Integer := ((Size shr 8) and $3F) * 8;
          var Height: Integer := Size and $FF;
          var Textured: Boolean := Control and 15 <> 4;
          if Textured then
            PrepareTexture(Mode, Color);
          if not Textured then
          begin
            Width := 1;
            Height := 1;
          end;
          if (Width > 0) and (Height > 0) then
          begin
            if Control and 15 = 0 then
            begin
              X[1] := X[0] + Width - 1;
              Y[1] := Y[0];
              X[2] := X[1];
              Y[2] := Y[0] + Height - 1;
              X[3] := X[0];
              Y[3] := Y[2];
            end;
            if Control and 15 = 1 then
            begin
              var Zoom: Integer := (Control shr 8) and 15;
              if Zoom <> 0 then
              begin
                var DW := Coordinate(VRWord(FAddress + 16)) + 1;
                var DH := Coordinate(VRWord(FAddress + 18)) + 1;
                case Zoom and 3 of
                  2:
                    Dec(X[0], DW div 2);
                  3:
                    Dec(X[0], DW - 1);
                end;
                case Zoom shr 2 of
                  2:
                    Dec(Y[0], DH div 2);
                  3:
                    Dec(Y[0], DH - 1);
                end;
                X[2] := X[0] + DW - 1;
                Y[2] := Y[0] + DH - 1;
              end;
              X[1] := X[2];
              Y[1] := Y[0];
              X[3] := X[0];
              Y[3] := Y[2];
            end;
            var U, V: array[0..3] of Integer;
            U[0] := 0;
            U[1] := Width - 1;
            U[2] := Width - 1;
            U[3] := 0;
            V[0] := 0;
            V[1] := 0;
            V[2] := Height - 1;
            V[3] := Height - 1;
            if Control and $10 <> 0 then
              for var i := 0 to 3 do
                U[i] := Width - 1 - U[i];
            if Control and $20 <> 0 then
              for var i := 0 to 3 do
                V[i] := Height - 1 - V[i];

            // Rectangles use exact integer coverage, including one-pixel sprites.
            if (Control and 15 = 0) then
            begin
              var Gouraud := Mode and 4 <> 0;
              var Flat := ((Shades[0] xor Shades[1]) or (Shades[0] xor Shades[2]) or
                (Shades[0] xor Shades[3])) and $7FFF = 0;
              var WX := Max(1, Width - 1);
              var HY := Max(1, Height - 1);
              var ShadeDen := WX * HY;
              for var PY := 0 to Height - 1 do
              begin
                var ShadeBase, ShadeDelta: array[0..2] of Integer;
                if Gouraud and not Flat then
                  for var Component := 0 to 2 do
                  begin
                    var A: Integer := (Shades[0] shr (Component * 5)) and 31;
                    var B: Integer := (Shades[1] shr (Component * 5)) and 31;
                    var C: Integer := (Shades[2] shr (Component * 5)) and 31;
                    var D: Integer := (Shades[3] shr (Component * 5)) and 31;
                    var Left := A * (HY - PY) + D * PY;
                    var Right := B * (HY - PY) + C * PY;
                    ShadeBase[Component] := Left * WX;
                    ShadeDelta[Component] := Right - Left;
                  end;
                var Ends: Integer := 0;
                for var PX := 0 to Width - 1 do
                begin
                  var TU := PX;
                  var TV := PY;
                  if Control and $10 <> 0 then
                    TU := Width - 1 - PX;
                  if Control and $20 <> 0 then
                    TV := Height - 1 - PY;
                  var Dot := Texture(Source, Width, TU, TV, Mode and not Word($1000), Color);
                  if Dot = -2 then
                  begin
                    Inc(Ends);
                    if Ends >= 2 then
                      Break;
                  end
                  else if Dot >= 0 then
                  begin
                    var Shade: Integer := $4210;
                    if Gouraud and (Dot and $8000 <> 0) then
                    begin
                      if Flat then
                        Shade := Shades[0] and $7FFF
                      else
                      begin
                        Shade := 0;
                        for var Component := 0 to 2 do
                          Shade := Shade or (((ShadeBase[Component] + ShadeDelta[Component] * PX) div ShadeDen) shl (Component * 5));
                      end;
                    end;
                    Plot(X[0] + PX, Y[0] + PY, Dot, Mode, Shade);
                  end;
                end;
              end;
            end
            else
            begin
              Quad(X, Y, U, V, Source, Width, Color, Mode, Textured, Shades);
            end;
          end;
        end;
      5:
        for var i := 0 to 3 do
          Line(X[i], Y[i], X[(i + 1) and 3], Y[(i + 1) and 3], Color, Mode, Shades[i], Shades[(i + 1) and 3]);
      6:
        Line(X[0], Y[0], X[1], Y[1], Color, Mode, Shades[0], Shades[1]);
      8:
        begin
          FClipX0 := Coordinate(VRWord(FAddress + 12));
          FClipY0 := Coordinate(VRWord(FAddress + 14));
          FClipX1 := Coordinate(VRWord(FAddress + 20));
          FClipY1 := Coordinate(VRWord(FAddress + 22));
        end;
      9:
        begin
          FSystemX := Coordinate(VRWord(FAddress + 20));
          FSystemY := Coordinate(VRWord(FAddress + 22));
        end;
      10:
        begin
          FLocalX := Coordinate(VRWord(FAddress + 12));
          FLocalY := Coordinate(VRWord(FAddress + 14));
        end;
    end;
  var Next := FAddress + 32;
  case (Control shr 12) and 3 of
    1:
      Next := Cardinal(VRWord(FAddress + 2)) * 8;
    2:
      begin
        if not FHasReturn then
        begin
          FReturn := Next;
          FHasReturn := True;
        end;
        Next := Cardinal(VRWord(FAddress + 2)) * 8;
      end;
    3:
      if FHasReturn then
      begin
        Next := FReturn;
        FHasReturn := False;
      end;
  end;
  FAddress := Next;
  FCommandCount := (FCommandCount + 1) and $7FFFFFFF;
  // Command loops stay active. Clocked slots return control to the CPUs,
  // which can modify the list or issue a forced drawing end.
end;

{$Q+}{$R+}

procedure TSaturnVDP1.Advance(Target: Int64);
begin
  if Target < FTime then
    raise EArgumentException.Create('VDP1 time');

  AdvanceForward(Target);
end;

procedure TSaturnVDP1.AdvanceForward(Target: Int64; BusBusy: Boolean);
begin
  // Host bursts interrupt drawing, including command fetches. Move the next
  // drawing slot forward rather than accumulating work to execute on release.
  // FTime/FNext already serialize the outstanding delay in existing snapshots.
  if BusBusy and FBusy then
    Inc(FNext, Target - FTime);
  FTime := Target;
  if not BusBusy and FBusy and (FNext <= Target) then
    AdvanceCommands(Target);
end;

procedure TSaturnVDP1.AdvanceCommands(Target: Int64);
begin
  while FBusy and (FNext <= Target) do
  begin
    Command;
    Inc(FNext, FCommandCost);
  end;
end;

procedure TSaturnVDP1.Erase(BufferIndex, FirstLine, LastLine: Integer);
begin
  var X0: Integer := ((FEraseRegisters[1] shr 9) and 63) * 8;
  var Y0: Integer := FEraseRegisters[1] and $1FF;
  var X1: Integer := Min(511, ((FEraseRegisters[2] shr 9) and 127) * 8 - 1);
  var Y1: Integer := Min(255 + Ord(FEraseMode and 3 = 3) * 256, FEraseRegisters[2] and $1FF);
  if FEraseMode and 1 <> 0 then
  begin
    X0 := X0 * 2;
    X1 := Min(511 + Ord(FEraseMode and 3 = 1) * 512, ((FEraseRegisters[2] shr 9) and 127) * 16 - 1);
  end;
  Y0 := Max(Y0, FirstLine);
  Y1 := Min(Y1, LastLine);
  if (X1 < X0) or (Y1 < Y0) then
    Exit;

  var Stride := 1024;
  var ByteX := X0 * 2;
  var ByteCount := (X1 - X0 + 1) * 2;
  if FEraseMode and 1 <> 0 then
  begin
    Stride := 512 + Ord(FEraseMode and 3 = 1) * 512;
    ByteX := X0;
    ByteCount := X1 - X0 + 1;
  end;
  var W: Cardinal := Swap(FEraseRegisters[0]);
  var Pattern := W or (W shl 16);
  for var Y := Y0 to Y1 do
  begin
    var Data: PByte := @FBuffer[BufferIndex, Y * Stride + ByteX];
    if (FEraseRegisters[0] shr 8) = (FEraseRegisters[0] and $FF) then
      FillChar(Data^, ByteCount, FEraseRegisters[0] and $FF)
    else // Erase X bounds are in 8/16-dot units, so every row spans whole aligned longwords.
      for var i := 0 to ByteCount div 4 - 1 do
      begin
        PCardinal(Data)^ := Pattern;
        Inc(Data, 4);
      end;
  end;
end;

procedure TSaturnVDP1.ScanLine;
begin
  // H-blank erase follows display fetch, one framebuffer row per scanline.
  // In double interlace it still advances one buffer row per field line.
  if FEraseLine < 0 then
    Exit;

  Erase(FDisplay, FEraseLine, FEraseLine);
  Inc(FEraseLine);
  if FEraseLine > Integer(FEraseRegisters[2] and $1FF) then
    FEraseLine := -1;
end;

procedure TSaturnVDP1.VBlankIn;
begin
  // VBE is sampled at the first H-blank after V-blank IN. The game may
  // clear it and request a swap in the later V-blank OUT handler.
  if FEraseVBlank or (FRegisters[0] and 8 <> 0) then
    Erase(FDisplay);
  FEraseVBlank := False;
end;

procedure TSaturnVDP1.VBlank;
begin
  var Mode := FRegisters[1] and 3;
  FEraseLine := -1;

  // Rotation uses V-blank erase. It clears the old display before exchange.
  if FEraseVBlank then
    Erase(FDisplay);
  FEraseVBlank := False;
  var Exchange := (Mode and 2 = 0) or (FChange and (Mode = 3));
  if Exchange then
  begin
    FDisplay := FDraw;
    FDraw := FDraw xor 1;
    FEraseRegisters[0] := FRegisters[3];
    FEraseRegisters[1] := FRegisters[4];
    FEraseRegisters[2] := FRegisters[5];
    FEraseMode := FRegisters[0];
    FRegisters[9] := FRegisters[10];
    FRegisters[8] := (FRegisters[8] shr 1) and 1;

    // PTM=2 starts on an actual framebuffer exchange, not on every field.
    if FRegisters[2] and 3 = 2 then
      Start;
  end;

  // Normal erase reads each displayed row first, then clears it during H-blank.
  // Manual erase must not blank the upcoming field before it is displayed.
  if (Mode and 2 = 0) or (FChange and (Mode = 2)) then
  begin
    if FEraseMode and 2 <> 0 then
      FEraseVBlank := True
    else
      FEraseLine := FEraseRegisters[1] and $1FF;
  end;
  FChange := False;
end;

function TSaturnVDP1.ReadRegister(Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := 0;
  for var i := 0 to Size - 1 do
  begin
    var A: Integer := (UInt64(Address) + Cardinal(i)) and $1F;
    var V: Word := 0;
    if A div 2 <= 11 then
      V := FRegisters[A div 2];
    if A and not 1 = 22 then
      V := $1000 or (FRegisters[0] and 15) or ((FRegisters[1] and $1E) shl 3) or ((FRegisters[2] and 2) shl 7);
    Result := (Result shl 8) or ((V shr ((1 - (A and 1)) * 8)) and $FF);
  end;
end;

procedure TSaturnVDP1.WriteRegister(Address, Value: Cardinal; Size: Integer);
begin
  if (Size <> 2) and (Size <> 4) then
    Exit;

  for var i := 0 to Size div 2 - 1 do
  begin
    var A: Integer := ((Address div 2) + Cardinal(i)) and 15;
    if A > 7 then
      Continue;

    FRegisters[A] := (Value shr ((Size div 2 - i - 1) * 16)) and $FFFF;
    case A of
      1:
        FChange := FRegisters[1] and 2 <> 0;
      2:
        if FRegisters[2] and 3 = 1 then
          Start;
      6:
        FBusy := False;
    end;
  end;
  UpdateDisplayMode;
end;

procedure TSaturnVDP1.SerializeState(Archive: TStateArchive; HasScanErase: Boolean);
begin
  Archive.Field(FVRAM, SizeOf(FVRAM));
  Archive.Field(FBuffer, SizeOf(FBuffer));
  Archive.Field(FRegisters, SizeOf(FRegisters));
  Archive.Field(FDraw, SizeOf(FDraw));
  Archive.Field(FDisplay, SizeOf(FDisplay));
  Archive.Field(FLocalX, SizeOf(FLocalX));
  Archive.Field(FLocalY, SizeOf(FLocalY));
  Archive.Field(FSystemX, SizeOf(FSystemX));
  Archive.Field(FSystemY, SizeOf(FSystemY));
  Archive.Field(FClipX0, SizeOf(FClipX0));
  Archive.Field(FClipY0, SizeOf(FClipY0));
  Archive.Field(FClipX1, SizeOf(FClipX1));
  Archive.Field(FClipY1, SizeOf(FClipY1));
  Archive.Field(FTime, SizeOf(FTime));
  Archive.Field(FNext, SizeOf(FNext));
  Archive.Field(FAddress, SizeOf(FAddress));
  Archive.Field(FReturn, SizeOf(FReturn));
  Archive.Field(FBusy, SizeOf(FBusy));
  Archive.Field(FHasReturn, SizeOf(FHasReturn));
  Archive.Field(FChange, SizeOf(FChange));
  Archive.Field(FCommandCount, SizeOf(FCommandCount));
  Archive.Field(FCommandCost, SizeOf(FCommandCost));
  if HasScanErase then
  begin
    Archive.Field(FEraseLine, SizeOf(FEraseLine));
    Archive.Field(FEraseRegisters, SizeOf(FEraseRegisters));
    Archive.Field(FEraseMode, SizeOf(FEraseMode));
    Archive.Field(FEraseVBlank, SizeOf(FEraseVBlank));
  end
  else if Archive.Loading then
  begin
    // Older snapshots have already performed their field erase.
    FEraseLine := -1;
    FEraseVBlank := False;
    FEraseRegisters[0] := FRegisters[3];
    FEraseRegisters[1] := FRegisters[4];
    FEraseRegisters[2] := FRegisters[5];
    FEraseMode := FRegisters[0];
  end;
  if (FEraseLine < -1) or (FEraseLine > 511) then
    raise EReadError.Create('VDP1 erase scanline');

  if not (FDraw in [0, 1]) or not (FDisplay in [0, 1]) or (FTime < 0) or (FNext < 0) or (FAddress > $80000) or (FCommandCount < 0) then
    raise EReadError.Create('VDP1 framebuffer');

  if not CoordinateValid(FLocalX) or not CoordinateValid(FLocalY) or
    not CoordinateValid(FSystemX) or not CoordinateValid(FSystemY) or
    not CoordinateValid(FClipX0) or not CoordinateValid(FClipY0) or
    not CoordinateValid(FClipX1) or not CoordinateValid(FClipY1) then
    raise EReadError.Create('VDP1 clip/local coordinate');

  if Archive.Loading then
    UpdateDisplayMode;
end;

end.

