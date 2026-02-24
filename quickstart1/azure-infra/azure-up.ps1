# Provision and deploy this quickstart to Azure
# Usage: .\azure-up.ps1 [-SkipLogin]

Param(
    [switch]$SkipLogin
)

$ErrorActionPreference = "Stop"

Push-Location (Join-Path $PSScriptRoot "..")
try {
    $token = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmm')

    if (-not $SkipLogin) {
        az account show --only-show-errors 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Logging in to Azure CLI..." -ForegroundColor Yellow
            az login
            if ($LASTEXITCODE -ne 0) { throw "az login failed" }
        }

        azd auth login
        if ($LASTEXITCODE -ne 0) { throw "azd auth login failed" }
    }

    $signedInUser = (az account show --query user.name -o tsv).Trim()
    if ([string]::IsNullOrWhiteSpace($signedInUser)) {
        throw "Unable to determine signed-in Azure user for owner tag"
    }

    $ownerAlias = if ($signedInUser.Contains('@')) {
        $signedInUser.Split('@')[0]
    }
    else {
        $signedInUser
    }

    Write-Host "Setting AZURE_RESOURCE_TOKEN to $token" -ForegroundColor Yellow
    azd env set AZURE_RESOURCE_TOKEN $token
    if ($LASTEXITCODE -ne 0) { throw "failed to set AZURE_RESOURCE_TOKEN" }

    Write-Host "Setting AZURE_OWNER_ALIAS to $ownerAlias" -ForegroundColor Yellow
    azd env set AZURE_OWNER_ALIAS $ownerAlias
    if ($LASTEXITCODE -ne 0) { throw "failed to set AZURE_OWNER_ALIAS" }

    azd up
    if ($LASTEXITCODE -ne 0) { throw "azd up failed" }
}
finally {
    Pop-Location
}
