{ PSP.Misc: sceReg, the system registry. The tree holds what games read:
  language, button assignment, nickname, date and time settings, network
  defaults and the font list. Registry handles are 0; categories get small
  handles; keys are addressed by name or by their handle within a category. }

const
  REG_TYPE_DIR = 1;
  REG_TYPE_INT = 2;
  REG_TYPE_STR = 3;
  REG_TYPE_BIN = 4;
  REG_ERROR_NOT_FOUND = Cardinal($80082710);
  REG_ERROR_BAD_HANDLE = Cardinal($80082715);
  REG_ERROR_BAD_PATH = Cardinal($80082716);
  REG_ERROR_NO_CATEGORY = Cardinal($80082718);
  REG_ERROR_SIZE = Cardinal($80082719);
  RegKeyNameSize = 27;

constructor TRegKey.Create(const AName: string; AKind: Integer);
begin
  inherited Create;
  Name := AName;
  Kind := AKind;
  Children := TObjectList<TRegKey>.Create(True);
end;

destructor TRegKey.Destroy;
begin
  Children.Free;
  inherited;
end;

function TRegKey.Find(const AName: string): TRegKey;
begin
  for var K in Children do
    if K.Name = AName then
      Exit(K);
  Result := nil;
end;

function TRegKey.Dir(const AName: string): TRegKey;
begin
  Result := Find(AName);
  if Result = nil then
  begin
    Result := TRegKey.Create(AName, REG_TYPE_DIR);
    Children.Add(Result);
  end;
end;

function TRegKey.AddInt(const AName: string; V: Integer): TRegKey;
begin
  Result := TRegKey.Create(AName, REG_TYPE_INT);
  Result.IntValue := V;
  Children.Add(Result);
end;

function TRegKey.AddStr(const AName, V: string; Size: Integer): TRegKey;
begin
  Result := TRegKey.Create(AName, REG_TYPE_STR);
  var B := TEncoding.UTF8.GetBytes(V);
  if Size < Length(B) + 1 then
    Size := Length(B) + 1;
  SetLength(Result.Data, Size);
  FillChar(Result.Data[0], Size, 0);
  if Length(B) > 0 then
    Move(B[0], Result.Data[0], Length(B));
  Children.Add(Result);
end;

function TRegKey.AddBin(const AName: string; const V: TBytes): TRegKey;
begin
  Result := TRegKey.Create(AName, REG_TYPE_BIN);
  Result.Data := Copy(V);
  Children.Add(Result);
end;

function TRegKey.Size: Cardinal;
begin
  case Kind of
    REG_TYPE_DIR: Result := 0;
    REG_TYPE_INT: Result := 4;
  else
    Result := Length(Data);
  end;
end;

function TRegKey.Value: TBytes;
begin
  if Kind = REG_TYPE_INT then
  begin
    SetLength(Result, 4);
    Move(IntValue, Result[0], 4);
  end
  else
    Result := Data;
end;

function RegBytes(const Values: array of Byte): TBytes;
begin
  SetLength(Result, Length(Values));
  for var I := 0 to High(Values) do
    Result[I] := Values[I];
end;

procedure TPSPMisc.BuildRegistry;
begin
  FRegRoot.Free;
  FRegRoot := TRegKey.Create('', REG_TYPE_DIR);
  var Registry := FRegRoot.Dir('REGISTRY');
  Registry.AddInt('category_version', $66);
  var Config := FRegRoot.Dir('CONFIG');
  var Data := FRegRoot.Dir('DATA');
  var Profile := FRegRoot.Dir('SYSPROFILE');

  var System := Config.Dir('SYSTEM');
  System.AddStr('owner_name', PSPSettings.Nickname, $80);
  var Xmb := System.Dir('XMB');
  Xmb.AddInt('language', PSPSettings.Language);
  Xmb.AddInt('button_assign', PSPSettings.ButtonSwap);
  Xmb.AddInt('theme_type', 0);
  var Lock := System.Dir('LOCK');
  Lock.AddInt('parental_level', PSPSettings.ParentalLevel);
  Lock.AddStr('password', '0000', 5);
  var Power := System.Dir('POWER_SAVING');
  Power.AddInt('suspend_interval', 600);
  Power.AddInt('backlight_off_interval', 300);
  Power.AddInt('wlan_mode', PSPSettings.WlanPowerSave);
  var Charset := System.Dir('CHARACTER_SET');
  Charset.AddInt('oem', 5);
  Charset.AddInt('ansi', $13);
  System.Dir('SOUND').AddInt('main_volume', 20);
  System.Dir('SOUND').AddInt('equalizer_mode', 0);
  System.Dir('SOUND').AddInt('avls', 0);

  var Date := Config.Dir('DATE');
  Date.AddInt('date_format', PSPSettings.DateFormat);
  Date.AddInt('time_format', PSPSettings.TimeFormat);
  Date.AddInt('time_zone_offset', PSPSettings.Timezone);
  Date.AddStr('time_zone_area', 'europe_london', $40);
  Date.AddInt('summer_time', PSPSettings.DaylightSaving);

  var Network := Config.Dir('NETWORK');
  var Adhoc := Network.Dir('ADHOC');
  Adhoc.AddStr('ssid_prefix', 'PSP', 4);
  Adhoc.AddInt('channel', PSPSettings.AdhocChannel);
  Network.Dir('INFRASTRUCTURE').AddInt('latest_id', 0);
  var Premo := Config.Dir('PREMO');
  Premo.AddInt('guide_page', 1);
  Premo.AddBin('ps3_mac', RegBytes([0, 0, 0, 0, 0, 0]));
  Premo.AddStr('ps3_name', '', $80);
  Premo.AddInt('flags', 0);
  Config.Dir('BROWSER').AddInt('flash_activated', 1);
  Config.Dir('ALARM');
  Config.Dir('CAMERA');
  Config.Dir('DISPLAY').AddInt('color_space_mode', 0);
  Config.Dir('GAME').AddInt('ap_title_name', 0);
  Config.Dir('MUSIC').AddInt('wma_play', 0);
  Config.Dir('PHOTO').AddInt('slideshow_speed', 0);
  Config.Dir('VIDEO').AddInt('menu_language', PSPSettings.Language);

  var Font := Data.Dir('FONT');
  Font.AddStr('path_name', 'flash0:/font', 13);
  Font.AddInt('num_fonts', 18);
  var Prop := Font.Dir('PROPERTY');
  for var I := 0 to 17 do
  begin
    var Info := Prop.Dir(Format('INFO%d', [I]));
    Info.AddStr('file_name', PSPFontFileName(I), $40);
  end;
  Data.Dir('COUNT').AddInt('boot_count', 1);

  Profile.Dir('RESOLUTION').AddInt('horizontal', 480);
  Profile.Dir('RESOLUTION').AddInt('vertical', 272);
  Profile.Dir('SOUND').AddInt('sound_volume', 20);
end;

function TPSPMisc.RegCategory(Handle: Cardinal): TRegKey;
begin
  if not FRegHandles.TryGetValue(Handle, Result) then
    Result := nil;
end;

function TPSPMisc.RegPath(const Path: string): TRegKey;
begin
  Result := nil;
  var Parts := Path.Split(['/'], TStringSplitOptions.ExcludeEmpty);
  if Length(Parts) = 0 then
    Exit;
  var K := FRegRoot;
  for var P in Parts do
  begin
    K := K.Find(P);
    if (K = nil) or (K.Kind <> REG_TYPE_DIR) then
      Exit(nil);
  end;
  Result := K;
end;

procedure TPSPMisc.hRegOpenRegistry;
begin
  if FHLE.Arg(2) <> 0 then
    FMemory.Write32(FHLE.Arg(2), 0);
  FHLE.Result(0);
end;

procedure TPSPMisc.hRegCloseRegistry;
begin
  if FHLE.Arg(0) <> 0 then
    FHLE.Result(REG_ERROR_BAD_HANDLE)
  else
    FHLE.Result(0);
end;

procedure TPSPMisc.hRegOpenCategory;
begin
  var Out_ := FHLE.Arg(3);
  var Fail := procedure(Code: Cardinal)
    begin
      if Out_ <> 0 then
        FMemory.Write32(Out_, $FFFFFFFF);
      FHLE.Result(Code);
    end;
  if FHLE.Arg(0) <> 0 then
    begin Fail(REG_ERROR_BAD_HANDLE); Exit; end;
  var Path := FMemory.ReadString(FHLE.Arg(1), 256);
  if (Path = '') or (Path = '/') then
    begin Fail(REG_ERROR_BAD_PATH); Exit; end;
  var K := RegPath(Path);
  if K = nil then
    begin Fail(REG_ERROR_NO_CATEGORY); Exit; end;
  Inc(FRegNextHandle);
  FRegHandles.AddOrSetValue(FRegNextHandle, K);
  if Out_ <> 0 then
    FMemory.Write32(Out_, FRegNextHandle);
  FHLE.Result(0);
end;

procedure TPSPMisc.hRegCloseCategory;
begin
  if not FRegHandles.ContainsKey(FHLE.Arg(0)) then
    begin FHLE.Result(REG_ERROR_BAD_HANDLE); Exit; end;
  FRegHandles.Remove(FHLE.Arg(0));
  FHLE.Result(0);
end;

procedure TPSPMisc.hRegZero;
begin
  FHLE.Result(0);
end;

procedure TPSPMisc.hRegGetKeysNum;
begin
  var C := RegCategory(FHLE.Arg(0));
  if C = nil then
    begin FHLE.Result(REG_ERROR_BAD_HANDLE); Exit; end;
  FMemory.Write32(FHLE.Arg(1), Cardinal(C.Children.Count));
  FHLE.Result(0);
end;

procedure TPSPMisc.hRegGetKeys;
begin
  var C := RegCategory(FHLE.Arg(0));
  if C = nil then
    begin FHLE.Result(REG_ERROR_BAD_HANDLE); Exit; end;
  var Buf := FHLE.Arg(1);
  var N := Min(FHLE.ArgInt(2), C.Children.Count);
  for var I := 0 to N - 1 do
    FMemory.WriteString(Buf + Cardinal(I) * RegKeyNameSize, RawByteString(C.Children[I].Name), RegKeyNameSize);
  FHLE.Result(0);
end;

procedure TPSPMisc.hRegGetKeyInfo;
begin
  var C := RegCategory(FHLE.Arg(0));
  if C = nil then
    begin FHLE.Result(REG_ERROR_BAD_HANDLE); Exit; end;
  var Name := FMemory.ReadString(FHLE.Arg(1), RegKeyNameSize);
  var K := C.Find(Name);
  if K = nil then
    begin FHLE.Result(REG_ERROR_NOT_FOUND); Exit; end;
  if FHLE.Arg(2) <> 0 then FMemory.Write32(FHLE.Arg(2), Cardinal(C.Children.IndexOf(K)) + 1);
  if FHLE.Arg(3) <> 0 then FMemory.Write32(FHLE.Arg(3), Cardinal(K.Kind));
  if FHLE.Arg(4) <> 0 then FMemory.Write32(FHLE.Arg(4), K.Size);
  FHLE.Result(0);
end;

procedure TPSPMisc.RegWriteValue(K: TRegKey; Buf, Size: Cardinal);
begin
  if K.Kind = REG_TYPE_DIR then
    begin FHLE.Result(REG_ERROR_NOT_FOUND); Exit; end;
  var V := K.Value;
  if Size < Cardinal(Length(V)) then
    begin FHLE.Result(REG_ERROR_SIZE); Exit; end;
  if Length(V) > 0 then
    FMemory.WriteBytes(Buf, V[0], Length(V));
  FHLE.Result(0);
end;

procedure TPSPMisc.hRegGetKeyValue;
begin
  var C := RegCategory(FHLE.Arg(0));
  if C = nil then
    begin FHLE.Result(REG_ERROR_BAD_HANDLE); Exit; end;
  var Index := Integer(FHLE.Arg(1)) - 1;
  if (Index < 0) or (Index >= C.Children.Count) then
    begin FHLE.Result(REG_ERROR_NOT_FOUND); Exit; end;
  RegWriteValue(C.Children[Index], FHLE.Arg(2), FHLE.Arg(3));
end;

procedure TPSPMisc.hRegGetKeyInfoByName;
begin
  var C := RegCategory(FHLE.Arg(0));
  if C = nil then
    begin FHLE.Result(REG_ERROR_BAD_HANDLE); Exit; end;
  var K := C.Find(FMemory.ReadString(FHLE.Arg(1), RegKeyNameSize));
  if K = nil then
    begin FHLE.Result(REG_ERROR_NOT_FOUND); Exit; end;
  if FHLE.Arg(2) <> 0 then FMemory.Write32(FHLE.Arg(2), Cardinal(K.Kind));
  if FHLE.Arg(3) <> 0 then FMemory.Write32(FHLE.Arg(3), K.Size);
  FHLE.Result(0);
end;

procedure TPSPMisc.hRegGetKeyValueByName;
begin
  var C := RegCategory(FHLE.Arg(0));
  if C = nil then
    begin FHLE.Result(REG_ERROR_BAD_HANDLE); Exit; end;
  var K := C.Find(FMemory.ReadString(FHLE.Arg(1), RegKeyNameSize));
  if K = nil then
    begin FHLE.Result(REG_ERROR_NOT_FOUND); Exit; end;
  RegWriteValue(K, FHLE.Arg(2), FHLE.Arg(3));
end;

procedure TPSPMisc.hRegSetKeyValue;
begin
  var C := RegCategory(FHLE.Arg(0));
  if C = nil then
    begin FHLE.Result(REG_ERROR_BAD_HANDLE); Exit; end;
  var K := C.Find(FMemory.ReadString(FHLE.Arg(1), RegKeyNameSize));
  if (K = nil) or (K.Kind = REG_TYPE_DIR) then
    begin FHLE.Result(REG_ERROR_NOT_FOUND); Exit; end;
  var Size := FHLE.Arg(3);
  var V: TBytes;
  SetLength(V, Size);
  if Size > 0 then
    FMemory.ReadBytes(FHLE.Arg(2), V[0], Size);
  if K.Kind = REG_TYPE_INT then
  begin
    if Size >= 4 then
      Move(V[0], K.IntValue, 4);
  end
  else
    K.Data := V;
  FHLE.Result(0);
end;

procedure TPSPMisc.hRegCreateKey;
begin
  var C := RegCategory(FHLE.Arg(0));
  if C = nil then
    begin FHLE.Result(REG_ERROR_BAD_HANDLE); Exit; end;
  var Name := FMemory.ReadString(FHLE.Arg(1), RegKeyNameSize);
  if C.Find(Name) = nil then
  begin
    var K := TRegKey.Create(Name, FHLE.ArgInt(2));
    SetLength(K.Data, FHLE.Arg(3));
    if Length(K.Data) > 0 then
      FillChar(K.Data[0], Length(K.Data), 0);
    C.Children.Add(K);
  end;
  FHLE.Result(0);
end;

procedure TPSPMisc.hRegGetCategoryNumAtRoot;
begin
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), Cardinal(FRegRoot.Children.Count));
  FHLE.Result(0);
end;

procedure TPSPMisc.hRegGetCategoryListAtRoot;
begin
  var Buf := FHLE.Arg(1);
  var N := Min(FHLE.ArgInt(2), FRegRoot.Children.Count);
  for var I := 0 to N - 1 do
    FMemory.WriteString(Buf + Cardinal(I) * RegKeyNameSize, RawByteString(FRegRoot.Children[I].Name), RegKeyNameSize);
  FHLE.Result(0);
end;
