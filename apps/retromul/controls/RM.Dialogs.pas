unit RM.Dialogs;

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, FMX.Types,
  FMX.Controls, FMX.Forms, FMX.Layouts, FMX.Objects, FMX.StdCtrls,
  FMX.Controls.Presentation;

type
  TRetroDialogKind = (Information, Warning, Error, Confirmation, Loading);

  TRetroDialog = class(TFrame)
    RectangleBackdrop: TRectangle;
    PanelCard: TPanel;
    RectangleAccent: TRectangle;
    CircleBadge: TCircle;
    LabelBadge, LabelTitle, LabelMessage: TLabel;
    VertScrollBoxMessage: TVertScrollBox;
    ButtonClose, ButtonCancel, ButtonAccept: TButton;
  private
    FReady, FConfirmation, FLoading: Boolean;
    FBusyIndicator: TAniIndicator;
    FOnResult: TProc<Boolean>;
    procedure AcceptClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
    procedure Arrange;
  protected
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Configure(const Text: string; Kind: TRetroDialogKind; const OnResult: TProc<Boolean>);
    procedure FocusDefault;
    procedure HandleKey(var Key: Word; var KeyChar: WideChar);
  end;

// All dialogs are asynchronous and belong to the host form. Call on the UI thread.
procedure ShowRetroMessage(Owner: TComponent; const Text: string; Kind: TRetroDialogKind = TRetroDialogKind.Error);

procedure ShowRetroConfirmation(Owner: TComponent; const Text: string; const OnResult: TProc<Boolean>);

procedure ShowRetroLoading(Owner: TComponent; const Text: string; const OnCancel: TProc);

procedure CloseRetroLoading(Owner: TComponent);

procedure SetRetroDialogActivity(Owner: TCustomForm; OnActivity: TNotifyEvent);

function RetroDialogVisible(Owner: TCustomForm): Boolean;

function HandleRetroDialogKey(Owner: TCustomForm; var Key: Word; var KeyChar: WideChar): Boolean;

implementation

uses
  System.Math, System.Generics.Collections, FMX.TextLayout, FMX.Graphics,
  RM.Icons;

{$R *.fmx}

type
  TDialogRequest = class
    Requester: TComponent;
    Text: string;
    Kind: TRetroDialogKind;
    OnResult: TProc<Boolean>;
  end;

  TRetroDialogHost = class(TComponent)
  private
    FForm: TCustomForm;
    FDialog: TRetroDialog;
    FQueue: TObjectList<TDialogRequest>;
    FActive: TDialogRequest;
    FBlocked: TList<TControl>;
    FPreviousFocus: TControl;
    FCompleting, FModal: Boolean;
    FOnActivity: TNotifyEvent;
    procedure BeginModal;
    procedure EndModal;
    procedure ShowNext;
    procedure Complete(Confirmed: Boolean; InvokeCallback: Boolean = True);
  protected
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Enqueue(Requester: TComponent; const Text: string; Kind: TRetroDialogKind; const OnResult: TProc<Boolean>);
  end;

function FindHost(Form: TCustomForm; CreateIfMissing: Boolean): TRetroDialogHost;
begin
  Result := nil;
  if (Form = nil) or (csDestroying in Form.ComponentState) then
    Exit;

  for var i := 0 to Form.ComponentCount - 1 do
    if Form.Components[i] is TRetroDialogHost then
      Exit(TRetroDialogHost(Form.Components[i]));

  if CreateIfMissing then
    Result := TRetroDialogHost.Create(Form);
end;

function OwnerForm(Owner: TComponent): TCustomForm;
begin
  while Owner <> nil do
  begin
    if Owner is TCustomForm then
      Exit(TCustomForm(Owner));

    if (Owner is TControl) and (TControl(Owner).Root <> nil) and (TControl(Owner).Root.GetObject is TCustomForm) then
      Exit(TCustomForm(TControl(Owner).Root.GetObject));

    Owner := Owner.Owner;
  end;
  Result := nil;
  if Application.MainForm is TCustomForm then
    Result := TCustomForm(Application.MainForm);
end;

procedure ShowRetroMessage(Owner: TComponent; const Text: string; Kind: TRetroDialogKind);
begin
  var Host := FindHost(OwnerForm(Owner), True);
  if Host <> nil then
    Host.Enqueue(Owner, Text, Kind, nil);
end;

procedure ShowRetroConfirmation(Owner: TComponent; const Text: string; const OnResult: TProc<Boolean>);
begin
  var Host := FindHost(OwnerForm(Owner), True);
  if Host <> nil then
    Host.Enqueue(Owner, Text, TRetroDialogKind.Confirmation, OnResult);
end;

procedure SetRetroDialogActivity(Owner: TCustomForm; OnActivity: TNotifyEvent);
begin
  var Host := FindHost(Owner, True);
  if Host <> nil then
    Host.FOnActivity := OnActivity;
end;

procedure ShowRetroLoading(Owner: TComponent; const Text: string; const OnCancel: TProc);
begin
  var Host := FindHost(OwnerForm(Owner), True);
  if Host <> nil then
    Host.Enqueue(Owner, Text, TRetroDialogKind.Loading,
      procedure(Confirmed: Boolean)
      begin
        if Assigned(OnCancel) then
          OnCancel();
      end);
end;

procedure CloseRetroLoading(Owner: TComponent);
begin
  var Host := FindHost(OwnerForm(Owner), False);
  if Host = nil then
    Exit;

  for var i := Host.FQueue.Count - 1 downto 0 do
    if (Host.FQueue[i].Requester = Owner) and (Host.FQueue[i].Kind = TRetroDialogKind.Loading) then
      Host.FQueue.Delete(i);
  if (Host.FActive <> nil) and (Host.FActive.Requester = Owner) and (Host.FActive.Kind = TRetroDialogKind.Loading) then
    Host.Complete(False, False);
end;

function RetroDialogVisible(Owner: TCustomForm): Boolean;
begin
  var Host := FindHost(Owner, False);
  Result := (Host <> nil) and Host.FModal;
end;

function HandleRetroDialogKey(Owner: TCustomForm; var Key: Word; var KeyChar: WideChar): Boolean;
begin
  var Host := FindHost(Owner, False);
  Result := (Host <> nil) and (Host.FActive <> nil);
  if Result then
    Host.FDialog.HandleKey(Key, KeyChar);
end;

constructor TRetroDialog.Create(AOwner: TComponent);
begin
  inherited;
  Visible := False;
  ButtonAccept.OnClick := AcceptClick;
  ButtonCancel.OnClick := CancelClick;
  ButtonClose.OnClick := CancelClick;
  AddButtonIcon(ButtonClose, IconClose, 16);

  FBusyIndicator := TAniIndicator.Create(Self);
  FBusyIndicator.Name := 'LoadingIndicator';
  FBusyIndicator.Parent := CircleBadge;
  FBusyIndicator.Align := TAlignLayout.Client;
  FBusyIndicator.HitTest := False;
  FBusyIndicator.Visible := False;
  FBusyIndicator.Margins.Rect := RectF(-6, -6, 0, 0);

  FReady := True;
end;

procedure TRetroDialog.Configure(const Text: string; Kind: TRetroDialogKind; const OnResult: TProc<Boolean>);
const
  Titles: array[TRetroDialogKind] of string = ('Information', 'Warning', 'Error', 'Confirmation', 'Loading...');
  Symbols: array[TRetroDialogKind] of string = ('i', '!', '!', '?', '');
begin
  FOnResult := OnResult;
  FConfirmation := Kind = TRetroDialogKind.Confirmation;
  FLoading := Kind = TRetroDialogKind.Loading;
  FBusyIndicator.Visible := FLoading;
  FBusyIndicator.Enabled := FLoading;
  LabelBadge.Visible := not FLoading;
  ButtonAccept.Visible := not FLoading;
  LabelTitle.Text := Translate(Titles[Kind]);
  LabelBadge.Text := Symbols[Kind];
  LabelMessage.Text := Text;
  ButtonClose.Hint := Translate('Close');
  ButtonCancel.Text := Translate('Cancel');
  if FConfirmation then
    ButtonAccept.Text := Translate('Confirm')
  else
    ButtonAccept.Text := Translate('OK');
  ButtonCancel.Visible := FConfirmation or FLoading;
  VertScrollBoxMessage.ViewportPosition := TPointF.Zero;
  Arrange;
end;

procedure TRetroDialog.FocusDefault;
begin
  if FConfirmation or FLoading then
    ButtonCancel.SetFocus
  else
    ButtonAccept.SetFocus;
end;

procedure TRetroDialog.AcceptClick(Sender: TObject);
begin
  var Callback := FOnResult;
  if Assigned(Callback) then
    Callback(True);
end;

procedure TRetroDialog.CancelClick(Sender: TObject);
begin
  var Callback := FOnResult;
  if Assigned(Callback) then
    Callback(False);
end;

procedure TRetroDialog.HandleKey(var Key: Word; var KeyChar: WideChar);
begin
  if (Key = vkEscape) {$IFDEF ANDROID} or (Key = vkHardwareBack){$ENDIF} then
    CancelClick(Self)
  else if Key = vkReturn then
  begin
    if FLoading or (FConfirmation and not ButtonAccept.IsFocused) or ButtonClose.IsFocused then
      CancelClick(Self)
    else
      AcceptClick(Self);
  end;

  // Tab is handled by FMX; the rest must never reach game shortcuts.
  if Key <> vkTab then
  begin
    Key := 0;
    KeyChar := #0;
  end;
end;

procedure TRetroDialog.Resize;
begin
  inherited;
  if FReady and not (csLoading in ComponentState) then
    Arrange;
end;

procedure TRetroDialog.Arrange;
begin
  var W := Max(1, Min(560, Width - 32));
  var Padding := Min(24, Max(8, W / 12));
  var TextWidth := Max(1, W - Padding * 2 - 16);
  var TextHeight: Single;

  var Layout := TTextLayoutManager.DefaultTextLayout.Create;
  try
    Layout.BeginUpdate;
    Layout.Font.Assign(LabelMessage.TextSettings.Font);
    Layout.MaxSize := TPointF.Create(TextWidth, 100000);
    Layout.WordWrap := True;
    Layout.Text := LabelMessage.Text;
    Layout.EndUpdate;
    TextHeight := Max(24, Ceil(Layout.TextHeight) + 8);
  finally
    Layout.Free;
  end;

  var FixedHeight := Padding * 2 + 44 + 16 + 16 + 42;
  var BodyHeight := Min(TextHeight, Max(0, Height - 32 - FixedHeight));
  var H := FixedHeight + BodyHeight;
  // Center alignment places the card; its rows own all child geometry.
  PanelCard.Width := W;
  PanelCard.Height := H;
  PanelCard.Padding.Rect := TRectF.Create(Padding, Padding, Padding, Padding);
  VertScrollBoxMessage.Height := BodyHeight;
  LabelMessage.Height := TextHeight;
  var ButtonWidth := Min(148, W - Padding * 2);
  if FConfirmation then
    ButtonWidth := Min(ButtonWidth, (W - Padding * 2 - 12) / 2);
  ButtonAccept.Width := ButtonWidth;
  ButtonCancel.Width := ButtonWidth;
  ButtonCancel.Margins.Right := IfThen(FLoading, 0, 12);
end;

constructor TRetroDialogHost.Create(AOwner: TComponent);
begin
  inherited;
  FForm := AOwner as TCustomForm;
  FQueue := TObjectList<TDialogRequest>.Create;
  FBlocked := TList<TControl>.Create;
  FDialog := TRetroDialog.Create(Self);
  FDialog.Parent := FForm;
  FDialog.Align := TAlignLayout.Contents;
end;

destructor TRetroDialogHost.Destroy;
begin
  FOnActivity := nil;
  FDialog.Free;
  FActive.Free;
  FQueue.Free;
  FBlocked.Free;
  inherited;
end;

procedure TRetroDialogHost.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited;
  if Operation <> TOperation.opRemove then
    Exit;

  if AComponent = FDialog then
    FDialog := nil;
  if AComponent = FPreviousFocus then
    FPreviousFocus := nil;
  if (FBlocked <> nil) and (AComponent is TControl) then
    FBlocked.Remove(TControl(AComponent));
  if FQueue <> nil then
    for var i := FQueue.Count - 1 downto 0 do
      if FQueue[i].Requester = AComponent then
        FQueue.Delete(i);

  if (FActive <> nil) and (FActive.Requester = AComponent) and
    not (csDestroying in ComponentState) and not (csDestroying in FForm.ComponentState) then
    Complete(False, False);
end;

procedure TRetroDialogHost.BeginModal;
begin
  if FModal then
    Exit;

  FModal := True;
  if (FForm.Focused <> nil) and (FForm.Focused.GetObject is TControl) then
  begin
    FPreviousFocus := TControl(FForm.Focused.GetObject);
    FPreviousFocus.FreeNotification(Self);
  end;

  // Disable only controls that were enabled, preserving their original state.
  for var i := 0 to FForm.ChildrenCount - 1 do
    if (FForm.Children[i] is TControl) and (FForm.Children[i] <> FDialog) then
    begin
      var Control := TControl(FForm.Children[i]);
      if Control.Enabled then
      begin
        FBlocked.Add(Control);
        Control.FreeNotification(Self);
        Control.Enabled := False;
      end;
    end;

  if Assigned(FOnActivity) then
    FOnActivity(Self);
end;

procedure TRetroDialogHost.EndModal;
begin
  FModal := False;
  FDialog.Visible := False;
  FDialog.FBusyIndicator.Enabled := False;
  for var Control in FBlocked do
    Control.Enabled := True;
  FBlocked.Clear;
  if (FPreviousFocus <> nil) and FPreviousFocus.CanFocus and FPreviousFocus.IsVisible and FPreviousFocus.Enabled then
    FPreviousFocus.SetFocus;
  FPreviousFocus := nil;
  if Assigned(FOnActivity) then
    FOnActivity(Self);
end;

procedure TRetroDialogHost.ShowNext;
begin
  if FCompleting or (FActive <> nil) or (csDestroying in FForm.ComponentState) then
    Exit;

  if FQueue.Count = 0 then
  begin
    if FModal then
      EndModal;
    Exit;
  end;

  FActive := FQueue.Extract(FQueue[0]);
  BeginModal;
  FDialog.Configure(FActive.Text, FActive.Kind,
    procedure(Confirmed: Boolean)
    begin
      Complete(Confirmed);
    end);
  FDialog.Visible := True;
  FDialog.BringToFront;
  FDialog.FocusDefault;
end;

procedure TRetroDialogHost.Complete(Confirmed: Boolean; InvokeCallback: Boolean);
begin
  if (FActive = nil) or FCompleting then
    Exit;

  var Callback := FActive.OnResult;
  FreeAndNil(FActive);
  FCompleting := True;
  try
    if InvokeCallback and Assigned(Callback) then
      Callback(Confirmed);
  finally
    FCompleting := False;
    ShowNext;
  end;
end;

procedure TRetroDialogHost.Enqueue(Requester: TComponent; const Text: string; Kind: TRetroDialogKind; const OnResult: TProc<Boolean>);
begin
  if not Assigned(OnResult) then
  begin
    if (FActive <> nil) and (FActive.Text = Text) and (FActive.Kind = Kind) then
      Exit;

    for var Queued in FQueue do
      if (Queued.Text = Text) and (Queued.Kind = Kind) then
        Exit;
  end;

  var Request := TDialogRequest.Create;
  Request.Requester := Requester;
  Request.Text := Text;
  Request.Kind := Kind;
  Request.OnResult := OnResult;
  if Requester <> nil then
    Requester.FreeNotification(Self);
  FQueue.Add(Request);
  ShowNext;
end;

end.

