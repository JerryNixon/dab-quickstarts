using System.Net.Http.Headers;
using Quickstart7.WebApp.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddHttpClient("dab-proxy");
builder.Services.AddSingleton<DataApiBuilderService>();
builder.Services.AddHostedService<DataApiBuilderHostedService>();

var app = builder.Build();

app.UseDefaultFiles();
app.UseStaticFiles();

app.MapGet("/dab/status", (DataApiBuilderService dab) => Results.Json(ToPublicStatus(dab.GetStatus())));

foreach (var pattern in new[]
{
    "/health",
    "/swagger",
    "/swagger/{**path}",
    "/api/{**path}",
    "/graphql",
    "/graphql/{**path}",
    "/mcp",
    "/mcp/{**path}",
    "/embed",
    "/embed/{**path}"
})
{
    MapDabProxy(app, pattern);
}

await app.RunAsync();

static void MapDabProxy(WebApplication app, string pattern)
{
    app.MapMethods(pattern, ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"], async (HttpContext context, DataApiBuilderService dab, IHttpClientFactory httpClientFactory) =>
    {
        if (IsUiRootGet(context.Request))
        {
            context.Response.Redirect($"{context.Request.Path}/{context.Request.QueryString}", permanent: false);
            return;
        }

        var status = dab.GetStatus();
        if (!status.Running || string.IsNullOrWhiteSpace(status.BaseUrl))
        {
            context.Response.StatusCode = StatusCodes.Status503ServiceUnavailable;
            await context.Response.WriteAsJsonAsync(new
            {
                error = "Data API builder is not running.",
                status.ErrorCode,
                status.ErrorMessage
            });
            return;
        }

        var targetUrl = BuildTargetUrl(status.BaseUrl, context.Request.Path, context.Request.QueryString);
        using var request = new HttpRequestMessage(new HttpMethod(context.Request.Method), targetUrl);

        foreach (var header in context.Request.Headers)
        {
            if (string.Equals(header.Key, "Host", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (!request.Headers.TryAddWithoutValidation(header.Key, header.Value.ToArray()))
            {
                request.Content ??= new StreamContent(context.Request.Body);
                request.Content.Headers.TryAddWithoutValidation(header.Key, header.Value.ToArray());
            }
        }

        if (context.Request.ContentLength > 0 || context.Request.Headers.ContainsKey("Transfer-Encoding"))
        {
            request.Content ??= new StreamContent(context.Request.Body);
            if (!string.IsNullOrWhiteSpace(context.Request.ContentType))
            {
                request.Content.Headers.ContentType = MediaTypeHeaderValue.Parse(context.Request.ContentType);
            }
        }

        var client = httpClientFactory.CreateClient("dab-proxy");
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, context.RequestAborted);
        context.Response.StatusCode = (int)response.StatusCode;

        foreach (var header in response.Headers)
        {
            context.Response.Headers[header.Key] = header.Value.ToArray();
        }

        foreach (var header in response.Content.Headers)
        {
            context.Response.Headers[header.Key] = header.Value.ToArray();
        }

        context.Response.Headers.Remove("transfer-encoding");
        await response.Content.CopyToAsync(context.Response.Body, context.RequestAborted);
    });
}

static bool IsUiRootGet(HttpRequest request)
{
    return HttpMethods.IsGet(request.Method)
        && (request.Path.Equals("/swagger", StringComparison.OrdinalIgnoreCase)
            || request.Path.Equals("/graphql", StringComparison.OrdinalIgnoreCase)
            || request.Path.Equals("/embed", StringComparison.OrdinalIgnoreCase));
}

static string BuildTargetUrl(string baseUrl, PathString path, QueryString query) => $"{baseUrl.TrimEnd('/')}{path}{query}";

static object ToPublicStatus(DataApiBuilderStatus status)
{
    return new
    {
        state = status.State.ToString(),
        status.Running,
        accessMode = "same-origin proxy",
        status.BaseUrl,
        healthUrl = "/health",
        restUrl = "/api/Todos",
        graphqlUrl = "/graphql/",
        mcpUrl = "/mcp",
        embedUrl = "/embed/",
        swaggerUrl = "/swagger/",
        status.StartedAt,
        status.ExitCode,
        errorCode = status.ErrorCode?.ToString(),
        status.ErrorMessage,
        output = LastLines(status.Output, 12)
    };
}

static string? LastLines(string? value, int count)
{
    if (string.IsNullOrWhiteSpace(value))
    {
        return value;
    }

    var lines = value.Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries);
    return string.Join(Environment.NewLine, lines.TakeLast(count));
}
