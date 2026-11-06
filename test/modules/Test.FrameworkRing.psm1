<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42ac82f7-1138-43e6-bf39-f54ef6969713
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool framework canary ring update
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
    The host side of the framework canary ring: which role this host plays in its
    pool's ring, and which framework revision a follower may install.
.DESCRIPTION
    A pool's pools.yml may carry a frameworkRing block (canaryMembers,
    requiredPasses). Canary members, and every host of a pool without the block,
    install the framework tip exactly as before. Every other member is a follower:
    it asks the pool aggregator for the newest framework revision with at least
    requiredPasses valid canary passes, counted over the canaries this host's own
    copy of pools.yml names, and installs only that. A follower that gets no
    answer, or an answer with no qualifying revision, stays where it is; it never
    falls back to the tip.

    The role comes from runtime/pool.state.json, which the cycle's pool pull
    writes, so a member decides with the configuration its previous cycle pulled
    and a ring change takes effect one cycle later. A host that has never pulled
    the pool configuration has no role yet and runs as a standalone host does.
#>

<#
.SYNOPSIS
    Read runtime/pool.state.json as a hashtable, or $null when it is absent or
    unreadable.
#>
function Read-YurunaPoolStateRecord {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR)
    if ([string]::IsNullOrWhiteSpace($RuntimeDir)) { return $null }
    $path = Join-Path $RuntimeDir 'pool.state.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable -ErrorAction Stop) }
    catch { Write-Verbose "Read-YurunaPoolStateRecord: $($_.Exception.Message)"; return $null }
}

<#
.SYNOPSIS
    This host's role in its pool's framework ring: 'none' (no ring; install the tip),
    'canary' (track the tip) or 'follower' (install the qualifying revision).
#>
function Get-YurunaFrameworkRingRole {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$PoolState, [AllowEmptyString()][string]$HostId)
    if ($PoolState -isnot [System.Collections.IDictionary]) { return 'none' }
    $ring = $PoolState['frameworkRing']
    if ($ring -isnot [System.Collections.IDictionary] -or [string]::IsNullOrWhiteSpace([string]$PoolState['poolId'])) { return 'none' }
    $canaries = @($ring['canaryMembers'] | ForEach-Object { ([string]$_).ToLowerInvariant() })
    if ($HostId -and $canaries -contains $HostId.ToLowerInvariant()) { return 'canary' }
    return 'follower'
}

<#
.SYNOPSIS
    Ask the pool aggregator which framework revision qualifies for a canary list.
.DESCRIPTION
    An open read of the aggregator's framework-ring route, HTTPS first and then
    HTTP, with the TLS leaf unverified for the same reason as the other open pool
    reads: the aggregator's certificate comes from the caching-proxy service's own
    CA. The answer only chooses among revisions the host's own trusted source
    already fetched (Resolve-GitRingRevision), so it is a selection, never a
    source of code.
.OUTPUTS
    [hashtable] Ok (the aggregator answered), Revision ('' when none qualifies),
    Passes, Detail (why Ok is false).
#>
function Get-YurunaFrameworkRingQualification {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowEmptyCollection()][string[]]$CanaryMembers = @(),
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$RequiredPasses,
        [string]$BaseUrl,
        [int]$TimeoutSeconds = 10
    )
    $result = @{ Ok = $false; Revision = ''; Passes = 0; Detail = '' }
    if (-not $BaseUrl) {
        if (-not (Get-Command Get-PoolAggregatorServiceSeedUrl -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $PSScriptRoot 'Test.CachingProxyService.psm1') -Global -DisableNameChecking -Verbose:$false
        }
        $BaseUrl = [string](Get-PoolAggregatorServiceSeedUrl)
        if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $result.Detail = 'no caching-proxy-service address known'; return $result }
    }
    if (-not (Get-Command Get-PoolAggregatorServiceManifest -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $PSScriptRoot '../extension/pool-aggregator-service/default.psm1') -Global -DisableNameChecking -Verbose:$false
    }
    $route = (Get-PoolAggregatorServiceManifest).Endpoints.FrameworkRing
    $query = 'canary=' + [uri]::EscapeDataString(($CanaryMembers | ForEach-Object { ([string]$_).ToLowerInvariant() }) -join ',') + "&passes=$RequiredPasses"
    $bases = @(@($BaseUrl, ($BaseUrl -replace '^https:', 'http:')) | Select-Object -Unique)
    foreach ($base in $bases) {
        $uri = "$($base.TrimEnd('/'))$route`?$query"
        try {
            $response = Invoke-WebRequest -Uri $uri -TimeoutSec $TimeoutSeconds -NoProxy -SkipCertificateCheck -SkipHttpErrorCheck -ErrorAction Stop -Verbose:$false
        } catch {
            $result.Detail = $_.Exception.Message
            continue
        }
        if ($response.StatusCode -ne 200) { $result.Detail = "HTTP $($response.StatusCode) from $uri"; continue }
        try { $answer = $response.Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
        catch { $result.Detail = "unreadable answer from ${uri}: $($_.Exception.Message)"; continue }
        $revision = ([string]$answer['qualifyingRevision']).Trim().ToLowerInvariant()
        if ($revision -and $revision -cnotmatch '^[0-9a-f]{40}$') { $result.Detail = "invalid revision from $uri"; continue }
        $passes = 0
        $null = [int]::TryParse([string]$answer['qualifyingPasses'], [ref]$passes)
        return @{ Ok = $true; Revision = $revision; Passes = $passes; Detail = '' }
    }
    return $result
}

<#
.SYNOPSIS
    Decide what the framework update does on this host for the ring.
.OUTPUTS
    [hashtable] Role ('none' | 'canary' | 'follower'); for a follower also
    Revision ('' = stay where it is), Passes, RequiredPasses, Reason ('' |
    'aggregator-unreachable' | 'no-qualifying-revision') and Detail.
#>
function Resolve-YurunaFrameworkRingTarget {
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Reads $global:__YurunaHostId, the identity channel the entry points set, to find this host among the canaries.')]
    param(
        [string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR,
        [string]$HostId = $global:__YurunaHostId,
        [string]$BaseUrl
    )
    $state = Read-YurunaPoolStateRecord -RuntimeDir $RuntimeDir
    $decision = @{ Role = (Get-YurunaFrameworkRingRole -PoolState $state -HostId $HostId); Revision = ''; Passes = 0; RequiredPasses = 0; Reason = ''; Detail = '' }
    if ($decision.Role -ne 'follower') { return $decision }
    $ring = $state['frameworkRing']
    $required = 0
    if (-not [int]::TryParse([string]$ring['requiredPasses'], [ref]$required) -or $required -lt 1 -or $required -gt 1000) {
        $decision.Reason = 'no-qualifying-revision'; return $decision
    }
    $decision.RequiredPasses = $required
    $lookup = @{ CanaryMembers = @($ring['canaryMembers'] | ForEach-Object { [string]$_ }); RequiredPasses = $required }
    if ($BaseUrl) { $lookup.BaseUrl = $BaseUrl }
    # A lookup that throws is one more way of not getting an answer: the follower
    # holds instead of failing the update.
    try { $answer = Get-YurunaFrameworkRingQualification @lookup }
    catch { $answer = @{ Ok = $false; Detail = $_.Exception.Message } }
    if (-not $answer.Ok) { $decision.Reason = 'aggregator-unreachable'; $decision.Detail = $answer.Detail; return $decision }
    if (-not $answer.Revision) { $decision.Reason = 'no-qualifying-revision'; return $decision }
    $decision.Revision = $answer.Revision
    $decision.Passes = $answer.Passes
    return $decision
}

<#
.SYNOPSIS
    Persist the last ring decision to runtime/framework-ring.json.
.DESCRIPTION
    The failure-pause poll runs in the resident runner, the update in the cycle
    process, so the record is how the poll learns that a qualifying revision was
    already held and need not wake the runner again. It also lets an operator see
    why a follower stayed where it is.
#>
function Write-YurunaFrameworkRingDecision {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Role,
        [AllowEmptyString()][string]$Revision = '',
        [Parameter(Mandatory)][string]$Outcome,
        [AllowEmptyString()][string]$Reason = '',
        [string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR
    )
    if ([string]::IsNullOrWhiteSpace($RuntimeDir)) { return $false }
    $path = Join-Path $RuntimeDir 'framework-ring.json'
    if (-not $PSCmdlet.ShouldProcess($path, 'Record the framework ring decision')) { return $false }
    $record = [ordered]@{
        role     = $Role
        revision = $Revision
        outcome  = $Outcome
        reason   = $Reason
        atUtc    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
    if (Get-Command Write-YurunaStateFileJson -ErrorAction SilentlyContinue) {
        return [bool](Write-YurunaStateFileJson -Path $path -InputObject $record -Depth 3 -Confirm:$false)
    }
    try {
        [System.IO.File]::WriteAllText($path, ($record | ConvertTo-Json -Depth 3 -Compress), [System.Text.UTF8Encoding]::new($false))
        return $true
    } catch { Write-Verbose "Write-YurunaFrameworkRingDecision: $($_.Exception.Message)"; return $false }
}

<#
.SYNOPSIS
    Read runtime/framework-ring.json, or $null when absent or unreadable.
#>
function Read-YurunaFrameworkRingDecision {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR)
    if ([string]::IsNullOrWhiteSpace($RuntimeDir)) { return $null }
    $path = Join-Path $RuntimeDir 'framework-ring.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable -ErrorAction Stop) }
    catch { Write-Verbose "Read-YurunaFrameworkRingDecision: $($_.Exception.Message)"; return $null }
}

Export-ModuleMember -Function Read-YurunaPoolStateRecord, Get-YurunaFrameworkRingRole, Get-YurunaFrameworkRingQualification, `
    Resolve-YurunaFrameworkRingTarget, Write-YurunaFrameworkRingDecision, Read-YurunaFrameworkRingDecision
