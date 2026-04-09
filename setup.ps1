#!/usr/bin/env pwsh
# setup.ps1 - First-time setup for QB Engineer
#
# Checks all prerequisites, creates .env, builds and starts the full stack.
# Run from the repo root after cloning.
#
# Usage:
#   .\setup.ps1                  # Core stack only — clean database, no demo data
#   .\setup.ps1 -Seeded          # Seed with demo data (users, jobs, customers, etc.)
#   .\setup.ps1 -Fresh           # Wipe existing database and start over
#   .\setup.ps1 -Fresh -Seeded   # Wipe database and reseed with demo data
#   .\setup.ps1 -IncludeAi       # Also start Ollama AI assistant
#   .\setup.ps1 -IncludeTts      # Also start Coqui TTS for training video narration
#   .\setup.ps1 -IncludeSigning  # Also start DocuSeal e-signature service
#   .\setup.ps1 -IncludeAll      # All optional profiles

param(
    [switch]$Seeded,
    [switch]$Fresh,
    [switch]$IncludeAi,
    [switch]$IncludeTts,
    [switch]$IncludeSigning,
    [switch]$IncludeAll
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($IncludeAll) {
    $IncludeAi = $true
    $IncludeTts = $true
    $IncludeSigning = $true
}

# ─────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────

function Write-Banner {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║        QB Engineer — First-Time Setup    ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step([string]$msg) {
    Write-Host "`n==> $msg" -ForegroundColor Cyan
}

function Write-Ok([string]$msg) {
    Write-Host "    [OK] $msg" -ForegroundColor Green
}

function Write-Warn([string]$msg) {
    Write-Host "    [!!] $msg" -ForegroundColor Yellow
}

function Write-Fail([string]$msg) {
    Write-Host "    [X]  $msg" -ForegroundColor Red
}

function Write-Instruction([string]$msg) {
    Write-Host "         $msg" -ForegroundColor White
}

function Invoke-Cmd([string]$desc, [scriptblock]$cmd) {
    Write-Host "    $desc..." -NoNewline
    try {
        & $cmd 2>&1 | Out-Null
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "exit code $LASTEXITCODE" }
        Write-Host " done" -ForegroundColor Green
    } catch {
        Write-Host " FAILED" -ForegroundColor Red
        throw
    }
}

function Stop-WithPrerequisiteError([string]$tool, [string[]]$instructions) {
    Write-Host ""
    Write-Fail "Missing prerequisite: $tool"
    Write-Host ""
    foreach ($line in $instructions) {
        Write-Instruction $line
    }
    Write-Host ""
    Write-Instruction "After installing, close this terminal and re-run:"
    Write-Instruction "  .\setup.ps1"
    Write-Host ""
    exit 1
}

# ─────────────────────────────────────────────────────────────
# Banner
# ─────────────────────────────────────────────────────────────

Write-Banner

# ─────────────────────────────────────────────────────────────
# 1. Check prerequisites
# ─────────────────────────────────────────────────────────────

Write-Step "Checking prerequisites"

$isLinux = $IsLinux -eq $true
$isMac   = $IsMacOS -eq $true
$isWin   = (-not $isLinux) -and (-not $isMac)

# --- Git ---

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $instructions = if ($isWin) {
        @(
            "Git is not installed.",
            "",
            "Download and install from: https://git-scm.com/download/win",
            "  - Use the default options during installation.",
            "  - Make sure 'Git from the command line' is checked."
        )
    } elseif ($isMac) {
        @(
            "Git is not installed.",
            "",
            "Install via Homebrew:  brew install git",
            "Or install Xcode CLI:  xcode-select --install"
        )
    } else {
        @(
            "Git is not installed.",
            "",
            "Install via your package manager:",
            "  Ubuntu/Debian:  sudo apt install git",
            "  Fedora/RHEL:    sudo dnf install git",
            "  Arch:           sudo pacman -S git"
        )
    }
    Stop-WithPrerequisiteError "Git" $instructions
}
Write-Ok "Git $(git --version 2>$null)"

# --- Docker ---

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    $instructions = if ($isWin) {
        @(
            "Docker is not installed.",
            "",
            "Download Docker Desktop from: https://www.docker.com/products/docker-desktop/",
            "  1. Run the installer",
            "  2. Restart your computer when prompted",
            "  3. Launch Docker Desktop and wait for it to finish starting"
        )
    } elseif ($isMac) {
        @(
            "Docker is not installed.",
            "",
            "Download Docker Desktop from: https://www.docker.com/products/docker-desktop/",
            "  Or install via Homebrew:  brew install --cask docker",
            "  Then launch Docker Desktop and wait for it to finish starting."
        )
    } else {
        @(
            "Docker is not installed.",
            "",
            "Install Docker Engine:",
            "  https://docs.docker.com/engine/install/",
            "",
            "Quick install (Ubuntu/Debian):",
            "  curl -fsSL https://get.docker.com | sudo sh",
            "",
            "Then add your user to the docker group:",
            "  sudo usermod -aG docker `$USER",
            "  Log out and back in for this to take effect."
        )
    }
    Stop-WithPrerequisiteError "Docker" $instructions
}

# --- Docker daemon running? ---

docker info *>$null
if ($LASTEXITCODE -ne 0) {
    if ($isLinux) {
        # Check if it's a permissions issue vs daemon not running
        $errOutput = docker info 2>&1 | Out-String
        if ($errOutput -match "permission denied") {
            Stop-WithPrerequisiteError "Docker (permissions)" @(
                "Docker is installed but your user does not have permission to use it.",
                "",
                "Fix: add your user to the 'docker' group:",
                "  sudo usermod -aG docker `$USER",
                "",
                "Then log out and back in (or run: newgrp docker)."
            )
        }
    }

    $instructions = if ($isWin -or $isMac) {
        @(
            "Docker is installed but the daemon is not running.",
            "",
            "Open Docker Desktop and wait for it to show 'Docker Desktop is running'.",
            "The whale icon in your system tray/menu bar should stop animating."
        )
    } else {
        @(
            "Docker is installed but the daemon is not running.",
            "",
            "Start the Docker service:",
            "  sudo systemctl start docker",
            "",
            "To start Docker automatically on boot:",
            "  sudo systemctl enable docker"
        )
    }
    Stop-WithPrerequisiteError "Docker (daemon)" $instructions
}
Write-Ok "Docker $(docker --version 2>$null)"

# --- Docker Compose ---

$composeVersion = docker compose version 2>$null
if ($LASTEXITCODE -ne 0) {
    Stop-WithPrerequisiteError "Docker Compose" @(
        "Docker Compose v2 is required but not found.",
        "",
        "Docker Desktop includes Compose v2 by default.",
        "If using Docker Engine on Linux, install the compose plugin:",
        "  sudo apt install docker-compose-plugin",
        "",
        "Verify with: docker compose version"
    )
}
Write-Ok "Docker Compose ($composeVersion)"

# --- Disk space check (rough — warn below 10 GB free) ---

try {
    if ($isWin) {
        $drive = (Get-Location).Drive
        $freeGB = [math]::Round($drive.Free / 1GB, 1)
    } else {
        $dfOutput = df -BG --output=avail . 2>$null | Select-Object -Last 1
        $freeGB = [int]($dfOutput -replace '[^0-9]', '')
    }
    if ($freeGB -lt 10) {
        Write-Warn "Only ${freeGB} GB free disk space. Recommended: 20+ GB."
        Write-Warn "Docker images + database + file storage can grow significantly."
    } else {
        Write-Ok "${freeGB} GB free disk space"
    }
} catch {
    Write-Warn "Could not check disk space (non-fatal)"
}

# --- Port availability check ---

$portsToCheck = @(
    @{ Port = 4200;  Name = "UI" },
    @{ Port = 5000;  Name = "API" },
    @{ Port = 5432;  Name = "PostgreSQL" },
    @{ Port = 9000;  Name = "MinIO API" },
    @{ Port = 9001;  Name = "MinIO Console" }
)

$portConflicts = @()
foreach ($p in $portsToCheck) {
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $p.Port)
        $listener.Start()
        $listener.Stop()
    } catch {
        $portConflicts += "$($p.Name) (port $($p.Port))"
    }
}

if ($portConflicts.Count -gt 0) {
    Write-Warn "The following ports are already in use:"
    foreach ($conflict in $portConflicts) {
        Write-Warn "  - $conflict"
    }
    Write-Warn "You can change ports in .env after setup, or stop the conflicting services."
    Write-Host ""
    $continue = Read-Host "    Continue anyway? (y/N)"
    if ($continue -ne "y" -and $continue -ne "Y") {
        Write-Host "    Setup cancelled." -ForegroundColor DarkGray
        exit 1
    }
} else {
    Write-Ok "All required ports are available (4200, 5000, 5432, 9000, 9001)"
}

Write-Host ""
Write-Ok "All prerequisites met!"

# ─────────────────────────────────────────────────────────────
# 2. Working directory check
# ─────────────────────────────────────────────────────────────

Write-Step "Verifying project files"

if (-not (Test-Path "docker-compose.yml")) {
    Write-Fail "docker-compose.yml not found."
    Write-Instruction "Run this script from the repo root:"
    Write-Instruction "  cd qb-engineer-wrapper"
    Write-Instruction "  .\setup.ps1"
    exit 1
}

if (-not (Test-Path ".env.example")) {
    Write-Fail ".env.example not found — the repo may be incomplete."
    Write-Instruction "Try a fresh clone:"
    Write-Instruction "  git clone https://github.com/danielhokanson/qb-engineer-wrapper.git"
    exit 1
}

Write-Ok "Project files found"

# ─────────────────────────────────────────────────────────────
# 3. Create .env from template
# ─────────────────────────────────────────────────────────────

Write-Step "Configuring environment"

if (Test-Path ".env") {
    Write-Ok ".env already exists — skipping creation"
    Write-Warn "To regenerate, delete .env and re-run setup.ps1"
} else {
    # Copy template
    Copy-Item ".env.example" ".env"
    Write-Ok "Created .env from .env.example"

    # Generate a random JWT key (48 alphanumeric chars)
    $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    $jwtKey = -join ((1..48) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })

    # Replace the dev placeholder JWT key with the generated one
    $envContent = Get-Content ".env" -Raw
    $envContent = $envContent -replace 'JWT_KEY=dev-secret-key-change-in-production-min-32-chars!!', "JWT_KEY=$jwtKey"

    # Default to clean install (no demo data) unless -Seeded flag is passed
    $seedValue = if ($Seeded) { "true" } else { "false" }
    $envContent = $envContent -replace 'SEED_DEMO_DATA=true', "SEED_DEMO_DATA=$seedValue"

    Set-Content ".env" -Value $envContent -NoNewline
    Write-Ok "Generated random JWT signing key"
    if ($Seeded) {
        Write-Ok "Demo data will be seeded (users, jobs, customers, etc.)"
    } else {
        Write-Ok "Clean install — no demo data (setup wizard creates your admin account)"
    }
}

# Prompt for seed user password when seeding demo data
if ($Seeded) {
    Write-Step "Demo data user password"
    Write-Host ""
    Write-Host "    Demo data includes 9 test users (admin@qbengineer.local, etc.)"
    Write-Host "    You must set a temporary password for these accounts."
    Write-Host "    Requirements: 8+ chars, uppercase, lowercase, digit, special char"
    Write-Host ""
    do {
        $seedPassword = Read-Host "    Enter password for demo users"
        if ($seedPassword.Length -lt 8) {
            Write-Warn "Password must be at least 8 characters"
        } elseif ($seedPassword -cnotmatch '[A-Z]') {
            Write-Warn "Password must contain an uppercase letter"
        } elseif ($seedPassword -cnotmatch '[a-z]') {
            Write-Warn "Password must contain a lowercase letter"
        } elseif ($seedPassword -notmatch '[0-9]') {
            Write-Warn "Password must contain a digit"
        } elseif ($seedPassword -notmatch '[^A-Za-z0-9]') {
            Write-Warn "Password must contain a special character"
        } else {
            break
        }
    } while ($true)

    $envContent = Get-Content ".env" -Raw
    $envContent = $envContent -replace 'SEED_USER_PASSWORD=.*', "SEED_USER_PASSWORD=$seedPassword"
    Set-Content ".env" -Value $envContent -NoNewline
    Write-Ok "Seed user password set"
}

# Apply -Fresh and -Seeded flags (works on both new and existing .env)
if ($Fresh) {
    $envContent = Get-Content ".env" -Raw
    $envContent = $envContent -replace 'RECREATE_DB=\w+', 'RECREATE_DB=true'
    if ($Seeded) {
        $envContent = $envContent -replace 'SEED_DEMO_DATA=\w+', 'SEED_DEMO_DATA=true'
    }
    Set-Content ".env" -Value $envContent -NoNewline
    Write-Warn "-Fresh: database will be wiped and recreated on next start"
}

# ─────────────────────────────────────────────────────────────
# 4. Write version.json
# ─────────────────────────────────────────────────────────────

Write-Step "Writing build version"

$buildVersion = git rev-list --count HEAD 2>$null
$buildSha     = git rev-parse --short HEAD 2>$null

if ($buildVersion -and $buildSha) {
    $env:BUILD_VERSION = $buildVersion
    $env:BUILD_SHA     = $buildSha
    $versionJson = '{"version":"' + $buildVersion + '","sha":"' + $buildSha + '"}'
    $versionPath = Join-Path (Get-Location) "qb-engineer-ui\public\assets\version.json"
    if (Test-Path (Split-Path $versionPath)) {
        Set-Content -Path $versionPath -Value $versionJson -Encoding UTF8 -NoNewline
        Write-Ok "Build $buildVersion ($buildSha)"
    } else {
        Write-Warn "UI public/assets directory not found — skipping version.json"
    }
} else {
    Write-Warn "Could not determine git version — using defaults"
}

# ─────────────────────────────────────────────────────────────
# 5. Build and start Docker services
# ─────────────────────────────────────────────────────────────

Write-Step "Building Docker images (this may take several minutes on first run)"

Invoke-Cmd "Building API image" {
    docker compose build qb-engineer-api
}

Invoke-Cmd "Building UI image" {
    docker compose build qb-engineer-ui
}

Write-Step "Starting core services (db, storage, backup, api, ui)"

$coreServices = @(
    "qb-engineer-db",
    "qb-engineer-storage",
    "qb-engineer-backup",
    "qb-engineer-api",
    "qb-engineer-ui"
)

Invoke-Cmd "docker compose up -d (core)" {
    docker compose up -d --remove-orphans @coreServices
}

# --- Optional: AI ---

if ($IncludeAi) {
    Write-Step "Starting AI service (Ollama)"
    Write-Warn "First run downloads AI models (~4 GB) — this can take several minutes"
    Invoke-Cmd "docker compose --profile ai up -d" {
        docker compose --profile ai up -d qb-engineer-ai qb-engineer-ai-init
    }
}

# --- Optional: TTS ---

if ($IncludeTts) {
    Write-Step "Starting TTS service (Coqui)"
    Write-Warn "First run downloads the VCTK voice model (~500 MB)"
    Invoke-Cmd "docker compose --profile tts up -d" {
        docker compose --profile tts up -d qb-engineer-tts
    }
}

# --- Optional: Signing ---

if ($IncludeSigning) {
    Write-Step "Starting DocuSeal signing service"
    Invoke-Cmd "docker compose --profile signing up -d" {
        docker compose --profile signing up -d qb-engineer-signing
    }
}

# ─────────────────────────────────────────────────────────────
# 6. Wait for API health
# ─────────────────────────────────────────────────────────────

Write-Step "Waiting for API to become healthy (first start includes database migration)"

$maxWait = 120
$elapsed = 0
$healthy = $false

while ($elapsed -lt $maxWait) {
    $status = docker inspect --format='{{.State.Health.Status}}' qb-engineer-api 2>$null
    if ($status -eq "healthy") {
        $healthy = $true
        break
    }
    $pct = [math]::Round(($elapsed / $maxWait) * 100)
    Write-Host "`r    Waiting... $status ($elapsed s / $maxWait s) [$pct%]" -NoNewline -ForegroundColor DarkGray
    Start-Sleep 5
    $elapsed += 5
}
Write-Host ""

if ($healthy) {
    Write-Ok "API is healthy and accepting requests"
} else {
    Write-Warn "API health check timed out after $maxWait s"
    Write-Warn "This is normal on very first start while migrations run."
    Write-Warn "Check progress with: docker compose logs -f qb-engineer-api"
}

# Reset RECREATE_DB so the next restart doesn't wipe the database again
if ($Fresh) {
    $envContent = Get-Content ".env" -Raw
    $envContent = $envContent -replace 'RECREATE_DB=true', 'RECREATE_DB=false'
    Set-Content ".env" -Value $envContent -NoNewline
    Write-Ok "Reset RECREATE_DB=false (database has been wiped, won't repeat on next start)"
}

# ─────────────────────────────────────────────────────────────
# 7. Final status
# ─────────────────────────────────────────────────────────────

Write-Step "Container status"
docker compose ps

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║          Setup complete!                 ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Open in your browser:" -ForegroundColor White
Write-Host ""
Write-Host "    http://localhost:4200" -ForegroundColor Cyan
Write-Host ""
Write-Host "  A setup wizard will guide you through creating" -ForegroundColor White
Write-Host "  your admin account and company profile." -ForegroundColor White
Write-Host ""
Write-Host "  ─── Service URLs ───" -ForegroundColor DarkGray
Write-Host "  UI:           http://localhost:4200" -ForegroundColor White
Write-Host "  API:          http://localhost:5000" -ForegroundColor White
Write-Host "  API Health:   http://localhost:5000/api/v1/health" -ForegroundColor White
Write-Host "  MinIO:        http://localhost:9001  (minioadmin / minioadmin)" -ForegroundColor White
if ($IncludeAi)      { Write-Host "  Ollama:       http://localhost:11434" -ForegroundColor White }
if ($IncludeTts)     { Write-Host "  Coqui TTS:    http://localhost:5002" -ForegroundColor White }
if ($IncludeSigning) { Write-Host "  DocuSeal:     http://localhost:3000" -ForegroundColor White }
Write-Host ""
Write-Host "  ─── Useful commands ───" -ForegroundColor DarkGray
Write-Host "  View logs:    docker compose logs -f qb-engineer-api" -ForegroundColor DarkGray
Write-Host "  Stop all:     docker compose stop" -ForegroundColor DarkGray
Write-Host "  Start all:    docker compose up -d" -ForegroundColor DarkGray
Write-Host "  Update:       .\refresh.ps1" -ForegroundColor DarkGray
Write-Host "  DB shell:     docker compose exec qb-engineer-db psql -U postgres -d qb_engineer" -ForegroundColor DarkGray
Write-Host ""
