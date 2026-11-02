program PSPRun;

{$APPTYPE CONSOLE}

// Runs a PSP program headless.
// PSPRun <file> [-frames N] [-out dir] [-every N] [-press btn@frame:len] [-log] [-test] [-quiet] [-strict]
// -from N: with -every, frames (hashes, -out) from frame N on.
// -lang N: the system language games read (sceUtility's PSP_SYSTEMPARAM_LANGUAGE_*, 1 English, 8 Russian).
// -gpu / -gpu-check: Vulkan compute rendering / CPU differential checking.
// -gpu-hle [-scale N]: Vulkan graphics-pipeline rendering (fast, not bit exact), N times the PSP's resolution;
// frames (-out, hashes) are then the renderer's at that resolution. -fixed-blend: no blending in the shader.
// -texscale N [-texfilter xbrz|hybrid|bicubic]: with -gpu-hle above 1x, textures made N times larger
// (2 to 6, texture scaling) with that filter.
// -test: isolated pspautotests host0: tree, no display, stops at exit.
// -hw: omit the emulator device and collect the program's host0: output and screenshot.
// -wav file: saves the sound output (44.1 kHz stereo); with -every, prints its level per interval.
// -calls [a,b,...]: at the end, how often each HLE function was called (names containing a, b, ...).
// -memstick dir: explicit persistent test memory stick (never deleted by the runner).
// -no-memstick: the configured removable card is ejected (its files are not deleted).
// -stick x,y@frame:length: signed analogue axes (-32768..32767), input only.

uses
  Winapi.Windows, System.SysUtils, System.Math, System.Classes, System.IOUtils, System.Hash, System.Diagnostics, System.Generics.Collections,
  Core.Emulation.Types, PSP.Types, PSP.Media, PSP.CPU, PSP.Console, PSP.Kernel, PSP.HLE, PSP.Loader, PSP.GE, PSP.GE.VulkanLLE,
  PSP.GE.VulkanHLE, PSP.GE.TexScale, PSP.Settings;

type
  TPress = record
    Button: TEmulatorButton;
    Frame, Length: Integer;
    Analog: Boolean;
    X, Y: SmallInt;
  end;

  TLogSink = class
    Echo: Boolean;
    Console: TPSPConsole;
    ShotFile: string;
    Shots: Integer;
    procedure Log(const S: string);
    procedure Screenshot;
  end;

procedure TLogSink.Log(const S: string);
begin
  if Echo then
    Writeln(ErrOutput, '[hle] ', S);
end;

procedure TLogSink.Screenshot;
begin
  Inc(Shots);
  if ShotFile = '' then
    Exit;
  var Data := Console.Display.ScreenshotBMP;
  var Name := ShotFile;
  if Shots > 1 then
    Name := ChangeFileExt(ShotFile, '') + '.' + IntToStr(Shots) + ExtractFileExt(ShotFile);
  TFile.WriteAllBytes(Name, Data);
end;

function IsTestOutput(const Name: string): Boolean;
begin
  var FileName := ExtractFileName(Name).ToLower;
  Result := (FileName = '__testoutput.txt') or (FileName = '__testerror.txt') or
    (FileName = '__testfinish.txt') or (FileName = '__screenshot.bmp');
end;

procedure StageReferencedTestInputs(const Image: TBytes; const SourceDir, SuiteDir, Overlay: string);
var
  Suite, Parent: string;
  procedure CopyInput(const Source: string);
  begin
    if IsTestOutput(Source) then Exit;
    var Target := TPath.Combine(Overlay, Source.Substring(Parent.Length));
    if FileExists(Target) then Exit;
    ForceDirectories(ExtractFileDir(Target));
    TFile.Copy(Source, Target, True);
  end;
  procedure Reference(const S: string);
  begin
    if not S.Contains('/') and not S.Contains('\') then Exit;
    var Name := S.Replace('\', '/');
    var Base := SourceDir;
    if Name.StartsWith('host0:', True) then begin Name := Name.Substring(6); Base := Parent; end
    else if Name.StartsWith('host:', True) then begin Name := Name.Substring(5); Base := Parent; end
    else if Name.Contains(':') then Exit;
    if Name.StartsWith('/') then begin Name := Name.Substring(1); Base := Parent; end;
    try Name := TPath.GetFullPath(TPath.Combine(Base, Name.Replace('/', PathDelim)));
    except on E: EArgumentException do Exit; end;
    // Only existing suite inputs may be copied. Never invent a missing file or
    // resolve a binary string outside this read-only fixture tree.
    if not Name.StartsWith(Suite, True) and not SameText(Name, ExcludeTrailingPathDelimiter(Suite)) then Exit;
    if FileExists(Name) then CopyInput(Name)
    else if DirectoryExists(Name) then
      for var FileName in TDirectory.GetFiles(Name, '*', TSearchOption.soAllDirectories) do CopyInput(FileName);
  end;
begin
  Suite := IncludeTrailingPathDelimiter(TPath.GetFullPath(SuiteDir));
  Parent := IncludeTrailingPathDelimiter(ExtractFileDir(ExcludeTrailingPathDelimiter(Suite)));
  // Null-terminated path literals in the actual ELF declare cross-group data
  // such as ../../modules/*.prx or ../../audio/atrac/*.at3. Stage the unchanged
  // inputs alongside the usual group data, without copying 124 MiB per run.
  var I := 0;
  while I < Length(Image) do
  begin
    var Start := I;
    while (I < Length(Image)) and (Image[I] >= 32) and (Image[I] < 127) do Inc(I);
    var N := I - Start;
    if (I < Length(Image)) and (Image[I] = 0) and (N >= 3) and (N <= 1024) then
      Reference(TEncoding.ASCII.GetString(Image, Start, N));
    Inc(I);
  end;
end;

type
  TWatch = class(TThread)
    Console: TPSPConsole;
    procedure Execute; override;
  end;

procedure TWatch.Execute;
begin
  while not Terminated do
  begin
    Sleep(2000);
    if Terminated then
      Break;
    Writeln(ErrOutput, Format('[watch] pc=%.8x now=%d next=%d busy=%d thread=%s', [Console.CPU.CurPC, Console.Scheduler.Now div 1000,
      Console.Scheduler.NextDue div 1000, Console.Kernel.BusyUntil div 1000, PSPThreadName(Console.Kernel.Current)]));
  end;
end;

type
  // The interpreter loop, keeping the last instructions run (-history N).
  THistoryEntry = record
    PC, Op, RA, SP, V0, A0: Cardinal;
    Thread: Cardinal;
  end;

  THistoryRunner = class(TPSPRunner)
    Console: TPSPConsole;
    Ring: TArray<THistoryEntry>;
    Head: Integer;
    Count: Int64;
    procedure Run(C: TPSPCPU); override;
    procedure CodeWritten(Address, Size: Cardinal); override;
    procedure Flushed; override;
    procedure Dump;
  end;

procedure THistoryRunner.Run(C: TPSPCPU);
begin
  while C.FRemaining > 0 do
  begin
    var PC := C.Ctx.PC;
    var Entry := C.Decoded(PC);
    var H: ^THistoryEntry := @Ring[Head];
    H.PC := PC;
    H.Op := Entry.Op;
    H.RA := C.Ctx.GPR[31];
    H.SP := C.Ctx.GPR[29];
    H.V0 := C.Ctx.GPR[2];
    H.A0 := C.Ctx.GPR[4];
    if Console.Kernel.Current <> nil then
      H.Thread := Console.Kernel.Current.UID
    else
      H.Thread := 0;
    Head := (Head + 1) mod Length(Ring);
    Inc(Count);
    C.CurPC := PC;
    C.Ctx.PC := C.Ctx.NPC;
    C.Ctx.NPC := C.Ctx.NPC + 4;
    Dec(C.FRemaining);
    Entry.Handler(C, Entry.Op);
    if C.Stopping then
      Break;
  end;
end;

procedure THistoryRunner.CodeWritten(Address, Size: Cardinal);
begin
end;

procedure THistoryRunner.Flushed;
begin
end;

procedure THistoryRunner.Dump;
begin
  var N := Min(Count, Int64(Length(Ring)));
  for var I := N downto 1 do
  begin
    var H := Ring[(Head - I + Length(Ring) * 2) mod Length(Ring)];
    Writeln(ErrOutput, Format('[hist] %.8x %.8x ra=%.8x sp=%.8x v0=%.8x a0=%.8x th=%x', [H.PC, H.Op, H.RA, H.SP, H.V0, H.A0, H.Thread]));
  end;
end;

function ButtonOf(const S: string): TEmulatorButton;
begin
  var L := S.ToLower;
  if L = 'up' then Exit(TEmulatorButton.Up);
  if L = 'down' then Exit(TEmulatorButton.Down);
  if L = 'left' then Exit(TEmulatorButton.Left);
  if L = 'right' then Exit(TEmulatorButton.Right);
  if (L = 'cross') or (L = 'x') then Exit(TEmulatorButton.A);
  if (L = 'circle') or (L = 'o') then Exit(TEmulatorButton.B);
  if L = 'select' then Exit(TEmulatorButton.Select);
  if L = 'start' then Exit(TEmulatorButton.Start);
  if L = 'l' then Exit(TEmulatorButton.C);
  if L = 'square' then Exit(TEmulatorButton.X);
  if L = 'triangle' then Exit(TEmulatorButton.Y);
  if L = 'r' then Exit(TEmulatorButton.Z);
  raise Exception.Create('unknown button ' + S);
end;

function FrameHash(const F: TEmulatorFrame): string;
begin
  var H := THashSHA2.Create;
  if Length(F.Pixels) > 0 then
    H.Update(F.Pixels[0], Length(F.Pixels) * 4);
  Result := H.HashAsString.Substring(0, 16);
end;

procedure SaveBMP(const F: TEmulatorFrame; const Name: string);
begin
  // Nothing displayed yet.
  if Length(F.Pixels) < F.Width * F.Height then
    Exit;
  var S := TFileStream.Create(Name, fmCreate);
  try
    var RowSize := F.Width * 3;
    var Pad := (4 - RowSize mod 4) mod 4;
    var DataSize := (RowSize + Pad) * F.Height;
    var Header: array[0..53] of Byte;
    FillChar(Header, SizeOf(Header), 0);
    Header[0] := Ord('B');
    Header[1] := Ord('M');
    PCardinal(@Header[2])^ := 54 + DataSize;
    PCardinal(@Header[10])^ := 54;
    PCardinal(@Header[14])^ := 40;
    PInteger(@Header[18])^ := F.Width;
    PInteger(@Header[22])^ := F.Height;
    PWord(@Header[26])^ := 1;
    PWord(@Header[28])^ := 24;
    PCardinal(@Header[34])^ := DataSize;
    S.WriteBuffer(Header, 54);
    var Row: TBytes;
    SetLength(Row, RowSize + Pad);
    for var Y := F.Height - 1 downto 0 do
    begin
      for var X := 0 to F.Width - 1 do
      begin
        var C := F.Pixels[Y * F.Width + X];
        Row[X * 3] := C and $FF;
        Row[X * 3 + 1] := (C shr 8) and $FF;
        Row[X * 3 + 2] := (C shr 16) and $FF;
      end;
      S.WriteBuffer(Row[0], Length(Row));
    end;
  finally
    S.Free;
  end;
end;

procedure SaveWAV(const Samples: TList<SmallInt>; const Name: string);
begin
  var S := TFileStream.Create(Name, fmCreate);
  try
    var DataSize := Cardinal(Samples.Count) * 2;
    var Header: array[0..43] of Byte;
    FillChar(Header, SizeOf(Header), 0);
    Move(AnsiString('RIFF')[1], Header[0], 4);
    PCardinal(@Header[4])^ := 36 + DataSize;
    Move(AnsiString('WAVEfmt ')[1], Header[8], 8);
    PCardinal(@Header[16])^ := 16;
    PWord(@Header[20])^ := 1;
    PWord(@Header[22])^ := 2;
    PCardinal(@Header[24])^ := 44100;
    PCardinal(@Header[28])^ := 44100 * 4;
    PWord(@Header[32])^ := 4;
    PWord(@Header[34])^ := 16;
    Move(AnsiString('data')[1], Header[36], 4);
    PCardinal(@Header[40])^ := DataSize;
    S.WriteBuffer(Header, SizeOf(Header));
    if Samples.Count > 0 then
      S.WriteBuffer(Samples.List[0], DataSize);
  finally
    S.Free;
  end;
end;

begin
  try
    if ParamCount < 1 then
    begin
      Writeln('PSPRun <file> [-frames N] [-out dir] [-every N] [-press btn@frame:len] [-log] [-test] [-no-memstick] [-quiet] [-strict]');
      Halt(2);
    end;
    var FileName := ExpandFileName(ParamStr(1));
    var Frames := 600;
    var OutDir := '';
    var Every := 0;
    var FromFrame := 0;
    var Lang := -1;
    var MemstickOverride := '';
    var NoMemstick := False;
    var FontDirectory := '';
    var Presses := TList<TPress>.Create;
    var EchoLog := False;
    var TestMode := False;
    var Quiet := False;
    var Strict := False;
    var TraceKernel := False;
    var WatchOn := False;
    var ShowState := False;
    var HwMode := False;
    var HistoryLen := 0;
    var DumpAt: Cardinal := 0;
    var DumpLen := 0;
    var ShotFile := '';
    var GPUMode := 0;
    var Scale := 1;
    var TexScale := 0;
    var TexFilter := tfXBRZ;
    var FixedBlend := False;
    var VRAMFile := '';
    var WavFile := '';
    var CallsOn := False;
    var CallsFilter := '';
    var I := 2;
    while I <= ParamCount do
    begin
      var A := ParamStr(I);
      if A = '-frames' then begin Inc(I); Frames := StrToInt(ParamStr(I)); end
      else if A = '-out' then begin Inc(I); OutDir := ParamStr(I); end
      else if A = '-memstick' then begin Inc(I); MemstickOverride := ExpandFileName(ParamStr(I)); end
      else if A = '-no-memstick' then NoMemstick := True
      else if A = '-fontdir' then begin Inc(I); FontDirectory := ParamStr(I); end
      else if A = '-every' then begin Inc(I); Every := StrToInt(ParamStr(I)); end
      else if A = '-from' then begin Inc(I); FromFrame := StrToInt(ParamStr(I)); end
      else if A = '-lang' then begin Inc(I); Lang := StrToInt(ParamStr(I)); end
      else if A = '-log' then EchoLog := True
      else if A = '-test' then TestMode := True
      else if A = '-quiet' then Quiet := True
      else if A = '-strict' then Strict := True
      else if A = '-trace' then TraceKernel := True
      else if A = '-watch' then WatchOn := True
      else if A = '-state' then ShowState := True
      else if A = '-hw' then HwMode := True
      else if A = '-history' then begin Inc(I); HistoryLen := StrToInt(ParamStr(I)); end
      else if A = '-dump' then begin Inc(I); DumpAt := StrToInt('$' + ParamStr(I)); Inc(I); DumpLen := StrToInt(ParamStr(I)); end
      else if A = '-shot' then begin Inc(I); ShotFile := ParamStr(I); end
      else if A = '-gpu' then GPUMode := 1
      else if A = '-gpu-check' then GPUMode := 2
      else if A = '-gpu-hle' then GPUMode := 3
      else if A = '-scale' then begin Inc(I); Scale := StrToInt(ParamStr(I)); end
      else if A = '-texscale' then begin Inc(I); TexScale := StrToInt(ParamStr(I)); end
      else if A = '-texfilter' then begin Inc(I); TexFilter := GETextureFilterFromName(ParamStr(I)); end
      else if A = '-fixed-blend' then FixedBlend := True
      else if A = '-vram' then begin Inc(I); VRAMFile := ParamStr(I); end
      else if A = '-wav' then begin Inc(I); WavFile := ParamStr(I); end
      else if A = '-calls' then begin CallsOn := True; if (I < ParamCount) and not ParamStr(I + 1).StartsWith('-') then begin Inc(I); CallsFilter := ParamStr(I); end; end
      else if A = '-press' then
      begin
        Inc(I);
        var Spec := ParamStr(I);
        var At := Spec.IndexOf('@');
        var Colon := Spec.IndexOf(':');
        var P := Default(TPress);
        P.Button := ButtonOf(Spec.Substring(0, At));
        if Colon > 0 then
        begin
          P.Frame := StrToInt(Spec.Substring(At + 1, Colon - At - 1));
          P.Length := StrToInt(Spec.Substring(Colon + 1));
        end
        else
        begin
          P.Frame := StrToInt(Spec.Substring(At + 1));
          P.Length := 6;
        end;
        Presses.Add(P);
      end;
      if A = '-stick' then
      begin
        Inc(I);
        var Spec := ParamStr(I);
        var Comma := Spec.IndexOf(',');
        var At := Spec.IndexOf('@');
        var Colon := Spec.IndexOf(':');
        if (Comma <= 0) or (At <= Comma) or (Colon <= At) then
          raise EArgumentException.Create('Expected -stick x,y@frame:length');
        var X := StrToInt(Spec.Substring(0, Comma));
        var Y := StrToInt(Spec.Substring(Comma + 1, At - Comma - 1));
        if (X < -32768) or (X > 32767) or (Y < -32768) or (Y > 32767) then
          raise EArgumentOutOfRangeException.Create('Stick axes must be -32768..32767');
        var P := Default(TPress);
        P.Analog := True; P.X := X; P.Y := Y;
        P.Frame := StrToInt(Spec.Substring(At + 1, Colon - At - 1));
        P.Length := StrToInt(Spec.Substring(Colon + 1));
        Presses.Add(P);
      end;
      Inc(I);
    end;
    if OutDir <> '' then
      ForceDirectories(OutDir);
    var Ext := ExtractFileExt(FileName).ToLower;
    var Prog: TPSPProgram;
    var Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
    try
      Prog := TPSPProgram.Read(Stream);
    finally
      Stream.Free;
    end;
    if (Ext = '.iso') or (Ext = '.cso') then
      Prog.MediaPath := FileName;
    // Every run gets its own memory stick, and tests a copy of their folder as host0:,
    // so runs in parallel do not see each other's files.
    var Scratch := TPath.Combine(TPath.GetTempPath, Format('psprun-%d-%s', [GetCurrentProcessId, TGUID.NewGuid.ToString]));
    var HostRoot := ExtractFileDir(FileName);
    var Memstick := TPath.Combine(Scratch, 'ms0');
    if MemstickOverride <> '' then Memstick := MemstickOverride;
    if TestMode then
    begin
      // host0:/ is the test suite's root on hardware (usbhostfs): the test's
      // folder is copied to the same place under the scratch root.
      var Host := TPath.Combine(Scratch, 'host0');
      var Rel := '';
      var At := HostRoot.ToLower.LastIndexOf('\tests\');
      if At >= 0 then
        Rel := HostRoot.Substring(At + 1);
      var Dest := Host;
      if Rel <> '' then
        Dest := TPath.Combine(Host, Rel);
      // Tests also read data next to their folder (../sample.at3, ../mp3/sample.mp3): the data
      // files of the whole test group (tests/<group>) come along, including PRX
      // fixtures loaded by other programs. Never fabricate a successful load
      // when an isolated fixture was accidentally omitted.
      var Parts := Rel.Split(['\'], TStringSplitOptions.ExcludeEmpty);
      if Length(Parts) >= 2 then
      begin
        var GroupDir := TPath.Combine(HostRoot.Substring(0, At + 1), Parts[0] + '\' + Parts[1]);
        for var F in TDirectory.GetFiles(GroupDir, '*', TSearchOption.soAllDirectories) do
        begin
          if IsTestOutput(F) then Continue;
          var X := ExtractFileExt(F).ToLower;
          if (X = '.c') or (X = '.cpp') or (X = '.h') or (X = '.expected') or (X = '.bmp') or
            (X = '.mak') or (X = '.s') or (X = '.exp') or SameText(ExtractFileName(F), 'Makefile') then
            Continue;
          var Target := TPath.Combine(Host, F.Substring(At + 1));
          ForceDirectories(ExtractFileDir(Target));
          TFile.Copy(F, Target, True);
        end;
      end;
      ForceDirectories(Dest);
      for var F in TDirectory.GetFiles(HostRoot, '*', TSearchOption.soAllDirectories) do
      begin
        if IsTestOutput(F) then Continue;
        var Target := TPath.Combine(Dest, F.Substring(HostRoot.Length + 1));
        ForceDirectories(ExtractFileDir(Target));
        TFile.Copy(F, Target, True);
      end;
      if At >= 0 then
        StageReferencedTestInputs(Prog.Executable, HostRoot, TPath.Combine(HostRoot.Substring(0, At + 1), 'tests'), Host);
      HostRoot := Host;
      if Rel <> '' then
        Prog.BootPath := 'host0:/' + Rel.Replace('\', '/') + '/' + ExtractFileName(FileName)
      else
        Prog.BootPath := 'host0:/' + ExtractFileName(FileName);
    end;
    var Sink := TLogSink.Create;
    Sink.Echo := EchoLog;
    // The console takes the system settings when it is made.
    if Lang >= 0 then
      PSPSettings.Language := Lang;
    var Console := TPSPConsole.Create(Prog, nil, HostRoot, Memstick, FontDirectory);
    Console.IO.MemstickInserted := not NoMemstick;
    var Watcher: TWatch := nil;
    var History: THistoryRunner := nil;
    var OriginalRunner := Console.CPU.Runner;
    var Wav := TList<SmallInt>.Create;
    var GPU: TGEVulkanLLEBackend := nil;
    var HLE: TGEVulkanHLEBackend := nil;
    try
      if GPUMode = 3 then
      begin
        var Error: string;
        if CreateGEVulkanHLEBackend(Console.Memory, HLE, Error, '', Scale, not FixedBlend) then
        begin
          HLE.TextureScale := TexScale;
          HLE.TextureFilter := TexFilter;
          Console.OnPresent := HLE.Present;
          TPSPGE(Console.System.Find(TPSPGE)).Engine.Backend := HLE;
          if not Quiet then
            Writeln(ErrOutput, 'gpu hle: ' + HLE.Compute.Name + ', shader blending ' + BoolToStr(HLE.ShaderBlend, True));
        end
        else
          Writeln(ErrOutput, 'gpu hle: unavailable (' + Error + '), the GE draws on the CPU');
      end
      else if GPUMode > 0 then
      begin
        var Error: string;
        if CreateGEVulkanLLEBackend(Console.Memory, GPUMode = 2, GPU, Error) then
        begin
          GPU.OnMessage :=
            procedure(const Text: string)
            begin
              Writeln(ErrOutput, Text);
            end;
          TPSPGE(Console.System.Find(TPSPGE)).Engine.Backend := GPU;
          if not Quiet then
            Writeln(ErrOutput, 'gpu: ' + GPU.Compute.Name + ', ' + GPU.Describe);
        end
        else
          Writeln(ErrOutput, 'gpu: unavailable (' + Error + '), the GE draws on the CPU');
      end;
      Console.OnLog := Sink.Log;
      Sink.Console := Console;
      Sink.ShotFile := ShotFile;
      Console.IO.OnScreenshot := Sink.Screenshot;
      if WatchOn then
      begin
        Watcher := TWatch.Create(True);
        Watcher.Console := Console;
        Watcher.FreeOnTerminate := False;
        Watcher.Start;
      end;
      Console.HLE.Strict := Strict;
      Console.Kernel.Trace := TraceKernel;
      Console.HLE.TraceCalls := TraceKernel;
      Console.HLE.NoClobber := GetEnvironmentVariable('PSP_NOCLOBBER') <> '';
      if TestMode then
        Console.IO.HasDisplay := False;
      Console.IO.NoEmulatorDevice := HwMode;
      if HistoryLen > 0 then
      begin
        History := THistoryRunner.Create;
        History.Console := Console;
        SetLength(History.Ring, HistoryLen);
        Console.CPU.Runner := History;
      end;
      if not Quiet then
        Writeln(ErrOutput, Format('title=%s id=%s', [Prog.Title, Prog.DiscId]));
      var Watch := TStopwatch.StartNew;
      var Frame: TEmulatorFrame;
      var LastHash := '';
      var Failed := '';
      var Peak := 0;
      var SumSq: Double := 0;
      var SumN: Int64 := 0;
      for var F := 1 to Frames do
      begin
        var Input := Default(TEmulatorInput);
        for var P in Presses do
          if (F >= P.Frame) and (F < P.Frame + P.Length) then
            if P.Analog then
            begin
              Input.Analog[0].Valid := True;
              Input.Analog[0].X := P.X;
              Input.Analog[0].Y := P.Y;
            end
            else
              Include(Input.Buttons, P.Button);
        Console.Input := Input;
        try
          Console.RunFrame(Frame);
        except
          on E: Exception do
          begin
            Failed := E.ClassName + ': ' + E.Message + Format(' at %p (image base %p)', [ExceptAddr, Pointer(HInstance)]);
            Break;
          end;
        end;
        var Text := Console.TakeOutput;
        if Text <> '' then
          Write(Text);
        if WavFile <> '' then
          for var Smp in Console.AudioSamples do
          begin
            Wav.Add(Smp);
            Peak := Max(Peak, Abs(Integer(Smp)));
            SumSq := SumSq + Sqr(Double(Smp));
            Inc(SumN);
          end;
        if (Every > 0) and (F >= FromFrame) and (F mod Every = 0) then
        begin
          var H := FrameHash(Frame);
          if not Quiet then
          begin
            if WavFile <> '' then
            begin
              var Rms := 0.0;
              if SumN > 0 then
                Rms := Sqrt(SumSq / SumN);
              Writeln(ErrOutput, Format('frame %d hash %s audio peak %d rms %.0f host=%.3fs guest=%.3fs',
                [F, H, Peak, Rms, Watch.Elapsed.TotalSeconds, Console.Scheduler.Now / 1e9]));
              Peak := 0;
              SumSq := 0;
              SumN := 0;
            end
            else
              Writeln(ErrOutput, Format('frame %d hash %s host=%.3fs guest=%.3fs',
                [F, H, Watch.Elapsed.TotalSeconds, Console.Scheduler.Now / 1e9]));
          end;
          if OutDir <> '' then
            SaveBMP(Frame, TPath.Combine(OutDir, Format('f%.5d.bmp', [F])));
        end;
        if Console.Kernel.Exited then
          Break;
      end;
      // Everything queued is drawn before VRAM is saved.
      if GPU <> nil then
        GPU.Sync
      else if HLE <> nil then
        HLE.Sync
      else
        TPSPGE(Console.System.Find(TPSPGE)).Engine.Workers.Sync;
      if VRAMFile <> '' then
        TFile.WriteAllBytes(VRAMFile, Console.Memory.VRAM);
      LastHash := FrameHash(Frame);
      var Text := Console.TakeOutput;
      if Text <> '' then
        Write(Text);
      if OutDir <> '' then
        SaveBMP(Frame, TPath.Combine(OutDir, 'last.bmp'));
      if HwMode then
      begin
        // As recorded on hardware: the program wrote its output and screenshot to host0:.
        var OutName := TPath.Combine(HostRoot, '__testoutput.txt');
        if FileExists(OutName) then
        begin
          // The guest may leave stdout open when it exits.
          var Output := TFileStream.Create(OutName, fmOpenRead or fmShareDenyNone);
          try
            var Bytes: TBytes;
            SetLength(Bytes, Output.Size);
            if Length(Bytes) > 0 then
            begin
              Output.ReadBuffer(Bytes[0], Length(Bytes));
              Write(TEncoding.ANSI.GetString(Bytes));
            end;
          finally
            Output.Free;
          end;
        end;
        var ShotName := TPath.Combine(HostRoot, '__screenshot.bmp');
        if (ShotFile <> '') and FileExists(ShotName) then
          TFile.Copy(ShotName, ShotFile, True);
      end;
      if History <> nil then
        History.Dump;
      if ShowState then
      begin
        Writeln(ErrOutput, Console.Kernel.DescribeThreads);
        Writeln(ErrOutput, Console.Loader.Describe);
      end;
      for var K := 0 to DumpLen div 4 - 1 do
        Writeln(ErrOutput, Format('[dump] %.8x %.8x', [DumpAt + Cardinal(K) * 4, Console.Memory.Read32(DumpAt + Cardinal(K) * 4)]));
      if CallsOn then
        for var K := 0 to Console.HLE.Count - 1 do
        begin
          var Fn := Console.HLE.FunctionInfo(K);
          if (Fn = nil) or (Fn.Calls = 0) then
            Continue;
          var Show := CallsFilter = '';
          for var Part in CallsFilter.Split([',']) do
            if (Part <> '') and Fn.Name.ToLower.Contains(Part.ToLower) then
              Show := True;
          if Show then
            Writeln(ErrOutput, Format('[calls] %s %d', [Fn.Name, Fn.Calls]));
        end;
      if WavFile <> '' then
        SaveWAV(Wav, WavFile);
      if not Quiet then
        Writeln(ErrOutput, Format('frames=%d time=%.2fs guest=%.2fs exited=%s hash=%s cpu=%.1fM (%.1f MHz host)',
          [Console.FrameNumber, Watch.Elapsed.TotalSeconds, Console.Scheduler.Now / 1e9,
          BoolToStr(Console.Kernel.Exited, True), LastHash, Console.Executed / 1e6,
          Console.Executed / 1e6 / Max(0.001, Watch.Elapsed.TotalSeconds)]));
      begin
        if Failed <> '' then
        begin
          Writeln(ErrOutput, 'ERROR: ' + Failed);
          Writeln(ErrOutput, Format('pc=%.8x thread=%s', [Console.CPU.CurPC, PSPThreadName(Console.Kernel.Current)]));
          Writeln(ErrOutput, Console.Kernel.DescribeThreads);
          Writeln(ErrOutput, Console.Loader.Describe);
        end;
        if not EchoLog then
        begin
          var L := Console.TakeLog;
          if L <> '' then
            Write(ErrOutput, L);
        end;
      end;
      if Failed <> '' then
        ExitCode := 1;
      if GPU <> nil then
      begin
        var St := GPU.Stats;
        if GPUMode > 0 then
          Writeln(ErrOutput, Format('gpu: %d batches, %d passes, %d prims, %d on the CPU, %d pages uploaded, ' +
            '%.2fs waiting (gpu: %.3fs upload, %.3fs drawing, %.3fs readback)', [St.Batches, St.Passes, St.Prims,
            St.Fallbacks, St.UploadedPages, St.WaitSeconds, St.UploadSeconds, St.DrawSeconds, St.ReadbackSeconds]));
        if not Quiet then
        begin
          Writeln(ErrOutput, Format('gpu: %d tiles, %d tile primitives', [St.Tiles, St.Binned]));
          Writeln(ErrOutput, Format('gpu: %d syncs (%d by access, %d before CPU-drawn primitives), ' +
            '%d pages compared, %d read back, %d primitives drawn on the CPU after CPU-drawn ones', [St.Syncs,
            St.AccessSyncs, St.FallbackSyncs, St.ComparedPages, St.ReadbackPages, St.CPURunPrims]));
          Write(ErrOutput, GPU.Report);
        end;
        if GPUMode = 2 then
          Writeln(ErrOutput, Format('gpu check: %d of %d batches differ (%d bytes)', [St.BadBatches, St.CheckedBatches,
            St.BadBytes]));
      end
      else if HLE <> nil then
      begin
        var St := HLE.Stats;
        Writeln(ErrOutput, Format('gpu hle: %d prims in %d draws, %d submits, %d flushes (%d watch faults without), %d read back, ' +
          '%d target loads, %d depth loads, %d depth copies, %d textures uploaded, %d reused, %d from targets, %d pipelines; ' +
          '%.2fs flushing (%.2fs waiting), %.2fs setting up; %d frames shown at %dx in %.2fs; %d uploads scaled %dx in %.2fs',
          [St.Prims, St.Draws, St.Submits, St.Flushes, St.WatchFaults, St.Readbacks, St.TargetLoads, St.DepthLoads, St.DepthCopies,
          St.TextureUploads, St.TextureHits, St.TargetTextures, St.Pipelines, St.FlushSeconds, St.WaitSeconds, St.SetupSeconds,
          St.Presents, HLE.Scale, St.PresentSeconds, St.TextureScales, HLE.TextureScale, St.ScaleSeconds]));
      end
      else if not Quiet then
        Writeln(ErrOutput, 'ge cpu: ' + TPSPGE(Console.System.Find(TPSPGE)).Engine.Workers.Describe);
    finally
      if Watcher <> nil then
      begin
        Watcher.Terminate;
        Watcher.WaitFor;
        Watcher.Free;
      end;
      Console.CPU.Runner := OriginalRunner;
      History.Free;
      Wav.Free;
      if GPU <> nil then
      begin
        TPSPGE(Console.System.Find(TPSPGE)).Engine.Backend := nil;
        GPU.Free;
      end;
      if HLE <> nil then
      begin
        Console.OnPresent := nil;
        TPSPGE(Console.System.Find(TPSPGE)).Engine.Backend := nil;
        HLE.Free;
      end;
      Console.Free;
      Sink.Free;
      Presses.Free;
      try
        if TDirectory.Exists(Scratch) then
          TDirectory.Delete(Scratch, True);
      except
      end;
    end;
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.ClassName, ': ', E.Message);
      Writeln(ErrOutput, Format('at %p (image base %p)', [ExceptAddr, Pointer(HInstance)]));
      ExitCode := 3;
    end;
  end;
end.
