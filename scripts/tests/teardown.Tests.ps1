$ErrorActionPreference = 'Stop'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$root = Join-Path ([IO.Path]::GetTempPath()) ('teardown-test-' + [guid]::NewGuid().ToString('N'))
$directory = Join-Path $root 'scripts'
$null = New-Item -ItemType Directory -Path $directory -Force
Copy-Item -LiteralPath (Join-Path $source 'scripts/teardown.ps1') -Destination $directory
$fixture = @{
  Subscription = [guid]::NewGuid(); Tenant = [guid]::NewGuid()
  ResourceGroup = 'rg-teardown-test'; BadTenant = $false; Confirm = 'DELETE'
  DiscoveryError = ''; GroupLists = 0
  Deletes = [Collections.Generic.List[string]]::new()
  TenantCleanup = [Collections.Generic.List[string]]::new()
  PrimaryGroupExists = $true; AuxiliaryGroupExists = $true; MonitorGroupExists = $true
  GroupInventoryFails = $false; MonitorDeleteFails = $false; MonitorCascadeDuringDelete = $false
  MonitorOwnerChanged = $false
}
$resourceGroupId = "/subscriptions/$($fixture.Subscription)/resourceGroups/$($fixture.ResourceGroup)"
$workspaceId = "$resourceGroupId/providers/Microsoft.OperationalInsights/workspaces/law-test"
$unsupportedId = "$resourceGroupId/providers/Microsoft.OperationsManagement/solutions/ContainerInsights(law-test)"
$associationId = "$workspaceId/providers/Microsoft.Insights/dataCollectionRuleAssociations/test-association"
$dcrId = "$resourceGroupId/providers/Microsoft.Insights/dataCollectionRules/dcr-test"
$dceId = "$resourceGroupId/providers/Microsoft.Insights/dataCollectionEndpoints/dce-test"
$auxiliaryGroup = "MC_$($fixture.ResourceGroup)_aks-test_northeurope"
$monitorGroup = 'MA_amw-amlab_northeurope_managed_3'
$monitorWorkspaceId = "$resourceGroupId/providers/Microsoft.Monitor/accounts/amw-amlab"
$otherSubscription = [guid]::NewGuid()
$groupInventory = @(
  @{ name = 'rg-other-lab'; managedBy = $null },
  @{ name = $auxiliaryGroup; managedBy = $null },
  @{ name = $fixture.ResourceGroup; managedBy = $null },
  @{ name = $monitorGroup; managedBy = $monitorWorkspaceId.ToUpperInvariant() },
  @{ name = 'MA_amw-amlab_northeurope_managed_2'; managedBy = "/subscriptions/$($fixture.Subscription)/resourceGroups/rg-other-lab/providers/Microsoft.Monitor/accounts/amw-amlab" },
  @{ name = 'MA_amw-amlab_northeurope_managed_unowned'; managedBy = $null },
  @{ name = 'MA_amw-amlab_northeurope_managed_other_subscription'; managedBy = "/subscriptions/$otherSubscription/resourceGroups/$($fixture.ResourceGroup)/providers/Microsoft.Monitor/accounts/amw-amlab" },
  @{ name = 'MA_amw-amlab_northeurope_managed_other_scope'; managedBy = "${resourceGroupId}-other/providers/Microsoft.Monitor/accounts/amw-amlab" },
  @{ name = 'MA_amw-amlab_northeurope_managed_other_type'; managedBy = "$resourceGroupId/providers/Microsoft.OperationalInsights/workspaces/amw-amlab" }
  @{ name = "MA_$($fixture.ResourceGroup)_managed"; managedBy = "/subscriptions/$($fixture.Subscription)/resourceGroups/rg-other-lab/providers/Microsoft.Monitor/accounts/amw-amlab" }
)
@{ expectedSubscriptionId = $fixture.Subscription; expectedTenantId = $fixture.Tenant } |
  ConvertTo-Json | Set-Content (Join-Path $root '.azure-target.json')

foreach ($helperName in @('setup-slis.ps1', 'setup-health-model.ps1')) {
  @'
param($ResourceGroup, [switch]$Teardown)
if ($ResourceGroup -ne $fixture.ResourceGroup -or -not $Teardown) { throw 'Unexpected tenant cleanup target.' }
$fixture.TenantCleanup.Add([IO.Path]::GetFileName($PSCommandPath))
'@ | Set-Content -LiteralPath (Join-Path $directory $helperName)
}

if ($IsWindows) {
  $argumentScript = Join-Path $directory 'capture-arguments.ps1'
  'ConvertTo-Json -InputObject @($args) -Compress' | Set-Content -LiteralPath $argumentScript
  $argumentShim = Join-Path $directory 'az.cmd'
  $nativePowerShell = Join-Path $PSHOME 'pwsh.exe'
  @"
@echo off
if exist "$nativePowerShell" (
  "$nativePowerShell" -NoProfile -NonInteractive -File "$argumentScript" %*
)
"@ | Set-Content -LiteralPath $argumentShim -Encoding ascii
}

function Read-Host { return $fixture.Confirm }
function az {
  $global:LASTEXITCODE = 0
  switch ($args[0..1] -join ' ') {
    'account set' {
      if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription.ToString()) { throw 'Wrong teardown subscription.' }
    }
    'account show' {
      return @{ id = $fixture.Subscription; tenantId = $(if ($fixture.BadTenant) { [guid]::NewGuid() } else { $fixture.Tenant }) } | ConvertTo-Json
    }
    'group list' {
      $fixture.GroupLists++
      if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription.ToString()) { throw 'Group discovery lost the verified subscription.' }
      if ($fixture.GroupInventoryFails) { $global:LASTEXITCODE = 1; return '[]' }
      $groups = @($groupInventory | Where-Object {
        ($fixture.PrimaryGroupExists -or $_.name -ne $fixture.ResourceGroup) -and
        ($fixture.AuxiliaryGroupExists -or $_.name -ne $auxiliaryGroup)
      })
      return ConvertTo-Json -InputObject $groups -Depth 4
    }
    'group exists' {
      if ($args[[Array]::IndexOf($args, '-n') + 1] -ne $monitorGroup) { throw 'Only the linked Monitor group needs a cascade check.' }
      if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription.ToString()) { throw 'Managed-group cleanup lost the verified subscription.' }
      return $fixture.MonitorGroupExists.ToString().ToLowerInvariant()
    }
    'group show' {
      if ($args[[Array]::IndexOf($args, '-n') + 1] -ne $monitorGroup -or $args -notcontains 'managedBy' -or
          $args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription.ToString()) { throw 'Unexpected managed-group owner check.' }
      if ($fixture.MonitorOwnerChanged) { return "/subscriptions/$($fixture.Subscription)/resourceGroups/rg-other-lab/providers/Microsoft.Monitor/accounts/amw-amlab" }
      return $monitorWorkspaceId
    }
    'group delete' {
      $name = $args[[Array]::IndexOf($args, '-n') + 1]
      if ($name -notin @($fixture.ResourceGroup, $auxiliaryGroup, $monitorGroup) -or $args -notcontains '--no-wait' -or $args -notcontains '--yes') { throw 'Unexpected resource group deletion.' }
      if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription.ToString()) { throw 'Group deletion lost the verified subscription.' }
      $fixture.Deletes.Add("group:$name")
      if ($name -eq $monitorGroup -and $fixture.MonitorDeleteFails) {
        if ($fixture.MonitorCascadeDuringDelete) { $fixture.MonitorGroupExists = $false }
        $message = if ($fixture.MonitorCascadeDuringDelete) { 'ResourceGroupNotFound' } else { 'AuthorizationFailed: managed group deletion was denied.' }
        & (Join-Path $PSHOME 'pwsh') -NoProfile -NonInteractive -Command "[Console]::Error.WriteLine('$message'); exit 1"
        $global:LASTEXITCODE = $LASTEXITCODE
      }
    }
    'resource list' {
      if ($args[[Array]::IndexOf($args, '-g') + 1] -ne $fixture.ResourceGroup) { throw 'Unexpected cleanup scope.' }
      if ($args -contains '--resource-type') {
        switch ($args[[Array]::IndexOf($args, '--resource-type') + 1]) {
          'Microsoft.App/agents' { return '[]' }
          'Microsoft.OperationalInsights/workspaces' { return '[]' }
          'Microsoft.Insights/dataCollectionRuleAssociations' { return ConvertTo-Json -InputObject @(@{ id = $associationId }) }
          'Microsoft.Insights/dataCollectionRules' { return ConvertTo-Json -InputObject @(@{ id = $dcrId; name = 'dcr-test' }) }
          'Microsoft.Insights/dataCollectionEndpoints' { return ConvertTo-Json -InputObject @(@{ id = $dceId; name = 'dce-test' }) }
          default { throw 'Unexpected resource type.' }
        }
      }
      return ConvertTo-Json -InputObject @(@{ id = $workspaceId; name = 'law-test' }, @{ id = $unsupportedId; name = 'ContainerInsights(law-test)' })
    }
    'rest --method' {
      if ($args[2] -ne 'get') { throw 'Only read-only association discovery is expected.' }
      $url = $args[[Array]::IndexOf($args, '--url') + 1]
      if ($url -eq "$workspaceId/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=2023-03-11") {
        return @{ value = @(@{ id = $associationId }, @{ id = $associationId }) } | ConvertTo-Json -Depth 4
      }
      if ($IsWindows) {
        $forwardedJson = & $argumentShim @args
        if ($LASTEXITCODE -ne 0) { throw 'Windows batch forwarding failed for the association discovery URL.' }
        $forwarded = @($forwardedJson | ConvertFrom-Json)
        if (($forwarded | ConvertTo-Json -Compress) -cne (@($args) | ConvertTo-Json -Compress)) { throw 'Windows batch forwarding changed the Azure CLI arguments.' }
      }
      if ($url -match '[()]' -or [Uri]::UnescapeDataString($url) -ne "$unsupportedId/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=2023-03-11") {
        throw 'Association discovery must encode parenthesized resource names without changing the resource ID.'
      }
      & (Join-Path $PSHOME 'pwsh') -NoProfile -NonInteractive -Command "[Console]::Error.WriteLine('$($fixture.DiscoveryError)'); exit 1"
      $global:LASTEXITCODE = $LASTEXITCODE
    }
    'resource delete' {
      $resourceId = $args[[Array]::IndexOf($args, '--ids') + 1]
      if ($resourceId -notin @($associationId, $dcrId, $dceId)) { throw 'Unexpected resource deletion.' }
      $fixture.Deletes.Add($resourceId)
    }
    default { throw 'Unexpected native Azure request.' }
  }
}

try {
  foreach ($nativePreference in @($true, $false)) {
    foreach ($discoveryCase in @(
      @{ Error = 'ERROR: Bad Request({"error":{"code":"UnsupportedResourceType","message":"Association cannot be created for this resource type."}})'; Skip = $true },
      @{ Error = 'ERROR: Bad Request({"error":{"code":"UnsupportedFeature","message":"Data Collection Rule Associations is not supported in the location of the targeted parent resource.","details":[{"code":"UnsupportedFeature","message":"This parent location cannot host DCR associations.","target":"UnsupportedFeature"}]}})'; Skip = $true },
      @{ Error = 'ERROR: (UnsupportedFeature) Data Collection Rule Associations is not supported in this parent location.'; Skip = $true },
      @{ Error = 'ERROR: (ResourceNotFound) No association endpoint at this resource.'; Skip = $true },
      @{ Error = 'ERROR: Not Found({"error":{"code":"NotFound","message":"No association endpoint."}})'; Skip = $true },
      @{ Error = 'ERROR: (AuthorizationFailed) Association discovery was denied.'; Skip = $false },
      @{ Error = 'ERROR: Forbidden({"error":{"code":"AuthorizationFailed","message":"NotFound and UnsupportedResourceType are not the error code."}})'; Skip = $false },
      @{ Error = 'ERROR: Forbidden({"error":{"code":"AuthorizationFailed","message":"Association discovery was denied.","details":[{"code":"UnsupportedFeature","target":"UnsupportedFeature"}]}})'; Skip = $false },
      @{ Error = 'ERROR: (InternalServerError) Association discovery is unavailable.'; Skip = $false }
    )) {
      $fixture.DiscoveryError = $discoveryCase.Error
      $fixture.Deletes.Clear()
      $fixture.TenantCleanup.Clear()
      & {
        $PSNativeCommandUseErrorActionPreference = $nativePreference
        $failure = ''
        try { & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -Yes | Out-Null }
        catch { $failure = $_.Exception.Message }
        if ($PSNativeCommandUseErrorActionPreference -ne $nativePreference) { throw 'Teardown changed the caller native-error preference.' }
        if ($discoveryCase.Skip) {
          if ($failure) { throw "Expected missing association discovery must not abort teardown: $failure" }
          $expectedDeletes = @($associationId, $dcrId, $dceId, "group:$($fixture.ResourceGroup)", "group:$auxiliaryGroup", "group:$monitorGroup")
          if (($fixture.Deletes -join ',') -ne ($expectedDeletes -join ',')) { throw 'Associations must be deduplicated and monitoring cleanup must precede only the matched group deletions.' }
            if (($fixture.TenantCleanup -join ',') -ne 'setup-slis.ps1,setup-health-model.ps1') { throw 'Normal teardown must retain its tenant cleanup order.' }
        } elseif ($failure -notlike '*DCR association discovery failed*' -or -not $failure.Contains($unsupportedId) -or
              -not $failure.Contains($discoveryCase.Error) -or $fixture.Deletes.Count -or $fixture.TenantCleanup.Count) {
          throw "Unexpected discovery errors must retain Azure diagnostics and stop before cleanup deletes: $failure"
        }
      }
    }
  }
  $fixture.DiscoveryError = 'ERROR: (UnsupportedResourceType) Associations unsupported for this resource.'
  $fixture.Deletes.Clear()
  $fixture.TenantCleanup.Clear()
  & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -KeepServiceGroup -Yes | Out-Null
  if ($fixture.TenantCleanup.Count -or ($fixture.Deletes -join ',') -ne (@($associationId, $dcrId, $dceId, "group:$($fixture.ResourceGroup)", "group:$auxiliaryGroup", "group:$monitorGroup") -join ',')) {
    throw 'KeepServiceGroup must preserve tenant resources while still removing the selected lab.'
  }
  foreach ($monitorGroupExists in @($true, $false)) {
    $fixture.PrimaryGroupExists = $false
    $fixture.AuxiliaryGroupExists = $false
    $fixture.MonitorGroupExists = $monitorGroupExists
    $fixture.Deletes.Clear()
    $fixture.TenantCleanup.Clear()
    & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -Yes | Out-Null
    $expectedDeletes = @()
    if ($monitorGroupExists) { $expectedDeletes += "group:$monitorGroup" }
    if (($fixture.Deletes -join ',') -ne ($expectedDeletes -join ',') -or $fixture.TenantCleanup.Count) {
      throw 'A rerun must clean up only the orphaned owned groups, allowing Azure to have already removed the Monitor group.'
    }
  }
  foreach ($cascadeDuringDelete in @($true, $false)) {
    $fixture.MonitorGroupExists = $true
    $fixture.MonitorDeleteFails = $true
    $fixture.MonitorCascadeDuringDelete = $cascadeDuringDelete
    $fixture.Deletes.Clear()
    $failure = ''
    try { & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -Yes | Out-Null }
    catch { $failure = $_.Exception.Message }
    if ($cascadeDuringDelete -and $failure) { throw "Automatic cleanup racing managed-group deletion must not fail: $failure" }
    if (-not $cascadeDuringDelete -and ($failure -notlike '*failed to submit deletion*AuthorizationFailed*' -or -not $failure.Contains($monitorGroup))) {
      throw 'Managed-group deletion errors must be reported when the group still exists.'
    }
  }
  $fixture.MonitorDeleteFails = $false
  $fixture.MonitorCascadeDuringDelete = $false
  $fixture.MonitorOwnerChanged = $true
  $fixture.MonitorGroupExists = $true
  $fixture.Deletes.Clear()
  $rejected = $false
  try { & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -Yes | Out-Null }
  catch { $rejected = $_.Exception.Message -like '*no longer owned*Refusing deletion*' }
  if (-not $rejected -or $fixture.Deletes.Count) { throw 'Ownership changes since discovery must stop managed-group deletion.' }
  $fixture.MonitorOwnerChanged = $false
  $fixture.PrimaryGroupExists = $true
  $fixture.AuxiliaryGroupExists = $true
  $fixture.MonitorGroupExists = $true
  $fixture.GroupInventoryFails = $true
  $fixture.Deletes.Clear()
  $rejected = $false
  try { & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -Yes | Out-Null }
  catch { $rejected = $_.Exception.Message -like '*Failed to list resource groups*' }
  if (-not $rejected -or $fixture.Deletes.Count) { throw 'Failed ownership discovery must stop before deletion.' }
  $fixture.GroupInventoryFails = $false
  $fixture.Deletes.Clear()
  $fixture.GroupLists = 0
  $fixture.BadTenant = $true
  $rejected = $false
  try { & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -Yes | Out-Null }
  catch { $rejected = $_.Exception.Message -like 'BLOCKED:*' }
  if (-not $rejected -or $fixture.GroupLists -or $fixture.Deletes.Count) { throw 'Account mismatch must stop teardown before resource discovery.' }
  $fixture.BadTenant = $false
  $fixture.Confirm = 'cancel'
  $confirmationOutput = & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup 6>&1 | Out-String
  if ($fixture.Deletes.Count) { throw 'Cancelled teardown must not delete resources.' }
  if (-not $confirmationOutput.Contains($monitorGroup) -or $confirmationOutput.Contains('MA_amw-amlab_northeurope_managed_2')) {
    throw 'Confirmation must list the owned managed group and exclude another lab sharing the workspace name.'
  }
  Write-Output 'PASS: unsupported and missing association probes work with both native-error preferences; unexpected failures retain diagnostics and block deletion. No Azure calls.'
  Write-Output 'PASS: cleanup order, deduplication, matched group scope, tenant guard, and cancellation are preserved. No Azure calls.'
  Write-Output 'PASS: KeepServiceGroup preserves shared tenant resources without skipping resource group cleanup. No Azure calls.'
  Write-Output 'PASS: managed Monitor groups follow exact subscription/RG/workspace ownership; other labs are excluded and cascaded or orphaned groups are handled. No Azure calls.'
  if ($IsWindows) { Write-Output 'PASS: parenthesized ARM resource paths survive native Windows .cmd argument forwarding unchanged. No Azure calls.' }
} finally {
  Remove-Item -LiteralPath $root -Recurse -Force
}