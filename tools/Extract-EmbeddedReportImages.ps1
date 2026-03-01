#Requires -Version 7.0
<#
.SYNOPSIS
  Extracts embedded base64 data-URI images from an HTML report.

.DESCRIPTION
  Finds <img src="data:image/...;base64,..."> entries and writes each image to
  disk so downstream tooling can publish/report concrete image files.

.PARAMETER HtmlPath
  Path to the HTML file to scan.

.PARAMETER OutputDir
  Optional output directory for extracted images. Defaults to
  <html-directory>/report-assets.

.PARAMETER FilePrefix
  Prefix for extracted filenames.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$HtmlPath,

  [string]$OutputDir,

  [string]$FilePrefix = 'compare-image'
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

function Get-ImageExtension {
  param([string]$MimeType)
  if ([string]::IsNullOrWhiteSpace($MimeType)) { return 'bin' }
  switch -Regex ($MimeType.ToLowerInvariant()) {
    '^image/png$' { return 'png' }
    '^image/jpeg$' { return 'jpg' }
    '^image/gif$' { return 'gif' }
    '^image/webp$' { return 'webp' }
    '^image/svg\+xml$' { return 'svg' }
    '^image/bmp$' { return 'bmp' }
    default { return 'bin' }
  }
}

if (-not (Test-Path -LiteralPath $HtmlPath -PathType Leaf)) {
  throw ("HTML report not found: {0}" -f $HtmlPath)
}

$resolvedHtmlPath = (Resolve-Path -LiteralPath $HtmlPath).Path
$htmlDir = Split-Path -Parent $resolvedHtmlPath
$resolvedOutputDir = if ([string]::IsNullOrWhiteSpace($OutputDir)) {
  Join-Path $htmlDir 'report-assets'
} else {
  Resolve-FullPath -PathValue $OutputDir -BaseDir $htmlDir
}

New-Item -ItemType Directory -Path $resolvedOutputDir -Force | Out-Null

$html = Get-Content -LiteralPath $resolvedHtmlPath -Raw -ErrorAction Stop
$imgMatches = [regex]::Matches(
  $html,
  '<img\b[^>]*\bsrc\s*=\s*(?<q>["''])(?<src>.*?)\k<q>',
  [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)

$savedPaths = [System.Collections.Generic.List[string]]::new()
$decodeFailures = [System.Collections.Generic.List[object]]::new()
$index = 0
foreach ($match in $imgMatches) {
  if (-not $match.Success) { continue }
  $srcValue = $match.Groups['src'].Value
  if ([string]::IsNullOrWhiteSpace($srcValue)) { continue }

  $dataMatch = [regex]::Match($srcValue, '^data:(?<mime>image/[^;]+);base64,(?<data>.+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if (-not $dataMatch.Success) { continue }

  $mime = $dataMatch.Groups['mime'].Value
  $base64Data = $dataMatch.Groups['data'].Value
  try {
    $clean = ($base64Data -replace '\s', '')
    $bytes = [System.Convert]::FromBase64String($clean)
    if (-not $bytes -or $bytes.Length -eq 0) {
      continue
    }

    $ext = Get-ImageExtension -MimeType $mime
    $fileName = '{0}-{1:D2}.{2}' -f $FilePrefix, $index, $ext
    $filePath = Join-Path $resolvedOutputDir $fileName
    [System.IO.File]::WriteAllBytes($filePath, $bytes)
    $savedPaths.Add((Resolve-Path -LiteralPath $filePath).Path)
    $index++
  } catch {
    $decodeFailures.Add([pscustomobject]@{
      index = $index
      mimeType = $mime
      message = $_.Exception.Message
    }) | Out-Null
  }
}

$result = [pscustomobject]@{
  schema = 'embedded-html-image-extraction@v1'
  htmlPath = $resolvedHtmlPath
  outputDir = $resolvedOutputDir
  extractedCount = $savedPaths.Count
  extractedPaths = @($savedPaths)
  decodeFailures = @($decodeFailures)
}

return $result
