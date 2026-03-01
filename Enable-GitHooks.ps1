#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$HooksPath = '.githooks'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (git rev-parse --show-toplevel 2>$null).Trim()
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
  throw 'Unable to resolve repository root via git rev-parse.'
}

Push-Location $repoRoot
try {
  $hooksFullPath = if ([System.IO.Path]::IsPathRooted($HooksPath)) {
    [System.IO.Path]::GetFullPath($HooksPath)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $HooksPath))
  }

  if (-not (Test-Path -LiteralPath $hooksFullPath -PathType Container)) {
    throw ("Hooks directory not found: {0}" -f $hooksFullPath)
  }

  $prePushHook = Join-Path $hooksFullPath 'pre-push'
  if (-not (Test-Path -LiteralPath $prePushHook -PathType Leaf)) {
    throw ("pre-push hook not found: {0}" -f $prePushHook)
  }

  git config core.hooksPath $HooksPath
  if ($LASTEXITCODE -ne 0) {
    throw 'Failed to set git core.hooksPath.'
  }

  Write-Host ("Configured git core.hooksPath -> {0}" -f $HooksPath) -ForegroundColor Green
  Write-Host ("Pre-push gate: {0}" -f $prePushHook)
  Write-Host 'Optional waivers: set PRVI_FAST_LOOP_WAIVERS=lane:signature:reference[, ...]'
}
finally {
  Pop-Location
}
