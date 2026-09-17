@description('Application Insights resource name.')
param name string

@description('Region.')
param location string

@description('Resource ID of the Log Analytics workspace that backs this App Insights.')
param workspaceId string

@description('Resource tags.')
param tags object = {}

resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: name
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspaceId
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

output id string = appi.id
output name string = appi.name
output appId string = appi.properties.AppId
output instrumentationKey string = appi.properties.InstrumentationKey
output connectionString string = appi.properties.ConnectionString
