#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$WindowsImage = 'nationalinstruments/labview:2026q1-windows',
  [string]$LinuxImage = 'nationalinstruments/labview:latest-linux',
  [string]$ToolchainLockPath = 'toolchain-lock.json',
  [string]$SmokeBaseViPath = 'fixtures/smoke/Base.vi',
  [string]$SmokeHeadViPath = 'fixtures/smoke/Base.vi',
  [string]$StrictBaseViPath = 'fixtures/smoke/Base.vi',
  [string]$StrictHeadViPath = 'fixtures/smoke/Head.vi',
  [string[]]$Waiver = @(),
  [switch]$RunStrictDiff,
  [string]$SummaryPath,
  [switch]$SkipPull
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot '..'))

$allowedWaiverLanes = @(
  'windows-smoke',
  'linux-smoke',
  'windows-strict',
  'linux-strict',
  'drift'
)

function Resolve-FullPath {
  param(
    [Parameter(Mandatory)][string]$PathValue,
    [string]$BasePath = (Get-Location).Path
  )
  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return [System.IO.Path]::GetFullPath($PathValue)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $BasePath $PathValue))
}

function Ensure-Directory {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Resolve-ExistingFile {
  param(
    [Parameter(Mandatory)][string]$PathValue,
    [Parameter(Mandatory)][string]$Description,
    [string]$BasePath = (Get-Location).Path
  )
  $full = Resolve-FullPath -PathValue $PathValue -BasePath $BasePath
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
    throw ("{0} not found: {1}" -f $Description, $full)
  }
  return $full
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
    [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Events,
    [int]$TimeoutSeconds = 180
  )

  $current = Get-DockerOsType
  if ($current -eq $Target) {
    $Events.Add([ordered]@{
      switched = $false
      from = $current
      to = $Target
      at = (Get-Date).ToUniversalTime().ToString('o')
    }) | Out-Null
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
  $observed = $null
  do {
    Start-Sleep -Seconds 2
    try { $observed = Get-DockerOsType } catch { $observed = $null }
    if ($observed -eq $Target) {
      $Events.Add([ordered]@{
        switched = $true
        from = $current
        to = $Target
        at = (Get-Date).ToUniversalTime().ToString('o')
      }) | Out-Null
      return
    }
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

function Parse-Waivers {
  param([string[]]$Values)
  $parsed = New-Object System.Collections.Generic.List[object]
  foreach ($item in @($Values)) {
    if ([string]::IsNullOrWhiteSpace($item)) { continue }
    $token = $item.Trim()
    $match = [regex]::Match($token, '^(?<lane>[a-z-]+):(?<signature>[^:]+):(?<reference>.+)$')
    if (-not $match.Success) {
      throw ("Invalid waiver token '{0}'. Expected lane:signature:reference." -f $token)
    }
    $lane = $match.Groups['lane'].Value
    if ($allowedWaiverLanes -notcontains $lane) {
      throw ("Invalid waiver lane '{0}' in token '{1}'." -f $lane, $token)
    }
    $signature = $match.Groups['signature'].Value.Trim()
    $reference = $match.Groups['reference'].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($signature) -or [string]::IsNullOrWhiteSpace($reference)) {
      throw ("Invalid waiver token '{0}'. Signature and reference are required." -f $token)
    }
    $parsed.Add([ordered]@{
      token = $token
      lane = $lane
      signature = $signature
      reference = $reference
    }) | Out-Null
  }
  return @($parsed.ToArray())
}

function Find-Waiver {
  param(
    [AllowNull()][object[]]$Waivers,
    [Parameter(Mandatory)][string]$Lane,
    [Parameter(Mandatory)][string]$Signature
  )
  if ($null -eq $Waivers) {
    return $null
  }
  foreach ($waiver in $Waivers) {
    if ($waiver.lane -ne $Lane) { continue }
    if ($waiver.signature -eq $Signature -or $waiver.signature -eq '*') {
      return $waiver
    }
  }
  return $null
}

function Invoke-PwshFile {
  param(
    [Parameter(Mandatory)][string]$ScriptPath,
    [Parameter(Mandatory)][string[]]$Arguments
  )
  $argList = @('-NoLogo', '-NoProfile', '-File', $ScriptPath) + $Arguments
  $output = & pwsh @argList 2>&1
  if ($output) {
    foreach ($line in @($output)) {
      Write-Host $line
    }
  }
  return [int]$LASTEXITCODE
}

function New-LaneResult {
  param([string]$Lane)
  return [ordered]@{
    lane = $Lane
    status = 'pending'
    exitCode = $null
    signature = $null
    message = $null
    waived = $false
    waiver = $null
    reportPath = $null
    capturePath = $null
  }
}

function Get-CaptureStatus {
  param([AllowNull()][string]$CapturePath)
  if ([string]::IsNullOrWhiteSpace($CapturePath)) { return $null }
  if (-not (Test-Path -LiteralPath $CapturePath -PathType Leaf)) { return $null }
  try {
    $capture = Get-Content -LiteralPath $CapturePath -Raw | ConvertFrom-Json -Depth 10
    if ($capture.PSObject.Properties['status']) {
      return [string]$capture.status
    }
  } catch {
    return $null
  }
  return $null
}

$lockPathResolved = Resolve-ExistingFile -PathValue $ToolchainLockPath -Description 'Toolchain lock file' -BasePath $repoRoot
$smokeBaseResolved = Resolve-ExistingFile -PathValue $SmokeBaseViPath -Description 'Smoke base VI' -BasePath $repoRoot
$smokeHeadResolved = Resolve-ExistingFile -PathValue $SmokeHeadViPath -Description 'Smoke head VI' -BasePath $repoRoot

$strictBaseResolved = $null
$strictHeadResolved = $null
if ($RunStrictDiff) {
  $strictBaseResolved = Resolve-ExistingFile -PathValue $StrictBaseViPath -Description 'Strict base VI' -BasePath $repoRoot
  $strictHeadResolved = Resolve-ExistingFile -PathValue $StrictHeadViPath -Description 'Strict head VI' -BasePath $repoRoot
}

$waiversParsed = Parse-Waivers -Values $Waiver
$lock = Get-Content -LiteralPath $lockPathResolved -Raw | ConvertFrom-Json -Depth 16
if ($lock.schema -ne 'pr-vi-history-toolchain-lock@v1') {
  throw ("Unexpected toolchain lock schema '{0}'." -f $lock.schema)
}

$engineEvents = New-Object System.Collections.Generic.List[object]
$results = [ordered]@{
  driftWindows = [ordered]@{}
  driftLinux = [ordered]@{}
  windowsSmoke = New-LaneResult -Lane 'windows-smoke'
  linuxSmoke = New-LaneResult -Lane 'linux-smoke'
  windowsStrict = New-LaneResult -Lane 'windows-strict'
  linuxStrict = New-LaneResult -Lane 'linux-strict'
}

$localParityRoot = Join-Path $repoRoot 'tests/results/local-parity'
Ensure-Directory -Path $localParityRoot

try {
  Switch-DockerEngine -Target 'windows' -Events $engineEvents
  Ensure-ImagePresent -Image $WindowsImage
  $windowsDigest = Get-ImageDigest -Image $WindowsImage
  $expectedWindowsDigest = [string]$lock.images.windows.sourceConfigDigest
  $windowsDigestMatch = [string]::Equals($windowsDigest, $expectedWindowsDigest, [System.StringComparison]::OrdinalIgnoreCase)
  $results.driftWindows = [ordered]@{
    lane = 'drift'
    side = 'windows'
    image = $WindowsImage
    expectedDigest = $expectedWindowsDigest
    observedDigest = $windowsDigest
    match = $windowsDigestMatch
    signature = if ($windowsDigestMatch) { 'ok' } else { 'windows-digest-mismatch' }
    waived = $false
    waiver = $null
  }
  if (-not $windowsDigestMatch) {
    $waiverHit = Find-Waiver -Waivers $waiversParsed -Lane 'drift' -Signature 'windows-digest-mismatch'
    if ($waiverHit) {
      $results.driftWindows.waived = $true
      $results.driftWindows.waiver = $waiverHit
    }
  }

  $windowsSmokeDir = Join-Path $localParityRoot 'windows-smoke'
  Ensure-Directory -Path $windowsSmokeDir
  $windowsSmokeReport = Join-Path $windowsSmokeDir 'compare-report.html'
  $windowsRunnerScript = Join-Path $repoRoot 'tools/Run-NIWindowsContainerCompare.ps1'
  $probeExit = Invoke-PwshFile -ScriptPath $windowsRunnerScript -Arguments @('-Probe', '-Image', $WindowsImage)
  if ($probeExit -ne 0) {
    $results.windowsSmoke.status = 'failed'
    $results.windowsSmoke.exitCode = $probeExit
    $results.windowsSmoke.signature = 'probe-failed'
    $results.windowsSmoke.message = 'Windows probe failed.'
  } else {
    $compareExit = Invoke-PwshFile -ScriptPath $windowsRunnerScript -Arguments @(
      '-BaseVi', $smokeBaseResolved,
      '-HeadVi', $smokeHeadResolved,
      '-Image', $WindowsImage,
      '-ReportPath', $windowsSmokeReport,
      '-ReportType', 'html'
    )
    $results.windowsSmoke.exitCode = $compareExit
    $results.windowsSmoke.reportPath = $windowsSmokeReport
    $results.windowsSmoke.capturePath = Join-Path $windowsSmokeDir 'ni-windows-container-capture.json'
    $captureStatus = Get-CaptureStatus -CapturePath $results.windowsSmoke.capturePath
    if ($captureStatus -in @('ok', 'diff')) {
      $results.windowsSmoke.status = 'passed'
      $results.windowsSmoke.signature = if ($captureStatus -eq 'diff') { 'diff-detected' } else { 'ok' }
    } else {
      $results.windowsSmoke.status = 'failed'
      $results.windowsSmoke.signature = ("exit-{0}" -f $compareExit)
      $results.windowsSmoke.message = if ($captureStatus) {
        "Windows smoke compare failed (capture status: $captureStatus)."
      } else {
        'Windows smoke compare failed.'
      }
    }
  }
  if ($results.windowsSmoke.status -eq 'failed') {
    $waiverHit = Find-Waiver -Waivers $waiversParsed -Lane 'windows-smoke' -Signature $results.windowsSmoke.signature
    if (-not $waiverHit) {
      $waiverHit = Find-Waiver -Waivers $waiversParsed -Lane 'windows-smoke' -Signature '*'
    }
    if ($waiverHit) {
      $results.windowsSmoke.waived = $true
      $results.windowsSmoke.waiver = $waiverHit
    }
  }

  if ($RunStrictDiff) {
    $windowsStrictDir = Join-Path $localParityRoot 'windows-strict'
    Ensure-Directory -Path $windowsStrictDir
    $windowsStrictReport = Join-Path $windowsStrictDir 'compare-report.html'
    $strictExit = Invoke-PwshFile -ScriptPath $windowsRunnerScript -Arguments @(
      '-BaseVi', $strictBaseResolved,
      '-HeadVi', $strictHeadResolved,
      '-Image', $WindowsImage,
      '-ReportPath', $windowsStrictReport,
      '-ReportType', 'html'
    )
    $results.windowsStrict.exitCode = $strictExit
    $results.windowsStrict.reportPath = $windowsStrictReport
    $results.windowsStrict.capturePath = Join-Path $windowsStrictDir 'ni-windows-container-capture.json'
    $captureStatus = Get-CaptureStatus -CapturePath $results.windowsStrict.capturePath
    if ($captureStatus -in @('ok', 'diff')) {
      $results.windowsStrict.status = 'passed'
      $results.windowsStrict.signature = if ($captureStatus -eq 'diff') { 'diff-detected' } else { 'ok' }
    } else {
      $results.windowsStrict.status = 'failed'
      $results.windowsStrict.signature = ("exit-{0}" -f $strictExit)
      $results.windowsStrict.message = if ($captureStatus) {
        "Windows strict compare failed (capture status: $captureStatus)."
      } else {
        'Windows strict compare failed.'
      }
    }
    if ($results.windowsStrict.status -eq 'failed') {
      $waiverHit = Find-Waiver -Waivers $waiversParsed -Lane 'windows-strict' -Signature $results.windowsStrict.signature
      if (-not $waiverHit) {
        $waiverHit = Find-Waiver -Waivers $waiversParsed -Lane 'windows-strict' -Signature '*'
      }
      if ($waiverHit) {
        $results.windowsStrict.waived = $true
        $results.windowsStrict.waiver = $waiverHit
      }
    }
  } else {
    $results.windowsStrict.status = 'skipped'
    $results.windowsStrict.signature = 'strict-disabled'
  }

  Switch-DockerEngine -Target 'linux' -Events $engineEvents
  Ensure-ImagePresent -Image $LinuxImage
  $linuxDigest = Get-ImageDigest -Image $LinuxImage
  $expectedLinuxDigest = [string]$lock.images.linux.sourceConfigDigest
  $linuxDigestMatch = [string]::Equals($linuxDigest, $expectedLinuxDigest, [System.StringComparison]::OrdinalIgnoreCase)
  $results.driftLinux = [ordered]@{
    lane = 'drift'
    side = 'linux'
    image = $LinuxImage
    expectedDigest = $expectedLinuxDigest
    observedDigest = $linuxDigest
    match = $linuxDigestMatch
    signature = if ($linuxDigestMatch) { 'ok' } else { 'linux-digest-mismatch' }
    waived = $false
    waiver = $null
  }
  if (-not $linuxDigestMatch) {
    $waiverHit = Find-Waiver -Waivers $waiversParsed -Lane 'drift' -Signature 'linux-digest-mismatch'
    if ($waiverHit) {
      $results.driftLinux.waived = $true
      $results.driftLinux.waiver = $waiverHit
    }
  }

  $linuxRunnerScript = Join-Path $repoRoot 'tools/Run-NILinuxContainerCompare.ps1'
  $linuxSmokeDir = Join-Path $localParityRoot 'linux-smoke'
  Ensure-Directory -Path $linuxSmokeDir
  $linuxSmokeReport = Join-Path $linuxSmokeDir 'compare-report.html'
  $linuxProbeExit = Invoke-PwshFile -ScriptPath $linuxRunnerScript -Arguments @('-Probe', '-Image', $LinuxImage)
  if ($linuxProbeExit -ne 0) {
    $results.linuxSmoke.status = 'failed'
    $results.linuxSmoke.exitCode = $linuxProbeExit
    $results.linuxSmoke.signature = 'probe-failed'
    $results.linuxSmoke.message = 'Linux probe failed.'
  } else {
    $linuxSmokeExit = Invoke-PwshFile -ScriptPath $linuxRunnerScript -Arguments @(
      '-BaseVi', $smokeBaseResolved,
      '-HeadVi', $smokeHeadResolved,
      '-Image', $LinuxImage,
      '-ReportPath', $linuxSmokeReport,
      '-ReportType', 'html'
    )
    $results.linuxSmoke.exitCode = $linuxSmokeExit
    $results.linuxSmoke.reportPath = $linuxSmokeReport
    $results.linuxSmoke.capturePath = Join-Path $linuxSmokeDir 'ni-linux-container-capture.json'
    $captureStatus = Get-CaptureStatus -CapturePath $results.linuxSmoke.capturePath
    if ($captureStatus -in @('ok', 'diff')) {
      $results.linuxSmoke.status = 'passed'
      $results.linuxSmoke.signature = if ($captureStatus -eq 'diff') { 'diff-detected' } else { 'ok' }
    } else {
      $results.linuxSmoke.status = 'failed'
      $results.linuxSmoke.signature = ("exit-{0}" -f $linuxSmokeExit)
      $results.linuxSmoke.message = if ($captureStatus) {
        "Linux smoke compare failed (capture status: $captureStatus)."
      } else {
        'Linux smoke compare failed.'
      }
    }
  }
  if ($results.linuxSmoke.status -eq 'failed') {
    $waiverHit = Find-Waiver -Waivers $waiversParsed -Lane 'linux-smoke' -Signature $results.linuxSmoke.signature
    if (-not $waiverHit) {
      $waiverHit = Find-Waiver -Waivers $waiversParsed -Lane 'linux-smoke' -Signature '*'
    }
    if ($waiverHit) {
      $results.linuxSmoke.waived = $true
      $results.linuxSmoke.waiver = $waiverHit
    }
  }

  if ($RunStrictDiff) {
    $linuxStrictDir = Join-Path $localParityRoot 'linux-strict'
    Ensure-Directory -Path $linuxStrictDir
    $linuxStrictReport = Join-Path $linuxStrictDir 'compare-report.html'
    $linuxStrictExit = Invoke-PwshFile -ScriptPath $linuxRunnerScript -Arguments @(
      '-BaseVi', $strictBaseResolved,
      '-HeadVi', $strictHeadResolved,
      '-Image', $LinuxImage,
      '-ReportPath', $linuxStrictReport,
      '-ReportType', 'html'
    )
    $results.linuxStrict.exitCode = $linuxStrictExit
    $results.linuxStrict.reportPath = $linuxStrictReport
    $results.linuxStrict.capturePath = Join-Path $linuxStrictDir 'ni-linux-container-capture.json'
    $captureStatus = Get-CaptureStatus -CapturePath $results.linuxStrict.capturePath
    if ($captureStatus -in @('ok', 'diff')) {
      $results.linuxStrict.status = 'passed'
      $results.linuxStrict.signature = if ($captureStatus -eq 'diff') { 'diff-detected' } else { 'ok' }
    } else {
      $results.linuxStrict.status = 'failed'
      $results.linuxStrict.signature = ("exit-{0}" -f $linuxStrictExit)
      $results.linuxStrict.message = if ($captureStatus) {
        "Linux strict compare failed (capture status: $captureStatus)."
      } else {
        'Linux strict compare failed.'
      }
    }
    if ($results.linuxStrict.status -eq 'failed') {
      $waiverHit = Find-Waiver -Waivers $waiversParsed -Lane 'linux-strict' -Signature $results.linuxStrict.signature
      if (-not $waiverHit) {
        $waiverHit = Find-Waiver -Waivers $waiversParsed -Lane 'linux-strict' -Signature '*'
      }
      if ($waiverHit) {
        $results.linuxStrict.waived = $true
        $results.linuxStrict.waiver = $waiverHit
      }
    }
  } else {
    $results.linuxStrict.status = 'skipped'
    $results.linuxStrict.signature = 'strict-disabled'
  }
}
finally {
  try {
    Switch-DockerEngine -Target 'windows' -Events $engineEvents
  } catch {
    Write-Warning ("Unable to restore docker engine to windows mode: {0}" -f $_.Exception.Message)
  }
}

if ([string]::IsNullOrWhiteSpace($SummaryPath)) {
  $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
  $SummaryPath = Join-Path $localParityRoot ("docker-fast-loop-{0}.json" -f $stamp)
}
$summaryPathResolved = Resolve-FullPath -PathValue $SummaryPath -BasePath $repoRoot
Ensure-Directory -Path (Split-Path -Parent $summaryPathResolved)

$failures = New-Object System.Collections.Generic.List[string]

if (-not $results.driftWindows.match -and -not $results.driftWindows.waived) {
  $failures.Add('drift/windows') | Out-Null
}
if (-not $results.driftLinux.match -and -not $results.driftLinux.waived) {
  $failures.Add('drift/linux') | Out-Null
}
foreach ($laneName in @('windowsSmoke', 'linuxSmoke', 'windowsStrict', 'linuxStrict')) {
  $lane = $results[$laneName]
  if ($lane.status -eq 'failed' -and -not $lane.waived) {
    if (($laneName -like '*Strict') -and (-not $RunStrictDiff)) {
      continue
    }
    $failures.Add($lane.lane) | Out-Null
  }
}

$summary = [ordered]@{}
$summary.schema = 'pr-vi-history-docker-fast-loop@v1'
$summary.generatedAt = (Get-Date).ToUniversalTime().ToString('o')
$summary.status = if ($failures.Count -eq 0) { 'pass' } else { 'fail' }
$summary.repoRoot = $repoRoot
$summary.config = [ordered]@{
  windowsImage = $WindowsImage
  linuxImage = $LinuxImage
  toolchainLockPath = $lockPathResolved
  smokeBaseViPath = $smokeBaseResolved
  smokeHeadViPath = $smokeHeadResolved
  runStrictDiff = [bool]$RunStrictDiff
  strictBaseViPath = $strictBaseResolved
  strictHeadViPath = $strictHeadResolved
  skipPull = [bool]$SkipPull
}
$summary.waivers = [ordered]@{
  requested = @($waiversParsed)
}
$summary.docker = [ordered]@{
  engineEvents = @($engineEvents.ToArray())
}
$summary.results = $results
$summary.failures = @($failures.ToArray())

$summary | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $summaryPathResolved -Encoding utf8

Write-Host ("Fast loop summary: {0}" -f $summaryPathResolved)
if ($failures.Count -eq 0) {
  Write-Host 'Docker Desktop fast loop passed.' -ForegroundColor Green
  exit 0
}

Write-Host ("Docker Desktop fast loop failed: {0}" -f ($failures -join ', ')) -ForegroundColor Red
exit 1
