param(
  [string]$Project = 'PSPRun.dpr',
  [string]$Defines = '',
  [ValidateSet('win32', 'win64')][string]$Platform = 'win64',
  [switch]$Checked,
  [string]$Out = ''
)
$ErrorActionPreference = 'Stop'
if ($Out -eq '') { $Out = Join-Path $PSScriptRoot 'bin' }
$root = Resolve-Path "$PSScriptRoot\..\..\..\.."
$src = "$root\source"
$dirs = @(Get-ChildItem $src -Recurse -Directory | Where-Object { $_.FullName -notmatch '\\ui\\|\\ui$|\\__history|\\gpu' } | ForEach-Object { $_.FullName })
$dirs += $src
$dirs += "$root\dependencies\PCMAudio"
$dirs += $PSScriptRoot
$paths = $dirs -join ';'
$name = [IO.Path]::GetFileNameWithoutExtension($Project)
$suffix = $Platform
if ($Checked) { $suffix += '_checked' }
$exe = "$name`_$suffix"
$dcu = "$Out\dcu_$exe"
New-Item -ItemType Directory -Force -Path $Out, $dcu | Out-Null
(Get-Content "$PSScriptRoot\$Project" -Raw).Replace("program $name;", "program $exe;") | Set-Content "$dcu\$exe.dpr" -NoNewline
$compiler = 'dcc64.exe'
if ($Platform -eq 'win32') { $compiler = 'dcc32.exe' }
$dcc = "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\$compiler"
$defs = @()
if ($Checked) { $defs += 'PSP_CHECKED' }
if ($Defines -ne '') { $defs += $Defines.Split(';') }
$extra = @()
if ($defs.Count -gt 0) { $extra += '-D' + ($defs -join ';') }
$checks = @('-$Q-', '-$R-')
if ($Checked) { $checks = @('-$Q+', '-$R+') }
& $dcc -B -Q '-$O+' @checks '-$D+' '-$L-' '-$C+' -GD "-NSSystem;Winapi;System.Win;Vcl" "-U$paths" "-I$paths" "-R$paths" "-E$Out" "-NU$dcu" @extra "$dcu\$exe.dpr"
if ($LASTEXITCODE -ne 0) { throw "build failed" }
Write-Output "$Out\$exe.exe"
