param(
  [ValidateSet('Win64', 'Win32')][string]$Platform = 'Win64',
  [ValidateSet('Release', 'Debug')][string]$Config = 'Release'
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..\..\..\..").Path
$studio = 'C:\Program Files (x86)\Embarcadero\Studio\37.0'
$vars = & cmd /c "`"$studio\bin\rsvars.bat`" && set"
if ($LASTEXITCODE -ne 0) { throw 'rsvars failed' }
foreach ($line in $vars) {
  if ($line -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process') }
}
$dirs = @("$root\apps\retromul", "$root\dependencies\DelphiWinUI3\Fixes\D13")
foreach ($base in @("$root\source", "$root\dependencies", "$root\apps\retromul")) {
  $dirs += $base
  $dirs += Get-ChildItem $base -Recurse -Directory | Where-Object {
    $_.FullName.Substring($base.Length) -notmatch '\\(\.git|__history|__recovery|Win32|Win64|Android|Android64|Linux64)(\\|$)' -and
    $_.FullName -notmatch '\\Fixes\\D(10|11|12)(\\|$)'
  } | ForEach-Object FullName
}
# Relative to the project (dcc runs there): the command line stays under
# Windows' limit with every source directory.
$paths = ($dirs | Select-Object -Unique | ForEach-Object { '..\..' + $_.Substring($root.Length) }) -join '%3B'
$log = "$PSScriptRoot\bin\frontend-$Platform-$Config.log"
New-Item -ItemType Directory -Force "$PSScriptRoot\bin" | Out-Null
& "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\MSBuild.exe" "$root\apps\retromul\RetroMul.dproj" /t:Build /nologo /v:minimal "/p:Platform=$Platform" "/p:Config=$Config" "/p:DCC_UnitSearchPath=$paths" /fl "/flp:LogFile=$log;Verbosity=normal"
$code = $LASTEXITCODE
if ($code -ne 0) { throw "frontend build failed ($code); full log: $log" }
Write-Output "$root\apps\retromul\$Platform\$Config\RetroMul.exe"
