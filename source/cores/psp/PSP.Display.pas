unit PSP.Display;

// sceDisplay and sceCtrl. A field is 286 lines at 59.94 Hz; vblank covers the
// last 14. The framebuffer set with "next frame" latches at vblank start, and
// the controller is sampled there too.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}

interface

uses
  System.SysUtils, System.Generics.Collections, System.UITypes, Core.Emulation.Types,
  PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel, PSP.Scheduler;

type
  TPSPFrameBuffer = record
    Address, Width, Format: Cardinal;
  end;

  TPSPVBlankEvent = procedure of object;

  TPSPCtrlSample = record
    Time, Buttons: Cardinal;
    LX, LY: Byte;
  end;

  TPSPDisplay = class
  private
    FKernel: TPSPKernel;
    FHLE: TPSPHLE;
    FMemory: TPSPMemory;
    FScheduler: TPSPScheduler;
    FCurrent, FPending: TPSPFrameBuffer;
    FHasPending: Boolean;
    FFrameStart: Int64;
    FInVBlank: Boolean;
    FVCount: Cardinal;
    FWaiters: TList<TPSPThread>;
    FMode, FModeWidth, FModeHeight: Cardinal;
    FOnVBlank: TPSPVBlankEvent;
    FFrameDone: Boolean;
    // Controller
    FInput: Cardinal;
    FAnalogX, FAnalogY: Byte;
    FSamples: array[0..63] of TPSPCtrlSample;
    FSampleHead, FSampleCount: Integer;
    FSampleIndex: Int64;
    FSamplingMode, FSamplingCycle: Cardinal;
    FLatchMake, FLatchBreak, FLatchPress, FLatchRelease, FLastButtons: Cardinal;
    FCtrlWaiters: TList<TPSPThread>;
    FIdleReset, FIdleBack: Integer;
    procedure VBlankStart;
    procedure VBlankEnd;
    function VBlankRetry(T: TPSPThread): Boolean;
    procedure VBlankAbort(T: TPSPThread);
    procedure WaitVBlank(AllowCB, OnlyIfNotInVBlank: Boolean);
    procedure SampleController;
    function CtrlRetry(T: TPSPThread): Boolean;
    procedure CtrlAbort(T: TPSPThread);
    procedure ReadSamples(Address: Cardinal; Count: Integer; Negative: Boolean; FromIndex: Int64);
    procedure hSetMode;
    procedure hGetMode;
    procedure hSetFrameBuf;
    procedure hGetFrameBuf;
    procedure hWaitVblankStart;
    procedure hWaitVblankStartCB;
    procedure hWaitVblank;
    procedure hWaitVblankCB;
    procedure hGetVcount;
    procedure hIsVblank;
    procedure hGetCurrentHcount;
    procedure hGetAccumulatedHcount;
    procedure hGetFramePerSec;
    procedure hIsForeground;
    procedure hSetHoldMode;
    procedure hSetResumeMode;
    procedure hGetBrightness;
    procedure hCtrlSetSamplingCycle;
    procedure hCtrlGetSamplingCycle;
    procedure hCtrlSetSamplingMode;
    procedure hCtrlGetSamplingMode;
    procedure hCtrlPeekBufferPositive;
    procedure hCtrlPeekBufferNegative;
    procedure hCtrlReadBufferPositive;
    procedure hCtrlReadBufferNegative;
    procedure hCtrlPeekLatch;
    procedure hCtrlReadLatch;
    procedure hCtrlSetIdleCancelThreshold;
    procedure hCtrlGetIdleCancelThreshold;
    procedure hCtrlZero;
    procedure ReadBufferCommon(Negative: Boolean);
  public
    constructor Create(Kernel: TPSPKernel);
    destructor Destroy; override;
    procedure Reset;
    procedure Register;
    procedure OnEvent;
    procedure SetInput(const Input: TEmulatorInput);
    // Converts the shown framebuffer to ARGB pixels.
    procedure Render(var Frame: TEmulatorFrame);
    function LineNow: Int64;
    property Current: TPSPFrameBuffer read FCurrent;
    property VCount: Cardinal read FVCount;
    property OnVBlank: TPSPVBlankEvent read FOnVBlank write FOnVBlank;
    property FrameDone: Boolean read FFrameDone write FFrameDone;
    property InVBlank: Boolean read FInVBlank;
  end;

const
  PSPLineNs = PSPFrameNs div PSPLinesPerFrame;

implementation

uses
  System.Math;

const
  ButtonBits: array[TEmulatorButton] of Cardinal =
    ($10, $40, $80, $20, $4000, $2000, $1, $8, $100, $8000, $1000, $200, 0);

constructor TPSPDisplay.Create(Kernel: TPSPKernel);
begin
  inherited Create;
  FKernel := Kernel;
  FHLE := Kernel.HLE;
  FMemory := Kernel.Memory;
  FScheduler := Kernel.Scheduler;
  FWaiters := TList<TPSPThread>.Create;
  FCtrlWaiters := TList<TPSPThread>.Create;
end;

destructor TPSPDisplay.Destroy;
begin
  FWaiters.Free;
  FCtrlWaiters.Free;
  inherited;
end;

procedure TPSPDisplay.Reset;
begin
  FCurrent := Default(TPSPFrameBuffer);
  FPending := Default(TPSPFrameBuffer);
  FHasPending := False;
  FFrameStart := FScheduler.Now;
  FInVBlank := False;
  FVCount := 0;
  FWaiters.Clear;
  FCtrlWaiters.Clear;
  FMode := 0;
  FModeWidth := 480;
  FModeHeight := 272;
  FSampleHead := 0;
  FSampleCount := 0;
  FSampleIndex := 0;
  FSamplingMode := 0;
  FSamplingCycle := 0;
  FLatchMake := 0;
  FLatchBreak := 0;
  FLatchPress := 0;
  FLatchRelease := 0;
  FLastButtons := 0;
  FAnalogX := 128;
  FAnalogY := 128;
  FIdleReset := -1;
  FIdleBack := -1;
  FScheduler.Schedule(TPSPEvent.VBlank, FFrameStart + Int64(PSPLineNs) * PSPVisibleLines);
end;

function TPSPDisplay.LineNow: Int64;
begin
  Result := (FScheduler.Now - FFrameStart) div PSPLineNs;
end;

procedure TPSPDisplay.OnEvent;
begin
  if FInVBlank then
    VBlankEnd
  else
    VBlankStart;
end;

procedure TPSPDisplay.VBlankStart;
begin
  FInVBlank := True;
  Inc(FVCount);
  if FHasPending then
  begin
    FCurrent := FPending;
    FHasPending := False;
  end;
  SampleController;
  FFrameDone := True;
  FScheduler.Schedule(TPSPEvent.VBlank, FFrameStart + PSPFrameNs);
  while FWaiters.Count > 0 do
  begin
    var T := FWaiters[0];
    FWaiters.Delete(0);
    if T.IsWaiting and (T.Wait.HLETag = 'vblank') then
      FKernel.EndWait(T, 0);
  end;
  FKernel.TriggerInterrupt(PSPInterruptVBlank);
  if Assigned(FOnVBlank) then
    FOnVBlank();
end;

procedure TPSPDisplay.VBlankEnd;
begin
  FInVBlank := False;
  FFrameStart := FFrameStart + PSPFrameNs;
  FScheduler.Schedule(TPSPEvent.VBlank, FFrameStart + Int64(PSPLineNs) * PSPVisibleLines);
end;

function TPSPDisplay.VBlankRetry(T: TPSPThread): Boolean;
begin
  Result := FVCount <> T.Wait.Data[0];
  if Result then
    T.SetResult(0)
  else if not FWaiters.Contains(T) then
    FWaiters.Add(T);
end;

procedure TPSPDisplay.VBlankAbort(T: TPSPThread);
begin
  FWaiters.Remove(T);
end;

procedure TPSPDisplay.WaitVBlank(AllowCB, OnlyIfNotInVBlank: Boolean);
begin
  FHLE.Result(0);
  if OnlyIfNotInVBlank and FInVBlank then
  begin
    if AllowCB then
      FKernel.CheckCallbacks;
    Exit;
  end;
  if not FKernel.CanWait then
    begin FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT); Exit; end;
  FWaiters.Add(FKernel.Current);
  FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, AllowCB, VBlankRetry, VBlankAbort, 'vblank');
  var T := FKernel.Current;
  if (T <> nil) and (T.Wait.HLETag = 'vblank') then
    T.Wait.Data[0] := FVCount
  else if (T <> nil) and (T.Frames.Count > 0) then
  begin
    var F := T.Frames.Last;
    F.SavedWait.Data[0] := FVCount;
    T.Frames[T.Frames.Count - 1] := F;
  end;
end;

procedure TPSPDisplay.SetInput(const Input: TEmulatorInput);
begin
  var B: Cardinal := 0;
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
    if Button in Input.Buttons then
      B := B or ButtonBits[Button];
  FInput := B;
  var X := 128;
  var Y := 128;
  if Input.Analog[0].Valid then
  begin
    X := EnsureRange((Integer(Input.Analog[0].X) + 32768) div 256, 0, 255);
    Y := EnsureRange((Integer(Input.Analog[0].Y) + 32768) div 256, 0, 255);
  end;
  FAnalogX := X;
  FAnalogY := Y;
end;

procedure TPSPDisplay.SampleController;
begin
  var S := Default(TPSPCtrlSample);
  S.Time := Cardinal(FScheduler.Now div 1000);
  S.Buttons := FInput;
  if FSamplingMode <> 0 then
  begin
    S.LX := FAnalogX;
    S.LY := FAnalogY;
  end
  else
  begin
    S.LX := 128;
    S.LY := 128;
  end;
  var Changed := FInput xor FLastButtons;
  FLatchMake := FLatchMake or (Changed and FInput);
  FLatchBreak := FLatchBreak or (Changed and not FInput);
  FLatchPress := FLatchPress or FInput;
  FLatchRelease := FLatchRelease or not FInput;
  FLastButtons := FInput;
  FSamples[FSampleHead] := S;
  FSampleHead := (FSampleHead + 1) mod Length(FSamples);
  if FSampleCount < Length(FSamples) then
    Inc(FSampleCount);
  Inc(FSampleIndex);
  while FCtrlWaiters.Count > 0 do
  begin
    var T := FCtrlWaiters[0];
    FCtrlWaiters.Delete(0);
    if T.IsWaiting and (T.Wait.HLETag = 'ctrl') then
    begin
      var Count := Min(Integer(T.Wait.Data[1]), Integer(FSampleIndex - Int64(T.Wait.Data[2])));
      ReadSamples(T.Wait.Data[0], Count, T.Wait.Data[3] <> 0, FSampleIndex - Count);
      FKernel.EndWait(T, Cardinal(Count));
    end;
  end;
end;

procedure TPSPDisplay.ReadSamples(Address: Cardinal; Count: Integer; Negative: Boolean; FromIndex: Int64);
begin
  for var I := 0 to Count - 1 do
  begin
    // Oldest of the requested samples first.
    var Age := Integer(FSampleIndex - (FromIndex + I));
    var Slot := (FSampleHead - Age + Length(FSamples) * 2) mod Length(FSamples);
    var S := FSamples[Slot];
    if FSampleCount = 0 then
    begin
      S := Default(TPSPCtrlSample);
      S.LX := 128;
      S.LY := 128;
    end;
    var A := Address + Cardinal(I) * 16;
    FMemory.Write32(A, S.Time);
    if Negative then
      FMemory.Write32(A + 4, not S.Buttons)
    else
      FMemory.Write32(A + 4, S.Buttons);
    FMemory.Write8(A + 8, S.LX);
    FMemory.Write8(A + 9, S.LY);
    FMemory.Fill(A + 10, 0, 6);
  end;
end;

function TPSPDisplay.CtrlRetry(T: TPSPThread): Boolean;
begin
  Result := FSampleIndex > Int64(T.Wait.Data[2]);
  if Result then
  begin
    var Count := Min(Integer(T.Wait.Data[1]), Integer(FSampleIndex - Int64(T.Wait.Data[2])));
    ReadSamples(T.Wait.Data[0], Count, T.Wait.Data[3] <> 0, FSampleIndex - Count);
    T.SetResult(Cardinal(Count));
  end
  else if not FCtrlWaiters.Contains(T) then
    FCtrlWaiters.Add(T);
end;

procedure TPSPDisplay.CtrlAbort(T: TPSPThread);
begin
  FCtrlWaiters.Remove(T);
end;

procedure PixelsFrom(Memory: TPSPMemory; const FB: TPSPFrameBuffer; var Frame: TEmulatorFrame);
begin
  var Bpp := 2;
  if FB.Format = 3 then
    Bpp := 4;
  var Stride := FB.Width;
  if Stride = 0 then
    Stride := 512;
  for var Y := 0 to PSPFrameHeight - 1 do
  begin
    var Row := Memory.Ptr(FB.Address + Cardinal(Y) * Stride * Cardinal(Bpp), PSPFrameWidth * Bpp);
    var Dest := @Frame.Pixels[Y * PSPFrameWidth];
    if Row = nil then
    begin
      FillChar(Dest^, PSPFrameWidth * 4, 0);
      for var X := 0 to PSPFrameWidth - 1 do
        Frame.Pixels[Y * PSPFrameWidth + X] := $FF000000;
      Continue;
    end;
    case FB.Format of
      3:
        for var X := 0 to PSPFrameWidth - 1 do
        begin
          var C := PCardinal(Row + X * 4)^;
          Frame.Pixels[Y * PSPFrameWidth + X] := $FF000000 or ((C and $FF) shl 16) or (C and $FF00) or ((C shr 16) and $FF);
        end;
      0:
        for var X := 0 to PSPFrameWidth - 1 do
        begin
          var C := PWord(Row + X * 2)^;
          var R := C and $1F;
          var G := (C shr 5) and $3F;
          var B := (C shr 11) and $1F;
          R := (R shl 3) or (R shr 2);
          G := (G shl 2) or (G shr 4);
          B := (B shl 3) or (B shr 2);
          Frame.Pixels[Y * PSPFrameWidth + X] := $FF000000 or (Cardinal(R) shl 16) or (Cardinal(G) shl 8) or Cardinal(B);
        end;
      1:
        for var X := 0 to PSPFrameWidth - 1 do
        begin
          var C := PWord(Row + X * 2)^;
          var R := C and $1F;
          var G := (C shr 5) and $1F;
          var B := (C shr 10) and $1F;
          R := (R shl 3) or (R shr 2);
          G := (G shl 3) or (G shr 2);
          B := (B shl 3) or (B shr 2);
          Frame.Pixels[Y * PSPFrameWidth + X] := $FF000000 or (Cardinal(R) shl 16) or (Cardinal(G) shl 8) or Cardinal(B);
        end;
      2:
        for var X := 0 to PSPFrameWidth - 1 do
        begin
          var C := PWord(Row + X * 2)^;
          var R := C and $F;
          var G := (C shr 4) and $F;
          var B := (C shr 8) and $F;
          Frame.Pixels[Y * PSPFrameWidth + X] := $FF000000 or (Cardinal(R * 17) shl 16) or (Cardinal(G * 17) shl 8) or Cardinal(B * 17);
        end;
    end;
  end;
end;

procedure TPSPDisplay.Render(var Frame: TEmulatorFrame);
begin
  Frame.Width := PSPFrameWidth;
  Frame.Height := PSPFrameHeight;
  if Length(Frame.Pixels) <> PSPFrameWidth * PSPFrameHeight then
    SetLength(Frame.Pixels, PSPFrameWidth * PSPFrameHeight);
  if FCurrent.Address = 0 then
  begin
    for var I := 0 to High(Frame.Pixels) do
      Frame.Pixels[I] := $FF000000;
    Exit;
  end;
  PixelsFrom(FMemory, FCurrent, Frame);
end;

{ HLE: display }

procedure TPSPDisplay.hSetMode;
begin
  var Mode := FHLE.Arg(0);
  var W := FHLE.Arg(1);
  var H := FHLE.Arg(2);
  if (Mode <> 0) or (W = 0) or (H = 0) or (W > 480) or (H > 272) then
    begin FHLE.Result(SCE_KERNEL_ERROR_INVAL); Exit; end;
  FMode := Mode;
  FModeWidth := W;
  FModeHeight := H;
  FHLE.Result(0);
end;

procedure TPSPDisplay.hGetMode;
begin
  if FHLE.Arg(0) <> 0 then FMemory.Write32(FHLE.Arg(0), FMode);
  if FHLE.Arg(1) <> 0 then FMemory.Write32(FHLE.Arg(1), FModeWidth);
  if FHLE.Arg(2) <> 0 then FMemory.Write32(FHLE.Arg(2), FModeHeight);
  FHLE.Result(0);
end;

procedure TPSPDisplay.hSetFrameBuf;
begin
  var FB := Default(TPSPFrameBuffer);
  FB.Address := FHLE.Arg(0);
  FB.Width := FHLE.Arg(1);
  FB.Format := FHLE.Arg(2);
  var Sync := FHLE.Arg(3);
  if Sync > 1 then
    begin FHLE.Result(SCE_KERNEL_ERROR_INVAL); Exit; end;
  if FB.Address <> 0 then
  begin
    if (FB.Format > 3) then
      begin FHLE.Result(SCE_KERNEL_ERROR_INVAL); Exit; end;
    if (FB.Width = 0) or ((FB.Width and 63) <> 0) then
      begin FHLE.Result(SCE_KERNEL_ERROR_INVAL); Exit; end;
  end;
  if Sync = 0 then
  begin
    FCurrent := FB;
    FHasPending := False;
  end
  else
  begin
    FPending := FB;
    FHasPending := True;
  end;
  FHLE.Result(0);
end;

procedure TPSPDisplay.hGetFrameBuf;
begin
  var FB := FCurrent;
  if (FHLE.Arg(3) = 1) and FHasPending then
    FB := FPending;
  if FHLE.Arg(0) <> 0 then FMemory.Write32(FHLE.Arg(0), FB.Address);
  if FHLE.Arg(1) <> 0 then FMemory.Write32(FHLE.Arg(1), FB.Width);
  if FHLE.Arg(2) <> 0 then FMemory.Write32(FHLE.Arg(2), FB.Format);
  FHLE.Result(0);
end;

procedure TPSPDisplay.hWaitVblankStart;
begin
  WaitVBlank(False, False);
end;

procedure TPSPDisplay.hWaitVblankStartCB;
begin
  WaitVBlank(True, False);
end;

procedure TPSPDisplay.hWaitVblank;
begin
  WaitVBlank(False, True);
end;

procedure TPSPDisplay.hWaitVblankCB;
begin
  WaitVBlank(True, True);
end;

procedure TPSPDisplay.hGetVcount;
begin
  FHLE.Result(FVCount);
end;

procedure TPSPDisplay.hIsVblank;
begin
  FKernel.NowUs;
  FHLE.Result(Ord(FInVBlank));
end;

procedure TPSPDisplay.hGetCurrentHcount;
begin
  FKernel.NowUs;
  FHLE.Result(Cardinal(LineNow mod PSPLinesPerFrame));
end;

procedure TPSPDisplay.hGetAccumulatedHcount;
begin
  FKernel.NowUs;
  FHLE.Result(Cardinal(Int64(FVCount) * PSPLinesPerFrame + LineNow));
end;

procedure TPSPDisplay.hGetFramePerSec;
begin
  FHLE.ResultFloat(59.9400599);
  FHLE.Result(PCardinal(@FHLE.CPU.Ctx.FPR[0])^);
end;

procedure TPSPDisplay.hIsForeground;
begin
  FHLE.Result(1);
end;

procedure TPSPDisplay.hSetHoldMode;
begin
  FHLE.Result(0);
end;

procedure TPSPDisplay.hSetResumeMode;
begin
  FHLE.Result(0);
end;

procedure TPSPDisplay.hGetBrightness;
begin
  if FHLE.Arg(0) <> 0 then FMemory.Write32(FHLE.Arg(0), 84);
  if FHLE.Arg(1) <> 0 then FMemory.Write32(FHLE.Arg(1), 0);
  FHLE.Result(0);
end;

{ HLE: controller }

procedure TPSPDisplay.hCtrlSetSamplingCycle;
begin
  var C := FHLE.Arg(0);
  if (C <> 0) and ((C < 5555) or (C > 20000)) then
    begin FHLE.Result(SCE_KERNEL_ERROR_INVAL); Exit; end;
  FHLE.Result(FSamplingCycle);
  FSamplingCycle := C;
end;

procedure TPSPDisplay.hCtrlGetSamplingCycle;
begin
  if FHLE.Arg(0) <> 0 then
    FMemory.Write32(FHLE.Arg(0), FSamplingCycle);
  FHLE.Result(0);
end;

procedure TPSPDisplay.hCtrlSetSamplingMode;
begin
  var M := FHLE.Arg(0);
  if M > 1 then
    begin FHLE.Result(SCE_KERNEL_ERROR_INVAL); Exit; end;
  FHLE.Result(FSamplingMode);
  FSamplingMode := M;
end;

procedure TPSPDisplay.hCtrlGetSamplingMode;
begin
  if FHLE.Arg(0) <> 0 then
    FMemory.Write32(FHLE.Arg(0), FSamplingMode);
  FHLE.Result(0);
end;

procedure TPSPDisplay.hCtrlPeekBufferPositive;
begin
  var N := EnsureRange(FHLE.ArgInt(1), 0, 64);
  ReadSamples(FHLE.Arg(0), N, False, FSampleIndex - N);
  FHLE.Result(Cardinal(N));
end;

procedure TPSPDisplay.hCtrlPeekBufferNegative;
begin
  var N := EnsureRange(FHLE.ArgInt(1), 0, 64);
  ReadSamples(FHLE.Arg(0), N, True, FSampleIndex - N);
  FHLE.Result(Cardinal(N));
end;

procedure TPSPDisplay.ReadBufferCommon(Negative: Boolean);
begin
  var Address := FHLE.Arg(0);
  var N := EnsureRange(FHLE.ArgInt(1), 0, 64);
  if not FKernel.CanWait then
  begin
    ReadSamples(Address, N, Negative, FSampleIndex - N);
    begin FHLE.Result(Cardinal(N)); Exit; end;
  end;
  // Reading waits for the next sample.
  FCtrlWaiters.Add(FKernel.Current);
  FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, False, CtrlRetry, CtrlAbort, 'ctrl');
  var T := FKernel.Current;
  T.Wait.Data[0] := Address;
  T.Wait.Data[1] := Cardinal(N);
  T.Wait.Data[2] := Cardinal(FSampleIndex);
  T.Wait.Data[3] := Ord(Negative);
end;

procedure TPSPDisplay.hCtrlReadBufferPositive;
begin
  ReadBufferCommon(False);
end;

procedure TPSPDisplay.hCtrlReadBufferNegative;
begin
  ReadBufferCommon(True);
end;

procedure TPSPDisplay.hCtrlPeekLatch;
begin
  var P := FHLE.Arg(0);
  FMemory.Write32(P, FLatchMake);
  FMemory.Write32(P + 4, FLatchBreak);
  FMemory.Write32(P + 8, FLatchPress);
  FMemory.Write32(P + 12, FLatchRelease);
  FHLE.Result(Cardinal(Min(FSampleCount, 1)));
end;

procedure TPSPDisplay.hCtrlReadLatch;
begin
  hCtrlPeekLatch;
  FLatchMake := 0;
  FLatchBreak := 0;
  FLatchPress := 0;
  FLatchRelease := 0;
end;

procedure TPSPDisplay.hCtrlSetIdleCancelThreshold;
begin
  FIdleReset := FHLE.ArgInt(0);
  FIdleBack := FHLE.ArgInt(1);
  FHLE.Result(0);
end;

procedure TPSPDisplay.hCtrlGetIdleCancelThreshold;
begin
  if FHLE.Arg(0) <> 0 then FMemory.Write32(FHLE.Arg(0), Cardinal(FIdleReset));
  if FHLE.Arg(1) <> 0 then FMemory.Write32(FHLE.Arg(1), Cardinal(FIdleBack));
  FHLE.Result(0);
end;

procedure TPSPDisplay.hCtrlZero;
begin
  FHLE.Result(0);
end;

procedure TPSPDisplay.Register;
const
  D = 'sceDisplay';
  C = 'sceCtrl';
begin
  var H := FHLE;
  H.Register(D, $0E20F177, 'sceDisplaySetMode', hSetMode);
  H.Register(D, $DEA197D4, 'sceDisplayGetMode', hGetMode);
  H.Register(D, $289D82FE, 'sceDisplaySetFrameBuf', hSetFrameBuf);
  H.Register(D, $EEDA2E54, 'sceDisplayGetFrameBuf', hGetFrameBuf);
  H.Register(D, $984C27E7, 'sceDisplayWaitVblankStart', hWaitVblankStart);
  H.Register(D, $46F186C3, 'sceDisplayWaitVblankStartCB', hWaitVblankStartCB);
  H.Register(D, $36CDFADE, 'sceDisplayWaitVblank', hWaitVblank);
  H.Register(D, $8EB9EC49, 'sceDisplayWaitVblankCB', hWaitVblankCB);
  H.Register(D, $9C6EAAD7, 'sceDisplayGetVcount', hGetVcount);
  H.Register(D, $4D4E10EC, 'sceDisplayIsVblank', hIsVblank);
  H.Register(D, $773DD3A3, 'sceDisplayGetCurrentHcount', hGetCurrentHcount);
  H.Register(D, $210EAB3A, 'sceDisplayGetAccumulatedHcount', hGetAccumulatedHcount);
  H.Register(D, $DBA6C4C4, 'sceDisplayGetFramePerSec', hGetFramePerSec);
  H.Register(D, $B4F378FA, 'sceDisplayIsForeground', hIsForeground);
  H.Register(D, $7ED59BC4, 'sceDisplaySetHoldMode', hSetHoldMode);
  H.Register(D, $A544C486, 'sceDisplaySetResumeMode', hSetResumeMode);
  H.Register(D, $31C4BAA8, 'sceDisplayGetBrightness', hGetBrightness);
  H.Register(C, $6A2774F3, 'sceCtrlSetSamplingCycle', hCtrlSetSamplingCycle);
  H.Register(C, $02BAAD91, 'sceCtrlGetSamplingCycle', hCtrlGetSamplingCycle);
  H.Register(C, $1F4011E6, 'sceCtrlSetSamplingMode', hCtrlSetSamplingMode);
  H.Register(C, $DA6B76A1, 'sceCtrlGetSamplingMode', hCtrlGetSamplingMode);
  H.Register(C, $3A622550, 'sceCtrlPeekBufferPositive', hCtrlPeekBufferPositive);
  H.Register(C, $C152080A, 'sceCtrlPeekBufferNegative', hCtrlPeekBufferNegative);
  H.Register(C, $1F803938, 'sceCtrlReadBufferPositive', hCtrlReadBufferPositive);
  H.Register(C, $60B81F86, 'sceCtrlReadBufferNegative', hCtrlReadBufferNegative);
  H.Register(C, $B1D0E5CD, 'sceCtrlPeekLatch', hCtrlPeekLatch);
  H.Register(C, $0B588501, 'sceCtrlReadLatch', hCtrlReadLatch);
  H.Register(C, $A7144800, 'sceCtrlSetIdleCancelThreshold', hCtrlSetIdleCancelThreshold);
  H.Register(C, $687660FA, 'sceCtrlGetIdleCancelThreshold', hCtrlGetIdleCancelThreshold);
  H.Register(C, $348D99D4, 'sceCtrlSetSuspendingExtraSamples', hCtrlZero);
  H.Register(C, $AF5960F3, 'sceCtrlGetSuspendingExtraSamples', hCtrlZero);
  H.Register(C, $A68FD260, 'sceCtrlClearRapidFire', hCtrlZero);
  H.Register(C, $6841BE1A, 'sceCtrlSetRapidFire', hCtrlZero);
end;

end.
