FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY WebApp.csproj ./
RUN dotnet restore WebApp.csproj
COPY . ./
RUN dotnet publish WebApp.csproj -c Release -o /app/publish /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
RUN dotnet tool install --global Microsoft.DataApiBuilder --version 2.0.9
ENV PATH="${PATH}:/root/.dotnet/tools"
ENV ASPNETCORE_URLS=http://+:8080
ENV DataApiBuilder__UseDotNetToolRun=false
COPY --from=build /app/publish ./
EXPOSE 8080
ENTRYPOINT ["dotnet", "WebApp.dll"]
