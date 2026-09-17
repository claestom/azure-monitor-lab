[CmdletBinding()]
param([string] $BicepExecutable)

$ErrorActionPreference = 'Stop'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$mainTemplate = Get-Content -LiteralPath (Join-Path $source 'infra/main.json') -Raw | ConvertFrom-Json
$cpuAlerts = @($mainTemplate.resources | Where-Object name -eq 'alert-vm-cpu-dynamic')
if ($cpuAlerts.Count -ne 1 -or $cpuAlerts[0].type -ne 'Microsoft.Insights/metricAlerts') { throw 'The main template must contain exactly one dynamic VM CPU metric alert.' }
$cpuAlert = $cpuAlerts[0].properties
if ($cpuAlert.evaluationFrequency -ne 'PT5M' -or $cpuAlert.windowSize -ne 'PT15M') { throw 'The dynamic VM CPU alert must check every 5 minutes with a 15-minute lookback.' }
$cpuCriteria = @($cpuAlert.criteria.allOf)
if ($cpuCriteria.Count -ne 1) { throw 'The dynamic VM CPU alert must have exactly one metric condition.' }
$cpuCriterion = $cpuCriteria[0]
if ($cpuCriterion.criterionType -ne 'DynamicThresholdCriterion' -or $cpuCriterion.metricNamespace -ne 'Microsoft.Compute/virtualMachines' -or $cpuCriterion.metricName -ne 'Percentage CPU' -or
    $cpuCriterion.operator -ne 'GreaterThan' -or $cpuCriterion.timeAggregation -ne 'Average' -or $cpuCriterion.alertSensitivity -ne 'Medium') {
  throw 'The dynamic VM CPU alert must detect above-baseline average Percentage CPU with medium sensitivity.'
}
if ($cpuCriterion.failingPeriods.numberOfEvaluationPeriods -ne 1 -or $cpuCriterion.failingPeriods.minFailingPeriodsToAlert -ne 1) { throw 'The dynamic VM CPU alert must require one violation out of one aggregated point.' }
if ($cpuCriterion.PSObject.Properties.Name -contains 'ignoreDataBefore') { throw 'The dynamic VM CPU alert must not discard its metric history by default.' }
Write-Output 'PASS: dynamic VM CPU alert defaults use a 5-minute check, 15-minute lookback, and one upper-threshold violation.'
if (-not $BicepExecutable) {
  $binary = if ($IsWindows) { 'bicep.exe' } else { 'bicep' }
  $BicepExecutable = Join-Path $HOME ".azure/bin/$binary"
}
$version = & $BicepExecutable --version
if ($LASTEXITCODE -ne 0 -or $version -notmatch '^Bicep CLI version 0\.37\.4\b') { throw 'Compile templates with Bicep 0.37.4 to match the checked-in artifacts.' }
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('amlab-template-check-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temporary
try {
  foreach ($relative in @('infra/main', 'infra/stages/00-foundation', 'infra/stages/10-workloads', 'infra/stages/40-optional-advanced', 'infra/stages/60-fabric', 'infra/modules/lab-console-platform', 'infra/modules/lab-console-job')) {
    $compiled = Join-Path $temporary ([IO.Path]::GetFileName($relative) + '.json')
    $messages = @(& $BicepExecutable build (Join-Path $source "$relative.bicep") --outfile $compiled 2>&1)
    if ($LASTEXITCODE -ne 0) { $messages; throw "Bicep compilation failed: $relative" }
    $actual = Get-Content -LiteralPath $compiled -Raw | ConvertFrom-Json -AsHashtable | ConvertTo-Json -Depth 100 -Compress
    $expected = Get-Content -LiteralPath (Join-Path $source "$relative.json") -Raw | ConvertFrom-Json -AsHashtable | ConvertTo-Json -Depth 100 -Compress
    if ($actual -cne $expected) { throw "$relative.json differs from its Bicep source. Regenerate it before publishing." }
    Write-Output "PASS: $relative.json matches its Bicep source."
  }
} finally { Remove-Item -LiteralPath $temporary -Recurse -Force }
