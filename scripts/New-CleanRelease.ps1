[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Destination
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$auditScript = Join-Path $PSScriptRoot 'Test-ProductionRelease.ps1'
$manifestPath = Join-Path $repositoryRoot 'release-manifest.txt'

& $auditScript -Path $repositoryRoot

$destinationPath = [System.IO.Path]::GetFullPath($Destination)
$repositoryPrefix = $repositoryRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
if (
    $destinationPath.Equals($repositoryRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
    $destinationPath.StartsWith($repositoryPrefix, [System.StringComparison]::OrdinalIgnoreCase)
) {
    throw 'Destination must be outside the source repository.'
}
if ($destinationPath -eq [System.IO.Path]::GetPathRoot($destinationPath)) {
    throw 'Destination cannot be a filesystem root.'
}
if (Test-Path -LiteralPath $destinationPath) {
    throw "Destination already exists; refusing to overwrite it: $destinationPath"
}

$destinationParent = Split-Path -Parent $destinationPath
if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
    throw "Destination parent does not exist: $destinationParent"
}

[void] (New-Item -ItemType Directory -Path $destinationPath)

$entries = Get-Content -LiteralPath $manifestPath |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_.Length -gt 0 -and -not $_.StartsWith('#') }

foreach ($entry in $entries) {
    $source = Join-Path $repositoryRoot ($entry.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    $target = Join-Path $destinationPath ($entry.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    $targetParent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $targetParent -PathType Container)) {
        [void] (New-Item -ItemType Directory -Path $targetParent)
    }
    Copy-Item -LiteralPath $source -Destination $target
}

& $auditScript -Path $destinationPath -Exact
Write-Output "Clean production release staged at: $destinationPath"
