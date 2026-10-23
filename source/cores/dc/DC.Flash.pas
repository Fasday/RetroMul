unit DC.Flash;

// The 128 KiB system flash ROM: generated contents (factory region/broadcast
// settings and the user system configuration block) and the command
// sequences of its MBM29LV002-compatible interface for direct SH-4 writes.
// Layout: Marcus Comstedt's flash ROM notes; KallistiOS flashrom.c.
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, DC.Types;

type
  TDCLanguage = (Japanese, English, German, French, Spanish, Italian);

  TDCFlashState = record
    Cycle: Integer;     // command sequence position
    Command: Cardinal;
    Dirty: Boolean;     // contents changed since the last save
  end;

  TDCFlash = class
  private
    FData: PByte;
  public
    S: TDCFlashState;
    constructor Create(Data: PByte);
    procedure Reset;
    // Fresh contents for a console of the given region.
    procedure Generate(Region: TDCRegion; Broadcast: TDCBroadcast; Language: TDCLanguage; Seconds: Cardinal);
    // True when the contents hold a factory region record.
    function Valid: Boolean;
    function Region: TDCRegion;
    procedure Write(Offset, Value: Cardinal);
    procedure SerializeState(Archive: TStateArchive);
  end;

function DCFlashCRC(Data: PByte; Count: Integer): Word;

implementation

const
  FactoryOffset = $1A000;
  UserOffset = $1C000;
  UserSize = $4000;

function DCFlashCRC(Data: PByte; Count: Integer): Word;
begin
  var N: Cardinal := $FFFF;
  for var I := 0 to Count - 1 do
  begin
    N := N xor (Cardinal(Data[I]) shl 8);
    for var Bit := 0 to 7 do
      if (N and $8000) <> 0 then
        N := ((N shl 1) xor $1021) and $FFFF
      else
        N := (N shl 1) and $FFFF;
  end;
  Result := Word(not N);
end;

constructor TDCFlash.Create(Data: PByte);
begin
  inherited Create;
  FData := Data;
  Reset;
end;

procedure TDCFlash.Reset;
begin
  S := Default(TDCFlashState);
end;

procedure TDCFlash.Generate(Region: TDCRegion; Broadcast: TDCBroadcast; Language: TDCLanguage; Seconds: Cardinal);
begin
  FillChar(FData^, DCFlashSize, $FF);
  // Factory record (and its copy): two zero digits, the region, its default
  // language (Japanese or English) and the broadcast standard, the machine
  // name, then serial digits. Japan 00000, USA 00110, Europe 00211.
  var DefaultLanguage: AnsiChar := '1';
  if Region = TDCRegion.Japan then
    DefaultLanguage := '0';
  var Factory: AnsiString := '00' + AnsiChar(Ord('0') + Ord(Region)) + DefaultLanguage +
    AnsiChar(Ord('0') + Ord(Broadcast)) + 'Dreamcast';
  while Length(Factory) < 53 do
    Factory := Factory + ' ';
  Factory := Factory + '00000000000000000000000000000000';
  for var Copy_ := 0 to 1 do
  begin
    var Base := FactoryOffset + Copy_ * $A0;
    for var I := 1 to Length(Factory) do
      FData[Base + I - 1] := Ord(Factory[I]);
  end;
  // Console ID used by SYSINFO (8 bytes at 1A056).
  for var I := 0 to 7 do
    FData[$1A056 + I] := Byte($30 + I);
  // User partition: header, the system configuration block and the bitmap.
  var Header: AnsiString := 'KATANA_FLASH____';
  for var I := 1 to Length(Header) do
    FData[UserOffset + I - 1] := Ord(Header[I]);
  FData[UserOffset + 16] := 2;
  FData[UserOffset + 17] := 0;
  var Block := FData + UserOffset + 64;
  FillChar(Block^, 64, $FF);
  Block[0] := 5;
  Block[1] := 0;
  PCardinal(Block + 2)^ := Seconds;
  Block[6] := $FF;
  Block[7] := Ord(Language);
  Block[8] := 0;   // stereo
  Block[9] := 1;   // autostart
  PWord(Block + 62)^ := DCFlashCRC(Block, 62);
  // Allocation bitmap in the last block: a cleared bit marks a used block.
  var Bitmap := FData + UserOffset + UserSize - 64;
  Bitmap[0] := $3F;
  S.Dirty := True;
end;

function TDCFlash.Valid: Boolean;
begin
  Result := CompareMem(FData + FactoryOffset + 5, PAnsiChar(AnsiString('Dreamcast')), 9) and
    (FData[FactoryOffset + 2] in [Ord('0')..Ord('2')]);
end;

function TDCFlash.Region: TDCRegion;
begin
  case FData[FactoryOffset + 2] of
    Ord('0'): Result := TDCRegion.Japan;
    Ord('1'): Result := TDCRegion.USA;
  else
    Result := TDCRegion.Europe;
  end;
end;

procedure TDCFlash.Write(Offset, Value: Cardinal);
begin
  // AMD-style unlock cycles at 5555/2AAA, then program (A0), erase (80 .. 30
  // sector, 80 .. 10 chip) or reset (F0). Programming only clears bits.
  Offset := Offset and (DCFlashSize - 1);
  Value := Value and $FF;
  if Value = $F0 then
  begin
    S.Cycle := 0;
    Exit;
  end;
  case S.Cycle of
    0, 3:
      if ((Offset and $7FFF) = $5555) and (Value = $AA) then
        Inc(S.Cycle)
      else
        S.Cycle := 0;
    1, 4:
      if ((Offset and $7FFF) = $2AAA) and (Value = $55) then
        Inc(S.Cycle)
      else
        S.Cycle := 0;
    2:
      if (Offset and $7FFF) = $5555 then
      begin
        S.Command := Value;
        if Value = $A0 then
          S.Cycle := 6
        else if Value = $80 then
          S.Cycle := 3
        else
          S.Cycle := 0;
      end
      else
        S.Cycle := 0;
    5:
      begin
        if Value = $10 then
          FillChar(FData^, DCFlashSize, $FF)
        else if Value = $30 then
        begin
          // Sectors: 64 KiB, 32 KiB, 8 KiB, 8 KiB, 16 KiB.
          var First, Size: Cardinal;
          if Offset < $10000 then
          begin
            First := 0;
            Size := $10000;
          end
          else if Offset < $18000 then
          begin
            First := $10000;
            Size := $8000;
          end
          else if Offset < $1A000 then
          begin
            First := $18000;
            Size := $2000;
          end
          else if Offset < $1C000 then
          begin
            First := $1A000;
            Size := $2000;
          end
          else
          begin
            First := $1C000;
            Size := $4000;
          end;
          FillChar((FData + First)^, Size, $FF);
        end;
        S.Dirty := True;
        S.Cycle := 0;
      end;
    6:
      begin
        FData[Offset] := FData[Offset] and Byte(Value);
        S.Dirty := True;
        S.Cycle := 0;
      end;
  else
    S.Cycle := 0;
  end;
end;

procedure TDCFlash.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(S.Cycle, SizeOf(S.Cycle));
  Archive.Field(S.Command, SizeOf(S.Command));
  if Archive.Loading and ((S.Cycle < 0) or (S.Cycle > 6)) then
    raise EReadError.Create('Dreamcast snapshot flash state');
end;

end.
