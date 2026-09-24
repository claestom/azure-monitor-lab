[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $Destination,
  [ValidateSet('linux-x64', 'win32-x64')] [string] $Platform = 'linux-x64'
)

$ErrorActionPreference = 'Stop'
$version = '3.0.0-beta.42'
if (Test-Path -LiteralPath $Destination) { throw 'Choose a new destination directory for the pinned MCP runtime.' }
$null = Get-Command npm -ErrorAction Stop
$null = Get-Command tar -ErrorAction Stop
$temporary = Join-Path ([IO.Path]::GetTempPath()) "amlab-mcp-package-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $temporary
try {
  $packed = npm pack "@azure/mcp-$Platform@$version" --ignore-scripts --json --pack-destination $temporary
  if ($LASTEXITCODE -ne 0) { throw 'Unable to download the pinned Azure MCP package.' }
  $metadata = @($packed | ConvertFrom-Json)
  if ($metadata.Count -ne 1 -or $metadata[0].version -ne $version -or $metadata[0].name -ne "@azure/mcp-$Platform") { throw 'Unexpected MCP package identity.' }
  $archive = Join-Path $temporary ([IO.Path]::GetFileName($metadata[0].filename))
  $integrity = 'sha512-' + [Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData([IO.File]::ReadAllBytes($archive)))
  if ($integrity -cne $metadata[0].integrity) { throw 'MCP package integrity verification failed.' }
  tar -xzf $archive -C $temporary
  if ($LASTEXITCODE -ne 0) { throw 'Unable to extract Azure MCP runtime.' }
  $executable = if ($Platform -eq 'win32-x64') { 'azmcp.exe' } else { 'azmcp' }
  if (-not (Test-Path (Join-Path $temporary "package/dist/$executable"))) { throw 'MCP package has no native executable.' }
  $null = New-Item -ItemType Directory -Path $Destination
  Copy-Item -Path (Join-Path $temporary 'package/dist/*') -Destination $Destination -Recurse
  foreach ($notice in @('LICENSE', 'NOTICE.txt', 'package.json')) {
    Copy-Item -LiteralPath (Join-Path $temporary "package/$notice") -Destination $Destination
  }
  Write-Host "Azure MCP $version ($Platform) installed in $Destination. No Azure operation was performed."
} finally {
  Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}