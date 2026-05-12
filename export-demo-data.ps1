# Orchestrates the disposable export stack (Windows / PowerShell variant).
#
# Stands up a throwaway Postgres + API from docker-compose.export.yml, the API
# seeds itself + dumps business entities to .\forge-ui\public\demo-data\
# and exits. This script then tears the stack down (including volumes) so
# nothing lingers. The dev stack is untouched.

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$OutDir = "forge-ui\public\demo-data"
$ComposeFile = "docker-compose.export.yml"

Write-Host "[export] Cleaning previous demo-data output..."
if (Test-Path $OutDir) {
    Get-ChildItem -Path $OutDir -File -Recurse |
        Where-Object { $_.Name -ne '.gitkeep' } |
        Remove-Item -Force
}

try {
    Write-Host "[export] Building + running export stack (this can take a few minutes on first run)..."
    docker compose -p forge-export -f $ComposeFile up --build --abort-on-container-exit --exit-code-from forge-api-export
    $ExitCode = $LASTEXITCODE

    if ($ExitCode -ne 0) {
        Write-Host "[export] FAILED: api-export exited with code $ExitCode" -ForegroundColor Red
        exit $ExitCode
    }

    $FileCount = (Get-ChildItem -Path $OutDir -File -Filter '*.json' | Measure-Object).Count
    Write-Host "[export] Done — $FileCount JSON files written to $OutDir\" -ForegroundColor Green
}
finally {
    Write-Host "[export] Tearing down export stack..."
    docker compose -p forge-export -f $ComposeFile down -v --remove-orphans 2>&1 | Out-Null
}
