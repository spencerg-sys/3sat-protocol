[CmdletBinding()]
param(
    [Parameter()]
    [string] $Path = (Split-Path -Parent $PSScriptRoot),

    [Parameter()]
    [switch] $Exact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Stop-ReleaseAudit {
    param([Parameter(Mandatory)][string] $Message)
    throw "Production release audit failed: $Message"
}

function Get-ReleaseEntries {
    param([Parameter(Mandatory)][string] $ManifestPath)

    $entries = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($line in Get-Content -LiteralPath $ManifestPath) {
        $entry = $line.Trim()
        if ($entry.Length -eq 0 -or $entry.StartsWith('#')) {
            continue
        }
        if (
            [System.IO.Path]::IsPathRooted($entry) -or
            $entry.Contains('\') -or
            $entry -match '(^|/)\.\.?(/|$)' -or
            $entry.EndsWith('/')
        ) {
            Stop-ReleaseAudit "unsafe manifest entry: $entry"
        }
        if (-not $seen.Add($entry)) {
            Stop-ReleaseAudit "duplicate manifest entry: $entry"
        }
        $entries.Add($entry)
    }

    if ($entries.Count -eq 0) {
        Stop-ReleaseAudit 'release manifest is empty'
    }
    return $entries
}

function Assert-NoReparsePoint {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $RelativePath
    )

    $current = $Root
    foreach ($segment in $RelativePath.Split('/')) {
        $current = Join-Path $current $segment
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-ReleaseAudit "symbolic link or reparse point is not allowed: $RelativePath"
        }
    }
}

function Get-RelativeReleasePath {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $FullName
    )

    $prefix = $Root.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $FullName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-ReleaseAudit "path escaped release root: $FullName"
    }
    return $FullName.Substring($prefix.Length).Replace('\', '/')
}

$manifestRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$manifestPath = Join-Path $manifestRoot 'release-manifest.txt'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Stop-ReleaseAudit "missing manifest: $manifestPath"
}

$resolvedRoot = Resolve-Path -LiteralPath $Path
$releaseRoot = [System.IO.Path]::GetFullPath($resolvedRoot.Path)
$rootItem = Get-Item -LiteralPath $releaseRoot -Force
if (-not $rootItem.PSIsContainer) {
    Stop-ReleaseAudit "release path is not a directory: $releaseRoot"
}
if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    Stop-ReleaseAudit 'release root cannot be a symbolic link or reparse point'
}

$entries = @(Get-ReleaseEntries -ManifestPath $manifestPath)
$manifestSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $entries) {
    [void] $manifestSet.Add($entry)
    $candidate = Join-Path $releaseRoot ($entry.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        Stop-ReleaseAudit "missing allowlisted file: $entry"
    }
    Assert-NoReparsePoint -Root $releaseRoot -RelativePath $entry
}

if ($Exact) {
    foreach ($item in Get-ChildItem -LiteralPath $releaseRoot -Recurse -Force) {
        $relative = Get-RelativeReleasePath -Root $releaseRoot -FullName $item.FullName
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-ReleaseAudit "symbolic link or reparse point is not allowed: $relative"
        }
        if ($item.PSIsContainer) {
            $directoryPrefix = $relative.TrimEnd('/') + '/'
            $isAllowlistedParent = $false
            foreach ($entry in $entries) {
                if ($entry.StartsWith($directoryPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $isAllowlistedParent = $true
                    break
                }
            }
            if (-not $isAllowlistedParent) {
                Stop-ReleaseAudit "directory is not allowlisted: $relative"
            }
        } elseif (-not $manifestSet.Contains($relative)) {
            Stop-ReleaseAudit "file is not allowlisted: $relative"
        }
    }

    $releaseManifestPath = Join-Path $releaseRoot 'release-manifest.txt'
    $sourceManifestText = [System.IO.File]::ReadAllText($manifestPath)
    $releaseManifestText = [System.IO.File]::ReadAllText($releaseManifestPath)
    if (-not $sourceManifestText.Equals($releaseManifestText, [System.StringComparison]::Ordinal)) {
        Stop-ReleaseAudit 'staged release manifest differs from the audited source manifest'
    }
    if (-not $releaseRoot.Equals($manifestRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        foreach ($entry in $entries) {
            $relativeSystemPath = $entry.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            $sourceHash = (Get-FileHash -LiteralPath (Join-Path $manifestRoot $relativeSystemPath) -Algorithm SHA256).Hash
            $releaseHash = (Get-FileHash -LiteralPath (Join-Path $releaseRoot $relativeSystemPath) -Algorithm SHA256).Hash
            if ($sourceHash -ne $releaseHash) {
                Stop-ReleaseAudit "staged file differs from audited source: $entry"
            }
        }
    }
}

$blockedFragments = @(
    ('421' + '614'),
    ('421_' + '614'),
    ('11155' + '111'),
    ('sepo' + 'lia'),
    ('test' + 'net'),
    ('goer' + 'li'),
    ('hole' + 'sky'),
    ('am' + 'oy'),
    ('fu' + 'ji'),
    ('mumba' + 'i'),
    ('301' + '542509'),
    ('301_' + '542_509'),
    ('0x4158B40E1Aa41Cd386b' + '7936B1023Fe094f77Fed1'),
    ('0x8Aa142115FbF51a721c8' + 'd59517284CE087f2D7EA'),
    ('0xa86B949636480d6DEf03' + '677965FfC45b121174fb'),
    ('0x75faf114eafb1BDbe2F0' + '316DF893fd58CE46AA4d'),
    ('0x2e1A3AeB940a7D12100c' + '21e6bfA4d42728bbDC58'),
    ('0x93c055B36fD941776444' + '47ed96B76A805baaFA27'),
    ('0x4908Cc479B314c215450' + '4BE85a2a281acbb628b6'),
    ('0x4450f41155A6987bbbf4' + '02046b29E8D3Ec601Ff4'),
    ('0x90e137D77CCF7828426D' + '4C8A5A17eF7092D77B40'),
    ('0xE99A3a001685130B46c9' + 'b504f58eFa77169dF3C3'),
    ('0xB6f72e5b728d78b9AD91' + '06575Bc2342533A25F7a'),
    ('0x721b097821EbA304CAd6' + 'B43115283081899080ba')
)

$sensitiveNames = @(
    'PRIVATE_KEY',
    'MNEMONIC',
    'PASSWORD',
    'SECRET',
    'API_KEY',
    'AUTH_TOKEN',
    'ACCESS_TOKEN',
    'DATABASE_URL',
    'RPC_URL'
)
$sensitiveAlternation = ($sensitiveNames | ForEach-Object { [regex]::Escape($_) }) -join '|'
$sensitiveAssignment = [regex]::new(
    "(?im)^[ \t]*(?<name>[A-Z0-9_]*(?:$sensitiveAlternation)[A-Z0-9_]*)[ \t]*=[ \t]*(?<value>[^#\r\n]*)"
)
$privateKeyArgument = [regex]::new('(?i)--private-key[ \t]+0x[0-9a-f]{64}(?![0-9a-f])')
$structuredPrivateMaterial = [regex]::new(
    '(?im)["'']?(?:private[_-]?key|mnemonic|seed[_-]?phrase)["'']?[ \t]*:[ \t]*["'']?(?<value>[^,"''\s}]+)'
)
$privateMaterialMarkers = @(
    ('-----BEGIN ' + 'PRIVATE KEY-----'),
    ('-----BEGIN ' + 'ENCRYPTED PRIVATE KEY-----'),
    ('-----BEGIN ' + 'EC PRIVATE KEY-----')
)
$publicRpc = 'https://arb1.arbitrum.io/rpc'
$safeRpcValues = @(
    $publicRpc,
    'http://127.0.0.1:8545',
    '${ARBITRUM_RPC_URL}',
    '${MAINNET_RPC_URL}'
)

foreach ($entry in $entries) {
    $leaf = [System.IO.Path]::GetFileName($entry)
    $leafLower = $leaf.ToLowerInvariant()
    if (
        ($leafLower.StartsWith('.env') -and $leafLower -ne '.env.example') -or
        $leafLower -eq '.npmrc' -or
        $leafLower -eq 'id_rsa' -or
        $leafLower.EndsWith('.pem') -or
        $leafLower.EndsWith('.key') -or
        $leafLower.EndsWith('.p12') -or
        $leafLower.EndsWith('.keystore')
    ) {
        Stop-ReleaseAudit "credential-bearing file name is not allowed: $entry"
    }

    $candidate = Join-Path $releaseRoot ($entry.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    $text = [System.IO.File]::ReadAllText($candidate)
    foreach ($fragment in $blockedFragments) {
        if ($text.IndexOf($fragment, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Stop-ReleaseAudit "retired network content found in $entry"
        }
    }
    foreach ($marker in $privateMaterialMarkers) {
        if ($text.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Stop-ReleaseAudit "private key material found in $entry"
        }
    }
    if ($privateKeyArgument.IsMatch($text) -or $structuredPrivateMaterial.IsMatch($text)) {
        Stop-ReleaseAudit "private key or recovery material found in $entry"
    }

    foreach ($match in $sensitiveAssignment.Matches($text)) {
        $name = $match.Groups['name'].Value
        $value = $match.Groups['value'].Value.Trim().Trim('"').Trim("'")
        if ($value.Length -eq 0) {
            continue
        }
        if ($name.EndsWith('RPC_URL', [System.StringComparison]::OrdinalIgnoreCase) -and $safeRpcValues -contains $value) {
            continue
        }
        Stop-ReleaseAudit "non-empty sensitive assignment found in $entry ($name)"
    }
}

$deploymentPath = Join-Path $releaseRoot 'contracts/deployments/3sat-42161.json'
try {
    $deployment = Get-Content -LiteralPath $deploymentPath -Raw | ConvertFrom-Json
} catch {
    Stop-ReleaseAudit 'production deployment record is not valid JSON'
}

$expectedDeployment = [ordered]@{
    ArtifactAccessController = '0xf875fDaBbC191801f8C8fD7fde968556Ca2D760f'
    BountyManager = '0xD31897B472156CC31Dc64d0fa45e43bF7B8C02ED'
    CommunityIncentivesController = '0x6EbBCBFa6DAE064812f597B784ada2E70f2d7473'
    InvestorVesting = '0xb3109c3fA0Ae89925F68d99e979A9F6AB1ad4C34'
    LIQUIDITY_ADDRESS = '0x8991CCf17d7A6e7077FF4e85eca1852067e759af'
    OFFICIAL_VERIFIER_ADDRESS = '0xA7421e0098D8F908Cf7222dFd14B4511F4d63A7a'
    OWNER_ADDRESS = '0xBdC4EC5115F8C004B54C8d97C56e933cA4340570'
    SATToken = '0x2C1B789B001F51F65a9fa61C4501B0E9Fc0Ab92c'
    TREASURY_ADDRESS = '0x978Ea7a4798375A3d0319b32Ca24FbeA6475A034'
    TeamVesting = '0xdA2eFf7212F954b7bA4e39e5FB8ED68D67Feda63'
    TreasuryReserveController = '0xA2b35109E53020aC66981E1F3315ecC60B7a59aD'
    TreasuryRouter = '0xBB34CFf137C48A3D13F164E1388a8913Fccb1C5D'
    USDC = '0xaf88d065e77c8cC2239327C5EDb3A432268e5831'
    VerifierRegistry = '0x360F58F6F6448492896261A8fe6D416E985fe52e'
}

$expectedProperties = @($expectedDeployment.Keys) + @('chainId', 'permissionlessVerificationEnabled')
$actualProperties = @($deployment.PSObject.Properties.Name)
if ($actualProperties.Count -ne $expectedProperties.Count) {
    Stop-ReleaseAudit 'production deployment record has an unexpected property count'
}
foreach ($property in $expectedProperties) {
    if ($actualProperties -notcontains $property) {
        Stop-ReleaseAudit "production deployment record is missing $property"
    }
}
foreach ($property in $actualProperties) {
    if ($expectedProperties -notcontains $property) {
        Stop-ReleaseAudit "production deployment record has unexpected property $property"
    }
}
foreach ($property in $expectedDeployment.Keys) {
    $actual = [string] $deployment.$property
    $expected = [string] $expectedDeployment[$property]
    if (-not $actual.Equals($expected, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-ReleaseAudit "production deployment address mismatch: $property"
    }
}
if ($deployment.chainId -is [string] -or [int64] $deployment.chainId -ne 42161) {
    Stop-ReleaseAudit 'production deployment chain ID is not Arbitrum One'
}
if ($deployment.permissionlessVerificationEnabled -isnot [bool]) {
    Stop-ReleaseAudit 'production verifier admission flag is not boolean'
}
if ($deployment.permissionlessVerificationEnabled) {
    Stop-ReleaseAudit 'production verifier admission is not fail-closed'
}

$environmentText = [System.IO.File]::ReadAllText((Join-Path $releaseRoot 'contracts/.env.example'))
if ($environmentText -notmatch '(?m)^ARBITRUM_RPC_URL=https://arb1\.arbitrum\.io/rpc\s*$') {
    Stop-ReleaseAudit 'public Arbitrum One RPC default is missing from the environment template'
}
foreach ($emptyName in @('MAINNET_RPC_URL', 'ETHERSCAN_API_KEY', 'ARBISCAN_API_KEY', 'DEPLOYER_PRIVATE_KEY')) {
    if ($environmentText -notmatch "(?m)^$emptyName=[ \t]*\r?$") {
        Stop-ReleaseAudit "environment template must keep $emptyName empty"
    }
}

$specText = [System.IO.File]::ReadAllText((Join-Path $releaseRoot 'docs/PROTOCOL_SPEC.md'))
if ($specText.IndexOf('0xeba2066d89faa2e842382a7e3c81a055205660aab1ad1b4510c5f20fb52d2046', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
    Stop-ReleaseAudit 'local commitment vector is missing or changed'
}

Write-Output "Production release audit passed ($($entries.Count) allowlisted files): $releaseRoot"
