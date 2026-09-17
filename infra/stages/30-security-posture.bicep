targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Short prefix used to build resource names.')
@minLength(3)
@maxLength(8)
param namePrefix string = 'amlab'

@description('Tag every resource with this owner.')
param ownerTag string = 'demo-lab'

var suffix = uniqueString(resourceGroup().id)
var lawCentralName = 'law-${namePrefix}-central-${take(suffix, 5)}'
var actionGroupName = 'ag-${namePrefix}-email'

var commonTags = {
  owner: ownerTag
  purpose: 'azure-monitor-lab'
  costCenter: 'demo'
}

resource lawCentral 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: lawCentralName
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-09-01-preview' existing = {
  name: actionGroupName
}

module lawRbac '../modules/law-rbac.bicep' = {
  name: 'law-rbac'
  params: {
    centralLawId: lawCentral.id
    centralLawName: lawCentral.name
    location: location
    tags: commonTags
  }
}
module securityPostureAlerts '../modules/security-posture-alerts.bicep' = {
  name: 'security-posture-alerts'
  params: {
    location: location
    workspaceId: lawCentral.id
    actionGroupId: actionGroup.id
    tags: commonTags
  }
}

