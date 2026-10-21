[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$CategoryFolder,
    [Parameter(Mandatory)] [string]$FeedFile,
    [Parameter(Mandatory)] [string]$NewestVersion
)

$ErrorActionPreference = "Stop"

$root = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "Source\UniversalConfigManager"
$include = Join-Path $root "include"
$src = Join-Path $root "src"
$exe = Join-Path $PSScriptRoot "UpdateNoticeTests.exe"
$objDir = Join-Path $env:TEMP "UpdateNoticeTests-obj"
New-Item -ItemType Directory -Force $objDir | Out-Null

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$vcvars = Join-Path $vs "VC\Auxiliary\Build\vcvars64.bat"

$bat = Join-Path $env:TEMP "UpdateNoticeTests-build.bat"
@"
@echo off
call "$vcvars" >nul
cl /std:c++20 /EHsc /nologo /W4 /utf-8 /I "$include" "$src\IdentityParse.cpp" "$src\Strings.cpp" "$src\Update.cpp" "$PSScriptRoot\test_main.cpp" /Fo"$objDir\\" /Fe"$exe"
"@ | Set-Content -Path $bat -Encoding ASCII

& cmd.exe /c "`"$bat`""
if ($LASTEXITCODE -ne 0) { throw "Build failed with exit code $LASTEXITCODE." }
& $exe $CategoryFolder $FeedFile $NewestVersion
exit $LASTEXITCODE
