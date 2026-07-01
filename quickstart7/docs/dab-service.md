# DataApiBuilderService class

Starts and monitors a local Data API builder process from an ASP.NET application.

`DataApiBuilderService` is a copy-friendly helper for apps that want DAB as a process sidecar instead of a standalone container. The class validates the DAB CLI, starts `dab start`, waits for `/health`, captures recent output, reports status, and stops the child process during application shutdown.

## Namespace

`Quickstart7.WebApp.Services`

## Assembly

`WebApp.dll`

## Source

`web-app/Services/DataApiBuilderService.cs`

## Definition

```csharp
public sealed class DataApiBuilderService : IAsyncDisposable
```

## Remarks

Use `DataApiBuilderService` when the ASP.NET app should own the DAB lifecycle. DAB still remains the API layer for SQL; this class does not generate DAB configuration, query SQL directly, or replace DAB.

The service starts DAB on a loopback URL. If `DataApiBuilderOptions.Port` is omitted, it chooses an available port. The ASP.NET app can then expose selected DAB endpoints through same-origin proxy routes such as `/api`, `/graphql`, `/mcp`, `/health`, and `/swagger/`.

## Examples

### Register the service

```csharp
builder.Services.AddSingleton<DataApiBuilderService>();
builder.Services.AddHostedService<DataApiBuilderHostedService>();
```

### Start with a local tool manifest

```csharp
await dab.StartAsync(new DataApiBuilderOptions
{
    ConfigPath = "dab-config.json",
    UseDotNetToolRun = true
}, cancellationToken);
```

### Start with a global DAB install

```csharp
await dab.StartAsync(new DataApiBuilderOptions
{
    ConfigPath = "dab-config.json",
    DabExecutablePath = "dab"
}, cancellationToken);
```

### Pass a connection string to DAB

```csharp
var options = new DataApiBuilderOptions
{
    ConfigPath = "dab-config.json",
    EnvironmentVariables = new(StringComparer.OrdinalIgnoreCase)
    {
        ["MSSQL_CONNECTION_STRING"] = connectionString
    }
};
```

### Use a fixed DAB port

```csharp
var options = new DataApiBuilderOptions
{
    ConfigPath = "dab-config.json",
    Port = 5000
};
```

### Let the service choose an available port

```csharp
var status = await dab.StartAsync(new DataApiBuilderOptions
{
    ConfigPath = "dab-config.json"
}, cancellationToken);

var dabBaseUrl = status.BaseUrl;
```

### Read current status

```csharp
var status = dab.GetStatus();

if (status.Running)
{
    logger.LogInformation("DAB is running at {BaseUrl}", status.BaseUrl);
}
```

### Surface startup failures

```csharp
var status = await dab.StartAsync(options, cancellationToken);

if (status.State == DataApiBuilderState.Failed)
{
    logger.LogWarning("DAB failed: {Code} {Message}", status.ErrorCode, status.ErrorMessage);
}
```

### Listen for process output

```csharp
dab.OutputReceived += (_, e) =>
{
    logger.LogInformation("DAB {Stream}: {Message}", e.Stream, e.Message);
};
```

### Cancel startup from an event

```csharp
dab.Starting += (_, e) =>
{
    if (!File.Exists(e.Options.ConfigPath))
    {
        e.Cancel = true;
        e.CancelReason = "DAB config is missing.";
    }
};
```

### Check for same-origin route conflicts

```csharp
var appRoutes = new[] { "/api/orders", "/healthz" };

if (DataApiBuilderService.HasReservedPathConflict(appRoutes))
{
    throw new InvalidOperationException("An app route overlaps a DAB proxy path.");
}
```

### Stop DAB during shutdown

```csharp
public Task StopAsync(CancellationToken cancellationToken)
{
    return dab.StopAsync(cancellationToken);
}
```

## Constructors

| Constructor | Description |
|---|---|
| `DataApiBuilderService(ILogger<DataApiBuilderService>)` | Initializes the service with an ASP.NET logger. |

## Fields

| Field | Value | Description |
|---|---:|---|
| `DefaultExecutable` | `dab` | Default executable name used when DAB is installed globally. |
| `DefaultMinimumVersion` | `2.0.9` | Minimum supported DAB CLI version for this quickstart. |
| `ReservedProxyPaths` | `/api`, `/graphql`, `/mcp`, `/embed`, `/health`, `/swagger` | Paths commonly reserved for same-origin DAB proxy routes. |

## Methods

| Method | Returns | Description |
|---|---|---|
| `StartAsync(DataApiBuilderOptions, CancellationToken)` | `Task<DataApiBuilderStatus>` | Validates configuration and CLI version, starts DAB, waits for `/health`, and returns the resulting status. |
| `StopAsync(CancellationToken)` | `Task<DataApiBuilderStatus>` | Stops the DAB process if it is running and returns the final status. |
| `GetStatus()` | `DataApiBuilderStatus` | Returns the most recent status. If the process exited, the status is updated before returning. |
| `DisposeAsync()` | `ValueTask` | Stops and disposes the child process. |
| `HasReservedPathConflict(IEnumerable<string>, IEnumerable<string>?)` | `bool` | Checks whether app routes overlap with reserved DAB proxy paths. |

## Events

| Event | Event data | Description |
|---|---|---|
| `Starting` | `DataApiBuilderStartingEventArgs` | Raised before startup. Handlers can cancel startup. |
| `Started` | `DataApiBuilderStatus` | Raised after DAB passes `/health`. |
| `Stopped` | `DataApiBuilderStatus` | Raised when DAB exits cleanly or is stopped. |
| `Failed` | `DataApiBuilderFailedEventArgs` | Raised when startup fails or the process exits unexpectedly. |
| `OutputReceived` | `DataApiBuilderOutputEventArgs` | Raised for captured stdout and stderr lines. |

## DataApiBuilderOptions properties

| Property | Type | Default | Description |
|---|---|---|---|
| `ConfigPath` | `string` | Required | Path to `dab-config.json`. Relative paths are normalized to full paths. |
| `Port` | `int?` | `null` | Optional loopback port for DAB. If omitted, the service chooses an available port. |
| `WorkingDirectory` | `string?` | Config directory | Working directory for the DAB process. |
| `DabExecutablePath` | `string` | `dab` | Executable used when `UseDotNetToolRun` is `false`. |
| `UseDotNetToolRun` | `bool` | `false` | When `true`, starts DAB with `dotnet tool run dab --`. |
| `MinimumVersion` | `Version` | `2.0.9` | Minimum acceptable DAB CLI version. |
| `EnvironmentVariables` | `Dictionary<string,string?>` | Empty | Environment variables passed to the DAB process. |
| `StartupTimeout` | `TimeSpan` | 30 seconds | Time to wait for DAB `/health`. |
| `LogLevel` | `string` | `Information` | DAB log level passed to `dab start`. |
| `MaxOutputLines` | `int` | `200` | Maximum recent output lines retained in status. |

## DataApiBuilderStatus properties

| Property | Type | Description |
|---|---|---|
| `State` | `DataApiBuilderState` | Current lifecycle state. |
| `Running` | `bool` | Indicates whether DAB is expected to be running. |
| `BaseUrl` | `string?` | Loopback base URL for the DAB process. |
| `HealthUrl` | `string?` | DAB health endpoint. |
| `RestUrl` | `string?` | DAB REST base endpoint. |
| `GraphQlUrl` | `string?` | DAB GraphQL endpoint. |
| `McpUrl` | `string?` | DAB MCP endpoint. |
| `EmbedUrl` | `string?` | DAB embed endpoint. |
| `SwaggerUrl` | `string?` | DAB Swagger endpoint. |
| `StartedAt` | `DateTimeOffset?` | UTC start time for the current process. |
| `ExitCode` | `int?` | Process exit code when available. |
| `ErrorCode` | `DataApiBuilderErrorCode?` | Failure category when startup or runtime fails. |
| `ErrorMessage` | `string?` | Human-readable failure message. |
| `Output` | `string?` | Recent scrubbed stdout/stderr output. |

## DataApiBuilderState enum

| Name | Description |
|---|---|
| `Stopped` | No DAB process is running. |
| `Starting` | DAB has been launched and health checks are pending. |
| `Running` | DAB passed `/health`. |
| `Failed` | Startup or runtime failed. |

## DataApiBuilderErrorCode enum

| Name | Description | Common fix |
|---|---|---|
| `ConfigMissing` | The config path does not exist. | Verify `dab-config.json` is copied to output/publish. |
| `CliMissing` | The DAB CLI could not be found. | Run `dotnet tool restore` or install the global tool. |
| `CliVersionTooOld` | The CLI is older than `2.0.9`. | Update Microsoft.DataApiBuilder. |
| `ProcessStartFailed` | The child process could not start. | Check executable path and permissions. |
| `PortUnavailable` | The requested port is already in use. | Pick another port or omit `Port`. |
| `ExitedDuringStartup` | DAB exited before `/health` passed. | Check recent output for config or SQL errors. |
| `StartupTimedOut` | `/health` did not respond in time. | Increase timeout or inspect DAB output. |
| `StartCanceled` | A `Starting` event handler canceled startup. | Check the event handler's cancel reason. |
| `ProcessExited` | DAB exited after startup. | Inspect `ExitCode` and recent `Output`. |

## Same-origin proxy paths

The quickstart proxies these ASP.NET paths to DAB:

| ASP.NET path | DAB feature |
|---|---|
| `/api` | REST |
| `/graphql` | GraphQL API requests |
| `/graphql/` | GraphQL browser UI |
| `/mcp` | MCP |
| `/embed/` | Future embedding support |
| `/health` | Health checks |
| `/swagger/` | OpenAPI UI |

Use trailing slashes for browser UIs (`/swagger/`, `/graphql/`, `/embed/`) so relative UI assets resolve under the proxied path. GraphQL API requests still post to `/graphql`.

## Tool installation

For local tool manifests, run:

```powershell
dotnet tool restore
```

For global installs, run:

```powershell
dotnet tool install --global Microsoft.DataApiBuilder --version 2.0.9
```

The quickstart uses `UseDotNetToolRun = true` locally so `dotnet tool run dab` uses the local manifest. In the container image, the Dockerfile installs DAB globally and sets `DataApiBuilder__UseDotNetToolRun=false`.

## Troubleshooting

### SQL login failed

Check the connection string environment variable referenced by `dab-config.json`. This quickstart uses SQL username/password authentication for clarity.

### `/api` returns 503

The ASP.NET app is running, but the DAB sidecar is not healthy. Open the sidecar utility panel or call `/dab/status`.

### Swagger or GraphQL does not open

Call `/health` first. If health fails, check `/dab/status` for startup output. For browser UIs, use trailing slashes: `/swagger/` and `/graphql/`.

## Applies to

- ASP.NET Core apps that start DAB as a child process.
- DAB CLI `2.0.9` or later.
- Local Aspire orchestration and containerized deployments that include the DAB CLI.
