program GEPixelCheck;

{$APPTYPE CONSOLE}
{$Q-}

// The specialised pixel pipelines against the generic one (PlotPixel): random
// primitives with every target format, texture, blend, depth, stencil, fog,
// secondary colour, alpha test, dither and write masks, drawn into two copies
// of VRAM; all bytes are compared after every primitive.

uses
  System.SysUtils, PSP.Types, PSP.Memory, PSP.GE.Texture, PSP.GE.Raster;

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
      S.DepthWrite := Next(3) <> 0;
      S.Blend := Next(2) = 0;
      S.BlendSrc := Next(11); S.BlendDst := Next(11); S.BlendOp := Next(6);
      S.FixA := Next($1000000); S.FixB := Next($1000000);
      S.AlphaTest := Next(3) = 0;
      S.AlphaFunc := Next(8); S.AlphaRef := Next(256); S.AlphaMask := 255;
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

begin
  try
    Check(StrToIntDef(ParamStr(1), 20000));
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
