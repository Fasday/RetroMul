{ PSP.Utility: savedata. A save is the folder ms0:/PSP/SAVEDATA/<game><save>
  with a PARAM.SFO; files written by the secure modes with a key are listed in
  its SAVEDATA_FILE_LIST, and SAVEDATA_PARAMS[0] records the protection mode.
  The data itself is stored as given (the mode is kept, not applied). In the
  headless runner list modes take the first listed save. }

const
  SdMode = $30;
  SdBind = $34;
  SdGameName = $3C;
  SdSaveName = $4C;
  SdSaveNameList = $60;
  SdFileName = $64;
  SdDataBuf = $74;
  SdDataBufSize = $78;
  SdDataSize = $7C;
  SdTitle = $80;
  SdSavedataTitle = $100;
  SdDetail = $180;
  SdParental = $580;
  SdIcon0 = $584;
  SdMsFree = $5D0;
  SdMsData = $5D4;
  SdUtilityData = $5D8;
  SdKey = $5DC;
  SdSecureVersion = $5EC;
  SdIdList = $5F4;
  SdFileList = $5F8;
  SdSizeInfo = $5FC;

  SD_LOAD_NO_MS = Cardinal($80110301);
  SD_LOAD_BROKEN = Cardinal($80110306);
  SD_LOAD_NO_DATA = Cardinal($80110307);
  SD_LOAD_PARAM = Cardinal($80110308);
  SD_LOAD_NO_FILE = Cardinal($80110309);
  SD_RW_NO_MS = Cardinal($80110321);
  SD_RW_BROKEN = Cardinal($80110326);
  SD_RW_NO_DATA = Cardinal($80110327);
  SD_RW_PARAM = Cardinal($80110328);
  SD_RW_NO_FILE = Cardinal($80110329);
  SD_DELETE_NO_MS = Cardinal($80110341);
  SD_DELETE_NO_DATA = Cardinal($80110347);
  SD_SAVE_NO_MS = Cardinal($80110381);
  SD_SAVE_PARAM = Cardinal($80110388);
  SD_SIZES_NO_MS = Cardinal($801103C1);

  SdClusterSize = $8000;
  // What the utility reports for an empty 16 GB stick.
  SdFreeClusters = $7FFFF;
  SdFreeKB = $FFFFFB;

  SfoFileListSize = $C60;
  SfoParamsSize = $80;
  SdSystemFiles: array[0..4] of string = ('PARAM.SFO', 'ICON0.PNG', 'ICON1.PMF', 'PIC1.PNG', 'SND0.AT3');

type
  ESaveName = class(Exception);

  TSaveFile = record
    Name: string;
    Size: Int64;
    Time: TDateTime;
  end;

  TSavedataRunner = class
  public
    M: TPSPMemory;
    Kernel: TPSPKernel;
    P, Size: Cardinal;
    Mode: Integer;
    GameName, SaveName, FileName: string;
    Key: TBytes;
    HasKey, HasVersion, Selected: Boolean;
    SecureVersion: Integer;
    Root: string;
    function Run: Cardinal;
    function RunMode: Cardinal;
    function Dir(const Name: string): string;
    function ModeByte(V: Integer): Byte;
    function ParamOk: Boolean;
    function Listed: TArray<string>;
    function FirstExisting(out Name: string): Boolean;
    function NowTime: TDateTime;
    procedure Stamp(const Path: string);
    procedure ReadGuest(Address, Size: Cardinal; out Data: TBytes);
    procedure LoadIcons(const D: string);
    procedure SaveIcons(const D: string);
    procedure FillSfoParam(Sfo: TPSPSFO);
    function WriteSave(const Name: string; Secure, NeedExisting: Boolean; out Res: Cardinal): Boolean;
    function DeleteSave(const Name: string): Boolean;
    function Load: Cardinal;
    function Read(Secure: Boolean): Cardinal;
    function Save: Cardinal;
    function Make(Secure: Boolean): Cardinal;
    function Write(Secure: Boolean): Cardinal;
    function Erase: Cardinal;
    function Sizes: Cardinal;
    function List: Cardinal;
    function Files: Cardinal;
    function GetSize: Cardinal;
  end;

function SdKeyIsSet(const Key: TBytes): Boolean;
begin
  for var B in Key do
    if B <> 0 then
      Exit(True);
  Result := False;
end;

function SdClusters(Size: Int64): Int64;
begin
  Result := (Size + SdClusterSize - 1) div SdClusterSize;
end;

function SdSizeString(KB: Int64): RawByteString;
begin
  if KB < 1024 then
    Result := RawByteString(Format('%d KB', [KB]))
  else if KB < 1024 * 1024 then
    Result := RawByteString(Format('%d MB', [KB div 1024]))
  else
    Result := RawByteString(Format('%d GB', [KB div (1024 * 1024)]));
end;

function SdFiles(const Dir: string): TArray<TSaveFile>;
begin
  Result := nil;
  if not TDirectory.Exists(Dir) then
    Exit;
  var Names := TDirectory.GetFiles(Dir);
  TArray.Sort<string>(Names);
  for var N in Names do
  begin
    var F: TSaveFile;
    F.Name := ExtractFileName(N).ToUpper;
    F.Size := TFile.GetSize(N);
    F.Time := TFile.GetLastWriteTime(N);
    Result := Result + [F];
  end;
end;

function SdUsedClusters(const Dir: string): Int64;
begin
  // The folder takes a cluster of its own.
  Result := 1;
  for var F in SdFiles(Dir) do
    Inc(Result, SdClusters(F.Size));
end;

function SdMatch(const Pattern, Name: string): Boolean;
begin
  // '?' is any one character, '*' any run.
  var P := 1;
  var N := 1;
  var StarP := 0;
  var StarN := 0;
  while N <= Length(Name) do
  begin
    if (P <= Length(Pattern)) and ((Pattern[P] = '?') or (UpCase(Pattern[P]) = UpCase(Name[N]))) then
    begin
      Inc(P);
      Inc(N);
    end
    else if (P <= Length(Pattern)) and (Pattern[P] = '*') then
    begin
      StarP := P;
      StarN := N;
      Inc(P);
    end
    else if StarP > 0 then
    begin
      P := StarP + 1;
      Inc(StarN);
      N := StarN;
    end
    else
      Exit(False);
  end;
  while (P <= Length(Pattern)) and (Pattern[P] = '*') do
    Inc(P);
  Result := P > Length(Pattern);
end;

procedure SdWriteDate(M: TPSPMemory; Address: Cardinal; T: TDateTime);
begin
  var Y, Mo, D, H, Mi, S, Ms: Word;
  DecodeDate(T, Y, Mo, D);
  DecodeTime(T, H, Mi, S, Ms);
  M.Write16(Address, Y);
  M.Write16(Address + 2, Mo);
  M.Write16(Address + 4, D);
  M.Write16(Address + 6, H);
  M.Write16(Address + 8, Mi);
  M.Write16(Address + 10, S);
  M.Write32(Address + 12, Cardinal(Ms) * 1000);
end;

function SdLoadSfo(const Dir: string; Sfo: TPSPSFO): Boolean;
begin
  var Name := TPath.Combine(Dir, 'PARAM.SFO');
  Result := TFile.Exists(Name) and Sfo.Load(TFile.ReadAllBytes(Name));
end;

function SdListIndex(const L: TBytes; const Name: string): Integer;
begin
  var I := 0;
  while I + 32 <= Length(L) do
  begin
    var N := 0;
    while (N < 13) and (L[I + N] <> 0) do
      Inc(N);
    if (N > 0) and SameText(TEncoding.ASCII.GetString(L, I, N), Name) then
      Exit(I);
    Inc(I, 32);
  end;
  Result := -1;
end;

function SdIsSecure(Sfo: TPSPSFO; const Name: string): Boolean;
begin
  Result := SdListIndex(Sfo.GetBytes('SAVEDATA_FILE_LIST'), Name) >= 0;
end;

function SdSecureTag(Sfo: TPSPSFO; const Name: string): TBytes;
begin
  var L := Sfo.GetBytes('SAVEDATA_FILE_LIST');
  var I := SdListIndex(L, Name);
  if I < 0 then
    Exit(nil);
  Result := Copy(L, I + 13, 16);
end;

// Lists Name as a secure file with its tag, or takes it off the list.
function SdSetSecure(Sfo: TPSPSFO; const Name: string; const Tag: TBytes; Secure: Boolean): Boolean;
begin
  var L := Sfo.GetBytes('SAVEDATA_FILE_LIST');
  var Old := Copy(L);
  if Length(L) < SfoFileListSize then
    SetLength(L, SfoFileListSize);
  var I := SdListIndex(L, Name);
  if I >= 0 then
    FillChar(L[I], 32, 0);
  if Secure then
  begin
    if I < 0 then
    begin
      I := 0;
      while (I + 32 <= Length(L)) and (L[I] <> 0) do
        Inc(I, 32);
    end;
    if I + 32 <= Length(L) then
    begin
      var B := TEncoding.ASCII.GetBytes(Name);
      Move(B[0], L[I], Min(Length(B), 12));
      if Length(Tag) >= 16 then
        Move(Tag[0], L[I + 13], 16);
    end;
  end;
  Sfo.SetBytes('SAVEDATA_FILE_LIST', L, SfoFileListSize);
  Result := (Length(Old) <> Length(L)) or not CompareMem(@Old[0], @L[0], Length(L));
end;

function SdTag(const Key, Data: TBytes): TBytes;
begin
  var H := THashMD5.Create;
  H.Update(Key);
  if Length(Data) > 0 then
    H.Update(Data);
  Result := H.HashAsBytes;
end;

{ TSavedataRunner }

function TSavedataRunner.Dir(const Name: string): string;
begin
  // The SDK's <> save-name marker names the game directory without a suffix.
  var Suffix := Name;
  if Suffix = '<>' then Suffix := '';
  // A name the memory stick cannot hold names no save.
  for var C in GameName + Suffix do
    if CharInSet(C, ['<', '>', ':', '"', '|', '?', '*', '\', '/']) or (C < ' ') then
      raise ESaveName.Create(Name);
  Result := TPath.Combine(Root, GameName + Suffix);
end;

function TSavedataRunner.ModeByte(V: Integer): Byte;
begin
  // Programs built for 3.00 and later get the newer protection by default.
  var Newer := Kernel.CompiledSdkVersion >= $03000000;
  case V of
    1: Result := $01;
    2: Result := $21;
    3: if Newer then Result := $41 else Result := $01;
  else
    if Newer then Result := $41 else Result := $21;
  end;
end;

function TSavedataRunner.ParamOk: Boolean;
begin
  if not HasVersion then
    Exit(True);
  if (SecureVersion < 0) or (SecureVersion > 3) then
    Exit(False);
  // Without a key only the unprotected mode works.
  Result := HasKey or (SecureVersion = 1);
end;

function TSavedataRunner.Listed: TArray<string>;
begin
  Result := nil;
  var L := M.Read32(P + SdSaveNameList);
  if L = 0 then
    Exit;
  for var I := 0 to 99 do
  begin
    var S := M.ReadString(L + Cardinal(I) * 20, 20);
    if S = '' then
      Break;
    Result := Result + [S];
  end;
end;

function TSavedataRunner.FirstExisting(out Name: string): Boolean;
begin
  for var S in Listed do
    try
      if TDirectory.Exists(Dir(S)) then
      begin
        Name := S;
        Exit(True);
      end;
    except
      on ESaveName do;
    end;
  Name := SaveName;
  Result := False;
end;

function TSavedataRunner.NowTime: TDateTime;
begin
  // The wall clock the RTC shows: 2026-01-01 plus guest time, local.
  Result := EncodeDate(2026, 1, 1) + (Kernel.Scheduler.Now / 86400e9) +
    (PSPSettings.Timezone + 60 * PSPSettings.DaylightSaving) / 1440;
end;

procedure TSavedataRunner.Stamp(const Path: string);
begin
  try
    var T := NowTime;
    if TDirectory.Exists(Path) then
    begin
      TDirectory.SetCreationTime(Path, T);
      TDirectory.SetLastWriteTime(Path, T);
    end
    else
    begin
      TFile.SetCreationTime(Path, T);
      TFile.SetLastWriteTime(Path, T);
    end;
  except
    on E: EInOutError do;
  end;
end;

procedure TSavedataRunner.ReadGuest(Address, Size: Cardinal; out Data: TBytes);
begin
  SetLength(Data, Size);
  if Size > 0 then
    M.ReadBytes(Address, Data[0], Size);
end;

procedure TSavedataRunner.LoadIcons(const D: string);
begin
  for var I := 0 to 3 do
  begin
    var F := P + SdIcon0 + Cardinal(I) * 16;
    var Buf := M.Read32(F);
    var BufSize := M.Read32(F + 4);
    var Name := TPath.Combine(D, SdSystemFiles[I + 1]);
    if (Buf = 0) or not TFile.Exists(Name) then
      Continue;
    var Data := TFile.ReadAllBytes(Name);
    var N := Min(Cardinal(Length(Data)), BufSize);
    if N > 0 then
      M.WriteBytes(Buf, Data[0], N);
    M.Write32(F + 8, N);
  end;
end;

procedure TSavedataRunner.SaveIcons(const D: string);
begin
  for var I := 0 to 3 do
  begin
    var F := P + SdIcon0 + Cardinal(I) * 16;
    var Buf := M.Read32(F);
    var N := M.Read32(F + 8);
    if (Buf = 0) or (N = 0) then
      Continue;
    var Data: TBytes;
    ReadGuest(Buf, N, Data);
    var Name := TPath.Combine(D, SdSystemFiles[I + 1]);
    TFile.WriteAllBytes(Name, Data);
    Stamp(Name);
  end;
end;

procedure TSavedataRunner.FillSfoParam(Sfo: TPSPSFO);
begin
  M.WriteString(P + SdTitle, UTF8Encode(Sfo.GetString('TITLE')), $80);
  M.WriteString(P + SdSavedataTitle, UTF8Encode(Sfo.GetString('SAVEDATA_TITLE')), $80);
  M.WriteString(P + SdDetail, UTF8Encode(Sfo.GetString('SAVEDATA_DETAIL')), $400);
  M.Write8(P + SdParental, Cardinal(Sfo.GetInt('PARENTAL_LEVEL')));
end;

function TSavedataRunner.WriteSave(const Name: string; Secure, NeedExisting: Boolean; out Res: Cardinal): Boolean;
begin
  Res := 0;
  var D := Dir(Name);
  var Sfo := TPSPSFO.Create;
  try
    var HadSfo := SdLoadSfo(D, Sfo);
    if NeedExisting then
    begin
      if not TDirectory.Exists(D) then
        begin Res := SD_RW_NO_DATA; Exit(False); end;
      if not HadSfo then
        begin Res := SD_RW_BROKEN; Exit(False); end;
    end;
    if not TDirectory.Exists(D) then
    begin
      ForceDirectories(D);
      Stamp(D);
    end;
    var Rewrite := not NeedExisting or Secure;
    if Rewrite then
    begin
      Sfo.SetString('CATEGORY', 'MS', 4);
      Sfo.SetInt('PARENTAL_LEVEL', M.Read8(P + SdParental));
      Sfo.SetString('SAVEDATA_DETAIL', UTF8ToString(M.ReadAnsi(P + SdDetail, $400)), $400);
      Sfo.SetString('SAVEDATA_DIRECTORY', ExtractFileName(D), $40);
      Sfo.SetString('SAVEDATA_TITLE', UTF8ToString(M.ReadAnsi(P + SdSavedataTitle, $80)), $80);
      Sfo.SetString('TITLE', UTF8ToString(M.ReadAnsi(P + SdTitle, $80)), $80);
      var Params := Sfo.GetBytes('SAVEDATA_PARAMS');
      SetLength(Params, SfoParamsSize);
      Params[0] := ModeByte(SecureVersion);
      Sfo.SetBytes('SAVEDATA_PARAMS', Params, SfoParamsSize);
      if not Sfo.Has('SAVEDATA_FILE_LIST') then
        SdSetSecure(Sfo, '', nil, False);
    end;
    if FileName <> '' then
    begin
      var Data: TBytes;
      ReadGuest(M.Read32(P + SdDataBuf), M.Read32(P + SdDataSize), Data);
      var FilePath := TPath.Combine(D, FileName);
      TFile.WriteAllBytes(FilePath, Data);
      Stamp(FilePath);
      if SdSetSecure(Sfo, FileName, SdTag(Key, Data), Secure) then
        Rewrite := True;
    end;
    if not NeedExisting then
      SaveIcons(D);
    if Rewrite then
    begin
      var SfoPath := TPath.Combine(D, 'PARAM.SFO');
      TFile.WriteAllBytes(SfoPath, Sfo.Save);
      Stamp(SfoPath);
    end;
    Result := True;
  finally
    Sfo.Free;
  end;
end;

function TSavedataRunner.DeleteSave(const Name: string): Boolean;
begin
  var D := Dir(Name);
  if not TDirectory.Exists(D) then
    Exit(False);
  for var F in TDirectory.GetFiles(D) do
    TFile.Delete(F);
  TDirectory.Delete(D, True);
  Result := True;
end;

function TSavedataRunner.Load: Cardinal;
begin
  var Name := SaveName;
  if (Mode = 4) and not Selected then
    FirstExisting(Name);
  if not ParamOk then
    Exit(SD_LOAD_PARAM);
  var D := Dir(Name);
  if not TDirectory.Exists(D) then
    Exit(SD_LOAD_NO_DATA);
  var Sfo := TPSPSFO.Create;
  try
    if not SdLoadSfo(D, Sfo) then
      Exit(SD_LOAD_BROKEN);
    if Mode = 4 then
      M.WriteString(P + SdSaveName, RawByteString(Name), 20);
    FillSfoParam(Sfo);
    LoadIcons(D);
    if FileName = '' then
      Exit(0);
    var FilePath := TPath.Combine(D, FileName);
    if not TFile.Exists(FilePath) then
      Exit(SD_LOAD_NO_FILE);
    var Data := TFile.ReadAllBytes(FilePath);
    if SdIsSecure(Sfo, FileName) then
    begin
      var Params := Sfo.GetBytes('SAVEDATA_PARAMS');
      if (Length(Params) = 0) or (Params[0] <> ModeByte(SecureVersion)) then
        Exit(SD_LOAD_BROKEN);
      var Tag := SdSecureTag(Sfo, FileName);
      var Expected := SdTag(Key, Data);
      if SdKeyIsSet(Tag) and not CompareMem(@Tag[0], @Expected[0], 16) then
        Exit(SD_LOAD_BROKEN);
    end;
    var N := Min(Cardinal(Length(Data)), M.Read32(P + SdDataBufSize));
    if N > 0 then
      M.WriteBytes(M.Read32(P + SdDataBuf), Data[0], N);
    M.Write32(P + SdDataSize, N);
    Result := 0;
  finally
    Sfo.Free;
  end;
end;

function TSavedataRunner.Read(Secure: Boolean): Cardinal;
begin
  if Secure and not ParamOk then
    Exit(SD_RW_PARAM);
  var D := Dir(SaveName);
  if not TDirectory.Exists(D) then
    Exit(SD_RW_NO_DATA);
  var Sfo := TPSPSFO.Create;
  try
    if not SdLoadSfo(D, Sfo) then
      Exit(SD_RW_BROKEN);
    if FileName = '' then
      Exit(0);
    var FilePath := TPath.Combine(D, FileName);
    if not TFile.Exists(FilePath) then
      Exit(SD_RW_NO_FILE);
    var Data := TFile.ReadAllBytes(FilePath);
    if SdIsSecure(Sfo, FileName) then
    begin
      // A protected file only opens through the secure modes.
      if not Secure then
        Exit(SD_RW_BROKEN);
      var Params := Sfo.GetBytes('SAVEDATA_PARAMS');
      if (Length(Params) = 0) or (Params[0] <> ModeByte(SecureVersion)) then
        Exit(SD_RW_BROKEN);
    end;
    var N := Min(Cardinal(Length(Data)), M.Read32(P + SdDataBufSize));
    if N > 0 then
      M.WriteBytes(M.Read32(P + SdDataBuf), Data[0], N);
    M.Write32(P + SdDataSize, N);
    Result := 0;
  finally
    Sfo.Free;
  end;
end;

function TSavedataRunner.Save: Cardinal;
begin
  var Name := SaveName;
  if (Mode = 5) and not Selected then
  begin
    var L := Listed;
    if Length(L) > 0 then
      Name := L[0];
  end;
  if not ParamOk then
    Exit(SD_SAVE_PARAM);
  WriteSave(Name, HasKey, False, Result);
  if Mode = 5 then
    M.WriteString(P + SdSaveName, RawByteString(Name), 20);
end;

function TSavedataRunner.Make(Secure: Boolean): Cardinal;
begin
  if Secure and not ParamOk then
    Exit(SD_RW_PARAM);
  WriteSave(SaveName, Secure and HasKey, False, Result);
end;

function TSavedataRunner.Write(Secure: Boolean): Cardinal;
begin
  if Secure and not ParamOk then
    Exit(SD_RW_PARAM);
  WriteSave(SaveName, Secure and HasKey, True, Result);
end;

function TSavedataRunner.Erase: Cardinal;
begin
  var D := Dir(SaveName);
  if not TDirectory.Exists(D) then
    Exit(SD_RW_NO_DATA);
  var Sfo := TPSPSFO.Create;
  try
    if not SdLoadSfo(D, Sfo) then
      Exit(SD_RW_BROKEN);
    if FileName = '' then
      Exit(0);
    var FilePath := TPath.Combine(D, FileName);
    if not TFile.Exists(FilePath) then
      Exit(SD_RW_NO_FILE);
    TFile.Delete(FilePath);
    if SdSetSecure(Sfo, FileName, nil, False) then
      TFile.WriteAllBytes(TPath.Combine(D, 'PARAM.SFO'), Sfo.Save);
    Result := 0;
  finally
    Sfo.Free;
  end;
end;

function TSavedataRunner.Sizes: Cardinal;
begin
  var Free := M.Read32(P + SdMsFree);
  if Free <> 0 then
  begin
    M.Write32(Free, SdClusterSize);
    M.Write32(Free + 4, SdFreeClusters);
    M.Write32(Free + 8, SdFreeKB);
    M.WriteString(Free + 12, SdSizeString(SdFreeKB), 8);
  end;
  var Info := M.Read32(P + SdMsData);
  if Info <> 0 then
  begin
    var Clusters: Int64 := 0;
    var Saved := GameName;
    try
      GameName := M.ReadString(Info, 16);
      var D := Dir(M.ReadString(Info + 16, 20));
      if TDirectory.Exists(D) then
        Clusters := SdUsedClusters(D);
    except
      on ESaveName do;
    end;
    GameName := Saved;
    var KB := Clusters * (SdClusterSize div 1024);
    M.Write32(Info + 36, Cardinal(Clusters));
    M.Write32(Info + 40, Cardinal(KB));
    M.WriteString(Info + 44, SdSizeString(KB), 8);
    M.Write32(Info + 52, Cardinal(KB));
    M.WriteString(Info + 56, SdSizeString(KB), 8);
  end;
  var Need := M.Read32(P + SdUtilityData);
  if Need <> 0 then
  begin
    // The data file, PARAM.SFO, the pictures and sounds, and the folder.
    var Clusters: Int64 := 2;
    if FileName <> '' then
      Inc(Clusters, SdClusters(M.Read32(P + SdDataSize)));
    for var I := 0 to 3 do
      Inc(Clusters, SdClusters(M.Read32(P + SdIcon0 + Cardinal(I) * 16 + 8)));
    var KB := Clusters * (SdClusterSize div 1024);
    M.Write32(Need, Cardinal(Clusters));
    M.Write32(Need + 4, Cardinal(KB));
    M.WriteString(Need + 8, SdSizeString(KB), 8);
    M.Write32(Need + 16, Cardinal(KB));
    M.WriteString(Need + 20, SdSizeString(KB), 8);
  end;
  Result := 0;
end;

function TSavedataRunner.List: Cardinal;
begin
  var L := M.Read32(P + SdIdList);
  if L = 0 then
    Exit(0);
  var Max := Integer(M.Read32(L));
  var Entries := M.Read32(L + 8);
  var Names := TDirectory.GetDirectories(Root);
  TArray.Sort<string>(Names);
  var Count := 0;
  for var N in Names do
  begin
    if Count >= Max then
      Break;
    var Folder := ExtractFileName(N);
    if not Folder.ToUpper.StartsWith(GameName.ToUpper) then
      Continue;
    var Rest := Folder.Substring(Length(GameName));
    if not SdMatch(SaveName, Rest) then
      Continue;
    var E := Entries + Cardinal(Count) * 72;
    var T := TDirectory.GetLastWriteTime(N);
    M.Write32(E, $11FF);
    SdWriteDate(M, E + 4, TDirectory.GetCreationTime(N));
    SdWriteDate(M, E + 20, T);
    SdWriteDate(M, E + 36, T);
    M.WriteString(E + 52, RawByteString(Rest), 20);
    Inc(Count);
  end;
  M.Write32(L + 4, Cardinal(Count));
  Result := 0;
end;

function TSavedataRunner.Files: Cardinal;
begin
  var D := Dir(SaveName);
  if not TDirectory.Exists(D) then
    Exit(SD_RW_NO_DATA);
  var Sfo := TPSPSFO.Create;
  try
    if not SdLoadSfo(D, Sfo) then
      Exit(SD_RW_BROKEN);
    var L := M.Read32(P + SdFileList);
    if L <> 0 then
    begin
      var Max: array[0..2] of Integer;
      var Base: array[0..2] of Cardinal;
      var Count: array[0..2] of Integer;
      for var K := 0 to 2 do
      begin
        Max[K] := Integer(M.Read32(L + Cardinal(K) * 4));
        Base[K] := M.Read32(L + 24 + Cardinal(K) * 4);
        Count[K] := 0;
      end;
      for var F in SdFiles(D) do
      begin
        // 0 secure, 1 normal, 2 system.
        var K := 1;
        for var S in SdSystemFiles do
          if F.Name = S then
            K := 2;
        if (K = 1) and SdIsSecure(Sfo, F.Name) then
          K := 0;
        if (Count[K] >= Max[K]) or (Base[K] = 0) then
          Continue;
        var E := Base[K] + Cardinal(Count[K]) * 80;
        M.Write32(E, $21FF);
        M.Write32(E + 8, Cardinal(F.Size));
        M.Write32(E + 12, Cardinal(F.Size shr 32));
        SdWriteDate(M, E + 16, F.Time);
        SdWriteDate(M, E + 32, F.Time);
        SdWriteDate(M, E + 48, F.Time);
        M.WriteString(E + 64, RawByteString(F.Name), 16);
        Inc(Count[K]);
      end;
      M.Write32(L + 12, Cardinal(Count[0]));
      M.Write32(L + 16, Cardinal(Count[1]));
      M.Write32(L + 20, Cardinal(Count[2]));
    end;
    M.Write32(P + SdBind, $3FD);
    Result := 0;
  finally
    Sfo.Free;
  end;
end;

function TSavedataRunner.GetSize: Cardinal;
begin
  var S := M.Read32(P + SdSizeInfo);
  if S = 0 then
    Exit(0);
  M.Write32(S + 16, SdClusterSize);
  M.Write32(S + 20, SdFreeClusters);
  M.Write32(S + 24, SdFreeKB);
  M.WriteString(S + 28, SdSizeString(SdFreeKB), 8);
  var NumSecure := Integer(M.Read32(S));
  var NumNormal := Integer(M.Read32(S + 4));
  if NumSecure + NumNormal > 0 then
  begin
    var Clusters: Int64 := 2;
    for var K := 0 to 1 do
    begin
      var Count := NumSecure;
      if K = 1 then
        Count := NumNormal;
      var Entries := M.Read32(S + 8 + Cardinal(K) * 4);
      for var I := 0 to Count - 1 do
      begin
        var E := Entries + Cardinal(I) * 24;
        Inc(Clusters, SdClusters(Int64(UInt64(M.Read32(E)) or (UInt64(M.Read32(E + 4)) shl 32))));
      end;
    end;
    // What the stick lacks for a new save and for rewriting the existing one:
    // nothing while there is room (programs take any other value as "full").
    var D := Dir(SaveName);
    var Existing: Int64 := 0;
    if TDirectory.Exists(D) then
      Existing := SdUsedClusters(D);
    var Lack := System.Math.Max(0, Clusters - SdFreeClusters) * (SdClusterSize div 1024);
    var LackOver := System.Math.Max(0, Clusters - Existing - SdFreeClusters) * (SdClusterSize div 1024);
    M.Write32(S + 36, Cardinal(Lack));
    M.WriteString(S + 40, SdSizeString(Lack), 8);
    M.Write32(S + 48, Cardinal(LackOver));
    M.WriteString(S + 52, SdSizeString(LackOver), 8);
  end;
  Result := 0;
end;

function TSavedataRunner.Run: Cardinal;
begin
  try
    Result := RunMode;
  except
    on ESaveName do
      case Mode of
        0, 2, 4: Result := SD_LOAD_NO_DATA;
        1, 3, 5: Result := SD_SAVE_PARAM;
        6, 7, 9, 10, 21: Result := SD_DELETE_NO_DATA;
        8, 11, 22: Result := 0;
      else
        Result := SD_RW_NO_DATA;
      end;
  end;
end;

function TSavedataRunner.RunMode: Cardinal;
begin
  if Root = '' then
    case Mode of
      0, 2, 4: Exit(SD_LOAD_NO_MS);
      1, 3, 5: Exit(SD_SAVE_NO_MS);
      6, 7, 9, 10: Exit(SD_DELETE_NO_MS);
      8: Exit(SD_SIZES_NO_MS);
    else
      Exit(SD_RW_NO_MS);
    end;
  case Mode of
    0, 2, 4: Result := Load;
    1, 3, 5: Result := Save;
    6:
      begin
        if Selected then
        begin
          if DeleteSave(SaveName) then
            Exit(0);
        end
        else
        begin
          var Name: string;
          if FirstExisting(Name) then
            DeleteSave(Name);
        end;
        Result := SD_DELETE_NO_DATA;
      end;
    7:
      begin
        Result := 0;
        for var Name in Listed do
          try
            if DeleteSave(Name) then
              Inc(Result);
          except
            on ESaveName do;
          end;
      end;
    8: Result := Sizes;
    9, 10, 21:
      if DeleteSave(SaveName) then
        Result := 0
      else
        Result := SD_DELETE_NO_DATA;
    11: Result := List;
    12: Result := Files;
    13: Result := Make(True);
    14: Result := Make(False);
    15: Result := Read(True);
    16: Result := Read(False);
    17: Result := Write(True);
    18: Result := Write(False);
    19, 20: Result := Erase;
    22: Result := GetSize;
  else
    Result := SD_LOAD_PARAM;
  end;
end;

procedure TPSPUtility.StepSavedata(D: TPSPDialog);
begin
  if D.Done then
    Exit;
  var R := TSavedataRunner.Create;
  try
    var P := D.Params;
    R.M := FMemory;
    R.Kernel := FKernel;
    R.P := P;
    R.Size := D.Size;
    R.Mode := Integer(FMemory.Read32(P + SdMode));
    R.GameName := FMemory.ReadString(P + SdGameName, 13);
    R.SaveName := FMemory.ReadString(P + SdSaveName, 20);
    R.FileName := FMemory.ReadString(P + SdFileName, 13);
    SetLength(R.Key, 16);
    FillChar(R.Key[0], 16, 0);
    if R.Size > SdKey then
      FMemory.ReadBytes(P + SdKey, R.Key[0], 16);
    R.HasKey := SdKeyIsSet(R.Key);
    R.HasVersion := R.Size >= $600;
    R.SecureVersion := 0;
    if R.HasVersion then
      R.SecureVersion := Integer(FMemory.Read32(P + SdSecureVersion));
    R.Root := '';
    if FSystem.IO.MemstickRoot <> '' then
    begin
      R.Root := TPath.Combine(FSystem.IO.MemstickRoot, 'PSP' + PathDelim + 'SAVEDATA');
      ForceDirectories(R.Root);
    end;
    if Interactive and (R.Mode >= 2) and (R.Mode <= 6) then
    begin
      if D.Stage = 0 then
      begin
        var Candidates: TArray<string>;
        if R.Mode in [4, 5, 6] then
          Candidates := R.Listed;
        if Length(Candidates) = 0 then
          Candidates := [R.SaveName];
        for var Name in Candidates do
          try
            if (R.Mode in [3, 5]) or TDirectory.Exists(R.Dir(Name)) then
              D.Choices := D.Choices + [Name];
          except
            on ESaveName do;
          end;
        case R.Mode of
          2, 4: D.Text := 'Select saved data to load.';
          3, 5: D.Text := 'Select where to save this data.';
          6: D.Text := 'Select saved data to delete.';
        end;
        if Length(D.Choices) = 0 then
          D.Text := 'There is no saved data.';
        D.Stage := 1;
      end;
      var B := Pressed(D);
      if (B and CancelButton) <> 0 then
      begin
        FMemory.Write32(P + DialogResult, 1);
        D.Done := True;
        Finish(D);
        Exit;
      end;
      if D.Stage = 1 then
      begin
        if (B and PSP_CTRL_UP) <> 0 then
          D.Selection := Max(0, D.Selection - 1);
        if (B and PSP_CTRL_DOWN) <> 0 then
          D.Selection := Min(Max(0, High(D.Choices)), D.Selection + 1);
      end;
      if (B and ConfirmButton) = 0 then
        Exit;
      if Length(D.Choices) = 0 then
      begin
        if R.Mode = 6 then
          FMemory.Write32(P + DialogResult, SD_DELETE_NO_DATA)
        else
          FMemory.Write32(P + DialogResult, SD_LOAD_NO_DATA);
        D.Done := True;
        Finish(D);
        Exit;
      end;
      R.SaveName := D.Choices[D.Selection];
      R.Selected := True;
      FMemory.WriteString(P + SdSaveName, RawByteString(R.SaveName), 20);
      if D.Stage = 1 then
      begin
        var Overwrite := False;
        if R.Mode in [3, 5] then
          try
            Overwrite := TDirectory.Exists(R.Dir(R.SaveName));
          except
            on ESaveName do;
          end;
        if Overwrite or (R.Mode = 6) then
        begin
          D.Stage := 2;
          if R.Mode = 6 then
            D.Text := 'Delete this saved data? This cannot be undone.'
          else
            D.Text := 'Overwrite this saved data?';
          Exit;
        end;
      end;
    end;
    D.Done := True;
    var Res: Cardinal;
    try
      Res := R.Run;
    except
      on E: EInOutError do
        Res := SD_RW_NO_MS;
      on E: EFileStreamError do
        Res := SD_RW_NO_MS;
    end;
    FMemory.Write32(P + DialogResult, Res);
    if FHLE.TraceCalls then
      FHLE.Log('utility: savedata mode %d -> %.8x', [R.Mode, Res]);
  finally
    R.Free;
  end;
  Finish(D);
end;
