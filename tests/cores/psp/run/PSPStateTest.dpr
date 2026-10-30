program PSPStateTest;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Hash, System.Diagnostics, Core.Emulation.Types,
  PSP.Console, PSP.Media, PSP.GE, PSP.IO, Core.PSP.Renderer;

function FrameInput(Frame: Integer): TEmulatorInput;
  procedure Press(Button: TEmulatorButton; At: Integer);
  begin
    if (Frame >= At) and (Frame < At + 6) then Include(Result.Buttons, Button);
  end;
begin
  Result := Default(TEmulatorInput);
  Press(TEmulatorButton.Start, 650); Press(TEmulatorButton.B, 850);
  if GetEnvironmentVariable('PSP_MH_SCENARIO') = '' then Exit;
  for var F in [1150, 1450, 1750, 2750, 3050, 3450, 3850, 4250, 4650, 5050, 5450,
    7500, 8000, 8500] do Press(TEmulatorButton.B, F);
  for var F in [1820, 1860, 1900, 1940, 1980, 2020] do Press(TEmulatorButton.A, F);
  Press(TEmulatorButton.Start, 2100); Press(TEmulatorButton.Start, 7000);
  for var F in [2220, 2270, 2320, 2370, 2420, 2470, 2520] do Press(TEmulatorButton.Down, F);
  Press(TEmulatorButton.Left, 2900); Press(TEmulatorButton.Left, 4450);
  for var F := 0 to 19 do Press(TEmulatorButton.B, 14200 + F * 300);
end;

procedure GuestWrite(C: TPSPConsole; const Path, Text: RawByteString);
const
  Buffer = $0BFF0000;
begin
  C.IO.Cwd := 'ms0:/';
  C.Memory.WriteString(Buffer, Path, 1024);
  C.CPU.Ctx.GPR[4] := Buffer;
  C.CPU.Ctx.GPR[5] := PSP_O_WRONLY or PSP_O_CREAT or PSP_O_TRUNC;
  C.CPU.Ctx.GPR[6] := $1FF;
  C.HLE.FunctionInfo(C.HLE.Find('IoFileMgrForUser', $109F50BC)).Handler();
  var Fd := C.CPU.Ctx.GPR[2];
  if Fd >= $80000000 then raise Exception.CreateFmt('Guest open failed: %.8x', [Fd]);
  C.IO.Cwd := 'ms0:/PSP/GAME';
  C.Memory.WriteString(Buffer, Text, 1024);
  C.CPU.Ctx.GPR[4] := Fd;
  C.CPU.Ctx.GPR[5] := Buffer;
  C.CPU.Ctx.GPR[6] := Length(Text);
  C.HLE.FunctionInfo(C.HLE.Find('IoFileMgrForUser', $42EC03AC)).Handler();
  if C.CPU.Ctx.GPR[2] <> Cardinal(Length(Text)) then raise Exception.Create('Guest write failed');
end;

function Digest(C: TPSPConsole): string;
begin
  TPSPGE(C.System.Find(TPSPGE)).Engine.Synchronize;
  var H := THashSHA2.Create;
  H.Update(C.Memory.RAM);
  H.Update(C.Memory.VRAM);
  H.Update(C.Memory.Scratch);
  H.Update(C.CPU.Ctx, SizeOf(C.CPU.Ctx));
  H.Update(C.Scheduler.Now, SizeOf(C.Scheduler.Now));
  var Samples := C.AudioSamples;
  if Length(Samples) > 0 then H.Update(Samples[0], Length(Samples) * 2);
  Result := H.HashAsString;
end;

procedure FileCase;
begin
  var S := TFileStream.Create(ParamStr(1), fmOpenRead or fmShareDenyWrite);
  var P: TPSPProgram;
  try P := TPSPProgram.Read(S); finally S.Free; end;
  if P.BootPath <> '' then P.MediaPath := ParamStr(1);
  var Root := TPath.Combine(TPath.GetTempPath, 'RetroMul-file-state-test-' + TGUID.NewGuid.ToString);
  // A file-only test has no input history to replay, even accidentally.
  var C := TPSPConsole.Create(P, nil, '', TPath.Combine(Root, 'ms'), ParamStr(5), False);
  var D: TPSPConsole := nil;
  try
    if SameText(ParamStr(2), '--save') then
    begin
      var Frame: TEmulatorFrame;
      for var I := 1 to StrToIntDef(ParamStr(4), 3) do
      begin
        C.Input := FrameInput(I);
        C.RunFrame(Frame);
      end;
      C.SaveDirectSnapshot(ParamStr(3));
      Writeln('STATE ', C.FrameNumber, ' ', Digest(C));
    end
    else
    begin
      D := C.RestoreSnapshot(ParamStr(3));
      Writeln('STATE ', D.FrameNumber, ' ', Digest(D));
    end;
  finally
    D.Free;
    C.Free;
    TDirectory.Delete(Root, True);
  end;
end;

begin
  try
    if SameText(ParamStr(2), '--save') or SameText(ParamStr(2), '--load') then
    begin
      FileCase;
      Exit;
    end;
    if ParamCount < 2 then raise Exception.Create('PSPStateTest image checkpoint-frame [font-dir] [vulkan]');
    var S := TFileStream.Create(ParamStr(1), fmOpenRead or fmShareDenyWrite);
    var P: TPSPProgram;
    try P := TPSPProgram.Read(S); finally S.Free; end;
    if P.BootPath <> '' then P.MediaPath := ParamStr(1);
    var Root := TPath.Combine(TPath.GetTempPath, 'RetroMul-PSP-test-' + TGUID.NewGuid.ToString);
    TDirectory.CreateDirectory(Root);
    TDirectory.CreateDirectory(TPath.Combine(Root, 'ms'));
    var SavePath := TPath.Combine(Root, 'ms' + PathDelim + 'snapshot-test-save.dat');
    TFile.WriteAllText(SavePath, 'initial-save', TEncoding.ASCII);
    var C := TPSPConsole.Create(P, nil, '', TPath.Combine(Root, 'ms'), ParamStr(3), True);
    var Renderer := TPSPRendererSession.Create(C, SameText(ParamStr(4), 'vulkan'));
    var D: TPSPConsole := nil;
    try
      var Frame: TEmulatorFrame;
      var N := StrToInt(ParamStr(2));
      for var I := 1 to N do
      begin
        C.Input := FrameInput(I);
        C.RunFrame(Frame);
      end;
      var Path := TPath.Combine(Root, 'state.snapshot');
      C.SaveSnapshot(Path);
      Writeln('Format: ', C.LastSnapshotFormat);
      if (GetEnvironmentVariable('PSP_REQUIRE_DIRECT') <> '') and (C.LastSnapshotFormat <> 'direct') then
        raise Exception.Create('Direct state required: ' + C.TakeLog);
      TFile.WriteAllText(SavePath, 'newer-save-on-disk', TEncoding.ASCII);
      Writeln('Saved ', N, ' frames, ', TFile.GetSize(Path), ' bytes');
      var Expected := Digest(C);
      var Cancelled := False;
      try
        D := C.RestoreSnapshot(Path,
          function(Done, Total: UInt64): Boolean
          begin
            if Total = 4 then Result := Done < 2
            else Result := (N > 0) and (Done < UInt64(N div 2 + 1));
          end);
      except
        on EAbort do Cancelled := True;
      end;
      if not Cancelled or (D <> nil) or (Digest(C) <> Expected) then
        raise Exception.Create('Cancellation changed the active machine');
      Writeln('PASS cancellation preserves active machine');
      var Hashes: TArray<string>;
      SetLength(Hashes, 90);
      C.Input := Default(TEmulatorInput);
      for var I := 0 to High(Hashes) do
      begin
        C.RunFrame(Frame);
        Hashes[I] := Digest(C);
      end;
      Renderer.Free;
      Renderer := nil;
      C.Free;
      C := nil;
      // A completely new console: this cannot rely on old closures or addresses.
      C := TPSPConsole.Create(P, nil, '', TPath.Combine(Root, 'ms'), ParamStr(3), True);
      D := C.RestoreSnapshot(Path);
      if Digest(D) <> Expected then raise Exception.Create('Restored state differs');
      var Data: TBytes;
      if (D.IO.ReadAll('ms0:/snapshot-test-save.dat', Data) <> 0) or
        (TEncoding.ASCII.GetString(Data) <> 'initial-save') or
        (TFile.ReadAllText(SavePath, TEncoding.ASCII) <> 'newer-save-on-disk') then
        raise Exception.Create('Replay touched live savedata or lost initial file data');
      var SecondPath := TPath.Combine(Root, 'second.snapshot');
      D.SaveSnapshot(SecondPath);
      var LoadClock := TStopwatch.StartNew;
      var Next := D.RestoreSnapshot(SecondPath);
      Writeln('Second-generation load: ', LoadClock.ElapsedMilliseconds, ' ms');
      D.Free;
      D := Next;
      Writeln('PASS no live writes during restore and second-generation state');
      D.Input := Default(TEmulatorInput);
      for var I := 0 to High(Hashes) do
      begin
        D.RunFrame(Frame);
        if Digest(D) <> Hashes[I] then raise Exception.CreateFmt('Continuation differs at +%d', [I + 1]);
      end;
      Writeln('PASS fresh-console restore and 90 full-memory/CPU/audio continuation frames');
      GuestWrite(D, 'snapshot-test-save.dat', 'save-after-load');
      if TFile.ReadAllText(SavePath, TEncoding.ASCII) <> 'save-after-load' then
        raise Exception.Create('In-game writes after load did not reach the live memory stick');
      Writeln('PASS guest writes through an open file after repeated load');
      var Corrupt := TFile.ReadAllBytes(Path);
      Corrupt[High(Corrupt)] := Corrupt[High(Corrupt)] xor 1;
      TFile.WriteAllBytes(Path, Corrupt);
      var Rejected := False;
      var Before := Digest(C);
      try
        var Bad := C.RestoreSnapshot(Path);
        Bad.Free;
      except
        on EReadError do Rejected := True;
      end;
      if not Rejected or (Digest(C) <> Before) then raise Exception.Create('Corruption was not atomic');
      Writeln('PASS corrupt snapshot rejection preserves active machine');
    finally
      Renderer.Free;
      C.Free;
      D.Free;
      TDirectory.Delete(Root, True);
    end;
  except
    on E: Exception do begin Writeln(E.ClassName, ': ', E.Message); ExitCode := 1; end;
  end;
end.
