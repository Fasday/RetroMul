unit NeoGeoCD.Disc;

interface

uses
  System.SysUtils, System.Classes, Core.Storage;

type
  TCDTrack = record
    Number, StartLBA, EndLBA, PregapLBA, FileSector, SectorSize, DataOffset: Integer;
    StoredPregap: Integer;
    Audio, LittleEndian, PregapAudio: Boolean;
    SourceName: string;
    Stream: TStream;
    ByteOffset, ByteSize: Int64;
  end;

  // Immutable TOC; streams are owned here and accessed by the emulation worker.
  TNeoGeoCDDisc = class
  private
    FTracks: TArray<TCDTrack>;
    FLeadOut: Integer;
    FIdentity: TBytes;
    FCompressedHash: TBytes;
    procedure LoadCHD(const Storage: IStorage; const Location: string);
    procedure LoadCue(Stream: TStream; const Storage: IStorage; const Location: string);
    procedure ValidateAndHash;
  public
    constructor Create(Stream: TStream; const Storage: IStorage; const Location: string);
    destructor Destroy; override;
    function TrackAt(LBA: Integer): Integer;
    function Track(Number: Integer): TCDTrack;
    function TrackCount: Integer;
    function LeadOut: Integer;
    function IsData(LBA: Integer): Boolean;
    procedure ReadData(LBA: Integer; var Sector: TBytes);
    procedure ReadAudio(LBA: Integer; var Sector: TBytes);
    function Identity: TBytes;
  end;

function CDSibling(const Storage: IStorage; const Location, Name: string): string;

implementation

uses
  System.Hash, System.IOUtils, System.Math, System.StrUtils, NeoGeoCD.CHD
  {$IFDEF ANDROID}, Core.Storage.Android{$ENDIF};

function CDSibling(const Storage: IStorage; const Location, Name: string): string;
begin
  // A CUE references files beside itself, never absolute paths or parent traversal.
  if (Name = '') or Name.Contains(':') or Name.Contains('/') or Name.Contains('\') or (Name = '.') or (Name = '..') then
    raise EReadError.Create('Invalid Neo Geo CD companion filename: ' + Name);

  if Location.StartsWith('content://', True) then
  begin
    // SAF document IDs are opaque. Find the source in the selected system
    // folder, then resolve by display name without constructing a URI.
    for var Folder in Storage.Folders(Storage.RomFolder) do
    begin
      var Files := Storage.Files(Folder);
      var Found := False;
      for var Candidate in Files do
        if {$IFDEF ANDROID}TAndroidStorage.SameDocument(Candidate, Location){$ELSE}Candidate = Location{$ENDIF} then
          Found := True;
      if not Found then
        Continue;

      for var Candidate in Files do
        if SameText(Storage.Describe(Candidate).Name, Name) then
          Exit(Candidate);

      Break;
    end;
    raise EReadError.Create('Missing Neo Geo CD companion in the selected ROM folder: ' + Name);
  end;

  Result := TPath.Combine(ExtractFilePath(Location.Replace('/', PathDelim)), Name);
  if not Storage.Exists(Result) then
  begin
    // CUE filenames often use a different case from a Linux filesystem.
    for var Candidate in Storage.Files(ExtractFilePath(Result)) do
      if SameText(ExtractFileName(Candidate), Name) then
        Exit(Candidate);

    raise EReadError.Create('Missing Neo Geo CD file: ' + Name);
  end;
end;

function CueTime(const Text: string): Integer;
begin
  var Parts := Text.Split([':']);
  if Length(Parts) <> 3 then
    raise EReadError.Create('Invalid CUE time: ' + Text);

  var M := StrToInt(Parts[0]);
  var S := StrToInt(Parts[1]);
  var F := StrToInt(Parts[2]);
  if (M < 0) or (M > 99) or (S < 0) or (S > 59) or (F < 0) or (F > 74) then
    raise EReadError.Create('Invalid CUE time: ' + Text);

  Result := (M * 60 + S) * 75 + F;
end;

procedure WaveRange(Stream: TStream; out Offset, Size: Int64);
var
  Header: array[0..11] of Byte;
  Chunk: array[0..7] of Byte;
  Format: array[0..15] of Byte;
begin
  Stream.Position := 0;
  Stream.ReadBuffer(Header, SizeOf(Header));
  if not CompareMem(@Header[0], PAnsiChar(AnsiString('RIFF')), 4) or not CompareMem(@Header[8], PAnsiChar(AnsiString('WAVE')), 4) then
    raise EReadError.Create('CD audio must be PCM WAV or BINARY');

  var ValidFormat := False;
  Offset := -1;
  Size := 0;
  while Stream.Position + 8 <= Stream.Size do
  begin
    Stream.ReadBuffer(Chunk, 8);
    var Count := Cardinal(Chunk[4]) or (Cardinal(Chunk[5]) shl 8) or
      (Cardinal(Chunk[6]) shl 16) or (Cardinal(Chunk[7]) shl 24);
    var Next := Stream.Position + Int64(Count) + (Count and 1);
    if Next > Stream.Size then
      raise EReadError.Create('Truncated CD audio WAV');

    if CompareMem(@Chunk[0], PAnsiChar(AnsiString('fmt ')), 4) then
    begin
      if Count < 16 then
        raise EReadError.Create('Invalid CD audio WAV format');

      Stream.ReadBuffer(Format, 16);
      ValidFormat := (Format[0] = 1) and (Format[1] = 0) and
        (Format[2] = 2) and (Format[3] = 0) and (Format[4] = $44) and
        (Format[5] = $AC) and (Format[6] = 0) and (Format[7] = 0) and
        (Format[12] = 4) and (Format[13] = 0) and (Format[14] = 16) and (Format[15] = 0);
    end
    else if CompareMem(@Chunk[0], PAnsiChar(AnsiString('data')), 4) then
    begin
      Offset := Stream.Position;
      Size := Count;
    end;
    Stream.Position := Next;
  end;

  if not ValidFormat or (Offset < 0) or (Size mod 4 <> 0) then
    raise EReadError.Create('CD audio WAV requires 44100 Hz, stereo, 16-bit PCM');
end;

constructor TNeoGeoCDDisc.Create(Stream: TStream; const Storage: IStorage; const Location: string);
begin
  inherited Create;
  if (Stream = nil) or (Storage = nil) or (Location = '') then
    raise EArgumentException.Create('Neo Geo CD needs a source location and storage');

  var SourceName := Location;
  if Location.StartsWith('content://', True) then
    SourceName := Storage.Describe(Location).Name;
  if SameText(ExtractFileExt(SourceName), '.cue') then
    LoadCue(Stream, Storage, Location)
  else if SameText(ExtractFileExt(SourceName), '.iso') then
  begin
    SetLength(FTracks, 1);
    FTracks[0].Number := 1;
    FTracks[0].SectorSize := 2048;
    FTracks[0].Stream := Storage.OpenRead(Location);
    FTracks[0].ByteSize := FTracks[0].Stream.Size;
    if (FTracks[0].ByteSize < 17 * 2048) or (FTracks[0].ByteSize > Int64(800) * 1024 * 1024) or (FTracks[0].ByteSize mod 2048 <> 0) then
      raise EReadError.Create('Invalid Neo Geo CD ISO size');

    FTracks[0].EndLBA := FTracks[0].ByteSize div 2048;
  end
  else if SameText(ExtractFileExt(SourceName), '.chd') then
    LoadCHD(Storage, Location)
  else
    raise EReadError.Create('Neo Geo CD expects ISO, CUE or CHD');

  if (FLeadOut = 0) and (Length(FTracks) > 0) then
    FLeadOut := FTracks[High(FTracks)].EndLBA;
  ValidateAndHash;
end;

destructor TNeoGeoCDDisc.Destroy;
begin
  for var Item in FTracks do
    Item.Stream.Free;
  inherited;
end;

procedure TNeoGeoCDDisc.LoadCue(Stream: TStream; const Storage: IStorage; const Location: string);
var
  Index0, Index1, Gaps, PostGaps: array[0..98] of Integer;
begin
  if Stream.Size - Stream.Position > 1024 * 1024 then
    raise EReadError.Create('CUE exceeds 1 MiB');

  var Data: TBytes;
  SetLength(Data, Stream.Size - Stream.Position);
  if Length(Data) > 0 then
    Stream.ReadBuffer(Data[0], Length(Data));
  var Text := TEncoding.UTF8.GetString(Data).TrimLeft([#$FEFF]);
  var FileName := '';
  var FileType := '';
  var Current := -1;
  for var Line in Text.Split([#10]) do
  begin
    var Value := Line.Trim;
    if Value = '' then
      Continue;

    var Tokens := Value.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
    var Command := Tokens[0].ToUpper;
    if Command = 'FILE' then
    begin
      if Value.Contains('"') then
      begin
        var First := Pos('"', Value);
        var Tail := Copy(Value, First + 1, MaxInt);
        var Last := Pos('"', Tail);
        if Last = 0 then
          raise EReadError.Create('Unterminated CUE filename');

        FileName := Copy(Tail, 1, Last - 1);
        FileType := Copy(Tail, Last + 1, MaxInt).Trim.ToUpper;
      end
      else
      begin
        if Length(Tokens) <> 3 then
          raise EReadError.Create('Invalid CUE FILE');

        FileName := Tokens[1];
        FileType := Tokens[2].ToUpper;
      end;
      if (FileType <> 'BINARY') and (FileType <> 'WAVE') then
        raise EReadError.Create('Unsupported CUE FILE type: ' + FileType);
    end
    else if Command = 'TRACK' then
    begin
      if (Length(Tokens) <> 3) or (FileName = '') or (Length(FTracks) >= 99) then
        raise EReadError.Create('Invalid CUE TRACK');

      Current := Length(FTracks);
      SetLength(FTracks, Current + 1);
      FTracks[Current].Number := StrToInt(Tokens[1]);
      if FTracks[Current].Number <> Current + 1 then
        raise EReadError.Create('CUE tracks must be numbered consecutively from 1');

      Index0[Current] := -1;
      Index1[Current] := -1;
      Gaps[Current] := 0;
      PostGaps[Current] := 0;
      var Kind := Tokens[2].ToUpper;
      FTracks[Current].Audio := Kind = 'AUDIO';
      FTracks[Current].SectorSize := 2352;
      if Kind = 'MODE1/2048' then
        FTracks[Current].SectorSize := 2048
      else if Kind = 'MODE1/2352' then
        FTracks[Current].DataOffset := 16
      else if Kind <> 'AUDIO' then
        raise EReadError.Create('Unsupported CUE TRACK type: ' + Kind);

      FTracks[Current].SourceName := FileName;
      FTracks[Current].Stream := Storage.OpenRead(CDSibling(Storage, Location, FileName));
      FTracks[Current].ByteSize := FTracks[Current].Stream.Size;
      // CUE BINARY audio, like PCM WAV, stores little-endian samples.
      FTracks[Current].LittleEndian := True;
      if FTracks[Current].ByteSize > Int64(800) * 1024 * 1024 then
        raise EReadError.Create('Neo Geo CD track exceeds 800 MiB');

      if FileType = 'WAVE' then
      begin
        if not FTracks[Current].Audio then
          raise EReadError.Create('WAVE is only valid for AUDIO tracks');
        WaveRange(FTracks[Current].Stream, FTracks[Current].ByteOffset, FTracks[Current].ByteSize);
      end;
    end
    else if Command = 'INDEX' then
    begin
      if (Current < 0) or (Length(Tokens) <> 3) then
        raise EReadError.Create('Invalid CUE INDEX');

      var N := StrToInt(Tokens[1]);
      var Time := CueTime(Tokens[2]);
      if N = 0 then
        Index0[Current] := Time
      else if N = 1 then
        Index1[Current] := Time;
    end
    else if Command = 'PREGAP' then
    begin
      if (Current < 0) or (Length(Tokens) <> 2) then
        raise EReadError.Create('Invalid CUE PREGAP');

      Gaps[Current] := CueTime(Tokens[1]);
    end
    else if Command = 'POSTGAP' then
    begin
      if (Current < 0) or (Length(Tokens) <> 2) then
        raise EReadError.Create('Invalid CUE POSTGAP');

      PostGaps[Current] := CueTime(Tokens[1]);
    end
    else if not ((Command = 'REM') or (Command = 'TITLE') or (Command = 'PERFORMER') or
      (Command = 'SONGWRITER') or (Command = 'CATALOG') or (Command = 'ISRC') or (Command = 'FLAGS')) then
      raise EReadError.Create('Unsupported CUE directive: ' + Command);
  end;
  var Cursor := 0;
  for var i := 0 to High(FTracks) do
  begin
    if (Index1[i] < 0) or ((Index0[i] >= 0) and (Index0[i] > Index1[i])) then
      raise EReadError.Create('CUE TRACK needs a valid INDEX 01');

    var EndSector := FTracks[i].ByteSize div FTracks[i].SectorSize;
    if (i < High(FTracks)) and SameText(FTracks[i].SourceName, FTracks[i + 1].SourceName) then
    begin
      if Index1[i + 1] <= Index1[i] then
        raise EReadError.Create('CUE indexes must increase within one FILE');

      begin
        EndSector := Index1[i + 1];
        if Index0[i + 1] >= 0 then
          EndSector := Index0[i + 1];
        if FTracks[i].SectorSize <> FTracks[i + 1].SectorSize then
          raise EReadError.Create('Mixed sector sizes in one CUE FILE');
      end;
    end;

    if EndSector <= Index1[i] then
      raise EReadError.Create('Invalid CUE track bounds');

    FTracks[i].FileSector := Index1[i];
    FTracks[i].PregapLBA := Cursor;
    if i > 0 then
    begin
      Inc(Cursor, PostGaps[i - 1]);
      Inc(Cursor, Gaps[i]);
      if Index0[i] >= 0 then
      begin
        FTracks[i].StoredPregap := Index1[i] - Index0[i];
        FTracks[i].PregapAudio := FTracks[i].Audio;
        Inc(Cursor, FTracks[i].StoredPregap);
      end;
    end;
    FTracks[i].StartLBA := Cursor;
    Inc(Cursor, EndSector - Index1[i]);
    FTracks[i].EndLBA := Cursor;
  end;
  if Length(FTracks) > 0 then
    FLeadOut := Cursor + PostGaps[High(FTracks)];
end;

procedure TNeoGeoCDDisc.LoadCHD(const Storage: IStorage; const Location: string);
begin
  var Input := Storage.OpenRead(Location);
  try
    if Input.Size > Int64(800) * 1024 * 1024 then
      raise EReadError.Create('CHD exceeds 800 MiB');

    var Hash := THashSHA2.Create;
    var Buffer: array[0..65535] of Byte;
    repeat
      var N := Input.Read(Buffer, SizeOf(Buffer));
      if N = 0 then
        Break;
      Hash.Update(Buffer, N);
    until False;

    FCompressedHash := Hash.HashAsBytes;
  finally
    Input.Free;
  end;
  var Source := OpenCHD(Storage.OpenRead(Location));
  var FileCursor := 0;
  var Cursor := 0;
  for var i := 0 to 98 do
  begin
    var Metadata := Source.Metadata($43485432, i); // CHT2
    if Metadata = '' then
      Metadata := Source.Metadata($43485452, i); // CHTR
    if Metadata = '' then
      Break;

    var Number := 0;
    var Frames := 0;
    var Gap := 0;
    var PostGap := 0;
    var Kind := '';
    var GapKind := '';
    for var Token in Metadata.Split([' '], TStringSplitOptions.ExcludeEmpty) do
    begin
      var Pair := Token.Split([':']);
      if Length(Pair) <> 2 then
        raise EReadError.Create('Invalid CHD track metadata');

      case IndexStr(Pair[0], ['TRACK', 'TYPE', 'FRAMES', 'PREGAP', 'PGTYPE', 'POSTGAP']) of
        0:
          Number := StrToInt(Pair[1]);
        1:
          Kind := Pair[1];
        2:
          Frames := StrToInt(Pair[1]);
        3:
          Gap := StrToInt(Pair[1]);
        4:
          GapKind := Pair[1];
        5:
          PostGap := StrToInt(Pair[1]);
      end;
    end;
    if (Number <> i + 1) or (Frames <= 0) or (Frames > 450000) or
      (Gap < 0) or (Gap > 450000) or (PostGap < 0) or (PostGap > 450000) then
      raise EReadError.Create('Invalid CHD track bounds');

    var Audio := Kind = 'AUDIO';
    if not Audio and (Kind <> 'MODE1') and (Kind <> 'MODE1_RAW') and
      (Kind <> 'MODE1/2048') and (Kind <> 'MODE1/2352') then
      raise EReadError.Create('Unsupported CHD track type: ' + Kind);

    FileCursor := (FileCursor + 3) and not 3; // CHD pads each track to four sectors.
    var StoredGap := 0;
    // Only the V prefix denotes pregap sectors physically stored in the CHD.
    if GapKind.StartsWith('V') then
      StoredGap := Gap;
    if Frames <= StoredGap then
      raise EReadError.Create('CHD track contains only a pregap');

    SetLength(FTracks, i + 1);
    var Item := Default(TCDTrack);
    Item.Number := Number;
    Item.Audio := Audio;
    Item.StoredPregap := StoredGap;
    Item.PregapAudio := GapKind = 'VAUDIO';
    Item.PregapLBA := Cursor;
    Inc(Cursor, Gap);
    Item.StartLBA := Cursor;
    Inc(Cursor, Frames - StoredGap);
    Item.EndLBA := Cursor;
    Inc(Cursor, PostGap);
    Item.FileSector := FileCursor + StoredGap;
    Inc(FileCursor, Frames);
    Item.SectorSize := 2448;
    if (Kind = 'MODE1_RAW') or (Kind = 'MODE1/2352') then
      Item.DataOffset := 16;
    Item.ByteSize := Source.Size;
    Item.Stream := TCHDStream.Create(Source);

    // CHD's CD audio is big-endian; BIN and WAV are little-endian.
    FTracks[i] := Item;
  end;
  FLeadOut := Cursor;
end;

procedure TNeoGeoCDDisc.ValidateAndHash;
begin
  if (Length(FTracks) = 0) or FTracks[0].Audio or (LeadOut > 100 * 60 * 75) then
    raise EReadError.Create('Neo Geo CD requires a data track followed by optional audio');

  var Sector: TBytes;
  ReadData(16, Sector);
  if (Sector[0] <> 1) or not CompareMem(@Sector[1], PAnsiChar(AnsiString('CD001')), 5) then
    raise EReadError.Create('Neo Geo CD data track requires ISO 9660');

  var Hash := THashSHA2.Create;
  var Buffer: array[0..65535] of Byte;
  for var Item in FTracks do
  begin
    Hash.Update(TEncoding.UTF8.GetBytes(Format('%d/%d/%d/%d/%d/%d/%d/%d',
          [Item.Number, Item.StartLBA, Item.EndLBA, Item.PregapLBA, Item.FileSector,
            Item.SectorSize, Ord(Item.Audio), Ord(Item.LittleEndian)])));
    // CHD's compressed hash already covers pregap content. CUE identities must
    // include the newly playable INDEX 00 bytes as well as INDEX 01.
    if (Item.StoredPregap > 0) and (Length(FCompressedHash) = 0) then
      Hash.Update(TEncoding.UTF8.GetBytes(Format('/pregap/%d/%d',
        [Item.StoredPregap, Ord(Item.PregapAudio)])));
    var FirstSector := Item.FileSector - Item.StoredPregap;
    var Remaining := Int64(Item.EndLBA - Item.StartLBA + Item.StoredPregap) * Item.SectorSize;
    if (FirstSector < 0) or (Remaining > Item.ByteSize - Int64(FirstSector) * Item.SectorSize) then
      raise EReadError.Create('Truncated CUE track');
    Item.Stream.Position := Item.ByteOffset + Int64(FirstSector) * Item.SectorSize;

    if Length(FCompressedHash) > 0 then
      Continue;

    while Remaining > 0 do
    begin
      var Count := Integer(Min(Int64(SizeOf(Buffer)), Remaining));
      Item.Stream.ReadBuffer(Buffer, Count);
      Hash.Update(Buffer, Count);
      Dec(Remaining, Count);
    end;
  end;
  Hash.Update(FCompressedHash);
  FIdentity := Hash.HashAsBytes;
end;

function TNeoGeoCDDisc.TrackAt(LBA: Integer): Integer;
begin
  Result := -1;
  for var i := 0 to High(FTracks) do
    if (LBA >= FTracks[i].PregapLBA) and (LBA < FTracks[i].EndLBA) then
      Exit(i);
end;

function TNeoGeoCDDisc.Track(Number: Integer): TCDTrack;
begin
  if (Number < 1) or (Number > Length(FTracks)) then
    raise EReadError.Create('Invalid CD track number');

  Result := FTracks[Number - 1];
end;

function TNeoGeoCDDisc.TrackCount: Integer;
begin
  Result := Length(FTracks);
end;

function TNeoGeoCDDisc.LeadOut: Integer;
begin
  Result := FLeadOut;
end;

function TNeoGeoCDDisc.IsData(LBA: Integer): Boolean;
begin
  var i := TrackAt(LBA);
  Result := (i >= 0) and not FTracks[i].Audio and (LBA >= FTracks[i].StartLBA);
end;

procedure TNeoGeoCDDisc.ReadData(LBA: Integer; var Sector: TBytes);
begin
  var i := TrackAt(LBA);
  if (i < 0) or FTracks[i].Audio or (LBA < FTracks[i].StartLBA) then
    raise EReadError.Create('CD data read outside data track');

  var Item := FTracks[i];
  SetLength(Sector, 2048);
  Item.Stream.Position := Item.ByteOffset + Int64(Item.FileSector + LBA - Item.StartLBA) *
    Item.SectorSize + Item.DataOffset;
  Item.Stream.ReadBuffer(Sector[0], 2048);
end;

procedure TNeoGeoCDDisc.ReadAudio(LBA: Integer; var Sector: TBytes);
begin
  SetLength(Sector, 2352);
  FillChar(Sector[0], 2352, 0);
  var i := TrackAt(LBA);
  if (i < 0) or not FTracks[i].Audio then
    Exit;

  var Item := FTracks[i];
  // PREGAP/POSTGAP silence precedes any stored INDEX 00 audio.
  if (LBA < Item.StartLBA) and (not Item.PregapAudio or
    (LBA < Item.StartLBA - Item.StoredPregap)) then
    Exit;
  Item.Stream.Position := Item.ByteOffset + Int64(Item.FileSector + LBA - Item.StartLBA) * Item.SectorSize;
  Item.Stream.ReadBuffer(Sector[0], 2352);
  if not Item.LittleEndian then
    for var N := 0 to 1175 do
    begin
      var B := Sector[N * 2];
      Sector[N * 2] := Sector[N * 2 + 1];
      Sector[N * 2 + 1] := B;
    end;
end;

function TNeoGeoCDDisc.Identity: TBytes;
begin
  Result := Copy(FIdentity);
end;

end.

