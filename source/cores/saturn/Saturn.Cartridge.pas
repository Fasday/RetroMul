unit Saturn.Cartridge;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots;

type
  TSaturnCartridge = class
  private
    FKind: Integer;
    FData: TBytes;
    FDirty: Boolean;
    function Index(Address: Cardinal): Integer;
  public
    // 0: empty, 1/4: DRAM MiB, 16: ROM, $21..$24: backup ID.
    constructor Create(Kind: Integer; const ROM: TBytes = nil);
    procedure Reset;
    function Read(Address: Cardinal): Byte;
    procedure Write(Address: Cardinal; Value: Byte);
    function Backup: TBytes;
    procedure LoadBackup(const Data: TBytes);
    procedure SerializeState(Archive: TStateArchive);
    property Kind: Integer read FKind;
    property Dirty: Boolean read FDirty write FDirty;
  end;

implementation

uses
  System.Hash;

constructor TSaturnCartridge.Create(Kind: Integer; const ROM: TBytes);
begin
  inherited Create;
  FKind := Kind;
  case Kind of
    0:
      ;
    1, 4:
      SetLength(FData, Kind * 1024 * 1024);
    16:
      begin
        if (Length(ROM) <> $100000) and (Length(ROM) <> $200000) and (Length(ROM) <> $400000) then
          raise EReadError.Create('Saturn ROM cartridge must contain 1, 2 or 4 MiB');
        FData := Copy(ROM);
      end;
    $21..$24:
      begin
        SetLength(FData, $40000 shl (Kind and 15));
        var Signature: AnsiString := 'BackUpRam Format';
      // External backup volumes use 256-byte allocation blocks.
        for var I := 0 to 15 do
          Move(Signature[1], FData[I * 16], 16);
      end;
  else
    raise EArgumentOutOfRangeException.Create('Saturn cartridge type');
  end;
end;

procedure TSaturnCartridge.Reset;
begin
  if FKind in [1, 4] then
    FillChar(FData[0], Length(FData), 0);
end;

function TSaturnCartridge.Index(Address: Cardinal): Integer;
begin
  Result := -1;
  case FKind of
    1, 4:
      if (Address >= $02400000) and (Address < $02800000) then
      begin
        if FKind = 4 then
          Result := Address and $3FFFFF
        else
          Result := ((Address and $200000) shr 2) or (Address and $7FFFF);
      end;
    16:
      if (Address >= $02000000) and (Address < $02400000) then
        Result := Address and Cardinal(Length(FData) - 1);
    $21..$24:
      if (Address >= $04000000) and (Address < $04FFFFFC) and Odd(Address) then
        Result := (Address shr 1) and Cardinal(Length(FData) - 1);
  end;
end;

function TSaturnCartridge.Read(Address: Cardinal): Byte;
begin
  Result := $FF;
  if (Address >= $04FFFFFC) and Odd(Address) then
  begin
    case FKind of
      1:
        Result := $5A;
      4:
        Result := $5C;
      $21..$24:
        Result := FKind;
    end;
    Exit;
  end;
  var I := Index(Address);
  if I >= 0 then
    Result := FData[I];
end;

procedure TSaturnCartridge.Write(Address: Cardinal; Value: Byte);
begin
  if FKind = 16 then
    Exit;
  var I := Index(Address);
  if (I >= 0) and (FData[I] <> Value) then
  begin
    FData[I] := Value;
    if FKind in [$21..$24] then
      FDirty := True;
  end;
end;

function TSaturnCartridge.Backup: TBytes;
begin
  Result := nil;
  if FKind in [$21..$24] then
    Result := Copy(FData);
end;

procedure TSaturnCartridge.LoadBackup(const Data: TBytes);
begin
  if not (FKind in [$21..$24]) or (Length(Data) <> Length(FData)) then
    raise EReadError.Create('Saturn backup cartridge size mismatch');
  FData := Copy(Data);
  FDirty := False;
end;

procedure TSaturnCartridge.SerializeState(Archive: TStateArchive);
begin
  var Kind := FKind;
  Archive.Field(Kind, SizeOf(Kind));
  if Kind <> FKind then
    raise EReadError.Create('Saturn snapshot cartridge mismatch');
  if FKind = 16 then
  begin
    var Hash := THashSHA2.Create;
    Hash.Update(FData);
    var Digest := Hash.HashAsBytes;
    var Expected := Copy(Digest);
    Archive.Field(Digest[0], Length(Digest));
    if Archive.Loading and not CompareMem(@Digest[0], @Expected[0], Length(Digest)) then
      raise EReadError.Create('Saturn snapshot ROM cartridge mismatch');
  end
  else if Length(FData) > 0 then
    Archive.Field(FData[0], Length(FData));
  if Archive.Loading and (FKind in [$21..$24]) then
    FDirty := True;
end;

end.

