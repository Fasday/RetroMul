unit Saturn.VDP1;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots;

type
  TVDP1IRQ = procedure of object;

  TSaturnVDP1 = class
  private
    FVRAM: array[0..$7FFFF] of Byte;
    FBuffer: array[0..1, 0..$3FFFF] of Byte;
    FRegisters: array[0..11] of Word;
    FDraw, FDisplay, FLocalX, FLocalY, FSystemX, FSystemY: Integer;
    FClipX0, FClipY0, FClipX1, FClipY1: Integer;
    FTime, FNext: Int64;
    FAddress, FReturn: Cardinal;
    FBusy, FHasReturn, FChange: Boolean;
    FCommandCount: Integer;
    FCommandCost: Integer;
    FIRQ: TVDP1IRQ;
    function VRWord(Address: Cardinal): Word;
    function Texture(Source: Cardinal; Width, U, V: Integer; Mode, Color: Word): Integer;
    procedure Plot(X, Y: Integer; Color, Mode: Word; Shade: Integer = $4210);
    procedure Line(X0, Y0, X1, Y1: Integer; Color, Mode: Word; Shade0, Shade1: Word);
    procedure Quad(const X, Y, U, V: array of Integer; Source: Cardinal; Width: Integer; Color, Mode: Word; Textured: Boolean; const Shades: array of Word);
    procedure Command;
    procedure Start;
    procedure Erase;
  public
    constructor Create(IRQ: TVDP1IRQ);
    procedure Reset;
    function ReadVRAM(Address: Cardinal; Size: Integer): Cardinal;
    procedure WriteVRAM(Address, Value: Cardinal; Size: Integer);
    function ReadBuffer(Address: Cardinal; Size: Integer): Cardinal;
    procedure WriteBuffer(Address, Value: Cardinal; Size: Integer);
    function ReadRegister(Address: Cardinal; Size: Integer): Cardinal;
    procedure WriteRegister(Address, Value: Cardinal; Size: Integer);
    procedure Advance(Target: Int64);
    procedure VBlank;
    function DisplayPixel(X, Y: Integer): Word;
    procedure SerializeState(Archive: TStateArchive);
    property Busy: Boolean read FBusy;
  end;

implementation

uses
  System.Math;

{$Q+}{$R+}

function Coordinate(Value: Word): Integer;
begin
  Result := Integer(Value and $7FF);
  if Result and $400 <> 0 then
    Dec(Result, $800);
end;

constructor TSaturnVDP1.Create(IRQ: TVDP1IRQ);
begin
  inherited Create;
  FIRQ := IRQ;
  Reset;
end;

procedure TSaturnVDP1.Reset;
begin
  FillChar(FVRAM, SizeOf(FVRAM), 0);
  FillChar(FBuffer, SizeOf(FBuffer), 0);
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FDraw := 0;
  FDisplay := 1;
  FLocalX := 0;
  FLocalY := 0;
  FSystemX := 511;
  FSystemY := 255;
  FClipX0 := 0;
  FClipY0 := 0;
  FClipX1 := 511;
  FClipY1 := 255;
  FTime := 0;
  FNext := 0;
  FAddress := 0;
  FReturn := 0;
  FBusy := False;
  FHasReturn := False;
  FChange := False;
  FCommandCount := 0;
end;

function TSaturnVDP1.VRWord(Address: Cardinal): Word;
begin
  Result := (Word(FVRAM[Address and $7FFFF]) shl 8) or FVRAM[(UInt64(Address) + 1) and $7FFFF];
end;

function TSaturnVDP1.ReadVRAM(Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := 0;
  for var I := 0 to Size - 1 do
    Result := (Result shl 8) or FVRAM[(UInt64(Address) + Cardinal(I)) and $7FFFF];
end;

procedure TSaturnVDP1.WriteVRAM(Address, Value: Cardinal; Size: Integer);
begin
  for var I := 0 to Size - 1 do
    FVRAM[(UInt64(Address) + Cardinal(I)) and $7FFFF] := (Value shr ((Size - I - 1) * 8)) and $FF;
end;

function TSaturnVDP1.ReadBuffer(Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := 0;
  for var I := 0 to Size - 1 do
    Result := (Result shl 8) or FBuffer[FDraw, (UInt64(Address) + Cardinal(I)) and $3FFFF];
end;

procedure TSaturnVDP1.WriteBuffer(Address, Value: Cardinal; Size: Integer);
begin
  for var I := 0 to Size - 1 do
    FBuffer[FDraw, (UInt64(Address) + Cardinal(I)) and $3FFFF] := (Value shr ((Size - I - 1) * 8)) and $FF;
end;

function TSaturnVDP1.DisplayPixel(X, Y: Integer): Word;
begin
  Result := 0;
  var Width: Integer := 512;
  if FRegisters[0] and 1 <> 0 then
    Width := 1024;
  var MaxY: Integer := 256;
  if FRegisters[1] and 8 <> 0 then
    MaxY := 512;
  if (X < 0) or (X >= Width) or (Y < 0) or (Y >= MaxY) then
    Exit;
  if FRegisters[1] and 8 <> 0 then
    Y := Y div 2;
  var At := Y * Width + X;
  if FRegisters[0] and 1 <> 0 then
    Result := FBuffer[FDisplay, At and $3FFFF]
  else
    Result := (Word(FBuffer[FDisplay, At * 2]) shl 8) or FBuffer[FDisplay, At * 2 + 1];
end;

function TSaturnVDP1.Texture(Source: Cardinal; Width, U, V: Integer; Mode, Color: Word): Integer;
begin
  var Kind: Integer := (Mode shr 3) and 7;
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
  var EndCode: Integer := $7FFF;
  case Kind of
    0, 1:
      EndCode := 15;
    2, 3, 4:
      EndCode := 255;
  end;
  if (Mode and $1080 = 0) and (Dot = EndCode) then
    Exit(-2);
  if (Mode and $40 = 0) and (Dot = 0) then
    Exit(-1);
  case Kind of
    2:
      Dot := Dot and 63;
    3:
      Dot := Dot and 127;
  end;
  case Kind of
    0:
      Result := (Color and $FFF0) or Dot;
    1:
      Result := VRWord(Cardinal(Color) * 8 + Cardinal(Dot) * 2);
    2:
      Result := (Color and $FFC0) or Dot;
    3:
      Result := (Color and $FF80) or Dot;
    4:
      Result := (Color and $FF00) or Dot;
  else
    Result := Dot;
  end;
end;

procedure TSaturnVDP1.Plot(X, Y: Integer; Color, Mode: Word; Shade: Integer);
begin
  var Width: Integer := 512;
  if FRegisters[0] and 1 <> 0 then
    Width := 1024;
  var MaxY: Integer := 256;
  if FRegisters[1] and 8 <> 0 then
    MaxY := 512;
  if (X < 0) or (X >= Width) or (Y < 0) or (Y >= MaxY) or (X > FSystemX) or (Y > FSystemY) then
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
  if Width = 1024 then
  begin
    FBuffer[FDraw, At div 2] := Color and $FF;
    Exit;
  end;
  var Old: Word := (Word(FBuffer[FDraw, At]) shl 8) or FBuffer[FDraw, At + 1];
  if Mode and $8000 <> 0 then
  begin
    FBuffer[FDraw, At] := (Old shr 8) or $80;
    Exit;
  end;
  var Calc: Integer := Mode and 7;
  if (Calc >= 4) and (Color and $8000 <> 0) then
  begin
    var NewColor: Word := $8000;
    for var C := 0 to 2 do
      NewColor := NewColor or (Word(EnsureRange(Integer((Color shr (C * 5)) and 31) + Integer((Shade shr (C * 5)) and 31) - 16, 0, 31)) shl (C * 5));
    Color := NewColor;
  end;
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
  FBuffer[FDraw, At] := Color shr 8;
  FBuffer[FDraw, At + 1] := Color and $FF;
end;

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

procedure TSaturnVDP1.Quad(const X, Y, U, V: array of Integer; Source: Cardinal; Width: Integer; Color, Mode: Word; Textured: Boolean; const Shades: array of Word);
begin
  // VDP1 fills lines between the A-D and B-C edges. Unlike two triangles,
  // this also covers concave, crossed and degenerate four-point commands.
  var Rows := Max(Max(Abs(X[3] - X[0]), Abs(Y[3] - Y[0])), Max(Abs(X[2] - X[1]), Abs(Y[2] - Y[1])));
  var Den := Max(1, Rows);
  for var Row := 0 to Rows do
  begin
    var AX := X[0] + (X[3] - X[0]) * Row div Den;
    var AY := Y[0] + (Y[3] - Y[0]) * Row div Den;
    var BX := X[1] + (X[2] - X[1]) * Row div Den;
    var BY := Y[1] + (Y[2] - Y[1]) * Row div Den;
    var AU := U[0] + (U[3] - U[0]) * Row div Den;
    var AV := V[0] + (V[3] - V[0]) * Row div Den;
    var BU := U[1] + (U[2] - U[1]) * Row div Den;
    var BV := V[1] + (V[2] - V[1]) * Row div Den;
    var Length := Max(Abs(BX - AX), Abs(BY - AY));
    var Span := Max(1, Length);
    var Ends: Integer := 0;
    for var Pixel := 0 to Length do
    begin
      var PX := AX + (BX - AX) * Pixel div Span;
      var PY := AY + (BY - AY) * Pixel div Span;
      var Dot: Integer := Color;
      if Textured then
        Dot := Texture(Source, Width, EnsureRange(AU + (BU - AU) * Pixel div Span, 0, Width - 1), Max(0, AV + (BV - AV) * Pixel div Span), Mode, Color);
      if Dot = -2 then
      begin
        Inc(Ends);
        if Ends >= 2 then
          Break;
      end;
      if Dot < 0 then
        Continue;
      var Shade: Integer := 0;
      for var Component := 0 to 2 do
      begin
        var SA: Integer := (Shades[0] shr (Component * 5)) and 31;
        var SD: Integer := (Shades[3] shr (Component * 5)) and 31;
        var SB: Integer := (Shades[1] shr (Component * 5)) and 31;
        var SC: Integer := (Shades[2] shr (Component * 5)) and 31;
        var Left := SA + (SD - SA) * Row div Den;
        var Right := SB + (SC - SB) * Row div Den;
        Shade := Shade or (EnsureRange(Left + (Right - Left) * Pixel div Span, 0, 31) shl (Component * 5));
      end;
      Plot(PX, PY, Dot, Mode, Shade);
    end;
  end;
end;

procedure TSaturnVDP1.Start;
begin
  FAddress := 0;
  FHasReturn := False;
  FBusy := True;
  FRegisters[8] := FRegisters[8] and 1;
  FNext := FTime + 16;
  FCommandCount := 0;
end;

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
  for var I := 0 to 3 do
  begin
    X[I] := Coordinate(VRWord(FAddress + 12 + Cardinal(I * 4))) + FLocalX;
    Y[I] := Coordinate(VRWord(FAddress + 14 + Cardinal(I * 4))) + FLocalY;
    Shades[I] := VRWord(Cardinal(VRWord(FAddress + 28)) * 8 + Cardinal(I * 2));
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
              for var I := 0 to 3 do
                U[I] := Width - 1 - U[I];
            if Control and $20 <> 0 then
              for var I := 0 to 3 do
                V[I] := Height - 1 - V[I];
        // Rectangles use exact integer coverage, including one-pixel sprites.
            if (Control and 15 = 0) then
            begin
              for var PY := 0 to Height - 1 do
              begin
                var Ends: Integer := 0;
                for var PX := 0 to Width - 1 do
                begin
                  var TU := PX;
                  var TV := PY;
                  if Control and $10 <> 0 then
                    TU := Width - 1 - PX;
                  if Control and $20 <> 0 then
                    TV := Height - 1 - PY;
                  var Dot := Texture(Source, Width, TU, TV, Mode, Color);
                  if Dot = -2 then
                  begin
                    Inc(Ends);
                    if Ends >= 2 then
                      Break;
                  end
                  else if Dot >= 0 then
                  begin
                    var Shade: Integer := $4210;
                    if Mode and 4 <> 0 then
                    begin
                      var WX: Integer := Max(1, Width - 1);
                      var HY: Integer := Max(1, Height - 1);
                      Shade := 0;
                      for var Component := 0 to 2 do
                      begin
                        var A: Integer := (Shades[0] shr (Component * 5)) and 31;
                        var B: Integer := (Shades[1] shr (Component * 5)) and 31;
                        var C: Integer := (Shades[2] shr (Component * 5)) and 31;
                        var D: Integer := (Shades[3] shr (Component * 5)) and 31;
                        Shade := Shade or (((A * (WX - PX) * (HY - PY) + B * PX * (HY - PY) + C * PX * PY + D * (WX - PX) * PY) div (WX * HY)) shl (Component * 5));
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
        for var I := 0 to 3 do
          Line(X[I], Y[I], X[(I + 1) and 3], Y[(I + 1) and 3], Color, Mode, Shades[I], Shades[(I + 1) and 3]);
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

procedure TSaturnVDP1.Advance(Target: Int64);
begin
  if Target < FTime then
    raise EArgumentException.Create('VDP1 time');
  FTime := Target;
  while FBusy and (FNext <= Target) do
  begin
    Command;
    Inc(FNext, FCommandCost);
  end;
end;

procedure TSaturnVDP1.Erase;
begin
  var X0: Integer := ((FRegisters[4] shr 9) and 63) * 8;
  var Y0: Integer := FRegisters[4] and $1FF;
  var X1: Integer := Min(511, ((FRegisters[5] shr 9) and 127) * 8 - 1);
  var Y1: Integer := Min(255, FRegisters[5] and $1FF);
  if FRegisters[0] and 1 <> 0 then
  begin
    X0 := X0 * 2;
    X1 := Min(1023, ((FRegisters[5] shr 9) and 127) * 16 - 1);
  end;
  for var Y := Y0 to Y1 do
    for var X := X0 to X1 do
    begin
      if FRegisters[0] and 1 <> 0 then
      begin
        var At := Y * 1024 + X;
        if Odd(X) then
          FBuffer[FDraw, At] := FRegisters[3] and $FF
        else
          FBuffer[FDraw, At] := FRegisters[3] shr 8;
      end
      else
      begin
        var At: Integer := (Y * 512 + X) * 2;
        FBuffer[FDraw, At] := FRegisters[3] shr 8;
        FBuffer[FDraw, At + 1] := FRegisters[3] and $FF;
      end;
    end;
end;

procedure TSaturnVDP1.VBlank;
begin
  if (FRegisters[1] and 2 = 0) or FChange then
  begin
    FDisplay := FDraw;
    FDraw := FDraw xor 1;
    FChange := False;
    FRegisters[9] := FRegisters[10];
    FRegisters[8] := (FRegisters[8] shr 1) and 1;
    Erase;
  end;
  if FRegisters[2] and 3 = 2 then
    Start;
end;

function TSaturnVDP1.ReadRegister(Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := 0;
  for var I := 0 to Size - 1 do
  begin
    var A: Integer := (UInt64(Address) + Cardinal(I)) and $1F;
    var V: Word := 0;
    if A div 2 <= 11 then
      V := FRegisters[A div 2];
    if A and not 1 = 22 then
      V := $1000 or (FRegisters[0] and 15) or ((FRegisters[1] and $1F) shl 4) or ((FRegisters[2] and 3) shl 8);
    Result := (Result shl 8) or ((V shr ((1 - (A and 1)) * 8)) and $FF);
  end;
end;

procedure TSaturnVDP1.WriteRegister(Address, Value: Cardinal; Size: Integer);
begin
  if (Size <> 2) and (Size <> 4) then
    Exit;
  for var I := 0 to Size div 2 - 1 do
  begin
    var A: Integer := ((Address div 2) + Cardinal(I)) and 15;
    if A > 7 then
      Continue;
    FRegisters[A] := (Value shr ((Size div 2 - I - 1) * 16)) and $FFFF;
    case A of
      1:
        if FRegisters[1] and 3 = 3 then
          FChange := True
        else if FRegisters[1] and 3 = 2 then
          Erase;
      2:
        if FRegisters[2] and 3 = 1 then
          Start;
      6:
        FBusy := False;
    end;
  end;
end;

procedure TSaturnVDP1.SerializeState(Archive: TStateArchive);
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
  if not (FDraw in [0, 1]) or not (FDisplay in [0, 1]) or (FTime < 0) or (FNext < 0) or (FAddress > $80000) or (FCommandCount < 0) then
    raise EReadError.Create('VDP1 framebuffer');
end;

end.

