# Post-provision hook -- deploys content after Bicep creates all resources
# Runs automatically after `azd provision` or `azd up`

$ErrorActionPreference = "Stop"

# All variables come from Bicep outputs (set by azd as env vars)
$resourceGroup     = $env:AZURE_RESOURCE_GROUP
$sqlServerName     = $env:AZURE_SQL_SERVER_NAME
$sqlServerFqdn     = $env:AZURE_SQL_SERVER_FQDN
$sqlDb             = $env:AZURE_SQL_DATABASE
$sqlAdminUser      = $env:AZURE_SQL_ADMIN_USER
$sqlAdminPassword  = $env:AZURE_SQL_ADMIN_PASSWORD
$acrName           = $env:AZURE_ACR_NAME
$webAppName        = $env:AZURE_WEB_APP_NAME
$webUrl            = $env:AZURE_WEB_APP_URL
$webFqdn           = $env:AZURE_WEB_APP_FQDN
$dabAppName        = $env:AZURE_CONTAINER_APP_API_NAME
$dabFqdn           = $env:AZURE_CONTAINER_APP_API_FQDN
$inspectorName     = $env:AZURE_MCP_INSPECTOR_NAME
$inspectorFqdn     = $env:AZURE_MCP_INSPECTOR_FQDN

$sqlConn = "Server=tcp:$sqlServerFqdn,1433;Database=$sqlDb;User Id=$sqlAdminUser;Password=$sqlAdminPassword;Encrypt=true;TrustServerCertificate=true"

# ── 1. Open SQL firewall for local machine ──

Write-Host "Adding client IP to SQL firewall..." -ForegroundColor Yellow
$myIp = (Invoke-WebRequest -Uri "https://api.ipify.org" -UseBasicParsing).Content
az sql server firewall-rule create `
    --resource-group $resourceGroup `
    --server $sqlServerName `
    --name "azd-deploy-client" `
    --start-ip-address $myIp `
    --end-ip-address $myIp 2>$null | Out-Null
Write-Host "Firewall rule added ($myIp)" -ForegroundColor Green

# ── 2. Deploy database schema (dacpac) ──

Write-Host "Building database project..." -ForegroundColor Yellow
dotnet build database/database.sqlproj -c Release
if ($LASTEXITCODE -ne 0) { throw "Database build failed" }
Write-Host "Database built" -ForegroundColor Green

Write-Host "Deploying schema with sqlpackage..." -ForegroundColor Yellow
sqlpackage /Action:Publish `
    /SourceFile:database/bin/Release/database.dacpac `
    /TargetConnectionString:"$sqlConn" `
    /p:BlockOnPossibleDataLoss=false
if ($LASTEXITCODE -ne 0) { throw "Schema deployment failed" }
Write-Host "Schema deployed" -ForegroundColor Green

# ── 3. Build and push DAB image to ACR ──

Write-Host "Preparing DAB config with Azure CORS..." -ForegroundColor Yellow
$apiDeployDir = "api-deploy-temp"
Copy-Item -Path "data-api" -Destination $apiDeployDir -Recurse -Force
$webOrigin = "https://$webFqdn"
$dabConfig = Get-Content -Path "$apiDeployDir/dab-config.json" -Raw
$dabConfig = $dabConfig.Replace("__WEB_URL_AZURE__", $webOrigin)
$dabConfig | Out-File -FilePath "$apiDeployDir/dab-config.json" -Encoding utf8 -Force
Write-Host "CORS origin set to $webOrigin" -ForegroundColor Green

Write-Host "Building DAB image in ACR..." -ForegroundColor Yellow
az acr build --registry $acrName --image dab-api:latest --file "$apiDeployDir/Dockerfile" $apiDeployDir/ | Out-Null
Remove-Item $apiDeployDir -Recurse -Force
Write-Host "Image pushed" -ForegroundColor Green

# ── 4. Update DAB container app with custom image ──

Write-Host "Updating DAB container app..." -ForegroundColor Yellow
az containerapp update `
    --name $dabAppName `
    --resource-group $resourceGroup `
    --image "$acrName.azurecr.io/dab-api:latest" | Out-Null
Write-Host "DAB updated" -ForegroundColor Green

# ── 5. Generate config.js and build/push web image ──

Write-Host "Deploying web files..." -ForegroundColor Yellow
$apiUrlAzure = "https://$dabFqdn"

$configContent = @"
const CONFIG = {
    apiUrlLocal: 'http://localhost:5000',
    apiUrlAzure: '$apiUrlAzure'
};
"@

# Write config to temp deploy folder
$deployDir = "web-deploy-temp"
Copy-Item -Path "web-app" -Destination $deployDir -Recurse -Force
$configContent | Out-File -FilePath "$deployDir/config.js" -Encoding utf8 -Force

# Build and push web image
az acr build --registry $acrName --image web-app:latest --file "$deployDir/Dockerfile" $deployDir/ | Out-Null
Remove-Item $deployDir -Recurse -Force
Write-Host "Web image pushed" -ForegroundColor Green

# ── 6. Update web container app with custom image ──

Write-Host "Updating web container app..." -ForegroundColor Yellow
az containerapp update `
    --name $webAppName `
    --resource-group $resourceGroup `
    --image "$acrName.azurecr.io/web-app:latest" | Out-Null
Write-Host "Web updated" -ForegroundColor Green

# ── 7. Build and push MCP Inspector image to ACR ──

Write-Host "Building MCP Inspector image in ACR..." -ForegroundColor Yellow
az acr build --registry $acrName --image mcp-inspector:latest --file mcp-inspector/Dockerfile mcp-inspector/ | Out-Null
Write-Host "Inspector image pushed" -ForegroundColor Green

# ── 8. Update MCP Inspector container app with custom image ──

Write-Host "Updating MCP Inspector container app..." -ForegroundColor Yellow
az containerapp update `
    --name $inspectorName `
    --resource-group $resourceGroup `
    --image "$acrName.azurecr.io/mcp-inspector:latest" | Out-Null
Write-Host "Inspector updated" -ForegroundColor Green

# ── 9. Update local config.js for dev ──

$configContent | Out-File -FilePath "web-app/config.js" -Encoding utf8 -Force
Write-Host "Local config.js updated" -ForegroundColor Green

# ── 10. Upsert workspace MCP server entry (.github/mcp.json) ──

$repoRoot = (Resolve-Path (Join-Path (Get-Location) "..")).Path
$mcpDir = Join-Path $repoRoot ".github"
$mcpFile = Join-Path $mcpDir "mcp.json"
$mcpServerName = "azure-sql-mcp-qs1"
$mcpUrl = "$apiUrlAzure/mcp"

if (-not (Test-Path $mcpDir)) {
    New-Item -ItemType Directory -Path $mcpDir -Force | Out-Null
}

if (Test-Path $mcpFile) {
    $mcpConfig = Get-Content -Path $mcpFile -Raw | ConvertFrom-Json -AsHashtable
}
else {
    $mcpConfig = @{}
}

if ($null -eq $mcpConfig) {
    $mcpConfig = @{}
}

if (-not $mcpConfig.ContainsKey('servers') -or $null -eq $mcpConfig.servers) {
    $mcpConfig.servers = @{}
}

$mcpConfig.servers[$mcpServerName] = @{
    type = 'http'
    url = $mcpUrl
}

$mcpConfig | ConvertTo-Json -Depth 100 | Out-File -FilePath $mcpFile -Encoding utf8 -Force
Write-Host "MCP server '$mcpServerName' configured at $mcpUrl" -ForegroundColor Green

# ── Summary ──

Write-Host "`n=== Deployment Complete ===" -ForegroundColor Cyan
Write-Host "Web:           $webUrl" -ForegroundColor White
Write-Host "API:           $apiUrlAzure" -ForegroundColor White
Write-Host "SQL Commander: https://$($env:AZURE_CONTAINER_APP_SQLCMDR_FQDN)" -ForegroundColor White
Write-Host "MCP Inspector: https://$inspectorFqdn" -ForegroundColor White
