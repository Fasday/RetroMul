#requires -Version 5.1
<#
.SYNOPSIS
Packages an existing Windows build as an unsigned Microsoft Store MSIX.
.EXAMPLE
.\BuildStorePackage.ps1
.EXAMPLE
.\BuildStorePackage.ps1 -Platform Win64 -Version 1.2.0.0
.EXAMPLE
.\BuildStorePackage.ps1 -SigningCertificateThumbprint '0123456789ABCDEF0123456789ABCDEF01234567'
.EXAMPLE
.\BuildStorePackage.ps1 -PackageName 'Publisher.App' -Publisher 'CN=publisher-id' -PublisherDisplayName 'Publisher'
.NOTES
Reads Partner Center identities and logo paths from the selected .dproj
configuration using MSBuild evaluation. Parameters override project settings.
Can Authenticode-sign the staged executable before packaging when a signing
certificate thumbprint is supplied. The MSIX itself remains unsigned for Store
submission. Does not compile, install, or submit the application. Requires Windows SDK.
Working files remain under codex-work/build/store-package; MSIX goes to releases.
#>
[CmdletBinding()]
param(
    [ValidateSet('Win32', 'Win64')]
    [string] $Platform = 'Win64',
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',
    [string] $ProjectFile,
    [string] $InputDirectory,
    [string] $ContentDirectory,
    [string] $PackageName,
    [string] $Publisher,
    [string] $PublisherDisplayName,
    [string] $DisplayName,
    [string] $Version,
    [string] $Description = 'RetroMul multi-system emulator',
    [string] $MinVersion = '10.0.17763.0',
    [string] $MaxVersionTested = '10.0.26100.0',
    [string] $MakeAppxPath,
    [ValidatePattern('^[A-Fa-f0-9]{40}$')]
    [string] $SigningCertificateThumbprint,
    [ValidateSet('CurrentUser', 'LocalMachine')]
    [string] $SigningCertificateStore = 'CurrentUser',
    [string] $SignToolPath,
    [string] $TimestampUrl = 'http://timestamp.digicert.com',
    [string] $OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $ProjectFile) { $ProjectFile = Join-Path $PSScriptRoot 'apps/retromul/RetroMul.dproj' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot 'releases' }
$ProjectFile = (Resolve-Path -LiteralPath $ProjectFile).ProviderPath
$projectDirectory = Split-Path -Parent $ProjectFile
$projectName = [IO.Path]::GetFileNameWithoutExtension($ProjectFile)
$workDirectory = Join-Path $PSScriptRoot ('codex-work/build/store-package/' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null

# Windows PowerShell provides the .NET Framework MSBuild evaluator on both PS 5.1
# and PS 7 hosts. Only selected public packaging properties are exported.
$evaluationScript = Join-Path $workDirectory 'ReadProject.ps1'
$propertiesFile = Join-Path $workDirectory 'project-properties.json'
$evaluationSource = @'
param($ProjectFile, $Platform, $Configuration, $OutputFile)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName Microsoft.Build
$globals = [Collections.Generic.Dictionary[string,string]]::new()
$globals['Config'] = $Configuration
$globals['Platform'] = $Platform
$globals['ProjectName'] = [IO.Path]::GetFileNameWithoutExtension($ProjectFile)
$collection = [Microsoft.Build.Evaluation.ProjectCollection]::new()
try {
    $project = [Microsoft.Build.Evaluation.Project]::new($ProjectFile, $globals, '4.0', $collection,
        [Microsoft.Build.Evaluation.ProjectLoadSettings]::IgnoreMissingImports)
    $values = [ordered]@{}
    foreach ($key in @('PF_UWPPackageName', 'PF_UWPPublisher', 'PF_UWPPackageDisplayName',
        'PF_UWPPublisherDisplayName', 'DCC_ExeOutput', 'UWP_DelphiLogo44', 'UWP_DelphiLogo150')) {
        $values[$key] = $project.GetPropertyValue($key)
    }
    [IO.File]::WriteAllText($OutputFile, ($values | ConvertTo-Json), [Text.UTF8Encoding]::new($true))
} finally { $collection.UnloadAllProjects(); $collection.Dispose() }
'@
[IO.File]::WriteAllText($evaluationScript, $evaluationSource, [Text.UTF8Encoding]::new($true))
$windowsPowerShell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
& $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $evaluationScript $ProjectFile $Platform $Configuration $propertiesFile
if ($LASTEXITCODE -ne 0) { throw "Could not evaluate $ProjectFile ($Configuration / $Platform)." }
$settings = Get-Content -LiteralPath $propertiesFile -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $PackageName) { $PackageName = $settings.PF_UWPPackageName }
if (-not $Publisher) { $Publisher = $settings.PF_UWPPublisher }
if (-not $PublisherDisplayName) { $PublisherDisplayName = $settings.PF_UWPPublisherDisplayName }
if (-not $DisplayName) { $DisplayName = $settings.PF_UWPPackageDisplayName }
foreach ($setting in @('PackageName', 'Publisher', 'PublisherDisplayName', 'DisplayName')) {
    if ([string]::IsNullOrWhiteSpace((Get-Variable -Name $setting -ValueOnly))) {
        throw "$setting is missing. Configure the project's Store settings for $Configuration / $Platform or pass -$setting."
    }
}
if ($PackageName -notmatch '^[A-Za-z0-9.-]{3,50}$') { throw 'PackageName must contain 3-50 letters, digits, dots, or hyphens.' }
if (-not $InputDirectory) {
    $InputDirectory = $settings.DCC_ExeOutput
    if (-not $InputDirectory) { $InputDirectory = "$Platform\$Configuration" }
    if (-not [IO.Path]::IsPathRooted($InputDirectory)) { $InputDirectory = Join-Path $projectDirectory $InputDirectory }
}
$InputDirectory = (Resolve-Path -LiteralPath $InputDirectory).ProviderPath
$executable = Join-Path $InputDirectory "$projectName.exe"
if (-not (Test-Path -LiteralPath $executable -PathType Leaf) -or (Get-Item -LiteralPath $executable).Length -eq 0) {
    throw "Windows executable not found or empty: $executable. Build $Configuration / $Platform first."
}
# Reject an executable from the wrong platform before producing a mislabeled MSIX.
$stream = [IO.File]::OpenRead($executable)
$reader = [IO.BinaryReader]::new($stream)
try {
    if ($reader.ReadUInt16() -ne 0x5a4d) { throw 'Input executable is not a PE file.' }
    $stream.Position = 0x3c
    $stream.Position = $reader.ReadInt32()
    if ($reader.ReadUInt32() -ne 0x00004550) { throw 'Input executable has no PE signature.' }
    $machine = $reader.ReadUInt16()
} finally { $reader.Dispose(); $stream.Dispose() }
$expectedMachine = if ($Platform -eq 'Win64') { 0x8664 } else { 0x014c }
if ($machine -ne $expectedMachine) { throw "Executable architecture does not match $Platform`: $executable" }
$architecture = if ($Platform -eq 'Win64') { 'x64' } else { 'x86' }
if (-not $Version) {
    $info = (Get-Item -LiteralPath $executable).VersionInfo
    $Version = "$($info.FileMajorPart).$($info.FileMinorPart).$($info.FileBuildPart).$($info.FilePrivatePart)"
}
foreach ($value in @($Version, $MinVersion, $MaxVersionTested)) {
    if ($value -notmatch '^\d+\.\d+\.\d+\.\d+$' -or @($value.Split('.') | Where-Object { [long]$_ -gt 65535 }).Count) {
        throw "Invalid four-part version: $value"
    }
}
if (([version]$Version).Major -eq 0 -or ([version]$Version).Revision -ne 0) {
    throw 'Store package version must have a nonzero major component and a final component of 0 (for example, 1.2.0.0).'
}
if ([version]$MinVersion -lt [version]'10.0.17763.0' -or [version]$MaxVersionTested -lt [version]$MinVersion) {
    throw 'MinVersion must be at least 10.0.17763.0; MaxVersionTested must not be lower than MinVersion.'
}

if (-not $MakeAppxPath) {
    $onPath = Get-Command makeappx.exe -ErrorAction SilentlyContinue
    if ($onPath) { $MakeAppxPath = $onPath.Source }
    else {
        $sdkRoots = @($env:WindowsSdkDir, (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10'))
        foreach ($registryPath in @('HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots')) {
            try { $sdkRoots += (Get-ItemProperty -LiteralPath $registryPath -Name KitsRoot10 -ErrorAction Stop).KitsRoot10 } catch { }
        }
        foreach ($sdkRoot in ($sdkRoots | Where-Object { $_ } | Select-Object -Unique)) {
            $sdkBins = @(Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'bin') -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } | Sort-Object { [version]$_.Name } -Descending)
            foreach ($sdkBin in $sdkBins) {
                foreach ($hostArchitecture in @('x64', 'x86')) {
                    $candidate = Join-Path $sdkBin.FullName "$hostArchitecture/makeappx.exe"
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $MakeAppxPath = $candidate; break }
                }
                if ($MakeAppxPath) { break }
            }
            if ($MakeAppxPath) { break }
        }
    }
}
if (-not $MakeAppxPath -or -not (Test-Path -LiteralPath $MakeAppxPath -PathType Leaf)) {
    throw 'MakeAppx.exe not found. Install Windows SDK or specify -MakeAppxPath.'
}
$MakeAppxPath = (Resolve-Path -LiteralPath $MakeAppxPath).ProviderPath
if ($SigningCertificateThumbprint) {
    $certificatePath = "Cert:\$SigningCertificateStore\My\$SigningCertificateThumbprint"
    $certificate = Get-Item -LiteralPath $certificatePath -ErrorAction Stop
    if (-not $certificate.HasPrivateKey) { throw "Signing certificate has no accessible private key: $certificatePath" }
    $now = Get-Date
    if ($certificate.NotBefore -gt $now -or $certificate.NotAfter -lt $now) { throw 'Signing certificate is not currently valid.' }
    $timestampUri = $null
    if (-not [uri]::TryCreate($TimestampUrl, [UriKind]::Absolute, [ref]$timestampUri) -or $timestampUri.Scheme -notin @('http', 'https')) {
        throw 'TimestampUrl must be an absolute HTTP or HTTPS RFC 3161 timestamp server URL.'
    }
    if (-not $SignToolPath) { $SignToolPath = Join-Path (Split-Path -Parent $MakeAppxPath) 'signtool.exe' }
    if (-not (Test-Path -LiteralPath $SignToolPath -PathType Leaf)) { throw 'SignTool.exe not found. Specify -SignToolPath.' }
    $SignToolPath = (Resolve-Path -LiteralPath $SignToolPath).ProviderPath
}

$payload = Join-Path $workDirectory 'payload'
$assetDirectory = Join-Path $payload 'Assets'
New-Item -ItemType Directory -Path $assetDirectory -Force | Out-Null
Copy-Item -LiteralPath $executable -Destination $payload
Get-ChildItem -LiteralPath $InputDirectory -File -Filter '*.dll' | Copy-Item -Destination $payload
$languageDirectory = Join-Path $InputDirectory 'Lang'
if (Test-Path -LiteralPath $languageDirectory -PathType Container) { Copy-Item -LiteralPath $languageDirectory -Destination $payload -Recurse }
if ($ContentDirectory) {
    $ContentDirectory = (Resolve-Path -LiteralPath $ContentDirectory).ProviderPath
    if (-not (Test-Path -LiteralPath $ContentDirectory -PathType Container)) { throw 'ContentDirectory must be a directory.' }
    $contentPrefix = $ContentDirectory.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($payload.StartsWith($contentPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'ContentDirectory must not contain the staging directory. Use a dedicated runtime resource directory.'
    }
    # Overlay additional runtime resources, while keeping the executable from the
    # architecture-checked build and generating the manifest and logos below.
    Get-ChildItem -LiteralPath $ContentDirectory -Force | Where-Object { $_.Name -ne "$projectName.exe" } |
        Copy-Item -Destination $payload -Recurse -Force
}
Add-Type -AssemblyName System.Drawing
foreach ($size in @(44, 150)) {
    $logoProperty = "UWP_DelphiLogo$size"
    $logoPath = $settings.$logoProperty
    if (-not $logoPath) { throw "$logoProperty is missing in the project settings." }
    if (-not [IO.Path]::IsPathRooted($logoPath)) { $logoPath = Join-Path $projectDirectory $logoPath }
    $image = [Drawing.Image]::FromFile($logoPath)
    try {
        if ($image.Width -ne $size -or $image.Height -ne $size) { throw "Expected a ${size}x${size} logo: $logoPath" }
        $image.Save((Join-Path $assetDirectory "Logo${size}x${size}.png"), [Drawing.Imaging.ImageFormat]::Png)
        if ($size -eq 150) {
            $storeLogo = [Drawing.Bitmap]::new(50, 50)
            $graphics = [Drawing.Graphics]::FromImage($storeLogo)
            try {
                $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.DrawImage($image, 0, 0, 50, 50)
                $storeLogo.Save((Join-Path $assetDirectory 'StoreLogo.png'), [Drawing.Imaging.ImageFormat]::Png)
            } finally { $graphics.Dispose(); $storeLogo.Dispose() }
        }
    } finally { $image.Dispose() }
}
# XML DOM assignments escape Partner Center names and descriptions correctly.
[xml]$manifest = @'
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
 xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
 xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"
 IgnorableNamespaces="uap rescap">
 <Identity Name="" Publisher="" Version="" ProcessorArchitecture="" />
 <Properties><DisplayName/><PublisherDisplayName/><Description/><Logo>Assets\StoreLogo.png</Logo></Properties>
 <Resources><Resource Language="en-US" /></Resources>
 <Dependencies><TargetDeviceFamily Name="Windows.Desktop" MinVersion="" MaxVersionTested="" /></Dependencies>
 <Applications><Application Id="RetroMul" Executable="" EntryPoint="Windows.FullTrustApplication">
  <uap:VisualElements DisplayName="" Description="" BackgroundColor="transparent"
   Square150x150Logo="Assets\Logo150x150.png" Square44x44Logo="Assets\Logo44x44.png" />
 </Application></Applications>
 <Capabilities><rescap:Capability Name="runFullTrust" /></Capabilities>
</Package>
'@
$manifest.Package.Identity.SetAttribute('Name', $PackageName)
$manifest.Package.Identity.SetAttribute('Publisher', $Publisher)
$manifest.Package.Identity.SetAttribute('Version', $Version)
$manifest.Package.Identity.SetAttribute('ProcessorArchitecture', $architecture)
foreach ($property in @('DisplayName', 'PublisherDisplayName', 'Description')) {
    $manifest.Package.Properties.SelectSingleNode("*[local-name()='$property']").InnerText = Get-Variable -Name $property -ValueOnly
}
$manifest.Package.Dependencies.TargetDeviceFamily.SetAttribute('MinVersion', $MinVersion)
$manifest.Package.Dependencies.TargetDeviceFamily.SetAttribute('MaxVersionTested', $MaxVersionTested)
$manifest.Package.Applications.Application.SetAttribute('Executable', "$projectName.exe")
$visualElements = $manifest.Package.Applications.Application.SelectSingleNode("*[local-name()='VisualElements']")
$visualElements.SetAttribute('DisplayName', $DisplayName)
$visualElements.SetAttribute('Description', $Description)
$xmlSettings = [Xml.XmlWriterSettings]::new()
$xmlSettings.Encoding = [Text.UTF8Encoding]::new($false)
$xmlSettings.Indent = $true
$writer = [Xml.XmlWriter]::Create((Join-Path $payload 'AppxManifest.xml'), $xmlSettings)
try { $manifest.Save($writer) } finally { $writer.Dispose() }

$temporaryPackage = Join-Path $workDirectory "$projectName.msix"
if ($SigningCertificateThumbprint) {
    $stagedExecutable = Join-Path $payload "$projectName.exe"
    $signArguments = @('sign', '/fd', 'SHA256', '/sha1', $SigningCertificateThumbprint, '/s', 'My',
        '/tr', $TimestampUrl, '/td', 'SHA256')
    if ($SigningCertificateStore -eq 'LocalMachine') { $signArguments += '/sm' }
    $signArguments += $stagedExecutable
    Write-Host "Signing $projectName.exe using certificate $SigningCertificateThumbprint..."
    & $SignToolPath @signArguments
    if ($LASTEXITCODE -ne 0) { throw "Executable signing failed (SignTool exit code $LASTEXITCODE). MSIX was not created." }
    & $SignToolPath verify /pa /tw $stagedExecutable
    if ($LASTEXITCODE -ne 0) { throw "Executable signature verification failed (SignTool exit code $LASTEXITCODE). MSIX was not created." }
}
Write-Host "Packaging $PackageName $Version / $architecture ($Configuration) for $PublisherDisplayName..."
& $MakeAppxPath pack /d $payload /p $temporaryPackage /o
if ($LASTEXITCODE -ne 0) { throw "MakeAppx failed (exit code $LASTEXITCODE). Working files: $workDirectory" }
if (-not (Test-Path -LiteralPath $temporaryPackage -PathType Leaf) -or (Get-Item -LiteralPath $temporaryPackage).Length -eq 0) {
    throw 'MakeAppx did not produce a nonempty MSIX package.'
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$packagePath = Join-Path $OutputDirectory "$projectName-$architecture.msix"
Move-Item -LiteralPath $temporaryPackage -Destination $packagePath -Force
Write-Host "Created $packagePath"
Write-Host "Unsigned package for Store submission. Working files: $workDirectory"
