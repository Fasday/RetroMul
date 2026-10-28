program GERasterTest;

{$APPTYPE CONSOLE}
{$O+}{$Q-}{$R-}{$EXCESSPRECISION OFF}{$POINTERMATH ON}

uses
  System.SysUtils, System.Math, System.Diagnostics, PSP.Types, PSP.Memory,
  PSP.GE.Raster, PSP.GE.GPU;

var
  Seed: Cardinal = $FEED1357;
  CPU, DeviceMemory: TPSPMemory;
  GPU: TGEGPUBackend;
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
  if Flag then Result.Tex.Levels[0].Addr := PSPVRAMBase + $60000;
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

procedure Draw(Kind: Integer; const S: TGERaster; const A, B, C: TGEVertex);
begin
  var D := S;
  D.VRAM := @DeviceMemory.VRAM[0];
  D.Tex.Memory := DeviceMemory;
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
      if not CreateGEGPUBackend(DeviceMemory, False, GPU, Error) then
        raise Exception.Create(Error);
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
      // Enough independent work to submit while the CPU continues and to reuse slots.
      S.Textured := False;
      for var Pass := 1 to 4 do
      begin
        for var I := 1 to 2500 do Draw(0, S, Vertex, Vertex, Vertex);
        GPU.Release;
      end;
      Compare;
      Writeln(Format('PASS: %d primitives, %d whole-VRAM compares, %.2f seconds', [Draws, Checks, Watch.Elapsed.TotalSeconds]));
      Writeln(Format('GPU %d primitives, CPU fallback %d, %d submissions', [GPU.Stats.Prims, GPU.Stats.Fallbacks, GPU.Stats.Batches]));
    except
      on E: Exception do begin Writeln(E.ClassName, ': ', E.Message); ExitCode := 1; end;
    end;
  finally
    GPU.Free;
    DeviceMemory.Free;
    CPU.Free;
  end;
end.
