#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$WindowsImage = 'nationalinstruments/labview:2026q1-windows',
  [string]$LinuxImage = 'nationalinstruments/labview:latest-linux',
  [string]$ToolchainLockPath = 'toolchain-lock.json',
  [switch]$SkipPull
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath {
  param([Parameter(Mandatory)][string]$PathValue)
  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return [System.IO.Path]::GetFullPath($PathValue)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $PathValue))
}

function Get-DockerOsType {
  $value = (& docker info --format '{{.OSType}}' 2>$null)
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
    throw 'Unable to query docker info. Ensure Docker Desktop is running.'
  }
  return $value.Trim().ToLowerInvariant()
}

function Get-DockerCliPath {
  if (-not [string]::Equals($env:OS, 'Windows_NT', [System.StringComparison]::OrdinalIgnoreCase)) {
    return $null
  }
  $candidate = Join-Path $env:ProgramFiles 'Docker\Docker\DockerCli.exe'
  if (Test-Path -LiteralPath $candidate -PathType Leaf) {
    return $candidate
  }
  return $null
}

function Switch-DockerEngine {
  param(
    [Parameter(Mandatory)][ValidateSet('windows', 'linux')][string]$Target,
    [int]$TimeoutSeconds = 180
  )

  $current = Get-DockerOsType
  if ($current -eq $Target) {
    return
  }

  $dockerCli = Get-DockerCliPath
  if ([string]::IsNullOrWhiteSpace($dockerCli)) {
    throw ("Docker engine is '{0}' and cannot auto-switch to '{1}' on this host." -f $current, $Target)
  }

  $switchArg = if ($Target -eq 'windows') { '-SwitchWindowsEngine' } else { '-SwitchLinuxEngine' }
  & $dockerCli $switchArg
  if ($LASTEXITCODE -ne 0) {
    throw ("Failed to request docker engine switch to '{0}'." -f $Target)
  }

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    Start-Sleep -Seconds 2
    $observed = $null
    try { $observed = Get-DockerOsType } catch { $observed = $null }
    if ($observed -eq $Target) { return }
  } while ((Get-Date) -lt $deadline)

  throw ("Timed out waiting for docker engine '{0}'." -f $Target)
}

function Ensure-ImagePresent {
  param([Parameter(Mandatory)][string]$Image)
  & docker image inspect $Image *> $null
  if ($LASTEXITCODE -eq 0) {
    return
  }
  if ($SkipPull) {
    throw ("Docker image not present locally and -SkipPull was supplied: {0}" -f $Image)
  }
  Write-Host ("Pulling {0}" -f $Image) -ForegroundColor Cyan
  & docker pull $Image
  if ($LASTEXITCODE -ne 0) {
    throw ("Unable to pull docker image: {0}" -f $Image)
  }
}

function Get-ImageDigest {
  param([Parameter(Mandatory)][string]$Image)
  $value = (& docker image inspect $Image --format '{{join .RepoDigests "\n"}}' 2>$null)
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
    throw ("Unable to read RepoDigests for image: {0}" -f $Image)
  }
  $line = @($value -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
  if ($line.Count -eq 0 -or ($line[0] -notmatch '@')) {
    throw ("RepoDigest format unexpected for image: {0}" -f $Image)
  }
  return (($line[0] -split '@', 2)[1]).Trim()
}

$resolvedLockPath = Resolve-FullPath -PathValue $ToolchainLockPath
if (-not (Test-Path -LiteralPath $resolvedLockPath -PathType Leaf)) {
  throw ("Toolchain lock file not found: {0}" -f $resolvedLockPath)
}

$lock = Get-Content -LiteralPath $resolvedLockPath -Raw | ConvertFrom-Json -Depth 16
if ($lock.schema -ne 'pr-vi-history-toolchain-lock@v1') {
  throw ("Unexpected toolchain lock schema '{0}'." -f $lock.schema)
}

Switch-DockerEngine -Target 'windows'
Ensure-ImagePresent -Image $WindowsImage
$windowsDigest = Get-ImageDigest -Image $WindowsImage

Switch-DockerEngine -Target 'linux'
Ensure-ImagePresent -Image $LinuxImage
$linuxDigest = Get-ImageDigest -Image $LinuxImage

$lock.generatedAt = (Get-Date).ToUniversalTime().ToString('o')
$lock.images.windows.sourceTag = $WindowsImage
$lock.images.windows.sourceConfigDigest = $windowsDigest
$lock.images.linux.sourceTag = $LinuxImage
$lock.images.linux.sourceConfigDigest = $linuxDigest

$lock | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $resolvedLockPath -Encoding utf8

Write-Host ("Updated {0}" -f $resolvedLockPath) -ForegroundColor Green
Write-Host ("Windows: {0} @ {1}" -f $WindowsImage, $windowsDigest)
Write-Host ("Linux:   {0} @ {1}" -f $LinuxImage, $linuxDigest)
