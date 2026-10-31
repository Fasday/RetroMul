program RetromulTerm;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  Core.Adapter.MSX in '..\..\source\adapters\Core.Adapter.MSX.pas',
  MSX.Cartridge in '..\..\source\cores\msx\MSX.Cartridge.pas',
  MSX.MapperAnalysis in '..\..\source\cores\msx\MSX.MapperAnalysis.pas',
  MSX.Console in '..\..\source\cores\msx\MSX.Console.pas',
  MSX.AudioBoard in '..\..\source\cores\msx\MSX.AudioBoard.pas',
  Yamaha.Sound.Y8950 in '..\..\source\hardware\audio\opl\Yamaha.Sound.Y8950.pas',
  MSX.RTC in '..\..\source\cores\msx\MSX.RTC.pas',
  MSX.Floppy in '..\..\source\cores\msx\MSX.Floppy.pas',
  MSX.Cassette in '..\..\source\cores\msx\MSX.Cassette.pas',
  MSX.Peripherals in '..\..\source\cores\msx\MSX.Peripherals.pas',
  MSX.Emulation in '..\..\source\cores\msx\MSX.Emulation.pas',
  MSX.Firmware in '..\..\source\cores\msx\MSX.Firmware.pas',
  MSX.Machine in '..\..\source\cores\msx\MSX.Machine.pas',
  MSX.VDP in '..\..\source\cores\msx\MSX.VDP.pas',
  MSX.VDP.Timing in '..\..\source\cores\msx\MSX.VDP.Timing.pas',
  MSX.VDP.AdjustTiming in '..\..\source\cores\msx\MSX.VDP.AdjustTiming.pas',
  MSX.VDP.SpriteTiming in '..\..\source\cores\msx\MSX.VDP.SpriteTiming.pas',
  MSX.VDP.ShortTiming in '..\..\source\cores\msx\MSX.VDP.ShortTiming.pas',

  HW.ARM.Shifter in '..\..\source\hardware\cpu\HW.ARM.Shifter.pas',
  Audio.ATRAC3.Decoder in '..\..\source\hardware\audio\atrac3\Audio.ATRAC3.Decoder.pas',
  Audio.ATRAC3 in '..\..\source\hardware\audio\atrac3\Audio.ATRAC3.pas',
  PSP.MP3 in '..\..\source\cores\psp\PSP.MP3.pas',
  PSP.Mpeg in '..\..\source\cores\psp\PSP.Mpeg.pas',
  Core.Bitstream in '..\..\source\media\Core.Bitstream.pas',
  Video.AVC.Bitstream in '..\..\source\hardware\video\avc\Video.AVC.Bitstream.pas',
  Video.AVC.H264.CABAC in '..\..\source\hardware\video\avc\Video.AVC.H264.CABAC.pas',
  Video.AVC.H264.DSP in '..\..\source\hardware\video\avc\Video.AVC.H264.DSP.pas',
  Video.AVC.H264 in '..\..\source\hardware\video\avc\Video.AVC.H264.pas',
  Video.AVC.H264.Syntax in '..\..\source\hardware\video\avc\Video.AVC.H264.Syntax.pas',
  Video.AVC.H264.Tables in '..\..\source\hardware\video\avc\Video.AVC.H264.Tables.pas',
  Video.AVC.Types in '..\..\source\hardware\video\avc\Video.AVC.Types.pas',
  FMXAudio.AAC.ER in '..\..\source\hardware\audio\codecs\FMXAudio.AAC.ER.pas',
  FMXAudio.AAC.LD in '..\..\source\hardware\audio\codecs\FMXAudio.AAC.LD.pas',
  FMXAudio.AAC in '..\..\source\hardware\audio\codecs\FMXAudio.AAC.pas',
  FMXAudio.AAC.PS in '..\..\source\hardware\audio\codecs\FMXAudio.AAC.PS.pas',
  FMXAudio.AAC.SBR in '..\..\source\hardware\audio\codecs\FMXAudio.AAC.SBR.pas',
  FMXAudio.AAC.SSR in '..\..\source\hardware\audio\codecs\FMXAudio.AAC.SSR.pas',
  FMXAudio.AAC.Tables in '..\..\source\hardware\audio\codecs\FMXAudio.AAC.Tables.pas',
  FMXAudio.AAC.USAC.LPC in '..\..\source\hardware\audio\codecs\FMXAudio.AAC.USAC.LPC.pas',
  FMXAudio.AAC.USAC.LPD in '..\..\source\hardware\audio\codecs\FMXAudio.AAC.USAC.LPD.pas',
  FMXAudio.AAC.USAC in '..\..\source\hardware\audio\codecs\FMXAudio.AAC.USAC.pas',
  FMXAudio.Bitstream in '..\..\source\hardware\audio\codecs\FMXAudio.Bitstream.pas',
  FMXAudio.Transform in '..\..\source\hardware\audio\codecs\FMXAudio.Transform.pas',
  FMXAudio.Types in '..\..\source\hardware\audio\codecs\FMXAudio.Types.pas',
  Audio.ATRAC3Plus in '..\..\source\hardware\audio\atrac3plus\Audio.ATRAC3Plus.pas',
  Audio.ATRAC3Plus.Decoder in '..\..\source\hardware\audio\atrac3plus\Audio.ATRAC3Plus.Decoder.pas',
  Audio.ATRAC3Plus.Primitives in '..\..\source\hardware\audio\atrac3plus\Audio.ATRAC3Plus.Primitives.pas',
  Audio.ATRAC3Plus.Tables in '..\..\source\hardware\audio\atrac3plus\Audio.ATRAC3Plus.Tables.pas',
  PSP.Audio in '..\..\source\cores\psp\PSP.Audio.pas',
  PSP.SAS in '..\..\source\cores\psp\PSP.SAS.pas',
  PSP.Utility in '..\..\source\cores\psp\PSP.Utility.pas',
  PSP.VFPU in '..\..\source\cores\psp\PSP.VFPU.pas',
  PSP.GE in '..\..\source\cores\psp\PSP.GE.pas',
  PSP.AES in '..\..\source\cores\psp\PSP.AES.pas',
  PSP.PRX in '..\..\source\cores\psp\PSP.PRX.pas',
  PSP.Kernel in '..\..\source\cores\psp\PSP.Kernel.pas',
  PSP.Memory in '..\..\source\cores\psp\PSP.Memory.pas',
  PSP.Media in '..\..\source\cores\psp\PSP.Media.pas',
  PSP.CPU in '..\..\source\cores\psp\PSP.CPU.pas',
  PSP.Console in '..\..\source\cores\psp\PSP.Console.pas',
  PSP.Atrac in '..\..\source\cores\psp\PSP.Atrac.pas',
  PSP.AudioCodec in '..\..\source\cores\psp\PSP.AudioCodec.pas',
  PSP.Display in '..\..\source\cores\psp\PSP.Display.pas',
  PSP.Font in '..\..\source\cores\psp\PSP.Font.pas',
  PSP.HLE in '..\..\source\cores\psp\PSP.HLE.pas',
  PSP.IO in '..\..\source\cores\psp\PSP.IO.pas',
  PSP.Loader in '..\..\source\cores\psp\PSP.Loader.pas',
  PSP.Misc in '..\..\source\cores\psp\PSP.Misc.pas',
  PSP.Psmf in '..\..\source\cores\psp\PSP.Psmf.pas',
  PSP.Scheduler in '..\..\source\cores\psp\PSP.Scheduler.pas',
  PSP.Service in '..\..\source\cores\psp\PSP.Service.pas',
  PSP.SysLibs in '..\..\source\cores\psp\PSP.SysLibs.pas',
  PSP.SysMem in '..\..\source\cores\psp\PSP.SysMem.pas',
  PSP.Types in '..\..\source\cores\psp\PSP.Types.pas',
  PSP.CPU.JIT in '..\..\source\cores\psp\PSP.CPU.JIT.pas',
  PSP.GE.Engine in '..\..\source\cores\psp\PSP.GE.Engine.pas',
  PSP.GE.Raster in '..\..\source\cores\psp\PSP.GE.Raster.pas',
  PSP.GE.Texture in '..\..\source\cores\psp\PSP.GE.Texture.pas',
  PSP.GE.Types in '..\..\source\cores\psp\PSP.GE.Types.pas',
  PSP.Jpeg in '..\..\source\cores\psp\PSP.Jpeg.pas',
  PSP.Mp4 in '..\..\source\cores\psp\PSP.Mp4.pas',
  PSP.MpegDemux in '..\..\source\cores\psp\PSP.MpegDemux.pas',
  PSP.MpegVideo in '..\..\source\cores\psp\PSP.MpegVideo.pas',
  PSP.SFO in '..\..\source\cores\psp\PSP.SFO.pas',
  PSP.Settings in '..\..\source\cores\psp\PSP.Settings.pas',
  PSP.State in '..\..\source\cores\psp\PSP.State.pas',
  PSP.State.Action in '..\..\source\cores\psp\PSP.State.Action.pas',
  PSP.State.Direct in '..\..\source\cores\psp\PSP.State.Direct.pas',
  PSP.State.Graph in '..\..\source\cores\psp\PSP.State.Graph.pas',
  PSP.State.Schema in '..\..\source\cores\psp\PSP.State.Schema.pas',
  SPV.PSPGERaster in '..\..\source\gpu\shaders\SPV.PSPGERaster.pas',
  SPV.PSPGESelfTest in '..\..\source\gpu\shaders\SPV.PSPGESelfTest.pas',
  SPV.PSPGEHLEVert in '..\..\source\gpu\shaders\SPV.PSPGEHLEVert.pas',
  SPV.PSPGEHLEFrag in '..\..\source\gpu\shaders\SPV.PSPGEHLEFrag.pas',
  SPV.PSPGEHLEBlendFrag in '..\..\source\gpu\shaders\SPV.PSPGEHLEBlendFrag.pas',
  SPV.PSPGEHLEDown in '..\..\source\gpu\shaders\SPV.PSPGEHLEDown.pas',
  PSP.VFPU.Math in '..\..\source\cores\psp\PSP.VFPU.Math.pas',
  PSP.Net in '..\..\source\cores\psp\PSP.Net.pas',
  PSP.Videocodec in '..\..\source\cores\psp\PSP.Videocodec.pas',
  PSP.GE.Backend in '..\..\source\cores\psp\PSP.GE.Backend.pas',
  PSP.GE.Workers in '..\..\source\cores\psp\PSP.GE.Workers.pas',
  {$IF (Defined(MSWINDOWS) or Defined(LINUX) or Defined(ANDROID)) and not Defined(CPUX86)}
  PSP.GE.VulkanLLE in '..\..\source\cores\psp\PSP.GE.VulkanLLE.pas',
  PSP.GE.VulkanHLE in '..\..\source\cores\psp\PSP.GE.VulkanHLE.pas',
  PSP.Crypto in '..\..\source\cores\psp\PSP.Crypto.pas',
  PSP.Crypto.ECDSA in '..\..\source\cores\psp\PSP.Crypto.ECDSA.pas',
  PSP.Crypto.Keys in '..\..\source\cores\psp\PSP.Crypto.Keys.pas',
  PSP.Crypto.Kirk in '..\..\source\cores\psp\PSP.Crypto.Kirk.pas',
  RM.Vulkan.Bindings in '..\..\source\gpu\vulkan\RM.Vulkan.Bindings.pas',
  RM.Vulkan.Loader in '..\..\source\gpu\vulkan\RM.Vulkan.Loader.pas',
  RM.Vulkan.Compute in '..\..\source\gpu\vulkan\RM.Vulkan.Compute.pas',
  {$ENDIF}
  Core.PSP.Archive in '..\..\source\adapters\Core.PSP.Archive.pas',
  Core.Adapter.PSP in '..\..\source\adapters\Core.Adapter.PSP.pas',
  System.SysUtils,
  System.Classes, System.UITypes,
  Winapi.Windows,
  FMX.Graphics,
  GW.Artwork.FMX in '..\..\source\ui\gamewatch\GW.Artwork.FMX.pas',
  Core.Emulation,
  Core.EmulatorFactory, Core.Adapter.PCE, Core.Adapter.SG1000,
  Core.Storage,
  Core.Platforms in '..\..\source\runtime\Core.Platforms.pas',
  Core.RomFormat,
  Core.RomHashes in '..\..\source\media\rom\Core.RomHashes.pas',
  Retromul.Terminal in 'Retromul.Terminal.pas';

var
  Running: Boolean;
  FEmulation: IEmulationCore;
  FUserPaused: Boolean;
  FKeysDown: array[0..255] of Boolean;
  FEmulationFaulted: Boolean;
  FRomDisplayName: string;

procedure SetStatus(const Text: string);
begin
  TRetromulTerminal.SetTitle('RetromulTerm - ' + Text);
end;

procedure StopOnError;
begin
  FEmulationFaulted := True;
  if FEmulation <> nil then
    FEmulation.Pause;
  SetStatus('Stopped after error - ' + FRomDisplayName);
end;

procedure LoadRom(const FileName: string; const DisplayName: string);
begin
  // Construct first: an invalid ROM leaves the current worker running.
  var NewEmulation: IEmulationCore;
  var Storage := TStorage.Default;
  var Stream := Storage.OpenRead(FileName);
  try NewEmulation := CreateEmulationCore(Stream, Storage, FileName);
  finally Stream.Free; end;
  try
    if FEmulation <> nil then
      FEmulation.Stop;
  except
    NewEmulation := nil;
    raise;
  end;
  FEmulation := nil;
  FEmulation := NewEmulation;
  FUserPaused := False;
  FillChar(FKeysDown, SizeOf(FKeysDown), 0);
  FRomDisplayName := DisplayName;
  if FRomDisplayName = '' then
    FRomDisplayName := ExtractFileName(FileName);
  try
    TRetromulTerminal.Clear;
    FEmulationFaulted := False;
    FEmulation.Start;
    SetStatus(FEmulation.Name + ' - ' + FRomDisplayName);
  except
    StopOnError;
    raise;
  end;
end;

procedure UpdateFrame;
begin
  if FEmulation = nil then
    Exit;
  var Frame: TEmulatorFrame;
  var NewFrame := FEmulation.TryGetFrame(Frame);
  var ErrorText := FEmulation.TakeError;
  if (ErrorText <> '') and not FEmulationFaulted then
  begin
    StopOnError;
    raise Exception.Create(ErrorText);
  end;
  if not FEmulationFaulted and NewFrame then
  begin
    SetStatus(Format('%s - %.1f FPS', [FEmulation.Name, Frame.FramesPerSecond]));
  end;
  if not NewFrame then
    Exit;

  TRetromulTerminal.DrawFrame(Frame, TTerminalRenderMode.trmAscii, TRetromulTerminal.Width, TRetromulTerminal.Height - 2);
end;

begin
  TRetromulTerminal.Initialize;
  try
    TRetromulTerminal.SetTitle('RetroMul');
    TRetromulTerminal.Clear;
    var RomName := ParamStr(1);
    {$IFDEF DEBUG}
    RomName := 'H:\ROMS\' + ROM_SYSTEM_NES + '\Super Mario Brothers' + ROM_EXTENSION_NES;
    //RomName := 'H:\ROMS\megadrive\Sonic The Hedgehog (USA, Europe).gen';
    //RomName := 'H:\ROMS\gb\DuckTales (USA).gb';
    {$ENDIF}
    if RomName.IsEmpty then
    begin
      Writeln('Set file name as param 1');
      Exit;
    end;
    LoadRom(RomName, '');

    Running := True;
    while Running do
    begin
      try
        UpdateFrame;
      except
        StopOnError;
        raise;
      end;

      var Keyboard: ISGKeyboardCore;
      var SCKeyboard := Supports(FEmulation, ISGKeyboardCore, Keyboard) and Keyboard.HasKeyboard;
      if SCKeyboard or (FEmulation.Config is TPCEConfig) then
      begin
        for var Code := 1 to 255 do
        begin
          var Down := TRetromulTerminal.IsKeyDown(Code);
          if Down <> FKeysDown[Code] then FEmulation.SetKeyState(Code, Down);
          FKeysDown[Code] := Down;
        end;
      end
      else
      begin
        FEmulation.SetKeyState(VK_LEFT, TRetromulTerminal.IsKeyDown(VK_LEFT));
        FEmulation.SetKeyState(VK_RIGHT, TRetromulTerminal.IsKeyDown(VK_RIGHT));
        FEmulation.SetKeyState(VK_UP, TRetromulTerminal.IsKeyDown(VK_UP));
        FEmulation.SetKeyState(VK_DOWN, TRetromulTerminal.IsKeyDown(VK_DOWN));
        FEmulation.SetKeyState(vkZ, TRetromulTerminal.IsKeyDown(vkZ));
        FEmulation.SetKeyState(vkX, TRetromulTerminal.IsKeyDown(vkX));
        FEmulation.SetKeyState(VK_RETURN, TRetromulTerminal.IsKeyDown(VK_RETURN));
        FEmulation.SetKeyState(VK_SPACE, TRetromulTerminal.IsKeyDown(VK_SPACE));
      end;

      // Escape is the SC-3000 BREAK key; F12 exits that keyboard session.
      if ((not SCKeyboard) and TRetromulTerminal.IsKeyDown(VK_ESCAPE)) or
        (SCKeyboard and TRetromulTerminal.IsKeyDown(VK_F12)) then
        Running := False;

      Sleep(16);
    end;
  finally
    TRetromulTerminal.Finalize;
  end;
end.
