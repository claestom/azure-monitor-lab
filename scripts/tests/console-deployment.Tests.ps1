$ErrorActionPreference = 'Stop'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$root = Join-Path ([IO.Path]::GetTempPath()) ('console-entry-test-' + [guid]::NewGuid().ToString('N'))
$directory = Join-Path $root 'scripts'
$null = New-Item -ItemType Directory -Path $directory -Force
$fixture = @{
  Subscription = [guid]::NewGuid(); Tenant = [guid]::NewGuid(); Operator = [guid]::NewGuid()
  Events = [Collections.Generic.List[string]]::new(); FailSetup = $false; BadTenant = $false; Uploads = 0
  OperatorRoles = 0; DeploymentWrites = 0
  DefaultOperator = $false; CurrentUserLookups = 0; ExistingOperatorRole = $false; CurrentUserUnavailable = $false
}
foreach ($name in @('deploy.ps1', 'deploy-webapp.ps1', 'post-staged-deploy.ps1', 'post-cloud-shell-deploy.ps1')) {
  Copy-Item -LiteralPath (Join-Path $source "scripts/$name") -Destination $directory
}
@{ expectedSubscriptionId = [guid]::NewGuid(); expectedTenantId = [guid]::NewGuid() } | ConvertTo-Json | Set-Content (Join-Path $root '.azure-target.json')
@'
param($PublishDirectory, $ResourceGroup, $SubscriptionId, $TenantId, $CentralLawName, $SreModelEndpoint, $SreModelDeployment, [switch]$BundleSreMcp)
if ($SubscriptionId -ne $fixture.Subscription -or $TenantId -ne $fixture.Tenant) { throw 'Wrong package target.' }
'{}' | Set-Content (Join-Path $PublishDirectory 'lab-console.json')
$fixture.Events.Add('package')
'@ | Set-Content (Join-Path $directory 'prepare-webapp-package.ps1')
@'
param($SubscriptionId, $TenantId, $ResourceGroup, $WebAppName, $ConsoleConfigPath, $AllowedUserObjectIds)
$operatorsMatch = if ($fixture.DefaultOperator) { -not $AllowedUserObjectIds } else { $AllowedUserObjectIds[0] -eq $fixture.Operator }
if ($SubscriptionId -ne $fixture.Subscription -or $TenantId -ne $fixture.Tenant -or -not $operatorsMatch -or -not (Test-Path $ConsoleConfigPath)) { throw 'Wrong automatic setup inputs.' }
$fixture.Events.Add('initialize')
if ($fixture.FailSetup) { throw 'Bootstrap failed.' }
'@ | Set-Content (Join-Path $directory 'initialize-webapp-console.ps1')
@'
param([guid]$SubscriptionId, [guid]$TenantId, $ResourceGroup, $WebAppName, $AksName, $WebAppHost, $CentralLawName, $ConsoleOperatorObjectIds, $AppInsightsConnectionString)
if ($SubscriptionId -ne $fixture.Subscription -or $TenantId -ne $fixture.Tenant -or $ConsoleOperatorObjectIds[0] -ne $fixture.Operator) { throw 'Deployment wrapper lost the verified target or operator inputs.' }
$fixture.Events.Add('post-deploy')
'@ | Set-Content (Join-Path $directory 'post-deploy.ps1')
foreach ($name in @('setup-health-model.ps1', 'setup-slis.ps1')) {
  'param($ResourceGroup, $SubscriptionId)' | Set-Content (Join-Path $directory $name)
}
foreach ($name in @('create-summary-rule.ps1', 'send-release-annotation.ps1')) {
  'param($ResourceGroup, $WorkspaceName, $Name, $Category)' | Set-Content (Join-Path $directory $name)
}
$null = New-Item -ItemType Directory -Path (Join-Path $root 'workloads') -Force
Copy-Item -LiteralPath (Join-Path $source 'workloads/k8s') -Destination (Join-Path $root 'workloads') -Recurse

function dotnet {
  $global:LASTEXITCODE = 0
  if ($args[0] -ne 'publish') { throw 'Unexpected dotnet command.' }
  $publish = $args[[Array]::IndexOf($args, '-o') + 1]
  $null = New-Item -ItemType Directory -Path (Join-Path $publish 'wwwroot') -Force
  'offline-package' | Set-Content (Join-Path $publish 'AmlabHello.dll')
  'offline-page' | Set-Content (Join-Path $publish 'wwwroot/index.html')
  $fixture.Events.Add('publish')
}

function az {
  $global:LASTEXITCODE = 0
  switch ($args[0..1] -join ' ') {
    'account set' {
      if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription.ToString()) { throw 'A stale local target overrode the selected subscription.' }
      return
    }
    'account show' { return @{ id = $fixture.Subscription; tenantId = $(if ($fixture.BadTenant) { [guid]::NewGuid() } else { $fixture.Tenant }) } | ConvertTo-Json }
    'group create' { $fixture.DeploymentWrites++; return '{}' }
    'provider show' { return 'Registered' }
    'deployment group' {
      if ($args[2] -eq 'create') { $fixture.DeploymentWrites++; return }
      if ($args[2] -ne 'show') { throw 'Unexpected deployment command.' }
      return @{
        webAppName = @{ value = 'app-amlab-test' }; webAppDefaultHost = @{ value = 'app-amlab-test.azurewebsites.net' }
        aksName = @{ value = 'aks-amlab' }; centralLawName = @{ value = 'law-amlab-central-test' }
        grafanaEndpoint = @{ value = 'https://example.com' }; workbookId = @{ value = 'test-workbook' }
        linuxVmNameOut = @{ value = 'vm-amlab-lin' }; windowsVmNameOut = @{ value = 'vm-amlab-win' }
      } | ConvertTo-Json -Depth 3
    }
    'monitor log-analytics' {
      if (($args[2..3] -join ' ') -ne 'workspace show') { throw 'Unexpected workspace command.' }
      return "/subscriptions/$($fixture.Subscription)/resourceGroups/test-rg/providers/Microsoft.OperationalInsights/workspaces/law-amlab-central-test"
    }
    'monitor diagnostic-settings' {
      if (($args[2..3] -join ' ') -eq 'subscription list') { return '' }
      if (($args[2..3] -join ' ') -ne 'subscription create') { throw 'Unexpected Activity Log command.' }
      $fixture.DeploymentWrites++
      return
    }
    'webapp show' { return '{"kind":"app,linux","host":"app-amlab-test.azurewebsites.net"}' }
    'webapp config' {
      if ($args[2] -eq 'show') { return 'DOTNETCORE|8.0' }
      if ($args -notcontains '--subscription') { throw 'An app write did not specify its subscription.' }
      return
    }
    'webapp deploy' {
      if (($fixture.Events -join ',') -ne 'publish,package,initialize') { throw 'Code was deployed before automatic console setup.' }
      if (-not (Test-Path $args[[Array]::IndexOf($args, '--src-path') + 1])) { throw 'The app package was not created.' }
      $fixture.Uploads++
      return
    }
    'resource list' {
      if ($args -contains 'Microsoft.Insights/dataCollectionRules') { return '[{"id":"test-dcr","name":"dcr-amlab-customlogs"}]' }
      if ($args -contains '[0].id') { return 'test-component' }
      return '[{"name":"app-amlab-test","type":"Microsoft.Web/sites"},{"name":"aks-amlab","type":"Microsoft.ContainerService/managedClusters"},{"name":"law-amlab-central-test","type":"Microsoft.OperationalInsights/workspaces"},{"name":"appi-amlab","id":"test-component","type":"Microsoft.Insights/components"}]'
    }
    'resource show' { return 'offline-connection' }
    'aks get-credentials' { if ($args -notcontains '--subscription') { throw 'Kubernetes discovery lost its subscription.' }; return }
    'role assignment' {
      if ($args -notcontains '--subscription') { throw 'Operator access lost its subscription.' }
      if ($args[2] -eq 'list') {
        $assignments = @(@{ principalId = [guid]::NewGuid().ToString(); scope = 'test-dcr' })
        if ($fixture.ExistingOperatorRole) { $assignments += @{ principalId = $fixture.Operator.ToString(); scope = 'test-dcr' } }
        return ConvertTo-Json -InputObject $assignments -Compress
      }
      if ($args[[Array]::IndexOf($args, '--assignee-object-id') + 1] -ne $fixture.Operator.ToString() -or $args -notcontains 'User') { throw 'Operator access targeted the deployment service principal.' }
      $fixture.OperatorRoles++
      return
    }
    'rest --method' {
      if ($args[2] -ne 'get' -or $args -notcontains 'https://graph.microsoft.com/v1.0/me?$select=id' -or $args -notcontains '--subscription') { throw 'Unexpected operator discovery request.' }
      if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription.ToString()) { throw 'Operator discovery lost the verified subscription.' }
      $fixture.CurrentUserLookups++
      if ($fixture.CurrentUserUnavailable) { $global:LASTEXITCODE = 1; return '{}' }
      return @{ id = $fixture.Operator.ToString() } | ConvertTo-Json
    }
    default { throw 'Unexpected native Azure call.' }
  }
}

function Start-Sleep { }
function Invoke-WebRequest { param($Uri, [switch]$UseBasicParsing, $TimeoutSec); return @{ StatusCode = 200 } }
function kubectl { $global:LASTEXITCODE = 0; if ($args[0] -eq 'get') { return '203.0.113.10' } }

try {
  $parameters = @{ SubscriptionId = $fixture.Subscription; TenantId = $fixture.Tenant; ResourceGroup = 'test-rg'; WebAppName = 'app-amlab-test'; ConsoleOperatorObjectIds = @($fixture.Operator) }
  & (Join-Path $directory 'deploy-webapp.ps1') @parameters -WhatIf
  if ($fixture.Events.Count -or $fixture.Uploads) { throw 'WhatIf performed deployment work.' }
  & (Join-Path $directory 'deploy-webapp.ps1') @parameters | Out-Null
  if ($fixture.Uploads -ne 1) { throw 'Successful app deployment did not upload its package.' }
  foreach ($failure in @('FailSetup', 'BadTenant')) {
    $fixture.Events.Clear()
    $fixture[$failure] = $true
    $rejected = $false
    try { & (Join-Path $directory 'deploy-webapp.ps1') @parameters | Out-Null } catch { $rejected = $true }
    if (-not $rejected -or $fixture.Uploads -ne 1) { throw 'An incomplete console was published.' }
    $fixture[$failure] = $false
  }
  foreach ($name in @('post-staged-deploy.ps1', 'post-cloud-shell-deploy.ps1')) {
    $fixture.Events.Clear()
    & (Join-Path $directory $name) -SubscriptionId $fixture.Subscription -ResourceGroup test-rg -ConsoleOperatorObjectIds @($fixture.Operator) | Out-Null
    if (($fixture.Events -join ',') -ne 'post-deploy') { throw 'Deployment completion did not invoke the shared console path exactly once.' }
  }
  @{ expectedSubscriptionId = $fixture.Subscription; expectedTenantId = $fixture.Tenant } | ConvertTo-Json | Set-Content (Join-Path $root '.azure-target.json')
  @'
param($ResourceGroup, [guid]$SubscriptionId)
if ($SubscriptionId -ne $fixture.Subscription) { throw 'One-shot SLI setup lost the verified subscription.' }
'@ | Set-Content (Join-Path $directory 'setup-slis.ps1')
  foreach ($inheritedAccount in @($null, [pscustomobject]@{ id = [guid]::NewGuid(); tenantId = [guid]::NewGuid() })) {
    $active = $inheritedAccount
    $fixture.Events.Clear()
    $fixture.DeploymentWrites = 0
    & (Join-Path $directory 'deploy.ps1') -ResourceGroup test-rg -SkipPreflight -ConsoleOperatorObjectIds @($fixture.Operator) | Out-Null
    if (($fixture.Events -join ',') -ne 'post-deploy' -or $fixture.DeploymentWrites -ne 3) { throw 'One-shot deployment did not complete its verified account handoff.' }
  }
  $fixture.BadTenant = $true
  $fixture.Events.Clear()
  $fixture.DeploymentWrites = 0
  $rejected = $false
  try { & (Join-Path $directory 'deploy.ps1') -ResourceGroup test-rg -SkipPreflight | Out-Null }
  catch { $rejected = $_.Exception.Message -like 'BLOCKED:*' }
  if (-not $rejected -or $fixture.DeploymentWrites -or $fixture.Events.Count) { throw 'One-shot account mismatch did not stop before deployment.' }
  $fixture.BadTenant = $false
  $postDeploy = Get-Content -LiteralPath (Join-Path $source 'scripts/post-deploy.ps1') -Raw
  if ($postDeploy.IndexOf("'initialize-webapp-console.ps1'") -lt 0 -or $postDeploy.IndexOf("'initialize-webapp-console.ps1'") -gt $postDeploy.IndexOf('Compress-Archive')) { throw 'Shared publication does not wait for automatic console setup.' }
  $fixture.Events.Clear()
  Copy-Item -LiteralPath (Join-Path $source 'scripts/post-deploy.ps1') -Destination $directory -Force
  & (Join-Path $directory 'post-deploy.ps1') @parameters -AksName aks-amlab -WebAppHost app-amlab-test.azurewebsites.net -CentralLawName law-amlab-central-test | Out-Null
  if ($fixture.Uploads -ne 2 -or $fixture.OperatorRoles -ne 1 -or $fixture.CurrentUserLookups) { throw 'Shared deployment did not publish and configure the supplied operator without interactive-user lookup.' }
  $defaultParameters = $parameters.Clone()
  $defaultParameters.Remove('ConsoleOperatorObjectIds')
  $fixture.DefaultOperator = $true
  foreach ($operatorInput in @(@{}, @{ ConsoleOperatorObjectIds = $null }, @{ ConsoleOperatorObjectIds = @() })) {
    foreach ($existingOperatorRole in @($false, $true)) {
      $fixture.ExistingOperatorRole = $existingOperatorRole
      $fixture.Events.Clear()
      $fixture.CurrentUserLookups = 0
      $fixture.OperatorRoles = 0
      $fixture.DeploymentWrites = 0
      & (Join-Path $directory 'deploy.ps1') -ResourceGroup test-rg -SkipPreflight @operatorInput | Out-Null
      $expectedRoleWrites = if ($existingOperatorRole) { 0 } else { 1 }
      if ($fixture.CurrentUserLookups -ne 1 -or $fixture.OperatorRoles -ne $expectedRoleWrites -or $fixture.DeploymentWrites -ne 3) { throw 'One-shot default operator discovery did not preserve idempotent custom-log access.' }
    }
  }
  $fixture.CurrentUserUnavailable = $true
  $fixture.Events.Clear()
  $fixture.CurrentUserLookups = 0
  $fixture.OperatorRoles = 0
  $rejected = $false
  try { & (Join-Path $directory 'post-deploy.ps1') @defaultParameters -AksName aks-amlab -WebAppHost app-amlab-test.azurewebsites.net -CentralLawName law-amlab-central-test | Out-Null }
  catch { $rejected = $_.Exception.Message -eq 'Specify console operator IDs for a noninteractive deployment.' }
  if (-not $rejected -or $fixture.OperatorRoles -or $fixture.CurrentUserLookups -ne 1) { throw 'Failed user discovery must stop without assigning custom-log access.' }
  Write-Output 'PASS: omitted, null, and empty one-shot operator lists resolve the signed-in user; existing roles are reused; failed user discovery stops without role writes.'
  Write-Output 'PASS: one-shot, app, staged, and Cloud Shell handoffs preserve account/operator inputs, bootstrap before publication, and stop on setup failures. No Azure calls.'
} finally {
  if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}