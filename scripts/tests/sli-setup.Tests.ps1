$ErrorActionPreference = 'Stop'
$previousExitCode = $global:LASTEXITCODE
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$root = Join-Path ([IO.Path]::GetTempPath()) ('sli-setup-test-' + [guid]::NewGuid().ToString('N'))
$directory = Join-Path $root 'scripts'
$null = New-Item -ItemType Directory -Path $directory -Force
Copy-Item -LiteralPath (Join-Path $source 'scripts/setup-slis.ps1') -Destination $directory
$fixture = @{
  Subscription = [guid]::NewGuid(); Tenant = [guid]::NewGuid(); Principal = [guid]::NewGuid()
  Mode = 'unsupported'; Queries = 0; TokenRequests = 0; Token = [guid]::NewGuid().ToString('N')
  Diagnostic = [guid]::NewGuid().ToString('N'); ExplicitSubscription = $false
}

function az {
  $global:LASTEXITCODE = 0
  switch ($args[0..1] -join ' ') {
    'account set' {
      if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription.ToString()) { throw 'Wrong subscription selected.' }
    }
    'account show' { return @{ id = $fixture.Subscription; tenantId = $fixture.Tenant } | ConvertTo-Json }
    'rest --method' {
      if ($args[2] -ne 'get') { throw 'Unexpected service group write.' }
      return '{"properties":{"provisioningState":"Succeeded"}}'
    }
    'identity show' { return @{ id = 'test-identity'; clientId = $fixture.Principal; principalId = $fixture.Principal } | ConvertTo-Json }
    'resource show' {
      return @{
        id = 'test-amw'
        properties = @{
          defaultIngestionSettings = @{ dataCollectionRuleResourceId = 'test-dcr'; dataCollectionEndpointResourceId = 'test-dce' }
          metrics = @{ prometheusQueryEndpoint = 'https://example.com' }
        }
      } | ConvertTo-Json -Depth 4
    }
    'role assignment' {
      if ($args[2] -ne 'list') { throw 'Existing SLI roles must be reused.' }
      return ConvertTo-Json -InputObject @(
        @{ roleDefinitionId = '/roles/43d0d8ad-25c7-4714-9337-8ba259a9fe05' },
        @{ roleDefinitionId = '/roles/3913510d-42f4-4e42-8a64-420c390055eb' }
      )
    }
    'account get-access-token' {
      $fixture.TokenRequests++
      if ($args[[Array]::IndexOf($args, '--resource') + 1] -ne 'https://prometheus.monitor.azure.com') { throw 'The Prometheus token audience must not be changed.' }
      $fixture.ExplicitSubscription = $args -contains '--subscription' -and $args[[Array]::IndexOf($args, '--subscription') + 1] -eq $fixture.Subscription.ToString()
      if ($fixture.Mode -eq 'unsupported-native') {
        $shell = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
        & $shell -NoProfile -NonInteractive -Command "[Console]::Error.WriteLine('ERROR: Audience https://prometheus.monitor.azure.com is not a supported MSI token audience.'); exit 1"
        $global:LASTEXITCODE = $LASTEXITCODE
        return
      }
      if ($fixture.Mode -eq 'unsupported') {
        $global:LASTEXITCODE = 1
        Write-Error "Audience https://prometheus.monitor.azure.com is not a supported MSI token audience. $($fixture.Diagnostic)" -ErrorAction Continue
        return
      }
      if ($fixture.Mode -eq 'authentication') {
        $global:LASTEXITCODE = 1
        Write-Error "Authentication failed. $($fixture.Diagnostic)" -ErrorAction Continue
        return
      }
      if ($fixture.Mode -eq 'empty') { return '' }
      return $fixture.Token
    }
    default { throw 'Unexpected Azure request, including automatic login/logout.' }
  }
}

function Invoke-RestMethod {
  param($Method, $Uri, $Headers, $TimeoutSec)
  $fixture.Queries++
  if ($Headers.Authorization -ne "Bearer $($fixture.Token)" -or $Method -ne 'Get' -or $Uri -notlike 'https://example.com/api/v1/query?query=*') { throw 'Invalid Prometheus query request.' }
  if ($fixture.Mode -eq 'query-error') { throw 'Prometheus query denied.' }
  $results = if ($fixture.Mode -eq 'missing') { @() } else { @(@{ value = @(0, '1') }) }
  return @{ data = @{ result = $results } }
}

function Start-Sleep { throw 'Zero-wait regression must not sleep.' }

function Invoke-TestSliSetup {
  $fixture.Queries = 0
  $fixture.TokenRequests = 0
  $messages = [Collections.Generic.List[string]]::new()
  $failure = ''
  try {
    & (Join-Path $directory 'setup-slis.ps1') -SubscriptionId $fixture.Subscription -ResourceGroup test-rg -MetricWaitMinutes 0 *>&1 |
      ForEach-Object { $messages.Add([string]$_) }
  } catch { $failure = $_.Exception.Message }
  $text = $messages -join "`n"
  if ($text.Contains($fixture.Token) -or $text.Contains($fixture.Diagnostic) -or $failure.Contains($fixture.Token) -or $failure.Contains($fixture.Diagnostic)) {
    throw 'Token or raw credential diagnostics leaked into output.'
  }
  return @{ Text = $text; Failure = $failure }
}

try {
  foreach ($nativePreference in @($false, $true)) {
    $PSNativeCommandUseErrorActionPreference = $nativePreference
    foreach ($mode in @('unsupported', 'unsupported-native')) {
      $fixture.Mode = $mode
      $result = Invoke-TestSliSetup
      if ($result.Failure -notlike '*Cloud Shell*' -or
          -not $result.Failure.Contains('az account clear') -or
          -not $result.Failure.Contains("az login --tenant $($fixture.Tenant) --use-device-code --scope https://prometheus.monitor.azure.com/.default") -or
          -not $result.Failure.Contains("az account set --subscription $($fixture.Subscription)") -or
          $result.Failure -notlike '*setup-slis.ps1*' -or $fixture.Queries -or $fixture.TokenRequests -ne 1) {
        throw 'Unsupported Cloud Shell audience must stop before queries and provide tenant-scoped sign-in plus a targeted SLI retry.'
      }
      if ($PSNativeCommandUseErrorActionPreference -ne $nativePreference) { throw 'The helper changed its caller native-error preference.' }
    }
  }
  foreach ($mode in @('authentication', 'empty', 'query-error', 'missing')) {
    $fixture.Mode = $mode
    $result = Invoke-TestSliSetup
    if (-not $result.Failure -or $result.Text -match 'All four documented source metrics are currently flowing') { throw 'Unverified metrics must never be reported as ready.' }
    if ($mode -in @('authentication', 'empty') -and $fixture.Queries) { throw 'Token failure must stop before queries.' }
    if ($mode -eq 'authentication' -and $result.Failure -like '*supported MSI token audience*') { throw 'Unrelated authentication failures must not be classified as the Cloud Shell restriction.' }
  }
  $fixture.Mode = 'success'
  $result = Invoke-TestSliSetup
  if ($result.Failure -or $fixture.Queries -ne 4 -or -not $fixture.ExplicitSubscription -or
      $result.Text -notmatch 'All four documented source metrics are currently flowing') { throw 'Successful SLI verification must query all four metrics with a subscription-scoped token.' }
  $readme = Get-Content -LiteralPath (Join-Path $source 'README.md') -Raw
  $portalCommands = [regex]::Match($readme, '(?s)### Option 1:.*?```powershell(?<commands>.*?)```').Groups['commands'].Value
  $scopedLogin = 'az login --tenant $tenantId --use-device-code --scope https://prometheus.monitor.azure.com/.default'
  if ($portalCommands -notmatch 'az account clear' -or -not $portalCommands.Contains($scopedLogin) -or
      $portalCommands.IndexOf('az account clear') -gt $portalCommands.IndexOf($scopedLogin) -or
      $portalCommands.IndexOf($scopedLogin) -gt $portalCommands.IndexOf('./scripts/post-cloud-shell-deploy.ps1')) {
    throw 'The portal quick-start must replace the cached Cloud Shell account and request the Prometheus scope before post-deployment.'
  }
  Write-Output 'PASS: Cloud Shell audience errors give scoped device-code recovery without leaking credentials or changing sign-in; other failures stop; all four metrics remain required. No Azure calls.'
} finally {
  Remove-Item -LiteralPath $root -Recurse -Force
  $global:LASTEXITCODE = $previousExitCode
}