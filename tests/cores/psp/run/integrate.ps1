# Merges the workers' branches into the integration worktree, one by one.
# Conflicts in PSP.Console.pas's run loop keep the integration branch's side;
# any other conflict stops the script for a manual resolution.
param([string[]]$Branches = @('kernel', 'cpu', 'ge', 'audio', 'media', 'util', 'jit', 'gpu'),
  [string]$Worktree = 'D:\Work\RetroMul-psp-wt\integ')
$ErrorActionPreference = 'Continue'
$resolver = Join-Path $PSScriptRoot 'resolve_ours.py'
foreach ($n in $Branches) {
  git -C $Worktree merge --no-edit "psp/$n" *> $null
  if ($LASTEXITCODE -eq 0) { "merged $n"; continue }
  $files = @(git -C $Worktree diff --name-only --diff-filter=U)
  $manual = @()
  foreach ($f in $files) {
    $path = Join-Path $Worktree $f
    $text = [IO.File]::ReadAllText($path)
    # Hunks: the run loop (ours), uses lists (both sides).
    $hunks = [regex]::Matches($text, '(?s)<<<<<<< [^\n]*\n(.*?)=======\r?\n(.*?)>>>>>>> [^\n]*\n')
    $ok = $true
    foreach ($h in $hunks) {
      $a = $h.Groups[1].Value; $b = $h.Groups[2].Value
      if ($a -match 'TakeDue|while True do|RunUntil|FStopAtFrame' -or $b -match 'TakeDue') { continue }
      if ($a -match '^\s*PSP\.[\w., ]+;\s*$' -and $b -match '^\s*PSP\.[\w., ]+;\s*$') { continue }
      $ok = $false
    }
    if (-not $ok) { $manual += $f; continue }
    $out = [regex]::Replace($text, '(?s)<<<<<<< [^\n]*\n(.*?)=======\r?\n(.*?)>>>>>>> [^\n]*\n', {
        param($m)
        $a = $m.Groups[1].Value; $b = $m.Groups[2].Value
        if ($a -match '^\s*PSP\.[\w., ]+;\s*$' -and $b -match '^\s*PSP\.[\w., ]+;\s*$') {
          $names = (($a + ',' + $b) -replace '[;\s]', '').Split(',') | Where-Object { $_ } | Select-Object -Unique
          return '  ' + ($names -join ', ') + ";`n"
        }
        return $a
      })
    [IO.File]::WriteAllText($path, $out)
    git -C $Worktree add $f
  }
  if ($manual.Count -gt 0) { "CONFLICT $n (manual): $($manual -join ', ')"; break }
  git -C $Worktree commit -q --no-edit
  "merged $n (resolved: $($files -join ', '))"
}
