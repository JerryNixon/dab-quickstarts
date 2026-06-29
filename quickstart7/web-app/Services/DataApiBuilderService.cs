using System.ComponentModel;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;

namespace Quickstart7.WebApp.Services;

public sealed class DataApiBuilderService : IAsyncDisposable
{
    public const string DefaultExecutable = "dab";
    public static readonly Version DefaultMinimumVersion = new(2, 0, 9);
    public static readonly string[] ReservedProxyPaths = ["/api", "/graphql", "/mcp", "/embed", "/health", "/swagger"];

    private readonly ILogger<DataApiBuilderService> _logger;
    private readonly object _sync = new();
    private RunningDab? _running;
    private DataApiBuilderStatus _lastStatus = DataApiBuilderStatus.Stopped();

    public DataApiBuilderService(ILogger<DataApiBuilderService> logger)
    {
        _logger = logger;
    }

    public event EventHandler<DataApiBuilderStartingEventArgs>? Starting;
    public event EventHandler<DataApiBuilderStatus>? Started;
    public event EventHandler<DataApiBuilderStatus>? Stopped;
    public event EventHandler<DataApiBuilderFailedEventArgs>? Failed;
    public event EventHandler<DataApiBuilderOutputEventArgs>? OutputReceived;

    public DataApiBuilderStatus GetStatus()
    {
        lock (_sync)
        {
            if (_running is null)
            {
                return _lastStatus;
            }

            if (_running.Process.HasExited)
            {
                var status = BuildStatus(_running, _running.Process.ExitCode == 0 ? DataApiBuilderState.Stopped : DataApiBuilderState.Failed)
                    with
                    {
                        Running = false,
                        ExitCode = _running.Process.ExitCode,
                        ErrorCode = _running.Process.ExitCode == 0 ? null : DataApiBuilderErrorCode.ProcessExited,
                        ErrorMessage = _running.Process.ExitCode == 0 ? null : $"DAB exited with code {_running.Process.ExitCode}."
                    };
                _lastStatus = status;
                _running = null;
                return status;
            }

            return BuildStatus(_running, DataApiBuilderState.Running);
        }
    }

    public async Task<DataApiBuilderStatus> StartAsync(DataApiBuilderOptions options, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(options);

        lock (_sync)
        {
            if (_running is not null && !_running.Process.HasExited)
            {
                return BuildStatus(_running, DataApiBuilderState.Running);
            }
        }

        var normalized = options.Normalize();
        var startingArgs = new DataApiBuilderStartingEventArgs(normalized);
        Starting?.Invoke(this, startingArgs);
        if (startingArgs.Cancel)
        {
            return RememberFailure(DataApiBuilderErrorCode.StartCanceled, startingArgs.CancelReason ?? "DAB startup was canceled.", null, null, null);
        }

        if (!File.Exists(normalized.ConfigPath))
        {
            return RememberFailure(DataApiBuilderErrorCode.ConfigMissing, $"DAB config was not found: {normalized.ConfigPath}", null, null, null);
        }

        var versionResult = await TryGetVersionAsync(normalized, cancellationToken).ConfigureAwait(false);
        if (!versionResult.Success)
        {
            return RememberFailure(versionResult.ErrorCode ?? DataApiBuilderErrorCode.CliMissing, versionResult.ErrorMessage ?? "DAB CLI is not available.", versionResult.Exception, null, versionResult.Output);
        }

        if (versionResult.Version is null || versionResult.Version < normalized.MinimumVersion)
        {
            var found = versionResult.Version?.ToString() ?? "unknown";
            return RememberFailure(
                DataApiBuilderErrorCode.CliVersionTooOld,
                $"DAB CLI {normalized.MinimumVersion} or newer is required. Found {found}. Update with: dotnet tool update --global Microsoft.DataApiBuilder --version {normalized.MinimumVersion}",
                null,
                null,
                versionResult.Output);
        }

        var port = normalized.Port ?? GetAvailableDataApiPort(5000);
        if (normalized.Port is not null && !IsLoopbackPortAvailable(port))
        {
            return RememberFailure(DataApiBuilderErrorCode.PortUnavailable, $"Port {port} is already in use. Choose another DAB port or omit the port to auto-select one.", null, null, versionResult.Output);
        }

        var baseUrl = $"http://127.0.0.1:{port}";
        var output = new BoundedOutput(normalized.MaxOutputLines);
        AppendOutput(output, "info", $"Starting DAB {versionResult.Version} on {baseUrl}.", normalized);

        var startInfo = CreateStartInfo(normalized, "start", "--config", normalized.ConfigPath, "--no-https-redirect", "--LogLevel", normalized.LogLevel);
        startInfo.Environment["ASPNETCORE_URLS"] = baseUrl;
        startInfo.Environment["DOTNET_URLS"] = baseUrl;
        foreach (var item in normalized.EnvironmentVariables)
        {
            startInfo.Environment[item.Key] = item.Value ?? string.Empty;
        }

        var process = new Process
        {
            StartInfo = startInfo,
            EnableRaisingEvents = true
        };

        var runtime = new RunningDab(process, normalized, baseUrl, output, DateTimeOffset.UtcNow);
        process.OutputDataReceived += (_, e) => AppendOutput(output, "out", e.Data, normalized);
        process.ErrorDataReceived += (_, e) => AppendOutput(output, "err", e.Data, normalized);
        process.Exited += (_, _) => HandleExited(runtime);

        try
        {
            if (!process.Start())
            {
                process.Dispose();
                return RememberFailure(DataApiBuilderErrorCode.ProcessStartFailed, "The DAB process did not start.", null, null, output.ToString());
            }
        }
        catch (Exception ex) when (ex is Win32Exception or FileNotFoundException)
        {
            process.Dispose();
            return RememberFailure(DataApiBuilderErrorCode.CliMissing, BuildCliMissingMessage(normalized), ex, null, output.ToString());
        }
        catch (Exception ex)
        {
            process.Dispose();
            return RememberFailure(DataApiBuilderErrorCode.ProcessStartFailed, $"DAB could not be started: {ex.Message}", ex, null, output.ToString());
        }

        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        lock (_sync)
        {
            _running = runtime;
            _lastStatus = BuildStatus(runtime, DataApiBuilderState.Starting);
        }

        var ready = await WaitForReadyAsync(runtime, normalized.StartupTimeout, cancellationToken).ConfigureAwait(false);
        if (ready.State == DataApiBuilderState.Failed)
        {
            await StopAsync(CancellationToken.None).ConfigureAwait(false);
            return RememberFailure(ready.ErrorCode ?? DataApiBuilderErrorCode.StartupTimedOut, ready.ErrorMessage ?? "DAB did not become healthy.", null, baseUrl, output.ToString());
        }

        var status = BuildStatus(runtime, DataApiBuilderState.Running);
        lock (_sync)
        {
            _lastStatus = status;
        }
        Started?.Invoke(this, status);
        return status;
    }

    public async Task<DataApiBuilderStatus> StopAsync(CancellationToken cancellationToken = default)
    {
        RunningDab? runtime;
        lock (_sync)
        {
            runtime = _running;
            _running = null;
        }

        if (runtime is null)
        {
            return _lastStatus with { State = DataApiBuilderState.Stopped, Running = false };
        }

        try
        {
            if (!runtime.Process.HasExited)
            {
                AppendOutput(runtime.Output, "info", "Stopping DAB.", runtime.Options);
                try
                {
                    runtime.Process.CloseMainWindow();
                }
                catch
                {
                    // Console child processes usually have no main window.
                }

                var waitTask = runtime.Process.WaitForExitAsync(cancellationToken);
                var completed = await Task.WhenAny(waitTask, Task.Delay(TimeSpan.FromSeconds(2), cancellationToken)).ConfigureAwait(false);
                if (completed != waitTask && !runtime.Process.HasExited)
                {
                    runtime.Process.Kill(entireProcessTree: true);
                    await runtime.Process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
                }
            }

            var status = BuildStatus(runtime, DataApiBuilderState.Stopped) with
            {
                Running = false,
                ExitCode = runtime.Process.HasExited ? runtime.Process.ExitCode : null
            };
            lock (_sync)
            {
                _lastStatus = status;
            }
            Stopped?.Invoke(this, status);
            return status;
        }
        finally
        {
            runtime.Process.Dispose();
        }
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync(CancellationToken.None).ConfigureAwait(false);
    }

    public static bool HasReservedPathConflict(IEnumerable<string> existingRoutePatterns, IEnumerable<string>? reservedPaths = null)
    {
        var reserved = (reservedPaths ?? ReservedProxyPaths)
            .Select(p => p.TrimEnd('/'))
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        foreach (var route in existingRoutePatterns)
        {
            var path = route.Trim().TrimEnd('/');
            if (!path.StartsWith('/'))
            {
                path = "/" + path;
            }

            if (reserved.Any(r => path.Equals(r, StringComparison.OrdinalIgnoreCase) || path.StartsWith(r + "/", StringComparison.OrdinalIgnoreCase)))
            {
                return true;
            }
        }

        return false;
    }

    private async Task<DataApiBuilderStatus> WaitForReadyAsync(RunningDab runtime, TimeSpan timeout, CancellationToken cancellationToken)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(2) };
        var stopAt = DateTimeOffset.UtcNow.Add(timeout);
        var healthUrl = CombineUrl(runtime.BaseUrl, "health");

        while (DateTimeOffset.UtcNow < stopAt)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (runtime.Process.HasExited)
            {
                return BuildStatus(runtime, DataApiBuilderState.Failed) with
                {
                    Running = false,
                    ExitCode = runtime.Process.ExitCode,
                    ErrorCode = DataApiBuilderErrorCode.ExitedDuringStartup,
                    ErrorMessage = $"DAB exited during startup with code {runtime.Process.ExitCode}."
                };
            }

            try
            {
                using var response = await http.GetAsync(healthUrl, cancellationToken).ConfigureAwait(false);
                if (response.IsSuccessStatusCode)
                {
                    return BuildStatus(runtime, DataApiBuilderState.Running);
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch
            {
                // DAB may still be binding its listener.
            }

            await Task.Delay(250, cancellationToken).ConfigureAwait(false);
        }

        return BuildStatus(runtime, DataApiBuilderState.Failed) with
        {
            Running = false,
            ErrorCode = DataApiBuilderErrorCode.StartupTimedOut,
            ErrorMessage = $"DAB did not become healthy within {timeout.TotalSeconds:N0} seconds."
        };
    }

    private async Task<VersionCheckResult> TryGetVersionAsync(DataApiBuilderOptions options, CancellationToken cancellationToken)
    {
        var startInfo = CreateStartInfo(options, "--version");
        try
        {
            using var process = new Process { StartInfo = startInfo };
            if (!process.Start())
            {
                return VersionCheckResult.Fail(DataApiBuilderErrorCode.CliMissing, BuildCliMissingMessage(options), null, null);
            }

            var outputTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
            var errorTask = process.StandardError.ReadToEndAsync(cancellationToken);
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
            var output = await outputTask.ConfigureAwait(false) + await errorTask.ConfigureAwait(false);

            if (process.ExitCode != 0)
            {
                return VersionCheckResult.Fail(DataApiBuilderErrorCode.CliMissing, BuildCliMissingMessage(options), null, output);
            }

            return VersionCheckResult.SuccessResult(ParseVersion(output), output);
        }
        catch (Exception ex) when (ex is Win32Exception or FileNotFoundException)
        {
            return VersionCheckResult.Fail(DataApiBuilderErrorCode.CliMissing, BuildCliMissingMessage(options), ex, null);
        }
    }

    private ProcessStartInfo CreateStartInfo(DataApiBuilderOptions options, params string[] dabArguments)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = options.UseDotNetToolRun ? "dotnet" : options.DabExecutablePath,
            WorkingDirectory = options.WorkingDirectory,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        if (options.UseDotNetToolRun)
        {
            startInfo.ArgumentList.Add("tool");
            startInfo.ArgumentList.Add("run");
            startInfo.ArgumentList.Add("dab");
            startInfo.ArgumentList.Add("--");
        }

        foreach (var argument in dabArguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        return startInfo;
    }

    private void AppendOutput(BoundedOutput output, string stream, string? value, DataApiBuilderOptions options)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return;
        }

        var scrubbed = ScrubSecrets(StripAnsi(value.Trim()), options.EnvironmentVariables.Values);
        output.Add($"{stream}: {scrubbed}");
        OutputReceived?.Invoke(this, new DataApiBuilderOutputEventArgs(stream, scrubbed));
    }

    private void HandleExited(RunningDab runtime)
    {
        DataApiBuilderStatus status;
        lock (_sync)
        {
            if (!ReferenceEquals(_running, runtime))
            {
                return;
            }

            _running = null;
            status = BuildStatus(runtime, runtime.Process.ExitCode == 0 ? DataApiBuilderState.Stopped : DataApiBuilderState.Failed) with
            {
                Running = false,
                ExitCode = runtime.Process.ExitCode,
                ErrorCode = runtime.Process.ExitCode == 0 ? null : DataApiBuilderErrorCode.ProcessExited,
                ErrorMessage = runtime.Process.ExitCode == 0 ? null : $"DAB exited with code {runtime.Process.ExitCode}."
            };
            _lastStatus = status;
        }

        if (status.State == DataApiBuilderState.Failed)
        {
            Failed?.Invoke(this, new DataApiBuilderFailedEventArgs(status.ErrorCode ?? DataApiBuilderErrorCode.ProcessExited, status.ErrorMessage ?? "DAB exited.", null, status));
        }
        else
        {
            Stopped?.Invoke(this, status);
        }
    }

    private DataApiBuilderStatus RememberFailure(DataApiBuilderErrorCode code, string message, Exception? exception, string? baseUrl, string? output)
    {
        var status = new DataApiBuilderStatus
        {
            State = DataApiBuilderState.Failed,
            Running = false,
            BaseUrl = baseUrl,
            HealthUrl = baseUrl is null ? null : CombineUrl(baseUrl, "health"),
            RestUrl = baseUrl is null ? null : CombineUrl(baseUrl, "api"),
            GraphQlUrl = baseUrl is null ? null : CombineUrl(baseUrl, "graphql"),
            McpUrl = baseUrl is null ? null : CombineUrl(baseUrl, "mcp"),
            EmbedUrl = baseUrl is null ? null : CombineUrl(baseUrl, "embed"),
            SwaggerUrl = baseUrl is null ? null : CombineUrl(baseUrl, "swagger"),
            ErrorCode = code,
            ErrorMessage = message,
            Output = output
        };

        lock (_sync)
        {
            _lastStatus = status;
        }

        _logger.LogWarning(exception, "Data API builder failed: {Message}", message);
        Failed?.Invoke(this, new DataApiBuilderFailedEventArgs(code, message, exception, status));
        return status;
    }

    private static DataApiBuilderStatus BuildStatus(RunningDab runtime, DataApiBuilderState state)
    {
        var running = state is DataApiBuilderState.Starting or DataApiBuilderState.Running;
        return new DataApiBuilderStatus
        {
            State = state,
            Running = running,
            BaseUrl = runtime.BaseUrl,
            HealthUrl = CombineUrl(runtime.BaseUrl, "health"),
            RestUrl = CombineUrl(runtime.BaseUrl, "api"),
            GraphQlUrl = CombineUrl(runtime.BaseUrl, "graphql"),
            McpUrl = CombineUrl(runtime.BaseUrl, "mcp"),
            EmbedUrl = CombineUrl(runtime.BaseUrl, "embed"),
            SwaggerUrl = CombineUrl(runtime.BaseUrl, "swagger"),
            StartedAt = runtime.StartedAt,
            Output = runtime.Output.ToString()
        };
    }

    private static string BuildCliMissingMessage(DataApiBuilderOptions options)
    {
        return options.UseDotNetToolRun
            ? "DAB CLI was not found in the local tool manifest. Run: dotnet tool restore"
            : $"DAB CLI was not found. Install it with: dotnet tool install --global Microsoft.DataApiBuilder --version {options.MinimumVersion}";
    }

    private static Version? ParseVersion(string value)
    {
        var match = Regex.Match(value, @"(?<version>\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)");
        if (!match.Success)
        {
            return null;
        }

        var core = match.Groups["version"].Value.Split(['-', '+'], 2)[0];
        return Version.TryParse(core, out var version) ? version : null;
    }

    private static int GetAvailableDataApiPort(int preferredPort)
    {
        if (IsLoopbackPortAvailable(preferredPort))
        {
            return preferredPort;
        }

        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        return ((IPEndPoint)listener.LocalEndpoint).Port;
    }

    private static bool IsLoopbackPortAvailable(int port)
    {
        try
        {
            using var listener = new TcpListener(IPAddress.Loopback, port);
            listener.Start();
            return true;
        }
        catch (SocketException)
        {
            return false;
        }
    }

    private static string CombineUrl(string baseUrl, string path) => $"{baseUrl.TrimEnd('/')}/{path.TrimStart('/')}";

    private static string ScrubSecrets(string value, IEnumerable<string?> secrets)
    {
        var scrubbed = value;
        foreach (var secret in secrets.Where(s => !string.IsNullOrWhiteSpace(s) && s.Length > 3))
        {
            scrubbed = scrubbed.Replace(secret!, "********", StringComparison.Ordinal);
        }

        return scrubbed;
    }

    private static string StripAnsi(string value)
    {
        return Regex.Replace(value, "\\x1B\\[[0-?]*[ -/]*[@-~]", string.Empty);
    }

    private sealed record RunningDab(Process Process, DataApiBuilderOptions Options, string BaseUrl, BoundedOutput Output, DateTimeOffset StartedAt);

    private sealed record VersionCheckResult(bool Success, Version? Version, DataApiBuilderErrorCode? ErrorCode, string? ErrorMessage, Exception? Exception, string? Output)
    {
        public static VersionCheckResult SuccessResult(Version? version, string output) => new(true, version, null, null, null, output);
        public static VersionCheckResult Fail(DataApiBuilderErrorCode code, string message, Exception? exception, string? output) => new(false, null, code, message, exception, output);
    }

    private sealed class BoundedOutput
    {
        private readonly int _maxLines;
        private readonly Queue<string> _lines = new();
        private readonly object _sync = new();

        public BoundedOutput(int maxLines)
        {
            _maxLines = Math.Max(10, maxLines);
        }

        public void Add(string line)
        {
            lock (_sync)
            {
                _lines.Enqueue($"{DateTimeOffset.Now:HH:mm:ss} {line}");
                while (_lines.Count > _maxLines)
                {
                    _lines.Dequeue();
                }
            }
        }

        public override string ToString()
        {
            lock (_sync)
            {
                return string.Join(Environment.NewLine, _lines);
            }
        }
    }
}

public sealed record DataApiBuilderOptions
{
    public required string ConfigPath { get; init; }
    public int? Port { get; init; }
    public string? WorkingDirectory { get; init; }
    public string DabExecutablePath { get; init; } = DataApiBuilderService.DefaultExecutable;
    public bool UseDotNetToolRun { get; init; }
    public Version MinimumVersion { get; init; } = DataApiBuilderService.DefaultMinimumVersion;
    public Dictionary<string, string?> EnvironmentVariables { get; init; } = new(StringComparer.OrdinalIgnoreCase);
    public TimeSpan StartupTimeout { get; init; } = TimeSpan.FromSeconds(30);
    public string LogLevel { get; init; } = "Information";
    public int MaxOutputLines { get; init; } = 200;

    public DataApiBuilderOptions Normalize()
    {
        var configPath = Path.GetFullPath(ConfigPath);
        return this with
        {
            ConfigPath = configPath,
            WorkingDirectory = Path.GetFullPath(WorkingDirectory ?? Path.GetDirectoryName(configPath) ?? AppContext.BaseDirectory),
            DabExecutablePath = string.IsNullOrWhiteSpace(DabExecutablePath) ? DataApiBuilderService.DefaultExecutable : DabExecutablePath,
            MinimumVersion = MinimumVersion ?? DataApiBuilderService.DefaultMinimumVersion,
            StartupTimeout = StartupTimeout <= TimeSpan.Zero ? TimeSpan.FromSeconds(30) : StartupTimeout,
            LogLevel = string.IsNullOrWhiteSpace(LogLevel) ? "Information" : LogLevel,
            MaxOutputLines = MaxOutputLines < 10 ? 10 : MaxOutputLines
        };
    }
}

public sealed record DataApiBuilderStatus
{
    public DataApiBuilderState State { get; init; }
    public bool Running { get; init; }
    public string? BaseUrl { get; init; }
    public string? HealthUrl { get; init; }
    public string? RestUrl { get; init; }
    public string? GraphQlUrl { get; init; }
    public string? McpUrl { get; init; }
    public string? EmbedUrl { get; init; }
    public string? SwaggerUrl { get; init; }
    public DateTimeOffset? StartedAt { get; init; }
    public int? ExitCode { get; init; }
    public DataApiBuilderErrorCode? ErrorCode { get; init; }
    public string? ErrorMessage { get; init; }
    public string? Output { get; init; }

    public static DataApiBuilderStatus Stopped() => new() { State = DataApiBuilderState.Stopped, Running = false };
}

public enum DataApiBuilderState
{
    Stopped,
    Starting,
    Running,
    Failed
}

public enum DataApiBuilderErrorCode
{
    ConfigMissing,
    CliMissing,
    CliVersionTooOld,
    ProcessStartFailed,
    PortUnavailable,
    ExitedDuringStartup,
    StartupTimedOut,
    StartCanceled,
    ProcessExited
}

public sealed class DataApiBuilderStartingEventArgs : EventArgs
{
    public DataApiBuilderStartingEventArgs(DataApiBuilderOptions options)
    {
        Options = options;
    }

    public DataApiBuilderOptions Options { get; }
    public bool Cancel { get; set; }
    public string? CancelReason { get; set; }
}

public sealed record DataApiBuilderFailedEventArgs(DataApiBuilderErrorCode ErrorCode, string Message, Exception? Exception, DataApiBuilderStatus Status);

public sealed record DataApiBuilderOutputEventArgs(string Stream, string Message);
