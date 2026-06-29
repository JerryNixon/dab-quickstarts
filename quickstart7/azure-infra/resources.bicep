param location string
param tags object
@minLength(2)
param resourceToken string
param sqlAdminUser string
@secure()
param sqlAdminPassword string

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: 'sql-server-${resourceToken}'
  location: location
  tags: tags
  properties: {
    administratorLogin: sqlAdminUser
    administratorLoginPassword: sqlAdminPassword
  }
}

resource sqlFirewallAzure 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource sqlDb 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: 'sql-db'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: 'acr${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true
  }
}

resource cae 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'environment-${resourceToken}'
  location: location
  tags: tags
  properties: {}
}

var sqlConnString = 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},1433;Database=sql-db;User Id=${sqlAdminUser};Password=${sqlAdminPassword};Encrypt=true;TrustServerCertificate=true'

resource sqlCmdr 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'sql-commander-${resourceToken}'
  location: location
  tags: tags
  properties: {
    managedEnvironmentId: cae.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8080
      }
      secrets: [
        {
          name: 'db-conn'
          value: sqlConnString
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'sql-commander'
          image: 'docker.io/jerrynixon/sql-commander:latest'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            {
              name: 'ConnectionStrings__db'
              secretRef: 'db-conn'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 1
      }
    }
  }
}

resource webApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'web-app-${resourceToken}'
  location: location
  tags: tags
  properties: {
    managedEnvironmentId: cae.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8080
      }
      registries: [
        {
          server: acr.properties.loginServer
          username: acr.listCredentials().username
          passwordSecretRef: 'acr-password'
        }
      ]
      secrets: [
        {
          name: 'db-conn'
          value: sqlConnString
        }
        {
          name: 'acr-password'
          value: acr.listCredentials().passwords[0].value
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'web-app'
          image: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'MSSQL_CONNECTION_STRING'
              secretRef: 'db-conn'
            }
            {
              name: 'DataApiBuilder__UseDotNetToolRun'
              value: 'false'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

output resourceToken string = resourceToken
output sqlServerName string = sqlServer.name
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output acrName string = acr.name
output sqlCmdrFqdn string = sqlCmdr.properties.configuration.ingress.fqdn
output webAppName string = webApp.name
output webAppFqdn string = webApp.properties.configuration.ingress.fqdn
