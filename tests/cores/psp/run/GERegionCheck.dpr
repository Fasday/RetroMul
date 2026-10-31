program GERegionCheck;

{$APPTYPE CONSOLE}

// REGION is independent of SCISSOR. In MHP3rd, scissor includes row 272
// while REGION ends at 271. An escaped depth write hits the vertex arena
// immediately after the depth buffer, deforming later skinned primitives.
// Compare every VRAM byte against independently constructed clipped writes.

uses
  System.SysUtils, Winapi.Windows, PSP.Types, PSP.Memory, PSP.GE.Types,
  PSP.GE.Engine, PSP.GE.VulkanLLE;

type
  TInputVertex = record
    Color: Cardinal;
    X, Y, Z: Single;
  end;

const
  Widths: array[0..4] of Cardinal = (0, 512, 1024, 2048, 4096);
  Source = $08800000;
  DepthBase = $88000;
  DepthValue = $4567;

var
  M: TPSPMemory;
  E: TPSPGEEngine;
  GPU: TGEVulkanLLEBackend;
  Expected: TBytes;
  Cases: Integer;

procedure Sync;
begin
  E.Workers.Sync;
  if GPU <> nil then GPU.Sync;
end;

procedure ResetBytes;
begin
  Sync;
  FillChar(M.VRAM[0], PSPVRAMSize, $CD);
  FillChar(Expected[0], PSPVRAMSize, $CD);
end;

function XY(X, Y: Cardinal): Cardinal;
begin
  Result := X or (Y shl 10);
end;

procedure Setup(Format, Width: Cardinal; Clear: Boolean);
begin
  Sync;
  E.Reset;
  M.SetVRAMTranslation(Width);
  E.Regs.Cmd[GE_VTYPE] := (1 shl 23) or (3 shl 7) or (7 shl 2);
  E.Regs.VAddr := Source;
  E.Regs.Cmd[GE_FRAMEBUFPTR] := 0;
  E.Regs.Cmd[GE_FRAMEBUFWIDTH] := 512;
  E.Regs.Cmd[GE_FRAMEBUFPIXFORMAT] := Format;
  E.Regs.Cmd[GE_ZBUFPTR] := DepthBase;
  // 8888 occupies twice the colour bytes: keep even the widest permuted
  // depth bank disjoint, so this test does not depend on alias draw order.
  if Format = 3 then E.Regs.Cmd[GE_ZBUFPTR] := $100000;
  E.Regs.Cmd[GE_ZBUFWIDTH] := 512;
  E.Regs.Cmd[GE_SCISSOR1] := 0;
  E.Regs.Cmd[GE_SCISSOR2] := XY(480, 272);
  E.Regs.Cmd[GE_REGION1] := 0;
  E.Regs.Cmd[GE_REGION2] := XY(479, 271);
  E.Regs.Cmd[GE_ZTESTENABLE] := 1;
  E.Regs.Cmd[GE_ZTEST] := 1; // Always; depth writes enabled.
  E.Regs.Cmd[GE_ZWRITEDISABLE] := 0;
  E.Regs.Cmd[GE_MAXZ] := 65535;
  E.Regs.Cmd[GE_SHADEMODE] := 1;
  if Clear then E.Regs.Cmd[GE_CLEARMODE] := $501; // Colour + depth, retain stencil.
  ResetBytes;
end;

procedure ExpectPixel(X, Y: Integer);
begin
  var Format := E.Regs.Cmd[GE_FRAMEBUFPIXFORMAT];
  var Offset := (Y * 512 + X) * 2;
  case Format of
    0: PWord(@Expected[Offset])^ := $07E0;
    1: PWord(@Expected[Offset])^ := $83E0; // Preserve old stencil bit.
    2: PWord(@Expected[Offset])^ := $C0F0;
    3: PCardinal(@Expected[Offset * 2])^ := $CD00FF00;
  end;
  var ZOffset := PSPDepthOffset(E.Regs.Cmd[GE_ZBUFPTR] + Cardinal((Y * 512 + X) * 2), M.VRAMShift);
  PWord(@Expected[ZOffset])^ := DepthValue;
end;

procedure ExpectRectangle;
begin
  var C := E.Regs.Cmd;
  var X1 := Integer(C[GE_SCISSOR1] and $3FF);
  var Y1 := Integer((C[GE_SCISSOR1] shr 10) and $3FF);
  var X2 := Integer(C[GE_SCISSOR2] and $3FF);
  var Y2 := Integer((C[GE_SCISSOR2] shr 10) and $3FF);
  if X1 < Integer(C[GE_REGION1] and $3FF) then X1 := C[GE_REGION1] and $3FF;
  if Y1 < Integer((C[GE_REGION1] shr 10) and $3FF) then Y1 := (C[GE_REGION1] shr 10) and $3FF;
  if X2 > Integer(C[GE_REGION2] and $3FF) then X2 := C[GE_REGION2] and $3FF;
  if Y2 > Integer((C[GE_REGION2] shr 10) and $3FF) then Y2 := (C[GE_REGION2] shr 10) and $3FF;
  for var Y := Y1 to Y2 do
    for var X := X1 to X2 do ExpectPixel(X, Y);
end;

procedure Draw(Kind: Integer; const Vertices: array of TInputVertex);
begin
  M.WriteBytes(Source, Vertices[0], Length(Vertices) * SizeOf(TInputVertex));
  E.Regs.VAddr := Source;
  E.Execute((GE_PRIM shl 24) or Cardinal(Kind shl 16) or Cardinal(Length(Vertices)), 0);
  E.ReleaseBackend;
  Sync;
end;

procedure Verify(const Name: string);
begin
  Inc(Cases);
  for var I := 0 to PSPVRAMSize - 1 do
    if M.VRAM[I] <> Expected[I] then
      raise Exception.CreateFmt('%s: VRAM differs at %.6x (got %.2x, expected %.2x)',
        [Name, I, M.VRAM[I], Expected[I]]);
end;

procedure Rectangle(Kind: Integer);
var
  V: array[0..3] of TInputVertex;
begin
  for var I := 0 to 3 do
  begin
    V[I].Color := $FF00FF00;
    V[I].Z := DepthValue;
    if I and 1 = 0 then V[I].X := -8 else V[I].X := 520;
    if I < 2 then V[I].Y := -8 else V[I].Y := 300;
  end;
  if Kind = 6 then Draw(6, [V[0], V[3]]) else Draw(4, V);
  ExpectRectangle;
  Verify('Region-clipped rectangle');
end;

procedure Check;
begin
  for var Width in Widths do
    for var Format := 0 to 3 do
    begin
      for var Clear := 0 to 1 do
        for var Kind in [4, 6] do
        begin
          Setup(Format, Width, Clear <> 0);
          Rectangle(Kind);
          // Change only REGION: BuildRaster's cached key must include it.
          ResetBytes;
          E.Regs.Cmd[GE_REGION1] := XY(10, 20);
          E.Regs.Cmd[GE_REGION2] := XY(199, 149);
          E.Regs.Cmd[GE_SCISSOR1] := XY(20, 10);
          Rectangle(Kind);
          ResetBytes;
          E.Regs.Cmd[GE_REGION1] := XY(100, 100);
          E.Regs.Cmd[GE_REGION2] := XY(50, 50);
          Rectangle(Kind); // Empty intersection: do not touch VRAM.
        end;
      Setup(Format, Width, False);
      var V := Default(TInputVertex);
      V.Color := $FF00FF00; V.Z := DepthValue;
      V.X := 480; V.Y := 10;
      Draw(0, [V]);
      Verify('Point beyond region right edge');
      V.X := 10; V.Y := 272;
      Draw(0, [V]);
      Verify('Point beyond region bottom edge');
      V.X := 479; V.Y := 271;
      Draw(0, [V]);
      ExpectPixel(479, 271);
      Verify('Point on last valid pixel');
      ResetBytes;
      V.X := 480; V.Y := 0;
      var W := V; W.Y := 272;
      Draw(1, [V, W]);
      Verify('Line beyond region right edge');
    end;
end;

begin
  try
    if SameText(ParamStr(1), '-serial') then SetEnvironmentVariable('PSP_GE_THREADS', '1');
    M := TPSPMemory.Create;
    E := TPSPGEEngine.Create(M);
    SetLength(Expected, PSPVRAMSize);
    try
      if SameText(ParamStr(1), '-gpu') then
      begin
        var Error: string;
        if not CreateGEVulkanLLEBackend(M, False, GPU, Error) then raise Exception.Create('GPU required: ' + Error);
        E.Backend := GPU;
      end;
      Check;
      Writeln(Format('PASS: %d full-VRAM region/scissor checks, all formats and five depth layouts', [Cases]));
    finally
      Sync;
      E.Backend := nil;
      GPU.Free; E.Free; M.Free;
    end;
  except
    on X: Exception do
    begin
      Writeln(X.ClassName + ': ' + X.Message);
      ExitCode := 1;
    end;
  end;
end.
