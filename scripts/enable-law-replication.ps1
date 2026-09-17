<#
.SYNOPSIS
  Enables cross-region replication on an existing central Log Analytics workspace.

.DESCRIPTION
  Discovers the single law-amlab-central-* workspace in the resource group and
  enables replication without redeploying the lab. Existing logs remain in the
  primary workspace; only logs ingested after activation replicate to the secondary.

.PARAMETER SubscriptionId
  Expected Azure subscription ID. The script pins and verifies this subscription.

.PARAMETER ResourceGroup
  Resource group containing the demo lab.

.PARAMETER ReplicationLocation
  Supported secondary Azure region, such as westeurope.

.PARAMETER WorkspaceName
  Optional explicit workspace name. When omitted, discovers law-amlab-central-*.

.LINK
  https://learn.microsoft.com/azure/azure-monitor/logs/workspace-replication?tabs=azure-cli#enable-workspace-replication
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [Parameter(Mandatory)] [string] $ReplicationLocation,
  [string] $WorkspaceName
)

$ErrorActionPreference = 'Stop'

function Assert-NativeCommandSucceeded([string] $Operation) {
  if ($LASTEXITCODE -ne 0) {
    throw "$Operation failed with exit code $LASTEXITCODE."
  }
}

Write-Host "`n=== Log Analytics Workspace Replication ===" -ForegroundColor Cyan

$targetFile = Join-Path $PSScriptRoot '..' '.azure-target.json'
$target = if (Test-Path $targetFile) {
  Get-Content -Raw $targetFile | ConvertFrom-Json
} else {
  $null
}
if ($target -and $SubscriptionId -ne $target.expectedSubscriptionId) {
  throw "BLOCKED: -SubscriptionId '$SubscriptionId' does not match .azure-target.json '$($target.expectedSubscriptionId)'."
}
if ($target -and $target.forbiddenSubscriptionIds -contains $SubscriptionId) {
  throw "BLOCKED: subscription '$SubscriptionId' is listed as forbidden in .azure-target.json."
}

az account set --subscription $SubscriptionId | Out-Null
Assert-NativeCommandSucceeded 'Setting the Azure subscription'
$activeAccount = az account show --query '{id:id,tenantId:tenantId}' -o json | ConvertFrom-Json
Assert-NativeCommandSucceeded 'Reading the active Azure subscription'
if ($activeAccount.id -ne $SubscriptionId) {
  throw "BLOCKED: active subscription '$($activeAccount.id)' does not match expected subscription '$SubscriptionId'."
}
if ($target -and $activeAccount.tenantId -ne $target.expectedTenantId) {
  throw "BLOCKED: active tenant '$($activeAccount.tenantId)' does not match .azure-target.json '$($target.expectedTenantId)'."
}

if ([string]::IsNullOrWhiteSpace($WorkspaceName)) {
  $workspaces = @(az monitor log-analytics workspace list -g $ResourceGroup -o json | ConvertFrom-Json)
  Assert-NativeCommandSucceeded "Listing Log Analytics workspaces in resource group '$ResourceGroup'"
  $centralWorkspaces = @($workspaces | Where-Object { $_.name -like 'law-amlab-central-*' })

  if ($centralWorkspaces.Count -eq 0) {
    throw "No workspace matching 'law-amlab-central-*' was found in resource group '$ResourceGroup'."
  }
  if ($centralWorkspaces.Count -gt 1) {
    throw "Multiple central workspaces were found: $($centralWorkspaces.name -join ', '). Pass -WorkspaceName explicitly."
  }
  $WorkspaceName = $centralWorkspaces[0].name
}

$workspace = az monitor log-analytics workspace show `
  -g $ResourceGroup -n $WorkspaceName -o json | ConvertFrom-Json
Assert-NativeCommandSucceeded "Reading Log Analytics workspace '$WorkspaceName'"

if ($workspace.replication.enabled -eq $true) {
  if ($workspace.replication.location -ieq $ReplicationLocation) {
    Write-Host "Replication is already enabled to '$ReplicationLocation'. No change needed." -ForegroundColor Green
    return
  }
  throw "Replication is already enabled to '$($workspace.replication.location)'. Disable it and wait for completion before selecting another location."
}
if ($workspace.location -ieq $ReplicationLocation) {
  throw "Replication location '$ReplicationLocation' must differ from the primary location '$($workspace.location)'."
}

$workspaceUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName`?api-version=2025-02-01"
$bodyFile = New-TemporaryFile
try {
  @{
    location = $workspace.location
    properties = @{
      replication = @{
        enabled = $true
        location = $ReplicationLocation
      }
    }
  } | ConvertTo-Json -Depth 4 | Set-Content -Path $bodyFile -Encoding utf8

  Write-Host "Workspace:          $WorkspaceName" -ForegroundColor Gray
  Write-Host "Primary location:   $($workspace.location)" -ForegroundColor Gray
  Write-Host "Secondary location: $ReplicationLocation" -ForegroundColor Gray
  Write-Host 'Enabling replication...' -ForegroundColor Yellow

  az rest --method PUT --uri $workspaceUri --body "@$bodyFile" `
    --headers 'Content-Type=application/json' --only-show-errors -o none
  Assert-NativeCommandSucceeded "Enabling replication on workspace '$WorkspaceName'"
} finally {
  Remove-Item -Path $bodyFile -Force -ErrorAction SilentlyContinue
}

$replication = az monitor log-analytics workspace show `
  -g $ResourceGroup -n $WorkspaceName `
  --query "replication.{enabled:enabled,location:location,provisioningState:provisioningState}" -o json |
  ConvertFrom-Json
Assert-NativeCommandSucceeded "Reading replication state for workspace '$WorkspaceName'"

Write-Host "Replication request accepted: enabled=$($replication.enabled), location=$($replication.location), state=$($replication.provisioningState)" -ForegroundColor Green
Write-Host 'Provisioning can take several minutes, and data types can take up to one hour to begin replicating.' -ForegroundColor Yellow
Write-Host 'Only logs ingested after replication becomes active are copied to the secondary region.' -ForegroundColor Yellow
Write-Host 'DCR-based ingestion requires each DCR to use this workspace system DCE for switchover continuity.' -ForegroundColor Yellow
Write-Host 'Review unsupported and partially supported features before relying on switchover.' -ForegroundColor Yellow
