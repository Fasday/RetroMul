program GEPixelCheck;

{$APPTYPE CONSOLE}
{$Q-}

// The specialised pixel pipelines against the generic one (PlotPixel): random
// primitives with every target format, texture, blend, depth, stencil, fog,
// secondary colour, alpha test, dither and write masks, drawn into two copies
// of VRAM; all bytes are compared after every primitive.

uses
  System.SysUtils, System.Math, PSP.Types, PSP.Memory, PSP.GE.Texture, PSP.GE.Raster;

const
  Permutations: array[0..4] of Integer = (0, 9, 10, 11, 12);

var
  Seed: Cardinal = $5EED1234;

function Next(N: Cardinal): Cardinal;
begin
  Seed := Seed * 1664525 + 1013904223;
  Result := (Seed shr 8) mod N;
end;

procedure Check(Count: Integer);
var
  A, B: TPSPMemory;
  S, T: TGERaster;
  V: array[0..2] of TGEVertex;
  Palette: array[0..1023] of Byte;
begin
  A := TPSPMemory.Create;
  B := TPSPMemory.Create;
  try
    for var I := 0 to PSPVRAMSize - 1 do A.VRAM[I] := Next(256);
    Move(A.VRAM[0], B.VRAM[0], PSPVRAMSize);
    for var I := 0 to 1023 do Palette[I] := Next(256);
    for var I := 0 to 256 * 256 * 4 - 1 do A.Write8($08800000 + Cardinal(I), Next(256));
    B.WriteBytes($08800000, A.Ptr($08800000, 256 * 256 * 4)^, 256 * 256 * 4);
    for var Test := 0 to Count - 1 do
    begin
      S := Default(TGERaster);
      S.VRAM := @A.VRAM[0];
      S.FBFormat := Next(4);
      S.FBAddr := Next(4) * $44000;
      S.FBStride := 512;
      S.ZAddr := $140000;
      S.ZStride := 512;
      S.ZPermutation := Permutations[Next(Length(Permutations))];
      S.ScissorX1 := Next(32); S.ScissorX2 := 479 - Integer(Next(32));
      S.ScissorY1 := Next(16); S.ScissorY2 := 271 - Integer(Next(16));
      S.BandY2 := 1023;
      S.Gouraud := Next(4) <> 0;
      S.Flat := not S.Gouraud;
      S.Through := Next(2) = 0;
      S.MinZ := Next(8000); S.MaxZ := 65535 - Integer(Next(8000));
      S.DepthClamp := Next(2) = 0;
      S.DepthTest := Next(2) = 0;
      S.DepthFunc := Next(8);
      if Next(4) = 0 then S.DepthFunc := 1;
      S.DepthWrite := Next(3) <> 0;
      S.Blend := Next(2) = 0;
      S.BlendSrc := Next(11); S.BlendDst := Next(11); S.BlendOp := Next(6);
      // The equations the pipelines have straight paths for.
      case Next(4) of
        0: begin S.BlendSrc := 2; S.BlendDst := 3; S.BlendOp := 0; end;
        1: begin S.BlendSrc := 2; S.BlendDst := 10 + Next(6); S.BlendOp := 0; end;
      end;
      S.FixA := Next($1000000); S.FixB := Next($1000000);
      S.AlphaTest := Next(3) = 0;
      S.AlphaFunc := Next(8); S.AlphaRef := Next(256); S.AlphaMask := 255;
      // Clear mode, with and without dither.
      S.ClearMode := Next(8) = 0;
      S.ClearColor := Next(4) <> 0; S.ClearStencil := Next(2) = 0; S.ClearDepth := Next(2) = 0;
      S.StencilTest := Next(2) = 0;
      S.StencilFunc := Next(8);
      S.StencilFail := Next(6); S.StencilZFail := Next(6); S.StencilZPass := Next(6);
      S.StencilMask := Next(256); S.StencilRef := Next(256);
      S.FogEnabled := Next(2) = 0;
      S.FogR := Next(256); S.FogG := Next(256); S.FogB := Next(256);
      S.Dither := Next(4) = 0;
      for var I := 0 to 15 do S.DitherMatrix[I] := Integer(Next(16)) - 8;
      S.MaskRGB := 0;
      S.MaskA := 0;
      if Next(4) = 0 then
      begin
        S.MaskRGB := Next($1000000);
        S.MaskA := Next(256);
      end;
      S.Tex.Memory := A;
      S.Tex.Format := Next(8);
      S.Tex.Swizzle := Next(2) = 0;
      S.Tex.Linear := Next(2) = 0;
      S.Tex.ClampU := Next(2) = 0;
      S.Tex.ClampV := Next(2) = 0;
      S.Tex.Clut := @Palette[0]; S.Tex.ClutFormat := Next(4); S.Tex.ClutMask := 255;
      S.Tex.ClutShift := Next(4); S.Tex.ClutOffset := Next(32) * 16;
      S.Tex.LevelCount := 1;
      S.Tex.Levels[0].Addr := $08800000;
      S.Tex.Levels[0].Width := 1 shl (4 + Next(5)); S.Tex.Levels[0].Height := 1 shl (4 + Next(5));
      S.Tex.Levels[0].BufWidth := 256;
      S.Tex.Levels[0].Size := 256 * 256 * 4;
      S.Tex.Levels[0].Ptr := A.Ptr($08800000, 256 * 256 * 4);
      S.Textured := Next(2) = 0;
      S.TexFunc := Next(5);
      S.TexAlpha := Next(2) = 0;
      S.ColorDouble := Next(5) = 0;
      S.EnvR := Next(256); S.EnvG := Next(256); S.EnvB := Next(256);
      if Next(8) = 0 then
        S.Tex.Format := 8 + Next(3);
      GEFitLevel(S.Tex, S.Tex.Levels[0]);
      GEPrepareRaster(S);
      T := S; T.VRAM := @B.VRAM[0]; T.Tex.Memory := B;
      T.Tex.Levels[0].Ptr := B.Ptr($08800000, 256 * 256 * 4);
      var Secondary := Next(2) = 0;
      for var I := 0 to 2 do
      begin
        V[I] := Default(TGEVertex);
        V[I].X := Integer(Next(560 * 16)) - 40 * 16;
        V[I].Y := Integer(Next(340 * 16)) - 34 * 16;
        V[I].R := Next(256); V[I].G := Next(256); V[I].B := Next(256); V[I].A := Next(256);
        if Secondary then
        begin
          V[I].SR := Next(256); V[I].SG := Next(256); V[I].SB := Next(256);
        end;
        V[I].Z := Integer(Next(80000)) - 7000;
        V[I].W := 0.25 + Next(256) / 128;
        V[I].Q := 1;
        V[I].S := Integer(Next(600)) - 44; V[I].T := Integer(Next(600)) - 44;
        V[I].Fog := (Integer(Next(300)) - 20) / 255;
      end;
      // One colour and depth (flat shaded or not): the triangles' constant paths.
      if Next(3) = 0 then
        for var I := 1 to 2 do
        begin
          V[I].R := V[0].R; V[I].G := V[0].G; V[I].B := V[0].B; V[I].A := V[0].A;
          V[I].SR := V[0].SR; V[I].SG := V[0].SG; V[I].SB := V[0].SB;
          if Next(4) <> 0 then V[I].Z := V[0].Z;
        end;
      var Sprite := Next(4) = 0;
      GEGenericPixels := True;
      GEGenericTexels := True;
      if Sprite then GEDrawSprite(S, V[0], V[1]) else GEDrawTriangle(S, V[0], V[1], V[2]);
      GEGenericPixels := False;
      GEGenericTexels := False;
      if Sprite then GEDrawSprite(T, V[0], V[1]) else GEDrawTriangle(T, V[0], V[1], V[2]);
      GEGenericPixels := False;
      if not CompareMem(@A.VRAM[0], @B.VRAM[0], PSPVRAMSize) then
        raise Exception.CreateFmt('VRAM differs after primitive %d (format %d, stencil %s, fog %s, secondary %s)',
          [Test, S.FBFormat, BoolToStr(S.StencilTest, True), BoolToStr(S.FogEnabled, True), BoolToStr(Secondary, True)]);
    end;
    Writeln(Format('PASS: %d primitives, specialised and generic pixel pipelines identical', [Count]));
  finally
    B.Free;
    A.Free;
  end;
end;

// A texture coordinate: mostly ordinary, often at the sampler's edges (texel
// centres and borders give or take an ulp, zero, the 2^22 and 2^23 binades,
// huge and negative values).
function Coord: Single;
begin
  case Next(8) of
    0: Result := (Integer(Next(2000)) - 1000) / 16;
    1:
      begin
        Result := (Integer(Next(2000)) - 1000) / 2;
        var B := PCardinal(@Result)^ + Cardinal(Next(5)) - 2;
        Result := PSingle(@B)^;
      end;
    2: Result := (Next(1000) + 0.5) * (1 shl Next(24));
    3:
      begin
        var B := Next($7F800000) or (Cardinal(Next(2)) shl 31);
        Result := PSingle(@B)^;
      end;
    4: Result := Next(4) * 0.25 - 0.5;
  else
    Result := (Integer(Next(1200000)) - 100000) / 1000;
  end;
end;

// The samplers against the reference (GEGenericTexels): every format, both
// filters, swizzled or not, wrap and clamp, levels that hold all their texels
// and levels that do not, CLUT index transforms.
procedure CheckSamplers(Count: Integer);
var
  M: TPSPMemory;
  T: TGETexture;
  Palette: array[0..1023] of Byte;
begin
  M := TPSPMemory.Create;
  try
    for var I := 0 to 1023 do Palette[I] := Next(256);
    for var I := 0 to 512 * 512 * 4 - 1 do M.Write8($08800000 + Cardinal(I), Next(256));
    var Samples := 0;
    for var Test := 0 to Count - 1 do
    begin
      T := Default(TGETexture);
      T.Memory := M;
      T.Format := Next(8);
      if Next(10) = 0 then T.Format := 8 + Next(3);
      T.Swizzle := Next(2) = 0;
      T.Linear := Next(2) = 0;
      T.ClampU := Next(2) = 0;
      T.ClampV := Next(2) = 0;
      T.Clut := @Palette[0]; T.ClutFormat := Next(4); T.ClutMask := Next(256);
      T.ClutShift := Next(8); T.ClutOffset := Next(32) * 16;
      if Next(2) = 0 then begin T.ClutMask := 255; T.ClutShift := 0; end;
      T.LevelCount := 1;
      var L: PGETexLevel := @T.Levels[0];
      L.Addr := $08800000 + Next(64) * 16;
      L.Width := 1 shl Next(10); L.Height := 1 shl Next(10);
      L.BufWidth := Max(L.Width, 16) shl Next(2);
      if Next(4) = 0 then L.BufWidth := Next(1024);
      L.Size := Next(512 * 512 * 4 - 1024) + 1;
      if Next(2) = 0 then L.Size := 512 * 512 * 4 - 1024;
      L.Ptr := M.Ptr(L.Addr, L.Size);
      GEFitLevel(T, L^);
      GEPreparePalette(T);
      GEPrepareSampler(T);
      for var K := 0 to 63 do
      begin
        var S := Coord;
        var TT := Coord;
        // NaN and infinities: the float conversions may raise; both paths
        // must then agree on that too.
        var Want, Got: Cardinal;
        var WantErr, GotErr: string;
        GEGenericTexels := True;
        try
          Want := GESampleTexture(T, S, TT);
        except
          on E: Exception do WantErr := E.ClassName;
        end;
        GEGenericTexels := False;
        try
          if Assigned(T.Sampler) then
            Got := T.Sampler(@T, S, TT)
          else
            Got := GESampleTexture(T, S, TT);
        except
          on E: Exception do GotErr := E.ClassName;
        end;
        if (WantErr <> GotErr) or ((WantErr = '') and (Want <> Got)) then
          raise Exception.CreateFmt('Texel differs: format %d swizzle %s linear %s fits %s at (%g, %g) [%.8x %.8x]: ' +
            '%.8x %s, want %.8x %s', [T.Format, BoolToStr(T.Swizzle, True), BoolToStr(T.Linear, True),
            BoolToStr(L.Fits, True), S, TT, PCardinal(@S)^, PCardinal(@TT)^, Got, GotErr, Want, WantErr]);
        Inc(Samples);
      end;
    end;
    Writeln(Format('PASS: %d texels, samplers identical to the reference', [Samples]));
  finally
    M.Free;
  end;
end;

begin
  try
    CheckSamplers(StrToIntDef(ParamStr(2), 40000));
    Check(StrToIntDef(ParamStr(1), 20000));
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
