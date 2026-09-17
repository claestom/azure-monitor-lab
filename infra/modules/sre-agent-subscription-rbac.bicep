targetScope = 'subscription'

@description('System-assigned principal ID of the Azure SRE Agent connector identity.')
param principalId string

resource monitoringContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, principalId, '749f88d5-cbae-40b8-bcfc-e573ddc772fa')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '749f88d5-cbae-40b8-bcfc-e573ddc772fa')
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}