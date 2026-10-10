unit RM.Styles;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs;

type
  TFormStyles = class(TForm)
    StyleBookWinUI3: TStyleBook;
    Lang: TLang;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetLanguage(const Language: string);
    procedure RelocalizeUI(Root: TFmxObject; const PreviousLanguage: string);
  end;

var
  FormStyles: TFormStyles;

implementation

uses
  System.TypInfo, FMX.Edit, FMX.ListBox;

{$R *.fmx}

constructor TFormStyles.Create(AOwner: TComponent);

  procedure Caption(const English, Russian, Portuguese: string);
  begin
    if Lang.Original.IndexOf(English) < 0 then
      Lang.Original.Add(English);
    Lang.LangStr['ru'].Values[English] := Russian;
    Lang.LangStr['pt'].Values[English] := Portuguese;
  end;

begin
  inherited;
  Lang.AddLang('ru');
  Lang.AddLang('pt');
  Caption('Rumble', 'Вибрация', 'Vibração');
  Caption('Cartridge rumble', 'Вибрация картриджа', 'Vibração do cartucho');
  Caption('Vibrate the device when the game activates its rumble motor.',
    'Вибрация устройства по сигналу игры.',
    'Vibrar o dispositivo quando o jogo ativar o motor do cartucho.');
  Caption('Boot ROM', 'Загрузочный ROM', 'ROM de inicialização');
  Caption('Boot ROM model', 'Модель загрузочного ROM', 'Modelo da ROM de inicialização');
  Caption('Boot ROM file', 'Файл загрузочного ROM', 'Arquivo da ROM de inicialização');
  Caption('Skip boot ROM', 'Запуск без загрузочного ROM', 'Iniciar sem ROM de inicialização');
  Caption('Select a console boot sequence, or start the game directly.',
    'Выберите загрузчик модели консоли или прямой запуск игры.',
    'Escolha a inicialização do console ou inicie o jogo diretamente.');
  Caption('Choose your boot ROM file for this model.',
    'Выберите файл загрузочного ROM для этой модели.',
    'Escolha o arquivo da ROM de inicialização deste modelo.');
  Caption('Leave empty to use the built-in boot ROM.',
    'Оставьте поле пустым для встроенного загрузочного ROM.',
    'Deixe vazio para usar a ROM de inicialização integrada.');
  Caption('Choose boot ROM', 'Выбрать загрузочный ROM', 'Escolher ROM de inicialização');
  Lang.Lang := Lang.Lang;
end;

procedure TFormStyles.SetLanguage(const Language: string);
begin
  var Code := Language.Trim.ToLower.Replace('_', '-');
  if (Code = 'ru') or Code.StartsWith('ru-') then
    Code := 'ru'
  else if (Code = 'pt') or Code.StartsWith('pt-') then
    Code := 'pt'
  else
    Code := 'en';
  if Lang.Lang <> Code then
    Lang.Lang := Code;
end;

procedure TFormStyles.RelocalizeUI(Root: TFmxObject; const PreviousLanguage: string);

  function Localized(const Value: string): string;
  begin
    Result := Value;
    if Value = '' then
      Exit;
    if Lang.Original.IndexOf(Value) >= 0 then
      Exit(Translate(Value));
    var Old := Lang.LangStr[PreviousLanguage];
    if Old <> nil then
      for var I := 0 to Old.Count - 1 do
        if Old.ValueFromIndex[I] = Value then
          Exit(Translate(Old.Names[I]));
  end;

  procedure Visit(Obj: TFmxObject);
  begin
    // Editable text is user data. Translate prompts and UI captions only.
    for var Name in ['Text', 'TextPrompt', 'Hint'] do
    begin
      if (Name = 'Text') and (Obj is TCustomEdit) then
        Continue;
      var Prop := GetPropInfo(Obj.ClassInfo, Name);
      if (Prop <> nil) and (Prop.PropType^.Kind in [tkString, tkLString, tkWString, tkUString]) then
      begin
        var Value := GetStrProp(Obj, Prop);
        var NewValue := Localized(Value);
        if NewValue <> Value then
          SetStrProp(Obj, Prop, NewValue);
      end;
    end;
    if Obj is TComboBox then
    begin
      var Combo := TComboBox(Obj);
      var Selected := Combo.ItemIndex;
      for var I := 0 to Combo.Items.Count - 1 do
        Combo.Items[I] := Localized(Combo.Items[I]);
      Combo.ItemIndex := Selected;
    end;
    if Obj is TCustomEdit then
      Exit;
    if Obj.Children <> nil then
      for var Child in Obj.Children do
        Visit(Child);
  end;

begin
  if (Root <> nil) and (PreviousLanguage <> Lang.Lang) then
    Visit(Root);
end;

end.

