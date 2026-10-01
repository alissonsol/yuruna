<#PSScriptInfo
.VERSION 2026.09.30
.GUID 4238dc49-0c94-4ba6-a7be-b24343a6ca42
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool intent sync git desired-state
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

# yuruna pool intent sync (the PULL spine for the multi-host pool harness).
# See ../../docs/pool-admin.md#what-a-pool-is for the reconciliation model
# and why every git call is bounded and credential-prompt-proof. -- Test.PoolSync.psm1

# Wall-clock backstops (seconds) for the git operations. A healthy LAN clone/fetch
# of a tiny intent repo finishes well under a second; these only cap a wedged or
# unreachable remote. The clone (first run) gets the larger cap.
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -Global -DisableNameChecking
$script:PoolSyncCloneTimeoutSeconds = 60
$script:PoolSyncFetchTimeoutSeconds = 30

# Invoke-PoolSyncGitCapture (and its exit-code wrapper Invoke-PoolSyncGit)
# runs a git command bounded by a wall-clock cap and kills the
# whole process tree on timeout, so a hung/unreachable remote can never block the
# loop. stdin is closed immediately and the credential-prompt env is neutralized
# (GIT_TERMINAL_PROMPT=0 + empty GIT_ASKPASS + GCM_INTERACTIVE=never), so a remote
# that would otherwise prompt for a password fails fast instead of stalling.
# Returns the exit code, 124 on timeout, or -1 if git could not be started.
# Mirrors Invoke-PoolStorageProcess; kept local so Test.PoolSync has no dependency
# on Test.PoolStorage.
function Invoke-PoolSyncGitCapture {
    <#
    .SYNOPSIS
        Runs a git command bounded by a wall-clock cap, killing the whole process tree on
        timeout, with stdin closed and every interactive credential path neutralized so a
        hung or prompting remote can never block the loop. Returns a hashtable
        @{ ExitCode; StdOut; StdErr } -- ExitCode is 124 on timeout, or -1 when git could
        not be started (StdOut/StdErr are empty in both of those cases).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter()][int]$TimeoutSeconds = 30
    )
    $result = Invoke-BoundedNativeCommand -FilePath 'git' -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds -Environment @{ LC_ALL = 'C'; LANG = 'C'; LANGUAGE = 'C'; GIT_TERMINAL_PROMPT = '0'; GIT_ASKPASS = ''; SSH_ASKPASS = ''; GCM_INTERACTIVE = 'never' } -MaxCapturedChars 262144
    if ($result.Started -and -not (Test-BoundedNativeResultComplete -Result $result)) { $result.ExitCode = 124 }
    return $result
}

function Invoke-PoolSyncGit {
    <#
    .SYNOPSIS
        Exit-code-only wrapper over Invoke-PoolSyncGitCapture (same bounded, credential-
        prompt-proof semantics). Returns the exit code, 124 on timeout, or -1 if git
        could not be started.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter()][int]$TimeoutSeconds = 30
    )
    return (Invoke-PoolSyncGitCapture -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds).ExitCode
}

function Test-PoolIntentCloneOrigin {
    <#
    .SYNOPSIS
        Returns $false only when the clone at -Path provably has an `origin` that differs
        from -Url. An unreadable origin (not a repository, git unrunnable, timeout) returns
        $true: the caller's own git step then reports the real failure. Without this check a
        clone left over from an earlier intentGitUrl keeps being fetched and pushed while
        the operator's current URL is silently ignored.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Url
    )
    $r = Invoke-PoolSyncGitCapture -ArgumentList @('-C', $Path, 'remote', 'get-url', 'origin') -TimeoutSeconds 15
    if ($r.ExitCode -ne 0) { return $true }
    $normalize = {
        param([string]$Value)
        $v = ($Value.Trim() -replace '\\', '/').TrimEnd('/')
        if ($v.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) { $v = $v.Substring(0, $v.Length - 4) }
        return $v.TrimEnd('/').ToLowerInvariant()
    }
    return ((& $normalize ([string]$r.StdOut)) -ceq (& $normalize $Url))
}

function Get-YurunaPoolConfig {
    <#
    .SYNOPSIS
        Returns a normalized pool config object, or $null when the feature is off (no pool
        block, enabled:false unless -IgnoreEnabled, or an empty intentGitUrl).
    .DESCRIPTION
        Accepts an already-parsed config; otherwise reads test.config.yml via
        the resolved YURUNA_CONFIG_PATH.
        When no parsed config is supplied, Read-TestConfig receives a resolved path;
        omitting its mandatory Path would prompt indefinitely in a headless runner.
        The pool config carries no poolId: membership lives in pools.yml members[].
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][AllowNull()]$Config,
        # Return the normalized object even when enabled is false, as long as
        # intentGitUrl is set -- for pre-flight validation (Test-Config) of the
        # connection before an operator flips enabled to true. The returned
        # object's Enabled field still reflects the real flag. The runner never
        # passes this, so a false enabled stays a no-op there.
        [switch]$IgnoreEnabled
    )
    if (-not $Config) {
        $cfgPath = if ($env:YURUNA_CONFIG_PATH) { $env:YURUNA_CONFIG_PATH } else { $null }
        if (-not [string]::IsNullOrWhiteSpace($cfgPath) -and (Test-Path -LiteralPath $cfgPath) -and
            (Get-Command Read-TestConfig -ErrorAction SilentlyContinue)) {
            try { $Config = Read-TestConfig -Path $cfgPath } catch { Write-Verbose "Read-TestConfig failed: $($_.Exception.Message)" }
        } else {
            Write-Verbose 'Get-YurunaPoolConfig: no -Config and no resolvable YURUNA_CONFIG_PATH; feature off.'
            return $null
        }
    }
    if (-not ($Config -is [System.Collections.IDictionary]) -or -not $Config.Contains('pool')) { return $null }
    $p = $Config['pool']
    if (-not ($p -is [System.Collections.IDictionary])) { return $null }
    $enabled      = ([string]$p['enabled']).Trim() -in @('true', 'yes', 'on', '1')
    $intentGitUrl = [string]$p['intentGitUrl']
    $localClone   = [string]$p['localClonePath']
    $pullTimeout  = if ($p['pullTimeoutSeconds']) { [int]$p['pullTimeoutSeconds'] } else { $script:PoolSyncFetchTimeoutSeconds }
    if (-not $enabled -and -not $IgnoreEnabled) { return $null }
    if ([string]::IsNullOrWhiteSpace($intentGitUrl)) {
        if ($enabled) { Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_3ee74fe8c9b60225') }
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($localClone)) {
        $runtimeDir = if ($env:YURUNA_RUNTIME_DIR) { $env:YURUNA_RUNTIME_DIR } else { Join-Path ([System.IO.Path]::GetTempPath()) 'yuruna-runtime' }
        $localClone = Join-Path $runtimeDir 'pool-intent'
    }
    return [pscustomobject]@{
        Enabled        = $enabled
        IntentGitUrl   = $intentGitUrl.Trim()
        LocalClonePath = $localClone
        PullTimeoutSeconds = $pullTimeout
    }
}

# Resolve-YurunaPoolForHost is the PURE core: given parsed pool intent and this
# host's stable hostId, return the pool object whose members[] contains the hostId
# (the single-source-of-truth lookup), or $null. No I/O; unit-testable.
function Resolve-YurunaPoolForHost {
    <#
    .SYNOPSIS
        The pure core lookup: given parsed pool intent and this host's stable hostId,
        returns the pool object whose members[] contains the hostId (the single source of
        truth), or $null. No I/O; unit-testable.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter()][AllowNull()]$Intent,
        [Parameter(Mandatory)][AllowEmptyString()][string]$HostId
    )
    if ([string]::IsNullOrWhiteSpace($HostId)) { return $null }
    if (-not ($Intent -is [System.Collections.IDictionary]) -or -not $Intent.Contains('pools')) { return $null }
    # A host belongs to AT MOST one pool (enforced by Add-HostToPool /
    # Test-PoolIntent). Collect every pool that lists this hostId so a multi-pool
    # authoring slip is surfaced loudly instead of silently first-match-wins.
    # $poolMatches (NOT $matches -- that shadows PowerShell's automatic regex var).
    $poolMatches = New-Object System.Collections.Generic.List[object]
    foreach ($pool in @($Intent['pools'])) {
        if (-not ($pool -is [System.Collections.IDictionary])) { continue }
        foreach ($member in @($pool['members'])) {
            # A member entry is either a bare hostId string or a mapping carrying a
            # hostId/name key; normalize to the identity string before comparing, so a
            # structured entry does not silently fail the bare-string assumption. Compare
            # ordinal-exact: hostId is a generated lowercase 42-prefixed hex string (32
            # chars), so an exact match is the correct identity test and a case/format
            # difference is a real authoring error, not a variant to accept.
            $memberId = if ($member -is [System.Collections.IDictionary]) {
                if ($member.Contains('hostId'))  { [string]$member['hostId'] }
                elseif ($member.Contains('name')) { [string]$member['name'] }
                else { '' }
            } else { [string]$member }
            if ([string]::Equals($memberId, $HostId, [System.StringComparison]::Ordinal)) { [void]$poolMatches.Add($pool); break }
        }
    }
    if ($poolMatches.Count -eq 0) { return $null }
    $winner = $poolMatches[0]
    if ($poolMatches.Count -gt 1) {
        $ids = @()
        foreach ($pm in $poolMatches) { $ids += [string]$pm['poolId'] }
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_5a025273229840cf' -Arguments @{ hostId = "$HostId"; join = "$($ids -join ', ')"; poolId = "$([string]$winner['poolId'])" })
    }
    return $winner
}

function Test-PoolIntentHasMember {
    <#
    .SYNOPSIS
        Pure: $true when the parsed pool intent lists at least one member in any pool.
    .DESCRIPTION
        Lets the caller tell "this host is genuinely absent from a populated members[]"
        (a probable hostId authoring typo, worth a warning) apart from "the intent lists
        no members at all". No I/O; unit-testable.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Intent)
    if (-not ($Intent -is [System.Collections.IDictionary]) -or -not $Intent.Contains('pools')) { return $false }
    foreach ($pool in @($Intent['pools'])) {
        if (($pool -is [System.Collections.IDictionary]) -and @($pool['members']).Count -gt 0) { return $true }
    }
    return $false
}

# Resolve-YurunaPoolDesiredState is PURE: returns run|paused|drain for a pool
# object, defaulting to 'run' when the pool is $null, the field is absent, or the
# value is unrecognized (fail-safe: an unknown intent never silently pauses a host).
function Resolve-YurunaPoolDesiredState {
    <#
    .SYNOPSIS
        Returns run|paused|drain for a pool object, defaulting to 'run' when the pool is
        $null, the field is absent, or the value is unrecognized (fail-safe: an unknown
        intent never silently pauses a host). Pure; no I/O.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Pool)
    if (-not ($Pool -is [System.Collections.IDictionary])) { return 'run' }
    $s = ([string]$Pool['desiredState']).Trim().ToLowerInvariant()
    if ($s -in @('run', 'paused', 'drain')) { return $s }
    return 'run'
}

# ConvertTo-PoolGatingRecord normalizes the operator-authored pools.yml `gating`
# block to the canonical shape carried to the aggregator (via pool.state.json ->
# host.registration.json). An EMPTY block (`gating: {}` or a bare `gating:`) yields
# an empty hashtable -- NOT $null -- so it still signals "alert me, with the schema
# defaults" downstream; the caller passes $null only when the pool authored no gating
# key at all (no alerts). Only the known numeric knobs are copied (extra keys dropped).
function ConvertTo-PoolGatingRecord {
    <#
    .SYNOPSIS
        Normalizes the operator-authored pools.yml gating block to the canonical record
        carried to the aggregator (only the known numeric knobs are copied, extra keys
        dropped). An empty block yields an empty ordered record (NOT $null) so it still
        signals "alert with the schema defaults"; the caller passes $null only when the
        pool authored no gating key at all.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary], [System.Collections.Specialized.OrderedDictionary])]
    param([Parameter()][AllowNull()]$Gating)
    $rec = [ordered]@{}
    if ($Gating -is [System.Collections.IDictionary]) {
        if ($Gating.Contains('failuresBeforeAlert'))  { $rec['failuresBeforeAlert']  = [int]$Gating['failuresBeforeAlert'] }
        if ($Gating.Contains('successesBeforeRearm')) { $rec['successesBeforeRearm'] = [int]$Gating['successesBeforeRearm'] }
        if ($Gating['quorum'] -is [System.Collections.IDictionary]) {
            $q = [ordered]@{}
            if ($Gating['quorum'].Contains('healthyThreshold'))     { $q['healthyThreshold']     = [double]$Gating['quorum']['healthyThreshold'] }
            if ($Gating['quorum'].Contains('degradedAfterSeconds')) { $q['degradedAfterSeconds'] = [int]$Gating['quorum']['degradedAfterSeconds'] }
            if ($q.Count -gt 0) { $rec['quorum'] = $q }
        }
    }
    return $rec
}

# Write-YurunaPoolState persists the per-cycle pull result to
# runtime/pool.state.json so the FRESH inner-runner process (which writes the host
# registration record) can stamp the derived poolId + gating without re-pulling --
# the filesystem is the cross-process channel (the inner process does not inherit the
# outer's $global). Atomic via Test.StateFile when available, else a direct write.
# Gating is null when the pool authored none (so registration carries no gating ->
# the aggregator observes the pool's gauges but never pages it).
function Write-YurunaPoolState {
    <#
    .SYNOPSIS
        Persists the per-cycle pull result to runtime/pool.state.json so the fresh
        inner-runner process can stamp the derived poolId + gating without re-pulling --
        the filesystem is the cross-process channel. Atomic via Test.StateFile when
        available, else a direct write. Returns $true on success. Gating is null when the
        pool authored none.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()][string]$PoolId,
        [Parameter(Mandatory)][string]$DesiredState,
        [Parameter(Mandatory)][bool]$IntentOk,
        [Parameter()][AllowNull()]$Gating,
        [Parameter()][AllowNull()][string]$PoolGuid
    )
    $runtimeDir = $env:YURUNA_RUNTIME_DIR
    if ([string]::IsNullOrWhiteSpace($runtimeDir)) { return $false }
    $path = Join-Path $runtimeDir 'pool.state.json'
    if (-not $PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.operator_566ac18cb90d8da9'))) { return $false }
    $state = [ordered]@{
        poolId       = $PoolId
        poolGuid     = $PoolGuid
        desiredState = $DesiredState
        intentOk     = $IntentOk
        gating       = $Gating
        lastSyncUtc  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
    if (Get-Command Write-YurunaStateFileJson -ErrorAction SilentlyContinue) {
        return [bool](Write-YurunaStateFileJson -Path $path -InputObject $state -Depth 4 -Confirm:$false)
    }
    try {
        [System.IO.File]::WriteAllText($path, ($state | ConvertTo-Json -Depth 4 -Compress), [System.Text.UTF8Encoding]::new($false))
        return $true
    } catch { Write-Verbose "Write-YurunaPoolState failed: $($_.Exception.Message)"; return $false }
}

# Write-YurunaPoolManifest persists the resolved pool's framework and project
# repositories to runtime/pool.manifest.json so the FRESH inner-runner process
# can override its repositories.frameworkUrl / repositories.projectUrl for the
# cycle. Atomic write, same cross-process channel as pool.state.json. When the
# pool is $null or does not carry both URLs, any stale manifest is DELETED so
# the inner falls back to the host's own repositories config. Best-effort.
function Write-YurunaPoolManifest {
    <#
    .SYNOPSIS
        Persists the resolved pool's repositories (frameworkUrl + projectUrl) to
        runtime/pool.manifest.json so the fresh inner-runner overrides its repo URLs for
        the cycle. When the pool is $null or does not carry both URLs, any stale manifest
        is deleted so the inner falls back to the host's own repositories config.
        Best-effort; returns $true only when a manifest was written.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()]$Pool,
        # autoEnrollment.targetPoolId from the intent doc, when the store
        # declares one. Supplied by the caller because only it has read the
        # document; empty on every store that has not opted into auto-enrollment,
        # which makes the guard below inert.
        [Parameter()][AllowEmptyString()][string]$AutoEnrollTargetPoolId = ''
    )
    $runtimeDir = $env:YURUNA_RUNTIME_DIR
    if ([string]::IsNullOrWhiteSpace($runtimeDir)) { return $false }
    $path = Join-Path $runtimeDir 'pool.manifest.json'
    $repositories = if ($Pool -is [System.Collections.IDictionary]) { $Pool['repositories'] } else { $null }
    # Defense in depth for the target-pool rule. Test-PoolIntent and
    # Set-PoolRepository.ps1 both refuse repositories on the auto-enrollment
    # target pool, but neither runs on this host: a hand-edited store would
    # otherwise reach here and repoint the host. Ignore them loudly rather than
    # obey them -- a host that lands in the target pool automatically must keep
    # running its own project.
    if ($repositories -and $AutoEnrollTargetPoolId -and ([string]$Pool['poolId'] -eq $AutoEnrollTargetPoolId)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_68f76316350291c3' -Arguments @{ poolId = "$($Pool['poolId'])" })
        $repositories = $null
    }
    # Both URLs must be non-blank. The runner never validates the store against
    # its schema, and a manifest without a usable pair would still mark the
    # cycle as pooled (host-scoped VM names) while the inner runner kept the
    # host's own repositories.
    $frameworkUrl = ''
    $projectUrl   = ''
    if ($repositories -is [System.Collections.IDictionary]) {
        $frameworkUrl = "$($repositories['frameworkUrl'])".Trim()
        $projectUrl   = "$($repositories['projectUrl'])".Trim()
    }
    if (-not $frameworkUrl -or -not $projectUrl) {
        if ((Test-Path -LiteralPath $path) -and $PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.operator_8c18f9a4318c42b8'))) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.operator_6fc9e3d7a9f00bc4'))) { return $false }
    # The fresh inner-runner process reads this object and nothing else from
    # the intent, so these key names are a contract with the "Pooled repos
    # override" region of Test.RunnerInnerLoop.psm1.
    $manifest = [ordered]@{
        poolId       = [string]$Pool['poolId']
        poolGuid     = [string]$Pool['poolGuid']
        repositories = [ordered]@{
            frameworkUrl = $frameworkUrl
            projectUrl   = $projectUrl
        }
        config       = if ($Pool['config'] -is [System.Collections.IDictionary]) { $Pool['config'] } else { @{} }
        writtenAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
    if (Get-Command Write-YurunaStateFileJson -ErrorAction SilentlyContinue) {
        return [bool](Write-YurunaStateFileJson -Path $path -InputObject $manifest -Depth 8 -Confirm:$false)
    }
    try {
        [System.IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json -Depth 8 -Compress), [System.Text.UTF8Encoding]::new($false))
        return $true
    } catch { Write-Verbose "Write-YurunaPoolManifest failed: $($_.Exception.Message)"; return $false }
}

# Sync-YurunaPoolIntent is the per-cycle PULL, called IN-PROCESS at the outer
# loop's cycle start. Clone-or-fetch the bare intent repo (bounded), parse
# pools.yml, find this host's pool by hostId, persist the derived poolId +
# desiredState to runtime/pool.state.json, and RETURN the pool object (or $null).
# Graceful degradation: a remote that is down/unreachable falls back to the
# last-good cloned pools.yml if present (stale-but-safe), else returns $null so the
# host cycles as a single host. Never throws.
function Sync-YurunaPoolIntent {
    <#
    .SYNOPSIS
        The per-cycle pull, called in-process at the outer loop's cycle start: clone-or-
        fetch the bare intent repo (bounded), parse pools.yml, find this host's pool by
        hostId, persist the derived poolId + desiredState to runtime/pool.state.json, and
        return the pool object (or $null). Falls back to the last-good cached pools.yml
        when the remote is unreachable, else cycles as a single host. Never throws.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Reads $global:__YurunaHostId -- the cross-host identity channel the entry point sets -- to find this host in pools.yml members[].')]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter()][AllowNull()]$Config,
        [Parameter()][string]$HostId
    )
    $pcfg = Get-YurunaPoolConfig -Config $Config
    if (-not $pcfg -or -not $pcfg.Enabled) {
        $null = Write-YurunaPoolManifest -Pool $null -Confirm:$false   # clear any stale manifest -> inner runs single-host
        return $null   # default-off short-circuit
    }
    if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
        Write-Verbose 'Sync-YurunaPoolIntent: powershell-yaml not available; skipping.'
        $null = Write-YurunaPoolManifest -Pool $null -Confirm:$false   # clear stale manifest -> inner runs single-host
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($HostId)) { $HostId = [string]$global:__YurunaHostId }

    $clone   = $pcfg.LocalClonePath
    $gitDir  = Join-Path $clone '.git'
    $pullOk  = $false
    $rc      = 0
    try {
        if (Test-Path -LiteralPath $gitDir) {
            # The clone is a disposable read-only cache: follow the configured URL when an
            # earlier intentGitUrl left a different origin behind.
            if (-not (Test-PoolIntentCloneOrigin -Path $clone -Url $pcfg.IntentGitUrl)) {
                $null = Invoke-PoolSyncGit -ArgumentList @('-C', $clone, 'remote', 'set-url', 'origin', $pcfg.IntentGitUrl) -TimeoutSeconds 15
            }
            # One wall-clock budget for the whole fetch+reset pull: derive each call's
            # timeout from a single deadline so a slow fetch cannot hand the reset a fresh
            # full PullTimeoutSeconds and let the pair run to ~2x the intended bound.
            $deadlineUtc = [DateTime]::UtcNow.AddSeconds($pcfg.PullTimeoutSeconds)
            $fetchBudget = [Math]::Max(1, [int][Math]::Ceiling(($deadlineUtc - [DateTime]::UtcNow).TotalSeconds))
            $rc = Invoke-PoolSyncGit -ArgumentList @('-C', $clone, 'fetch', '--depth', '1', '--quiet', 'origin') -TimeoutSeconds $fetchBudget
            if ($rc -eq 0) {
                $resetBudget = [Math]::Max(1, [int][Math]::Ceiling(($deadlineUtc - [DateTime]::UtcNow).TotalSeconds))
                $rc = Invoke-PoolSyncGit -ArgumentList @('-C', $clone, 'reset', '--hard', '--quiet', 'FETCH_HEAD') -TimeoutSeconds $resetBudget
            }
            $pullOk = ($rc -eq 0)
        } else {
            $parent = Split-Path -Parent $clone
            if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            $rc = Invoke-PoolSyncGit -ArgumentList @('clone', '--depth', '1', '--quiet', $pcfg.IntentGitUrl, $clone) -TimeoutSeconds $script:PoolSyncCloneTimeoutSeconds
            $pullOk = ($rc -eq 0)
        }
    } catch { $rc = -1; Write-Verbose "Sync-YurunaPoolIntent: git step threw: $($_.Exception.Message)" }

    $poolsPath = Join-Path $clone 'pools.yml'
    if (-not (Test-Path -LiteralPath $poolsPath)) {
        # No intent available (first pull failed, nothing cached): behave single-host.
        $null = Write-YurunaPoolState -PoolId $null -DesiredState 'run' -IntentOk:$pullOk -Confirm:$false
        $null = Write-YurunaPoolManifest -Pool $null -Confirm:$false   # clear stale manifest -> single-host
        if (-not $pullOk) {
            $why = if ($rc -eq 124) { 'timed out' } elseif ($rc -eq -1) { 'git not runnable' } else { "git rc=$rc" }
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_6a59b18694397dbf' -Arguments @{ intentGitUrl = "$($pcfg.IntentGitUrl)"; why = "$why" })
        }
        return $null
    }
    if (-not $pullOk) {
        # Surface WHY the pull failed so a real git error (a persistent 128/network
        # failure) is not indistinguishable from a transient timeout in the log.
        $why = if ($rc -eq 124) { 'timed out' } elseif ($rc -eq -1) { 'git not runnable' } else { "git rc=$rc" }
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_2d47f583d26c79d3' -Arguments @{ why = "$why"; poolsPath = "$poolsPath" })
    }

    $intent = $null
    try { $intent = Get-Content -Raw -LiteralPath $poolsPath | ConvertFrom-Yaml -Ordered } catch { Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_075bc59a36ee3ca1' -Arguments @{ message = "$($_.Exception.Message)" }) }
    $pool = Resolve-YurunaPoolForHost -Intent $intent -HostId $HostId
    if (-not $pool -and (Test-PoolIntentHasMember -Intent $intent)) {
        # pools.yml parsed and lists members, but none is this host: almost always a
        # hostId spelling/case typo in the intent repo rather than a deliberate exclusion.
        # Surface it so the authoring error is observable instead of silently single-host.
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_47955cec68775797' -Arguments @{ hostId = "$HostId" })
    }
    $poolId   = if ($pool) { [string]$pool['poolId'] } else { $null }
    $poolGuid = if ($pool) { [string]$pool['poolGuid'] } else { $null }
    $state  = Resolve-YurunaPoolDesiredState -Pool $pool
    # Carry the authored gating policy (the advisory alert thresholds) to the
    # aggregator via pool.state.json -> host.registration.json. $null when the pool
    # authored no gating KEY (the aggregator then never pages it); an empty block is a
    # non-null empty record (alert with the schema defaults).
    $gating = if (($pool -is [System.Collections.IDictionary]) -and $pool.Contains('gating')) {
        ConvertTo-PoolGatingRecord -Gating $pool['gating']
    } else { $null }
    $null = Write-YurunaPoolState -PoolId $poolId -PoolGuid $poolGuid -DesiredState $state -IntentOk:$pullOk -Gating $gating -Confirm:$false
    # Publish (or clear, when this host is unpooled or its pool carries no
    # repositories) the pool's framework and project repositories for the
    # inner runner. The target-pool id is read from the same parsed document so
    # the manifest writer can refuse repositories on it (defense in depth --
    # neither the admin CLI nor Test-PoolIntent runs on this host).
    $autoTarget = if (($intent -is [System.Collections.IDictionary]) -and $intent['autoEnrollment']) { [string]$intent['autoEnrollment']['targetPoolId'] } else { '' }
    $null = Write-YurunaPoolManifest -Pool $pool -AutoEnrollTargetPoolId $autoTarget -Confirm:$false
    return $pool
}

Export-ModuleMember -Function `
    Get-YurunaPoolConfig, Sync-YurunaPoolIntent, Test-PoolIntentCloneOrigin, `
    Resolve-YurunaPoolForHost, Resolve-YurunaPoolDesiredState, `
    Test-PoolIntentHasMember, `
    Write-YurunaPoolState, Write-YurunaPoolManifest, Invoke-PoolSyncGit, Invoke-PoolSyncGitCapture, `
    ConvertTo-PoolGatingRecord
