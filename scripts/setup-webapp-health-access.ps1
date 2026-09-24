[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)] [guid] $SubscriptionId,
  [Parameter(Mandatory)] [guid] $TenantId,
  [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9_.()-]+$')] [string] $ResourceGroup,
  [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9-]+$')] [string] $WebAppName,
  [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9-]+$')] [string] $CentralLawName,
  [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9-]+$')] [string] $AppInsightsLawName
)

$ErrorActionPreference = 'Stop'
if ($SubscriptionId -eq [guid]::Empty -or $TenantId -eq [guid]::Empty) { throw 'A nonempty subscription and tenant are required.' }
if (-not $PSCmdlet.ShouldProcess("$SubscriptionId/$ResourceGroup/$WebAppName", 'Grant app identity Reader on this resource group and Log Analytics Reader on the two workspaces, then enable infrastructure health')) { return }
az account set --subscription $SubscriptionId --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Could not select the expected subscription.' }
$account = az account show --query '{id:id,tenantId:tenantId}' --output json --only-show-errors | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $account.id -ne $SubscriptionId.ToString() -or $account.tenantId -ne $TenantId.ToString()) { throw 'Subscription or tenant mismatch. No resources were changed.' }
$token = az account get-access-token --subscription $SubscriptionId --resource 'https://management.azure.com/' --query accessToken --output tsv --only-show-errors
if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Could not acquire the Azure management token.' }
$scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
$webId = "$scope/providers/Microsoft.Web/sites/$WebAppName"
$centralId = "$scope/providers/Microsoft.OperationalInsights/workspaces/$CentralLawName"
$applicationId = "$scope/providers/Microsoft.OperationalInsights/workspaces/$AppInsightsLawName"

function Invoke-HealthSetup([string] $Method, [string] $Path, [object] $Body = $null) {
  if (-not $Path.StartsWith("$scope/providers/", [StringComparison]::OrdinalIgnoreCase)) { throw 'Setup path is outside the selected resource group.' }
  $request = @{ Method = $Method; Uri = "https://management.azure.com$Path"; Headers = @{ Authorization = "Bearer $token" }; TimeoutSec = 60; Verbose = $false; Debug = $false }
  if ($null -ne $Body) { $request.Body = $Body | ConvertTo-Json -Depth 15 -Compress; $request.ContentType = 'application/json' }
  try { Invoke-RestMethod @request }
  catch { throw "Health access setup request failed (HTTP $([int]$_.Exception.Response.StatusCode)). Response details suppressed to protect app settings." }
}

try {
  $web = Invoke-HealthSetup GET "${webId}?api-version=2024-11-01"
  if (-not $web.identity.principalId -or $web.identity.type -notmatch 'SystemAssigned' -or $web.identity.tenantId -ne $TenantId.ToString()) { throw 'An existing system-assigned app identity in the expected tenant is required.' }
  $auth = (Invoke-HealthSetup GET "$webId/config/authsettingsV2?api-version=2024-11-01").properties
  if (-not $auth.platform.enabled -or $auth.identityProviders.azureActiveDirectory.registration.openIdIssuer -ne "https://login.microsoftonline.com/$TenantId/v2.0") { throw 'Configure operator-restricted App Service Authentication in this tenant before enabling infrastructure health.' }
  $settingsResponse = Invoke-HealthSetup POST "$webId/config/appsettings/list?api-version=2024-11-01"
  $settings = @{}
  foreach ($property in $settingsResponse.properties.PSObject.Properties) { $settings[$property.Name] = $property.Value }
  $operators = @($settings.Keys | Where-Object { $_ -like 'LabConsole__AllowedPrincipalIds__*' } | Where-Object { $parsed = [guid]::Empty; [guid]::TryParse($settings[$_], [ref]$parsed) -and $parsed -ne [guid]::Empty })
  if ($operators.Count -eq 0) { throw 'An approved backend operator allowlist is required. Authentication was not changed.' }
  foreach ($workspaceId in @($centralId, $applicationId) | Select-Object -Unique) {
    $workspace = Invoke-HealthSetup GET "${workspaceId}?api-version=2023-09-01"
    if (-not $workspace.properties.customerId) { throw 'A selected workspace has no Logs query identity.' }
  }
  $roles = @(@{ Name = 'Reader'; Scope = $scope })
  foreach ($workspaceId in @($centralId, $applicationId) | Select-Object -Unique) { $roles += @{ Name = 'Log Analytics Reader'; Scope = $workspaceId } }
  foreach ($role in $roles) {
    $definitions = @(az role definition list --name $role.Name --subscription $SubscriptionId --query '[].id' --output json --only-show-errors | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0 -or $definitions.Count -ne 1) { throw "Could not resolve role '$($role.Name)'." }
    $role.DefinitionId = $definitions[0]
  }
  $settings['LabConsole__Health__Enabled'] = 'false'
  $null = Invoke-HealthSetup PUT "$webId/config/appsettings?api-version=2024-11-01" @{ properties = $settings }
  foreach ($role in $roles) {
    $assignments = @(az role assignment list --scope $role.Scope --subscription $SubscriptionId --output json --only-show-errors | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0) { throw 'Could not verify existing role assignments.' }
    $existing = @($assignments | Where-Object { $_.principalId -eq $web.identity.principalId -and $_.scope -ieq $role.Scope -and $_.roleDefinitionId -ieq $role.DefinitionId })
    if ($existing.Count -eq 0) {
      $null = az role assignment create --assignee-object-id $web.identity.principalId --assignee-principal-type ServicePrincipal `
        --role $role.DefinitionId --scope $role.Scope --subscription $SubscriptionId --output none --only-show-errors
      if ($LASTEXITCODE -ne 0) { throw 'Read-only role assignment failed. Infrastructure health remains disabled.' }
    }
  }
  $settings['LabConsole__ResourceGroup'] = $ResourceGroup
  $settings['LabConsole__AppService'] = $WebAppName
  $settings['LabConsole__Health__SubscriptionId'] = $SubscriptionId.ToString()
  $settings['LabConsole__Health__TenantId'] = $TenantId.ToString()
  $settings['LabConsole__Health__CentralWorkspaceResourceId'] = $centralId
  $settings['LabConsole__Health__AppInsightsWorkspaceResourceId'] = $applicationId
  $settings['LabConsole__Health__Enabled'] = 'true'
  $null = Invoke-HealthSetup PUT "$webId/config/appsettings?api-version=2024-11-01" @{ properties = $settings }
  Write-Host 'Infrastructure health read access configured. Allow RBAC propagation before refreshing the first tab. No agent execution, authentication, or workload state was changed.'
} finally { $token = $null; $settingsResponse = $null; $settings = $null }