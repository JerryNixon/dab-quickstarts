# Deploy quickstart6 to Azure
# Usage: .\azure-up.ps1

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

    # Mark entra setup as not yet run in this session
    $env:DAB_ENTRA_ALREADY_RAN = $null

    # Run azd up (preprovision hook runs entra-setup.ps1, postprovision runs post-provision.ps1)
    azd up

    # Mark entra as done so it won't re-run if script is called again
    $env:DAB_ENTRA_ALREADY_RAN = '1'
}
finally {
    Pop-Location
}
