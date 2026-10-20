#requires -Version 5.1
<#
.SYNOPSIS
Creates a GitHub Release and uploads platform ZIPs and Windows MSIX packages.
.EXAMPLE
.\CreateRelease.ps1 -Tag v1.0.0
.EXAMPLE
.\CreateRelease.ps1 -Tag v1.1.0-beta.1 -Prerelease -NotesFile .\release-notes.md
.EXAMPLE
.\CreateRelease.ps1 -Tag v1.0.0 -WhatIf
.NOTES
Requires GitHub CLI (gh) authenticated with access to the repository.
Uses existing files; run BuildReleases.ps1 and BuildStorePackage.ps1 first.
Includes RetroMul-x64.msix by default. Use -StoreArchitectures x86,x64 for both
Windows packages or -StoreArchitectures @() to upload only platform ZIPs.
If the tag does not exist,
GitHub creates it at Target (main by default). No local commit or push is run.
Creates a published Latest release by default. Use -Prerelease for a preview.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^\s-][^\s]*$')]
    [string] $Tag,
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string] $Repository = 'HemulGM/RetroMul',
    [ValidateNotNullOrEmpty()]
    [string] $Target = 'main',
    [string] $Title,
    [string] $NotesFile,
    [ValidateSet('win32', 'win64', 'linux64', 'android32', 'android64', 'macos64', 'macosarm64')]
    [ValidateNotNullOrEmpty()]
    [string[]] $Platforms = @('win32', 'win64', 'linux64', 'android32', 'android64', 'macos64', 'macosarm64'),
    [ValidateSet('x86', 'x64')]
    [string[]] $StoreArchitectures = @('x64'),
    [switch] $Prerelease
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $Title) { $Title = "RetroMul $Tag" }
$releaseDirectory = Join-Path $PSScriptRoot 'releases'
$assets = @(
    foreach ($platform in ($Platforms | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)) {
        $assetPath = Join-Path $releaseDirectory "RetroMul-$platform.zip"
        if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
            throw "Release archive not found: $assetPath. Run BuildReleases.ps1 first."
        }
        if ((Get-Item -LiteralPath $assetPath).Length -eq 0) { throw "Release archive is empty: $assetPath" }
        $assetPath
    }
    foreach ($architecture in ($StoreArchitectures | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)) {
        $assetPath = Join-Path $releaseDirectory "RetroMul-$architecture.msix"
        if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
            throw "Store package not found: $assetPath. Run BuildStorePackage.ps1 for this architecture first."
        }
        if ((Get-Item -LiteralPath $assetPath).Length -eq 0) { throw "Store package is empty: $assetPath" }
        $assetPath
    }
)
if ($NotesFile) {
    if (-not (Test-Path -LiteralPath $NotesFile -PathType Leaf)) { throw "Release notes file not found: $NotesFile" }
    $NotesFile = (Resolve-Path -LiteralPath $NotesFile).ProviderPath
}

$createArguments = @('release', 'create', $Tag, '--repo', $Repository, '--target', $Target, '--title', $Title)
if ($NotesFile) { $createArguments += @('--notes-file', $NotesFile) } else { $createArguments += '--generate-notes' }
if ($Prerelease) { $createArguments += @('--prerelease', '--latest=false') } else { $createArguments += '--latest' }
$createArguments += @('--') + $assets

Write-Host "Repository: $Repository; tag: $Tag; target for a new tag: $Target"
Write-Host "Title: $Title"
Write-Host ('Release assets:' + [Environment]::NewLine + ($assets -join [Environment]::NewLine))
$action = if ($Prerelease) { 'Publish a prerelease and upload archives' } else { 'Publish a Latest release and upload archives' }
if (-not $PSCmdlet.ShouldProcess("$Repository / $Tag", $action)) { return }

$ghCommand = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghCommand) { throw 'GitHub CLI (gh) was not found. Install it from https://cli.github.com/ and run gh auth login.' }
& $ghCommand @createArguments
if ($LASTEXITCODE -ne 0) {
    throw "Release creation or upload failed (gh exit code $LASTEXITCODE). A release may remain on GitHub; inspect it before retrying."
}
$state = if ($Prerelease) { 'prerelease' } else { 'Latest' }
Write-Host "Created $state release $Tag in $Repository with $($assets.Count) files."
