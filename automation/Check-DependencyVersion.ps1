<#PSScriptInfo
.VERSION 2026.07.03
.GUID 42d1e2f3-a4b5-4c67-8d90-1e2f3a4b5c6d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna dependency version pin
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Compare the upstream-latest stable release of each pinned dependency
    against the version pinned in automation/yuruna-versions.sh.
.DESCRIPTION
    yuruna-versions.sh is the single source of truth for the dependency
    version numbers the guest provisioning scripts bake in (Kubernetes minor,
    OpenTofu, nvm, Node.js major). This script reads those pins and asks each
    upstream what its current stable release is, then reports which pins have
    a newer release available so an operator knows what to bump.

    Upstream "latest" is resolved WITHOUT the rate-limited api.github.com
    endpoint: GitHub projects are queried by following the redirect of
    github.com/<repo>/releases/latest to its /releases/tag/<tag> target (the
    same HEAD-follow technique the guest update scripts use). Kubernetes uses
    dl.k8s.io/release/stable.txt and Node.js uses nodejs.org/dist/index.json.

    Each dependency is resolved independently in a try/catch, so a single
    unreachable upstream reports "check failed" for that row without aborting
    the rest. Rows are emitted as objects (pipe to ConvertTo-Json, Where-Object,
    etc.); a human-readable summary goes to the information stream.

    The "latest"-tracked dependencies (Helm, Flannel, mkcert, PowerShell) are
    not pinned -- the guest scripts intentionally fetch their newest release at
    install time -- so they are reported for visibility only and never flagged
    as out of date. Pass -PinnedOnly to omit them.
.PARAMETER VersionsFile
    Path to the version manifest. Defaults to yuruna-versions.sh next to this
    script.
.PARAMETER PinnedOnly
    Only check the dependencies that have a pin in the manifest; skip the
    informational "latest"-tracked rows.
.PARAMETER AsJson
    Emit the result rows as a JSON array instead of objects.
.OUTPUTS
    [pscustomobject] One row per dependency with Dependency, Pinned, Latest,
    Status, and Source properties.
.EXAMPLE
    ./Check-DependencyVersion.ps1
    Report every dependency and whether a newer stable release is available.
.EXAMPLE
    ./Check-DependencyVersion.ps1 -PinnedOnly -AsJson
    Emit only the pinned dependencies as a JSON array (for CI consumption).
#>

[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [string]$VersionsFile = (Join-Path $PSScriptRoot 'yuruna-versions.sh'),
    [switch]$PinnedOnly,
    [switch]$AsJson
)

$InformationPreference = 'Continue'

function Get-VersionPin {
    <#
    .SYNOPSIS
        Parse a yuruna-versions.sh manifest into a name -> value hashtable.
    .OUTPUTS
        [hashtable]
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Version manifest not found: $Path"
    }
    $map = @{}
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        # Tolerate an optional `export ` prefix; stop the value at the first
        # whitespace or comment so a trailing `# note` never leaks into it.
        if ($line -match '^\s*(?:export\s+)?(?<k>[A-Za-z_][A-Za-z0-9_]*)=(?<v>[^#\s]+)') {
            $map[$Matches['k']] = $Matches['v']
        }
    }
    return $map
}

function Get-GitHubLatestTag {
    <#
    .SYNOPSIS
        Resolve a GitHub repo's latest release tag (without the leading 'v')
        by following the /releases/latest redirect -- no api.github.com call.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Repo)
    $url  = "https://github.com/$Repo/releases/latest"
    $resp = Invoke-WebRequest -Uri $url -Method Head -MaximumRedirection 10 -TimeoutSec 20 -ErrorAction Stop
    $final = [string]$resp.BaseResponse.RequestMessage.RequestUri
    if ($final -match '/releases/tag/v?(?<v>[^/]+)$') {
        return $Matches['v']
    }
    throw "Could not parse a release tag from redirect target '$final'."
}

function Get-NodeLatestLtsVersion {
    <#
    .SYNOPSIS
        Resolve the newest Node.js LTS release version (without leading 'v').
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # index.json is newest-first; .lts is $false for non-LTS lines and the
    # codename string for LTS lines, so a truthiness filter finds the latest LTS.
    $index = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec 20 -ErrorAction Stop
    $lts   = $index | Where-Object { $_.lts } | Select-Object -First 1
    if (-not $lts) { throw 'No LTS entry found in nodejs.org/dist/index.json.' }
    return ([string]$lts.version) -replace '^v', ''
}

function Get-K8sLatestStableVersion {
    <#
    .SYNOPSIS
        Resolve the current stable Kubernetes release (without leading 'v').
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $raw = Invoke-RestMethod -Uri 'https://dl.k8s.io/release/stable.txt' -TimeoutSec 20 -ErrorAction Stop
    return ([string]$raw).Trim() -replace '^v', ''
}

function Get-ComparableVersion {
    <#
    .SYNOPSIS
        Reduce a full version string to the granularity a pin is tracked at:
        'minor' -> major.minor, 'major' -> major, anything else -> unchanged.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Full,
        [Parameter(Mandatory)][string]$Kind
    )
    if ([string]::IsNullOrWhiteSpace($Full)) { return '' }
    $parts = $Full -split '\.'
    switch ($Kind) {
        'minor' { return ($parts | Select-Object -First 2) -join '.' }
        'major' { return $parts[0] }
        default { return $Full }
    }
}

function Get-VersionStatus {
    <#
    .SYNOPSIS
        Classify a pinned version against the resolved-latest comparable form.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Pinned,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Latest,
        [Parameter(Mandatory)][string]$Kind
    )
    if ([string]::IsNullOrWhiteSpace($Latest)) { return 'check failed' }
    try {
        if ($Kind -eq 'major') {
            $p = [int]$Pinned; $l = [int]$Latest
        } else {
            # 'minor' and 'full' both compare cleanly as [version] (X.Y or X.Y.Z).
            $p = [version]$Pinned; $l = [version]$Latest
        }
    } catch {
        # A malformed pin ('1.30+', 'latest', a typo) or unparsable upstream string must degrade
        # THIS row -- the call site is unguarded, so a throw here would abort the whole report.
        return 'unparsable pin'
    }
    if ($l -gt $p) { return 'UPDATE AVAILABLE' }
    if ($l -lt $p) { return 'pinned ahead' }
    return 'up-to-date'
}

# Dependency descriptors. Pinned rows carry a manifest key + comparison Kind;
# the resolver scriptblock returns the upstream-latest FULL version string.
$pinnedDeps = @(
    @{ Name = 'Kubernetes (minor)'; Key = 'YURUNA_K8S_MINOR';       Kind = 'minor'; Source = 'dl.k8s.io/release/stable.txt';      Resolve = { Get-K8sLatestStableVersion } }
    @{ Name = 'OpenTofu';           Key = 'YURUNA_OPENTOFU_VERSION'; Kind = 'full';  Source = 'github.com/opentofu/opentofu';      Resolve = { Get-GitHubLatestTag -Repo 'opentofu/opentofu' } }
    @{ Name = 'nvm';                Key = 'YURUNA_NVM_VERSION';      Kind = 'full';  Source = 'github.com/nvm-sh/nvm';             Resolve = { Get-GitHubLatestTag -Repo 'nvm-sh/nvm' } }
    @{ Name = 'Node.js (LTS major)'; Key = 'YURUNA_NODE_MAJOR';      Kind = 'major'; Source = 'nodejs.org/dist/index.json';        Resolve = { Get-NodeLatestLtsVersion } }
)

# "latest"-tracked dependencies: the guest scripts fetch the newest release at
# install time, so there is no pin to bump. Reported for visibility only.
$trackedDeps = @(
    @{ Name = 'Helm (tracks latest)';       Source = 'github.com/helm/helm';                   Resolve = { Get-GitHubLatestTag -Repo 'helm/helm' } }
    @{ Name = 'Flannel (tracks latest)';    Source = 'github.com/flannel-io/flannel';          Resolve = { Get-GitHubLatestTag -Repo 'flannel-io/flannel' } }
    @{ Name = 'mkcert (tracks latest)';     Source = 'github.com/FiloSottile/mkcert';          Resolve = { Get-GitHubLatestTag -Repo 'FiloSottile/mkcert' } }
    @{ Name = 'PowerShell (tracks latest)'; Source = 'github.com/PowerShell/PowerShell';        Resolve = { Get-GitHubLatestTag -Repo 'PowerShell/PowerShell' } }
)

$pins    = Get-VersionPin -Path $VersionsFile
$results = New-Object System.Collections.Generic.List[pscustomobject]

Write-Information "Pinned dependency versions from $VersionsFile"

foreach ($dep in $pinnedDeps) {
    $pinned = if ($pins.ContainsKey($dep.Key)) { $pins[$dep.Key] } else { $null }
    $latestFull = ''
    $errMsg     = $null
    try {
        $raw = & $dep.Resolve
        if (-not [string]::IsNullOrWhiteSpace($raw)) { $latestFull = ([string]$raw) -replace '^v', '' }
    } catch {
        $errMsg = $_.Exception.Message
    }
    $latestCmp = Get-ComparableVersion -Full $latestFull -Kind $dep.Kind
    if ($null -eq $pinned) {
        $status = 'no pin in manifest'
    } elseif ($errMsg) {
        $status = 'check failed'
    } else {
        $status = Get-VersionStatus -Pinned $pinned -Latest $latestCmp -Kind $dep.Kind
    }
    $results.Add([pscustomobject]@{
        Dependency = $dep.Name
        Pinned     = if ($null -eq $pinned) { '(missing)' } else { $pinned }
        Latest     = if ($errMsg) { '?' } else { $latestCmp }
        Status     = $status
        Source     = $dep.Source
        Detail     = if ($errMsg) { $errMsg } elseif ($latestFull -ne $latestCmp) { "latest release $latestFull" } else { '' }
    })
}

if (-not $PinnedOnly) {
    foreach ($dep in $trackedDeps) {
        $latestFull = ''
        $errMsg     = $null
        try {
            $raw = & $dep.Resolve
            if (-not [string]::IsNullOrWhiteSpace($raw)) { $latestFull = ([string]$raw) -replace '^v', '' }
        } catch {
            $errMsg = $_.Exception.Message
        }
        $results.Add([pscustomobject]@{
            Dependency = $dep.Name
            Pinned     = '(latest)'
            Latest     = if ($errMsg) { '?' } else { $latestFull }
            Status     = if ($errMsg) { 'check failed' } else { 'tracks latest' }
            Source     = $dep.Source
            Detail     = if ($errMsg) { $errMsg } else { '' }
        })
    }
}

$updateCount = @($results | Where-Object { $_.Status -eq 'UPDATE AVAILABLE' }).Count
$failCount   = @($results | Where-Object { $_.Status -eq 'check failed' }).Count
if ($updateCount -gt 0) {
    Write-Information "$updateCount pinned dependency(ies) have a newer stable release -- bump them in $VersionsFile."
} else {
    Write-Information 'All pinned dependencies are up to date with their upstream stable releases.'
}
if ($failCount -gt 0) {
    Write-Information "$failCount dependency(ies) could not be checked (see the Detail column)."
}

if ($AsJson) {
    $results | ConvertTo-Json -Depth 4
} else {
    $results
}
