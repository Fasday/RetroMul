unit RM.Settings.PSP;

interface

uses
  RM.Settings.Platform, RM.Settings.Builder, System.IniFiles;

type
  TPSPSettingsPage = class(TSettingsPlatform)
  public
    procedure Configuration(Context: TSettingsPageBuilder); override;
  end;

implementation

uses
  RM.Settings.Catalog, FMX.Types, System.SysUtils, HW.JIT;

procedure TPSPSettingsPage.Configuration(Context: TSettingsPageBuilder);
begin
  if JitSupported then
  begin
    Context.Heading('GroupPSPEmulation', 'PSP emulation');
    Context.AddChoice('RowPSPExecution', 'CPU', 'The recompiler runs the game''s code as native code; the interpreter runs it instruction by instruction. Both give the same emulation; the recompiler is faster. Applies during play.', 'Emulation', 'Execution', SettingChoices([Translate('Recompiler (JIT)'), Translate('Interpreter')], ['jit', 'interpreter']), 'jit', True);
  end;
  Context.Heading('GroupPSPSystem', 'PSP system');
  Context.AddChoice('RowPSPLanguage', 'System language', 'The language games read from the system settings. Applies when the game starts.', 'System', 'Language', SettingChoices([Translate('Japanese'), Translate('English'), Translate('French'), Translate('Spanish'), Translate('German'), Translate('Italian'), Translate('Dutch'), Translate('Portuguese'), Translate('Russian'), Translate('Korean'), Translate('Chinese (traditional)'), Translate('Chinese (simplified)')], ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11']), '1', True);
  Context.AddChoice('RowPSPConfirm', 'Confirm button', 'Which button confirms in system dialogs and in games that follow the system setting.', 'System', 'ButtonSwap', SettingChoices([Translate('Cross'), Translate('Circle')], ['1', '0']), '1', True);
  Context.AddText('RowPSPNickname', 'Nickname', 'The user name games show and store in saves.', 'System', 'Nickname', 'RetroMul', True);
end;

initialization
  RegisterSettingsPlatform('psp', TPSPSettingsPage);

end.
