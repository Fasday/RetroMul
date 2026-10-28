program ComputeTest;

{$APPTYPE CONSOLE}
{$O+}{$Q-}{$R-}
{$EXCESSPRECISION OFF}
{$POINTERMATH ON}

// Headless checks of the Vulkan compute path. Every kernel's output is
// compared exactly with the same computation done here in Pascal.
// ComputeTest [-device name] [-validation]

uses
  System.SysUtils, System.StrUtils, System.Types, System.Math, System.Diagnostics, RM.Vulkan.Bindings, RM.Vulkan.Loader, RM.Vulkan.Compute;

{$I TestArith.spv.inc}
{$I TestBytes.spv.inc}
{$I TestFloat.spv.inc}
{$I TestTriangles.spv.inc}

var
  Failures: Integer;
  Seed: Cardinal = $2545F491;

function Rand: Cardinal;
begin
  Seed := Seed xor (Seed shl 13);
  Seed := Seed xor (Seed shr 17);
  Seed := Seed xor (Seed shl 5);
  Result := Seed;
end;

function RandRange(Lo, Hi: Integer): Integer;
begin
  Result := Lo + Integer(Rand mod Cardinal(Hi - Lo + 1));
end;

// Interesting operands more often than uniform random words would give them.
function Operand: Cardinal;
const
  Special: array[0..11] of Cardinal = (0, 1, 2, 3, $FFFFFFFF, $FFFFFFFE, $80000000, $7FFFFFFF, $80000001, $FFFF, $10000, $8000);
begin
  case Rand mod 8 of
    0: Result := Special[Rand mod Cardinal(Length(Special))];
    1: Result := Rand mod 256;
    2: Result := Cardinal(-Integer(Rand mod 1000));
  else
    Result := Rand;
  end;
end;

procedure Report(const Test: string; Bad, Total: Integer);
begin
  if Bad = 0 then
    Writeln(Format('  ok    %-34s %d values', [Test, Total]))
  else
  begin
    Writeln(Format('  FAIL  %-34s %d of %d differ', [Test, Bad, Total]));
    Inc(Failures);
  end;
end;

function Sar32(V: Integer; N: Cardinal): Integer;
begin
  if V < 0 then
    Result := not Integer(Cardinal(not V) shr N)
  else
    Result := Integer(Cardinal(V) shr N);
end;

function Sar64(V: Int64; N: Cardinal): Int64;
begin
  if V < 0 then
    Result := not Int64(UInt64(not V) shr N)
  else
    Result := Int64(UInt64(V) shr N);
end;

function MSB(V: Cardinal): Integer;
begin
  Result := -1;
  for var I := 31 downto 0 do
    if V and (Cardinal(1) shl I) <> 0 then
      Exit(I);
end;

function LSB(V: Cardinal): Integer;
begin
  Result := -1;
  for var I := 0 to 31 do
    if V and (Cardinal(1) shl I) <> 0 then
      Exit(I);
end;

function Bits(V: Cardinal): Integer;
begin
  Result := 0;
  while V <> 0 do
  begin
    Inc(Result, V and 1);
    V := V shr 1;
  end;
end;

procedure ExpectArith(A, B, C, D: Cardinal; var O: array of Cardinal);
begin
  var SA := Integer(A);
  var SB := Integer(B);
  O[0] := A + B;
  O[1] := A - B;
  O[2] := Cardinal(UInt64(A) * B);
  O[3] := Cardinal((UInt64(A) * B) shr 32);
  O[4] := Cardinal(UInt64(Int64(SA) * SB) shr 32);
  O[5] := A shr (B and 31);
  O[6] := Cardinal(Sar32(SA, B and 31));
  O[7] := A shl (C and 31);
  if B <> 0 then
  begin
    O[8] := A div B;
    O[9] := A mod B;
  end
  else
  begin
    O[8] := 0;
    O[9] := 0;
  end;
  var SD := Sar32(SB, D and 15);
  if (SD <> 0) and not ((SA = Low(Integer)) and (SD = -1)) then
  begin
    O[10] := Cardinal(SA div SD);
    // GLSL % on signed integers is OpSMod: the sign of the divisor.
    var R := SA mod SD;
    if (R <> 0) and ((R < 0) <> (SD < 0)) then
      R := R + SD;
    O[11] := Cardinal(R);
  end
  else
  begin
    O[10] := 0;
    O[11] := 0;
  end;
  O[12] := Cardinal(Min(SA, SB));
  if A > B then O[13] := A else O[13] := B;
  var Off := C and 15;
  var Count := D and 15;
  O[14] := (A shr Off) and ((Cardinal(1) shl Count) - 1);
  var Field := (A shr Off) and ((Cardinal(1) shl (Count + 1)) - 1);
  if Field and (Cardinal(1) shl Count) <> 0 then
    Field := Field or not ((Cardinal(1) shl (Count + 1)) - 1);
  O[15] := Field;
  O[16] := Cardinal(Bits(A)) or (Cardinal(MSB(B)) shl 8) or (Cardinal(LSB(C)) shl 16);
  O[17] := Cardinal(Abs(SA)) xor Cardinal(Sign(SB));

  var A64 := UInt64(A) or (UInt64(B) shl 32);
  var B64 := UInt64(C) or (UInt64(D) shl 32);
  var SA64 := Int64(A64);
  var SB64 := Int64(B64);
  var P: UInt64;
  P := A64 + B64; O[18] := Cardinal(P); O[19] := Cardinal(P shr 32);
  P := A64 - B64; O[20] := Cardinal(P); O[21] := Cardinal(P shr 32);
  P := A64 * B64; O[22] := Cardinal(P); O[23] := Cardinal(P shr 32);
  P := A64 shr (C and 63); O[24] := Cardinal(P); O[25] := Cardinal(P shr 32);
  P := UInt64(Sar64(SA64, D and 63)); O[26] := Cardinal(P); O[27] := Cardinal(P shr 32);
  var SD64 := Sar64(SB64, A and 31);
  if (SD64 <> 0) and not ((SA64 = Low(Int64)) and (SD64 = -1)) then
    P := UInt64(SA64 div SD64)
  else
    P := 0;
  O[28] := Cardinal(P); O[29] := Cardinal(P shr 32);
  if B64 <> 0 then
    P := A64 div B64
  else
    P := 0;
  O[30] := Cardinal(P); O[31] := Cardinal(P shr 32);
  P := UInt64(Int64(SA) * SB + SA); O[32] := Cardinal(P); O[33] := Cardinal(P shr 32);
  O[34] := Ord(SA64 < SB64) or (Ord(A64 < B64) shl 1) or (Ord(SA64 = SA) shl 2);

  var X := SmallInt(A);
  var Y := SmallInt(B);
  var UX := Word(A);
  var UY := Word(B);
  O[35] := Word(UX + UY);
  O[36] := Word(Cardinal(UX) * UY);
  O[37] := Cardinal(Integer(SmallInt(Integer(X) * Y)));
  O[38] := Cardinal(Sar32(X, C and 15));
  O[39] := UX shr (D and 15);
  O[40] := Cardinal(Integer(X) + Y);
  if (Y <> 0) and not ((X = -32768) and (Y = -1)) then
    O[41] := Cardinal(Integer(SmallInt(X div Y)))
  else
    O[41] := 0;

  var S8 := ShortInt(A);
  var U8 := Byte(A);
  var V8 := Byte(B);
  O[42] := Cardinal(Integer(S8));
  O[43] := Byte(U8 + V8);
  O[44] := Byte(Cardinal(U8) * V8);
  O[45] := Cardinal(Sar32(S8, 2));
  O[46] := Cardinal(SA * S8);
  O[47] := Cardinal((UInt64(A) * B) shr 16);
end;

procedure TestArith(C: TVulkanCompute; Cmd: TVulkanCommands);
const
  N = 4096;
  Stride = 48;
var
  Inputs: array of Cardinal;
  Expected: array[0..Stride - 1] of Cardinal;
begin
  SetLength(Inputs, N * 4);
  for var I := 0 to High(Inputs) do
    Inputs[I] := Operand;
  var Src := C.CreateBuffer(Length(Inputs) * 4, vbkUpload);
  var Dst := C.CreateBuffer(N * Stride * 4, vbkReadback);
  var K := C.CreateKernel(TestArithSPV, 2, 4);
  try
    Src.Write(0, Inputs[0], Length(Inputs) * 4);
    K.Bind(0, Src);
    K.Bind(1, Dst);
    var Count: Cardinal := N;
    Cmd.Start;
    Cmd.Dispatch(K, (N + 63) div 64, 1, 1, Count, 4);
    Cmd.FullBarrier;
    Cmd.Run;
    Dst.Invalidate;
    var Got := PCardinal(Dst.Data);
    var Bad: array[0..Stride - 1] of Integer;
    FillChar(Bad, SizeOf(Bad), 0);
    for var I := 0 to N - 1 do
    begin
      ExpectArith(Inputs[I * 4], Inputs[I * 4 + 1], Inputs[I * 4 + 2], Inputs[I * 4 + 3], Expected);
      for var J := 0 to Stride - 1 do
        if PCardinal(PByte(Got) + (I * Stride + J) * 4)^ <> Expected[J] then
        begin
          if Bad[J] = 0 then
            Writeln(Format('    op %d: %.8x %.8x %.8x %.8x -> %.8x, expected %.8x', [J, Inputs[I * 4], Inputs[I * 4 + 1],
              Inputs[I * 4 + 2], Inputs[I * 4 + 3], PCardinal(PByte(Got) + (I * Stride + J) * 4)^, Expected[J]]));
          Inc(Bad[J]);
        end;
    end;
    var Total32 := 0; var Total64 := 0; var Total16 := 0; var Total8 := 0;
    for var J := 0 to 17 do Inc(Total32, Bad[J]);
    for var J := 18 to 34 do Inc(Total64, Bad[J]);
    for var J := 35 to 41 do Inc(Total16, Bad[J]);
    for var J := 42 to 47 do Inc(Total8, Bad[J]);
    Report('32-bit integer arithmetic', Total32, N * 18);
    Report('64-bit integer arithmetic', Total64, N * 17);
    Report('16-bit integer arithmetic', Total16, N * 7);
    Report('8-bit integer arithmetic', Total8, N * 6);
  finally
    K.Free;
    Dst.Free;
    Src.Free;
  end;
end;

procedure TestBuffers(C: TVulkanCompute; Cmd: TVulkanCommands);
const
  N = 1001;
var
  Bytes: array of Byte;
  Halves: array of Word;
begin
  SetLength(Bytes, N);
  SetLength(Halves, N);
  for var I := 0 to N - 1 do
  begin
    Bytes[I] := Byte(Rand);
    Halves[I] := Word(Rand);
  end;
  var Size8 := (N + 3) and not 3;
  var Size16 := (N * 2 + 3) and not 3;
  var Upload := C.CreateBuffer(Size8 + Size16, vbkUpload);
  var DevBytes := C.CreateBuffer(Size8, vbkDevice);
  var DevHalves := C.CreateBuffer(Size16, vbkDevice);
  var DevWords := C.CreateBuffer(N * 4, vbkDevice);
  var DevOutBytes := C.CreateBuffer(Size8, vbkDevice);
  var DevOutHalves := C.CreateBuffer(Size16, vbkDevice);
  var Scratch := C.CreateBuffer(4096, vbkDevice);
  var Back := C.CreateBuffer(N * 4 + Size8 + Size16 + 4096, vbkReadback);
  var K := C.CreateKernel(TestBytesSPV, 5, 4);
  try
    Upload.Write(0, Bytes[0], N);
    Upload.Write(Size8, Halves[0], N * 2);
    K.Bind(0, DevBytes);
    K.Bind(1, DevHalves);
    K.Bind(2, DevWords);
    K.Bind(3, DevOutBytes);
    K.Bind(4, DevOutHalves);
    var Pattern: array[0..63] of Cardinal;
    for var I := 0 to High(Pattern) do
      Pattern[I] := Rand;
    var Count: Cardinal := N;
    Cmd.Start;
    Cmd.Copy(Upload, DevBytes, 0, 0, Size8);
    Cmd.Copy(Upload, DevHalves, Size8, 0, Size16);
    Cmd.Fill(Scratch, 0, 4096, $A5C3E1F0);
    Cmd.Barrier(VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT or
      VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_SHADER_READ_BIT or VK_ACCESS_TRANSFER_WRITE_BIT);
    Cmd.Update(Scratch, 1024, Pattern, SizeOf(Pattern));
    Cmd.Dispatch(K, (N + 63) div 64, 1, 1, Count, 4);
    Cmd.FullBarrier;
    Cmd.Copy(DevWords, Back, 0, 0, N * 4);
    Cmd.Copy(DevOutBytes, Back, 0, N * 4, Size8);
    Cmd.Copy(DevOutHalves, Back, 0, N * 4 + Size8, Size16);
    Cmd.Copy(Scratch, Back, 0, N * 4 + Size8 + Size16, 4096);
    Cmd.FullBarrier;
    Cmd.Run;
    Back.Invalidate;
    var P := Back.Data;
    var Bad := 0;
    for var I := 0 to N - 1 do
    begin
      var W := Cardinal(Bytes[I]) or (Cardinal(Halves[I]) shl 8) or (Cardinal(Ord(Bytes[I] >= 128)) shl 31);
      if PCardinal(P + I * 4)^ <> W then Inc(Bad);
      if P[N * 4 + I] <> Bytes[I] xor $5A then Inc(Bad);
      if PWord(P + N * 4 + Size8 + I * 2)^ <> Word(Halves[I] + I) then Inc(Bad);
    end;
    Report('8/16-bit storage loads and stores', Bad, N * 3);
    Bad := 0;
    var S := P + N * 4 + Size8 + Size16;
    for var I := 0 to 1023 do
    begin
      var Want: Cardinal := $A5C3E1F0;
      if (I >= 256) and (I < 256 + 64) then
        Want := Pattern[I - 256];
      if PCardinal(S + I * 4)^ <> Want then
        Inc(Bad);
    end;
    Report('buffer copy, fill and update', Bad, 1024);
  finally
    K.Free;
    Back.Free;
    Scratch.Free;
    DevOutHalves.Free;
    DevOutBytes.Free;
    DevWords.Free;
    DevHalves.Free;
    DevBytes.Free;
    Upload.Free;
  end;
end;

function FloatOperand: Cardinal;
const
  Special: array[0..13] of Cardinal = ($00000000, $80000000, $3F800000, $BF800000, $7F800000, $FF800000, $7FC00000,
    $00000001, $807FFFFF, $00800000, $7F7FFFFF, $3F000000, $4B000000, $CB7FFFFF);
begin
  case Rand mod 8 of
    0: Result := Special[Rand mod Cardinal(Length(Special))];
    1: Result := (Rand and $807FFFFF) or (Cardinal(RandRange(100, 154)) shl 23);
    2: Result := Rand and $807FFFFF;
    3: Result := (Rand and $80FFFFFF) or (Cardinal(RandRange(120, 135)) shl 23);
  else
    Result := Rand;
  end;
end;

function SameBits32(A, B: Cardinal): Boolean;
begin
  Result := (A = B) or (((A and $7F800000) = $7F800000) and ((A and $7FFFFF) <> 0) and
    ((B and $7F800000) = $7F800000) and ((B and $7FFFFF) <> 0));
end;

function SameBits64(A, B: UInt64): Boolean;
const
  E = UInt64($7FF0000000000000);
  M = UInt64($000FFFFFFFFFFFFF);
begin
  Result := (A = B) or (((A and E) = E) and ((A and M) <> 0) and ((B and E) = E) and ((B and M) <> 0));
end;

function F32(V: Cardinal): Single; inline;
begin
  Result := PSingle(@V)^;
end;

function B32(V: Single): Cardinal; inline;
begin
  Result := PCardinal(@V)^;
end;

function B64(V: Double): UInt64; inline;
begin
  Result := PUInt64(@V)^;
end;

// roundEven and floor keep the sign of a zero result.
function RoundEven32(V: Single): Single;
begin
  if IsNan(V) or IsInfinite(V) or (Abs(V) >= 8388608) then
    Exit(V);
  Result := Round(V);
  if (Result = 0) and (B32(V) and $80000000 <> 0) then
    Result := F32($80000000);
end;

function Floor32(V: Single): Single;
begin
  if IsNan(V) or IsInfinite(V) or (Abs(V) >= 8388608) or (V = 0) then
    Exit(V);
  Result := Floor(V);
end;

function RoundEven64(V: Double): Double;
begin
  if IsNan(V) or IsInfinite(V) or (Abs(V) >= 4503599627370496.0) then
    Exit(V);
  Result := Round(V);
  if (Result = 0) and (B64(V) and UInt64($8000000000000000) <> 0) then
  begin
    var Z := UInt64($8000000000000000);
    Result := PDouble(@Z)^;
  end;
end;

procedure TestFloat(C: TVulkanCompute; Cmd: TVulkanCommands);
const
  N = 65536;
  Stride = 24;
var
  Inputs: array of Cardinal;
begin
  {$IFDEF CPUX86}
  Writeln('  skip  IEEE float comparison: the Win32 CPU uses x87 extended intermediates');
  Exit;
  {$ENDIF}
  if not (C.Features.Float64 and C.Features.DenormPreserve32 and C.Features.RoundEven32 and C.Features.DenormPreserve64 and
    C.Features.RoundEven64) then
  begin
    Writeln('  skip  IEEE float controls (not supported)');
    Exit;
  end;
  SetLength(Inputs, N * 4);
  for var I := 0 to N - 1 do
  begin
    Inputs[I * 4] := FloatOperand;
    Inputs[I * 4 + 1] := FloatOperand;
    Inputs[I * 4 + 2] := Operand;
    Inputs[I * 4 + 3] := Rand;
    case Rand mod 4 of
      0: Inputs[I * 4 + 3] := (Inputs[I * 4 + 1] and $800FFFFF) or (Cardinal(RandRange(1000, 1046)) shl 20);
      1: Inputs[I * 4 + 3] := Inputs[I * 4 + 1] and $800FFFFF;
    end;
  end;
  var Src := C.CreateBuffer(Length(Inputs) * 4, vbkUpload);
  var Dst := C.CreateBuffer(N * Stride * 4, vbkReadback);
  var K := C.CreateKernel(TestFloatSPV, 2, 4);
  try
    Src.Write(0, Inputs[0], Length(Inputs) * 4);
    K.Bind(0, Src);
    K.Bind(1, Dst);
    var Count: Cardinal := N;
    Cmd.Start;
    Cmd.Dispatch(K, (N + 63) div 64, 1, 1, Count, 4);
    Cmd.FullBarrier;
    Cmd.Run;
    Dst.Invalidate;
    var Bad: array[0..Stride - 1] of Integer;
    FillChar(Bad, SizeOf(Bad), 0);
    var G := PCardinal(Dst.Data);
    for var I := 0 to N - 1 do
    begin
      var R := PCardinal(PByte(G) + I * Stride * 4);
      var W: PCardinal;
      var FA := F32(Inputs[I * 4]);
      var FB := F32(Inputs[I * 4 + 1]);
      var DAb := UInt64(Inputs[I * 4]) or (UInt64(Inputs[I * 4 + 1]) shl 32);
      var DBb := UInt64(Inputs[I * 4 + 2]) or (UInt64(Inputs[I * 4 + 3]) shl 32);
      var DA := PDouble(@DAb)^;
      var DB := PDouble(@DBb)^;
      var S: Single;
      S := FA + FB; if not SameBits32(R[0], B32(S)) then Inc(Bad[0]);
      if (not SameBits32(R[0], B32(S))) and (Bad[0] < 6) then
        Writeln(Format('    add %.8x + %.8x = %.8x, expected %.8x', [Inputs[I * 4], Inputs[I * 4 + 1], R[0], B32(S)]));
      S := FA * FB;
      if (not SameBits32(R[2], B32(S))) and (Bad[2] < 6) then
        Writeln(Format('    mul %.8x * %.8x = %.8x, expected %.8x', [Inputs[I * 4], Inputs[I * 4 + 1], R[2], B32(S)]));
      if (not SameBits32(R[6], B32(RoundEven32(FA)))) and (Bad[6] < 6) then
        Writeln(Format('    roundEven %.8x = %.8x, expected %.8x', [Inputs[I * 4], R[6], B32(RoundEven32(FA))]));
      var DS: Double := DA + DB;
      if (not SameBits64(PUInt64(@R[10])^, B64(DS))) and (Bad[10] < 6) then
        Writeln(Format('    dadd %.16x + %.16x = %.16x, expected %.16x', [DAb, DBb, PUInt64(@R[10])^, B64(DS)]));
      S := FA + FB;
      S := FA - FB; if not SameBits32(R[1], B32(S)) then Inc(Bad[1]);
      S := FA * FB; if not SameBits32(R[2], B32(S)) then Inc(Bad[2]);
      S := FA / FB; if not SameBits32(R[3], B32(S)) then Inc(Bad[3]);
      S := Integer(Inputs[I * 4 + 2]); if not SameBits32(R[4], B32(S)) then Inc(Bad[4]);
      var T: Cardinal := 0;
      if Abs(FA) < 2147483648.0 then
        T := Cardinal(Trunc(FA));
      if R[5] <> T then Inc(Bad[5]);
      if not SameBits32(R[6], B32(RoundEven32(FA))) then Inc(Bad[6]);
      if not SameBits32(R[7], B32(Floor32(FA))) then Inc(Bad[7]);
      var MI: Single := Integer(Inputs[I * 4 + 2]);
      var M: Single := MI * FB;
      S := M + FA; if not SameBits32(R[8], B32(S)) then Inc(Bad[8]);
      var DFA: Double := FA;
      var DFB: Double := FB;
      var D: Double := DFA * DFB;
      S := D; if not SameBits32(R[9], B32(S)) then Inc(Bad[9]);
      W := @R[10]; D := DA + DB; if not SameBits64(PUInt64(W)^, B64(D)) then Inc(Bad[10]);
      W := @R[12]; D := DA * DB; if not SameBits64(PUInt64(W)^, B64(D)) then Inc(Bad[12]);
      W := @R[14]; D := DA / DB; if not SameBits64(PUInt64(W)^, B64(D)) then Inc(Bad[14]);
      W := @R[16]; D := DFA * DFB; if not SameBits64(PUInt64(W)^, B64(D)) then Inc(Bad[16]);
      S := DA; if not SameBits32(R[18], B32(S)) then Inc(Bad[18]);
      W := @R[19]; D := Int64(DBb); if not SameBits64(PUInt64(W)^, B64(D)) then Inc(Bad[19]);
      W := @R[21]; if not SameBits64(PUInt64(W)^, B64(RoundEven64(DA))) then Inc(Bad[21]);
      T := 0;
      if Abs(DA) < 2147483648.0 then
        T := Cardinal(Trunc(DA));
      if R[23] <> T then Inc(Bad[23]);
    end;
    Report('float32 add, sub, mul', Bad[0] + Bad[1] + Bad[2] + Bad[8], N * 4);
    Report('float32 conversions, roundEven, floor', Bad[4] + Bad[5] + Bad[6] + Bad[7] + Bad[9], N * 5);
    Report('float64 add, mul', Bad[10] + Bad[12] + Bad[16], N * 3);
    Report('float64 conversions, roundEven', Bad[18] + Bad[19] + Bad[21] + Bad[23], N * 4);
    Writeln(Format('  info  float32 division differs in %d of %d, float64 division in %d of %d', [Bad[3], N, Bad[14], N]));
  finally
    K.Free;
    Dst.Free;
    Src.Free;
  end;
end;

type
  TToyTriangle = record
    X0, Y0, X1, Y1, X2, Y2: Integer;
    C0, C1, C2: Cardinal;
    Z: Cardinal;
    Mode: Integer;
    Pad: Integer;
  end;

const
  FBWidth = 512;
  FBHeight = 272;

function TopLeft(DX, DY: Int64): Boolean; inline;
begin
  Result := (DY < 0) or ((DY = 0) and (DX > 0));
end;

procedure ToyDraw(const T: TToyTriangle; var Color, Depth: array of Cardinal);
begin
  var X0: Int64 := T.X0; var Y0: Int64 := T.Y0;
  var X1: Int64 := T.X1; var Y1: Int64 := T.Y1;
  var X2: Int64 := T.X2; var Y2: Int64 := T.Y2;
  var C0 := T.C0; var C1 := T.C1; var C2 := T.C2;
  var Area := (X1 - X0) * (Y2 - Y0) - (Y1 - Y0) * (X2 - X0);
  if Area = 0 then
    Exit;
  if Area < 0 then
  begin
    var TX := X1; X1 := X2; X2 := TX;
    var TY := Y1; Y1 := Y2; Y2 := TY;
    var TC := C1; C1 := C2; C2 := TC;
    Area := -Area;
  end;
  var MinX := Min(X0, Min(X1, X2)); var MaxX := Max(X0, Max(X1, X2));
  var MinY := Min(Y0, Min(Y1, Y2)); var MaxY := Max(Y0, Max(Y1, Y2));
  var PX1 := Max(0, Integer((MinX - 8 + 15 + $1000000) div 16) - $100000);
  var PX2 := Min(FBWidth - 1, Integer((MaxX - 8 + $1000000) div 16) - $100000);
  var PY1 := Max(0, Integer((MinY - 8 + 15 + $1000000) div 16) - $100000);
  var PY2 := Min(FBHeight - 1, Integer((MaxY - 8 + $1000000) div 16) - $100000);
  var DX0 := X2 - X1; var DY0 := Y2 - Y1;
  var DX1 := X0 - X2; var DY1 := Y0 - Y2;
  var DX2 := X1 - X0; var DY2 := Y1 - Y0;
  var B0: Int64 := 0; var B1: Int64 := 0; var B2: Int64 := 0;
  if not TopLeft(DX0, DY0) then B0 := -1;
  if not TopLeft(DX1, DY1) then B1 := -1;
  if not TopLeft(DX2, DY2) then B2 := -1;
  for var PY := PY1 to PY2 do
    for var PX := PX1 to PX2 do
    begin
      var SX := Int64(PX) * 16 + 8;
      var SY := Int64(PY) * 16 + 8;
      var E0 := -((SX - X1) * DY0 - (SY - Y1) * DX0);
      var E1 := -((SX - X2) * DY1 - (SY - Y2) * DX1);
      var E2 := -((SX - X0) * DY2 - (SY - Y0) * DX2);
      if (E0 + B0 < 0) or (E1 + B1 < 0) or (E2 + B2 < 0) then
        Continue;
      var Index := PY * FBWidth + PX;
      var C := Color[Index];
      if T.Mode = 0 then
      begin
        if T.Z > Depth[Index] then
          Continue;
        Depth[Index] := T.Z;
        var A := Int64(C0 shr 24);
        var R: Cardinal := 0;
        var S := 0;
        while S < 24 do
        begin
          var V := (Int64((C0 shr S) and 255) * E0 + Int64((C1 shr S) and 255) * E1 + Int64((C2 shr S) and 255) * E2) div Area;
          var Old := Int64((C shr S) and 255);
          R := R or (Cardinal((V * A + Old * (255 - A)) div 255) shl S);
          Inc(S, 8);
        end;
        Color[Index] := R or (C and $FF000000);
      end
      else
        Color[Index] := C + $01000000;
    end;
end;

procedure TestTriangles(C: TVulkanCompute; Cmd: TVulkanCommands);
var
  Tris: array of TToyTriangle;
  Color, Depth, RefColor, RefDepth: array of Cardinal;

  procedure Add(X0, Y0, X1, Y1, X2, Y2: Integer; Mode: Integer);
  begin
    var T := Default(TToyTriangle);
    T.X0 := X0; T.Y0 := Y0; T.X1 := X1; T.Y1 := Y1; T.X2 := X2; T.Y2 := Y2;
    T.C0 := Rand; T.C1 := Rand; T.C2 := Rand;
    T.Z := Rand and $FFFF;
    T.Mode := Mode;
    Tris := Tris + [T];
  end;

begin
  // Large overlapping triangles reaching past the edges, small ones, degenerate ones.
  for var I := 1 to 300 do
    Add(RandRange(-1024, 9216), RandRange(-1024, 5376), RandRange(-1024, 9216), RandRange(-1024, 5376),
      RandRange(-1024, 9216), RandRange(-1024, 5376), 0);
  for var I := 1 to 1500 do
  begin
    var X := RandRange(0, FBWidth * 16); var Y := RandRange(0, FBHeight * 16);
    Add(X, Y, X + RandRange(-48, 48), Y + RandRange(-48, 48), X + RandRange(-48, 48), Y + RandRange(-48, 48), 0);
  end;
  for var I := 1 to 50 do
  begin
    var X := RandRange(0, FBWidth * 16); var Y := RandRange(0, FBHeight * 16);
    var DX := RandRange(-200, 200); var DY := RandRange(-200, 200);
    Add(X, Y, X + DX, Y + DY, X + 2 * DX, Y + 2 * DY, 0);
  end;
  // A mesh on pixel centres, edges and odd offsets, counting coverage: the
  // top-left rule must cover every pixel inside exactly once.
  // Unmoved columns lie on pixel centres (1000 + 400 k = 16 n + 8).
  var Grid: array[0..12, 0..9] of TPoint;
  for var GX := 0 to 12 do
    for var GY := 0 to 9 do
    begin
      var Jitter := Ord((GX + GY) mod 3 <> 0);
      Grid[GX, GY] := TPoint.Create(1000 + GX * 400 + RandRange(-80, 80) * Jitter * Ord((GX > 0) and (GX < 12)),
        800 + GY * 300 + RandRange(-60, 60) * Jitter * Ord((GY > 0) and (GY < 9)));
    end;
  // A horizontal edge along pixel centres.
  Grid[3, 3] := TPoint.Create(2200, 1704);
  Grid[4, 3] := TPoint.Create(2600, 1704);
  var MeshFirst := Length(Tris);
  for var GX := 0 to 11 do
    for var GY := 0 to 8 do
    begin
      var P00 := Grid[GX, GY]; var P10 := Grid[GX + 1, GY];
      var P01 := Grid[GX, GY + 1]; var P11 := Grid[GX + 1, GY + 1];
      if (GX + GY) and 1 = 0 then
      begin
        Add(P00.X, P00.Y, P10.X, P10.Y, P11.X, P11.Y, 1);
        Add(P00.X, P00.Y, P01.X, P01.Y, P11.X, P11.Y, 1);
      end
      else
      begin
        Add(P00.X, P00.Y, P10.X, P10.Y, P01.X, P01.Y, 1);
        Add(P10.X, P10.Y, P11.X, P11.Y, P01.X, P01.Y, 1);
      end;
    end;
  var MeshLast := High(Tris);

  var Pixels := FBWidth * FBHeight;
  SetLength(Color, Pixels);
  SetLength(Depth, Pixels);
  for var I := 0 to Pixels - 1 do
  begin
    Color[I] := Rand and $00FFFFFF;
    Depth[I] := $C000 + Rand mod $4000;
  end;
  RefColor := Copy(Color);
  RefDepth := Copy(Depth);

  var TriSize := Length(Tris) * SizeOf(TToyTriangle);
  var Upload := C.CreateBuffer(TriSize + Pixels * 8, vbkUpload);
  var TriBuf := C.CreateBuffer(TriSize, vbkDevice);
  var ColorBuf := C.CreateBuffer(Pixels * 4, vbkDevice);
  var DepthBuf := C.CreateBuffer(Pixels * 4, vbkDevice);
  var Back := C.CreateBuffer(Pixels * 8, vbkReadback);
  var K := C.CreateKernel(TestTrianglesSPV, 3, 12);
  try
    Upload.Write(0, Tris[0], TriSize);
    Upload.Write(TriSize, Color[0], Pixels * 4);
    Upload.Write(TriSize + Pixels * 4, Depth[0], Pixels * 4);
    K.Bind(0, TriBuf);
    K.Bind(1, ColorBuf);
    K.Bind(2, DepthBuf);
    var Push: array[0..2] of Cardinal;
    Push[0] := Length(Tris);
    Push[1] := FBWidth;
    Push[2] := FBHeight;
    Cmd.Start;
    Cmd.Copy(Upload, TriBuf, 0, 0, TriSize);
    Cmd.Copy(Upload, ColorBuf, TriSize, 0, Pixels * 4);
    Cmd.Copy(Upload, DepthBuf, TriSize + Pixels * 4, 0, Pixels * 4);
    Cmd.FullBarrier;
    Cmd.Timestamp(0);
    Cmd.Dispatch(K, (FBWidth + 7) div 8, (FBHeight + 7) div 8, 1, Push, SizeOf(Push));
    Cmd.FullBarrier;
    Cmd.Timestamp(1);
    Cmd.Copy(ColorBuf, Back, 0, 0, Pixels * 4);
    Cmd.Copy(DepthBuf, Back, 0, Pixels * 4, Pixels * 4);
    Cmd.FullBarrier;
    var Watch := TStopwatch.StartNew;
    Cmd.Run;
    var Wall := Watch.Elapsed.TotalMilliseconds;
    Back.Read(0, Color[0], Pixels * 4);
    Back.Read(Pixels * 4, Depth[0], Pixels * 4);

    Watch := TStopwatch.StartNew;
    for var T in Tris do
      ToyDraw(T, RefColor, RefDepth);
    var CPU := Watch.Elapsed.TotalMilliseconds;

    var Bad := 0;
    var First := -1;
    for var I := 0 to Pixels - 1 do
      if (Color[I] <> RefColor[I]) or (Depth[I] <> RefDepth[I]) then
      begin
        if First < 0 then
          First := I;
        Inc(Bad);
      end;
    if First >= 0 then
      Writeln(Format('    first difference at (%d, %d): %.8x/%.4x, expected %.8x/%.4x', [First mod FBWidth, First div FBWidth,
        Color[First], Depth[First], RefColor[First], RefDepth[First]]));
    Report(Format('%d triangles into %dx%d', [Length(Tris), FBWidth, FBHeight]), Bad, Pixels);

    // Inside the mesh every pixel is covered exactly once (the count is in the top byte).
    var Twice := 0;
    var Inside := 0;
    for var PY := 0 to FBHeight - 1 do
      for var PX := 0 to FBWidth - 1 do
      begin
        var SX := PX * 16 + 8; var SY := PY * 16 + 8;
        if (SX > Grid[0, 0].X) and (SX < Grid[12, 0].X) and (SY > Grid[0, 0].Y) and (SY < Grid[0, 9].Y) then
        begin
          Inc(Inside);
          if (RefColor[PY * FBWidth + PX] shr 24) <> 1 then
            Inc(Twice);
        end;
      end;
    Report(Format('top-left rule over a %d-triangle mesh', [MeshLast - MeshFirst + 1]), Twice, Inside);
    Writeln(Format('  time  GPU %.3f ms (kernel %.3f ms), CPU reference %.1f ms', [Wall, Cmd.Elapsed(0, 1) / 1e6, CPU]));
  finally
    K.Free;
    Back.Free;
    DepthBuf.Free;
    ColorBuf.Free;
    TriBuf.Free;
    Upload.Free;
  end;
end;

begin
  SetExceptionMask(exAllArithmeticExceptions);
  FormatSettings := TFormatSettings.Invariant;
  try
    var DeviceName := '';
    var Validation := False;
    var I := 1;
    while I <= ParamCount do
    begin
      if ParamStr(I) = '-device' then
      begin
        Inc(I);
        DeviceName := ParamStr(I);
      end
      else if ParamStr(I) = '-validation' then
        Validation := True;
      Inc(I);
    end;
    var C: TVulkanCompute;
    var Error: string;
    if not TryCreateVulkanCompute(C, Error, DeviceName, Validation) then
    begin
      Writeln('No Vulkan compute device: ', Error);
      Halt(2);
    end;
    try
      var F := C.Features;
      Writeln(Format('%s, Vulkan %d.%d.%d, queue family %d%s', [C.Name, C.Properties.apiVersion shr 22,
        (C.Properties.apiVersion shr 12) and $3FF, C.Properties.apiVersion and $FFF, C.QueueFamily,
        IfThen(C.Validation, ', validation layer on', '')]));
      Writeln(Format('int64 %s, int16 %s, int8 %s, float64 %s, 8/16-bit storage %s/%s, timeline %s, denorm/RTE 32 %s/%s 64 %s/%s',
        [BoolToStr(F.Int64, True), BoolToStr(F.Int16, True), BoolToStr(F.Int8, True), BoolToStr(F.Float64, True),
        BoolToStr(F.Storage8, True), BoolToStr(F.Storage16, True), BoolToStr(F.Timeline, True),
        BoolToStr(F.DenormPreserve32, True), BoolToStr(F.RoundEven32, True), BoolToStr(F.DenormPreserve64, True),
        BoolToStr(F.RoundEven64, True)]));
      var Cmd := C.CreateCommands(4);
      try
        TestArith(C, Cmd);
        TestBuffers(C, Cmd);
        TestFloat(C, Cmd);
        TestTriangles(C, Cmd);
      finally
        Cmd.Free;
      end;
    finally
      C.Free;
    end;
    if Failures > 0 then
    begin
      Writeln(Failures, ' test(s) failed');
      ExitCode := 1;
    end
    else
      Writeln('all passed');
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 3;
    end;
  end;
end.
