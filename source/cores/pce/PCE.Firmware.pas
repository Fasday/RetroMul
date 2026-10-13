unit PCE.Firmware;

interface

uses
  System.SysUtils, System.Classes, PCE.Cartridge;

function DefaultPCEBIOSName(Model: TPCEModel): string;

function LoadBuiltinPCEBIOS(const Name: string): TBytes;

implementation

{$R 'PCE.Firmware.res' 'PCE.Firmware.rc'}

function DefaultPCEBIOSName(Model: TPCEModel): string;
begin
  if not PCEHasCD(Model) then
    raise EArgumentException.Create('System Card requires a CD model');

  if PCEIsSuperCD(Model) then
  begin
    if Model = TPCEModel.TurboDuo then
      Result := 'syscard3u.pce'
    else
      Result := 'syscard3.pce';
  end
  else
  begin
    if Model = TPCEModel.TurboGrafxCD then
      Result := 'syscard2u.pce'
    else
      Result := 'syscard2.pce';
  end;
end;

function LoadBuiltinPCEBIOS(const Name: string): TBytes;
const
  Names: array[0..4] of string = ('syscard1.pce', 'syscard2.pce', 'syscard2u.pce', 'syscard3.pce', 'syscard3u.pce');
  Resources: array[0..4] of string = ('PCE_SYSCARD1', 'PCE_SYSCARD2', 'PCE_SYSCARD2U', 'PCE_SYSCARD3', 'PCE_SYSCARD3U');
  CRCs: array[0..4] of Cardinal = ($3F9F95A4, $283B74E0, $FF2A5EC3, $6D9A73EF, $2B5B75FE);
begin
  for var i := Low(Names) to High(Names) do
    if SameText(Name, Names[i]) then
    begin
      var Stream := TResourceStream.Create(HInstance, Resources[i], PChar(10));
      try
        if Stream.Size <> 262144 then
          raise EReadError.Create('Invalid built-in System Card size');

        SetLength(Result, Stream.Size);
        Stream.ReadBuffer(Result[0], Length(Result));
      finally
        Stream.Free;
      end;
      if PCECRC32(Result) <> CRCs[i] then
        raise EReadError.Create('Invalid built-in System Card checksum');

      Exit;
    end;

  raise EReadError.CreateFmt('Unknown built-in System Card: %s', [Name]);
end;

end.

