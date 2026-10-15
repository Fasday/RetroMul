unit NGP.Firmware;

interface

uses
  System.SysUtils;

function LoadNGPBIOS(Color: Boolean): TBytes;

implementation

uses
  System.Classes;

{$R 'NGP.Firmware.res' 'NGP.Firmware.rc'}

function LoadNGPBIOS(Color: Boolean): TBytes;
begin
  var ResourceName: string;
  if Color then
    ResourceName := 'NGPC_BIOS'
  else
    ResourceName := 'NGP_BIOS';

  var Stream := TResourceStream.Create(HInstance, ResourceName, PChar(10));
  try
    if Stream.Size <> $10000 then
      raise EReadError.Create('Invalid built-in Pocket BIOS size');

    SetLength(Result, $10000);
    Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

end.

