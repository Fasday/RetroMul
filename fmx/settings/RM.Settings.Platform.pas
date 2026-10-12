unit RM.Settings.platform;

interface

uses
  System.Classes, System.SysUtils, System.IniFiles, System.Generics.Collections,
  FMX.Types, FMX.Controls, FMX.Layouts, FMX.StdCtrls, FMX.Edit, FMX.ListBox,
  FMX.SpinBox, RM.Gamepad;

const
  SETTINGS_CATEGORY_GENERAL = 0;
  SETTINGS_CATEGORY_LIBRARY = 1;
  SETTINGS_CATEGORY_VIDEO_AUDIO = 2;
  SETTINGS_CATEGORY_CONTROLS = 3;
  SETTINGS_CATEGORY_PERIPHERALS = 4;

const
  SETTINGS_PAGE_MAIN = 0;
  SETTINGS_PAGE_GB = 1;
  SETTINGS_PAGE_GBC = 2;
  SETTINGS_PAGE_NES = 3;
  SETTINGS_PAGE_MD = 4;
  SETTINGS_PAGE_SNES = 5;
  SETTINGS_PAGE_NEOGEO = 6;
  SETTINGS_PAGE_GBA = 7;
  SETTINGS_PAGE_N64 = 8;
  SETTINGS_PAGE_SG1000 = 9;
  SETTINGS_PAGE_SC3000 = 10;
  SETTINGS_PAGE_SF7000 = 11;
  SETTINGS_PAGE_MULTIVISION = 12;
  SETTINGS_PAGE_SMS = 13;

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
    constructor Create(Id: Integer; const Core, Caption, Manufacturer, Aliases: string; Layout: TScreenGamepadLayout; PortCount: Integer = 2);
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
  Panel.SetBounds(0, 0, 900, 230);
  var Title := NewLabel;
  Title.Name := 'LabelGroup' + Name + 'Title';
  Title.Parent := Panel;
  Title.SetBounds(16, 14, 868, 36);
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
    raise EInvalidOperation.Create('Settings row has no editor: ' + Name);
  end;
  var Panel := TPanel.Create(Owner);
  Panel.Name := 'Panel' + Name;
  Panel.Parent := Store;
  Panel.StyleLookup := 'retromul_row';
  Panel.Padding.Rect := TRectF.Create(16, 12, 16, 12);
  Panel.SetBounds(16, 0, 868, 72);
  var Text := TLayout.Create(Owner);
  Text.Name := 'Layout' + Name + 'Text';
  Text.Parent := Panel;
  Text.SetBounds(16, 12, 550, 48);
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
  Result.Parent := Panel;
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

constructor TSettingsPlatform.Create(Id: Integer; const Core, Caption, Manufacturer, Aliases: string; Layout: TScreenGamepadLayout; PortCount: Integer);
begin
  inherited Create;
  PageId := Id;
  CoreId := Core;
  Name := Caption;
  Brand := Manufacturer;
  SearchTerms := Aliases;
  PadLayout := Layout;
  Ports := PortCount;
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

