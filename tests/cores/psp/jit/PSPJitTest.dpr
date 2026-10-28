program PSPJitTest;

// The Allegrex recompiler against the interpreter (PSP.JitTest):
// PSPJitTest [programs] [bench] [-v] [-mix] (-v: the guest faults that ended
// programs; -mix: the instructions the interpreter runs, by opcode, instead).
// Exit code 1 when they differ.

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, PSP.JitTest;

begin
  var Report := TStringList.Create;
  try
    try
      var Programs := 300;
      var Bench := False;
      for var I := 1 to ParamCount do
        if SameText(ParamStr(I), 'bench') then
          Bench := True
        else if ParamStr(I).StartsWith('-') then
        else
          Programs := StrToInt(ParamStr(I));
      if Programs > 0 then
        if not RunPSPJitTest(Programs, Report) then
          ExitCode := 1;
      if Bench then
        RunPSPJitBench(Report);
    except
      on E: Exception do
      begin
        Report.Add(E.ClassName + ': ' + E.Message);
        ExitCode := 2;
      end;
    end;
    for var L in Report do
      Writeln(L);
  finally
    Report.Free;
  end;
end.
