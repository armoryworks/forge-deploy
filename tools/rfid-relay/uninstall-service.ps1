#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Uninstalls the QB Engineer RFID Relay Windows Service.

.PARAMETER InstallDir
    Directory where the executable was installed. Default matches install-service.ps1.
    If specified and the directory contains only the relay, it will be removed.
#>

param(
    [string] $InstallDir = "C:\Program Files\QB Engineer\RfidRelay"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ServiceName = "QbEngineerRfidRelay"

function Write-Step([string]$msg) { Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Write-OK([string]$msg)   { Write-Host "   OK  $msg" -ForegroundColor Green }

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

if (-not $svc) {
    Write-Host "Service '$ServiceName' is not installed." -ForegroundColor Yellow
} else {
    Write-Step "Stopping service '$ServiceName'..."
    if ($svc.Status -eq 'Running') {
        Stop-Service -Name $ServiceName -Force
        Start-Sleep -Seconds 2
    }
    Write-OK "Stopped."

    Write-Step "Removing service..."
    & sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 1
    Write-OK "Service removed."
}

if (Test-Path $InstallDir) {
    Write-Step "Removing install directory: $InstallDir"
    Remove-Item -Path $InstallDir -Recurse -Force
    Write-OK "Directory removed."
}

Write-Host ""
Write-Host "QB Engineer RFID Relay uninstalled." -ForegroundColor Green
Write-Host ""
