$ErrorActionPreference = 'Stop'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$scriptPath = Join-Path $source 'scripts/setup-fabric.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw "Fabric setup does not parse: $($parseErrors.Message -join '; ')" }

foreach ($name in @('Write-Info', 'Wait-FabricOperation', 'New-FabricItem', 'ConvertTo-InlineBase64', 'Set-EventstreamTopology')) {
  $definition = @($ast.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq $name
  })
  if ($definition.Count -ne 1) { throw "Expected one Fabric helper named '$name'." }
  . ([scriptblock]::Create($definition[0].Extent.Text))
}

$fabricApi = 'https://api.fabric.microsoft.com/v1'
$script:fabricHeaders = @{ Authorization = 'Bearer ' + [guid]::NewGuid().ToString('N') }
$MaxOperationMinutes = 1
$fixture = @{}

function Reset-Fixture {
  $fixture.StatusCode = 201
  $fixture.Headers = @{ Location = @("$fabricApi/workspaces/test-workspace") }
  $fixture.CreateUri = "$fabricApi/workspaces"
  $fixture.OperationUri = "$fabricApi/operations/test-operation"
  $fixture.States = [Collections.Generic.Queue[object]]::new()
  $fixture.Posts = 0
  $fixture.Polls = 0
  $fixture.Delays = [Collections.Generic.List[int]]::new()
  $fixture.PostFailure = ''
}

function Invoke-RestMethod {
  param($Method, $Uri, $Headers, $ContentType, $Body, $ResponseHeadersVariable, $StatusCodeVariable)
  if ($Headers.Authorization -ne $script:fabricHeaders.Authorization) { throw 'Unexpected Fabric authorization.' }
  if ($Method -eq 'Post' -and $Uri -eq "$fabricApi/workspaces/test-workspace/eventstreams/test-stream/getDefinition") {
    return @{ definition = @{ parts = @() } }
  }
  if ($Method -eq 'Get' -and $Uri -eq "$fabricApi/workspaces/test-workspace/eventstreams/test-stream/topology") {
    return @{ sources = @() }
  }
  if ($Method -eq 'Post' -and $Uri -eq $fixture.CreateUri) {
    $fixture.Posts++
    if ($fixture.PostFailure) { throw $fixture.PostFailure }
    if ($ContentType -ne 'application/json' -or -not ($Body | ConvertFrom-Json)) { throw 'Invalid Fabric request body.' }
    if ($ResponseHeadersVariable) { Set-Variable -Name $ResponseHeadersVariable -Value $fixture.Headers -Scope 1 }
    if ($StatusCodeVariable) { Set-Variable -Name $StatusCodeVariable -Value $fixture.StatusCode -Scope 1 }
    if ($fixture.StatusCode -eq 202) { return }
    return [pscustomobject]@{ id = 'test-workspace'; displayName = 'Test workspace' }
  }
  if ($Method -eq 'Get') {
    $fixture.Polls++
    if ($Uri -ne $fixture.OperationUri) { throw "Unexpected polling URL '$Uri' after HTTP $($fixture.StatusCode)." }
    if (-not $fixture.States.Count) { throw 'The test did not expect another operation poll.' }
    if ($ResponseHeadersVariable) { Set-Variable -Name $ResponseHeadersVariable -Value @{ 'Retry-After' = @('2') } -Scope 1 }
    return $fixture.States.Dequeue()
  }
  throw "Unexpected Fabric request: $Method $Uri"
}

function Start-Sleep {
  param([int] $Seconds)
  $fixture.Delays.Add($Seconds)
}

function Assert-Failure {
  param([scriptblock] $Action, [string] $ExpectedMessage)
  $failure = ''
  try { & $Action | Out-Null } catch { $failure = $_.Exception.Message }
  if ($failure -notlike $ExpectedMessage) { throw "Expected '$ExpectedMessage', got '$failure'." }
}

function Invoke-TestCreate {
  New-FabricItem -Path 'workspaces' -Body @{ displayName = 'Test workspace' }
}

function Invoke-TestTopology {
  Set-EventstreamTopology -WorkspaceId test-workspace -EventstreamId test-stream `
    -ConnectionId test-connection -KqlDatabaseId test-database -DatabaseName TestDatabase -TableName TestTable
}

foreach ($statusCode in @(201, 200)) {
  Reset-Fixture
  $fixture.StatusCode = $statusCode
  $created = Invoke-TestCreate
  if ($created.id -ne 'test-workspace' -or $fixture.Posts -ne 1 -or $fixture.Polls -or $fixture.Delays.Count) {
    throw "HTTP $statusCode must return the created resource without polling or rerunning the POST."
  }
}
Write-Output 'PASS: HTTP 200/201 with a resource Location return immediately.'

foreach ($headerMode in @('absolute', 'relative', 'id-only', 'id-with-result-location')) {
  Reset-Fixture
  $fixture.StatusCode = 202
  $fixture.Headers = switch ($headerMode) {
    'absolute' { @{ Location = @($fixture.OperationUri) } }
    'relative' { @{ Location = @('/v1/operations/test-operation') } }
    'id-only' { @{ 'x-ms-operation-id' = @('test-operation') } }
    'id-with-result-location' { @{ Location = @("$($fixture.OperationUri)/result"); 'x-ms-operation-id' = @('test-operation') } }
  }
  foreach ($status in @('NotStarted', 'Running', 'Succeeded')) { $fixture.States.Enqueue(@{ status = $status }) }
  Invoke-TestCreate | Out-Null
  if ($fixture.Posts -ne 1 -or $fixture.Polls -ne 3 -or ($fixture.Delays -join ',') -ne '2,2') {
    throw "HTTP 202 must wait to completion using '$headerMode' headers without repeating the POST."
  }
}
Write-Output 'PASS: HTTP 202 waits for completion using operation Location or ID and honors Retry-After.'

Reset-Fixture
$fixture.StatusCode = 202
$fixture.Headers = @{}
Assert-Failure { Invoke-TestCreate } '*operation URL or ID*'
if ($fixture.Posts -ne 1 -or $fixture.Polls -or $fixture.Delays.Count) { throw 'Missing operation metadata must fail before polling.' }

foreach ($status in @($null, '', 'UnexpectedStatus')) {
  Reset-Fixture
  $fixture.StatusCode = 202
  $fixture.Headers = @{ Location = @($fixture.OperationUri) }
  $fixture.States.Enqueue(@{ status = $status })
  Assert-Failure { Invoke-TestCreate } '*unexpected status*'
  if ($fixture.Posts -ne 1 -or $fixture.Polls -ne 1 -or $fixture.Delays.Count) { throw 'Missing or unknown status must fail without an empty polling loop.' }
}

foreach ($status in @('Failed', 'Cancelled')) {
  Reset-Fixture
  $fixture.StatusCode = 202
  $fixture.Headers = @{ Location = @($fixture.OperationUri) }
  $fixture.States.Enqueue(@{ status = $status; error = @{ errorCode = 'TestFailure'; message = 'Test operation failed.' } })
  Assert-Failure { Invoke-TestCreate } "*status '$status'*TestFailure*"
  if ($fixture.Posts -ne 1 -or $fixture.Polls -ne 1 -or $fixture.Delays.Count) { throw 'Failed operations must stop without resubmission.' }
}

Reset-Fixture
$fixture.PostFailure = 'Test request denied.'
Assert-Failure { Invoke-TestCreate } 'Test request denied.'
if ($fixture.Posts -ne 1 -or $fixture.Polls) { throw 'Request failures must not be retried or polled.' }
Write-Output 'PASS: Missing operation metadata, invalid statuses, failed operations, and request errors stop promptly.'

foreach ($statusCode in @(200, 202)) {
  Reset-Fixture
  $fixture.StatusCode = $statusCode
  $fixture.CreateUri = "$fabricApi/workspaces/test-workspace/eventstreams/test-stream/updateDefinition"
  if ($statusCode -eq 202) {
    $fixture.Headers = @{ 'x-ms-operation-id' = @('test-operation') }
    $fixture.States.Enqueue(@{ status = 'Running' })
    $fixture.States.Enqueue(@{ status = 'Succeeded' })
  }
  Invoke-TestTopology
  $expectedPolls = if ($statusCode -eq 202) { 2 } else { 0 }
  if ($fixture.Posts -ne 1 -or $fixture.Polls -ne $expectedPolls) { throw "Eventstream update mishandled HTTP $statusCode." }
}

Reset-Fixture
$fixture.StatusCode = 202
$fixture.CreateUri = "$fabricApi/workspaces/test-workspace/eventstreams/test-stream/updateDefinition"
$fixture.Headers = @{}
Assert-Failure { Invoke-TestTopology } '*operation URL or ID*'
if ($fixture.Posts -ne 1 -or $fixture.Polls) { throw 'An accepted Eventstream update without operation metadata must not report success.' }
Write-Output 'PASS: Eventstream updates use the same synchronous/asynchronous rules. No Azure calls or real delays.'