$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot '../../../scripts/prepare-webapp-package.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) "console-package-test-$([guid]::NewGuid().ToString('N'))"
$state = @{ Sre = $false; FailPackage = $false; Packages = 0 }

function az {
  $global:LASTEXITCODE = 0
  if ($args[0] -ne 'resource' -or $args[1] -ne 'list' -or $args -notcontains '--subscription' -or $args -notcontains 'test-sub') {
    throw 'The package helper must use explicitly scoped read-only discovery.'
  }
  if ($state.Sre) { return '[{"type":"Microsoft.App/agents","name":"sre-test","id":"/subscriptions/test-sub/resourceGroups/test-rg/providers/Microsoft.App/agents/sre-test"}]' }
  return '[]'
}

function npm {
  $state.Packages++
  if ($state.FailPackage) { $global:LASTEXITCODE = 1; return '' }
  $global:LASTEXITCODE = 0
  $directory = $args[[Array]::IndexOf($args, '--pack-destination') + 1]
  $archive = Join-Path $directory 'test-package.tgz'
  [IO.File]::WriteAllText($archive, 'offline package fixture')
  $integrity = 'sha512-' + [Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData([IO.File]::ReadAllBytes($archive)))
  @{ name = '@azure/mcp-linux-x64'; version = '3.0.0-beta.42'; filename = 'test-package.tgz'; integrity = $integrity } | ConvertTo-Json
}

function tar {
  $global:LASTEXITCODE = 0
  $directory = $args[[Array]::IndexOf($args, '-C') + 1]
  $null = New-Item -ItemType Directory -Path (Join-Path $directory 'package/dist') -Force
  foreach ($file in @('dist/azmcp', 'LICENSE', 'NOTICE.txt', 'package.json')) {
    [IO.File]::WriteAllText((Join-Path $directory "package/$file"), 'offline runtime fixture')
  }
}

function New-PublishedFixture([string] $Name) {
  $directory = Join-Path $root $Name
  $null = New-Item -ItemType Directory -Path (Join-Path $directory 'wwwroot') -Force
  [IO.File]::WriteAllText((Join-Path $directory 'AmlabHello.dll'), 'offline assembly fixture')
  [IO.File]::WriteAllText((Join-Path $directory 'wwwroot/index.html'), 'Welcome to the Azure Monitor Lab')
  return $directory
}

try {
  $basic = New-PublishedFixture 'basic'
  & $helper -PublishDirectory $basic -ResourceGroup test-rg -SubscriptionId test-sub -TenantId test-tenant
  $config = Get-Content (Join-Path $basic 'lab-console.json') -Raw | ConvertFrom-Json
  if ($state.Packages -ne 0 -or $config.LabConsole.Sre.McpExecutable) { throw 'Basic deployment unexpectedly required MCP.' }
  if ($config.LabConsole.Foundry.Enabled -or $config.LabConsole.Sre.Enabled) { throw 'Agent execution must stay opt-in.' }

  $state.Sre = $true
  $sre = New-PublishedFixture 'sre'
  & $helper -PublishDirectory $sre -ResourceGroup test-rg -SubscriptionId test-sub -TenantId test-tenant
  $config = Get-Content (Join-Path $sre 'lab-console.json') -Raw | ConvertFrom-Json
  if ($state.Packages -ne 1 -or $config.LabConsole.Sre.McpExecutable -ne 'mcp/azmcp') { throw 'Normal SRE deployment did not automatically include MCP.' }
  if (-not (Test-Path (Join-Path $sre 'mcp/azmcp'))) { throw 'Native MCP executable missing from package.' }
  if ($config.LabConsole.Sre.TenantId -ne 'test-tenant' -or $config.LabConsole.Sre.AgentName -ne 'sre-test') { throw 'Discovered SRE context missing.' }
  if ($config.LabConsole.Sre.Enabled -or $config.LabConsole.Foundry.Enabled) { throw 'Packaging must not enable billable agent execution.' }

  $state.FailPackage = $true
  $failed = New-PublishedFixture 'failed'
  $caught = $false
  try { & $helper -PublishDirectory $failed -ResourceGroup test-rg -SubscriptionId test-sub -TenantId test-tenant } catch { $caught = $true }
  if (-not $caught) { throw 'MCP packaging failure was silently accepted.' }
  $caught = $false
  try { & $helper -PublishDirectory (Join-Path $root 'missing') -ResourceGroup test-rg -SubscriptionId test-sub -TenantId test-tenant } catch { $caught = $true }
  if (-not $caught) { throw 'Incomplete web app publish was accepted.' }
  Write-Host 'PASS: normal lab packaging, automatic SRE runtime inclusion, disabled execution, and fail-closed publishing.'
} finally {
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}