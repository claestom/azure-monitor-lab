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
}
$resourceGroupId = "/subscriptions/$($fixture.Subscription)/resourceGroups/$($fixture.ResourceGroup)"
$workspaceId = "$resourceGroupId/providers/Microsoft.OperationalInsights/workspaces/law-test"
$unsupportedId = "$resourceGroupId/providers/Microsoft.Network/virtualNetworks/vnet-test"
$associationId = "$workspaceId/providers/Microsoft.Insights/dataCollectionRuleAssociations/test-association"
$dcrId = "$resourceGroupId/providers/Microsoft.Insights/dataCollectionRules/dcr-test"
$dceId = "$resourceGroupId/providers/Microsoft.Insights/dataCollectionEndpoints/dce-test"
$auxiliaryGroup = "MC_$($fixture.ResourceGroup)_aks-test_northeurope"
@{ expectedSubscriptionId = $fixture.Subscription; expectedTenantId = $fixture.Tenant } |
  ConvertTo-Json | Set-Content (Join-Path $root '.azure-target.json')

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
      return ConvertTo-Json -InputObject @('rg-other-lab', $auxiliaryGroup, $fixture.ResourceGroup)
    }
    'group delete' {
      $name = $args[[Array]::IndexOf($args, '-n') + 1]
      if ($name -notin @($fixture.ResourceGroup, $auxiliaryGroup) -or $args -notcontains '--no-wait' -or $args -notcontains '--yes') { throw 'Unexpected resource group deletion.' }
      $fixture.Deletes.Add("group:$name")
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
      return ConvertTo-Json -InputObject @(@{ id = $workspaceId; name = 'law-test' }, @{ id = $unsupportedId; name = 'vnet-test' })
    }
    'rest --method' {
      if ($args[2] -ne 'get') { throw 'Only read-only association discovery is expected.' }
      $url = $args[[Array]::IndexOf($args, '--url') + 1]
      if ($url -eq "$workspaceId/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=2023-03-11") {
        return @{ value = @(@{ id = $associationId }, @{ id = $associationId }) } | ConvertTo-Json -Depth 4
      }
      if ($url -ne "$unsupportedId/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=2023-03-11") { throw 'Unexpected association discovery target.' }
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
      & {
        $PSNativeCommandUseErrorActionPreference = $nativePreference
        $failure = ''
        try { & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -Yes | Out-Null }
        catch { $failure = $_.Exception.Message }
        if ($PSNativeCommandUseErrorActionPreference -ne $nativePreference) { throw 'Teardown changed the caller native-error preference.' }
        if ($discoveryCase.Skip) {
          if ($failure) { throw "Expected missing association discovery must not abort teardown: $failure" }
          $expectedDeletes = @($associationId, $dcrId, $dceId, "group:$($fixture.ResourceGroup)", "group:$auxiliaryGroup")
          if (($fixture.Deletes -join ',') -ne ($expectedDeletes -join ',')) { throw 'Associations must be deduplicated and monitoring cleanup must precede only the matched group deletions.' }
        } elseif ($failure -notlike '*DCR association discovery failed*' -or -not $failure.Contains($unsupportedId) -or
                  -not $failure.Contains($discoveryCase.Error) -or $fixture.Deletes.Count) {
          throw "Unexpected discovery errors must retain Azure diagnostics and stop before cleanup deletes: $failure"
        }
      }
    }
  }
  $fixture.Deletes.Clear()
  $fixture.GroupLists = 0
  $fixture.BadTenant = $true
  $rejected = $false
  try { & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -Yes | Out-Null }
  catch { $rejected = $_.Exception.Message -like 'BLOCKED:*' }
  if (-not $rejected -or $fixture.GroupLists -or $fixture.Deletes.Count) { throw 'Account mismatch must stop teardown before resource discovery.' }
  $fixture.BadTenant = $false
  $fixture.Confirm = 'cancel'
  & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup | Out-Null
  if ($fixture.Deletes.Count) { throw 'Cancelled teardown must not delete resources.' }
  Write-Output 'PASS: unsupported and missing association probes work with both native-error preferences; unexpected failures retain diagnostics and block deletion. No Azure calls.'
  Write-Output 'PASS: cleanup order, deduplication, matched group scope, tenant guard, and cancellation are preserved. No Azure calls.'
} finally {
  Remove-Item -LiteralPath $root -Recurse -Force
}