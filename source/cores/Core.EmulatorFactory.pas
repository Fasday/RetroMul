unit Core.EmulatorFactory;

interface

uses
  System.Classes, System.SysUtils, Core.Storage, Core.Emulation;

function CreateEmulationCore(const FileName: string): IEmulationCore; overload;

// The caller owns Stream. Cartridges copy bytes; CD cores own separate track streams.
// RomName must retain the location for Neo Geo parent ZIPs and CD tracks/BIOS.
function CreateEmulationCore(Stream: TStream; const Storage: IStorage; const RomName: string = ''): IEmulationCore; overload;

implementation

uses
  Core.RomFormat, Core.Adapter.NES, Core.Adapter.GB, Core.Adapter.GBC,
  Core.Adapter.N64, Core.Adapter.MD, Core.Adapter.GBA, Core.Adapter.SNES, Core.Adapter.NeoGeo, NeoGeo.Cartridge;

function CreateEmulationCore(const FileName: string): IEmulationCore;
begin
  var Storage := TStorage.Default;
  var Stream := Storage.OpenRead(FileName);
  try
    Result := CreateEmulationCore(Stream, Storage, FileName);
  finally
    Stream.Free;
  end;
end;

function CreateEmulationCore(Stream: TStream; const Storage: IStorage; const RomName: string): IEmulationCore;
begin
  // Disc streams exceed cartridge limits; keep them on disk and read sectors.
  var SourceName := RomName;
  if (Storage <> nil) and RomName.StartsWith('content://', True) then
    SourceName := Storage.Describe(RomName).Name;
  if SameText(ExtractFileExt(SourceName), ROM_EXTENSION_CUE) or
    SameText(ExtractFileExt(SourceName), ROM_EXTENSION_ISO) or
    SameText(ExtractFileExt(SourceName), ROM_EXTENSION_CHD) then
    Exit(TNeoGeoCoreAdapter.Create(Stream, Storage, RomName, True));
  var Data := ReadNeoGeoData(Stream);
  var Format := DetectRom(Data);
  if (Format.System=TRomSystem.Unknown) and SameText(ExtractFileExt(RomName),ROM_EXTENSION_GBA) then Format.System:=TRomSystem.GBA;
  if (Format.System <> TRomSystem.NeoGeo) and (Length(Data) > ROM_MAX_SIZE) then
    raise EReadError.Create('ROM exceeds 64 MiB');
  if Format.System = TRomSystem.Unknown then
    raise EReadError.Create('Unrecognized ROM header (NES, Game Boy, Game Boy Color, Game Boy Advance, Mega Drive, SNES, Nintendo 64 or Neo Geo expected)');

  Data := NormalizeRom(Data, Format);
  var Input := TBytesStream.Create(Data);
  try
    case Format.System of
      TRomSystem.N64:
        Result := TN64CoreAdapter.Create(Input, Storage, RomName);
      TRomSystem.NeoGeo:
        Result := TNeoGeoCoreAdapter.Create(Input, Storage, RomName);
      TRomSystem.NES:
        Result := TNesCoreAdapter.Create(Input, Storage, RomName);
      TRomSystem.GB:
        Result := TGBCoreAdapter.Create(Input, Storage, RomName);
      TRomSystem.GBC:
        Result := TGBCCoreAdapter.Create(Input, Storage, RomName);
      TRomSystem.GBA:
        Result := TGBACoreAdapter.Create(Input, Storage, RomName);
      TRomSystem.MD:
        Result := TMDCoreAdapter.Create(Input, Storage, RomName);
      TRomSystem.SNES:
        Result := TSnesCoreAdapter.Create(Input, Storage, RomName);
    end;
  finally
    Input.Free;
  end;
end;

end.

