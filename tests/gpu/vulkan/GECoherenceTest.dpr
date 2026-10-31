program GECoherenceTest;

{$APPTYPE CONSOLE}
{$O+}{$Q-}{$R-}{$EXCESSPRECISION OFF}{$POINTERMATH ON}

uses
  System.SysUtils, System.Math, PSP.Types, PSP.Memory, PSP.CPU, PSP.CPU.JIT, PSP.VFPU,
  PSP.GE.Raster, PSP.GE.VulkanLLE;

const
  Widths: array[0..4] of Cardinal = (0, 512, 1024, 2048, 4096);
  Shifts: array[0..4] of Integer = (0, 9, 10, 11, 12);
  CodeStart = PSPRAMBase + $2000;
  RAMSource = PSPRAMBase + $8000;

var
  CPU, DeviceMemory: TPSPMemory;
  GPU: TGEVulkanLLEBackend;
  Core: TPSPCPU;
  Jit: TPSPRecompiler;
  Checks, Draws, NativeCopies: Integer;
  Label_: string;

procedure Require(Condition: Boolean; const Message_: string);
begin
  if not Condition then
    raise Exception.Create(Label_ + ': ' + Message_);
end;

function Physical(Address: Cardinal; Shift: Integer): Cardinal;
begin
  Result := Address and (PSPVRAMSize - 1);
  if (Address and $200000) = 0 then Exit;
  if (Address and $400000) <> 0 then
    Result := PSPDepthOffset(Result, Shift)
  else if Shift = 0 then
    Result := Result xor $600
  else
    Result := Result xor ((Cardinal(1) shl (Shift + 3)) or $40);
end;

procedure Tables;
begin
  var T := DeviceMemory.PageTable;
  for var M := 0 to 3 do
    for var P := 0 to PSPVRAMSize div PSPPageSize - 1 do
    begin
      var Index := (PSPVRAMBase + Cardinal(M) * PSPVRAMSize) shr PSPPageShift + Cardinal(P);
      var Actual := PPointer(PByte(T) + Index * SizeOf(Pointer))^;
      if M and 1 <> 0 then
        Require(Actual = nil, 'nonlinear page was mapped as contiguous')
      else if DeviceMemory.VRAMHeld(P) then
        Require(Actual = nil, 'held linear page is exposed to native code')
      else
        Require(Actual = @DeviceMemory.VRAM[P * PSPPageSize], 'linear page was not restored');
    end;
end;

procedure Compare;
begin
  GPU.Sync;
  Inc(Checks);
  Require(DeviceMemory.HeldVRAMPages = 0, 'Sync retained held pages');
  Require((CPU.Faults = 0) and (DeviceMemory.Faults = 0), 'valid mirror access was treated as unmapped');
  Require(CompareMem(@CPU.VRAM[0], @DeviceMemory.VRAM[0], PSPVRAMSize), 'physical VRAM differs');
  Tables;
end;

function BaseState: TGERaster;
begin
  Result := Default(TGERaster);
  Result.VRAM := @CPU.VRAM[0];
  Result.FBFormat := 3;
  Result.FBStride := 512;
  Result.ZStride := 512;
  Result.Through := True;
  Result.Flat := True;
  Result.BandY2 := 1023;
  GEPrepareRaster(Result);
end;

function Vertex: TGEVertex;
begin
  Result := Default(TGEVertex);
  Result.W := 1; Result.Q := 1;
  Result.R := $5A; Result.G := $93; Result.B := $E7; Result.A := $B2;
  Result.Z := $2468;
end;

procedure Draw(const S: TGERaster; Count: Integer = 1);
begin
  var D := S;
  D.VRAM := @DeviceMemory.VRAM[0];
  D.Tex.Memory := DeviceMemory;
  var V := Vertex;
  for var I := 1 to Count do
  begin
    GEDrawPoint(S, V);
    GPU.DrawPoint(D, V);
    Inc(Draws);
  end;
end;

procedure QueuePixel(Offset: Cardinal; Submitted: Boolean = False);
begin
  var S := BaseState;
  S.FBAddr := Offset;
  S.ClearMode := True;
  S.ClearColor := True;
  S.ClearStencil := True;
  if Submitted then
  begin
    Draw(S, 2048);
    GPU.Release;
  end
  else
    Draw(S);
  Require(DeviceMemory.VRAMHeld(Offset shr PSPPageShift), 'point did not hold its physical page');
  Tables;
end;

procedure NativeCopy(Source, Dest: Cardinal; Quad: Boolean);
begin
  var N := 1;
  var LoadOp: Cardinal := $C9000000;
  var StoreOp: Cardinal := $E9200000;
  if Quad then
  begin
    N := 4;
    LoadOp := $D9000000;
    StoreOp := $F9200000;
  end;
  var Values: array[0..3] of Cardinal;
  for var I := 0 to N - 1 do
    Values[I] := CPU.Read32(Source + Cardinal(I) * 4);
  for var I := 0 to N - 1 do
    CPU.Write32(Dest + Cardinal(I) * 4, Values[I]);
  DeviceMemory.Write32(CodeStart, LoadOp);
  DeviceMemory.Write32(CodeStart + 4, StoreOp);
  DeviceMemory.Write32(CodeStart + 8, 0);
  DeviceMemory.Write32(CodeStart + 12, 0);
  Core.Ctx.GPR[8] := Source;
  Core.Ctx.GPR[9] := Dest;
  Core.SetPC(CodeStart);
  Core.Run(2);
  Require(Core.Ctx.PC = CodeStart + 8, 'native VFPU block did not execute exactly two instructions');
  Inc(NativeCopies);
  Compare;
end;

// A JIT store of one word, without the comparison that synchronizes.
procedure NativeStore(Dest, Value: Cardinal);
begin
  CPU.Write32(Dest, Value);
  DeviceMemory.Write32(RAMSource + $100, Value);
  DeviceMemory.Write32(CodeStart, $C9000100);     // lv.s S000, 256($8)
  DeviceMemory.Write32(CodeStart + 4, $E9200000); // sv.s S000, 0($9)
  DeviceMemory.Write32(CodeStart + 8, 0);
  DeviceMemory.Write32(CodeStart + 12, 0);
  CPU.Write32(RAMSource + $100, Value);
  Core.Ctx.GPR[8] := RAMSource;
  Core.Ctx.GPR[9] := Dest;
  Core.SetPC(CodeStart);
  Core.Run(2);
  Require(Core.Ctx.PC = CodeStart + 8, 'native store block did not execute exactly two instructions');
  Inc(NativeCopies);
end;

function TexState(Addr: Cardinal): TGERaster;
begin
  Result := BaseState;
  Result.FBAddr := $120000;
  Result.Textured := True; Result.TexFunc := 3; Result.TexAlpha := True;
  Result.Tex.Memory := CPU; Result.Tex.Format := 3; Result.Tex.LevelCount := 1;
  Result.Tex.Levels[0].Addr := Addr;
  Result.Tex.Levels[0].Width := 16; Result.Tex.Levels[0].Height := 16; Result.Tex.Levels[0].BufWidth := 16;
end;

// Batches outlive Release and are read back only when needed; texture pages
// are watched (reads go on, writes first draw), not held.
procedure Deferred;
const
  RAMTex = PSPRAMBase + $10000;
begin
  for var W := 0 to High(Widths) do
  begin
    CPU.SetVRAMTranslation(Widths[W]);
    DeviceMemory.SetVRAMTranslation(Widths[W]);
    Label_ := Format('deferred width %d', [Widths[W]]);
    // Several submissions in one epoch, then one read back of all of them.
    QueuePixel($30000, True);
    QueuePixel($50000, True);
    QueuePixel($70000);
    Require(DeviceMemory.HeldVRAMPages >= 3, 'Release gave drawn pages back');
    Require(DeviceMemory.Read32(PSPVRAMBase + $50000) = CPU.Read32(PSPVRAMBase + $50000), 'submitted page read');
    Require(DeviceMemory.HeldVRAMPages = 0, 'a held page read did not synchronize');
    Compare;
    // Textures drawn by an earlier submission of the same epoch.
    QueuePixel($30000, True);
    for var M := 0 to 3 do
      Draw(TexState(PSPVRAMBase + Cardinal(M) * PSPVRAMSize + $30000));
    Compare;
    // Textures in VRAM, through every mirror, then written in different ways.
    for var M := 0 to 3 do
      for var How := 0 to 4 do
      begin
        Label_ := Format('watched VRAM texture width %d mirror %d write %d', [Widths[W], M, How]);
        var TexAddr := PSPVRAMBase + Cardinal(M) * PSPVRAMSize + $60000;
        var S := TexState(TexAddr);
        Draw(S);
        var Read: Cardinal;
        DeviceMemory.ReadBytes(TexAddr, Read, 4);
        Require(Read = CPU.Read32(TexAddr), 'watched texture read');
        Require(DeviceMemory.Read32(TexAddr or $40000000) = CPU.Read32(TexAddr), 'watched texture word read');
        Require((DeviceMemory.HeldVRAMPages > 0) and (DeviceMemory.WatchedPages > 0), 'a texture read drew the batch');
        var V := $C0DE0000 + Cardinal(W * 64 + M * 8 + How);
        case How of
          0: begin CPU.Write32(TexAddr, V); DeviceMemory.Write32(TexAddr, V); end;
          1: begin CPU.WriteBytes(TexAddr, V, 4); DeviceMemory.WriteBytes(TexAddr, V, 4); end;
          2:
            begin
              // The same physical bytes through the linear mirror 2.
              var Linear := PSPVRAMBase + 2 * PSPVRAMSize + Physical(TexAddr, Shifts[W]);
              CPU.Write32(Linear, V); DeviceMemory.Write32(Linear, V);
            end;
          3: NativeStore(TexAddr, V);
          4: Require(DeviceMemory.Ptr(TexAddr and not $200000, 4) <> nil, 'linear texture pointer');
        end;
        Require((DeviceMemory.HeldVRAMPages = 0) and (DeviceMemory.WatchedPages = 0),
          'a texture write did not draw the batch first');
        Draw(S);
        Compare;
      end;
    // Textures in main memory: the batch's copy stays valid while watched.
    for var How := 0 to 2 do
    begin
      Label_ := Format('watched RAM texture width %d write %d', [Widths[W], How]);
      var S := TexState(RAMTex);
      Draw(S);
      Require(DeviceMemory.Read32(RAMTex) = CPU.Read32(RAMTex), 'watched RAM texture read');
      Require((DeviceMemory.HeldVRAMPages > 0) and (DeviceMemory.WatchedPages > 0), 'a RAM texture read drew the batch');
      var V := $BEEF0000 + Cardinal(W * 8 + How);
      case How of
        0: begin CPU.Write32(RAMTex, V); DeviceMemory.Write32(RAMTex, V); end;
        1: begin CPU.WriteBytes(RAMTex, V, 4); DeviceMemory.WriteBytes(RAMTex, V, 4); end;
        2: NativeStore(RAMTex, V);
      end;
      Require((DeviceMemory.HeldVRAMPages = 0) and (DeviceMemory.WatchedPages = 0),
        'a RAM texture write did not draw the batch first');
      // The same texture again: a new copy, not the batch's old one.
      Draw(S);
      Draw(S);
      Compare;
    end;
  end;
end;

procedure Exercise;
begin
  for var W := 0 to High(Widths) do
  begin
    CPU.SetVRAMTranslation(Widths[W]);
    DeviceMemory.SetVRAMTranslation(Widths[W]);
    for var M in [1, 3] do
    begin
      var A := PSPVRAMBase + Cardinal(M) * PSPVRAMSize + $80;
      var P := Physical(A, Shifts[W]);
      Label_ := Format('width %d mirror %d', [Widths[W], M]);
      QueuePixel(P, True);
      if W > 0 then Require(not DeviceMemory.VRAMHeld($80 shr PSPPageShift), 'test did not isolate the permuted page');
      Require(DeviceMemory.Read8(A) = CPU.Read8(A), 'held mirror byte read');
      Require(DeviceMemory.HeldVRAMPages = 0, 'mirror read failed to fault the actual page');
      Compare;
      if W > 0 then
      begin
        QueuePixel($80);
        Require(DeviceMemory.Read32(A) = CPU.Read32(A), 'unheld translated read');
        Require(DeviceMemory.HeldVRAMPages > 0, 'mirror read faulted the unrelated unpermuted page');
        Require(DeviceMemory.Ptr(A, 4) = nil, 'nonlinear Ptr should stay nil');
        Require(DeviceMemory.PageBase(A) = nil, 'nonlinear PageBase should stay nil');
        CPU.Write32(A, $CAFEBABE); DeviceMemory.Write32(A, $CAFEBABE);
        Require(DeviceMemory.HeldVRAMPages > 0, 'unheld mirror access faulted an unrelated page');
        Compare;
      end;
      QueuePixel(P);
      Require(DeviceMemory.Read16(A) = CPU.Read16(A), 'held mirror halfword read');
      Compare;
      QueuePixel(P);
      Require(DeviceMemory.Read32(A or $40000000) = CPU.Read32(A), 'uncached held mirror word read');
      Compare;

      QueuePixel(P);
      Require(DeviceMemory.HostPtr(A, 4) = nil, 'HostPtr exposed nonlinear data');
      Require(DeviceMemory.HeldVRAMPages > 0, 'HostPtr consumed held data');
      Require(DeviceMemory.Valid(A, 4), 'nonlinear VRAM should be valid');
      Require(DeviceMemory.HeldVRAMPages > 0, 'Valid consumed held data');
      Require(DeviceMemory.Ptr(A, 4) = nil, 'Ptr exposed nonlinear data');
      Require(DeviceMemory.HeldVRAMPages = 0, 'Ptr did not synchronize the mapped page');
      Compare;
      QueuePixel(P);
      Require(DeviceMemory.PageBase(A) = nil, 'PageBase exposed nonlinear data');
      Require(DeviceMemory.HeldVRAMPages = 0, 'PageBase missed a held mapped page');
      Compare;

      QueuePixel(P);
      CPU.Write8(A + 1, $AB); DeviceMemory.Write8(A + 1, $AB);
      Compare;
      QueuePixel(P);
      CPU.Write16(A + 2, $5678); DeviceMemory.Write16(A + 2, $5678);
      Compare;
      QueuePixel(P);
      CPU.Write32(A, $89ABCDEF); DeviceMemory.Write32(A, $89ABCDEF);
      Compare;
      // The first page is not held: Ptr must inspect the mapped second page.
      var R := PSPVRAMBase + Cardinal(M) * PSPVRAMSize + $1FF0;
      QueuePixel(Physical(R + 32, Shifts[W]));
      Require(DeviceMemory.Ptr(R, 64) = nil, 'cross-page nonlinear Ptr');
      Require(DeviceMemory.HeldVRAMPages = 0, 'cross-page Ptr missed a translated held page');
      var B1, B2: array[0..63] of Byte;
      CPU.ReadBytes(R, B1, 64); DeviceMemory.ReadBytes(R, B2, 64);
      Require(CompareMem(@B1, @B2, 64), 'cross-page byte copy differs');
      Compare;
      QueuePixel(Physical(R + 32, Shifts[W]));
      for var I := 0 to 63 do B1[I] := Byte(I xor $A6);
      CPU.WriteBytes(R, B1, 64); DeviceMemory.WriteBytes(R, B1, 64);
      Compare;

      QueuePixel(P);
      NativeCopy(A, PSPVRAMBase + $A0000, True);
      QueuePixel(P);
      NativeCopy(A, PSPVRAMBase + $A0010, False);
      QueuePixel(P);
      NativeCopy(RAMSource, A, True);
      QueuePixel(P);
      NativeCopy(RAMSource, A, False);
      // Inline stores into held linear mirrors must also use the slow path.
      for var LinearMirror in [0, 2] do
      begin
        var Dest := PSPVRAMBase + Cardinal(LinearMirror) * PSPVRAMSize + P;
        QueuePixel(P);
        NativeCopy(RAMSource, Dest, True);
        QueuePixel(P);
        NativeCopy(RAMSource, Dest, False);
      end;

      // The GPU texture path must use the current mirror translation too.
      var S := BaseState;
      S.FBAddr := $120000;
      S.Textured := True; S.TexFunc := 3; S.TexAlpha := True;
      S.Tex.Memory := CPU; S.Tex.Format := 3; S.Tex.LevelCount := 1;
      S.Tex.Levels[0].Addr := PSPVRAMBase + Cardinal(M) * PSPVRAMSize + $60000;
      S.Tex.Levels[0].Width := 16; S.Tex.Levels[0].Height := 16; S.Tex.Levels[0].BufWidth := 16;
      Draw(S);
      CPU.Write32(S.Tex.Levels[0].Addr, $10293847);
      DeviceMemory.Write32(S.Tex.Levels[0].Addr, $10293847);
      Draw(S);
      Compare;
      Inc(S.Tex.Levels[0].Addr, $1D);
      CPU.Write32(S.Tex.Levels[0].Addr, $ABCDEF12);
      DeviceMemory.Write32(S.Tex.Levels[0].Addr, $ABCDEF12);
      Draw(S);
      Compare;
    end;
    Label_ := Format('cross-mirror width %d', [Widths[W]]);
    var Boundary := Cardinal($043FFFF0);
    QueuePixel(Physical(Boundary, Shifts[W]));
    var Bytes: array[0..31] of Byte;
    for var I := 0 to High(Bytes) do Bytes[I] := Byte(I * 7 + W);
    CPU.WriteBytes(Boundary, Bytes, SizeOf(Bytes));
    DeviceMemory.WriteBytes(Boundary, Bytes, SizeOf(Bytes));
    Compare;
    if W > 0 then
    begin
      // The first 2 MiB of this range miss physical bank K: it is reached
      // later, through linear mirror 2. A capped translated scan is wrong.
      var K := Cardinal(1) shl (Shifts[W] - 9);
      QueuePixel(K * PSPPageSize);
      var Size := PSPVRAMSize + (K + 1) * PSPPageSize;
      Require(DeviceMemory.Valid($04201000, Size), 'multi-mirror range should be valid');
      Require(DeviceMemory.Ptr($04201000, Size) = nil, 'multi-mirror range is not contiguous');
      Require(DeviceMemory.HeldVRAMPages = 0, 'range scan stopped before the mapped held page');
      Compare;
    end;
    Label_ := Format('depth width %d', [Widths[W]]);
    var S := BaseState;
    S.FBAddr := $180000; S.ZAddr := $40000; S.ZPermutation := Shifts[W];
    S.ClearMode := True; S.ClearDepth := True;
    Draw(S);
    Require(DeviceMemory.Read16($04640000) = $2468, 'depth mirror does not see shader depth writes');
    Require(CPU.Read16($04640000) = $2468, 'reference depth write missing');
    Compare;
    // Translation changes retire old work before adopting the new permutation.
    QueuePixel($30000, True);
    var Next := (W + 1) mod Length(Widths);
    CPU.SetVRAMTranslation(Widths[Next]);
    DeviceMemory.SetVRAMTranslation(Widths[Next]);
    Require(DeviceMemory.HeldVRAMPages = 0, 'translation change did not retire old work');
    Compare;
  end;
end;

begin
  SetExceptionMask(exAllArithmeticExceptions);
  CPU := TPSPMemory.Create;
  DeviceMemory := TPSPMemory.Create;
  try
    try
      var Error: string;
      Require(CreateGEVulkanLLEBackend(DeviceMemory, False, GPU, Error), Error);
      Core := TPSPCPU.Create(DeviceMemory);
      Jit := TPSPRecompiler.Create(Core, []);
      try
        Require(Jit.Enabled, 'native JIT required by coherence regression');
        for var I := 0 to PSPVRAMSize div 4 - 1 do
        begin
          var V := Cardinal(I) * $13579BDF xor $53AC8271;
          PCardinal(@CPU.VRAM[I * 4])^ := V;
          PCardinal(@DeviceMemory.VRAM[I * 4])^ := V;
        end;
        for var I := 0 to 3 do
        begin
          CPU.Write32(RAMSource + Cardinal(I) * 4, $11223300 + Cardinal(I));
          DeviceMemory.Write32(RAMSource + Cardinal(I) * 4, $11223300 + Cardinal(I));
        end;
        Exercise;
        Deferred;
      finally
        Jit.Free;
        Core.Free;
      end;
      Label_ := 'reset with held pages';
      QueuePixel($30000, True);
      CPU.Reset; DeviceMemory.Reset;
      Compare;
      QueuePixel($10000);
      Compare;
      Writeln(Format('PASS: %d draws, %d whole-VRAM/table comparisons, %d native scalar/quad VFPU copies',
        [Draws, Checks, NativeCopies]));
      Writeln(Format('GPU %d primitives; CPU fallback %d', [GPU.Stats.Prims, GPU.Stats.Fallbacks]));
    except
      on E: Exception do begin Writeln('FAIL: ', E.ClassName, ': ', E.Message); ExitCode := 1; end;
    end;
  finally
    GPU.Free;
    DeviceMemory.Free;
    CPU.Free;
  end;
end.
