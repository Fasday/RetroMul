unit SMS.Cartridge;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, SG1000.Cartridge;

{$SCOPEDENUMS ON}
type
  TSMSMapper = (Sega, Codemasters, Korean, Zemina, Nemesis, Janggun, HiCom, FourPak,
    Korean188, Fixed48K, Seojin);

  TSMSCartridge = class
  private
    FData: TBytes;
    FRAM: array[0..$7FFF] of Byte;
    FBanks: array[0..5] of Byte;
    FRegisters: array[0..3] of Byte;
    FMapper: TSMSMapper;
    FControl, FGame: Byte;
    FDirty: Boolean;
    function GetExpandedRAM: Boolean;
    function ROM(Bank, Offset, Size: Integer): Byte;
  public
    constructor Create(const Data: TBytes; MapperHint: Integer = -1);
    procedure Reset;
    function Read(Address: Word): Byte;
    procedure Write(Address: Word; Value: Byte);
    function SaveRAM: TBytes;
    procedure LoadRAM(const Data: TBytes);
    procedure SerializeState(State: TStateArchive);
    property Mapper: TSMSMapper read FMapper;
    property ExpandedRAM: Boolean read GetExpandedRAM;
    property Dirty: Boolean read FDirty write FDirty;
  end;

implementation

constructor TSMSCartridge.Create(const Data: TBytes; MapperHint: Integer);
begin
  inherited Create;
  if (Length(Data) = 0) or (Length(Data) > 4 * 1024 * 1024 + 512) then
    raise EReadError.Create('SMS cartridge must contain 1..4194304 bytes');
  var Start := 0;
  if Length(Data) mod $4000 = 512 then
    Start := 512;
  FData := Copy(Data, Start, Length(Data) - Start);
  FMapper := TSMSMapper.Sega;
  // MAME's CC0 software-list cartridge wiring is generated into this unit's
  // include. A user-selected mapper remains available for unlisted homebrew.
  // CRC32 cartridge wiring from MAME CC0 hash/sms.xml.
  case SGCRC32(FData) of
    $29822980, $8813514B, $A577CE46, $B9664AE1, $EA5C3A6F:
      FMapper := TSMSMapper.Codemasters;
    $0918FBA0, $17AB6883, $565C799F, $61E8806F, $6D309AC5:
      FMapper := TSMSMapper.Fixed48K;
    $A67F2A5C:
      FMapper := TSMSMapper.FourPak;
    $00E9809F, $4088EEB4, $6EBFE1C3, $81A36A4F, $82C09B57, $8333C86E, $8D2D695D, $98AF0236, $FBA94148:
      FMapper := TSMSMapper.HiCom;
    $192949D5:
      FMapper := TSMSMapper.Janggun;
    $18FB98A3, $8040B2FA, $89B79E77, $929222C4, $97D03541, $BF5A994A:
      FMapper := TSMSMapper.Korean;
    $380D7400:
      FMapper := TSMSMapper.Korean188;
    $E316C06D:
      FMapper := TSMSMapper.Nemesis;
    $CDBFE86E:
      FMapper := TSMSMapper.Seojin;
    $06965ED9, $0A77FA5E, $445525E2, $77EFE84A, $83F0EEDE, $9195C34C, $A05258F5, $F89AF3CC:
      FMapper := TSMSMapper.Zemina;
  end;
  if (MapperHint >= 0) and (MapperHint <= Ord(High(TSMSMapper))) then
    FMapper := TSMSMapper(MapperHint);
  var Size := Length(FData);
  SetLength(FData, ((Size + $3FFF) div $4000) * $4000);
  for var I := Size to High(FData) do
    FData[I] := $FF;
  Reset;
end;

function TSMSCartridge.GetExpandedRAM: Boolean;
begin
  Result := FMapper = TSMSMapper.Seojin;
end;

procedure TSMSCartridge.Reset;
begin
  for var I := 0 to 5 do
    FBanks[I] := I;
  if FMapper = TSMSMapper.Sega then
  begin
    FBanks[1] := 1;
    FBanks[2] := 2;
  end;
  if FMapper = TSMSMapper.Codemasters then
    FBanks[2] := 0;
  if FMapper = TSMSMapper.Nemesis then
    FBanks[0] := $0F;
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FControl := 0;
  FGame := 0;
  // Battery RAM survives resets; loading a new object initializes it to zero.
end;

function TSMSCartridge.ROM(Bank, Offset, Size: Integer): Byte;
begin
  Result := FData[(Bank * Size + Offset) mod Length(FData)];
end;

function TSMSCartridge.Read(Address: Word): Byte;
begin
  var Slot := Address div $4000;
  var Half := Address div $2000;
  if Address >= $C000 then
  begin
    if FMapper = TSMSMapper.Seojin then
      Exit(FRAM[Address and $3FFF]);
    Exit($FF);
  end;
  case FMapper of
    TSMSMapper.Fixed48K:
      Exit(FData[Integer(Address) mod Length(FData)]);
    TSMSMapper.Seojin:
      begin
        if Address < $400 then
          Exit(ROM((FGame and $0F) * 2, Address, $4000) xor $80);
        Exit(ROM(((FGame and $0F) * 2) or FBanks[Slot], Address and $3FFF, $4000) xor $80);
      end;
    TSMSMapper.Sega, TSMSMapper.Korean:
      begin
        if (Address >= $8000) and (FControl and 8 <> 0) then
          Exit(FRAM[(Address and $3FFF) + ((FControl and 4) * $1000)]);
        if Address < $400 then
          Exit(FData[Address]);
        var Bank := Integer(FBanks[Slot]);
        if FControl and 3 <> 0 then
          Inc(Bank, (4 - (FControl and 3)) * 8);
        Exit(ROM(Bank, Address and $3FFF, $4000));
      end;
    TSMSMapper.Codemasters:
      begin
        if (Address >= $A000) and (FControl and $80 <> 0) then
          Exit(FRAM[Address and $1FFF]);
        Exit(ROM(FBanks[Slot], Address and $3FFF, $4000));
      end;
    TSMSMapper.HiCom:
      begin
        if Address >= $8000 then
          Exit(ROM(0, Address and $3FFF, $4000));
        Exit(ROM(FGame, Address, $8000));
      end;
    TSMSMapper.FourPak:
      begin
        var Bank := Integer(FRegisters[Slot]);
        if Slot = 2 then
          Inc(Bank, FRegisters[0] and $30);
        Exit(ROM(Bank, Address and $3FFF, $4000));
      end;
    TSMSMapper.Korean188:
      begin
        if Address < $4000 then
          Exit(FData[Address]);
        Exit(ROM((FGame xor $1F) + (Half - 2), Address and $1FFF, $2000));
      end;
    TSMSMapper.Janggun:
      begin
        var Value := ROM(FBanks[Half] and $3F, Address and $1FFF, $2000);
        if FBanks[Half] and $80 <> 0 then
        begin
          var Flipped := 0;
          for var I := 0 to 7 do
            Flipped := Flipped or (((Value shr I) and 1) shl (7 - I));
          Value := Flipped;
        end;
        Exit(Value);
      end;
  else
    Exit(ROM(FBanks[Half], Address and $1FFF, $2000));
  end;
end;

procedure TSMSCartridge.Write(Address: Word; Value: Byte);
begin
  case FMapper of
    TSMSMapper.Sega, TSMSMapper.Korean:
      begin
        if (Address >= $8000) and (Address < $C000) and (FControl and 8 <> 0) then
        begin
          FRAM[(Address and $3FFF) + ((FControl and 4) * $1000)] := Value;
          FDirty := True;
        end;
        if Address = $FFFC then
          FControl := Value;
        if Address >= $FFFD then
          FBanks[Address - $FFFD] := Value;
        if (FMapper = TSMSMapper.Korean) and (Address = $A000) then
          FBanks[2] := Value;
      end;
    TSMSMapper.Codemasters:
      begin
        if Address = 0 then
          FBanks[0] := Value;
        if Address = $4000 then
        begin
          FControl := Value;
          FBanks[1] := Value and $7F;
        end;
        if Address = $8000 then
          FBanks[2] := Value;
        if (Address >= $A000) and (Address < $C000) and (FControl and $80 <> 0) then
        begin
          FRAM[Address and $1FFF] := Value;
          FDirty := True;
        end;
      end;
    TSMSMapper.Zemina, TSMSMapper.Nemesis:
      case Address of
        0:
          FBanks[4] := Value;
        1:
          FBanks[5] := Value;
        2:
          FBanks[2] := Value;
        3:
          FBanks[3] := Value;
      end;
    TSMSMapper.Janggun:
      case Address of
        $FFFD, $FFFE, $FFFF:
          begin
            var Slot := (Address - $FFFD) * 2;
            var Bank := (Integer(Value) mod (Length(FData) div $4000)) * 2;
            // Bank latches are bytes even when a manually selected mapper is
            // applied to a larger ROM. Narrow explicitly with Q+/R+ enabled.
            FBanks[Slot] := Bank and $FF;
            FBanks[Slot + 1] := (Bank + 1) and $FF;
          end;
        $4000:
          FBanks[2] := Value;
        $6000:
          FBanks[3] := Value;
        $8000:
          FBanks[4] := Value;
        $A000:
          FBanks[5] := Value;
      end;
    TSMSMapper.HiCom:
      if Address = $FFFF then
        FGame := Value;
    TSMSMapper.FourPak:
      case Address of
        $3FFE:
          FRegisters[0] := Value;
        $7FFF:
          FRegisters[1] := Value;
        $BFFF:
          FRegisters[2] := Value;
      end;
    TSMSMapper.Korean188:
      if Address and $6000 = $2000 then
        FGame := Value;
    TSMSMapper.Seojin:
      begin
        if Address >= $C000 then
        begin
          FRAM[Address and $3FFF] := Value;
          FDirty := True;
        end;
        if Address = $FFF0 then
          FGame := Value;
        if Address >= $FFFD then
          FBanks[Address - $FFFD] := Value;
      end;
  end;
end;

function TSMSCartridge.SaveRAM: TBytes;
begin
  SetLength(Result, SizeOf(FRAM));
  for var I := 0 to High(Result) do
    Result[I] := FRAM[I];
end;

procedure TSMSCartridge.LoadRAM(const Data: TBytes);
begin
  if Length(Data) <> SizeOf(FRAM) then
    raise EReadError.Create('SMS battery RAM must contain 32768 bytes');
  for var I := 0 to High(Data) do
    FRAM[I] := Data[I];
  FDirty := False;
end;

procedure TSMSCartridge.SerializeState(State: TStateArchive);
begin
  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FBanks, SizeOf(FBanks));
  State.Field(FRegisters, SizeOf(FRegisters));
  State.Field(FControl, SizeOf(FControl));
  State.Field(FGame, SizeOf(FGame));
  State.Field(FDirty, SizeOf(FDirty));
end;

end.

