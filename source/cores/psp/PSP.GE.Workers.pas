unit PSP.GE.Workers;

// A fixed pool for a single primitive's independent row bands. Dispatch is
// synchronous: all bands finish before the GE executes another command or
// gives control back to the CPU. No VRAM readers/writers need asynchronous
// fences, and GE order, including framebuffer textures, stays unchanged.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Math, PSP.Types, PSP.GE.Raster;

type
  TGEJob = record
    Raster: TGERaster;
    V: array[0..2] of TGEVertex;
    Sprite: Boolean;
    MXCSR: UInt32;
    FPUControl: Word;
  end;

  TGEWorker = class(TThread)
  private
    FStart, FDone: THandle;
    FError: Exception;
    FJob: TGEJob;
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
  end;

  TGEWorkers = class
  private
    FWorkers: array of TGEWorker;
    FThreads: Integer;
    procedure StartWorkers;
    procedure Draw(const S: TGERaster; const A, B, C: TGEVertex; Sprite: Boolean);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Triangle(const S: TGERaster; const A, B, C: TGEVertex);
    procedure Sprite(const S: TGERaster; const A, B: TGEVertex);
  end;

implementation

procedure RunJob(const J: TGEJob);
begin
  if J.Sprite then
    GEDrawSprite(J.Raster, J.V[0], J.V[1])
  else
    GEDrawTriangle(J.Raster, J.V[0], J.V[1], J.V[2]);
end;

constructor TGEWorker.Create;
begin
  inherited Create(False);
  FStart := CreateEvent(nil, False, False, nil);
  FDone := CreateEvent(nil, False, False, nil);
  if (FStart = 0) or (FDone = 0) then RaiseLastOSError;
end;

destructor TGEWorker.Destroy;
begin
  Terminate;
  if FStart <> 0 then SetEvent(FStart);
  WaitFor;
  if FStart <> 0 then CloseHandle(FStart);
  if FDone <> 0 then CloseHandle(FDone);
  FError.Free;
  inherited;
end;

procedure TGEWorker.Execute;
begin
  // Match the emulator thread's default IEEE rounding, denormals and masked
  // exceptions; its exact control word is also copied on every dispatch.
  while True do
  begin
    WaitForSingleObject(FStart, INFINITE);
    if Terminated then Exit;
    try
      Set8087CW(FJob.FPUControl);
      SetMXCSR(FJob.MXCSR);
      RunJob(FJob);
    except
      FError := Exception(AcquireExceptionObject);
    end;
    SetEvent(FDone);
  end;
end;

constructor TGEWorkers.Create;
begin
  inherited;
  FThreads := EnsureRange(StrToIntDef(GetEnvironmentVariable('PSP_GE_THREADS'), Min(6, TThread.ProcessorCount)), 1, 12);
end;

destructor TGEWorkers.Destroy;
begin
  for var W in FWorkers do W.Free;
  inherited;
end;

procedure TGEWorkers.StartWorkers;
begin
  if Length(FWorkers) <> 0 then Exit;
  SetLength(FWorkers, FThreads - 1);
  for var I := 0 to High(FWorkers) do FWorkers[I] := TGEWorker.Create;
end;

function Overlap(A, B, C, D: NativeUInt): Boolean; inline;
begin
  Result := (A < D) and (C < B);
end;

// Bands may not write the same physical storage (short strides, wraparound,
// overlapping depth and colour targets), or read storage another band may
// be writing. Such primitives retain the original single-thread order.
function Independent(const S: TGERaster; Y1, Y2: Integer): Boolean;
begin
  var Bpp := 2;
  if S.FBFormat = 3 then Bpp := 4;
  if (S.FBStride <= Cardinal(S.ScissorX2)) or (S.FBStride = 0) then Exit(False);
  var Base := NativeUInt(S.VRAM);
  var C1 := Base + S.FBAddr + (NativeUInt(Y1) * S.FBStride + Cardinal(S.ScissorX1)) * Cardinal(Bpp);
  var C2 := Base + S.FBAddr + (NativeUInt(Y2) * S.FBStride + Cardinal(S.ScissorX2) + 1) * Cardinal(Bpp);
  if C2 > Base + PSPVRAMSize then Exit(False);
  var HasZ := S.DepthTest or (S.ClearMode and S.ClearDepth);
  var Z1, Z2: NativeUInt;
  Z1 := 0; Z2 := 0;
  if HasZ then
  begin
    if (S.ZStride <= Cardinal(S.ScissorX2)) or (S.ZStride = 0) then Exit(False);
    Z1 := Base + S.ZAddr + (NativeUInt(Y1) * S.ZStride + Cardinal(S.ScissorX1)) * 2;
    Z2 := Base + S.ZAddr + (NativeUInt(Y2) * S.ZStride + Cardinal(S.ScissorX2) + 1) * 2;
    if Z2 > Base + PSPVRAMSize then Exit(False);
    // Depth's bank permutation stays within a 64 KB block.
    Z1 := Base + ((Z1 - Base) and not NativeUInt($FFFF));
    Z2 := Base + (((Z2 - Base) + $FFFF) and not NativeUInt($FFFF));
    if Overlap(C1, C2, Z1, Z2) then Exit(False);
  end;
  if S.Textured then
    for var I := 0 to S.Tex.LevelCount - 1 do
    begin
      var L := S.Tex.Levels[I];
      if (L.Ptr = nil) or (L.Width > L.BufWidth) then Exit(False);
      if S.Tex.Swizzle and ((L.Height < 8) or (L.BufWidth and 31 <> 0)) then Exit(False);
      if (S.Tex.Format >= 8) and ((L.Height < 4) or (L.BufWidth < 4)) then Exit(False);
      var T1 := NativeUInt(L.Ptr);
      if Overlap(T1, T1 + L.Size, C1, C2) or (HasZ and Overlap(T1, T1 + L.Size, Z1, Z2)) then Exit(False);
      // Bytes fetched outside the contiguous level use the guest memory
      // reader: only RAM textures are safe without further address analysis.
      if Overlap(T1, T1 + L.Size, Base, Base + PSPVRAMSize) then Exit(False);
    end;
  Result := True;
end;

procedure TGEWorkers.Draw(const S: TGERaster; const A, B, C: TGEVertex; Sprite: Boolean);
var
  Job: TGEJob;
begin
  Job.Raster := S;
  Job.V[0] := A; Job.V[1] := B; Job.V[2] := C;
  Job.Sprite := Sprite;
  var X1 := Min(A.X, B.X); var X2 := Max(A.X, B.X);
  var Y1 := Min(A.Y, B.Y); var Y2 := Max(A.Y, B.Y);
  if not Sprite then
  begin
    X1 := Min(X1, C.X); X2 := Max(X2, C.X);
    Y1 := Min(Y1, C.Y); Y2 := Max(Y2, C.Y);
  end;
  X1 := Max(S.ScissorX1, X1 div 16 - 1);
  X2 := Min(S.ScissorX2, X2 div 16 + 1);
  Y1 := Max(Max(S.ScissorY1, S.BandY1), Y1 div 16 - 1);
  Y2 := Min(Min(S.ScissorY2, S.BandY2), Y2 div 16 + 1);
  var Rows := Y2 - Y1 + 1;
  if (FThreads = 1) or (Rows < 24) or (Int64(X2 - X1 + 1) * Rows < 16384) or not Independent(S, Y1, Y2) then
  begin
    RunJob(Job);
    Exit;
  end;
  StartWorkers;
  Job.MXCSR := GetMXCSR;
  Job.FPUControl := Get8087CW;
  var N := Min(FThreads, Rows div 12);
  for var I := 1 to N - 1 do
  begin
    Job.Raster.BandY1 := Y1 + Rows * I div N;
    Job.Raster.BandY2 := Y1 + Rows * (I + 1) div N - 1;
    FWorkers[I - 1].FJob := Job;
    SetEvent(FWorkers[I - 1].FStart);
  end;
  Job.Raster.BandY1 := Y1;
  Job.Raster.BandY2 := Y1 + Rows div N - 1;
  try
    RunJob(Job);
  finally
    for var I := 0 to N - 2 do WaitForSingleObject(FWorkers[I].FDone, INFINITE);
  end;
  for var I := 0 to N - 2 do
    if FWorkers[I].FError <> nil then
    begin
      var E := FWorkers[I].FError;
      FWorkers[I].FError := nil;
      raise E;
    end;
end;

procedure TGEWorkers.Triangle(const S: TGERaster; const A, B, C: TGEVertex);
begin
  Draw(S, A, B, C, False);
end;

procedure TGEWorkers.Sprite(const S: TGERaster; const A, B: TGEVertex);
begin
  Draw(S, A, B, B, True);
end;

end.
