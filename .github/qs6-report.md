# Quickstart 6 — Investigation & Fix Report

**Status:** ✅ Working  
**Environment:** Azure (Azure Container Apps + Azure SQL)  
**DAB Version:** 2.0.0  
**Date resolved:** 2026-03-31

---

## What quickstart 6 does

Quickstart 6 demonstrates **On-Behalf-Of (OBO) / user-delegated authentication** — a DAB 2.0 feature where DAB passes the caller's Entra ID token all the way through to Azure SQL, so the database authenticates as the **actual signed-in user** rather than as the DAB service account.

The stack is:
- **Entra ID** — single-tenant app registration with `access_as_user` scope and `user_impersonation` permission on Azure SQL
- **DAB 2.0** on Azure Container Apps — validates JWT, performs OBO token exchange, connects to SQL as the user
- **Azure SQL** — Entra ID-only auth; external users provisioned via `CREATE USER [...] FROM EXTERNAL PROVIDER`
- **Vanilla JS SPA** (MSAL) — acquires delegated token, calls DAB REST API
- **`WhoAmI` SQL view** — confirms the database sees the real user identity

---

## Symptoms

All authenticated REST calls returned HTTP 500 with:

```json
{"error":{"code":"UnexpectedError","message":"While processing your request the server ran into an unexpected error.","status":500}}
```

MSAL was authenticating successfully (token acquired, `aud` matched DAB config). The 500 occurred after token validation, during the SQL execution phase.

---

## Root cause

**`Microsoft.Data.SqlClient` forbids setting `AccessToken` when `Authentication=` is present in the connection string.**

The `resources.bicep` originally provisioned the DAB container app with a Managed Identity connection string:

```
Server=tcp:...;Database=sql-db;Authentication=Active Directory Managed Identity;Encrypt=true;TrustServerCertificate=true
```

DAB 2.0's OBO implementation injects the per-user OBO token by setting `SqlConnection.AccessToken` at runtime. The `Microsoft.Data.SqlClient` library throws an unhandled exception when `AccessToken` is set and the connection string already contains an `Authentication=` keyword. DAB caught this as a generic 500.

The conflict is documented in the `Microsoft.Data.SqlClient` API:
> *"The AccessToken property cannot be set when the connection string contains an authentication method."*

This affected every entity (Todos, WhoAmI) and every HTTP verb (GET, POST).

---

## Fix applied

### 1. Changed the DAB connection string to bare format (no `Authentication=`)

**`azure-infra/resources.bicep`** — replaced `sqlMiConnString` with `sqlBareConnString`:

```bicep
// Before (broken):
var sqlMiConnString = '...;Authentication=Active Directory Managed Identity;...'

// After (fixed):
var sqlBareConnString = 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},1433;Database=sql-db;Encrypt=true;TrustServerCertificate=true'
```

With a bare connection string DAB 2.0:
- Acquires an MSI token automatically (via Azure.Identity) for its own health checks and internal operations
- Injects the per-user OBO token as `AccessToken` for each authenticated request

### 2. Live fix to the deployed container app

The currently deployed `data-api-202603301931` container app secret `db-conn` was updated in-place via:

```powershell
az containerapp secret set --name data-api-202603301931 --resource-group rg-quickstart6-202603301931 --secrets "db-conn=Server=tcp:sql-server-202603301931.database.windows.net,1433;Database=sql-db;Encrypt=true;TrustServerCertificate=true"
az containerapp revision restart --name data-api-202603301931 --resource-group rg-quickstart6-202603301931 --revision data-api-202603301931--v5
```

### 3. Updated docs

`data-api-builder-docs-pr/.../authenticate-on-behalf-of.md` — added a prominent **Connection string requirement** section explaining the `Authentication=` constraint and showing the correct bare format. Also updated the full configuration example.

---

## Verification

After the fix:
- `GET /health` — MSSQL: Healthy (base MSI connection works), entities: Healthy ✅  
- `GET /api/WhoAmI` (with bearer token) — returns `live.com#jerry@nixoncorp.com` ✅  
- `GET /api/Todos` (with bearer token) — returns user-scoped rows ✅  
- `POST /api/Todos` — 201 Created ✅  
- Row-level security (`@item.Owner eq @claims.preferred_username`) — enforced ✅
- SQL Server identity shown in UI: `live.com#jerry@nixoncorp.com` (the real user, not the MSI) ✅

---

## Can Aspire be used locally?

**Not for OBO.** OBO requires:
1. A real Entra ID app registration (needs a cloud tenant)
2. Azure SQL with Entra ID authentication configured (needs Azure SQL, not a local SQL container)
3. An OBO token exchange against `login.microsoftonline.com` (requires network access to Entra ID)

A local SQL Server container cannot accept Entra ID tokens. This quickstart is **Azure-only by design** — the demo scenario (identity passing from web app → DAB → SQL) fundamentally requires Azure AD and Azure SQL. Aspire could orchestrate the web app and DAB locally but the SQL backend must be Azure SQL, making a fully local Aspire deployment impractical for this scenario.

**Recommended developer flow:** deploy once with `azure-up.ps1`, then run the SPA locally against the Azure DAB endpoint (`apiUrlAzure` in `config.js`).

---

## Deployment checklist (for fresh deployments)

1. `cd quickstart6/azure-infra && .\azure-up.ps1`  
   — runs `azd up` which triggers:  
   &nbsp;&nbsp;• `entra-setup.ps1` (pre-provision hook) — creates app registration, scopes, secrets  
   &nbsp;&nbsp;• Bicep provisioning — SQL, Container Apps, ACR  
   &nbsp;&nbsp;• `post-provision.ps1` (post-provision hook) — schema, Entra admin, DB users, DAB image, web image  
2. Open the `web-app-url` from `.azure-env`  
3. Sign in with an Entra ID account that has been granted database access

To grant an additional user access to the database, run this T-SQL against `sql-db`:
```sql
CREATE USER [user@domain.com] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [user@domain.com];
ALTER ROLE db_datawriter ADD MEMBER [user@domain.com];
```
