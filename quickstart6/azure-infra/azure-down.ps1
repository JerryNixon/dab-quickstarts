# Tear down quickstart6 Azure resources
# Usage: .\azure-down.ps1

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot
$repoRoot = (Resolve-Path "$scriptDir/..").Path
Push-Location $repoRoot

try {
    # Ensure we're logged in
    $account = az account show 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Not logged in to Azure CLI. Running az login..." -ForegroundColor Yellow
        az login
    }

    $azdAccount = azd auth login --check-status 2>&1
    if ($azdAccount -notmatch 'Logged in') {
        Write-Host "Not logged in to azd. Running azd auth login..." -ForegroundColor Yellow
        azd auth login
    }

    # Run azd down (postdown hook runs entra-teardown.ps1)
    azd down --force --purge
}
finally {
    Pop-Location
}
