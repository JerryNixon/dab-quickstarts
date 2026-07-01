// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

var builder = DistributedApplication.CreateBuilder(args);

var root = Path.GetFullPath(Path.Combine(builder.AppHostDirectory, ".."));
var webRoot = Path.Combine(root, "web-app");
var webProject = Path.Combine(webRoot, "WebApp.csproj");

var options = new
{
    SqlServer = "sql-server",
    SqlVolume = "sql-data",
    SqlDatabase = "TodoDb",
    SqlProject = "sql-project",
    SqlCmdr = "sql-cmdr",
    SqlCmdrImage = "latest",
    WebApp = "web-app",
    WebAppPort = 5173,
    WebAppTargetPort = 5174,
};

var sqlPassword = builder.AddParameter("sql-password", secret: true);

var sqlServer = builder
    .AddSqlServer(options.SqlServer, sqlPassword)
    .WithDataVolume(options.SqlVolume)
    .WithEnvironment("ACCEPT_EULA", "Y");

var sqlDatabase = sqlServer
    .AddDatabase(options.SqlDatabase);

var sqlDatabaseProject = builder
    .AddSqlProject<Projects.database>(options.SqlProject)
    .WithReference(sqlDatabase);

builder.AddContainer(options.SqlCmdr, "jerrynixon/sql-commander", options.SqlCmdrImage)
    .WithImageRegistry("docker.io")
    .WithHttpEndpoint(targetPort: 8080, name: "http")
    .WithEnvironment("ConnectionStrings__db", sqlDatabase)
    .WithUrls(context =>
    {
        context.Urls.Clear();
        context.Urls.Add(new() { Url = "/", DisplayText = "Commander", Endpoint = context.GetEndpoint("http") });
    })
    .WithParentRelationship(sqlDatabase)
    .WithHttpHealthCheck("/health")
    .WaitForCompletion(sqlDatabaseProject);

builder.AddExecutable(options.WebApp, "dotnet", webRoot, "run", "--project", webProject, "--no-launch-profile", "--urls", $"http://localhost:{options.WebAppTargetPort}")
    .WithHttpEndpoint(targetPort: options.WebAppTargetPort, port: options.WebAppPort, name: "http")
    .WithEnvironment("ASPNETCORE_ENVIRONMENT", "Development")
    .WithEnvironment("DOTNET_ENVIRONMENT", "Development")
    .WithEnvironment("MSSQL_CONNECTION_STRING", sqlDatabase)
    .WithUrls(context =>
    {
        context.Urls.Clear();
        context.Urls.Add(new() { Url = "/", DisplayText = "Web App", Endpoint = context.GetEndpoint("http") });
        context.Urls.Add(new() { Url = "/health", DisplayText = "DAB Health", Endpoint = context.GetEndpoint("http") });
        context.Urls.Add(new() { Url = "/swagger/", DisplayText = "DAB Swagger", Endpoint = context.GetEndpoint("http") });
        context.Urls.Add(new() { Url = "/graphql/", DisplayText = "DAB GraphQL", Endpoint = context.GetEndpoint("http") });
    })
    .WaitForCompletion(sqlDatabaseProject);

await builder.Build().RunAsync();
