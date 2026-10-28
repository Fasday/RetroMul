program PSPAdapterRun;

{$APPTYPE CONSOLE}

// Opens a file through the emulator factory, as the front end does, runs the
// core's worker for some seconds (with sound unless -mute) and saves the last
// frame: PSPAdapterRun <file> <seconds> [out.png] [-mute] [-interpreter]

uses
  System.SysUtils, System.Classes, System.Diagnostics, Core.Emulation, Core.Emulation.Types, Core.EmulatorFactory,
  Core.Snapshots, Core.Adapter.PSP;

begin
  try
    var Path := ParamStr(1);
    var Seconds := StrToIntDef(ParamStr(2), 10);
    var OutFile := '';
    var Mute := False;
    var Interpreter := False;
    for var I := 3 to ParamCount do
      if ParamStr(I) = '-mute' then
        Mute := True
      else if ParamStr(I) = '-interpreter' then
        Interpreter := True
      else
        OutFile := ParamStr(I);
    var Core := CreateEmulationCore(Path);
    Writeln('core: ', Core.Name);
    Core.Config.AudioEnabled := not Mute;
    var Config := Core.Config as TObject;
    if Config is TPSPConfig then
      TPSPConfig(Config).Recompiler := not Interpreter;
    Core.Start;
    var Frame, LastFrame: TEmulatorFrame;
    var Got := 0;
    var First: UInt64 := 0;
    var FirstAt: Double := 0;
    var Watch := TStopwatch.StartNew;
    while Watch.Elapsed.TotalSeconds < Seconds do
    begin
      Sleep(20);
      if Core.TryGetFrame(Frame) then
      begin
        if Got = 0 then
        begin
          First := Frame.FrameNumber;
          FirstAt := Watch.Elapsed.TotalSeconds;
        end;
        Inc(Got);
        LastFrame := Frame;
      end;
      var E := Core.TakeError;
      if E <> '' then
        Writeln('error: ', E);
    end;
    var Span := Watch.Elapsed.TotalSeconds - FirstAt;
    Writeln(Format('%d frames shown, guest frames %d..%d in %.1f s: %.1f guest fps', [Got, First, LastFrame.FrameNumber,
      Span, (LastFrame.FrameNumber - First) / Span]));
    if (OutFile <> '') and (Length(LastFrame.Pixels) > 0) then
      SaveSnapshotPreview(OutFile, LastFrame.Width, LastFrame.Height, LastFrame.Width, @LastFrame.Pixels[0]);
    Core.Stop;
    var E := Core.TakeError;
    if E <> '' then
      Writeln('error: ', E);
  except
    on E: Exception do
    begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
