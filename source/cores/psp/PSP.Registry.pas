unit PSP.Registry;

interface
uses System.SysUtils,System.Generics.Collections,Core.Storage,PSP.Memory,PSP.CPU;
type
  TPSPRegistryEntry=class
    Name:string;
    Kind:Cardinal;
    Data:TBytes;
  end;
  TPSPRegistryCategory=record
    Path:string;
    Mode:Cardinal;
  end;
  TPSPRegistry=class
  private
    FMemory:TPSPMemory;FCPU:TPSPCPU;FStorage:IStorage;
    FDatabase:TObjectDictionary<string,TObjectList<TPSPRegistryEntry>>;
    FCategories:TDictionary<Cardinal,TPSPRegistryCategory>;
    FChanged:TDictionary<string,Boolean>;
    FOpenCount,FNextHandle:Cardinal;
    procedure AddData(const Path,Name:string;Kind:Cardinal;const Hex:string);
    function FindKey(const Path,Name:string):Integer;
    procedure Flush;
    procedure Load;
  public
    constructor Create(Memory:TPSPMemory;CPU:TPSPCPU;const Storage:IStorage);
    destructor Destroy;override;
    function Handle(NID:Cardinal;out Value:Cardinal):Boolean;
    function ReadInteger(const Path,Name:string;Default:Cardinal):Cardinal;
  end;
implementation
uses System.Classes,System.IOUtils,System.JSON,System.NetEncoding,System.Math;
const InvalidRegistry=$80082715;InvalidPath=$80082716;MissingCategory=$80082718;
  InvalidName=$80082738;Denied=$8008273B;BadAddress=$800200D3;
constructor TPSPRegistry.Create(Memory:TPSPMemory;CPU:TPSPCPU;const Storage:IStorage);
begin
  inherited Create;FMemory:=Memory;FCPU:=CPU;FStorage:=Storage;
  FDatabase:=TObjectDictionary<string,TObjectList<TPSPRegistryEntry>>.Create([doOwnsValues]);
  FCategories:=TDictionary<Cardinal,TPSPRegistryCategory>.Create;
  FChanged:=TDictionary<string,Boolean>.Create;FNextHandle:=1;
  {$I PSP.RegistryData.inc}
  Load;
end;
destructor TPSPRegistry.Destroy;
begin FChanged.Free;FCategories.Free;FDatabase.Free;inherited end;
function TPSPRegistry.FindKey(const Path,Name:string):Integer;
begin
  Result:=-1;var Entries:TObjectList<TPSPRegistryEntry>;
  if not FDatabase.TryGetValue(Path,Entries) then Exit;
  for var I:=0 to Entries.Count-1 do if Entries[I].Name=Name then Exit(I);
end;
procedure TPSPRegistry.AddData(const Path,Name:string;Kind:Cardinal;const Hex:string);
begin
  var Entries:TObjectList<TPSPRegistryEntry>;
  if not FDatabase.TryGetValue(Path,Entries) then
  begin Entries:=TObjectList<TPSPRegistryEntry>.Create(True);FDatabase.Add(Path,Entries) end;
  var Index:=FindKey(Path,Name);var Entry:TPSPRegistryEntry;
  if Index<0 then begin Entry:=TPSPRegistryEntry.Create;Entry.Name:=Name;Entries.Add(Entry) end else Entry:=Entries[Index];
  Entry.Kind:=Kind;SetLength(Entry.Data,Length(Hex) div 2);
  for var I:=0 to High(Entry.Data) do Entry.Data[I]:=StrToInt('$'+Copy(Hex,I*2+1,2));
  var ChildPath:=Name;if Path<>'' then ChildPath:=Path+'/'+Name;
  if (Kind=1) and not FDatabase.ContainsKey(ChildPath) then
    FDatabase.Add(ChildPath,TObjectList<TPSPRegistryEntry>.Create(True));
end;
function TPSPRegistry.ReadInteger(const Path,Name:string;Default:Cardinal):Cardinal;
begin
  Result:=Default;var Index:=FindKey(Path,Name);if Index<0 then Exit;
  var Entry:=FDatabase[Path][Index];if (Entry.Kind<>2) or (Length(Entry.Data)<>4) then Exit;
  Move(Entry.Data[0],Result,4);
end;
procedure TPSPRegistry.Load;
begin
  if FStorage=nil then Exit;
  var FileName:=TPath.Combine(FStorage.SaveRoot,'psp-registry.json');if not FStorage.Exists(FileName) then Exit;
  var Data:=FStorage.ReadBytes(FileName);if Length(Data)>4*1024*1024 then raise Exception.Create('PSP registry storage exceeds limit');
  var Root:=TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Data));
  try
    if not (Root is TJSONArray) then raise Exception.Create('Invalid PSP registry storage');
    if TJSONArray(Root).Count>4096 then raise Exception.Create('PSP registry entry limit');
    for var Item in TJSONArray(Root) do
    begin
      var Row:=Item as TJSONObject;var Path:=Row.GetValue<string>('path');var Name:=Row.GetValue<string>('name');var Kind:=Row.GetValue<Integer>('kind');
      var Bytes:=TNetEncoding.Base64.DecodeStringToBytes(Row.GetValue<string>('data'));
      if (Length(Path)>256) or (Length(Name)>27) or (Kind<1) or (Kind>4) or (Length(Bytes)>65536) then raise Exception.Create('Invalid PSP registry entry');
      var Hex:='';for var B in Bytes do Hex:=Hex+IntToHex(B,2);AddData(Path,Name,Kind,Hex);
      FChanged.AddOrSetValue(Path+#0+Name,True);
    end;
  finally Root.Free end;
end;
procedure TPSPRegistry.Flush;
begin
  if (FStorage=nil) or (FChanged.Count=0) then Exit;
  var Root:=TJSONArray.Create;
  try
    for var Changed in FChanged.Keys do
    begin
      var Split:=Changed.IndexOf(#0);var Path:=Changed.Substring(0,Split);var Name:=Changed.Substring(Split+1);
      var Index:=FindKey(Path,Name);if Index<0 then Continue;
      var Entry:=FDatabase[Path][Index];
      var Row:=TJSONObject.Create;Root.AddElement(Row);Row.AddPair('path',Path);Row.AddPair('name',Name);
      Row.AddPair('kind',TJSONNumber.Create(Entry.Kind));Row.AddPair('data',TNetEncoding.Base64.EncodeBytesToString(Entry.Data));
    end;
    FStorage.EnsureFolder(FStorage.SaveRoot);
    var Stream:=TStringStream.Create(Root.ToJSON,TEncoding.UTF8);
    try FStorage.WriteAtomic(TPath.Combine(FStorage.SaveRoot,'psp-registry.json'),Stream) finally Stream.Free end;
  finally Root.Free end;
end;
function TPSPRegistry.Handle(NID:Cardinal;out Value:Cardinal):Boolean;
  function ValidName(const Name:string):Boolean;
  begin Result:=(Name<>'') and (Length(TEncoding.UTF8.GetBytes(Name))<=27) and not Name.Contains('/') and not Name.Contains('..') end;
begin
  Result:=True;Value:=0;
  var A:=FCPU.Registers[4];var B:=FCPU.Registers[5];var C:=FCPU.Registers[6];var D:=FCPU.Registers[7];var E:=FCPU.Registers[8];
  case NID of
    $92E41280:
      begin
        if not FMemory.IsValid(A,272) or not FMemory.IsValid(C,4) then begin Value:=BadAddress;Exit end;
        if FMemory.ReadString(A+4,256)<>'/system' then begin Value:=InvalidRegistry;Exit end;
        if (B<>1) and (B<>2) then begin Value:=Denied;Exit end;
        FMemory.Write32(C,0);Inc(FOpenCount);Exit;
      end;
    $FA8A5739,$39461B4D:
      begin
        if (A<>0) or (FOpenCount=0) then begin Value:=InvalidRegistry;Exit end;
        Flush;
        if NID=$FA8A5739 then begin Dec(FOpenCount);if FOpenCount=0 then FCategories.Clear end;Exit;
      end;
    $1D8A762E:
      begin
        if not FMemory.IsValid(D,4) then begin Value:=BadAddress;Exit end;
        FMemory.Write32(D,$FFFFFFFF);
        if (A<>0) or (FOpenCount=0) then begin Value:=InvalidRegistry;Exit end;
        var Path:=FMemory.ReadString(B,256);while Path.StartsWith('/') do Delete(Path,1,1);
        if (Path='') or Path.Contains('..') or Path.EndsWith('/') then begin Value:=InvalidPath;Exit end;
        if not FDatabase.ContainsKey(Path) then begin Value:=MissingCategory;Exit end;
        if (C<>1) and (C<>2) then begin Value:=Denied;Exit end;
        var Category:TPSPRegistryCategory;Category.Path:=Path;Category.Mode:=C;
        var Id:=FNextHandle;Inc(FNextHandle);FCategories.Add(Id,Category);FMemory.Write32(D,Id);Exit;
      end;
    $0CAE832B,$0D69BF40,$57641A81,$17768E14,$D4475AA8,$28A8E98A,$2C0DB9DD,$2D211135,$C5768D02,$30BE0259: ;
  else Exit(False) end;
  var Category:TPSPRegistryCategory;
  if not FCategories.TryGetValue(A,Category) then begin Value:=MissingCategory;Exit end;
  if NID=$0CAE832B then begin FCategories.Remove(A);Exit end;
  if NID=$0D69BF40 then begin Flush;Exit end;
  var Entries:=FDatabase[Category.Path];
  if NID=$2C0DB9DD then
  begin if not FMemory.IsValid(B,4) then Value:=BadAddress else FMemory.Write32(B,Entries.Count);Exit end;
  if NID=$2D211135 then
  begin
    if (C>4096) or not FMemory.IsValid(B,C*27) then begin Value:=BadAddress;Exit end;
    for var I:=0 to Min(Integer(C),Entries.Count)-1 do
    begin var At:=B+Cardinal(I)*27;FMemory.Zero(At,27);FMemory.Load(At,Copy(TEncoding.UTF8.GetBytes(Entries[I].Name),0,26)) end;Exit;
  end;
  var Index:Integer;var Name:string;
  if NID=$28A8E98A then Index:=Integer(B)
  else begin Name:=FMemory.ReadString(B,28);if not ValidName(Name) then begin Value:=InvalidName;Exit end;Index:=FindKey(Category.Path,Name) end;
  if (NID=$57641A81) or (NID=$17768E14) then
  begin
    if Category.Mode=2 then begin Value:=Denied;Exit end;
    if (NID=$57641A81) and (Index>=0) then begin Value:=$80082728;Exit end;
    if NID=$57641A81 then
    begin
      if (C<1) or (C>4) or (D>65536) or ((C=2) and (D<>4)) then begin Value:=$FFFFFFFF;Exit end;
      AddData(Category.Path,Name,C,StringOfChar('0',D*2));FChanged.AddOrSetValue(Category.Path+#0+Name,True);Exit;
    end;
    if (Index<0) or (D>65536) or not FMemory.IsValid(C,D) then begin Value:=$FFFFFFFF;Exit end;
    var Entry:=Entries[Index];if (Entry.Kind=1) or ((Entry.Kind=2) and (D<4)) then begin Value:=$FFFFFFFF;Exit end;
    if Entry.Kind=2 then Entry.Data:=FMemory.ReadBytes(C,4) else Entry.Data:=FMemory.ReadBytes(C,D);
    if (Entry.Kind=3) and ((Length(Entry.Data)=0) or (Entry.Data[High(Entry.Data)]<>0)) then Entry.Data:=Entry.Data+TBytes.Create(0);
    FChanged.AddOrSetValue(Category.Path+#0+Name,True);Exit;
  end;
  if (Index<0) or (Index>=Entries.Count) then begin Value:=$FFFFFFFF;Exit end;
  var Entry:=Entries[Index];
  if (NID=$D4475AA8) or (NID=$C5768D02) then
  begin
    var TypeAddress:=C;var SizeAddress:=D;
    if NID=$D4475AA8 then
    begin
      if not FMemory.IsValid(C,4) then begin Value:=BadAddress;Exit end;
      FMemory.Write32(C,Index);TypeAddress:=D;SizeAddress:=E;
    end;
    if not FMemory.IsValid(TypeAddress,4) or not FMemory.IsValid(SizeAddress,4) then begin Value:=BadAddress;Exit end;
    FMemory.Write32(TypeAddress,Entry.Kind);FMemory.Write32(SizeAddress,Length(Entry.Data));Exit;
  end;
  if (D<Cardinal(Length(Entry.Data))) or not FMemory.IsValid(C,D) then begin Value:=$FFFFFFFF;Exit end;
  FMemory.Load(C,Entry.Data);
end;
end.
