[CmdletBinding()]
param([string] $BicepExecutable)

$ErrorActionPreference = 'Stop'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $BicepExecutable) {
  $binary = if ($IsWindows) { 'bicep.exe' } else { 'bicep' }
  $BicepExecutable = Join-Path $HOME ".azure/bin/$binary"
}
$version = & $BicepExecutable --version
if ($LASTEXITCODE -ne 0 -or $version -notmatch '^Bicep CLI version 0\.37\.4\b') { throw 'Compile templates with Bicep 0.37.4 to match the checked-in artifacts.' }
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('amlab-template-check-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temporary
try {
  foreach ($relative in @('infra/main', 'infra/stages/10-workloads', 'infra/modules/lab-console-platform', 'infra/modules/lab-console-job')) {
    $compiled = Join-Path $temporary ([IO.Path]::GetFileName($relative) + '.json')
    $messages = @(& $BicepExecutable build (Join-Path $source "$relative.bicep") --outfile $compiled 2>&1)
    if ($LASTEXITCODE -ne 0) { $messages; throw "Bicep compilation failed: $relative" }
    $actual = Get-Content -LiteralPath $compiled -Raw | ConvertFrom-Json -AsHashtable | ConvertTo-Json -Depth 100 -Compress
    $expected = Get-Content -LiteralPath (Join-Path $source "$relative.json") -Raw | ConvertFrom-Json -AsHashtable | ConvertTo-Json -Depth 100 -Compress
    if ($actual -cne $expected) { throw "$relative.json differs from its Bicep source. Regenerate it before publishing." }
    Write-Output "PASS: $relative.json matches its Bicep source."
  }
} finally { Remove-Item -LiteralPath $temporary -Recurse -Force }
