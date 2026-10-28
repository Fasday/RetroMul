program PSPCompile;

// Compiles the PSP core alone, for other targets' compilers (build_targets.ps1).

{$APPTYPE CONSOLE}

uses
  System.SysUtils, PSP.Media, PSP.Console;

begin
  Writeln(TPSPConsole.ClassName);
end.
