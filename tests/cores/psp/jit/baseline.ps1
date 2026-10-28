# Builds PSPRun at another commit (the speed round's baseline) into
# bin\baseline-<commit>, with only the CPU renderer's 'helping the pool'
# statistic added (emuspeed.py's own cpu needs it). baseline.ps1 [-Commit 8f60810]
param([string]$Commit = '8f60810')
$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\..\..\.."
$out = "$PSScriptRoot\bin\baseline-$Commit"
$src = "$env:TEMP\psp-baseline-$Commit"
if (Test-Path $src) { Remove-Item -Recurse -Force $src }
New-Item -ItemType Directory -Force $src | Out-Null
git -C $root archive --format=zip -o "$src.zip" $Commit source dependencies tests/cores/psp/run/build.ps1 tests/cores/psp/run/PSPRun.dpr
Expand-Archive "$src.zip" -DestinationPath $src
Remove-Item "$src.zip"
$workers = "$src\source\cores\psp\PSP.GE.Workers.pas"
$text = [IO.File]::ReadAllText($workers)
if (-not $text.Contains('helping the pool')) {
  $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
  function Swap([string]$old, [string]$new) {
    $o = $old.Replace("`n", $nl); $n = $new.Replace("`n", $nl)
    if (-not $script:text.Contains($o)) { throw "baseline patch: not found: $old" }
    $script:text = $script:text.Replace($o, $n)
  }
  Swap "    FSerialTicks: Int64;`n" "    FSerialTicks: Int64;`n    FHelpTicks: Int64;`n"
  Swap "      SetModes(B.MXCSR, B.FPUControl);`n      try`n        WorkBands(B);`n      finally`n        SetModes(SavedMXCSR, SavedControl);`n      end;" "      SetModes(B.MXCSR, B.FPUControl);`n      var H := TStopwatch.GetTimeStamp;`n      try`n        WorkBands(B);`n      finally`n        SetModes(SavedMXCSR, SavedControl);`n        Inc(FHelpTicks, TStopwatch.GetTimeStamp - H);`n      end;"
  Swap "'drawn on the emulator thread %.2fs', [" "'drawn on the emulator thread %.2fs, helping the pool %.2fs', ["
  Swap "    FSerialTicks / F]);" "    FSerialTicks / F, FHelpTicks / F]);"
  [IO.File]::WriteAllText($workers, $text)
}
& "$src\tests\cores\psp\run\build.ps1" -Out $out | Select-String -Pattern 'Error|Fatal|PSPRun_win64.exe$'
Remove-Item -Recurse -Force $src
