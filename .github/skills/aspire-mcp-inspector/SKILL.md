---
name: aspire-mcp-inspector
description: Add MCP Inspector to a .NET Aspire AppHost for debugging MCP servers like Data API Builder. Use when asked to inspect MCP traffic, debug MCP connections, or add MCP Inspector to Aspire.
---

# MCP Inspector in .NET Aspire

Add the MCP Inspector as an Aspire-managed resource so it auto-starts alongside your MCP server (e.g., Data API Builder), appears in the dashboard, and is accessible in the browser without manual setup.

## Documentation references

- https://github.com/CommunityToolkit/Aspire/blob/main/src/CommunityToolkit.Aspire.Hosting.McpInspector/README.md
- https://github.com/modelcontextprotocol/inspector
- https://modelcontextprotocol.io/docs/tools/inspector

---

## Package

```xml
<PackageReference Include="CommunityToolkit.Aspire.Hosting.McpInspector" Version="13.1.1" />
```

---

## Canonical Program.cs Pattern

```csharp
var mcpInspector = builder
    .AddMcpInspector("mcp-inspector", options =>
    {
        options.InspectorVersion = "0.20.0";   // always pin — default version has known StreamableHTTP bugs
    })
    .WithMcpServer(dabServer, transportType: McpTransportType.StreamableHttp)
    .WithParentRelationship(dabServer)          // groups under the MCP server in the dashboard
    .WithEnvironment("DANGEROUSLY_OMIT_AUTH", "true")  // removes token prompt for local dev
    .WaitFor(dabServer);
```

---

## Transport Type

Always use `McpTransportType.StreamableHttp` for DAB and most modern MCP servers.

- DAB exposes MCP at `/mcp` via Streamable HTTP — **not SSE**
- `McpTransportType.Sse` will produce a "Connection Error" against DAB

---

## Inspector Version

**Always pin `InspectorVersion` explicitly.** The version bundled in the NuGet package (`0.17.2`) has a crash on StreamableHTTP:

```
TypeError [ERR_INVALID_STATE]: Invalid state: Controller is already closed
```

Use `0.20.0` or later. Check https://www.npmjs.com/package/@modelcontextprotocol/inspector for the current release.

---

## Auth

For local development, set `DANGEROUSLY_OMIT_AUTH=true`. This eliminates the "Proxy Authentication Required" dialog. It is safe because the inspector only binds to `localhost`.

Without this, the token-embedded URL is shown in the Aspire dashboard — the user must click that specific link. Navigating directly to `http://localhost:6274` will trigger the auth prompt.

---

## How It Works

The inspector is **not a container** — it runs as a Node.js process (`npx @modelcontextprotocol/inspector@<version>`) on the host machine. The Aspire toolkit:

1. Writes a temp JSON config file at startup with the MCP server URL and transport type
2. Invokes `npx -y <package> --config <tempfile> --server <name>`
3. Starts two ports: `6274` (browser UI) and `6277` (proxy server)

The inspector UI will pre-select the configured server but **does not auto-connect** — the user must click **Connect** once in the browser.

---

## Ports

| Port | Purpose |
|------|---------|
| 6274 | Inspector browser UI (default) |
| 6277 | Proxy server (default) |

Override via `options.ClientPort` and `options.ServerPort`.

---

## Common Issues and Fixes

### "Controller is already closed" crash
**Cause:** Default inspector version (0.17.2) bug with StreamableHTTP.  
**Fix:** Pin `options.InspectorVersion = "0.20.0"`.

### "Proxy Authentication Required" dialog
**Cause:** Browser navigated to `localhost:6274` directly instead of the token URL, or auth was not disabled.  
**Fix:** Add `.WithEnvironment("DANGEROUSLY_OMIT_AUTH", "true")`.

### "Connection Error — Check if your MCP server is running and proxy token is correct"
**Cause 1:** Wrong transport type (SSE instead of StreamableHTTP).  
**Fix:** Use `McpTransportType.StreamableHttp`.  
**Cause 2:** MCP server not yet healthy when inspector tried to connect.  
**Fix:** Ensure `.WaitFor(dabServer)` is present.

### Do not override `WithUrls`
The Aspire toolkit generates the token-embedded URL via its own `WithUrls` callback. Chaining another `WithUrls` that clears or replaces the URL list will break the dashboard link.

---

## Prerequisites

- Node.js 22+ installed on the host (`node --version`)
- npx available (`npx --version`)
- Docker running (for the MCP server container)
