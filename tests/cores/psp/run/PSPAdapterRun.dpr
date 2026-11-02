program PSPAdapterRun;

{$APPTYPE CONSOLE}

// The actual adapter and worker, paced with sound unless -mute.
// PSPAdapterRun <file> <seconds> [out.png] [-mute] [-interpreter] [-gpu | -gpu-hle]
// -frame N: capture exactly guest frame N (fail if it was missed).
// -lifecycle: pause/resume, Reset, then Stop/Start during the run.
// -mash: Start and Cross (Enter, Z) in turn every 1.25 s from 8 s to 36 s, then
// Cross every 1.7 s until 47 s. -from S: measure the frame rate from S seconds.

uses
  System.SysUtils, System.Classes, System.Diagnostics, System.Hash, System.UITypes, Core.Emulation, Core.Emulation.Types,
  Core.Storage, Core.Snapshots, Core.Platforms.PSP.Adapter, Core.Platforms.PSP.Renderer;

function Hash(const Frame: TEmulatorFrame): string;
begin
  var H := THashSHA2.Create;
  if Length(Frame.Pixels) > 0 then
    H.Update(Frame.Pixels[0], Length(Frame.Pixels) * SizeOf(Cardinal));
  Result := H.HashAsString;
end;

begin
  try
    var Path := ParamStr(1);
    var Seconds := StrToIntDef(ParamStr(2), 10);
    var OutFile := '';
    var Mute := False;
    var Interpreter := False;
    var Renderer := prCPU;
    var Lifecycle := False;
    var Capture := 0;
    var Mash := False;
    var From: Double := 0;
    var I := 3;
    while I <= ParamCount do
    begin
      var A := ParamStr(I);
      if A = '-mute' then Mute := True
      else if A = '-interpreter' then Interpreter := True
      else if A = '-gpu' then Renderer := prVulkanLLE
      else if A = '-gpu-hle' then Renderer := prVulkanHLE
      else if A = '-lifecycle' then Lifecycle := True
      else if A = '-frame' then begin Inc(I); Capture := StrToInt(ParamStr(I)); end
      else if A = '-mash' then Mash := True
      else if A = '-from' then begin Inc(I); From := StrToFloat(ParamStr(I), TFormatSettings.Invariant); end
      else OutFile := A;
      Inc(I);
    end;
    // The core's registration with the factory is the frontend's
    // (RM.Platforms.PSP): the adapter is made here as it makes it.
    var Core: IEmulationCore;
    var Stream := TStorage.Default.OpenRead(Path);
    try
      Core := TPSPCoreAdapter.Create(Stream, TStorage.Default, Path, '');
    finally
      Stream.Free;
    end;
    Writeln('core: ', Core.Name);
    Core.Config.AudioEnabled := not Mute;
    var Config := Core.Config as TObject;
    if Config is TPSPConfig then
    begin
      TPSPConfig(Config).Recompiler := not Interpreter;
      TPSPConfig(Config).Renderer := Renderer;
    end;
    var Adapter := Core as TObject;
    var Frame, LastFrame: TEmulatorFrame;
    var Got := 0;
    var First: UInt64 := 0;
    var FirstAt: Double := 0;
    var Phase := 0;
    var Watch := TStopwatch.StartNew;
    Core.Start;
    try
      while Watch.Elapsed.TotalSeconds < Seconds do
      begin
        if Capture > 0 then Sleep(1) else Sleep(20);
        if Lifecycle and (Phase = 0) and (Watch.Elapsed.TotalSeconds >= Seconds / 3) then
        begin
          Core.Pause;
          Sleep(100);
          Core.Resume;
          Core.Reset;
          Phase := 1;
          Writeln('lifecycle: pause/resume/reset');
        end;
        if Lifecycle and (Phase = 1) and (Watch.Elapsed.TotalSeconds >= Seconds * 2 / 3) then
        begin
          Core.Stop;
          Core.Start;
          Phase := 2;
          Writeln('lifecycle: stop/start');
        end;
        if Mash then
        begin
          var T := Watch.Elapsed.TotalSeconds;
          var Start := (T >= 8) and (T < 36) and (Trunc((T - 8) / 1.25) mod 2 = 0) and (Frac((T - 8) / 1.25) < 0.2);
          var Cross := ((T >= 8) and (T < 36) and (Trunc((T - 8) / 1.25) mod 2 = 1) and (Frac((T - 8) / 1.25) < 0.2)) or
            ((T >= 36) and (T < 47) and (Frac((T - 36) / 1.7) < 0.15));
          Core.SetKeyState(vkReturn, Start);
          Core.SetKeyState(vkZ, Cross);
        end;
        if Core.TryGetFrame(Frame) then
        begin
          if (Got = 0) or ((From > 0) and (FirstAt < From) and (Watch.Elapsed.TotalSeconds >= From)) then
          begin
            First := Frame.FrameNumber;
            FirstAt := Watch.Elapsed.TotalSeconds;
          end;
          Inc(Got);
          LastFrame := Frame;
          if (Capture > 0) and (Frame.FrameNumber >= UInt64(Capture)) then
          begin
            if Frame.FrameNumber <> UInt64(Capture) then
              raise Exception.CreateFmt('Missed capture frame %d (got %d)', [Capture, Frame.FrameNumber]);
            Break;
          end;
        end;
        var E := Core.TakeError;
        if E <> '' then
          raise Exception.Create(E);
      end;
      if (Capture > 0) and (LastFrame.FrameNumber <> UInt64(Capture)) then
        raise Exception.Create('Capture timed out');
      if Got = 0 then
        raise Exception.Create('No frames from the adapter');
      var Span := Watch.Elapsed.TotalSeconds - FirstAt;
      if Span <= 0 then Span := 0.001;
      if Lifecycle then
        Writeln(Format('%d frames shown across reset/restart; final guest frame %d', [Got, LastFrame.FrameNumber]))
      else
        Writeln(Format('%d frames shown, guest frames %d..%d in %.1f s: %.1f guest fps (reported %.1f)', [Got, First,
          LastFrame.FrameNumber, Span, (Int64(LastFrame.FrameNumber) - Int64(First)) / Span, LastFrame.FramesPerSecond]));
      Writeln(Format('frame %d hash %s', [LastFrame.FrameNumber, Hash(LastFrame)]));
      if Adapter is TPSPCoreAdapter then
        Writeln('renderer: ', TPSPCoreAdapter(Adapter).RendererStatus);
      if (OutFile <> '') and (Length(LastFrame.Pixels) > 0) then
        SaveSnapshotPreview(OutFile, LastFrame.Width, LastFrame.Height, LastFrame.Width, @LastFrame.Pixels[0]);
    finally
      Core.Stop;
    end;
    var E := Core.TakeError;
    if E <> '' then
      raise Exception.Create(E);
  except
    on E: Exception do
    begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
