unit N64.RDP;

interface

uses
  System.SysUtils, System.Classes, System.Math, N64.Types, Core.Snapshots;

type
  TN64RDPCommandTrace = procedure(const Words: TArray<Cardinal>) of object;

  TN64Texel = record
    C: array[0..3] of Integer; // RGBA, nine bits including signed conversion output.
  end;

  TN64Tile = record
    Format, Size, Line, TMEM, Palette, SL, TL, SH, TH: Integer;
    ClampS, ClampT, MirrorS, MirrorT: Boolean;
    MaskS, MaskT, ShiftS, ShiftT: Integer;
  end;

  TN64RDP = class
  private
    FBus: TN64Bus;
    FTMEM: array[0..4095] of Byte;
    FTiles: array[0..7] of TN64Tile;
    FColorAddress, FTextureAddress, FFill, FPrimitive, FEnvironment, FOtherHi, FOtherLo: Cardinal;
    FCombineHi, FCombineLo: Cardinal;
    FBlendColor, FFogColor: Cardinal;
    FZAddress, FPrimitiveDepth, FPrimitiveDelta, FPrimitiveLOD: Cardinal;
    FKeyWidth, FKeyCenter, FKeyScale: array[0..2] of Integer;
    FNoiseSeed, FNoise: Cardinal;
    FLODFraction, FMinLevel, FShadeAlpha, FAlphaDither: Integer;
    FColorFormat: Integer;
    FConvert: array[0..5] of Integer;
    FHasCombine: Boolean;
    FColorWidth, FColorSize, FTextureWidth, FTextureSize, FTextureFormat: Integer;
    FScissorX0, FScissorY0, FScissorX1, FScissorY1: Integer;
    FScissorQuarterX0, FScissorQuarterY0, FScissorQuarterX1, FScissorQuarterY1: Integer;
    FScissorField, FScissorOdd: Boolean;
    FCommand: array[0..43] of Cardinal;
    FCommandCount: Integer;
    FWorkClocks: UInt64;
    FTransferBits: UInt64;
    FPipelineCrashed: Boolean;
    FHiddenOld: array[0..7] of Byte;
    FDrawFlip: Boolean;
    FDelayedHidden: Integer;
    FMemoryColor: Cardinal;
    FMemoryCoverage: Integer;
    FOnCommand: TN64RDPCommandTrace;
    FOnCommandCompleted: TN64RDPCommandTrace;
    function Color16(V: Word): Cardinal;
    procedure Pixel(X, Y: Integer; Color: Cardinal; Fill: Boolean = False; Depth: Integer = -1; Delta: Cardinal = 1; Coverage: Integer = 8; CoverageBit: Boolean = True);
    function Texture(Tile: Integer; S, T: Int64; Cycle: Integer; const Previous: TN64Texel): TN64Texel;
    function TextureTexel(Tile, S, T: Integer): TN64Texel;
    procedure LoadTexture(Tile, SL, TL, SH, TH: Integer; Block: Boolean);
    function Combine(Texel: TN64Texel; Shade: Cardinal; Texel1, TexelNext: TN64Texel): Cardinal;
    procedure Dither(X, Y: Integer; out RGB, Alpha: Integer);
    procedure Triangle(Code: Cardinal);
    procedure Rectangle(Code: Cardinal);
    procedure WriteFramebuffer8(Address: Cardinal; Value: Byte);
    procedure CompleteDelayedHidden;
  public
    constructor Create(Bus: TN64Bus);
    procedure Reset;
    function Execute(Start, Finish: Cardinal; XBUS: Boolean; out Consumed: Cardinal): Boolean;
    procedure SerializeState(State: TStateArchive);
    function Describe: string;
    // Deterministic RCP work estimate. Pipeline stalls/overlap remain approximate.
    property WorkClocks: UInt64 read FWorkClocks;
    property PipelineCrashed: Boolean read FPipelineCrashed;
    property OnCommand: TN64RDPCommandTrace read FOnCommand write FOnCommand;
    property OnCommandCompleted: TN64RDPCommandTrace read FOnCommandCompleted write FOnCommandCompleted;
  end;

implementation

// Arithmetic right shift without relying on signed host shifts or unchecked casts.

function FloorDiv(Value, Divisor: Int64): Int64; inline;
begin
  Result := Value div Divisor;
  if (Value < 0) and (Value mod Divisor <> 0) then
    Dec(Result);
end;

function ShiftRight(Value: Int64; Count: Integer): Int64; inline;
begin
  Result := FloorDiv(Value, Int64(1) shl Count);
end;

function WrapSigned32(Value: Int64): Int64; inline;
begin
  Result := SignedValue(SX(UInt64(Value and $FFFFFFFF), 32));
end;

function Clamp9(Value: Integer): Integer; inline;
begin
  Value := Value and $1FF;
  case Value shr 7 of
    0, 1:
      Result := Value;
    2:
      Result := 255;
  else
    Result := 0;
  end;
end;

constructor TN64RDP.Create(Bus: TN64Bus);
begin
  inherited Create;
  FBus := Bus;
  Reset
end;

function TexelFromRGBA(Color: Cardinal): TN64Texel; inline;
begin
  for var I := 0 to 3 do
    Result.C[I] := (Color shr ((3 - I) * 8)) and $FF;
end;

function TexelToRGBA(const Texel: TN64Texel): Cardinal; inline;
begin
  Result := 0;
  for var I := 0 to 3 do
    Result := (Result shl 8) or Cardinal(Clamp9(Texel.C[I]));
end;

function TN64RDP.Describe: string;
begin
  Result := Format('color=%6.6x width=%d size=%d z=%6.6x modes=%6.6x/%8.8x combine=%6.6x/%8.8x scissor=%d,%d:%d,%d',
    [FColorAddress, FColorWidth, FColorSize, FZAddress, FOtherHi, FOtherLo, FCombineHi, FCombineLo,
      FScissorX0, FScissorY0, FScissorX1, FScissorY1]);
end;

procedure TN64RDP.Reset;
begin
  for var I := 0 to 4095 do
    FTMEM[I] := 0;
  for var I := 0 to 7 do
    FTiles[I] := Default(TN64Tile);
  FColorAddress := 0;
  FTextureAddress := 0;
  FFill := 0;
  FPrimitive := $FFFFFFFF;
  FEnvironment := 0;
  FOtherHi := 0;
  FOtherLo := 0;
  FColorWidth := 320;
  FColorSize := 2;
  FCombineHi := 0;
  FCombineLo := 0;
  FHasCombine := False;
  FBlendColor := 0;
  FFogColor := 0;
  FZAddress := 0;
  FPrimitiveDepth := 0;
  FPrimitiveDelta := 0;
  FPrimitiveLOD := 0;
  FMinLevel := 0;
  FLODFraction := 0;
  FShadeAlpha := 0;
  FAlphaDither := 0;
  FNoiseSeed := 3;
  FNoise := 0;
  FColorFormat := 0;
  FScissorQuarterX0 := 0;
  FScissorQuarterY0 := 0;
  FScissorQuarterX1 := 4096;
  FScissorQuarterY1 := 4096;
  FScissorField := False;
  FScissorOdd := False;
  for var I := 0 to 2 do
  begin
    FKeyWidth[I] := 0;
    FKeyCenter[I] := 0;
    FKeyScale[I] := 0;
  end;
  for var I := 0 to High(FConvert) do
    FConvert[I] := 0;
  FTextureWidth := 1;
  FTextureSize := 2;
  FTextureFormat := 0;
  FScissorX0 := 0;
  FScissorY0 := 0;
  FScissorX1 := 1024;
  FScissorY1 := 1024;
  FCommandCount := 0;
  FWorkClocks := 0;
  FTransferBits := 0;
  FPipelineCrashed := False;
  FDrawFlip := False;
  FDelayedHidden := -1;
  FMemoryColor := 0;
  FMemoryCoverage := 0;
  for var I := 0 to High(FHiddenOld) do
    FHiddenOld[I] := 0;
  for var I := 0 to High(FCommand) do
    FCommand[I] := 0;
end;

function TN64RDP.Color16(V: Word): Cardinal;
begin
  var R := (V shr 11) and 31;
  var G := (V shr 6) and 31;
  var B := (V shr 1) and 31;
  Result := (((Cardinal(R) shl 3) or (R shr 2)) shl 24) or
    (((Cardinal(G) shl 3) or (G shr 2)) shl 16) or
    (((Cardinal(B) shl 3) or (B shr 2)) shl 8);
  if (V and 1) <> 0 then
    Result := Result or $FF;
end;

procedure TN64RDP.CompleteDelayedHidden;
begin
  if (FDelayedHidden >= 0) and (FDelayedHidden < $800000) then
  begin
    var Address := Cardinal(FDelayedHidden);
    var Hidden := (FBus.ReadHidden(Address) and 1) or (FHiddenOld[(Address div 2) and 7] and 2);
    FBus.WriteHidden(Address, Hidden);
  end;
  FDelayedHidden := -1;
end;

procedure TN64RDP.WriteFramebuffer8(Address: Cardinal; Value: Byte);
begin
  if Address >= $800000 then
    Exit;
  var Hidden := FBus.ReadHidden(Address);
  var OldIndex := (Address div 2) and 7;
  if not FDrawFlip then
  begin
    if Odd(Address) then
      Hidden := (Hidden and 2) or (Value and 1)
    else
      Hidden := (Hidden and 1) or (FHiddenOld[OldIndex] and 2);
  end
  else
  begin
    if (FDelayedHidden >= 0) and (Cardinal(FDelayedHidden) < Address) then
      CompleteDelayedHidden;
    if Odd(Address) then
    begin
      if FDelayedHidden >= 0 then
        Hidden := Byte((Value and 1) * 3)
      else
        Hidden := (Hidden and 2) or (Value and 1);
      FDelayedHidden := -1;
    end
    else
      FDelayedHidden := Integer(Address + 1);
  end;
  FBus.Write8(Address, Value);
  FBus.WriteHidden(Address, Hidden);
  if Odd(Address) then
    FHiddenOld[OldIndex] := Byte((Value and 1) * 3);
end;

procedure TN64RDP.Dither(X, Y: Integer; out RGB, Alpha: Integer);
const
  Magic: array[0..15] of Byte = (0, 6, 1, 7, 4, 2, 5, 3, 3, 5, 2, 4, 7, 1, 6, 0);
  Bayer: array[0..15] of Byte = (0, 4, 1, 5, 4, 0, 5, 1, 3, 7, 2, 6, 7, 3, 6, 2);
begin
  var Cycle := (FOtherHi shr 20) and 3;
  var NeedsNoise := (((FCombineHi shr 5) and 15) = 7) or (((FOtherHi shr 4) and 3) = 2);
  if Cycle = 1 then
    NeedsNoise := NeedsNoise or (((FCombineHi shr 20) and 15) = 7);
  if NeedsNoise then
  begin
    FNoiseSeed := Cardinal((UInt64(FNoiseSeed) * $343FD + $269EC3) and $FFFFFFFF);
    FNoise := (((FNoiseSeed shr 16) and 7) shl 6) or $20;
  end;
  if FScissorField then
    Y := Y shr 1;
  var Index := ((Y and 3) shl 2) or (X and 3);
  var RGBMode := (FOtherHi shr 6) and 3;
  case RGBMode of
    0:
      RGB := Magic[Index];
    1:
      RGB := Bayer[Index];
    2:
      begin
        FNoiseSeed := Cardinal((UInt64(FNoiseSeed) * $343FD + $269EC3) and $FFFFFFFF);
        RGB := (FNoiseSeed shr 16) and $7FFF;
      end;
  else
    RGB := 7
  end;
  var Matrix := Integer(Magic[Index]);
  if RGBMode in [1, 3] then
    Matrix := Bayer[Index];
  case (FOtherHi shr 4) and 3 of
    0:
      Alpha := Matrix;
    1:
      Alpha := Matrix xor 7;
    2:
      Alpha := (FNoise shr 6) and 7;
  else
    Alpha := 0
  end;
  FAlphaDither := Alpha;
end;

procedure TN64RDP.Pixel(X, Y: Integer; Color: Cardinal; Fill: Boolean; Depth: Integer; Delta: Cardinal; Coverage: Integer; CoverageBit: Boolean);
const
  ZShift: array[0..7] of Integer = (6, 5, 4, 3, 2, 1, 0, 0);
  ZBase: array[0..7] of Cardinal = (0, $20000, $30000, $38000, $3C000, $3E000, $3F000, $3F800);
  Magic: array[0..15] of Byte = (0, 6, 1, 7, 4, 2, 5, 3, 3, 5, 2, 4, 7, 1, 6, 0);
  Bayer: array[0..15] of Byte = (0, 4, 1, 5, 4, 0, 5, 1, 3, 7, 2, 6, 7, 3, 6, 2);
var
  MemoryColor, InputColor, BlendedColor: Cardinal;
  MemoryCoverage, DZEncode, OldDZEncode, BlendShiftA, BlendShiftB: Integer;
  BlendEnabled, PreWrap: Boolean;

  function Source(Index, Cycle: Integer): Cardinal;
  begin
    case Index of
      0:
        if Cycle = 0 then
          Result := InputColor
        else
          Result := BlendedColor;
      1:
        Result := MemoryColor;
      2:
        Result := FBlendColor;
    else
      Result := FFogColor
    end;
  end;

  function EncodedDZ(V: Cardinal): Integer;
  begin
    Result := 0;
    V := V and $FFFF;
    while V > 1 do
    begin
      V := V shr 1;
      Inc(Result)
    end;
  end;

  function BlenderDivide(Denominator, Numerator: Integer): Integer;
  begin
    // The RDP divider is an eight-step restoring divider, not a host division.
    var D := (Denominator shr 2) and 15;
    var N := Numerator and $7FF;
    var InverseD := D xor 15;
    var Remainder := (InverseD + (N shr 8) + 1) and 7;
    Result := 0;
    for var K := 0 to 7 do
    begin
      var Bit := (N shr (7 - K)) and 1;
      var Temp := D + Remainder * 2 + Bit;
      if (Result and (256 shr K)) <> 0 then
        Temp := InverseD + Remainder * 2 + Bit + 1;
      Remainder := Temp and 7;
      if (Temp and 16) <> 0 then
        Result := Result or (1 shl (7 - K));
    end;
  end;

  function Blend(Cycle: Integer; AlwaysBlend: Boolean): Cardinal;
  begin
    var M1A := Integer((FOtherLo shr (30 - Cycle * 2)) and 3);
    var M1B := Integer((FOtherLo shr (26 - Cycle * 2)) and 3);
    var M2A := Integer((FOtherLo shr (22 - Cycle * 2)) and 3);
    var M2B := Integer((FOtherLo shr (18 - Cycle * 2)) and 3);
    var First := Source(M1A, Cycle);
    var Second := Source(M2A, Cycle);
    if ((FOtherLo and $80) <> 0) and not PreWrap then
      Exit(Second);
    // Partial reject: the standard input/inverse-input-alpha equation bypasses blending at alpha=255.
    var PartialReject := (M1B = 0) and (M2B = 0) and ((InputColor and $FF) = $FF);
    if not AlwaysBlend and (not BlendEnabled or PartialReject) then
      Exit(First);
    var Alpha := Integer(InputColor and $FF);
    case M1B of
      1:
        Alpha := FFogColor and $FF;
      2:
        Alpha := FShadeAlpha;
      3:
        Alpha := 0
    end;
    var Beta := Alpha xor 255;
    case M2B of
      1:
        Beta := MemoryCoverage shl 5;
      2:
        Beta := 255;
      3:
        Beta := 0
    end;
    Alpha := Alpha shr 3;
    Beta := Beta shr 3;
    if M2B = 1 then
    begin
      Alpha := (Alpha shr BlendShiftA) and $3C;
      Beta := (Beta shr BlendShiftB) or 3;
    end;
    Result := InputColor and $FF;
    for var Channel := 1 to 3 do
    begin
      var Value := Integer((First shr (Channel * 8)) and $FF) * Alpha +
        Integer((Second shr (Channel * 8)) and $FF) * (Beta + 1);
      if AlwaysBlend or ((FOtherLo and $4000) <> 0) then
        Value := (Value shr 5) and $FF
      else
        Value := BlenderDivide((Alpha and $3C) + (Beta and $3C) + 4, (Value shr 2) and $7FF);
      Result := Result or (Cardinal(Value) shl (Channel * 8));
    end;
  end;

begin
  if (X < FScissorX0) or (X >= FScissorX1) or (Y < FScissorY0) or (Y >= FScissorY1) or
    (X < 0) or (X >= 1024) or (Y < 0) or (Y >= 1024) then
    Exit;
  if FScissorField and (Odd(Y) <> FScissorOdd) then
    Exit;
  var BPP := 1;
  if FColorSize >= 2 then
    BPP := 1 shl (FColorSize - 1);
  var Offset := Cardinal((Y * FColorWidth + X) * BPP);
  var Address := UInt64(FColorAddress) + Offset;
  if Address + Cardinal(BPP) > $800000 then
    Exit;
  var A := Cardinal(Address);
  var Cycle := (FOtherHi shr 20) and 3;
  if Cycle = 1 then
    Inc(FWorkClocks, 2)
  else if Cycle = 0 then
    Inc(FWorkClocks)
  else
    Inc(FTransferBits, Cardinal(BPP * 8));
  if Fill then
  begin
    case FColorSize of
      0:
        Exit; // 4-bit fill crashes the guest RDP pipeline; never a host error.
        1:
        begin
          var V := Byte((FFill shr ((3 - (A and 3)) * 8)) and $FF);
          WriteFramebuffer8(A, V);
        end;
      2:
        begin
          var V: Word;
          if (A and 2) = 0 then
            V := Word(FFill shr 16)
          else
            V := Word(FFill and $FFFF);
          FBus.Write8(A, Byte(V shr 8));
          FBus.Write8(A + 1, Byte(V and $FF));
          FBus.WriteHidden(A, Byte((V and 1) * 3));
          FHiddenOld[(A div 2) and 7] := Byte((V and 1) * 3);
        end;
      3:
        begin
          FBus.Write32(A, FFill);
          FBus.WriteHidden(A, Byte(((FFill shr 16) and 1) * 3));
          FBus.WriteHidden(A + 2, Byte((FFill and 1) * 3));
          FHiddenOld[(A div 2) and 7] := Byte(((FFill shr 16) and 1) * 3);
          FHiddenOld[((A div 2) + 1) and 7] := Byte((FFill and 1) * 3);
        end;
    end;
    Exit;
  end;
  InputColor := Color;
  var PreviousMemoryColor := FMemoryColor;
  var PreviousMemoryCoverage := FMemoryCoverage;
  MemoryColor := (FMemoryColor and $FFFFFF00) or $E0;
  MemoryCoverage := 7;
  if (FOtherLo and $40) <> 0 then
  begin
    case FColorSize of
      1:
        begin
          var V := Cardinal(FBus.Read8(A));
          MemoryColor := (V shl 24) or (V shl 16) or (V shl 8) or $E0
        end;
      2:
        begin
          var V := (Word(FBus.Read8(A)) shl 8) or FBus.Read8(A + 1);
          MemoryColor := Color16(V) and $F8F8F800;
          MemoryCoverage := ((V and 1) shl 2) or FBus.ReadHidden(A);
          if FColorFormat <> 0 then
          begin
            var I := Cardinal(V shr 8);
            MemoryColor := (I shl 24) or (I shl 16) or (I shl 8);
            MemoryCoverage := (V shr 5) and 7;
          end;
          MemoryColor := MemoryColor or Cardinal(MemoryCoverage shl 5);
        end;
      3:
        begin
          MemoryColor := FBus.Read32(A);
          MemoryCoverage := (MemoryColor shr 5) and 7
        end;
    end;
  end;
  var Alpha := Integer(InputColor and $FF);
  if Cycle < 2 then
  begin
    FMemoryColor := MemoryColor;
    FMemoryCoverage := MemoryCoverage
  end;
  var AlphaProduct := 0;
  if Alpha = 255 then
    Alpha := 256;
  if (Cycle < 2) and ((FOtherLo and $1000) <> 0) then
  begin
    AlphaProduct := (Alpha * Coverage + 4) shr 3;
    Coverage := (AlphaProduct shr 5) and 15;
  end;
  if (Cycle < 2) and ((FOtherLo and $2000) <> 0) then
    if (FOtherLo and $1000) <> 0 then
      Alpha := Min(255, AlphaProduct)
    else
      Alpha := Min(255, Coverage shl 5)
  else if Cycle < 2 then
    Alpha := Min(255, Alpha + FAlphaDither)
  else
    Alpha := Min(255, Alpha);
  InputColor := (InputColor and $FFFFFF00) or Cardinal(Alpha);
  if (FOtherLo and 1) <> 0 then
  begin
    var Threshold := Integer(FBlendColor and $FF);
    if (FOtherLo and 2) <> 0 then
    begin
      FNoiseSeed := Cardinal((UInt64(FNoiseSeed) * $343FD + $269EC3) and $FFFFFFFF);
      Threshold := (FNoiseSeed shr 16) and $FF;
    end;
    if (Cycle = 2) and (FColorSize = 2) then
    begin
      if Alpha < 128 then
        Exit
    end
    else if Alpha < Threshold then
      Exit;
  end;
  if ((FOtherLo and 8) <> 0) then
  begin
    if Coverage = 0 then
      Exit
  end
  else if not CoverageBit then
    Exit;
  PreWrap := ((MemoryCoverage + Coverage) and 8) <> 0;
  BlendEnabled := ((FOtherLo and $4000) <> 0) or (((FOtherLo and 8) <> 0) and not PreWrap);
  if (FOtherLo and 4) <> 0 then
  begin
    Depth := Integer(FPrimitiveDepth);
    Delta := FPrimitiveDelta
  end;
  var ZAddress := UInt64(FZAddress) + Cardinal((Y * FColorWidth + X) * 2);
  var UseDepth := (Depth >= 0) and (ZAddress + 2 <= $800000) and (Cycle < 2);
  DZEncode := EncodedDZ(Delta);
  BlendShiftA := 0;
  BlendShiftB := Max(0, 15 - DZEncode);
  if BlendShiftB > 4 then
    BlendShiftB := 4;
  if UseDepth and ((FOtherLo and $10) <> 0) then
  begin
    var ZA := Cardinal(ZAddress);
    var Stored := (Cardinal(FBus.Read8(ZA)) shl 8) or FBus.Read8(ZA + 1);
    var Level := (Stored shr 13) and 7;
    var OldZ := (((Stored shr 2) and $7FF) shl ZShift[Level]) + ZBase[Level];
    OldDZEncode := Integer((Stored and 3) shl 2) or FBus.ReadHidden(ZA);
    var OldDZ := Cardinal(1) shl OldDZEncode;
    var Coplanar := False;
    if Level < 3 then
      if OldDZ = $8000 then
      begin
        Coplanar := True;
        OldDZ := $FFFF
      end
      else
        OldDZ := Max(OldDZ * 2, Cardinal(16) shr Level);
    var DZ := Cardinal(1) shl EncodedDZ((Delta or OldDZ) and $FFFF);
    if (Delta or OldDZ) = 0 then
      DZ := 0;
    var Tolerance := DZ * 8;
    var Farther := Coplanar or (Int64(Depth) + Tolerance >= OldZ);
    var Nearer := Coplanar or (Int64(Depth) - Tolerance <= OldZ);
    var InFront := Cardinal(Depth) < OldZ;
    var IsMax := OldZ = $3FFFF;
    BlendShiftA := EnsureRange(DZEncode - OldDZEncode, 0, 4);
    BlendShiftB := EnsureRange(OldDZEncode - DZEncode, 0, 4);
    BlendEnabled := ((FOtherLo and $4000) <> 0) or (((FOtherLo and 8) <> 0) and not PreWrap and Farther);
    case (FOtherLo shr 10) and 3 of
      0:
        if not IsMax and ((PreWrap and not InFront) or (not PreWrap and not Nearer)) then
          Exit;
      1:
        if InFront and Farther and PreWrap then
        begin
          var Coefficient := ((OldZ shr EncodedDZ(DZ)) - (Cardinal(Depth) shr EncodedDZ(DZ))) and 15;
          Coverage := Integer((Coefficient * Cardinal(Coverage) shr 3) and 15);
        end
        else if not IsMax and ((PreWrap and not InFront) or (not PreWrap and not Nearer)) then
          Exit;
      2:
        if not InFront and not IsMax then
          Exit;
      3:
        if not Farther or not Nearer or IsMax then
          Exit;
    end;
  end;
  if Cycle < 2 then
  begin
    BlendedColor := InputColor;
    if Cycle = 1 then
    begin
      var CurrentMemoryColor := MemoryColor;
      var CurrentMemoryCoverage := MemoryCoverage;
      MemoryColor := PreviousMemoryColor;
      MemoryCoverage := PreviousMemoryCoverage;
      BlendedColor := Blend(0, True);
      MemoryColor := CurrentMemoryColor;
      MemoryCoverage := CurrentMemoryCoverage;
    end;
    Color := Blend(Integer(Cycle), False);
    var RGBDither := (FOtherHi shr 6) and 3;
    if RGBDither <> 3 then
    begin
      var Index := ((Y and 3) shl 2) or (X and 3);
      var DitherValue := Integer(Magic[Index]);
      if RGBDither = 1 then
        DitherValue := Bayer[Index];
      if RGBDither = 2 then
        DitherValue := FNoise;
      var Dithered := Color and $FF;
      for var Channel := 1 to 3 do
      begin
        var V := Integer((Color shr (Channel * 8)) and $FF);
        var Threshold := DitherValue;
        if RGBDither = 2 then
          Threshold := (DitherValue shr ((3 - Channel) * 3)) and 7;
        if (V and 7) > Threshold then
          V := Min(255, (V and $F8) + 8);
        Dithered := Dithered or (Cardinal(V) shl (Channel * 8));
      end;
      Color := Dithered;
    end;
  end;
  var FinalCoverage := 7;
  if Cycle < 2 then
    case (FOtherLo shr 8) and 3 of
      0:
        begin
          if BlendEnabled then
            FinalCoverage := Coverage + MemoryCoverage
          else
            FinalCoverage := Coverage - 1;
          if (FinalCoverage and 8) <> 0 then
            FinalCoverage := 7
          else
            FinalCoverage := FinalCoverage and 7
        end;
      1:
        FinalCoverage := (Coverage + MemoryCoverage) and 7;
      2:
        FinalCoverage := 7;
      3:
        FinalCoverage := MemoryCoverage;
    end;
  if UseDepth and ((FOtherLo and $20) <> 0) then
  begin
    var Z := Cardinal(EnsureRange(Depth, 0, $3FFFF));
    var Level := 7;
    while (Level > 0) and (Z < ZBase[Level]) do
      Dec(Level);
    var Stored := Word((Cardinal(Level) shl 13) or (((Z - ZBase[Level]) shr ZShift[Level]) shl 2) or Cardinal(DZEncode shr 2));
    FBus.Write8(Cardinal(ZAddress), Byte(Stored shr 8));
    FBus.Write8(Cardinal(ZAddress + 1), Byte(Stored and $FF));
    FBus.WriteHidden(Cardinal(ZAddress), Byte(DZEncode and 3));
  end;
  case FColorSize of
    0:
      FBus.Write8(A, 0);
    1:
      begin
        var V := Byte((Color shr 24) and $FF);
        if Odd(A) then
          V := Byte((Color shr 16) and $FF);
        WriteFramebuffer8(A, V);
      end;
    2:
      begin
        var V := Word(((Color shr 27) shl 11) or (((Color shr 19) and 31) shl 6) or
          (((Color shr 11) and 31) shl 1) or Cardinal(FinalCoverage shr 2));
        if Cycle = 2 then
        begin
          V := (V and $FFFE) or Word(Ord((Color and $FF) >= 128));
          FinalCoverage := Integer(V and 1) * 3;
        end;
        if FColorFormat <> 0 then
        begin
          V := Word(((Color shr 24) shl 8) or Cardinal(FinalCoverage shl 5));
          FinalCoverage := 0
        end;
        if Cycle = 2 then
          if FDrawFlip then
          begin
            WriteFramebuffer8(A, Byte(V shr 8));
            WriteFramebuffer8(A + 1, Byte(V and $FF))
          end
          else
          begin
            WriteFramebuffer8(A + 1, Byte(V and $FF));
            WriteFramebuffer8(A, Byte(V shr 8))
          end
        else
        begin
          FBus.Write8(A, Byte(V shr 8));
          FBus.Write8(A + 1, Byte(V and $FF));
          FBus.WriteHidden(A, Byte(FinalCoverage and 3));
          FHiddenOld[(A div 2) and 7] := Byte(FinalCoverage and 3);
        end;
      end;
    3:
      begin
        var V := (Color and $FFFFFF00) or Cardinal(FinalCoverage shl 5);
        FBus.Write32(A, V);
        FBus.WriteHidden(A, Byte(((Color shr 16) and 1) * 3));
        FBus.WriteHidden(A + 2, 0);
        FHiddenOld[(A div 2) and 7] := Byte(((Color shr 16) and 1) * 3);
        FHiddenOld[((A div 2) + 1) and 7] := 0;
      end;
  end;
end;

function WrapCoord(Value: Int64; Limit, Mask, Shift: Integer; Clamp, Mirror: Boolean): Integer;
begin
  if Shift <= 10 then
    Value := Value div (1 shl Shift)
  else
    Value := Value * (1 shl (16 - Shift));
  if Clamp then
    Value := EnsureRange(Value, Int64(0), Int64(Max(0, Limit)));
  if Mask > 0 then
  begin
    Mask := Min(Mask, 10);
    var M := (1 shl Mask) - 1;
    if Mirror and ((Value and (M + 1)) <> 0) then
      Value := not Value;
    Value := Value and M;
  end;
  Result := Integer(Value and $FFFF);
end;

function Floor256(Value: Int64): Integer;
begin
  Result := Integer(Value div 256);
  if (Value < 0) and (Value mod 256 <> 0) then
    Dec(Result);
end;

function TN64RDP.TextureTexel(Tile, S, T: Integer): TN64Texel;
begin
  var R := FTiles[Tile];
  S := WrapCoord(S, (R.SH div 4 - R.SL div 4) and $3FF, R.MaskS, 0, R.ClampS or (R.MaskS = 0), R.MirrorS);
  T := WrapCoord(T, (R.TH div 4 - R.TL div 4) and $3FF, R.MaskT, 0, R.ClampT or (R.MaskT = 0), R.MirrorT);
  var Size := R.Size;
  var Bits := 4 shl Size;
  var Row := T and $FF;
  var Address := Integer((Int64(R.TMEM) * 8 + Int64(Row) * R.Line * 8 + Int64(S) * Bits div 8) and $FFF);
  if Size = 3 then
    Address := Integer((Int64(R.TMEM) * 8 + Int64(Row) * R.Line * 8 + Int64(S) * 2) and $FFF);
  if R.Format = 1 then
    Address := Integer((Int64(R.TMEM) * 8 + Int64(Row) * R.Line * 8 + S) and $7FF);
  if Odd(T) then
    Address := Address xor 4;
  var V := Cardinal(FTMEM[Address]);
  if Size >= 2 then
    V := (V shl 8) or FTMEM[(Address + 1) and $FFF];
  if (Size = 3) and (R.Format = 0) then
  begin
    Address := Address and $7FF;
    V := (Cardinal(FTMEM[Address]) shl 24) or (Cardinal(FTMEM[(Address + 1) and $7FF]) shl 16) or
      (Cardinal(FTMEM[Address or $800]) shl 8) or FTMEM[((Address + 1) and $7FF) or $800];
  end;
  if Size = 0 then
    if (S and 1) = 0 then
      V := V shr 4
    else
      V := V and 15;
  if (FOtherHi and $8000) <> 0 then
  begin
    if Size = 0 then
      V := Cardinal(R.Palette * 16) + V
    else if Size >= 2 then
      V := (V shr ((Size - 1) * 8)) and $FF;
    var PA := ($800 + Integer(V and $FF) * 8 + ((Address shr 1) and 3) * 2) and $FFF;
    var Palette := (Cardinal(FTMEM[PA]) shl 8) or FTMEM[(PA + 1) and $FFF];
    if (FOtherHi and $4000) = 0 then
      Exit(TexelFromRGBA(Color16(Word(Palette))));
    Result.C[0] := Palette shr 8;
    Result.C[1] := Result.C[0];
    Result.C[2] := Result.C[0];
    Result.C[3] := Palette and $FF;
    Exit;
  end;
  Result := Default(TN64Texel);
  case R.Format of
    0:
      begin
        if Size = 3 then
          Exit(TexelFromRGBA(V));
        if Size = 2 then
          Exit(TexelFromRGBA(Color16(Word(V))));
        if Size = 0 then
          V := V * 17;
        for var I := 0 to 3 do
          Result.C[I] := Integer(V);
      end;
    1:
      if Size <= 1 then
      begin
        var Y := Integer(FTMEM[Address]);
        if Size = 0 then
          Y := (Y and $F0) or (Y shr 4);
        Result.C[0] := Y - 128;
        Result.C[1] := Y - 128;
        Result.C[2] := Y;
        Result.C[3] := Y;
      end
      else
      begin
        Result.C[0] := Integer(FTMEM[Address and $7FE]) - 128;
        Result.C[1] := Integer(FTMEM[(Address and $7FE) + 1]) - 128;
        Result.C[2] := FTMEM[Address or $800];
        Result.C[3] := Result.C[2];
      end;
    2:
      begin
        if Size = 0 then
          V := Cardinal(R.Palette * 16) + V;
        if Size >= 2 then
        begin
          Result.C[0] := V shr 8;
          Result.C[1] := V and $FF;
          Result.C[2] := Result.C[0];
          Result.C[3] := Result.C[1]
        end
        else
          for var I := 0 to 3 do
            Result.C[I] := Integer(V);
      end;
    3:
      begin
        var Intensity := V;
        var Alpha := V;
        case Size of
          0:
            begin
              Intensity := ((V and 14) shl 4) or ((V and 14) shl 1) or ((V and 14) shr 2);
              Alpha := (V and 1) * 255
            end;
          1:
            begin
              Intensity := (V shr 4) * 17;
              Alpha := (V and 15) * 17
            end;
          2, 3:
            begin
              Intensity := V shr 8;
              Alpha := V and $FF
            end;
        end;
        Result.C[0] := Integer(Intensity);
        Result.C[1] := Integer(Intensity);
        Result.C[2] := Integer(Intensity);
        Result.C[3] := Integer(Alpha);
        if Size = 3 then
          Result.C[1] := Result.C[3];
      end;
  else
    if Size >= 2 then
    begin
      Result.C[0] := V shr 8;
      Result.C[1] := V and $FF;
      Result.C[2] := Result.C[0];
      Result.C[3] := Result.C[1]
    end
    else
    begin
      if Size = 0 then
        V := V * 17;
      for var I := 0 to 3 do
        Result.C[I] := Integer(V)
    end;
  end;
end;

function TN64RDP.Texture(Tile: Integer; S, T: Int64; Cycle: Integer; const Previous: TN64Texel): TN64Texel;

  function Converted(const Raw: TN64Texel): TN64Texel;
  begin
    var U := Integer(SignedValue(SX(Cardinal(Raw.C[0] and $1FF), 9)));
    var V := Integer(SignedValue(SX(Cardinal(Raw.C[1] and $1FF), 9)));
    var Y := Integer(SignedValue(SX(Cardinal(Raw.C[2] and $1FF), 9)));
    Result.C[0] := (Y + Floor256(FConvert[0] * V + 128)) and $1FF;
    Result.C[1] := (Y + Floor256(FConvert[1] * U + FConvert[2] * V + 128)) and $1FF;
    Result.C[2] := (Y + Floor256(FConvert[3] * U + 128)) and $1FF;
    Result.C[3] := Y and $1FF;
  end;

begin
  var R := FTiles[Tile];
  S := SignedValue(SX(UInt64(S and $FFFF), 16));
  T := SignedValue(SX(UInt64(T and $FFFF), 16));
  if R.ShiftS <= 10 then
    S := ShiftRight(S, R.ShiftS)
  else
    S := SignedValue(SX(UInt64((S * (1 shl (16 - R.ShiftS))) and $FFFF), 16));
  if R.ShiftT <= 10 then
    T := ShiftRight(T, R.ShiftT)
  else
    T := SignedValue(SX(UInt64((T * (1 shl (16 - R.ShiftT))) and $FFFF), 16));
  var MaxS := ShiftRight(S, 3) >= R.SH;
  var MaxT := ShiftRight(T, 3) >= R.TH;
  S := S - R.SL * 8;
  T := T - R.TL * 8;
  var FX := Integer(S and 31);
  var FY := Integer(T and 31);
  if R.ClampS or (R.MaskS = 0) then
    if MaxS then
    begin
      S := Int64((R.SH div 4 - R.SL div 4) and $3FF) * 32;
      FX := 0
    end
    else if S < 0 then
    begin
      S := 0;
      FX := 0
    end;
  if R.ClampT or (R.MaskT = 0) then
    if MaxT then
    begin
      T := Int64((R.TH div 4 - R.TL div 4) and $3FF) * 32;
      FY := 0
    end
    else if T < 0 then
    begin
      T := 0;
      FY := 0
    end;
  var X := Integer(ShiftRight(S, 5));
  var Y := Integer(ShiftRight(T, 5));
  var Base := TextureTexel(Tile, X, Y);
  if ((FOtherHi shr 20) and 3) = 2 then
    Exit(Base);
  var Bilerp := (FOtherHi and (Cardinal($800) shr Cycle)) <> 0;
  var ConvertOne := (Cycle = 1) and ((FOtherHi and $200) <> 0);
  var Sample := (FOtherHi and $2000) <> 0;
  if Sample or ((FOtherHi and $8000) <> 0) then
  begin
    var C1 := TextureTexel(Tile, X + 1, Y);
    var C2 := TextureTexel(Tile, X, Y + 1);
    var C3 := TextureTexel(Tile, X + 1, Y + 1);
    var ChromaX := FX;
    if R.Format = 1 then
    begin
      ChromaX := (FX shr 1) or ((X and 1) shl 4);
      var Chroma1 := TextureTexel(Tile, X + 2, Y);
      var Chroma3 := TextureTexel(Tile, X + 2, Y + 1);
      C1.C[0] := Chroma1.C[0];
      C1.C[1] := Chroma1.C[1];
      C3.C[0] := Chroma3.C[0];
      C3.C[1] := Chroma3.C[1];
    end;
    if not Bilerp then
    begin
      var Raw := Base;
      if FX + FY >= 32 then
      begin
        Raw.C[2] := C3.C[2];
        Raw.C[3] := C3.C[3]
      end;
      if ChromaX + FY >= 32 then
      begin
        Raw.C[0] := C3.C[0];
        Raw.C[1] := C3.C[1]
      end;
      if ConvertOne then
        Raw := Previous;
      Exit(Converted(Raw));
    end;
    for var I := 0 to 3 do
    begin
      var FractionX := FX;
      if I < 2 then
        FractionX := ChromaX;
      var A := Base.C[I];
      var B := C1.C[I];
      var C := C2.C[I];
      var D := C3.C[I];
      if ConvertOne then
      begin
        var PR := Integer(SignedValue(SX(Cardinal(Previous.C[0] and $1FF), 9)));
        var PG := Integer(SignedValue(SX(Cardinal(Previous.C[1] and $1FF), 9)));
        var PB := Integer(SignedValue(SX(Cardinal(Previous.C[2] and $1FF), 9)));
        if FractionX + FY >= 32 then
          Result.C[I] := PB + Floor256(PR * (C - D) + PG * (B - D) + 128)
        else
          Result.C[I] := PB + Floor256(PR * (B - A) + PG * (C - A) + 128);
        if ((FOtherHi and $1000) <> 0) and (FractionX = 16) and (FY = 16) then
          Result.C[I] := PB + Floor256(PR * (C - D) + PG * (B - D) + ((A - D - 1) * 64) + 192);
      end
      else
      begin
        if FractionX + FY >= 32 then
          Result.C[I] := D + Integer(ShiftRight((C - D) * (32 - FractionX) + (B - D) * (32 - FY) + 16, 5))
        else
          Result.C[I] := A + Integer(ShiftRight((B - A) * FractionX + (C - A) * FY + 16, 5));
        if ((FOtherHi and $1000) <> 0) and (FractionX = 16) and (FY = 16) then
          Result.C[I] := Integer(ShiftRight(A + B + C + D + 2, 2));
      end;
      Result.C[I] := Result.C[I] and $1FF;
    end;
  end
  else if Bilerp then
    if ConvertOne then
    begin
      for var I := 0 to 3 do
        Result.C[I] := Previous.C[2] and $1FF
    end
    else
      Result := Base
  else if ConvertOne then
    Result := Converted(Previous)
  else
    Result := Converted(Base);
end;

function TN64RDP.Combine(Texel: TN64Texel; Shade: Cardinal; Texel1, TexelNext: TN64Texel): Cardinal;
var
  CombinedRGB, Equation, Bypass: array[0..2] of Integer;
  CombinedAlpha: Integer;

  function Component(Color: Cardinal; Channel: Integer): Integer; inline;
  begin
    Result := (Color shr ((3 - Channel) * 8)) and $FF
  end;

  function Extended(Value: Integer): Integer; inline;
  begin
    Result := Value and $1FF;
    if (Result and $180) = $180 then
      Dec(Result, 512);
  end;

  function RGB(Index, Channel, Role: Integer): Integer;
  begin
    if Role = 2 then
      case Index of
        6:
          Exit(FKeyScale[Channel]);
        7:
          Exit(CombinedAlpha);
        8:
          Exit(Texel.C[3]);
        9:
          Exit(Texel1.C[3]);
        10:
          Exit(Integer(FPrimitive and $FF));
        11:
          Exit(Integer(Shade and $FF));
        12:
          Exit(Integer(FEnvironment and $FF));
        13:
          Exit(FLODFraction);
        14:
          Exit(Integer(FPrimitiveLOD));
        15:
          Exit(FConvert[5]);
        16..31:
          Exit(0);
      end;
    case Index of
      0:
        Result := CombinedRGB[Channel];
      1:
        Result := Texel.C[Channel];
      2:
        Result := Texel1.C[Channel];
      3:
        Result := Component(FPrimitive, Channel);
      4:
        Result := Component(Shade, Channel);
      5:
        Result := Component(FEnvironment, Channel);
      6:
        if Role = 1 then
          Result := FKeyCenter[Channel]
        else
          Result := 256;
      7:
        case Role of
          0:
            Result := Integer(FNoise);
          1:
            Result := FConvert[4]        else
          Result := 0
        end;
    else
      Result := 0
    end;
  end;

  function Alpha(Index: Integer; Multiplier: Boolean): Integer;
  begin
    if Multiplier then
      case Index of
        0:
          Exit(FLODFraction);
        6:
          Exit(Integer(FPrimitiveLOD));
        7:
          Exit(0)
      end;
    case Index of
      0:
        Result := CombinedAlpha;
      1:
        Result := Texel.C[3];
      2:
        Result := Texel1.C[3];
      3:
        Result := FPrimitive and $FF;
      4:
        Result := Shade and $FF;
      5:
        Result := FEnvironment and $FF;
      6:
        Result := 256;
    else
      Result := 0
    end;
  end;

begin
  FShadeAlpha := Min(255, Integer(Shade and $FF) + FAlphaDither);
  // Power-on combiner inputs select the one source on every mux leg.
  if not FHasCombine then
    Exit($FFFFFFFF);
  CombinedAlpha := 0;
  for var I := 0 to 2 do
    CombinedRGB[I] := 0;
  var FirstCycle := 1;
  if ((FOtherHi shr 20) and 3) = 1 then
    FirstCycle := 0;
  for var Cycle := FirstCycle to 1 do
  begin
    if (Cycle = 1) and (FirstCycle = 0) then
    begin
      Texel := Texel1;
      Texel1 := TexelNext
    end;
    var A, B, C, D, AA, AB, AC, AD: Integer;
    if Cycle = 0 then
    begin
      A := (FCombineHi shr 20) and 15;
      C := (FCombineHi shr 15) and 31;
      AA := (FCombineHi shr 12) and 7;
      AC := (FCombineHi shr 9) and 7;
      B := (FCombineLo shr 28) and 15;
      D := (FCombineLo shr 15) and 7;
      AB := (FCombineLo shr 12) and 7;
      AD := (FCombineLo shr 9) and 7;
    end
    else
    begin
      A := (FCombineHi shr 5) and 15;
      C := FCombineHi and 31;
      AA := (FCombineLo shr 21) and 7;
      AC := (FCombineLo shr 18) and 7;
      B := (FCombineLo shr 24) and 15;
      D := (FCombineLo shr 6) and 7;
      AB := (FCombineLo shr 3) and 7;
      AD := FCombineLo and 7;
    end;
    for var Channel := 0 to 2 do
    begin
      Bypass[Channel] := RGB(A, Channel, 0);
      var Multiplier := Integer(SignedValue(SX(Cardinal(RGB(C, Channel, 2) and $1FF), 9)));
      Equation[Channel] := ((Extended(Bypass[Channel]) - Extended(RGB(B, Channel, 1))) * Multiplier +
        Extended(RGB(D, Channel, 3)) * 256 + 128) and $1FFFF;
    end;
    var Multiplier := Integer(SignedValue(SX(Cardinal(Alpha(AC, True) and $1FF), 9)));
    var NewAlpha := Integer(ShiftRight((Extended(Alpha(AA, False)) - Extended(Alpha(AB, False))) * Multiplier +
        Extended(Alpha(AD, False)) * 256 + 128, 8)) and $1FF;
    for var Channel := 0 to 2 do
      CombinedRGB[Channel] := Equation[Channel] shr 8;
    CombinedAlpha := NewAlpha;
  end;
  Result := 0;
  for var Channel := 0 to 2 do
    if (FOtherHi and $100) <> 0 then
      Result := (Result shl 8) or Cardinal(Clamp9(Bypass[Channel]))
    else
      Result := (Result shl 8) or Cardinal(Clamp9(CombinedRGB[Channel]));
  var FinalAlpha := Clamp9(CombinedAlpha);
  if ((FOtherHi and $100) <> 0) and ((FOtherLo and $2000) = 0) then
  begin
    FinalAlpha := 255;
    for var Channel := 0 to 2 do
    begin
      var Key := Integer(SignedValue(SX(Cardinal(Equation[Channel]), 17)));
      if Key > 0 then
        if (Key and 15) = 8 then
          Key := -Key + 16
        else
          Key := -Key;
      FinalAlpha := Min(FinalAlpha, EnsureRange(FKeyWidth[Channel] * 16 + Key, 0, 255));
    end;
  end;
  Result := (Result shl 8) or Cardinal(FinalAlpha);
end;

procedure TN64RDP.LoadTexture(Tile, SL, TL, SH, TH: Integer; Block: Boolean);
begin
  if FTextureSize = 0 then
  begin
    FPipelineCrashed := True;
    Exit
  end;
  var R := FTiles[Tile];
  var Bits := 4 shl FTextureSize;
  var Width := ((SH div 4) - (SL div 4) + 1) and $FFF;
  var Height := Max(0, (TH div 4) - (TL div 4) + 1);
  if Block then
  begin
    Width := (SH - SL + 1) and $FFF;
    Height := 1
  end;
  var Bytes := ((Width * Bits + 7) div 8 + 7) and not 7;
  Inc(FWorkClocks, Cardinal(((Int64(Bytes) * Min(Height, 1024)) + 7) div 8));
  for var Y := 0 to Min(Height, 1024) - 1 do
    for var X := 0 to Min(Bytes, 16384) - 1 do
    begin
      var SourceS := SL div 4;
      var SourceT := TL div 4;
      if Block then
      begin
        SourceS := SL;
        SourceT := TL
      end;
      var Source := UInt64(FTextureAddress) + Cardinal(((SourceT + Y) * FTextureWidth + SourceS) * Bits div 8 + X);
      var Row := Y;
      if Block then
        Row := (X div 8 * TH) div 2048;
      var Target := (R.TMEM * 8 + Y * R.Line * 8 + X) and $FFF;
      if (R.Format = 0) and (R.Size = 3) then
        Target := ((R.TMEM * 8 + Y * R.Line * 8 + X div 4 * 2 + X mod 2) and $7FF) or ((X div 2 and 1) * $800);
      if (R.Format = 1) and (FTextureSize = 2) then
        Target := ((R.TMEM * 8 + Y * R.Line * 8 + X div 2) and $7FF) or ((X and 1) * $800);
      if Odd(Row) then
        Target := Target xor 4;
      if Source < $800000 then
        FTMEM[Target] := FBus.Read8(Cardinal(Source));
    end;
end;

procedure TN64RDP.Triangle(Code: Cardinal);
const
  XOffset: array[0..15] of Byte = (0, 3, 2, 2, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0);
  YOffset: array[0..15] of Byte = (0, 0, 1, 0, 2, 0, 1, 0, 3, 0, 1, 0, 2, 0, 1, 0);
  ReciprocalPoint: array[0..63] of Integer =
    ($4000, $3F04, $3E10, $3D22, $3C3C, $3B5D, $3A83, $39B1, $38E4, $381C, $375A, $369D, $35E5, $3532, $3483, $33D9,
    $3333, $3291, $31F4, $3159, $30C3, $3030, $2FA1, $2F15, $2E8C, $2E06, $2D83, $2D03, $2C86, $2C0B, $2B93, $2B1E,
    $2AAB, $2A3A, $29CC, $2960, $28F6, $288E, $2828, $27C4, $2762, $2702, $26A4, $2648, $25ED, $2594, $253D, $24E7,
    $2492, $243F, $23EE, $239E, $234F, $2302, $22B6, $226C, $2222, $21DA, $2193, $214D, $2108, $20C5, $2082, $2041);
  ReciprocalSlope: array[0..63] of Integer =
    ($F03, $F0B, $F11, $F19, $F20, $F25, $F2D, $F32, $F37, $F3D, $F42, $F47, $F4C, $F50, $F55, $F59,
    $F5D, $F62, $F64, $F69, $F6C, $F70, $F73, $F76, $F79, $F7C, $F7F, $F82, $F84, $F87, $F8A, $F8C,
    $F8E, $F91, $F93, $F95, $F97, $F99, $F9B, $F9D, $F9F, $FA1, $FA3, $FA4, $FA6, $FA8, $FA9, $FAA,
    $FAC, $FAE, $FAF, $FB0, $FB2, $FB3, $FB5, $FB5, $FB7, $FB8, $FB9, $FBA, $FBC, $FBC, $FBE, $FBE);
var
  // Raw 16.16 attributes: base, dx, de, dy. Every guest add wraps at 32 bits.
  Coeff: array[0..3, 0..7] of Int64;
  SpanAttribute: array[0..7] of Int64;
  Major, Minor: array[0..3] of Integer;
  Invalid: array[0..3] of Boolean;
  XH, XM, XL, DH, DM, DL: Int64;
  YH, YM, YL, BaseY, Cycle, Tile, MaxLevel, UnscrX: Integer;
  Flip, OffsetAttributes: Boolean;

  function Coefficient(Base, Group, Channel: Integer): Int64;
  begin
    var Index := Channel div 2;
    var Shift := 16 * (1 - (Channel and 1));
    var Hi := (FCommand[Base + Group + Index] shr Shift) and $FFFF;
    var Lo := (FCommand[Base + Group + Index + 4] shr Shift) and $FFFF;
    Result := SignedValue(SX((Hi shl 16) or Lo, 32));
  end;

  function EdgeQuantise(Value: Int64): Integer;
  begin
    // Sticky bit retains all discarded fractional bits in the eighth-pixel edge.
    var Raw := Cardinal(Value and $FFFFFFFF);
    var Sticky := Ord(((Raw shr 1) and $1FFF) <> 0);
    Result := Integer((Raw shr 13) and $1FFE) or Sticky;
    if ((Raw and $08000000) <> 0) or ((Result < FScissorQuarterX0 * 2) and ((Raw and $04000000) = 0)) then
      Exit(FScissorQuarterX0 * 2);
    Result := Integer((Raw shr 13) and $3FFE) or Sticky;
    if ((Result and $2000) <> 0) or ((Result and $1FFF) >= FScissorQuarterX1 * 2) then
      Result := FScissorQuarterX1 * 2;
    Result := Result and $1FFF;
  end;

  function TextureDivide(Coordinate, W: Int64): Integer;
  begin
    var SS := SignedValue(SX(UInt64(ShiftRight(Coordinate, 16) and $FFFF), 16));
    if (FOtherHi and $80000) = 0 then
      Exit(Integer(SS));
    var SW := Integer(ShiftRight(W, 16) and $FFFF);
    if SW = 0 then
      Exit(32767);
    var BadW := (SW and $8000) <> 0;
    SW := SW and $7FFF;
    var K := 1;
    while (K <= 14) and (((SW shl K) and $8000) = 0) do
      Inc(K);
    var Shift := K - 1;
    var Normal := (SW shl Shift) and $3FFF;
    var Slope := (ReciprocalSlope[Normal shr 8] and $3FF) - 1023;
    var Reciprocal := Integer(ShiftRight(Int64(Slope) * ((Normal and $FF) shl 2), 10)) + ReciprocalPoint[Normal shr 8];
    Reciprocal := Reciprocal and $7FFF;
    var Product := SS * Reciprocal;
    var V := Product * 2;
    if Shift <> 14 then
      V := ShiftRight(Product, 13 - Shift);
    if BadW then
      V := 32767;
    Result := Integer(EnsureRange(V, Int64(-32768), Int64(32767)));
  end;

  procedure RasterRow(Y: Integer);
  begin
    if FPipelineCrashed then
      Exit;
    var Left := 1024;
    var Right := 0;
    for var Q := 0 to 3 do
      if not Invalid[Q] then
      begin
        Left := Min(Left, Min(Major[Q], Minor[Q]) div 8);
        Right := Max(Right, Max(Major[Q], Minor[Q]) div 8);
      end;
    if (Y < 0) or (Y >= 1024) or (Left > Right) or (Left >= 1024) or (Right < 0) then
      Exit;
    if FScissorField and (Odd(Y) <> FScissorOdd) then
      Exit;
    Left := Max(Left, 0);
    Right := Min(Right, 1023);
    var StartX := Right;
    var EndX := Left;
    var Step := -1;
    if Flip then
    begin
      StartX := Left;
      EndX := Right;
      Step := 1
    end;
    var X := StartX;
    FDelayedHidden := -1;
    while True do
    begin
      var Mask := 0;
      for var Q := 0 to 3 do
        if not Invalid[Q] then
        begin
          var Lo := Minor[Q];
          var Hi := Major[Q];
          if Flip then
          begin
            Lo := Major[Q];
            Hi := Minor[Q]
          end;
          var FMask := $A shr (Q and 1);
          var RowMask := FMask;
          if X < Lo div 8 then
            RowMask := 0
          else if X = Lo div 8 then
            RowMask := RowMask and ($F shr (((Lo and 7) + 1) shr 1));
          if X > Hi div 8 then
            RowMask := 0
          else if X = Hi div 8 then
            RowMask := RowMask and ($F0 shr (((Hi and 7) + 1) shr 1));
          Mask := Mask or (RowMask shl ((Q - 2) and 4));
        end;
      var Coverage := 0;
      for var Bit := 0 to 7 do
        Inc(Coverage, (Mask shr Bit) and 1);
      if (Coverage <> 0) or (Cycle >= 2) then
      begin
        if Cycle >= 2 then
          Coverage := 8;
        var OffX := 0;
        var OffY := 0;
        if Coverage <> 8 then
        begin
          var Expanded := (Mask and 5) or ((Mask and $5A) shl 4) or ((Mask and $A0) shl 8);
          var YMask := 0;
          for var Q := 0 to 3 do
            if (Expanded and ($F000 shr (Q * 4))) <> 0 then
              YMask := YMask or (1 shl Q);
          OffY := YOffset[YMask];
          OffX := XOffset[(Expanded shr ((OffY xor 3) * 4)) and 15];
        end;
        var Attributes: array[0..7] of Int64;
        for var I := 0 to 7 do
          Attributes[I] := WrapSigned32(SpanAttribute[I] + Coeff[1, I] * (X - UnscrX));
        var Shade: Cardinal := 0;
        if (Code and 4) <> 0 then
        begin
          Shade := 0;
          for var I := 0 to 3 do
          begin
            var V := ShiftRight(Attributes[I], 14);
            if Coverage = 8 then
              V := ShiftRight(V, 2)
            else
            begin
              var DX := SignedValue(SX(UInt64(ShiftRight(Coeff[1, I], 14) and $1FFF), 13));
              var DY := SignedValue(SX(UInt64(ShiftRight(Coeff[3, I], 14) and $1FFF), 13));
              V := ShiftRight(V * 4 + OffX * DX + OffY * DY, 4);
            end;
            Shade := (Shade shl 8) or Cardinal(Clamp9(Integer(V and $1FF)));
          end;
        end;
        var Texel := TexelFromRGBA(Shade);
        var Texel1 := Texel;
        var TexelNext := Texel;
        FLODFraction := 0;
        if (Code and 2) <> 0 then
        begin
          var S := TextureDivide(Attributes[4], Attributes[6]);
          var T := TextureDivide(Attributes[5], Attributes[6]);
          var NextS := TextureDivide(WrapSigned32(Attributes[4] + Coeff[1, 4] * Step), WrapSigned32(Attributes[6] + Coeff[1, 6] * Step));
          var NextT := TextureDivide(WrapSigned32(Attributes[5] + Coeff[1, 5] * Step), WrapSigned32(Attributes[6] + Coeff[1, 6] * Step));
          var Lod := Max(Abs(NextS - S), Abs(NextT - T));
          var NextYS := TextureDivide(WrapSigned32(Attributes[4] + (Coeff[3, 4] and not Int64($7FFF))),
            WrapSigned32(Attributes[6] + (Coeff[3, 6] and not Int64($7FFF))));
          var NextYT := TextureDivide(WrapSigned32(Attributes[5] + (Coeff[3, 5] and not Int64($7FFF))),
            WrapSigned32(Attributes[6] + (Coeff[3, 6] and not Int64($7FFF))));
          Lod := Max(Lod, Max(Abs(NextYS - S), Abs(NextYT - T)));
          var Level := 0;
          var Magnify := Lod < 32;
          Lod := Max(Lod, FMinLevel);
          while (Level < 7) and (Lod >= (64 shl Level)) do
            Inc(Level);
          var Distant := (Level >= MaxLevel) or (Lod >= $4000);
          if Lod < 32 then
            FLODFraction := Lod * 8
          else
            FLODFraction := ((Lod shl 3) shr Level) and $FF;
          if ((FOtherHi and $60000) = 0) then
            if Distant then
              FLODFraction := 255
            else if Magnify then
              FLODFraction := 0;
          if ((FOtherHi and $40000) <> 0) and Magnify then
            FLODFraction := FLODFraction or $100;
          Level := Min(Level, MaxLevel);
          // With LOD disabled, one-cycle lookahead keeps the primitive tile;
          // two-cycle TEXEL1 reads the adjacent tile. LOD may replace either.
          var Tile0 := Tile;
          var Tile1 := Tile;
          if Cycle = 1 then
            Tile1 := (Tile + 1) and 7;
          if (FOtherHi and $10000) <> 0 then
          begin
            Tile0 := (Tile + Level) and 7;
            Tile1 := (Tile0 + 1) and 7;
            if (FOtherHi and $20000) <> 0 then
            begin
              if not Magnify then
                Tile0 := (Tile0 + 1) and 7;
              if Distant then
                Tile1 := Tile0
              else
                Tile1 := (Tile0 + 1) and 7;
            end
            else if Distant or (Magnify and ((FOtherHi and $40000) = 0)) then
              Tile1 := Tile0;
          end;
          Texel := Texture(Tile0, S, T, 0, Default(TN64Texel));
          Texel1 := Texture(Tile1, S, T, 1, Texel);
          TexelNext := Texture(Tile0, NextS, NextT, 0, Default(TN64Texel));
          if Cycle = 0 then
            Texel1 := TexelNext;
          if not FHasCombine then
            Shade := TexelToRGBA(Texel);
        end;
        var Depth := -1;
        var Delta: Cardinal := 1;
        if (Code and 1) <> 0 then
        begin
          var Z := ShiftRight(Attributes[7], 10) and $3FFFFF;
          if Coverage = 8 then
            Z := ShiftRight(Z, 3)
          else
            Z := ShiftRight(Z * 4 + OffX * ShiftRight(Coeff[1, 7], 10) +
              OffY * ShiftRight(Coeff[3, 7], 10), 5);
          case (Z and $60000) shr 17 of
            2:
              Depth := $3FFFF;
            3:
              Depth := 0           else
            Depth := Integer(Z and $3FFFF)
          end;
          var DX := Integer(ShiftRight(Coeff[1, 7], 16) and $FFFF);
          var DY := Integer(ShiftRight(Coeff[3, 7], 16) and $FFFF);
          if (DX and $8000) <> 0 then
            DX := (DX xor $FFFF) and $7FFF;
          if (DY and $8000) <> 0 then
            DY := (DY xor $FFFF) and $7FFF;
          Delta := Cardinal(DX + DY);
          if (Delta and $C000) <> 0 then
            Delta := $8000
          else if Delta = 0 then
            Delta := 1
          else if Delta = 1 then
            Delta := 3
          else
          begin
            var Bit := Cardinal($2000);
            while (Bit > 0) and ((Delta and Bit) = 0) do
              Bit := Bit shr 1;
            Delta := Bit shl 1;
          end;
        end;
        var RGBDither, AlphaDither: Integer;
        Dither(X, Y, RGBDither, AlphaDither);
        if Cycle = 3 then
          Pixel(X, Y, FFill, True)
        else if Cycle = 2 then
          Pixel(X, Y, TexelToRGBA(Texel), False, -1, 1, 8, True)
        else
          Pixel(X, Y, Combine(Texel, Shade, Texel1, TexelNext), False, Depth, Delta, Coverage, (Mask and $80) <> 0);
      end;
      if X = EndX then
        Break;
      Inc(X, Step);
    end;
    CompleteDelayedHidden;
    if (Cycle = 3) and ((FOtherLo and $20) <> 0) and ((FOtherLo and 4) = 0) then
      FPipelineCrashed := True;
  end;

begin
  YL := Integer(SignedValue(SX(FCommand[0] and $3FFF, 14)));
  if FPipelineCrashed then
    Exit;
  if (FScissorQuarterX1 <= FScissorQuarterX0) or (FScissorQuarterY1 <= FScissorQuarterY0) then
    Exit;
  YM := Integer(SignedValue(SX((FCommand[1] shr 16) and $3FFF, 14)));
  YH := Integer(SignedValue(SX(FCommand[1] and $3FFF, 14)));
  if YL <= YH then
    Exit;
  XL := SignedValue(SX(FCommand[2], 28));
  DL := SignedValue(SX(FCommand[3], 30));
  XH := SignedValue(SX(FCommand[4], 28));
  DH := SignedValue(SX(FCommand[5], 30));
  XM := SignedValue(SX(FCommand[6], 28));
  DM := SignedValue(SX(FCommand[7], 30));
  Flip := (FCommand[0] and $800000) <> 0;
  FDrawFlip := Flip;
  Tile := (FCommand[0] shr 16) and 7;
  MaxLevel := (FCommand[0] shr 19) and 7;
  Cycle := (FOtherHi shr 20) and 3;
  if FColorSize = 1 then
  begin
    FHiddenOld[0] := FHiddenOld[0] and 1;
    FHiddenOld[4] := FHiddenOld[4] and 1
  end;
  if ((Cycle = 2) and (FColorSize = 3)) or ((Cycle = 3) and ((FColorSize = 0) or ((FOtherLo and $50) <> 0))) then
  begin
    FPipelineCrashed := True;
    Exit
  end;
  for var Group := 0 to 3 do
    for var I := 0 to 7 do
      Coeff[Group, I] := 0;
  var ShadeBase := 8;
  var TextureBase := ShadeBase;
  if (Code and 4) <> 0 then
    Inc(TextureBase, 16);
  var ZBase := TextureBase;
  if (Code and 2) <> 0 then
    Inc(ZBase, 16);
  for var Group := 0 to 3 do
  begin
    var Index := 0;
    case Group of
      1:
        Index := 2;
      2:
        Index := 8;
      3:
        Index := 10
    end;
    if (Code and 4) <> 0 then
      for var I := 0 to 3 do
        Coeff[Group, I] := Coefficient(ShadeBase, Index, I);
    if (Code and 2) <> 0 then
      for var I := 0 to 2 do
        Coeff[Group, I + 4] := Coefficient(TextureBase, Index, I);
    if (Code and 1) <> 0 then
      Coeff[Group, 7] := SignedValue(SX(FCommand[ZBase + Group], 32));
  end;
  for var I := 0 to 6 do
    Coeff[1, I] := Coeff[1, I] and not Int64(31);
  BaseY := Integer(ShiftRight(YH, 2));
  var QuarterStart := BaseY * 4;
  var LastQuarter := Min(YL, FScissorQuarterY1) - 1;
  OffsetAttributes := not (((FCommand[5] and $80000000) <> 0) xor Flip);
  var LoadQuarter := 0;
  if OffsetAttributes then
    LoadQuarter := 3;
  var XMajor := XH and not Int64(1);
  var XMinor := XM and not Int64(1);
  var MajorStep := ShiftRight(DH, 2) and not Int64(1);
  var MinorStep := ShiftRight(DM, 2) and not Int64(1);
  for var Q := 0 to 3 do
    Invalid[Q] := True;
  for var Quarter := QuarterStart to (LastQuarter or 3) do
  begin
    var Q := Quarter and 3;
    var Y := Integer(ShiftRight(Quarter, 2));
    if Quarter = YM then
    begin
      XMinor := XL and not Int64(1);
      MinorStep := ShiftRight(DL, 2) and not Int64(1)
    end;
    Major[Q] := EdgeQuantise(XMajor);
    Minor[Q] := EdgeQuantise(XMinor);
    Invalid[Q] := (Quarter < Max(YH, FScissorQuarterY0)) or (Quarter > LastQuarter);
    var MajorCross := (Cardinal(XMajor and $FFFFFFFF) xor $08000000) and $0FFFC000;
    var MinorCross := (Cardinal(XMinor and $FFFFFFFF) xor $08000000) and $0FFFC000;
    if Flip then
      Invalid[Q] := Invalid[Q] or (MinorCross < MajorCross)
    else
      Invalid[Q] := Invalid[Q] or (MajorCross < MinorCross);
    if Q = LoadQuarter then
    begin
      UnscrX := Integer(SignedValue(SX(UInt64(ShiftRight(XMajor, 16) and $FFF), 12)));
      var Fraction := ShiftRight(XMajor, 8) and $FF;
      for var I := 0 to 7 do
      begin
        var DE := Coeff[2, I] and not Int64($1FF);
        var DY := Coeff[3, I] and not Int64($1FF);
        var Offset: Int64 := 0;
        if OffsetAttributes then
          Offset := DE - ShiftRight(DE, 2) - DY + ShiftRight(DY, 2);
        var DX := ShiftRight(Coeff[1, I], 8) and not Int64(1);
        if Cycle = 2 then
          DX := 0;
        var Base := WrapSigned32(Coeff[0, I] + Coeff[2, I] * (Y - BaseY));
        SpanAttribute[I] := WrapSigned32((Base and not Int64($1FF)) + Offset - Fraction * DX) and not Int64($3FF);
      end;
    end;
    if Q = 3 then
      RasterRow(Y);
    XMajor := WrapSigned32(XMajor + MajorStep);
    XMinor := WrapSigned32(XMinor + MinorStep);
  end;
end;

procedure TN64RDP.Rectangle(Code: Cardinal);

  procedure SetCoefficient(Index: Integer; S, T: Int64);
  begin
    var SR := Cardinal(S and $FFFFFFFF);
    var TR := Cardinal(T and $FFFFFFFF);
    FCommand[Index] := (SR and $FFFF0000) or (TR shr 16);
    FCommand[Index + 4] := ((SR and $FFFF) shl 16) or (TR and $FFFF);
  end;

begin
  var A := FCommand[0];
  var B := FCommand[1];
  var ST := FCommand[2];
  var Delta := FCommand[3];
  var XL := (A shr 12) and $FFF;
  var YL := A and $FFF;
  var XH := (B shr 12) and $FFF;
  var YH := B and $FFF;
  var Tile := (B shr 24) and 7;
  if ((FOtherHi shr 20) and 3) in [2, 3] then
    YL := YL or 3;
  for var I := 0 to High(FCommand) do
    FCommand[I] := 0;
  FCommand[0] := $00800000 or (Tile shl 16) or YL;
  FCommand[1] := (YL shl 16) or YH;
  FCommand[2] := XL shl 14;
  FCommand[4] := XH shl 14;
  FCommand[6] := XL shl 14;
  if Code = 54 then
    Triangle(8)
  else
  begin
    var S := SignedValue(SX(ST shr 16, 16));
    var T := SignedValue(SX(ST and $FFFF, 16));
    var DS := SignedValue(SX(Delta shr 16, 16));
    var DT := SignedValue(SX(Delta and $FFFF, 16));
    if ((FOtherHi shr 20) and 3) = 2 then
      DS := ShiftRight(DS, 2);
    SetCoefficient(8, S * 65536, T * 65536);
    if Code = 36 then
    begin
      SetCoefficient(10, DS * 2048, 0);
      SetCoefficient(16, 0, DT * 2048);
      SetCoefficient(18, 0, DT * 2048);
    end
    else
    begin
      SetCoefficient(10, 0, DT * 2048);
      SetCoefficient(16, DS * 2048, 0);
      SetCoefficient(18, DS * 2048, 0);
    end;
    Triangle(10);
  end;
end;

function TN64RDP.Execute(Start, Finish: Cardinal; XBUS: Boolean; out Consumed: Cardinal): Boolean;

  function WordAt(Address: Cardinal): Cardinal;
  begin
    Result := FCommand[Address div 4];
  end;

begin
  Result := False;
  FWorkClocks := 0;
  FTransferBits := 0;
  Consumed := Start;
  if FPipelineCrashed then
    Exit;
  if (Finish < Start) or (Finish - Start > $800000) then
    raise EReadError.Create('Invalid RDP command range');
  while UInt64(Consumed) + 8 <= Finish do
  begin
    for var I := 0 to 1 do
    begin
      var Address := Consumed + Cardinal(I * 4);
      if XBUS then
        FCommand[FCommandCount] := FBus.Read32($04000000 + (Address and $FFF))
      else
        FCommand[FCommandCount] := FBus.Read32(Address and $FFFFFF);
      Inc(FCommandCount);
    end;
    Inc(Consumed, 8);
    if FCommandCount < 2 then
      Continue;
    var A := WordAt(0);
    var B := WordAt(4);
    var Code := (A shr 24) and 63;
    var Words := 2;
    if Code in [8..15] then
    begin
      Words := 8;
      if (Code and 4) <> 0 then
        Inc(Words, 16);
      if (Code and 2) <> 0 then
        Inc(Words, 16);
      if (Code and 1) <> 0 then
        Inc(Words, 4);
    end
    else if Code in [36, 37] then
      Words := 4;
    if FCommandCount < Words then
      Continue;
    var TraceWords: TArray<Cardinal>;
    if Assigned(FOnCommand) or Assigned(FOnCommandCompleted) then
    begin
      SetLength(TraceWords, Words);
      for var I := 0 to Words - 1 do
        TraceWords[I] := FCommand[I];
      if Assigned(FOnCommand) then
        FOnCommand(TraceWords);
    end;
    Inc(FWorkClocks, Cardinal(Words div 2));
    case Code of
      0, 38, 39, 40, 41:
        if Code = 41 then
          Result := True;
      45:
        begin
          FScissorQuarterX0 := (A shr 12) and $FFF;
          FScissorQuarterY0 := A and $FFF;
          FScissorQuarterX1 := (B shr 12) and $FFF;
          FScissorQuarterY1 := B and $FFF;
          FScissorX0 := FScissorQuarterX0 div 4;
          FScissorY0 := FScissorQuarterY0 div 4;
          FScissorX1 := (FScissorQuarterX1 + 3) div 4;
          FScissorY1 := (FScissorQuarterY1 + 3) div 4;
          FScissorField := (B and $02000000) <> 0;
          FScissorOdd := (B and $01000000) <> 0;
        end;
      47:
        begin
          FOtherHi := A and $FFFFFF;
          FOtherLo := B
        end;
      53:
        begin
          var I := (B shr 24) and 7;
          FTiles[I].Format := (A shr 21) and 7;
          FTiles[I].Size := (A shr 19) and 3;
          FTiles[I].Line := (A shr 9) and $1FF;
          FTiles[I].TMEM := A and $1FF;
          FTiles[I].Palette := (B shr 20) and 15;
          FTiles[I].ClampT := (B and $80000) <> 0;
          FTiles[I].MirrorT := (B and $40000) <> 0;
          FTiles[I].MaskT := (B shr 14) and 15;
          FTiles[I].ShiftT := (B shr 10) and 15;
          FTiles[I].ClampS := (B and $200) <> 0;
          FTiles[I].MirrorS := (B and $100) <> 0;
          FTiles[I].MaskS := (B shr 4) and 15;
          FTiles[I].ShiftS := B and 15;
        end;
      50, 51, 52, 48:
        begin
          var I := (B shr 24) and 7;
          var SL := Integer((A shr 12) and $FFF);
          var TL := Integer(A and $FFF);
          var SH := Integer((B shr 12) and $FFF);
          var TH := Integer(B and $FFF);
          FTiles[I].SL := SL;
          FTiles[I].TL := TL;
          FTiles[I].SH := SH;
          FTiles[I].TH := TH;
          if Code = 50 then
          begin
            FTiles[I].SL := SL;
            FTiles[I].TL := TL;
            FTiles[I].SH := SH;
            FTiles[I].TH := TH
          end
          else if Code = 48 then
          begin
            if FTextureSize = 0 then
            begin
              FPipelineCrashed := True;
              FCommandCount := 0;
              Break
            end;
            var Count := ((SH div 4) - (SL div 4) + 1) and $FFF;
            if Count > 0 then
              Inc(FWorkClocks, Cardinal(Min(Count, 256)));
            for var J := 0 to Min(Count, 256) - 1 do
            begin
              var Source := UInt64(FTextureAddress) + Cardinal(((TL div 4) * FTextureWidth + SL div 4 + J) * 2);
              var V: Cardinal := 0;
              if Source + 1 < $800000 then
                V := (Cardinal(FBus.Read8(Cardinal(Source))) shl 8) or FBus.Read8(Cardinal(Source + 1));
              for var K := 0 to 3 do
              begin
                // Quad-coordinate loading expands S before tile-size addressing.
                // Standard TLUT tiles use size=4b; 8b/16b tiles leave sparse entries.
                var Stride := 8 shl Min(FTiles[I].Size, 2);
                var Address := (FTiles[I].TMEM * 8 + J * Stride + K * 2) and $FFF;
                FTMEM[Address] := Byte(V shr 8);
                FTMEM[(Address + 1) and $FFF] := Byte(V and $FF);
              end;
            end;
          end
          else
            LoadTexture(I, SL, TL, SH, TH, Code = 51);
        end;
      54, 36, 37:
        Rectangle(Code);
      55:
        FFill := B;
      56:
        FFogColor := B;
      57:
        FBlendColor := B;
      58:
        begin
          FPrimitive := B;
          FPrimitiveLOD := A and $FF;
          FMinLevel := (A shr 8) and 31;
        end;
      59:
        FEnvironment := B;
      61:
        begin
          FTextureFormat := (A shr 21) and 7;
          FTextureSize := (A shr 19) and 3;
          FTextureWidth := (A and $3FF) + 1;
          FTextureAddress := B and $FFFFFF
        end;
      63:
        begin
          FColorSize := (A shr 19) and 3;
          FColorFormat := (A shr 21) and 7;
          FColorWidth := (A and $3FF) + 1;
          FColorAddress := B and $FFFFFF
        end;
      60:
        begin
          FCombineHi := A and $FFFFFF;
          FCombineLo := B;
          FHasCombine := True
        end;
      46:
        begin
          FPrimitiveDepth := ((B shr 16) and $7FFF) * 8;
          FPrimitiveDelta := B and $FFFF
        end;
      62:
        FZAddress := B and $FFFFFF;
      44:
        begin
          FConvert[0] := Integer(SignedValue(SX((A shr 13) and $1FF, 9))) * 2 + 1;
          FConvert[1] := Integer(SignedValue(SX((A shr 4) and $1FF, 9))) * 2 + 1;
          FConvert[2] := Integer(SignedValue(SX(((A and 15) shl 5) or (B shr 27), 9))) * 2 + 1;
          FConvert[3] := Integer(SignedValue(SX((B shr 18) and $1FF, 9))) * 2 + 1;
          FConvert[4] := (B shr 9) and $1FF;
          FConvert[5] := B and $1FF;
        end;
      42:
        begin
          FKeyWidth[1] := (A shr 12) and $FFF;
          FKeyWidth[2] := A and $FFF;
          FKeyCenter[1] := (B shr 24) and $FF;
          FKeyScale[1] := (B shr 16) and $FF;
          FKeyCenter[2] := (B shr 8) and $FF;
          FKeyScale[2] := B and $FF;
        end;
      43:
        begin
          FKeyWidth[0] := (B shr 16) and $FFF;
          FKeyCenter[0] := (B shr 8) and $FF;
          FKeyScale[0] := B and $FF;
        end;
      8..15:
        Triangle(Code);
    else
      raise EN64Unsupported.CreateFmt('RDP opcode %2.2x is not implemented', [Code]);
    end;
    // Fill/copy memory writes use a 64-bit bus per RCP clock at peak throughput.
    Inc(FWorkClocks, (FTransferBits + 63) div 64);
    FTransferBits := 0;
    FCommandCount := 0;
    if Assigned(FOnCommandCompleted) then
      FOnCommandCompleted(TraceWords);
  end;
end;

procedure TN64RDP.SerializeState(State: TStateArchive);

  procedure ValidateFlag(var Flag);
  begin
    // Boolean's declared range is 0..1, so Ord(Flag)>1 may be optimized out.
    // Inspect the stored byte without interpreting it as a typed Boolean.
    var Raw: Byte;
    Move(Flag, Raw, SizeOf(Raw));
    if Raw > 1 then
      raise EReadError.Create('Invalid RDP Boolean snapshot');
  end;

begin
  State.Field(FTMEM, SizeOf(FTMEM));
  State.Field(FTiles, SizeOf(FTiles));
  State.Field(FColorAddress, 4);
  State.Field(FTextureAddress, 4);
  State.Field(FFill, 4);
  State.Field(FPrimitive, 4);
  State.Field(FEnvironment, 4);
  State.Field(FOtherHi, 4);
  State.Field(FOtherLo, 4);
  State.Field(FCombineHi, 4);
  State.Field(FCombineLo, 4);
  State.Field(FHasCombine, SizeOf(FHasCombine));
  State.Field(FBlendColor, 4);
  State.Field(FFogColor, 4);
  State.Field(FZAddress, 4);
  State.Field(FPrimitiveDepth, 4);
  State.Field(FPrimitiveDelta, 4);
  State.Field(FPrimitiveLOD, 4);
  State.Field(FConvert, SizeOf(FConvert));
  State.Field(FKeyWidth, SizeOf(FKeyWidth));
  State.Field(FKeyCenter, SizeOf(FKeyCenter));
  State.Field(FKeyScale, SizeOf(FKeyScale));
  State.Field(FNoiseSeed, 4);
  State.Field(FNoise, 4);
  State.Field(FLODFraction, 4);
  State.Field(FMinLevel, 4);
  State.Field(FShadeAlpha, 4);
  State.Field(FAlphaDither, 4);
  State.Field(FColorFormat, 4);
  State.Field(FColorWidth, 4);
  State.Field(FColorSize, 4);
  State.Field(FTextureWidth, 4);
  State.Field(FTextureSize, 4);
  State.Field(FTextureFormat, 4);
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FCommandCount, 4);
  State.Field(FWorkClocks, SizeOf(FWorkClocks));
  State.Field(FTransferBits, SizeOf(FTransferBits));
  State.Field(FPipelineCrashed, SizeOf(FPipelineCrashed));
  State.Field(FHiddenOld, SizeOf(FHiddenOld));
  State.Field(FDrawFlip, SizeOf(FDrawFlip));
  State.Field(FDelayedHidden, 4);
  State.Field(FMemoryColor, 4);
  State.Field(FMemoryCoverage, 4);
  State.Field(FScissorX0, 4);
  State.Field(FScissorY0, 4);
  State.Field(FScissorX1, 4);
  State.Field(FScissorY1, 4);
  State.Field(FScissorQuarterX0, 4);
  State.Field(FScissorQuarterY0, 4);
  State.Field(FScissorQuarterX1, 4);
  State.Field(FScissorQuarterY1, 4);
  State.Field(FScissorField, SizeOf(FScissorField));
  State.Field(FScissorOdd, SizeOf(FScissorOdd));
  if State.Loading then
  begin
    ValidateFlag(FHasCombine);
    ValidateFlag(FPipelineCrashed);
    ValidateFlag(FDrawFlip);
    ValidateFlag(FScissorField);
    ValidateFlag(FScissorOdd);
    for var I := 0 to High(FTiles) do
    begin
      ValidateFlag(FTiles[I].ClampS);
      ValidateFlag(FTiles[I].ClampT);
      ValidateFlag(FTiles[I].MirrorS);
      ValidateFlag(FTiles[I].MirrorT);
    end;
    if (FCommandCount < 0) or (FCommandCount >= Length(FCommand)) or Odd(FCommandCount) then
      raise EReadError.Create('Invalid RDP command snapshot');
    if (FColorSize < 0) or (FColorSize > 3) or (FZAddress > $FFFFFF) or
      (FPrimitiveDepth > $3FFFF) or (FPrimitiveDelta > $FFFF) or (FPrimitiveLOD > 255) or
      (FScissorX0 < 0) or (FScissorX0 > 1024) or (FScissorX1 < 0) or (FScissorX1 > 1024) or
      (FScissorY0 < 0) or (FScissorY0 > 1024) or (FScissorY1 < 0) or (FScissorY1 > 1024) then
      raise EReadError.Create('Invalid RDP rasterizer snapshot');
    for var I := 0 to 5 do
      if ((I < 4) and ((FConvert[I] < -511) or (FConvert[I] > 511))) or
        ((I >= 4) and ((FConvert[I] < 0) or (FConvert[I] > 511))) then
        raise EReadError.Create('Invalid RDP conversion snapshot');
    if (FColorWidth < 1) or (FColorWidth > 4096) or (FTextureWidth < 1) or (FTextureWidth > 4096) or
      (FTextureSize < 0) or (FTextureSize > 3) then
      raise EReadError.Create('Invalid RDP snapshot');
    if (FMinLevel < 0) or (FMinLevel > 31) or (FLODFraction < 0) or (FLODFraction > 511) or
      (FShadeAlpha < 0) or (FShadeAlpha > 255) or (FAlphaDither < 0) or (FAlphaDither > 7) or
      (FColorFormat < 0) or (FColorFormat > 7) or
      (FScissorQuarterX0 < 0) or (FScissorQuarterX0 > 4096) or
      (FScissorQuarterY0 < 0) or (FScissorQuarterY0 > 4096) or
      (FScissorQuarterX1 < 0) or (FScissorQuarterX1 > 4096) or
      (FScissorQuarterY1 < 0) or (FScissorQuarterY1 > 4096) then
      raise EReadError.Create('Invalid RDP pipeline snapshot');
    if (FDelayedHidden < -1) or (FDelayedHidden > $800000) or (FMemoryCoverage < 0) or (FMemoryCoverage > 7) or (FNoise > $1FF) or
      (FWorkClocks > UInt64($10000000000)) then
      raise EReadError.Create('Invalid RDP memory/timing snapshot');
    if FTransferBits > UInt64($10000000000) then
      raise EReadError.Create('Invalid RDP transfer timing snapshot');
    for var I := 0 to High(FHiddenOld) do
      if FHiddenOld[I] > 3 then
        raise EReadError.Create('Invalid RDP hidden snapshot');
    for var I := 0 to 2 do
      if (FKeyWidth[I] < 0) or (FKeyWidth[I] > 4095) or (FKeyCenter[I] < 0) or (FKeyCenter[I] > 255) or
        (FKeyScale[I] < 0) or (FKeyScale[I] > 255) then
        raise EReadError.Create('Invalid RDP key snapshot');
    for var I := 0 to 7 do
      if (FTiles[I].Format < 0) or (FTiles[I].Format > 7) or
        (FTiles[I].SL < 0) or (FTiles[I].SL > 4095) or (FTiles[I].SH < 0) or (FTiles[I].SH > 4095) or
        (FTiles[I].TL < 0) or (FTiles[I].TL > 4095) or (FTiles[I].TH < 0) or (FTiles[I].TH > 4095) or
        (FTiles[I].TMEM < 0) or (FTiles[I].TMEM > 511) or
        (FTiles[I].Palette < 0) or (FTiles[I].Palette > 15) or (FTiles[I].Size < 0) or (FTiles[I].Size > 3) or (FTiles[I].Line < 0) or (FTiles[I].Line > 511) or
        (FTiles[I].MaskS < 0) or (FTiles[I].MaskS > 15) or (FTiles[I].MaskT < 0) or (FTiles[I].MaskT > 15) or
        (FTiles[I].ShiftS < 0) or (FTiles[I].ShiftS > 15) or (FTiles[I].ShiftT < 0) or (FTiles[I].ShiftT > 15) then
        raise EReadError.Create('Invalid RDP tile snapshot');
  end;
end;

end.

