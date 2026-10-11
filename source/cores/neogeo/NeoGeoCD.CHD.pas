unit NeoGeoCD.CHD;

interface

uses
  System.SysUtils, System.Classes;

type
  ICHDSource = interface
    ['{D71190B0-3E47-44E7-94E8-6E073971BC5B}']
    function Size: Int64;
    function Metadata(Tag, Index: Cardinal): string;
    function ReadAt(Position: Int64; var Buffer; Count: Integer): Integer;
  end;

  // Independent positions over a shared, immutable CHD with a one-hunk cache.
  TCHDStream = class(TStream)
  private
    FSource: ICHDSource;
    FPosition: Int64;
  protected
    function GetSize: Int64; override;
  public
    constructor Create(const Source: ICHDSource);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

// Takes ownership of the stream, including on failure.
function OpenCHD(Stream: TStream): ICHDSource;

implementation

uses
  System.Math, CHD, CHD.Common;

type
  TCHDSource = class(TInterfacedObject, ICHDSource)
  private
    FImage: TCHDFile;
    FSize: Int64;
  public
    constructor Create(Stream: TStream);
    destructor Destroy; override;
    function Size: Int64;
    function Metadata(Tag, Index: Cardinal): string;
    function ReadAt(Position: Int64; var Buffer; Count: Integer): Integer;
  end;

constructor TCHDSource.Create(Stream: TStream);
begin
  inherited Create;
  try
    FImage := TCHDFile.Create(Stream, True);
  except
    on E: ECHDError do
      raise EReadError.Create('Neo Geo CD CHD: ' + E.Message);
  end;

  var Header := FImage.Header;
  if (Header.LogicalBytes = 0) or
    (Header.LogicalBytes > UInt64(2) * 1024 * 1024 * 1024) or
    (Header.HunkBytes = 0) or (Header.HunkBytes > 1024 * 1024) or
    (Header.UnitBytes <> 2448) then
    raise EReadError.Create('Unsupported Neo Geo CD CHD geometry');

  FSize := Int64(Header.LogicalBytes);
end;

destructor TCHDSource.Destroy;
begin
  FImage.Free;
  inherited;
end;

function TCHDSource.Size: Int64;
begin
  Result := FSize;
end;

function TCHDSource.Metadata(Tag, Index: Cardinal): string;
var
  Value: TCHDMetadata;
begin
  if not FImage.FindMetadata(Tag, Index, Value) then
    Exit('');

  if Length(Value.Data) >= 1024 then
    raise EReadError.Create('CHD track metadata exceeds limit');

  Result := Value.AsString;
end;

function TCHDSource.ReadAt(Position: Int64; var Buffer; Count: Integer): Integer;
var
  Bytes: TBytes;
begin
  if (Position < 0) or (Position > FSize) then
    raise EReadError.Create('CHD read outside image');

  Count := Integer(Min(Int64(Max(0, Count)), FSize - Position));
  if Count = 0 then
    Exit(0);

  SetLength(Bytes, Count);
  try
    Result := FImage.ReadAt(UInt64(Position), Bytes, 0, Count);
  except
    on E: ECHDError do
      raise EReadError.Create('Neo Geo CD CHD: ' + E.Message);
  end;

  Move(Bytes[0], Buffer, Result);
end;

constructor TCHDStream.Create(const Source: ICHDSource);
begin
  inherited Create;
  if Source = nil then
    raise EArgumentNilException.Create('CHD source is required');

  FSource := Source;
end;

function TCHDStream.GetSize: Int64;
begin
  Result := FSource.Size;
end;

function TCHDStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := FSource.ReadAt(FPosition, Buffer, Count);
  Inc(FPosition, Result);
end;

function TCHDStream.Write(const Buffer; Count: Longint): Longint;
begin
  raise EWriteError.Create('CHD is read-only');
end;

function TCHDStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
var
  Base, Limit: Int64;
begin
  Limit := FSource.Size;
  case Origin of
    soBeginning:
      Base := 0;
    soCurrent:
      Base := FPosition;
    soEnd:
      Base := Limit;
  else
    raise EStreamError.Create('Invalid CHD seek origin');
  end;

  // Check before adding, including Low/High(Int64) offsets.
  if (Offset < -Base) or (Offset > Limit - Base) then
    raise EStreamError.Create('CHD seek outside image');

  Result := Base + Offset;
  FPosition := Result;
end;

function OpenCHD(Stream: TStream): ICHDSource;
begin
  Result := TCHDSource.Create(Stream);
end;

end.

