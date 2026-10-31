program PSPRendererLifecycleTest;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IniFiles, Core.Adapter.PSP, Core.PSP.Renderer,
  PSP.Types, PSP.Media, PSP.Console, PSP.GE, PSP.GE.Raster, Core.Emulation.Types;

type
  TConfigAccess = class(TPSPConfig)
    procedure ReadCore(Ini: TCustomIniFile);
    procedure WriteCore(Ini: TCustomIniFile);
  end;

  TFailLog = class
    Fail: Boolean;
    procedure Log(const Text: string);
  end;

procedure TConfigAccess.ReadCore(Ini: TCustomIniFile);
begin
  LoadCoreSettings(Ini);
end;

procedure TConfigAccess.WriteCore(Ini: TCustomIniFile);
begin
  SaveCoreSettings(Ini);
end;

procedure TFailLog.Log(const Text: string);
begin
  if Fail and Text.StartsWith('gpu: vulkan') then
    raise EAbort.Create('injected renderer constructor failure');
end;

procedure Require(Condition: Boolean; const Text: string);
begin
  if not Condition then
    raise Exception.Create(Text);
end;

procedure ConfigTest;
begin
  var C := TConfigAccess.Create('', nil);
  var Ini := TMemIniFile.Create('');
  try
    Require(C.Renderer = prCPU, 'CPU must be the default');
    Ini.WriteString('Video', 'Renderer', 'unknown');
    Ini.WriteString('Emulation', 'Execution', 'interpreter');
    Ini.WriteInteger('System', 'Language', 9);
    Ini.WriteInteger('System', 'ButtonSwap', 0);
    Ini.WriteString('System', 'Nickname', 'RendererTest');
    C.ReadCore(Ini);
    Require((C.Renderer = prCPU) and not C.Recompiler, 'Unknown renderer must use CPU; JIT choice preserved');
    Ini.WriteString('Video', 'Renderer', 'vulkan-hle');
    C.ReadCore(Ini);
    Require(C.Renderer = prVulkanHLE, 'Vulkan HLE INI choice not read');
    C.WriteCore(Ini);
    Require(Ini.ReadString('Video', 'Renderer', '') = 'vulkan-hle', 'Vulkan HLE choice not saved');
    Ini.WriteString('Video', 'Renderer', 'Vulkan-LLE');
    C.ReadCore(Ini);
    Require(C.Renderer = prVulkanLLE, 'Vulkan LLE alias not read');
    Ini.WriteString('Video', 'Renderer', 'VULKAN');
    C.ReadCore(Ini);
    Require(C.Renderer = prVulkanLLE, 'Vulkan INI choice not read');
    C.WriteCore(Ini);
    // The LLE keeps the value earlier versions wrote.
    Require(Ini.ReadString('Video', 'Renderer', '') = 'vulkan', 'Vulkan choice not saved');
    Require((C.Language = 9) and (C.ButtonSwap = 0) and (C.Nickname = 'RendererTest'), 'System settings changed');
    Ini.DeleteKey('Video', 'Renderer');
    C.ReadCore(Ini);
    Require(C.Renderer = prCPU, 'Absent choice must return to CPU');
    Require(C.Resolution = 1, 'The internal resolution must default to 1x');
    Ini.WriteInteger('Video', 'Resolution', 4);
    C.ReadCore(Ini);
    Require(C.Resolution = 4, 'Internal resolution not read');
    Ini.WriteInteger('Video', 'Resolution', 99);
    C.ReadCore(Ini);
    Require(C.Resolution = 8, 'Internal resolution not limited');
    C.WriteCore(Ini);
    Require(Ini.ReadInteger('Video', 'Resolution', 0) = 8, 'Internal resolution not saved');
    Ini.DeleteKey('Video', 'Resolution');
    C.ReadCore(Ini);
    Require(C.Resolution = 8, 'Absent resolution must keep the current one');
    Ini.WriteInteger('Video', 'Resolution', 1);
    C.ReadCore(Ini);
    C.WriteCore(Ini);
    Require(Ini.ReadString('Video', 'Renderer', '') = 'cpu', 'CPU choice not saved');
  finally
    Ini.Free;
    C.Free;
  end;
end;

procedure Exercise(const FileName: string; Kind: TPSPRenderer);
begin
  var Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  var P: TPSPProgram;
  try
    P := TPSPProgram.Read(Stream);
  finally
    Stream.Free;
  end;
  P.BootPath := 'host0:/' + ExtractFileName(FileName);
  var C := TPSPConsole.Create(P, nil, ExtractFileDir(FileName));
  var Log := TFailLog.Create;
  try
    var GE := TPSPGE(C.System.Find(TPSPGE)).Engine;
    C.OnLog := Log.Log;
    Log.Fail := True;
    var Failed := False;
    try
      var R := TPSPRendererSession.Create(C, Kind);
      R.Free;
    except
      on E: EAbort do Failed := True;
    end;
    Require(Failed, 'GPU unavailable or constructor failure injection was not reached');
    Require((GE.Backend = nil) and not Assigned(C.Memory.OnVRAMFault), 'Constructor failure leaked renderer ownership');
    Log.Fail := False;
    var R := TPSPRendererSession.Create(C, Kind);
    try
      try
        Require(R.Status.StartsWith(PSPRendererName(Kind) + ':'), 'Test requires a qualified Vulkan device');
        var Backend := GE.Backend;
        var S := Default(TGERaster);
        S.VRAM := @C.Memory.VRAM[0];
        S.FBStride := 512; S.FBFormat := 3;
        S.ScissorX2 := 31; S.ScissorY2 := 31; S.BandY2 := 1023;
        S.Through := True;
        GEPrepareRaster(S);
        var A := Default(TGEVertex);
        A.W := 1; A.Q := 1; A.R := 255; A.A := 255;
        var B := A; B.X := 32 * 16;
        var D := A; D.Y := 32 * 16;
        Backend.DrawTriangle(S, A, B, D);
        Require(C.Memory.HeldVRAMPages > 0, 'No pending GPU pages before Reset');
        C.Reset;
        Require((GE.Backend = Backend) and (C.Memory.HeldVRAMPages = 0), 'Reset lost the renderer or retained held pages');
        Backend.DrawTriangle(S, A, B, D);
        C.Memory.Write32($08F00000, $13579BDF);
        C.Loader.OnLoadExec(P.BootPath, 0, 0);
        var Frame: TEmulatorFrame;
        C.RunFrame(Frame);
        Require(C.Memory.Read32($08F00000) = 0, 'LoadExec did not reset RAM');
        Require(TPSPGE(C.System.Find(TPSPGE)).Engine.Backend = Backend, 'LoadExec lost the renderer');
        Backend.DrawTriangle(S, A, B, D);
        raise EAbort.Create('injected run failure');
      finally
        R.Free;
        R := nil;
      end;
    except
      on E: EAbort do ;
    end;
    R.Free;
    Require((GE.Backend = nil) and not Assigned(C.Memory.OnVRAMFault) and (C.Memory.HeldVRAMPages = 0),
      'Run failure leaked the renderer or held pages');
    // Reattach after both failures; the memory must be usable again.
    R := TPSPRendererSession.Create(C, Kind);
    R.Free;
    if Kind = prVulkanHLE then
    begin
      // At twice the resolution the shown frames come from the renderer.
      R := TPSPRendererSession.Create(C, Kind, 2);
      try
        Require(R.Status.Contains('at 2x') and Assigned(C.OnPresent), 'Scaled HLE session not attached');
        C.Reset;
        C.Loader.OnLoadExec(P.BootPath, 0, 0);
        var Scaled := False;
        for var F := 1 to 120 do
        begin
          var Frame: TEmulatorFrame;
          C.RunFrame(Frame);
          if (Frame.Width = 960) and (Frame.Height = 544) and (Length(Frame.Pixels) = 960 * 544) then
          begin
            Scaled := True;
            Break;
          end;
        end;
        Require(Scaled, 'No frame shown at twice the resolution');
      finally
        R.Free;
      end;
      Require(not Assigned(C.OnPresent) and (GE.Backend = nil) and not Assigned(C.Memory.OnVRAMFault),
        'Scaled session left its hooks');
    end;
  finally
    C.OnLog := nil;
    Log.Free;
    C.Free;
  end;
end;

begin
  try
    ConfigTest;
    var Failure := '';
    var Path := ExpandFileName(ParamStr(1));
    var Worker := TThread.CreateAnonymousThread(
      procedure
      begin
        try
          Exercise(Path, prVulkanLLE);
          Exercise(Path, prVulkanHLE);
        except
          on E: Exception do Failure := E.ClassName + ': ' + E.Message;
        end;
      end);
    Worker.FreeOnTerminate := False;
    Worker.Start;
    Worker.WaitFor;
    Worker.Free;
    Require(Failure = '', Failure);
    Writeln('PASS: settings, worker-owned GPU (LLE and HLE), Reset, LoadExec, constructor/run failure cleanup and reattach');
  except
    on E: Exception do
    begin
      Writeln('FAIL: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
