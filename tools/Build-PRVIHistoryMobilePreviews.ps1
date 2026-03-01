#Requires -Version 7.0
<#
.SYNOPSIS
  Builds mobile-optimized image previews from PR VI history artifacts.

.DESCRIPTION
  Scans artifact output for compare-report image assets and emits normalized
  preview variants (webp/png) at fixed widths. Produces a machine-readable
  manifest contract for downstream PR comment rendering.

.PARAMETER ArtifactRoot
  Root directory containing downloaded PR VI history artifacts.

.PARAMETER OutputDir
  Destination directory for generated preview assets.

.PARAMETER ManifestPath
  Output path for the preview manifest JSON.

.PARAMETER Widths
  Preview widths to generate. Defaults to 360 and 720.

.PARAMETER MaxSources
  Maximum source images to process.

.PARAMETER GitHubOutputPath
  Optional GitHub output file path for step outputs.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$ArtifactRoot,

  [string]$OutputDir,

  [string]$ManifestPath,

  [int[]]$Widths = @(360, 720),

  [int]$MaxSources = 12,

  [string]$GitHubOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath {
  param(
    [Parameter(Mandatory)][string]$PathValue,
    [Parameter(Mandatory)][string]$BaseDir
  )
  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return [System.IO.Path]::GetFullPath($PathValue)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $BaseDir $PathValue))
}

function Sanitize-Token {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return 'preview' }
  $token = ($Value -replace '[^A-Za-z0-9._-]', '_').Trim('_')
  if ([string]::IsNullOrWhiteSpace($token)) { return 'preview' }
  if ($token.Length -gt 64) { return $token.Substring(0, 64) }
  return $token
}

function Get-RelativePathSafe {
  param(
    [string]$PathValue,
    [string]$BaseDir
  )
  try {
    $full = [System.IO.Path]::GetFullPath($PathValue)
    $base = [System.IO.Path]::GetFullPath($BaseDir)
    if (-not $full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $full
    }
    return $full.Substring($base.Length).TrimStart('\','/').Replace('\','/')
  } catch {
    return $PathValue
  }
}

function Get-SourcePriority {
  param([string]$FullName)
  $path = $FullName.Replace('\','/').ToLowerInvariant()
  if ($path.Contains('/cli-images/')) { return 1 }
  if ($path.Contains('/report-assets/')) { return 2 }
  if ($path.Contains('/compare-report_files/')) { return 3 }
  if ($path.Contains('/mobile-preview/')) { return 9 }
  return 5
}

function Resolve-ImageTool {
  $magick = Get-Command -Name 'magick' -ErrorAction SilentlyContinue
  if ($magick) {
    return [pscustomobject]@{
      Name = 'magick'
      Path = $magick.Source
    }
  }

  $convert = Get-Command -Name 'convert' -ErrorAction SilentlyContinue
  if ($convert) {
    if ($IsWindows -and $convert.Source -match '(?i)\\windows\\system32\\convert\.exe$') {
      return $null
    }
    try {
      $versionOutput = & $convert.Source -version 2>&1
      if ($LASTEXITCODE -eq 0 -and ($versionOutput -join "`n") -match 'ImageMagick') {
        return [pscustomobject]@{
          Name = 'convert'
          Path = $convert.Source
        }
      }
    } catch {}
    return $null
  }

  return $null
}

function Invoke-ResizeImage {
  param(
    [Parameter(Mandatory)][pscustomobject]$Tool,
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][int]$Width
  )

  $resizeSpec = ('{0}x>' -f $Width)
  if ($Tool.Name -eq 'magick') {
    & $Tool.Path $SourcePath -auto-orient -strip -resize $resizeSpec $OutputPath
  } else {
    & $Tool.Path $SourcePath -auto-orient -strip -resize $resizeSpec $OutputPath
  }
  return ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $OutputPath -PathType Leaf))
}

function Write-OutputValue {
  param(
    [string]$OutputPath,
    [string]$Name,
    [string]$Value
  )
  if ([string]::IsNullOrWhiteSpace($OutputPath)) { return }
  Add-Content -LiteralPath $OutputPath -Value ("{0}={1}" -f $Name, $Value) -Encoding utf8
}

$resolvedArtifactRoot = if ([System.IO.Path]::IsPathRooted($ArtifactRoot)) {
  [System.IO.Path]::GetFullPath($ArtifactRoot)
} else {
  Resolve-FullPath -PathValue $ArtifactRoot -BaseDir (Get-Location).Path
}

$resolvedOutputDir = if ([string]::IsNullOrWhiteSpace($OutputDir)) {
  Join-Path $resolvedArtifactRoot 'mobile-preview'
} else {
  Resolve-FullPath -PathValue $OutputDir -BaseDir $resolvedArtifactRoot
}

$resolvedManifestPath = if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
  Join-Path $resolvedOutputDir 'mobile-preview.json'
} else {
  Resolve-FullPath -PathValue $ManifestPath -BaseDir $resolvedArtifactRoot
}

New-Item -ItemType Directory -Path $resolvedOutputDir -Force | Out-Null

$warnings = [System.Collections.Generic.List[string]]::new()
$status = 'ok'
$tool = Resolve-ImageTool
if (-not $tool) {
  $status = 'skipped-no-image-tool'
  $warnings.Add('No image conversion tool found (`magick`/`convert`), preview generation skipped.') | Out-Null
}

$sourceFiles = @()
if (Test-Path -LiteralPath $resolvedArtifactRoot -PathType Container) {
  $extensions = @('.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp')
  $sourceFiles = @(
    Get-ChildItem -LiteralPath $resolvedArtifactRoot -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object {
        $ext = $_.Extension.ToLowerInvariant()
        if ($extensions -notcontains $ext) { return $false }
        $normalized = $_.FullName.Replace('\','/').ToLowerInvariant()
        if ($normalized.Contains('/mobile-preview/')) { return $false }
        return $true
      } |
      Sort-Object @{ Expression = { Get-SourcePriority -FullName $_.FullName } }, @{ Expression = { $_.Length }; Descending = $true }, @{ Expression = { $_.FullName } } |
      Select-Object -First $MaxSources
  )
} else {
  $status = 'missing-artifact-root'
  $warnings.Add(("Artifact root not found: {0}" -f $resolvedArtifactRoot)) | Out-Null
}

$items = [System.Collections.Generic.List[object]]::new()
$processedCount = 0
if ($tool -and @($sourceFiles).Count -gt 0) {
  foreach ($source in $sourceFiles) {
    $sourceToken = Sanitize-Token -Value ([System.IO.Path]::GetFileNameWithoutExtension($source.Name))
    $itemIndex = $processedCount + 1
    $itemVariants = [System.Collections.Generic.List[object]]::new()

    foreach ($width in $Widths) {
      if ($width -le 0) { continue }
      foreach ($format in @('webp', 'png')) {
        $fileName = ('{0:D2}-{1}-w{2}.{3}' -f $itemIndex, $sourceToken, $width, $format)
        $outPath = Join-Path $resolvedOutputDir $fileName
        $ok = $false
        try {
          $ok = Invoke-ResizeImage -Tool $tool -SourcePath $source.FullName -OutputPath $outPath -Width $width
        } catch {
          $ok = $false
          $warnings.Add(("Resize failed for '{0}' -> '{1}': {2}" -f $source.FullName, $outPath, $_.Exception.Message)) | Out-Null
        }

        if ($ok) {
          $fileInfo = Get-Item -LiteralPath $outPath -ErrorAction Stop
          $itemVariants.Add([pscustomobject]@{
            width = $width
            format = $format
            path = $fileInfo.FullName
            relativePath = Get-RelativePathSafe -PathValue $fileInfo.FullName -BaseDir $resolvedArtifactRoot
            bytes = [long]$fileInfo.Length
            sha256 = (Get-FileHash -LiteralPath $fileInfo.FullName -Algorithm SHA256).Hash
          }) | Out-Null
        } else {
          if ($status -eq 'ok') { $status = 'degraded' }
        }
      }
    }

    if ($itemVariants.Count -gt 0) {
      $inlineCandidate = $itemVariants | Where-Object { $_.width -eq 360 -and $_.format -eq 'webp' } | Select-Object -First 1
      if (-not $inlineCandidate) {
        $inlineCandidate = $itemVariants | Where-Object { $_.width -eq 360 -and $_.format -eq 'png' } | Select-Object -First 1
      }
      $tapCandidate = $itemVariants | Where-Object { $_.width -eq 720 -and $_.format -eq 'png' } | Select-Object -First 1
      if (-not $tapCandidate) {
        $tapCandidate = $itemVariants | Where-Object { $_.width -eq 720 } | Select-Object -First 1
      }
      if (-not $tapCandidate) {
        $tapCandidate = $itemVariants | Select-Object -First 1
      }

      $items.Add([pscustomobject]@{
        index = $itemIndex
        sourcePath = $source.FullName
        sourceRelativePath = Get-RelativePathSafe -PathValue $source.FullName -BaseDir $resolvedArtifactRoot
        inlinePreviewPath = if ($inlineCandidate) { $inlineCandidate.path } else { $null }
        tapPreviewPath = if ($tapCandidate) { $tapCandidate.path } else { $null }
        variants = @($itemVariants)
      }) | Out-Null
    }

    $processedCount++
  }
}

if (@($sourceFiles).Count -eq 0 -and $status -eq 'ok') {
  $status = 'no-sources'
  $warnings.Add('No image sources found under artifact root.') | Out-Null
}

$manifest = [ordered]@{
  schema = 'pr-vi-history-mobile-preview@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  status = $status
  artifactRoot = $resolvedArtifactRoot
  outputDir = $resolvedOutputDir
  widths = @($Widths)
  sourceCount = @($sourceFiles).Count
  itemCount = $items.Count
  warnings = @($warnings)
  items = @($items)
}

New-Item -ItemType Directory -Path (Split-Path -Parent $resolvedManifestPath) -Force | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedManifestPath -Encoding utf8

Write-OutputValue -OutputPath $GitHubOutputPath -Name 'mobile_preview_manifest_path' -Value $resolvedManifestPath
Write-OutputValue -OutputPath $GitHubOutputPath -Name 'mobile_preview_output_dir' -Value $resolvedOutputDir
Write-OutputValue -OutputPath $GitHubOutputPath -Name 'mobile_preview_count' -Value ([string]$items.Count)
Write-OutputValue -OutputPath $GitHubOutputPath -Name 'mobile_preview_status' -Value $status

return [pscustomobject]$manifest
