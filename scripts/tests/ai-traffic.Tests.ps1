$ErrorActionPreference = 'Stop'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$root = Join-Path ([IO.Path]::GetTempPath()) ('ai-traffic-test-' + [guid]::NewGuid().ToString('N'))
$scriptDirectory = Join-Path $root 'scripts'
$null = New-Item -ItemType Directory -Path $scriptDirectory -Force
Copy-Item -LiteralPath (Join-Path $source 'scripts/setup-ai.ps1') -Destination $scriptDirectory
$fixture = @{
  Subscription = [guid]::NewGuid(); Tenant = [guid]::NewGuid()
  Events = [Collections.Generic.List[string]]::new(); Fail = ''; State = 'running'
}
$environmentNames = @('AZURE_AI_PROJECT_ENDPOINT', 'AZURE_CHAT_DEPLOYMENT', 'AZURE_ROUTER_DEPLOYMENT', 'APPLICATIONINSIGHTS_CONNECTION_STRING')
$previousEnvironment = @{}
foreach ($name in $environmentNames) { $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }

function Get-Command {
  param($Name, $ErrorAction)
  if ($Name -notin @('python', 'python3')) { throw 'Unexpected executable lookup.' }
  [pscustomobject]@{ Source = 'Invoke-TestPython' }
}

function az {
  $global:LASTEXITCODE = 0
  switch ($args[0..1] -join ' ') {
    'account set' {
      if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription.ToString()) { throw 'Wrong AI setup subscription.' }
    }
    'account show' { return @{ id = $fixture.Subscription; tenantId = $fixture.Tenant } | ConvertTo-Json }
    default { throw 'Unexpected Azure request.' }
  }
}

function Invoke-TestPython {
  $global:LASTEXITCODE = 0
  $step = if ($args[0] -eq '-m') { 'dependencies' } else { [IO.Path]::GetFileNameWithoutExtension($args[0]) }
  $fixture.Events.Add($step)
  if ($fixture.Fail -eq $step) { $global:LASTEXITCODE = 1; return }
  if ($step -in @('background_traffic', 'simulate_traffic')) {
    if ($args -contains '--loop' -or $args[[Array]::IndexOf($args, '--conversations') + 1] -ne 150) { throw 'Traffic must remain a finite 150-conversation batch.' }
    if ($env:AZURE_AI_PROJECT_ENDPOINT -ne 'https://example.services.ai.azure.com/api/projects/test' -or $env:APPLICATIONINSIGHTS_CONNECTION_STRING -ne 'test-telemetry') { throw 'Traffic lost its configured environment.' }
  }
  if ($step -eq 'background_traffic') {
    return @{ processId = 4321; state = $fixture.State; logPath = 'test-traffic.log'; statusPath = 'test-status.json' } | ConvertTo-Json
  }
}

try {
  $parameters = @{
    SubscriptionId = $fixture.Subscription; TenantId = $fixture.Tenant; ResourceGroup = 'test-rg'; NamePrefix = 'amlab'
    ProjectEndpoint = 'https://example.services.ai.azure.com/api/projects/test'; AppInsightsConnectionString = 'test-telemetry'
  }
  foreach ($mode in @(@{}, @{ SkipTraffic = $true }, @{ BackgroundTraffic = $true })) {
    $fixture.Events.Clear()
    & (Join-Path $scriptDirectory 'setup-ai.ps1') @parameters @mode | Out-Null
    $expected = if ($mode.SkipTraffic) { 'dependencies,create_agents' } elseif ($mode.BackgroundTraffic) { 'dependencies,create_agents,background_traffic' } else { 'dependencies,create_agents,simulate_traffic' }
    if (($fixture.Events -join ',') -ne $expected) { throw 'AI setup did not preserve foreground, background, and skip behavior.' }
  }
  foreach ($failure in @('dependencies', 'create_agents', 'background_traffic')) {
    $fixture.Fail = $failure
    $fixture.Events.Clear()
    $rejected = $false
    try { & (Join-Path $scriptDirectory 'setup-ai.ps1') @parameters -BackgroundTraffic | Out-Null } catch { $rejected = $true }
    if (-not $rejected -or $fixture.Events[$fixture.Events.Count - 1] -ne $failure) { throw 'Failed AI setup continued or reported a successful launch.' }
  }
  $fixture.Fail = ''
  $fixture.State = 'failed'
  $rejected = $false
  try { & (Join-Path $scriptDirectory 'setup-ai.ps1') @parameters -BackgroundTraffic | Out-Null } catch { $rejected = $true }
  if (-not $rejected) { throw 'A failed worker must not be reported as running.' }
  $fixture.Events.Clear()
  $rejected = $false
  try { & (Join-Path $scriptDirectory 'setup-ai.ps1') @parameters -SkipTraffic -BackgroundTraffic | Out-Null } catch { $rejected = $true }
  if (-not $rejected -or $fixture.Events.Count) { throw 'Conflicting traffic modes must fail before setup.' }
  Write-Output 'PASS: AI setup preserves foreground/skip behavior, launches finite background traffic after agents, and reports startup failures. No Azure calls.'
} finally {
  foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name]) }
  Remove-Item -LiteralPath $root -Recurse -Force
}