# Compiles the PSP core for the other targets the application ships on:
# Win32, Linux64 (with a Linux SDK made from WSL: -Sdk), Android32/64 (dccaarm,
# dccaarm64: compile only, no link). build_targets.ps1 [-Targets win32,linux64,android64]
param([string[]]$Targets = @('win32', 'linux64', 'android32', 'android64'), [string]$Sdk = 'D:\LinuxSDK\ubuntu-22.04')
$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\..\..\.."
$studio = 'C:\Program Files (x86)\Embarcadero\Studio\37.0'
$sources = Get-ChildItem "$root\source" -Recurse -Directory | Where-Object { $_.FullName -notmatch '\\ui(\\|$)|\\gpu' } | ForEach-Object FullName
$paths = (@($PSScriptRoot) + $sources + @("$root\source")) -join ';'
$env:PATH = "$studio\bin;$studio\bin64;$env:PATH"
$failed = @()
foreach ($t in $Targets) {
  $out = "$PSScriptRoot\bin\$t"
  New-Item -ItemType Directory -Force -Path "$out\dcu" | Out-Null
  $compiler, $ns, $extra = switch ($t) {
    'win32' { 'dcc32', 'System;Winapi', @() }
    'linux64' { 'dcclinux64', 'System;Posix;Linuxapi', @("--syslibroot:$Sdk", "--libpath:$studio\lib\linux64\release;$Sdk\usr\lib\x86_64-linux-gnu") }
    'android32' { 'dccaarm', 'System;Posix;Androidapi', @('-CC') }
    'android64' { 'dccaarm64', 'System;Posix;Androidapi', @('-CC') }
  }
  $libdir = switch ($t) { 'win32' { 'win32' } 'linux64' { 'linux64' } 'android32' { 'android' } 'android64' { 'android64' } }
  $u = "$paths;$studio\lib\$libdir\release"
  Write-Output "== $t"
  # Units compiling is what counts here; linking needs each platform's SDK set up.
  $msgs = & "$studio\bin\$compiler.exe" -B -Q '-$O+' "-NS$ns" "-E$out" "-NU$out\dcu" "-NO$out\dcu" "-U$u" "-I$u" @extra "$PSScriptRoot\PSPCompile.dpr" 2>&1 |
    Where-Object { $_ -match 'Error|Fatal' }
  $compileErrors = @($msgs | Where-Object { $_ -notmatch 'E2597|F2588|F1026' })
  $msgs
  if ($compileErrors.Count -gt 0) { $failed += $t }
}
if ($failed.Count -gt 0) { throw "failed: $($failed -join ', ')" }
