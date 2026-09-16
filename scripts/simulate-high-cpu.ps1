<#
.SYNOPSIS
  Submit a bounded 10-minute CPU simulation to both running demo VMs.
.DESCRIPTION
  Requires exactly one Linux and one Windows VM tagged purpose=azure-monitor-lab.
  Validates both VMs and their agents before submitting fixed Run Command scripts.
  Each guest targets every logical CPU, expires independently, and prevents overlap.
  Completion means both requests were submitted, not that CPU or alerts were verified.
  Cancellation does not stop a submitted guest command. No automatic retry is made.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9_().-]{1,90}$')] [string] $ResourceGroup,
  [guid] $SubscriptionId = [guid]::Empty,
  [guid] $TenantId = [guid]::Empty
)

$ErrorActionPreference = 'Stop'
function Assert-CpuCommandSucceeded([string] $Operation) {
  if ($LASTEXITCODE -ne 0) { throw "$Operation failed. No CPU command was retried." }
}

$targetFile = Join-Path $PSScriptRoot '..' '.azure-target.json'
if (Test-Path -LiteralPath $targetFile) {
  $target = Get-Content -LiteralPath $targetFile -Raw | ConvertFrom-Json
  if ($SubscriptionId -eq [guid]::Empty) { $SubscriptionId = [guid]$target.expectedSubscriptionId }
  if ($TenantId -eq [guid]::Empty) { $TenantId = [guid]$target.expectedTenantId }
}
if ($SubscriptionId -eq [guid]::Empty -or $TenantId -eq [guid]::Empty -or $ResourceGroup.EndsWith('.')) {
  throw 'An explicit lab subscription, tenant, and valid resource group are required.'
}
az account set --subscription $SubscriptionId.ToString() --only-show-errors | Out-Null
Assert-CpuCommandSucceeded 'Selecting the lab subscription'
$account = az account show --query '{id:id,tenantId:tenantId}' --output json --only-show-errors | ConvertFrom-Json
Assert-CpuCommandSucceeded 'Verifying the lab account'
if ($account.id -ne $SubscriptionId.ToString() -or $account.tenantId -ne $TenantId.ToString()) {
  throw 'BLOCKED: the active account does not match the approved lab subscription and tenant.'
}

$inventory = @(az vm list --subscription $SubscriptionId.ToString() --resource-group $ResourceGroup --output json --only-show-errors | ConvertFrom-Json)
Assert-CpuCommandSucceeded 'Discovering the demo VMs'
$vms = @($inventory | Where-Object { $_.tags.purpose -ceq 'azure-monitor-lab' })
if ($vms.Count -ne 2 -or @($vms | Where-Object { $_.storageProfile.osDisk.osType -eq 'Linux' }).Count -ne 1 -or
  @($vms | Where-Object { $_.storageProfile.osDisk.osType -eq 'Windows' }).Count -ne 1) {
  throw 'Exactly one Linux and one Windows demo VM tagged purpose=azure-monitor-lab are required. No CPU command was submitted.'
}
foreach ($vm in $vms) {
  $expectedId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/virtualMachines/$($vm.name)"
  if ($vm.id -ine $expectedId) { throw 'A discovered VM is outside the approved lab scope.' }
  $view = az vm get-instance-view --subscription $SubscriptionId.ToString() --resource-group $ResourceGroup --name $vm.name --query instanceView --output json --only-show-errors | ConvertFrom-Json
  Assert-CpuCommandSucceeded 'Checking VM and agent readiness'
  if ($view.statuses.code -notcontains 'PowerState/running' -or $view.vmAgent.statuses.code -notcontains 'ProvisioningState/succeeded') {
    throw "VM '$($vm.name)' must be running with a ready Azure VM Agent. Start the lab first. No CPU command was submitted."
  }
}
if (-not $PSCmdlet.ShouldProcess(($vms.name -join ', '), 'Submit a self-expiring 10-minute CPU load on both demo VMs via Run Command')) { return }

$linuxScript = @'
set -eu
command -v timeout >/dev/null
command -v flock >/dev/null
cpu_count=$(getconf _NPROCESSORS_ONLN)
case "$cpu_count" in ''|*[!0-9]*) exit 1 ;; esac
test "$cpu_count" -gt 0
umask 077
mkdir -p /var/lib/azure-monitor-lab
exec 9>/var/lib/azure-monitor-lab/cpu-simulation.lock
if ! flock -n 9; then
  echo 'A lab CPU simulation is already running; no additional load was started.'
  exit 0
fi
worker_pids=''
cleanup() {
  for worker_pid in $worker_pids; do kill "$worker_pid" 2>/dev/null || true; done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
worker_index=0
while [ "$worker_index" -lt "$cpu_count" ]; do
  timeout --signal=TERM --kill-after=5s 600s sh -c 'while :; do :; done' &
  worker_pids="$worker_pids $!"
  worker_index=$((worker_index + 1))
done
echo 'Lab CPU load started on all logical CPUs; each worker expires after 600 seconds.'
for worker_pid in $worker_pids; do
  worker_status=0
  wait "$worker_pid" || worker_status=$?
  case "$worker_status" in 0|124|137) ;; *) exit "$worker_status" ;; esac
done
worker_pids=''
echo 'Lab CPU load completed.'
'@

$windowsScript = @'
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;

public static class AmlabCpuSimulation
{
    public static void Run()
    {
        using (var guard = new Mutex(false, @"Global\AzureMonitorLabCpuSimulation"))
        {
            bool acquired;
            try { acquired = guard.WaitOne(0); }
            catch (AbandonedMutexException) { acquired = true; }
            if (!acquired)
            {
                Console.WriteLine("A lab CPU simulation is already running; no additional load was started.");
                return;
            }
            try
            {
                var clock = Stopwatch.StartNew();
                var workers = new List<Thread>();
                for (var workerIndex = 0; workerIndex < Environment.ProcessorCount; workerIndex++)
                {
                    var worker = new Thread(() =>
                    {
                        while (clock.Elapsed.TotalSeconds < 600) { Thread.SpinWait(100000); }
                    });
                    worker.IsBackground = true;
                    workers.Add(worker);
                    worker.Start();
                }
                Console.WriteLine("Lab CPU load started on all logical CPUs; expires after 600 seconds.");
                foreach (var worker in workers) { worker.Join(); }
                Console.WriteLine("Lab CPU load completed.");
            }
            finally { guard.ReleaseMutex(); }
        }
    }
}
"@
[AmlabCpuSimulation]::Run()
'@

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('amlab-cpu-' + [guid]::NewGuid().ToString('N'))
$submitted = [Collections.Generic.List[string]]::new()
try {
  $null = New-Item -ItemType Directory -Path $temporary
  foreach ($vm in $vms) {
    $linuxTarget = $vm.storageProfile.osDisk.osType -eq 'Linux'
    $commandId = if ($linuxTarget) { 'RunShellScript' } else { 'RunPowerShellScript' }
    $scriptPath = Join-Path $temporary $(if ($linuxTarget) { 'cpu.sh' } else { 'cpu.ps1' })
    $payload = if ($linuxTarget) { $linuxScript } else { $windowsScript }
    [IO.File]::WriteAllText($scriptPath, $payload.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    az vm run-command invoke --subscription $SubscriptionId.ToString() --resource-group $ResourceGroup --name $vm.name --command-id $commandId --scripts "@$scriptPath" --no-wait --output none --only-show-errors | Out-Null
    Assert-CpuCommandSucceeded 'Submitting the VM CPU simulation'
    $submitted.Add($vm.name)
  }
} catch {
  $partial = if ($submitted.Count) { $submitted -join ', ' } else { 'none confirmed' }
  throw "CPU simulation submission failed. Earlier accepted targets: $partial. An uncertain request may still run for 10 minutes. Inspect VM metrics before retrying; cancellation is not rollback."
} finally {
  if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
Write-Output 'CPU simulation requests submitted to both demo VMs. Guest commands run independently for 10 minutes; confirm Percentage CPU and guest execution results in Azure Monitor/Run Command. Cancellation does not stop submitted load.'