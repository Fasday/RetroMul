# Compiles the GLSL shaders (*.comp, *.vert, *.frag) to SPIR-V and writes each as a
# Pascal unit next to its source: Name.comp -> SPV.Name.pas with
#   const NameSPV: array[0..N - 1] of Cardinal = (...);
# Vertex and fragment shaders get the stage in the name: Name.vert -> SPV.NameVert.pas
# with NameVertSPV.
# The units are committed, so building needs no Vulkan SDK; run this after
# editing a shader. Without arguments it compiles this folder, and the compute
# tests' shaders where they are present.
param(
  [string[]]$Dirs = @(),
  [string]$Sdk = $env:VULKAN_SDK
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\..\.."
if ($Dirs.Count -eq 0) { $Dirs = @($PSScriptRoot) + @("$root\tests\gpu\vulkan\shaders" | Where-Object { Test-Path $_ }) }
if (-not $Sdk) { $Sdk = 'C:\VulkanSDK\1.4.363.0' }
$glslc = Join-Path $Sdk 'Bin\glslc.exe'
$val = Join-Path $Sdk 'Bin\spirv-val.exe'
$dis = Join-Path $Sdk 'Bin\spirv-dis.exe'
$as = Join-Path $Sdk 'Bin\spirv-as.exe'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("rm-spv-" + [Guid]::NewGuid().ToString('N'))
$utf8 = New-Object System.Text.UTF8Encoding($false)
$utf8bom = New-Object System.Text.UTF8Encoding($true)
$failed = 0
foreach ($dir in $Dirs) {
  foreach ($f in Get-ChildItem $dir -File | Where-Object { $_.Extension -in '.comp', '.vert', '.frag' } | Sort-Object Name) {
    $name = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    $stage = 'compute'
    if ($f.Extension -eq '.vert') { $stage = 'vertex'; $name += 'Vert' }
    if ($f.Extension -eq '.frag') { $stage = 'fragment'; $name += 'Frag' }
    & $glslc --target-env=vulkan1.2 -O "-fshader-stage=$stage" -I $PSScriptRoot -I $dir -o "$tmp.spv" $f.FullName
    if ($LASTEXITCODE -ne 0) { $failed++; continue }
    # glslang keeps one execution mode of each kind: give modules with doubles the
    # 32-bit float controls for 16 and 64 bits too.
    $asm = & $dis --raw-id --no-color "$tmp.spv"
    if (($asm -match '^\s*OpCapability Float64$').Count -gt 0) {
      $lines = New-Object System.Collections.Generic.List[string]
      foreach ($line in $asm) {
        $lines.Add($line)
        if ($line -match '^(\s*OpExecutionMode %\d+ (DenormPreserve|SignedZeroInfNanPreserve|RoundingModeRTE)) 32$') {
          $lines.Add("$($Matches[1]) 16")
          $lines.Add("$($Matches[1]) 64")
        }
      }
      [IO.File]::WriteAllLines("$tmp.spvasm", $lines, $utf8)
      & $as --target-env vulkan1.2 -o "$tmp.spv" "$tmp.spvasm"
      if ($LASTEXITCODE -ne 0) { $failed++; continue }
    }
    & $val --target-env vulkan1.2 "$tmp.spv"
    if ($LASTEXITCODE -ne 0) { $failed++; continue }
    $bytes = [IO.File]::ReadAllBytes("$tmp.spv")
    $count = $bytes.Length / 4
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("unit SPV.$name;`r`n`r`ninterface`r`n`r`n")
    [void]$sb.Append("// Generated from $($f.Name); do not edit.`r`n")
    [void]$sb.Append("const`r`n  $($name.Replace('.', ''))SPV: array[0..$($count - 1)] of Cardinal = (`r`n")
    for ($i = 0; $i -lt $count; $i++) {
      if ($i % 10 -eq 0) { [void]$sb.Append('    ') }
      [void]$sb.Append('$' + [BitConverter]::ToUInt32($bytes, $i * 4).ToString('X8'))
      if ($i -lt $count - 1) {
        if ($i % 10 -eq 9) { [void]$sb.Append(",`r`n") } else { [void]$sb.Append(', ') }
      }
    }
    [void]$sb.Append(");`r`n`r`nimplementation`r`n`r`nend.`r`n")
    $unit = Join-Path $f.DirectoryName "SPV.$name.pas"
    [IO.File]::WriteAllText($unit, $sb.ToString(), $utf8bom)
    Write-Output "$($f.Name): $count words"
  }
}
Remove-Item "$tmp.spv", "$tmp.spvasm" -ErrorAction SilentlyContinue
if ($failed -gt 0) { throw "$failed shader(s) failed" }
