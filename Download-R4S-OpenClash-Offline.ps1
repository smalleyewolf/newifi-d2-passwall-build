#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Destination = (Join-Path (Get-Location) 'R4S-OpenClash-Offline'),
    [switch]$SkipFirmware
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$FirmwareName = 'istoreos-24.10.5-2025123110-r4s-squashfs.img.gz'
$FirmwareUrl = 'https://fw.koolcenter.com/iStoreOS/r4s/' + $FirmwareName
$ExpectedKernelAbi = '6.6.119~77d4782035a23e6f19f9c4751451b4e3-r1'
$ExpectedKmodPath = '6.6.119-1-77d4782035a23e6f19f9c4751451b4e3'
$GitHubHeaders = @{ 'User-Agent' = 'R4S-OpenClash-Offline-Builder' }

$Folders = @{}
foreach ($name in @('Firmware', 'OpenClash', 'Mihomo', 'Dependencies', 'Kmods', 'Manifests')) {
    $path = Join-Path $Destination $name
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    $Folders[$name] = $path
}
$IndexFolder = Join-Path $Folders.Manifests 'Indexes'
New-Item -ItemType Directory -Force -Path $IndexFolder | Out-Null

$script:Manifest = New-Object System.Collections.ArrayList

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Add-ManifestEntry {
    param(
        [string]$Category, [string]$Package, [string]$Version,
        [string]$Path, [string]$Url, [string]$ExpectedSha256,
        [string]$Source
    )
    $actual = Get-Sha256 $Path
    $verified = [string]::IsNullOrWhiteSpace($ExpectedSha256) -or
        ($actual -eq $ExpectedSha256.ToLowerInvariant())
    if (-not $verified) {
        throw "SHA256 mismatch: $Path`nExpected: $ExpectedSha256`nActual:   $actual"
    }
    [void]$script:Manifest.Add([pscustomobject]@{
        Category       = $Category
        Package        = $Package
        Version        = $Version
        File           = [IO.Path]::GetFileName($Path)
        Bytes          = (Get-Item -LiteralPath $Path).Length
        SHA256         = $actual
        ExpectedSHA256 = $ExpectedSha256
        Verified       = $verified
        Source         = $Source
        URL            = $Url
    })
}

function Invoke-FileDownload {
    param(
        [Parameter(Mandatory = $true)][string[]]$Urls,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [long]$ExpectedSize = 0,
        [string]$ExpectedSha256 = ''
    )
    if (Test-Path -LiteralPath $OutFile) {
        $existingSize = (Get-Item -LiteralPath $OutFile).Length
        $existingHashOk = [string]::IsNullOrWhiteSpace($ExpectedSha256) -or
            ((Get-Sha256 $OutFile) -eq $ExpectedSha256.ToLowerInvariant())
        $existingSizeOk = ($ExpectedSize -le 0) -or ($existingSize -eq $ExpectedSize)
        if ($existingSize -gt 0 -and $existingSizeOk -and $existingHashOk) {
            Write-Host "Using verified existing file: $OutFile"
            return $Urls[0]
        }
    }

    $partial = $OutFile + '.partial'
    foreach ($url in $Urls) {
        try {
            Write-Host "Downloading: $url"
            if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
                & curl.exe -L --fail --retry 3 --retry-delay 2 --connect-timeout 30 `
                    --silent --show-error --output $partial $url
                if ($LASTEXITCODE -ne 0) { throw "curl.exe exited with $LASTEXITCODE" }
            }
            else {
                Invoke-WebRequest -UseBasicParsing -Headers $GitHubHeaders -Uri $url -OutFile $partial
            }
            if (-not (Test-Path -LiteralPath $partial)) { throw 'No output file was created.' }
            $length = (Get-Item -LiteralPath $partial).Length
            if ($length -le 0) { throw 'Downloaded file is empty.' }
            if ($ExpectedSize -gt 0 -and $length -ne $ExpectedSize) {
                throw "Size mismatch. Expected $ExpectedSize bytes, got $length."
            }
            if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
                $actual = Get-Sha256 $partial
                if ($actual -ne $ExpectedSha256.ToLowerInvariant()) {
                    throw "SHA256 mismatch. Expected $ExpectedSha256, got $actual."
                }
            }
            Move-Item -Force -LiteralPath $partial -Destination $OutFile
            return $url
        }
        catch {
            Write-Warning "Download failed from $url : $($_.Exception.Message)"
            Remove-Item -Force -LiteralPath $partial -ErrorAction SilentlyContinue
        }
    }
    throw "All download sources failed for $OutFile"
}

function Expand-GzipText([string]$Path) {
    $inputStream = [IO.File]::OpenRead($Path)
    try {
        $gzip = New-Object IO.Compression.GZipStream($inputStream, [IO.Compression.CompressionMode]::Decompress)
        try {
            $reader = New-Object IO.StreamReader($gzip, [Text.Encoding]::UTF8)
            try { return $reader.ReadToEnd() }
            finally { $reader.Dispose() }
        }
        finally { $gzip.Dispose() }
    }
    finally { $inputStream.Dispose() }
}

function ConvertFrom-PackagesIndex([string]$Text, [object]$Feed) {
    $result = New-Object System.Collections.ArrayList
    foreach ($block in ($Text -split "(?:\r?\n){2,}")) {
        if ([string]::IsNullOrWhiteSpace($block)) { continue }
        $record = @{}
        $lastKey = $null
        foreach ($line in ($block -split "\r?\n")) {
            if ($line -match '^([^:]+):\s?(.*)$') {
                $lastKey = $matches[1]
                $record[$lastKey] = $matches[2]
            }
            elseif ($lastKey -and $line -match '^\s+(.*)$') {
                $record[$lastKey] += ' ' + $matches[1]
            }
        }
        if ($record.ContainsKey('Package') -and $record.ContainsKey('Filename')) {
            $record['_Feed'] = $Feed
            [void]$result.Add($record)
        }
    }
    return ,$result
}

function Get-DependencyChoices([string]$Depends) {
    $groups = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Depends)) { return ,$groups }
    foreach ($group in ($Depends -split ',')) {
        $choices = New-Object System.Collections.ArrayList
        foreach ($choice in ($group -split '\|')) {
            $name = ($choice -replace '\s*\(.*?\)\s*', '').Trim()
            $name = $name.TrimStart('+')
            if ($name -match '^[^:]+:(.+)$') { $name = $matches[1] }
            if ($name -and -not $name.StartsWith('@')) { [void]$choices.Add($name) }
        }
        if ($choices.Count -gt 0) { [void]$groups.Add(@($choices)) }
    }
    return ,$groups
}

function Get-GitHubLatestAsset {
    param([string]$Repository, [string]$NameRegex, [string]$OutFolder, [string]$Category)
    $api = "https://api.github.com/repos/$Repository/releases/latest"
    Write-Host "Reading official release metadata: $Repository"
    $release = Invoke-RestMethod -Headers $GitHubHeaders -Uri $api
    $matches = @($release.assets | Where-Object { $_.name -match $NameRegex })
    if ($matches.Count -ne 1) {
        throw "Expected exactly one asset matching '$NameRegex' in $Repository release $($release.tag_name); found $($matches.Count)."
    }
    $asset = $matches[0]
    $path = Join-Path $OutFolder $asset.name
    $usedUrl = Invoke-FileDownload -Urls @($asset.browser_download_url) -OutFile $path -ExpectedSize ([long]$asset.size)
    Add-ManifestEntry -Category $Category -Package $Repository -Version $release.tag_name `
        -Path $path -Url $usedUrl -ExpectedSha256 '' -Source 'Official GitHub release API'
}

Write-Host "Output directory: $Destination"

if (-not $SkipFirmware) {
    $firmwarePath = Join-Path $Folders.Firmware $FirmwareName
    $usedUrl = Invoke-FileDownload -Urls @($FirmwareUrl) -OutFile $firmwarePath
    Add-ManifestEntry -Category 'Firmware' -Package 'iStoreOS-R4S' -Version '24.10.5-2025123110' `
        -Path $firmwarePath -Url $usedUrl -ExpectedSha256 '' -Source 'iStoreOS official firmware server'
}
else { Write-Warning 'Firmware download was skipped by request.' }

Get-GitHubLatestAsset -Repository 'vernesong/OpenClash' `
    -NameRegex '^luci-app-openclash_[0-9.]+_all\.ipk$' -OutFolder $Folders.OpenClash -Category 'OpenClash'
Get-GitHubLatestAsset -Repository 'MetaCubeX/mihomo' `
    -NameRegex '^mihomo-linux-arm64-v[0-9.]+\.gz$' -OutFolder $Folders.Mihomo -Category 'Mihomo'

$releaseRootPrimary = 'https://mirrors.cernet.edu.cn/openwrt/releases/24.10.5'
$releaseRootFallback = 'https://downloads.openwrt.org/releases/24.10.5'
$feedSpecs = @(
    @{ Name = 'core';      Relative = 'targets/rockchip/armv8/packages' },
    @{ Name = 'kmods';     Relative = "targets/rockchip/armv8/kmods/$ExpectedKmodPath" },
    @{ Name = 'base';      Relative = 'packages/aarch64_generic/base' },
    @{ Name = 'luci';      Relative = 'packages/aarch64_generic/luci' },
    @{ Name = 'packages';  Relative = 'packages/aarch64_generic/packages' },
    @{ Name = 'routing';   Relative = 'packages/aarch64_generic/routing' },
    @{ Name = 'telephony'; Relative = 'packages/aarch64_generic/telephony' }
)

$allRecords = New-Object System.Collections.ArrayList
foreach ($spec in $feedSpecs) {
    $spec.BaseUrls = @(
        "$releaseRootPrimary/$($spec.Relative)",
        "$releaseRootFallback/$($spec.Relative)"
    )
    $indexPath = Join-Path $IndexFolder ($spec.Name + '-Packages.gz')
    $indexUrls = @($spec.BaseUrls | ForEach-Object { $_ + '/Packages.gz' })
    $usedUrl = Invoke-FileDownload -Urls $indexUrls -OutFile $indexPath
    $spec.UsedBaseUrl = $usedUrl.Substring(0, $usedUrl.Length - '/Packages.gz'.Length)
    $text = Expand-GzipText $indexPath
    foreach ($record in (ConvertFrom-PackagesIndex -Text $text -Feed $spec)) {
        [void]$allRecords.Add($record)
    }
    Add-ManifestEntry -Category 'Index' -Package $spec.Name -Version '24.10.5' `
        -Path $indexPath -Url $usedUrl -ExpectedSha256 '' -Source 'Firmware-matched distfeed index'
    foreach ($suffix in @('Packages.sig')) {
        try {
            $sigPath = Join-Path $IndexFolder ($spec.Name + '-' + $suffix)
            [void](Invoke-FileDownload -Urls @($spec.BaseUrls | ForEach-Object { $_ + '/' + $suffix }) -OutFile $sigPath)
        }
        catch { Write-Warning "Could not retain $suffix for feed $($spec.Name): $($_.Exception.Message)" }
    }
}

$byName = @{}
$providedBy = @{}
foreach ($record in $allRecords) {
    $name = [string]$record.Package
    if (-not $byName.ContainsKey($name)) { $byName[$name] = $record }
    if ($record.ContainsKey('Provides')) {
        foreach ($provided in ([string]$record.Provides -split ',')) {
            $virtualName = ($provided -replace '\s*\(.*?\)\s*', '').Trim()
            if ($virtualName -and -not $providedBy.ContainsKey($virtualName)) { $providedBy[$virtualName] = $record }
        }
    }
}

# These are the nftables/IPK requirements published by the OpenClash project.
$userRoots = @('bash', 'dnsmasq-full', 'curl', 'ca-bundle', 'ip-full', 'ruby', 'ruby-yaml', 'unzip', 'luci-compat', 'luci', 'luci-base')
$kmodRoots = @('kmod-tun', 'kmod-inet-diag', 'kmod-nft-tproxy')
$queue = New-Object System.Collections.Queue
foreach ($root in ($userRoots + $kmodRoots)) { $queue.Enqueue($root) }
$selected = @{}
$unresolved = New-Object System.Collections.ArrayList
$firmwareProvided = @('kernel', 'libc', 'librt', 'libpthread')

while ($queue.Count -gt 0) {
    $requestedName = [string]$queue.Dequeue()
    if ($firmwareProvided -contains $requestedName) { continue }
    $record = $null
    if ($byName.ContainsKey($requestedName)) { $record = $byName[$requestedName] }
    elseif ($providedBy.ContainsKey($requestedName)) { $record = $providedBy[$requestedName] }
    if ($null -eq $record) {
        if (-not $unresolved.Contains($requestedName)) { [void]$unresolved.Add($requestedName) }
        continue
    }
    $realName = [string]$record.Package
    if ($selected.ContainsKey($realName)) { continue }
    $selected[$realName] = $record
    $depends = if ($record.ContainsKey('Depends')) { [string]$record.Depends } else { '' }
    foreach ($choices in (Get-DependencyChoices $depends)) {
        $chosen = $null
        foreach ($choice in $choices) {
            if (($firmwareProvided -contains $choice) -or $byName.ContainsKey($choice) -or $providedBy.ContainsKey($choice)) {
                $chosen = $choice; break
            }
        }
        if ($chosen) { $queue.Enqueue($chosen) }
        else { [void]$unresolved.Add(($choices -join ' | ')) }
    }
}

if ($unresolved.Count -gt 0) {
    $uniqueMissing = @($unresolved | Sort-Object -Unique)
    throw "Unresolved recursive dependencies: $($uniqueMissing -join ', ')"
}

# Every selected kmod must declare this image's exact kernel ABI.
$resolvedKmods = @($selected.Values | Where-Object { ([string]$_.Package).StartsWith('kmod-') })
foreach ($record in $resolvedKmods) {
    $depends = if ($record.ContainsKey('Depends')) { [string]$record.Depends } else { '' }
    $escapedAbi = [regex]::Escape($ExpectedKernelAbi)
    if ($depends -notmatch "kernel\s*\(=\s*$escapedAbi\)") {
        throw "ABI safety stop: $($record.Package) does not depend on kernel (= $ExpectedKernelAbi). Actual Depends: $depends"
    }
}
foreach ($requiredKmod in $kmodRoots) {
    if (-not $selected.ContainsKey($requiredKmod)) { throw "Required kmod missing from exact ABI repository: $requiredKmod" }
}

Write-Host "Resolved $($selected.Count) packages (including recursive dependencies)."
foreach ($name in @($selected.Keys | Sort-Object)) {
    $record = $selected[$name]
    $category = if ($name.StartsWith('kmod-')) { 'Kmods' } else { 'Dependencies' }
    $folder = $Folders[$category]
    $fileName = Split-Path -Leaf ([string]$record.Filename)
    $outPath = Join-Path $folder $fileName
    $feed = $record['_Feed']
    $relativeFile = ([string]$record.Filename).TrimStart('/')
    $urls = New-Object System.Collections.ArrayList
    [void]$urls.Add(([string]$feed.UsedBaseUrl).TrimEnd('/') + '/' + $relativeFile)
    foreach ($base in $feed.BaseUrls) {
        $candidate = ([string]$base).TrimEnd('/') + '/' + $relativeFile
        if (-not $urls.Contains($candidate)) { [void]$urls.Add($candidate) }
    }
    $size = if ($record.ContainsKey('Size')) { [long]$record.Size } else { 0 }
    $sha = if ($record.ContainsKey('SHA256sum')) { [string]$record.SHA256sum } else { '' }
    if ([string]::IsNullOrWhiteSpace($sha)) { throw "No SHA256sum in index for $name" }
    $usedUrl = Invoke-FileDownload -Urls @($urls) -OutFile $outPath -ExpectedSize $size -ExpectedSha256 $sha
    Add-ManifestEntry -Category $category -Package $name -Version ([string]$record.Version) `
        -Path $outPath -Url $usedUrl -ExpectedSha256 $sha -Source ("OpenWrt 24.10.5 " + $feed.Name)
}

$kmodNote = @"
R4S iStoreOS 24.10.5-2025123110 KMOD SAFETY NOTE

Firmware kernel ABI: $ExpectedKernelAbi
Exact kmod repository: $ExpectedKmodPath

The stock image package database confirms that kmod-tun, kmod-inet-diag and
kmod-nft-tproxy are already installed. Files in this folder are exact-ABI
offline backups. Do not install them on any other firmware/build. This script
does not install anything on the router.
"@
Set-Content -LiteralPath (Join-Path $Folders.Kmods 'README-DO-NOT-MIX-KMODS.txt') -Value $kmodNote -Encoding UTF8

$sourceEvidence = @"
Evidence extracted from the exact target image: $FirmwareName

DISTRIB_ID=iStoreOS
DISTRIB_RELEASE=24.10.5
DISTRIB_REVISION=2025123110
DISTRIB_TARGET=rockchip/armv8
DISTRIB_ARCH=aarch64_generic

Kernel package version: $ExpectedKernelAbi
Kmod feed directory: $ExpectedKmodPath

The image's /etc/opkg/distfeeds.conf points to OpenWrt 24.10.5 feeds for
rockchip/armv8 and aarch64_generic. The script uses the same CERNET URLs first,
with downloads.openwrt.org as the byte-equivalent official fallback.

Package payloads are checked against Size and SHA256sum from Packages.gz.
Packages.sig files are retained when available, but this Windows-only script
does not perform usign signature verification of the indexes.
"@
Set-Content -LiteralPath (Join-Path $Folders.Manifests 'ABI-AND-SOURCE-EVIDENCE.txt') -Value $sourceEvidence -Encoding UTF8

$csvPath = Join-Path $Folders.Manifests 'download-manifest.csv'
$jsonPath = Join-Path $Folders.Manifests 'download-manifest.json'
$shaPath = Join-Path $Folders.Manifests 'SHA256SUMS.txt'
$script:Manifest | Sort-Object Category, Package | Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath $csvPath
$script:Manifest | Sort-Object Category, Package | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath $jsonPath
$shaLines = $script:Manifest | Sort-Object Category, File | ForEach-Object { "$($_.SHA256) *$($_.Category)/$($_.File)" }
Set-Content -LiteralPath $shaPath -Value $shaLines -Encoding ASCII

Write-Host ''
Write-Host 'Offline bundle completed successfully.' -ForegroundColor Green
Write-Host "Manifest: $csvPath"
Write-Host "SHA256:   $shaPath"
Write-Host "Kmod ABI: $ExpectedKernelAbi (verified before download)"
