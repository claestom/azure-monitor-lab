<#
.SYNOPSIS
  Create the optional Microsoft Fabric Real-Time Intelligence demo items.

.DESCRIPTION
  Pins and verifies the Azure subscription, finds the deployed Fabric F2 capacity,
  then creates or reuses a workspace, Eventhouse, KQL database, and Eventstream.
  It attempts to create the Event Hubs connection and publish the source-to-Eventhouse
  topology. If the tenant rejects public API connection creation, the user creates
  that connection once in Fabric and reruns this script to publish the topology.

.EXAMPLE
  ./scripts/setup-fabric.ps1 -SubscriptionId <subscription-id> -ResourceGroup rg-azure-monitor-lab
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [string] $NamePrefix = 'amlab',
  [string] $WorkspaceName = 'Azure Monitor Demo Lab',
  [string] $EventhouseName = 'Azure Monitor Demo Eventhouse',
  [string] $KqlDatabaseName = 'MonitoringTelemetry',
  [string] $EventstreamName = 'AzureMonitorEvents',
  [string] $DestinationTableName = 'AzureDiagnosticsRaw',
  [ValidateRange(5, 120)] [int] $MaxOperationMinutes = 30,
  [switch] $SkipEventstreamConnection,
  [switch] $Teardown
)

$ErrorActionPreference = 'Stop'
$fabricApi = 'https://api.fabric.microsoft.com/v1'

function Write-Step($Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Info($Message) { Write-Host "    $Message" -ForegroundColor DarkGray }

function Get-CollectionItem {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $DisplayName
  )

  $response = Invoke-RestMethod -Method Get -Uri "$fabricApi/$Path" -Headers $script:fabricHeaders
  return @($response.value | Where-Object { $_.displayName -eq $DisplayName }) | Select-Object -First 1
}

function Wait-FabricOperation {
  param(
    [Parameter(Mandatory)] [string] $OperationUrl,
    [string] $OperationId = ''
  )

  if ($OperationUrl.StartsWith('/')) {
    $OperationUrl = "https://api.fabric.microsoft.com$OperationUrl"
  }
  if ([string]::IsNullOrWhiteSpace($OperationId)) {
    $OperationId = ($OperationUrl.TrimEnd('/') -split '/')[-1]
  }

  $deadline = [DateTime]::UtcNow.AddMinutes($MaxOperationMinutes)
  $lastStatus = ''
  $operation = $null
  while ([DateTime]::UtcNow -lt $deadline) {
    $pollHeaders = $null
    $operation = Invoke-RestMethod `
      -Method Get `
      -Uri $OperationUrl `
      -Headers $script:fabricHeaders `
      -ResponseHeadersVariable pollHeaders
    if ($operation.status -notin @('NotStarted', 'Running', 'Succeeded', 'Failed', 'Cancelled')) {
      $unexpectedStatus = if ([string]::IsNullOrWhiteSpace($operation.status)) { '<missing>' } else { $operation.status }
      throw "Fabric operation '$OperationId' returned unexpected status '$unexpectedStatus'. Expected an operation status response. Operation URL: $OperationUrl"
    }
    if ($operation.status -ne $lastStatus) {
      $progress = if ($null -ne $operation.percentComplete) { " ($($operation.percentComplete)%)" } else { '' }
      Write-Info "Fabric operation $OperationId`: $($operation.status)$progress"
      $lastStatus = $operation.status
    }
    if ($operation.status -eq 'Succeeded') { return }
    if ($operation.status -in @('Failed', 'Cancelled')) {
      $errorDetails = $operation.error | ConvertTo-Json -Depth 8 -Compress
      throw "Fabric operation '$OperationId' ended with status '$($operation.status)': $errorDetails"
    }

    $retryAfter = 10
    if ($pollHeaders -and $pollHeaders.'Retry-After') {
      $parsedRetryAfter = 0
      if ([int]::TryParse(($pollHeaders.'Retry-After' | Select-Object -First 1), [ref]$parsedRetryAfter)) {
        $retryAfter = [Math]::Min([Math]::Max($parsedRetryAfter, 1), 60)
      }
    }
    Start-Sleep -Seconds $retryAfter
  }

  $lastOperationStatus = if ($operation -and $operation.status) { $operation.status } else { '<unknown>' }
  $lastUpdated = if ($operation.lastUpdatedTimeUtc) { $operation.lastUpdatedTimeUtc } else { '<unknown>' }
  $percentComplete = if ($null -ne $operation.percentComplete) { $operation.percentComplete } else { '<unknown>' }
  throw "Fabric operation '$OperationId' did not complete within $MaxOperationMinutes minutes. Last status: '$lastOperationStatus', progress: $percentComplete%, last updated: $lastUpdated. The operation may still complete; rerun this script safely to discover and reuse the item. Operation URL: $OperationUrl"
}

function New-FabricItem {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [hashtable] $Body
  )

  $responseHeaders = $null
  $responseStatus = $null
  $request = @{
    Method = 'Post'
    Uri = "$fabricApi/$Path"
    Headers = $script:fabricHeaders
    ContentType = 'application/json'
    Body = ($Body | ConvertTo-Json -Depth 8)
    ResponseHeadersVariable = 'responseHeaders'
    StatusCodeVariable = 'responseStatus'
  }
  $result = Invoke-RestMethod @request
  if ($responseStatus -in @(200, 201)) { return $result }
  if ($responseStatus -ne 202) { throw "Fabric request '$Path' returned unexpected HTTP status '$responseStatus'." }

  $operationId = $responseHeaders.'x-ms-operation-id' | Select-Object -First 1
  $operationUrl = if ($operationId) { "$fabricApi/operations/$operationId" } else { $responseHeaders.Location | Select-Object -First 1 }
  if ([string]::IsNullOrWhiteSpace($operationUrl)) {
    throw "Fabric accepted '$Path' but did not return an operation URL or ID. No request was retried."
  }
  Wait-FabricOperation -OperationUrl $operationUrl -OperationId $operationId
  return $result
}

function Ensure-FabricItem {
  param(
    [Parameter(Mandatory)] [string] $CollectionPath,
    [Parameter(Mandatory)] [string] $DisplayName,
    [Parameter(Mandatory)] [hashtable] $CreateBody
  )

  $item = Get-CollectionItem -Path $CollectionPath -DisplayName $DisplayName
  if ($item) {
    Write-Info "Reusing '$DisplayName' ($($item.id))"
    return $item
  }

  Write-Info "Creating '$DisplayName'"
  $created = New-FabricItem -Path $CollectionPath -Body $CreateBody
  if ($created.id) { return $created }

  $item = Get-CollectionItem -Path $CollectionPath -DisplayName $DisplayName
  if (-not $item) { throw "Fabric created '$DisplayName', but it could not be resolved afterward." }
  return $item
}

function ConvertTo-InlineBase64 {
  param([Parameter(Mandatory)] [string] $Value)
  return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
}

function Get-FabricConnection {
  param(
    [Parameter(Mandatory)] [string] $DisplayName,
    [string] $NamespaceName = '',
    [string] $EventHubName = ''
  )

  $connections = Invoke-RestMethod -Method Get -Uri "$fabricApi/connections" -Headers $script:fabricHeaders
  $connection = @($connections.value | Where-Object { $_.displayName -eq $DisplayName }) | Select-Object -First 1
  if ($connection -or [string]::IsNullOrWhiteSpace($NamespaceName)) { return $connection }

  $namespaceToken = $NamespaceName.ToLowerInvariant()
  $eventHubPattern = '(^|[;"/:=])' + [regex]::Escape($EventHubName.ToLowerInvariant()) + '($|[;"/},])'
  return @($connections.value | Where-Object {
    $_.connectionDetails -and
    $_.connectionDetails.type -eq 'EventHub' -and
    $_.connectionDetails.path -and
    $_.connectionDetails.path.ToLowerInvariant().Contains($namespaceToken) -and
    $_.connectionDetails.path.ToLowerInvariant() -match $eventHubPattern
  }) | Select-Object -First 1
}

function Ensure-EventHubConnection {
  param(
    [Parameter(Mandatory)] [string] $NamespaceName,
    [Parameter(Mandatory)] [string] $EventHubName
  )

  $connectionName = "amlab-$NamespaceName-$EventHubName"
  $connection = Get-FabricConnection `
    -DisplayName $connectionName `
    -NamespaceName $NamespaceName `
    -EventHubName $EventHubName
  if ($connection) {
    Write-Info "Refreshing Fabric connection '$connectionName' ($($connection.id))"
  }

  $listenKey = $null
  $connectionBody = $null
  try {
    $listenKey = az eventhubs namespace authorization-rule keys list `
      --subscription $SubscriptionId `
      --resource-group $ResourceGroup `
      --namespace-name $NamespaceName `
      --name diagnostics-listen `
      --query primaryKey `
      -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($listenKey)) {
      throw "Could not retrieve the Listen-only 'diagnostics-listen' key. Redeploy the latest template or use -SkipEventstreamConnection."
    }

    $credentialDetails = @{
      singleSignOnType = 'None'
      connectionEncryption = 'NotEncrypted'
      skipTestConnection = $false
      credentials = @{
        credentialType = 'Basic'
        username = 'diagnostics-listen'
        password = $listenKey
      }
    }
    if ($connection) {
      $updateBody = @{
        connectivityType = 'ShareableCloud'
        displayName = $connectionName
        privacyLevel = 'Organizational'
        credentialDetails = $credentialDetails
      }
      $connection = Invoke-RestMethod `
        -Method Patch `
        -Uri "$fabricApi/connections/$($connection.id)" `
        -Headers $script:fabricHeaders `
        -ContentType 'application/json' `
        -Body ($updateBody | ConvertTo-Json -Depth 12)
      return $connection
    }

    $connectionBody = @{
      connectivityType = 'ShareableCloud'
      displayName = $connectionName
      connectionDetails = @{
        type = 'EventHub'
        creationMethod = 'EventHub.Contents'
        parameters = @(
          @{ dataType = 'Text'; name = 'endpoint'; value = "sb://$NamespaceName.servicebus.windows.net/" }
          @{ dataType = 'Text'; name = 'entityPath'; value = $EventHubName }
        )
      }
      privacyLevel = 'Organizational'
      credentialDetails = $credentialDetails
    }

    Write-Info "Creating Fabric Event Hub connection '$connectionName'"
    try {
      $connection = Invoke-RestMethod `
        -Method Post `
        -Uri "$fabricApi/connections" `
        -Headers $script:fabricHeaders `
        -ContentType 'application/json' `
        -Body ($connectionBody | ConvertTo-Json -Depth 12)
    } catch {
      $fabricError = $_.ErrorDetails.Message
      if ($fabricError) {
        try {
          $parsedError = $fabricError | ConvertFrom-Json
          $safeError = "$($parsedError.errorCode): $($parsedError.message)"
        } catch {
          $safeError = 'Fabric API request failed without a structured error response.'
        }
        throw "Fabric rejected automated Event Hub connection creation. Create the connection once in the Fabric portal, then rerun this script to publish the topology automatically. Fabric response: $safeError"
      }
      throw
    }
    return $connection
  } finally {
    $listenKey = $null
    $credentialDetails = $null
    $updateBody = $null
    $connectionBody = $null
  }
}

function Set-EventstreamTopology {
  param(
    [Parameter(Mandatory)] [string] $WorkspaceId,
    [Parameter(Mandatory)] [string] $EventstreamId,
    [Parameter(Mandatory)] [string] $ConnectionId,
    [Parameter(Mandatory)] [string] $KqlDatabaseId,
    [Parameter(Mandatory)] [string] $DatabaseName,
    [Parameter(Mandatory)] [string] $TableName
  )

  $sourceName = 'AzureEventHubSource'
  $streamName = "$EventstreamName-stream"
  $destinationName = 'EventhouseDestination'
  $definitionResponse = Invoke-RestMethod `
    -Method Post `
    -Uri "$fabricApi/workspaces/$WorkspaceId/eventstreams/$EventstreamId/getDefinition" `
    -Headers $script:fabricHeaders
  $eventstreamPart = @($definitionResponse.definition.parts | Where-Object { $_.path -eq 'eventstream.json' }) | Select-Object -First 1
  $existingTopology = if ($eventstreamPart -and $eventstreamPart.payload) {
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($eventstreamPart.payload)) | ConvertFrom-Json
  } else {
    [pscustomobject]@{
      sources = @()
      destinations = @()
      streams = @()
      operators = @()
    }
  }

  $existingSource = @($existingTopology.sources | Where-Object { $_.name -eq $sourceName }) | Select-Object -First 1
  $existingStream = @($existingTopology.streams | Where-Object { $_.name -eq $streamName }) | Select-Object -First 1
  $existingDestination = @($existingTopology.destinations | Where-Object { $_.name -eq $destinationName }) | Select-Object -First 1
  $runtimeTopology = Invoke-RestMethod `
    -Method Get `
    -Uri "$fabricApi/workspaces/$WorkspaceId/eventstreams/$EventstreamId/topology" `
    -Headers $script:fabricHeaders
  $runtimeSource = @($runtimeTopology.sources | Where-Object { $_.name -eq $sourceName }) | Select-Object -First 1
  $sourceId = if ($existingSource.id -and $runtimeSource.status -ne 'Failed') {
    $existingSource.id
  } else {
    if ($runtimeSource.status -eq 'Failed') {
      Write-Info "Recreating failed Eventstream source '$sourceName'"
    }
    [guid]::NewGuid().ToString()
  }
  $streamId = if ($existingStream.id) { $existingStream.id } else { [guid]::NewGuid().ToString() }
  $destinationId = if ($existingDestination.id) { $existingDestination.id } else { [guid]::NewGuid().ToString() }

  $topology = [ordered]@{
    sources = @(
      [ordered]@{
        id = $sourceId
        name = $sourceName
        type = 'AzureEventHub'
        properties = [ordered]@{
          dataConnectionId = $ConnectionId
          consumerGroupName = '$Default'
          inputSerialization = @{ type = 'Json'; properties = @{ encoding = 'UTF8' } }
        }
      }
    )
    destinations = @(
      [ordered]@{
        id = $destinationId
        name = $destinationName
        type = 'Eventhouse'
        properties = [ordered]@{
          dataIngestionMode = 'ProcessedIngestion'
          workspaceId = $WorkspaceId
          itemId = $KqlDatabaseId
          databaseName = $DatabaseName
          tableName = $TableName
          inputSerialization = @{ type = 'Json'; properties = @{ encoding = 'UTF8' } }
        }
        inputNodes = @( @{ name = $streamName } )
      }
    )
    streams = @(
      [ordered]@{
        id = $streamId
        name = $streamName
        type = 'DefaultStream'
        properties = @{}
        inputNodes = @( @{ name = $sourceName } )
      }
    )
    operators = @()
    compatibilityLevel = '1.1'
  }

  $properties = [ordered]@{
    retentionTimeInDays = 1
    eventThroughputLevel = 'Low'
  }
  $requestBody = @{
    definition = @{
      parts = @(
        @{
          path = 'eventstream.json'
          payload = ConvertTo-InlineBase64 -Value ($topology | ConvertTo-Json -Depth 20)
          payloadType = 'InlineBase64'
        }
        @{
          path = 'eventstreamProperties.json'
          payload = ConvertTo-InlineBase64 -Value ($properties | ConvertTo-Json -Depth 5)
          payloadType = 'InlineBase64'
        }
      )
    }
  }

  $responseHeaders = $null
  $responseStatus = $null
  try {
    Invoke-RestMethod `
      -Method Post `
      -Uri "$fabricApi/workspaces/$WorkspaceId/eventstreams/$EventstreamId/updateDefinition" `
      -Headers $script:fabricHeaders `
      -ContentType 'application/json' `
      -Body ($requestBody | ConvertTo-Json -Depth 25) `
      -ResponseHeadersVariable responseHeaders `
      -StatusCodeVariable responseStatus | Out-Null
  } catch {
    $fabricError = $_.ErrorDetails.Message
    if ($fabricError) {
      try {
        $parsedError = $fabricError | ConvertFrom-Json
        throw "Eventstream definition was rejected: $($parsedError.errorCode): $($parsedError.message)"
      } catch {
        if ($_.Exception.Message -like 'Eventstream definition was rejected:*') { throw }
      }
    }
    throw "Eventstream definition was rejected: $($_.Exception.Message)"
  }
  if ($responseStatus -eq 202) {
    $operationId = $responseHeaders.'x-ms-operation-id' | Select-Object -First 1
    $operationUrl = if ($operationId) { "$fabricApi/operations/$operationId" } else { $responseHeaders.Location | Select-Object -First 1 }
    if ([string]::IsNullOrWhiteSpace($operationUrl)) {
      throw 'Fabric accepted the Eventstream definition but did not return an operation URL or ID. No request was retried.'
    }
    Wait-FabricOperation -OperationUrl $operationUrl -OperationId $operationId
  }
}

Write-Step 'Pinning the Azure subscription'
az account set --subscription $SubscriptionId | Out-Null
$active = az account show --query '{id:id,tenantId:tenantId,userName:user.name,userType:user.type}' -o json | ConvertFrom-Json
if ($active.id -ne $SubscriptionId) {
  throw "Subscription guardrail failed: expected '$SubscriptionId', got '$($active.id)'."
}
Write-Info "Subscription: $($active.id)"
Write-Info "Tenant: $($active.tenantId)"
Write-Info "Signed-in identity: $($active.userName) ($($active.userType))"

Write-Step 'Discovering the deployed Fabric capacity'
$armCapacity = az resource list `
  --subscription $SubscriptionId `
  --resource-group $ResourceGroup `
  --resource-type Microsoft.Fabric/capacities `
  --query '[0].{id:id,name:name,location:location,sku:sku.name}' `
  -o json | ConvertFrom-Json
if (-not $armCapacity) {
  throw "No Microsoft Fabric capacity was found in '$ResourceGroup'. Enable the Fabric stage first."
}
if ($armCapacity.sku -ne 'F2' -or $armCapacity.location.Replace(' ', '').ToLowerInvariant() -ne 'swedencentral') {
  throw "Expected an F2 capacity in swedencentral, found '$($armCapacity.sku)' in '$($armCapacity.location)'."
}
Write-Info "Capacity: $($armCapacity.name) (F2, swedencentral)"
Write-Host '    Cost warning: indicative PAYG retail cost while active is about $0.36/hour, $8.64/day, or $262.80/month.' -ForegroundColor Yellow

$capacityDetails = az resource show `
  --ids $armCapacity.id `
  --api-version 2023-11-01 `
  --query '{state:properties.state,administrators:properties.administration.members}' `
  -o json | ConvertFrom-Json
$capacityAdministrators = @($capacityDetails.administrators)
Write-Info "Capacity state: $($capacityDetails.state)"
Write-Info "Capacity administrators: $($capacityAdministrators -join ', ')"
if ($capacityDetails.state -ne 'Active') {
  throw "Fabric capacity '$($armCapacity.name)' is '$($capacityDetails.state)'. Resume it before setup: ./scripts/resume-fabric.ps1 -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup"
}
if ($active.userType -ne 'user') {
  throw "Fabric setup requires an interactive Microsoft Entra user. Azure CLI is signed in as '$($active.userType)'."
}
if ($capacityAdministrators -notcontains $active.userName) {
  throw "Signed-in user '$($active.userName)' is not a configured Fabric capacity administrator. Redeploy with fabricAdminEmail set to this tenant user UPN, or sign in as one of: $($capacityAdministrators -join ', ')."
}

Write-Step 'Authenticating to the Fabric API'
$fabricToken = az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv
if ([string]::IsNullOrWhiteSpace($fabricToken)) { throw 'Could not acquire a Microsoft Fabric API token.' }
$script:fabricHeaders = @{ Authorization = "Bearer $fabricToken" }

if ($Teardown) {
  Write-Step 'Removing the Fabric workspace and contained items'
  $teardownNamespace = az resource list `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroup `
    --resource-type Microsoft.EventHub/namespaces `
    --query '[0].name' `
    -o tsv
  if (-not [string]::IsNullOrWhiteSpace($teardownNamespace)) {
    $connectionName = "amlab-$teardownNamespace-diagnostics"
    $connection = Get-FabricConnection `
      -DisplayName $connectionName `
      -NamespaceName $teardownNamespace `
      -EventHubName 'diagnostics'
    if ($connection) {
      Write-Info "Deleting Fabric connection '$($connection.displayName)' ($($connection.id))"
      Invoke-RestMethod `
        -Method Delete `
        -Uri "$fabricApi/connections/$($connection.id)" `
        -Headers $script:fabricHeaders | Out-Null
    }
  }

  $workspace = Get-CollectionItem -Path 'workspaces' -DisplayName $WorkspaceName
  if (-not $workspace) {
    Write-Info "Workspace '$WorkspaceName' does not exist; nothing to remove."
    return
  }

  Invoke-RestMethod `
    -Method Delete `
    -Uri "$fabricApi/workspaces/$($workspace.id)" `
    -Headers $script:fabricHeaders | Out-Null
  Write-Host "Fabric workspace '$WorkspaceName' and its contained items were deleted." -ForegroundColor Green
  return
}

$capacities = Invoke-RestMethod -Method Get -Uri "$fabricApi/capacities" -Headers $script:fabricHeaders
$fabricCapacity = @($capacities.value | Where-Object { $_.displayName -eq $armCapacity.name }) | Select-Object -First 1
if (-not $fabricCapacity) {
  throw "Fabric API did not return capacity '$($armCapacity.name)'. Confirm the tenant is Fabric-enabled and your identity is a capacity administrator."
}

Write-Step 'Creating or reusing the Fabric workspace'
$workspace = Ensure-FabricItem `
  -CollectionPath 'workspaces' `
  -DisplayName $WorkspaceName `
  -CreateBody @{
    displayName = $WorkspaceName
    description = 'Real-Time Intelligence scenarios for the Azure Monitor Demo Lab.'
    capacityId = $fabricCapacity.id
  }

Write-Step 'Creating or reusing Real-Time Intelligence items'
$eventhouse = Ensure-FabricItem `
  -CollectionPath "workspaces/$($workspace.id)/eventhouses" `
  -DisplayName $EventhouseName `
  -CreateBody @{
    displayName = $EventhouseName
    description = 'Eventhouse for operational and business event correlation.'
  }

$kqlDatabase = Ensure-FabricItem `
  -CollectionPath "workspaces/$($workspace.id)/kqlDatabases" `
  -DisplayName $KqlDatabaseName `
  -CreateBody @{
    displayName = $KqlDatabaseName
    description = 'Read-write KQL database for streamed lab telemetry.'
    creationPayload = @{
      databaseType = 'ReadWrite'
      parentEventhouseItemId = $eventhouse.id
    }
  }

$eventstream = Ensure-FabricItem `
  -CollectionPath "workspaces/$($workspace.id)/eventstreams" `
  -DisplayName $EventstreamName `
  -CreateBody @{
    displayName = $EventstreamName
    description = 'Eventstream for the Azure Event Hubs diagnostics source and Eventhouse destination.'
  }

Write-Step 'Resolving the Azure Event Hub source'
$eventHubNamespace = az resource list `
  --subscription $SubscriptionId `
  --resource-group $ResourceGroup `
  --resource-type Microsoft.EventHub/namespaces `
  --query '[0].name' `
  -o tsv
if ([string]::IsNullOrWhiteSpace($eventHubNamespace)) {
  Write-Host '    No Event Hubs namespace was found. Deploy Stage A before configuring the Eventstream source.' -ForegroundColor Yellow
} else {
  Write-Info "Namespace: $eventHubNamespace"
  Write-Info 'Event Hub: diagnostics'
  Write-Info 'Listen authorization rule: diagnostics-listen'
}

$eventstreamAutomated = $false
if (-not $SkipEventstreamConnection -and -not [string]::IsNullOrWhiteSpace($eventHubNamespace)) {
  Write-Step 'Connecting the Fabric Eventstream automatically'
  try {
    $eventHubConnection = Ensure-EventHubConnection `
      -NamespaceName $eventHubNamespace `
      -EventHubName 'diagnostics'
    Set-EventstreamTopology `
      -WorkspaceId $workspace.id `
      -EventstreamId $eventstream.id `
      -ConnectionId $eventHubConnection.id `
      -KqlDatabaseId $kqlDatabase.id `
      -DatabaseName $KqlDatabaseName `
      -TableName $DestinationTableName
    $eventstreamAutomated = $true
    Write-Host "Eventstream source and Eventhouse destination configured." -ForegroundColor Green
  } catch {
    Write-Host "  Automatic Eventstream connection failed: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host '  Create the Event Hub connection once in Fabric, then rerun this script. The source and destination topology will be published automatically.' -ForegroundColor Yellow
  }
}

Write-Host "`nFabric setup completed." -ForegroundColor Green
Write-Host "Workspace: https://app.fabric.microsoft.com/groups/$($workspace.id)"
Write-Host "Eventhouse ID: $($eventhouse.id)"
Write-Host "KQL database ID: $($kqlDatabase.id)"
Write-Host "Eventstream ID: $($eventstream.id)"
if (-not $eventstreamAutomated) {
  Write-Host "`nManual Eventstream connection:" -ForegroundColor Cyan
  Write-Host "1. Open '$EventstreamName', switch to Edit mode, and select Add source > Connect data sources > Azure Event Hubs."
  Write-Host "2. Create a Shared Access Key connection to namespace '$eventHubNamespace' and Event Hub 'diagnostics'."
  Write-Host "3. Use Shared Access Key Name 'diagnostics-listen' and its primary or secondary key from the Event Hubs namespace."
  Write-Host "4. After the connection test succeeds, cancel before adding or publishing source topology."
  Write-Host "5. Rerun this script. It will discover the connection and publish the source, stream, and Eventhouse destination automatically."
  Write-Host "6. Confirm events arrive in '$DestinationTableName', then create the Real-Time Dashboard from '$KqlDatabaseName'."
  Write-Host "The connection key is entered only in Fabric; do not paste it into this script or source control."
}
Write-Host "`nNext steps: docs/STAGE-FABRIC.md#after-deployps1-checklist" -ForegroundColor Cyan
Write-Host "Verify '$DestinationTableName', create the Real-Time Dashboard, check the Azure health views, and suspend F2 when finished."
Write-Host "`nSuspend F2 when idle: ./scripts/suspend-fabric.ps1 -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup" -ForegroundColor Yellow