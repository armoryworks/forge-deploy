#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs the QB Engineer RFID Relay as a Windows Service that starts automatically at boot.

.DESCRIPTION
    Publishes pcsc-relay as a self-contained win-x64 executable, installs it as a
    Windows Service named "QbEngineerRfidRelay", and starts it immediately.

    The service runs as LocalSystem and restarts automatically on failure.

.PARAMETER Port
    WebSocket port for the relay. Default: 9876.

.PARAMETER DebounceMs
    Debounce window in milliseconds to suppress duplicate scans. Default: 500.

.PARAMETER InstallDir
    Directory to publish the executable to. Default: C:\Program Files\QB Engineer\RfidRelay

.EXAMPLE
    .\install-service.ps1
    .\install-service.ps1 -Port 9876 -DebounceMs 300
    .\install-service.ps1 -InstallDir "D:\Services\RfidRelay"
#>

param(
    [int]    $Port        = 9876,
    [int]    $DebounceMs  = 500,
    [string] $InstallDir  = "C:\Program Files\QB Engineer\RfidRelay"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ServiceName    = "QbEngineerRfidRelay"
$DisplayName    = "QB Engineer RFID Relay"
$Description    = "Bridges USB NFC/RFID smart card readers to the QB Engineer browser app via WebSocket."
$ExeName        = "pcsc-relay.exe"
$ProjectDir     = Join-Path $PSScriptRoot "pcsc-relay"

function Write-Step([string]$msg) { Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Write-OK([string]$msg)   { Write-Host "   OK  $msg" -ForegroundColor Green }
function Write-Fail([string]$msg) { Write-Host "   ERR $msg" -ForegroundColor Red }

# ── 1. Build / publish ─────────────────────────────────────────────────────

Write-Step "Publishing pcsc-relay (self-contained win-x64)..."

if (-not (Test-Path $ProjectDir)) {
    Write-Fail "Project directory not found: $ProjectDir"
    exit 1
}

$publishOut = Join-Path $env:TEMP "pcsc-relay-publish"
dotnet publish "$ProjectDir" `
    --configuration Release `
    --runtime win-x64 `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    --output "$publishOut" `
    --nologo -v quiet

if ($LASTEXITCODE -ne 0) {
    Write-Fail "dotnet publish failed (exit $LASTEXITCODE)."
    exit $LASTEXITCODE
}

$exePath = Join-Path $publishOut $ExeName
if (-not (Test-Path $exePath)) {
    Write-Fail "Published executable not found at: $exePath"
    exit 1
}

Write-OK "Build succeeded."

# ── 2. Copy to install directory ────────────────────────────────────────────

Write-Step "Installing to: $InstallDir"

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir | Out-Null
}

$destExe = Join-Path $InstallDir $ExeName
Copy-Item -Path $exePath -Destination $destExe -Force
Write-OK "Copied $ExeName."

# ── 3. Stop + remove existing service if present ────────────────────────────

$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Step "Removing existing service '$ServiceName'..."
    if ($existing.Status -eq 'Running') {
        Stop-Service -Name $ServiceName -Force
        Start-Sleep -Seconds 2
    }
    & sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 1
    Write-OK "Existing service removed."
}

# ── 4. Register service ──────────────────────────────────────────────────────

Write-Step "Registering Windows Service '$ServiceName'..."

$binPath = "`"$destExe`" --port $Port --debounce $DebounceMs"

New-Service `
    -Name        $ServiceName `
    -BinaryPathName $binPath `
    -DisplayName $DisplayName `
    -Description $Description `
    -StartupType Automatic | Out-Null

Write-OK "Service registered."

# ── 5. Configure failure actions (restart on crash) ─────────────────────────

# Reset failure count after 1 day; restart after 5s, 10s, 30s
& sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null
Write-OK "Auto-restart on failure configured."

# ── 6. Ensure Smart Card service is running ──────────────────────────────────

Write-Step "Checking Windows Smart Card service (SCardSvr)..."

$scardSvc = Get-Service -Name SCardSvr -ErrorAction SilentlyContinue
if (-not $scardSvc) {
    Write-Host "   WARN  Smart Card service not found — reader may not be detected." -ForegroundColor Yellow
} elseif ($scardSvc.StartType -eq 'Disabled') {
    Set-Service -Name SCardSvr -StartupType Manual
    Write-OK "SCardSvr re-enabled."
} else {
    Write-OK "SCardSvr present (StartType: $($scardSvc.StartType))."
}

# ── 7. Start service ─────────────────────────────────────────────────────────

Write-Step "Starting service..."

Start-Service -Name $ServiceName
Start-Sleep -Seconds 2

$svc = Get-Service -Name $ServiceName
if ($svc.Status -eq 'Running') {
    Write-OK "Service is running."
} else {
    Write-Fail "Service did not start (Status: $($svc.Status)). Check Event Viewer > Windows Logs > Application."
    exit 1
}

# ── Done ─────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  QB Engineer RFID Relay installed and running!" -ForegroundColor Green
Write-Host "  WebSocket:  ws://localhost:$Port" -ForegroundColor Green
Write-Host "  Service:    $ServiceName" -ForegroundColor Green
Write-Host "  Executable: $destExe" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  To check status:   Get-Service $ServiceName"
Write-Host "  To view logs:      Event Viewer > Windows Logs > Application"
Write-Host "  To uninstall:      .\uninstall-service.ps1"
Write-Host ""
