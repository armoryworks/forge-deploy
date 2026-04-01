<#
.SYNOPSIS
    Publishes pcsc-relay and builds the Inno Setup installer.

.DESCRIPTION
    Produces dist\rfid-relay-setup.exe — a standard Windows installer that
    end-users double-click to install the QB Engineer RFID Relay as a
    Windows Service with no command-line interaction required.

.EXAMPLE
    .\build-installer.ps1

    # Override version:
    .\build-installer.ps1 -Version "1.2.0"
#>
param(
    [string] $Version = "1.0.0"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectDir  = Join-Path $PSScriptRoot "pcsc-relay"
$PublishDir  = Join-Path $PSScriptRoot "publish\win-x64"
$DistDir     = Join-Path $PSScriptRoot "dist"
$IssFile     = Join-Path $PSScriptRoot "rfid-relay-setup.iss"

function Write-Step([string]$msg) { Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Write-OK([string]$msg)   { Write-Host "   OK  $msg" -ForegroundColor Green }

# ── 1. Publish self-contained win-x64 exe ───────────────────────────────────

Write-Step "Publishing pcsc-relay (self-contained win-x64)..."

if (Test-Path $PublishDir) { Remove-Item $PublishDir -Recurse -Force }

dotnet publish "$ProjectDir" `
    --configuration Release `
    --runtime win-x64 `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:Version=$Version `
    --output "$PublishDir" `
    --nologo -v quiet

if ($LASTEXITCODE -ne 0) { Write-Error "dotnet publish failed." }

$exePath = Join-Path $PublishDir "pcsc-relay.exe"
if (-not (Test-Path $exePath)) { Write-Error "Expected exe not found: $exePath" }

Write-OK "Published: $([math]::Round((Get-Item $exePath).Length / 1MB, 1)) MB"

# ── 2. Run Inno Setup compiler ───────────────────────────────────────────────

Write-Step "Building installer with Inno Setup..."

if (-not (Test-Path $DistDir)) { New-Item -ItemType Directory -Path $DistDir | Out-Null }

# Try common Inno Setup install locations
$iscc = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles}\Inno Setup 6\ISCC.exe",
    (Get-Command iscc -ErrorAction SilentlyContinue)?.Source
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if (-not $iscc) {
    Write-Host @"

  Inno Setup not found. Download from: https://jrsoftware.org/isdl.php

  Alternatively, build via CI (GitHub Actions includes Inno Setup):
    - uses: Minionguyjpro/Inno-Setup-Action@v1.2.2
      with:
        path: tools/rfid-relay/rfid-relay-setup.iss

"@ -ForegroundColor Yellow
    Write-Error "Inno Setup (ISCC.exe) not found."
}

& "$iscc" /DAppVersion=$Version "$IssFile"
if ($LASTEXITCODE -ne 0) { Write-Error "ISCC failed (exit $LASTEXITCODE)." }

$installer = Join-Path $DistDir "rfid-relay-setup.exe"
Write-OK "Installer: $installer ($([math]::Round((Get-Item $installer).Length / 1MB, 1)) MB)"

# ── Done ─────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  dist\rfid-relay-setup.exe is ready to distribute." -ForegroundColor Green
Write-Host ""
Write-Host "  End-users: double-click to install. No command line needed." -ForegroundColor Green
Write-Host "  Silent deploy (IT/MDM): rfid-relay-setup.exe /VERYSILENT" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
