namespace Quickstart7.WebApp.Services;

public sealed class DataApiBuilderHostedService : IHostedService
{
    private readonly DataApiBuilderService _dab;
    private readonly IConfiguration _configuration;
    private readonly IHostEnvironment _environment;
    private readonly ILogger<DataApiBuilderHostedService> _logger;

    public DataApiBuilderHostedService(
        DataApiBuilderService dab,
        IConfiguration configuration,
        IHostEnvironment environment,
        ILogger<DataApiBuilderHostedService> logger)
    {
        _dab = dab;
        _configuration = configuration;
        _environment = environment;
        _logger = logger;
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        var section = _configuration.GetSection("DataApiBuilder");
        var configuredConfigPath = section["ConfigPath"] ?? "dab-config.json";
        var configPath = Path.IsPathRooted(configuredConfigPath)
            ? configuredConfigPath
            : Path.Combine(_environment.ContentRootPath, configuredConfigPath);

        var connectionString = _configuration["MSSQL_CONNECTION_STRING"];
        if (string.IsNullOrWhiteSpace(connectionString))
        {
            _logger.LogWarning("MSSQL_CONNECTION_STRING is not set. DAB will fail until a SQL connection string is provided.");
        }

        var startupTimeoutSeconds = int.TryParse(section["StartupTimeoutSeconds"], out var seconds) ? seconds : 30;
        var minimumVersion = Version.TryParse(section["MinimumVersion"], out var parsedVersion)
            ? parsedVersion
            : DataApiBuilderService.DefaultMinimumVersion;

        var options = new DataApiBuilderOptions
        {
            ConfigPath = configPath,
            WorkingDirectory = _environment.ContentRootPath,
            UseDotNetToolRun = bool.TryParse(section["UseDotNetToolRun"], out var useDotNetToolRun) && useDotNetToolRun,
            MinimumVersion = minimumVersion,
            StartupTimeout = TimeSpan.FromSeconds(startupTimeoutSeconds),
            LogLevel = section["LogLevel"] ?? "Information",
            EnvironmentVariables = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase)
            {
                ["MSSQL_CONNECTION_STRING"] = connectionString
            }
        };

        var status = await _dab.StartAsync(options, cancellationToken).ConfigureAwait(false);
        if (status.State == DataApiBuilderState.Failed)
        {
            _logger.LogWarning("DAB sidecar did not start: {ErrorCode} {ErrorMessage}", status.ErrorCode, status.ErrorMessage);
        }
    }

    public Task StopAsync(CancellationToken cancellationToken)
    {
        return _dab.StopAsync(cancellationToken);
    }
}
