param(
  [string]$Project = 'ComputeTest.dpr',
  [string]$Defines = '',
  [ValidateSet('win32', 'win64')][string]$Platform = 'win64',
  [string]$Out = ''
)
$ErrorActionPreference = 'Stop'
if ($Out -eq '') { $Out = Join-Path $PSScriptRoot 'bin' }
$root = Resolve-Path "$PSScriptRoot\..\..\.."
$dirs = @("$root\source\gpu\vulkan", "$root\source\gpu\shaders", "$root\source\cores\psp", "$root\source\hardware\jit", "$PSScriptRoot\shaders", $PSScriptRoot)
$paths = $dirs -join ';'
$name = [IO.Path]::GetFileNameWithoutExtension($Project)
$exe = "$name`_$Platform"
$dcu = "$Out\dcu_$exe"
New-Item -ItemType Directory -Force -Path $Out, $dcu | Out-Null
(Get-Content "$PSScriptRoot\$Project" -Raw).Replace("program $name;", "program $exe;") | Set-Content "$dcu\$exe.dpr" -NoNewline
$compiler = 'dcc64.exe'
if ($Platform -eq 'win32') { $compiler = 'dcc32.exe' }
$dcc = "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\$compiler"
$extra = @()
if ($Defines -ne '') { $extra += '-D' + $Defines }
& $dcc -B -Q '-$O+' '-$Q-' '-$R-' '-$D+' '-$L-' '-$C+' -GD "-NSSystem;Winapi;System.Win" "-U$paths" "-I$paths" "-R$paths" "-E$Out" "-NU$dcu" @extra "$dcu\$exe.dpr"
if ($LASTEXITCODE -ne 0) { throw "build failed" }
Write-Output "$Out\$exe.exe"
