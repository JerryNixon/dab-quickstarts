# Tear down this quickstart's Azure resources
# Usage: .\azure-down.ps1 [-NoPurge]
# By default, resources are purged (soft-delete removed). Pass -NoPurge to keep them recoverable.

Param(
    [switch]$NoPurge
)

$ErrorActionPreference = "Stop"

Push-Location (Join-Path $PSScriptRoot "..")
try {
    az account show --only-show-errors 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Logging in to Azure CLI..." -ForegroundColor Yellow
        az login
        if ($LASTEXITCODE -ne 0) { throw "az login failed" }
    }

    if ($NoPurge) {
        azd down --force
    }
    else {
        azd down --force --purge
    }
    if ($LASTEXITCODE -ne 0) { throw "azd down failed" }

    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
    $mcpFile = Join-Path $repoRoot ".github/mcp.json"
    $mcpServerName = "azure-sql-mcp-qs4"

    if (Test-Path $mcpFile) {
        $mcpConfig = Get-Content $mcpFile -Raw | ConvertFrom-Json -AsHashtable
        if ($mcpConfig -and $mcpConfig.ContainsKey('servers') -and $mcpConfig.servers -and $mcpConfig.servers.ContainsKey($mcpServerName)) {
            $mcpConfig.servers.Remove($mcpServerName) | Out-Null
            $mcpConfig | ConvertTo-Json -Depth 100 | Out-File -FilePath $mcpFile -Encoding utf8 -Force
            Write-Host "Removed '$mcpServerName' from .github/mcp.json" -ForegroundColor Green
        }
    }
}
finally {
    Pop-Location
}
