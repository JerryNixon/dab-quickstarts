# Post-provision hook -- deploys content after Bicep creates all resources
# Runs automatically after `azd provision` or `azd up`.

$ErrorActionPreference = "Stop"

$resourceGroup    = $env:AZURE_RESOURCE_GROUP
$sqlServerName    = $env:AZURE_SQL_SERVER_NAME
$sqlServerFqdn    = $env:AZURE_SQL_SERVER_FQDN
$sqlDb            = $env:AZURE_SQL_DATABASE
$sqlAdminUser     = $env:AZURE_SQL_ADMIN_USER
$sqlAdminPassword = $env:AZURE_SQL_ADMIN_PASSWORD
$acrName          = $env:AZURE_ACR_NAME
$webAppName       = $env:AZURE_WEB_APP_NAME
$webUrl           = $env:AZURE_WEB_APP_URL
$sqlCmdrFqdn      = $env:AZURE_CONTAINER_APP_SQLCMDR_FQDN

$sqlConn = "Server=tcp:$sqlServerFqdn,1433;Database=$sqlDb;User Id=$sqlAdminUser;Password=$sqlAdminPassword;Encrypt=true;TrustServerCertificate=true"

Write-Host "Adding client IP to SQL firewall..." -ForegroundColor Yellow
$myIp = (Invoke-WebRequest -Uri "https://api.ipify.org" -UseBasicParsing).Content
az sql server firewall-rule create `
    --resource-group $resourceGroup `
    --server $sqlServerName `
    --name "azd-deploy-client" `
    --start-ip-address $myIp `
    --end-ip-address $myIp 2>$null | Out-Null
Write-Host "Firewall rule added ($myIp)" -ForegroundColor Green

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

Write-Host "Building ASP.NET web image with DAB CLI sidecar support..." -ForegroundColor Yellow
az acr build --registry $acrName --image web-app:latest --file web-app/Dockerfile web-app/ | Out-Null
Write-Host "Web image pushed" -ForegroundColor Green

Write-Host "Updating web container app..." -ForegroundColor Yellow
az containerapp update `
    --name $webAppName `
    --resource-group $resourceGroup `
    --image "$acrName.azurecr.io/web-app:latest" `
    --set-env-vars "MSSQL_CONNECTION_STRING=secretref:db-conn" "DataApiBuilder__UseDotNetToolRun=false" | Out-Null
Write-Host "Web updated" -ForegroundColor Green

$repoRoot = (Resolve-Path (Join-Path (Get-Location) "..")).Path
$mcpDir = Join-Path $repoRoot ".github"
$mcpFile = Join-Path $mcpDir "mcp.json"
$mcpServerName = "azure-sql-mcp"
$mcpUrl = "$webUrl/mcp"

if (-not (Test-Path $mcpDir)) {
    New-Item -ItemType Directory -Path $mcpDir -Force | Out-Null
}

if (Test-Path $mcpFile) {
    $mcpConfig = Get-Content -Path $mcpFile -Raw | ConvertFrom-Json -AsHashtable
}
else {
    $mcpConfig = @{}
}

if ($null -eq $mcpConfig) { $mcpConfig = @{} }
if (-not $mcpConfig.ContainsKey('servers') -or $null -eq $mcpConfig.servers) { $mcpConfig.servers = @{} }

$mcpConfig.servers[$mcpServerName] = @{
    type = 'http'
    url = $mcpUrl
}

$mcpConfig | ConvertTo-Json -Depth 100 | Out-File -FilePath $mcpFile -Encoding utf8 -Force
Write-Host "MCP server '$mcpServerName' configured at $mcpUrl" -ForegroundColor Green

Write-Host "`n=== Deployment Complete ===" -ForegroundColor Cyan
Write-Host "Web + DAB sidecar: $webUrl" -ForegroundColor White
Write-Host "DAB Health:        $webUrl/health" -ForegroundColor White
Write-Host "DAB Swagger:       $webUrl/swagger/" -ForegroundColor White
Write-Host "DAB GraphQL:       $webUrl/graphql/" -ForegroundColor White
Write-Host "DAB MCP:           $webUrl/mcp" -ForegroundColor White
Write-Host "SQL Commander:     https://$sqlCmdrFqdn" -ForegroundColor White
