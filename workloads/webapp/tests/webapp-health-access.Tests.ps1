$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot '../../../scripts/setup-webapp-health-access.ps1'
$fixture = @{
  Subscription = [guid]::NewGuid(); Tenant = [guid]::NewGuid(); Operator = [guid]::NewGuid(); Identity = [guid]::NewGuid()
  Settings = @{ ExistingSetting = 'preserve-me'; PrivateValue = [guid]::NewGuid().ToString(); 'LabConsole__Sre__Enabled' = 'true' }
  Roles = @(); Definitions = @{}; Requests = @(); Writes = @(); BadTenant = $false; AuthEnabled = $true; FailRole = $false; CliCalls = 0
}
$fixture.Settings['LabConsole__AllowedPrincipalIds__0'] = $fixture.Operator.ToString()
$parameters = @{ SubscriptionId = $fixture.Subscription; TenantId = $fixture.Tenant; ResourceGroup = 'test-rg'; WebAppName = 'test-app'; CentralLawName = 'central'; AppInsightsLawName = 'application' }
$scope = "/subscriptions/$($fixture.Subscription)/resourceGroups/test-rg"

function az {
  $fixture.CliCalls++
  $global:LASTEXITCODE = 0
  if ($args -notcontains '--subscription' -and $args[1] -ne 'show') { throw 'Explicit subscription missing.' }
  if ($args[0] -eq 'account' -and $args[1] -eq 'set') { return }
  if ($args[0] -eq 'account' -and $args[1] -eq 'show') { return @{ id = $fixture.Subscription; tenantId = $(if ($fixture.BadTenant) { [guid]::NewGuid() } else { $fixture.Tenant }) } | ConvertTo-Json }
  if ($args[0] -eq 'account' -and $args[1] -eq 'get-access-token') { if ($args -contains '--tenant') { throw 'Token flags are incompatible.' }; return 'offline-access-token' }
  if ($args[0] -ne 'role') { throw 'Only role operations are allowed.' }
  if ($args[1] -eq 'definition') {
    $name = $args[[Array]::IndexOf($args, '--name') + 1]
    if ($name -notin @('Reader', 'Log Analytics Reader')) { throw 'A non-read role was requested.' }
    if (-not $fixture.Definitions.ContainsKey($name)) { $fixture.Definitions[$name] = "/providers/Microsoft.Authorization/roleDefinitions/$([guid]::NewGuid())" }
    return ConvertTo-Json -InputObject @($fixture.Definitions[$name])
  }
  if ($args[2] -eq 'list') { return ConvertTo-Json -InputObject @($fixture.Roles) }
  if ($args[2] -eq 'create') {
    if ($fixture.FailRole) { $global:LASTEXITCODE = 1; return }
    $roleScope = $args[[Array]::IndexOf($args, '--scope') + 1]
    $definition = $args[[Array]::IndexOf($args, '--role') + 1]
    if ($roleScope -notin @($scope, "$scope/providers/Microsoft.OperationalInsights/workspaces/central", "$scope/providers/Microsoft.OperationalInsights/workspaces/application")) { throw 'Unexpected role scope.' }
    if ($roleScope -eq $scope -and $definition -ne $fixture.Definitions.Reader) { throw 'Only Reader is allowed on the resource group.' }
    if ($args -notcontains '--assignee-object-id' -or $args -notcontains 'ServicePrincipal') { throw 'Managed identity object ID required.' }
    $fixture.Roles += @{ principalId = $fixture.Identity.ToString(); roleDefinitionId = $definition; scope = $roleScope }
    return
  }
  throw 'Unexpected role operation.'
}

function Invoke-RestMethod {
  [CmdletBinding()]
  param([string] $Method, [string] $Uri, [hashtable] $Headers, [string] $Body, [string] $ContentType, [int] $TimeoutSec)
  if (-not $Uri.StartsWith("https://management.azure.com$scope/providers/")) { throw 'Out-of-scope request.' }
  $fixture.Requests += "$Method $Uri"
  if ($Uri -match '/sites/test-app\?') { return @{ identity = @{ principalId = $fixture.Identity.ToString(); tenantId = $fixture.Tenant.ToString(); type = 'SystemAssigned' } } }
  if ($Uri -match '/config/authsettingsV2') {
    if ($Method -ne 'GET') { throw 'Authentication was modified.' }
    return @{ properties = @{ platform = @{ enabled = $fixture.AuthEnabled }; identityProviders = @{ azureActiveDirectory = @{ registration = @{ openIdIssuer = "https://login.microsoftonline.com/$($fixture.Tenant)/v2.0" } } } } }
  }
  if ($Uri -match '/config/appsettings/list') { return (@{ properties = $fixture.Settings } | ConvertTo-Json -Depth 10 | ConvertFrom-Json) }
  if ($Uri -match '/config/appsettings\?' -and $Method -eq 'PUT') {
    $fixture.Settings = ($Body | ConvertFrom-Json -AsHashtable).properties
    $fixture.Writes += $fixture.Settings.Clone()
    return @{}
  }
  if ($Uri -match '/workspaces/(central|application)\?') { return @{ properties = @{ customerId = [guid]::NewGuid().ToString() } } }
  throw 'Unexpected setup endpoint.'
}

& $helper @parameters -WhatIf
if ($fixture.CliCalls -ne 0 -or $fixture.Requests.Count -ne 0) { throw 'WhatIf called Azure.' }
$private = $fixture.Settings.PrivateValue
$output = & $helper @parameters 6>&1 | Out-String
if ($output.Contains($private) -or $output.Contains('offline-access-token')) { throw 'Setup exposed protected values.' }
if ($fixture.Roles.Count -ne 3) { throw 'Expected three scoped read-only assignments.' }
if ($fixture.Settings.ExistingSetting -ne 'preserve-me' -or $fixture.Settings['LabConsole__Sre__Enabled'] -ne 'true') { throw 'Unrelated settings changed.' }
if ($fixture.Writes[0]['LabConsole__Health__Enabled'] -ne 'false' -or $fixture.Writes[-1]['LabConsole__Health__Enabled'] -ne 'true') { throw 'Enablement did not follow completed role setup.' }
if ($fixture.Settings['LabConsole__Health__CentralWorkspaceResourceId'] -ne "$scope/providers/Microsoft.OperationalInsights/workspaces/central") { throw 'Workspace scope missing.' }
& $helper @parameters | Out-Null
if ($fixture.Roles.Count -ne 3) { throw 'Repeated setup duplicated roles.' }
$fixture.FailRole = $true; $fixture.Roles = @()
$caught = $false
try { & $helper @parameters | Out-Null } catch { $caught = $true }
if (-not $caught -or $fixture.Settings['LabConsole__Health__Enabled'] -ne 'false') { throw 'Role failure did not fail closed.' }
$fixture.AuthEnabled = $false
$writes = $fixture.Writes.Count
$caught = $false
try { & $helper @parameters | Out-Null } catch { $caught = $true }
if (-not $caught -or $fixture.Writes.Count -ne $writes) { throw 'Missing authentication was not rejected before writes.' }
$fixture.BadTenant = $true
$requests = $fixture.Requests.Count
$caught = $false
try { & $helper @parameters | Out-Null } catch { $caught = $true }
if (-not $caught -or $fixture.Requests.Count -ne $requests) { throw 'Tenant mismatch did not stop before resource operations.' }
Write-Host 'PASS: health access WhatIf, scoped read roles, operator/auth preflight, protected output, settings preservation, idempotence, and fail-closed setup.'