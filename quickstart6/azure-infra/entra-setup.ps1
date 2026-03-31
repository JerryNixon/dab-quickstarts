# Entra ID setup -- creates app registration with client secret for OBO

$ErrorActionPreference = "Stop"

if ($env:DAB_ENTRA_ALREADY_RAN -eq '1') {
    Write-Host "Skipping Entra setup (already executed in this azure-up run)." -ForegroundColor Gray
    return
}

$repoRoot = (Resolve-Path "$PSScriptRoot/..").Path
$azureEnvFile = "$repoRoot/.azure-env"

$isAzd = [bool]$env:AZURE_ENV_NAME
$localRedirect = "http://localhost:5173"

# ── 0. Token management ──

$utcToken = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmm')

if (Test-Path $azureEnvFile) {
    $envData = @{}
    Get-Content $azureEnvFile | Where-Object { $_ -match '=' -and $_ -notmatch '^#' } | ForEach-Object {
        $parts = $_ -split '=', 2
        $envData[$parts[0].Trim()] = $parts[1].Trim()
    }
    $existingToken = $envData['token']
    if ($existingToken -match '^\d{12}$') {
        $token = $existingToken
        Write-Host "Using existing token: $token" -ForegroundColor Gray
    } else {
        $token = $utcToken
        Write-Host "Existing token missing/invalid; generated UTC token: $token" -ForegroundColor Yellow
    }
} else {
    $token = $utcToken
    Write-Host "Generated token: $token" -ForegroundColor Green
}

if ($isAzd) {
    azd env set AZURE_RESOURCE_TOKEN $token
    $signedInUser = az account show --query "user.name" -o tsv
    $ownerAlias = if ($signedInUser -match '@') { ($signedInUser -split '@', 2)[0] } else { $signedInUser }
    azd env set AZURE_OWNER_ALIAS $ownerAlias
}

$appName = "app-$token"

# ── 1. App registration (idempotent) ──

Write-Host "Configuring Entra ID app registration..." -ForegroundColor Yellow
$appJson = az ad app list --display-name $appName --query "[0]"
$app = $appJson | ConvertFrom-Json

if (-not $app) {
    $app = az ad app create `
        --display-name $appName `
        --sign-in-audience "AzureADMyOrg" `
        --query "{appId: appId, id: id}" | ConvertFrom-Json
    Write-Host "App registration created: $appName" -ForegroundColor Green
} else {
    Write-Host "App registration exists: $appName" -ForegroundColor Gray
}

# Reuse existing scope ID if present (avoids CannotDeleteOrUpdateEnabledEntitlement error)
$existingScopeId = az ad app show --id $app.appId --query "api.oauth2PermissionScopes[?value=='access_as_user'].id | [0]" -o tsv

# Ensure service principal exists for the app (required for permission grants)
$spExists = az ad sp show --id $app.appId --query "id" -o tsv 2>$null
if (-not $spExists) {
    az ad sp create --id $app.appId | Out-Null
}

if ($existingScopeId) {
    $scopeId = $existingScopeId
    Write-Host "Using existing scope: $scopeId" -ForegroundColor Gray
} else {
    $scopeId = [guid]::NewGuid().ToString()
}
$appPatch = @{
    spa = @{ redirectUris = @($localRedirect) }
    web = @{ redirectUris = @() }
    identifierUris = @("api://$($app.appId)")
    api = @{
        requestedAccessTokenVersion = 2
        oauth2PermissionScopes = @(
            @{
                id = $scopeId
                adminConsentDisplayName = "Access TODO API"
                adminConsentDescription = "Allows the app to access the TODO API on behalf of the signed-in user"
                userConsentDisplayName = "Access TODO API"
                userConsentDescription = "Allows the app to access the TODO API on your behalf"
                isEnabled = $true
                type = "User"
                value = "access_as_user"
            }
        )
    }
} | ConvertTo-Json -Depth 4

$appPatch | Out-File -FilePath "$repoRoot/temp-app-patch.json" -Encoding utf8
az rest --method PATCH `
    --uri "https://graph.microsoft.com/v1.0/applications/$($app.id)" `
    --headers "Content-Type=application/json" `
    --body "@$repoRoot/temp-app-patch.json" | Out-Null
Remove-Item "$repoRoot/temp-app-patch.json" -Force

# Pre-authorize the SPA (no consent prompt)
$preAuthConfig = @{
    api = @{
        preAuthorizedApplications = @(
            @{
                appId = $app.appId
                delegatedPermissionIds = @($scopeId)
            }
        )
    }
} | ConvertTo-Json -Depth 4

$preAuthConfig | Out-File -FilePath "$repoRoot/temp-preauth.json" -Encoding utf8
az rest --method PATCH `
    --uri "https://graph.microsoft.com/v1.0/applications/$($app.id)" `
    --headers "Content-Type=application/json" `
    --body "@$repoRoot/temp-preauth.json" | Out-Null
Remove-Item "$repoRoot/temp-preauth.json" -Force
Write-Host "API scope exposed: api://$($app.appId)/access_as_user" -ForegroundColor Green

# ── 2. Add Azure SQL Database delegated permission (user_impersonation) ──

Write-Host "Adding Azure SQL Database permission..." -ForegroundColor Yellow
# Azure SQL Database well-known resource app
$sqlResourceAppId = "022907d3-0f1b-48f7-badc-1ba6abab6d66"

# Look up the user_impersonation scope ID
$sqlSp = az ad sp show --id $sqlResourceAppId --query "oauth2PermissionScopes[?value=='user_impersonation'].id | [0]" -o tsv 2>$null
if (-not $sqlSp) {
    Write-Host "Azure SQL Database service principal not found in tenant. Creating..." -ForegroundColor Yellow
    az ad sp create --id $sqlResourceAppId | Out-Null
    $sqlSp = az ad sp show --id $sqlResourceAppId --query "oauth2PermissionScopes[?value=='user_impersonation'].id | [0]" -o tsv
}

# Add the delegated permission
az ad app permission add --id $app.appId --api $sqlResourceAppId --api-permissions "$sqlSp=Scope" | Out-Null

# Grant admin consent
az ad app permission grant --id $app.appId --api $sqlResourceAppId --scope "user_impersonation" | Out-Null
Write-Host "Azure SQL Database permission granted" -ForegroundColor Green

# ── 3. Create client secret for OBO token exchange ──

Write-Host "Creating client secret for OBO..." -ForegroundColor Yellow
$existingSecretHint = $null
if (Test-Path $azureEnvFile) {
    $envLines = Get-Content $azureEnvFile
    $existingSecretHint = ($envLines | Where-Object { $_ -match '^client-secret=' }) -replace '^client-secret=', ''
}

if ($existingSecretHint -and $existingSecretHint.Length -gt 5) {
    Write-Host "Client secret already exists in .azure-env — reusing" -ForegroundColor Gray
    $clientSecret = $existingSecretHint
} else {
    $secretJson = az ad app credential reset --id $app.appId --display-name "obo-secret" --years 1 --query "{password: password}" | ConvertFrom-Json
    $clientSecret = $secretJson.password
    Write-Host "Client secret created" -ForegroundColor Green
}

$tenantId = (az account show --query tenantId -o tsv)

# Store values for azd if running under azd
if ($isAzd) {
    azd env set AZURE_CLIENT_ID $app.appId
    azd env set AZURE_TENANT_ID $tenantId
    azd env set AZURE_OBO_CLIENT_SECRET $clientSecret
    Write-Host "Stored CLIENT_ID + TENANT_ID + OBO_CLIENT_SECRET in azd env" -ForegroundColor Green
}

# ── 4. Update dab-config.json with real auth values ──

Write-Host "Updating DAB config with EntraId auth..." -ForegroundColor Yellow
Push-Location "$repoRoot/data-api"
dab configure `
    --runtime.host.authentication.provider "EntraId" `
    --runtime.host.authentication.jwt.audience "api://$($app.appId)" `
    --runtime.host.authentication.jwt.issuer "https://login.microsoftonline.com/$tenantId/v2.0"
Pop-Location
Write-Host "DAB config updated" -ForegroundColor Green

# ── 5. Update config.js ──

$configContent = @"
const CONFIG = {
    clientId: '$($app.appId)',
    tenantId: '$tenantId',
    apiUrlLocal: 'http://localhost:5000',
    apiUrlAzure: '__API_URL_AZURE__'
};
"@
$configContent | Out-File -FilePath "$repoRoot/web-app/config.js" -Encoding utf8 -Force
Write-Host "config.js updated" -ForegroundColor Green

# ── 6. Write .azure-env ──

@"
# Auto-generated. Do not edit. Delete to reset.
token=$token
resource-group=rg-quickstart6-$token
sql-server=sql-server-$token
sql-database=sql-db
container-registry=acr$token
environment=environment-$token
data-api=data-api-$token
sql-commander=sql-commander-$token
service-plan=service-plan-$token
web-app=web-app-$token
app-registration=$appName
client-secret=$clientSecret
"@ | Out-File -FilePath $azureEnvFile -Encoding utf8 -Force
Write-Host "Environment written to .azure-env" -ForegroundColor Green

# ── 7. Verify config files were updated ──

$failed = @()
$configJsContent = Get-Content "$repoRoot/web-app/config.js" -Raw
if ($configJsContent -match '__CLIENT_ID__|__TENANT_ID__') {
    $failed += "web-app/config.js still contains placeholders"
}
$dabConfigContent = Get-Content "$repoRoot/data-api/dab-config.json" -Raw
if ($dabConfigContent -match '__AUDIENCE__|__ISSUER__') {
    $failed += "data-api/dab-config.json still contains placeholders"
}
if ($failed.Count -gt 0) {
    foreach ($f in $failed) { Write-Host "x $f" -ForegroundColor Red }
    exit 1
}
Write-Host "v All config files verified" -ForegroundColor Green
