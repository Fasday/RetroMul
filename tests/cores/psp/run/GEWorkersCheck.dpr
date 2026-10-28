program GEWorkersCheck;

{$APPTYPE CONSOLE}

uses
  Winapi.Windows, System.SysUtils, PSP.Types, PSP.Memory, PSP.GE.Raster,
  PSP.GE.Workers;

var
  Seed: Cardinal = $15B00B1E;

function Next(N: Cardinal): Cardinal;
begin
  Seed := Seed * 1664525 + 1013904223;
  Result := (Seed shr 8) mod N;
end;

procedure Check;
var
  A, B: TPSPMemory;
  One, Many: TGEWorkers;
  S, T: TGERaster;
  V: array[0..2] of TGEVertex;
  Palette: array[0..1023] of Byte;
begin
  A := TPSPMemory.Create;
  B := TPSPMemory.Create;
  SetEnvironmentVariable('PSP_GE_THREADS', '1');
  One := TGEWorkers.Create;
  SetEnvironmentVariable('PSP_GE_THREADS', '6');
  Many := TGEWorkers.Create;
  try
    for var I := 0 to PSPVRAMSize - 1 do A.VRAM[I] := Next(256);
    Move(A.VRAM[0], B.VRAM[0], PSPVRAMSize);
    for var I := 0 to 1023 do Palette[I] := Next(256);
    for var I := 0 to 512 * 512 * 4 - 1 do A.Write8($08800000 + Cardinal(I), Next(256));
    var PA := A.Ptr($08800000, 512 * 512 * 4);
    B.WriteBytes($08800000, PA^, 512 * 512 * 4);
    for var Test := 0 to 511 do
    begin
      S := Default(TGERaster);
      S.VRAM := @A.VRAM[0];
      S.FBFormat := Test and 3;
      S.FBStride := 512;
      S.ZAddr := $100000;
      S.ZStride := 512;
      S.ScissorX1 := Next(32); S.ScissorX2 := 479 - Integer(Next(32));
      S.ScissorY1 := Next(16); S.ScissorY2 := 271 - Integer(Next(16));
      S.BandY2 := 1023;
      S.Gouraud := True;
      S.Through := (Test and 4) <> 0;
      S.MinZ := 0; S.MaxZ := 65535;
      S.DepthClamp := True;
      S.DepthTest := (Test and 8) <> 0;
      S.DepthFunc := Next(8);
      S.DepthWrite := True;
      S.Blend := (Test and 16) <> 0;
      S.BlendSrc := Next(11); S.BlendDst := Next(11); S.BlendOp := Next(6);
      S.FixA := Next($1000000); S.FixB := Next($1000000);
      S.AlphaTest := (Test and 32) <> 0;
      S.AlphaFunc := Next(8); S.AlphaRef := 128; S.AlphaMask := 255;
      S.StencilTest := Test mod 9 = 0;
      S.StencilFunc := 1; S.StencilZPass := 4; S.StencilZFail := 3;
      S.StencilMask := 255; S.StencilRef := 255;
      S.ClearMode := Test mod 11 = 0;
      S.ClearColor := True; S.ClearStencil := True; S.ClearDepth := True;
      S.Dither := Test mod 7 = 0;
      for var I := 0 to 15 do S.DitherMatrix[I] := Integer(Next(16)) - 8;
      S.MaskRGB := Next($1000000) and $010101;
      S.MaskA := 0;
      S.Tex.Memory := A;
      S.Tex.Format := Test mod 8;
      S.Tex.Linear := (Test and 64) <> 0;
      S.Tex.Clut := @Palette[0]; S.Tex.ClutFormat := 3; S.Tex.ClutMask := 255;
      S.Tex.LevelCount := 1;
      S.Tex.Levels[0].Addr := $08800000;
      S.Tex.Levels[0].Width := 512; S.Tex.Levels[0].Height := 512;
      S.Tex.Levels[0].BufWidth := 512;
      S.Tex.Levels[0].Size := 512 * 512 * 4;
      S.Tex.Levels[0].Ptr := A.Ptr($08800000, 512 * 512 * 4);
      S.Textured := (Test and 128) <> 0;
      S.TexFunc := Test mod 5;
      S.TexAlpha := True;
      S.ColorDouble := Test mod 13 = 0;
      // Fallbacks: physical aliases, wrapped targets and short strides.
      case Test mod 19 of
        0: S.ZAddr := $100;
        1: S.FBAddr := $1F0000;
        2: S.FBStride := 128;
        3:
          begin
            S.Tex.Levels[0].Addr := $04000000;
            S.Tex.Levels[0].Size := PSPVRAMSize;
            S.Tex.Levels[0].Ptr := @A.VRAM[0];
          end;
      end;
      GEPrepareRaster(S);
      T := S; T.VRAM := @B.VRAM[0]; T.Tex.Memory := B;
      if S.Tex.Levels[0].Addr = $04000000 then
        T.Tex.Levels[0].Ptr := @B.VRAM[0]
      else
        T.Tex.Levels[0].Ptr := B.Ptr($08800000, 512 * 512 * 4);
      for var I := 0 to 2 do
      begin
        V[I] := Default(TGEVertex);
        V[I].X := Integer(Next(640 * 16)) - 80 * 16;
        V[I].Y := Integer(Next(400 * 16)) - 64 * 16;
        V[I].R := Next(256); V[I].G := Next(256); V[I].B := Next(256); V[I].A := Next(256);
        if Test mod 3 = 0 then
        begin
          V[I].R := 80; V[I].G := 40; V[I].B := 20; V[I].A := 128;
          V[I].SR := Next(128); V[I].SG := Next(128); V[I].SB := Next(128);
        end;
        V[I].Z := Next(65536);
        V[I].W := 0.5 + Next(128) / 128;
        V[I].Q := 1;
        V[I].S := Next(512); V[I].T := Next(512);
        V[I].Fog := Next(256) / 255;
      end;
      if (Test and 1) = 0 then
      begin
        One.Triangle(S, V[0], V[1], V[2]);
        Many.Triangle(T, V[0], V[1], V[2]);
      end
      else
      begin
        One.Sprite(S, V[0], V[1]);
        Many.Sprite(T, V[0], V[1]);
      end;
      if not CompareMem(@A.VRAM[0], @B.VRAM[0], PSPVRAMSize) then
        raise Exception.CreateFmt('VRAM differs after primitive %d', [Test]);
    end;
    Writeln('PASS: 512 primitives, all VRAM bytes identical with 1 and 6 threads');
  finally
    Many.Free; One.Free;
    B.Free; A.Free;
  end;
end;

begin
  try
    Check;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
