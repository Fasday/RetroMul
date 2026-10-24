unit RM.Settings;

{$I ..\RM.Mobile.inc}

interface

uses
  Core.Platforms, Core.RomFormat, System.IOUtils, System.SysUtils,
  System.Classes, System.IniFiles, System.Generics.Collections, System.Types,
  System.UITypes, FMX.Forms, FMX.Types, FMX.Controls, FMX.Layouts, FMX.StdCtrls,
  FMX.Text, FMX.Edit, FMX.EditBox, FMX.SpinBox, FMX.ListBox,
  FMX.Controls.Presentation, Core.Storage, Core.Emulation, FMXInput, FMX.Objects,
  RM.Settings.Platform, RM.Settings.Catalog, RM.ShaderBitmap, RM.BitmapShaders;

const
  SETTINGS_CATEGORY_GENERAL = RM.Settings.platform.SETTINGS_CATEGORY_GENERAL;
  SETTINGS_CATEGORY_LIBRARY = RM.Settings.platform.SETTINGS_CATEGORY_LIBRARY;
  SETTINGS_CATEGORY_VIDEO_AUDIO = RM.Settings.platform.SETTINGS_CATEGORY_VIDEO_AUDIO;
  SETTINGS_CATEGORY_CONTROLS = RM.Settings.platform.SETTINGS_CATEGORY_CONTROLS;
  SETTINGS_CATEGORY_PERIPHERALS = RM.Settings.platform.SETTINGS_CATEGORY_PERIPHERALS;

const
  SETTINGS_PAGE_MAIN = RM.Settings.platform.SETTINGS_PAGE_MAIN;
  SETTINGS_PAGE_GB = RM.Settings.platform.SETTINGS_PAGE_GB;
  SETTINGS_PAGE_GBC = RM.Settings.platform.SETTINGS_PAGE_GBC;
  SETTINGS_PAGE_NES = RM.Settings.platform.SETTINGS_PAGE_NES;
  SETTINGS_PAGE_MD = RM.Settings.platform.SETTINGS_PAGE_MD;
  SETTINGS_PAGE_SNES = RM.Settings.platform.SETTINGS_PAGE_SNES;
  SETTINGS_PAGE_NEOGEO = RM.Settings.platform.SETTINGS_PAGE_NEOGEO;
  SETTINGS_PAGE_GBA = RM.Settings.platform.SETTINGS_PAGE_GBA;
  SETTINGS_PAGE_N64 = RM.Settings.platform.SETTINGS_PAGE_N64;
  SETTINGS_PAGE_SG1000 = RM.Settings.platform.SETTINGS_PAGE_SG1000;
  SETTINGS_PAGE_SC3000 = RM.Settings.platform.SETTINGS_PAGE_SC3000;
  SETTINGS_PAGE_SF7000 = RM.Settings.platform.SETTINGS_PAGE_SF7000;
  SETTINGS_PAGE_MULTIVISION = RM.Settings.platform.SETTINGS_PAGE_MULTIVISION;
  SETTINGS_PAGE_SMS = RM.Settings.platform.SETTINGS_PAGE_SMS;
  SETTINGS_PAGE_GG = RM.Settings.platform.SETTINGS_PAGE_GG;
  SETTINGS_PAGE_GW = RM.Settings.platform.SETTINGS_PAGE_GW;

const
  AUTOSAVE_DEFAULT_MINUTES = 10;
  AUTOSAVE_MAX_MINUTES = 1440;

const
  SettingsCategoryNames: array[SETTINGS_CATEGORY_GENERAL..SETTINGS_CATEGORY_PERIPHERALS] of string =
    ('General', 'Library', 'Video and audio', 'Controls', 'Peripherals');

var
  SettingsCoreIds, SettingsPageNames: TArray<string>;
  SettingsCoreOrder: TArray<Integer>;

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
    Assignments: TLayout;
    AssignmentList: TLayout;
    Port: Integer;
    Device: string;
  end;

  TSettingsView = class(TFrame)
    PanelSidebar: TPanel;
    PanelPlatforms: TPanel;
    LayoutPlatformSearchSlot: TLayout;
    ListBoxPlatforms: TListBox;
    LabelNoPlatforms: TLabel;
    LayoutPlatformPickerSlot: TLayout;
    ButtonReset: TButton;
    ButtonRefresh: TButton;
    ListBoxNavigation: TListBox;
    LayoutBody, LayoutContent, LayoutHeader, LayoutFooter: TLayout;
    LayoutSettingsMainColumn, LayoutSettingsPreviewColumn: TLayout;
    VertScrollBoxScroll: TVertScrollBox;
    LabelTitle, LabelStatus: TLabel;
    PanelConfigurationNotice: TPanel;
    VertScrollBoxConfigurationNotice: TVertScrollBox;
    LabelConfigurationNotice: TLabel;
    ButtonApply, ButtonBack, ButtonCancelCapture: TButton;
    LayoutComponentStore: TLayout;
    LabelBrand: TLabel;
    PathBrandIcon: TPath;
  private
    FStorage: IStorage;
    FPicker: TSettingsLocationPicker;
    FTemplatePicker: TSettingsTemplatePicker;
    FPickingBootROM: Boolean;
    FPickingTranslation: Boolean;
    FInput: TInputManager; // Draft assignments owned by this view.
    FHostInput: TInputManager; // Shared device snapshots; owned by the form.
    FDrafts: TArray<TMemIniFile>;
    FContext: TSettingsPageContext;
    FFields: TObjectList<TSettingsField>;
    FDevices: TObjectList<TSettingsDevice>;
    FDeviceIds: array[0..11] of string;
    FAlive: TFunc<Boolean>;
    FInvalidate: TProc;
    FSearch: TEdit;
    FPagePicker: TComboBox;
    FCategory, FCorePage, FPlayer: Integer;
    FPlatformSearch: TEdit;
    FPlatformPicker: TComboBox;
    FCategoryIcons: array[SETTINGS_CATEGORY_GENERAL..SETTINGS_CATEGORY_PERIPHERALS] of TControl;
    FPage: Integer;
    FGroup: TPanel;
    FPreview: TControl;
    FPreviewGroup: TPanel;
    FPreviewShaderFile: string;
    FPreviewShaderLoaded: Boolean;
    FHeight: Single;
    FBuilding, FRebuildPending, FArranging, FDeviceArranging, FLayoutPending: Boolean;
    FVolumeValue: TLabel;
    FAutosaveMinutes: TSpinBox;
    FCaptureAction: Integer;
    FCaptureDeadline: UInt64;
    FCaptureButton: TButton;
    FOnApply, FOnClose: TNotifyEvent;
    procedure InitializeRuntimeControls;
    procedure RefreshPlatformList;
    procedure SyncPlatformSelection;
    procedure PlatformSearchChange(Sender: TObject);
    procedure PlatformSelectionChange(Sender: TObject);
    procedure PlatformPickerChange(Sender: TObject);
    procedure BuildPalettePreview(Palette, Scaling: TComboBox);
    procedure BuildVideoPreview;
    procedure UpdateShaderPreview;
    procedure ShaderParameterChange(Sender: TObject);
    procedure ShaderFileChange(Sender: TObject);
    function ShaderTrack(const Name, Key: string; Default, Minimum, Maximum: Integer): TTrackBar;
    procedure ClearPathClick(Sender: TObject);
    procedure SaveTemplateClick(Sender: TObject);
    procedure BuildPage(PreserveScroll: Boolean = False);
    procedure RequestRebuild;
    procedure StorePage;
    procedure WireConfigurationChanges;
    procedure ConfigurationChange(Sender: TObject);
    procedure UpdateConfigurationNotice;
    procedure MeasureConfigurationNotice;
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
    procedure DetectRomFoldersClick(Sender: TObject);
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
  RM.Dialogs, FMX.TextLayout, Core.Adapter.PS1
  {$IFDEF ANDROID}, Core.Storage.Android{$ENDIF};

{$R *.fmx}

type
  TSettingsLayoutAccess = class(TLayout);

  TSettingsViewContext = class(TSettingsPageContext)
  private
    FView: TSettingsView;
  public
    constructor Create(View: TSettingsView);
    procedure Heading(const Name: string); override;
    function Combo(const Name, Section, Key: string; const Labels, Values: array of string; const Default: string): TComboBox; override;
    function Check(const Name, Section, Key: string; Default: Boolean): TSwitch; override;
    function Number(const Name, Section, Key: string; Default, Max: Integer): TSpinBox; override;
    function PathEdit(const Name, Section, Key, Default: string; Folder: Boolean): TEdit; override;
    procedure PalettePreview(Palette, Scaling: TComboBox); override;
    procedure BuildBindings(Port: Integer; const Device: string); override;
  end;

  TSettingsInputBackend = class(TInputBackend)
  private
    FHost: TInputManager;
  public
    constructor Create(Host: TInputManager);
    procedure Refresh; override;
    procedure RefreshIfNeeded; override;
    function Poll: TArray<TInputValue>; override;
  end;

  TSettingsPreview = class(TShaderBitmap)
  private
    FPaletteIndex: Integer;
    procedure SetPaletteIndex(Value: Integer);
  public
    constructor Create(AOwner: TComponent); override;
    property PaletteIndex: Integer read FPaletteIndex write SetPaletteIndex;
    procedure SetColorPattern;
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

constructor TSettingsViewContext.Create(View: TSettingsView);
begin
  inherited Create;
  FView := View;
end;

procedure TSettingsViewContext.Heading(const Name: string);
begin
  FView.Heading(Name);
end;

function TSettingsViewContext.Combo(const Name, Section, Key: string; const Labels, Values: array of string; const Default: string): TComboBox;
begin
  Result := FView.Combo(Name, Section, Key, Labels, Values, Default);
end;

function TSettingsViewContext.Check(const Name, Section, Key: string; Default: Boolean): TSwitch;
begin
  Result := FView.Check(Name, Section, Key, Default);
end;

function TSettingsViewContext.Number(const Name, Section, Key: string; Default, Max: Integer): TSpinBox;
begin
  Result := FView.Number(Name, Section, Key, Default, Max);
end;

function TSettingsViewContext.PathEdit(const Name, Section, Key, Default: string; Folder: Boolean): TEdit;
begin
  Result := FView.PathEdit(Name, Section, Key, Default, Folder);
end;

procedure TSettingsViewContext.PalettePreview(Palette, Scaling: TComboBox);
begin
  FView.BuildPalettePreview(Palette, Scaling);
end;

procedure TSettingsViewContext.BuildBindings(Port: Integer; const Device: string);
begin
  FView.BuildBindings(Port, Device);
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
  WrapMode := TImageWrapMode.Fit;
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
  ResetHistory;
end;

procedure TSettingsPreview.SetColorPattern;
begin
  if FPaletteIndex = -1 then
    Exit;
  Bitmap.SetSize(256, 240);
  var Data: TBitmapData;
  if not Bitmap.Map(TMapAccess.Write, Data) then
    Exit;
  try
    // Fine edges, gradients and saturated colors make all built-in effects visible.
    for var Y := 0 to Bitmap.Height - 1 do
      for var X := 0 to Bitmap.Width - 1 do
      begin
        var Pixel: TAlphaColorRec;
        Pixel.A := 255;
        Pixel.R := X;
        Pixel.G := Y * 255 div 239;
        Pixel.B := 255 - X;
        if Y < 48 then
        begin
          Pixel.R := 255 * Ord((X div 32 and 1) <> 0);
          Pixel.G := 255 * Ord((X div 32 and 2) <> 0);
          Pixel.B := 255 * Ord((X div 32 and 4) <> 0);
        end;
        if (Y > 176) and (X > 16) and (X < 240) then
        begin
          var Shade := Byte(48 + 160 * Ord(((X div 4 + Y div 4) and 1) = 0));
          Pixel.R := Shade;
          Pixel.G := Shade;
          Pixel.B := Shade;
        end;
        if (X in [16, 239]) or (Y in [64, 160]) then
          Pixel.Color := TAlphaColors.White;
        Data.SetPixel(X, Y, Pixel.Color);
      end;
    FPaletteIndex := -1;
  finally
    Bitmap.Unmap(Data);
  end;
  ResetHistory;
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
  else if FItems[Index].Button < 0 then
    // -1 - N: auxiliary button N.
    Result := TScreenGamepad(FDevice).AuxiliaryButtonBounds(-1 - FItems[Index].Button)
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
      var Name := Translate(CoreButtonName(Core, B));
      AddCallout(Ord(B), PadAction(Port, B), Name, Translate('Button ') + Name, Left, Click);
    end;
  if (Core = ROM_SYSTEM_N64) and (Device is TScreenGamepad) and
    not TScreenGamepad(Device).AuxiliaryButtonBounds(0).IsEmpty then
    AddCallout(-1, N64LAction + Port, 'L', Translate('Button ') + 'L', True, Click);
  if (Core = ROM_SYSTEM_PS1) and (Device is TScreenGamepad) then
    for var Extra := Low(TPS1Extra) to High(TPS1Extra) do
      if not TScreenGamepad(Device).AuxiliaryButtonBounds(Ord(Extra)).IsEmpty then
        AddCallout(-1 - Ord(Extra), PS1Action(Port, Extra), Translate(PS1ExtraName(Extra)),
          Translate('Button ') + Translate(PS1ExtraName(Extra)), True, Click);
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
    Aspect := TNesPowerPad(FDevice).AspectRatio;
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
  // PaintTo temporarily detaches Parent when rendering to a bitmap.
  var D := TDeviceCallouts(Owner);
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
  SetLength(FDrafts, SettingsPlatforms.MaxPageId + 1);
  FDrafts[SETTINGS_PAGE_MAIN] := FStorage.ReadConfig(FStorage.ConfigFile('config'));
  for var platform in SettingsPlatforms.Items do
    FDrafts[platform.PageId] := FStorage.ReadConfig(FStorage.ConfigFile(platform.CoreId));
  FContext := TSettingsViewContext.Create(Self);
  FContext.Owner := Self;
  FContext.Store := LayoutComponentStore;
  FContext.ComboClass := TSettingsComboBox;
  FContext.NumberClass := TSettingsSpinBox;
  FContext.OnRebuild := PortChange;
  FContext.OnClearPath := ClearPathClick;
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
  FPlatformSearch := FindComponent('SearchEditPlatformSearch') as TEdit;
  FPlatformSearch.TextPrompt := Translate('Search platforms');
  FPlatformSearch.OnChangeTracking := PlatformSearchChange;
  FPlatformSearch.OnResize := EditorResize;
  FPlatformPicker := FindComponent('SettingsComboBoxPlatformPicker') as TComboBox;
  FPlatformPicker.OnChange := PlatformPickerChange;
  FPlatformPicker.OnResize := ComboResize;
  ListBoxPlatforms.OnChange := PlatformSelectionChange;
  RefreshPlatformList;
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

procedure TSettingsView.BuildVideoPreview;
begin
  var PreviousGroup := FGroup;
  Heading('GroupPreview');
  FPreviewGroup := FGroup;
  var PreviewRow := Row('Row160144');
  PreviewRow.Tag := 1;
  PreviewRow.Padding.Rect := TRectF.Empty;
  PreviewRow.Height := 350;
  TLayout(TLabel(PreviewRow.TagObject).Parent).Visible := False;
  FPreview := FindComponent('SettingsPreviewPalettePreview') as TSettingsPreview;
  FPreview.Align := TAlignLayout.Client;
  FGroup := PreviousGroup;
end;

procedure TSettingsView.BuildPalettePreview(Palette, Scaling: TComboBox);
begin
  Palette.OnChange := PreviewChange;
  Scaling.OnChange := PreviewChange;
  BuildVideoPreview;
  var Preview := TSettingsPreview(FPreview);
  Preview.PaletteIndex := Palette.ItemIndex;
  Preview.DisableInterpolation := Scaling.ItemIndex = 0;
end;

function TSettingsView.ShaderTrack(const Name, Key: string; Default, Minimum, Maximum: Integer): TTrackBar;
begin
  Row(Name);
  Result := FindComponent('SettingsTrackBar' + Name + 'Editor') as TSettingsTrackBar;
  Result.OnChange := nil;
  Field(Result, 'Shaders', Key).DefaultValue := IntToStr(Default);
  Result.Min := Minimum;
  Result.Max := Maximum;
  Result.Frequency := 1;
  Result.Tracking := True;
  Result.TagString := Key;
  Result.TagObject := FindComponent('Label' + Name + 'Value');
  Result.Value := EnsureRange(FDrafts[FPage].ReadInteger('Shaders', Key, Default), Minimum, Maximum);
  Result.OnChange := ShaderParameterChange;
  ShaderParameterChange(Result);
end;

procedure TSettingsView.ShaderParameterChange(Sender: TObject);
begin
  var Track := TTrackBar(Sender);
  var Value := Round(Track.Value);
  var Caption := IntToStr(Value) + '%';
  if Track.TagString = 'LCDResponseMS' then
    Caption := IntToStr(Value) + ' ' + Translate('ms');
  TLabel(Track.TagObject).Text := Caption;
  if FBuilding then
    Exit;
  StorePage;
  UpdateShaderPreview;
end;

procedure TSettingsView.ShaderFileChange(Sender: TObject);
begin
  if FBuilding then
    Exit;
  StorePage;
  UpdateShaderPreview;
end;

procedure TSettingsView.UpdateShaderPreview;
begin
  if not (FPreview is TSettingsPreview) then
    Exit;
  var Preview := TSettingsPreview(FPreview);
  var Draft := FDrafts[FPage];
  var Options := TBitmapShaderSettings.Default;
  Options.ScanlineStrength := Draft.ReadInteger('Shaders', 'Scanlines', 35) / 100;
  Options.Curvature := Draft.ReadInteger('Shaders', 'Curvature', 8) / 100;
  Options.MaskStrength := Draft.ReadInteger('Shaders', 'Mask', 65) / 100;
  Options.Glow := Draft.ReadInteger('Shaders', 'Glow', 20) / 100;
  Options.LCDGridStrength := Draft.ReadInteger('Shaders', 'LCDGrid', 35) / 100;
  Options.LCDResponseMS := Draft.ReadInteger('Shaders', 'LCDResponseMS', 65);
  Options.Gamma := Draft.ReadInteger('Shaders', 'Gamma', 100) / 100;
  Options.Saturation := Draft.ReadInteger('Shaders', 'Saturation', 100) / 100;
  Options.Temperature := Draft.ReadInteger('Shaders', 'Temperature', 100) / 100 - 1;
  Preview.Settings := Options;
  Preview.DisableInterpolation := Draft.ReadString('Video', 'Filter', 'nearest') = 'nearest';
  var Effect := Draft.ReadString('Shaders', 'Mode', 'off');
  var NextMode := TBitmapShaderMode.Original;
  if Effect = 'scanlines' then
    NextMode := TBitmapShaderMode.Scanlines
  else if Effect = 'crt' then
    NextMode := TBitmapShaderMode.CRT
  else if Effect = 'lcd' then
    NextMode := TBitmapShaderMode.LCD
  else if Effect = 'color' then
    NextMode := TBitmapShaderMode.ColorCorrection;
  var Status := FindComponent('LabelShaderPreviewStatus') as TLabel;
  if Effect = 'custom' then
  begin
    var FileName := Draft.ReadString('Shaders', 'File', '').Trim;
    if (FileName <> FPreviewShaderFile) or (not FPreviewShaderLoaded and not Status.Visible) then
    begin
      FPreviewShaderFile := FileName;
      FPreviewShaderLoaded := False;
      Status.Visible := False;
      if FileName <> '' then
      begin
        if not System.IOUtils.TPath.IsPathRooted(FileName) then
          FileName := System.IOUtils.TPath.Combine(System.IOUtils.TPath.GetDocumentsPath, FileName);
        try
          Preview.LoadShaderFromFile(FileName);
          FPreviewShaderLoaded := True;
        except
          on E: Exception do
          begin
            Preview.Mode := TBitmapShaderMode.Original;
            Status.Text := Translate('Cannot preview this shader. Check the shader file.');
            Status.Hint := E.Message;
            Status.ShowHint := True;
            Status.Visible := True;
          end;
        end;
      end
      else
      begin
        Status.Text := Translate('Choose a shader file to see the preview.');
        Status.Visible := True;
      end;
    end;
    if FPreviewShaderLoaded then
      NextMode := TBitmapShaderMode.Custom;
  end
  else
    Status.Visible := False;
  Preview.Mode := NextMode;
end;

procedure TSettingsView.ClearPathClick(Sender: TObject);
begin
  TEdit(TEditButton(Sender).TagObject).Text := '';
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
    Control.Size.Size := Slot.Size.Size;
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
  ReplaceRuntime('ZXConfigurationPresetEditor', TSettingsComboBox);
  for var platform in SettingsPlatforms.Items do
  begin
    FContext.PageId := platform.PageId;
    platform.Initialize(FContext);
  end;
  ReplaceRuntime('RowPS1VideoEditor', TSettingsComboBox);
  for var PS1Port := 1 to 2 do
    ReplaceRuntime('RowPS1ControllerPort' + IntToStr(PS1Port) + 'Editor', TSettingsComboBox);
  var PS1Clear := FindComponent('EditButtonRowPS1BIOSClear') as TEditButton;
  PS1Clear.TagObject := FindComponent('EditRowPS1BIOSEditor');
  PS1Clear.OnClick := ClearPathClick;
  ReplaceRuntime('RowNGModelEditor', TSettingsComboBox);
  ReplaceRuntime('RowShaderModeEditor', TSettingsComboBox);
  ReplaceRuntime('RowShaderScanlinesEditor', TSettingsTrackBar);
  ReplaceRuntime('RowShaderCurvatureEditor', TSettingsTrackBar);
  ReplaceRuntime('RowShaderMaskEditor', TSettingsTrackBar);
  ReplaceRuntime('RowShaderGlowEditor', TSettingsTrackBar);
  ReplaceRuntime('RowShaderLCDGridEditor', TSettingsTrackBar);
  ReplaceRuntime('RowShaderLCDResponseEditor', TSettingsTrackBar);
  ReplaceRuntime('RowShaderGammaEditor', TSettingsTrackBar);
  ReplaceRuntime('RowShaderSaturationEditor', TSettingsTrackBar);
  ReplaceRuntime('RowShaderTemperatureEditor', TSettingsTrackBar);
  ReplaceRuntime('RowNGRegionEditor', TSettingsComboBox);
  ReplaceRuntime('RowNGCardSizeEditor', TSettingsComboBox);
  var NeoGeoClear := FindComponent('EditButtonRowNGBIOSClear') as TEditButton;
  NeoGeoClear.TagObject := FindComponent('EditRowNGBIOSEditor');
  NeoGeoClear.OnClick := ClearPathClick;
  NeoGeoClear := FindComponent('EditButtonRowNGCardPathClear') as TEditButton;
  NeoGeoClear.TagObject := FindComponent('EditRowNGCardPathEditor');
  NeoGeoClear.OnClick := ClearPathClick;
  ReplaceRuntime('RowPCEModelEditor', TSettingsComboBox);
  ReplaceRuntime('RowSaturnRegionEditor', TSettingsComboBox);
  ReplaceRuntime('RowSaturnRAMCartEditor', TSettingsComboBox);
  ReplaceRuntime('RowSaturnCDBackendEditor', TSettingsComboBox);
  for var SaturnPort := 1 to 12 do
    ReplaceRuntime('RowSaturnControllerPort' + IntToStr(SaturnPort) + 'Editor', TSettingsComboBox);
  var SaturnClear := FindComponent('EditButtonRowSaturnBIOSClear') as TEditButton;
  SaturnClear.TagObject := FindComponent('EditRowSaturnBIOSEditor');
  SaturnClear.OnClick := ClearPathClick;
  SaturnClear := FindComponent('EditButtonRowSaturnCartROMClear') as TEditButton;
  SaturnClear.TagObject := FindComponent('EditRowSaturnCartROMEditor');
  SaturnClear.OnClick := ClearPathClick;
  var PCEClear := FindComponent('EditButtonRowPCEBIOSClear') as TEditButton;
  PCEClear.TagObject := FindComponent('EditRowPCEBIOSEditor');
  PCEClear.OnClick := ClearPathClick;
  var ClearTranslation := FindComponent('EditButtonRowTranslationfileClear') as TEditButton;
  ClearTranslation.TagObject := FindComponent('EditRowTranslationfileEditor');
  ClearTranslation.OnClick := ClearPathClick;
  (FindComponent('ButtonSaveTranslationTemplate') as TButton).OnClick := SaveTemplateClick;
  ReplaceRuntime('PlatformSearch', TSearchEdit);
  ReplaceCombo('PlatformPicker', []);
  ReplaceRuntime('SettingsSearch', TSearchEdit);
  (TSearchEdit(FindComponent('SearchEditSettingsSearch'))).TextPrompt := Translate('Search this section');
  ReplaceCombo('SettingsPagePicker', ['General', 'Library', 'Video and audio', 'Controls', 'Peripherals']);
  (FindComponent('SettingsComboBoxSettingsPagePicker') as TSettingsComboBox).ItemIndex := FCategory;
  ReplaceCombo('RowLanguageEditor', ['English', 'Русский', 'Português']);
  ReplaceRuntime('AutosaveMinutes', TSettingsSpinBox);
  (TSettingsSpinBox(FindComponent('SettingsSpinBoxAutosaveMinutes'))).Min := 1;
  (TSettingsSpinBox(FindComponent('SettingsSpinBoxAutosaveMinutes'))).Max := 1440;
  (TSettingsSpinBox(FindComponent('SettingsSpinBoxAutosaveMinutes'))).ValueType := TNumValueType.Integer;
  ReplaceRuntime('RowGamepadscaleEditor', TSettingsSpinBox);
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
  ReplaceRuntime('RowMDCDAudioEditor', TSettingsSpinBox);
  ReplaceRuntime('RowMD32XAudioEditor', TSettingsSpinBox);
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
  for var Port := 0 to 11 do
    ReplaceCombo('RowInputsource' + IntToStr(Port) + 'Editor', []);
end;

destructor TSettingsView.Destroy;
begin
  FBuilding := True;
  if Assigned(FInvalidate) then
    FInvalidate();
  CancelCapture;
  FContext.Free;
  FFields.Free;
  FreeAndNil(FDevices);
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
    FPagePicker.ItemIndex := FCategory;
    CancelCapture;
    FAutosaveMinutes := nil;
    FVolumeValue := nil;
    if FPreview is TSettingsPreview then
      TSettingsPreview(FPreview).Mode := TBitmapShaderMode.Original;
    FPreview := nil;
    FPreviewGroup := nil;
    FPreviewShaderFile := '';
    FPreviewShaderLoaded := False;
    (FindComponent('LabelShaderPreviewStatus') as TLabel).Visible := False;
    FDevices.Clear;
    FFields.Clear;
    LayoutSettingsMainColumn.BeginUpdate;
    LayoutSettingsPreviewColumn.BeginUpdate;
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
    LayoutContent.Margins.Right := Max(16, VertScrollBoxScroll.Width - 1240);
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
      var PadScale := Number('RowGamepadscale', 'General', 'GamepadScale', 100, 200);
      PadScale.Min := 50;
      PadScale.Value := Max(50, PadScale.Value);
      Number('RowBottominset', 'General', 'ControlBottomInset', 100, 400);
      Check('RowTouchhaptics', 'General', 'TouchHaptics', True);
    end
    else if FCategory = SETTINGS_CATEGORY_LIBRARY then
    begin
      Heading('GroupPlatformFolders');
      Row('RowDetectRomFolders');
      (FindComponent('ButtonDetectRomFolders') as TButton).OnClick := DetectRomFoldersClick;
      for var platform in TPlatformRegistry.All do
        PathEdit('RowRomFolder' + platform.Folder.Substring(0, 1).ToUpper + platform.Folder.Substring(1), 'RomFolders', platform.Id, '', True);
      Heading('GroupGamelibrary');
      Combo('RowLibraryview', 'Library', 'View', [], ['grid', 'list'], 'grid');
      Combo('RowCardsize', 'Library', 'CardWidth', [], ['140', '170', '220'], '170');
      Check('RowShowplatformoncards', 'Library', 'ShowPlatform', True);
      Check('RowLetternavigation', 'Library', 'ShowLetters', False);
      Heading('GroupMetadata');
      Row('RowCoversanddescriptions');
    end
    else
    begin
      var platform := SettingsPlatforms.Find(FPage);
      FContext.PageId := FPage;
      FContext.Draft := FDrafts[FPage];
      if FInput <> nil then
        LoadInputBindings(FInput, FDrafts[FPage], SettingsCoreIds[FPage]);
      if FCategory = SETTINGS_CATEGORY_VIDEO_AUDIO then
      begin
        platform.Configuration(FContext);
        Heading('GroupVideo');
        var Scaling := Combo('RowImagescaling', 'Video', 'Filter', [], ['nearest', 'linear'], 'nearest');
        Scaling.OnChange := PreviewChange;
        platform.Video(FContext);
        FGroup := FindComponent('PanelGroupVideo') as TPanel;
        var ShaderMode := Combo('RowShaderMode', 'Shaders', 'Mode',
          ['Off', 'Scanlines', 'CRT', 'LCD', 'Color correction', 'Custom'],
          ['off', 'scanlines', 'crt', 'lcd', 'color', 'custom'], 'off');
        ShaderMode.OnChange := PortChange;
        var Effect := FDrafts[FPage].ReadString('Shaders', 'Mode', 'off');
        if (Effect = 'scanlines') or (Effect = 'crt') then
          ShaderTrack('RowShaderScanlines', 'Scanlines', 35, 0, 100);
        if Effect = 'crt' then
        begin
          ShaderTrack('RowShaderCurvature', 'Curvature', 8, 0, 30);
          ShaderTrack('RowShaderMask', 'Mask', 65, 0, 100);
          ShaderTrack('RowShaderGlow', 'Glow', 20, 0, 100);
        end;
        if Effect = 'lcd' then
        begin
          ShaderTrack('RowShaderLCDGrid', 'LCDGrid', 35, 0, 100);
          ShaderTrack('RowShaderLCDResponse', 'LCDResponseMS', 65, 0, 500);
        end;
        if Effect = 'custom' then
          EditText('RowShaderFile', 'Shaders', 'File', '').OnChangeTracking := ShaderFileChange;
        if (Effect = 'color') or (Effect = 'custom') then
        begin
          ShaderTrack('RowShaderGamma', 'Gamma', 100, 25, 400);
          ShaderTrack('RowShaderSaturation', 'Saturation', 100, 0, 200);
          ShaderTrack('RowShaderTemperature', 'Temperature', 100, 0, 200);
        end;
        if FPreview = nil then
        begin
          BuildVideoPreview;
          TSettingsPreview(FPreview).SetColorPattern;
        end;
        Heading('GroupAudio');
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
        platform.Audio(FContext);
      end
      else if FCategory = SETTINGS_CATEGORY_CONTROLS then
      begin
        Heading('GroupController');
        var Count := platform.PlayerCount(FDrafts[FPage]);
        FPlayer := EnsureRange(FPlayer, 0, Count - 1);
        Row('RowPlayer');
        var Player := FindComponent('SettingsComboBoxRowPlayerEditor') as TSettingsComboBox;
        Player.OnChange := nil;
        Player.Items.Clear;
        Player.Align := TAlignLayout.Client;
        for var i := 1 to Count do
          Player.Items.Add(Translate('Player ') + IntToStr(i));
        Player.ItemIndex := FPlayer;
        Player.OnChange := PlayerChange;
        Player.OnResize := ComboResize;
        ComboResize(Player);
        BuildPort(FPlayer, Translate('Bindings · player ') + IntToStr(FPlayer + 1));
      end
      else if FPage <> SETTINGS_PAGE_GW then
      begin
        platform.Peripherals(FContext);
        for var Port := 0 to platform.Ports - 1 do
          BuildPort(Port, Translate('Port ') + IntToStr(Port + 1));
        platform.Expansion(FContext);
      end;
      WireConfigurationChanges;
      LabelStatus.Text := Translate('Settings are saved separately for each platform. Core options apply when you next open a ROM.');
      if platform.HasConfiguration then
        LabelStatus.Text := Translate('Configuration changes stay in this draft until you click Apply. Hardware options apply when you next open a ROM.');
    end;
  finally
    FBuilding := False;
    UpdateShaderPreview;
    UpdateConfigurationNotice;
    Resize;
    LayoutSettingsMainColumn.EndUpdate;
    LayoutSettingsPreviewColumn.EndUpdate;
    VertScrollBoxScroll.EndUpdate;
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

procedure TSettingsView.WireConfigurationChanges;
begin
  var platform := SettingsPlatforms.Find(FPage);
  if (platform = nil) or not platform.HasConfiguration then
    Exit;
  for var F in FFields do
    if F.Control is TComboBox then
    begin
      if not Assigned(TComboBox(F.Control).OnChange) then
        TComboBox(F.Control).OnChange := ConfigurationChange;
    end
    else if F.Control is TSwitch then
    begin
      if not Assigned(TSwitch(F.Control).OnSwitch) then
        TSwitch(F.Control).OnSwitch := ConfigurationChange;
    end
    else if F.Control is TSpinBox then
    begin
      if not Assigned(TSpinBox(F.Control).OnChange) then
        TSpinBox(F.Control).OnChange := ConfigurationChange;
    end
    else if F.Control is TEdit then
    begin
      if not Assigned(TEdit(F.Control).OnChangeTracking) then
        TEdit(F.Control).OnChangeTracking := ConfigurationChange;
    end;
end;

procedure TSettingsView.ConfigurationChange(Sender: TObject);
begin
  if FBuilding or FRebuildPending then
    Exit;
  var platform := SettingsPlatforms.Find(FPage);
  if (platform = nil) or not platform.HasConfiguration then
    Exit;
  for var F in FFields do
    if F.Control = Sender then
    begin
      // FMX may deliver a switch animation notification after rebuilding a page.
      // Ignore notifications whose value is already present in the draft.
      var Changed := False;
      var Draft := FDrafts[FPage];
      if F.Control is TComboBox then
      begin
        var Index := TComboBox(F.Control).ItemIndex;
        Changed := (Index >= 0) and (Index < Length(F.Values)) and
          not SameText(Draft.ReadString(F.Section, F.Key, F.DefaultValue), F.Values[Index]);
      end
      else if F.Control is TSwitch then
        Changed := Draft.ReadBool(F.Section, F.Key, StrToIntDef(F.DefaultValue, 0) <> 0) <> TSwitch(F.Control).IsChecked
      else if F.Control is TSpinBox then
        Changed := Draft.ReadInteger(F.Section, F.Key, StrToIntDef(F.DefaultValue, 0)) <> Round(TSpinBox(F.Control).Value)
      else if F.Control is TEdit then
        Changed := Draft.ReadString(F.Section, F.Key, F.DefaultValue) <> TEdit(F.Control).Text.Trim;
      if not Changed then
        Exit;
      LabelStatus.Text := Translate('Configuration changed in the draft. Click Apply to save, or Cancel to discard.');
      StorePage;
      if platform.ChangeConfiguration(FDrafts[FPage], F.Section, F.Key) then
        RequestRebuild
      else
      begin
        // Update only the preset indicator; keep the edited control and focus.
        FBuilding := True;
        try
          for var P in FFields do
            if SameText(P.Section, 'Hardware') and SameText(P.Key, 'Preset') then
              TComboBox(P.Control).ItemIndex := 0;
        finally
          FBuilding := False;
        end;
      end;
      UpdateConfigurationNotice;
      Exit;
    end;
end;

procedure TSettingsView.MeasureConfigurationNotice;
begin
  if not PanelConfigurationNotice.Visible then
    Exit;
  var Layout := TTextLayoutManager.DefaultTextLayout.Create;
  try
    Layout.BeginUpdate;
    Layout.Font.Assign(LabelConfigurationNotice.TextSettings.Font);
    Layout.MaxSize := TPointF.Create(Max(1, PanelConfigurationNotice.Width - 48), 100000);
    Layout.WordWrap := True;
    Layout.Text := LabelConfigurationNotice.Text;
    Layout.EndUpdate;
    LabelConfigurationNotice.Height := Max(24, Ceil(Layout.TextHeight) + 8);
    PanelConfigurationNotice.Height := Min(Max(64, LabelConfigurationNotice.Height + 16),
      Max(64, Min(180, Height * 0.25)));
  finally
    Layout.Free;
  end;
  VertScrollBoxConfigurationNotice.RealignContent;
end;

procedure TSettingsView.UpdateConfigurationNotice;
begin
  var platform := SettingsPlatforms.Find(FPage);
  var Text := '';
  if (platform <> nil) and platform.HasConfiguration then
    Text := platform.ConfigurationNotice(FDrafts[FPage]);
  if LabelConfigurationNotice.Text <> Text then
    VertScrollBoxConfigurationNotice.ViewportPosition := TPointF.Zero;
  LabelConfigurationNotice.Text := Text;
  PanelConfigurationNotice.Visible := Text <> '';
  MeasureConfigurationNotice;
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
    begin
      if F.Section = 'Shaders' then
        FDrafts[FPage].WriteInteger(F.Section, F.Key, Round(TTrackBar(F.Control).Value))
      else
        FDrafts[FPage].WriteFloat(F.Section, F.Key, TTrackBar(F.Control).Value / 100);
    end
    else if F.Control is TEdit then
      FDrafts[FPage].WriteString(F.Section, F.Key, TEdit(F.Control).Text.Trim);
  end;
  if (FPage > SETTINGS_PAGE_MAIN) and (FInput <> nil) then
    SaveInputBindings(FInput, FDrafts[FPage]);
end;

procedure TSettingsView.Heading(const Name: string);
begin
  FGroup := FindComponent('Panel' + Name) as TPanel;
  if Name = 'GroupPreview' then
    FGroup.Parent := LayoutSettingsPreviewColumn
  else
    FGroup.Parent := LayoutSettingsMainColumn;
  // Top alignment uses previous Y for sorting. Reset only the sort key while
  // the column is updating, so page declaration order becomes alignment order.
  FGroup.Position.Y := 0;
  FGroup.Visible := True;
  FGroup.OnResize := ContentResize;
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
  if string(Result.Row.Name).StartsWith('PanelRowPCE') then
  begin
    Control.Align := TAlignLayout.Client;
    Control.OnResize := EditorResize;
    Exit;
  end;
  Control.Align := TAlignLayout.Client;
  Control.OnResize := EditorResize;
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
      Result.Items.Add(Translate(Caption));
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
  {$IFDEF ISMOBILE}
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

  // FMX can call Resize from inside an unfinished parent alignment. Settle
  // once more after that alignment has applied the final column bounds.
  if not FLayoutPending then
  begin
    FLayoutPending := True;
    var Alive: TFunc<Boolean> := FAlive;
    TThread.ForceQueue(nil,
      procedure
      begin
        if not Alive() then
          Exit;
        try
          Resize;
        finally
          FLayoutPending := False;
        end;
      end);
  end;

  FArranging := True;
  try
    PanelSidebar.Visible := Width >= 1050;
    PanelSidebar.Width := 264;
    PanelPlatforms.Visible := (FCategory >= SETTINGS_CATEGORY_VIDEO_AUDIO) and (Width >= 760);
    PanelPlatforms.Width := 216;
    PanelSidebar.Align := TAlignLayout.MostLeft;
    PanelPlatforms.Align := TAlignLayout.Left;
    LayoutBody.Align := TAlignLayout.Client;
    ListBoxNavigation.Visible := PanelSidebar.Visible;
    FPagePicker.Visible := not PanelSidebar.Visible;
    FPlatformPicker.Visible := (FCategory >= SETTINGS_CATEGORY_VIDEO_AUDIO) and not PanelPlatforms.Visible;
    // Settle the sidebar widths before using the header's available width.
    // During a window-state transition the parent can still be realigning.
    Realign;
    TSettingsLayoutAccess(LayoutBody).Realign;
    LabelTitle.Text := Translate(SettingsCategoryNames[FCategory]);
    if FCategory = SETTINGS_CATEGORY_GENERAL then
      LabelTitle.Text := Translate('General settings');
    for var I := Low(FCategoryIcons) to High(FCategoryIcons) do
      if I = FCategory then
        TPath(FCategoryIcons[I]).Stroke.Color := $FFFFB344
      else
        TPath(FCategoryIcons[I]).Stroke.Color := $FFB9C2CC;
    var CompactSearch := LayoutHeader.Width < 740;
    var HeadingRow := FindComponent('LayoutSettingsHeading') as TLayout;
    var CompactSearchSlot := FindComponent('LayoutSettingsCompactSearchSlot') as TLayout;
    CompactSearchSlot.Visible := CompactSearch;
    if CompactSearch then
    begin
      FSearch.Parent := CompactSearchSlot;
      FSearch.Align := TAlignLayout.Client;
      FSearch.Margins.Rect := TRectF.Empty;
    end
    else
    begin
      FSearch.Parent := HeadingRow;
      FSearch.Align := TAlignLayout.Right;
      FSearch.Width := 260;
      FSearch.Margins.Rect := RectF(16, 0, 0, 12);
    end;
    LayoutHeader.Height := 60 + 44 * (Ord(FPagePicker.Visible) + Ord(FPlatformPicker.Visible) + Ord(CompactSearch));
    VertScrollBoxScroll.Align := TAlignLayout.Client;
    FSearch.Visible := True;
    if LayoutContent = nil then
      Exit;

    var CompactReset := LayoutFooter.Width < 520;
    var ResetRow := FindComponent('LayoutSettingsCompactReset') as TLayout;
    ResetRow.Visible := CompactReset and (FCaptureButton = nil);
    if CompactReset then
      ButtonReset.Parent := ResetRow
    else
      ButtonReset.Parent := FindComponent('LayoutSettingsActions') as TLayout;
    ButtonReset.Visible := FCaptureButton = nil;
    LayoutFooter.Height := 96 + 44 * Ord(ResetRow.Visible);
    ButtonRefresh.Visible := (FCategory = SETTINGS_CATEGORY_CONTROLS) and (LayoutFooter.Width >= 700);
    ButtonApply.Visible := FCaptureButton = nil;
    ButtonBack.Visible := FCaptureButton = nil;
    MeasureConfigurationNotice;
    // Header/footer heights determine the viewport. Apply them, then settle
    // the content width before measuring responsive rows and column heights.
    TSettingsLayoutAccess(LayoutBody).Realign;
    LayoutContent.Margins.Right := Max(16, VertScrollBoxScroll.Width - 1240);
    VertScrollBoxScroll.RealignContent;
    LayoutContent.BeginUpdate;
    try
      var Columns := (FCategory = SETTINGS_CATEGORY_VIDEO_AUDIO) and (FPreviewGroup <> nil) and (LayoutContent.Width >= 850);
      if FPreviewGroup <> nil then
        if Columns then
          FPreviewGroup.Parent := LayoutSettingsPreviewColumn
        else
        begin
          FPreviewGroup.Parent := LayoutSettingsMainColumn;
          // Keep the preview next to its image settings in the single column.
          var VideoGroup := FindComponent('PanelGroupVideo') as TPanel;
          FPreviewGroup.Index := VideoGroup.Index + 1;
        end;
      LayoutSettingsPreviewColumn.Visible := Columns and (FPreviewGroup <> nil) and FPreviewGroup.Visible;
      if Columns then
      begin
        LayoutSettingsPreviewColumn.Align := TAlignLayout.Right;
        LayoutSettingsPreviewColumn.Margins.Rect := TRectF.Create(16, 0, 0, 0);
        LayoutSettingsPreviewColumn.Width := LayoutContent.Width * 0.38 - 8;
        LayoutSettingsMainColumn.Align := TAlignLayout.Client;
        LayoutSettingsMainColumn.Width := Max(0, LayoutContent.Width - LayoutSettingsPreviewColumn.Width - 16);
      end
      else
      begin
        LayoutSettingsMainColumn.Align := TAlignLayout.MostTop;
        LayoutSettingsPreviewColumn.Align := TAlignLayout.Top;
        // The last main card already contributes the shared 16px bottom margin.
        LayoutSettingsPreviewColumn.Margins.Rect := TRectF.Empty;
        LayoutSettingsMainColumn.Width := LayoutContent.Width;
        LayoutSettingsPreviewColumn.Width := LayoutContent.Width;
      end;
      var MainHeight: Single := 0;
      var PreviewHeight: Single := 0;
      for var Column in [LayoutSettingsMainColumn, LayoutSettingsPreviewColumn] do
      begin
        Column.BeginUpdate;
        try
          for var I := 0 to Column.ChildrenCount - 1 do
            if Column.Children[I] is TPanel then
            begin
              var Card := TPanel(Column.Children[I]);
              if not Card.Visible then
                Continue;
              // A resize can arrive while FMX is already aligning this column.
              // Use the real stack offset, since a nested Realign is skipped.
              if Column = LayoutSettingsMainColumn then
                Card.Position.Y := MainHeight
              else
                Card.Position.Y := PreviewHeight;
              Card.Width := Column.Width;
              ArrangeGroup(Card);
              if Column = LayoutSettingsMainColumn then
                MainHeight := MainHeight + Card.Height + Card.Margins.Top + Card.Margins.Bottom
              else
                PreviewHeight := PreviewHeight + Card.Height + Card.Margins.Top + Card.Margins.Bottom;
            end;
        finally
          Column.EndUpdate;
        end;
      end;
      LayoutSettingsMainColumn.Height := MainHeight;
      LayoutSettingsPreviewColumn.Height := PreviewHeight;
      if Columns then
        LayoutContent.Height := Max(MainHeight, PreviewHeight)
      else if LayoutSettingsPreviewColumn.Visible then
        LayoutContent.Height := MainHeight + PreviewHeight + LayoutSettingsPreviewColumn.Margins.Top
      else
        LayoutContent.Height := MainHeight;
    finally
      LayoutContent.EndUpdate;
    end;
    // Publishing the measured height must also refresh the scroll range;
    // FMX may have cached it earlier in the native window resize sequence.
    VertScrollBoxScroll.RealignContent;
  finally
    FArranging := False;
  end;
end;

procedure TSettingsView.ArrangeGroup(Group: TPanel);
begin
  Group.BeginUpdate;
  try
    // Group padding and Top-aligned rows are shared by every platform.
    Group.Padding.Rect := TRectF.Create(16, 14, 16, 12);
    var ContentHeight: Single := 0;
    for var Child in Group.Children do
      if (Child is TControl) and (Child.Owner = Self) then
      begin
        var C := TControl(Child);
        C.Align := TAlignLayout.Top;
        C.Position.Y := Group.Padding.Top + ContentHeight;
        C.Margins.Rect := TRectF.Create(0, 0, 0, 6);
        if C is TPanel then
        begin
          C.Width := Max(0, Group.Width - 32);
          if C.Tag = 1 then
            DeviceResize(C)
          else
            RowResize(C);
        end;
        if C.Visible then
          ContentHeight := ContentHeight + C.Height + C.Margins.Bottom;
      end;
    Group.Height := ContentHeight + Group.Padding.Top + Group.Padding.Bottom;
  finally
    Group.EndUpdate;
  end;
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
  if (P.Tag = 1) or (P.TagObject = nil) then
    Exit;
  P.Padding.Rect := TRectF.Create(16, 12, 16, 12);
  var Text := TLayout(TLabel(P.TagObject).Parent);
  var Editors := FindComponent('Layout' + string(P.Name).Substring(5) + 'EditorContainer') as TLayout;
  if Editors = nil then
    Exit;
  Text.Align := TAlignLayout.Client;
  Text.Margins.Rect := TRectF.Empty;
  if Text.ChildrenCount > 1 then
    TControl(Text.Children[1]).Visible := True;
  var Narrow := P.Width < 600;
  P.Height := IfThen(Narrow, 134, 72);
  var W: Single := 220;
  if Editors.ChildrenCount > 0 then
  begin
    var Editor := TControl(Editors.Children[0]);
    if Editor is TSwitch then
      W := 64
    else if Editor is TLayout then
      W := 268;
    if Narrow and (Editor is TSwitch) then
    begin
      Editor.Align := TAlignLayout.Right;
      Editor.Width := 64;
    end
    else
      Editor.Align := TAlignLayout.Client;
    Editor.Margins.Rect := TRectF.Empty;
  end;
  if Narrow then
  begin
    Editors.Align := TAlignLayout.Bottom;
    Editors.Height := 32;
    Editors.Margins.Rect := TRectF.Create(0, 8, 0, 0);
  end
  else
  begin
    Editors.Align := TAlignLayout.Right;
    Editors.Width := Min(W, Max(0, P.Width - 32));
    Editors.Margins.Rect := TRectF.Create(16, 8, 0, 8);
  end;
  // Mobile FMX can resize aligned rows after the view's layout pass. Keep
  // card and scroll-content heights in sync with those final row sizes.
  if not FBuilding and not FArranging then
    Resize;
end;

procedure TSettingsView.DeviceResize(Sender: TObject);
begin
  if FDeviceArranging or (FDevices = nil) or (csDestroying in ComponentState) then
    Exit;
  FDeviceArranging := True;
  try
    var P := TPanel(Sender);
    for var D in FDevices do
      if (D.Control <> nil) and (D.Control.Owner = P) then
      begin
        var Slot := FindComponent('LayoutBindingPreview' + IntToStr(D.Port)) as TLayout;
        Slot.Visible := (D.Assignments = nil) or (P.Width >= 600);
        Slot.Align := TAlignLayout.Client;
        P.Height := 460;
        if D.Assignments <> nil then
        begin
          D.Assignments.Visible := True;
          D.Assignments.Align := TAlignLayout.Client;
          D.Assignments.Margins.Rect := TRectF.Create(0, 8, 0, 8);
          var BodyHeight := D.AssignmentList.Height + D.Assignments.Margins.Top + D.Assignments.Margins.Bottom;
          if Slot.Visible then
            if P.Width >= 850 then
            begin
              D.Assignments.Align := TAlignLayout.Right;
              D.Assignments.Width := 248;
              D.Assignments.Margins.Left := 12;
              BodyHeight := Max(BodyHeight, 280 + Slot.Margins.Top + Slot.Margins.Bottom);
            end
            else
            begin
              Slot.Align := TAlignLayout.Top;
              Slot.Height := 280;
              BodyHeight := BodyHeight + Slot.Height + Slot.Margins.Top + Slot.Margins.Bottom;
            end;
          var Header := FindComponent('LayoutRowButtonbindings' + IntToStr(D.Port) + 'Text') as TLayout;
          var Footer := FindComponent('LayoutBindingFooter' + IntToStr(D.Port)) as TLayout;
          P.Height := P.Padding.Top + P.Padding.Bottom +
            Header.Height + Header.Margins.Top + Header.Margins.Bottom +
            BodyHeight + Footer.Height + Footer.Margins.Top + Footer.Margins.Bottom;
        end;
        if D.Diagram is TDeviceCallouts then
          TDeviceCallouts(D.Diagram).ShowAnnotations(True);
      end;
  finally
    FDeviceArranging := False;
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
  if FBuilding or (SettingsPlatforms.Find(Index) = nil) then
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
  SyncPlatformSelection;
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

procedure TSettingsView.RefreshPlatformList;
begin
  var WasBuilding := FBuilding;
  FBuilding := True;
  ListBoxPlatforms.BeginUpdate;
  try
    ListBoxPlatforms.Clear;
    FPlatformPicker.Items.Clear;
    var Brand := '';
    var Matches := SettingsPlatforms.Matching(FPlatformSearch.Text);
    for var platform in Matches do
    begin
      if Brand <> platform.Brand then
      begin
        Brand := platform.Brand;
        var Header := TListBoxGroupHeader.Create(ListBoxPlatforms);
        Header.Parent := ListBoxPlatforms;
        Header.Text := Brand;
        Header.Height := 36;
        Header.HitTest := False;
        Header.Selectable := False;
      end;
      var Item := TListBoxItem.Create(ListBoxPlatforms);
      Item.Parent := ListBoxPlatforms;
      Item.Name := 'PlatformItem' + IntToStr(platform.PageId);
      Item.Tag := platform.PageId;
      Item.Text := Translate(platform.Name);
      Item.Height := 44;
      Item.TextSettings.HorzAlign := TTextAlign.Leading;
      Item.TextSettings.Trimming := TTextTrimming.Character;
      Item.TextSettings.WordWrap := False;
      Item.StylesData['text.Margins.Left'] := 44;
      CreatePlatformIcon(Item, platform.CoreId);
      Item.StyleLookup := 'listboxitemstyle';
      if platform.PageId = FCorePage then
        ListBoxPlatforms.ItemIndex := Item.Index;
    end;
    // The compact selector remains complete even when the sidebar is filtered.
    for var platform in SettingsPlatforms.Matching('') do
    begin
      var Index := FPlatformPicker.Items.AddObject(platform.Brand + ' · ' + Translate(platform.Name), platform);
      if platform.PageId = FCorePage then
        FPlatformPicker.ItemIndex := Index;
    end;
    LabelNoPlatforms.Visible := Length(Matches) = 0;
    LabelNoPlatforms.Text := Translate('No platforms found');
    FPlatformSearch.TextPrompt := Translate('Search platforms');
  finally
    ListBoxPlatforms.EndUpdate;
    FBuilding := WasBuilding;
  end;
end;

procedure TSettingsView.PlatformSearchChange(Sender: TObject);
begin
  if not FBuilding then
    RefreshPlatformList;
end;

procedure TSettingsView.SyncPlatformSelection;
begin
  var WasBuilding := FBuilding;
  FBuilding := True;
  try
    ListBoxPlatforms.ItemIndex := -1;
    for var I := 0 to ListBoxPlatforms.Count - 1 do
      if ListBoxPlatforms.ListItems[I].Tag = FCorePage then
      begin
        ListBoxPlatforms.ItemIndex := I;
        Break;
      end;
    for var I := 0 to FPlatformPicker.Items.Count - 1 do
      if TSettingsPlatform(FPlatformPicker.Items.Objects[I]).PageId = FCorePage then
      begin
        FPlatformPicker.ItemIndex := I;
        Break;
      end;
  finally
    FBuilding := WasBuilding;
  end;
end;

procedure TSettingsView.PlatformSelectionChange(Sender: TObject);
begin
  if not FBuilding and (ListBoxPlatforms.Selected <> nil) and
    (ListBoxPlatforms.Selected.Tag > 0) then
    SelectCore(ListBoxPlatforms.Selected.Tag, True);
end;

procedure TSettingsView.PlatformPickerChange(Sender: TObject);
begin
  if not FBuilding and (FPlatformPicker.ItemIndex >= 0) then
    SelectCore(TSettingsPlatform(FPlatformPicker.Items.Objects[FPlatformPicker.ItemIndex]).PageId, True);
end;

procedure TSettingsView.SearchChange(Sender: TObject);
begin
  if FBuilding or (LayoutContent = nil) then
    Exit;

  var Query := FSearch.Text.Trim.ToLower;
  for var Column in [LayoutSettingsMainColumn, LayoutSettingsPreviewColumn] do
    for var I := 0 to Column.ChildrenCount - 1 do
      if Column.Children[I] is TPanel then
      begin
        var Group := TPanel(Column.Children[I]);
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
  if FPage = SETTINGS_PAGE_GW then
  begin
    // The handheld's controls are built in; only host input bindings are configurable.
    FDrafts[FPage].WriteString('Ports', Key, 'pad');
    BuildBindings(Port, 'pad');
    Exit;
  end;
  var Device := FDrafts[FPage].ReadString('Ports', Key, 'auto');
  var Options := SettingsPlatforms.Find(FPage).PortOptions(Port);
  var C := Combo(Options.RowName, 'Ports', Key, Options.Labels, Options.Values, Options.Default);
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

  procedure AddAssignment(D: TSettingsDevice; Panel: TPanel; Action: Integer; const Caption: string);
  begin
    var Binding := SettingsButton(Panel);
    Binding.Parent := D.AssignmentList;
    Binding.Align := TAlignLayout.Top;
    Binding.Height := 32;
    Binding.Margins.Rect := RectF(8, 4, 8, 4);
    Binding.Index := D.AssignmentList.ChildrenCount - 1;
    Binding.Tag := Action;
    Binding.TagObject := D;
    Binding.TagString := Caption;
    Binding.Text := Translate(Caption) + '   ·   ' + BindingCaption(FInput, Action);
    Binding.OnClick := AssignmentClick;
    Binding.Enabled := FInput <> nil;
  end;

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
    Pad.Configure(TPlatformRegistry.Require(SettingsCoreIds[FPage]).System, Device,
      CoreButtons(SettingsCoreIds[FPage], Device));
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
  (FindComponent('LayoutPadAssignments' + IntToStr(Port)) as TControl).Visible := False;
  if (FPage = SETTINGS_PAGE_GW) or (D.Control is TScreenGamepad) then
  begin
    D.Assignments := FindComponent('LayoutPadAssignments' + IntToStr(Port)) as TLayout;
    D.Assignments.Visible := True;
    D.AssignmentList := FindComponent('LayoutPadAssignmentList' + IntToStr(Port)) as TLayout;
    var Y: Single := 8;
    for var B in CoreButtons(SettingsCoreIds[FPage], Device) do
    begin
      AddAssignment(D, P, PadAction(Port, B), CoreButtonName(SettingsCoreIds[FPage], B));
      Y := Y + 40;
    end;
    if SettingsCoreIds[FPage] = ROM_SYSTEM_N64 then
    begin
      AddAssignment(D, P, N64LAction + Port, 'L');
      Y := Y + 40;
    end;
    // A digital pad has only L2 beyond the logical pad.
    if SettingsCoreIds[FPage] = ROM_SYSTEM_PS1 then
      for var Extra := Low(TPS1Extra) to High(TPS1Extra) do
        if (Extra = TPS1Extra.L2) or (Device = 'pad-analog') then
        begin
          AddAssignment(D, P, PS1Action(Port, Extra), PS1ExtraName(Extra));
          Y := Y + 40;
        end;
    D.AssignmentList.Height := Y;
  end;
  Preview.Parent := FindComponent('LayoutBindingPreview' + IntToStr(Port)) as TLayout;
  Preview.Align := TAlignLayout.Client;
  Preview.Margins.Rect := TRectF.Empty;
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
          B.Text := Translate(B.TagString) + '   ·   ' + BindingCaption(FInput, B.Tag);
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
    if (D.Diagram = LabelControl.Parent) or ((LabelControl.Parent <> nil) and (D.Diagram = LabelControl.Parent.Parent)) then
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
      begin
        if (SettingsCoreIds[FPage] = ROM_SYSTEM_N64) and
          ((TScreenGamepad(Sender).AuxiliaryButtons and 1) <> 0) then
        begin
          Action := N64LAction + D.Port;
          Caption := Translate('Button ') + 'L';
        end;
        if SettingsCoreIds[FPage] = ROM_SYSTEM_PS1 then
          for var Extra := Low(TPS1Extra) to High(TPS1Extra) do
            if (TScreenGamepad(Sender).AuxiliaryButtons and (1 shl Ord(Extra))) <> 0 then
            begin
              Action := PS1Action(D.Port, Extra);
              Caption := Translate('Button ') + Translate(PS1ExtraName(Extra));
            end;
        for var B in TScreenGamepad(Sender).Buttons do
          if B in CoreButtons(SettingsCoreIds[FPage], D.Device) then
          begin
            Action := PadAction(D.Port, B);
            Caption := Translate('Button ') + Translate(CoreButtonName(SettingsCoreIds[FPage], B));
            Break;
          end;
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
  if FBuilding then
    Exit;
  StorePage;
  if (FPage = SETTINGS_PAGE_GB) and (FPreview is TSettingsPreview) then
    TSettingsPreview(FPreview).PaletteIndex :=
      (FindComponent('SettingsComboBoxRowGameBoypaletteEditor') as TComboBox).ItemIndex;
  UpdateShaderPreview;
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
      end;
    end);
end;

procedure TSettingsView.DetectRomFoldersClick(Sender: TObject);
begin
  CancelCapture;
  StorePage;
  var Alive: TFunc<Boolean> := FAlive;
  PickLocation(True, '',
    procedure(const Selection: TStorageSelection)
    begin
      if not Alive() then
        Exit;
      if Selection.Error <> '' then
        LabelStatus.Text := Selection.Error
      else if not Selection.Cancelled then
      try
        var Count := 0;
        for var platform in TPlatformRegistry.All do
        begin
          var Folder := FStorage.DetectRomFolder(Selection.Location, platform.Id);
          if Folder = '' then
            Continue;
          FDrafts[SETTINGS_PAGE_MAIN].WriteString('RomFolders', platform.Id, Folder);
          Inc(Count);
        end;
        if (FPage = SETTINGS_PAGE_MAIN) and (FCategory = SETTINGS_CATEGORY_LIBRARY) then
          BuildPage(True);
        LabelStatus.Text := Format(Translate('Platform folders found: %d. Click Apply to save changes.'), [Count]);
      except
        on E: Exception do
          LabelStatus.Text := E.Message;
      end;
    end);
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
    for var platform in TPlatformRegistry.All do
    begin
      var Folder := FDrafts[SETTINGS_PAGE_MAIN].ReadString('RomFolders', platform.Id, '').Trim;
      if (Folder <> '') and not FStorage.FolderExists(Folder) then
        raise Exception.Create(platform.Name + ': ' + Translate('ROM folder not found. Choose an existing folder.'));
    end;
    FDrafts[SETTINGS_PAGE_MAIN].DeleteKey('General', 'Path');

    for var platform in SettingsPlatforms.Items do
    begin
      var Draft := FDrafts[platform.PageId];
      Draft.DeleteKey('Audio', 'Enabled');
      Draft.DeleteKey('Audio', 'FMEnabled');
      Draft.DeleteKey('SegaCD', 'AudioEnabled');
      Draft.DeleteKey('Sega32X', 'AudioEnabled');
      platform.Validate(Draft);
    end;

    // Config writes are per core and retain all settings that this UI does not expose.
    for var Ini in FDrafts do
      if Ini <> nil then
        FStorage.WriteConfig(Ini);
    if Assigned(FOnApply) then
      FOnApply(Self);
    LabelStatus.Text := Translate('Saved. Runtime settings applied. Hardware and boot options apply when you next open a ROM.');
  except
    on E: Exception do
      LabelStatus.Text := Translate('Unable to save settings: ') + E.Message;
  end;
  UpdateConfigurationNotice;
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
  RefreshPlatformList;
  BuildPage(True);
end;

procedure TSettingsView.BackClick(Sender: TObject);
begin
  CancelCapture;
  if Assigned(FOnClose) then
    FOnClose(Self);
end;

initialization
  SettingsCoreIds := RM.Settings.Catalog.SettingsCoreIds;
  SettingsPageNames := RM.Settings.Catalog.SettingsPageNames;
  SettingsCoreOrder := RM.Settings.Catalog.SettingsCoreOrder;
  TPresentationProxyFactory.Current.Register(TSettingsSpinBox, TControlType.Styled,
    TStyledPresentationProxy<TSettingsSpinBoxStyle>);

finalization
  TPresentationProxyFactory.Current.Unregister(TSettingsSpinBox, TControlType.Styled,
    TStyledPresentationProxy<TSettingsSpinBoxStyle>);

end.

