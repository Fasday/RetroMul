unit RM.Settings;

interface

uses
  Core.RomFormat, System.IOUtils, System.SysUtils, System.Classes,
  System.IniFiles, System.Generics.Collections, System.Types, System.UITypes,
  FMX.Forms, FMX.Types, FMX.Controls, FMX.Layouts, FMX.StdCtrls, FMX.Text,
  FMX.Edit, FMX.EditBox, FMX.SpinBox, FMX.ListBox, FMX.Controls.Presentation,
  Core.Storage, Core.Emulation, FMXInput, FMX.Objects;

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

const
  AUTOSAVE_DEFAULT_MINUTES = 10;
  AUTOSAVE_MAX_MINUTES = 1440;

const
  SettingsCategoryNames: array[SETTINGS_CATEGORY_GENERAL..SETTINGS_CATEGORY_PERIPHERALS] of string = ('General', 'Library', 'Video and audio', 'Controls', 'Peripherals');
  SettingsCoreIds: array[SETTINGS_PAGE_GB..SETTINGS_PAGE_GBA] of string = (
    ROM_SYSTEM_GB, ROM_SYSTEM_GBC, ROM_SYSTEM_NES, ROM_SYSTEM_MD, ROM_SYSTEM_SNES, ROM_SYSTEM_NEOGEO, ROM_SYSTEM_GBA);
  SettingsPageNames: array[SETTINGS_PAGE_MAIN..SETTINGS_PAGE_GBA] of string = ('Main', 'Game Boy', 'Game Boy Color',
    'NES / Famicom', 'Mega Drive', 'Super Nintendo', 'Neo Geo', 'Game Boy Advance');
  // Presentation order is independent of the page IDs used by drafts and core selection.
  SettingsCoreOrder: array[0..6] of Integer = (
    SETTINGS_PAGE_GB, SETTINGS_PAGE_GBC, SETTINGS_PAGE_GBA, SETTINGS_PAGE_NES,
    SETTINGS_PAGE_MD, SETTINGS_PAGE_SNES, SETTINGS_PAGE_NEOGEO);

type
  TDeviceCallouts = class;

  TBindingLines = class(TControl)
  protected
    procedure Paint; override;
  end;

  TBindingCallout = record
    Button: Integer;
    Name: string;
    Left: Boolean;
    LabelControl: TLabel;
  end;

  TDeviceCallouts = class(TControl)
  private
    FDevice: TControl;
    FItems: TArray<TBindingCallout>;
    FLines: TBindingLines;
    FInput: TInputManager;
    FAnnotations: Boolean;
    function ButtonBounds(Index: Integer): TRectF;
    procedure AddCallout(Button, Action: Integer; const Name, Caption: string; Left: Boolean; Click: TNotifyEvent);
  protected
    procedure Resize; override;
  public
    procedure Configure(Device: TControl; Input: TInputManager; const Core: string; Port: Integer; Click: TNotifyEvent);
    procedure Refresh;
    procedure ShowAnnotations(Value: Boolean);
  end;

  TSettingsLocationPicker = reference to procedure(Folder: Boolean; const Current: string; const Callback: TStorageSelectionCallback);

  TSettingsTemplatePicker = reference to procedure(const SuggestedName: string; const Callback: TStorageSelectionCallback);

  TSettingsField = class
    Control: TControl;
    Row: TPanel;
    Section, Key, DefaultValue: string;
    Values: TArray<string>;
  end;

  TSettingsDevice = class
    Control: TControl;
    Diagram: TControl;
    Capture, Clear: TButton;
    Caption: TLabel;
    Assignments: TVertScrollBox;
    AssignmentList: TLayout;
    Port: Integer;
    Device: string;
  end;

  TSettingsView = class(TFrame)
    PanelSidebar: TPanel;
    LayoutCoreTabs: TLayout;
    ButtonReset: TButton;
    ButtonRefresh: TButton;
    ListBoxNavigation: TListBox;
    LayoutBody, LayoutContent, LayoutHeader, LayoutFooter: TLayout;
    VertScrollBoxScroll: TVertScrollBox;
    LabelTitle, LabelStatus: TLabel;
    ButtonApply, ButtonBack, ButtonCancelCapture: TButton;
    LayoutComponentStore: TLayout;
  private
    FStorage: IStorage;
    FPicker: TSettingsLocationPicker;
    FTemplatePicker: TSettingsTemplatePicker;
    FPickingBootROM: Boolean;
    FPickingTranslation: Boolean;
    FInput: TInputManager; // Draft assignments owned by this view.
    FHostInput: TInputManager; // Shared device snapshots; owned by the form.
    FDrafts: array[SETTINGS_PAGE_MAIN..SETTINGS_PAGE_GBA] of TMemIniFile;
    FFields: TObjectList<TSettingsField>;
    FDevices: TObjectList<TSettingsDevice>;
    FDeviceIds: array[0..7] of string;
    FAlive: TFunc<Boolean>;
    FInvalidate: TProc;
    FSearch: TEdit;
    FPagePicker: TComboBox;
    FCategory, FCorePage, FPlayer: Integer;
    FCoreButtons: array[SETTINGS_PAGE_GB..SETTINGS_PAGE_GBA] of TButton;
    FCategoryIcons: array[SETTINGS_CATEGORY_GENERAL..SETTINGS_CATEGORY_PERIPHERALS] of TControl;
    FPage: Integer;
    FGroup: TPanel;
    FPreview: TControl;
    FPreviewGroup: TPanel;
    FHeight: Single;
    FBuilding, FRebuildPending, FArranging: Boolean;
    FVolumeValue: TLabel;
    FFolderEdit: TEdit;
    FAutosaveMinutes: TSpinBox;
    FCaptureAction: Integer;
    FCaptureDeadline: UInt64;
    FCaptureButton: TButton;
    FOnApply, FOnClose: TNotifyEvent;
    procedure InitializeRuntimeControls;
    procedure InitializeGBControls;
    procedure ClearPathClick(Sender: TObject);
    procedure SaveTemplateClick(Sender: TObject);
    procedure BuildPage(PreserveScroll: Boolean = False);
    procedure RequestRebuild;
    procedure StorePage;
    procedure Heading(const Name: string);
    function Row(const Name: string): TPanel;
    function Field(Control: TControl; const Section, Key: string): TSettingsField;
    function Combo(const Name, Section, Key: string; const Labels, Values: array of string; const Default: string): TComboBox;
    function Check(const Name, Section, Key: string; Default: Boolean): TSwitch;
    function Number(const Name, Section, Key: string; Default, Max: Integer): TSpinBox;
    function EditText(const Name, Section, Key, Default: string): TEdit;
    function PathEdit(const Name, Section, Key, Default: string; Folder: Boolean): TEdit;
    procedure ArrangeGroup(Group: TPanel);
    procedure ContentResize(Sender: TObject);
    procedure EditorResize(Sender: TObject);
    procedure ComboResize(Sender: TObject);
    procedure RowResize(Sender: TObject);
    procedure DeviceResize(Sender: TObject);
    procedure BindingFooterResize(Sender: TObject);
    procedure NavigationChange(Sender: TObject);
    procedure PagePickerChange(Sender: TObject);
    procedure CoreClick(Sender: TObject);
    procedure SearchChange(Sender: TObject);
    procedure PlayerChange(Sender: TObject);
    procedure BuildPort(Port: Integer; const Caption: string);
    procedure BuildBindings(Port: Integer; const Device: string);
    function AddBinding(const Caption: string; Action, Port: Integer): TButton;
    procedure BuildDevice(Port: Integer; const Device: string);
    procedure RefreshBindings;
    procedure SelectBinding(Device: TSettingsDevice; Action: Integer; const Caption: string);
    procedure AssignmentClick(Sender: TObject);
    procedure CalloutClick(Sender: TObject);
    procedure VirtualDeviceChange(Sender: TObject);
    procedure DeviceChange(Sender: TObject);
    procedure RefreshDevicesClick(Sender: TObject);
    procedure PortChange(Sender: TObject);
    procedure CaptureClick(Sender: TObject);
    procedure ClearBindingClick(Sender: TObject);
    procedure CancelCaptureClick(Sender: TObject);
    procedure VolumeChange(Sender: TObject);
    procedure AutosaveToggle(Sender: TObject);
    procedure PreviewChange(Sender: TObject);
    procedure ResetClick(Sender: TObject);
    procedure PathClick(Sender: TObject);
    procedure CheckRomFolder(const Location: string);
    procedure ApplyClick(Sender: TObject);
    procedure BackClick(Sender: TObject);
  protected
    procedure Resize; override;
    procedure PickLocation(Folder: Boolean; const Current: string; const Callback: TStorageSelectionCallback); virtual;
    procedure PickTemplateLocation(const Callback: TStorageSelectionCallback); virtual;
  public
    constructor CreateSettings(AOwner: TComponent; const Storage: IStorage; Input: TInputManager);
    destructor Destroy; override;
    procedure SelectCategory(Index: Integer);
    procedure SelectCore(Index: Integer; PreserveCategory: Boolean = False);
    property Category: Integer read FCategory;
    property CorePage: Integer read FCorePage;
    procedure Poll;
    procedure CancelCapture;
    property InputManager: TInputManager read FInput;
    function HandleCaptureKeyDown(var Key: Word; var KeyChar: WideChar): Boolean;
    procedure ApplyLanguage(const PreviousLanguage: string);
    property OnApply: TNotifyEvent read FOnApply write FOnApply;
    property LocationPicker: TSettingsLocationPicker read FPicker write FPicker;
    property TemplateLocationPicker: TSettingsTemplatePicker read FTemplatePicker write FTemplatePicker;
    property OnClose: TNotifyEvent read FOnClose write FOnClose;
  end;

implementation

uses
  System.Math, System.TypInfo, RM.Input, GB.Memory, GB.Palettes, FMX.OpenDialog,
  RM.Gamepad, NES.PowerPad, NES.SuborKeyboard, NES.FamicomKeyboard,
  NES.MiraclePiano, NES.Controller, NES.MiraclePianoDevice, FMX.BehaviorManager,
  FMX.Graphics, FMX.SpinBox.Style, FMX.Presentation.Style,
  FMX.Presentation.Factory, RM.LibraryView, RM.Icons, RM.SearchEdit, RM.Styles,
  RM.Dialogs
  {$IFDEF ANDROID}, Core.Storage.Android{$ENDIF};

{$R *.fmx}

type
  TSettingsInputBackend = class(TInputBackend)
  private
    FHost: TInputManager;
  public
    constructor Create(Host: TInputManager);
    procedure Refresh; override;
    procedure RefreshIfNeeded; override;
    function Poll: TArray<TInputValue>; override;
  end;

  TSettingsPreview = class(TImage)
  private
    FPaletteIndex: Integer;
    procedure SetPaletteIndex(Value: Integer);
  public
    constructor Create(AOwner: TComponent); override;
    property PaletteIndex: Integer read FPaletteIndex write SetPaletteIndex;
  published
    property Align;
    property Margins;
    property Position;
    property Size;
  end;

  TSettingsComboBox = class(TComboBox)
  private
    FCaption: TLabel;
  protected
    procedure ApplyStyle; override;
    procedure DoChange; override;
  public
    constructor Create(AOwner: TComponent); override;
  end;

  TSettingsTrackBar = class(TTrackBar)
  protected
    procedure DoRealign; override;
    procedure MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean); override;
  end;

  TSettingsSpinBox = class(TSpinBox)
  protected
    function DefinePresentationName: string; override;
  end;

  TSettingsSpinBoxStyle = class(TStyledSpinBox)
  protected
    procedure MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean); override;
  end;

constructor TSettingsInputBackend.Create(Host: TInputManager);
begin
  inherited Create;
  FHost := Host;
end;

procedure TSettingsInputBackend.Refresh;
begin
  FHost.Refresh;
  RefreshIfNeeded;
end;

procedure TSettingsInputBackend.RefreshIfNeeded;
begin
  FDevices := FHost.Devices;
end;

function TSettingsInputBackend.Poll: TArray<TInputValue>;
begin
  // The frontend polls the native backend once. Editing assignments must not
  // replace the running game's map or consume relative input a second time.
  Result := FHost.Values;
end;

function SettingsLabel(Owner: TComponent): TLabel;
begin
  Result := TLabel.Create(Owner);
  Result.StyledSettings := Result.StyledSettings - [TStyledSetting.Other];
  Result.TextSettings.Trimming := TTextTrimming.Character;
  Result.TextSettings.WordWrap := False;
end;

function SettingsButton(Owner: TComponent): TButton;
begin
  Result := TButton.Create(Owner);
  Result.StyledSettings := Result.StyledSettings - [TStyledSetting.Other];
  Result.TextSettings.Trimming := TTextTrimming.Character;
  Result.TextSettings.WordWrap := False;
end;

constructor TSettingsComboBox.Create(AOwner: TComponent);
begin
  inherited;
  StyleLookup := 'comboboxstyle';
  FCaption := SettingsLabel(Self);
  FCaption.Parent := Self;
  FCaption.Align := TAlignLayout.Client;
  FCaption.Margins.Rect := TRectF.Create(12, 0, 32, 0);
  FCaption.HitTest := False;
  FCaption.StyledSettings := [];
  FCaption.TextSettings.Font.Family := 'Segoe UI';
  FCaption.TextSettings.Font.Size := 14;
  FCaption.TextSettings.FontColor := $FFE8ECF1;
end;

procedure TSettingsComboBox.ApplyStyle;
begin
  inherited;
  var Content: TControl;
  if FindStyleResource<TControl>('content', Content) then
    Content.OnPaint := nil;
  if FCaption <> nil then
    FCaption.BringToFront;
end;

procedure TSettingsComboBox.DoChange;
begin
  if FCaption <> nil then
    FCaption.Text := Text;
  inherited;
end;

constructor TSettingsPreview.Create(AOwner: TComponent);
begin
  inherited;
  WrapMode := TImageWrapMode.Stretch;
  DisableInterpolation := True;
  FPaletteIndex := -1;
  SetPaletteIndex(0);
end;

procedure TSettingsPreview.SetPaletteIndex(Value: Integer);
begin
  Value := EnsureRange(Value, 0, SCREEN_PALETTE_COUNT - 1);
  if Value = FPaletteIndex then
    Exit;
  Bitmap.SetSize(160, 144);
  var Data: TBitmapData;
  if not Bitmap.Map(TMapAccess.Write, Data) then
    Exit;
  try
    var Palette := ScreenPalettes[Value];
    for var PixelY := 0 to Bitmap.Height - 1 do
      for var PixelX := 0 to Bitmap.Width - 1 do
      begin
        var X := PixelX * 32 div Bitmap.Width;
        var Y := PixelY * 29 div Bitmap.Height;
        var Shade := 0;
        if Y > 12 + Abs(16 - X) div 2 then
          Shade := 1;
        if Y > 19 then
          Shade := 2;
        if (Y = 20) or ((Y > 20) and ((X + Y) mod 4 = 0)) then
          Shade := 3;
        if (X in [4..7]) and (Y in [9..16]) then
          Shade := 2;
        if (X = 6) and (Y in [16..19]) then
          Shade := 3;
        if (X in [14..15]) and (Y in [16..19]) then
          Shade := 3;
        if (Y in [4..5]) and (X in [18..22]) then
          Shade := 0;
        Data.SetPixel(PixelX, PixelY, Palette.Colors[Shade]);
      end;
    FPaletteIndex := Value;
  finally
    Bitmap.Unmap(Data);
  end;
  Repaint;
end;

procedure TSettingsTrackBar.DoRealign;
begin
  inherited;
  // FMX updates the highlight during Resize, before the styled track is resized.
  // Recalculate it after alignment, when the track and thumb have their final bounds.
  if (FTrack = nil) or (FTrackHighlight = nil) then
    Exit;
  var Center := GetThumbRect.CenterPoint;
  if Orientation = TOrientation.Horizontal then
  begin
    if Reverse then
      Center.X := FTrack.Width - Center.X;
    FTrackHighlight.Width := Round(Center.X);
  end
  else
  begin
    if Reverse then
      Center.Y := FTrack.Height - Center.Y;
    FTrackHighlight.Height := Round(Center.Y);
  end;
end;

procedure TSettingsTrackBar.MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean);
begin
  // Leave the wheel unhandled so the containing scroll box receives it.
end;

function TSettingsSpinBox.DefinePresentationName: string;
begin
  Result := 'SettingsSpinBox-' + GetPresentationSuffix;
end;

procedure TSettingsSpinBoxStyle.MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean);
begin
  // TStyledEditBox increments even when Handled is true; bypass that implementation.
end;

function TDeviceCallouts.ButtonBounds(Index: Integer): TRectF;
begin
  if FDevice is TNesPowerPad then
    Result := TNesPowerPad(FDevice).ButtonBounds(FItems[Index].Button)
  else
    Result := TScreenGamepad(FDevice).ButtonBounds(TEmulatorButton(FItems[Index].Button));
end;

procedure TDeviceCallouts.AddCallout(Button, Action: Integer; const Name, Caption: string; Left: Boolean; Click: TNotifyEvent);
begin
  var Index := Length(FItems);
  SetLength(FItems, Index + 1);
  FItems[Index].Button := Button;
  FItems[Index].Name := Name;
  FItems[Index].Left := Left;
  var L := SettingsLabel(Self);
  FItems[Index].LabelControl := L;
  L.Parent := Self;
  L.Height := 28;
  L.HitTest := FInput <> nil;
  L.OnClick := Click;
  L.Tag := Action;
  L.TagString := Caption;
  L.StyledSettings := L.StyledSettings - [TStyledSetting.Size, TStyledSetting.Other];
  L.TextSettings.Font.Size := 12;
  L.TextSettings.WordWrap := False;
  L.TextSettings.Trimming := TTextTrimming.Character;
  if Left then
    L.TextSettings.HorzAlign := TTextAlign.Trailing
  else
    L.TextSettings.HorzAlign := TTextAlign.Leading;
end;

procedure TDeviceCallouts.Configure(Device: TControl; Input: TInputManager; const Core: string; Port: Integer; Click: TNotifyEvent);
begin
  HitTest := False;
  FDevice := Device;
  FInput := Input;
  FDevice.Parent := Self;
  FAnnotations := True;
  FDevice.Align := TAlignLayout.None;
  FLines := TBindingLines.Create(Self);
  FLines.Parent := Self;
  FLines.Align := TAlignLayout.Client;
  FLines.HitTest := False;
  if Device is TNesPowerPad then
    for var Button := 1 to 12 do
      AddCallout(Button, PowerPadAction + Button - 1, IntToStr(Button),
        Translate('Pad ') + IntToStr(Button), (Button - 1) mod 4 < 2, Click)
  else
    for var B in TScreenGamepad(Device).ButtonMask do
    begin
      var Left := B in [TEmulatorButton.Up, TEmulatorButton.Down,
          TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.Select,
          TEmulatorButton.Mode];
      if (Core = ROM_SYSTEM_SNES) and (B = TEmulatorButton.C) then
        Left := True;
      var Name := CoreButtonName(Core, B);
      AddCallout(Ord(B), PadAction(Port, B), Name, Translate('Button ') + Name, Left, Click);
    end;
  Refresh;
  Resize;
end;

procedure TDeviceCallouts.Refresh;
begin
  for var Item in FItems do
  begin
    var L := Item.LabelControl;
    if L = nil then
      Continue;

    var Assignment := BindingCaption(FInput, L.Tag);
    L.Text := Item.Name + ' · ' + Assignment;
    if Width < 460 then
      L.Text := Assignment;
    L.Hint := L.TagString + ': ' + Assignment;
    L.ShowHint := True;
  end;
end;

procedure TDeviceCallouts.Resize;
begin
  inherited;
  if csDestroying in ComponentState then
    Exit;
  if (FDevice = nil) or (FLines = nil) then
    Exit;

  var Rail := Min(170, Max(40, Width * 0.18));
  if not FAnnotations then
    Rail := 0;
  var Aspect: Single := 0.46;
  if FDevice is TScreenGamepad then
    Aspect := TScreenGamepad(FDevice).AspectRatio;
  if FDevice is TNesPowerPad then
    Aspect := 3.8 / 4.4;
  var Limit := IfThen(FAnnotations, 400, 640);
  var PadWidth := Min(Min(Limit, Max(40, Height / Aspect)), Max(40, Width - 2 * (Rail + 12)));
  FDevice.SetBounds((Width - PadWidth) / 2, (Height - PadWidth * Aspect) / 2,
    PadWidth, PadWidth * Aspect);
  for var Side := 0 to 1 do
  begin
    var Buttons: TArray<Integer> := nil;
    for var B := 0 to High(FItems) do
      if FItems[B].Left = (Side = 0) then
      begin
        var N := Length(Buttons);
        SetLength(Buttons, N + 1);
        Buttons[N] := B;
      end;
    // Match vertical button order to the callouts to limit crossed leaders.
    for var i := 0 to High(Buttons) - 1 do
      for var J := i + 1 to High(Buttons) do
      begin
        var ReverseColumns := (FDevice is TNesPowerPad) and (Side = 1);
        var EarlierColumn := ButtonBounds(Buttons[J]).CenterPoint.X < ButtonBounds(Buttons[i]).CenterPoint.X;
        if ReverseColumns then
          EarlierColumn := ButtonBounds(Buttons[J]).CenterPoint.X > ButtonBounds(Buttons[i]).CenterPoint.X;
        if (ButtonBounds(Buttons[J]).CenterPoint.Y < ButtonBounds(Buttons[i]).CenterPoint.Y) or
          ((ButtonBounds(Buttons[J]).CenterPoint.Y = ButtonBounds(Buttons[i]).CenterPoint.Y) and
          EarlierColumn) then
        begin
          var B := Buttons[i];
          Buttons[i] := Buttons[J];
          Buttons[J] := B;
        end;
      end;
    var Step := Min(34, Height / Max(1, Length(Buttons)));
    for var i := 0 to High(Buttons) do
    begin
      var L := FItems[Buttons[i]].LabelControl;
      var X: Single := 0;
      if Side = 1 then
        X := Width - Rail;
      L.SetBounds(X, (Height - Step * Length(Buttons)) / 2 + i * Step + (Step - L.Height) / 2,
        Rail, L.Height);
    end;
  end;
  Refresh;
  FLines.Repaint;
end;

procedure TDeviceCallouts.ShowAnnotations(Value: Boolean);
begin
  FAnnotations := Value;
  for var Item in FItems do
    Item.LabelControl.Visible := Value;
  FLines.Visible := Value;
  Resize;
end;

procedure TBindingLines.Paint;
begin
  inherited;
  var D := TDeviceCallouts(Parent);
  Canvas.Stroke.Kind := TBrushKind.Solid;
  Canvas.Stroke.Color := TAlphaColors.Gray;
  Canvas.Stroke.Thickness := 1;
  for var B := 0 to High(D.FItems) do
  begin
    var R := D.ButtonBounds(B);
    var L := D.FItems[B].LabelControl;
    var Start := R.CenterPoint + D.FDevice.Position.Point;
    var Finish := TPointF.Create(L.Position.X - 5, L.Position.Y + L.Height / 2);
    Start.X := R.Right + D.FDevice.Position.X;
    if D.FItems[B].Left then
    begin
      Start.X := R.Left + D.FDevice.Position.X;
      Finish.X := L.Position.X + L.Width + 5;
    end;
    if (D.FDevice is TNesPowerPad) and ((D.FItems[B].Button - 1) mod 4 in [1, 2]) then
    begin
      // Route inner columns through the gaps below each row, away from pad numbers.
      Start := TPointF.Create(R.CenterPoint.X + D.FDevice.Position.X, R.Bottom + D.FDevice.Position.Y);
      var ExitPoint := TPointF.Create(Start.X, Start.Y + 4);
      var RailX := D.FDevice.Position.X + D.FDevice.Width + 8;
      if D.FItems[B].Left then
        RailX := D.FDevice.Position.X - 8;
      var Outside := TPointF.Create(RailX, ExitPoint.Y);
      var Elbow := TPointF.Create(RailX, Finish.Y);
      Canvas.DrawLine(Start, ExitPoint, AbsoluteOpacity * 0.8);
      Canvas.DrawLine(ExitPoint, Outside, AbsoluteOpacity * 0.8);
      Canvas.DrawLine(Outside, Elbow, AbsoluteOpacity * 0.8);
      Canvas.DrawLine(Elbow, Finish, AbsoluteOpacity * 0.8);
    end
    else
    begin
      var Elbow := TPointF.Create((Start.X + Finish.X) / 2, Finish.Y);
      Canvas.DrawLine(Start, Elbow, AbsoluteOpacity * 0.8);
      Canvas.DrawLine(Elbow, Finish, AbsoluteOpacity * 0.8);
    end;
    Canvas.Fill.Color := TAlphaColors.Gray;
    Canvas.FillEllipse(TRectF.Create(Start.X - 2, Start.Y - 2, Start.X + 2, Start.Y + 2), AbsoluteOpacity);
  end;
end;

constructor TSettingsView.CreateSettings(AOwner: TComponent; const Storage: IStorage; Input: TInputManager);
begin
  FBuilding := True;
  inherited Create(AOwner);
  FCategory := SETTINGS_CATEGORY_GENERAL;
  FPage := SETTINGS_PAGE_MAIN;
  FCorePage := SETTINGS_PAGE_GB;
  FStorage := Storage;
  FHostInput := Input;
  if Input <> nil then
    FInput := TInputManager.Create(TSettingsInputBackend.Create(Input));
  FFields := TObjectList<TSettingsField>.Create;
  FDevices := TObjectList<TSettingsDevice>.Create;
  var Alive := True;
  FAlive :=
    function: Boolean
    begin
      Result := Alive;
    end;
  FInvalidate :=
    procedure
    begin
      Alive := False;
    end;
  FDrafts[SETTINGS_PAGE_MAIN] := FStorage.ReadConfig(FStorage.ConfigFile('config'));
  FDrafts[SETTINGS_PAGE_MAIN].WriteString('General', 'Path', FStorage.RomFolder);
  for var i := Low(SettingsCoreIds) to High(SettingsCoreIds) do
    FDrafts[i] := FStorage.ReadConfig(FStorage.ConfigFile(SettingsCoreIds[i]));
  InitializeRuntimeControls;
  FSearch := FindComponent('SearchEditSettingsSearch') as TEdit;
  FPagePicker := FindComponent('SettingsComboBoxSettingsPagePicker') as TComboBox;
  FormStyles.RelocalizeUI(Self, 'en');
  LayoutComponentStore.Parent := nil;
  (FindComponent('ButtonSidebarBack') as TButton).OnClick := BackClick;
  (FindComponent('ButtonSidebarBack') as TButton).StylesData['text.Margins.Left'] := 36;
  (FindComponent('ButtonSidebarBack') as TButton).StylesData['text.Margins.Right'] := 10;
  for var i := Low(FCategoryIcons) to High(FCategoryIcons) do
  begin
    FCategoryIcons[i] := FindComponent('PathCategoryIcon' + IntToStr(i)) as TControl;
    ListBoxNavigation.ListItems[i].StyledSettings := ListBoxNavigation.ListItems[i].StyledSettings + [TStyledSetting.Other];
    ListBoxNavigation.ListItems[i].TextSettings.HorzAlign := TTextAlign.Leading;
    ListBoxNavigation.ListItems[i].StylesData['text.Margins.Left'] := 48;
  end;
  ListBoxNavigation.OnChange := NavigationChange;
  FSearch.OnChangeTracking := SearchChange;
  FSearch.OnResize := EditorResize;
  for var i := Low(FCoreButtons) to High(FCoreButtons) do
  begin
    FCoreButtons[i] := FindComponent('ButtonCore' + IntToStr(i)) as TButton;
    FCoreButtons[i].Tag := i;
    FCoreButtons[i].OnClick := CoreClick;
  end;
  FPagePicker.OnResize := ComboResize;
  ComboResize(FPagePicker);
  FPagePicker.OnChange := PagePickerChange;
  ButtonApply.OnClick := ApplyClick;
  ButtonBack.OnClick := BackClick;
  ButtonReset.OnClick := ResetClick;
  ButtonRefresh.OnClick := RefreshDevicesClick;
  ButtonRefresh.Enabled := FInput <> nil;
  ButtonCancelCapture.OnClick := CancelCaptureClick;
  VertScrollBoxScroll.OnResize := ContentResize;
  BuildPage;
end;

procedure TSettingsView.ClearPathClick(Sender: TObject);
begin
  TEdit(TEditButton(Sender).TagObject).Text := '';
end;

procedure TSettingsView.InitializeGBControls;

  function BootRow(const Name, Caption, Detail: string): TPanel;
  begin
    Result := TPanel.Create(Self);
    Result.Name := 'Panel' + Name;
    Result.Parent := LayoutComponentStore;
    Result.StyleLookup := 'retromul_row';
    Result.Padding.Rect := TRectF.Create(16, 12, 16, 12);
    Result.SetBounds(16, 0, 868, 72);
    var Text := TLayout.Create(Self);
    Text.Name := 'Layout' + Name + 'Text';
    Text.Parent := Result;
    Text.SetBounds(16, 12, 550, 48);
    var Title := SettingsLabel(Self);
    Title.Name := 'Label' + Name + 'Title';
    Title.Parent := Text;
    Title.Align := TAlignLayout.Top;
    Title.Height := 24;
    Title.StyledSettings := Title.StyledSettings - [TStyledSetting.Size];
    Title.TextSettings.Font.Size := 15;
    Title.Text := Caption;
    var Note := SettingsLabel(Self);
    Note.Name := 'Label' + Name + 'Detail';
    Note.Parent := Text;
    Note.Align := TAlignLayout.Client;
    Note.Opacity := 0.72;
    Note.Text := Detail;
  end;

begin
  var Group := TPanel.Create(Self);
  Group.Name := 'PanelGroupBootROM';
  Group.Parent := LayoutComponentStore;
  Group.StyleLookup := 'retromul_card';
  Group.SetBounds(0, 0, 900, 230);
  var Title := SettingsLabel(Self);
  Title.Name := 'LabelGroupBootROMTitle';
  Title.Parent := Group;
  Title.SetBounds(16, 14, 868, 36);
  Title.StyledSettings := Title.StyledSettings - [TStyledSetting.Size];
  Title.TextSettings.Font.Size := 20;
  Title.Text := 'Boot ROM';
  var ModelRow := BootRow('RowBootModel', 'Boot ROM model',
    'Select a console boot sequence, or start the game directly.');
  var Models := TSettingsComboBox.Create(Self);
  Models.Name := 'SettingsComboBoxRowBootModelEditor';
  Models.Parent := ModelRow;
  for var Model := TGBBootModel.Skip to High(TGBBootModel) do
  begin
    var Name := 'RowBootFile' + GB_BOOT_MODEL_KEYS[Model];
    var Detail := 'Choose your boot ROM file for this model.';
    if Model = TGBBootModel.Skip then
    begin
      Name := 'RowBootFileGBA';
      Detail := 'Optional 16 KiB GBA BIOS. Leave empty to use the built-in emibios.';
    end;
    if Model in [TGBBootModel.DMG, TGBBootModel.MGB] then
      Detail := 'Leave empty to use the built-in boot ROM.';
    var FileRow := BootRow(Name, 'Boot ROM file', Detail);
    var Editor := TEdit.Create(Self);
    Editor.Name := 'Edit' + Name + 'Editor';
    Editor.Parent := FileRow;
    var Browse := TEditButton.Create(Self);
    Browse.Name := 'EditButton' + Name + 'Browse';
    Browse.Parent := Editor;
    Browse.Width := 32;
    Browse.Text := '…';
    var Clear := TEditButton.Create(Self);
    Clear.Name := 'EditButton' + Name + 'Clear';
    Clear.Parent := Editor;
    Clear.Width := 32;
    Clear.Text := '×';
    Clear.Hint := Translate('Clear');
    Clear.TagObject := Editor;
    Clear.OnClick := ClearPathClick;
  end;
  Group := TPanel.Create(Self);
  Group.Name := 'PanelGroupGBACartridge'; Group.Parent:=LayoutComponentStore;
  Group.StyleLookup:='retromul_card'; Group.SetBounds(0,0,900,230);
  Title:=SettingsLabel(Self); Title.Name:='LabelGroupGBACartridgeTitle'; Title.Parent:=Group;
  Title.SetBounds(16,14,868,36); Title.Text:='GBA cartridge';
  var SaveRow:=BootRow('RowGBASaveType','Save memory',
    'Auto detects the cartridge. Override only when a ROM uses an unrecognized save format.');
  var SaveChoice:=TSettingsComboBox.Create(Self);
  SaveChoice.Name:='SettingsComboBoxRowGBASaveTypeEditor'; SaveChoice.Parent:=SaveRow;
  var SolarRow:=BootRow('RowGBASolarLevel','Sunlight',
    'Boktai sensor level: 0 is darkness, 255 is maximum light.');
  var SolarValue:=TSettingsSpinBox.Create(Self);
  SolarValue.Name:='SettingsSpinBoxRowGBASolarLevelEditor'; SolarValue.Parent:=SolarRow;
  Group := TPanel.Create(Self);
  Group.Name := 'PanelGroupRumble';
  Group.Parent := LayoutComponentStore;
  Group.StyleLookup := 'retromul_card';
  Group.SetBounds(0, 0, 900, 150);
  Title := SettingsLabel(Self);
  Title.Name := 'LabelGroupRumbleTitle';
  Title.Parent := Group;
  Title.SetBounds(16, 14, 868, 36);
  Title.StyledSettings := Title.StyledSettings - [TStyledSetting.Size];
  Title.TextSettings.Font.Size := 20;
  Title.Text := 'Rumble';
  var RumbleRow := BootRow('RowRumble', 'Cartridge rumble',
    'Vibrate the device when the game activates its rumble motor.');
  var RumbleSwitch := TSwitch.Create(Self);
  RumbleSwitch.Name := 'SwitchRowRumbleEditor';
  RumbleSwitch.Parent := RumbleRow;
  Group := TPanel.Create(Self);
  Group.Name := 'PanelGroupGBEnhancements';
  Group.Parent := LayoutComponentStore;
  Group.StyleLookup := 'retromul_card';
  Group.SetBounds(0, 0, 900, 500);
  Title := SettingsLabel(Self);
  Title.Name := 'LabelGroupGBEnhancementsTitle';
  Title.Parent := Group;
  Title.SetBounds(16, 14, 868, 36);
  Title.StyledSettings := Title.StyledSettings - [TStyledSetting.Size];
  Title.TextSettings.Font.Size := 20;
  Title.Text := 'Game Boy enhancements';
  var Names: TArray<string> := ['FrameBlending', 'BGPalette', 'OBJ0Palette', 'OBJ1Palette',
      'ShowBackground', 'ShowWindow', 'ShowSprites', 'RemoveSpriteLimit', 'Overclock',
      'Channel1Volume', 'Channel2Volume', 'Channel3Volume', 'Channel4Volume'];
  var Captions: TArray<string> := ['Frame blending', 'Background palette', 'OBJ0 palette', 'OBJ1 palette',
      'Show background', 'Show window', 'Show sprites', 'Remove sprite limit', 'CPU speed (%)',
      'Channel 1 volume (%)', 'Channel 2 volume (%)', 'Wave channel volume (%)', 'Noise channel volume (%)'];
  var Details: TArray<string> := ['Blend the current and previous emulated frames equally.',
      'Palette for monochrome games.', 'Palette for monochrome games.', 'Palette for monochrome games.',
      'Display the background layer.', 'Display the window layer.', 'Display the sprite layer.',
      'Display up to 40 sprites per line; games may show unexpected graphics.',
      '100 is normal speed; higher values reduce CPU slowdown and may affect games.',
      'Square wave with frequency sweep.', 'Second square wave channel.', 'Programmable wave channel.', 'Noise channel.'];
  for var i := 0 to High(Names) do
  begin
    var Name := 'RowGB' + Names[i];
    var OptionRow := BootRow(Name, Captions[i], Details[i]);
    if i in [0, 4, 5, 6, 7] then
    begin
      var Toggle := TSwitch.Create(Self);
      Toggle.Name := 'Switch' + Name + 'Editor';
      Toggle.Parent := OptionRow;
    end
    else if i in [1, 2, 3] then
    begin
      var Choice := TSettingsComboBox.Create(Self);
      Choice.Name := 'SettingsComboBox' + Name + 'Editor';
      Choice.Parent := OptionRow;
    end
    else
    begin
      var Percent := TSettingsSpinBox.Create(Self);
      Percent.Name := 'SettingsSpinBox' + Name + 'Editor';
      Percent.Parent := OptionRow;
    end;
  end;
end;

procedure TSettingsView.InitializeRuntimeControls;
type
  TRuntimeControlClass = class of TControl;

  procedure ReplaceRuntime(const Name: string; Kind: TRuntimeControlClass);
  begin
    // FMX stores ordinary layout slots so the designer needs no custom package.
    var Slot := FindComponent('Layout' + Name + 'Slot') as TLayout;
    var Control := Kind.Create(Self);
    Control.Name := Copy(Kind.ClassName, 2, MaxInt) + Name;
    Control.SetBounds(Slot.Position.X, Slot.Position.Y, Slot.Width, Slot.Height);
    Control.Margins.Assign(Slot.Margins);
    Control.Align := Slot.Align;
    Control.Parent := Slot.Parent;
    Control.Index := Slot.Index;
    Slot.Free;
  end;

  function ReplaceCombo(const Name: string; const Captions: array of string): TSettingsComboBox;
  begin
    ReplaceRuntime(Name, TSettingsComboBox);
    Result := FindComponent('SettingsComboBox' + Name) as TSettingsComboBox;
    for var Caption in Captions do
      Result.Items.Add(Translate(Caption));
  end;

begin
  InitializeGBControls;
  var ClearTranslation := FindComponent('EditButtonRowTranslationfileClear') as TEditButton;
  ClearTranslation.TagObject := FindComponent('EditRowTranslationfileEditor');
  ClearTranslation.OnClick := ClearPathClick;
  (FindComponent('ButtonSaveTranslationTemplate') as TButton).OnClick := SaveTemplateClick;
  ReplaceRuntime('SettingsSearch', TSearchEdit);
  (TSearchEdit(FindComponent('SearchEditSettingsSearch'))).TextPrompt := Translate('Search this section');
  ReplaceCombo('SettingsPagePicker', ['General', 'Library', 'Video and audio', 'Controls', 'Peripherals']);
  (FindComponent('SettingsComboBoxSettingsPagePicker') as TSettingsComboBox).ItemIndex := FCategory;
  ReplaceCombo('RowLanguageEditor', ['English', 'Русский', 'Português']);
  ReplaceRuntime('AutosaveMinutes', TSettingsSpinBox);
  (TSettingsSpinBox(FindComponent('SettingsSpinBoxAutosaveMinutes'))).Min := 1;
  (TSettingsSpinBox(FindComponent('SettingsSpinBoxAutosaveMinutes'))).Max := 1440;
  (TSettingsSpinBox(FindComponent('SettingsSpinBoxAutosaveMinutes'))).ValueType := TNumValueType.Integer;
  ReplaceRuntime('RowBottominsetEditor', TSettingsSpinBox);
  (TSettingsSpinBox(FindComponent('SettingsSpinBoxRowBottominsetEditor'))).Min := 0;
  (TSettingsSpinBox(FindComponent('SettingsSpinBoxRowBottominsetEditor'))).ValueType := TNumValueType.Integer;
  (TSettingsSpinBox(FindComponent('SettingsSpinBoxRowBottominsetEditor'))).Max := 400;
  ReplaceCombo('RowLibraryviewEditor', ['Covers', 'List']);
  ReplaceCombo('RowCardsizeEditor', ['Compact', 'Normal', 'Large']);
  ReplaceCombo('RowImagescalingEditor', ['Nearest neighbor', 'Smoothing']);
  ReplaceCombo('RowGameBoypaletteEditor', []);
  ReplaceRuntime('PalettePreview', TSettingsPreview);
  ReplaceCombo('RowNESregionEditor', ['Automatic', 'NTSC', 'PAL']);
  ReplaceRuntime('VolumeTrack', TSettingsTrackBar);
  (TSettingsTrackBar(FindComponent('SettingsTrackBarVolumeTrack'))).Min := 0;
  (TSettingsTrackBar(FindComponent('SettingsTrackBarVolumeTrack'))).Max := 100;
  (TSettingsTrackBar(FindComponent('SettingsTrackBarVolumeTrack'))).Value := 50;
  ReplaceCombo('RowPlayerEditor', []);
  ReplaceCombo('RowConnecteddeviceEditor', ['Automatic', 'None', 'Subor keyboard', 'Famicom keyboard', 'Data Recorder']);
  for var Port := 1 to 8 do
    ReplaceCombo('RowControllerPort' + IntToStr(Port) + 'Editor', ['Gamepad', 'None']);
  for var Port := 1 to 8 do
    ReplaceCombo('RowConnecteddevice2Port' + IntToStr(Port) + 'Editor', ['Gamepad · 6 buttons', 'Gamepad · 3 buttons', 'None']);
  for var Port := 1 to 8 do
    ReplaceCombo('RowConnecteddevice10Port' + IntToStr(Port) + 'Editor', ['Automatic', 'Gamepad', 'Dendy · Turbo', 'Miracle Piano', 'None']);
  for var Port := 1 to 8 do
    ReplaceCombo('RowConnecteddevice18Port' + IntToStr(Port) + 'Editor', ['Automatic', 'Gamepad', 'Dendy · Turbo', 'Zapper', 'Power Pad', 'None']);
  for var Port := 1 to 8 do
    ReplaceCombo('RowConnecteddevice26Port' + IntToStr(Port) + 'Editor', ['Gamepad', 'None']);
  for var Port := 0 to 7 do
    ReplaceCombo('RowInputsource' + IntToStr(Port) + 'Editor', []);
end;

destructor TSettingsView.Destroy;
begin
  FBuilding := True;
  if Assigned(FInvalidate) then
    FInvalidate();
  CancelCapture;
  FFields.Free;
  FDevices.Free;
  for var Ini in FDrafts do
    Ini.Free;
  FInput.Free;
  inherited;
end;

procedure TSettingsView.BuildPage(PreserveScroll: Boolean);
begin
  var Position := VertScrollBoxScroll.ViewportPosition;
  FBuilding := True;
  VertScrollBoxScroll.BeginUpdate;
  try
    CancelCapture;
    FFolderEdit := nil;
    FAutosaveMinutes := nil;
    FVolumeValue := nil;
    FPreview := nil;
    FPreviewGroup := nil;
    FDevices.Clear;
    FFields.Clear;
    // Keep resource cards; release only styles and data-dependent device views.
    for var i := 0 to ComponentCount - 1 do
      if (Components[i] is TPanel) and
        (string(Components[i].Name).StartsWith('PanelRow') or string(Components[i].Name).StartsWith('PanelGroup')) then
      begin
        var Card := TPanel(Components[i]);
        while Card.ComponentCount > 0 do
          Card.Components[0].Free;
        Card.Parent := LayoutComponentStore;
        Card.Visible := True;
        Card.OnResize := nil;
      end;
    LayoutContent.Width := Min(1240, Max(0, VertScrollBoxScroll.Width - 16));
    FGroup := nil;
    FHeight := 0;
    LabelStatus.Text := Translate('Click Apply to save changes.');
    if FCategory = SETTINGS_CATEGORY_GENERAL then
    begin
      Heading('GroupAppearance');
      Combo('RowLanguage', 'General', 'Language', [], ['en', 'ru', 'pt'], 'en');
      PathEdit('RowTranslationfile', 'General', 'TranslationFile', '', False);
      (FindComponent('EditButtonRowTranslationfileClear') as TEditButton).Hint := Translate('Clear');
      Row('RowTranslationtemplate');
      Row('RowTheme');

      Heading('GroupDuringgameplay');
      Check('RowPausewhenfocusislost', 'General', 'PauseOnFocusLoss', True);
      Check('RowStartinfullscreen', 'General', 'StartFullscreen', False);
      Heading('GroupAutosave');
      var ExitSave := Check('RowAutosaveonexit', 'General', 'AutosaveOnExit', True);
      ExitSave.Name := 'SwitchAutosaveOnExit';
      var Periodic := Check('RowAutosaveeveryNminutes', 'General', 'AutosavePeriodic', False);
      Periodic.Name := 'SwitchAutosavePeriodic';
      FAutosaveMinutes := FindComponent('SettingsSpinBoxAutosaveMinutes') as TSettingsSpinBox;
      FAutosaveMinutes.Name := 'SettingsSpinBoxAutosaveMinutes';
      Field(FAutosaveMinutes, 'General', 'AutosaveMinutes').DefaultValue := IntToStr(AUTOSAVE_DEFAULT_MINUTES);
      FAutosaveMinutes.Min := 1;
      FAutosaveMinutes.Max := AUTOSAVE_MAX_MINUTES;
      FAutosaveMinutes.ValueType := TNumValueType.Integer;
      FAutosaveMinutes.Value := EnsureRange(FDrafts[SETTINGS_PAGE_MAIN].ReadInteger('General', 'AutosaveMinutes',
          AUTOSAVE_DEFAULT_MINUTES), 1, AUTOSAVE_MAX_MINUTES);
      Periodic.Align := TAlignLayout.Right;
      FAutosaveMinutes.Align := TAlignLayout.Client;
      FAutosaveMinutes.Enabled := Periodic.IsChecked;
      Periodic.OnSwitch := AutosaveToggle;
      Heading('GroupOnscreenbuttons');
      Number('RowBottominset', 'General', 'ControlBottomInset', 100, 400);
    end
    else if FCategory = SETTINGS_CATEGORY_LIBRARY then
    begin
      Heading('GroupGamelibrary');
      FFolderEdit := PathEdit('RowROMfolder', 'General', 'Path', FStorage.RomFolder, True);
      Combo('RowLibraryview', 'Library', 'View', [], ['grid', 'list'], 'grid');
      Combo('RowCardsize', 'Library', 'CardWidth', [], ['140', '170', '220'], '170');
      Check('RowShowplatformoncards', 'Library', 'ShowPlatform', True);
      Check('RowLetternavigation', 'Library', 'ShowLetters', False);
      Heading('GroupMetadata');
      Row('RowCoversanddescriptions');
    end
    else
    begin
      if FInput <> nil then
        LoadInputBindings(FInput, FDrafts[FPage], SettingsCoreIds[FPage]);
      if FCategory = SETTINGS_CATEGORY_VIDEO_AUDIO then
      begin
        Heading('GroupVideo');
        var Scaling := Combo('RowImagescaling', 'Video', 'Filter', [], ['nearest', 'linear'], 'nearest');
        if FPage = SETTINGS_PAGE_GB then
        begin
          var Labels, Values: TArray<string>;
          SetLength(Labels, SCREEN_PALETTE_COUNT);
          SetLength(Values, SCREEN_PALETTE_COUNT);
          for var i := 0 to SCREEN_PALETTE_COUNT - 1 do
          begin
            Labels[i] := ScreenPalettes[i].Name;
            Values[i] := IntToStr(i);
          end;
          var Palette := Combo('RowGameBoypalette', 'Video', 'Palette', Labels, Values, '0');
          Palette.OnChange := PreviewChange;
          Scaling.OnChange := PreviewChange;
          Heading('GroupPreview');
          FPreviewGroup := FGroup;
          var PreviewRow := Row('Row160144');
          PreviewRow.Tag := 1;
          PreviewRow.Padding.Rect := TRectF.Empty;
          PreviewRow.Height := 350;
          TLayout(TLabel(PreviewRow.TagObject).Parent).Visible := False;
          var Preview := FindComponent('SettingsPreviewPalettePreview') as TSettingsPreview;
          // Restore the original aspect ratio before the fit alignment recalculates.
          Preview.Align := TAlignLayout.None;
          Preview.SetBounds(0, 0, 320, 288);
          Preview.Align := TAlignLayout.Fit;
          FPreview := Preview;
          Preview.PaletteIndex := Palette.ItemIndex;
          Preview.DisableInterpolation := Scaling.ItemIndex = 0;
        end;
        if FPage = SETTINGS_PAGE_GBC then
          Check('RowLCDcolors', 'Video', 'ColorCorrection', False);
        if FPage in [SETTINGS_PAGE_GB, SETTINGS_PAGE_GBC] then
        begin
          Heading('GroupGBEnhancements');
          Check('RowGBFrameBlending', 'Video', 'FrameBlending', False);
          var PaletteLabels, PaletteValues: TArray<string>;
          SetLength(PaletteLabels, SCREEN_PALETTE_COUNT + 1);
          SetLength(PaletteValues, SCREEN_PALETTE_COUNT + 1);
          PaletteLabels[0] := Translate('Default palette');
          PaletteValues[0] := '-1';
          for var i := 0 to SCREEN_PALETTE_COUNT - 1 do
          begin
            PaletteLabels[i + 1] := ScreenPalettes[i].Name;
            PaletteValues[i + 1] := IntToStr(i);
          end;
          Combo('RowGBBGPalette', 'Video', 'BGPalette', PaletteLabels, PaletteValues, '-1');
          Combo('RowGBOBJ0Palette', 'Video', 'OBJ0Palette', PaletteLabels, PaletteValues, '-1');
          Combo('RowGBOBJ1Palette', 'Video', 'OBJ1Palette', PaletteLabels, PaletteValues, '-1');
          Check('RowGBShowBackground', 'Video', 'ShowBackground', True);
          Check('RowGBShowWindow', 'Video', 'ShowWindow', True);
          Check('RowGBShowSprites', 'Video', 'ShowSprites', True);
          Check('RowGBRemoveSpriteLimit', 'Video', 'RemoveSpriteLimit', False);
          var CPUPercent := Number('RowGBOverclock', 'Emulation', 'Overclock', 100, 400);
          CPUPercent.Min := 100;
          CPUPercent.Value := EnsureRange(CPUPercent.Value, 100, 400);
        end;
        if FPage = SETTINGS_PAGE_NES then
          Combo('RowNESregion', 'Video', 'Region', [], ['Auto', 'NTSC', 'PAL'], 'Auto');
        if FPage = SETTINGS_PAGE_SNES then
          Check('RowCropoverscan', 'Video', 'CropOverscan', False);
        if FPage in [SETTINGS_PAGE_GB, SETTINGS_PAGE_GBC] then
        begin
          Heading('GroupBootROM');
          var BootLabels, BootKeys: TArray<string>;
          SetLength(BootLabels, Ord(High(TGBBootModel)) + 1);
          SetLength(BootKeys, Length(BootLabels));
          for var Model := Low(TGBBootModel) to High(TGBBootModel) do
          begin
            BootLabels[Ord(Model)] := Translate(GB_BOOT_MODEL_LABELS[Model]);
            BootKeys[Ord(Model)] := GB_BOOT_MODEL_KEYS[Model];
          end;
          var BootModel := Combo('RowBootModel', 'Boot', 'Model', BootLabels, BootKeys, 'none');
          BootModel.OnChange := PortChange;
          var SelectedBoot := GBBootModel(FDrafts[FPage].ReadString('Boot', 'Model', 'none'));
          if SelectedBoot <> TGBBootModel.Skip then
            PathEdit('RowBootFile' + GB_BOOT_MODEL_KEYS[SelectedBoot], 'Boot',
              GB_BOOT_MODEL_KEYS[SelectedBoot] + 'File', '', False);
        end;
        if FPage = SETTINGS_PAGE_GBA then
        begin
          Heading('GroupBootROM');
          PathEdit('RowBootFileGBA', 'Boot', 'File', '', False);
          Heading('GroupGBACartridge');
          Combo('RowGBASaveType','Cartridge','SaveType',
            [Translate('Auto'), Translate('None'), Translate('SRAM'),
             Translate('Flash 64 KiB'), Translate('Flash 128 KiB'), Translate('EEPROM')],
            ['-1','0','1','2','3','4'],'-1');
          Number('RowGBASolarLevel','Cartridge','SolarLevel',128,255);
        end;
        Heading('GroupAudio');
        Check('RowAudio', 'Audio', 'Enabled', True);
        var VolumeRow := Row('RowVolume');
        var Volume := FindComponent('SettingsTrackBarVolumeTrack') as TSettingsTrackBar;
        Volume.OnChange := nil;
        var VolumeField := Field(Volume, 'Audio', 'Volume');
        VolumeField.Row := VolumeRow;
        VolumeField.DefaultValue := '0.5';
        Volume.Align := TAlignLayout.Client;
        FVolumeValue := FindComponent('LabelVolumeValue') as TLabel;
        Volume.Value := EnsureRange(FDrafts[FPage].ReadFloat('Audio', 'Volume', 0.5), 0, 1) * 100;
        Volume.OnChange := VolumeChange;
        VolumeChange(Volume);
        if FPage in [SETTINGS_PAGE_GB, SETTINGS_PAGE_GBC] then
          for var i := 1 to 4 do
            Number('RowGBChannel' + IntToStr(i) + 'Volume', 'Audio', 'Channel' + IntToStr(i) + 'Volume', 100, 100);
      end
      else if FCategory = SETTINGS_CATEGORY_CONTROLS then
      begin
        Heading('GroupController');
        var Count := 2;
        if (FPage <= SETTINGS_PAGE_GBC) or (FPage = SETTINGS_PAGE_GBA) then
          Count := 1;
        if (FPage = SETTINGS_PAGE_NES) and FDrafts[FPage].ReadBool('Input', 'FourScore', False) then
          Count := 4;
        if (FPage = SETTINGS_PAGE_SNES) and FDrafts[FPage].ReadBool('Input', 'Multitap2', False) then
          Count := 5;
        if (FPage = SETTINGS_PAGE_SNES) and FDrafts[FPage].ReadBool('Input', 'Multitap1', False) then
          Count := 8;
        FPlayer := EnsureRange(FPlayer, 0, Count - 1);
        Row('RowPlayer');
        var Player := FindComponent('SettingsComboBoxRowPlayerEditor') as TSettingsComboBox;
        Player.OnChange := nil;
        Player.Items.Clear;
        Player.Align := TAlignLayout.None;
        Player.SetBounds(16, 20, 220, 32);
        for var i := 1 to Count do
          Player.Items.Add(Translate('Player ') + IntToStr(i));
        Player.ItemIndex := FPlayer;
        Player.OnChange := PlayerChange;
        Player.OnResize := ComboResize;
        ComboResize(Player);
        BuildPort(FPlayer, Translate('Bindings · player ') + IntToStr(FPlayer + 1));
      end
      else
      begin
        if (FPage in [SETTINGS_PAGE_GB, SETTINGS_PAGE_GBC]) or (FPage=SETTINGS_PAGE_GBA) then
        begin
          Heading('GroupRumble');
          Check('RowRumble', 'Peripherals', 'Rumble', True);
        end;
        if FPage = SETTINGS_PAGE_NES then
        begin
          Heading('GroupAdditionalplayers');
          var FourScore := Check('RowFourScore', 'Input', 'FourScore', False);
          FourScore.OnSwitch := PortChange;
        end;
        if FPage = SETTINGS_PAGE_SNES then
        begin
          Heading('GroupAdditionalplayers');
          var Multi := Check('RowMultitapport2', 'Input', 'Multitap2', False);
          Multi.OnSwitch := PortChange;
          Multi := Check('RowMultitapport1', 'Input', 'Multitap1', False);
          Multi.OnSwitch := PortChange;
        end;
        BuildPort(0, Translate('Port 1'));
        if (FPage > SETTINGS_PAGE_GBC) and (FPage <> SETTINGS_PAGE_GBA) then
          BuildPort(1, Translate('Port 2'));
        if FPage = SETTINGS_PAGE_NES then
        begin
          Heading('GroupFamicomexpansionport');
          var Expansion := Combo('RowConnecteddevice', 'Ports', 'Expansion', [], ['auto', 'none', 'subor', 'famicom', 'recorder'], 'auto');
          Expansion.OnChange := PortChange;
          var Device := FDrafts[FPage].ReadString('Ports', 'Expansion', 'auto');
          if (Device = 'subor') or (Device = 'famicom') then
          begin
            Check('RowPhysicalkeyboard', 'Ports', 'KeyboardEnabled', True);
            BuildBindings(4, Device);
          end;
          if (Device = 'recorder') or (Device = 'famicom') then
            PathEdit('RowInitialcassette', 'Ports', 'TapeFile', '', False);
        end;
      end;
      LabelStatus.Text := Translate('Settings are saved separately for each platform. Core options apply when you next open a ROM.');
    end;
  finally
    FBuilding := False;
    VertScrollBoxScroll.EndUpdate;
    Resize;
    if PreserveScroll then
      VertScrollBoxScroll.ViewportPosition := TPointF.Create(0, EnsureRange(Position.Y, 0,
          Max(0, VertScrollBoxScroll.ContentBounds.Height - VertScrollBoxScroll.ClientHeight)))
    else
      VertScrollBoxScroll.ViewportPosition := TPointF.Zero;
    SearchChange(FSearch);
  end;
end;

procedure TSettingsView.RequestRebuild;
begin
  if FRebuildPending then
    Exit;

  FRebuildPending := True;
  var Alive: TFunc<Boolean> := FAlive;
  TThread.ForceQueue(nil,
    procedure
    begin
      if not Alive() then
        Exit;

      FRebuildPending := False;
      BuildPage(True);
    end);
end;

procedure TSettingsView.StorePage;
begin
  for var F in FFields do
  begin
    if F.Control is TComboBox then
    begin
      var Index := TComboBox(F.Control).ItemIndex;
      if (Index >= 0) and (Index < Length(F.Values)) then
        FDrafts[FPage].WriteString(F.Section, F.Key, F.Values[Index]);
    end
    else if F.Control is TSwitch then
      FDrafts[FPage].WriteBool(F.Section, F.Key, TSwitch(F.Control).IsChecked)
    else if F.Control is TSpinBox then
      FDrafts[FPage].WriteInteger(F.Section, F.Key, Round(TSpinBox(F.Control).Value))
    else if F.Control is TTrackBar then
      FDrafts[FPage].WriteFloat(F.Section, F.Key, TTrackBar(F.Control).Value / 100)
    else if F.Control is TEdit then
      FDrafts[FPage].WriteString(F.Section, F.Key, TEdit(F.Control).Text.Trim);
  end;
  if (FPage > SETTINGS_PAGE_MAIN) and (FInput <> nil) then
    SaveInputBindings(FInput, FDrafts[FPage]);
end;

procedure TSettingsView.Heading(const Name: string);
begin
  FGroup := FindComponent('Panel' + Name) as TPanel;
  FGroup.Parent := LayoutContent;
  FGroup.Visible := True;
  FGroup.Width := VertScrollBoxScroll.Width - 16;
  FGroup.TagString := (FindComponent('Label' + Name + 'Title') as TLabel).Text;
end;

function TSettingsView.Row(const Name: string): TPanel;
begin
  Result := FindComponent('Panel' + Name) as TPanel;
  Result.Parent := FGroup;
  Result.Visible := True;
  Result.TagObject := FindComponent('Label' + Name + 'Title');
  Result.TagString := TLabel(Result.TagObject).Text + ' ' +
    (FindComponent('Label' + Name + 'Detail') as TLabel).Text;
  Result.Width := VertScrollBoxScroll.Width - 16;
  Result.OnResize := RowResize;
  FHeight := FHeight + Result.Height + 8;
end;

function TSettingsView.Field(Control: TControl; const Section, Key: string): TSettingsField;
begin
  Result := TSettingsField.Create;
  Result.Control := Control;
  var Parent := Control.Parent;
  while (Parent <> nil) and not (Parent is TPanel) do
    Parent := Parent.Parent;
  Result.Row := Parent as TPanel;
  Result.Section := Section;
  Result.Key := Key;
  FFields.Add(Result);
  Control.Align := TAlignLayout.None;
  Control.OnResize := EditorResize;
  Control.SetBounds(16, 20, 220, 32);
end;

function TSettingsView.Combo(const Name, Section, Key: string; const Labels, Values: array of string; const Default: string): TComboBox;
begin
  Row(Name);
  Result := FindComponent('SettingsComboBox' + Name + 'Editor') as TSettingsComboBox;
  Result.OnChange := nil;
  if Length(Labels) > 0 then
  begin
    Result.Items.Clear;
    for var Caption in Labels do
      Result.Items.Add(Caption);
  end;
  var F := Field(Result, Section, Key);
  F.DefaultValue := Default;
  Result.OnResize := ComboResize;
  ComboResize(Result);
  SetLength(F.Values, Length(Values));
  var Current := FDrafts[FPage].ReadString(Section, Key, Default);
  var Selected := 0;
  for var i := 0 to Result.Items.Count - 1 do
  begin
    F.Values[i] := Values[i];
    if SameText(Current, Values[i]) then
      Selected := i;
  end;
  Result.ItemIndex := Selected;
end;

function TSettingsView.Check(const Name, Section, Key: string; Default: Boolean): TSwitch;
begin
  Row(Name);
  if Name = 'RowAutosaveonexit' then
    Result := FindComponent('SwitchAutosaveOnExit') as TSwitch
  else if Name = 'RowAutosaveeveryNminutes' then
    Result := FindComponent('SwitchAutosavePeriodic') as TSwitch
  else
    Result := FindComponent('Switch' + Name + 'Editor') as TSwitch;
  Result.OnSwitch := nil;
  Field(Result, Section, Key).DefaultValue := IntToStr(Ord(Default));
  Result.Width := 64;
  Result.IsChecked := FDrafts[FPage].ReadBool(Section, Key, Default);
end;

function TSettingsView.Number(const Name, Section, Key: string; Default, Max: Integer): TSpinBox;
begin
  Row(Name);
  Result := FindComponent('SettingsSpinBox' + Name + 'Editor') as TSettingsSpinBox;
  Field(Result, Section, Key).DefaultValue := IntToStr(Default);
  Result.Min := 0;
  Result.Max := Max;
  Result.ValueType := TNumValueType.Integer;
  Result.Value := EnsureRange(FDrafts[FPage].ReadInteger(Section, Key, Default), 0, Max);
end;

function TSettingsView.EditText(const Name, Section, Key, Default: string): TEdit;
begin
  Row(Name);
  Result := FindComponent('Edit' + Name + 'Editor') as TEdit;
  Field(Result, Section, Key).DefaultValue := Default;
  Result.Text := FDrafts[FPage].ReadString(Section, Key, Default);
end;

function TSettingsView.PathEdit(const Name, Section, Key, Default: string; Folder: Boolean): TEdit;
begin
  Result := EditText(Name, Section, Key, Default);
  {$IF Defined(ANDROID) or Defined(IOS)}
  Result.ReadOnly := True;
  {$ENDIF}
  var Browse := FindComponent('EditButton' + Name + 'Browse') as TEditButton;
  Browse.Hint := Translate('Choose file');
  if Folder then
    Browse.Hint := Translate('Choose folder');
  Browse.Tag := Ord(Folder);
  Browse.TagObject := Result;
  Browse.OnClick := PathClick;
end;

procedure TSettingsView.Resize;
begin
  if (csLoading in ComponentState) or FBuilding or (csDestroying in ComponentState) then
    Exit;

  inherited;
  if (LayoutBody = nil) or FArranging then
    Exit;

  FArranging := True;
  try
    PanelSidebar.Visible := Width >= 900;
    ListBoxNavigation.Visible := PanelSidebar.Visible;
    FPagePicker.Visible := not PanelSidebar.Visible;
    LabelTitle.Text := Translate(SettingsCategoryNames[FCategory]);
    if FCategory = SETTINGS_CATEGORY_GENERAL then
      LabelTitle.Text := Translate('General settings');
    LayoutCoreTabs.Visible := FCategory >= SETTINGS_CATEGORY_VIDEO_AUDIO;
    for var i := Low(FCategoryIcons) to High(FCategoryIcons) do
      if i = FCategory then
        TPath(FCategoryIcons[i]).Stroke.Color := $FFFFB344
      else
        TPath(FCategoryIcons[i]).Stroke.Color := $FFB9C2CC;
    LayoutHeader.Height := 60 + IfThen(LayoutCoreTabs.Visible, 48, 0) + IfThen(FPagePicker.Visible, 44, 0);
    FPagePicker.Align := TAlignLayout.None;
    FPagePicker.SetBounds(0, 48, LayoutHeader.Width, 32);
    LayoutCoreTabs.Align := TAlignLayout.None;
    LayoutCoreTabs.SetBounds(0, LayoutHeader.Height - 48, LayoutHeader.Width, 40);
    FSearch.Visible := LayoutHeader.Width >= 740;
    FSearch.SetBounds(Max(0, LayoutHeader.Width - 260), 0, 260, 32);
    var X: Single := 0;
    for var i in SettingsCoreOrder do
    begin
      FCoreButtons[i].Text := SettingsPageNames[i];
      case i of
        SETTINGS_PAGE_GB:
          FCoreButtons[i].Text := 'GB';
        SETTINGS_PAGE_GBC:
          FCoreButtons[i].Text := 'GBC';
        SETTINGS_PAGE_GBA:
          FCoreButtons[i].Text := 'GBA';
        SETTINGS_PAGE_NES:
          FCoreButtons[i].Text := 'NES';
        SETTINGS_PAGE_SNES:
          FCoreButtons[i].Text := 'SNES';
      end;
      if LayoutCoreTabs.Width < 600 then
        case i of
          SETTINGS_PAGE_MD:
            FCoreButtons[i].Text := 'MD';
          SETTINGS_PAGE_NEOGEO:
            FCoreButtons[i].Text := 'NG';
        end;
      var W := Max(32, Min(104, (LayoutCoreTabs.Width -
        (Length(SettingsCoreIds) - 1) * 7) / Length(SettingsCoreIds)));
      FCoreButtons[i].SetBounds(X, 0, W, 36);
      X := X + W + 7;
      if i = FCorePage then
        FCoreButtons[i].StyleLookup := 'buttonstyle_accent'
      else
        FCoreButtons[i].StyleLookup := 'buttonstyle';
    end;
    if LayoutContent = nil then
      Exit;

    LayoutContent.Width := Min(1240, Max(0, VertScrollBoxScroll.Width - 16));
    var Y: Single := 0;
    var LeftY: Single := 0;
    var Columns := (FCategory = SETTINGS_CATEGORY_VIDEO_AUDIO) and (FPreviewGroup <> nil) and (LayoutContent.Width >= 850);
    for var i := 0 to LayoutContent.ChildrenCount - 1 do
      if LayoutContent.Children[i] is TPanel then
      begin
        var C := TPanel(LayoutContent.Children[i]);
        if not C.Visible then
          Continue;

        C.Width := LayoutContent.Width;
        if Columns then
          if C = FPreviewGroup then
            C.Width := LayoutContent.Width * 0.38 - 8
          else
            C.Width := LayoutContent.Width * 0.62 - 8;
        ArrangeGroup(C);
        C.Position.X := 0;
        if Columns then
          if C = FPreviewGroup then
          begin
            C.Position.Point := TPointF.Create(LayoutContent.Width * 0.62 + 8, 0);
            Y := Max(Y, C.Height);
          end
          else
          begin
            C.Position.Y := LeftY;
            LeftY := LeftY + C.Height + 16;
            Y := Max(Y, LeftY);
          end
        else
        begin
          C.Position.Y := Y;
          Y := Y + C.Height + 16;
        end;
      end;
    LayoutContent.Height := Y;
    ButtonApply.SetBounds(Max(0, LayoutFooter.Width - 140), 52, 140, 40);
    ButtonBack.SetBounds(Max(0, LayoutFooter.Width - 260), 52, 108, 40);
    ButtonReset.SetBounds(0, 52, 160, 40);
    ButtonReset.Visible := LayoutFooter.Width >= 520;
    ButtonRefresh.SetBounds(176, 52, 176, 40);
    ButtonRefresh.Visible := (FCategory = SETTINGS_CATEGORY_CONTROLS) and (LayoutFooter.Width >= 700);
    ButtonCancelCapture.SetBounds(Max(0, LayoutFooter.Width - 150), 52, 150, 40);
    ButtonApply.Visible := FCaptureButton = nil;
    ButtonBack.Visible := FCaptureButton = nil;
  finally
    FArranging := False;
  end;
end;

procedure TSettingsView.ArrangeGroup(Group: TPanel);
begin
  var Y: Single := 14;
  if (FCategory = SETTINGS_CATEGORY_CONTROLS) and (Group.TagString = Translate('Controller')) and (Group.Width >= 850) then
  begin
    var Index := 0;
    Y := 132;
    for var i := 0 to Group.ChildrenCount - 1 do
      if (Group.Children[i] is TControl) and (Group.Children[i].Owner = Self) then
      begin
        var C := TControl(Group.Children[i]);
        if C is TPanel then
        begin
          var P := TPanel(C);
          // Player, device and source occupy the first row. Special-device
          // options stay below them, with room for their descriptions.
          if Index < 3 then
          begin
            P.Tag := 2;
            P.Padding.Rect := TRectF.Empty;
            P.SetBounds(16 + Index * (Group.Width - 32) / 3, 56, (Group.Width - 56) / 3, 64);
            var Text := TLayout(TLabel(P.TagObject).Parent);
            Text.Align := TAlignLayout.None;
            Text.Margins.Rect := TRectF.Empty;
            Text.SetBounds(0, 0, P.Width, 24);
            TControl(Text.Children[1]).Visible := False;
            for var J := 0 to P.ChildrenCount - 1 do
              if (P.Children[J] is TControl) and (P.Children[J].Owner = Self) and (P.Children[J] <> TLabel(P.TagObject).Parent) then
              begin
                var Editor := TControl(P.Children[J]);
                Editor.Align := TAlignLayout.None;
                Editor.Margins.Rect := TRectF.Empty;
                var W := P.Width;
                if Editor is TSwitch then
                  W := 64;
                Editor.SetBounds(P.Width - W, 32, W, 32);
              end;
          end
          else
          begin
            P.Tag := 0;
            P.Width := Max(0, Group.Width - 32);
            RowResize(P);
            P.SetBounds(16, Y, P.Width, P.Height);
            if P.Visible then
              Y := Y + P.Height + 6;
          end;
          Inc(Index);
        end
        else
          C.SetBounds(16, 14, Group.Width - 32, 36);
      end;
    Group.Height := Y + 12;
    Exit;
  end;
  for var i := 0 to Group.ChildrenCount - 1 do
    if (Group.Children[i] is TControl) and (Group.Children[i].Owner = Self) then
    begin
      var C := TControl(Group.Children[i]);
      C.Width := Max(0, Group.Width - 32);
      if C is TPanel then
      begin
        if C.Tag = 2 then
          C.Tag := 0;
        RowResize(C);
      end;
      if not C.Visible then
        Continue;

      C.SetBounds(16, Y, C.Width, C.Height);
      Y := Y + C.Height + 6;
    end;
  Group.Height := Y + 12;
end;

procedure TSettingsView.ContentResize(Sender: TObject);
begin
  Resize;
end;

procedure TSettingsView.EditorResize(Sender: TObject);
begin
  var C := TControl(Sender);
  if C.Height > 32 then
    C.Height := 32;
  if (C is TSwitch) and (C.Width > 64) then
    C.Width := 64;
end;

procedure TSettingsView.ComboResize(Sender: TObject);
begin
  EditorResize(Sender);
  var C := TComboBox(Sender);
  C.DisableMouseWheel := True;
  C.ItemHeight := C.Height;
  C.ListBox.ScrollAnimation := TBehaviorBoolean.True;
end;

procedure TSettingsView.RowResize(Sender: TObject);
begin
  var P := TPanel(Sender);
  if P.Tag in [1, 2] then
    Exit; // Device previews and the controller grid arrange themselves.

  P.Padding.Rect := TRectF.Create(16, 12, 16, 12);
  var Text := TLayout(TLabel(P.TagObject).Parent);
  Text.Align := TAlignLayout.None;
  Text.Margins.Rect := TRectF.Empty;
  if Text.ChildrenCount > 1 then
    TControl(Text.Children[1]).Visible := True;
  var Narrow := P.Width < 600;
  P.Height := IfThen(Narrow, 134, 72);
  var TextWidth := Max(0, P.Width - 32);
  // Explicit bounds keep editors centered without stretching them vertically.
  for var i := 0 to P.ChildrenCount - 1 do
    if (P.Children[i] is TControl) and (P.Children[i].Owner = Self) and (P.Children[i] <> TLabel(P.TagObject).Parent) then
    begin
      var C := TControl(P.Children[i]);
      var W: Single := 220;
      if C is TSwitch then
        W := 64
      else if C is TLayout then
        W := 268;
      if Narrow and not (C is TSwitch) then
        W := TextWidth;
      W := Min(W, Max(0, P.Width - 32));
      C.Align := TAlignLayout.None;
      C.Margins.Rect := TRectF.Empty;
      var Top := (P.Height - 32) / 2;
      if Narrow then
        Top := P.Height - 44;
      C.SetBounds(Max(16, P.Width - 16 - W), Top, W, 32);
      if not Narrow then
        TextWidth := Max(0, P.Width - 48 - W);
    end;
  Text.SetBounds(16, 12, TextWidth, IfThen(Narrow, 70, 48));
end;

procedure TSettingsView.DeviceResize(Sender: TObject);
begin
  var P := TPanel(Sender);
  for var D in FDevices do
    if (D.Assignments <> nil) and (D.Assignments.Parent = P) then
    begin
      D.Assignments.Visible := P.Width >= 850;
      if D.Diagram is TDeviceCallouts then
        TDeviceCallouts(D.Diagram).ShowAnnotations(not D.Assignments.Visible);
    end;
end;

procedure TSettingsView.BindingFooterResize(Sender: TObject);
begin
  var Footer := TLayout(Sender);
  var Caption := TLabel(Footer.Children[0]);
  var Editors := TLayout(Footer.Children[1]);
  if Footer.Width < 600 then
  begin
    Caption.Align := TAlignLayout.Top;
    Caption.Height := 24;
    Editors.Align := TAlignLayout.Bottom;
    Editors.Height := 32;
    Editors.Margins.Top := 0;
    Editors.Margins.Bottom := 0;
  end
  else
  begin
    Caption.Align := TAlignLayout.Client;
    Editors.Align := TAlignLayout.Right;
    Editors.Width := 268;
    Editors.Margins.Top := 14;
    Editors.Margins.Bottom := 14;
  end;
end;

procedure TSettingsView.SelectCategory(Index: Integer);
begin
  if FBuilding or (Index < Low(SettingsCategoryNames)) or (Index > High(SettingsCategoryNames)) or (Index = FCategory) then
    Exit;

  StorePage;
  FCategory := Index;
  if Index < SETTINGS_CATEGORY_VIDEO_AUDIO then
    FPage := SETTINGS_PAGE_MAIN
  else
    FPage := FCorePage;
  FBuilding := True;
  try
    ListBoxNavigation.ItemIndex := Index;
    FPagePicker.ItemIndex := Index;
  finally
    FBuilding := False;
  end;
  FSearch.Text := '';
  BuildPage;
end;

procedure TSettingsView.SelectCore(Index: Integer; PreserveCategory: Boolean);
begin
  if FBuilding or (Index < Low(SettingsCoreIds)) or (Index > High(SettingsCoreIds)) then
    Exit;

  StorePage;
  FCorePage := Index;
  FPlayer := 0;
  if (FCategory < SETTINGS_CATEGORY_VIDEO_AUDIO) and not PreserveCategory then
    FCategory := SETTINGS_CATEGORY_VIDEO_AUDIO;
  if FCategory < SETTINGS_CATEGORY_VIDEO_AUDIO then
    FPage := SETTINGS_PAGE_MAIN
  else
    FPage := FCorePage;
  FBuilding := True;
  try
    ListBoxNavigation.ItemIndex := FCategory;
    FPagePicker.ItemIndex := FCategory;
  finally
    FBuilding := False;
  end;
  BuildPage;
end;

procedure TSettingsView.NavigationChange(Sender: TObject);
begin
  // TListBox.OnChange passes the selected item as Sender.
  SelectCategory(ListBoxNavigation.ItemIndex);
end;

procedure TSettingsView.PagePickerChange(Sender: TObject);
begin
  SelectCategory(FPagePicker.ItemIndex);
end;

procedure TSettingsView.CoreClick(Sender: TObject);
begin
  SelectCore(TButton(Sender).Tag);
end;

procedure TSettingsView.SearchChange(Sender: TObject);
begin
  if FBuilding or (LayoutContent = nil) then
    Exit;

  var Query := FSearch.Text.Trim.ToLower;
  for var i := 0 to LayoutContent.ChildrenCount - 1 do
    if LayoutContent.Children[i] is TPanel then
    begin
      var Group := TPanel(LayoutContent.Children[i]);
      var ShowGroup := Query = '';
      for var J := 0 to Group.ChildrenCount - 1 do
        if Group.Children[J] is TPanel then
        begin
          var Row := TPanel(Group.Children[J]);
          Row.Visible := (Query = '') or Row.TagString.ToLower.Contains(Query) or Group.TagString.ToLower.Contains(Query);
          ShowGroup := ShowGroup or Row.Visible;
        end;
      Group.Visible := ShowGroup;
    end;
  Resize;
end;

procedure TSettingsView.PlayerChange(Sender: TObject);
begin
  if FBuilding then
    Exit;

  StorePage;
  FPlayer := TComboBox(Sender).ItemIndex;
  RequestRebuild;
end;

procedure TSettingsView.BuildPort(Port: Integer; const Caption: string);
begin
  if FCategory <> SETTINGS_CATEGORY_CONTROLS then
    Heading('GroupPort' + IntToStr(Port + 1));
  var Key := 'Port' + IntToStr(Port + 1);
  var Device := FDrafts[FPage].ReadString('Ports', Key, 'auto');
  var C: TComboBox;
  if (FPage <= SETTINGS_PAGE_GBC) or (FPage = SETTINGS_PAGE_GBA) then
    C := Combo('RowControllerPort' + IntToStr(Port + 1), 'Ports', Key, [], ['pad', 'none'], 'pad')
  else if FPage = SETTINGS_PAGE_MD then
    C := Combo('RowConnecteddevice2Port' + IntToStr(Port + 1), 'Ports', Key, [], ['pad6', 'pad3', 'none'], 'pad6')
  else if (FPage = SETTINGS_PAGE_NES) and (Port = 0) then
    C := Combo('RowConnecteddevice10Port' + IntToStr(Port + 1), 'Ports', Key, [], ['auto', 'pad', 'paddendy', 'piano', 'none'], 'auto')
  else if (FPage = SETTINGS_PAGE_NES) and (Port = 1) then
    C := Combo('RowConnecteddevice18Port' + IntToStr(Port + 1), 'Ports', Key, [], ['auto', 'pad', 'paddendy', 'zapper', 'powerpad', 'none'], 'auto')
  else if FPage = SETTINGS_PAGE_NES then
    C := Combo('RowConnecteddevice26Port' + IntToStr(Port + 1), 'Ports', Key,
      ['Gamepad', 'Dendy · Turbo', 'None'], ['pad', 'paddendy', 'none'], 'pad')
  else
    C := Combo('RowConnecteddevice26Port' + IntToStr(Port + 1), 'Ports', Key,
      ['Gamepad', 'None'], ['pad', 'none'], 'pad');
  // Normalize absent legacy values to the device displayed by the selector.
  for var F in FFields do
    if F.Control = C then
      Device := F.Values[C.ItemIndex];
  C.OnChange := PortChange;
  if FCategory = SETTINGS_CATEGORY_CONTROLS then
    BuildBindings(Port, Device);
end;

procedure TSettingsView.BuildBindings(Port: Integer; const Device: string);
begin
  if Device = 'none' then
    Exit;

  var Labels, Values: TArray<string>;
  var Devices: TArray<TInputDevice>;
  if FInput <> nil then
    Devices := FInput.Devices;
  SetLength(Labels, Length(Devices) + 1);
  SetLength(Values, Length(Labels));
  Labels[0] := Translate('All devices');
  Values[0] := '';
  for var i := 0 to High(Devices) do
  begin
    Labels[i + 1] := Devices[i].Name;
    if Devices[i].Id = SystemKeyboardId then
      Labels[i + 1] := Translate('Keyboard')
    else if Devices[i].Id = SystemMouseId then
      Labels[i + 1] := Translate('Mouse');
    Values[i + 1] := Devices[i].Id;
  end;
  var SourceKey := 'Source' + IntToStr(Port + 1);
  if (FPage = SETTINGS_PAGE_NES) and (Port = 4) then
    SourceKey := 'SourceExpansion';
  var SavedId := FDrafts[FPage].ReadString('Ports', SourceKey, '');
  var Found := SavedId = '';
  for var Id in Values do
    if Id = SavedId then
      Found := True;
  if not Found then
  begin
    var N := Length(Labels);
    SetLength(Labels, N + 1);
    SetLength(Values, N + 1);
    Labels[N] := Translate('Disconnected device');
    Values[N] := SavedId;
  end;
  var Source := Combo('RowInputsource' + IntToStr(Port), 'Ports', SourceKey, Labels, Values, '');
  FDeviceIds[Port] := SavedId;
  Source.Tag := Port;
  Source.OnChange := DeviceChange;
  Source.Enabled := FInput <> nil;
  if (Device = 'piano') then
  begin
    Check('RowPhysicalkeyboard2' + IntToStr(Port), 'Ports', 'KeyboardEnabled', True);
  end;
  if Device = 'zapper' then
    AddBinding(Translate('Zapper trigger'), ZapperTriggerAction, Port)
  else
    BuildDevice(Port, Device);
end;

function TSettingsView.AddBinding(const Caption: string; Action, Port: Integer): TButton;
begin
  var P := Row('RowBinding' + IntToStr(Port));
  var B := FindComponent('ButtonBindingEditorsCapture' + IntToStr(Port)) as TButton;
  B.Text := Translate('Assign · ') + BindingCaption(FInput, Action);
  B.Tag := Action;
  B.TagString := IntToStr(Port);
  B.TagObject := P.TagObject;
  B.OnClick := CaptureClick;
  B.Enabled := FInput <> nil;
  var Clear := FindComponent('ButtonBindingEditorsClear' + IntToStr(Port)) as TButton;
  Clear.Tag := Action;
  Clear.OnClick := ClearBindingClick;
  Clear.Enabled := FInput <> nil;
  Result := B;
end;

procedure TSettingsView.BuildDevice(Port: Integer; const Device: string);
begin
  Heading('GroupBindings' + IntToStr(Port));
  var D := TSettingsDevice.Create;
  FDevices.Add(D);
  D.Port := Port;
  D.Device := Device;
  var P := Row('RowButtonbindings' + IntToStr(Port));
  P.Tag := 1;
  P.Height := 340;
  var Text := TLayout(TLabel(P.TagObject).Parent);
  Text.Align := TAlignLayout.Top;
  Text.Height := 34;
  TControl(Text.Children[1]).Visible := False;
  if Device = 'powerpad' then
  begin
    var Pad := TNesPowerPad.Create(P);
    Pad.OnChange := VirtualDeviceChange;
    D.Control := Pad;
    var Diagram := TDeviceCallouts.Create(P);
    Diagram.Configure(Pad, FInput, ROM_SYSTEM_NES, Port, CalloutClick);
    D.Diagram := Diagram;
    P.Height := 448;
  end
  else if Device = 'subor' then
  begin
    var Keyboard := TNesSuborKeyboard.Create(P);
    Keyboard.OnChange := VirtualDeviceChange;
    D.Control := Keyboard;
  end
  else if Device = 'famicom' then
  begin
    var Keyboard := TNesFamicomKeyboard.Create(P);
    Keyboard.OnChange := VirtualDeviceChange;
    D.Control := Keyboard;
  end
  else if Device = 'piano' then
  begin
    var Piano := TNesMiraclePiano.Create(P);
    Piano.OnChange := VirtualDeviceChange;
    D.Control := Piano;
  end
  else
  begin
    var Pad := TScreenGamepad.Create(P);
    case FPage of
      SETTINGS_PAGE_GB:
        Pad.Layout := TScreenGamepadLayout.GameBoy;
      SETTINGS_PAGE_GBC:
        Pad.Layout := TScreenGamepadLayout.GameBoyColor;
      SETTINGS_PAGE_GBA:
        Pad.Layout := TScreenGamepadLayout.GameBoyAdvance;
      SETTINGS_PAGE_NES:
        if Device = 'paddendy' then
          Pad.Layout := TScreenGamepadLayout.Dendy
        else
          Pad.Layout := TScreenGamepadLayout.Nes;
      SETTINGS_PAGE_MD:
        Pad.Layout := TScreenGamepadLayout.Sega;
      SETTINGS_PAGE_SNES:
        Pad.Layout := TScreenGamepadLayout.Snes;
      SETTINGS_PAGE_NEOGEO:
        Pad.Layout := TScreenGamepadLayout.NeoGeo;
    end;
    Pad.ButtonMask := CoreButtons(SettingsCoreIds[FPage], Device);
    Pad.OnChange := VirtualDeviceChange;
    D.Control := Pad;
    var Diagram := TDeviceCallouts.Create(P);
    Diagram.Configure(Pad, FInput, SettingsCoreIds[FPage], Port, CalloutClick);
    D.Diagram := Diagram;
    P.Height := 460;
  end;
  var Preview := D.Control;
  if D.Diagram <> nil then
    Preview := D.Diagram;
  (FindComponent('VertScrollBoxPadAssignments' + IntToStr(Port)) as TControl).Visible := False;
  if D.Control is TScreenGamepad then
  begin
    D.Assignments := FindComponent('VertScrollBoxPadAssignments' + IntToStr(Port)) as TVertScrollBox;
    D.Assignments.Visible := True;
    D.AssignmentList := FindComponent('LayoutPadAssignmentList' + IntToStr(Port)) as TLayout;
    var Y: Single := 8;
    for var B in TScreenGamepad(D.Control).ButtonMask do
    begin
      var Binding := SettingsButton(P);
      Binding.Parent := D.AssignmentList;
      Binding.SetBounds(8, Y, D.AssignmentList.Width - 16, 32);
      Binding.Tag := PadAction(Port, B);
      Binding.TagObject := D;
      Binding.TagString := CoreButtonName(SettingsCoreIds[FPage], B);
      Binding.Text := Binding.TagString + '   ·   ' + BindingCaption(FInput, Binding.Tag);
      Binding.OnClick := AssignmentClick;
      Binding.Enabled := FInput <> nil;
      Y := Y + 40;
    end;
    D.AssignmentList.Height := Y;
  end;
  Preview.Parent := P;
  Preview.Align := TAlignLayout.Client;
  Preview.Margins.Top := 8;
  Preview.Margins.Bottom := 8;
  D.Control.Tag := Port;
  // Keep the editor inside this card. No button is selected until the user clicks.
  var Footer := FindComponent('LayoutBindingFooter' + IntToStr(Port)) as TLayout;
  D.Caption := FindComponent('LabelBindingCaption' + IntToStr(Port)) as TLabel;
  D.Caption.Text := '';
  D.Capture := FindComponent('ButtonPadEditorsCapture' + IntToStr(Port)) as TButton;
  D.Capture.Text := Translate('Assign');
  D.Capture.Tag := -1;
  D.Capture.TagString := IntToStr(Port);
  D.Capture.TagObject := D.Caption;
  D.Capture.OnClick := CaptureClick;
  D.Capture.Enabled := FInput <> nil;
  D.Capture.Visible := False;
  D.Clear := FindComponent('ButtonPadEditorsClear' + IntToStr(Port)) as TButton;
  D.Clear.Tag := -1;
  D.Clear.OnClick := ClearBindingClick;
  D.Clear.Enabled := FInput <> nil;
  D.Clear.Visible := False;
  Footer.OnResize := BindingFooterResize;
  BindingFooterResize(Footer);
  P.OnResize := DeviceResize;
  DeviceResize(P);
end;

procedure TSettingsView.RefreshBindings;
begin
  for var D in FDevices do
  begin
    if D.Diagram is TDeviceCallouts then
      TDeviceCallouts(D.Diagram).Refresh;
    if D.AssignmentList <> nil then
      for var i := 0 to D.AssignmentList.ChildrenCount - 1 do
        if D.AssignmentList.Children[i] is TButton then
        begin
          var B := TButton(D.AssignmentList.Children[i]);
          B.Text := B.TagString + '   ·   ' + BindingCaption(FInput, B.Tag);
        end;
    if (D.Capture.Tag >= 0) and (D.Capture <> FCaptureButton) then
      D.Capture.Text := Translate('Assign · ') + BindingCaption(FInput, D.Capture.Tag);
  end;
end;

procedure TSettingsView.SelectBinding(Device: TSettingsDevice; Action: Integer; const Caption: string);
begin
  CancelCapture;
  Device.Capture.Tag := Action;
  Device.Clear.Tag := Action;
  Device.Caption.Text := Caption;
  Device.Capture.Text := Translate('Assign · ') + BindingCaption(FInput, Action);
  Device.Capture.Visible := True;
  Device.Clear.Visible := True;
  CaptureClick(Device.Capture);
end;

procedure TSettingsView.AssignmentClick(Sender: TObject);
begin
  var B := TButton(Sender);
  SelectBinding(TSettingsDevice(B.TagObject), B.Tag, Translate('Button ') + B.TagString);
end;

procedure TSettingsView.CalloutClick(Sender: TObject);
begin
  if FBuilding or (FInput = nil) then
    Exit;

  var LabelControl := TLabel(Sender);
  for var D in FDevices do
    if D.Diagram = LabelControl.Parent then
    begin
      SelectBinding(D, LabelControl.Tag, LabelControl.TagString);
      Exit;
    end;
end;

procedure TSettingsView.VirtualDeviceChange(Sender: TObject);
const
  Mapping: array[TNesButton] of TEmulatorButton = (TEmulatorButton.A,
    TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
    TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right);
  Notes: array[0..11] of string = ('C', 'C♯', 'D', 'D♯', 'E', 'F', 'F♯', 'G', 'G♯', 'A', 'A♯', 'B');
begin
  if FBuilding or (FInput = nil) then
    Exit;

  for var D in FDevices do
    if D.Control = Sender then
    begin
      var Action := -1;
      var Caption := '';
      if Sender is TScreenGamepad then
        for var B in TScreenGamepad(Sender).Buttons do
          if B in CoreButtons(SettingsCoreIds[FPage], D.Device) then
          begin
            Action := PadAction(D.Port, B);
            Caption := Translate('Button ') + CoreButtonName(SettingsCoreIds[FPage], B);
            Break;
          end;

      if Sender is TNesPowerPad then
        for var B in TNesPowerPad(Sender).Buttons do
        begin
          Action := PowerPadAction + B - 1;
          Caption := Translate('Pad ') + IntToStr(B);
          Break;
        end;

      if Sender is TNesSuborKeyboard then
        for var K in TNesSuborKeyboard(Sender).Keys do
        begin
          Action := SuborAction + Ord(K);
          Caption := Translate('Key ') + Copy(GetEnumName(TypeInfo(TSuborKey), Ord(K)), 3, MaxInt);
          Break;
        end;

      if Sender is TNesFamicomKeyboard then
        for var K in TNesFamicomKeyboard(Sender).Keys do
        begin
          Action := FamicomAction + Ord(K);
          Caption := Translate('Key ') + Copy(GetEnumName(TypeInfo(TFamicomKey), Ord(K)), 3, MaxInt);
          Break;
        end;

      if Sender is TNesMiraclePiano then
      begin
        for var K in TNesMiraclePiano(Sender).Keys do
        begin
          Action := PianoAction + K;
          if K < 49 then
            Caption := Translate('Note ') + Notes[K mod 12] + IntToStr(2 + K div 12)
          else
            Caption := Translate('Piano button ') + IntToStr(K);
          Break;
        end;

        if Action < 0 then
          for var B in TNesMiraclePiano(Sender).Buttons do
          begin
            Action := PadAction(0, Mapping[B]);
            Caption := Translate('Button ') + CoreButtonName(ROM_SYSTEM_NES, Mapping[B]);
            Break;
          end;
      end;
      if Action < 0 then
        Exit;

      SelectBinding(D, Action, Caption);
      Exit;
    end;
end;

procedure TSettingsView.DeviceChange(Sender: TObject);
begin
  if FBuilding then
    Exit;

  var C := TComboBox(Sender);
  for var F in FFields do
    if F.Control = C then
      FDeviceIds[C.Tag] := F.Values[C.ItemIndex];
end;

procedure TSettingsView.RefreshDevicesClick(Sender: TObject);
begin
  CancelCapture;
  StorePage;
  FInput.Refresh;
  RequestRebuild;
end;

procedure TSettingsView.PortChange(Sender: TObject);
begin
  if FBuilding then
    Exit;

  StorePage;
  RequestRebuild;
end;

procedure TSettingsView.CaptureClick(Sender: TObject);
begin
  if (FInput = nil) or (TButton(Sender).Tag < 0) then
    Exit;

  CancelCapture;
  FCaptureButton := TButton(Sender);
  FCaptureAction := FCaptureButton.Tag;
  var Port := StrToIntDef(FCaptureButton.TagString, 0);
  FHostInput.Poll;
  FInput.BeginCapture(FCaptureAction, FDeviceIds[Port]);
  FCaptureDeadline := TThread.GetTickCount64 + 10000;
  LabelStatus.Text := Translate('Press a button or direction. Esc cancels. Waiting: 10 seconds.');
  FCaptureButton.Text := Translate('Waiting for input…');
  ButtonCancelCapture.Visible := True;
  Resize;
end;

procedure TSettingsView.ClearBindingClick(Sender: TObject);
begin
  CancelCapture;
  FInput.RemoveBindings(TButton(Sender).Tag);
  StorePage;
  RefreshBindings;
  LabelStatus.Text := Translate('Binding removed. Click Apply.');
  Resize;
end;

procedure TSettingsView.CancelCapture;
begin
  if FInput <> nil then
    FInput.CancelCapture;
  if FCaptureButton <> nil then
    FCaptureButton.Text := Translate('Assign · ') + BindingCaption(FInput, FCaptureAction);
  FCaptureButton := nil;
  if ButtonCancelCapture <> nil then
    ButtonCancelCapture.Visible := False;
end;

procedure TSettingsView.CancelCaptureClick(Sender: TObject);
begin
  CancelCapture;
  LabelStatus.Text := Translate('Binding cancelled.');
  Resize;
end;

function TSettingsView.HandleCaptureKeyDown(var Key: Word; var KeyChar: WideChar): Boolean;
begin
  Result := FCaptureButton <> nil;
  if not Result then
    Exit;

  // Native input captures the physical key. Do not also let the focused editor
  // change the source, move focus, or restart capture with Enter/Space.
  if Key = vkEscape then
    CancelCaptureClick(Self);
  Key := 0;
  KeyChar := #0;
end;

procedure TSettingsView.Poll;
begin
  if FInput = nil then
    Exit;

  FInput.Enabled := FHostInput.Enabled;
  FInput.Poll;
  if FCaptureButton = nil then
    Exit;

  var Binding: TInputBinding;
  if FInput.TakeCaptured(Binding) then
  begin
    if (Binding.Kind = TInputElementKind.Key) and (Binding.Code = 41) then
    begin
      CancelCaptureClick(Self);
      Exit;
    end;

    FInput.RemoveBindings(FCaptureAction);
    FInput.AddBinding(Binding);
    CancelCapture;
    RefreshBindings;
    LabelStatus.Text := Translate('Binding saved in the draft. Click Apply.');
    Resize;
  end
  else if TThread.GetTickCount64 >= FCaptureDeadline then
    CancelCaptureClick(Self);
end;

procedure TSettingsView.VolumeChange(Sender: TObject);
begin
  if FVolumeValue <> nil then
    FVolumeValue.Text := IntToStr(Round(TTrackBar(Sender).Value)) + '%';
end;

procedure TSettingsView.AutosaveToggle(Sender: TObject);
begin
  if FAutosaveMinutes <> nil then
    FAutosaveMinutes.Enabled := TSwitch(Sender).IsChecked;
end;

procedure TSettingsView.PreviewChange(Sender: TObject);
begin
  if FPreview is TSettingsPreview then
  begin
    var Preview := TSettingsPreview(FPreview);
    Preview.PaletteIndex := (FindComponent('SettingsComboBoxRowGameBoypaletteEditor') as TComboBox).ItemIndex;
    Preview.DisableInterpolation := (FindComponent('SettingsComboBoxRowImagescalingEditor') as TComboBox).ItemIndex = 0;
  end;
end;

procedure TSettingsView.ResetClick(Sender: TObject);
begin
  CancelCapture;
  for var Field in FFields do
    FDrafts[FPage].WriteString(Field.Section, Field.Key, Field.DefaultValue);
  if (FCategory = SETTINGS_CATEGORY_CONTROLS) and (FInput <> nil) then
  begin
    FDrafts[FPage].DeleteKey('FMXInput', 'Bindings');
    LoadInputBindings(FInput, FDrafts[FPage], SettingsCoreIds[FPage]);
    SaveInputBindings(FInput, FDrafts[FPage]);
  end;
  BuildPage;
  LabelStatus.Text := Translate('Section reset. Click Apply to save.');
end;

procedure TSettingsView.PathClick(Sender: TObject);
begin
  CancelCapture;
  var Button := TEditButton(Sender);
  var Edit := TEdit(Button.TagObject);
  var Section, Key: string;
  for var F in FFields do
    if F.Control = Edit then
    begin
      Section := F.Section;
      Key := F.Key;
      Break;
    end;

  var Page := FPage;
  var Alive: TFunc<Boolean> := FAlive;
  FPickingBootROM := Section = 'Boot';
  FPickingTranslation := (Section = 'General') and (Key = 'TranslationFile');
  PickLocation(Button.Tag = 1, Edit.Text,
    procedure(const Selection: TStorageSelection)
    begin
      if not Alive() then
        Exit;

      if Selection.Error <> '' then
        LabelStatus.Text := Selection.Error
      else if not Selection.Cancelled then
      begin
        FDrafts[Page].WriteString(Section, Key, Selection.Location);
        if FPage = Page then
          for var F in FFields do
            if (F.Section = Section) and (F.Key = Key) then
              TEdit(F.Control).Text := Selection.Location;
        LabelStatus.Text := Translate('Click Apply to save changes.');
        if (Section = 'General') and (Key = 'Path') then
          CheckRomFolder(Selection.Location);
      end;
    end);
end;

procedure TSettingsView.CheckRomFolder(const Location: string);
begin
  var SupportedFolders := '';

  {$IFDEF ANDROID}
  // Document provider URIs must be queried; combining them with a name is invalid.
  if Location.StartsWith('content://') then
    for var Folder in TAndroidStorage.Enumerate(Location, False, True) do
      for var RomSystem := TRomSystem.NES to High(TRomSystem) do
        if SameText(Folder.Name, RomSystemFolder(RomSystem)) then
          Exit;
  {$ENDIF}

  for var RomSystem := TRomSystem.NES to High(TRomSystem) do
  begin
    var Name := RomSystemFolder(RomSystem);
    {$IFDEF ANDROID}
    if not Location.StartsWith('content://') then
    {$ENDIF}
      if FStorage.FolderExists(System.IOUtils.TPath.Combine(Location, Name)) then
        Exit;

    if SupportedFolders <> '' then
      SupportedFolders := SupportedFolders + ', ';
    SupportedFolders := SupportedFolders + Name;
  end;
  var Warning := Format(Translate('The selected folder contains no supported platform subfolders. ROMs must be placed in these subfolders: %s.'),
    [SupportedFolders]);
  LabelStatus.Text := Warning;
  ShowRetroMessage(Self, Warning, TRetroDialogKind.Warning);
end;

procedure TSettingsView.PickLocation(Folder: Boolean; const Current: string; const Callback: TStorageSelectionCallback);
begin
  if Assigned(FPicker) then
  begin
    FPicker(Folder, Current, Callback);
    Exit;
  end;

  var Dialog := TFMXOpenDialog.Create(nil);
  try
    Dialog.MultipleSelection := False;
    Dialog.InitialDirectory := Current;
    if not Folder then
      Dialog.InitialDirectory := ExtractFilePath(Current);
    Dialog.Title := Translate('Choose ROM folder');
    if not Folder then
    begin
      if FPickingTranslation then
      begin
        Dialog.Title := Translate('Choose translation file');
        Dialog.Filter := Translate('Translation files (*.txt;*.lng)|*.txt;*.lng|All files|*.*');
      end
      else if FPickingBootROM then
      begin
        Dialog.Title := Translate('Choose boot ROM');
        Dialog.Filter := 'Boot ROM (*.bin;*.rom;*.gb)|*.bin;*.rom;*.gb|All files|*.*';
      end
      else
      begin
        Dialog.Title := Translate('Choose cassette');
        Dialog.Filter := Translate('Cassettes (*.tape)|*.tape|All files|*.*');
      end;
      Dialog.FileMustExist := True;
    end;
    var Completion: TFMXSelectionCallback :=
      procedure(const Selection: TFMXSelectionResult)
      begin
        var Result := Default(TStorageSelection);
        Result.Cancelled := Selection.Status = TFMXSelectionStatus.Cancelled;
        Result.Error := Selection.Error;
        if Selection.Status = TFMXSelectionStatus.Selected then
          Result.Location := Selection.Locations[0];
        Callback(Result);
      end;
    if Folder then
      Dialog.SelectFolder(Completion)
    else
      Dialog.SelectFiles(Completion);
  finally
    Dialog.Free;
  end;
end;

procedure TSettingsView.PickTemplateLocation(const Callback: TStorageSelectionCallback);
begin
  if Assigned(FTemplatePicker) then
  begin
    FTemplatePicker('lang_template.txt', Callback);
    Exit;
  end;
  var Dialog := TFMXOpenDialog.Create(nil);
  try
    Dialog.Title := Translate('Save translation template');
    Dialog.Filter := Translate('Text files (*.txt)|*.txt|All files|*.*');
    Dialog.MimeType := 'text/plain';
    Dialog.SaveFile('lang_template.txt',
      procedure(const Selection: TFMXSelectionResult)
      begin
        var Result := Default(TStorageSelection);
        Result.Cancelled := Selection.Status = TFMXSelectionStatus.Cancelled;
        Result.Error := Selection.Error;
        if Selection.Status = TFMXSelectionStatus.Selected then
          Result.Location := Selection.Locations[0];
        Callback(Result);
      end);
  finally
    Dialog.Free;
  end;
end;

procedure TSettingsView.SaveTemplateClick(Sender: TObject);
begin
  CancelCapture;
  var Alive: TFunc<Boolean> := FAlive;
  try
    PickTemplateLocation(
      procedure(const Selection: TStorageSelection)
      begin
        if not Alive() or Selection.Cancelled then
          Exit;
        try
          if Selection.Error <> '' then
            raise Exception.Create(Selection.Error);
          FormStyles.SaveTranslationTemplate(FStorage, Selection.Location);
          LabelStatus.Text := Translate('Translation template saved.');
        except
          on E: Exception do
            LabelStatus.Text := Translate('Unable to save translation template: ') + E.Message;
        end;
      end);
  except
    on E: Exception do
      LabelStatus.Text := Translate('Unable to save translation template: ') + E.Message;
  end;
end;

procedure TSettingsView.ApplyClick(Sender: TObject);
begin
  try
    CancelCapture;
    StorePage;
    var Translation := FormStyles.LoadTranslation(FStorage,
      FDrafts[SETTINGS_PAGE_MAIN].ReadString('General', 'TranslationFile', '').Trim,
      FDrafts[SETTINGS_PAGE_MAIN].ReadString('General', 'Language', 'en'));
    Translation.Free; // Validate the file before writing any settings.
    var Folder := FDrafts[SETTINGS_PAGE_MAIN].ReadString('General', 'Path', '').Trim;

    {$IF not Defined(ANDROID) and not Defined(IOS)}
    if (Folder <> '') and not TDirectory.Exists(Folder) then
      raise Exception.Create(Translate('ROM folder not found. Choose an existing folder.'));
    {$ENDIF}

    if FDrafts[SETTINGS_PAGE_NES].ReadBool('Input', 'FourScore', False) and
      ((FDrafts[SETTINGS_PAGE_NES].ReadString('Ports', 'Port1', 'auto') = 'piano') or
      (FDrafts[SETTINGS_PAGE_NES].ReadString('Ports', 'Port2', 'auto') = 'zapper') or
      (FDrafts[SETTINGS_PAGE_NES].ReadString('Ports', 'Port2', 'auto') = 'powerpad')) then
      raise Exception.Create(Translate('Disable Four Score to use Zapper, Power Pad or Miracle Piano.'));

    if (FDrafts[SETTINGS_PAGE_NES].ReadString('Ports', 'Port1', 'auto') = 'piano') and
      ((FDrafts[SETTINGS_PAGE_NES].ReadString('Ports', 'Port2', 'auto') = 'zapper') or
      (FDrafts[SETTINGS_PAGE_NES].ReadString('Ports', 'Port2', 'auto') = 'powerpad')) then
      raise Exception.Create(Translate('Miracle Piano uses both ports. Disconnect Zapper or Power Pad.'));

    // Config writes are per core and retain all settings that this UI does not expose.
    for var Ini in FDrafts do
      FStorage.WriteConfig(Ini);
    FStorage.RomFolder := Folder;
    if Assigned(FOnApply) then
      FOnApply(Self);
    LabelStatus.Text := Translate('Saved. Core options and connected devices apply when you next open a ROM.');
  except
    on E: Exception do
      LabelStatus.Text := Translate('Unable to save settings: ') + E.Message;
  end;
end;

procedure TSettingsView.ApplyLanguage(const PreviousLanguage: string);
begin
  FBuilding := True;
  try
    FormStyles.RelocalizeUI(Self, PreviousLanguage);
    FormStyles.RelocalizeUI(LayoutComponentStore, PreviousLanguage);
  finally
    FBuilding := False;
  end;
  BuildPage(True);
end;

procedure TSettingsView.BackClick(Sender: TObject);
begin
  CancelCapture;
  if Assigned(FOnClose) then
    FOnClose(Self);
end;

initialization
  TPresentationProxyFactory.Current.Register(TSettingsSpinBox, TControlType.Styled,
    TStyledPresentationProxy<TSettingsSpinBoxStyle>);

finalization
  TPresentationProxyFactory.Current.Unregister(TSettingsSpinBox, TControlType.Styled,
    TStyledPresentationProxy<TSettingsSpinBoxStyle>);

end.

