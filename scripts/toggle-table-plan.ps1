<#
.SYNOPSIS
  Toggle a LAW table between Analytics and Basic Logs plan to demo cost savings.

.DESCRIPTION
  Switches a table (default: ContainerLogV2) between Analytics and Basic plan.
  Shows the 8x cost difference and query limitations of Basic Logs.

.PARAMETER ResourceGroup
  Resource group containing the demo lab. When omitted, the script prompts for it.

.PARAMETER WorkspaceName
  Central LAW name. When omitted, the script discovers the single workspace matching
  law-amlab-central-* in the resource group.

.PARAMETER TableName
  Table to toggle (default: ContainerLogV2).

.PARAMETER Plan
  Target plan: 'Basic' or 'Analytics'.
#>
param(
  [string]$ResourceGroup,
  [string]$WorkspaceName,
  [string]$TableName = 'ContainerLogV2',

  [Parameter(Mandatory)]
  [ValidateSet('Basic', 'Analytics')]
  [string]$Plan
)

$ErrorActionPreference = 'Stop'

function Assert-NativeCommandSucceeded([string]$Operation) {
  if ($LASTEXITCODE -ne 0) {
    throw "$Operation failed with exit code $LASTEXITCODE."
  }
}

Write-Host "`n=== Table Plan Toggle ===" -ForegroundColor Cyan

if ([string]::IsNullOrWhiteSpace($ResourceGroup)) {
  $ResourceGroup = Read-Host 'Resource group containing the demo lab'
}
if ([string]::IsNullOrWhiteSpace($ResourceGroup)) {
  throw 'ResourceGroup is required.'
}

if ([string]::IsNullOrWhiteSpace($WorkspaceName)) {
  Write-Host "Discovering central Log Analytics workspace in '$ResourceGroup'..." -ForegroundColor Gray
  $workspaces = @(az monitor log-analytics workspace list -g $ResourceGroup -o json | ConvertFrom-Json)
  Assert-NativeCommandSucceeded "Listing Log Analytics workspaces in resource group '$ResourceGroup'"

  $centralWorkspaces = @($workspaces | Where-Object { $_.name -like 'law-amlab-central-*' })
  if ($centralWorkspaces.Count -eq 0) {
    throw "No workspace matching 'law-amlab-central-*' was found in resource group '$ResourceGroup'. Pass -WorkspaceName explicitly if the lab uses a different name."
  }
  if ($centralWorkspaces.Count -gt 1) {
    $workspaceNames = $centralWorkspaces.name -join ', '
    throw "Multiple workspaces matching 'law-amlab-central-*' were found in resource group '$ResourceGroup': $workspaceNames. Pass -WorkspaceName explicitly."
  }

  $WorkspaceName = $centralWorkspaces[0].name
}

# Show current plan
$current = az monitor log-analytics workspace table show `
  -g $ResourceGroup --workspace-name $WorkspaceName -n $TableName `
  --query "plan" -o tsv
Assert-NativeCommandSucceeded "Reading the plan for table '$TableName'"

Write-Host "Table:        $TableName" -ForegroundColor Gray
Write-Host "Resource group: $ResourceGroup" -ForegroundColor Gray
Write-Host "Workspace:      $WorkspaceName" -ForegroundColor Gray
Write-Host "Current plan: $current" -ForegroundColor Yellow
Write-Host "Target plan:  $Plan" -ForegroundColor Yellow

if ($current -eq $Plan) {
  Write-Host "`nTable is already on the '$Plan' plan. No change needed." -ForegroundColor Green
  return
}

# Toggle
Write-Host "`nSwitching $TableName to '$Plan'..." -ForegroundColor Yellow

$subscriptionId = az account show --query id -o tsv
Assert-NativeCommandSucceeded 'Reading the active Azure subscription'
$tableUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName/tables/$TableName`?api-version=2025-02-01"
$bodyFile = New-TemporaryFile
try {
  @{ properties = @{ plan = $Plan } } |
    ConvertTo-Json -Depth 3 -Compress |
    Set-Content -Path $bodyFile -Encoding utf8

  az rest --method PATCH --uri $tableUri --body "@$bodyFile" `
    --headers 'Content-Type=application/json' --only-show-errors -o none
  Assert-NativeCommandSucceeded "Switching table '$TableName' to the '$Plan' plan"
} finally {
  Remove-Item -Path $bodyFile -Force -ErrorAction SilentlyContinue
}

$updatedPlan = $null
for ($attempt = 1; $attempt -le 12; $attempt++) {
  $updatedPlan = az monitor log-analytics workspace table show `
    -g $ResourceGroup --workspace-name $WorkspaceName -n $TableName `
    --query "plan" -o tsv
  Assert-NativeCommandSucceeded "Verifying the plan for table '$TableName'"
  if ($updatedPlan -eq $Plan) {
    break
  }
  Start-Sleep -Seconds 5
}
if ($updatedPlan -ne $Plan) {
  throw "Table '$TableName' reported plan '$updatedPlan' after requesting '$Plan'."
}

Write-Host "Done. $TableName is now on the '$Plan' plan." -ForegroundColor Green

if ($Plan -eq 'Basic') {
  Write-Host @"

=== Basic Logs: what changes ===
  Cost:        ~8x cheaper ingestion (per-GB rate)
  Retention:   30 days interactive; total retention remains unchanged
  KQL:         Limited — only: where, extend, parse, project, search
               NO: join, union, summarize, sort, distinct, count
  Search jobs: Use search jobs for complex analytics on Basic Logs data
  Alerts:      Log search alerts work (at higher cost per evaluation)

  Try this KQL (works on Basic):
    $TableName | where LogMessage has "error" | take 10

  This KQL will FAIL on Basic:
    $TableName | summarize count() by PodName
"@ -ForegroundColor Gray
} else {
  Write-Host "`nFull KQL and 30-day interactive retention restored." -ForegroundColor Gray
}
