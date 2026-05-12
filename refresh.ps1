#!/usr/bin/env pwsh
# refresh.ps1 - Pull latest main, rebuild images, and start Forge
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

# --- Phase 7: Pi-side guard — forge-deploy supersedes refresh on prod ---
#
# refresh.ps1 is the legacy git-pull-and-rebuild proxy. Phase 6 of the CICD
# rollout retired it on the Pi: prod now pulls prebuilt GHCR images via
# forge-deploy (with healthcheck-gated rollback).
#
# Sentinel: /etc/forge/deploy-state.json — created by
# scripts/install-forge-deploy.sh on Pi-style hosts. On Windows workstations
# the path is absent and the guard is a no-op (Test-Path returns $false
# for Linux-style paths), so the local-build dev loop continues to work.
# PowerShell Core (pwsh) on the Pi would catch the sentinel and abort.
#
# See docs/cicd-design.md (Phase 7) and docs/forge-deploy.md.
if (Test-Path -PathType Leaf '/etc/forge/deploy-state.json') {
    Write-Host "ERROR: refresh.ps1 is the legacy git-pull-and-rebuild proxy, retired on the Pi side." -ForegroundColor Red
    Write-Host "       This host has forge-deploy installed (state file at /etc/forge/deploy-state.json)."
    Write-Host ""
    Write-Host "       Use forge-deploy instead (in a bash shell):"
    Write-Host "         forge-deploy --list --releases # see available semver tags in GHCR"
    Write-Host "         forge-deploy 1.2.3             # deploy that semver to all services"
    Write-Host "         forge-deploy --list            # see recent main-<sha> tags (legacy)"
    Write-Host "         forge-deploy --status          # current deployed tag per service"
    Write-Host "         forge-deploy --rollback        # revert to prior tag"
    Write-Host ""
    Write-Host "       refresh.ps1 remains the dev-side dev-loop tool (workstations doing local builds)."
    exit 1
}

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
$versionPath = Join-Path (Get-Location) "forge-ui\public\assets\version.json"
Set-Content -Path $versionPath -Value $versionJson -Encoding UTF8 -NoNewline
Write-Ok "Wrote $versionPath"

# --- Swap in maintenance page before tearing down the real site ---

Write-Step "Swapping in maintenance page"

# Detect host port from the ACTUAL running UI container first — whatever port
# the real UI is bound to, maintenance takes over. This avoids drift between
# .env, override YAML, and whatever's actually live.
$uiPort = ""
$uiContainerPort = ""
$uiInspect = docker inspect forge-ui 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
if ($uiInspect) {
    $portsObj = $uiInspect[0].NetworkSettings.Ports
    if ($portsObj) {
        foreach ($prop in $portsObj.PSObject.Properties) {
            if ($prop.Value) {
                # prop.Name is "80/tcp", prop.Value is array of host bindings
                $containerSide = ($prop.Name -split "/")[0]
                $hostSide = $prop.Value[0].HostPort
                if ($hostSide) {
                    $uiPort = $hostSide
                    $uiContainerPort = $containerSide
                    Write-Ok "Detected live UI binding: $uiPort -> container $uiContainerPort"
                    break
                }
            }
        }
    }
}

# Fallback chain if no running container: override file -> .env -> default.
if (-not $uiPort) {
    if (Test-Path "docker-compose.override.yml") {
        $overrideContent = Get-Content "docker-compose.override.yml" -Raw -ErrorAction SilentlyContinue
        # Match both quoted "443:443" and unquoted 443:443 YAML forms.
        if ($overrideContent -match 'forge-ui[\s\S]*?ports:\s*\n\s*-\s*"?(\d+):\d+"?') {
            $uiPort = $Matches[1]
        }
    }
    if (-not $uiPort) {
        $envContent = Get-Content ".env" -ErrorAction SilentlyContinue
        if ($envContent) {
            $portLine = $envContent | Where-Object { $_ -match "^UI_PORT=" }
            if ($portLine) { $uiPort = ($portLine -split "=", 2)[1].Trim() }
        }
    }
    if (-not $uiPort) { $uiPort = "4200" }
    Write-Warn "No running UI container - falling back to detected port $uiPort"
}

# Maintenance nginx always listens on BOTH :80 and :443 internally (with a
# self-signed cert), so HTTPS-Only / cached HSTS browsers still land on the
# maintenance page. On standard ports we publish both host ports; on dev
# ports we publish that port plus :443 for the HTTPS-upgrade path.
if ($uiPort -eq "80" -or $uiPort -eq "443") {
    $maintPortMaps = @("80:80", "443:443")
} else {
    $maintPortMaps = @("${uiPort}:80", "443:443")
}

# Stop the real UI first to free the port(s)
Invoke-Cmd "Stop UI container" {
    docker compose stop forge-ui 2>$null
    docker compose rm -sf forge-ui 2>$null
}

# Always rebuild the maintenance image — nginx:alpine base is cached and
# this ensures config changes land without needing a manual rebuild.
Invoke-Cmd "Build maintenance image" {
    docker build -q -t qb-maintenance maintenance/ | Out-Null
}

# Attach maintenance to the compose network as alias `forge-ui` so
# reverse proxies that target the container hostname keep resolving during refresh.
$composeNetwork = (docker network ls --format '{{.Name}}' | Select-String -Pattern '^forge-wrapper_' | Select-Object -First 1).ToString().Trim()

function Build-RunArgs([string[]]$portMaps) {
    $args = @("-d", "--name", "qb-maintenance", "--restart", "no")
    if ($composeNetwork) {
        $args += @("--network", $composeNetwork, "--network-alias", "forge-ui")
    }
    # Mount the same cert the real UI uses (Cloudflare Origin Cert, Let's
    # Encrypt, etc.) so CF Full-strict and strict reverse proxies accept
    # the maintenance page during refresh. Falls through to self-signed
    # inside the container if .\certs doesn't exist.
    if ((Test-Path ".\certs\selfsigned.crt") -and (Test-Path ".\certs\selfsigned.key")) {
        $args += @("-v", "$((Get-Location).Path)\certs:/etc/nginx/certs:ro")
    }
    foreach ($m in $portMaps) { $args += @("-p", $m) }
    $args += "qb-maintenance"
    return $args
}

Invoke-Cmd "Start maintenance dragon" {
    docker rm -f qb-maintenance 2>$null | Out-Null
    $runArgs = Build-RunArgs $maintPortMaps
    docker run @runArgs 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Dual-port bind failed (likely :443 occupied) - retrying with primary port only"
        docker rm -f qb-maintenance 2>$null | Out-Null
        $fallback = if ($uiPort -eq "443") { @("443:443") } else { @("${uiPort}:80") }
        $runArgs = Build-RunArgs $fallback
        docker run @runArgs | Out-Null
        $script:maintPortMaps = $fallback
    }
}
Write-Ok ("Maintenance dragon is guarding ports: " + ($maintPortMaps -join ", "))
if ($composeNetwork) { Write-Ok "  attached to $composeNetwork as forge-ui" }

# --- Remove remaining app containers (preserve db + storage volumes) ---

Write-Step "Removing app containers"
Invoke-Cmd "Remove API container" {
    docker compose rm -sf forge-api
}

# --- Refresh node_modules volume if package.json changed ---

Write-Step "Checking for dependency changes"
$pkgChanged = git diff 'HEAD@{1}' --name-only 2>$null | Select-String "forge-ui/package"
if ($pkgChanged) {
    Write-Warn "package.json changed - recreating node_modules volume"
    Invoke-Cmd "Remove ui_node_modules volume" {
        docker volume rm -f forge-wrapper_ui_node_modules 2>$null
    }
} else {
    Write-Ok "No package.json changes detected"
}

# --- Build images ---

Write-Step "Building images (no cache)"
Invoke-Cmd "Build API" {
    docker compose build --no-cache forge-api
}
Invoke-Cmd "Build UI" {
    docker compose build --no-cache forge-ui
}

# --- Compose up - core services ---

Write-Step "Starting core services"

$env:RECREATE_DB = if ($RecreateDb) { "true" } else { "false" }
if ($RecreateDb) {
    Write-Warn "RECREATE_DB=true -- database will be wiped and reseeded"
}

# Start everything except UI — maintenance container holds the port
$coreServices = @(
    "forge",
    "forge-storage",
    "forge-backup",
    "forge-api"
)

Invoke-Cmd "docker compose up -d (core)" {
    docker compose up -d --force-recreate --remove-orphans @coreServices
}

# --- Optional: AI ---

if ($IncludeAi) {
    Write-Step "Starting AI service (Ollama)"
    Write-Warn "First run pulls gemma3:4b + all-minilm:l6-v2 - this can take several minutes"
    Invoke-Cmd "docker compose up -d (AI)" {
        docker compose --profile ai up -d forge-ai forge-ai-init
    }
} else {
    Write-Warn "Skipping AI service. Add -IncludeAi to include Ollama."
}

# --- Optional: Signing ---

if ($IncludeSigning) {
    Write-Step "Starting DocuSeal signing service"
    Invoke-Cmd "docker compose up -d (signing)" {
        docker compose --profile signing up -d forge-signing
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
    $status = docker inspect --format='{{.State.Health.Status}}' forge-api 2>$null
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
    Write-Warn "API health check timed out after $maxWait s - check logs: docker compose logs -f forge-api"
}

# --- Swap maintenance container -> real UI ---

Write-Step "Swapping maintenance page for real UI"
Invoke-Cmd "Remove maintenance container" { docker rm -f qb-maintenance 2>$null }
Invoke-Cmd "Start real UI" { docker compose up -d --force-recreate forge-ui }
Write-Ok "Real UI is live — dragon dismissed"

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
Write-Host "  Logs:    docker compose logs -f forge-api" -ForegroundColor DarkGray
Write-Host "  Stop:    docker compose stop" -ForegroundColor DarkGray
Write-Host "  DB CLI:  docker compose exec forge psql -U postgres -d forge" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  IMPORTANT: Open http://localhost:4200 and press Ctrl+Shift+R (or Cmd+Shift+R on Mac)" -ForegroundColor Yellow
Write-Host "             to hard-refresh the browser and pick up the latest UI changes." -ForegroundColor Yellow
Write-Host ""
