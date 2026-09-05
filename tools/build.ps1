<#
    Builds the release archives for AdminMenuMod.

    Two packages:

      AdminMenuMod-<ver>.zip
          The mod on its own, for anyone already running UE4SS.

      AdminMenuMod-<ver>-with-UE4SS.zip
          Everything: dwmapi.dll + ue4ss/ + the mod. Extract it into
              <SteamLibrary>\steamapps\common\Voyage\Voyage\Binaries\Win64\
          and the game is ready to go. UE4SS is MIT licensed and its licence
          travels with it in ue4ss\LICENSE.

    Both use `ue4ss` as the archive root, so either one extracts to the same place.

    menu.lua and craft.lua are deliberately left out. They are developer tools -
    menuscan, which maps the game's widget tree, and craftlist/craftdata, which map
    its craftable list. main.lua loads them with pcall, so their absence is normal
    and stops nothing.

    The release has no console commands at all. Everything happens from the button.

    Usage:
        pwsh -File tools/build.ps1
        pwsh -File tools/build.ps1 -Version 1.1.0
        pwsh -File tools/build.ps1 -UE4SS "C:\path\to\unpacked\UE4SS"

    -UE4SS points at a folder holding dwmapi.dll and ue4ss\, which is what the UE4SS
    release archive unpacks to. Leave it out and only the small package is built.
#>

param(
    [string]$Version = "1.0.0",
    [string]$UE4SS = ""
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root "AdminMenuMod"
$dist = Join-Path $root "dist"
$staging = Join-Path $root ".staging"

# The files that run on a player's machine. Everything else in Scripts/ is a tool.
$runtime = @("main.lua", "state.lua", "inject.lua", "catalog.lua")
$docs = @("README.md", "LICENSE", "CHANGELOG.md")

if (-not (Test-Path $source)) {
    throw "cannot find the mod source: $source"
}

New-Item -ItemType Directory -Path $dist -Force | Out-Null

function New-Staging {
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
}

function Copy-Mod([string]$modsDir) {
    $modDir = Join-Path $modsDir "AdminMenuMod"
    $scriptDir = Join-Path $modDir "Scripts"
    New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null

    # enabled.txt turns the mod on without the player having to edit mods.txt.
    New-Item -ItemType File -Path (Join-Path $modDir "enabled.txt") -Force | Out-Null

    foreach ($file in $runtime) {
        $path = Join-Path $source "Scripts\$file"
        if (-not (Test-Path $path)) {
            throw "missing runtime file: $path"
        }
        Copy-Item $path -Destination $scriptDir
    }
}

function Copy-Docs {
    # The documents live in the repository root, where GitHub renders them.
    foreach ($doc in $docs) {
        Copy-Item (Join-Path $root $doc) -Destination $staging
    }
}

function Write-Zip([string]$name) {
    $zip = Join-Path $dist $name
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $staging "*") -DestinationPath $zip
    Remove-Item $staging -Recurse -Force

    $size = [math]::Round((Get-Item $zip).Length / 1MB, 2)
    Write-Output ("built {0}  ({1} MB)" -f $name, $size)
}

# --- the mod on its own --------------------------------------------------------------
New-Staging
Copy-Mod (Join-Path $staging "ue4ss\Mods")
Copy-Docs
Write-Zip "AdminMenuMod-$Version.zip"

# --- the mod with UE4SS --------------------------------------------------------------
$ue4ssSource = Join-Path $UE4SS "ue4ss"
$loader = Join-Path $UE4SS "dwmapi.dll"

if ($UE4SS -eq "" -or -not (Test-Path $ue4ssSource) -or -not (Test-Path $loader)) {
    Write-Output "skipping the bundled package: no UE4SS given"
    Write-Output "  point at it with -UE4SS <folder containing dwmapi.dll and ue4ss\>"
    return
}

New-Staging
Copy-Item $ue4ssSource -Destination $staging -Recurse
Copy-Item $loader -Destination $staging

# A log, a reflection dump or someone's local settings have no business in a release.
# The source should be clean anyway, but this is cheap insurance against shipping a
# 174 MB dump by accident.
Get-ChildItem -Path (Join-Path $staging "ue4ss") -Recurse -File |
    Where-Object { $_.Extension -in ".log", ".jmap", ".bak" -or $_.Name -eq "imgui.ini" } |
    ForEach-Object {
        Write-Output ("  leaving out {0}" -f $_.Name)
        Remove-Item $_.FullName -Force
    }

Copy-Mod (Join-Path $staging "ue4ss\Mods")
Copy-Docs
Write-Zip "AdminMenuMod-$Version-with-UE4SS.zip"
