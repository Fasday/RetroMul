unit Core.Storage;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, Core.Storage.Types
  {$IFDEF IOS}, iOSapi.Foundation{$ENDIF};

type
  TStorageFile = Core.Storage.Types.TStorageFile;

  TStorageSnapshot = Core.Storage.Types.TStorageSnapshot;

  TStorageSelection = Core.Storage.Types.TStorageSelection;

  TStorageSelectionCallback = Core.Storage.Types.TStorageSelectionCallback;

  IStoragePicker = Core.Storage.Types.IStoragePicker;

  IStorage = Core.Storage.Types.IStorage;

  TStorage = class(TInterfacedObject, IStorage)
  private
    FRoot, FRomFolder: string;
    FPicker: IStoragePicker;
    FCheckRomFileSize: Boolean;
    FMaxRomFileSize: Int64;
    function GetRoot: string;
    function GetRomFolder: string;
    function GetCheckRomFileSize: Boolean;
    procedure SetCheckRomFileSize(Value: Boolean);
    function GetMaxRomFileSize: Int64;
    procedure SetMaxRomFileSize(Value: Int64);
  public
    constructor Create(const Root: string = ''; const Picker: IStoragePicker = nil);
    class function Default: IStorage; static;
    // Keep the returned scope alive on the calling thread during loading.
    class function BeginReadCancellation(const CheckCancelled: TProc): IInterface; static;
    class procedure CheckReadCancelled; static;
    procedure SetRomFolder(const Value: string);
    function OpenRead(const Location: string): TStream; virtual;
    function OpenWrite(const Location: string): TStream;
    function Exists(const Location: string): Boolean;
    function ModifiedTime(const Location: string): TDateTime;
    function FolderExists(const Location: string): Boolean;
    procedure EnsureFolder(const Location: string);
    function Files(const Location: string; Recursive: Boolean = False): TArray<string>;
    function Folders(const Location: string): TArray<string>;
    procedure Delete(const Location: string);
    procedure Replace(const Source, Target: string);
    procedure WriteAtomic(const Location: string; Stream: TStream);
    function ReadBytes(const Location: string): TBytes;
    procedure WriteBytes(const Location: string; const Data: TBytes);
    function ReadText(const Location: string): string;
    function ConfigFile(const SystemId: string): string;
    function ReadConfig(const Location: string): TMemIniFile;
    procedure WriteConfig(Ini: TMemIniFile);
    function SaveRoot: string;
    function SnapshotRoot: string;
    function ScreenshotFile(const RomName: string): string;
    function TemporaryFile(const Extension: string): string;
    function GamePath(const Root, RomName, Identity, Extension: string): string;
    function GameSave(const SystemId, RomName, Identity: string): string;
    function GameSnapshots(const SystemId, RomName, Identity: string): string;
    function Snapshots(const SystemId, RomName, Identity: string): TArray<TStorageSnapshot>;
    function Roms(const SystemId: string): TArray<TStorageFile>;
    function Describe(const Location: string): TStorageFile;
    procedure SelectRomFolder(const Callback: TStorageSelectionCallback);
    procedure SelectRom(const Callback: TStorageSelectionCallback);
    property RomFolder: string read GetRomFolder write SetRomFolder;
    property CheckRomFileSize: Boolean read GetCheckRomFileSize write SetCheckRomFileSize;
    property MaxRomFileSize: Int64 read GetMaxRomFileSize write SetMaxRomFileSize;
  end;

{$IFDEF IOS}
// Keep document-provider grants alive for cores and restore them on next launch.
function RememberIOSDocumentURL(const URL: NSURL): string;
{$ENDIF}

implementation

uses
  System.IOUtils, System.StrUtils, System.Generics.Collections, Core.Platforms,
  Core.RomFormat,
  {$IFDEF ANDROID}
  Core.Storage.Android, {$ENDIF}
  {$IFDEF IOS} Macapi.Helpers, System.Hash, {$ENDIF}
  {$IFDEF MSWINDOWS} Winapi.Windows, {$ELSE} Posix.Stdio, Posix.Unistd, {$ENDIF}
  System.Types;

type
  TReadCancellationScope = class(TInterfacedObject)
  private
    FPrevious: TReadCancellationScope;
  public
    CheckCancelled: TProc;
    constructor Create(const Check: TProc);
    destructor Destroy; override;
  end;

  TCancellableReadStream = class(TStream)
  private
    FSource: TStream;
    FCheckCancelled: TProc;
  protected
    function GetSize: Int64; override;
  public
    constructor Create(Source: TStream; const Check: TProc);
    destructor Destroy; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

threadvar
  ReadCancellationScope: TReadCancellationScope;

constructor TReadCancellationScope.Create(const Check: TProc);
begin
  inherited Create;
  CheckCancelled := Check;
  FPrevious := ReadCancellationScope;
  ReadCancellationScope := Self;
end;

destructor TReadCancellationScope.Destroy;
begin
  ReadCancellationScope := FPrevious;
  inherited;
end;

constructor TCancellableReadStream.Create(Source: TStream; const Check: TProc);
begin
  inherited Create;
  FSource := Source;
  FCheckCancelled := Check;
end;

destructor TCancellableReadStream.Destroy;
begin
  FSource.Free;
  inherited;
end;

function TCancellableReadStream.GetSize: Int64;
begin
  FCheckCancelled();
  Result := FSource.Size;
end;

function TCancellableReadStream.Read(var Buffer; Count: Longint): Longint;
begin
  FCheckCancelled();
  Result := FSource.Read(Buffer, Count);
end;

function TCancellableReadStream.Write(const Buffer; Count: Longint): Longint;
begin
  raise EWriteError.Create('Read-only stream');
end;

function TCancellableReadStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  FCheckCancelled();
  Result := FSource.Seek(Offset, Origin);
end;

class function TStorage.BeginReadCancellation(const CheckCancelled: TProc): IInterface;
begin
  Result := TReadCancellationScope.Create(CheckCancelled);
end;

class procedure TStorage.CheckReadCancelled;
begin
  if (ReadCancellationScope <> nil) and Assigned(ReadCancellationScope.CheckCancelled) then
    ReadCancellationScope.CheckCancelled();
end;

{$IFDEF IOS}
type
  TIOSDocumentGrant = record
    OriginalPath, CurrentPath: string;
    URL: NSURL;
    Scoped: Boolean;
  end;

var
  IOSDocumentGrants: TList<TIOSDocumentGrant>;
  IOSGrantsLoaded: Boolean;

function IOSBookmarkFile: string;
begin
  Result := TPath.Combine(TPath.GetHomePath, 'Library/Application Support/RetroMul/document-access.ini');
end;

procedure LoadIOSDocumentGrants;
begin
  // Called under the grants monitor, including before the first worker starts.
  if IOSGrantsLoaded then
    Exit;
  IOSGrantsLoaded := True;
  var Ini := TMemIniFile.Create(IOSBookmarkFile, TEncoding.UTF8);
  var Sections := TStringList.Create;
  try
    var Updated := False;
    Ini.ReadSections(Sections);
    for var Section in Sections do
    try
      var Data := TNSData.Wrap(TNSData.Alloc.initWithBase64EncodedString(
          StrToNSStr(Ini.ReadString(Section, 'Bookmark', '')), 0));
      if Data = nil then
        Continue;
      var Stale := False;
      var URL := TNSURL.Wrap(TNSURL.OCClass.URLByResolvingBookmarkData(Data,
          NSURLBookmarkResolutionWithoutUI, nil, @Stale, nil));
      if URL = nil then
        Continue;
      var Grant := Default(TIOSDocumentGrant);
      Grant.URL := URL;
      Grant.Scoped := URL.startAccessingSecurityScopedResource;
      Grant.CurrentPath := NSStrToStr(URL.path);
      if not Grant.Scoped and not TFile.Exists(Grant.CurrentPath) and
        not TDirectory.Exists(Grant.CurrentPath) then
        Continue;
      Grant.OriginalPath := Ini.ReadString(Section, 'Path', Grant.CurrentPath);
      IOSDocumentGrants.Add(Grant);
      if Stale then
      begin
        Data := URL.bookmarkDataWithOptions(NSURLBookmarkCreationMinimalBookmark, nil, nil, nil);
        if Data <> nil then
        begin
          Ini.WriteString(Section, 'Bookmark', NSStrToStr(Data.base64EncodedStringWithOptions(0)));
          Updated := True;
        end;
      end;
    except
      // A removed document must not prevent opening other games or choosing again.
    end;
    if Updated then
      Ini.UpdateFile;
  finally
    Sections.Free;
    Ini.Free;
  end;
end;

function RememberIOSDocumentURL(const URL: NSURL): string;
begin
  if URL = nil then
    raise EArgumentNilException.Create('Document URL');
  Result := NSStrToStr(URL.path);
  if Result = '' then
    raise EInOutError.Create('The document picker returned an empty path');
  TMonitor.Enter(IOSDocumentGrants);
  try
    LoadIOSDocumentGrants;
    for var Existing in IOSDocumentGrants do
      if (Result = Existing.CurrentPath) or
        Result.StartsWith(IncludeTrailingPathDelimiter(Existing.CurrentPath)) then
      begin
        Result := Existing.OriginalPath + Result.Substring(Length(Existing.CurrentPath));
        Exit;
      end;
    var Grant := Default(TIOSDocumentGrant);
    Grant.OriginalPath := Result;
    Grant.CurrentPath := Result;
    Grant.URL := URL;
    Grant.Scoped := URL.startAccessingSecurityScopedResource;
    try
      if not Grant.Scoped and not TFile.Exists(Result) and not TDirectory.Exists(Result) then
        raise EInOutError.Create('Cannot access the selected document. Please choose it again.');
      var Data := URL.bookmarkDataWithOptions(NSURLBookmarkCreationMinimalBookmark, nil, nil, nil);
      if Data = nil then
        raise EInOutError.Create('Cannot preserve access to the selected document');
      ForceDirectories(ExtractFilePath(IOSBookmarkFile));
      var Ini := TMemIniFile.Create(IOSBookmarkFile, TEncoding.UTF8);
      try
        var Section := THashSHA2.GetHashString(Result);
        Ini.WriteString(Section, 'Path', Result);
        Ini.WriteString(Section, 'Bookmark', NSStrToStr(Data.base64EncodedStringWithOptions(0)));
        Ini.UpdateFile;
      finally
        Ini.Free;
      end;
      IOSDocumentGrants.Add(Grant);
    except
      if Grant.Scoped then
        URL.stopAccessingSecurityScopedResource;
      raise;
    end;
  finally
    TMonitor.Exit(IOSDocumentGrants);
  end;
end;

function IOSGrantedPath(const Location: string; ToNative: Boolean): string;
begin
  Result := Location;
  TMonitor.Enter(IOSDocumentGrants);
  try
    LoadIOSDocumentGrants;
    var BestLength := 0;
    for var Grant in IOSDocumentGrants do
    begin
      var Source := Grant.OriginalPath;
      var Target := Grant.CurrentPath;
      if not ToNative then
      begin
        Source := Grant.CurrentPath;
        Target := Grant.OriginalPath;
      end;
      if (Length(Source) > BestLength) and
        ((Location = Source) or Location.StartsWith(IncludeTrailingPathDelimiter(Source))) then
      begin
        BestLength := Length(Source);
        Result := Target + Location.Substring(BestLength);
      end;
    end;
  finally
    TMonitor.Exit(IOSDocumentGrants);
  end;
end;
{$ENDIF}

function NativeStoragePath(const Location: string): string;
begin
  {$IFDEF MSWINDOWS}
  Result := Location.Replace('/', '\');
  if Result.StartsWith('\\?\') then
    Exit;

  Result := ExpandFileName(Result);
  if Result.StartsWith('\\') then
    Result := '\\?\UNC\' + Copy(Result, 3, MaxInt)
  else
    Result := '\\?\' + Result;
  {$ELSE}
  {$IFDEF IOS}
  Result := IOSGrantedPath(Location, True);
  {$ELSE}
  Result := Location;
  {$ENDIF}
  {$ENDIF}
end;

function LogicalStoragePath(const Location: string): string;
begin
  Result := Location;
  {$IFDEF IOS}
  Result := IOSGrantedPath(Location, False);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if Result.StartsWith('\\?\UNC\', True) then
    Result := '\\' + Copy(Result, 9, MaxInt)
  else if Result.StartsWith('\\?\') then
    Result := Copy(Result, 5, MaxInt);
  {$ENDIF}
end;

function SafeName(const Value: string): string;
begin
  Result := Value.Trim;
  if (Result = '') or (Result = '.') or (Result = '..') or
    (Pos('/', Result) > 0) or (Pos('\', Result) > 0) or (Pos(':', Result) > 0) then
    raise EArgumentException.Create('Invalid storage name: ' + Value);
end;

{ TStorage }

constructor TStorage.Create(const Root: string; const Picker: IStoragePicker);
begin
  inherited Create;
  FCheckRomFileSize := True;
  FMaxRomFileSize := ROM_MAX_SIZE;
  FRoot := Root;
  if FRoot = '' then
  begin
    FRoot := TPath.GetDocumentsPath;
    if (FRoot = '') or not TPath.IsPathRooted(FRoot) then
      FRoot := TPath.GetHomePath;
    if (FRoot = '') or not TPath.IsPathRooted(FRoot) then
      raise EInOutError.Create('Cannot determine storage directory');

    FRoot := TPath.Combine(FRoot, 'RetroMul');
  end;
  FRoot := ExpandFileName(FRoot);
  FPicker := Picker;
  var Ini := ReadConfig(ConfigFile('config'));
  try
    FRomFolder := Ini.ReadString('General', 'Path', '');
  finally
    Ini.Free;
  end;
end;

class function TStorage.Default: IStorage;
begin
  // Independent instances avoid mutable global settings shared between workers.
  Result := TStorage.Create;
end;

function TStorage.GetRoot: string;
begin
  Result := FRoot;
end;

function TStorage.GetRomFolder: string;
begin
  Result := FRomFolder;
end;

function TStorage.GetCheckRomFileSize: Boolean;
begin
  Result := FCheckRomFileSize;
end;

procedure TStorage.SetCheckRomFileSize(Value: Boolean);
begin
  FCheckRomFileSize := Value;
end;

function TStorage.GetMaxRomFileSize: Int64;
begin
  Result := FMaxRomFileSize;
end;

procedure TStorage.SetMaxRomFileSize(Value: Int64);
begin
  if Value <= 0 then
    raise EArgumentOutOfRangeException.Create('MaxRomFileSize must be positive (bytes)');

  FMaxRomFileSize := Value;
end;

procedure TStorage.SetRomFolder(const Value: string);
begin
  var Ini := ReadConfig(ConfigFile('config'));
  try
    Ini.WriteString('General', 'Path', Value);
    WriteConfig(Ini);
    FRomFolder := Value;
  finally
    Ini.Free;
  end;
end;

function TStorage.OpenRead(const Location: string): TStream;
begin
  CheckReadCancelled;
  {$IFDEF ANDROID}
  if Location.StartsWith('content://') then
    Result := TAndroidStorage.OpenUri(Location)
  else
  {$ENDIF}
    Result := TFileStream.Create(NativeStoragePath(Location), fmOpenRead or fmShareDenyWrite);
  if (ReadCancellationScope <> nil) and Assigned(ReadCancellationScope.CheckCancelled) then
    Result := TCancellableReadStream.Create(Result, ReadCancellationScope.CheckCancelled);
end;

function TStorage.OpenWrite(const Location: string): TStream;
begin
  {$IFDEF ANDROID}
  if Location.StartsWith('content://') then
    Exit(TAndroidStorage.OpenWriteUri(Location));
  {$ENDIF}
  EnsureFolder(ExtractFilePath(ExpandFileName(Location)));
  Result := TFileStream.Create(NativeStoragePath(Location), fmCreate);
end;

function TStorage.Exists(const Location: string): Boolean;
begin
  {$IFDEF ANDROID}
  if Location.StartsWith('content://') then
    Exit(TAndroidStorage.Exists(Location));
  {$ENDIF}
  Result := TFile.Exists(NativeStoragePath(Location));
end;

function TStorage.ModifiedTime(const Location: string): TDateTime;
begin
  {$IFDEF ANDROID}
  if Location.StartsWith('content://') then
    Exit(TAndroidStorage.ModifiedTime(Location));
  {$ENDIF}
  Result := TFile.GetLastWriteTime(NativeStoragePath(Location));
end;

function TStorage.FolderExists(const Location: string): Boolean;
begin
  {$IFDEF ANDROID}
  if Location.StartsWith('content://') then
    Exit(TAndroidStorage.Exists(Location));
  {$ENDIF}
  Result := TDirectory.Exists(NativeStoragePath(Location));
end;

procedure TStorage.EnsureFolder(const Location: string);
begin
  TDirectory.CreateDirectory(NativeStoragePath(Location));
end;

function TStorage.Files(const Location: string; Recursive: Boolean): TArray<string>;
begin
  {$IFDEF ANDROID}
  if Location.StartsWith('content://') then
  begin
    var Items := TAndroidStorage.Enumerate(Location, Recursive);
    SetLength(Result, Length(Items));
    for var i := 0 to High(Items) do
      Result[i] := Items[i].Location;
    Exit;
  end;
  {$ENDIF}
  if not FolderExists(Location) then
    Exit(nil);
  var Option := TSearchOption.soTopDirectoryOnly;
  if Recursive then
    Option := TSearchOption.soAllDirectories;
  Result := TDirectory.GetFiles(NativeStoragePath(Location), '*', Option);
  for var i := 0 to High(Result) do
    Result[i] := LogicalStoragePath(Result[i]);
end;

function TStorage.Folders(const Location: string): TArray<string>;
begin
  {$IFDEF ANDROID}
  if Location.StartsWith('content://') then
  begin
    var Items := TAndroidStorage.Enumerate(Location, False, True);
    SetLength(Result, Length(Items));
    for var i := 0 to High(Items) do
      Result[i] := Items[i].Location;
    Exit;
  end;
  {$ENDIF}
  if not FolderExists(Location) then
    Exit(nil);
  Result := TDirectory.GetDirectories(NativeStoragePath(Location));
  for var i := 0 to High(Result) do
    Result[i] := LogicalStoragePath(Result[i]);
end;

procedure TStorage.Delete(const Location: string);
begin
  if Exists(Location) then
    TFile.Delete(NativeStoragePath(Location));
end;

procedure TStorage.Replace(const Source, Target: string);
begin
  {$IFDEF MSWINDOWS}
  if not MoveFileEx(PChar(NativeStoragePath(Source)), PChar(NativeStoragePath(Target)), MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
    RaiseLastOSError;
  {$ELSE}
  var Src := UTF8String(NativeStoragePath(Source));
  var Dst := UTF8String(NativeStoragePath(Target));
  if Posix.Stdio.__rename(PAnsiChar(Src), PAnsiChar(Dst)) <> 0 then
    RaiseLastOSError;
  {$ENDIF}
end;

procedure TStorage.WriteAtomic(const Location: string; Stream: TStream);
begin
  if Location.StartsWith('content://') then
    raise ENotSupportedException.Create('Document providers do not guarantee atomic replacement; use OpenWrite for document export');

  // Keep the temporary basename short even for nested snapshot staging files.
  var Temporary := TPath.Combine(ExtractFilePath(Location),
    TGUID.NewGuid.ToString.Replace('{', '').Replace('}', '').Replace('-', '') + '.tmp');
  try
    var Output := OpenWrite(Temporary);
    try
      Stream.Position := 0;
      Output.CopyFrom(Stream, Stream.Size);
      {$IFDEF MSWINDOWS}
      if not FlushFileBuffers(TFileStream(Output).Handle) then
        RaiseLastOSError;
      {$ELSE}
      if fsync(TFileStream(Output).Handle) <> 0 then
        RaiseLastOSError;
      {$ENDIF}
    finally
      Output.Free;
    end;
    Replace(Temporary, Location);
  finally
    Delete(Temporary);
  end;
end;

function TStorage.ReadBytes(const Location: string): TBytes;
begin
  var Input := OpenRead(Location);
  try
    Result := ReadRomData(Input);
  finally
    Input.Free;
  end;
end;

procedure TStorage.WriteBytes(const Location: string; const Data: TBytes);
begin
  var Stream := TBytesStream.Create(Data);
  try
    WriteAtomic(Location, Stream);
  finally
    Stream.Free;
  end;
end;

function TStorage.ReadText(const Location: string): string;
begin
  var Data := ReadBytes(Location);
  var Encoding: TEncoding := nil;
  var Offset := TEncoding.GetBufferEncoding(Data, Encoding, TEncoding.UTF8);
  Result := Encoding.GetString(Data, Offset, Length(Data) - Offset);
end;

function TStorage.ConfigFile(const SystemId: string): string;
begin
  var SettingsId := SystemId;
  var platform: TPlatformInfo;
  if TPlatformRegistry.Find(SystemId, platform) then
    SettingsId := platform.SettingsCoreId;
  Result := TPath.Combine(FRoot, SafeName(SettingsId) + '.ini');
end;

function TStorage.ReadConfig(const Location: string): TMemIniFile;
begin
  // TMemIniFile never reads/writes a physical file here: all I/O goes through storage.
  Result := TMemIniFile.Create('', TEncoding.UTF8);
  try
    Result.Rename(Location, False);
    var ReadLocation := Location;
    if not Exists(ReadLocation) then
    begin
      var platform: TPlatformInfo;
      if TPlatformRegistry.Find(TPath.GetFileNameWithoutExtension(Location), platform) and
        (platform.LegacySettingsId <> '') and SameText(Location, ConfigFile(platform.Id)) then
        ReadLocation := ConfigFile(platform.LegacySettingsId);
    end;
    if Exists(ReadLocation) then
    begin
      var Lines := TStringList.Create;
      try
        Lines.Text := ReadText(ReadLocation);
        Result.SetStrings(Lines);
      finally
        Lines.Free;
      end;
    end;
  except
    Result.Free;
    raise;
  end;
end;

procedure TStorage.WriteConfig(Ini: TMemIniFile);
begin
  var Lines := TStringList.Create;
  try
    Ini.GetStrings(Lines);
    WriteBytes(Ini.FileName, TEncoding.UTF8.GetBytes(Lines.Text));
  finally
    Lines.Free;
  end;
end;

function TStorage.SaveRoot: string;
begin
  Result := TPath.Combine(FRoot, 'saves');
end;

function TStorage.SnapshotRoot: string;
begin
  Result := TPath.Combine(FRoot, 'snapshots');
end;

function TStorage.ScreenshotFile(const RomName: string): string;
begin
  var Name := ChangeFileExt(ExtractFileName(RomName), '');
  for var i := 1 to Length(Name) do
    if (Ord(Name[i]) < 32) or CharInSet(Name[i], ['<', '>', ':', '"', '/', '\', '|', '?', '*']) then
      Name[i] := '_';
  if Name = '' then
    Name := 'Game';
  Result := TPath.Combine(TPath.Combine(FRoot, 'screenshots'), Copy(Name, 1, 80) + '_' +
    FormatDateTime('yyyymmdd_hhnnss_zzz', Now) + '_' + TGUID.NewGuid.ToString + '.png');
end;

function TStorage.TemporaryFile(const Extension: string): string;
begin
  if (Pos('/', Extension) > 0) or (Pos('\', Extension) > 0) then
    raise EArgumentException.Create('Invalid temporary file extension');

  Result := TPath.Combine(TPath.Combine(FRoot, 'cache'), TGUID.NewGuid.ToString + Extension);
end;

function TStorage.GamePath(const Root, RomName, Identity, Extension: string): string;
begin
  Result := '';
  var Candidates := Files(Root);
  if Extension = '' then
    Candidates := Folders(Root);
  for var Path in Candidates do
  begin
    var Name := ExtractFileName(Path);
    if SameText(Name, Identity + Extension) or EndsText('_' + Identity + Extension, Name) then
    begin
      if Result <> '' then
        raise EInOutError.Create('Multiple saves for game ' + Identity);

      Result := Path;
    end;
  end;
  if Result <> '' then
    Exit;

  var Title := ChangeFileExt(ExtractFileName(RomName), '').Trim;
  for var i := 1 to Length(Title) do
    if (Ord(Title[i]) < 32) or CharInSet(Title[i], ['<', '>', ':', '"', '/', '\', '|', '?', '*']) then
      Title[i] := '_';
  Title := Copy(Title, 1, 80).Trim;
  if Title = '' then
    Title := 'Game';
  Result := TPath.Combine(Root, Title + '_' + SafeName(Identity) + Extension);
end;

function GameIdentity(const SystemId, Identity: string): string;
begin
  Result := Identity;
  if not SameText(SystemId, ROM_SYSTEM_NES) and not StartsText(UpperCase(SystemId) + '-', Identity) then
    Result := UpperCase(SafeName(SystemId)) + '-' + Identity;
end;

function TStorage.GameSave(const SystemId, RomName, Identity: string): string;
begin
  Result := GamePath(SaveRoot, RomName, GameIdentity(SystemId, Identity), '.sav');
end;

function TStorage.GameSnapshots(const SystemId, RomName, Identity: string): string;
begin
  Result := GamePath(SnapshotRoot, RomName, GameIdentity(SystemId, Identity), '');
end;

function TStorage.Snapshots(const SystemId, RomName, Identity: string): TArray<TStorageSnapshot>;
begin
  var List := TList<TStorageSnapshot>.Create;
  try
    for var Path in Files(GameSnapshots(SystemId, RomName, Identity)) do
      if SameText(ExtractFileExt(Path), '.snapshot') then
      begin
        var Item := System.Default(TStorageSnapshot);
        Item.Name := ChangeFileExt(ExtractFileName(Path), '');
        Item.Location := Path;
        Item.PreviewLocation := ChangeFileExt(Path, '.png');
        if not Exists(Item.PreviewLocation) then
          Item.PreviewLocation := ChangeFileExt(Path, '.bmp'); // Read legacy previews.
        if not Exists(Item.PreviewLocation) then
          Item.PreviewLocation := '';
        Item.Modified := ModifiedTime(Path);
        List.Add(Item);
      end;
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

function TStorage.Describe(const Location: string): TStorageFile;
begin
  {$IFDEF ANDROID}
  if Location.StartsWith('content://') then
    Exit(TAndroidStorage.Describe(Location));
  {$ENDIF}
  Result := System.Default(TStorageFile);
  Result.Location := Location;
  Result.Name := ExtractFileName(Location);
  Result.Size := TFile.GetSize(NativeStoragePath(Location));
end;

function TStorage.Roms(const SystemId: string): TArray<TStorageFile>;
begin
  if FRomFolder = '' then
    Exit(nil);

  var RomSystem := RomSystemFromId(LowerCase(SafeName(SystemId)));
  if RomSystem = TRomSystem.Unknown then
    Exit(nil);

  var platform := TPlatformRegistry.Require(SystemId);
  var FolderName := platform.Folder;
  var Extensions := platform.Extensions;
  var FolderNames := platform.ScanFolders;
  var Candidates: TArray<TStorageFile>;
  {$IFDEF ANDROID}
  if FRomFolder.StartsWith('content://') then
  begin
    // Query only root directories, then the selected system's direct children.
    for var Folder in TAndroidStorage.Enumerate(FRomFolder, False, True) do
      if MatchText(Folder.Name, FolderNames) then
      begin
        var Items := TAndroidStorage.Enumerate(Folder.Location, False);
        for var i := 0 to High(Items) do
          Items[i].RelativePath := Folder.Name + '/' + Items[i].Name;
        Candidates := Candidates + Items;
      end;
  end
  else
  {$ENDIF}
  begin
    var List := TList<TStorageFile>.Create;
    try
      for var CandidateFolder in FolderNames do
        for var Path in Files(TPath.Combine(FRomFolder, CandidateFolder)) do
        begin
          if not MatchText(ExtractFileExt(Path), Extensions) then
            Continue;

          var Item := Describe(Path);
          Item.RelativePath := ExtractRelativePath(IncludeTrailingPathDelimiter(FRomFolder), Path);
          List.Add(Item);
        end;
      Candidates := List.ToArray;
    finally
      List.Free;
    end;
  end;
  var Matches := TList<TStorageFile>.Create;
  try
    for var Item in Candidates do
    begin
      if (RomSystem in [TRomSystem.NeoGeo, TRomSystem.NeoGeoAES]) and (SameText(Item.Name, 'neogeo.zip') or SameText(Item.Name, 'gg-bios.zip') or
        SameText(Item.Name, 'neocd.zip') or SameText(Item.Name, 'neogeo.7z') or
        SameText(Item.Name, 'gg-bios.7z') or SameText(Item.Name, 'neocd.7z')) then
        Continue;

      // Prefer the CUE with its complete TOC/audio over the paired data ISO.
      if (RomSystem in [TRomSystem.NeoGeoCD, TRomSystem.PCECD, TRomSystem.SegaCD, TRomSystem.Saturn, TRomSystem.PS1]) and SameText(ExtractFileExt(Item.Name), '.iso') then
      begin
        var HasCue := False;
        for var Candidate in Candidates do
          if SameText(Candidate.Name, ChangeFileExt(Item.Name, '.cue')) and
            (ExtractFilePath(Candidate.RelativePath) = ExtractFilePath(Item.RelativePath)) then
            HasCue := True;
        if HasCue then
          Continue;
      end;

      // PlayStation track files belong to a CUE named like them (Game.cue with
      // Game.bin or "Game (Track 1).bin"); a lone BIN is a raw disc image.
      if (RomSystem = TRomSystem.PS1) and SameText(ExtractFileExt(Item.Name), '.bin') then
      begin
        var HasCue := False;
        for var Candidate in Candidates do
          if SameText(ExtractFileExt(Candidate.Name), '.cue') and
            (ExtractFilePath(Candidate.RelativePath) = ExtractFilePath(Item.RelativePath)) and
            ChangeFileExt(Item.Name, '').ToLower.StartsWith(ChangeFileExt(Candidate.Name, '').ToLower) then
            HasCue := True;
        if HasCue then
          Continue;
      end;

      // Listing never opens ROM streams. Header validation belongs to loading.
      var MaxSize := FMaxRomFileSize;
      if (RomSystem in [TRomSystem.NeoGeoCD, TRomSystem.PCECD, TRomSystem.SegaCD, TRomSystem.Saturn, TRomSystem.PS1]) and (MaxSize = ROM_MAX_SIZE) then
        MaxSize := Int64(800) * 1024 * 1024;
      if (RomSystem in [TRomSystem.NeoGeo, TRomSystem.NeoGeoAES]) and (MaxSize = ROM_MAX_SIZE) then
        MaxSize := 256 * 1024 * 1024;
      if (FCheckRomFileSize and (Item.Size > MaxSize)) or not MatchText(ExtractFileExt(Item.Name), Extensions) then
        Continue;

      if (RomSystem = TRomSystem.SuperGrafx) and
        not SameText(ExtractFileExt(Item.Name), '.sgx') and
        not Item.Name.ToLower.Contains('(sgx)') and not Item.Name.ToLower.Contains('supergrafx') and
        not Item.RelativePath.ToLower.StartsWith('sgx/') and not Item.RelativePath.ToLower.StartsWith('supergrafx/') and
        not Item.RelativePath.ToLower.StartsWith('sgx\') and not Item.RelativePath.ToLower.StartsWith('supergrafx\') then
        Continue;

      if RomSystem = TRomSystem.PCE then
      begin
        if Item.Name.ToLower.Contains('(sgx)') or Item.Name.ToLower.Contains('supergrafx') then
          Continue;
        if Item.Name.ToLower.Contains('[bios]') or Item.Name.ToLower.StartsWith('syscard') then
          Continue;
      end;

      var Match := Item;
      if Match.RelativePath = '' then
        Match.RelativePath := FolderName + '/' + Item.Name;
      Matches.Add(Match);
    end;
    Result := Matches.ToArray;
  finally
    Matches.Free;
  end;
end;

procedure TStorage.SelectRomFolder(const Callback: TStorageSelectionCallback);
begin
  if FPicker = nil then
    raise ENotSupportedException.Create('No storage picker is configured');

  var Storage: IStorage := Self;
  FPicker.Select(True,
    procedure(const Selection: TStorageSelection)
    begin
      var Result := Selection;
      if not Result.Cancelled and (Result.Error = '') then
      try
        Storage.RomFolder := Result.Location;
      except
        on E: Exception do
          Result.Error := E.Message;
      end;
      if Assigned(Callback) then
        Callback(Result);
    end);
end;

procedure TStorage.SelectRom(const Callback: TStorageSelectionCallback);
begin
  if FPicker = nil then
    raise ENotSupportedException.Create('No storage picker is configured');

  FPicker.Select(False, Callback);
end;

{$IFDEF IOS}
initialization
  IOSDocumentGrants := TList<TIOSDocumentGrant>.Create;

finalization
  for var Grant in IOSDocumentGrants do
    if Grant.Scoped then
      Grant.URL.stopAccessingSecurityScopedResource;
  IOSDocumentGrants.Free;
{$ENDIF}

end.

