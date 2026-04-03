# Quickstart 6: On-Behalf-Of (OBO) Flow

Demonstrates **On-Behalf-Of (OBO) / user-delegated authentication** in Data API Builder 2.0. Users sign in with Microsoft Entra ID, and DAB exchanges the user's token to connect to Azure SQL **as that user's identity** — not as a service account.

A `WhoAmI` view (`SELECT SUSER_NAME()`) proves that SQL Server sees the real user. The web app shows this identity in a prominent badge: **"SQL Server sees you as: jerry@nixoncorp.com"**.

## What You'll Learn

- Configure DAB `user-delegated-auth` for OBO token exchange
- Create an Entra app registration with a client secret and `Azure SQL Database` delegated permission
- Flow the user's identity from browser → API → database
- Validate with `SUSER_NAME()` that SQL sees the actual caller
- Use a **bare connection string** (no `Authentication=` keyword) so DAB can inject the OBO token per-request

## Azure-Only

> **Important:** OBO requires Azure SQL with Entra ID authentication configured. A local Docker SQL Server container cannot accept Entra tokens — the OBO token exchange calls `login.microsoftonline.com` and requires Azure SQL's external provider support. **This quickstart is Azure-only by design.** There is no local Aspire option for the full OBO flow.

## Auth Matrix

| Hop | Who |
|-----|-----|
| User → Web App | MSAL browser login (Entra ID) |
| Web App → DAB API | Bearer token (JWT) |
| DAB API → Azure SQL | **OBO token — the actual user's identity** |

## Architecture

```mermaid
flowchart LR
    U[User]

    subgraph Microsoft Entra
        E[App Registration]
    end

    subgraph Azure Container Apps
        W[Web App]
        A[Data API builder]
    end

    subgraph Azure SQL
        S[(Database)]
    end

    U <-->|Login| E
    E -.-> W
    U -->|OAuth| W -->|Bearer Token| A -->|OBO Token| S
```

> **Why OBO?** Unlike Managed Identity (where SQL sees the app's identity), OBO passes the actual user's identity to the database. SQL Server sees `jerry@nixoncorp.com` — powerful for auditing, row-level security, and SUSER_NAME()-based policies.

## Prerequisites

- [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli)
- [Azure Developer CLI (azd)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Data API Builder CLI](https://learn.microsoft.com/azure/data-api-builder/) — `dotnet tool restore`
- [PowerShell](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
- **Entra ID permissions:** ability to create app registrations, grant admin consent, and create client secrets in your tenant

## Deploy to Azure

```powershell
pwsh ./azure-infra/azure-up.ps1
```

This runs `azd up` which automatically:

1. **Pre-provision** (`entra-setup.ps1`) — creates the Entra app registration, exposes `access_as_user` scope, adds `Azure SQL Database` `user_impersonation` delegated permission, creates client secret, updates `dab-config.json` and `config.js`
2. **Bicep provision** — creates SQL Server + Database, Container Apps Environment, ACR, and Container Apps for DAB, web app, SQL Commander, and MCP Inspector
3. **Post-provision** (`post-provision.ps1`) — deploys schema via SqlPackage, sets Entra admin on SQL Server, creates database users for the DAB managed identity and the signed-in user, builds and pushes custom container images, configures OBO environment variables

Deployment takes approximately **15–20 minutes**.

## Tear Down

```powershell
pwsh ./azure-infra/azure-down.ps1
```

Deletes all Azure resources, removes the Entra app registration, and resets local config files to placeholder state.

## Validating OBO

Once deployed, open the web app URL (printed at end of `azure-up.ps1`). The **"SQL Server sees you as:"** badge shows `SELECT SUSER_NAME()`. If OBO is working, it shows your Entra email, not the managed identity name.

You can also call the API directly:

```bash
curl -H "Authorization: Bearer <your-token>" https://<dab-fqdn>/api/WhoAmI
```

## Key Implementation Detail — Bare Connection String

When OBO is enabled, the connection string **must not** include an `Authentication=` keyword. `Microsoft.Data.SqlClient` throws if `AccessToken` is set and `Authentication=` is already present.

✅ Correct:
```
Server=tcp:<server>.database.windows.net,1433;Database=<db>;Encrypt=true;TrustServerCertificate=true
```

❌ Broken (causes HTTP 500 on every authenticated request):
```
Server=tcp:<server>.database.windows.net,1433;Database=<db>;Authentication=Active Directory Managed Identity;...
```

DAB 2.0 with OBO uses Azure.Identity (MSI) automatically for health checks and acquires the per-user OBO token for each authenticated request.

## Key Implementation Files

| File | Purpose |
|------|---------|
| `data-api/dab-config.json` | Enables `user-delegated-auth` (OBO) under `data-source`, disables cache, and adds `WhoAmI` view entity |
| `database/Views/WhoAmI.sql` | Defines `SELECT SUSER_NAME() AS UserName` for identity verification |
| `web-app/index.html` | Shows identity badge for SQL identity and includes debug log area |
| `web-app/dab.js` | Implements `fetchWhoAmI()` |
| `web-app/app.js` | Calls `updateIdentity()` on load and refresh |
| `azure-infra/entra-setup.ps1` | Creates client secret and adds Azure SQL Database `user_impersonation` permission |
| `azure-infra/resources.bicep` | Uses bare SQL connection string (no `Authentication=`) and wires OBO secrets |
| `azure-infra/post-provision.ps1` | Grants signed-in user DB access, enables OBO in DAB config, sets OBO env vars, and forces revision suffix on image updates |


## Next Steps

- Read the [OBO documentation](https://learn.microsoft.com/azure/data-api-builder/concept/security/authenticate-on-behalf-of) for configuration details
- Combine OBO with Row-Level Security for user-aware SQL policies

