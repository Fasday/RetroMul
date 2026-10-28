program GEWorkersCheck;

{$APPTYPE CONSOLE}
{$Q-}

// The queued, banded CPU renderer against immediate single-thread drawing:
// random primitives into several targets that alias each other and the
// textures, CLUT reloads between primitives, unsafe layouts drawn alone.
// After every few primitives the queue is synchronized and all VRAM compared.

uses
  Winapi.Windows, System.SysUtils, PSP.Types, PSP.Memory, PSP.GE.Raster,
  PSP.GE.Workers;

const
  Permutations: array[0..4] of Integer = (0, 9, 10, 11, 12);
  Targets: array[0..3] of Cardinal = (0, $44000, $88000, $8C000);

var
  Seed: Cardinal = $15B00B1E;

function Next(N: Cardinal): Cardinal;
begin
  Seed := Seed * 1664525 + 1013904223;
  Result := (Seed shr 8) mod N;
end;

procedure Check(Count: Integer);
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
  One := TGEWorkers.Create(A);
  SetEnvironmentVariable('PSP_GE_THREADS', '6');
  Many := TGEWorkers.Create(B);
  try
    for var I := 0 to PSPVRAMSize - 1 do A.VRAM[I] := Next(256);
    Move(A.VRAM[0], B.VRAM[0], PSPVRAMSize);
    for var I := 0 to 1023 do Palette[I] := Next(256);
    for var I := 0 to 512 * 512 * 4 - 1 do A.Write8($08800000 + Cardinal(I), Next(256));
    var PA := A.Ptr($08800000, 512 * 512 * 4);
    B.WriteBytes($08800000, PA^, 512 * 512 * 4);
    var Compares := 0;
    for var Test := 0 to Count - 1 do
    begin
      S := Default(TGERaster);
      S.VRAM := @A.VRAM[0];
      S.FBFormat := Next(4);
      S.FBAddr := Targets[Next(Length(Targets))];
      S.FBStride := 512;
      S.ZAddr := $100000;
      S.ZStride := 512;
      S.ZPermutation := Permutations[Test mod Length(Permutations)];
      S.ScissorX1 := Next(32); S.ScissorX2 := 479 - Integer(Next(32));
      S.ScissorY1 := Next(16); S.ScissorY2 := 271 - Integer(Next(16));
      S.BandY2 := 1023;
      S.Gouraud := Next(4) <> 0;
      S.Flat := not S.Gouraud;
      S.Through := Next(2) = 0;
      S.MinZ := 0; S.MaxZ := 65535;
      S.DepthClamp := True;
      S.DepthTest := Next(2) = 0;
      S.DepthFunc := Next(8);
      S.DepthWrite := True;
      S.Blend := Next(2) = 0;
      S.BlendSrc := Next(11); S.BlendDst := Next(11); S.BlendOp := Next(6);
      S.FixA := Next($1000000); S.FixB := Next($1000000);
      S.AlphaTest := Next(3) = 0;
      S.AlphaFunc := Next(8); S.AlphaRef := 128; S.AlphaMask := 255;
      S.StencilTest := Next(9) = 0;
      S.StencilFunc := 1; S.StencilZPass := 4; S.StencilZFail := 3;
      S.StencilMask := 255; S.StencilRef := 255;
      S.ClearMode := Next(11) = 0;
      S.ClearColor := True; S.ClearStencil := True; S.ClearDepth := True;
      S.Dither := Next(7) = 0;
      for var I := 0 to 15 do S.DitherMatrix[I] := Integer(Next(16)) - 8;
      S.MaskRGB := Next($1000000) and $010101;
      S.MaskA := 0;
      S.Tex.Memory := A;
      S.Tex.Format := Next(8);
      S.Tex.Linear := Next(2) = 0;
      S.Tex.Clut := @Palette[0]; S.Tex.ClutFormat := Next(4); S.Tex.ClutMask := 255;
      S.Tex.LevelCount := 1;
      S.Tex.Levels[0].Addr := $08800000;
      S.Tex.Levels[0].Width := 512; S.Tex.Levels[0].Height := 512;
      S.Tex.Levels[0].BufWidth := 512;
      S.Tex.Levels[0].Size := 512 * 512 * 4;
      S.Tex.Levels[0].Ptr := A.Ptr($08800000, 512 * 512 * 4);
      S.Textured := Next(2) = 0;
      S.TexFunc := Next(5);
      S.TexAlpha := True;
      S.ColorDouble := Next(13) = 0;
      var VRAMTexture: Cardinal := $FFFFFFFF;
      case Next(23) of
        // Drawn alone: physical aliases, wrapped targets, short strides.
        0: S.ZAddr := $100;
        1: S.FBAddr := $1F0000;
        2: S.FBStride := 128;
        3: VRAMTexture := 0;
        // Textures from the targets other primitives draw.
        4..8: VRAMTexture := Targets[Next(Length(Targets))];
      end;
      if VRAMTexture <> $FFFFFFFF then
      begin
        S.Tex.Format := 3;
        S.Tex.Levels[0].Addr := $04000000 + VRAMTexture;
        S.Tex.Levels[0].Width := 128; S.Tex.Levels[0].Height := 128;
        S.Tex.Levels[0].BufWidth := 128;
        S.Tex.Levels[0].Size := 128 * 128 * 4;
        if VRAMTexture = 0 then
          S.Tex.Levels[0].Size := PSPVRAMSize;
        S.Tex.Levels[0].Ptr := @A.VRAM[VRAMTexture];
        S.Textured := True;
      end;
      GEPrepareRaster(S);
      T := S; T.VRAM := @B.VRAM[0]; T.Tex.Memory := B;
      if VRAMTexture <> $FFFFFFFF then
        T.Tex.Levels[0].Ptr := @B.VRAM[VRAMTexture]
      else
        T.Tex.Levels[0].Ptr := B.Ptr($08800000, 512 * 512 * 4);
      for var I := 0 to 2 do
      begin
        V[I] := Default(TGEVertex);
        V[I].X := Integer(Next(640 * 16)) - 80 * 16;
        V[I].Y := Integer(Next(400 * 16)) - 64 * 16;
        V[I].R := Next(256); V[I].G := Next(256); V[I].B := Next(256); V[I].A := Next(256);
        if Next(3) = 0 then
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
      Many.StateChanged;
      case Next(16) of
        0:
          begin
            One.Line(S, V[0], V[1]);
            Many.Line(T, V[0], V[1]);
          end;
        1:
          begin
            One.Point(S, V[0]);
            Many.Point(T, V[0]);
          end;
        2..7:
          begin
            One.Sprite(S, V[0], V[1]);
            Many.Sprite(T, V[0], V[1]);
          end;
      else
        One.Triangle(S, V[0], V[1], V[2]);
        Many.Triangle(T, V[0], V[1], V[2]);
      end;
      // A CLUT load: queued primitives keep the palette they were drawn with.
      if Next(5) = 0 then
      begin
        for var I := 0 to 63 do Palette[Next(1024)] := Next(256);
        Many.ClutChanged;
      end;
      // The GE stops: a large batch is drawn in the background meanwhile.
      if Next(6) = 0 then
        Many.Release;
      // The CPU rewrites a RAM texture or VRAM queued primitives use: the
      // queue must draw first (watched and held pages).
      case Next(12) of
        0:
          begin
            var Addr := $08800000 + Next(512 * 512 * 4) and not Cardinal(3);
            var Value := Next($7FFFFFFF);
            A.Write32(Addr, Value);
            B.Write32(Addr, Value);
          end;
        1:
          begin
            var Addr := $08800000 + Next(512 * 512 * 4 - 4096);
            var Bytes: array[0..255] of Byte;
            for var I := 0 to High(Bytes) do Bytes[I] := Next(256);
            A.WriteBytes(Addr, Bytes, SizeOf(Bytes));
            B.WriteBytes(Addr, Bytes, SizeOf(Bytes));
          end;
        2:
          begin
            var Addr := $04000000 + Next(PSPVRAMSize) and not Cardinal(3);
            var Value := Next($7FFFFFFF);
            A.Write32(Addr, Value);
            B.Write32(Addr, Value);
          end;
      end;
      if (Next(40) = 0) or (Test = Count - 1) then
      begin
        Many.Sync;
        Inc(Compares);
        if not CompareMem(@A.VRAM[0], @B.VRAM[0], PSPVRAMSize) then
          raise Exception.CreateFmt('VRAM differs after primitive %d', [Test]);
      end;
    end;
    Writeln(Format('PASS: %d primitives, %d whole-VRAM compares with 1 and 6 threads (%s)',
      [Count, Compares, Many.Describe]));
  finally
    Many.Free; One.Free;
    B.Free; A.Free;
  end;
end;

begin
  try
    Check(StrToIntDef(ParamStr(1), 4096));
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
