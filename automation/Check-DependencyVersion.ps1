<#PSScriptInfo
.VERSION 2026.09.18
.GUID 427703ae-4857-433b-ab5f-5f81a7ae94c2
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
    OpenTofu, Helm, nvm, Node.js major). This script reads those pins and asks each
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

    The "latest"-tracked dependencies (Flannel, mkcert, PowerShell) are not
    pinned -- the guest scripts intentionally fetch their newest release at
    install time -- so they are reported for visibility only and never flagged
    as out of date. Pass -PinnedOnly to omit them.
    Yuruna.Requirement.yml is checked alongside it. Those entries are host-tool
    FLOORS -- the versions a host is probed against, not versions anything
    installs -- so a newer upstream is reported for visibility and never fails
    the run. They are listed only when the tracked rows are (omit -PinnedOnly).
.PARAMETER VersionsFile
    Path to the version manifest. Defaults to yuruna-versions.sh next to this
    script.
.PARAMETER RequirementFile
    Path to the host-tool requirement list. Defaults to Yuruna.Requirement.yml
    next to this script.
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
    [string]$RequirementFile = (Join-Path $PSScriptRoot 'Yuruna.Requirement.yml'),
    [switch]$PinnedOnly,
    [switch]$AsJson
)

# The narration is for a person reading a terminal. Under -AsJson stdout is a
# document a caller parses whole, and a line of prose ahead of it makes the
# parse fail on the first character -- so the one machine-readable mode this
# script has would emit something no consumer can read. Turning the stream off
# rather than redirecting it keeps the human mode byte-identical.
Import-Module (Join-Path $PSScriptRoot 'Yuruna.Globalization.psm1') -DisableNameChecking
$InformationPreference = if ($AsJson) { 'SilentlyContinue' } else { 'Continue' }

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
        throw (Format-YurunaOperatorMessage -Key 'automation.operator_115fdbece1d774ee' -Arguments @{ path = "$Path" })
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

function Get-RequirementFloor {
    <#
    .SYNOPSIS
        Parse Yuruna.Requirement.yml into a tool -> version-number hashtable.
    .DESCRIPTION
        The `version:` values are the strings each probe command prints, so they
        carry vendor decoration around the number ('7.6.4 (Core)', 'curl 8.21.0',
        'aws-cli/2.36.18', 'qemu-img version 11.0.3'). The first dotted numeric
        run in the value is the version; everything around it is noise.

        A two-key regex rather than powershell-yaml: this script has no module
        dependencies today, and the two keys it needs sit at a fixed indent.
    .OUTPUTS
        [hashtable]
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    $tool = $null
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match '^\s*-\s+tool:\s*"(?<t>[^"]+)"') { $tool = $Matches['t']; continue }
        if ($tool -and $line -match '^\s*version:\s*"(?<v>[^"]+)"') {
            if ($Matches['v'] -match '(?<n>\d+(?:\.\d+)+)') { $map[$tool] = $Matches['n'] }
            $tool = $null
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
    throw (Format-YurunaOperatorMessage -Key 'automation.operator_3f717ea683c65c4f' -Arguments @{ final = "$final" })
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
    if (-not $lts) { throw (Format-YurunaOperatorMessage -Key 'automation.operator_bb0c3d93bfb12851') }
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
        # A malformed pin ('1.30+', 'latest', a typo) or unparseable upstream string must degrade
        # THIS row -- the call site is unguarded, so a throw here would abort the whole report.
        return 'unparseable pin'
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
    @{ Name = 'Helm';               Key = 'YURUNA_HELM_VERSION';     Kind = 'full';  Source = 'github.com/helm/helm';              Resolve = { Get-GitHubLatestTag -Repo 'helm/helm' } }
    @{ Name = 'nvm';                Key = 'YURUNA_NVM_VERSION';      Kind = 'full';  Source = 'github.com/nvm-sh/nvm';             Resolve = { Get-GitHubLatestTag -Repo 'nvm-sh/nvm' } }
    @{ Name = 'Node.js (LTS major)'; Key = 'YURUNA_NODE_MAJOR';      Kind = 'major'; Source = 'nodejs.org/dist/index.json';        Resolve = { Get-NodeLatestLtsVersion } }
)

# "latest"-tracked dependencies: the guest scripts fetch the newest release at
# install time, so there is no pin to bump. Reported for visibility only.
$trackedDeps = @(
    @{ Name = 'Flannel (tracks latest)';    Source = 'github.com/flannel-io/flannel';          Resolve = { Get-GitHubLatestTag -Repo 'flannel-io/flannel' } }
    @{ Name = 'mkcert (tracks latest)';     Source = 'github.com/FiloSottile/mkcert';          Resolve = { Get-GitHubLatestTag -Repo 'FiloSottile/mkcert' } }
    @{ Name = 'PowerShell (tracks latest)'; Source = 'github.com/PowerShell/PowerShell';        Resolve = { Get-GitHubLatestTag -Repo 'PowerShell/PowerShell' } }
)

# Host-tool floors from Yuruna.Requirement.yml. These are the versions a host is
# probed against, not versions anything installs, so upstream moving ahead is
# informational: it never fails the run. Without them nothing watches the host
# side at all, and a floor can trail for months unnoticed.
#
# Only tools with an unambiguous upstream release feed are listed. Docker and
# Docker buildx are deliberately absent: both track what Docker Desktop bundles
# rather than the newest upstream tag, so comparing them to upstream would report
# drift on a correctly provisioned machine every time.
$hostFloorDeps = @(
    @{ Name = 'PowerShell (host floor)'; Tool = 'PowerShell'; Source = 'github.com/PowerShell/PowerShell';       Resolve = { Get-GitHubLatestTag -Repo 'PowerShell/PowerShell' } }
    @{ Name = 'containerd (host floor)'; Tool = 'containerd'; Source = 'github.com/containerd/containerd';       Resolve = { Get-GitHubLatestTag -Repo 'containerd/containerd' } }
    @{ Name = 'tesseract (host floor)';  Tool = 'tesseract';  Source = 'github.com/tesseract-ocr/tesseract';     Resolve = { Get-GitHubLatestTag -Repo 'tesseract-ocr/tesseract' } }
    @{ Name = 'mkcert (host floor)';     Tool = 'mkcert';     Source = 'github.com/FiloSottile/mkcert';          Resolve = { Get-GitHubLatestTag -Repo 'FiloSottile/mkcert' } }
    @{ Name = 'VS Code (host floor)';    Tool = 'Visual Studio Code'; Source = 'github.com/microsoft/vscode';    Resolve = { Get-GitHubLatestTag -Repo 'microsoft/vscode' } }
)

$pins    = Get-VersionPin -Path $VersionsFile
$results = New-Object System.Collections.Generic.List[pscustomobject]

Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_8447eca0c0a9d73f' -Arguments @{ versionsFile = "$VersionsFile" })

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
        Detail     = if ($errMsg) { $errMsg } elseif ($latestFull -ne $latestCmp) { (Format-YurunaOperatorMessage -Key 'automation.operator_36a9f2bd83246e41' -Arguments @{ latestFull = "$latestFull" }) } else { '' }
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

    $floors = Get-RequirementFloor -Path $RequirementFile
    if ($floors.Count -gt 0) {
        Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_19bdfd5f627c414b' -Arguments @{ requirementFile = "$RequirementFile" })
    }
    foreach ($dep in $hostFloorDeps) {
        $floor = if ($floors.ContainsKey($dep.Tool)) { $floors[$dep.Tool] } else { $null }
        $latestFull = ''
        $errMsg     = $null
        try {
            $raw = & $dep.Resolve
            if (-not [string]::IsNullOrWhiteSpace($raw)) { $latestFull = ([string]$raw) -replace '^v', '' }
        } catch {
            $errMsg = $_.Exception.Message
        }
        $status =
            if ($null -eq $floor)  { 'no floor in requirements' }
            elseif ($errMsg)       { 'check failed' }
            else {
                switch (Get-VersionStatus -Pinned $floor -Latest $latestFull -Kind 'full') {
                    'UPDATE AVAILABLE' { 'floor behind latest' }
                    'pinned ahead'     { 'floor ahead of latest' }
                    default            { $_ }
                }
            }
        $results.Add([pscustomobject]@{
            Dependency = $dep.Name
            Pinned     = if ($null -eq $floor) { '(missing)' } else { $floor }
            Latest     = if ($errMsg) { '?' } else { $latestFull }
            Status     = $status
            Source     = $dep.Source
            Detail     = if ($errMsg) { $errMsg } else { '' }
        })
    }
}

$updateCount = @($results | Where-Object { $_.Status -eq 'UPDATE AVAILABLE' }).Count
$failCount   = @($results | Where-Object { $_.Status -eq 'check failed' }).Count
if ($updateCount -gt 0) {
    Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_18982d04385047ff' -Arguments @{ updateCount = "$updateCount"; versionsFile = "$VersionsFile" })
} else {
    Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_af1b6f5726980144')
}
if ($failCount -gt 0) {
    Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_7cbd86bd81900553' -Arguments @{ failCount = "$failCount" })
}
$floorBehind = @($results | Where-Object { $_.Status -eq 'floor behind latest' }).Count
if ($floorBehind -gt 0) {
    Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_c4bb0e59cd2b6b17' -Arguments @{ floorBehind = "$floorBehind"; requirementFile = "$RequirementFile" })
}

if ($AsJson) {
    $results | ConvertTo-Json -Depth 4
} else {
    $results
}

# Exit non-zero when a pinned dependency has drifted (a newer stable release is
# available) so a CI gate can fail the build on drift. A dependency that could
# not be checked ($failCount) is a transient upstream/network blip, not an
# actionable version bump, so it does not by itself force a non-zero exit.
if ($updateCount -gt 0) { exit 1 }
exit 0
