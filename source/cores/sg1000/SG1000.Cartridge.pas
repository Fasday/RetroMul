unit SG1000.Cartridge;

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots;

{$SCOPEDENUMS ON}
type
  TSGMapper = (Standard, Ram2K, Ram8K, Basic32K, Music10K, DahjeeA, DahjeeB, SegaBanked, System2K,
    Terebi, Survivors, Megacart);

  TSGCartridge = class
  private
    FData: TBytes;
    FRAM: array[0..$7FFF] of Byte;
    FMapper: TSGMapper;
    FBanks: array[0..2] of Byte;
    FBankControl: Byte;
    FTabletX, FTabletY, FTabletData, FBlock, FBlockLatch: Byte;
    FTabletPressed: Boolean;
    function RAMIndex(Address: Integer): Integer;
  public
    constructor Create(const Data: TBytes; MapperHint: Integer = -1);
    procedure Reset;
    function Read(Address: Word): Byte;
    procedure Write(Address: Word; Value: Byte);
    procedure WritePort(Port, Value: Byte);
    procedure SetTablet(X, Y: Integer; Pressed: Boolean);
    function OverridesSystemRAM: Boolean;
    procedure SerializeState(State: TStateArchive);
    property Mapper: TSGMapper read FMapper;
  end;

function SGCRC32(const Data: TBytes): Cardinal;

implementation

function SGCRC32(const Data: TBytes): Cardinal;
begin
  Result := $FFFFFFFF;
  for var Value in Data do
  begin
    Result := Result xor Value;
    for var Bit := 0 to 7 do
      if Result and 1 <> 0 then
        Result := (Result shr 1) xor $EDB88320
      else
        Result := Result shr 1;
  end;
  Result := Result xor $FFFFFFFF;
end;

constructor TSGCartridge.Create(const Data: TBytes; MapperHint: Integer);
begin
  inherited Create;
  if (Length(Data) = 0) or (Length(Data) > $400000) then
    raise EReadError.Create('SG-1000/SC-3000 cartridge must contain 1..4194304 bytes');

  FData := Copy(Data);
  FMapper := TSGMapper.Standard;
  if Length(Data) > $C000 then
    FMapper := TSGMapper.SegaBanked;
  case SGCRC32(FData) of
    // Cartridge wiring identified by CRC32; metadata from MAME CC0 software lists.
    $1D1A0CA3, $AF4F14BC, $B7EC1307, $CDF7BDF3, $F691F9C7:
      FMapper := TSGMapper.Ram2K;
    $092F29D6:
      FMapper := TSGMapper.Ram8K;
    $55F47493, $5D9F11CA, $78A37CBC, $A46E3C73, $D5E919C1:
      FMapper := TSGMapper.Basic32K;
    $2EC28526, $622010E1:
      FMapper := TSGMapper.Music10K;
    $223397A1, $281D2888, $29E047CC, $2E7166D5, $306D5F78, $5CBD1163, $C550B4F0, $CE5648C3, $DF7CBFA5, $E0816BB7, $FC87463C:
      FMapper := TSGMapper.DahjeeA;
    $2E366CCF, $69FC1494, $AAAC12CF, $D2EDD329, $FFC4EE3F:
      FMapper := TSGMapper.DahjeeB;
    // Korean Circus Charlie requires 2 KiB at $C000, mirrored through $FFFF.
    // The ordinary 1 KiB SG RAM aliases its stack and game work area.
      $7F7F009D:
      FMapper := TSGMapper.System2K;
    $DD4A661B:
      FMapper := TSGMapper.Terebi;
    // These unbanked translations are padded to 65535 bytes, not banked carts.
      $3003D9BD, $626E30CC:
      FMapper := TSGMapper.Standard;
  end;
  if Length(Data) >= $200000 then
    FMapper := TSGMapper.Survivors;
  if Length(Data) >= $400000 then
    FMapper := TSGMapper.Megacart;
  if (MapperHint >= 0) and (MapperHint <= Ord(High(TSGMapper))) then
    FMapper := TSGMapper(MapperHint);
  if FMapper = TSGMapper.SegaBanked then
  begin
    var OriginalSize := Length(FData);
    SetLength(FData, ((OriginalSize + $3FFF) div $4000) * $4000);
    for var I := OriginalSize to High(FData) do
      FData[I] := $FF;
  end;
  Reset;
end;

procedure TSGCartridge.Reset;
begin
  FillChar(FRAM, SizeOf(FRAM), 0);
  FBanks[0] := 0;
  FBanks[1] := 1;
  FBanks[2] := 2;
  FBankControl := 0;
  FBlock := $3F;
  FBlockLatch := 0;
  FTabletData := 0;
  FTabletX := 128;
  FTabletY := 96;
  FTabletPressed := False;
end;

function TSGCartridge.RAMIndex(Address: Integer): Integer;
begin
  Result := -1;
  case FMapper of
    TSGMapper.Ram2K:
      if (Address >= $8000) and (Address < $A000) then
        Result := Address and $7FF;
    TSGMapper.Ram8K, TSGMapper.Music10K:
      if (Address >= $8000) and (Address < $A000) then
        Result := Address and $1FFF;
    TSGMapper.Basic32K:
      if Address >= $8000 then
        Result := Address - $8000;
    TSGMapper.Survivors, TSGMapper.Megacart:
      if Address >= $8000 then
        Result := Address - $8000;
    TSGMapper.SegaBanked:
      if (Address >= $8000) and (Address < $C000) and (FBankControl and 8 <> 0) then
        Result := (Address and $3FFF) + ((FBankControl and 4) * $1000);
    TSGMapper.DahjeeA:
      if (Address >= $2000) and (Address < $4000) then
        Result := Address and $1FFF;
  end;
  if Address >= $C000 then
    case FMapper of
      TSGMapper.Music10K:
        Result := $2000 + (Address and $7FF);
      TSGMapper.DahjeeA:
        Result := $2000 + (Address and $3FF);
      TSGMapper.DahjeeB:
        Result := Address and $1FFF;
      TSGMapper.System2K:
        Result := Address and $7FF;
    end;
end;

function TSGCartridge.OverridesSystemRAM: Boolean;
begin
  Result := FMapper in [TSGMapper.Basic32K, TSGMapper.Music10K,
      TSGMapper.DahjeeA, TSGMapper.DahjeeB, TSGMapper.System2K, TSGMapper.Survivors, TSGMapper.Megacart];
end;

function TSGCartridge.Read(Address: Word): Byte;
begin
  if FMapper = TSGMapper.Terebi then
  begin
    if Address = $8000 then
      Exit(Ord(not FTabletPressed));
    if Address = $A000 then
      Exit(FTabletData);
  end;
  var Index := RAMIndex(Address);
  if Index >= 0 then
    Result := FRAM[Index]
  else if FMapper in [TSGMapper.Survivors, TSGMapper.Megacart] then
    Result := FData[((Integer(FBlock) * $8000) + (Address and $7FFF)) mod Length(FData)]
  else if (FMapper = TSGMapper.SegaBanked) and (Address >= $400) and (Address < $C000) then
    Result := FData[(Integer(FBanks[Address div $4000]) * $4000 + (Address and $3FFF)) mod Length(FData)]
  else
    Result := FData[Integer(Address) mod Length(FData)];
end;

procedure TSGCartridge.Write(Address: Word; Value: Byte);
begin
  if (FMapper = TSGMapper.Terebi) and (Address = $6000) then
  begin
    if Value and 1 <> 0 then
      FTabletData := FTabletX
    else
      FTabletData := FTabletY + $20;
    Exit;
  end;
  if (FMapper = TSGMapper.SegaBanked) and (Address >= $FFFC) then
  begin
    if Address = $FFFC then
      FBankControl := Value
    else
      FBanks[Address - $FFFD] := Value;
  end;
  var Index := RAMIndex(Address);
  if Index >= 0 then
    FRAM[Index] := Value;
end;

procedure TSGCartridge.SetTablet(X, Y: Integer; Pressed: Boolean);
begin
  FTabletX := System.Math.EnsureRange(X, 4, 251);
  FTabletY := System.Math.EnsureRange(Y, 0, 191);
  FTabletPressed := Pressed;
end;

procedure TSGCartridge.WritePort(Port, Value: Byte);
begin
  if Port and $E0 <> $E0 then
    Exit;
  if FMapper = TSGMapper.Survivors then
  begin
    FBlock := $3F;
    if Value and $80 <> 0 then
      FBlock := (Value and $1F) or ((Value and $40) shr 1);
  end
  else if FMapper = TSGMapper.Megacart then
  begin
    FBlock := (Value and $1F) or ((Value and $C0) shr 1);
  end;
end;

procedure TSGCartridge.SerializeState(State: TStateArchive);
begin
  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FBanks, SizeOf(FBanks));
  State.Field(FBankControl, SizeOf(FBankControl));
  State.Field(FTabletX, SizeOf(FTabletX));
  State.Field(FTabletY, SizeOf(FTabletY));
  State.Field(FTabletData, SizeOf(FTabletData));
  State.Field(FTabletPressed, SizeOf(FTabletPressed));
  State.Field(FBlock, SizeOf(FBlock));
  State.Field(FBlockLatch, SizeOf(FBlockLatch));
end;

end.

