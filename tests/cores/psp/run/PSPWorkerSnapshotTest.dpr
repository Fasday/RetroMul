program PSPWorkerSnapshotTest;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Diagnostics, Core.Emulation,
  Core.Storage, Core.Adapter.PSP;

procedure Require(Value: Boolean; const Text: string);
begin
  if not Value then raise Exception.Create(Text);
end;

begin
  try
    var Root := TPath.Combine(TPath.GetTempPath, 'RetroMul-worker-test-' + TGUID.NewGuid.ToString);
    var Storage: IStorage := TStorage.Create(Root);
    if SameText(ParamStr(2), 'vulkan') then
    begin
      var Ini := Storage.ReadConfig(Storage.ConfigFile('psp'));
      try
        Ini.WriteString('Video', 'Renderer', 'vulkan');
        Storage.WriteConfig(Ini);
      finally
        Ini.Free;
      end;
    end;
    var Stream := TFileStream.Create(ParamStr(1), fmOpenRead or fmShareDenyWrite);
    var Core: IEmulationCore;
    try Core := TPSPCoreAdapter.Create(Stream, Storage, ParamStr(1)); finally Stream.Free; end;
    try
      Require(Core.SupportsSnapshots, 'Snapshots not advertised');
      var Operation: IEmulationSnapshotOperation;
      Require(Supports(Core, IEmulationSnapshotOperation, Operation), 'Nonblocking snapshot transport missing');
      var Location: IEmulationSnapshotLocation;
      Require(Supports(Core, IEmulationSnapshotLocation, Location), 'Snapshot location missing');
      Require(Location.GetSnapshotDirectory <> '', 'Empty snapshot directory');
      Core.Config.AudioEnabled := False;
      Core.Start;
      var Frame: TEmulatorFrame;
      var Clock := TStopwatch.StartNew;
      var Frames: UInt64 := 0;
      while (Frames < 12) and (Clock.ElapsedMilliseconds < 15000) do
      begin
        if Core.TryGetFrame(Frame) then Frames := Frame.FrameNumber;
        TThread.Sleep(5);
      end;
      Require(Frames >= 12, 'Worker produced no frames: ' + Core.TakeError);
      Core.Pause;
      Core.SaveSnapshot('Quick');
      Writeln('PASS worker saves while paused');
      Operation.BeginSnapshot('Quick', True);
      var Done, Total: UInt64;
      var Error: string;
      Clock := TStopwatch.StartNew;
      var Polls := 0;
      while Operation.SnapshotStatus(Done, Total, Error) and (Clock.ElapsedMilliseconds < 30000) do
      begin
        Inc(Polls);
        TThread.Sleep(1);
      end;
      Require(Error = '', Error);
      Require(Clock.ElapsedMilliseconds < 30000, 'Load timeout');
      Require(Core.TryGetFrame(Frame), 'Load did not publish a frame while paused');
      Require(Frame.FrameNumber >= 12, 'Wrong restored frame number');
      Writeln('PASS nonblocking worker load and paused preview, polls=', Polls);
      var Path := TPath.Combine(Location.GetSnapshotDirectory, 'Quick.snapshot');
      var Saved := TFile.ReadAllBytes(Path);
      var Bad := Copy(Saved);
      Bad[High(Bad)] := Bad[High(Bad)] xor 1;
      TFile.WriteAllBytes(Path, Bad);
      Operation.BeginSnapshot('Quick', True);
      Clock := TStopwatch.StartNew;
      while Operation.SnapshotStatus(Done, Total, Error) and (Clock.ElapsedMilliseconds < 30000) do TThread.Sleep(1);
      Require(Error <> '', 'Worker did not report the corrupted snapshot');
      TFile.WriteAllBytes(Path, Saved);
      Writeln('PASS worker snapshot error propagation');
      Operation.BeginSnapshot('Quick', True);
      Operation.CancelSnapshot;
      Clock := TStopwatch.StartNew;
      while Operation.SnapshotStatus(Done, Total, Error) and (Clock.ElapsedMilliseconds < 30000) do TThread.Sleep(1);
      Require(Error = '', Error);
      Core.Resume;
      Clock := TStopwatch.StartNew;
      var Last := Frame.FrameNumber;
      while (Frames <= Last + 2) and (Clock.ElapsedMilliseconds < 10000) do
      begin
        if Core.TryGetFrame(Frame) then Frames := Frame.FrameNumber;
        TThread.Sleep(5);
      end;
      Require(Frames > Last + 2, 'Worker did not resume');
      Require(Core.TakeError = '', 'Worker reported an error');
      Operation.BeginSnapshot('Quick', True);
      Core.Stop;
      Require(not Operation.SnapshotStatus(Done, Total, Error), 'Snapshot remains pending after shutdown');
      Writeln('PASS cancellation, resume and shutdown during a snapshot operation');
      Operation := nil;
      Location := nil;
    finally
      Core.Stop;
      Core := nil;
      Storage := nil;
      TDirectory.Delete(Root, True);
    end;
  except
    on E: Exception do begin Writeln(E.ClassName, ': ', E.Message); ExitCode := 1; end;
  end;
end.
