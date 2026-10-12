unit RM.LibraryView;

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes,
  System.Generics.Collections, System.IniFiles, FMX.Types, FMX.Controls,
  FMX.Forms, FMX.Layouts, FMX.StdCtrls, FMX.Edit, FMX.Objects, Core.Storage,
  FMX.Controls.Presentation;

type
  TLibraryGame = class
  public
    FileInfo: TStorageFile;
    SystemId, Title, Cover, Description, Developer, Genre, Players: string;
    Favorite: Boolean;
    LastPlayed: TDateTime;
    function Key: string;
  end;

  TLibraryCard = class(TPanel)
    Cover: TImage;
    Title, platform: TLabel;
    Selection: TRectangle;
  end;

  TLibraryView = class(TFrame)
    PanelSidebar, PanelInspector: TPanel;
    LayoutCompactActions: TLayout;
    VertScrollBoxScroll: TVertScrollBox;
    LayoutGrid: TLayout;
    LabelTitle, LabelCount, LabelDetails, LabelDescription, LabelGameInfo, LabelSavesEmpty, LabelEmpty, LabelContinueTitle: TLabel;
    ImageCover: TImage;
    LayoutContinuePreview: TLayout;
    LabelContinueNoPreview: TLabel;
    LabelContinueCaption, LabelContinuePlatform, LabelContinueLastPlayed, LabelContinueSave: TLabel;
    PathPlayIcon: TPath;
    VertScrollBoxPlatforms: TVertScrollBox;
    ButtonSidebarMD: TButton;
    PathSidebarMDIcon: TPath;
    ButtonSidebarSNES: TButton;
    PathSidebarSNESIcon: TPath;
    ButtonSidebarNeoGeo: TButton;
    PathSidebarNeoGeoIcon: TPath;
    ButtonSidebarNeoGeoCD: TButton;
    ButtonSidebarN64: TButton;
    ButtonSidebarSG1000, ButtonSidebarSC3000: TButton;
    PathSidebarSG1000Icon, PathSidebarSC3000Icon: TPath;
    PathSidebarNeoGeoCDIcon: TPath;
    ButtonSidebarNES: TButton;
    PathSidebarNESIcon: TPath;
    ButtonSidebarGBA: TButton;
    PathSidebarGBAIcon: TPath;
    ButtonSidebarGBC: TButton;
    PathSidebarGBCIcon: TPath;
    ButtonSidebarGB: TButton;
    PathSidebarGBIcon: TPath;
    Path1: TPath;
  private
    FStorage: IStorage;
    FGames: TObjectList<TLibraryGame>;
    FState: TMemIniFile;
    FSelected, FRecent: TLibraryGame;
    FSystemFilter, FLetterFilter: string;
    FMode, FLimit: Integer;
    FSnapshotName: string;
    LayoutBody, LayoutHeader, LayoutFilters, FContinue: TLayout;
    FSearch: TEdit;
    FLetterScroll: TVertScrollBox;
    FLetterButtons: TList<TButton>;
    ButtonPlay, ButtonFavorite, ButtonMore, FGridButton, FListButton, FResume: TButton;
    FSaveButtons: array[0..2] of TButton;
    FSaveImages: array[0..2] of TImage;
    FPlatformButtons: TList<TButton>;
    FSidebarPlatformBorders: TList<TRectangle>;
    FNavButtons: array[0..2] of TButton;
    FNavIcons: array[0..2] of TPath;
    FGridIcon, FListIcon: TPath;
    FContinueCover: TRectangle;
    FContinueGamePreview: TImage;
    FCards: TList<TLibraryCard>;
    FListMode, FBuilding, FArranging, FLayouting, FShowPlatform, FShowLetters: Boolean;
    FCardWidth: Integer;
    FContinueCollapse, FContinueExtent: Single;
    FOnPlay, FOnSettings, FOnOpen: TNotifyEvent;
    procedure SaveState;
    function Matches(Game: TLibraryGame): Boolean;
    function GetSelected: TLibraryGame;
    function Snapshots(Game: TLibraryGame): TArray<TStorageSnapshot>;
    procedure LoadImage(Image: TImage; const Location: string);
    procedure BuildCards(AppendOnly: Boolean = False);
    procedure ArrangeCards;
    procedure UpdateLetterNavigation(const Games: TList<TLibraryGame>);
    procedure ArrangeLetterNavigation;
    procedure UpdateViewIcons;
    procedure GridResize(Sender: TObject);
    procedure BodyResize(Sender: TObject);
    {$IF Defined(ANDROID) or Defined(IOS)}
    procedure ScrollViewportChanged(Sender: TObject; const OldPosition, NewPosition: TPointF; const ContentSizeChanged: Boolean);
    {$ENDIF}
    procedure UpdateInspector;
    procedure SelectContinueGame;
    procedure UpdateContinue;
    procedure LoadContinueGamePreview;
    procedure ArrangeContinuePreview;
    procedure OpenClick(Sender: TObject);
    procedure SettingsClick(Sender: TObject);
    procedure FilterClick(Sender: TObject);
    procedure ModeClick(Sender: TObject);
    procedure SearchChange(Sender: TObject);
    procedure LetterClick(Sender: TObject);
    procedure CardClick(Sender: TObject);
    {$IF Defined(ANDROID) or Defined(IOS)}
    procedure CardTap(Sender: TObject; const Point: TPointF);
    {$ELSE}
    procedure CardDblClick(Sender: TObject);
    {$ENDIF}
    procedure PlayClick(Sender: TObject);
    procedure ResumeClick(Sender: TObject);
    procedure SaveClick(Sender: TObject);
    procedure FavoriteClick(Sender: TObject);
    procedure ViewClick(Sender: TObject);
    procedure MoreClick(Sender: TObject);
  protected
    procedure Resize; override;
  public
    constructor CreateLibrary(AOwner: TComponent; const Storage: IStorage);
    destructor Destroy; override;
    procedure Reload;
    procedure ApplyPreferences;
    procedure ApplyLanguage(const PreviousLanguage: string);
    procedure RecordSession(const FileName, SnapshotDirectory: string);
    procedure RefreshSnapshots;
    property Selected: TLibraryGame read GetSelected;
    property SnapshotName: string read FSnapshotName;
    property OnPlay: TNotifyEvent read FOnPlay write FOnPlay;
    property OnSettings: TNotifyEvent read FOnSettings write FOnSettings;
    property OnOpen: TNotifyEvent read FOnOpen write FOnOpen;
  end;

function LibrarySystemName(const Id: string): string;

implementation

{$R *.fmx}

uses
  System.IOUtils, System.Math, System.Math.Vectors, System.Hash,
  System.Character, System.Generics.Defaults, FMX.Graphics, FMX.BehaviorManager,
  SCRP.GameList, HGM.FMX.Image, Core.RomFormat, Core.SavePaths, RM.Icons,
  RM.SearchEdit, RM.Styles;

{$IF Defined(ANDROID) or Defined(IOS)}
type
  TLibraryScrollBox = class(TVertScrollBox)
  private
    FInputTransform: TMatrix;
    FStableInput: Boolean;
    function InputPoint(const X, Y: Single): TPointF;
  protected
    procedure AniMouseDown(const Touch: Boolean; const X, Y: Single); override;
    procedure AniMouseMove(const Touch: Boolean; const X, Y: Single); override;
    procedure AniMouseUp(const Touch: Boolean; const X, Y: Single); override;
  end;

function TLibraryScrollBox.InputPoint(const X, Y: Single): TPointF;
begin
  Result := TPointF.Create(X, Y);
  if FStableInput and (ContentLayout <> nil) then
    Result := ContentLayout.LocalToAbsolute(Result) * FInputTransform;
end;

procedure TLibraryScrollBox.AniMouseDown(const Touch: Boolean; const X, Y: Single);
begin
  if not AniCalculations.Down then
  begin
    FStableInput := Touch and (ContentLayout <> nil);
    if FStableInput then
      FInputTransform := ContentLayout.InvertAbsoluteMatrix;
  end;
  inherited;
end;

procedure TLibraryScrollBox.AniMouseMove(const Touch: Boolean; const X, Y: Single);
begin
  // FMX supplies viewport-local points. Keep the gesture's initial coordinates
  // while collapsing the header moves and enlarges the viewport under the finger.
  var P := InputPoint(X, Y);
  inherited AniMouseMove(Touch, P.X, P.Y);
end;

procedure TLibraryScrollBox.AniMouseUp(const Touch: Boolean; const X, Y: Single);
begin
  var P := InputPoint(X, Y);
  inherited AniMouseUp(Touch, P.X, P.Y);
end;
{$ENDIF}

type
  TLibraryPlatformInfo = record
    Id, Name, FilterButton, SidebarButton: string;
  end;

const
  LibraryPlatforms: array[0..11] of TLibraryPlatformInfo = (
    (Id: ''; Name: 'All'; FilterButton: 'ButtonFilter0'; SidebarButton: ''),
    (Id: ROM_SYSTEM_NES; Name: 'NES'; FilterButton: 'ButtonFilter1'; SidebarButton: 'ButtonSidebarNES'),
    (Id: ROM_SYSTEM_SNES; Name: 'SNES'; FilterButton: 'ButtonFilter2'; SidebarButton: 'ButtonSidebarSNES'),
    (Id: ROM_SYSTEM_GB; Name: 'GB'; FilterButton: 'ButtonFilter3'; SidebarButton: 'ButtonSidebarGB'),
    (Id: ROM_SYSTEM_GBC; Name: 'GBC'; FilterButton: 'ButtonFilter4'; SidebarButton: 'ButtonSidebarGBC'),
    (Id: ROM_SYSTEM_MD; Name: 'Mega Drive'; FilterButton: 'ButtonFilter5'; SidebarButton: 'ButtonSidebarMD'),
    (Id: ROM_SYSTEM_NEOGEO; Name: 'Neo Geo'; FilterButton: 'ButtonFilter6'; SidebarButton: 'ButtonSidebarNeoGeo'),
    (Id: ROM_SYSTEM_GBA; Name: 'GBA'; FilterButton: 'ButtonFilter7'; SidebarButton: 'ButtonSidebarGBA'),
    (Id: ROM_SYSTEM_NEOGEOCD; Name: 'Neo Geo CD'; FilterButton: 'ButtonFilter8'; SidebarButton: 'ButtonSidebarNeoGeoCD'),
    (Id: ROM_SYSTEM_N64; Name: 'Nintendo 64'; FilterButton: 'ButtonFilter9'; SidebarButton: 'ButtonSidebarN64'),
    (Id: ROM_SYSTEM_SG1000; Name: 'SG-1000'; FilterButton: 'ButtonFilterSG1000'; SidebarButton: 'ButtonSidebarSG1000'),
    (Id: ROM_SYSTEM_SC3000; Name: 'SC-3000'; FilterButton: 'ButtonFilterSC3000'; SidebarButton: 'ButtonSidebarSC3000'));

function LibrarySystemName(const Id: string): string;
begin
  Result := Id;
  for var platform in LibraryPlatforms do
    if Id = platform.Id then
      Exit(Translate(platform.Name));
end;

function LibraryDate(const Value: TDateTime): string;
begin
  if Trunc(Value) = Trunc(Date) then
    Result := Translate('today, ') + FormatDateTime('hh:nn', Value)
  else if Trunc(Value) = Trunc(Date) - 1 then
    Result := Translate('yesterday, ') + FormatDateTime('hh:nn', Value)
  else
    Result := FormatDateTime('dd.mm.yyyy hh:nn', Value);
end;

function TLibraryGame.Key: string;
begin
  Result := THashSHA2.GetHashString(FileInfo.Location);
end;

function LibraryTitleLetter(const Title: string): string;
begin
  var Value := Title.Trim;
  Result := '#';
  if (Value <> '') and Value.Chars[0].IsLetter then
    Result := Value.Substring(0, 1).ToUpper;
end;

function TextLabel(Owner: TComponent; Parent: TFmxObject; const Text: string; Size: Single = 14): TLabel;
begin
  Result := TLabel.Create(Owner);
  Result.Parent := Parent;
  Result.Text := Text;
  Result.StyledSettings := [];
  Result.TextSettings.Font.Family := 'Segoe UI';
  Result.TextSettings.Font.Size := Size;
  Result.TextSettings.FontColor := $FFE8ECF1;
  Result.TextSettings.Trimming := TTextTrimming.Character;
  Result.TextSettings.WordWrap := False;
  Result.HitTest := False;
end;

function ActionButton(Owner: TComponent; Parent: TFmxObject; const Text: string; Click: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Owner);
  Result.Parent := Parent;
  Result.Text := Translate(Text);
  Result.StyledSettings := Result.StyledSettings - [TStyledSetting.Other];
  Result.TextSettings.Trimming := TTextTrimming.Character;
  Result.TextSettings.WordWrap := False;
  Result.Height := 42;
  Result.OnClick := Click;
end;

constructor TLibraryView.CreateLibrary(AOwner: TComponent; const Storage: IStorage);
begin
  FBuilding := True;
  inherited Create(AOwner);
  FStorage := Storage;
  FGames := TObjectList<TLibraryGame>.Create;
  FCards := TList<TLibraryCard>.Create;
  FLetterButtons := TList<TButton>.Create;
  FPlatformButtons := TList<TButton>.Create;
  FSidebarPlatformBorders := TList<TRectangle>.Create;
  FState := FStorage.ReadConfig(FStorage.ConfigFile('library'));
  FLimit := 48;
  PanelSidebar := FindComponent('PanelSidebar') as TPanel;
  PanelInspector := FindComponent('PanelInspector') as TPanel;
  LayoutBody := FindComponent('LayoutBody') as TLayout;
  LayoutHeader := FindComponent('LayoutHeader') as TLayout;
  LayoutFilters := FindComponent('LayoutFilters') as TLayout;
  FContinue := FindComponent('LayoutContinue') as TLayout;
  LayoutCompactActions := FindComponent('LayoutCompactActions') as TLayout;
  VertScrollBoxScroll := FindComponent('VertScrollBoxScroll') as TVertScrollBox;
  LayoutGrid := FindComponent('LayoutGrid') as TLayout;

  FLetterScroll := TVertScrollBox.Create(Self);
  FLetterScroll.Name := 'VertScrollBoxLetters';
  FLetterScroll.Parent := LayoutBody;
  FLetterScroll.ShowScrollBars := False;
  FLetterScroll.ScrollAnimation := TBehaviorBoolean.True;

  var AllLetters := ActionButton(Self, FLetterScroll, '*', LetterClick);
  AllLetters.Name := 'ButtonAllLetters';
  AllLetters.TagString := '';
  AllLetters.Hint := Translate('All');
  AllLetters.ShowHint := True;
  FLetterButtons.Add(AllLetters);
  {$IF Defined(ANDROID) or Defined(IOS)}
  // Retain the standard control in the designer; use stable gesture coordinates at runtime.
  var Scroll := TLibraryScrollBox.Create(Self);
  Scroll.SetBounds(VertScrollBoxScroll.Position.X, VertScrollBoxScroll.Position.Y, VertScrollBoxScroll.Width, VertScrollBoxScroll.Height);
  Scroll.ScrollAnimation := VertScrollBoxScroll.ScrollAnimation;
  Scroll.StyleLookup := VertScrollBoxScroll.StyleLookup;
  Scroll.Parent := VertScrollBoxScroll.Parent;
  Scroll.TabOrder := VertScrollBoxScroll.TabOrder;

  LayoutGrid.Parent := Scroll;
  VertScrollBoxScroll.Free;
  VertScrollBoxScroll := Scroll;
  VertScrollBoxScroll.Name := 'LibraryScrollBoxScroll';
  {$ENDIF}
  LabelTitle := FindComponent('LabelTitle') as TLabel;
  LabelCount := FindComponent('LabelCount') as TLabel;
  LabelDetails := FindComponent('LabelDetails') as TLabel;
  LabelDescription := FindComponent('LabelDescription') as TLabel;
  LabelGameInfo := FindComponent('LabelGameInfo') as TLabel;
  LabelSavesEmpty := FindComponent('LabelSavesEmpty') as TLabel;
  LabelEmpty := FindComponent('LabelEmpty') as TLabel;
  LabelContinueTitle := FindComponent('LabelContinueTitle') as TLabel;
  ImageCover := FindComponent('ImageCover') as TImage;
  ButtonPlay := FindComponent('ButtonPlay') as TButton;
  ButtonFavorite := FindComponent('ButtonFavorite') as TButton;
  ButtonMore := FindComponent('ButtonMore') as TButton;
  FGridButton := FindComponent('ButtonGridView') as TButton;
  FListButton := FindComponent('ButtonListView') as TButton;
  FGridIcon := FindComponent('PathGridViewIcon') as FMX.Objects.TPath;
  FListIcon := FindComponent('PathListViewIcon') as FMX.Objects.TPath;
  FResume := FindComponent('ButtonResume') as TButton;
  LayoutContinuePreview := FindComponent('LayoutContinuePreview') as TLayout;
  FContinueCover := FindComponent('RectangleContinueCover') as TRectangle;
  FContinueCover.Fill.Bitmap.WrapMode := TWrapMode.TileStretch;
  FContinueGamePreview := FindComponent('ImageContinueGamePreview') as TImage;
  LabelContinueNoPreview := FindComponent('LabelContinueNoPreview') as TLabel;
  LabelContinueCaption := FindComponent('LabelContinueCaption') as TLabel;
  LabelContinuePlatform := FindComponent('LabelContinuePlatform') as TLabel;
  LabelContinueLastPlayed := FindComponent('LabelContinueLastPlayed') as TLabel;
  LabelContinueSave := FindComponent('LabelContinueSave') as TLabel;

  for var i := 0 to 2 do
  begin
    FNavButtons[i] := FindComponent('ButtonNav' + IntToStr(i)) as TButton;
    FNavButtons[i].OnClick := ModeClick;
    FNavButtons[i].TextSettings.HorzAlign := TTextAlign.Leading;
    FNavButtons[i].StylesData['text.Margins.Left'] := 48;
    FNavIcons[i] := FindComponent('PathNavIcon' + IntToStr(i)) as FMX.Objects.TPath;
    FSaveImages[i] := FindComponent('ImageSavePreview' + IntToStr(i)) as TImage;
    FSaveButtons[i] := FindComponent('ButtonSaveButton' + IntToStr(i)) as TButton;
    FSaveButtons[i].OnClick := SaveClick;
  end;

  // Bind existing frame components by name and system ID, never by an array index or numeric Tag.
  for var platform in LibraryPlatforms do
    if FindComponent(platform.FilterButton) is TButton then
    begin
      var Button := FindComponent(platform.FilterButton) as TButton;
      Button.TagString := platform.Id;
      Button.OnClick := FilterClick;
      FPlatformButtons.Add(Button);
    end;

  for var platform in LibraryPlatforms do
    if FindComponent(platform.SidebarButton) is TButton then
    begin
      var Button := FindComponent(platform.SidebarButton) as TButton;
      Button.TagString := platform.Id;
      Button.OnClick := FilterClick;
      Button.TextSettings.HorzAlign := TTextAlign.Leading;
      Button.StylesData['text.Margins.Left'] := 48;

      var Border := TRectangle.Create(Button);
      Border.TagString := platform.Id;
      FSidebarPlatformBorders.Add(Border);
      Border.Parent := Button;
      Border.Align := TAlignLayout.Contents;
      Border.Fill.Kind := TBrushKind.None;
      Border.Stroke.Color := $FFFFB344;
      Border.Stroke.Thickness := 2;
      Border.XRadius := 6;
      Border.YRadius := 6;
      Border.HitTest := False;
      Border.Visible := False;
    end;

  for var Name in ['ButtonOpenRom', 'ButtonSettings'] do
  begin
    var Button := FindComponent(Name) as TButton;
    Button.TextSettings.HorzAlign := TTextAlign.Leading;
    Button.StylesData['text.Margins.Left'] := 48;
  end;

  var SearchHost := FindComponent('LayoutSearchHost') as TLayout;
  FSearch := TSearchEdit.Create(Self);
  FSearch.Name := 'SearchEditSearch';
  FSearch.Parent := SearchHost;
  FSearch.Align := TAlignLayout.Client;
  FSearch.TextPrompt := Translate('Search games');
  FSearch.OnChangeTracking := SearchChange;

  (FindComponent('ButtonOpenRom') as TButton).OnClick := OpenClick;
  (FindComponent('ButtonSettings') as TButton).OnClick := SettingsClick;
  (FindComponent('ButtonCompactOpen') as TButton).OnClick := OpenClick;
  (FindComponent('ButtonCompactSettings') as TButton).OnClick := SettingsClick;
  FormStyles.RelocalizeUI(Self, 'en');
  ButtonPlay.OnClick := PlayClick;
  ButtonFavorite.OnClick := FavoriteClick;
  FResume.OnClick := ResumeClick;
  FListButton.OnClick := ViewClick;
  FGridButton.OnClick := ViewClick;
  ButtonMore.OnClick := MoreClick;
  LayoutBody.OnResize := BodyResize;
  LayoutGrid.OnResize := GridResize;
  {$IF Defined(ANDROID) or Defined(IOS)}
  FContinue.ClipChildren := True;
  VertScrollBoxScroll.OnViewportPositionChange := ScrollViewportChanged;
  {$ENDIF}
  FBuilding := False;
  ApplyPreferences;
  Reload;
end;

destructor TLibraryView.Destroy;
begin
  FBuilding := True;
  FCards.Free;
  FLetterButtons.Free;
  FPlatformButtons.Free;
  FSidebarPlatformBorders.Free;
  FGames.Free;
  FState.Free;
  inherited;
end;

procedure TLibraryView.Reload;
begin
  FBuilding := True;
  FSelected := nil;
  FRecent := nil;
  // Cards reference games. Release them before replacing the catalog.
  for var Card in FCards do
    Card.Free;
  FCards.Clear;
  FGames.Clear;
  try
    for var platform in LibraryPlatforms do
    begin
      if platform.Id = '' then
        Continue;
      var Folder := TPath.Combine(FStorage.RomFolder, RomSystemFolder(RomSystemFromId(platform.Id)));
      if (platform.Id = ROM_SYSTEM_SC3000) and not FStorage.RomFolder.StartsWith('content://', True) and
        not FStorage.FolderExists(Folder) then
        Folder := TPath.Combine(FStorage.RomFolder, ROM_SYSTEM_SG1000);
      var Metadata := TGameList.Create;
      var Lookup := TDictionary<string, TGame>.Create;
      try
        var XML := TPath.Combine(Folder, 'gamelist.xml');
        if not FStorage.RomFolder.StartsWith('content://') and FStorage.Exists(XML) then
        begin
          var Stream := FStorage.OpenRead(XML);
          try
            try
              Metadata.LoadFromStream(Stream);
            except
              Metadata.Clear;
            end;
          finally
            Stream.Free;
          end;
          for var Game in Metadata.Games do
            Lookup.AddOrSetValue(LowerCase(ExpandFileName(Game.GetPhysicalPath(Folder, Game.Path))), Game);
        end;
        for var FileInfo in FStorage.Roms(platform.Id) do
        begin
          var Item := TLibraryGame.Create;
          FGames.Add(Item);
          Item.FileInfo := FileInfo;
          Item.SystemId := platform.Id;
          Item.Title := TPath.GetFileNameWithoutExtension(FileInfo.Name);
          var Entry: TGame;
          if Lookup.TryGetValue(LowerCase(ExpandFileName(FileInfo.Location)), Entry) then
          begin
            if Entry.Name <> '' then
              Item.Title := Entry.Name;
            Item.Cover := Entry.GetPhysicalPath(Folder, Entry.Image);
            if Item.Cover.IsEmpty then
              Item.Cover := Entry.GetPhysicalPath(Folder, Entry.Box);
            Item.Description := Entry.Desc;
            Item.Developer := Entry.Developer;
            Item.Genre := Entry.Genre;
            Item.Players := Entry.Players;
            Item.Favorite := Entry.Favorite;
          end;
          Item.Favorite := FState.ReadBool('Favorites', Item.Key, Item.Favorite);
          Item.LastPlayed := FState.ReadFloat('Recent', Item.Key, 0);
        end;
      finally
        Lookup.Free;
        Metadata.Free;
      end;
    end;
    FGames.Sort(TComparer<TLibraryGame>.Construct(
      function(const A, B: TLibraryGame): Integer
      begin
        Result := CompareText(A.Title, B.Title);
      end));
  finally
    FBuilding := False;
  end;
  UpdateContinue;
  BuildCards;
end;

procedure TLibraryView.ApplyPreferences;
begin
  var Ini := FStorage.ReadConfig(FStorage.ConfigFile('config'));
  try
    FListMode := Ini.ReadString('Library', 'View', 'grid') = 'list';
    FShowPlatform := Ini.ReadBool('Library', 'ShowPlatform', True);
    FShowLetters := Ini.ReadBool('Library', 'ShowLetters', False);
    if not FShowLetters then
      FLetterFilter := '';
    FCardWidth := EnsureRange(Ini.ReadInteger('Library', 'CardWidth', 170), 140, 240);
  finally
    Ini.Free;
  end;
  UpdateViewIcons;
  if FCards <> nil then
    BuildCards;
end;

procedure TLibraryView.ApplyLanguage(const PreviousLanguage: string);
begin
  FormStyles.RelocalizeUI(Self, PreviousLanguage);
  // Rebuild data captions from the game records so titles and metadata stay intact.
  BuildCards;
  UpdateInspector;
  UpdateContinue;
end;

procedure TLibraryView.RecordSession(const FileName, SnapshotDirectory: string);
begin
  for var Game in FGames do
    if SameText(Game.FileInfo.Location, FileName) then
    begin
      Game.LastPlayed := Now;
      FState.WriteFloat('Recent', Game.Key, Game.LastPlayed);
      if SnapshotDirectory <> '' then
        FState.WriteString('Snapshots', Game.Key, SnapshotDirectory);
      SaveState;
      RefreshSnapshots;
      Break;
    end;
end;

procedure TLibraryView.SaveState;
begin
  FStorage.WriteConfig(FState);
end;

function TLibraryView.Matches(Game: TLibraryGame): Boolean;
begin
  Result := ((FSystemFilter = '') or (Game.SystemId = FSystemFilter)) and
    ((FMode <> 1) or (Game.LastPlayed > 0)) and ((FMode <> 2) or Game.Favorite) and
    ((FSearch.Text = '') or Game.Title.ToLower.Contains(FSearch.Text.ToLower));
end;

function TLibraryView.GetSelected: TLibraryGame;
begin
  Result := FSelected;
end;

function TLibraryView.Snapshots(Game: TLibraryGame): TArray<TStorageSnapshot>;
begin
  Result := nil;
  if Game = nil then
    Exit;

  var Directory := FState.ReadString('Snapshots', Game.Key, '');
  if Directory = '' then
    Exit;

  var Items := TList<TStorageSnapshot>.Create;
  try
    for var Location in FStorage.Files(Directory) do
      if SameText(ExtractFileExt(Location), SNAPSHOT_EXTENSION) then
      begin
        var Item := Default(TStorageSnapshot);
        Item.Name := ChangeFileExt(ExtractFileName(Location), '');
        Item.Location := Location;
        Item.Modified := FStorage.ModifiedTime(Location);
        Item.PreviewLocation := ChangeFileExt(Location, '.png');
        if not FStorage.Exists(Item.PreviewLocation) then
          Item.PreviewLocation := ChangeFileExt(Location, '.bmp');
        Items.Add(Item);
      end;
    Items.Sort(TComparer<TStorageSnapshot>.Construct(
      function(const A, B: TStorageSnapshot): Integer
      begin
        Result := CompareValue(B.Modified, A.Modified);
        if Result = 0 then
          Result := CompareText(A.Location, B.Location);
      end));
    Result := Items.ToArray;
  finally
    Items.Free;
  end;
end;

procedure TLibraryView.LoadImage(Image: TImage; const Location: string);
begin
  Image.Bitmap.RemoveCallback(Image);
  Image.Bitmap := nil;
  try
    if (Location <> '') and FStorage.Exists(Location) then
      Image.Bitmap.LoadFromFileAsync(Image, Location, 320, 400, nil, FStorage);
  except
    Image.Bitmap := nil;
  end;
end;

procedure TLibraryView.RefreshSnapshots;
begin
  UpdateInspector;
  UpdateContinue;
  Resize;
end;

procedure TLibraryView.BuildCards(AppendOnly: Boolean);
begin
  if FBuilding or (LayoutGrid = nil) then
    Exit;

  var PreviousSelected := FSelected;
  FBuilding := True;
  try
    var MatchesList := TList<TLibraryGame>.Create;
    try
      for var Game in FGames do
        if Matches(Game) then
          MatchesList.Add(Game);

      // Index the current search and platform before filtering by initial.
      if FShowLetters then
        UpdateLetterNavigation(MatchesList)
      else
        FLetterScroll.Visible := False;
      if FLetterFilter <> '' then
        for var i := MatchesList.Count - 1 downto 0 do
          if LibraryTitleLetter(MatchesList[i].Title) <> FLetterFilter then
            MatchesList.Delete(i);
      if FMode = 1 then
        MatchesList.Sort(TComparer<TLibraryGame>.Construct(
          function(const A, B: TLibraryGame): Integer
          begin
            Result := CompareValue(B.LastPlayed, A.LastPlayed);
          end));

      // Append only when the existing cards still match the current prefix.
      // A recorded session can change the order of the Recent list.
      if AppendOnly then
      begin
        AppendOnly := FCards.Count <= Min(FLimit, MatchesList.Count);
        if AppendOnly then
          for var i := 0 to FCards.Count - 1 do
            if FCards[i].TagObject <> MatchesList[i] then
            begin
              AppendOnly := False;
              Break;
            end;
      end;

      if not AppendOnly then
      begin
        for var Card in FCards do
          Card.Free;
        FCards.Clear;
      end;

      var SelectedVisible := MatchesList.Contains(FSelected);
      if not SelectedVisible then
      begin
        FSelected := nil;
        if MatchesList.Count > 0 then
          FSelected := MatchesList[0];
      end;

      LabelCount.Text := IntToStr(MatchesList.Count) + Translate(' games');
      for var i := FCards.Count to Min(FLimit, MatchesList.Count) - 1 do
      begin
        var Game := MatchesList[i];
        var Card := TLibraryCard.Create(LayoutGrid);
        Card.Parent := LayoutGrid;
        Card.StyleLookup := 'retromul_card';
        Card.TagObject := Game;
        {$IF Defined(ANDROID) or Defined(IOS)}
        Card.OnTap := CardTap;
        {$ELSE}
        Card.OnClick := CardClick;
        Card.OnDblClick := CardDblClick;
        {$ENDIF}
        FCards.Add(Card);
        var Cover := TImage.Create(Card);
        Card.Cover := Cover;
        Cover.Parent := Card;
        Cover.HitTest := False;
        Cover.WrapMode := TImageWrapMode.Fit;
        LoadImage(Cover, Game.Cover);
        var Title := TextLabel(Card, Card, Game.Title, 14);
        Card.Title := Title;
        Title.TextSettings.Font.Style := [TFontStyle.fsBold];
        var platform := TextLabel(Card, Card, LibrarySystemName(Game.SystemId), 12);
        Card.platform := platform;
        platform.Opacity := 0.6;
        platform.Visible := FShowPlatform;
        var SelectedBorder := TRectangle.Create(Card);
        Card.Selection := SelectedBorder;
        SelectedBorder.Parent := Card;
        SelectedBorder.Align := TAlignLayout.Contents;
        SelectedBorder.Fill.Kind := TBrushKind.None;
        SelectedBorder.Stroke.Color := $FFFFB344;
        SelectedBorder.Stroke.Thickness := 2;
        SelectedBorder.XRadius := 10;
        SelectedBorder.YRadius := 10;
        SelectedBorder.HitTest := False;
        SelectedBorder.Visible := FSelected = Game;
      end;
      ButtonMore.Visible := MatchesList.Count > FLimit;
      LabelEmpty.Visible := MatchesList.Count = 0;
      if FGames.Count = 0 then
        LabelEmpty.Text := Translate('Your library is empty') + sLineBreak + Translate('Open settings and choose a ROM folder.')
      else
        LabelEmpty.Text := Translate('No games found') + sLineBreak + Translate('Change your search or filter.');
    finally
      MatchesList.Free;
    end;
  finally
    FBuilding := False;
  end;

  if AppendOnly then
  begin
    ArrangeCards;
    if FSelected <> PreviousSelected then
      UpdateInspector;
    Exit;
  end;

  for var i := 0 to 2 do
  begin
    if i = FMode then
      FNavButtons[i].StyleLookup := 'retromul_nav_active'
    else
      FNavButtons[i].StyleLookup := 'buttonstyle_subtle';
    FNavButtons[i].StylesData['text.Margins.Left'] := 48;
    if i = FMode then
      FNavIcons[i].Stroke.Color := $FFFFB344
    else
      FNavIcons[i].Stroke.Color := $FFB9C2CC;
  end;

  for var Button in FPlatformButtons do
    if FSystemFilter = Button.TagString then
      Button.StyleLookup := 'buttonstyle_accent'
    else
      Button.StyleLookup := 'buttonstyle';

  for var Border in FSidebarPlatformBorders do
    Border.Visible := FSystemFilter = Border.TagString;

  Resize;
  UpdateInspector;
end;

procedure TLibraryView.UpdateLetterNavigation(const Games: TList<TLibraryGame>);
begin
  var Letters := TStringList.Create;
  try
    Letters.Sorted := True;
    Letters.Duplicates := dupIgnore;
    for var Game in Games do
      Letters.Add(LibraryTitleLetter(Game.Title));
    for var Letter in Letters do
    begin
      var Found := False;
      for var Button in FLetterButtons do
        if Button.TagString = Letter then
        begin
          Found := True;
          Break;
        end;

      if not Found then
      begin
        var Button := ActionButton(Self, FLetterScroll, Letter, LetterClick);
        Button.TagString := Letter;
        Button.StyledSettings := [];
        Button.TextSettings.Font.Size := 13;
        Button.TextSettings.Font.Style := [TFontStyle.fsBold];
        FLetterButtons.Add(Button);
      end;
    end;

    FLetterButtons.Sort(TComparer<TButton>.Construct(
      function(const A, B: TButton): Integer
      begin
        Result := CompareText(A.TagString, B.TagString);
      end));

    for var Button in FLetterButtons do
    begin
      Button.Visible := (Button.TagString = '') or (Letters.IndexOf(Button.TagString) >= 0);
      Button.StyledSettings := Button.StyledSettings - [TStyledSetting.FontColor];
      if Button.TagString = FLetterFilter then
      begin
        Button.StyleLookup := 'buttonstyle_accent';
        Button.TextSettings.FontColor := $FF1B2025;
      end
      else
      begin
        Button.StyleLookup := 'buttonstyle_subtle';
        Button.TextSettings.FontColor := $FFE8ECF1;
      end;
    end;
    FLetterButtons[0].Hint := Translate('All');
    FLetterScroll.Visible := Games.Count > 0;
  finally
    Letters.Free;
  end;
end;

procedure TLibraryView.ArrangeLetterNavigation;
begin
  var Count := 0;
  for var Button in FLetterButtons do
    if Button.Visible then
      Inc(Count);

  var H := EnsureRange(Floor(FLetterScroll.Height / Max(1, Count)), 24, 36);
  var Y: Single := 0;
  for var Button in FLetterButtons do
    if Button.Visible then
    begin
      Button.SetBounds(0, Y, FLetterScroll.Width, H - 2);
      Y := Y + H;
    end;
end;

procedure TLibraryView.ArrangeCards;
begin
  if FBuilding or FArranging or (LayoutGrid = nil) then
    Exit;

  FArranging := True;
  try
    var Available := Max(140, VertScrollBoxScroll.Width - 16);
    LayoutGrid.Width := Available;
    var Columns := Max(1, Floor((Available + 14) / (FCardWidth + 14)));
    {$IF Defined(ANDROID) or Defined(IOS)}
    // Mobile grid cards must fit at least two across, even at the largest setting.
    Columns := Max(2, Columns);
    {$ENDIF}
    if FListMode then
      Columns := 1;
    var W := (Available - (Columns - 1) * 14) / Columns;
    var H := W * 1.1 + 66;
    if FListMode then
      H := 92;

    for var i := 0 to FCards.Count - 1 do
    begin
      var Card := FCards[i];
      Card.SetBounds((i mod Columns) * (W + 14), (i div Columns) * (H + 14), W, H);
      var Image := Card.Cover;
      var Title := Card.Title;
      var platform := Card.platform;
      if FListMode then
      begin
        Image.SetBounds(8, 8, 60, 76);
        Title.SetBounds(84, 14, W - 104, 32);
        platform.SetBounds(84, 49, W - 104, 24);
      end
      else
      begin
        Image.SetBounds(8, 8, W - 16, H - 74);
        Title.SetBounds(12, H - 60, W - 24, 28);
        platform.SetBounds(12, H - 32, W - 24, 22);
      end;
    end;
    var Y := Ceil(FCards.Count / Columns) * (H + 14);
    ButtonMore.SetBounds(Max(0, (Available - 180) / 2), Y + 4, 180, 42);
    LabelEmpty.SetBounds(16, 28, Available - 32, 132);
    LayoutGrid.Height := Max(180, Y + IfThen(ButtonMore.Visible, 64, 0));
  finally
    FArranging := False;
  end;
end;

procedure TLibraryView.Resize;
begin
  if (csLoading in ComponentState) or FBuilding or FLayouting or (LayoutBody = nil) then
    Exit;

  FLayouting := True;
  try
    inherited;
    PanelSidebar.Visible := Width >= 900;
    LayoutCompactActions.Visible := not PanelSidebar.Visible;
    PanelInspector.Visible := Width >= 1120;
    var ContentWidth := Max(140, LayoutBody.Width - 48);
    var Y: Single := 22;
    LayoutHeader.SetBounds(24, Y, ContentWidth, 92);
    Y := Y + 96;
    if LayoutCompactActions.Visible then
    begin
      LayoutCompactActions.SetBounds(24, Y, ContentWidth, 48);
      Y := Y + 48;
    end;
    LayoutContinuePreview.Visible := ContentWidth >= 720;
    FContinueCollapse := 0;
    FContinueExtent := 0;
    if FContinue.Visible then
    begin
      var Stacked := ContentWidth < 520;
      var Height := IfThen(Stacked, 208, 154);
      FContinueExtent := Height + 16;
      {$IF Defined(ANDROID) or Defined(IOS)}
      // Reserve the wrapped filters, count, and a usable list viewport on short screens.
      if LayoutBody.Height - Y - FContinueExtent < 88 + 28 + 18 + 92 then
        FContinueExtent := 0;
      FContinueCollapse := EnsureRange(VertScrollBoxScroll.ViewportPosition.Y, 0, FContinueExtent);
      if FContinueExtent = 0 then
        FContinue.Opacity := 0
      else
        FContinue.Opacity := 1 - FContinueCollapse / FContinueExtent;
      FContinue.Enabled := (FContinueExtent > 0) and (FContinueCollapse < Height);
      {$ENDIF}
      FContinue.SetBounds(24, Y, ContentWidth, Max(0, Min(Height, FContinueExtent - FContinueCollapse)));
      var TextX: Single := 20;
      if LayoutContinuePreview.Visible then
      begin
        var PreviewWidth: Single := 176;
        LayoutContinuePreview.SetBounds(12, 12, PreviewWidth, Height - 24);
        ArrangeContinuePreview;
        TextX := 12 + LayoutContinuePreview.Width + 24;
      end;
      var ButtonWidth := Min(144, ContentWidth - 40);
      var TextWidth := ContentWidth - TextX - 20;
      if not Stacked then
        TextWidth := TextWidth - ButtonWidth - 20;
      LabelContinueCaption.SetBounds(TextX, 16, TextWidth, 18);
      LabelContinueTitle.SetBounds(TextX, 38, TextWidth, 32);
      LabelContinuePlatform.SetBounds(TextX, 74, TextWidth, 18);
      LabelContinueLastPlayed.SetBounds(TextX, 94, TextWidth, 18);
      LabelContinueSave.SetBounds(TextX, 114, TextWidth, 18);
      FResume.SetBounds(ContentWidth - ButtonWidth - 18, Height - 58, ButtonWidth, 40);
      Y := Y + FContinueExtent - FContinueCollapse;
    end;
    LayoutFilters.SetBounds(24, Y, ContentWidth, 46);
    var X: Single := 0;
    var FilterY: Single := 4;
    for var B in FPlatformButtons do
    begin
      var W: Single := 56;
      if Length(B.Text) > 6 then
        W := 102;
      if X + W > ContentWidth then
      begin
        X := 0;
        FilterY := FilterY + 41;
      end;
      B.Visible := True;
      B.SetBounds(X, FilterY, W, 34);
      X := X + W + 7;
    end;
    LayoutFilters.Height := FilterY + 42;
    Y := Y + LayoutFilters.Height;
    LabelCount.SetBounds(24, Y, ContentWidth, 28);
    Y := Y + 28;
    // Add the consumed header distance to the content before growing its viewport.
    // This keeps the scroll range and card motion continuous during the collapse.
    var LetterWidth: Single := 0;
    if FLetterScroll.Visible then
      LetterWidth := 44;
    VertScrollBoxScroll.Width := Max(96, ContentWidth - LetterWidth);
    LayoutGrid.Position.Y := FContinueCollapse;
    ArrangeCards;
    VertScrollBoxScroll.SetBounds(24 + LetterWidth, Y, VertScrollBoxScroll.Width, Max(0, LayoutBody.Height - Y - 18));
    FLetterScroll.SetBounds(24, Y, 36, VertScrollBoxScroll.Height);
    ArrangeLetterNavigation;
  finally
    FLayouting := False;
  end;
end;

procedure TLibraryView.GridResize(Sender: TObject);
begin
  ArrangeCards;
end;

procedure TLibraryView.BodyResize(Sender: TObject);
begin
  Resize;
end;

{$IF Defined(ANDROID) or Defined(IOS)}
procedure TLibraryView.ScrollViewportChanged(Sender: TObject; const OldPosition, NewPosition: TPointF; const ContentSizeChanged: Boolean);
begin
  if FBuilding or FLayouting or not FContinue.Visible then
    Exit;
  var Collapse := EnsureRange(NewPosition.Y, 0, FContinueExtent);
  if SameValue(Collapse, FContinueCollapse, 0.1) then
    Exit;
  FLayouting := True;
  try
    FContinueCollapse := Collapse;
    var Height := FContinueExtent - 16;
    FContinue.Height := Max(0, Min(Height, FContinueExtent - Collapse));
    FContinue.Opacity := 1 - Collapse / FContinueExtent;
    FContinue.Enabled := Collapse < Height;
    LayoutFilters.Position.Y := FContinue.Position.Y + FContinueExtent - Collapse;
    LabelCount.Position.Y := LayoutFilters.Position.Y + LayoutFilters.Height;
    // Move the grid as one unit, keeping every card and its content size unchanged.
    LayoutGrid.Position.Y := Collapse;
    var Y := LabelCount.Position.Y + LabelCount.Height;
    VertScrollBoxScroll.SetBounds(VertScrollBoxScroll.Position.X, Y, VertScrollBoxScroll.Width, Max(0, LayoutBody.Height - Y - 18));
    FLetterScroll.SetBounds(24, Y, 36, VertScrollBoxScroll.Height);
    ArrangeLetterNavigation;
  finally
    FLayouting := False;
  end;
end;
{$ENDIF}

procedure TLibraryView.UpdateInspector;
begin
  ButtonPlay.Enabled := FSelected <> nil;
  ButtonFavorite.Enabled := FSelected <> nil;
  if FSelected = nil then
  begin
    LabelTitle.Text := Translate('Select a game');
    ImageCover.Bitmap := nil;
    LabelDetails.Text := '';
    LabelDescription.Text := '';
    LabelGameInfo.Text := '';
  end
  else
  begin
    LabelTitle.Text := FSelected.Title;
    LabelDetails.Text := LibrarySystemName(FSelected.SystemId) + sLineBreak + FSelected.Developer;
    LabelDescription.Text := FSelected.Description;
    if LabelDescription.Text = '' then
      LabelDescription.Text := FSelected.Genre;
    LabelGameInfo.Text := '';
    if FSelected.Genre <> '' then
      LabelGameInfo.Text := Translate('Genre: ') + FSelected.Genre;
    if FSelected.Players <> '' then
      LabelGameInfo.Text := LabelGameInfo.Text + sLineBreak + Translate('Players: ') + FSelected.Players;
    if FSelected.Favorite then
      ButtonFavorite.Text := Translate('Remove from favorites')
    else
      ButtonFavorite.Text := Translate('Add to favorites');
    LoadImage(ImageCover, FSelected.Cover);
  end;

  var Saves := Snapshots(FSelected);
  LabelSavesEmpty.Visible := Length(Saves) = 0;
  LabelSavesEmpty.Text := Translate('No save states yet.');
  for var i := 0 to 2 do
  begin
    FSaveButtons[i].Visible := i < Length(Saves);
    FSaveImages[i].Visible := i < Length(Saves);
    if i < Length(Saves) then
    begin
      FSaveButtons[i].Text := Saves[i].Name + sLineBreak + FormatDateTime('dd.mm.yyyy hh:nn', Saves[i].Modified);
      FSaveButtons[i].TagString := Saves[i].Location;
      LoadImage(FSaveImages[i], Saves[i].PreviewLocation);
    end;
  end;
end;

procedure TLibraryView.SelectContinueGame;
begin
  FRecent := nil;
  var Latest: TDateTime := 0;
  var HasSnapshot := False;
  for var Game in FGames do
  begin
    var Saves := Snapshots(Game);
    if Length(Saves) > 0 then
    begin
      if not HasSnapshot or (Saves[0].Modified > Latest) or
        ((Saves[0].Modified = Latest) and (Game.LastPlayed > FRecent.LastPlayed)) then
      begin
        FRecent := Game;
        Latest := Saves[0].Modified;
      end;
      HasSnapshot := True;
    end
    else if not HasSnapshot and (Game.LastPlayed > 0) and
      ((FRecent = nil) or (Game.LastPlayed > FRecent.LastPlayed)) then
      FRecent := Game;
  end;
end;

procedure TLibraryView.UpdateContinue;
begin
  SelectContinueGame;
  var Bitmap := FContinueCover.Fill.Bitmap.Bitmap;
  Bitmap.RemoveCallback(FContinueCover);
  FContinueGamePreview.Bitmap.RemoveCallback(FContinueGamePreview);
  FContinue.Visible := FRecent <> nil;
  if FRecent = nil then
    Exit;

  LabelContinueTitle.Text := FRecent.Title;
  LabelContinuePlatform.Text := LibrarySystemName(FRecent.SystemId);
  if FRecent.Genre <> '' then
    LabelContinuePlatform.Text := LabelContinuePlatform.Text + ' · ' + FRecent.Genre;
  LabelContinueLastPlayed.Text := Translate('Last played: ') + LibraryDate(FRecent.LastPlayed);
  var Saves := Snapshots(FRecent);
  var Preview := '';
  if Length(Saves) > 0 then
  begin
    LabelContinueCaption.Text := Translate('Continue playing');
    FResume.Text := Translate('Resume');
    LabelContinueSave.Text := Translate('Save state: ') + Saves[0].Name + ' · ' + LibraryDate(Saves[0].Modified);
    if FStorage.Exists(Saves[0].PreviewLocation) then
      Preview := Saves[0].PreviewLocation;
  end
  else
  begin
    LabelContinueCaption.Text := Translate('Recently played');
    FResume.Text := Translate('Play');
    LabelContinueSave.Text := Translate('No save states yet');
  end;
  Bitmap.SetSize(0, 0);
  FContinueCover.Fill.Kind := TBrushKind.Solid;
  FContinueCover.Visible := True;
  FContinueGamePreview.Bitmap := nil;
  FContinueGamePreview.Visible := False;
  LabelContinueNoPreview.Visible := True;
  LabelContinueNoPreview.Text := Translate('No save-state screenshot');
  if Length(Saves) = 0 then
    LabelContinueNoPreview.Text := Translate('No save state');
  ArrangeContinuePreview;
  if Preview <> '' then
    Bitmap.LoadFromFileAsync(FContinueCover, Preview, 320, 400,
      procedure(Success: Boolean)
      begin
        if Success then
        begin
          FContinueCover.Fill.Kind := TBrushKind.Bitmap;
          LabelContinueNoPreview.Visible := False;
          Resize;
        end
        else
          LoadContinueGamePreview;
      end, FStorage)
  else
    LoadContinueGamePreview;
end;

procedure TLibraryView.LoadContinueGamePreview;
begin
  FContinueCover.Visible := False;
  FContinueGamePreview.Visible := True;
  LabelContinueNoPreview.Text := Translate('Preview unavailable');
  LabelContinueNoPreview.Visible := (FRecent.Cover = '') or not FStorage.Exists(FRecent.Cover);
  LoadImage(FContinueGamePreview, FRecent.Cover);
end;

procedure TLibraryView.ArrangeContinuePreview;
begin
  var Bitmap := FContinueCover.Fill.Bitmap.Bitmap;
  if not Bitmap.IsEmpty then
    LayoutContinuePreview.Width := LayoutContinuePreview.Height * Bitmap.Width / Bitmap.Height
  else
    LayoutContinuePreview.Width := 176;
  FContinueCover.SetBounds(0, 0, LayoutContinuePreview.Width, LayoutContinuePreview.Height);
end;

procedure TLibraryView.OpenClick(Sender: TObject);
begin
  if Assigned(FOnOpen) then
    FOnOpen(Self);
end;

procedure TLibraryView.SettingsClick(Sender: TObject);
begin
  if Assigned(FOnSettings) then
    FOnSettings(Self);
end;

procedure TLibraryView.FilterClick(Sender: TObject);
begin
  FSystemFilter := TButton(Sender).TagString;
  FLetterFilter := '';
  FLimit := 48;
  BuildCards;
  VertScrollBoxScroll.ViewportPosition := TPointF.Zero;
end;

procedure TLibraryView.ModeClick(Sender: TObject);
begin
  FMode := TButton(Sender).Tag;
  FLetterFilter := '';
  FLimit := 48;
  BuildCards;
end;

procedure TLibraryView.SearchChange(Sender: TObject);
begin
  FLetterFilter := '';
  FLimit := 48;
  BuildCards;
end;

procedure TLibraryView.LetterClick(Sender: TObject);
begin
  FLetterFilter := TButton(Sender).TagString;
  FLimit := 48;
  BuildCards;
  VertScrollBoxScroll.ViewportPosition := TPointF.Zero;
end;

procedure TLibraryView.CardClick(Sender: TObject);
begin
  FSelected := TLibraryGame(TPanel(Sender).TagObject);
  for var Card in FCards do
    Card.Selection.Visible := Card.TagObject = FSelected;
  UpdateInspector;
  if not PanelInspector.Visible then
    PlayClick(Self);
end;

{$IF Defined(ANDROID) or Defined(IOS)}
procedure TLibraryView.CardTap(Sender: TObject; const Point: TPointF);
begin
  CardClick(Sender);
end;
{$ELSE}

procedure TLibraryView.CardDblClick(Sender: TObject);
begin
  if PanelInspector.Visible then
  begin
    CardClick(Sender);
    PlayClick(Self);
  end;
end;
{$ENDIF}

procedure TLibraryView.PlayClick(Sender: TObject);
begin
  FSnapshotName := '';
  if (FSelected <> nil) and Assigned(FOnPlay) then
    FOnPlay(Self);
end;

procedure TLibraryView.ResumeClick(Sender: TObject);
begin
  if FRecent = nil then
    Exit;

  FSelected := FRecent;
  var Saves := Snapshots(FRecent);
  FSnapshotName := '';
  if Length(Saves) > 0 then
    FSnapshotName := Saves[0].Location;
  if Assigned(FOnPlay) then
    FOnPlay(Self);
end;

procedure TLibraryView.SaveClick(Sender: TObject);
begin
  FSnapshotName := TButton(Sender).TagString;
  if Assigned(FOnPlay) then
    FOnPlay(Self);
end;

procedure TLibraryView.FavoriteClick(Sender: TObject);
begin
  if FSelected = nil then
    Exit;

  FSelected.Favorite := not FSelected.Favorite;
  FState.WriteBool('Favorites', FSelected.Key, FSelected.Favorite);
  SaveState;
  // The favorite action lives in the inspector, which survives card rebuilds.
  BuildCards;
end;

procedure TLibraryView.UpdateViewIcons;
begin
  if FListMode then
  begin
    FListIcon.Stroke.Color := $FFFFB344;
    FGridIcon.Stroke.Color := $FFE8ECF1;
  end
  else
  begin
    FListIcon.Stroke.Color := $FFE8ECF1;
    FGridIcon.Stroke.Color := $FFFFB344;
  end;
end;

procedure TLibraryView.ViewClick(Sender: TObject);
begin
  FListMode := TButton(Sender).Tag = 1;
  UpdateViewIcons;
  var Ini := FStorage.ReadConfig(FStorage.ConfigFile('config'));
  try
    if FListMode then
      Ini.WriteString('Library', 'View', 'list')
    else
      Ini.WriteString('Library', 'View', 'grid');
    FStorage.WriteConfig(Ini);
  finally
    Ini.Free;
  end;
  ArrangeCards;
end;

procedure TLibraryView.MoreClick(Sender: TObject);
begin
  if FBuilding or (LayoutGrid = nil) then
    Exit;
  var Viewport := VertScrollBoxScroll.ViewportPosition;
  Inc(FLimit, 48);
  BuildCards(True);
  VertScrollBoxScroll.ViewportPosition := Viewport;
end;

end.

