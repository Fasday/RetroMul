unit GBA.Firmware;

interface

uses
  System.SysUtils, System.Classes;

// Unmodified emibios 0.1.6 (LGPL-3.0-or-later). The source and license are
// also embedded, and accompany the original binary in firmware/.
function LoadBuiltinGBABIOS: TBytes;

function LoadBuiltinGBABIOSSource: TBytes;

function LoadBuiltinGBABIOSLicense: TBytes;

implementation

{$R 'GBA.Firmware.res' 'GBA.Firmware.rc'}

function ResourceBytes(const Name: string): TBytes;
begin
  var Stream := TResourceStream.Create(HInstance, Name, PChar(10));
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[0], Stream.Size);
  finally
    Stream.Free;
  end;
end;

function LoadBuiltinGBABIOS: TBytes;
begin
  Result := ResourceBytes('GBA_EMIBIOS');
  if Length(Result) <> 16384 then
    raise EReadError.Create('Invalid built-in GBA BIOS resource');
end;

function LoadBuiltinGBABIOSSource: TBytes;
begin
  Result := ResourceBytes('GBA_EMIBIOS_SOURCE');
end;

function LoadBuiltinGBABIOSLicense: TBytes;
begin
  Result := ResourceBytes('GBA_EMIBIOS_LICENSE');
end;

end.

