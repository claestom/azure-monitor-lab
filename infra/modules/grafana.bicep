@description('Azure Managed Grafana name.')
param name string

@description('Region.')
param location string

@description('Azure Monitor Workspace resource ID to integrate (Managed Prometheus).')
param azureMonitorWorkspaceId string

@description('Optional Microsoft Entra object ID of the lab operator or group to grant Grafana Admin. Empty assigns the deployment identity; set explicitly when deploying through automation.')
param adminObjectId string = ''

@description('Resource tags.')
param tags object = {}

var adminPrincipalId = empty(adminObjectId) ? deployer().objectId : adminObjectId

resource grafana 'Microsoft.Dashboard/grafana@2024-10-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
    apiKey: 'Enabled'
    deterministicOutboundIP: 'Disabled'
    grafanaIntegrations: {
      azureMonitorWorkspaceIntegrations: [
        {
          azureMonitorWorkspaceResourceId: azureMonitorWorkspaceId
        }
      ]
    }
  }
}

// Grant Grafana's MSI Monitoring Reader on the resource group so it can query Azure Monitor.
resource roleMonitoringReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, grafana.id, 'monitoring-reader')
  properties: {
    principalId: grafana.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
    principalType: 'ServicePrincipal'
  }
}

resource deployerAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(grafana.id, adminPrincipalId, '22926164-76b3-42b3-bc55-97df8dab3e41')
  scope: grafana
  properties: {
    principalId: adminPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '22926164-76b3-42b3-bc55-97df8dab3e41')
  }
}

output id string = grafana.id
output name string = grafana.name
output endpoint string = grafana.properties.endpoint
