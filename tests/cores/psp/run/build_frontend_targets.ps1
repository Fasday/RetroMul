# Compile the changed adapter, renderer and settings units, including their
# dependencies, without linking or pretending that cross-platform runtime was tested.
param(
  [string[]]$Targets = @('linux64', 'android64'),
  [string]$Sdk = 'D:\LinuxSDK\ubuntu-22.04'
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..\..\..\..").Path
$studio = 'C:\Program Files (x86)\Embarcadero\Studio\37.0'
$dirs = @($PSScriptRoot)
foreach ($base in @("$root\source", "$root\apps\retromul")) {
  $dirs += $base
  $dirs += Get-ChildItem $base -Recurse -Directory | Where-Object {
    $_.FullName.Substring($base.Length) -notmatch '\\(__history|__recovery|Win32|Win64|Android|Android64|Linux64)(\\|$)'
  } | ForEach-Object FullName
}
$dirs += "$root\dependencies\PCMAudio"
$dirs += "$root\dependencies\Delphi7z"
$dirs += "$root\dependencies\FMXInput"
$dirs += "$root\dependencies\FMXVibration"
$paths = $dirs -join ';'
$env:PATH = "$studio\bin;$studio\bin64;$env:PATH"
$failed = @()
foreach ($target in $Targets) {
  $out = "$PSScriptRoot\bin\frontend-$target"
  New-Item -ItemType Directory -Force "$out\dcu" | Out-Null
  $compiler, $ns, $extra = switch ($target) {
    'win32' { 'dcc32', 'System;Winapi', @() }
    'linux64' { 'dcclinux64', 'System;Posix;Linuxapi', @("--syslibroot:$Sdk", "--libpath:$studio\lib\linux64\release;$Sdk\usr\lib\x86_64-linux-gnu") }
    'android64' { 'dccaarm64', 'System;Posix;Androidapi', @('-CC') }
    default { throw "Unknown target $target" }
  }
  $u = "$paths;$studio\lib\$target\release"
  Write-Output "== $target (full log: $out\build.log)"
  & "$studio\bin\$compiler.exe" -B -Q '-$O+' "-NS$ns" "-E$out" "-NU$out\dcu" "-NO$out\dcu" "-U$u" "-I$u" @extra "$PSScriptRoot\PSPFrontendCompileUnit.pas" 2>&1 | Tee-Object "$out\build.log"
  $code = $LASTEXITCODE
  if ($code -ne 0) { $failed += "$target ($code)" }
  else { Write-Output "$target frontend units compiled (not linked or run)" }
}
if ($failed.Count -gt 0) { throw "Compilation failed: $($failed -join ', ')" }
