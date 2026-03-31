# Quickstart 6: OBO (On-Behalf-Of) Build Report

## Objective

Build a complete quickstart demonstrating **Data API Builder 2.0 On-Behalf-Of (OBO)** authentication.
When a user signs in via the web app (MSAL + Entra ID), their identity flows through DAB to Azure SQL.
The database sees the actual user, not a service account. Validated with a `WhoAmI` view that calls `SUSER_NAME()`.

## What Was Built

**~35 files** across 8 directories, modeled after QS3/QS4 but with critical OBO-specific additions.

### Database (`database/`)
- `Tables/Todos.sql` — Same schema as QS4 (TodoId, Title, DueDate, Owner, Completed)
- `Views/WhoAmI.sql` — **NEW** `CREATE VIEW [dbo].[WhoAmI] AS SELECT SUSER_NAME() AS [UserName]`
  This is the OBO proof: returns the actual Entra user email when OBO is active, or the SQL admin when it's not.
- `Scripts/PostDeployment.sql` — Seeds 3 sample todos
- Uses `Microsoft.Build.Sql/2.0.0` SDK, `SqlAzureV12` DSP

### Data API (`data-api/`)
- `dab-config.json` — Key OBO additions:
  - `data-source.user-delegated-auth` with `enabled`, `provider: EntraId`, `database-audience: https://database.windows.net`
  - `cache.enabled: false` (required when OBO is enabled — tokens are per-user)
  - `WhoAmI` entity (view) with `authenticated` role, read-only
  - `Todos` entity with `@item.Owner eq @claims.preferred_username` policy (users only see their own data)
- `Dockerfile` — Uses `mcr.microsoft.com/azure-databases/data-api-builder:2.0.0-rc`
  **Important discovery**: The 1.7.83-rc image does NOT support `user-delegated-auth`. OBO requires DAB 2.0.

### Web App (`web-app/`)
- MSAL authentication with `access_as_user` scope (acquires token for DAB's API scope)
- Identity badge shows "SQL Server sees you as: jerry@nixoncorp.com" — visual OBO proof
- `dab.js` includes `fetchWhoAmI()` function calling `/api/WhoAmI`
- config.js uses `__CLIENT_ID__` / `__TENANT_ID__` placeholders, replaced by `entra-setup.ps1`

### Aspire AppHost (`aspire-apphost/`)
- Same structure as QS4 with `qs6-` prefixes
- `Demo.cs` checks for placeholder values and offers interactive Entra setup
- **Key finding**: OBO does NOT work locally with Aspire. Docker SQL Server doesn't accept Entra ID tokens.
  Locally, the app runs with SQL Auth. WhoAmI returns the SQL admin user. OBO activates only on Azure.

### Azure Infrastructure (`azure-infra/`)
- `entra-setup.ps1` — Creates app registration, `access_as_user` scope, client secret, Azure SQL Database `user_impersonation` permission
- `entra-teardown.ps1` — Deletes app registration, resets config files to placeholders
- `resources.bicep` — Container Apps + ACR + Azure SQL with Entra admin. OBO secret NOT in Bicep (see below)
- `post-provision.ps1` — The heavy lifter: deploys schema, grants user DB access via `CREATE USER [...] FROM EXTERNAL PROVIDER`, enables OBO, builds/pushes DAB image to ACR, sets OBO secrets on container app

## Problems Encountered and Solved

### 1. Region Capacity
- **East US 2**: `RegionDoesNotAllowProvisioning` — no new SQL Servers
- **East US**: Same error
- **Central US**: Succeeded
- **Fix**: Set `AZURE_LOCATION centralus` in azd env

### 2. Bicep Chicken-and-Egg
- `oboClientSecret` was a Bicep parameter, but `entra-setup.ps1` (preprovision hook) creates it
- Bicep resolution runs BEFORE hooks populate the env var → deployment fails
- **Fix**: Removed `oboClientSecret` from Bicep entirely. OBO secrets are added in `post-provision.ps1` via `az containerapp secret set` and `az containerapp update --set-env-vars`

### 3. DAB CLI Provider Flag
- `dab configure --data-source.user-delegated-auth.provider "EntraId"` fails — `provider` is not a valid CLI option
- The CLI only supports `--data-source.user-delegated-auth.enabled` and `--data-source.user-delegated-auth.database-audience`
- **Fix**: Removed `--data-source.user-delegated-auth.provider` from post-provision.ps1. The `provider` value is already set in the JSON file.

### 4. DAB Docker Image Version
- `mcr.microsoft.com/azure-databases/data-api-builder:1.7.83-rc` throws `Unexpected property user-delegated-auth while deserializing DataSource`
- OBO is a DAB 2.0 feature, not available in 1.7
- **Fix**: Updated Dockerfile to use `2.0.0-rc` image. Health check shows `version: 2.0.0`

### 5. azd Auth Mismatch
- azd was logged in as `jnixon@microsoft.com` but subscription is in `nixoncorp.com` tenant
- **Fix**: `azd config set auth.useAzCliAuth true` to use az CLI credentials (`jerry@nixoncorp.com`)

## OBO Documentation Validation

Read the DAB OBO docs at `data-api-builder-docs-pr/data-api-builder/concept/security/authenticate-on-behalf-of.md`.
Validated against the DAB 2.0 JSON schema. **The docs are correct.**

Key validated facts:
- `user-delegated-auth` sits under `data-source` (not under `runtime`)
- Properties: `enabled` (bool), `provider` (string, e.g. "EntraId"), `database-audience` (string)
- Env vars: `DAB_OBO_CLIENT_ID`, `DAB_OBO_TENANT_ID`, `DAB_OBO_CLIENT_SECRET`
- Cache must be disabled when OBO is active

## Deployment Summary

| Resource | Name | Status |
|---------|------|--------|
| Resource Group | rg-quickstart6-202603301931 | Created |
| SQL Server | sql-server-202603301931 | Healthy |
| SQL Database | sql-db | Schema deployed |
| ACR | acr202603301931 | Images pushed |
| DAB Container App | data-api-202603301931 | Running (v2.0.0) |
| Web App | web-app-202603301931 | Running |
| SQL Commander | sql-commander-202603301931 | Running |
| MCP Inspector | mcp-inspector-202603301931 | Running |
| App Registration | app-202603301931 | Configured |

### Live URLs

- **Web App**: https://web-app-202603301931.gentlepebble-f64c4c17.centralus.azurecontainerapps.io
- **DAB API**: https://data-api-202603301931.gentlepebble-f64c4c17.centralus.azurecontainerapps.io
- **SQL Commander**: https://sql-commander-202603301931.gentlepebble-f64c4c17.centralus.azurecontainerapps.io
- **MCP Inspector**: https://mcp-inspector-202603301931.gentlepebble-f64c4c17.centralus.azurecontainerapps.io

### DAB Health Check
```json
{
  "status": "Unhealthy",
  "version": "2.0.0",
  "checks": [
    { "name": "MSSQL", "status": "Healthy" },
    { "name": "Todos", "status": "Unhealthy (Forbidden)" },
    { "name": "WhoAmI", "status": "Unhealthy (Forbidden)" }
  ]
}
```

The REST endpoints show "Forbidden" because entities require the `authenticated` role. The health check runs anonymously. This is expected and correct behavior. The MSSQL data source is healthy.

## How to Validate OBO

1. Open the **Web App** URL
2. Sign in with your Entra ID account (auto-redirect via MSAL)
3. Look at the **identity badge** — it should show: "SQL Server sees you as: jerry@nixoncorp.com"
4. The Todo list should only show items where `Owner` matches your `preferred_username`
5. In **SQL Commander**, run `SELECT * FROM WhoAmI` — this runs as the MI, so it shows the managed identity name
6. The difference between steps 3 and 5 proves OBO is working: the web user's identity flows through DAB to SQL

## Key Technical Insight

OBO is fundamentally an **Azure-only** feature for DAB. Locally:
- Docker SQL Server doesn't accept Entra ID tokens
- Aspire runs the full stack but uses SQL Auth
- WhoAmI returns the SQL admin user, not the signed-in user
- The web app works but the identity badge shows the admin identity

On Azure:
- Azure SQL accepts Entra tokens via the OBO flow
- DAB exchanges the user's Entra token for a SQL token using the client secret
- The database principal is created via `CREATE USER [...] FROM EXTERNAL PROVIDER`
- WhoAmI returns the actual user email, proving end-to-end identity flow

## Files Created

```
quickstart6/
├── .config/dotnet-tools.json
├── .gitignore
├── .vscode/
│   ├── extensions.json
│   └── launch.json
├── azure.yaml
├── quickstart6.sln
├── README.md
├── report.md
├── aspire-apphost/
│   ├── Aspire.AppHost.csproj
│   ├── appsettings.Development.json
│   ├── Demo.cs
│   ├── Program.cs
│   └── Properties/launchSettings.json
├── azure-infra/
│   ├── azure-down.ps1
│   ├── azure-up.ps1
│   ├── entra-down.ps1
│   ├── entra-setup.ps1
│   ├── entra-teardown.ps1
│   ├── entra-up.ps1
│   ├── main.bicep
│   ├── main.parameters.json
│   ├── post-provision.ps1
│   └── resources.bicep
├── data-api/
│   ├── dab-config.json
│   └── Dockerfile
├── database/
│   ├── database.publish.xml
│   ├── database.sqlproj
│   ├── Scripts/PostDeployment.sql
│   ├── Tables/Todos.sql
│   └── Views/WhoAmI.sql
├── mcp-inspector/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   └── nginx.conf
└── web-app/
    ├── app.js
    ├── auth.js
    ├── config.js
    ├── dab.js
    ├── Dockerfile
    ├── index.html
    └── styles.css
```
