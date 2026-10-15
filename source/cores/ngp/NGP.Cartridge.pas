unit NGP.Cartridge;

interface

uses
  System.Classes, System.SysUtils, Core.Snapshots;

type
  TNGPCartridge = class
  private
    FOriginal, FData: TBytes;
    FState: array[0..1] of Byte;
    FCommand: array[0..1] of Byte;
    FDirty, FColor: Boolean;
    FEntry: Cardinal;
    FTitle: string;
    function ChipSize(Chip: Integer): Integer;
  public
    constructor Create(const Data: TBytes);
    class function Recognizes(const Data: TBytes): Boolean; static;
    function ReadByte(Offset: Cardinal): Byte;
    procedure WriteByte(Offset: Cardinal; Value: Byte);
    procedure Reset;
    procedure LoadBackup(const Data: TBytes);
    function Backup: TBytes;
    procedure SerializeState(State: TStateArchive);
    property Color: Boolean read FColor;
    property Entry: Cardinal read FEntry;
    property Title: string read FTitle;
    property Identity: TBytes read FOriginal;
    property Dirty: Boolean read FDirty;
  end;

implementation

class function TNGPCartridge.Recognizes(const Data: TBytes): Boolean;
begin
  Result := (Length(Data) >= $40) and (Length(Data) <= $400000);
  if not Result then
    Exit;

  var Copyright := TEncoding.ASCII.GetString(Data, 0, 28);
  Result := ((Copyright = 'COPYRIGHT BY SNK CORPORATION') or
    (Copyright.TrimRight = 'COPYRIGHT BY SNK CORPORATION') or
    (Copyright.TrimRight = ' LICENSED BY SNK CORPORATION') or
    (Copyright.Trim = 'LICENSED BY SNK CORPORATION')) and
    (Data[$23] in [$00, $10]);
end;

constructor TNGPCartridge.Create(const Data: TBytes);
begin
  inherited Create;
  if not Recognizes(Data) then
    raise EReadError.Create('Invalid Neo Geo Pocket cartridge header (maximum 4 MiB)');

  FEntry := Cardinal(Data[$1C]) or (Cardinal(Data[$1D]) shl 8) or
    (Cardinal(Data[$1E]) shl 16) or (Cardinal(Data[$1F]) shl 24);
  if not ((FEntry >= $200040) and (FEntry < $200000 + Cardinal(Length(Data))) and (FEntry < $400000)) and
    not ((Length(Data) > $200000) and (FEntry >= $800000) and
    (FEntry < $800000 + Cardinal(Length(Data) - $200000))) then
    raise EReadError.Create('Neo Geo Pocket entry point is outside the cartridge');

  FOriginal := Copy(Data);
  FColor := Data[$23] = $10;
  FTitle := TEncoding.ASCII.GetString(Data, $24, 12).Replace(#0, '').Trim;
  var Size := $80000;
  while Size < Length(Data) do
    Size := Size * 2;
  SetLength(FData, Size);
  FillChar(FData[0], Size, $FF);
  Move(Data[0], FData[0], Length(Data));
end;

function TNGPCartridge.ChipSize(Chip: Integer): Integer;
begin
  Result := Length(FData) - Chip * $200000;
  if Result > $200000 then
    Result := $200000;
  if Result < 0 then
    Result := 0;
end;

procedure TNGPCartridge.Reset;
begin
  FillChar(FState, SizeOf(FState), 0);
  FillChar(FCommand, SizeOf(FCommand), 0);
end;

function TNGPCartridge.ReadByte(Offset: Cardinal): Byte;
begin
  Result := $FF;
  if Offset >= Cardinal(Length(FData)) then
    Exit;

  var Chip := Integer(Offset div $200000);
  if FState[Chip] = 4 then
  begin
    case Offset and $1FFFFF of
      0, $7C000, $FC000, $1FC000:
        Result := $98;
      1, $7C001, $FC001, $1FC001:
        case ChipSize(Chip) of
          $80000:
            Result := $AB;
          $100000:
            Result := $2C;
        else
          Result := $2F;
        end;
      2, $7C002, $FC002, $1FC002:
        Result := $02;
      3, $7C003, $FC003, $1FC003:
        Result := $80;
    end;
  end
  else
    Result := FData[Offset];
end;

procedure TNGPCartridge.WriteByte(Offset: Cardinal; Value: Byte);
begin
  if Offset >= Cardinal(Length(FData)) then
    Exit;

  var Chip := Integer(Offset div $200000);
  var Addr := Offset and $1FFFFF;

  // In program mode F0 is data, including the valid 1->0 transitions.
  if FState[Chip] = 3 then
  begin
    FData[Offset] := FData[Offset] and Value;
    FDirty := True;
    FState[Chip] := 0;
    Exit;
  end;

  if Value = $F0 then
  begin
    FState[Chip] := 0;
    FCommand[Chip] := 0;
    Exit;
  end;

  case FState[Chip] of
    0, 4:
      if (Addr = $5555) and (Value = $AA) then
        FState[Chip] := 1;
    1:
      if (Addr = $2AAA) and (Value = $55) then
        FState[Chip] := 2
      else
        FState[Chip] := 0;
    2:
      begin
        FState[Chip] := 0;
        if FCommand[Chip] = $80 then
        begin
          if (Value = $10) and (Addr = $5555) then
          begin
            FillChar(FData[Chip * $200000], ChipSize(Chip), $FF);
            FDirty := True;
          end
          else if Value = $30 then
          begin
            var Size := $10000;
            var Base := Integer(Addr) and not $FFFF;
            var Top := ChipSize(Chip) - $10000;
            if Integer(Addr) >= Top then
            begin
              case Integer(Addr) - Top of
                $0000..$7FFF:
                  begin
                    Base := Top;
                    Size := $8000;
                  end;
                $8000..$9FFF:
                  begin
                    Base := Top + $8000;
                    Size := $2000;
                  end;
                $A000..$BFFF:
                  begin
                    Base := Top + $A000;
                    Size := $2000;
                  end;
              else
                begin
                  Base := Top + $C000;
                  Size := $4000;
                end;
              end;
            end;
            FillChar(FData[Chip * $200000 + Base], Size, $FF);
            FDirty := True;
          end;
          FCommand[Chip] := 0;
        end
        else if Addr = $5555 then
          case Value of
            $90:
              FState[Chip] := 4;
            $A0:
              FState[Chip] := 3;
            $80:
              FCommand[Chip] := $80;
          end;
      end;
  end;
end;

function TNGPCartridge.Backup: TBytes;
begin
  Result := Copy(FData);
end;

procedure TNGPCartridge.LoadBackup(const Data: TBytes);
begin
  if Length(Data) <> Length(FData) then
    raise EReadError.Create('Invalid Neo Geo Pocket flash save size');

  FData := Copy(Data);
  FDirty := False;
  Reset;
end;

procedure TNGPCartridge.SerializeState(State: TStateArchive);
begin
  State.Field(FData[0], Length(FData));
  State.Field(FState, SizeOf(FState));
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FDirty, SizeOf(FDirty));
  if State.Loading then
  begin
    for var S in FState do
      if S > 4 then
        raise EReadError.Create('Invalid Pocket flash command');

    FDirty := True;
  end;
end;

end.

