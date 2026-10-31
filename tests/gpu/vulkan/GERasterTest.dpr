program GERasterTest;

{$APPTYPE CONSOLE}
{$O+}{$Q-}{$R-}{$EXCESSPRECISION OFF}{$POINTERMATH ON}

uses
  System.SysUtils, System.Math, System.Diagnostics, PSP.Types, PSP.Memory,
  PSP.GE.Texture, PSP.GE.Raster, PSP.GE.VulkanLLE;

const
  Permutations: array[0..4] of Integer = (0, 9, 10, 11, 12);
  LargeTexCoords: array[0..5] of Single = (8388608, 16777216, -16777216, 2147483648, -2147483648, 0.5);

var
  Seed: Cardinal = $FEED1357;
  CPU, DeviceMemory: TPSPMemory;
  GPU: TGEVulkanLLEBackend;
  Clut: array[0..1023] of Byte;
  Draws, Checks: Integer;

function Rand: Cardinal;
begin
  Seed := Seed xor (Seed shl 13);
  Seed := Seed xor (Seed shr 17);
  Seed := Seed xor (Seed shl 5);
  Result := Seed;
end;

function Between(Lo, Hi: Integer): Integer;
begin
  Result := Lo + Integer(Rand mod Cardinal(Hi - Lo + 1));
end;

function Flag: Boolean;
begin
  Result := Rand and 1 <> 0;
end;

procedure Compare;
begin
  GPU.Sync;
  Inc(Checks);
  var A: PByte := @CPU.VRAM[0];
  var B: PByte := @DeviceMemory.VRAM[0];
  for var I := 0 to PSPVRAMSize - 1 do
    if A[I] <> B[I] then
      raise Exception.CreateFmt('draw %d, check %d: VRAM %.6x CPU %.2x GPU %.2x', [Draws, Checks, I, A[I], B[I]]);
end;

function Vertex: TGEVertex;
begin
  Result := Default(TGEVertex);
  Result.X := Between(-16, 80 * 16);
  Result.Y := Between(-16, 64 * 16);
  Result.Z := Between(-100, 65635);
  Result.W := Between(1, 32) / 16;
  Result.R := Between(0, 255); Result.G := Between(0, 255);
  Result.B := Between(0, 255); Result.A := Between(0, 255);
  Result.SR := Between(0, 30); Result.SG := Between(0, 30); Result.SB := Between(0, 30);
  Result.S := Between(-512, 1024) / 32;
  Result.T := Between(-512, 1024) / 32;
  Result.Q := Between(-8, 32) / 8;
  Result.Fog := Between(-5, 20) / 16;
end;

function State: TGERaster;
begin
  Result := Default(TGERaster);
  Result.VRAM := @CPU.VRAM[0];
  Result.FBAddr := $20000; Result.ZAddr := $100000;
  Result.ZPermutation := Permutations[Draws mod Length(Permutations)];
  Result.FBStride := 512; Result.ZStride := 512;
  Result.FBFormat := Rand mod 4;
  Result.ScissorX1 := 0; Result.ScissorY1 := 0;
  Result.ScissorX2 := 63; Result.ScissorY2 := 47;
  Result.BandY1 := 0; Result.BandY2 := 1023;
  Result.Through := Flag; Result.DepthClamp := Flag;
  Result.ClearMode := Rand mod 10 = 0;
  Result.ClearColor := Flag; Result.ClearStencil := Flag; Result.ClearDepth := Flag;
  Result.Flat := Flag; Result.Gouraud := not Result.Flat;
  Result.Textured := Flag and not Result.ClearMode;
  Result.Tex.Memory := CPU;
  Result.Tex.Format := Rand mod 11;
  Result.Tex.Swizzle := Flag;
  Result.Tex.LevelCount := 1;
  Result.Tex.ClampU := Flag; Result.Tex.ClampV := Flag; Result.Tex.Linear := Flag;
  Result.Tex.MinFilter := Ord(Result.Tex.Linear);
  Result.Tex.Clut := @Clut[0];
  Result.Tex.ClutFormat := Rand mod 4;
  Result.Tex.ClutMask := Rand and 255;
  Result.Tex.ClutShift := Rand mod 32;
  Result.Tex.ClutOffset := Rand and $1F0;
  for var L := 0 to 7 do
  begin
    Result.Tex.Levels[L].Addr := PSPRAMBase + $10000;
    Result.Tex.Levels[L].Width := 16; Result.Tex.Levels[L].Height := 16;
    Result.Tex.Levels[L].BufWidth := 32;
  end;
  if Flag then Result.Tex.Levels[0].Addr := PSPVRAMBase + Cardinal(Draws mod 4) * PSPVRAMSize + $60000;
  Result.TexFunc := Rand mod 8;
  Result.TexAlpha := Flag; Result.ColorDouble := Flag;
  Result.EnvR := Rand and 255; Result.EnvG := Rand and 255; Result.EnvB := Rand and 255;
  Result.FogEnabled := Flag;
  Result.FogR := Rand and 255; Result.FogG := Rand and 255; Result.FogB := Rand and 255;
  Result.ColorTest := Rand mod 4 = 0;
  Result.ColorTestFunc := Rand mod 4; Result.ColorRef := Rand and $FFFFFF; Result.ColorMask := Rand and $FFFFFF;
  Result.AlphaTest := Flag; Result.AlphaFunc := Rand mod 8; Result.AlphaRef := Rand and 255; Result.AlphaMask := Rand and 255;
  Result.StencilTest := Flag; Result.StencilFunc := Rand mod 8;
  Result.StencilRef := Rand and 255; Result.StencilMask := Rand and 255;
  Result.StencilFail := Rand mod 8; Result.StencilZFail := Rand mod 8; Result.StencilZPass := Rand mod 8;
  Result.DepthTest := Flag; Result.DepthFunc := Rand mod 8; Result.DepthWrite := Flag;
  Result.MinZ := 0; Result.MaxZ := 65535;
  Result.Blend := Flag; Result.BlendOp := Rand mod 8; Result.BlendSrc := Rand mod 16; Result.BlendDst := Rand mod 16;
  Result.FixA := Rand and $FFFFFF; Result.FixB := Rand and $FFFFFF;
  Result.Dither := Flag;
  for var I := 0 to 15 do Result.DitherMatrix[I] := Between(-8, 7);
  Result.LogicOp := Flag; Result.LogicFunc := Rand mod 16;
  if Rand mod 4 = 0 then begin Result.MaskRGB := Rand and $FFFFFF; Result.MaskA := Rand and 255; end;
  GEPrepareRaster(Result);
end;

var
  // Level pointers into each memory, as the engine sets them (the CPU
  // renderer's queue only queues textured primitives with them).
  HostLevels: Boolean;

procedure SetLevels(var T: TGERaster; M: TPSPMemory);
const
  Bits: array[0..15] of Integer = (16, 16, 16, 32, 4, 8, 16, 32, 4, 8, 8, 0, 0, 0, 0, 0);
begin
  T.Tex.Memory := M;
  for var L := 0 to 7 do
  begin
    var V: PGETexLevel := @T.Tex.Levels[L];
    V.Size := Cardinal(V.BufWidth * V.Height * Bits[T.Tex.Format and 15]) div 8;
    V.Ptr := nil;
    if (L < T.Tex.LevelCount) and (V.Size > 0) then
      V.Ptr := M.HostPtr(V.Addr, V.Size);
    GEFitLevel(T.Tex, V^);
  end;
end;

procedure Draw(Kind: Integer; const Source: TGERaster; const A, B, C: TGEVertex);
begin
  var S := Source;
  if HostLevels then
    SetLevels(S, CPU);
  var D := S;
  D.VRAM := @DeviceMemory.VRAM[0];
  D.Tex.Memory := DeviceMemory;
  if HostLevels then
    SetLevels(D, DeviceMemory);
  case Kind of
    0: begin GEDrawTriangle(S, A, B, C); GPU.DrawTriangle(D, A, B, C); end;
    1: begin GEDrawSprite(S, A, B); GPU.DrawSprite(D, A, B); end;
    2: begin GEDrawLine(S, A, B); GPU.DrawLine(D, A, B); end;
    3: begin GEDrawPoint(S, A); GPU.DrawPoint(D, A); end;
  end;
  Inc(Draws);
end;

begin
  SetExceptionMask(exAllArithmeticExceptions);
  CPU := TPSPMemory.Create;
  DeviceMemory := TPSPMemory.Create;
  GPU := nil;
  try
    try
      var Error: string;
      if not CreateGEVulkanLLEBackend(DeviceMemory, False, GPU, Error) then
        raise Exception.Create(Error);
      // The GPU draws all it can; runs on the CPU are tested at the end.
      GPU.CPURunPixels := 0;
      var Watch := TStopwatch.StartNew;
      for var I := 0 to PSPVRAMSize - 1 do CPU.VRAM[I] := Byte(Rand);
      Move(CPU.VRAM[0], DeviceMemory.VRAM[0], PSPVRAMSize);
      for var I := 0 to 32767 do
      begin
        var B := Byte(Rand);
        CPU.Write8(PSPRAMBase + $10000 + Cardinal(I), B);
        DeviceMemory.Write8(PSPRAMBase + $10000 + Cardinal(I), B);
      end;
      for var I := 0 to 1023 do Clut[I] := Byte(Rand);
      for var I := 1 to 6000 do
      begin
        var S := State;
        Draw(Rand mod 4, S, Vertex, Vertex, Vertex);
        if I mod 97 = 0 then Compare;
        if I mod 41 = 0 then
        begin
          // A CPU write to held VRAM must retire the pending draws first.
          var A := PSPVRAMBase + $20000 + Cardinal(Between(0, 4095) * 4);
          var V := Rand;
          CPU.Write32(A, V); DeviceMemory.Write32(A, V);
        end;
      end;
      Compare;
      // Repeated state, changing RAM texels and CLUT between primitives.
      var S := State;
      S.Textured := True; S.ClearMode := False; S.Tex.Format := 5;
      S.Tex.Levels[0].Addr := PSPRAMBase + $10000;
      S.TexFunc := 3; S.TexAlpha := True; S.Tex.ClutMask := 255;
      S.ColorTest := False; S.AlphaTest := False; S.DepthTest := False; S.StencilTest := False;
      S.Blend := False; S.FogEnabled := False; S.LogicOp := False;
      GEPrepareRaster(S);
      var A := Vertex; var B := Vertex;
      A.X := 0; A.Y := 0; A.S := 0; A.T := 0; A.Q := 1;
      B.X := 1024; B.Y := 768; B.S := 16; B.T := 16; B.Q := 1;
      for var I := 0 to 127 do
      begin
        var V := Rand;
        CPU.Write32(PSPRAMBase + $10000 + Cardinal(I * 4), V);
        DeviceMemory.Write32(PSPRAMBase + $10000 + Cardinal(I * 4), V);
        Clut[I] := Byte(Rand);
        Draw(1, S, A, B, B);
      end;
      Compare;
      // Textures in the render target's own rows: columns beside what is
      // drawn go to the GPU, overlapping ones (in any layout) to the CPU.
      for var I := 1 to 4000 do
      begin
        var T := State;
        T.ClearMode := False;
        T.Textured := True;
        T.Tex.Swizzle := Rand mod 4 = 0;
        T.Tex.Format := Rand mod 8;
        var Size := 16 shl (Rand mod 3);
        T.Tex.Levels[0].Width := Size;
        T.Tex.Levels[0].Height := 16 shl (Rand mod 3);
        T.Tex.Levels[0].BufWidth := 256 shl (Rand mod 2);
        var Offset := Between(-4, 40) * 2048 + Between(0, 511) * 4;
        if Rand mod 4 = 0 then Offset := Between(-4, 40) * 1024 + Between(0, 255) * 4;
        var Mirror: Cardinal := 0;
        if Rand mod 5 = 0 then Mirror := Rand mod 4;
        T.Tex.Levels[0].Addr := PSPVRAMBase + Mirror * PSPVRAMSize + Cardinal($20000 + Offset);
        // Depth beside (or within) the colour rows, in another layout.
        if Rand mod 3 = 0 then
        begin
          T.ZAddr := Cardinal($20000 + Between(0, 60) * 2048 + Between(0, 127) * 16);
          T.ZStride := 256 shl (Rand mod 2);
          T.DepthTest := True;
        end;
        GEPrepareRaster(T);
        var P := Vertex; var Q := Vertex; var R := Vertex;
        if Rand mod 3 = 0 then
        begin
          P.X := Between(0, 40) * 16; P.Y := Between(0, 40) * 16;
          Q.X := P.X + Between(1, 24) * 16; Q.Y := P.Y + Between(1, 8) * 16;
        end;
        Draw(Rand mod 4, T, P, Q, R);
        if I mod 37 = 0 then GPU.Release;
        if I mod 53 = 0 then Compare;
      end;
      Compare;
      // Sprites sampling a window of the buffer they draw into: only the
      // texels they reach decide whether they read their own pixels.
      for var I := 1 to 4000 do
      begin
        var T := State;
        T.ClearMode := False;
        T.Textured := True;
        T.Tex.Swizzle := False;
        T.Tex.Format := Rand mod 8;
        T.Tex.Levels[0].Width := 64;
        T.Tex.Levels[0].Height := 64;
        T.Tex.Levels[0].BufWidth := 256 shl (Rand mod 2);
        T.Tex.Levels[0].Addr := PSPVRAMBase + Cardinal($20000 + Between(0, 2) * 2048 + Between(0, 8) * 16);
        GEPrepareRaster(T);
        var P := Vertex; var Q := Vertex;
        P.X := Between(0, 60 * 16); P.Y := Between(0, 44 * 16);
        Q.X := P.X + Between(-24, 24) * 16 + Between(-8, 8); Q.Y := P.Y + Between(-12, 12) * 16 + Between(-8, 8);
        P.Q := 1; Q.Q := 1;
        P.S := Between(-4 * 16, 70 * 16) / 16; Q.S := P.S + Between(-40 * 16, 40 * 16) / 16;
        P.T := Between(-4 * 16, 70 * 16) / 16; Q.T := P.T + Between(-40 * 16, 40 * 16) / 16;
        if Rand mod 8 = 0 then Q.S := P.S;
        Draw(1, T, P, Q, Q);
        if I mod 29 = 0 then GPU.Release;
        if I mod 41 = 0 then Compare;
      end;
      Compare;
      // The same layout for texels and pixels, one texel a pixel, the window
      // shifted by about the box's size: whether a sprite reads what it has
      // drawn depends on its last texels, and the filter's neighbours.
      for var I := 1 to 16000 do
      begin
        var T := State;
        T.ClearMode := False;
        T.Textured := True;
        T.FBFormat := 3;
        T.Tex.Swizzle := False;
        T.Tex.Format := 3;
        T.Tex.Levels[0].Width := 64;
        T.Tex.Levels[0].Height := 64;
        T.Tex.Levels[0].BufWidth := 512;
        var C := Between(0, 2) * 4;
        var R := Between(0, 2);
        T.Tex.Levels[0].Addr := PSPVRAMBase + Cardinal($20000 + R * 2048 + C * 4);
        T.AlphaTest := False; T.StencilTest := False; T.DepthTest := False; T.ColorTest := False;
        T.MaskRGB := 0; T.MaskA := 0;
        GEPrepareRaster(T);
        var BX := Between(8, 48); var BY := Between(6, 36);
        var W := Between(1, 10); var H := Between(1, 8);
        var P := Vertex; var Q := Vertex;
        P.X := BX * 16; P.Y := BY * 16; Q.X := (BX + W) * 16; Q.Y := (BY + H) * 16;
        P.Q := 1; Q.Q := 1;
        var DX := Between(-W - 3, W + 3) + Between(-15, 15) / 16;
        var DY := Between(-H - 3, H + 3) + Between(-15, 15) / 16;
        if Rand mod 2 = 0 then DY := Between(-1, 1) * Between(-15, 15) / 16;
        P.S := BX - C + DX; Q.S := P.S + W;
        P.T := BY - R + DY; Q.T := P.T + H;
        if Flag then
          Draw(1, T, P, Q, Q)
        else
        begin
          // Two corners and a third, with S/Q and T/Q (what is sampled) as
          // on the sprite, through any positive Q and W.
          var V: array[0..2] of TGEVertex;
          V[0] := P; V[1] := Q; V[2] := P;
          if Flag then begin V[2].X := Q.X; V[2].S := Q.S; end else begin V[2].Y := Q.Y; V[2].T := Q.T; end;
          for var K := 0 to 2 do
          begin
            V[K].W := Between(4, 32) / 16;
            V[K].Q := Between(8, 24) / 16;
            V[K].S := V[K].S * V[K].Q;
            V[K].T := V[K].T * V[K].Q;
          end;
          Draw(0, T, V[0], V[1], V[2]);
        end;
        if I mod 13 = 0 then GPU.Release;
        if I mod 31 = 0 then Compare;
      end;
      Compare;
      // Mipmaps and the level of detail (GESampleTextureLod): every filter
      // and TEXLEVEL mode, biases and slopes, levels in RAM and in VRAM
      // mirrors, per-pixel LOD of triangles (any Q and w), sprites, lines, points.
      for var I := 1 to 8000 do
      begin
        var T := State;
        T.ClearMode := False;
        T.Textured := True;
        T.Tex.LevelCount := Between(1, 8);
        T.Tex.MaxLevel := T.Tex.LevelCount - 1;
        T.Tex.MinFilter := Rand mod 8;
        T.Tex.LevelMode := Rand mod 4;
        T.Tex.LodBias := Between(-40, 40);
        case Rand mod 5 of
          0: T.Tex.Slope := 0;
          1: T.Tex.Slope := Between(1, 4000) / 1000;
          2: T.Tex.Slope := -Between(1, 4000) / 1000;
          3: T.Tex.Slope := Between(1, 1000) / 100000;
        else
          T.Tex.Slope := Between(1, 100) * 3.25;
        end;
        var Size := 8 shl (Rand mod 4);
        var InRAM := Flag;
        for var L := 0 to 7 do
        begin
          T.Tex.Levels[L].Width := Max(1, Size shr L);
          T.Tex.Levels[L].Height := Max(1, (Size shl (Rand mod 2)) shr L);
          if Rand mod 6 = 0 then T.Tex.Levels[L].Width := 1 shl (Rand mod 7);
          T.Tex.Levels[L].BufWidth := Max(T.Tex.Levels[L].Width, 16);
          if InRAM then
            T.Tex.Levels[L].Addr := PSPRAMBase + $10000 + Cardinal(L) * $800 + Cardinal(Rand mod 4) * 16
          else
            T.Tex.Levels[L].Addr := PSPVRAMBase + Cardinal(Rand mod 4) * PSPVRAMSize + $60000 + Cardinal(L) * $800;
        end;
        // Levels sharing a mipmap's pages, one of them in RAM.
        if Rand mod 8 = 0 then T.Tex.Levels[Between(0, 7)].Addr := PSPRAMBase + $12000;
        if Rand mod 25 = 0 then T.Tex.Levels[0].Width := 24;
        T.Tex.NeedLod := ((T.Tex.MinFilter >= 4) and (T.Tex.MaxLevel > 0)) or
          (((T.Tex.MinFilter and 1) <> 0) <> T.Tex.Linear);
        GEPrepareRaster(T);
        var VA := Vertex; var VB := Vertex; var VC := Vertex;
        // Minified, magnified, flat and huge texture coordinates.
        var Spread := 1 shl (Rand mod 12);
        VA.S := Between(-Spread, Spread) / 4; VB.S := Between(-Spread, Spread) / 4; VC.S := Between(-Spread, Spread) / 4;
        VA.T := Between(-Spread, Spread) / 4; VB.T := Between(-Spread, Spread) / 4; VC.T := Between(-Spread, Spread) / 4;
        if Rand mod 16 = 0 then begin VB.S := VA.S; VC.S := VA.S; VB.T := VA.T; VC.T := VA.T; end;
        if Rand mod 32 = 0 then VA.S := 3e30;
        if Rand mod 3 <> 0 then
        begin
          VA.Q := Between(1, 32) / 8; VB.Q := Between(1, 32) / 8; VC.Q := Between(1, 32) / 8;
        end;
        if Rand mod 4 = 0 then
        begin
          VA.Q := 1; VB.Q := 1;
        end;
        Draw(Rand mod 4, T, VA, VB, VC);
        if I mod 37 = 0 then GPU.Release;
        if I mod 59 = 0 then Compare;
      end;
      Compare;
      // Bilinear floor narrows its argument to Single in the current reference.
      S.Tex.Format := 3;
      S.Tex.Linear := True;
      for var Coord in LargeTexCoords do
      begin
        A.S := Coord; B.S := Coord;
        A.T := Coord; B.T := Coord;
        Draw(1, S, A, B, B);
        Compare;
      end;
      // Enough independent work to submit while the CPU continues and to reuse slots.
      S.Textured := False;
      for var Pass := 1 to 4 do
      begin
        for var I := 1 to 2500 do Draw(0, S, Vertex, Vertex, Vertex);
        GPU.Release;
      end;
      Compare;
      // CPU-drawn primitives start runs on the CPU renderer's queue, which
      // end in GPU batches again: interleaved with CPU writes to held pages,
      // GE stops and other budgets.
      HostLevels := True;
      var Queued := GPU.Stats.CPURunPrims;
      for var I := 1 to 8000 do
      begin
        var T := State;
        if Rand mod 4 = 0 then
        begin
          // It textures from the pixels it draws: drawn on the CPU.
          T.ClearMode := False;
          T.Textured := True;
          T.Tex.Swizzle := False;
          T.Tex.Format := 3;
          T.Tex.LevelCount := 1;
          T.Tex.NeedLod := False;
          T.Tex.Levels[0].Addr := PSPVRAMBase + $20000;
          T.Tex.Levels[0].Width := 64; T.Tex.Levels[0].Height := 64; T.Tex.Levels[0].BufWidth := 512;
        end;
        GEPrepareRaster(T);
        if Rand mod 50 = 0 then
          GPU.CPURunPixels := Between(0, 300000);
        Draw(Rand mod 4, T, Vertex, Vertex, Vertex);
        if I mod 23 = 0 then GPU.Release;
        if I mod 31 = 0 then
        begin
          var WA := PSPVRAMBase + $20000 + Cardinal(Between(0, 4095) * 4);
          var WV := Rand;
          CPU.Write32(WA, WV); DeviceMemory.Write32(WA, WV);
        end;
        if I mod 41 = 0 then Compare;
      end;
      Compare;
      HostLevels := False;
      Queued := GPU.Stats.CPURunPrims - Queued;
      if Queued < 1000 then
        raise Exception.CreateFmt('only %d primitives drawn in runs on the CPU', [Queued]);
      Writeln(Format('PASS: %d primitives, %d whole-VRAM compares, %.2f seconds', [Draws, Checks, Watch.Elapsed.TotalSeconds]));
      Writeln(Format('GPU %d primitives, CPU fallback %d, %d submissions, %d in runs on the CPU queue',
        [GPU.Stats.Prims, GPU.Stats.Fallbacks, GPU.Stats.Batches, GPU.Stats.CPURunPrims]));
    except
      on E: Exception do begin Writeln(E.ClassName, ': ', E.Message); ExitCode := 1; end;
    end;
  finally
    GPU.Free;
    DeviceMemory.Free;
    CPU.Free;
  end;
end.
