program PSPRun;

{$APPTYPE CONSOLE}

// Runs a PSP program headless.
// PSPRun <file> [-frames N] [-out dir] [-every N] [-press btn@frame:len] [-log] [-test] [-quiet] [-strict]
// -test: pspautotests mode (host0: = the file's folder, no display, stops at exit).

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.IOUtils, System.Hash, System.Diagnostics, System.Generics.Collections,
  Core.Emulation.Types, PSP.Types, PSP.Media, PSP.Console, PSP.Kernel, PSP.HLE, PSP.Loader;

type
  TPress = record
    Button: TEmulatorButton;
    Frame, Length: Integer;
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

begin
  try
    if ParamCount < 1 then
    begin
      Writeln('PSPRun <file> [-frames N] [-out dir] [-every N] [-press btn@frame:len] [-log] [-test] [-quiet] [-strict]');
      Halt(2);
    end;
    var FileName := ExpandFileName(ParamStr(1));
    var Frames := 600;
    var OutDir := '';
    var Every := 0;
    var Presses := TList<TPress>.Create;
    var EchoLog := False;
    var TestMode := False;
    var Quiet := False;
    var Strict := False;
    var TraceKernel := False;
    var WatchOn := False;
    var ShotFile := '';
    var I := 2;
    while I <= ParamCount do
    begin
      var A := ParamStr(I);
      if A = '-frames' then begin Inc(I); Frames := StrToInt(ParamStr(I)); end
      else if A = '-out' then begin Inc(I); OutDir := ParamStr(I); end
      else if A = '-every' then begin Inc(I); Every := StrToInt(ParamStr(I)); end
      else if A = '-log' then EchoLog := True
      else if A = '-test' then TestMode := True
      else if A = '-quiet' then Quiet := True
      else if A = '-strict' then Strict := True
      else if A = '-trace' then TraceKernel := True
      else if A = '-watch' then WatchOn := True
      else if A = '-shot' then begin Inc(I); ShotFile := ParamStr(I); end
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
    var Scratch := TPath.Combine(TPath.GetTempPath, Format('psprun-%d', [GetCurrentProcessId]));
    var HostRoot := ExtractFileDir(FileName);
    var Memstick := TPath.Combine(Scratch, 'ms0');
    if TestMode then
    begin
      var Host := TPath.Combine(Scratch, 'host0');
      ForceDirectories(Host);
      for var F in TDirectory.GetFiles(HostRoot) do
        TFile.Copy(F, TPath.Combine(Host, ExtractFileName(F)), True);
      for var D in TDirectory.GetDirectories(HostRoot) do
        TDirectory.Copy(D, TPath.Combine(Host, ExtractFileName(D)));
      HostRoot := Host;
    end;
    var Sink := TLogSink.Create;
    Sink.Echo := EchoLog;
    var Console := TPSPConsole.Create(Prog, nil, HostRoot, Memstick);
    try
      Console.OnLog := Sink.Log;
      Sink.Console := Console;
      Sink.ShotFile := ShotFile;
      Console.IO.OnScreenshot := Sink.Screenshot;
      if WatchOn then
      begin
        var Watcher := TWatch.Create(True);
        Watcher.Console := Console;
        Watcher.FreeOnTerminate := True;
        Watcher.Start;
      end;
      Console.HLE.Strict := Strict;
      Console.Kernel.Trace := TraceKernel;
      Console.HLE.TraceCalls := TraceKernel;
      if TestMode then
        Console.IO.HasDisplay := False;
      if not Quiet then
        Writeln(ErrOutput, Format('title=%s id=%s', [Prog.Title, Prog.DiscId]));
      var Watch := TStopwatch.StartNew;
      var Frame: TEmulatorFrame;
      var LastHash := '';
      var Failed := '';
      for var F := 1 to Frames do
      begin
        var Input := Default(TEmulatorInput);
        for var P in Presses do
          if (F >= P.Frame) and (F < P.Frame + P.Length) then
            Include(Input.Buttons, P.Button);
        Console.Input := Input;
        try
          Console.RunFrame(Frame);
        except
          on E: Exception do
          begin
            Failed := E.ClassName + ': ' + E.Message;
            Break;
          end;
        end;
        var Text := Console.TakeOutput;
        if Text <> '' then
          Write(Text);
        if (Every > 0) and (F mod Every = 0) then
        begin
          var H := FrameHash(Frame);
          if not Quiet then
            Writeln(ErrOutput, Format('frame %d hash %s', [F, H]));
          if OutDir <> '' then
            SaveBMP(Frame, TPath.Combine(OutDir, Format('f%.5d.bmp', [F])));
        end;
        LastHash := FrameHash(Frame);
        if Console.Kernel.Exited then
          Break;
      end;
      var Text := Console.TakeOutput;
      if Text <> '' then
        Write(Text);
      if OutDir <> '' then
        SaveBMP(Frame, TPath.Combine(OutDir, 'last.bmp'));
      if not Quiet then
        Writeln(ErrOutput, Format('frames=%d time=%.2fs guest=%.2fs exited=%s hash=%s',
          [Console.FrameNumber, Watch.Elapsed.TotalSeconds, Console.Scheduler.Now / 1e9,
          BoolToStr(Console.Kernel.Exited, True), LastHash]));
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
    finally
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
      ExitCode := 3;
    end;
  end;
end.
