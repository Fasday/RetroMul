unit SG1000.Disk;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots;

type
  TSGSector = record
    Cylinder, Head, ID, SizeCode, Status1, Status2: Byte;
    Data: TBytes;
  end;

  TSGTrack = record
    Cylinder, Head: Byte;
    Sectors: TArray<TSGSector>;
  end;

  TSGDisk = class
  private
    FTracks: TArray<TSGTrack>;
    FRaw, FProtected, FDirty: Boolean;
    function TrackIndex(Cylinder, Head: Integer): Integer;
    function SectorIndex(Track, ID, SizeCode: Integer): Integer;
  public
    constructor Create(const Image: TBytes; WriteProtected: Boolean = False);
    function Read(Cylinder, Head, ID, SizeCode: Integer; out Data: TBytes; out Status1, Status2: Byte): Boolean;
    function Write(Cylinder, Head, ID, SizeCode: Integer; const Data: TBytes; Deleted: Boolean): Boolean;
    function ReadID(Cylinder, Head, Position: Integer; out Sector: TSGSector): Boolean;
    procedure Format(Cylinder, Head: Integer; const IDs: TBytes; Fill: Byte);
    function Image: TBytes;
    procedure SerializeState(State: TStateArchive);
    property WriteProtected: Boolean read FProtected write FProtected;
    property Dirty: Boolean read FDirty write FDirty;
  end;

implementation

function Signature(const Data: TBytes; Offset: Integer; const Text: AnsiString): Boolean;
begin
  Result := (Offset >= 0) and (Offset + Length(Text) <= Length(Data));
  if not Result then
    Exit;
  for var I := 1 to Length(Text) do
    if Data[Offset + I - 1] <> Ord(Text[I]) then
      Exit(False);
end;

constructor TSGDisk.Create(const Image: TBytes; WriteProtected: Boolean);
begin
  inherited Create;
  FProtected := WriteProtected;
  FRaw := Length(Image) = 163840;
  if FRaw then
  begin
    SetLength(FTracks, 40);
    for var C := 0 to 39 do
    begin
      FTracks[C].Cylinder := C;
      SetLength(FTracks[C].Sectors, 16);
      for var R := 0 to 15 do
      begin
        FTracks[C].Sectors[R].Cylinder := C;
        FTracks[C].Sectors[R].ID := R + 1;
        FTracks[C].Sectors[R].SizeCode := 1;
        FTracks[C].Sectors[R].Data := Copy(Image, (C * 16 + R) * 256, 256);
      end;
    end;
    Exit;
  end;
  var Extended := Signature(Image, 0, 'EXTENDED CPC DSK File');
  if (Length(Image) < 256) or not (Extended or Signature(Image, 0, 'MV - CPCEMU Disk-File')) then
    raise EReadError.Create('SF-7000 disk must be a 160 KiB .sf7 or a CPC DSK image');
  var Cylinders := Integer(Image[$30]);
  var Heads := Integer(Image[$31]);
  if (Cylinders < 1) or (Cylinders > 84) or (Heads < 1) or (Heads > 2) then
    raise EReadError.Create('Invalid DSK geometry');
  SetLength(FTracks, Cylinders * Heads);
  var Offset := 256;
  for var T := 0 to High(FTracks) do
  begin
    FTracks[T].Cylinder := T div Heads;
    FTracks[T].Head := T mod Heads;
    var TrackSize := Integer(Image[$32]) or (Integer(Image[$33]) shl 8);
    if Extended then
      TrackSize := Image[$34 + T] * 256;
    if TrackSize = 0 then
      Continue;
    if (TrackSize < 256) or (Offset + TrackSize > Length(Image)) or
      not Signature(Image, Offset, 'Track-Info') then
      raise EReadError.Create('Truncated DSK track');
    var Count := Integer(Image[Offset + $15]);
    if Count > 29 then
      raise EReadError.Create('Too many DSK sectors in one track');
    SetLength(FTracks[T].Sectors, Count);
    var DataOffset := Offset + 256;
    for var S := 0 to Count - 1 do
    begin
      var Header := Offset + $18 + S * 8;
      var Sector := Default(TSGSector);
      Sector.Cylinder := Image[Header];
      Sector.Head := Image[Header + 1];
      Sector.ID := Image[Header + 2];
      Sector.SizeCode := Image[Header + 3];
      Sector.Status1 := Image[Header + 4];
      Sector.Status2 := Image[Header + 5];
      if Sector.SizeCode > 7 then
        raise EReadError.Create('Invalid DSK sector size');
      var Size := 128 shl Sector.SizeCode;
      if Extended then
        Size := Integer(Image[Header + 6]) or (Integer(Image[Header + 7]) shl 8);
      if (Size = 0) or (DataOffset + Size > Offset + TrackSize) then
        raise EReadError.Create('Truncated DSK sector');
      Sector.Data := Copy(Image, DataOffset, Size);
      FTracks[T].Sectors[S] := Sector;
      Inc(DataOffset, Size);
    end;
    Inc(Offset, TrackSize);
  end;
end;

function TSGDisk.TrackIndex(Cylinder, Head: Integer): Integer;
begin
  for var I := 0 to High(FTracks) do
    if (FTracks[I].Cylinder = Cylinder) and (FTracks[I].Head = Head) then
      Exit(I);
  Result := -1;
end;

function TSGDisk.SectorIndex(Track, ID, SizeCode: Integer): Integer;
begin
  if Track >= 0 then
    for var I := 0 to High(FTracks[Track].Sectors) do
      if (FTracks[Track].Sectors[I].ID = ID) and
        (FTracks[Track].Sectors[I].SizeCode = SizeCode) then
        Exit(I);
  Result := -1;
end;

function TSGDisk.Read(Cylinder, Head, ID, SizeCode: Integer; out Data: TBytes; out Status1, Status2: Byte): Boolean;
begin
  Data := nil;
  Status1 := 4;
  Status2 := 0;
  var T := TrackIndex(Cylinder, Head);
  var S := SectorIndex(T, ID, SizeCode);
  Result := S >= 0;
  if not Result then
    Exit;
  var Sector := FTracks[T].Sectors[S];
  Data := Copy(Sector.Data);
  Status1 := Sector.Status1;
  Status2 := Sector.Status2;
end;

function TSGDisk.Write(Cylinder, Head, ID, SizeCode: Integer; const Data: TBytes; Deleted: Boolean): Boolean;
begin
  var T := TrackIndex(Cylinder, Head);
  var S := SectorIndex(T, ID, SizeCode);
  Result := not FProtected and (S >= 0);
  if not Result then
    Exit;
  FTracks[T].Sectors[S].Data := Copy(Data);
  FTracks[T].Sectors[S].Status1 := 0;
  FTracks[T].Sectors[S].Status2 := Ord(Deleted) * $40;
  FDirty := True;
end;

function TSGDisk.ReadID(Cylinder, Head, Position: Integer; out Sector: TSGSector): Boolean;
begin
  Sector := Default(TSGSector);
  var T := TrackIndex(Cylinder, Head);
  Result := (T >= 0) and (Length(FTracks[T].Sectors) > 0);
  if Result then
    Sector := FTracks[T].Sectors[Position mod Length(FTracks[T].Sectors)];
end;

procedure TSGDisk.Format(Cylinder, Head: Integer; const IDs: TBytes; Fill: Byte);
begin
  if FProtected then
    raise EWriteError.Create('SF-7000 disk is write protected');
  if (Length(IDs) mod 4 <> 0) or (Length(IDs) > 29 * 4) then
    raise EWriteError.Create('Invalid SF-7000 format sector IDs');
  var T := TrackIndex(Cylinder, Head);
  if T < 0 then
    raise EWriteError.Create('Track outside SF-7000 disk');
  SetLength(FTracks[T].Sectors, Length(IDs) div 4);
  for var S := 0 to High(FTracks[T].Sectors) do
  begin
    var Sector := Default(TSGSector);
    Sector.Cylinder := IDs[S * 4];
    Sector.Head := IDs[S * 4 + 1];
    Sector.ID := IDs[S * 4 + 2];
    Sector.SizeCode := IDs[S * 4 + 3];
    if Sector.SizeCode > 7 then
      raise EWriteError.Create('Invalid format sector size');
    SetLength(Sector.Data, 128 shl Sector.SizeCode);
    for var I := 0 to High(Sector.Data) do
      Sector.Data[I] := Fill;
    FTracks[T].Sectors[S] := Sector;
  end;
  FDirty := True;
end;

function TSGDisk.Image: TBytes;
begin
  // Preserve the raw format only while the standard 40x1x16x256 geometry survives.
  var Raw := FRaw and (Length(FTracks) = 40);
  for var Track in FTracks do
  begin
    Raw := Raw and (Length(Track.Sectors) = 16);
    for var Sector in Track.Sectors do
      Raw := Raw and (Sector.Head = 0) and (Sector.ID >= 1) and (Sector.ID <= 16) and
        (Sector.SizeCode = 1) and (Length(Sector.Data) = 256) and
        (Sector.Status1 = 0) and (Sector.Status2 = 0);
  end;
  if Raw then
  begin
    SetLength(Result, 163840);
    for var Track in FTracks do
      for var Sector in Track.Sectors do
        for var I := 0 to 255 do
          Result[(Integer(Track.Cylinder) * 16 + Sector.ID - 1) * 256 + I] := Sector.Data[I];
    Exit;
  end;
  SetLength(Result, 256);
  var Signature := TEncoding.ASCII.GetBytes('EXTENDED CPC DSK File' + #13#10 + 'Disk-Info' + #13#10);
  for var I := 0 to High(Signature) do
    Result[I] := Signature[I];
  var Heads := 1;
  var Cylinders := 1;
  for var Track in FTracks do
  begin
    if Track.Head + 1 > Heads then
      Heads := Track.Head + 1;
    if Track.Cylinder + 1 > Cylinders then
      Cylinders := Track.Cylinder + 1;
  end;
  Result[$30] := Cylinders;
  Result[$31] := Heads;
  for var T := 0 to High(FTracks) do
  begin
    var Size := 256;
    for var Sector in FTracks[T].Sectors do
      Inc(Size, Length(Sector.Data));
    Size := ((Size + 255) div 256) * 256;
    if Size > $FF00 then
      raise EWriteError.Create('DSK track is too large');
    var Offset := Length(Result);
    SetLength(Result, Offset + Size);
    Result[$34 + T] := Size div 256;
    Signature := TEncoding.ASCII.GetBytes('Track-Info' + #13#10);
    for var I := 0 to High(Signature) do
      Result[Offset + I] := Signature[I];
    Result[Offset + $10] := FTracks[T].Cylinder;
    Result[Offset + $11] := FTracks[T].Head;
    Result[Offset + $14] := 1;
    Result[Offset + $15] := Length(FTracks[T].Sectors);
    Result[Offset + $16] := $2A;
    Result[Offset + $17] := $E5;
    var DataOffset := Offset + 256;
    for var S := 0 to High(FTracks[T].Sectors) do
    begin
      var Sector := FTracks[T].Sectors[S];
      var Header := Offset + $18 + S * 8;
      Result[Header] := Sector.Cylinder;
      Result[Header + 1] := Sector.Head;
      Result[Header + 2] := Sector.ID;
      Result[Header + 3] := Sector.SizeCode;
      Result[Header + 4] := Sector.Status1;
      Result[Header + 5] := Sector.Status2;
      Result[Header + 6] := Length(Sector.Data) and $FF;
      Result[Header + 7] := Length(Sector.Data) shr 8;
      for var I := 0 to High(Sector.Data) do
        Result[DataOffset + I] := Sector.Data[I];
      Inc(DataOffset, Length(Sector.Data));
    end;
  end;
end;

procedure TSGDisk.SerializeState(State: TStateArchive);
begin
  var Bytes: TBytes;
  if not State.Loading then
    Bytes := Image;
  var Size := Length(Bytes);
  State.Field(Size, SizeOf(Size));
  if (Size < 256) or (Size > 4 * 1024 * 1024) then
    raise EReadError.Create('Invalid snapshot disk size');
  if State.Loading then
    SetLength(Bytes, Size);
  State.Field(Bytes[0], Size);
  State.Field(FProtected, SizeOf(FProtected));
  State.Field(FDirty, SizeOf(FDirty));
  if State.Loading then
  begin
    var Disk := TSGDisk.Create(Bytes, FProtected);
    try
      FTracks := Disk.FTracks;
      FRaw := Disk.FRaw;
    finally
      Disk.Free;
    end;
  end;
end;

end.

