unit PSP.GE.GPU;

// The GE's rasterizer and pixel pipeline on a Vulkan compute device, with the
// arithmetic of PSP.GE.Raster bit for bit (source/gpu/shaders/PSPGERaster.comp).
//
// Primitives are set up here exactly as PSP.GE.Raster sets them up and go
// with their packed raster state into a batch of passes: runs of primitives
// with one render target, split wherever a texture reads memory the pass
// draws. Sync runs the batch on the GPU's copy of VRAM and copies VRAM back
// into guest memory. The GPU copy learns of every other write to VRAM by
// comparing guest VRAM page by page with what it last handed back. What the
// kernel cannot draw the same way (pixels sharing memory, a primitive
// texturing from the pixels it draws) is drawn by PSP.GE.Raster after a Sync.
//
// In check mode every batch is also drawn by PSP.GE.Raster into guest memory,
// which keeps the CPU's result, and the two are compared.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Types, System.Math, System.Diagnostics, System.Generics.Collections, PSP.Types, PSP.Memory,
  PSP.GE.Texture, PSP.GE.Raster, PSP.GE.Backend, RM.Vulkan.Bindings, RM.Vulkan.Loader, RM.Vulkan.Compute;

type
  TGEGPUStats = record
    Batches, Passes, Prims, Fallbacks, UploadedPages: Int64;
    CheckedBatches, BadBatches, BadBytes: Int64;
    // Host seconds waiting for the GPU; GPU seconds uploading, drawing, copying back.
    WaitSeconds, UploadSeconds, DrawSeconds, ReadbackSeconds: Double;
  end;

  TGEGPUMessage = reference to procedure(const Text: string);

  TGEGPUSpan = record
    Lo, Len: Int64; // VRAM offset and length, may run past the end (wraps)
  end;

  TGEGPUPass = record
    First, Count: Integer;
    X1, Y1, X2, Y2: Integer;
    FBAddr, FBStride, FBFormat, ZAddr, ZStride: Cardinal;
    UsesZ: Boolean;
    Reads: TArray<TGEGPUSpan>;
  end;
  PGEGPUPass = ^TGEGPUPass;

  TGEGPUCheckPrim = record
    Kind: Integer;
    S: TGERaster;
    V: array[0..2] of TGEVertex;
    Clut: TBytes;
  end;

  TGEGPUBackend = class(TGERasterBackend)
  private
    FMemory: TPSPMemory;
    FCompute: TVulkanCompute;
    FKernel: TVulkanKernel;
    FCmd: TVulkanCommands;
    FVRAM, FPrimBuf, FStateBuf, FDataBuf, FUpload, FReadback: TVulkanBuffer;
    FShadow: TBytes;
    FPrims: TArray<Cardinal>;
    FPrimCount: Integer;
    FStates: TArray<Cardinal>;
    FStateCount: Integer;
    FData: TBytes;
    FDataSize: Integer;
    FPasses: TArray<TGEGPUPass>;
    FPassCount: Integer;
    FLastRaster: TGERaster;
    FLastClut: array[0..1023] of Byte;
    FLastState: Integer;
    FLastTex: TGEGPUSpan;
    FLastTexInVRAM: Boolean;
    FCheck: Boolean;
    FCheckPrims: TList<TGEGPUCheckPrim>;
    FStats: TGEGPUStats;
    FOnMessage: TGEGPUMessage;
    FWhy: string;
    FReasons: TDictionary<string, Integer>;
    procedure Bind;
    procedure Grow(var Buffer: TVulkanBuffer; Bytes: Int64);
    function AddData(Bytes: Integer): Integer;
    function NewPrim: PCardinal;
    function PackState(const S: TGERaster; out Tex: TGEGPUSpan; out TexInVRAM, Ok: Boolean): Integer;
    function Place(const S: TGERaster; State: Integer; const Tex: TGEGPUSpan; TexInVRAM: Boolean;
      X1, Y1, X2, Y2: Integer): Boolean;
    procedure Record_(Kind: Integer; const S: TGERaster; const V0, V1, V2: TGEVertex);
    procedure Fallback;
    procedure CheckBatch;
    procedure Message(const Text: string);
  public
    constructor Create(Memory: TPSPMemory; Compute: TVulkanCompute; Check: Boolean);
    destructor Destroy; override;
    procedure DrawTriangle(const S: TGERaster; const V0, V1, V2: TGEVertex); override;
    procedure DrawSprite(const S: TGERaster; const V0, V1: TGEVertex); override;
    procedure DrawLine(const S: TGERaster; const V0, V1: TGEVertex); override;
    procedure DrawPoint(const S: TGERaster; const V: TGEVertex); override;
    procedure Access(Address, Size: Cardinal; Write: Boolean); override;
    procedure Sync; override;
    property Compute: TVulkanCompute read FCompute;
    property Stats: TGEGPUStats read FStats;
    property OnMessage: TGEGPUMessage read FOnMessage write FOnMessage;
  end;

// A GPU backend, or False with the reason when there is no suitable device.
function CreateGEGPUBackend(Memory: TPSPMemory; Check: Boolean; out Backend: TGEGPUBackend; out Error: string;
  const DeviceName: string = ''): Boolean;

implementation

{$I PSPGERaster.spv.inc}
{$I PSPGESelfTest.spv.inc}

const
  PrimWords = 64;
  StateWords = 128;
  FragWords = 16;
  PageSize = 4096;
  VRAMMask = PSPVRAMSize - 1;

  KindTriangle = 0;
  KindSprite = 1;
  KindFragments = 2;
  KindLine = 3;
  KindPoint = 4;

  // State words, as source/gpu/shaders/PSPGEState.glsl reads them.
  ST_FLAGS = 11;
  ST_DITHER = 42;
  ST_TEXFORMAT = 58;
  ST_TEXSOURCE = 68;
  ST_LEVELS = 72;

type
  TGEGPUPush = record
    First, Count: Cardinal;
    X1, Y1, X2, Y2: Integer;
  end;

  TGEGPUFragment = record
    R, G, B, A: Integer;
    SR, SG, SB: Integer;
    Z: Integer;
    S, T: Single;
    Fog: Single;
  end;

function SameBits(A, B: UInt64; Double: Boolean): Boolean;
begin
  if A = B then
    Exit(True);
  // NaN payloads are not compared: the kernel only ever converts NaNs to integers.
  if Double then
    Result := ((A and $7FF0000000000000) = $7FF0000000000000) and ((A and $FFFFFFFFFFFFF) <> 0) and
      ((B and $7FF0000000000000) = $7FF0000000000000) and ((B and $FFFFFFFFFFFFF) <> 0)
  else
    Result := ((A and $7F800000) = $7F800000) and ((A and $7FFFFF) <> 0) and
      ((B and $7F800000) = $7F800000) and ((B and $7FFFFF) <> 0);
end;

// The device's float arithmetic against the CPU's on operands of all kinds.
function SelfTest(Compute: TVulkanCompute): string;
const
  N = 16384;
  Stride = 16;
  Special: array[0..15] of Cardinal = ($00000000, $80000000, $3F800000, $BF800000, $7F800000, $FF800000, $7FC00000,
    $00000001, $807FFFFF, $00800000, $7F7FFFFF, $3F000000, $4B000000, $CB7FFFFF, $3EFFFFFF, $00000002);
var
  Inputs: array of Cardinal;
  Seed: Cardinal;

  function Rand: Cardinal;
  begin
    Seed := Seed xor (Seed shl 13);
    Seed := Seed xor (Seed shr 17);
    Seed := Seed xor (Seed shl 5);
    Result := Seed;
  end;

  function Operand: Cardinal;
  begin
    case Rand mod 6 of
      0: Result := Special[Rand mod 16];
      1: Result := Rand and $807FFFFF;
      2: Result := (Rand and $80FFFFFF) or (Cardinal(110 + Rand mod 40) shl 23);
    else
      Result := Rand;
    end;
  end;

begin
  Result := '';
  Seed := $9E3779B9;
  SetLength(Inputs, N * 4);
  for var I := 0 to N - 1 do
  begin
    Inputs[I * 4] := Operand;
    Inputs[I * 4 + 1] := Operand;
    Inputs[I * 4 + 2] := Operand;
    Inputs[I * 4 + 3] := Operand;
    case Rand mod 4 of
      0: Inputs[I * 4 + 3] := (Inputs[I * 4 + 1] and $800FFFFF) or (Cardinal(1000 + Rand mod 47) shl 20);
      1: Inputs[I * 4 + 3] := Inputs[I * 4 + 1] and $800FFFFF;
    end;
  end;
  var Src := Compute.CreateBuffer(N * 16, vbkUpload);
  var Dst := Compute.CreateBuffer(N * Stride * 4, vbkReadback);
  var K := Compute.CreateKernel(PSPGESelfTestSPV, 2, 4);
  var Cmd := Compute.CreateCommands;
  var Mask := GetExceptionMask;
  SetExceptionMask(exAllArithmeticExceptions);
  try
    Src.Write(0, Inputs[0], N * 16);
    K.Bind(0, Src);
    K.Bind(1, Dst);
    var Count: Cardinal := N;
    Cmd.Start;
    Cmd.Dispatch(K, N div 64, 1, 1, Count, 4);
    Cmd.FullBarrier;
    Cmd.Run;
    Dst.Invalidate;
    var Names: array[0..7] of string;
    Names[0] := 'single multiply'; Names[1] := 'double add'; Names[2] := 'double multiply';
    Names[3] := 'double conversion'; Names[4] := 'single conversion'; Names[5] := 'integer conversion';
    Names[6] := 'roundEven'; Names[7] := 'division';
    var Bad: array[0..7] of Integer;
    FillChar(Bad, SizeOf(Bad), 0);
    for var I := 0 to N - 1 do
    begin
      var R := PCardinal(Dst.Data + I * Stride * 4);
      var A := Inputs[I * 4];
      var B := Inputs[I * 4 + 1];
      var FA := PSingle(@A)^;
      var FB := PSingle(@B)^;
      var DAb := UInt64(A) or (UInt64(B) shl 32);
      var DBb := UInt64(Inputs[I * 4 + 2]) or (UInt64(Inputs[I * 4 + 3]) shl 32);
      var DA := PDouble(@DAb)^;
      var DB := PDouble(@DBb)^;
      var S: Single := FA * FB;
      if not SameBits(R[0], PCardinal(@S)^, False) then Inc(Bad[0]);
      var D: Double := DA + DB;
      if not SameBits(PUInt64(@R[1])^, PUInt64(@D)^, True) then Inc(Bad[1]);
      D := DA * DB;
      if not SameBits(PUInt64(@R[3])^, PUInt64(@D)^, True) then Inc(Bad[2]);
      var DFA: Double := FA;
      D := DFA * DB;
      if not SameBits(PUInt64(@R[5])^, PUInt64(@D)^, True) then Inc(Bad[3]);
      S := DA;
      if not SameBits(R[7], PCardinal(@S)^, False) then Inc(Bad[4]);
      D := Int64(DBb);
      if not SameBits(PUInt64(@R[8])^, PUInt64(@D)^, True) then Inc(Bad[5]);
      D := DA;
      if not (IsNan(DA) or IsInfinite(DA) or (Abs(DA) >= 4503599627370496.0)) then
      begin
        D := Round(DA);
        // roundEven keeps the sign of zero.
        if (D = 0) and (DAb shr 63 <> 0) then
          PUInt64(@D)^ := UInt64($8000000000000000);
      end;
      if not SameBits(PUInt64(@R[10])^, PUInt64(@D)^, True) then Inc(Bad[6]);
      D := DA / DB;
      if not SameBits(PUInt64(@R[12])^, PUInt64(@D)^, True) then Inc(Bad[7]);
      var T: Cardinal := 0;
      if Abs(DA) < 2147483648.0 then
        T := Cardinal(Trunc(DA));
      if R[14] <> T then Inc(Bad[5]);
    end;
    for var J := 0 to 7 do
      if Bad[J] > 0 then
        Result := Result + Format('%s differs from the CPU in %d of %d; ', [Names[J], Bad[J], N]);
  finally
    SetExceptionMask(Mask);
    Cmd.Free;
    K.Free;
    Dst.Free;
    Src.Free;
  end;
end;

function CreateGEGPUBackend(Memory: TPSPMemory; Check: Boolean; out Backend: TGEGPUBackend; out Error: string;
  const DeviceName: string): Boolean;
var
  Compute: TVulkanCompute;
begin
  Backend := nil;
  if not TryCreateVulkanCompute(Compute, Error, DeviceName) then
    Exit(False);
  var F := Compute.Features;
  if not (F.Int64 and F.Int16 and F.Int8 and F.Float64 and F.Storage8 and F.Storage16 and F.DenormPreserve32 and
    F.DenormPreserve64 and F.RoundEven32 and F.RoundEven64 and F.SignedZeroInfNan32) then
  begin
    Error := Compute.Name + ' lacks 64/16/8-bit integers, doubles, small storage or IEEE float controls.';
    Compute.Free;
    Exit(False);
  end;
  try
    Error := SelfTest(Compute);
    if Error <> '' then
    begin
      Error := Compute.Name + ': ' + Error;
      Compute.Free;
      Exit(False);
    end;
    Backend := TGEGPUBackend.Create(Memory, Compute, Check);
  except
    on E: Exception do
    begin
      Error := E.Message;
      Compute.Free;
      Exit(False);
    end;
  end;
  Result := True;
end;

{ Spans of VRAM }

function Span(Lo, Len: Int64): TGEGPUSpan; inline;
begin
  Result.Lo := Lo and VRAMMask;
  Result.Len := Min(Len, Int64(PSPVRAMSize));
end;

function Overlap(const A, B: TGEGPUSpan): Boolean;
begin
  if (A.Len <= 0) or (B.Len <= 0) then
    Exit(False);
  for var Shift := -1 to 1 do
  begin
    var Lo := B.Lo + Shift * Int64(PSPVRAMSize);
    if (A.Lo < Lo + B.Len) and (Lo < A.Lo + A.Len) then
      Exit(True);
  end;
  Result := False;
end;

// Bytes of a render target a box of pixels covers.
function TargetSpan(Addr, Stride, Bpp: Cardinal; X1, Y1, X2, Y2: Integer): TGEGPUSpan;
begin
  var First := Int64(Y1) * Stride + X1;
  var Last := Int64(Y2) * Stride + X2;
  Result := Span(Int64(Addr) + First * Bpp, (Last - First + 1) * Bpp);
end;

// The guest bytes the texture unit can read for the current level.
function TextureBytes(const T: TGETexture; out Addr, Size: Cardinal): Boolean;
begin
  var L := T.Levels[T.Level];
  Addr := L.Addr;
  Size := 0;
  var W := L.Width;
  var H := L.Height;
  var Bits := 0;
  case T.Format of
    0, 1, 2, 6: Bits := 16;
    3, 7: Bits := 32;
    4: Bits := 4;
    5: Bits := 8;
    8, 9, 10:
      begin
        var BlockBytes := 16;
        if T.Format = 8 then
          BlockBytes := 8;
        var BlocksPerRow := L.BufWidth div 4;
        Size := Cardinal(((((H - 1) shr 2) * BlocksPerRow + ((W - 1) shr 2)) + 1) * BlockBytes);
        Exit(True);
      end;
  else
    Exit(False);
  end;
  var RowBytes := (L.BufWidth * Bits) div 8;
  var ByteX := ((W - 1) * Bits) div 8;
  var Bytes := Max(1, Bits div 8);
  if T.Swizzle then
    Size := Cardinal(((((H - 1) shr 3) * (RowBytes shr 4) + (ByteX shr 4)) shl 7) + 7 * 16 + 15 + Bytes)
  else
    Size := Cardinal((H - 1) * RowBytes + ByteX + Bytes);
  Result := True;
end;

function TouchesVRAM(Address, Size: Cardinal): Boolean;
begin
  var Lo := Int64(Address and $1FFFFFFF);
  var Hi := Lo + Max(Int64(Size), 1);
  Result := ((Hi > PSPVRAMBase) and (Lo < PSPVRAMBase + 4 * PSPVRAMSize)) or
    ((Hi > $20000000) and (Hi - $20000000 > PSPVRAMBase));
end;

{ TGEGPUBackend }

constructor TGEGPUBackend.Create(Memory: TPSPMemory; Compute: TVulkanCompute; Check: Boolean);
begin
  inherited Create;
  FMemory := Memory;
  FCompute := Compute;
  FCheck := Check;
  FCheckPrims := TList<TGEGPUCheckPrim>.Create;
  FReasons := TDictionary<string, Integer>.Create;
  SetLength(FShadow, PSPVRAMSize);
  FVRAM := Compute.CreateBuffer(PSPVRAMSize + 256, vbkDevice);
  FUpload := Compute.CreateBuffer(PSPVRAMSize, vbkUpload);
  FReadback := Compute.CreateBuffer(PSPVRAMSize, vbkReadback);
  FPrimBuf := Compute.CreateBuffer(4096 * PrimWords * 4, vbkShared);
  FStateBuf := Compute.CreateBuffer(1024 * StateWords * 4, vbkShared);
  FDataBuf := Compute.CreateBuffer(4 shl 20, vbkShared);
  FKernel := Compute.CreateKernel(PSPGERasterSPV, 7, SizeOf(TGEGPUPush));
  FCmd := Compute.CreateCommands(4);
  FCmd.SpinMicroseconds := 20000;
  Bind;
  FCmd.Start;
  FCmd.Fill(FVRAM, 0, FVRAM.Size, 0);
  FCmd.FullBarrier;
  FCmd.Run;
  FLastState := -1;
end;

destructor TGEGPUBackend.Destroy;
begin
  FCmd.Free;
  FKernel.Free;
  FDataBuf.Free;
  FStateBuf.Free;
  FPrimBuf.Free;
  FReadback.Free;
  FUpload.Free;
  FVRAM.Free;
  FReasons.Free;
  FCheckPrims.Free;
  FCompute.Free;
  inherited;
end;

procedure TGEGPUBackend.Message(const Text: string);
begin
  if Assigned(FOnMessage) then
    FOnMessage(Text);
end;

procedure TGEGPUBackend.Bind;
begin
  FKernel.Bind(0, FVRAM);
  FKernel.Bind(1, FVRAM);
  FKernel.Bind(2, FVRAM);
  FKernel.Bind(3, FPrimBuf);
  FKernel.Bind(4, FStateBuf);
  FKernel.Bind(5, FDataBuf);
  FKernel.Bind(6, FDataBuf);
end;

procedure TGEGPUBackend.Grow(var Buffer: TVulkanBuffer; Bytes: Int64);
begin
  if Bytes <= Int64(Buffer.Size) then
    Exit;
  var Size := Int64(Buffer.Size);
  while Size < Bytes do
    Size := Size * 2;
  Buffer.Free;
  Buffer := FCompute.CreateBuffer(Size, vbkShared);
  Bind;
end;

function TGEGPUBackend.AddData(Bytes: Integer): Integer;
begin
  Result := (FDataSize + 15) and not 15;
  FDataSize := Result + Bytes;
  if FDataSize > Length(FData) then
    SetLength(FData, Max(FDataSize, Length(FData) * 2));
end;

function TGEGPUBackend.NewPrim: PCardinal;
begin
  if (FPrimCount + 1) * PrimWords > Length(FPrims) then
    SetLength(FPrims, Max(4096 * PrimWords, Length(FPrims) * 2));
  Result := @FPrims[FPrimCount * PrimWords];
  FillChar(Result^, PrimWords * 4, 0);
  Inc(FPrimCount);
end;

function TGEGPUBackend.PackState(const S: TGERaster; out Tex: TGEGPUSpan; out TexInVRAM, Ok: Boolean): Integer;
begin
  Ok := True;
  var UsesClut := S.Textured and (S.Tex.Format >= 4) and (S.Tex.Format <= 7);
  if (FLastState >= 0) and CompareMem(@S, @FLastRaster, SizeOf(TGERaster)) and
    (not UsesClut or CompareMem(S.Tex.Clut, @FLastClut[0], SizeOf(FLastClut))) then
  begin
    Tex := FLastTex;
    TexInVRAM := FLastTexInVRAM;
    Exit(FLastState);
  end;
  Tex := Default(TGEGPUSpan);
  TexInVRAM := False;
  var Source: Cardinal := 0;
  var Base: Cardinal := 0;
  var DataOfs: Cardinal := 0;
  var ClutOfs: Cardinal := 0;
  if S.Textured then
  begin
    var Addr, Size: Cardinal;
    if TextureBytes(S.Tex, Addr, Size) and (Size > 0) then
    begin
      if Size > $1000000 then
      begin
        FWhy := 'texture larger than 16 MB';
        Ok := False;
        Exit(-1);
      end;
      var Phys := Int64(Addr and $1FFFFFFF);
      if (Phys >= PSPVRAMBase) and (Phys + Size <= PSPVRAMBase + 4 * PSPVRAMSize) and (Int64(Addr) + Size <= $100000000) then
      begin
        TexInVRAM := True;
        Tex := Span(Addr, Size);
      end
      else
      begin
        if TouchesVRAM(Addr, Size) then
          Sync;
        Source := 1;
        Base := Addr;
        DataOfs := AddData(Size);
        FMemory.ReadBytes(Addr, FData[DataOfs], Size);
      end;
    end;
    if UsesClut then
    begin
      ClutOfs := AddData(1024);
      Move(S.Tex.Clut^, FData[ClutOfs], 1024);
    end;
  end;
  if (FStateCount + 1) * StateWords > Length(FStates) then
    SetLength(FStates, Max(1024 * StateWords, Length(FStates) * 2));
  Result := FStateCount;
  Inc(FStateCount);
  var W := PCardinal(@FStates[Result * StateWords]);
  FillChar(W^, StateWords * 4, 0);
  W[0] := S.FBAddr;
  W[1] := S.FBStride;
  W[2] := S.FBFormat;
  W[3] := S.ZAddr;
  W[4] := S.ZStride;
  W[5] := Cardinal(S.ScissorX1);
  W[6] := Cardinal(S.ScissorY1);
  W[7] := Cardinal(S.ScissorX2);
  W[8] := Cardinal(S.ScissorY2);
  W[9] := Cardinal(S.BandY1);
  W[10] := Cardinal(S.BandY2);
  var Flags: Cardinal := 0;
  if S.Through then Flags := Flags or (1 shl 0);
  if S.ClearMode then Flags := Flags or (1 shl 1);
  if S.ClearColor then Flags := Flags or (1 shl 2);
  if S.ClearStencil then Flags := Flags or (1 shl 3);
  if S.ClearDepth then Flags := Flags or (1 shl 4);
  if S.Flat then Flags := Flags or (1 shl 5);
  if S.Gouraud then Flags := Flags or (1 shl 6);
  if S.Textured then Flags := Flags or (1 shl 7);
  if S.TexAlpha then Flags := Flags or (1 shl 8);
  if S.ColorDouble then Flags := Flags or (1 shl 9);
  if S.FogEnabled then Flags := Flags or (1 shl 10);
  if S.ColorTest then Flags := Flags or (1 shl 11);
  if S.AlphaTest then Flags := Flags or (1 shl 12);
  if S.StencilTest then Flags := Flags or (1 shl 13);
  if S.DepthTest then Flags := Flags or (1 shl 14);
  if S.DepthWrite then Flags := Flags or (1 shl 15);
  if S.Blend then Flags := Flags or (1 shl 16);
  if S.Dither then Flags := Flags or (1 shl 17);
  if S.LogicOp then Flags := Flags or (1 shl 18);
  W[ST_FLAGS] := Flags;
  W[12] := Cardinal(S.TexFunc);
  W[13] := Cardinal(S.EnvR);
  W[14] := Cardinal(S.EnvG);
  W[15] := Cardinal(S.EnvB);
  W[16] := Cardinal(S.FogR);
  W[17] := Cardinal(S.FogG);
  W[18] := Cardinal(S.FogB);
  W[19] := Cardinal(S.ColorTestFunc);
  W[20] := S.ColorRef;
  W[21] := S.ColorMask;
  W[22] := Cardinal(S.AlphaFunc);
  W[23] := Cardinal(S.AlphaRef);
  W[24] := Cardinal(S.AlphaMask);
  W[25] := Cardinal(S.StencilFunc);
  W[26] := Cardinal(S.StencilRef);
  W[27] := Cardinal(S.StencilMask);
  W[28] := Cardinal(S.StencilFail);
  W[29] := Cardinal(S.StencilZFail);
  W[30] := Cardinal(S.StencilZPass);
  W[31] := Cardinal(S.DepthFunc);
  W[32] := Cardinal(S.MinZ);
  W[33] := Cardinal(S.MaxZ);
  W[34] := Cardinal(S.BlendOp);
  W[35] := Cardinal(S.BlendSrc);
  W[36] := Cardinal(S.BlendDst);
  W[37] := S.FixA;
  W[38] := S.FixB;
  W[39] := Cardinal(S.LogicFunc);
  W[40] := S.MaskRGB;
  W[41] := Cardinal(S.MaskA);
  for var I := 0 to 15 do
    W[ST_DITHER + I] := Cardinal(S.DitherMatrix[I]);
  if S.Textured then
  begin
    W[ST_TEXFORMAT] := Cardinal(S.Tex.Format);
    W[59] := Ord(S.Tex.Swizzle);
    W[60] := Cardinal(S.Tex.Level);
    W[61] := Ord(S.Tex.ClampU);
    W[62] := Ord(S.Tex.ClampV);
    W[63] := Ord(S.Tex.Linear);
    W[64] := Cardinal(S.Tex.ClutFormat);
    W[65] := Cardinal(S.Tex.ClutShift);
    W[66] := Cardinal(S.Tex.ClutMask);
    W[67] := Cardinal(S.Tex.ClutOffset);
    W[ST_TEXSOURCE] := Source;
    W[69] := Base;
    W[70] := DataOfs;
    W[71] := ClutOfs;
    for var L := 0 to 7 do
    begin
      W[ST_LEVELS + L * 4] := S.Tex.Levels[L].Addr;
      W[ST_LEVELS + L * 4 + 1] := Cardinal(S.Tex.Levels[L].Width);
      W[ST_LEVELS + L * 4 + 2] := Cardinal(S.Tex.Levels[L].Height);
      W[ST_LEVELS + L * 4 + 3] := Cardinal(S.Tex.Levels[L].BufWidth);
    end;
  end;
  FLastRaster := S;
  if UsesClut then
    Move(S.Tex.Clut^, FLastClut[0], SizeOf(FLastClut));
  FLastState := Result;
  FLastTex := Tex;
  FLastTexInVRAM := TexInVRAM;
end;

// Puts the next primitive (covering the box) into a pass. False when the
// kernel cannot draw it exactly as the CPU does.
function TGEGPUBackend.Place(const S: TGERaster; State: Integer; const Tex: TGEGPUSpan; TexInVRAM: Boolean;
  X1, Y1, X2, Y2: Integer): Boolean;
begin
  var Bpp: Cardinal := 2;
  if S.FBFormat = 3 then
    Bpp := 4;
  var UsesZ := (S.ClearMode and S.ClearDepth) or (not S.ClearMode and S.DepthTest);
  // Distinct pixels must not share memory.
  if (X2 >= Integer(S.FBStride)) or ((Int64(Y2 - Y1) * S.FBStride + X2 - X1 + 1) * Bpp > PSPVRAMSize) then
  begin FWhy := 'pixels share colour memory'; Exit(False); end;
  var FB := TargetSpan(S.FBAddr, S.FBStride, Bpp, X1, Y1, X2, Y2);
  var Z := Default(TGEGPUSpan);
  if UsesZ then
  begin
    if (X2 >= Integer(S.ZStride)) or ((Int64(Y2 - Y1) * S.ZStride + X2 - X1 + 1) * 2 > PSPVRAMSize) then
    begin FWhy := 'pixels share depth memory'; Exit(False); end;
    Z := TargetSpan(S.ZAddr, S.ZStride, 2, X1, Y1, X2, Y2);
    if Overlap(FB, Z) then
    begin FWhy := 'colour and depth share memory'; Exit(False); end;
  end;
  // A texture read from the pixels being drawn depends on the drawing order.
  if TexInVRAM and (Overlap(Tex, FB) or Overlap(Tex, Z)) then
  begin FWhy := 'texture from the pixels drawn'; Exit(False); end;

  var NewPass := FPassCount = 0;
  if not NewPass then
  begin
    var P: PGEGPUPass := @FPasses[FPassCount - 1];
    if (P.FBAddr <> S.FBAddr) or (P.FBStride <> S.FBStride) or (P.FBFormat <> S.FBFormat) or (P.UsesZ <> UsesZ) or
      (UsesZ and ((P.ZAddr <> S.ZAddr) or (P.ZStride <> S.ZStride))) then
      NewPass := True
    else
    begin
      var UX1 := Min(P.X1, X1); var UY1 := Min(P.Y1, Y1);
      var UX2 := Max(P.X2, X2); var UY2 := Max(P.Y2, Y2);
      var PFB := TargetSpan(S.FBAddr, S.FBStride, Bpp, UX1, UY1, UX2, UY2);
      var PZ := Default(TGEGPUSpan);
      if UsesZ then
        PZ := TargetSpan(S.ZAddr, S.ZStride, 2, UX1, UY1, UX2, UY2);
      if ((Int64(UY2 - UY1) * S.FBStride + UX2 - UX1 + 1) * Bpp > PSPVRAMSize) or
        (UsesZ and (((Int64(UY2 - UY1) * S.ZStride + UX2 - UX1 + 1) * 2 > PSPVRAMSize) or Overlap(PFB, PZ))) then
        NewPass := True
      else if TexInVRAM and (Overlap(Tex, PFB) or Overlap(Tex, PZ)) then
        NewPass := True
      else
        for var R in P.Reads do
          if Overlap(R, PFB) or Overlap(R, PZ) then
          begin
            NewPass := True;
            Break;
          end;
    end;
  end;
  if NewPass then
  begin
    if FPassCount = Length(FPasses) then
      SetLength(FPasses, Max(64, FPassCount * 2));
    var P: PGEGPUPass := @FPasses[FPassCount];
    Inc(FPassCount);
    P^ := Default(TGEGPUPass);
    P.First := FPrimCount;
    P.X1 := X1; P.Y1 := Y1; P.X2 := X2; P.Y2 := Y2;
    P.FBAddr := S.FBAddr;
    P.FBStride := S.FBStride;
    P.FBFormat := S.FBFormat;
    P.ZAddr := S.ZAddr;
    P.ZStride := S.ZStride;
    P.UsesZ := UsesZ;
  end;
  var P: PGEGPUPass := @FPasses[FPassCount - 1];
  Inc(P.Count);
  P.X1 := Min(P.X1, X1); P.Y1 := Min(P.Y1, Y1);
  P.X2 := Max(P.X2, X2); P.Y2 := Max(P.Y2, Y2);
  if TexInVRAM then
    P.Reads := P.Reads + [Tex];
  Result := True;
end;

procedure TGEGPUBackend.Record_(Kind: Integer; const S: TGERaster; const V0, V1, V2: TGEVertex);
begin
  if not FCheck then
    Exit;
  var C := Default(TGEGPUCheckPrim);
  C.Kind := Kind;
  C.S := S;
  C.V[0] := V0;
  C.V[1] := V1;
  C.V[2] := V2;
  if S.Textured and (S.Tex.Clut <> nil) then
  begin
    SetLength(C.Clut, 1024);
    Move(S.Tex.Clut^, C.Clut[0], 1024);
  end;
  FCheckPrims.Add(C);
end;

procedure TGEGPUBackend.Fallback;
begin
  Sync;
  Inc(FStats.Fallbacks);
  var N := 0;
  FReasons.TryGetValue(FWhy, N);
  FReasons.AddOrSetValue(FWhy, N + 1);
  if N = 0 then
    Message('gpu: drawn on the CPU: ' + FWhy);
end;

procedure PutVertex(P: PCardinal; const V: TGEVertex);
begin
  P[0] := Cardinal(V.X);
  P[1] := Cardinal(V.Y);
  P[2] := Cardinal(V.Z);
  P[3] := PCardinal(@V.W)^;
  P[4] := Cardinal(V.R);
  P[5] := Cardinal(V.G);
  P[6] := Cardinal(V.B);
  P[7] := Cardinal(V.A);
  P[8] := Cardinal(V.SR);
  P[9] := Cardinal(V.SG);
  P[10] := Cardinal(V.SB);
  P[11] := PCardinal(@V.S)^;
  P[12] := PCardinal(@V.T)^;
  P[13] := PCardinal(@V.Fog)^;
end;

procedure TGEGPUBackend.DrawTriangle(const S: TGERaster; const V0, V1, V2: TGEVertex);
var
  Tex: TGEGPUSpan;
  InVRAM, Ok: Boolean;
begin
  // The set-up of GEDrawTriangle.
  var X0 := Int64(V0.X); var Y0 := Int64(V0.Y);
  var X1 := Int64(V1.X); var Y1 := Int64(V1.Y);
  var X2 := Int64(V2.X); var Y2 := Int64(V2.Y);
  var Area := (X1 - X0) * (Y2 - Y0) - (Y1 - Y0) * (X2 - X0);
  if Area = 0 then
    Exit;
  var A0, A1, A2: PGEVertex;
  A0 := @V0; A1 := @V1; A2 := @V2;
  if Area < 0 then
  begin
    A1 := @V2; A2 := @V1;
    X1 := V2.X; Y1 := V2.Y; X2 := V1.X; Y2 := V1.Y;
    Area := -Area;
  end;
  var MinX := Min(X0, Min(X1, X2));
  var MaxX := Max(X0, Max(X1, X2));
  var MinY := Min(Y0, Min(Y1, Y2));
  var MaxY := Max(Y0, Max(Y1, Y2));
  var PX1 := Integer((MinX - 8 + 15 + $100000) div 16) - $10000;
  var PX2 := Integer((MaxX - 8 + $100000) div 16) - $10000;
  var PY1 := Integer((MinY - 8 + 15 + $100000) div 16) - $10000;
  var PY2 := Integer((MaxY - 8 + $100000) div 16) - $10000;
  PX1 := Max(PX1, S.ScissorX1);
  PY1 := Max(PY1, Max(S.ScissorY1, S.BandY1));
  PX2 := Min(PX2, S.ScissorX2);
  PY2 := Min(PY2, Min(S.ScissorY2, S.BandY2));
  if (PX1 > PX2) or (PY1 > PY2) then
    Exit;
  var DX0 := X2 - X1; var DY0 := Y2 - Y1;
  var DX1 := X0 - X2; var DY1 := Y0 - Y2;
  var DX2 := X1 - X0; var DY2 := Y1 - Y0;
  var Bias: Cardinal := 0;
  if not ((DY0 < 0) or ((DY0 = 0) and (DX0 > 0))) then Bias := Bias or 1;
  if not ((DY1 < 0) or ((DY1 = 0) and (DX1 > 0))) then Bias := Bias or 2;
  if not ((DY2 < 0) or ((DY2 = 0) and (DX2 > 0))) then Bias := Bias or 4;
  var FArea := 1.0 / Area;

  var State := PackState(S, Tex, InVRAM, Ok);
  if not Ok or not Place(S, State, Tex, InVRAM, PX1, PY1, PX2, PY2) then
  begin
    Fallback;
    GEDrawTriangle(S, V0, V1, V2);
    Exit;
  end;
  var P := NewPrim;
  P[0] := KindTriangle;
  P[1] := Cardinal(State);
  P[2] := Cardinal(PX1);
  P[3] := Cardinal(PY1);
  P[4] := Cardinal(PX2);
  P[5] := Cardinal(PY2);
  PutVertex(@P[6], A0^);
  PutVertex(@P[20], A1^);
  PutVertex(@P[34], A2^);
  P[48] := Cardinal(V2.R);
  P[49] := Cardinal(V2.G);
  P[50] := Cardinal(V2.B);
  P[51] := Cardinal(V2.A);
  P[52] := Cardinal(V2.SR);
  P[53] := Cardinal(V2.SG);
  P[54] := Cardinal(V2.SB);
  P[55] := Cardinal(UInt64(Area));
  P[56] := Cardinal(UInt64(Area) shr 32);
  P[57] := Cardinal(PUInt64(@FArea)^);
  P[58] := Cardinal(PUInt64(@FArea)^ shr 32);
  P[59] := Bias;
  Record_(KindTriangle, S, V0, V1, V2);
end;

procedure TGEGPUBackend.DrawSprite(const S: TGERaster; const V0, V1: TGEVertex);
var
  Tex: TGEGPUSpan;
  InVRAM, Ok: Boolean;
begin
  // The set-up of GEDrawSprite.
  var X1 := Min(V0.X, V1.X);
  var X2 := Max(V0.X, V1.X);
  var Y1 := Min(V0.Y, V1.Y);
  var Y2 := Max(V0.Y, V1.Y);
  var PX1 := (X1 - 8 + 15 + 65536) div 16 - 4096;
  var PX2 := (X2 - 8 + 15 + 65536) div 16 - 4096 - 1;
  var PY1 := (Y1 - 8 + 15 + 65536) div 16 - 4096;
  var PY2 := (Y2 - 8 + 15 + 65536) div 16 - 4096 - 1;
  PX1 := Max(PX1, S.ScissorX1);
  PY1 := Max(PY1, Max(S.ScissorY1, S.BandY1));
  PX2 := Min(PX2, S.ScissorX2);
  PY2 := Min(PY2, Min(S.ScissorY2, S.BandY2));
  if (PX1 > PX2) or (PY1 > PY2) then
    Exit;
  var DS: Single := 0; var DT: Single := 0;
  if V1.X <> V0.X then DS := (V1.S - V0.S) / ((V1.X - V0.X) / 16);
  if V1.Y <> V0.Y then DT := (V1.T - V0.T) / ((V1.Y - V0.Y) / 16);

  var State := PackState(S, Tex, InVRAM, Ok);
  if not Ok or not Place(S, State, Tex, InVRAM, PX1, PY1, PX2, PY2) then
  begin
    Fallback;
    GEDrawSprite(S, V0, V1);
    Exit;
  end;
  var P := NewPrim;
  P[0] := KindSprite;
  P[1] := Cardinal(State);
  P[2] := Cardinal(PX1);
  P[3] := Cardinal(PY1);
  P[4] := Cardinal(PX2);
  P[5] := Cardinal(PY2);
  PutVertex(@P[6], V0);
  PutVertex(@P[20], V1);
  P[34] := PCardinal(@DS)^;
  P[35] := PCardinal(@DT)^;
  Record_(KindSprite, S, V0, V1, V1);
end;

procedure TGEGPUBackend.DrawLine(const S: TGERaster; const V0, V1: TGEVertex);
var
  F: TGEGPUFragment;
  Frags: TArray<TGEGPUFragment>;
  Pos: TArray<TPoint>;
  Tex: TGEGPUSpan;
  InVRAM, Ok: Boolean;
begin
  // GEDrawLine, keeping the fragments.
  var X0 := V0.X; var Y0 := V0.Y;
  var DX := V1.X - X0; var DY := V1.Y - Y0;
  if (DX = 0) and (DY = 0) then
    Exit;
  var XMajor := Abs(DX) >= Abs(DY);
  var A0, A1, D: Integer;
  if XMajor then
  begin
    A0 := Min(V0.X, V1.X); A1 := Max(V0.X, V1.X); D := DX;
  end
  else
  begin
    A0 := Min(V0.Y, V1.Y); A1 := Max(V0.Y, V1.Y); D := DY;
  end;
  var P1 := (A0 - 8 + 15 + $100000) div 16 - $10000;
  var P2 := (A1 - 8 + 15 + $100000) div 16 - $10000 - 1;
  if P2 < P1 then
    Exit;
  SetLength(Frags, P2 - P1 + 1);
  SetLength(Pos, P2 - P1 + 1);
  var BX1 := MaxInt; var BY1 := MaxInt; var BX2 := -MaxInt; var BY2 := -MaxInt;
  for var P := P1 to P2 do
  begin
    var C := P * 16 + 8;
    var T: Single;
    var PX, PY: Integer;
    if XMajor then
    begin
      T := (C - X0) / D;
      PX := P;
      PY := (Y0 + Round(DY * T) + $100000) div 16 - $10000;
    end
    else
    begin
      T := (C - Y0) / D;
      PY := P;
      PX := (X0 + Round(DX * T) + $100000) div 16 - $10000;
    end;
    F.R := V1.R; F.G := V1.G; F.B := V1.B; F.A := V1.A;
    F.SR := V1.SR; F.SG := V1.SG; F.SB := V1.SB;
    F.Z := V1.Z;
    F.S := V1.S; F.T := V1.T;
    F.Fog := V1.Fog;
    if not S.Flat and S.Gouraud then
    begin
      F.R := Round(V0.R + (V1.R - V0.R) * T);
      F.G := Round(V0.G + (V1.G - V0.G) * T);
      F.B := Round(V0.B + (V1.B - V0.B) * T);
      F.A := Round(V0.A + (V1.A - V0.A) * T);
    end;
    F.Z := Round(V0.Z + (V1.Z - V0.Z) * T);
    F.S := V0.S + (V1.S - V0.S) * T;
    F.T := V0.T + (V1.T - V0.T) * T;
    F.Fog := V0.Fog + (V1.Fog - V0.Fog) * T;
    Frags[P - P1] := F;
    Pos[P - P1] := TPoint.Create(PX, PY);
    BX1 := Min(BX1, PX); BY1 := Min(BY1, PY);
    BX2 := Max(BX2, PX); BY2 := Max(BY2, PY);
  end;
  BX1 := Max(BX1, S.ScissorX1);
  BY1 := Max(BY1, Max(S.ScissorY1, S.BandY1));
  BX2 := Min(BX2, S.ScissorX2);
  BY2 := Min(BY2, Min(S.ScissorY2, S.BandY2));
  if (BX1 > BX2) or (BY1 > BY2) then
    Exit;
  var State := PackState(S, Tex, InVRAM, Ok);
  if not Ok or not Place(S, State, Tex, InVRAM, BX1, BY1, BX2, BY2) then
  begin
    Fallback;
    GEDrawLine(S, V0, V1);
    Exit;
  end;
  var Ofs := AddData(Length(Frags) * FragWords * 4);
  var W := PCardinal(@FData[Ofs]);
  FillChar(W^, Length(Frags) * FragWords * 4, 0);
  for var I := 0 to High(Frags) do
  begin
    var Q := W + I * FragWords;
    Q[0] := Cardinal(Pos[I].X);
    Q[1] := Cardinal(Pos[I].Y);
    Q[2] := Cardinal(Frags[I].R);
    Q[3] := Cardinal(Frags[I].G);
    Q[4] := Cardinal(Frags[I].B);
    Q[5] := Cardinal(Frags[I].A);
    Q[6] := Cardinal(Frags[I].SR);
    Q[7] := Cardinal(Frags[I].SG);
    Q[8] := Cardinal(Frags[I].SB);
    Q[9] := Cardinal(Frags[I].Z);
    Q[10] := PCardinal(@Frags[I].S)^;
    Q[11] := PCardinal(@Frags[I].T)^;
    Q[12] := PCardinal(@Frags[I].Fog)^;
  end;
  var P := NewPrim;
  P[0] := KindFragments;
  P[1] := Cardinal(State);
  P[2] := Cardinal(BX1);
  P[3] := Cardinal(BY1);
  P[4] := Cardinal(BX2);
  P[5] := Cardinal(BY2);
  P[6] := Cardinal(Length(Frags));
  P[7] := Cardinal(P1);
  P[8] := Ord(XMajor);
  P[9] := Cardinal(Ofs div 4);
  Record_(KindLine, S, V0, V1, V1);
end;

procedure TGEGPUBackend.DrawPoint(const S: TGERaster; const V: TGEVertex);
var
  Tex: TGEGPUSpan;
  InVRAM, Ok: Boolean;
begin
  var PX := (V.X + $100000) div 16 - $10000;
  var PY := (V.Y + $100000) div 16 - $10000;
  if (PX < S.ScissorX1) or (PX > S.ScissorX2) or (PY < S.ScissorY1) or (PY > S.ScissorY2) or (PY < S.BandY1) or
    (PY > S.BandY2) then
    Exit;
  var State := PackState(S, Tex, InVRAM, Ok);
  if not Ok or not Place(S, State, Tex, InVRAM, PX, PY, PX, PY) then
  begin
    Fallback;
    GEDrawPoint(S, V);
    Exit;
  end;
  var Ofs := AddData(FragWords * 4);
  var Q := PCardinal(@FData[Ofs]);
  FillChar(Q^, FragWords * 4, 0);
  Q[0] := Cardinal(PX);
  Q[1] := Cardinal(PY);
  Q[2] := Cardinal(V.R);
  Q[3] := Cardinal(V.G);
  Q[4] := Cardinal(V.B);
  Q[5] := Cardinal(V.A);
  Q[6] := Cardinal(V.SR);
  Q[7] := Cardinal(V.SG);
  Q[8] := Cardinal(V.SB);
  Q[9] := Cardinal(V.Z);
  Q[10] := PCardinal(@V.S)^;
  Q[11] := PCardinal(@V.T)^;
  Q[12] := PCardinal(@V.Fog)^;
  var P := NewPrim;
  P[0] := KindFragments;
  P[1] := Cardinal(State);
  P[2] := Cardinal(PX);
  P[3] := Cardinal(PY);
  P[4] := Cardinal(PX);
  P[5] := Cardinal(PY);
  P[6] := 1;
  P[7] := Cardinal(PX);
  P[8] := 1;
  P[9] := Cardinal(Ofs div 4);
  Record_(KindPoint, S, V, V, V);
end;

procedure TGEGPUBackend.Access(Address, Size: Cardinal; Write: Boolean);
begin
  if (FPrimCount > 0) and TouchesVRAM(Address, Size) then
    Sync;
end;

procedure TGEGPUBackend.Sync;
var
  Push: TGEGPUPush;
begin
  if FPrimCount = 0 then
  begin
    FPassCount := 0;
    FStateCount := 0;
    FDataSize := 0;
    FLastState := -1;
    Exit;
  end;
  Inc(FStats.Batches);
  Inc(FStats.Passes, FPassCount);
  Inc(FStats.Prims, FPrimCount);
  Grow(FPrimBuf, Int64(FPrimCount) * PrimWords * 4);
  Grow(FStateBuf, Int64(FStateCount) * StateWords * 4);
  Grow(FDataBuf, Max(FDataSize, 16));
  FPrimBuf.Write(0, FPrims[0], FPrimCount * PrimWords * 4);
  FStateBuf.Write(0, FStates[0], FStateCount * StateWords * 4);
  if FDataSize > 0 then
    FDataBuf.Write(0, FData[0], FDataSize);

  var VRAM: PByte := @FMemory.VRAM[0];
  var Upload := FUpload.Data;
  FCmd.Start;
  FCmd.Timestamp(0);
  var Run := -1;
  var Uploaded := False;
  for var Page := 0 to PSPVRAMSize div PageSize do
  begin
    var Dirty := (Page < PSPVRAMSize div PageSize) and
      not CompareMem(VRAM + Page * PageSize, @FShadow[Page * PageSize], PageSize);
    if Dirty then
    begin
      Move(VRAM[Page * PageSize], Upload[Page * PageSize], PageSize);
      Move(VRAM[Page * PageSize], FShadow[Page * PageSize], PageSize);
      Inc(FStats.UploadedPages);
      if Run < 0 then
        Run := Page;
    end
    else if Run >= 0 then
    begin
      FUpload.Flush(Run * PageSize, (Page - Run) * PageSize);
      FCmd.Copy(FUpload, FVRAM, Run * PageSize, Run * PageSize, (Page - Run) * PageSize);
      Uploaded := True;
      Run := -1;
    end;
  end;
  if Uploaded then
    FCmd.Barrier(VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
      VK_ACCESS_SHADER_READ_BIT or VK_ACCESS_SHADER_WRITE_BIT);
  FCmd.Timestamp(1);
  for var I := 0 to FPassCount - 1 do
  begin
    var P: PGEGPUPass := @FPasses[I];
    Push.First := P.First;
    Push.Count := P.Count;
    Push.X1 := P.X1;
    Push.Y1 := P.Y1;
    Push.X2 := P.X2;
    Push.Y2 := P.Y2;
    FCmd.Dispatch(FKernel, (P.X2 - P.X1 + 8) div 8, (P.Y2 - P.Y1 + 8) div 8, 1, Push, SizeOf(Push));
    FCmd.Barrier(VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_ACCESS_SHADER_WRITE_BIT,
      VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT or VK_PIPELINE_STAGE_TRANSFER_BIT,
      VK_ACCESS_SHADER_READ_BIT or VK_ACCESS_SHADER_WRITE_BIT or VK_ACCESS_TRANSFER_READ_BIT);
  end;
  FCmd.Timestamp(2);
  FCmd.Copy(FVRAM, FReadback, 0, 0, PSPVRAMSize);
  FCmd.Barrier(VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_HOST_BIT,
    VK_ACCESS_HOST_READ_BIT);
  FCmd.Timestamp(3);
  var Watch := TStopwatch.StartNew;
  FCmd.Run;
  FStats.WaitSeconds := FStats.WaitSeconds + Watch.Elapsed.TotalSeconds;
  FStats.UploadSeconds := FStats.UploadSeconds + FCmd.Elapsed(0, 1) * 1e-9;
  FStats.DrawSeconds := FStats.DrawSeconds + FCmd.Elapsed(1, 2) * 1e-9;
  FStats.ReadbackSeconds := FStats.ReadbackSeconds + FCmd.Elapsed(2, 3) * 1e-9;
  FReadback.Invalidate;
  if FCheck then
    CheckBatch
  else
    Move(FReadback.Data^, VRAM^, PSPVRAMSize);
  Move(FReadback.Data^, FShadow[0], PSPVRAMSize);

  FPrimCount := 0;
  FPassCount := 0;
  FStateCount := 0;
  FDataSize := 0;
  FLastState := -1;
  FCheckPrims.Clear;
end;

procedure TGEGPUBackend.CheckBatch;
begin
  Inc(FStats.CheckedBatches);
  for var I := 0 to FCheckPrims.Count - 1 do
  begin
    var C := FCheckPrims[I];
    if C.Clut <> nil then
      C.S.Tex.Clut := @C.Clut[0];
    case C.Kind of
      KindTriangle: GEDrawTriangle(C.S, C.V[0], C.V[1], C.V[2]);
      KindSprite: GEDrawSprite(C.S, C.V[0], C.V[1]);
      KindLine: GEDrawLine(C.S, C.V[0], C.V[1]);
      KindPoint: GEDrawPoint(C.S, C.V[0]);
    end;
  end;
  var CPU := PByte(@FMemory.VRAM[0]);
  var GPU := FReadback.Data;
  var Bad := 0;
  var First := -1;
  for var I := 0 to PSPVRAMSize - 1 do
    if CPU[I] <> GPU[I] then
    begin
      if First < 0 then
        First := I;
      Inc(Bad);
    end;
  if Bad > 0 then
  begin
    Inc(FStats.BadBatches);
    Inc(FStats.BadBytes, Bad);
    if FStats.BadBatches <= 20 then
    begin
      var A := First and not 3;
      Message(Format('gpu check: batch %d (%d prims, %d passes) differs in %d bytes, first at VRAM %.6x: cpu %.8x gpu %.8x',
        [FStats.Batches, FCheckPrims.Count, FPassCount, Bad, First, PCardinal(CPU + A)^, PCardinal(GPU + A)^]));
    end;
  end;
end;

end.
