unit Saturn.Firmware;

interface

uses
  System.SysUtils;

function DefaultSaturnBIOSName(Region: Byte): string;

function LoadBuiltinSaturnBIOS(const Name: string): TBytes;

function LoadSaturnCDFirmware: TBytes;

implementation

uses
  System.Classes;

{$R 'Saturn.Firmware.res' 'Saturn.Firmware.rc'}

function LoadSaturnCDFirmware: TBytes;
begin
  var Stream := TResourceStream.Create(HInstance, 'SATURN_CDB_106', PChar(10));
  try
    if Stream.Size <> 65536 then
      raise EReadError.Create('Invalid SH-1 CD firmware size');

    SetLength(Result, Stream.Size);
    Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

function DefaultSaturnBIOSName(Region: Byte): string;
begin
  if Region in [1, 2] then
    Result := 'sega_101.bin'
  else
    Result := 'mpr-17933.bin';
end;

function LoadBuiltinSaturnBIOS(const Name: string): TBytes;
const
  Names: array[0..2] of string = ('mpr-17933.bin', 'sega_100.bin', 'sega_101.bin');
  IDs: array[0..2] of string = ('SATURN_BIOS_US_EU', 'SATURN_BIOS_JP_100', 'SATURN_BIOS_JP_101');
begin
  for var i := Low(Names) to High(Names) do
    if SameText(Name, Names[i]) then
    begin
      var Stream := TResourceStream.Create(HInstance, IDs[i], PChar(10));
      try
        if Stream.Size <> $80000 then
          raise EReadError.Create('Invalid built-in Saturn BIOS size');
        SetLength(Result, Stream.Size);
        Stream.ReadBuffer(Result[0], Length(Result));
      finally
        Stream.Free;
      end;
      Exit;
    end;
  raise EReadError.CreateFmt('Unknown built-in Saturn BIOS: %s', [Name]);
end;

end.

