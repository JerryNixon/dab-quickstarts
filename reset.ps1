# Reset all quickstarts to "ready to be a demo" state.
# Removes per-run artifacts and restores placeholder config values.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "[reset] $Message" -ForegroundColor Cyan
}

function Remove-IfExists {
    param([string]$Path)
    if (Test-Path $Path) {
        Remove-Item -Path $Path -Recurse -Force
        Write-Host "  removed: $Path" -ForegroundColor DarkGray
    }
}

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $repoRoot

Write-Step "Resetting quickstarts under $repoRoot"

$quickstarts = Get-ChildItem -Path $repoRoot -Directory | Where-Object { $_.Name -match '^quickstart\d+$' } | Sort-Object Name

if (-not $quickstarts) {
    throw 'No quickstart folders found.'
}

foreach ($qs in $quickstarts) {
    $qsRoot = $qs.FullName
    $qsName = $qs.Name
    Write-Step "Processing $qsName"

    # Runtime state directories/files created by azd and setup scripts
    Remove-IfExists (Join-Path $qsRoot '.azure')
    Remove-IfExists (Join-Path $qsRoot '.azure-env')

    # Common temporary deployment artifacts
    Remove-IfExists (Join-Path $qsRoot 'api-deploy-temp')
    Remove-IfExists (Join-Path $qsRoot 'web-deploy-temp')
    Remove-IfExists (Join-Path $qsRoot 'web-deploy.zip')

    # Common temporary JSON patch files
    Remove-IfExists (Join-Path $qsRoot 'temp-app-patch.json')
    Remove-IfExists (Join-Path $qsRoot 'temp-preauth.json')
    Remove-IfExists (Join-Path $qsRoot 'temp-role.json')
    Remove-IfExists (Join-Path $qsRoot 'temp-spa-config.json')

    # Restore web config placeholders
    $configPath = Join-Path $qsRoot 'web-app\config.js'
    if (Test-Path $configPath) {
        switch ($qsName) {
            'quickstart1' {
                @"
const CONFIG = {
    apiUrlLocal: 'http://localhost:5000',
    apiUrlAzure: '__API_URL_AZURE__'
};
"@ | Out-File -FilePath $configPath -Encoding utf8 -Force
            }
            'quickstart2' {
                @"
const CONFIG = {
    apiUrlLocal: 'http://localhost:5000',
    apiUrlAzure: '__API_URL_AZURE__'
};
"@ | Out-File -FilePath $configPath -Encoding utf8 -Force
            }
            'quickstart3' {
                @"
const CONFIG = {
    apiUrlLocal: 'http://localhost:5000',
    apiUrlAzure: '__API_URL_AZURE__'
};
"@ | Out-File -FilePath $configPath -Encoding utf8 -Force
            }
            'quickstart4' {
                @"
const CONFIG = {
    clientId: '__CLIENT_ID__',
    tenantId: '__TENANT_ID__',
    apiUrlLocal: 'http://localhost:5000',
    apiUrlAzure: '__API_URL_AZURE__'
};
"@ | Out-File -FilePath $configPath -Encoding utf8 -Force
            }
            'quickstart5' {
                @"
const CONFIG = {
    clientId: '__CLIENT_ID__',
    tenantId: '__TENANT_ID__',
    apiUrlLocal: 'http://localhost:5000',
    apiUrlAzure: '__API_URL_AZURE__'
};
"@ | Out-File -FilePath $configPath -Encoding utf8 -Force
            }
        }
        Write-Host "  reset:   $configPath" -ForegroundColor DarkGray
    }
}

# Remove quickstart MCP entries while preserving any user-added servers.
$mcpFile = Join-Path $repoRoot '.github\mcp.json'
if (Test-Path $mcpFile) {
    $raw = Get-Content -Path $mcpFile -Raw
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $mcpConfig = $raw | ConvertFrom-Json -AsHashtable
        if ($null -ne $mcpConfig -and $mcpConfig.ContainsKey('servers') -and $null -ne $mcpConfig.servers) {
            $keysToRemove = @(
                'azure-sql-mcp-qs1',
                'azure-sql-mcp-qs2',
                'azure-sql-mcp-qs3',
                'azure-sql-mcp-qs4',
                'azure-sql-mcp-qs5'
            )

            foreach ($key in $keysToRemove) {
                if ($mcpConfig.servers.ContainsKey($key)) {
                    $null = $mcpConfig.servers.Remove($key)
                    Write-Host "  removed MCP server: $key" -ForegroundColor DarkGray
                }
            }

            if ($mcpConfig.servers.Count -eq 0) {
                Remove-Item -Path $mcpFile -Force
                Write-Host "  removed empty MCP file: $mcpFile" -ForegroundColor DarkGray
            }
            else {
                $mcpConfig | ConvertTo-Json -Depth 100 | Out-File -FilePath $mcpFile -Encoding utf8 -Force
            }
        }
    }
}

Write-Step 'Reset complete. Quickstarts are back to demo-ready defaults.'
