<#
.SYNOPSIS
  Start every startable lab resource: VMs, VMSS, AKS cluster, Web Apps.
.DESCRIPTION
  Counterpart to the nightly stop policy (which deallocates VMs / stops AKS /
  stops web apps to keep lab cost low). Idempotent: only kicks off a start on
  resources that are actually in a stopped/deallocated state.

  Resources covered:
    - Virtual Machines       (az vm start)
    - VM Scale Sets          (az vmss start)
    - AKS managed clusters   (az aks start)
    - App Service Web Apps   (az webapp start)

  By default, calls return immediately (--no-wait where supported). Pass -Wait
  to poll until every resource reaches a Running state.
  Pass -WhatIf to perform resource discovery without issuing start commands.
.EXAMPLE
  ./scripts/start-the-lab.ps1 -ResourceGroup rg-azure-monitor-lab
.EXAMPLE
  ./scripts/start-the-lab.ps1 -ResourceGroup rg-azure-monitor-lab -Wait
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [switch] $Wait,
  [int]    $TimeoutMinutes = 20
)
$ErrorActionPreference = 'Stop'
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Info($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }

# --- Subscription guardrail ----------------------------------------------------
$targetFile = Join-Path $PSScriptRoot '..' '.azure-target.json'
if (Test-Path $targetFile) {
  $target = Get-Content -Raw $targetFile | ConvertFrom-Json
  az account set --subscription $target.expectedSubscriptionId | Out-Null
  $active = az account show --query "{id:id, tenantId:tenantId}" -o json | ConvertFrom-Json
  if ($active.id -ne $target.expectedSubscriptionId -or $active.tenantId -ne $target.expectedTenantId) {
    throw "BLOCKED: not on allowed lab subscription. Aborting start-the-lab."
  }
}

# Verify the RG exists before we fan out queries.
if (-not (az group exists -n $ResourceGroup | ConvertFrom-Json)) {
  throw "Resource group '$ResourceGroup' not found in the active subscription."
}

$started = @{ vm = @(); vmss = @(); aks = @(); webapp = @() }
$skipped = @{ vm = @(); vmss = @(); aks = @(); webapp = @() }

# --- 1. Virtual Machines -------------------------------------------------------
Write-Step "Virtual Machines"
$vms = az vm list -g $ResourceGroup -d --query "[].{name:name, power:powerState}" -o json | ConvertFrom-Json
if (-not $vms) { Write-Info "no VMs in $ResourceGroup" }
foreach ($vm in $vms) {
  if ($vm.power -eq 'VM running') {
    Write-Info "$($vm.name) already running"
    $skipped.vm += $vm.name
  } else {
    if ($PSCmdlet.ShouldProcess($vm.name, 'Start virtual machine')) {
      Write-Ok  "starting $($vm.name) (was: $($vm.power))"
      az vm start -g $ResourceGroup -n $vm.name --no-wait | Out-Null
      $started.vm += $vm.name
    }
  }
}

# --- 2. VM Scale Sets ----------------------------------------------------------
Write-Step "VM Scale Sets"
$vmssPowerStateQuery = "[].{power:instanceView.statuses[?starts_with(code,'PowerState/')].code | [0]}"
$vmsses = az vmss list -g $ResourceGroup --query "[].name" -o tsv
if (-not $vmsses) { Write-Info "no VMSS in $ResourceGroup" }
foreach ($name in $vmsses) {
  # A VMSS has no single power state — count deallocated instances.
  $instances = az vmss list-instances -g $ResourceGroup -n $name --expand instanceView --query $vmssPowerStateQuery -o json | ConvertFrom-Json
  $stoppedCount = @($instances | Where-Object { $_.power -ne 'PowerState/running' }).Count
  if ($stoppedCount -eq 0) {
    Write-Info "$name all instances running"
    $skipped.vmss += $name
  } else {
    if ($PSCmdlet.ShouldProcess($name, 'Start virtual machine scale set')) {
      Write-Ok  "starting $name ($stoppedCount/$($instances.Count) instances stopped)"
      az vmss start -g $ResourceGroup -n $name --no-wait | Out-Null
      $started.vmss += $name
    }
  }
}

# --- 3. AKS clusters -----------------------------------------------------------
Write-Step "AKS clusters"
$aksClusters = az aks list -g $ResourceGroup --query "[].{name:name, power:powerState.code, prov:provisioningState}" -o json | ConvertFrom-Json
if (-not $aksClusters) { Write-Info "no AKS clusters in $ResourceGroup" }
foreach ($aks in $aksClusters) {
  if ($aks.power -eq 'Running') {
    Write-Info "$($aks.name) already Running"
    $skipped.aks += $aks.name
  } else {
    if ($PSCmdlet.ShouldProcess($aks.name, 'Start AKS cluster')) {
      Write-Ok  "starting $($aks.name) (was: $($aks.power))"
      az aks start -g $ResourceGroup -n $aks.name --no-wait | Out-Null
      $started.aks += $aks.name
    }
  }
}

# --- 4. App Service Web Apps ---------------------------------------------------
Write-Step "Web Apps"
$webapps = az webapp list -g $ResourceGroup --query "[].{name:name, state:state}" -o json | ConvertFrom-Json
if (-not $webapps) { Write-Info "no Web Apps in $ResourceGroup" }
foreach ($wa in $webapps) {
  if ($wa.state -eq 'Running') {
    Write-Info "$($wa.name) already Running"
    $skipped.webapp += $wa.name
  } else {
    if ($PSCmdlet.ShouldProcess($wa.name, 'Start web app')) {
      Write-Ok  "starting $($wa.name) (was: $($wa.state))"
      az webapp start -g $ResourceGroup -n $wa.name | Out-Null
      $started.webapp += $wa.name
    }
  }
}

if ($WhatIfPreference) {
  Write-Host 'Resource discovery completed. No start commands were issued.'
  return
}

# --- Summary -------------------------------------------------------------------
Write-Step "Summary"
$total = ($started.vm + $started.vmss + $started.aks + $started.webapp).Count
$noop  = ($skipped.vm + $skipped.vmss + $skipped.aks + $skipped.webapp).Count
Write-Host "  Started: $total  ·  Already running: $noop" -ForegroundColor Yellow

if ($total -eq 0) {
  Write-Host "`n✅ Everything was already running. Nothing to do." -ForegroundColor Green
  return
}

if (-not $Wait) {
  Write-Host "`n✅ Start commands issued. Pass -Wait to poll until all resources are running." -ForegroundColor Green
  return
}

# --- Optional: poll until Running ---------------------------------------------
Write-Step "Polling until all resources reach Running (timeout: $TimeoutMinutes min)"
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
while ((Get-Date) -lt $deadline) {
  $pending = @()

  foreach ($n in $started.vm) {
    $p = az vm get-instance-view -g $ResourceGroup -n $n --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus | [0]" -o tsv
    if ($p -ne 'VM running') { $pending += "vm/$n=$p" }
  }
  foreach ($n in $started.vmss) {
    $stoppedCount = (az vmss list-instances -g $ResourceGroup -n $n --expand instanceView --query "$vmssPowerStateQuery | [?power!='PowerState/running'] | length(@)" -o tsv)
    if ([int]$stoppedCount -gt 0) { $pending += "vmss/$n=$stoppedCount-stopped" }
  }
  foreach ($n in $started.aks) {
    $p = az aks show -g $ResourceGroup -n $n --query "powerState.code" -o tsv
    $s = az aks show -g $ResourceGroup -n $n --query "provisioningState" -o tsv
    if ($p -ne 'Running' -or $s -ne 'Succeeded') { $pending += "aks/$n=$p/$s" }
  }
  foreach ($n in $started.webapp) {
    $p = az webapp show -g $ResourceGroup -n $n --query "state" -o tsv
    if ($p -ne 'Running') { $pending += "webapp/$n=$p" }
  }

  if ($pending.Count -eq 0) {
    Write-Host "`n✅ All resources Running." -ForegroundColor Green
    return
  }
  Write-Info ("waiting on: " + ($pending -join ', '))
  Start-Sleep -Seconds 20
}
throw "Timeout after $TimeoutMinutes min. Still pending: $($pending -join ', ')"
