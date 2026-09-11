<#
.SYNOPSIS
    Builds and refreshes the personal portable install under dist\.

.DESCRIPTION
    The `data` folder beside the executable is the portable switch:
    app_settings::portable_data_directory keeps settings, themes and cache
    there instead of in %APPDATA%.

    Ownership is split so the script can run over a folder that is in daily
    use. The script owns the executable, the note in data\, and the Compact
    Stacked theme documents, which come from src\themes\ -- the source of
    truth shared between machines through git. Everything else under data\
    belongs to the app and to you: settings, cache, context menus, and any
    theme the script does not ship are never touched.

    A running widget holds a lock on its own executable, so it is stopped
    before the copy and started again afterwards unless -NoRestart says not
    to.

.PARAMETER SkipBuild
    Reuse the binary already in target\release instead of building again.

.PARAMETER Archive
    Also write a .zip of the payload, for copying to another machine.

.PARAMETER NoRestart
    Leave the widget stopped after replacing the executable.
#>
[CmdletBinding()]
param(
    [switch] $SkipBuild,
    [switch] $Archive,
    [switch] $NoRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path $PSScriptRoot -Parent
$Manifest = Join-Path $RepoRoot 'Cargo.toml'
$PackageName = 'claude-code-usage-monitor'
$ExeName = "$PackageName.exe"

# Theme documents that ship as files, edited in src\themes\ and carried
# between machines by git. Their names already follow the <theme id>.json
# convention the app writes, so they load as-is.
$ShippedThemes = @(
    'compact-stacked-fable.json'
)

function Get-PackageVersion {
    # Match the [package] version only; dependency tables carry a `version`
    # key at line start too, so an unanchored search picks the wrong one.
    $manifestText = Get-Content -LiteralPath $Manifest -Raw
    $match = [regex]::Match($manifestText, '(?ms)^\[package\].*?^version\s*=\s*"([^"]+)"')
    if (-not $match.Success) {
        throw "Could not read the package version from $Manifest."
    }
    $match.Groups[1].Value
}

function Invoke-ReleaseBuild {
    Write-Host 'Building release binary...' -ForegroundColor Cyan
    cargo build --release --manifest-path $Manifest
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build failed with exit code $LASTEXITCODE."
    }
}

function Stop-InstalledWidget {
    param([Parameter(Mandatory)] [string] $InstalledExe)

    # Only this copy: another checkout, or a winget install, is none of our
    # business and stopping it would be a surprise.
    $running = @(Get-Process -Name $PackageName -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $InstalledExe })
    if ($running.Count -eq 0) {
        return $false
    }

    Write-Host 'Stopping the running widget...' -ForegroundColor DarkGray
    $running | Stop-Process -Force
    foreach ($process in $running) {
        # Waiting on the handle beats polling for the name: the lock is gone
        # once the process object reports exit.
        $null = $process.WaitForExit(10000)
        if (-not $process.HasExited) {
            throw "$ExeName did not exit; quit it from the tray icon and run this again."
        }
    }
    $true
}

function Start-InstalledWidget {
    param([Parameter(Mandatory)] [string] $InstalledExe)

    Write-Host 'Restarting the widget...' -ForegroundColor DarkGray
    Start-Process -FilePath $InstalledExe -WorkingDirectory (Split-Path $InstalledExe -Parent) | Out-Null
}

function Write-PortableNote {
    param([Parameter(Mandatory)] [string] $DataRoot)

    Set-Content -LiteralPath (Join-Path $DataRoot 'README.txt') -Encoding UTF8 -Value @'
Portable data folder
====================

This folder is what makes the copy of Claude Code Usage Monitor beside it
portable. While it exists the app keeps its settings, themes and cache here
instead of in %APPDATA%\ClaudeCodeUsageMonitor. Delete it and the app goes
back to using %APPDATA%.

    settings.json      window, provider and appearance settings
    usage-cache.json   last known usage, so the widget has something to show
                       before the first poll finishes
    context-menus\     menu documents, installed by the app
    themes\            theme documents (.json)
    themes\assets\     images referenced by themes

Classic and Minecraft are built into the executable and install themselves
into themes\ on first run.

The Compact Stacked themes are files, and scripts\make-dist.ps1 copies them
from src\themes\ on every run. That is where they are edited and how they
travel between machines, so edit them there -- a change made here in Theme
Studio is overwritten the next time the script runs. Themes saved under any
other name are left alone.

This file and the executable are the script's; everything else here is yours
and survives a rebuild.
'@
}

function Copy-ShippedThemes {
    param([Parameter(Mandatory)] [string] $DataRoot)

    $sourceRoot = Join-Path $RepoRoot 'src\themes'
    $targetRoot = Join-Path $DataRoot 'themes'
    New-Item -Path $targetRoot -ItemType Directory -Force | Out-Null

    foreach ($theme in $ShippedThemes) {
        $source = Join-Path $sourceRoot $theme
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Theme $theme is missing from $sourceRoot."
        }

        # src\themes\ wins, but say so when the installed copy has drifted:
        # that means an edit was made in Theme Studio and is about to be lost.
        $target = Join-Path $targetRoot $theme
        if (Test-Path -LiteralPath $target) {
            $installed = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
            $authored = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
            if ($installed -ne $authored) {
                Write-Warning "$theme differs from src\themes\ and is being replaced."
            }
        }
        Copy-Item -LiteralPath $source -Destination $targetRoot -Force
    }
}

$version = Get-PackageVersion
$distRoot = Join-Path $RepoRoot 'dist'
$payloadRoot = Join-Path $distRoot $PackageName
$dataRoot = Join-Path $payloadRoot 'data'
$builtExe = Join-Path $RepoRoot "target\release\$ExeName"

if (-not $SkipBuild) {
    Invoke-ReleaseBuild
}

if (-not (Test-Path -LiteralPath $builtExe)) {
    throw "$builtExe is missing. Run without -SkipBuild to build it first."
}

$isFirstRun = -not (Test-Path -LiteralPath $dataRoot)
Write-Host "Staging $PackageName $version..." -ForegroundColor Cyan

New-Item -Path $payloadRoot -ItemType Directory -Force | Out-Null
$installedExe = Join-Path $payloadRoot $ExeName
$wasRunning = Stop-InstalledWidget -InstalledExe $installedExe
Copy-Item -LiteralPath $builtExe -Destination $payloadRoot -Force

New-Item -Path $dataRoot -ItemType Directory -Force | Out-Null
Write-PortableNote -DataRoot $dataRoot
Copy-ShippedThemes -DataRoot $dataRoot

if ($isFirstRun) {
    Write-Host 'Created a fresh data folder.' -ForegroundColor DarkGray
}
else {
    Write-Host 'Kept the existing data folder; refreshed the shipped themes.' -ForegroundColor DarkGray
}

if ($Archive) {
    $archivePath = Join-Path $distRoot "$PackageName-$version.zip"
    if (Test-Path -LiteralPath $archivePath) {
        Remove-Item -LiteralPath $archivePath -Force
    }
    Compress-Archive -Path $payloadRoot -DestinationPath $archivePath
    Write-Host "Archive: $archivePath" -ForegroundColor Green
}

Write-Host "Payload: $payloadRoot" -ForegroundColor Green

if ($wasRunning -and -not $NoRestart) {
    Start-InstalledWidget -InstalledExe $installedExe
}
