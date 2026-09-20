<#
.SYNOPSIS
  Tear the lab down: remove monitoring dependencies, then delete the resource group.
#>
[CmdletBinding()]
param(
  [string] $ResourceGroup = 'rg-azure-monitor-lab',
  [switch] $Yes
)
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ResourceGroup)) {
  throw 'ResourceGroup cannot be empty.'
}

function Remove-MatchingResourceGroups {
  param([string[]] $Names)

  foreach ($name in $Names) {
    Write-Host "Deleting $name ..." -ForegroundColor Yellow
    az group delete -n $name --yes --no-wait
    if ($LASTEXITCODE -ne 0) {
      throw "Azure CLI failed to submit deletion for resource group '$name'."
    }
  }

  Write-Host "Delete requests accepted (running in background)." -ForegroundColor Green
  Write-Host "Verify completion with:" -ForegroundColor Green
  $Names | ForEach-Object { Write-Host "  az group exists -n '$_'" -ForegroundColor Green }
}

# Subscription guardrail
$targetFile = Join-Path $PSScriptRoot '..' '.azure-target.json'
if (Test-Path $targetFile) {
  $target = Get-Content -Raw $targetFile | ConvertFrom-Json
  az account set --subscription $target.expectedSubscriptionId | Out-Null
  $active = az account show --query "{id:id, tenantId:tenantId}" -o json | ConvertFrom-Json
  if ($active.id -ne $target.expectedSubscriptionId -or $active.tenantId -ne $target.expectedTenantId) {
    throw "BLOCKED: not on allowed lab subscription. Aborting teardown."
  }
}

# Include Azure-managed and auxiliary resource groups whose names contain the
# complete requested RG name, such as MC_<rg>_<aks>_<region>.
$allResourceGroupNames = @(az group list --query '[].name' -o json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) {
  throw 'Failed to list resource groups for teardown discovery.'
}
$resourceGroupsToDelete = @(
  $allResourceGroupNames |
    Where-Object { $_.IndexOf($ResourceGroup, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 } |
    Sort-Object { if ($_ -ieq $ResourceGroup) { 0 } else { 1 } }, { $_ }
)

if ($resourceGroupsToDelete.Count -eq 0) {
  Write-Host "No resource groups contain '$ResourceGroup'. Nothing to delete." -ForegroundColor Yellow
  return
}

if (-not $Yes) {
  Write-Host "The following resource groups contain '$ResourceGroup' and will be deleted:" -ForegroundColor Yellow
  $resourceGroupsToDelete | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
  $confirm = Read-Host 'Type DELETE to confirm deletion of every resource group listed above'
  if ($confirm -ne 'DELETE') { Write-Host "Aborted." -ForegroundColor Yellow; return }
} else {
  Write-Host "Deleting resource groups whose names contain '$ResourceGroup':" -ForegroundColor Yellow
  $resourceGroupsToDelete | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}

$primaryResourceGroupExists = @($allResourceGroupNames | Where-Object { $_ -ieq $ResourceGroup }).Count -gt 0
if (-not $primaryResourceGroupExists) {
  Write-Host "The original resource group no longer exists; deleting matched auxiliary resource groups directly." -ForegroundColor Yellow
  Remove-MatchingResourceGroups -Names $resourceGroupsToDelete
  return
}

# Delete billable SRE Agent resources explicitly before the asynchronous RG delete.
$sreAgents = @(az resource list -g $ResourceGroup --resource-type Microsoft.App/agents -o json | ConvertFrom-Json)
foreach ($sreAgent in $sreAgents) {
  Write-Host "Deleting SRE Agent $($sreAgent.name) before resource-group cleanup ..." -ForegroundColor Yellow
  az resource delete --ids $sreAgent.id --api-version 2025-05-01-preview
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to delete SRE Agent '$($sreAgent.name)'. Stop before deleting the resource group and verify the agent manually to avoid continued billing."
  }
}

# Remove dependencies that can prevent Azure from deleting the monitoring estate.
# The final RG deletion remains --no-wait.
Write-Host "Removing LAW replication, DCR associations, DCRs, and DCEs ..." -ForegroundColor Yellow

$workspaces = az resource list -g $ResourceGroup --resource-type Microsoft.OperationalInsights/workspaces -o json | ConvertFrom-Json
foreach ($workspace in @($workspaces)) {
  # az resource list returns a shallow resource projection; fetch the workspace
  # before checking replication so the nested property is not missed.
  $workspaceDetails = az resource show --ids $workspace.id --api-version 2025-02-01 -o json | ConvertFrom-Json
  if ($workspaceDetails.properties.replication.enabled -eq $true) {
    Write-Host "  Disabling replication on $($workspace.name)" -ForegroundColor DarkGray
    az monitor log-analytics workspace update -g $ResourceGroup -n $workspace.name --replication-enabled false --only-show-errors | Out-Null
  }
}

$dcrAssociations = @(az resource list -g $ResourceGroup --resource-type Microsoft.Insights/dataCollectionRuleAssociations -o json | ConvertFrom-Json)

# Workspace and resource-scoped associations are child resources, so the RG-level
# resource list can omit them (notably the LAW microsoft-default association).
$allResources = az resource list -g $ResourceGroup -o json | ConvertFrom-Json
foreach ($resource in @($allResources)) {
  $nestedErrorFile = New-TemporaryFile
  $previousNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
  try {
    $PSNativeCommandUseErrorActionPreference = $false
    $nestedJson = az rest --method get --url "$($resource.id)/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=2023-03-11" 2> $nestedErrorFile.FullName
    $nestedExitCode = $LASTEXITCODE
    $nestedError = Get-Content -LiteralPath $nestedErrorFile.FullName -Raw
  } finally {
    $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
    Remove-Item -LiteralPath $nestedErrorFile.FullName -Force
  }
  if ($nestedExitCode -ne 0) {
    $nestedErrorCode = ''
    if ($nestedError -match '(?ms)^\s*ERROR:\s*[^\{\r\n]*(?<body>\{.*\})\)\s*$') {
      try { $nestedErrorCode = ($Matches.body | ConvertFrom-Json).error.code } catch { }
    } elseif ($nestedError -match '(?m)^\s*ERROR:\s*\((?<code>[A-Za-z0-9]+)\)') {
      $nestedErrorCode = $Matches.code
    } elseif ($nestedError -match '(?m)^\s*ERROR:\s*Not Found\s*$') {
      $nestedErrorCode = 'NotFound'
    }
    if ($nestedErrorCode -in @('UnsupportedResourceType', 'UnsupportedFeature', 'ResourceNotFound', 'ParentResourceNotFound', 'NotFound')) { continue }
    throw "DCR association discovery failed for '$($resource.id)' (exit code $nestedExitCode). Details:`n$nestedError"
  }
  if (-not [string]::IsNullOrWhiteSpace($nestedJson)) {
    $nested = $nestedJson | ConvertFrom-Json
    $dcrAssociations += @($nested.value)
  }
}

$associationIds = @($dcrAssociations | Where-Object { $_.id } | Select-Object -ExpandProperty id -Unique)
foreach ($associationId in $associationIds) {
  Write-Host "  Removing DCR association $associationId" -ForegroundColor DarkGray
  az resource delete --ids $associationId --api-version 2023-03-11
}

$dcrs = az resource list -g $ResourceGroup --resource-type Microsoft.Insights/dataCollectionRules -o json | ConvertFrom-Json
foreach ($dcr in @($dcrs)) {
  Write-Host "  Removing DCR $($dcr.name)" -ForegroundColor DarkGray
  az resource delete --ids $dcr.id --api-version 2024-03-11
}

$dces = az resource list -g $ResourceGroup --resource-type Microsoft.Insights/dataCollectionEndpoints -o json | ConvertFrom-Json
foreach ($dce in @($dces)) {
  Write-Host "  Removing DCE $($dce.name)" -ForegroundColor DarkGray
  az resource delete --ids $dce.id --api-version 2023-03-11 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "    DCE is managed by Azure; it will be removed with the LAW/RG cascade." -ForegroundColor DarkGray
  }
}

# Tear down tenant-scoped artefacts FIRST (they survive RG delete otherwise and
# end up dangling against the deleted AMW). Safe + idempotent — both helper
# scripts swallow 404s.
Write-Host "Removing demo SLIs (scenario 46) ..." -ForegroundColor Yellow
$setupSli = Join-Path $PSScriptRoot 'setup-slis.ps1'
if (Test-Path $setupSli) {
  & $setupSli -ResourceGroup $ResourceGroup -Teardown
}

Write-Host "Removing service group + member relationship (scenario 45) ..." -ForegroundColor Yellow
$setupHm = Join-Path $PSScriptRoot 'setup-health-model.ps1'
if (Test-Path $setupHm) {
  & $setupHm -ResourceGroup $ResourceGroup -Teardown
}

Remove-MatchingResourceGroups -Names $resourceGroupsToDelete
