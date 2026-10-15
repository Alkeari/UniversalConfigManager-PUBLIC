<#
.SYNOPSIS
Stages Universal Config Manager for local testing under a separate Dev package identity.

.DESCRIPTION
Universal Config Manager is a UE4SS Lua mod: no build step, Info.json and Scripts/ ship exactly
as committed. This script never touches the released package; it only stages a second,
disposable package beside it and flips the loader's enable switch between the two.

  -Package   (default) Stages a DEV build under the workshop root at $LocalPackageId as its own
             package, "UniversalConfigManagerDev" ("Universal Config Manager (Dev)"), with
             "DebugMode": true so the loader reinstalls it on every launch. The released package
             (PackageName UniversalConfigManager, once it exists as a subscribed Workshop item)
             is never touched; instead the script flips the loader's enable switch in
             Mods\PalModSettings.ini so that ONLY the dev package is active. Safe to run with
             Palworld open; the game never loads from the staging folder directly.

  -Unstage   Removes the dev package (staging folder, installed copy, loader record) and gives
             the enable switch back to the released package name. Run it when a test session is
             over, or the next launch keeps running the dev build.

  -Release   Writes the two publishable packages:
               out/UniversalConfigManager-<version>.zip        Steam Workshop. Loader package:
                                                               Info.json exactly as committed
                                                               (DebugMode false, depends on the
                                                               Workshop UE4SS), Scripts/.
               out/UniversalConfigManager-<version>-nexus.zip  Nexus Mods. Full-game-path UE4SS
                                                               mod (Pal\Binaries\Win64\ue4ss\
                                                               Mods\UniversalConfigManager\ with
                                                               enabled.txt, no Info.json) for a
                                                               UE4SS from Nexus Mods; the Pal\
                                                               prefix is what Vortex needs.
             Same Scripts/ in both; only the wrapper differs. Never upload the staged test copy.

Pass any combination; passing none runs -Package only. Publishing is NOT done here:
The separate publishing tool takes <this repo>, builds through -Release and
uploads from out\.
#>
[CmdletBinding()]
param(
    [switch]$Package,
    [switch]$Unstage,
    [switch]$Release,
    [string]$GameRoot = "D:\Steam\steamapps\common\Palworld",
    [string]$LocalPackageId = "9000000006"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$packageName = "UniversalConfigManager"
$devPackageName = "$($packageName)Dev"
$settingsIni = Join-Path $GameRoot "Mods\PalModSettings.ini"

if (-not $Package -and -not $Unstage -and -not $Release) { $Package = $true }

# The loader's enable switch: one "ActiveModList=<PackageName>" line per enabled package in
# PalModSettings.ini, the same file Options -> Mod Management writes. Exactly one of the released
# package and the dev package is ever enabled.
function Set-ActivePackage([string]$enable, [string]$disable) {
    $lines = Get-Content -LiteralPath $settingsIni
    $lines = @($lines | Where-Object { $_ -ne "ActiveModList=$disable" })
    if (-not ($lines -contains "ActiveModList=$enable")) {
        $index = [array]::FindLastIndex($lines, [Predicate[string]]{ param($l) $l -like "ActiveModList=*" })
        if ($index -lt 0) { $index = $lines.Count - 1 }
        $lines = $lines[0..$index] + @("ActiveModList=$enable") + $(if ($index + 1 -lt $lines.Count) { $lines[($index + 1)..($lines.Count - 1)] } else { @() })
    }
    Set-Content -LiteralPath $settingsIni -Value $lines -Encoding UTF8
    Write-Host "Loader enable switch: $enable on, $disable off"
}

function Get-WorkshopRoot {
    $match = Select-String -Path $settingsIni -Pattern "^WorkshopRootDir=(.+)$"
    if (-not $match) { throw "WorkshopRootDir not found in $settingsIni" }
    return $match.Matches[0].Groups[1].Value.Trim()
}

if ($Unstage) {
    $workshopRoot = Get-WorkshopRoot
    foreach ($p in (Join-Path $workshopRoot $LocalPackageId),
                   (Join-Path $GameRoot "Mods\NativeMods\UE4SS\Mods\$devPackageName"),
                   (Join-Path $GameRoot "Mods\ManagedMods\$devPackageName")) {
        if (Test-Path $p) { Remove-Item -LiteralPath $p -Recurse -Force; Write-Host "Removed $p" }
    }
    Set-ActivePackage -enable $packageName -disable $devPackageName
    Write-Host "Dev build unstaged. Next launch runs the released package (once published)."
    return
}

if ($Package) {
    $workshopRoot = Get-WorkshopRoot
    $staging = Join-Path $workshopRoot $LocalPackageId

    # A separate package so the loader installs it beside, never over, the released item. The
    # staged copy must reinstall on every launch; the committed manifest must not.
    $info = Get-Content -LiteralPath (Join-Path $repoRoot "Info.json") -Raw | ConvertFrom-Json
    $info.PackageName = $devPackageName
    $info.ModName = "$($info.ModName) (Dev)"
    $info.DebugMode = $true
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    $info | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $staging "Info.json") -Encoding UTF8

    $stagedScripts = Join-Path $staging "Scripts"
    if (Test-Path $stagedScripts) { Remove-Item -LiteralPath $stagedScripts -Recurse -Force }
    Copy-Item -LiteralPath (Join-Path $repoRoot "Scripts") -Destination $staging -Recurse -Force
    $stagedAssets = Join-Path $staging "Assets"
    if (Test-Path $stagedAssets) { Remove-Item -LiteralPath $stagedAssets -Recurse -Force }
    Copy-Item -LiteralPath (Join-Path $repoRoot "Assets") -Destination $staging -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot "LICENSE.md") -Destination $staging -Force

    Set-ActivePackage -enable $devPackageName -disable $packageName
    Write-Host "Dev package staged at $staging"
    Write-Host "Fully close and relaunch Palworld: DebugMode reinstalls from this staged copy on launch, and only a real relaunch proves it."
    Write-Host "When the test session is over: tools/deploy.ps1 -Unstage (re-enables the released package name)."
}

if ($Release) {
    # The ONLY identity that ever ships is the released one. Anything else in the committed
    # manifest (a dev name, debug mode, a stray suffix) stops the release here.
    $info = Get-Content -LiteralPath (Join-Path $repoRoot "Info.json") -Raw | ConvertFrom-Json
    if ($info.PackageName -ne $packageName) { throw "Info.json PackageName is '$($info.PackageName)'; a release must be exactly '$packageName'." }
    if ($info.ModName -ne "Universal Config Manager") { throw "Info.json ModName is '$($info.ModName)'; a release must be exactly 'Universal Config Manager'." }
    if ($info.DebugMode) { throw "Info.json has DebugMode true; a release package must ship with it false." }

    $outDir = Join-Path $repoRoot "out"
    $pkgDir = Join-Path $outDir $packageName
    if (Test-Path $pkgDir) { Remove-Item -Recurse -Force $pkgDir }
    New-Item -ItemType Directory -Force -Path $pkgDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot "Info.json") -Destination $pkgDir -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot "LICENSE.md") -Destination $pkgDir -Force
    # Copied only when present, so the package still builds before a thumbnail exists.
    $thumbnail = Join-Path $repoRoot "thumbnail.png"
    if (Test-Path $thumbnail) { Copy-Item -LiteralPath $thumbnail -Destination $pkgDir -Force }
    Copy-Item -LiteralPath (Join-Path $repoRoot "PACKAGE_README.txt") -Destination (Join-Path $pkgDir "README.txt") -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot "Scripts") -Destination $pkgDir -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot "Assets") -Destination $pkgDir -Recurse -Force
    $zip = Join-Path $outDir "$packageName-$($info.Version).zip"
    if (Test-Path $zip) { Remove-Item -Force $zip }
    Compress-Archive -Path $pkgDir -DestinationPath $zip
    Write-Host "Steam Workshop package written to $zip"

    # Nexus Mods package: the same Scripts/ as a plain UE4SS mod. A Nexus or GitHub UE4SS
    # lives in Pal\Binaries\Win64\ue4ss\ and loads Mods\<Name>\Scripts\main.lua when
    # enabled.txt exists. The zip carries the FULL game path,
    # Pal\Binaries\Win64\ue4ss\Mods\UniversalConfigManager\, because that is the one layout
    # every version of Vortex's Palworld extension auto-installs: its root-mod installer
    # matches a top-level Pal\ folder and deploys the archive verbatim to the game root (the
    # same finding Palpedia Enhancer's packaging records). Manual users extract into the
    # Palworld install folder. No Info.json: the Palworld loader is not involved.
    $nexusRoot = Join-Path $outDir "nexus"
    if (Test-Path $nexusRoot) { Remove-Item -Recurse -Force $nexusRoot }
    $nexusDir = Join-Path $nexusRoot "Pal\Binaries\Win64\ue4ss\Mods\$packageName"
    New-Item -ItemType Directory -Force -Path $nexusDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot "Scripts") -Destination $nexusDir -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot "Assets") -Destination $nexusDir -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot "LICENSE.md") -Destination $nexusDir -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot "PACKAGE_README_NEXUS.txt") -Destination (Join-Path $nexusDir "README.txt") -Force
    Set-Content -LiteralPath (Join-Path $nexusDir "enabled.txt") -Value "" -NoNewline
    $nexusZip = Join-Path $outDir "$packageName-$($info.Version)-nexus.zip"
    if (Test-Path $nexusZip) { Remove-Item -Force $nexusZip }
    Compress-Archive -Path (Join-Path $nexusRoot "Pal") -DestinationPath $nexusZip
    Write-Host "Nexus Mods package written to $nexusZip"
}
