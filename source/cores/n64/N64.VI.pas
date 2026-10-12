unit N64.VI;
{$Q+}{$R+}

interface

uses System.SysUtils, System.Classes, System.Math, N64.Types, Core.Snapshots;

type
  // The active analogue raster is independent of the RDRAM framebuffer stride.
  // All colour filtering and 10-bit source addressing use integer arithmetic.
  TN64VI = class
  private
    FBus: TN64Bus;
    FRandom: Cardinal;
    FWeave: TArray<Cardinal>;
    FWidth, FHeight: Integer;
    FLastField: Integer;
    function Random: Cardinal;
  public
    constructor Create(Bus: TN64Bus);
    procedure Reset;
    procedure Render(const Registers: array of Cardinal; out Width, Height: Integer; out Pixels: TArray<Cardinal>);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

type
  TVIPixel = record
    R, G, B, Coverage: Integer;
  end;

function FloorShift(Value: Int64; Count: Integer): Integer;
begin
  var Divisor := Int64(1) shl Count;
  Result := Integer(Value div Divisor);
  if (Value < 0) and (Value mod Divisor <> 0) then Dec(Result);
end;

function IntegerSqrt(Value: Cardinal): Cardinal;
begin
  Result := 0;
  var Bit: Cardinal := 1 shl 30;
  while Bit > Value do Bit := Bit shr 2;
  while Bit <> 0 do
  begin
    if Value >= Result + Bit then
    begin
      Dec(Value, Result + Bit);
      Inc(Result, Bit * 2);
    end;
    Result := Result shr 1;
    Bit := Bit shr 2;
  end;
end;

function Median(A, B, C: Integer): Integer; inline;
begin
  Result := Max(Min(A, B), Min(Max(A, B), C));
end;

function Lerp(const A, B: TVIPixel; Fraction: Integer): TVIPixel;
begin
  Result := A;
  Result.R := A.R + FloorShift((B.R - A.R) * Fraction + 16, 5);
  Result.G := A.G + FloorShift((B.G - A.G) * Fraction + 16, 5);
  Result.B := A.B + FloorShift((B.B - A.B) * Fraction + 16, 5);
end;

constructor TN64VI.Create(Bus: TN64Bus);
begin
  inherited Create;
  FBus := Bus;
  Reset;
end;

procedure TN64VI.Reset;
begin
  FRandom := 3;
  FWeave := nil;
  FWidth := 0;
  FHeight := 0;
  FLastField := -1;
end;

function TN64VI.Random: Cardinal;
begin
  FRandom := Cardinal((UInt64(FRandom) * $343FD + $269EC3) and $FFFFFFFF);
  Result := (FRandom shr 16) and $7FFF;
end;

procedure TN64VI.Render(const Registers: array of Cardinal; out Width, Height: Integer; out Pixels: TArray<Cardinal>);
var
  Origin: Cardinal;
  Stride, PixelType, AAMode, Status: Integer;
  FetchState: Integer;
  CacheRows: array[0..7] of Int64;
  CacheStates: array[0..7] of Integer;
  CacheValues: array[0..7] of TArray<TVIPixel>;
  CacheValid: array[0..7] of TArray<Boolean>;

  function Raw(Index: Int64): TVIPixel;
  begin
    Result := Default(TVIPixel);
    var Bytes := 2;
    if PixelType = 3 then Bytes := 4;
    var Address := Int64(Origin) + Index * Bytes;
    if (Address < 0) or (Address + Bytes > $800000) then Exit;
    var A := Cardinal(Address);
    if PixelType = 3 then
    begin
      var V := FBus.Read32(A);
      Result.R := (V shr 24) and $FF;
      Result.G := (V shr 16) and $FF;
      Result.B := (V shr 8) and $FF;
      Result.Coverage := (V shr 5) and 7;
    end
    else
    begin
      var V := (Cardinal(FBus.Read8(A)) shl 8) or FBus.Read8(A + 1);
      // VI fetch keeps the low three colour bits clear; restoration/gamma follows.
      Result.R := Integer((V shr 8) and $F8);
      Result.G := Integer((V shr 3) and $F8);
      Result.B := Integer((V shl 2) and $F8);
      Result.Coverage := Integer((V and 1) shl 2) or FBus.ReadHidden(A);
    end;
  end;

  function Filtered(Index: Int64): TVIPixel;
  var
    Colours: array[0..6] of TVIPixel;
    Directions: array[0..7] of Int64;
  begin
    Result := Raw(Index);
    if AAMode >= 2 then Result.Coverage := 7;
    if Result.Coverage = 7 then
    begin
      if (Status and $10000) = 0 then Exit;
      Directions[0] := Index - Stride - 1;
      Directions[1] := Index - Stride;
      Directions[2] := Index - Stride + 1;
      Directions[3] := Index + Stride - 1;
      Directions[4] := Index + Stride;
      Directions[5] := Index + Stride + 1;
      Directions[6] := Index - 1;
      Directions[7] := Index + 1;
      if FetchState = 1 then
      begin
        Directions[3] := Index - 1;
        Directions[4] := Index;
        Directions[5] := Index + 1;
      end;
      var R := Result.R shr 3; var G := Result.G shr 3; var B := Result.B shr 3;
      for var I := 0 to 7 do
      begin
        var C := Raw(Directions[I]);
        if (C.R shr 3) > R then Inc(Result.R) else if (C.R shr 3) < R then Dec(Result.R);
        if (C.G shr 3) > G then Inc(Result.G) else if (C.G shr 3) < G then Dec(Result.G);
        if (C.B shr 3) > B then Inc(Result.B) else if (C.B shr 3) < B then Dec(Result.B);
      end;
      Exit;
    end;
    Directions[0] := Index - Stride - 1;
    Directions[1] := Index - Stride + 1;
    Directions[2] := Index - 2;
    Directions[3] := Index + 2;
    Directions[4] := Index + Stride - 1;
    Directions[5] := Index + Stride + 1;
    if FetchState = 1 then
    begin
      Directions[4] := Directions[2];
      Directions[5] := Directions[3];
    end;
    Colours[0] := Result;
    var Count := 1;
    for var I := 0 to 5 do
    begin
      var C := Raw(Directions[I]);
      if C.Coverage = 7 then
      begin
        Colours[Count] := C;
        Inc(Count);
      end;
    end;
    for var Channel := 0 to 2 do
    begin
      var Values: array[0..6] of Integer;
      for var I := 0 to Count - 1 do
        case Channel of
          0: Values[I] := Colours[I].R;
          1: Values[I] := Colours[I].G;
          2: Values[I] := Colours[I].B;
        end;
      // Retain the centre while rejecting an isolated neighbour extremum.
      var PosMax := 0; var PosMin := 0;
      var Low := Values[0]; var High := Values[0];
      for var I := 1 to Count - 1 do
        if Values[I] > Values[PosMax] then begin High := Values[PosMax]; PosMax := I end
        else if Values[I] < Values[PosMin] then begin Low := Values[PosMin]; PosMin := I end;
      if High <> Values[PosMax] then for var I := PosMax + 1 to Count - 1 do High := Max(High, Values[I]);
      if Low <> Values[PosMin] then for var I := PosMin + 1 to Count - 1 do Low := Min(Low, Values[I]);
      var Center := 0;
      case Channel of 0: Center := Result.R; 1: Center := Result.G; 2: Center := Result.B end;
      var Value := (Center + FloorShift((Low + High - Center * 2) * (7 - Result.Coverage) + 4, 3)) and $FF;
      case Channel of 0: Result.R := Value; 1: Result.G := Value; 2: Result.B := Value end;
    end;
  end;

  function Cached(Index: Int64): TVIPixel;
  begin
    var Row := Index div Stride;
    if (Index < 0) and (Index mod Stride <> 0) then Dec(Row);
    var Column := Integer(Index - Row * Stride);
    var Slot := Integer(Row and 7);
    if (CacheRows[Slot] <> Row) or (CacheStates[Slot] <> FetchState) then
    begin
      CacheRows[Slot] := Row; CacheStates[Slot] := FetchState;
      for var I := 0 to High(CacheValid[Slot]) do CacheValid[Slot][I] := False;
    end;
    if not CacheValid[Slot][Column] then
    begin
      CacheValues[Slot][Column] := Filtered(Index);
      CacheValid[Slot][Column] := True;
    end;
    Result := CacheValues[Slot][Column];
  end;

  function Divot(Index: Int64): TVIPixel;
  begin
    Result := Cached(Index);
    if (Status and $10) = 0 then Exit;
    var Left := Cached(Index - 1); var Right := Cached(Index + 1);
    if (Result.Coverage and Left.Coverage and Right.Coverage) = 7 then Exit;
    Result.R := Median(Result.R, Left.R, Right.R);
    Result.G := Median(Result.G, Left.G, Right.G);
    Result.B := Median(Result.B, Left.B, Right.B);
  end;

begin
  if Length(Registers) < 14 then raise EArgumentException.Create('VI requires fourteen registers');
  Status := Integer(Registers[0] and $1FFFF);
  Origin := Registers[1] and $FFFFFF;
  Stride := Integer(Registers[2] and $FFF);
  PixelType := Status and 3;
  AAMode := (Status shr 8) and 3;
  var XStart := Integer((Registers[12] shr 16) and $FFF);
  var YStart := Integer((Registers[13] shr 16) and $FFF);
  var XStep := Integer(Registers[12] and $FFF);
  var YStep := Integer(Registers[13] and $FFF);
  var HStart := Integer((Registers[9] shr 16) and $3FF);
  var HEnd := Integer(Registers[9] and $3FF);
  var VStart := Integer((Registers[10] shr 16) and $3FF);
  var VEnd := Integer(Registers[10] and $3FF);
  var ActiveWidth := HEnd - HStart;
  var FieldRows := (VEnd - VStart) div 2;
  var Interlaced := (Status and $40) <> 0;
  var PAL := (Registers[6] and $3FF) > 550;
  // The signal includes its blank borders. A progressive field has 1:2 pixel
  // aspect; repeat each filtered scanline for IEmulationCore square pixels.
  Width := 640; Height := 480;
  if PAL then Height := 576;
  if (ActiveWidth < 1) or (ActiveWidth > 1024) or (FieldRows < 1) or (FieldRows > 512) or
    (Stride < 1) or (XStep = 0) or (YStep = 0) then
  begin
    SetLength(Pixels, Width * Height);
    for var I := 0 to High(Pixels) do Pixels[I] := $FF000000;
    Exit;
  end;
  var LeftBlank := 108;
  var TopBlank := 34;
  if PAL then begin LeftBlank := 128; TopBlank := 44 end;
  var ActiveLeft := HStart - LeftBlank;
  var ActiveTop := (VStart - TopBlank) div 2;
  var LeftClipped := ActiveLeft < 0;
  if LeftClipped then
  begin
    Inc(XStart, -ActiveLeft * XStep);
    Inc(ActiveWidth, ActiveLeft); ActiveLeft := 0;
  end;
  if ActiveTop < 0 then begin Inc(YStart, -ActiveTop * YStep); ActiveTop := 0 end;
  var RightClipped := ActiveLeft + ActiveWidth > Width;
  if RightClipped then ActiveWidth := Width - ActiveLeft;
  // These samples belong to the VI analog blanking interval. Retain the
  // border in the output instead of masking it in an oracle comparison.
  var FirstSample := 8; var LastSample := ActiveWidth - 7;
  if LeftClipped then FirstSample := 0;
  if RightClipped then LastSample := ActiveWidth;
  FieldRows := Min(FieldRows, Height div 2 - ActiveTop);
  var Field := Integer(Registers[4] and 1);
  // CURRENT identifies the physical field belonging to this ORIGIN/scale
  // packet. Its visible canvas row parity is inverted, as in the references.
  // At wrap Console passes the saved completed physical field; its guest
  // MMIO CURRENT may already name the next field.
  if Interlaced then Field := Field xor 1;
  if (FWidth <> Width) or (FHeight <> Height) then
  begin
    FWidth := Width; FHeight := Height; SetLength(FWeave, Width * Height);
    for var I := 0 to High(FWeave) do FWeave[I] := $FF000000;
  end;
  if not (PixelType in [2, 3]) then
  begin
    for var I := 0 to High(FWeave) do FWeave[I] := $FF000000;
    Pixels := Copy(FWeave);
    Exit;
  end;
  for var Y := 0 to Height - 1 do
    if not Interlaced or ((Y and 1) = Field) then
      for var X := 0 to Width - 1 do FWeave[Y * Width + X] := $FF000000;
  FetchState := 0;
  for var Slot := 0 to 7 do
  begin
    CacheRows[Slot] := Low(Int64); CacheStates[Slot] := -1;
    SetLength(CacheValues[Slot], Stride); SetLength(CacheValid[Slot], Stride);
  end;
  for var Y := 0 to FieldRows - 1 do
  begin
    var SY := Int64(YStart) + Int64(Y) * YStep;
    var SourceRow := SY div 1024;
    if SourceRow = (SY + YStep) div 1024 then FetchState := 2 else FetchState := FetchState shr 1;
    var YFraction := Integer((SY div 32) and 31);
    var OutputY := (ActiveTop + Y) * 2;
    if Interlaced then Inc(OutputY, Field);
    for var X := FirstSample to LastSample - 1 do
    begin
      var SX := Int64(XStart) + Int64(X) * XStep;
      var Index := SourceRow * Stride + SX div 1024;
      var Colour := Divot(Index);
      if AAMode <> 3 then
      begin
        var XFraction := Integer((SX div 32) and 31);
        var Below := Divot(Index + Stride);
        var Right := Divot(Index + 1);
        var BelowRight := Divot(Index + Stride + 1);
        Colour := Lerp(Colour, Below, YFraction);
        Right := Lerp(Right, BelowRight, YFraction);
        Colour := Lerp(Colour, Right, XFraction);
      end;
      var Noise: Cardinal := 0;
      if (Status and 4) <> 0 then Noise := Random;
      var R := EnsureRange(Colour.R, 0, 255); var G := EnsureRange(Colour.G, 0, 255); var B := EnsureRange(Colour.B, 0, 255);
      if (Status and 8) <> 0 then
      begin
        var RD := 0; var GD := 0; var BD := 0;
        if (Status and 4) <> 0 then
        begin RD := Noise and 63; GD := (Noise shr 6) and 63; BD := ((Noise shr 9) and 56) or (Noise and 7) end;
        R := IntegerSqrt(Cardinal(R * 64 + RD)) * 2;
        G := IntegerSqrt(Cardinal(G * 64 + GD)) * 2;
        B := IntegerSqrt(Cardinal(B * 64 + BD)) * 2;
      end
      else if (Status and 4) <> 0 then
      begin
        R := Min(255, R + Integer(Noise and 1));
        G := Min(255, G + Integer((Noise shr 1) and 1));
        B := Min(255, B + Integer((Noise shr 2) and 1));
      end;
      var OutputIndex := OutputY * Width + ActiveLeft + X;
      FWeave[OutputIndex] := $FF000000 or (Cardinal(R) shl 16) or (Cardinal(G) shl 8) or Cardinal(B);
      if not Interlaced then FWeave[OutputIndex + Width] := FWeave[OutputIndex];
    end;
  end;
  FLastField := Field;
  Pixels := Copy(FWeave);
end;

procedure TN64VI.SerializeState(State: TStateArchive);
begin
  State.Field(FRandom, 4);
  State.Field(FWidth, 4);
  State.Field(FHeight, 4);
  State.Field(FLastField, 4);
  if State.Loading then
  begin
    if (FWidth < 0) or (FWidth > 1024) or (FHeight < 0) or (FHeight > 1024) or
      (FLastField < -1) or (FLastField > 1) then raise EReadError.Create('Invalid VI raster snapshot');
    SetLength(FWeave, FWidth * FHeight);
  end;
  if Length(FWeave) > 0 then State.Field(FWeave[0], Length(FWeave) * SizeOf(Cardinal))
  else begin var Empty: Byte := 0; State.Field(Empty, 0) end;
end;

end.
