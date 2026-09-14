<#
.SYNOPSIS
  Run the lab post-deployment setup from Azure Cloud Shell.

.DESCRIPTION
  Pins and verifies the selected subscription, discovers the portal-deployed lab
  resources, resolves Application Insights through the core ARM CLI surface, and
  runs the same workload, Health Model, and SLI helpers used by deploy.ps1.

.EXAMPLE
  ./scripts/post-cloud-shell-deploy.ps1 -SubscriptionId <subscription-id> -ResourceGroup rg-azure-monitor-lab
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [string] $NamePrefix = 'amlab',
  [guid[]] $ConsoleOperatorObjectIds
)

$ErrorActionPreference = 'Stop'
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Info($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

Write-Step "Pinning the Azure subscription"
az account set --subscription $SubscriptionId | Out-Null
$active = az account show --query "{id:id, tenantId:tenantId}" -o json | ConvertFrom-Json
if ($active.id -ne $SubscriptionId) {
  throw "Subscription guardrail failed: expected '$SubscriptionId', got '$($active.id)'."
}

Write-Info "Subscription: $($active.id)"
Write-Info "Resource group: $ResourceGroup"
Write-Info "Name prefix: $NamePrefix"

Write-Step "Discovering portal deployment resources"
$resources = az resource list -g $ResourceGroup -o json | ConvertFrom-Json
$webApp = @($resources | Where-Object {
  $_.type -ieq 'Microsoft.Web/sites' -and $_.name -like "app-$NamePrefix-*"
}) | Select-Object -First 1
$aks = @($resources | Where-Object {
  $_.type -ieq 'Microsoft.ContainerService/managedClusters' -and $_.name -ieq "aks-$NamePrefix"
}) | Select-Object -First 1
$centralLaw = @($resources | Where-Object {
  $_.type -ieq 'Microsoft.OperationalInsights/workspaces' -and $_.name -like "law-$NamePrefix-central-*"
}) | Select-Object -First 1
$appInsights = @($resources | Where-Object {
  $_.type -ieq 'Microsoft.Insights/components' -and $_.name -ieq "appi-$NamePrefix"
}) | Select-Object -First 1

if (-not $webApp) { throw "Could not find App Service 'app-$NamePrefix-<suffix>' in '$ResourceGroup'." }
if (-not $aks) { throw "Could not find AKS cluster 'aks-$NamePrefix' in '$ResourceGroup'." }
if (-not $centralLaw) { throw "Could not find central LAW 'law-$NamePrefix-central-<suffix>' in '$ResourceGroup'." }
if (-not $appInsights) { throw "Could not find Application Insights 'appi-$NamePrefix' in '$ResourceGroup'." }

$webAppHost = "$($webApp.name).azurewebsites.net"
Write-Info "Web App: $($webApp.name)"
Write-Info "AKS: $($aks.name)"
Write-Info "Central LAW: $($centralLaw.name)"
Write-Info "Application Insights: $($appInsights.name)"

Write-Step "Resolving App Insights through ARM"
$appInsightsConnectionString = az resource show `
  --ids $appInsights.id `
  --api-version 2020-02-02 `
  --query properties.ConnectionString `
  -o tsv
if ([string]::IsNullOrWhiteSpace($appInsightsConnectionString)) {
  throw "Application Insights connection string lookup returned no value."
}

Write-Step "Running App Service and AKS post-deployment setup"
& (Join-Path $PSScriptRoot 'post-deploy.ps1') `
  -SubscriptionId $active.id -TenantId $active.tenantId `
  -ResourceGroup $ResourceGroup `
  -WebAppName $webApp.name `
  -AksName $aks.name `
  -WebAppHost $webAppHost `
  -CentralLawName $centralLaw.name `
  -AppInsightsConnectionString $appInsightsConnectionString `
  -ConsoleOperatorObjectIds $ConsoleOperatorObjectIds

Write-Step "Provisioning service group and health model prerequisites"
& (Join-Path $PSScriptRoot 'setup-health-model.ps1') -ResourceGroup $ResourceGroup

Write-Step "Verifying demo SLI prerequisites and source metrics"
& (Join-Path $PSScriptRoot 'setup-slis.ps1') -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup

Write-Host @"

Cloud Shell post-deployment setup completed.

Manual SLI step still required:
  1. Open the SLI portal URL printed above.
  2. Create sli-aks-pods-running and sli-aks-pod-start-latency.
  3. Use amw-$NamePrefix and id-sli-$NamePrefix from resource group '$ResourceGroup'.
  4. Follow Scenario 46 in docs/DEMO-SCENARIOS.md for the exact fields and warm-up step.

The Deploy to Azure button and this wrapper prepare SLI prerequisites but do not
create the Microsoft.Monitor/slis preview resources.
"@ -ForegroundColor Green