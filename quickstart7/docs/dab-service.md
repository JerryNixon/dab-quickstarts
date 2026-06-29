# DataApiBuilderService developer guide

`DataApiBuilderService` is a small copy-friendly class for ASP.NET apps that want Data API builder without hosting DAB as a separate service. Your app starts DAB as a local process, monitors it, and can proxy DAB endpoints through the same origin.

## What it does

- Validates that `dab-config.json` exists.
- Validates that the DAB CLI is installed and version `2.0.9` or newer.
- Starts `dab start --config <path>` as a child process.
- Chooses an available loopback port when you do not provide one.
- Captures recent stdout/stderr output.
- Waits for `/health` before reporting the process as running.
- Stops the process when your app shuts down.

It does not generate DAB config, talk directly to SQL, or replace DAB. DAB remains the API layer for SQL.

## Minimal setup

1. Copy `Services/DataApiBuilderService.cs` into your ASP.NET project.
2. Add a `dab-config.json` file to your app and copy it to output/publish.
3. Install DAB CLI `2.0.9` or newer.
4. Set the connection string environment variable referenced by your DAB config, for example `MSSQL_CONNECTION_STRING`.
5. Register the service and start it from a hosted service or your own startup code.

For local tool manifests, run:

```powershell
dotnet tool restore
```

For global installs, run:

```powershell
dotnet tool install --global Microsoft.DataApiBuilder --version 2.0.9
```

## Starting DAB

Create options with the path to your config file. The port is optional.

- If `Port` is set, DAB uses that loopback port and the service validates that it is available.
- If `Port` is omitted, the service chooses an available loopback port. Your ASP.NET app can then expose DAB with same-origin proxy routes.

The quickstart uses `UseDotNetToolRun = true` locally so `dotnet tool run dab` uses the local tool manifest. In a container, the Dockerfile installs DAB globally and sets `DataApiBuilder__UseDotNetToolRun=false`.

## Same-origin proxy paths

The demo proxies these paths to DAB:

- `/api` for REST
- `/graphql` for GraphQL
- `/mcp` for MCP
- `/embed` for future embedding support
- `/health` for health checks
- `/swagger` for the OpenAPI UI

If your app already uses one of those paths, choose a dedicated DAB port or change your route layout. The service exposes `ReservedProxyPaths` and `HasReservedPathConflict` to help detect conflicts before startup.

## Events

- `Starting` — cancelable. Use it to block startup when your app is not ready.
- `Started` — fires after DAB `/health` succeeds.
- `OutputReceived` — streams stdout/stderr lines.
- `Failed` — includes an error code, message, exception when available, and recent output.
- `Stopped` — fires when DAB exits or is stopped.

## Error codes

| Code | Meaning | Fix |
|------|---------|-----|
| `ConfigMissing` | The config path does not exist. | Verify `dab-config.json` is copied to output/publish. |
| `CliMissing` | The DAB CLI could not be found. | Run `dotnet tool restore` or install the global tool. |
| `CliVersionTooOld` | The CLI is older than `2.0.9`. | Update Microsoft.DataApiBuilder. |
| `PortUnavailable` | The requested port is already in use. | Pick another port or omit `Port`. |
| `ExitedDuringStartup` | DAB exited before health was ready. | Check recent output for config or SQL errors. |
| `StartupTimedOut` | `/health` did not respond in time. | Increase timeout or inspect DAB output. |
| `ProcessStartFailed` | The child process could not start. | Check executable path and permissions. |

## Troubleshooting

### SQL login failed

Check the connection string environment variable referenced by `dab-config.json`. This quickstart uses SQL username/password authentication for clarity.

### `/api` returns 503

The ASP.NET app is running, but the DAB sidecar is not healthy. Open the demo status panel or call `/dab/status`.

### Swagger or GraphQL does not open

Call `/health` first. If health fails, check `/dab/status` for the DAB startup output.
