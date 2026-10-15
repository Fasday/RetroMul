unit RM.VirtualController;

interface

uses
  System.Classes, System.Types, System.UITypes, System.Generics.Collections,
  FMX.Types, FMX.Controls, FMX.Graphics;

type
  TVirtualSide = (Left, Right);

  TVirtualController = class;

  TVirtualElement = class;

  TVirtualInputEvent = procedure(Sender: TObject; Element: TVirtualElement; Part: Integer; Value: Single) of object;

  // Extend this class to introduce another input type. Geometry is in logical
  // side coordinates; PartBounds, HitParts and Paint share the same geometry.
  TVirtualElement = class abstract(TPersistent)
  private
    FController: TVirtualController;
    FId, FCaption: string;
    FSide: TVirtualSide;
    FBounds: TRectF;
    FValues, FFeedback: TArray<Single>;
    FPartEnabled: TArray<Boolean>;
    FCaptureGroup: string;
    FRetainOnSlide: Boolean;
    function GetPartEnabled(Part: Integer): Boolean;
    procedure SetPartEnabled(Part: Integer; Value: Boolean);
    function GetFeedback(Part: Integer): Single;
    procedure SetFeedback(Part: Integer; Value: Single);
    procedure SetBounds(const Value: TRectF);
    procedure SetSide(Value: TVirtualSide);
    procedure SetCaption(const Value: string);
  protected
    function LocalPartBounds(Part: Integer): TRectF; virtual;
    function HitParts(const P: TPointF): TArray<Integer>; virtual;
    function InputValue(const P: TPointF): Single; virtual;
    function PartInputValue(Part: Integer; const P: TPointF): Single; virtual;
    procedure Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single); virtual; abstract;
    procedure DrawLabel(Canvas: TCanvas; const R: TRectF; const Text: string; Alpha: Single);
  public
    constructor Create(const AId, ACaption: string; ASide: TVirtualSide; const ABounds: TRectF; PartCount: Integer = 1); virtual;
    function Value(Part: Integer = 0): Single;
    function PartCount: Integer;
    function VisualValue(Part: Integer = 0): Single;
    function HasEnabledParts: Boolean;
    property PartEnabled[Part: Integer]: Boolean read GetPartEnabled write SetPartEnabled;
    property Feedback[Part: Integer]: Single read GetFeedback write SetFeedback;
    // Nonempty groups enable rolling between action buttons with one contact.
    property CaptureGroup: string read FCaptureGroup write FCaptureGroup;
    property RetainOnSlide: Boolean read FRetainOnSlide write FRetainOnSlide;
    property Id: string read FId;
    property Caption: string read FCaption write SetCaption;
    property Side: TVirtualSide read FSide write SetSide;
    property Bounds: TRectF read FBounds write SetBounds;
    property Controller: TVirtualController read FController;
  end;

  TVirtualButton = class(TVirtualElement)
  protected
    function HitParts(const P: TPointF): TArray<Integer>; override;
    procedure Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single); override;
  end;

  TVirtualKey = class(TVirtualElement)
  protected
    procedure Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single); override;
  end;

  TVirtualDPad = class(TVirtualElement)
  public
    const
      Up = 0;
      Down = 1;
      Left = 2;
      Right = 3;
  protected
    function LocalPartBounds(Part: Integer): TRectF; override;
    function HitParts(const P: TPointF): TArray<Integer>; override;
    procedure Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single); override;
  public
    constructor Create(const AId, ACaption: string; ASide: TVirtualSide; const ABounds: TRectF; PartCount: Integer = 4); override;
  end;

  TVirtualStick = class(TVirtualElement)
  protected
    function HitParts(const P: TPointF): TArray<Integer>; override;
    function PartInputValue(Part: Integer; const P: TPointF): Single; override;
    procedure Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single); override;
  public
    constructor Create(const AId, ACaption: string; ASide: TVirtualSide; const ABounds: TRectF; PartCount: Integer = 4); override;
    function AxisX: Single;
    function AxisY: Single;
  end;

  TVirtualSwitch = class(TVirtualElement)
  private
    FLatched: Boolean;
  protected
    procedure Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single); override;
  end;

  TVirtualTrigger = class(TVirtualElement)
  protected
    function InputValue(const P: TPointF): Single; override;
    procedure Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single); override;
  end;

  TVirtualController = class(TControl)
  private
    type
      TContact = record
        Element: TVirtualElement;
        Point, Position: TPointF;
        HoldAnchor: Boolean;
      end;
  private
    FElements: TObjectList<TVirtualElement>;
    FContacts: TDictionary<NativeInt, TContact>;
    FScale, FInkOpacity: Single;
    FDesignSideSize: TSizeF;
    FOnInput: TVirtualInputEvent;
    FOnGeometryChanged: TNotifyEvent;
    function GetCount: Integer;
    function GetElement(Index: Integer): TVirtualElement;
    procedure SetScale(Value: Single);
    procedure SetDesignSideSize(const Value: TSizeF);
    procedure SetInkOpacity(Value: Single);
    procedure Recompute;
    function GroupBounds(Element: TVirtualElement): TRectF;
    function ToSide(const P: TPointF; Side: TVirtualSide): TPointF;
    function TransformRect(const R: TRectF; Side: TVirtualSide): TRectF;
  protected
    procedure InputChanged; virtual;
    procedure Paint; override;
    procedure Resize; override;
    procedure EnabledChanged; override;
    procedure VisibleChanged; override;
    procedure AncestorVisibleChanged(const Visible: Boolean); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Single); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
  public
    const
      SideWidth = 240;
      DesignHeight = 320;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    // Ownership transfers only after successful Add; IDs must be unique.
    function Add(Element: TVirtualElement): TVirtualElement;
    procedure Remove(Element: TVirtualElement);
    procedure Clear;
    procedure GeometryChanged;
    function Find(const Id: string): TVirtualElement;
    function EffectiveScale: Single;
    function SideBounds(Side: TVirtualSide): TRectF;
    function ElementBounds(Element: TVirtualElement): TRectF;
    function PartBounds(Element: TVirtualElement; Part: Integer): TRectF;
    function PartCenter(Element: TVirtualElement; Part: Integer): TPointF;
    // All input positions and returned bounds are relative to this control.
    // Forward platform contacts here; IDs allow simultaneous independent input.
    procedure PointerDown(Id: NativeInt; const P: TPointF);
    procedure PointerMove(Id: NativeInt; const P: TPointF);
    procedure PointerUp(Id: NativeInt);
    procedure ReleaseAll; virtual;
    property Count: Integer read GetCount;
    property Elements[Index: Integer]: TVirtualElement read GetElement; default;
    property DesignSideSize: TSizeF read FDesignSideSize write SetDesignSideSize;
    property LayoutScale: Single read FScale write SetScale;
    property InkOpacity: Single read FInkOpacity write SetInkOpacity;
    property OnInput: TVirtualInputEvent read FOnInput write FOnInput;
    property OnGeometryChanged: TNotifyEvent read FOnGeometryChanged write FOnGeometryChanged;
  end;

implementation

uses
  System.SysUtils, System.Math;

constructor TVirtualElement.Create(const AId, ACaption: string; ASide: TVirtualSide; const ABounds: TRectF; PartCount: Integer);
begin
  inherited Create;
  if (AId = '') or (PartCount < 1) then
    raise EArgumentException.Create('Element needs an ID and at least one part');
  FRetainOnSlide := True;
  FId := AId;
  FCaption := ACaption;
  FSide := ASide;
  SetLength(FValues, PartCount);
  SetLength(FFeedback, PartCount);
  SetLength(FPartEnabled, PartCount);
  for var I := 0 to PartCount - 1 do FPartEnabled[I] := True;
  SetBounds(ABounds);
end;

procedure TVirtualElement.SetBounds(const Value: TRectF);
begin
  if IsNan(Value.Left) or IsNan(Value.Top) or IsNan(Value.Right) or IsNan(Value.Bottom) or
    IsInfinite(Value.Left) or IsInfinite(Value.Top) or IsInfinite(Value.Right) or IsInfinite(Value.Bottom) or
    (Value.Left < 0) or (Value.Top < 0) or (Value.Width < 1) or (Value.Height < 1) then
    raise EArgumentException.Create('Bounds must be finite, nonnegative and have positive size');
  if (FController <> nil) and ((Value.Right > FController.DesignSideSize.Width) or
    (Value.Bottom > FController.DesignSideSize.Height)) then
    raise EArgumentException.Create('Bounds must fit the logical side');
  FBounds := Value;
  if FController <> nil then
    FController.GeometryChanged;
end;

procedure TVirtualElement.SetSide(Value: TVirtualSide);
begin
  if FSide = Value then
    Exit;
  FSide := Value;
  if FController <> nil then
    FController.GeometryChanged;
end;

procedure TVirtualElement.SetCaption(const Value: string);
begin
  FCaption := Value;
  if FController <> nil then
    FController.Repaint;
end;

function TVirtualElement.LocalPartBounds(Part: Integer): TRectF;
begin
  Result := FBounds;
end;

function TVirtualElement.HitParts(const P: TPointF): TArray<Integer>;
begin
  Result := nil;
  if FBounds.Contains(P) then
    Result := [0];
end;

function TVirtualElement.InputValue(const P: TPointF): Single;
begin
  Result := 1;
end;

function TVirtualElement.PartInputValue(Part: Integer; const P: TPointF): Single;
begin
  Result := InputValue(P);
end;

constructor TVirtualStick.Create(const AId, ACaption: string; ASide: TVirtualSide; const ABounds: TRectF; PartCount: Integer);
begin
  inherited Create(AId, ACaption, ASide, ABounds, 4);
end;

function TVirtualStick.HitParts(const P: TPointF): TArray<Integer>;
begin
  Result := [0, 1, 2, 3];
end;

function TVirtualStick.PartInputValue(Part: Integer; const P: TPointF): Single;
begin
  var X := (P.X - Bounds.CenterPoint.X) / (Bounds.Width / 2);
  var Y := (P.Y - Bounds.CenterPoint.Y) / (Bounds.Height / 2);
  var Magnitude := Sqrt(Sqr(X) + Sqr(Y));
  if Magnitude <= 0.12 then Exit(0);
  var Amount := Min(1.0, (Magnitude - 0.12) / 0.88);
  X := X / Magnitude * Amount;
  Y := Y / Magnitude * Amount;
  case Part of
    0: Result := Max(0.0, -Y);
    1: Result := Max(0.0, Y);
    2: Result := Max(0.0, -X);
    3: Result := Max(0.0, X);
  else Result := 0;
  end;
end;

function TVirtualStick.AxisX: Single;
begin Result := Value(3) - Value(2); end;

function TVirtualStick.AxisY: Single;
begin Result := Value(1) - Value(0); end;

procedure TVirtualStick.Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single);
begin
  Canvas.Stroke.Color := TAlphaColors.White;
  Canvas.Stroke.Thickness := 1.5;
  Canvas.Fill.Color := TAlphaColors.White;
  Canvas.FillEllipse(Bounds, Alpha * 0.08);
  Canvas.DrawEllipse(Bounds, Alpha);
  var Center := Bounds.CenterPoint + PointF(AxisX * Bounds.Width * 0.28, AxisY * Bounds.Height * 0.28);
  var Radius := Min(Bounds.Width, Bounds.Height) * 0.2;
  var Knob := RectF(Center.X - Radius, Center.Y - Radius, Center.X + Radius, Center.Y + Radius);
  Canvas.FillEllipse(Knob, Alpha * 0.3);
  Canvas.DrawEllipse(Knob, Alpha);
end;

function TVirtualElement.Value(Part: Integer): Single;
begin
  if (Part < 0) or (Part >= Length(FValues)) then
    raise EArgumentOutOfRangeException.Create('Part');
  Result := FValues[Part];
end;

function TVirtualElement.PartCount: Integer;
begin
  Result := Length(FValues);
end;

function TVirtualElement.GetPartEnabled(Part: Integer): Boolean;
begin
  if (Part < 0) or (Part >= PartCount) then raise EArgumentOutOfRangeException.Create('Part');
  Result := FPartEnabled[Part];
end;

procedure TVirtualElement.SetPartEnabled(Part: Integer; Value: Boolean);
begin
  if (Part < 0) or (Part >= PartCount) then raise EArgumentOutOfRangeException.Create('Part');
  if FPartEnabled[Part] = Value then Exit;
  FPartEnabled[Part] := Value;
  if FController <> nil then FController.GeometryChanged;
end;

function TVirtualElement.HasEnabledParts: Boolean;
begin
  Result := False;
  for var Enabled in FPartEnabled do if Enabled then Exit(True);
end;

function TVirtualElement.GetFeedback(Part: Integer): Single;
begin
  if (Part < 0) or (Part >= PartCount) then raise EArgumentOutOfRangeException.Create('Part');
  Result := FFeedback[Part];
end;

procedure TVirtualElement.SetFeedback(Part: Integer; Value: Single);
begin
  if (Part < 0) or (Part >= PartCount) then raise EArgumentOutOfRangeException.Create('Part');
  if IsNan(Value) or IsInfinite(Value) then raise EArgumentException.Create('Invalid feedback');
  FFeedback[Part] := EnsureRange(Value, 0.0, 1.0);
  if FController <> nil then FController.Repaint;
end;

function TVirtualElement.VisualValue(Part: Integer): Single;
begin
  Result := Max(Value(Part), Feedback[Part]);
end;

procedure TVirtualKey.Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single);
begin
  Canvas.Fill.Color := TAlphaColors.White;
  Canvas.Stroke.Color := TAlphaColors.White;
  Canvas.Stroke.Thickness := 1.5;
  Canvas.FillRect(Bounds, 8, 8, AllCorners, Alpha * (0.16 + 0.54 * VisualValue));
  Canvas.DrawRect(Bounds, 8, 8, AllCorners, Alpha);
  DrawLabel(Canvas, Bounds, Caption, Alpha);
end;

procedure TVirtualElement.DrawLabel(Canvas: TCanvas; const R: TRectF; const Text: string; Alpha: Single);
begin
  Canvas.Fill.Color := TAlphaColors.White;
  Canvas.Font.Size := Max(9, Min(R.Width, R.Height) * 0.3);
  Canvas.FillText(R, Text, False, Alpha, [], TTextAlign.Center, TTextAlign.Center);
end;

function TVirtualButton.HitParts(const P: TPointF): TArray<Integer>;
var
  X, Y: Single;
begin
  X := (P.X - Bounds.CenterPoint.X) / (Bounds.Width / 2);
  Y := (P.Y - Bounds.CenterPoint.Y) / (Bounds.Height / 2);
  Result := nil;
  if Sqr(X) + Sqr(Y) <= 1 then
    Result := [0];
end;

procedure TVirtualButton.Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single);
begin
  Canvas.Fill.Color := TAlphaColors.White;
  Canvas.Stroke.Color := TAlphaColors.White;
  Canvas.Stroke.Thickness := 1.5;
  Canvas.FillEllipse(Bounds, Alpha * (0.16 + 0.54 * VisualValue));
  Canvas.DrawEllipse(Bounds, Alpha);
  DrawLabel(Canvas, Bounds, Caption, Alpha);
end;

constructor TVirtualDPad.Create(const AId, ACaption: string; ASide: TVirtualSide; const ABounds: TRectF; PartCount: Integer);
begin
  inherited Create(AId, ACaption, ASide, ABounds, 4);
end;

function TVirtualDPad.LocalPartBounds(Part: Integer): TRectF;
var
  W, H: Single;
begin
  W := Bounds.Width / 3;
  H := Bounds.Height / 3;
  case Part of
    Up:
      Result := RectF(Bounds.Left + W, Bounds.Top, Bounds.Right - W, Bounds.Top + H);
    Down:
      Result := RectF(Bounds.Left + W, Bounds.Bottom - H, Bounds.Right - W, Bounds.Bottom);
    Left:
      Result := RectF(Bounds.Left, Bounds.Top + H, Bounds.Left + W, Bounds.Bottom - H);
    Right:
      Result := RectF(Bounds.Right - W, Bounds.Top + H, Bounds.Right, Bounds.Bottom - H);
  else
    Result := TRectF.Empty;
  end;
end;

function TVirtualDPad.HitParts(const P: TPointF): TArray<Integer>;
var
  X, Y: Single;
begin
  Result := nil;
  if not Bounds.Contains(P) then
    Exit;
  X := (P.X - Bounds.CenterPoint.X) / (Bounds.Width / 2);
  Y := (P.Y - Bounds.CenterPoint.Y) / (Bounds.Height / 2);
  // Rectangular dead zone; corners activate two directions.
  if Y < -0.33 then
    Result := Result + [Up];
  if Y > 0.33 then
    Result := Result + [Down];
  if X < -0.33 then
    Result := Result + [Left];
  if X > 0.33 then
    Result := Result + [Right];
end;

procedure TVirtualDPad.Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single);
const
  Labels: array[0..3] of string = ('U', 'D', 'L', 'R');
var
  i: Integer;
  R: TRectF;
begin
  Canvas.Fill.Color := TAlphaColors.White;
  Canvas.FillEllipse(Bounds, Alpha * 0.06);
  Canvas.Stroke.Color := TAlphaColors.White;
  Canvas.Stroke.Thickness := 1.5;
  for i := 0 to 3 do
  begin
    if not PartEnabled[i] then Continue;
    R := Controller.PartBounds(Self, i);
    Canvas.Fill.Color := TAlphaColors.White;
    Canvas.FillRect(R, 4, 4, AllCorners, Alpha * (0.16 + 0.54 * VisualValue(i)));
    Canvas.DrawRect(R, 4, 4, AllCorners, Alpha);
    DrawLabel(Canvas, R, Labels[i], Alpha);
  end;
end;

procedure TVirtualSwitch.Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single);
var
  R: TRectF;
  D: Single;
begin
  Canvas.Stroke.Color := TAlphaColors.White;
  Canvas.Stroke.Thickness := 1.5;
  Canvas.Fill.Color := TAlphaColors.White;
  Canvas.FillRect(Bounds, Bounds.Height / 2, Bounds.Height / 2, AllCorners, Alpha * 0.12);
  Canvas.DrawRect(Bounds, Bounds.Height / 2, Bounds.Height / 2, AllCorners, Alpha);
  D := Min(Bounds.Height - 8, Bounds.Width / 3);
  R := RectF(Bounds.Left + 4, Bounds.CenterPoint.Y - D / 2, Bounds.Left + 4 + D, Bounds.CenterPoint.Y + D / 2);
  if VisualValue > 0 then
    R.Offset(Bounds.Width - D - 8, 0);
  Canvas.FillEllipse(R, Alpha * 0.8);
  DrawLabel(Canvas, Bounds, Caption, Alpha);
end;

function TVirtualTrigger.InputValue(const P: TPointF): Single;
begin
  Result := EnsureRange((Bounds.Bottom - P.Y) / Bounds.Height, 0.0, 1.0);
end;

procedure TVirtualTrigger.Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single);
var
  R: TRectF;
begin
  Canvas.Stroke.Color := TAlphaColors.White;
  Canvas.Stroke.Thickness := 1.5;
  Canvas.Fill.Color := TAlphaColors.White;
  Canvas.FillRect(Bounds, 8, 8, AllCorners, Alpha * 0.12);
  R := Bounds;
  R.Top := R.Bottom - R.Height * VisualValue;
  Canvas.FillRect(R, 6, 6, AllCorners, Alpha * 0.6);
  Canvas.DrawRect(Bounds, 8, 8, AllCorners, Alpha);
  DrawLabel(Canvas, Bounds, Caption, Alpha);
end;

constructor TVirtualController.Create(AOwner: TComponent);
begin
  inherited;
  FElements := TObjectList<TVirtualElement>.Create(True);
  FContacts := TDictionary<NativeInt, TContact>.Create;
  FScale := 1;
  FDesignSideSize := TSizeF.Create(SideWidth, DesignHeight);
  FInkOpacity := 0.65;
  AutoCapture := True;
  HitTest := True;
  SetBounds(0, 0, 960, 320);
end;

destructor TVirtualController.Destroy;
begin
  FOnInput := nil;
  FOnGeometryChanged := nil;
  FContacts.Free;
  FElements.Free;
  inherited;
end;

function TVirtualController.GetCount: Integer;
begin
  Result := FElements.Count;
end;

function TVirtualController.GetElement(Index: Integer): TVirtualElement;
begin
  Result := FElements[Index];
end;

function TVirtualController.Find(const Id: string): TVirtualElement;
var
  E: TVirtualElement;
begin
  for E in FElements do
    if E.Id = Id then
      Exit(E);
  Result := nil;
end;

function TVirtualController.Add(Element: TVirtualElement): TVirtualElement;
begin
  if (Element = nil) or (Element.Controller <> nil) then
    raise EArgumentException.Create('Element is nil or already owned');
  if Find(Element.Id) <> nil then
    raise EArgumentException.Create('Duplicate element ID');
  if (Element.Bounds.Right > FDesignSideSize.Width) or (Element.Bounds.Bottom > FDesignSideSize.Height) then
    raise EArgumentException.Create('Element must fit the logical side');
  FElements.Add(Element);
  Element.FController := Self;
  GeometryChanged;
  Result := Element;
end;

procedure TVirtualController.Remove(Element: TVirtualElement);
begin
  if (Element = nil) or (Element.Controller <> Self) then
    Exit;
  ReleaseAll;
  FElements.Remove(Element);
  GeometryChanged;
end;

procedure TVirtualController.Clear;
begin
  ReleaseAll;
  FElements.Clear;
  GeometryChanged;
end;

function TVirtualController.EffectiveScale: Single;
begin
  Result := Max(0.001, Min(FScale, Min(Width / (2 * FDesignSideSize.Width), Height / FDesignSideSize.Height)));
end;

function TVirtualController.SideBounds(Side: TVirtualSide): TRectF;
var
  S, X, Y: Single;
begin
  S := EffectiveScale;
  X := 0;
  if Side = TVirtualSide.Right then
    X := Width - FDesignSideSize.Width * S;
  Y := Height - FDesignSideSize.Height * S;
  Result := RectF(X, Y, X + FDesignSideSize.Width * S, Height);
end;

function TVirtualController.ToSide(const P: TPointF; Side: TVirtualSide): TPointF;
var
  R: TRectF;
  S: Single;
begin
  R := SideBounds(Side);
  S := EffectiveScale;
  Result := PointF((P.X - R.Left) / S, (P.Y - R.Top) / S);
end;

function TVirtualController.TransformRect(const R: TRectF; Side: TVirtualSide): TRectF;
var
  B: TRectF;
  S: Single;
begin
  B := SideBounds(Side);
  S := EffectiveScale;
  Result := RectF(B.Left + R.Left * S, B.Top + R.Top * S,
    B.Left + R.Right * S, B.Top + R.Bottom * S);
end;

function TVirtualController.ElementBounds(Element: TVirtualElement): TRectF;
begin
  if (Element = nil) or (Element.Controller <> Self) then
    raise EArgumentException.Create('Foreign element');
  Result := TransformRect(Element.Bounds, Element.Side);
end;

function TVirtualController.PartBounds(Element: TVirtualElement; Part: Integer): TRectF;
begin
  if (Element = nil) or (Element.Controller <> Self) then
    raise EArgumentException.Create('Foreign element');
  if (Part < 0) or (Part >= Element.PartCount) then
    raise EArgumentOutOfRangeException.Create('Part');
  Result := TransformRect(Element.LocalPartBounds(Part), Element.Side);
end;

function TVirtualController.PartCenter(Element: TVirtualElement; Part: Integer): TPointF;
begin
  Result := PartBounds(Element, Part).CenterPoint;
end;

procedure TVirtualController.SetDesignSideSize(const Value: TSizeF);
var
  E: TVirtualElement;
begin
  if IsNan(Value.Width) or IsNan(Value.Height) or IsInfinite(Value.Width) or
    IsInfinite(Value.Height) or (Value.Width < 1) or (Value.Height < 1) then
    raise EArgumentException.Create('Invalid logical side size');
  for E in FElements do
    if (E.Bounds.Right > Value.Width) or (E.Bounds.Bottom > Value.Height) then
      raise EArgumentException.Create('Existing elements must fit the logical side');
  FDesignSideSize := Value;
  GeometryChanged;
end;

procedure TVirtualController.SetScale(Value: Single);
begin
  if IsNan(Value) or IsInfinite(Value) or (Value <= 0) then
    raise EArgumentException.Create('Invalid scale');
  if FScale = Value then
    Exit;
  FScale := Value;
  GeometryChanged;
end;

procedure TVirtualController.SetInkOpacity(Value: Single);
begin
  if IsNan(Value) or IsInfinite(Value) then
    raise EArgumentException.Create('Invalid opacity');
  FInkOpacity := EnsureRange(Value, 0.0, 1.0);
  Repaint;
end;

procedure TVirtualController.GeometryChanged;
begin
  if FContacts = nil then
    Exit;
  ReleaseAll;
  Repaint;
  if Assigned(FOnGeometryChanged) then
    FOnGeometryChanged(Self);
end;

procedure TVirtualController.Resize;
begin
  inherited;
  GeometryChanged;
end;

procedure TVirtualController.EnabledChanged;
begin
  inherited;
  if not Enabled then
    ReleaseAll;
end;

procedure TVirtualController.VisibleChanged;
begin
  inherited;
  if not Visible then
    ReleaseAll;
end;

procedure TVirtualController.AncestorVisibleChanged(const Visible: Boolean);
begin
  inherited;
  if not Visible then
    ReleaseAll;
end;

procedure TVirtualController.InputChanged;
begin
end;

function TVirtualController.GroupBounds(Element: TVirtualElement): TRectF;
begin
  Result := ElementBounds(Element);
  for var E in FElements do
    if E.HasEnabledParts and (E.CaptureGroup = Element.CaptureGroup) then
    begin
      var Bounds := ElementBounds(E);
      Result := RectF(Min(Result.Left, Bounds.Left), Min(Result.Top, Bounds.Top),
        Max(Result.Right, Bounds.Right), Max(Result.Bottom, Bounds.Bottom));
    end;
  Result.Inflate(6, 6);
end;

procedure TVirtualController.Recompute;
var
  E: TVirtualElement;
  C: TContact;
  NewValues: TArray<Single>;
  Part, I: Integer;
  V: Single;
begin
  for E in FElements do
  begin
    NewValues := nil;
    SetLength(NewValues, E.PartCount);
    if E is TVirtualSwitch then
      NewValues[0] := Ord(TVirtualSwitch(E).FLatched)
    else
      for C in FContacts.Values do
        if (C.Element = E) or ((C.Element.CaptureGroup <> '') and
          (C.Element.CaptureGroup = E.CaptureGroup)) then
        begin
          var Point := ToSide(C.Position, E.Side);
          V := E.InputValue(Point);
          if E is TVirtualTrigger then NewValues[0] := Max(NewValues[0], V)
          else
          begin
            if C.HoldAnchor and (C.Element = E) then NewValues[0] := 1;
            for Part in E.HitParts(Point) do
              if (Part >= 0) and (Part < E.PartCount) then
                NewValues[Part] := Max(NewValues[Part], E.PartInputValue(Part, Point));
          end;
        end;
    for I := 0 to E.PartCount - 1 do
    begin
      if not E.PartEnabled[I] then NewValues[I] := 0;
      if not SameValue(E.FValues[I], NewValues[I], 0.0001) then
      begin
        E.FValues[I] := NewValues[I];
        if Assigned(FOnInput) then FOnInput(Self, E, I, NewValues[I]);
      end;
    end;
  end;
  // Subclasses read one complete state, without transient opposing directions.
  InputChanged;
  Repaint;
end;

procedure TVirtualController.PointerDown(Id: NativeInt; const P: TPointF);
var
  i: Integer;
  C: TContact;
begin
  if not Enabled or not AbsoluteEnabled or not ParentedVisible or not LocalRect.Contains(P) then
    Exit;
  FContacts.Remove(Id);
  for i := Count - 1 downto 0 do
  begin
    C.Element := Elements[i];
    if not C.Element.HasEnabledParts then Continue;
    C.HoldAnchor := (C.Element.CaptureGroup <> '') and C.Element.RetainOnSlide;
    C.Position := P;
    C.Point := ToSide(P, C.Element.Side);
    if not C.Element.Bounds.Contains(C.Point) then Continue;
    if Length(C.Element.HitParts(C.Point)) = 0 then
      if not ((C.Element is TVirtualDPad) and C.Element.Bounds.Contains(C.Point)) then
        Continue;
    if C.Element is TVirtualSwitch then
      TVirtualSwitch(C.Element).FLatched := not TVirtualSwitch(C.Element).FLatched;
    FContacts.Add(Id, C);
    Break;
  end;
  Recompute;
end;

procedure TVirtualController.PointerMove(Id: NativeInt; const P: TPointF);
var
  C: TContact;
begin
  if not FContacts.TryGetValue(Id, C) then
    Exit;
  if not AbsoluteEnabled or not ParentedVisible then
  begin
    ReleaseAll;
    Exit;
  end;
  C.Point := ToSide(P, C.Element.Side);
  C.Position := P;
  if (C.Element.CaptureGroup <> '') and
    (not LocalRect.Contains(P) or not GroupBounds(C.Element).Contains(P)) then
    C.HoldAnchor := False;
  FContacts[Id] := C;
  Recompute;
end;

procedure TVirtualController.PointerUp(Id: NativeInt);
begin
  if not FContacts.ContainsKey(Id) then
    Exit;
  FContacts.Remove(Id);
  Recompute;
end;

procedure TVirtualController.ReleaseAll;
var
  E: TVirtualElement;
begin
  if FContacts = nil then
    Exit;
  FContacts.Clear;
  for E in FElements do
  begin
    if E is TVirtualSwitch then TVirtualSwitch(E).FLatched := False;
    for var I := 0 to E.PartCount - 1 do E.FFeedback[I] := 0;
  end;
  Recompute;
end;

procedure TVirtualController.Paint;
var
  E: TVirtualElement;
begin
  Canvas.Stroke.Kind := TBrushKind.Solid;
  Canvas.Fill.Kind := TBrushKind.Solid;
  // No background: this control can overlay a game view.
  for E in FElements do
    if E.HasEnabledParts then E.Paint(Canvas, ElementBounds(E), FInkOpacity * AbsoluteOpacity);
end;

procedure TVirtualController.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  {$IF not Defined(ANDROID) and not Defined(IOS)}
  if Button = TMouseButton.mbLeft then
    PointerDown(-1, PointF(X, Y));
  {$ENDIF}
end;

procedure TVirtualController.MouseMove(Shift: TShiftState; X, Y: Single);
begin
  inherited;
  {$IF not Defined(ANDROID) and not Defined(IOS)}
  PointerMove(-1, PointF(X, Y));
  {$ENDIF}
end;

procedure TVirtualController.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  {$IF not Defined(ANDROID) and not Defined(IOS)}
  if Button = TMouseButton.mbLeft then
    PointerUp(-1);
  {$ENDIF}
end;

end.

