unit Saturn.SCSP.DSP;

interface

uses
  Core.Snapshots;

type
  TSCSPRead = function(Address: Cardinal): Byte of object;

  TSCSPWrite = procedure(Address: Cardinal; Value: Byte) of object;

  PSCSPDecodedInstruction = ^TSCSPDecodedInstruction;

  TSCSPDecodedInstruction = record
    I0, I1, I2, I3: Word;
    ReadTemp, InputIndex, YSelect, Shift: Byte;
    MemoryIndex, EffectIndex, CoefficientAddress, AddressWord: Byte;
  end;

  TSCSPDSP = class
  private
    FRead: TSCSPRead;
    FWrite: TSCSPWrite;
    FRegisters: array[0..$4FF] of Byte;
    FProgram: array[0..127] of TSCSPDecodedInstruction;
    FProgramDirty: Boolean; // derived decode cache, excluded from snapshots
    FTemp: array[0..127] of Integer;
    FMemory: array[0..31] of Integer;
    FMix: array[0..15] of Integer;
    FEffects: array[0..15] of SmallInt;
    FExternal: array[0..1] of SmallInt;
    FDelay, FMemoryValue: Integer;
    FReadAddress, FWriteAddress: Cardinal;
    FWriteValue: Word;
    FReadPending, FWritePending, FReadLinear, FRunning: Boolean;
    procedure DecodeProgram;
    function WordAt(Address: Integer): Word; inline;
  public
    RingBase, RingLength: Integer;
    constructor Create(Read: TSCSPRead; Write: TSCSPWrite);
    procedure Reset;
    function ReadRegister(Address: Integer): Byte;
    procedure WriteRegister(Address: Integer; Value: Byte);
    procedure Mix(Channel, Sample: Integer);
    procedure external(Left, Right: SmallInt);
    function Effect(Channel: Integer): Integer;
    procedure Step;
    procedure SerializeState(Archive: TStateArchive);
  end;

implementation

uses
  System.Math;

{$Q-}{$R-}
function Sar(Value: Int64; Count: Integer): Integer; inline;
begin
  // All DSP callers shift by 0..16 and consume only the low 32 result bits.
  // Logical and arithmetic 64-bit shifts differ only above those bits.
  Result := Integer(UInt64(Value) shr Count);
end;

function Signed(Value: Int64; Bits: Integer): Integer; inline;
begin
  // Bias/unbias performs sign extension without a data-dependent branch.
  var Sign: Cardinal := Cardinal(1) shl (Bits - 1);
  Result := Integer(((Cardinal(Value) and (Sign * 2 - 1)) xor Sign) - Sign);
end;
{$Q+}{$R+}

// Same 1:4:11 signed floating sample format as the later AICA. PCM remains
// big endian on Saturn; these conversions operate on the numeric word.

function Pack(Value: Integer): Word;
begin
  var Sign: Integer := (Value shr 23) and 1;
  var V := Value and $FFFFFF;
  var Test: Integer := (V xor (V shl 1)) and $FFFFFF;
  var Exponent: Integer := 0;
  while (Exponent < 12) and (Test and $800000 = 0) do
  begin
    Test := Test shl 1;
    Inc(Exponent);
  end;
  var Mantissa: Integer;
  if Exponent < 12 then
    Mantissa := Integer((UInt64(V) shl Exponent) and $3FFFFF) shr 11
  else
    Mantissa := V;
  Result := (Mantissa and $7FF) or (Exponent shl 11) or (Sign shl 15);
end;

function Unpack(Value: Word): Integer;
begin
  var Sign: Integer := (Value shr 15) and 1;
  var Exponent: Integer := (Value shr 11) and 15;
  var V: Integer := (Value and $7FF) shl 11;
  if Exponent > 11 then
  begin
    Exponent := 11;
    V := V or (Sign shl 22);
  end
  else
    V := V or ((Sign xor 1) shl 22);
  Result := Sar(Signed(V or (Sign shl 23), 24), Exponent);
end;

constructor TSCSPDSP.Create(Read: TSCSPRead; Write: TSCSPWrite);
begin
  inherited Create;
  FRead := Read;
  FWrite := Write;
  Reset;
end;

procedure TSCSPDSP.Reset;
begin
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FillChar(FTemp, SizeOf(FTemp), 0);
  FillChar(FMemory, SizeOf(FMemory), 0);
  FillChar(FMix, SizeOf(FMix), 0);
  FillChar(FEffects, SizeOf(FEffects), 0);
  FillChar(FExternal, SizeOf(FExternal), 0);
  FDelay := 0;
  FMemoryValue := 0;
  FReadAddress := 0;
  FWriteAddress := 0;
  FWriteValue := 0;
  FReadPending := False;
  FWritePending := False;
  FReadLinear := False;
  FRunning := False;
  FProgramDirty := True;
  RingBase := 0;
  RingLength := 8192;
end;

{$Q-}{$R-}
function TSCSPDSP.WordAt(Address: Integer): Word;
begin
  Result := Swap(PWord(@FRegisters[Address])^);
end;
{$Q+}{$R+}

function TSCSPDSP.ReadRegister(Address: Integer): Byte;
begin
  if (Address >= $700) and (Address < $C00) then
    Exit(FRegisters[Address - $700]);

  var V: Integer := 0;
  var Shift: Integer := (3 - (Address and 3)) * 8;
  if (Address >= $C00) and (Address < $E00) then
    V := (FTemp[(Address - $C00) div 4] and $FFFFFF) shl 8
  else if (Address >= $E00) and (Address < $E80) then
    V := (FMemory[(Address - $E00) div 4] and $FFFFFF) shl 8
  else if (Address >= $E80) and (Address < $EC0) then
    V := (FMix[(Address - $E80) div 4] and $FFFFF) shl 12
  else if (Address >= $EC0) and (Address < $EE0) then
  begin
    V := Word(FEffects[(Address - $EC0) div 2]);
    Shift := (1 - (Address and 1)) * 8;
  end
  else if (Address >= $EE0) and (Address < $EE4) then
  begin
    V := Word(FExternal[(Address - $EE0) div 2]);
    Shift := (1 - (Address and 1)) * 8;
  end;
  Result := (V shr Shift) and $FF;
end;

procedure TSCSPDSP.WriteRegister(Address: Integer; Value: Byte);
begin
  if (Address >= $700) and (Address < $C00) then
  begin
    FRegisters[Address - $700] := Value;
    if Address >= $800 then
      FProgramDirty := True;
    if Address = $BFF then
      FRunning := True;
  end;
end;

procedure TSCSPDSP.Mix(Channel, Sample: Integer);
begin
  FMix[Channel and 15] := Signed(Int64(FMix[Channel and 15]) + Sample, 20);
end;

procedure TSCSPDSP.external(Left, Right: SmallInt);
begin
  FExternal[0] := Left;
  FExternal[1] := Right;
end;

function TSCSPDSP.Effect(Channel: Integer): Integer;
begin
  Result := FEffects[Channel and 15];
end;

procedure TSCSPDSP.DecodeProgram;
begin
  for var Index := 0 to 127 do
  begin
    var P := $100 + Index * 8;
    var D := PSCSPDecodedInstruction(@FProgram[Index]);
    D.I0 := WordAt(P);
    D.I1 := WordAt(P + 2);
    D.I2 := WordAt(P + 4);
    D.I3 := WordAt(P + 6);
    D.ReadTemp := (D.I0 shr 8) and 127;
    D.InputIndex := (D.I1 shr 6) and 63;
    D.YSelect := (D.I1 shr 13) and 3;
    D.Shift := (D.I2 shr 4) and 3;
    D.MemoryIndex := D.I1 and 31;
    D.EffectIndex := (D.I2 shr 8) and 15;
    D.CoefficientAddress := ((D.I3 shr 9) and 63) * 2;
    D.AddressWord := $80 + ((D.I3 shr 2) and 31) * 2;
  end;
  FProgramDirty := False;
end;

// Internal microcode fields and all register indices are masked to their
// hardware widths. Bus callbacks and public register/state access stay checked.

{$Q-}{$R-}
procedure TSCSPDSP.Step;
begin
  FillChar(FEffects, SizeOf(FEffects), 0);
  if not FRunning then
  begin
    FillChar(FMix, SizeOf(FMix), 0);
    Exit;
  end;

  if FProgramDirty then
    DecodeProgram;
  var Acc: Integer := 0;
  var Fraction: Integer := 0;
  var YRegister: Integer := 0;
  var AddressRegister: Integer := 0;
  for var Index := 0 to 127 do
  begin
    var Decoded := PSCSPDecodedInstruction(@FProgram[Index]);
    var I0 := Decoded.I0;
    var I1 := Decoded.I1;
    var I2 := Decoded.I2;
    var I3 := Decoded.I3;
    var ReadTemp: Integer := Decoded.ReadTemp;
    var InputIndex: Integer := Decoded.InputIndex;
    var Input: Integer := 0;
    if InputIndex < 32 then
      Input := FMemory[InputIndex]
    else if InputIndex < 48 then
      Input := Signed(Int64(FMix[InputIndex - 32]) * 16, 24)
    else if InputIndex < 50 then
      Input := Integer(FExternal[InputIndex - 48]) * 256;
    if I1 and $20 <> 0 then
      FMemory[Decoded.MemoryIndex] := FMemoryValue;
    var B: Integer := 0;
    if I2 and 2 = 0 then
    begin
      B := FTemp[(ReadTemp + FDelay) and 127];
      if I2 and 1 <> 0 then
        B := Acc;
      if I2 and 4 <> 0 then
        B := -B;
    end;
    var X := Input;
    if I1 and $8000 = 0 then
      X := FTemp[(ReadTemp + FDelay) and 127];
    var Y: Integer := 0;
    case Decoded.YSelect of
      0:
        Y := Fraction;
      1:
        // COEF is signed Q1.12 in register bits 15..3; low bits are unused.
        Y := WordAt(Decoded.CoefficientAddress) shr 3;
      2:
        Y := (YRegister shr 11) and $1FFF;
      3:
        Y := (YRegister shr 4) and $FFF;
    end;
    Y := Signed(Y, 13);
    if I2 and 8 <> 0 then
      YRegister := Input;
    var Shift: Integer := Decoded.Shift;
    var Shifted: Integer := 0;
    case Shift of
      0:
        Shifted := EnsureRange(Acc, -$800000, $7FFFFF);
      1:
        Shifted := EnsureRange(Int64(Acc) * 2, -$800000, $7FFFFF);
      2:
        Shifted := Signed(Int64(Acc) * 2, 24);
      3:
        Shifted := Signed(Acc, 24);
    end;
    Acc := Signed(Int64(Sar(Int64(X) * Y, 12)) + B, 26);
    if I0 and $80 <> 0 then
      FTemp[((I0 and 127) + FDelay) and 127] := Shifted;
    if I2 and $1000 <> 0 then
      FEffects[Decoded.EffectIndex] := Sar(Shifted, 8);
    if I2 and $40 <> 0 then
    begin
      if Shift = 3 then
        Fraction := Shifted and $FFF
      else
        Fraction := (Shifted shr 11) and $1FFF;
    end;

    // Read pipeline: IWT observes the result from two microsteps earlier.
    if FReadPending then
    begin
      var V: Word := (Word(FRead(FReadAddress)) shl 8) or FRead((FReadAddress + 1) and $7FFFF);
      if FReadLinear then
        FMemoryValue := SmallInt(V) * 256
      else
        FMemoryValue := Unpack(V);
      FReadPending := False;
    end;
    if FWritePending then
    begin
      FWrite(FWriteAddress, FWriteValue shr 8);
      FWrite((FWriteAddress + 1) and $7FFFF, FWriteValue and $FF);
      FWritePending := False;
    end;
    if I2 and $6000 <> 0 then
    begin
      var A: Integer := WordAt(Decoded.AddressWord);
      if I2 and $8000 = 0 then
        Inc(A, FDelay);
      if I3 and 2 <> 0 then
        Inc(A, AddressRegister and $FFF);
      if I3 and 1 <> 0 then
        Inc(A);
      if I2 and $8000 = 0 then
        A := A and (RingLength - 1)
      else
        A := A and $FFFF;
      A := (A * 2 + RingBase) and $7FFFF;
      if I2 and $2000 <> 0 then
      begin
        FReadAddress := A;
        FReadPending := True;
        FReadLinear := I3 and $8000 <> 0;
      end;
      if I2 and $4000 <> 0 then
      begin
        FWriteAddress := A;
        FWritePending := True;
        if I3 and $8000 <> 0 then
          FWriteValue := Sar(Shifted, 8) and $FFFF
        else
          FWriteValue := Pack(Shifted);
      end;
    end;
    if I2 and $80 <> 0 then
    begin
      if Shift = 3 then
        AddressRegister := (Shifted shr 12) and $FFF
      else
        AddressRegister := Sar(Input, 16);
    end;
  end;
  FDelay := (FDelay - 1) and $FFFF;
  FillChar(FMix, SizeOf(FMix), 0);
end;

{$Q+}{$R+}
procedure TSCSPDSP.SerializeState(Archive: TStateArchive);
begin
  if Archive.Loading then
    FProgramDirty := True;
  Archive.Field(FRegisters, SizeOf(FRegisters));
  Archive.Field(FTemp, SizeOf(FTemp));
  Archive.Field(FMemory, SizeOf(FMemory));
  Archive.Field(FMix, SizeOf(FMix));
  Archive.Field(FEffects, SizeOf(FEffects));
  Archive.Field(FExternal, SizeOf(FExternal));
  Archive.Field(FDelay, SizeOf(FDelay));
  Archive.Field(FMemoryValue, SizeOf(FMemoryValue));
  Archive.Field(FReadAddress, SizeOf(FReadAddress));
  Archive.Field(FWriteAddress, SizeOf(FWriteAddress));
  Archive.Field(FWriteValue, SizeOf(FWriteValue));
  Archive.Field(FReadPending, SizeOf(FReadPending));
  Archive.Field(FWritePending, SizeOf(FWritePending));
  Archive.Field(FReadLinear, SizeOf(FReadLinear));
  Archive.Field(FRunning, SizeOf(FRunning));
  Archive.Field(RingBase, SizeOf(RingBase));
  Archive.Field(RingLength, SizeOf(RingLength));
end;

end.

