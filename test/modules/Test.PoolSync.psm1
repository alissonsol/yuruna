<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42b1c2d3-e4f5-4a67-8b90-1c2d3e4f5a6b
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
# Each runner PULLs the slow-changing pool intent (pools.yml: membership +
# desiredState) from a bare git repo on the caching-proxy over the LAN, finds its
# OWN pool by locating its stable hostId in members[] (the single source of
# truth), and reconciles the pulled desiredState (run|paused|drain) into the outer
# loop -- exactly like the local control.cycle-restart flag. Everything here is
# OPTIONAL + default-off + BEST-EFFORT: a host with no pool config, or an
# unreachable intent store, keeps cycling as a single host. Every git call is
# wall-clock-bounded + credential-prompt-proof so the unattended (and on the
# bare-pwsh path, INTERACTIVE) outer loop can never hang on it.

# Wall-clock backstops (seconds) for the git operations. A healthy LAN clone/fetch
# of a tiny intent repo finishes well under a second; these only cap a wedged or
# unreachable remote. The clone (first run) gets the larger cap.
$script:PoolSyncCloneTimeoutSec = 60
$script:PoolSyncFetchTimeoutSec = 30

# Invoke-PoolSyncGit runs a git command bounded by a wall-clock cap and kills the
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
    $git = (Get-Command -CommandType Application -Name 'git' -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $git) { Write-Verbose 'Invoke-PoolSyncGitCapture: git not found on PATH.'; return @{ ExitCode = -1; StdOut = ''; StdErr = '' } }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $git
    foreach ($a in $ArgumentList) { [void]$psi.ArgumentList.Add([string]$a) }
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    # Neutralize every interactive credential path for the child only.
    $psi.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $psi.Environment['GIT_ASKPASS']         = ''
    $psi.Environment['SSH_ASKPASS']         = ''
    $psi.Environment['GCM_INTERACTIVE']     = 'never'
    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-Verbose "Invoke-PoolSyncGitCapture: failed to start git: $($_.Exception.Message)"
        return @{ ExitCode = -1; StdOut = ''; StdErr = '' }
    }
    try { $proc.StandardInput.Close() } catch { $null = $_ }
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        Write-Warning "pool sync: 'git $($ArgumentList -join ' ')' exceeded ${TimeoutSeconds}s; killing the process tree."
        try { $proc.Kill($true) } catch { $null = $_ }
        try { $null = $proc.WaitForExit(5000) } catch { $null = $_ }
        try { $proc.Dispose() } catch { $null = $_ }
        return @{ ExitCode = 124; StdOut = ''; StdErr = '' }
    }
    try { $null = [System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask), 2000) } catch { $null = $_ }
    $result = @{ ExitCode = [int]$proc.ExitCode; StdOut = [string]$outTask.Result; StdErr = [string]$errTask.Result }
    try { $proc.Dispose() } catch { $null = $_ }
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

# Get-YurunaPoolConfig returns a normalized pool config object, or $null when the
# feature is OFF (no `pool` block, enabled:false unless -IgnoreEnabled, or an empty
# intentGitUrl). Mirrors Get-YurunaPoolStorageConfig: accepts an already-parsed
# config (IDictionary); when none is supplied it reads test.config.yml via
# Read-TestConfig USING A RESOLVED PATH ($env:YURUNA_CONFIG_PATH) -- never by-name
# with the Mandatory $Path omitted (that stalls forever on the interactive
# "Supply values for the following parameters:" prompt under the headless runner).
# NOTE: the pool config carries NO poolId -- membership lives only in pools.yml
# members[] (the single source of truth); the runner derives its pool from there.
function Get-YurunaPoolConfig {
    <#
    .SYNOPSIS
        Returns a normalized pool config object, or $null when the feature is off (no pool
        block, enabled:false unless -IgnoreEnabled, or an empty intentGitUrl). Accepts an
        already-parsed config; otherwise reads test.config.yml via the resolved
        YURUNA_CONFIG_PATH. Carries no poolId -- membership lives only in pools.yml.
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
    $enabled      = [bool]$p['enabled']
    $intentGitUrl = [string]$p['intentGitUrl']
    $localClone   = [string]$p['localClonePath']
    $pullTimeout  = if ($p['pullTimeoutSeconds']) { [int]$p['pullTimeoutSeconds'] } else { $script:PoolSyncFetchTimeoutSec }
    if (-not $enabled -and -not $IgnoreEnabled) { return $null }
    if ([string]::IsNullOrWhiteSpace($intentGitUrl)) {
        if ($enabled) { Write-Warning 'pool.enabled is true but pool.intentGitUrl is empty; pool intent sync disabled.' }
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
        PullTimeoutSec = $pullTimeout
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
    foreach ($pool in @($Intent['pools'])) {
        if (-not ($pool -is [System.Collections.IDictionary])) { continue }
        foreach ($member in @($pool['members'])) {
            # A member entry is either a bare hostId string or a mapping carrying a
            # hostId/name key; normalize to the identity string before comparing, so a
            # structured entry does not silently fail the bare-string assumption. Compare
            # ordinal-exact: hostId is a generated lowercase 42-prefixed hex string (32
            # chars), so an exact
            # match is the correct identity test and a case/format difference is a real
            # authoring error, not a variant to accept.
            $memberId = if ($member -is [System.Collections.IDictionary]) {
                if ($member.Contains('hostId'))  { [string]$member['hostId'] }
                elseif ($member.Contains('name')) { [string]$member['name'] }
                else { '' }
            } else { [string]$member }
            if ([string]::Equals($memberId, $HostId, [System.StringComparison]::Ordinal)) { return $pool }
        }
    }
    return $null
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
            if ($Gating['quorum'].Contains('degradedAfterMinutes')) { $q['degradedAfterMinutes'] = [int]$Gating['quorum']['degradedAfterMinutes'] }
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
        [Parameter()][AllowNull()]$Gating
    )
    $runtimeDir = $env:YURUNA_RUNTIME_DIR
    if ([string]::IsNullOrWhiteSpace($runtimeDir)) { return $false }
    $path = Join-Path $runtimeDir 'pool.state.json'
    if (-not $PSCmdlet.ShouldProcess($path, 'Write pool sync state')) { return $false }
    $state = [ordered]@{
        poolId       = $PoolId
        desiredState = $DesiredState
        intentOk     = $IntentOk
        gating       = $Gating
        lastSyncUtc  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
    if (Get-Command Write-YurunaStateFileJson -ErrorAction SilentlyContinue) {
        return [bool](Write-YurunaStateFileJson -Path $path -InputObject $state -Depth 4 -Confirm:$false)
    }
    try {
        [System.IO.File]::WriteAllText($path, ($state | ConvertTo-Json -Depth 4 -Compress), [System.Text.UTF8Encoding]::new($false))
        return $true
    } catch { Write-Verbose "Write-YurunaPoolState failed: $($_.Exception.Message)"; return $false }
}

# Write-YurunaPoolManifest persists the resolved pool's TEST-SET assignment to
# runtime/pool.manifest.json so the FRESH inner-runner process can drive
# the cycle from the pool's test-sets instead of test.runner.yml. Atomic write,
# same cross-process channel as pool.state.json. When the pool is $null OR has no
# test-sets, any stale manifest is DELETED so the inner falls back to single-host
# (the gate is "manifest present with a non-empty testSets[]"). Best-effort.
function Write-YurunaPoolManifest {
    <#
    .SYNOPSIS
        Persists the resolved pool's test-set assignment to runtime/pool.manifest.json so
        the fresh inner-runner process drives the cycle from the pool's test-sets instead
        of test.runner.yml. When the pool is $null or has no test-sets, any stale manifest
        is deleted so the inner falls back to single-host. Best-effort; returns $true only
        when a manifest was written.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Pool)
    $runtimeDir = $env:YURUNA_RUNTIME_DIR
    if ([string]::IsNullOrWhiteSpace($runtimeDir)) { return $false }
    $path = Join-Path $runtimeDir 'pool.manifest.json'
    $testSets = if ($Pool -is [System.Collections.IDictionary]) { @($Pool['testSets']) } else { @() }
    if (-not ($Pool -is [System.Collections.IDictionary]) -or $testSets.Count -eq 0) {
        if ((Test-Path -LiteralPath $path) -and $PSCmdlet.ShouldProcess($path, 'Remove stale pool manifest')) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($path, 'Write pool manifest')) { return $false }
    $sets = New-Object System.Collections.Generic.List[object]
    foreach ($ts in $testSets) {
        if (-not ($ts -is [System.Collections.IDictionary])) { continue }
        $sets.Add([ordered]@{
            name          = [string]$ts['name']
            order         = if ($ts.Contains('order')) { [int]$ts['order'] } else { 0 }
            cycleStrategy = if ($ts.Contains('cycleStrategy')) { [string]$ts['cycleStrategy'] } else { 'all' }
        })
    }
    $manifest = [ordered]@{
        poolId      = [string]$Pool['poolId']
        testSets    = @($sets.ToArray())
        config      = if ($Pool['config'] -is [System.Collections.IDictionary]) { $Pool['config'] } else { @{} }
        writtenAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
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
            # One wall-clock budget for the whole fetch+reset pull: derive each call's
            # timeout from a single deadline so a slow fetch cannot hand the reset a fresh
            # full PullTimeoutSec and let the pair run to ~2x the intended bound.
            $deadlineUtc = [DateTime]::UtcNow.AddSeconds($pcfg.PullTimeoutSec)
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
            $rc = Invoke-PoolSyncGit -ArgumentList @('clone', '--depth', '1', '--quiet', $pcfg.IntentGitUrl, $clone) -TimeoutSeconds $script:PoolSyncCloneTimeoutSec
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
            Write-Warning "pool sync: could not reach the intent store ($($pcfg.IntentGitUrl)) ($why); cycling as a single host."
        }
        return $null
    }
    if (-not $pullOk) {
        # Surface WHY the pull failed so a real git error (a persistent 128/network
        # failure) is not indistinguishable from a transient timeout in the log.
        $why = if ($rc -eq 124) { 'timed out' } elseif ($rc -eq -1) { 'git not runnable' } else { "git rc=$rc" }
        Write-Warning "pool sync: intent fetch failed ($why); using the last-good cached pools.yml ($poolsPath)."
    }

    $intent = $null
    try { $intent = Get-Content -Raw -LiteralPath $poolsPath | ConvertFrom-Yaml -Ordered } catch { Write-Warning "pool sync: pools.yml parse failed ($($_.Exception.Message)); cycling as a single host." }
    $pool = Resolve-YurunaPoolForHost -Intent $intent -HostId $HostId
    if (-not $pool -and (Test-PoolIntentHasMember -Intent $intent)) {
        # pools.yml parsed and lists members, but none is this host: almost always a
        # hostId spelling/case typo in the intent repo rather than a deliberate exclusion.
        # Surface it so the authoring error is observable instead of silently single-host.
        Write-Warning "pool sync: host $HostId is not in any pool's members[] though pools.yml lists members; check the hostId spelling/case in the intent repo. Cycling as a single host."
    }
    $poolId = if ($pool) { [string]$pool['poolId'] } else { $null }
    $state  = Resolve-YurunaPoolDesiredState -Pool $pool
    # Carry the authored gating policy (the advisory alert thresholds) to the
    # aggregator via pool.state.json -> host.registration.json. $null when the pool
    # authored no gating KEY (the aggregator then never pages it); an empty block is a
    # non-null empty record (alert with the schema defaults).
    $gating = if (($pool -is [System.Collections.IDictionary]) -and $pool.Contains('gating')) {
        ConvertTo-PoolGatingRecord -Gating $pool['gating']
    } else { $null }
    $null = Write-YurunaPoolState -PoolId $poolId -DesiredState $state -IntentOk:$pullOk -Gating $gating -Confirm:$false
    # Publish (or clear, when this host is unpooled / the pool has no
    # test-sets) the resolved test-set assignment for the inner runner.
    $null = Write-YurunaPoolManifest -Pool $pool -Confirm:$false
    return $pool
}

Export-ModuleMember -Function `
    Get-YurunaPoolConfig, Sync-YurunaPoolIntent, `
    Resolve-YurunaPoolForHost, Resolve-YurunaPoolDesiredState, `
    Test-PoolIntentHasMember, `
    Write-YurunaPoolState, Write-YurunaPoolManifest, Invoke-PoolSyncGit, Invoke-PoolSyncGitCapture, `
    ConvertTo-PoolGatingRecord
