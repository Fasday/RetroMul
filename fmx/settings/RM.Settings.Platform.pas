unit RM.Settings.platform;

interface

uses
  System.Classes, System.SysUtils, System.IniFiles, System.Generics.Collections,
  FMX.Types, FMX.Controls, FMX.Layouts, FMX.StdCtrls, FMX.Edit, FMX.ListBox,
  FMX.SpinBox, RM.Gamepad, Core.Platforms;

const
  SETTINGS_CATEGORY_GENERAL = 0;
  SETTINGS_CATEGORY_LIBRARY = 1;
  SETTINGS_CATEGORY_VIDEO_AUDIO = 2;
  SETTINGS_CATEGORY_CONTROLS = 3;
  SETTINGS_CATEGORY_PERIPHERALS = 4;

const
  SETTINGS_PAGE_MAIN = Core.Platforms.SETTINGS_PAGE_MAIN;
  SETTINGS_PAGE_GB = Core.Platforms.SETTINGS_PAGE_GB;
  SETTINGS_PAGE_GBC = Core.Platforms.SETTINGS_PAGE_GBC;
  SETTINGS_PAGE_NES = Core.Platforms.SETTINGS_PAGE_NES;
  SETTINGS_PAGE_MD = Core.Platforms.SETTINGS_PAGE_MD;
  SETTINGS_PAGE_SNES = Core.Platforms.SETTINGS_PAGE_SNES;
  SETTINGS_PAGE_NEOGEO = Core.Platforms.SETTINGS_PAGE_NEOGEO;
  SETTINGS_PAGE_GBA = Core.Platforms.SETTINGS_PAGE_GBA;
  SETTINGS_PAGE_N64 = Core.Platforms.SETTINGS_PAGE_N64;
  SETTINGS_PAGE_SG1000 = Core.Platforms.SETTINGS_PAGE_SG1000;
  SETTINGS_PAGE_SC3000 = Core.Platforms.SETTINGS_PAGE_SC3000;
  SETTINGS_PAGE_SF7000 = Core.Platforms.SETTINGS_PAGE_SF7000;
  SETTINGS_PAGE_MULTIVISION = Core.Platforms.SETTINGS_PAGE_MULTIVISION;
  SETTINGS_PAGE_SMS = Core.Platforms.SETTINGS_PAGE_SMS;
  SETTINGS_PAGE_GG = Core.Platforms.SETTINGS_PAGE_GG;
  SETTINGS_PAGE_GW = Core.Platforms.SETTINGS_PAGE_GW;
  SETTINGS_PAGE_PCE = Core.Platforms.SETTINGS_PAGE_PCE;
  SETTINGS_PAGE_SGX = Core.Platforms.SETTINGS_PAGE_SGX;
  SETTINGS_PAGE_PCECD = Core.Platforms.SETTINGS_PAGE_PCECD;
  SETTINGS_PAGE_NEOGEOCD = Core.Platforms.SETTINGS_PAGE_NEOGEOCD;

type
  TSettingsEditorClass = class of TControl;

  TSettingsEditorKind = (sekSwitch, sekCombo, sekNumber, sekPath);

  // The platform describes settings; the view owns controls, drafts and navigation.
  TSettingsPageContext = class abstract
  public
    Owner: TComponent;
    Store: TLayout;
    PageId: Integer;
    Draft: TMemIniFile;
    ComboClass, NumberClass: TSettingsEditorClass;
    OnRebuild, OnClearPath: TNotifyEvent;
    function NewLabel: TLabel;
    procedure CreateGroup(const Name, Caption: string);
    function CreateOption(const Name, Caption, Detail: string; Kind: TSettingsEditorKind): TControl;
    procedure Heading(const Name: string); virtual; abstract;
    function Combo(const Name, Section, Key: string; const Labels, Values: array of string; const Default: string): TComboBox; virtual; abstract;
    function Check(const Name, Section, Key: string; Default: Boolean): TSwitch; virtual; abstract;
    function Number(const Name, Section, Key: string; Default, Max: Integer): TSpinBox; virtual; abstract;
    function PathEdit(const Name, Section, Key, Default: string; Folder: Boolean): TEdit; virtual; abstract;
    procedure PalettePreview(Palette, Scaling: TComboBox); virtual; abstract;
    procedure BuildBindings(Port: Integer; const Device: string); virtual; abstract;
  end;

  TSettingsPortOptions = record
    RowName, Default: string;
    Labels, Values: TArray<string>;
  end;

  TSettingsPlatform = class
  public
    PageId: Integer;
    CoreId, Name, Brand, SearchTerms: string;
    PadLayout: TScreenGamepadLayout;
    Ports: Integer;
    constructor Create(const Info: TPlatformInfo);
    procedure Initialize(Context: TSettingsPageContext); virtual;
    procedure Video(Context: TSettingsPageContext); virtual;
    procedure Audio(Context: TSettingsPageContext); virtual;
    procedure Peripherals(Context: TSettingsPageContext); virtual;
    procedure Expansion(Context: TSettingsPageContext); virtual;
    procedure Validate(Draft: TMemIniFile); virtual;
    function PlayerCount(Draft: TMemIniFile): Integer; virtual;
    function PortOptions(Port: Integer): TSettingsPortOptions; virtual;
  end;

  TSettingsPlatformRegistry = class
  private
    FItems: TObjectList<TSettingsPlatform>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(platform: TSettingsPlatform);
    function Find(PageId: Integer): TSettingsPlatform;
    function MaxPageId: Integer;
    function Matching(const Query: string): TArray<TSettingsPlatform>;
    property Items: TObjectList<TSettingsPlatform> read FItems;
  end;

implementation

uses
  System.Types, System.Generics.Defaults, RM.Icons;

function TSettingsPageContext.NewLabel: TLabel;
begin
  Result := TLabel.Create(Owner);
  Result.StyledSettings := Result.StyledSettings - [TStyledSetting.Other];
  Result.TextSettings.Trimming := TTextTrimming.Character;
  Result.TextSettings.WordWrap := False;
end;

procedure TSettingsPageContext.CreateGroup(const Name, Caption: string);
begin
  if Owner.FindComponent('PanelGroup' + Name) <> nil then
    Exit;
  var Panel := TPanel.Create(Owner);
  Panel.Name := 'PanelGroup' + Name;
  Panel.Parent := Store;
  Panel.StyleLookup := 'retromul_card';
  Panel.Align := TAlignLayout.Top;
  Panel.Margins.Bottom := 16;
  Panel.Width := 900;
  Panel.Height := 230;
  Panel.Padding.Rect := TRectF.Create(16, 14, 16, 12);
  var Title := NewLabel;
  Title.Name := 'LabelGroup' + Name + 'Title';
  Title.Parent := Panel;
  Title.Align := TAlignLayout.Top;
  Title.Height := 36;
  Title.Margins.Bottom := 6;
  Title.StyledSettings := Title.StyledSettings - [TStyledSetting.Size];
  Title.TextSettings.Font.Size := 20;
  Title.Text := Caption;
end;

function TSettingsPageContext.CreateOption(const Name, Caption, Detail: string; Kind: TSettingsEditorKind): TControl;
begin
  if Owner.FindComponent('Panel' + Name) <> nil then
  begin
    var Existing := Owner.FindComponent('Panel' + Name) as TPanel;
    for var i := 0 to Existing.ChildrenCount - 1 do
      if Existing.Children[i] is TControl then
        if string(Existing.Children[i].Name).EndsWith('Editor') then
          Exit(TControl(Existing.Children[i]));
    var Editors := Owner.FindComponent('Layout' + Name + 'EditorContainer') as TLayout;
    if (Editors <> nil) and (Editors.ChildrenCount > 0) then
      Exit(TControl(Editors.Children[0]));
    raise EInvalidOperation.Create('Settings row has no editor: ' + Name);
  end;
  var Panel := TPanel.Create(Owner);
  Panel.Name := 'Panel' + Name;
  Panel.Parent := Store;
  Panel.StyleLookup := 'retromul_row';
  Panel.Padding.Rect := TRectF.Create(16, 12, 16, 12);
  Panel.Align := TAlignLayout.Top;
  Panel.Height := 72;
  Panel.Width := 868;
  Panel.Margins.Bottom := 6;
  var Text := TLayout.Create(Owner);
  Text.Name := 'Layout' + Name + 'Text';
  Text.Parent := Panel;
  Text.Align := TAlignLayout.Client;
  var Title := NewLabel;
  Title.Name := 'Label' + Name + 'Title';
  Title.Parent := Text;
  Title.Align := TAlignLayout.Top;
  Title.Height := 24;
  Title.StyledSettings := Title.StyledSettings - [TStyledSetting.Size];
  Title.TextSettings.Font.Size := 15;
  Title.Text := Caption;
  var Note := NewLabel;
  Note.Name := 'Label' + Name + 'Detail';
  Note.Parent := Text;
  Note.Align := TAlignLayout.Client;
  Note.Opacity := 0.72;
  Note.Text := Detail;
  case Kind of
    sekSwitch:
      Result := TSwitch.Create(Owner);
    sekCombo:
      Result := ComboClass.Create(Owner);
    sekNumber:
      Result := NumberClass.Create(Owner);
    sekPath:
      Result := TEdit.Create(Owner);
  else
    raise EArgumentOutOfRangeException.Create('Invalid settings editor kind');
  end;
  Result.Name := Copy(Result.ClassName, 2, MaxInt) + Name + 'Editor';
  var Editors := TLayout.Create(Owner);
  Editors.Name := 'Layout' + Name + 'EditorContainer';
  Editors.Parent := Panel;
  Editors.Align := TAlignLayout.Right;
  Editors.Width := 220;
  if Kind = sekSwitch then Editors.Width := 64;
  Editors.Margins.Rect := TRectF.Create(16, 8, 0, 8);
  Result.Parent := Editors;
  Result.Align := TAlignLayout.Client;
  if Kind = sekPath then
  begin
    var Browse := TEditButton.Create(Owner);
    Browse.Name := 'EditButton' + Name + 'Browse';
    Browse.Parent := Result;
    Browse.Width := 32;
    Browse.Text := '…';
    var Clear := TEditButton.Create(Owner);
    Clear.Name := 'EditButton' + Name + 'Clear';
    Clear.Parent := Result;
    Clear.Width := 32;
    Clear.Text := '×';
    Clear.Hint := Translate('Clear');
    Clear.TagObject := Result;
    Clear.OnClick := OnClearPath;
  end;
end;

constructor TSettingsPlatform.Create(const Info: TPlatformInfo);
begin
  inherited Create;
  PageId := Info.SettingsPageId;
  CoreId := Info.SettingsCoreId;
  Name := Info.Name;
  Brand := Info.Manufacturer;
  SearchTerms := Info.SearchTerms;
  PadLayout := Info.PadLayout;
  Ports := Info.Ports;
end;

procedure TSettingsPlatform.Initialize(Context: TSettingsPageContext);
begin
end;

procedure TSettingsPlatform.Video(Context: TSettingsPageContext);
begin
end;

procedure TSettingsPlatform.Audio(Context: TSettingsPageContext);
begin
end;

procedure TSettingsPlatform.Peripherals(Context: TSettingsPageContext);
begin
end;

procedure TSettingsPlatform.Expansion(Context: TSettingsPageContext);
begin
end;

procedure TSettingsPlatform.Validate(Draft: TMemIniFile);
begin
end;

function TSettingsPlatform.PlayerCount(Draft: TMemIniFile): Integer;
begin
  Result := Ports;
end;

function TSettingsPlatform.PortOptions(Port: Integer): TSettingsPortOptions;
begin
  Result.RowName := 'RowConnecteddevice26Port' + IntToStr(Port + 1);
  if Ports = 1 then
    Result.RowName := 'RowControllerPort' + IntToStr(Port + 1);
  Result.Labels := ['Gamepad', 'None'];
  Result.Values := ['pad', 'none'];
  Result.Default := 'pad';
end;

constructor TSettingsPlatformRegistry.Create;
begin
  inherited;
  FItems := TObjectList<TSettingsPlatform>.Create;
end;

destructor TSettingsPlatformRegistry.Destroy;
begin
  FItems.Free;
  inherited;
end;

procedure TSettingsPlatformRegistry.Add(platform: TSettingsPlatform);
begin
  try
    if (platform.PageId <= 0) or (platform.CoreId = '') or (platform.Brand = '') or
      (platform.Ports < 1) or (platform.Ports > 8) or (Find(platform.PageId) <> nil) then
      raise EArgumentException.Create('Invalid or duplicate settings platform: ' + platform.Name);
    for var Item in FItems do
      if SameText(Item.CoreId, platform.CoreId) then
        raise EArgumentException.Create('Duplicate settings core: ' + platform.CoreId);
    FItems.Add(platform);
  except
    platform.Free;
    raise;
  end;
end;

function TSettingsPlatformRegistry.Find(PageId: Integer): TSettingsPlatform;
begin
  Result := nil;
  for var Item in FItems do
    if Item.PageId = PageId then
      Exit(Item);
end;

function TSettingsPlatformRegistry.MaxPageId: Integer;
begin
  Result := 0;
  for var Item in FItems do
    if Item.PageId > Result then
      Result := Item.PageId;
end;

function TSettingsPlatformRegistry.Matching(const Query: string): TArray<TSettingsPlatform>;
begin
  var Matches := TList<TSettingsPlatform>.Create;
  try
    var Search := Query.Trim.ToLower;
    for var Item in FItems do
      if (Search = '') or (Translate(Item.Name) + ' ' + Item.Name + ' ' + Item.Brand + ' ' + Item.CoreId + ' ' +
        Item.SearchTerms).ToLower.Contains(Search) then
        Matches.Add(Item);
    Matches.Sort(TComparer<TSettingsPlatform>.Construct(
      function(const A, B: TSettingsPlatform): Integer
      begin
        Result := CompareText(A.Brand, B.Brand);
        if Result = 0 then
          Result := CompareText(A.Name, B.Name);
      end));
    Result := Matches.ToArray;
  finally
    Matches.Free;
  end;
end;

end.

