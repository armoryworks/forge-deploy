#!/usr/bin/env pwsh
# refresh.ps1 - Pull latest main, rebuild images, and start QB Engineer
#
# Usage:
#   .\refresh.ps1                  # Pull main, rebuild UI + API, start all core services
#   .\refresh.ps1 -IncludeAi       # Also start Ollama + pull AI models
#   .\refresh.ps1 -IncludeSigning  # Also start DocuSeal signing service
#   .\refresh.ps1 -RecreateDb      # Wipe and reseed the database
#   .\refresh.ps1 -IncludeAi -IncludeSigning

param(
    [switch]$IncludeAi,
    [switch]$IncludeSigning,
    [switch]$RecreateDb
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Helpers ---

function Write-Step([string]$msg) {
    Write-Host "`n==> $msg" -ForegroundColor Cyan
}

function Write-Ok([string]$msg) {
    Write-Host "    [OK] $msg" -ForegroundColor Green
}

function Write-Warn([string]$msg) {
    Write-Host "    [!!] $msg" -ForegroundColor Yellow
}

function Invoke-Cmd([string]$desc, [scriptblock]$cmd) {
    Write-Host "    $desc..." -NoNewline
    try {
        & $cmd
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "exit code $LASTEXITCODE" }
        Write-Host " done" -ForegroundColor Green
    } catch {
        Write-Host " FAILED" -ForegroundColor Red
        throw
    }
}

# --- Pre-flight ---

Write-Step "Pre-flight checks"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "Docker not found in PATH. Install Docker Desktop and try again."
    exit 1
}

docker info *>$null
if ($LASTEXITCODE -ne 0) {
    Write-Error "Docker daemon is not running. Start Docker Desktop and try again."
    exit 1
}
Write-Ok "Docker is running"

if (-not (Test-Path "docker-compose.yml")) {
    Write-Error "Run this script from the repo root (where docker-compose.yml lives)."
    exit 1
}
Write-Ok "Working directory: $(Get-Location)"

# --- Git pull main ---

Write-Step "Pulling latest code from main"

$currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
if ($currentBranch -ne "main") {
    Write-Warn "Currently on branch '$currentBranch' - switching to main"
    Invoke-Cmd "git checkout main" { git checkout main }
}

Invoke-Cmd "git pull origin main" { git pull origin main }

# --- Capture build version from git ---

$env:BUILD_VERSION = git rev-list --count HEAD 2>$null
$env:BUILD_SHA     = git rev-parse --short HEAD 2>$null
Write-Ok "Build version: $env:BUILD_VERSION ($env:BUILD_SHA)"

# Write version.json to disk so the dev volume mount picks it up
$versionJson = '{"version":"' + $env:BUILD_VERSION + '","sha":"' + $env:BUILD_SHA + '"}'
$versionPath = Join-Path (Get-Location) "qb-engineer-ui\public\assets\version.json"
Set-Content -Path $versionPath -Value $versionJson -Encoding UTF8 -NoNewline
Write-Ok "Wrote $versionPath"

# --- Remove running app containers (preserve db + storage volumes) ---

Write-Step "Removing app containers"
Invoke-Cmd "Remove UI + API containers" {
    docker compose rm -sf qb-engineer-ui qb-engineer-api
}

# --- Refresh node_modules volume if package.json changed ---

Write-Step "Checking for dependency changes"
$pkgChanged = git diff 'HEAD@{1}' --name-only 2>$null | Select-String "qb-engineer-ui/package"
if ($pkgChanged) {
    Write-Warn "package.json changed - recreating node_modules volume"
    Invoke-Cmd "Remove ui_node_modules volume" {
        docker volume rm -f qb-engineer-wrapper_ui_node_modules 2>$null
    }
} else {
    Write-Ok "No package.json changes detected"
}

# --- Build images ---

Write-Step "Building images (no cache)"
Invoke-Cmd "Build API" {
    docker compose build --no-cache qb-engineer-api
}
Invoke-Cmd "Build UI" {
    docker compose build --no-cache qb-engineer-ui
}

# --- Compose up - core services ---

Write-Step "Starting core services"

$env:RECREATE_DB = if ($RecreateDb) { "true" } else { "false" }
if ($RecreateDb) {
    Write-Warn "RECREATE_DB=true -- database will be wiped and reseeded"
}

$coreServices = @(
    "qb-engineer-db",
    "qb-engineer-storage",
    "qb-engineer-backup",
    "qb-engineer-api",
    "qb-engineer-ui"
)

Invoke-Cmd "docker compose up -d (core)" {
    docker compose up -d --force-recreate --remove-orphans @coreServices
}

# --- Optional: AI ---

if ($IncludeAi) {
    Write-Step "Starting AI service (Ollama)"
    Write-Warn "First run pulls gemma3:4b + all-minilm:l6-v2 - this can take several minutes"
    Invoke-Cmd "docker compose up -d (AI)" {
        docker compose --profile ai up -d qb-engineer-ai qb-engineer-ai-init
    }
} else {
    Write-Warn "Skipping AI service. Add -IncludeAi to include Ollama."
}

# --- Optional: Signing ---

if ($IncludeSigning) {
    Write-Step "Starting DocuSeal signing service"
    Invoke-Cmd "docker compose up -d (signing)" {
        docker compose --profile signing up -d qb-engineer-signing
    }
} else {
    Write-Warn "Skipping signing service. Add -IncludeSigning to include DocuSeal."
}

# --- Wait for API health ---

Write-Step "Waiting for API to become healthy"
$maxWait = 60
$elapsed = 0
$healthy = $false

while ($elapsed -lt $maxWait) {
    $status = docker inspect --format='{{.State.Health.Status}}' qb-engineer-api 2>$null
    if ($status -eq "healthy") {
        $healthy = $true
        break
    }
    $msg = "    API status: $status (" + $elapsed + "s / " + $maxWait + "s)"
    Write-Host $msg -ForegroundColor DarkGray
    Start-Sleep 5
    $elapsed += 5
}

if ($healthy) {
    Write-Ok "API is healthy"
} else {
    Write-Warn "API health check timed out after $maxWait s - check logs: docker compose logs -f qb-engineer-api"
}

# --- Status ---

Write-Step "Container status"
docker compose ps

Write-Host ""
Write-Host "  UI:      http://localhost:4200" -ForegroundColor White
Write-Host "  API:     http://localhost:5000" -ForegroundColor White
Write-Host "  MinIO:   http://localhost:9001  (minioadmin / minioadmin)" -ForegroundColor White
if ($IncludeAi)      { Write-Host "  Ollama:  http://localhost:11434" -ForegroundColor White }
if ($IncludeSigning) { Write-Host "  DocuSeal: http://localhost:3000" -ForegroundColor White }
Write-Host ""
Write-Host "  Logs:    docker compose logs -f qb-engineer-api" -ForegroundColor DarkGray
Write-Host "  Stop:    docker compose stop" -ForegroundColor DarkGray
Write-Host "  DB CLI:  docker compose exec qb-engineer-db psql -U postgres -d qb_engineer" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  IMPORTANT: Open http://localhost:4200 and press Ctrl+Shift+R (or Cmd+Shift+R on Mac)" -ForegroundColor Yellow
Write-Host "             to hard-refresh the browser and pick up the latest UI changes." -ForegroundColor Yellow
Write-Host ""
