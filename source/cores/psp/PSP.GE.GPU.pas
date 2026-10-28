unit PSP.GE.GPU;

// The GE's rasterizer and pixel pipeline on a Vulkan compute device, with the
// arithmetic of PSP.GE.Raster bit for bit (source/gpu/shaders/PSPGERaster.comp).
//
// Primitives are set up here exactly as PSP.GE.Raster sets them up and go
// with their packed raster state into a batch of passes: runs of primitives
// with one render target, split wherever a texture reads memory the pass
// draws. The VRAM pages a batch draws into or textures from are held
// (TPSPMemory.HoldVRAM), so the batch may grow while the CPU runs: the first
// access to a held page runs it (Sync) on the GPU's copy of VRAM and copies
// those pages back into guest memory. The GPU copy learns of every other
// write to VRAM by comparing guest VRAM page by page with what it last
// handed back; textures in main memory are copied when they are used. What
// the kernel cannot draw the same way (pixels sharing memory, a primitive
// texturing from the pixels it draws) is drawn by PSP.GE.Raster after a Sync.
//
// In check mode every batch, run whenever the GE stops, is also drawn by
// PSP.GE.Raster into guest memory, which keeps the CPU's result, and the two
// are compared.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Types, System.Math, System.Diagnostics, System.Generics.Collections, PSP.Types, PSP.Memory,
  PSP.GE.Texture, PSP.GE.Raster, PSP.GE.Backend, RM.Vulkan.Bindings, RM.Vulkan.Loader, RM.Vulkan.Compute;

const
  VRAMPageCount = PSPVRAMSize div PSPPageSize;

type
  TGEGPUStats = record
    Batches, Passes, Prims, Fallbacks, UploadedPages: Int64;
    // Waits for everything drawn: in all, for an access to held or watched
    // memory, before a primitive drawn on the CPU. Pages compared and read back.
    Syncs, AccessSyncs, FallbackSyncs, ComparedPages, ReadbackPages: Int64;
    Tiles, Binned: Int64;
    CheckedBatches, BadBatches, BadBytes: Int64;
    // Host seconds waiting for the GPU; GPU seconds uploading, drawing, copying back.
    WaitSeconds, UploadSeconds, DrawSeconds, ReadbackSeconds: Double;
  end;

  TGEGPUMessage = reference to procedure(const Text: string);

  TGEGPUSpan = record
    Lo, Len: Int64; // VRAM offset and length, may run past the end (wraps)
    // When Stride > 0, only Rows rows of Width bytes, Stride bytes apart, from
    // Lo (a render target's box, an unswizzled texture level).
    Stride, Width, Rows: Int64;
  end;

  TGEGPUPass = record
    First, Count: Integer;
    X1, Y1, X2, Y2: Integer;
    FBAddr, FBStride, FBFormat, ZAddr, ZStride: Cardinal;
    ZPermutation: Integer;
    UsesZ: Boolean;
    // Bytes the pass's whole box covers (depth in whole permutation blocks).
    FB, Z: TGEGPUSpan;
    Reads: TArray<TGEGPUSpan>;
    ReadCount: Integer;
  end;
  PGEGPUPass = ^TGEGPUPass;

  TGEGPUCheckPrim = record
    Kind: Integer;
    S: TGERaster;
    V: array[0..2] of TGEVertex;
    Clut: TBytes;
  end;

  // A submitted batch: its buffers, and the pages to copy back when it is done.
  TGEGPUSlot = record
    Cmd: TVulkanCommands;
    PrimBuf, StateBuf, DataBuf, BinBuf, Upload, Readback: TVulkanBuffer;
    Pages: array[0..VRAMPageCount - 1] of Boolean;
    PageCount: Integer;
    Busy: Boolean;
    Order: Int64;
  end;
  PGEGPUSlot = ^TGEGPUSlot;

  TGEGPUBackend = class(TGERasterBackend)
  private
    FMemory: TPSPMemory;
    FCompute: TVulkanCompute;
    FKernel: TVulkanKernel;
    FVRAM: TVulkanBuffer;
    FSlots: array[0..1] of TGEGPUSlot;
    FNextSlot: Integer;
    FSubmitted: Int64;
    // Until the next Sync (an epoch): pages held as render targets, pages the
    // GPU may have drawn and not given back yet, pages whose GPU copy has been
    // brought up to date (held or watched since), pages to upload with the
    // next submission, watched pages and 64 KB banks of VRAM.
    FHeld: array[0..VRAMPageCount - 1] of Boolean;
    FDrawn: array[0..VRAMPageCount - 1] of Boolean;
    FDrawnCount: Integer;
    FVerified: array[0..VRAMPageCount - 1] of Boolean;
    FVerifiedList: array[0..VRAMPageCount - 1] of Integer;
    FVerifiedCount: Integer;
    FUpload: array[0..VRAMPageCount - 1] of Boolean;
    FUploadCount: Integer;
    FWatched: array[0..VRAMPageCount - 1] of Boolean;
    FWatchedBanks: array[0..VRAMPageCount div 16 - 1] of Boolean;
    FBins: TArray<Cardinal>;
    FBinCount: Integer;
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
    FLastTranslation: Integer;
    FLastTex: TGEGPUSpan;
    FLastTexInVRAM: Boolean;
    FCheck: Boolean;
    FCheckPrims: TList<TGEGPUCheckPrim>;
    FStats: TGEGPUStats;
    FOnMessage: TGEGPUMessage;
    FWhy: string;
    FReasons: TDictionary<string, Integer>;
    FSnapshots: TDictionary<UInt64, Integer>;
    FLastClutData: Integer;
    FSyncing: Boolean;
    FReleasePrims: Integer;
    procedure Bind(Slot: Integer);
    // Sends the batch to the GPU; with ReadBack, also every page drawn since
    // the last read back, to be put into guest memory when it completes.
    procedure Submit(ReadBack: Boolean);
    procedure Complete(Slot: Integer);
    procedure Split(const Why: string);
    function BinPass(const P: TGEGPUPass; out TilesX, TilesY: Integer): Cardinal;
    procedure Verify(Page: Integer); inline;
    procedure VerifyPage(Page: Integer);
    procedure Hold(const Span: TGEGPUSpan);
    procedure WatchVRAM(const Span: TGEGPUSpan);
    procedure WatchRAM(Address, Size: Cardinal);
    procedure EndEpoch;
    function Pending: Boolean;
    procedure BeginPrim;
    procedure VRAMFault;
    procedure Grow(Slot: Integer; var Buffer: TVulkanBuffer; Bytes: Int64);
    function AddData(Bytes: Integer): Integer;
    function NewPrim: PCardinal;
    function PackState(const S: TGERaster; out Tex: TGEGPUSpan; out TexInVRAM, Ok: Boolean): Integer;
    function Place(const S: TGERaster; State: Integer; const Tex: TGEGPUSpan; TexInVRAM: Boolean;
      X1, Y1, X2, Y2: Integer): Boolean;
    procedure Record_(Kind: Integer; const S: TGERaster; const V0, V1, V2: TGEVertex);
    procedure Fallback;
    procedure CheckBatch(const Held: array of Boolean; Readback: TVulkanBuffer);
    procedure Message(const Text: string);
  public
    constructor Create(Memory: TPSPMemory; Compute: TVulkanCompute; Check: Boolean);
    destructor Destroy; override;
    procedure DrawTriangle(const S: TGERaster; const V0, V1, V2: TGEVertex); override;
    procedure DrawSprite(const S: TGERaster; const V0, V1: TGEVertex); override;
    procedure DrawLine(const S: TGERaster; const V0, V1: TGEVertex); override;
    procedure DrawPoint(const S: TGERaster; const V: TGEVertex); override;
    procedure Sync; override;
    procedure Release; override;
    // Why primitives were drawn on the CPU and why passes were split, with counts.
    function Report: string;
    // Where the batch buffers are.
    function Describe: string;
    property Compute: TVulkanCompute read FCompute;
    property Stats: TGEGPUStats read FStats;
    property OnMessage: TGEGPUMessage read FOnMessage write FOnMessage;
  end;

// A GPU backend, or False with the reason when there is no suitable device.
function CreateGEGPUBackend(Memory: TPSPMemory; Check: Boolean; out Backend: TGEGPUBackend; out Error: string;
  const DeviceName: string = ''): Boolean;

implementation

{$I ..\..\gpu\shaders\PSPGERaster.spv.inc}
{$I ..\..\gpu\shaders\PSPGESelfTest.spv.inc}

const
  PrimWords = 128;
  StateWords = 128;
  FragWords = 16;
  PageSize = 4096;
  VRAMPages = PSPVRAMSize div PageSize;
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
  // A batch this large starts drawing when the GE stops (PSP_GPU_RELEASE
  // for measurements).
  ReleasePrims = 256;

type
  TGEGPUPush = record
    Table, TilesX: Cardinal;
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
  var Src: TVulkanBuffer := nil;
  var Dst: TVulkanBuffer := nil;
  var K: TVulkanKernel := nil;
  var Cmd: TVulkanCommands := nil;
  var Mask := GetExceptionMask;
  SetExceptionMask(exAllArithmeticExceptions);
  try
    Src := Compute.CreateBuffer(N * 16, vbkUpload);
    Dst := Compute.CreateBuffer(N * Stride * 4, vbkReadback);
    K := Compute.CreateKernel(PSPGESelfTestSPV, 2, 4);
    Cmd := Compute.CreateCommands;
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
  Taken: Boolean;
begin
  Backend := nil;
  Taken := False;
  if Assigned(Memory.OnVRAMFault) then
  begin
    Error := 'This memory already has a VRAM device.';
    Exit(False);
  end;
  {$IFDEF CPUX86}
  Error := 'The Win32/x87 raster reference is not qualified for GPU rendering; use Win64.';
  Exit(False);
  {$ENDIF}
  if not TryCreateVulkanCompute(Compute, Error, DeviceName) then
    Exit(False);
  var F := Compute.Features;
  if not (F.Int64 and F.Int16 and F.Int8 and F.Float64 and F.Storage8 and F.Storage16 and F.DenormPreserve32 and
    F.DenormPreserve64 and F.RoundEven32 and F.RoundEven64 and F.SignedZeroInfNan32 and F.SignedZeroInfNan64) then
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
    Taken := True;
    Backend := TGEGPUBackend.Create(Memory, Compute, Check);
  except
    on E: Exception do
    begin
      Error := E.Message;
      if not Taken then
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
  Result.Stride := 0;
  Result.Width := 0;
  Result.Rows := 0;
end;

// Rows bytes of Width, Stride apart (Width <= Stride), from Lo.
function RowSpan(Lo, Stride, Width, Rows: Int64): TGEGPUSpan;
begin
  Result := Span(Lo, (Rows - 1) * Stride + Width);
  if (Width <= Stride) and (Rows > 1) and (Result.Len < PSPVRAMSize) then
  begin
    Result.Stride := Stride;
    Result.Width := Width;
    Result.Rows := Rows;
  end;
end;

function FloorDiv(A, B: Int64): Int64; inline;
begin
  Result := A div B;
  if (A mod B <> 0) and ((A < 0) <> (B < 0)) then
    Dec(Result);
end;

// Whether bytes [Lo, Hi) meet a row of R (R.Lo relative to them by Delta).
function MeetsRows(const R: TGEGPUSpan; Delta, Lo, Hi: Int64): Boolean;
begin
  // Rows J with Delta + J * Stride < Hi and Delta + J * Stride + Width > Lo.
  var First := Max(Int64(0), FloorDiv(Lo - Delta - R.Width, R.Stride) + 1);
  var Last := Min(R.Rows - 1, FloorDiv(Hi - Delta - 1, R.Stride));
  Result := First <= Last;
end;

function Overlap(const A, B: TGEGPUSpan): Boolean;
begin
  if (A.Len <= 0) or (B.Len <= 0) then
    Exit(False);
  for var Shift := -1 to 1 do
  begin
    var Lo := B.Lo + Shift * Int64(PSPVRAMSize);
    if (A.Lo < Lo + B.Len) and (Lo < A.Lo + A.Len) then
    begin
      // Rows: only the bytes in them count.
      if (A.Stride = 0) and (B.Stride = 0) then
        Exit(True);
      if B.Stride = 0 then
      begin
        if MeetsRows(A, A.Lo, Lo, Lo + B.Len) then
          Exit(True);
      end
      else if A.Stride = 0 then
      begin
        if MeetsRows(B, Lo, A.Lo, A.Lo + A.Len) then
          Exit(True);
      end
      else if A.Stride = B.Stride then
      begin
        // B's rows start R bytes into a row of A, from Q rows below its first.
        var D := Lo - A.Lo;
        var Q := FloorDiv(D, A.Stride);
        var R := D - Q * A.Stride;
        // Row offsets K = Q + J - I between B's row J and A's row I.
        var KMin := Q - (A.Rows - 1);
        var KMax := Q + (B.Rows - 1);
        if ((KMin <= 0) and (KMax >= 0) and (R < A.Width)) or
          ((KMin <= -1) and (KMax >= -1) and (R > A.Stride - B.Width)) then
          Exit(True);
      end
      else
      begin
        for var J := 0 to B.Rows - 1 do
          if MeetsRows(A, A.Lo, Lo + J * B.Stride, Lo + J * B.Stride + B.Width) then
            Exit(True);
      end;
    end;
  end;
  Result := False;
end;

// Whether every byte of R is one of Q's.
function Contains(const Q, R: TGEGPUSpan): Boolean;
begin
  if (R.Lo < Q.Lo) or (R.Lo + R.Len > Q.Lo + Q.Len) then
    Exit(False);
  if Q.Stride = 0 then
    Exit(True);
  var D := R.Lo - Q.Lo;
  var Row := D div Q.Stride;
  var Column := D mod Q.Stride;
  if R.Stride = 0 then
    Result := (Column + R.Len <= Q.Width) and (Row < Q.Rows)
  else
    Result := (R.Stride = Q.Stride) and (Column + R.Width <= Q.Width) and (Row + R.Rows <= Q.Rows);
end;

// Bytes of a render target a box of pixels covers (X2 < Stride).
function TargetSpan(Addr, Stride, Bpp: Cardinal; X1, Y1, X2, Y2: Integer): TGEGPUSpan;
begin
  var First := Int64(Y1) * Stride + X1;
  Result := RowSpan(Int64(Addr) + First * Bpp, Int64(Stride) * Bpp, Int64(X2 - X1 + 1) * Bpp, Y2 - Y1 + 1);
end;

// EDRAM permutations of a translation (PSPDepthOffset, the odd mirrors) move
// bytes only within aligned blocks: 2 KB untranslated, else 16 times the
// translation width (as PSP.GE.Workers takes them).
function PermutationBlock(Shift: Integer): Int64; inline;
begin
  if Shift = 0 then
    Result := $800
  else
    Result := Int64(1) shl Min(Shift + 4, 21);
end;

// The whole blocks a logical span's bytes lie in: where they can be physically.
function BlockSpan(const S: TGEGPUSpan; Block: Int64): TGEGPUSpan;
begin
  if S.Len <= 0 then
    Exit(S);
  var First := S.Lo and not (Block - 1);
  var Last := (S.Lo + S.Len + Block - 1) and not (Block - 1);
  Result := Span(First, Last - First);
end;

// The guest bytes the texture unit can read for the current level: Size from
// Addr, and when unswizzled, only the first Width bytes of each of Rows rows
// of Stride bytes (texel coordinates are wrapped or clamped into the level).
function TextureBytes(const T: TGETexture; out Addr, Size: Cardinal; out Stride, Width, Rows: Int64): Boolean;
begin
  var L := T.Levels[T.Level];
  Addr := L.Addr;
  Size := 0;
  Stride := 0;
  Width := 0;
  Rows := 0;
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
  begin
    Size := Cardinal((H - 1) * RowBytes + ByteX + Bytes);
    Stride := RowBytes;
    Width := ByteX + Bytes;
    Rows := H;
  end;
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
  FSnapshots := TDictionary<UInt64, Integer>.Create;
  SetLength(FShadow, PSPVRAMSize);
  FVRAM := Compute.CreateBuffer(PSPVRAMSize + 256, vbkDevice);
  FKernel := Compute.CreateKernel(PSPGERasterSPV, 8, SizeOf(TGEGPUPush), [], Length(FSlots));
  for var I := 0 to High(FSlots) do
  begin
    var S: PGEGPUSlot := @FSlots[I];
    S.Upload := Compute.CreateBuffer(PSPVRAMSize, vbkUpload);
    S.Readback := Compute.CreateBuffer(PSPVRAMSize, vbkReadback);
    S.PrimBuf := Compute.CreateBuffer(4096 * PrimWords * 4, vbkShared);
    S.StateBuf := Compute.CreateBuffer(1024 * StateWords * 4, vbkShared);
    S.DataBuf := Compute.CreateBuffer(4 shl 20, vbkShared);
    S.BinBuf := Compute.CreateBuffer(1 shl 20, vbkShared);
    S.Cmd := Compute.CreateCommands(4);
    S.Cmd.SpinMicroseconds := 20000;
    Bind(I);
  end;
  var Cmd := FSlots[0].Cmd;
  Cmd.Start;
  Cmd.Fill(FVRAM, 0, FVRAM.Size, 0);
  Cmd.FullBarrier;
  Cmd.Run;
  FLastState := -1;
  FLastClutData := -1;
  FReleasePrims := StrToIntDef(GetEnvironmentVariable('PSP_GPU_RELEASE'), ReleasePrims);
  FMemory.OnVRAMFault := VRAMFault;
end;

destructor TGEGPUBackend.Destroy;
begin
  try
    if (FMemory.HeldVRAMPages > 0) or (FMemory.WatchedPages > 0) or (FPrimCount > 0) or (FDrawnCount > 0) then
      Sync;
  finally
    FMemory.ReleaseVRAM;
    FMemory.ReleaseWatches;
    FMemory.OnVRAMFault := nil;
    for var I := 0 to High(FSlots) do
    begin
      var S: PGEGPUSlot := @FSlots[I];
      S.Cmd.Free;
      S.BinBuf.Free;
      S.DataBuf.Free;
      S.StateBuf.Free;
      S.PrimBuf.Free;
      S.Readback.Free;
      S.Upload.Free;
    end;
    FKernel.Free;
    FVRAM.Free;
    FSnapshots.Free;
    FReasons.Free;
    FCheckPrims.Free;
    FCompute.Free;
    inherited;
  end;
end;

procedure TGEGPUBackend.Message(const Text: string);
begin
  if Assigned(FOnMessage) then
    FOnMessage(Text);
end;

// The GPU's copy of a page is brought up to date once an epoch, when the batch
// first uses it: from then on the page is held or watched, so guest memory
// cannot change it before the batch is drawn. Pages are compared with what
// the GPU was last given or gave back.
procedure TGEGPUBackend.Verify(Page: Integer);
begin
  if not FVerified[Page] then
    VerifyPage(Page);
end;

procedure TGEGPUBackend.VerifyPage(Page: Integer);
begin
  FVerified[Page] := True;
  FVerifiedList[FVerifiedCount] := Page;
  Inc(FVerifiedCount);
  Inc(FStats.ComparedPages);
  var Guest := @FMemory.VRAM[Page * PageSize];
  if not CompareMem(Guest, @FShadow[Page * PageSize], PageSize) then
  begin
    Move(Guest^, FShadow[Page * PageSize], PageSize);
    FUpload[Page] := True;
    Inc(FUploadCount);
  end;
end;

// Render target pages: held, so that any access first gives them back.
procedure TGEGPUBackend.Hold(const Span: TGEGPUSpan);
begin
  if Span.Len <= 0 then
    Exit;
  var First := Span.Lo div PageSize;
  var Last := (Span.Lo + Span.Len - 1) div PageSize;
  for var Page := First to Last do
  begin
    var P := Integer(Page mod VRAMPages);
    if not FHeld[P] then
    begin
      Verify(P);
      FHeld[P] := True;
      FMemory.HoldVRAM(P);
    end;
    if not FDrawn[P] then
    begin
      FDrawn[P] := True;
      Inc(FDrawnCount);
    end;
  end;
end;

// Texture pages in VRAM: watched, so that a write first draws the batch. The
// odd mirrors permute bytes within 64 KB banks, so all of a bank's pages
// there are watched.
procedure TGEGPUBackend.WatchVRAM(const Span: TGEGPUSpan);
const
  Linear0 = PSPVRAMBase shr PSPPageShift;
  Linear2 = (PSPVRAMBase + 2 * PSPVRAMSize) shr PSPPageShift;
  Odd1 = (PSPVRAMBase + PSPVRAMSize) shr PSPPageShift;
  Odd3 = (PSPVRAMBase + 3 * PSPVRAMSize) shr PSPPageShift;
begin
  if Span.Len <= 0 then
    Exit;
  var First := Span.Lo div PageSize;
  var Last := (Span.Lo + Span.Len - 1) div PageSize;
  for var Page := First to Last do
  begin
    var P := Integer(Page mod VRAMPages);
    if FWatched[P] then
      Continue;
    FWatched[P] := True;
    Verify(P);
    FMemory.WatchPage(Linear0 + P);
    FMemory.WatchPage(Linear2 + P);
    var Bank := P shr 4;
    if not FWatchedBanks[Bank] then
    begin
      FWatchedBanks[Bank] := True;
      for var B := Bank * 16 to Bank * 16 + 15 do
      begin
        FMemory.WatchPage(Odd1 + B);
        FMemory.WatchPage(Odd3 + B);
      end;
    end;
  end;
end;

// Textures in main memory: the batch keeps a copy, valid while it is watched.
procedure TGEGPUBackend.WatchRAM(Address, Size: Cardinal);
begin
  var Lo := Address and $1FFFFFFF;
  var Hi := UInt64(Lo) + Max(Size, 1) - 1;
  if Hi >= $20000000 then
    Hi := $1FFFFFFF;
  for var Page := Integer(Lo shr PSPPageShift) to Integer(Hi shr PSPPageShift) do
    FMemory.WatchPage(Page);
end;

// Everything has been drawn and given back: guest memory is free again.
procedure TGEGPUBackend.EndEpoch;
begin
  FMemory.ReleaseVRAM;
  FMemory.ReleaseWatches;
  for var I := 0 to FVerifiedCount - 1 do
    FVerified[FVerifiedList[I]] := False;
  FVerifiedCount := 0;
  FillChar(FHeld, SizeOf(FHeld), 0);
  FillChar(FWatched, SizeOf(FWatched), 0);
  FillChar(FWatchedBanks, SizeOf(FWatchedBanks), 0);
end;

// Batches stay within reasonable buffer sizes.
procedure TGEGPUBackend.BeginPrim;
begin
  if (FPrimCount >= 65536) or (FDataSize >= 64 shl 20) then
    if FCheck then
      Sync
    else
      Submit(False);
end;

procedure TGEGPUBackend.VRAMFault;
begin
  Inc(FStats.AccessSyncs);
  Sync;
end;

procedure TGEGPUBackend.Split(const Why: string);
begin
  var N := 0;
  var Key := 'pass split: ' + Why;
  FReasons.TryGetValue(Key, N);
  FReasons.AddOrSetValue(Key, N + 1);
end;

function TGEGPUBackend.Describe: string;
begin
  if FSlots[0].PrimBuf.DeviceLocal then
    Result := 'batches in device memory'
  else
    Result := 'batches in host memory';
end;

function TGEGPUBackend.Report: string;
begin
  Result := '';
  for var Pair in FReasons do
    Result := Result + Format('%s: %d'#10, [Pair.Key, Pair.Value]);
end;

// The GE stops: the batch starts on the GPU while the CPU runs on, unless
// the GPU is still drawing the last one: then it grows, and the GPU gets
// fewer, larger passes the busier it is. Nothing is read back: the pages
// stay held or watched until an access or a CPU-drawn primitive needs them
// (Sync).
procedure TGEGPUBackend.Release;
begin
  if FCheck then
    Sync
  else if FPrimCount >= FReleasePrims then
  begin
    var Last: PGEGPUSlot := @FSlots[(FNextSlot + Length(FSlots) - 1) mod Length(FSlots)];
    if not Last.Busy or Last.Cmd.Done then
      Submit(False);
  end;
end;

procedure TGEGPUBackend.Bind(Slot: Integer);
begin
  var S: PGEGPUSlot := @FSlots[Slot];
  FKernel.Bind(Slot, 0, FVRAM);
  FKernel.Bind(Slot, 1, FVRAM);
  FKernel.Bind(Slot, 2, FVRAM);
  FKernel.Bind(Slot, 3, S.PrimBuf);
  FKernel.Bind(Slot, 4, S.StateBuf);
  FKernel.Bind(Slot, 5, S.DataBuf);
  FKernel.Bind(Slot, 6, S.DataBuf);
  FKernel.Bind(Slot, 7, S.BinBuf);
end;

// Sorts a pass's primitives into 16x16 tiles, keeping their order: a table of
// (first, count) per tile, then the lists. Returns the table's word offset.
function TGEGPUBackend.BinPass(const P: TGEGPUPass; out TilesX, TilesY: Integer): Cardinal;
begin
  var TX1 := P.X1 shr 4;
  var TY1 := P.Y1 shr 4;
  TilesX := (P.X2 shr 4) - TX1 + 1;
  TilesY := (P.Y2 shr 4) - TY1 + 1;
  var Tiles := TilesX * TilesY;
  var Total := 0;
  for var I := P.First to P.First + P.Count - 1 do
  begin
    var W := PCardinal(@FPrims[I * PrimWords]);
    Inc(Total, ((Integer(W[4]) shr 4) - (Integer(W[2]) shr 4) + 1) * ((Integer(W[5]) shr 4) - (Integer(W[3]) shr 4) + 1));
  end;
  Result := FBinCount;
  Inc(FStats.Tiles, Tiles);
  Inc(FStats.Binned, Total);
  var Need := FBinCount + Tiles * 2 + Total;
  if Need > Length(FBins) then
    SetLength(FBins, Max(Need, Length(FBins) * 2));
  var Table := PCardinal(@FBins[FBinCount]);
  FillChar(Table^, Tiles * 2 * 4, 0);
  for var I := P.First to P.First + P.Count - 1 do
  begin
    var W := PCardinal(@FPrims[I * PrimWords]);
    for var TY := (Integer(W[3]) shr 4) - TY1 to (Integer(W[5]) shr 4) - TY1 do
      for var TX := (Integer(W[2]) shr 4) - TX1 to (Integer(W[4]) shr 4) - TX1 do
        Inc(Table[(TY * TilesX + TX) * 2 + 1]);
  end;
  var Next := Cardinal(FBinCount + Tiles * 2);
  for var T := 0 to Tiles - 1 do
  begin
    Table[T * 2] := Next;
    Inc(Next, Table[T * 2 + 1]);
    Table[T * 2 + 1] := 0;
  end;
  for var I := P.First to P.First + P.Count - 1 do
  begin
    var W := PCardinal(@FPrims[I * PrimWords]);
    for var TY := (Integer(W[3]) shr 4) - TY1 to (Integer(W[5]) shr 4) - TY1 do
      for var TX := (Integer(W[2]) shr 4) - TX1 to (Integer(W[4]) shr 4) - TX1 do
      begin
        var T := (TY * TilesX + TX) * 2;
        FBins[Table[T] + Table[T + 1]] := Cardinal(I);
        Inc(Table[T + 1]);
      end;
  end;
  FBinCount := Need;
end;

// Only for an idle slot.
procedure TGEGPUBackend.Grow(Slot: Integer; var Buffer: TVulkanBuffer; Bytes: Int64);
begin
  if Bytes <= Int64(Buffer.Size) then
    Exit;
  var Size := Int64(Buffer.Size);
  while Size < Bytes do
    Size := Size * 2;
  Buffer.Free;
  Buffer := FCompute.CreateBuffer(Size, vbkShared);
  Bind(Slot);
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
  if S.Textured and S.Tex.NeedLod then
  begin
    Tex := Default(TGEGPUSpan);
    TexInVRAM := False;
    FWhy := 'LOD-dependent texture sampling';
    Ok := False;
    Exit(-1);
  end;
  var UsesClut := S.Textured and (S.Tex.Format >= 4) and (S.Tex.Format <= 7);
  // A texture's copy in the batch stays valid: its pages are watched.
  if (FLastState >= 0) and (FLastTranslation = FMemory.VRAMShift) and CompareMem(@S, @FLastRaster, SizeOf(TGERaster)) and
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
    var RowStride, RowWidth, Rows: Int64;
    if TextureBytes(S.Tex, Addr, Size, RowStride, RowWidth, Rows) and (Size > 0) then
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
        var FirstMirror := (Phys - PSPVRAMBase) div PSPVRAMSize;
        var LastMirror := (Phys + Size - 1 - PSPVRAMBase) div PSPVRAMSize;
        if (FirstMirror and 1 <> 0) or (FirstMirror <> LastMirror) then
        begin
          // The odd mirrors permute bytes within aligned blocks (as
          // TPSPMemory.VRAMOffset and PSPDepthOffset).
          var Block := PermutationBlock(FMemory.VRAMShift);
          Tex := BlockSpan(Tex, Block);
          var Alignment := 1;
          case S.Tex.Format of
            0, 1, 2, 6: Alignment := 2;
            3, 7, 8, 9, 10: Alignment := 4;
          end;
          // An unaligned native read can cross the mapped block's upper edge.
          if Addr and Cardinal(Alignment - 1) <> 0 then
          begin
            if Tex.Lo + Tex.Len + Block > PSPVRAMSize then
            begin
              FWhy := 'unaligned texture near the physical VRAM boundary';
              Ok := False;
              Exit(-1);
            end;
            Tex := Span(Tex.Lo, Tex.Len + Block);
          end;
        end
        else if RowStride > 0 then
          Tex := RowSpan(Addr, RowStride, RowWidth, Rows);
      end
      else
      begin
        if TouchesVRAM(Addr, Size) then
          Sync;
        Source := 1;
        Base := Addr;
        // The batch's copy of the same bytes: they are watched since.
        var Key := UInt64(Addr) or (UInt64(Size) shl 32);
        var Old: Integer;
        if FSnapshots.TryGetValue(Key, Old) then
          DataOfs := Old
        else
        begin
          DataOfs := AddData(Size);
          WatchRAM(Addr, Size);
          FMemory.ReadBytes(Addr, FData[DataOfs], Size);
          FSnapshots.AddOrSetValue(Key, DataOfs);
        end;
      end;
    end;
    if UsesClut then
    begin
      if (FLastClutData >= 0) and CompareMem(@FData[FLastClutData], S.Tex.Clut, 1024) then
        ClutOfs := FLastClutData
      else
      begin
        ClutOfs := AddData(1024);
        Move(S.Tex.Clut^, FData[ClutOfs], 1024);
        FLastClutData := ClutOfs;
      end;
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
  if S.DepthClamp then Flags := Flags or (1 shl 19);
  W[104] := S.KeepMask;
  W[105] := Cardinal(S.ZPermutation);
  W[106] := Cardinal(FMemory.VRAMShift);
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
  FLastTranslation := FMemory.VRAMShift;
  FLastTex := Tex;
  FLastTexInVRAM := TexInVRAM;
end;

// Whether a pass already reads (and keeps apart from what it draws) a span.
function Covered(const P: TGEGPUPass; const R: TGEGPUSpan): Boolean;
begin
  for var I := P.ReadCount - 1 downto 0 do
    if Contains(P.Reads[I], R) then
      Exit(True);
  Result := False;
end;

// Puts the next primitive (covering the box) into a pass. False when the
// kernel cannot draw it exactly as the CPU does.
function TGEGPUBackend.Place(const S: TGERaster; State: Integer; const Tex: TGEGPUSpan; TexInVRAM: Boolean;
  X1, Y1, X2, Y2: Integer): Boolean;
begin
  var UsesZ := (S.ClearMode and S.ClearDepth) or (not S.ClearMode and S.DepthTest);
  // Within the last pass's box, with its buffers and a texture it reads:
  // everything below has been checked and held for the whole box already.
  if FPassCount > 0 then
  begin
    var P: PGEGPUPass := @FPasses[FPassCount - 1];
    if (X1 >= P.X1) and (Y1 >= P.Y1) and (X2 <= P.X2) and (Y2 <= P.Y2) and (P.FBAddr = S.FBAddr) and
      (P.FBStride = S.FBStride) and (P.FBFormat = S.FBFormat) and
      (not UsesZ or (P.UsesZ and (P.ZAddr = S.ZAddr) and (P.ZStride = S.ZStride) and
        (P.ZPermutation = S.ZPermutation))) and
      (not TexInVRAM or Covered(P^, Tex)) then
    begin
      Inc(P.Count);
      Exit(True);
    end;
  end;

  var Bpp: Cardinal := 2;
  if S.FBFormat = 3 then
    Bpp := 4;
  // Distinct pixels must not share memory.
  if (X2 >= Integer(S.FBStride)) or ((Int64(Y2 - Y1) * S.FBStride + X2 - X1 + 1) * Bpp > PSPVRAMSize) then
  begin FWhy := 'pixels share colour memory'; Exit(False); end;
  var FB := TargetSpan(S.FBAddr, S.FBStride, Bpp, X1, Y1, X2, Y2);
  var Z := Default(TGEGPUSpan);
  if UsesZ then
  begin
    if (X2 >= Integer(S.ZStride)) or ((Int64(Y2 - Y1) * S.ZStride + X2 - X1 + 1) * 2 > PSPVRAMSize) then
    begin FWhy := 'pixels share depth memory'; Exit(False); end;
    Z := BlockSpan(TargetSpan(S.ZAddr, S.ZStride, 2, X1, Y1, X2, Y2), PermutationBlock(S.ZPermutation));
    if Overlap(FB, Z) then
    begin FWhy := 'colour and depth share memory'; Exit(False); end;
  end;
  // A texture read from the pixels being drawn depends on the drawing order.
  if TexInVRAM and (Overlap(Tex, FB) or Overlap(Tex, Z)) then
  begin FWhy := 'texture from the pixels drawn'; Exit(False); end;

  var NewPass := FPassCount = 0;
  var PFB := FB;
  var PZ := Z;
  if not NewPass then
  begin
    var P: PGEGPUPass := @FPasses[FPassCount - 1];
    // Primitives without depth go with any depth buffer.
    if (P.FBAddr <> S.FBAddr) or (P.FBStride <> S.FBStride) or (P.FBFormat <> S.FBFormat) or
      (UsesZ and P.UsesZ and ((P.ZAddr <> S.ZAddr) or (P.ZStride <> S.ZStride) or
        (P.ZPermutation <> S.ZPermutation))) then
    begin
      NewPass := True;
      Split('render target');
    end
    else
    begin
      var PassZ := P.UsesZ or UsesZ;
      var ZAddr := P.ZAddr;
      var ZStride := P.ZStride;
      var ZPermutation := P.ZPermutation;
      if not P.UsesZ then
      begin
        ZAddr := S.ZAddr;
        ZStride := S.ZStride;
        ZPermutation := S.ZPermutation;
      end;
      var UX1 := Min(P.X1, X1); var UY1 := Min(P.Y1, Y1);
      var UX2 := Max(P.X2, X2); var UY2 := Max(P.Y2, Y2);
      var Changed := (UX1 <> P.X1) or (UY1 <> P.Y1) or (UX2 <> P.X2) or (UY2 <> P.Y2) or (PassZ <> P.UsesZ);
      PFB := P.FB;
      PZ := P.Z;
      if Changed then
      begin
        PFB := TargetSpan(S.FBAddr, S.FBStride, Bpp, UX1, UY1, UX2, UY2);
        if PassZ then
          PZ := BlockSpan(TargetSpan(ZAddr, ZStride, 2, UX1, UY1, UX2, UY2), PermutationBlock(ZPermutation));
      end;
      if Changed and (((Int64(UY2 - UY1) * S.FBStride + UX2 - UX1 + 1) * Bpp > PSPVRAMSize) or
        (PassZ and ((UX2 >= Integer(ZStride)) or ((Int64(UY2 - UY1) * ZStride + UX2 - UX1 + 1) * 2 > PSPVRAMSize) or
        Overlap(PFB, PZ)))) then
      begin
        NewPass := True;
        Split('memory span');
      end
      else if TexInVRAM and (Overlap(Tex, PFB) or Overlap(Tex, PZ)) then
      begin
        NewPass := True;
        Split('texture reads the pass');
      end
      else if Changed then
        for var I := 0 to P.ReadCount - 1 do
          if Overlap(P.Reads[I], PFB) or Overlap(P.Reads[I], PZ) then
          begin
            NewPass := True;
            Split('pass reads the target');
            Break;
          end;
      if NewPass then
      begin
        PFB := FB;
        PZ := Z;
      end;
    end;
  end;
  if NewPass then
  begin
    if FPassCount = Length(FPasses) then
      SetLength(FPasses, Max(64, FPassCount * 2));
    var P: PGEGPUPass := @FPasses[FPassCount];
    Inc(FPassCount);
    var Reads := P.Reads;
    P^ := Default(TGEGPUPass);
    P.Reads := Reads;
    P.First := FPrimCount;
    P.X1 := X1; P.Y1 := Y1; P.X2 := X2; P.Y2 := Y2;
    P.FBAddr := S.FBAddr;
    P.FBStride := S.FBStride;
    P.FBFormat := S.FBFormat;
  end;
  var P: PGEGPUPass := @FPasses[FPassCount - 1];
  if UsesZ and not P.UsesZ then
  begin
    P.UsesZ := True;
    P.ZAddr := S.ZAddr;
    P.ZStride := S.ZStride;
    P.ZPermutation := S.ZPermutation;
  end;
  Inc(P.Count);
  P.X1 := Min(P.X1, X1); P.Y1 := Min(P.Y1, Y1);
  P.X2 := Max(P.X2, X2); P.Y2 := Max(P.Y2, Y2);
  // The whole box's buffers are held, so primitives within it need nothing.
  if (PFB.Lo <> P.FB.Lo) or (PFB.Len <> P.FB.Len) then
  begin
    P.FB := PFB;
    Hold(PFB);
  end;
  if P.UsesZ and ((PZ.Lo <> P.Z.Lo) or (PZ.Len <> P.Z.Len)) then
  begin
    P.Z := PZ;
    Hold(PZ);
  end;
  if TexInVRAM and not Covered(P^, Tex) then
  begin
    if P.ReadCount = Length(P.Reads) then
      SetLength(P.Reads, Max(8, P.ReadCount * 2));
    P.Reads[P.ReadCount] := Tex;
    Inc(P.ReadCount);
    WatchVRAM(Tex);
  end;
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
  if Pending then
    Inc(FStats.FallbackSyncs);
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

procedure PutPlane(P: PCardinal; C0, C1, C2: Integer; DX0, DY0, DX1, DY1, DX2, DY2, Area: Int64; Anchor: Integer);
begin
  var NX := -(C0 * DY0 + C1 * DY1 + C2 * DY2) * 16;
  var NY := (C0 * DX0 + C1 * DX1 + C2 * DX2) * 16;
  var C := C0;
  if Anchor = 1 then C := C1;
  if Anchor = 2 then C := C2;
  PInt64(P)^ := Int64(C) shl 14;
  PInt64(P + 2)^ := (NX shl 14) div Area;
  PInt64(P + 4)^ := (NY shl 14) div Area;
end;

procedure TGEGPUBackend.DrawTriangle(const S: TGERaster; const V0, V1, V2: TGEVertex);
var
  Tex: TGEGPUSpan;
  InVRAM, Ok: Boolean;
begin
  BeginPrim;
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
  P[60] := PCardinal(@A0.Q)^;
  P[61] := PCardinal(@A1.Q)^;
  P[62] := PCardinal(@A2.Q)^;
  var AI := 0;
  var AX := X0; var AY := Y0;
  if (Y1 > AY) or ((Y1 = AY) and (X1 > AX)) then
  begin
    AI := 1; AX := X1; AY := Y1;
  end;
  if (Y2 > AY) or ((Y2 = AY) and (X2 > AX)) then
  begin
    AI := 2; AX := X2; AY := Y2;
  end;
  P[64] := Cardinal(AX);
  P[65] := Cardinal(AY);
  if S.Gouraud and not S.Flat then
  begin
    PutPlane(P + 66, A0.R, A1.R, A2.R, DX0, DY0, DX1, DY1, DX2, DY2, Area, AI);
    PutPlane(P + 72, A0.G, A1.G, A2.G, DX0, DY0, DX1, DY1, DX2, DY2, Area, AI);
    PutPlane(P + 78, A0.B, A1.B, A2.B, DX0, DY0, DX1, DY1, DX2, DY2, Area, AI);
    PutPlane(P + 84, A0.A, A1.A, A2.A, DX0, DY0, DX1, DY1, DX2, DY2, Area, AI);
  end;
  Record_(KindTriangle, S, V0, V1, V2);
end;

procedure TGEGPUBackend.DrawSprite(const S: TGERaster; const V0, V1: TGEVertex);
var
  Tex: TGEGPUSpan;
  InVRAM, Ok: Boolean;
begin
  BeginPrim;
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
  var Turned := (V0.X > V1.X) <> (V0.Y > V1.Y);
  var SX: Single := 0; var SY: Single := 0; var TX: Single := 0; var TY: Single := 0;
  var QX: Single := 0; var QY: Single := 0;
  if V1.X <> V0.X then
  begin
    if Turned then
      TX := (V1.T - V0.T) / ((V1.X - V0.X) / 16)
    else
    begin
      SX := (V1.S - V0.S) / ((V1.X - V0.X) / 16);
      QX := (V1.Q - V0.Q) / ((V1.X - V0.X) / 16);
    end;
  end;
  if V1.Y <> V0.Y then
  begin
    if Turned then
    begin
      SY := (V1.S - V0.S) / ((V1.Y - V0.Y) / 16);
      QY := (V1.Q - V0.Q) / ((V1.Y - V0.Y) / 16);
    end
    else
      TY := (V1.T - V0.T) / ((V1.Y - V0.Y) / 16);
  end;

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
  P[34] := PCardinal(@SX)^;
  P[35] := PCardinal(@SY)^;
  P[36] := PCardinal(@TX)^;
  P[37] := PCardinal(@TY)^;
  P[38] := PCardinal(@QX)^;
  P[39] := PCardinal(@QY)^;
  P[40] := PCardinal(@V0.Q)^;
  P[41] := Ord((V0.Q <> 1) or (V1.Q <> 1));
  Record_(KindSprite, S, V0, V1, V1);
end;

function RasterRound(X: Double): Integer; {$IF Defined(CPUX64) and Defined(MSWINDOWS)}assembler;{$ELSE}inline;{$ENDIF}
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
asm
  .NOFRAME
  CVTSD2SI EAX, XMM0
end;
{$ELSE}
begin
  Result := Round(X);
end;
{$ENDIF}

procedure TGEGPUBackend.DrawLine(const S: TGERaster; const V0, V1: TGEVertex);
var
  F: TGEGPUFragment;
  Frags: TArray<TGEGPUFragment>;
  Pos: TArray<TPoint>;
  Tex: TGEGPUSpan;
  InVRAM, Ok: Boolean;
begin
  BeginPrim;
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
      PY := (Y0 + RasterRound(DY * T) + $100000) div 16 - $10000;
    end
    else
    begin
      T := (C - Y0) / D;
      PY := P;
      PX := (X0 + RasterRound(DX * T) + $100000) div 16 - $10000;
    end;
    F.R := V1.R; F.G := V1.G; F.B := V1.B; F.A := V1.A;
    F.SR := V1.SR; F.SG := V1.SG; F.SB := V1.SB;
    F.Z := V1.Z;
    F.S := V1.S; F.T := V1.T;
    F.Fog := V1.Fog;
    if not S.Flat and S.Gouraud then
    begin
      F.R := RasterRound(V0.R + (V1.R - V0.R) * T);
      F.G := RasterRound(V0.G + (V1.G - V0.G) * T);
      F.B := RasterRound(V0.B + (V1.B - V0.B) * T);
      F.A := RasterRound(V0.A + (V1.A - V0.A) * T);
    end;
    F.Z := RasterRound(V0.Z + (V1.Z - V0.Z) * T);
    F.S := V0.S + (V1.S - V0.S) * T;
    F.T := V0.T + (V1.T - V0.T) * T;
    var Q := V0.Q + (V1.Q - V0.Q) * T;
    if (Q <> 1) and (Q <> 0) then
    begin
      F.S := F.S / Q;
      F.T := F.T / Q;
    end;
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
  BeginPrim;
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
  var FS: Single := V.S;
  var FT: Single := V.T;
  if (V.Q <> 1) and (V.Q <> 0) then
  begin
    FS := V.S / V.Q;
    FT := V.T / V.Q;
  end;
  Q[10] := PCardinal(@FS)^;
  Q[11] := PCardinal(@FT)^;
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

procedure TGEGPUBackend.Submit(ReadBack: Boolean);
var
  Push: TGEGPUPush;
begin
  ReadBack := ReadBack and (FDrawnCount > 0);
  if (FPrimCount = 0) and (FUploadCount = 0) and not ReadBack then
    Exit;
  var Index := FNextSlot;
  var Slot: PGEGPUSlot := @FSlots[Index];
  if Slot.Busy then
    Complete(Index);
  FNextSlot := (FNextSlot + 1) mod Length(FSlots);
  try
    var Tables: TArray<Cardinal>;
    var Grid: TArray<TPoint>;
    if FPrimCount > 0 then
    begin
      Inc(FStats.Batches);
      Inc(FStats.Passes, FPassCount);
      Inc(FStats.Prims, FPrimCount);
      FBinCount := 0;
      SetLength(Tables, FPassCount);
      SetLength(Grid, FPassCount);
      for var I := 0 to FPassCount - 1 do
        Tables[I] := BinPass(FPasses[I], Grid[I].X, Grid[I].Y);
      Grow(Index, Slot.PrimBuf, Int64(FPrimCount) * PrimWords * 4);
      Grow(Index, Slot.StateBuf, Int64(FStateCount) * StateWords * 4);
      Grow(Index, Slot.DataBuf, Max(FDataSize, 16));
      Grow(Index, Slot.BinBuf, Int64(FBinCount) * 4);
      Slot.PrimBuf.Write(0, FPrims[0], FPrimCount * PrimWords * 4);
      Slot.StateBuf.Write(0, FStates[0], FStateCount * StateWords * 4);
      if FDataSize > 0 then
        Slot.DataBuf.Write(0, FData[0], FDataSize);
      Slot.BinBuf.Write(0, FBins[0], FBinCount * 4);
    end;

    var Cmd := Slot.Cmd;
    var Upload := Slot.Upload.Data;
    Cmd.Start;
    Cmd.Timestamp(0);
    // Pages guest memory changed since the GPU last had them (VerifyPage put
    // them into the shadow).
    if FUploadCount > 0 then
    begin
      var Run := -1;
      for var Page := 0 to VRAMPages do
      begin
        if (Page < VRAMPages) and FUpload[Page] then
        begin
          FUpload[Page] := False;
          Move(FShadow[Page * PageSize], Upload[Page * PageSize], PageSize);
          Inc(FStats.UploadedPages);
          if Run < 0 then
            Run := Page;
        end
        else if Run >= 0 then
        begin
          Slot.Upload.Flush(Run * PageSize, (Page - Run) * PageSize);
          Cmd.Copy(Slot.Upload, FVRAM, Run * PageSize, Run * PageSize, (Page - Run) * PageSize);
          Run := -1;
        end;
      end;
      Cmd.Barrier(VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
        VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT or VK_PIPELINE_STAGE_TRANSFER_BIT,
        VK_ACCESS_SHADER_READ_BIT or VK_ACCESS_SHADER_WRITE_BIT or VK_ACCESS_TRANSFER_READ_BIT);
    end;
    Cmd.Timestamp(1);
    FKernel.ActiveSet := Index;
    for var I := 0 to FPassCount - 1 do
    begin
      var P: PGEGPUPass := @FPasses[I];
      Push.Table := Tables[I];
      Push.TilesX := Grid[I].X;
      Push.X1 := P.X1;
      Push.Y1 := P.Y1;
      Push.X2 := P.X2;
      Push.Y2 := P.Y2;
      Cmd.Dispatch(FKernel, Grid[I].X, Grid[I].Y, 1, Push, SizeOf(Push));
      Cmd.Barrier(VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_ACCESS_SHADER_WRITE_BIT,
        VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT or VK_PIPELINE_STAGE_TRANSFER_BIT,
        VK_ACCESS_SHADER_READ_BIT or VK_ACCESS_SHADER_WRITE_BIT or VK_ACCESS_TRANSFER_READ_BIT);
    end;
    Cmd.Timestamp(2);
    // Everything drawn since the last read back: only those pages can differ.
    Slot.PageCount := 0;
    if ReadBack then
    begin
      if FPassCount = 0 then
        Cmd.Barrier(VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT or VK_PIPELINE_STAGE_TRANSFER_BIT,
          VK_ACCESS_SHADER_WRITE_BIT or VK_ACCESS_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
          VK_ACCESS_TRANSFER_READ_BIT);
      Move(FDrawn, Slot.Pages, SizeOf(FDrawn));
      Slot.PageCount := FDrawnCount;
      Inc(FStats.ReadbackPages, FDrawnCount);
      FillChar(FDrawn, SizeOf(FDrawn), 0);
      FDrawnCount := 0;
      var Run := -1;
      for var Page := 0 to VRAMPages do
      begin
        if (Page < VRAMPages) and Slot.Pages[Page] then
        begin
          if Run < 0 then
            Run := Page;
        end
        else if Run >= 0 then
        begin
          Cmd.Copy(FVRAM, Slot.Readback, Run * PageSize, Run * PageSize, (Page - Run) * PageSize);
          Run := -1;
        end;
      end;
    end;
    // A later submission must not overwrite VRAM while this one reads it.
    Cmd.Barrier(VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_READ_BIT or VK_ACCESS_TRANSFER_WRITE_BIT,
      VK_PIPELINE_STAGE_HOST_BIT or VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT or VK_PIPELINE_STAGE_TRANSFER_BIT,
      VK_ACCESS_HOST_READ_BIT or VK_ACCESS_SHADER_WRITE_BIT or VK_ACCESS_TRANSFER_WRITE_BIT);
    Cmd.Timestamp(3);
    Cmd.Submit;
    Inc(FSubmitted);
    Slot.Order := FSubmitted;
    Slot.Busy := True;
  finally
    FPrimCount := 0;
    FPassCount := 0;
    FStateCount := 0;
    FDataSize := 0;
    FLastState := -1;
    FLastClutData := -1;
    FSnapshots.Clear;
    if FUploadCount > 0 then
    begin
      FillChar(FUpload, SizeOf(FUpload), 0);
      FUploadCount := 0;
    end;
    if not FCheck then
      FCheckPrims.Clear;
  end;
end;

// Waits for a slot's batch and puts the pages it read back into guest memory
// (which in check mode gets the CPU's drawing instead, compared with the GPU's).
procedure TGEGPUBackend.Complete(Slot: Integer);
begin
  var S: PGEGPUSlot := @FSlots[Slot];
  if not S.Busy then
    Exit;
  var Watch := TStopwatch.StartNew;
  S.Cmd.Wait;
  S.Busy := False;
  FStats.WaitSeconds := FStats.WaitSeconds + Watch.Elapsed.TotalSeconds;
  FStats.UploadSeconds := FStats.UploadSeconds + S.Cmd.Elapsed(0, 1) * 1e-9;
  FStats.DrawSeconds := FStats.DrawSeconds + S.Cmd.Elapsed(1, 2) * 1e-9;
  FStats.ReadbackSeconds := FStats.ReadbackSeconds + S.Cmd.Elapsed(2, 3) * 1e-9;
  if S.PageCount = 0 then
    Exit;
  S.Readback.Invalidate;
  var Back := S.Readback.Data;
  var VRAM: PByte := @FMemory.VRAM[0];
  if FCheck then
  begin
    FMemory.ReleaseVRAM;
    CheckBatch(S.Pages, S.Readback);
    FCheckPrims.Clear;
  end;
  for var Page := 0 to VRAMPages - 1 do
    if S.Pages[Page] then
    begin
      if not FCheck then
        Move(Back[Page * PageSize], VRAM[Page * PageSize], PageSize);
      Move(Back[Page * PageSize], FShadow[Page * PageSize], PageSize);
    end;
  S.PageCount := 0;
end;

function TGEGPUBackend.Pending: Boolean;
begin
  Result := (FPrimCount > 0) or (FDrawnCount > 0) or (FUploadCount > 0) or (FMemory.HeldVRAMPages > 0) or
    (FMemory.WatchedPages > 0);
  for var I := 0 to High(FSlots) do
    Result := Result or FSlots[I].Busy;
end;

procedure TGEGPUBackend.Sync;
begin
  if FSyncing then
    Exit;
  FSyncing := True;
  try
    if Pending then
      Inc(FStats.Syncs);
    Submit(True);
    // Oldest first.
    var First := FNextSlot;
    for var I := 0 to High(FSlots) do
      Complete((First + I) mod Length(FSlots));
    EndEpoch;
    FStateCount := 0;
    FDataSize := 0;
    FLastState := -1;
    FLastClutData := -1;
    FSnapshots.Clear;
  finally
    FSyncing := False;
  end;
end;

procedure TGEGPUBackend.CheckBatch(const Held: array of Boolean; Readback: TVulkanBuffer);
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
  var GPU := Readback.Data;
  var Bad := 0;
  var First := -1;
  for var Page := 0 to High(Held) do
    if Held[Page] then
      for var I := Page * PageSize to Page * PageSize + PageSize - 1 do
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
      Message(Format('gpu check: batch %d (%d prims) differs in %d bytes, first at VRAM %.6x: cpu %.8x gpu %.8x',
        [FStats.Batches, FCheckPrims.Count, Bad, First, PCardinal(CPU + A)^, PCardinal(GPU + A)^]));
    end;
  end;
end;

end.