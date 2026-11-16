# Windows/PowerShell version of scripts/fetch-deps.sh
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
New-Item -ItemType Directory -Force vendor | Out-Null
if (-not (Test-Path vendor/FBInk/.git)) {
    git clone --depth 1 https://github.com/NiLuJe/FBInk.git vendor/FBInk
}
Push-Location vendor/FBInk
git submodule update --init --depth 1 font8x8 stb libunibreak
Pop-Location
Write-Host "FBInk ready"
