# build-wsl.ps1 [rom...] [-Keys aes_keys.txt] [-Out folder]
# Pocket Native Windows build using Microsoft's WSL container CLI (wslc.exe)
# instead of Docker Desktop / Podman. Requires WSL 2.9.3+ with wslc.
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Rom = @(),
    [string]$Keys = "",
    [string]$Out = ""
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$Host.UI.RawUI.WindowTitle = "Pocket Native (WSL Containers)"

function Pick($title, $filter, $many) {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.OpenFileDialog -Property @{ Title = $title; Filter = $filter; Multiselect = $many }
    $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
    $picked = "$($dialog.ShowDialog($owner))" -eq "OK"
    $owner.Dispose()
    [void](New-Object -ComObject WScript.Shell).AppActivate("Pocket Native (WSL Containers)")
    if (-not $picked) { return @() }
    return $dialog.FileNames
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Write-Host "WSL is not installed."
    Write-Host "Install it from an Administrator PowerShell with:  wsl --install"
    exit 1
}
if (-not (Get-Command wslc.exe -ErrorAction SilentlyContinue)) {
    Write-Host "wslc.exe was not found. Pocket Native's WSL build requires WSL 2.9.3 or newer."
    Write-Host "Update WSL with:  wsl --update"
    Write-Host "Then verify it with:  wslc version"
    exit 1
}

if ($Rom.Count -eq 0) {
    $Rom = @(Pick "Pick the games to build" "3DS games (*.3ds;*.cci;*.cia;*.zcci;*.zcia)|*.3ds;*.cci;*.cia;*.zcci;*.zcia|All files|*.*" $true)
    if ($Rom.Count -eq 0) { Write-Host "no game picked"; exit 2 }
}
foreach ($file in $Rom) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        Write-Host "usage: scripts\build-wsl.ps1 [rom...] [-Keys aes_keys.txt] [-Out folder]"
        Write-Host "no such file: $file"
        exit 2
    }
}
$Rom = @($Rom | ForEach-Object { (Resolve-Path -LiteralPath $_).Path })
if ($Keys) { $Keys = (Resolve-Path -LiteralPath $Keys -ErrorAction Stop).Path }
if (-not $Out) { $Out = Join-Path $repo "build" }
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path -LiteralPath $Out).Path

function KeysFor($file) {
    if ($script:Keys) { return $script:Keys }
    foreach ($near in @((Join-Path (Split-Path -Parent $file) "aes_keys.txt"), (Join-Path $repo "aes_keys.txt"))) {
        if (Test-Path -LiteralPath $near -PathType Leaf) { return $near }
    }
    if (@(".cia", ".zcia") -notcontains [IO.Path]::GetExtension($file).ToLower()) { return $null }
    $picked = @(Pick "A .cia needs your console's aes_keys.txt, pick it" "aes_keys.txt|aes_keys.txt|Text files (*.txt)|*.txt" $false)
    if ($picked.Count -gt 0) { $script:Keys = $picked[0] }
    return $script:Keys
}

# Keep the official Pocket Native container definition. The hash gives each
# Containerfile revision its own cached image, like the original build.ps1.
$containerFile = Join-Path $repo "scripts\container\Containerfile"
if (-not (Test-Path -LiteralPath $containerFile -PathType Leaf)) {
    Write-Host "Pocket Native Containerfile not found: $containerFile"
    exit 1
}
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $containerFile).Hash.ToLower().Substring(0, 12)
$image = "pocket-native-build:$hash"

# wslc's CLI intentionally follows familiar container CLI syntax. Try an
# inspect first; if the image is absent, build it from Pocket Native's file.
& wslc.exe image inspect $image *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "== making the WSL build container, once"
    & wslc.exe build -f $containerFile -t $image (Join-Path $repo "scripts\container")
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$failed = @()
foreach ($file in $Rom) {
    Write-Host "== building $(Split-Path -Leaf $file)"
    $mounts = @(
        "-v", "${repo}:/src:ro",
        "-v", "pocket-native-work:/work",
        "-v", "${Out}:/out",
        "-v", "$(Split-Path -Parent $file):/rom:ro"
    )
    $arguments = @("/rom/$(Split-Path -Leaf $file)")
    $gameKeys = KeysFor $file
    if ($gameKeys) {
        $mounts += @("-v", "$(Split-Path -Parent $gameKeys):/keys:ro")
        $arguments += "/keys/$(Split-Path -Leaf $gameKeys)"
    }

    & wslc.exe run --rm @mounts `
        -e CARGO_HOME=/work/cargo `
        -e CARGO_TARGET_DIR=/work/target `
        -e HOME=/work `
        $image bash /src/scripts/container/inside.sh @arguments
    if ($LASTEXITCODE -ne 0) { $failed += $file }
}

# Same harmless release check as Pocket Native's official Windows script.
$updateScript = Join-Path $PSScriptRoot "update.ps1"
if (Test-Path -LiteralPath $updateScript -PathType Leaf) {
    & $updateScript -Check
}

if ($failed.Count -gt 0) {
    Write-Host "== these did not build:"
    $failed | ForEach-Object { Write-Host "   $_" }
    exit 1
}
Write-Host "== done: $Out\Pocket Native"
exit 0
