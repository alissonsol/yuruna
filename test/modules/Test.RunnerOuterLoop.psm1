<#PSScriptInfo
.VERSION 2026.10.31
.GUID 42904a4e-7e96-4d32-883d-8326239ad090
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner outer-loop
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
    Eternal cycle loop for [test/Start-TestRunner.ps1](../Start-TestRunner.ps1):
    git pull, spawn the inner runner per cycle, watch the heartbeat,
    pause on failure with four break-out triggers (framework commit,
    project commit, local config edit, status-UI start request).
.DESCRIPTION
    Stops only on Ctrl+C (caller's $State.ShutdownState['Requested']
    flip). Per the resilience contract, anything else -- a flaky
    network, a hung sequence, an unhandled exception inside the
    inner -- is just another failure that the outer absorbs and retries.

    Lives in its own module, separate from the Start-TestRunner.ps1
    entry point, so the loop body and its helpers can be unit-tested
    independently of the entry-point script. The caller (Start-TestRunner.ps1) builds
    a State hashtable and calls Invoke-RunnerOuterLoop; the function
    returns when ShutdownState['Requested'] flips. The watchdog lives
    in its own module ([Test.RunnerWatchdog](Test.RunnerWatchdog.psm1))
    so the heartbeat + kill logic stays decoupled from the loop.
#>

# --- REGION: Pure git / config helpers
# Each helper is module-level and takes its inputs as parameters; no
# script-scope state is read implicitly. Callers (Invoke-RunnerOuterLoop
# and downstream test fixtures) pass repo paths + config paths
# explicitly so the helpers stay testable.

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.OuterLog.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.HostGit.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.SourceSelection.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.FrameworkRing.psm1') -DisableNameChecking
# The refresh gate, the cycle record and the handoff helpers the loop consults
# before every spawn live in Test.SingleInstance. Imported here as well as by the
# Outer module set so the gate is never absent from a process that can spawn.
Import-Module (Join-Path $PSScriptRoot 'Test.SingleInstance.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.DiagnosticPreservation.psm1') -DisableNameChecking
# The cycle outcome record, the typed result and the bounded repairs the loop reports
# and recovers through. Imported here as well as by the Outer module set so the loop
# never runs without them.
Import-Module (Join-Path $PSScriptRoot 'Test.RecoveryContract.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.RecoveryLedger.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.RecoveryProbe.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.RecoveryActions.psm1') -DisableNameChecking
function Get-OuterCommitSha {
    <#
    .SYNOPSIS
        Return the local HEAD SHA of the repo at $RepoRoot, or $null when
        git fails (not a repo, detached/unborn HEAD, git error).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    $sha = & git -C $RepoRoot rev-parse HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ([string]$sha).Trim()
}

function Invoke-OuterNetworkGit {
    <#
    .SYNOPSIS
        One bounded, credential-prompt-proof network git run for the outer loop,
        trying every GitHub credential source the host has: GH_TOKEN, then the
        gh CLI's stored login, then plain git (machine credential helper / SSH
        agent). Returns @{ ExitCode; StdOut; StdErr; Output }.
    .DESCRIPTION
        Execution stays on Invoke-PoolSyncGitCapture (wall-clock cap +
        process-tree kill + neutralized credential prompts), so nothing here can
        hang the (bare-pwsh-INTERACTIVE) outer loop. The credential sources
        (Get-YurunaGitAuthAttemptList) and the auth classifier
        (Test-GitRemoteAuthFailure) live in Test.HostGit; both are
        Get-Command-guarded like the module's other cross-module calls, so a
        session without Test.HostGit degrades to a single plain bounded run.
        A failed credentialed attempt falls through to the next source only when
        the failure is credential-shaped -- a network outage fails identically
        for every source, so it is returned immediately instead of burning
        another bounded timeout per source.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter()][int]$TimeoutSeconds = 30,
        [datetime]$DeadlineUtc = [datetime]::MaxValue
    )
    # Classifier captured as CommandInfo once, so the foreign-module call works
    # regardless of import scope.
    $classifier = Get-Command Test-GitRemoteAuthFailure -ErrorAction SilentlyContinue
    $attempts   = @()
    if (Get-Command Get-YurunaGitAuthAttemptList -ErrorAction SilentlyContinue) {
        $attempts = @(Get-YurunaGitAuthAttemptList)
    }
    foreach ($attempt in $attempts) {
        $remaining = [int][math]::Min([double]$TimeoutSeconds, [math]::Floor(($DeadlineUtc - [datetime]::UtcNow).TotalSeconds))
        if ($remaining -lt 1) { return @{ ExitCode = 124; StdOut = ''; StdErr = ''; Output = 'Repository probe deadline expired.' } }
        # The -c credential args are git GLOBAL options -- they precede the caller's args.
        $r   = Invoke-PoolSyncGitCapture -ArgumentList (@($attempt.Args) + @($ArgumentList)) -TimeoutSeconds $remaining
        $out = ((@($r.StdOut, $r.StdErr) | Where-Object { $_ }) -join "`n").Trim()
        $hit = @{ ExitCode = [int]$r.ExitCode; StdOut = [string]$r.StdOut; StdErr = [string]$r.StdErr; Output = $out }
        if ($hit.ExitCode -eq 0) { return $hit }
        if (-not ($classifier -and (& $classifier -Output $out))) { return $hit }
        Write-Verbose "Invoke-OuterNetworkGit: the $($attempt.Source) attempt was rejected as unauthorized; trying the next credential source."
    }
    $remaining = [int][math]::Min([double]$TimeoutSeconds, [math]::Floor(($DeadlineUtc - [datetime]::UtcNow).TotalSeconds))
    if ($remaining -lt 1) { return @{ ExitCode = 124; StdOut = ''; StdErr = ''; Output = 'Repository probe deadline expired.' } }
    $r = Invoke-PoolSyncGitCapture -ArgumentList $ArgumentList -TimeoutSeconds $remaining
    return @{
        ExitCode = [int]$r.ExitCode
        StdOut   = [string]$r.StdOut
        StdErr   = [string]$r.StdErr
        Output   = ((@($r.StdOut, $r.StdErr) | Where-Object { $_ }) -join "`n").Trim()
    }
}

function Test-OuterNewCommitsAvailable {
    <#
    .SYNOPSIS
        Report a changed configured upstream tip, including a rewind or a new
        history root. The baseline is the remote tip observed at pause entry,
        so an unchanged remote cannot repeatedly wake a locally ahead checkout.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$BaselineSha,
        [string]$ConfigPath,
        [datetime]$DeadlineUtc = [datetime]::UtcNow.AddSeconds(30)
    )
    if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot 'test/test.config.yml' }
    # The failure pause polls this every few minutes while the operator may be
    # saving test.config.yml; a config that does not parse, or a mirror block
    # that is invalid, ends this probe and never the resident runner.
    try {
        # A canary-ring follower installs only the revision the pool qualified, so
        # a new tip is no reason to end its pause; a new qualifying revision is.
        $ring = Resolve-YurunaFrameworkRingTarget
        if ($ring.Role -eq 'follower') { return (Test-OuterRingRevisionNew -RepoRoot $RepoRoot -Ring $ring) }
        $snapshot = Get-GitSourceConfiguration -ConfigPath $ConfigPath
        $target = Get-GitRepositoryUpdateTarget -RepoRoot $RepoRoot -NoFetch -Operation Poll -SourceContext $snapshot.context -DeadlineUtc $DeadlineUtc
        return [bool]($target.Success -and -not $target.Skipped -and $target.Revision -ne $BaselineSha)
    } catch {
        Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.outer_poll_failed' -Arguments @{ probe = 'framework'; message = (ConvertTo-RecoverySafeText -Text ([string]$_.Exception.Message)) })
        return $false
    }
}

function Test-RunnerConfigGateNetworkOnly {
    <#
    .SYNOPSIS
        Classify structured gate failures without interpreting operator messages.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()]$Gate)
    if (-not $Gate -or -not $Gate.failures) { return $false }
    foreach ($failure in @($Gate.failures)) {
        if (-not $failure -or -not (Test-TransientNetworkFailureClass -FailureClass ([string]$failure.class))) {
            return $false
        }
    }
    return $true
}

function Test-OuterRepositoryAccess {
    <#
    .SYNOPSIS
        Check source access within one deadline, without fetching or requiring a new SHA.
    .DESCRIPTION
        The framework uses its configured upstream; a detached release needs no
        framework update. Every required source must answer before recovery is
        reported. Local project sources keep their existing Git transport.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][datetime]$DeadlineUtc,
        [switch]$NoGitPull
    )
    if ($DeadlineUtc -le [datetime]::UtcNow) { return $false }
    try {
        $snapshot = Get-GitSourceConfiguration -ConfigPath $ConfigPath
        $prior = Read-InstalledGitSource -RepoRoot $RepoRoot
        $required = 0
        if (-not $NoGitPull) {
            $target = Get-GitRepositoryUpdateTarget -RepoRoot $RepoRoot -NoFetch -Operation Poll -SourceContext $snapshot.context -InstalledProvenance $prior.framework -DeadlineUtc $DeadlineUtc
            if (-not $target.Success) { return $false }
            if (-not $target.Skipped) { $required++ }
        }
        if ($snapshot.projectUrl) {
            $selected = Resolve-GitSourceSelection -RepositoryUrl $snapshot.projectUrl -Ref HEAD -SourceContext $snapshot.context -Operation Poll -InstalledProvenance $prior.project -DeadlineUtc $DeadlineUtc
            if (-not $selected.success) { return $false }
            $required++
        }
        return $required -gt 0
    } catch { Write-Verbose "Repository recovery probe failed: $($_.Exception.Message)"; return $false }

}

function Test-OuterRingRevisionNew {
    <#
    .SYNOPSIS
        For a canary-ring follower, report a qualifying revision the checkout does
        not already contain and that the last update did not already hold back.
    .DESCRIPTION
        The update runs in the cycle process and records its decision; reading that
        record keeps a revision the follower cannot install (another upstream, or
        not newer) from ending every pause. A revision whose objects are not here
        yet reads as new, and the next update decides.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][System.Collections.IDictionary]$Ring)
    if (-not $Ring.Revision) { return $false }
    $head = Get-OuterCommitSha -RepoRoot $RepoRoot
    if (-not $head -or $Ring.Revision -ceq $head) { return $false }
    $last = Read-YurunaFrameworkRingDecision
    if ($last -and [string]$last.revision -ceq $Ring.Revision -and ([string]$last.outcome).StartsWith('held-', [StringComparison]::Ordinal)) { return $false }
    $null = & git -C $RepoRoot merge-base --is-ancestor $Ring.Revision $head 2>$null
    return ($LASTEXITCODE -ne 0)
}

function Invoke-OuterGitPull {
    <#
    .SYNOPSIS
        Update clean framework sources to their configured upstream snapshot.
        Return one boolean and retain a redacted failure for the cycle record.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$RepoRoot, [string]$ConfigPath)
    $script:LastOuterPullFailure = ''
    $script:LastOuterPullFailureClass = 'bootstrap_sync'
    $script:LastOuterSourceSelection = $null
    if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot 'test/test.config.yml' }
    try {
        $snapshot = Get-GitSourceConfiguration -ConfigPath $ConfigPath
        $prior = Read-InstalledGitSource -RepoRoot $RepoRoot
        $update = @{ RepoRoot = $RepoRoot; SourceContext = $snapshot.context; InstalledProvenance = $prior.framework; DeadlineUtc = ([datetime]::UtcNow.AddSeconds(280)) }
        # A canary-ring follower installs the revision its pool qualified, or stays
        # where it is; it never falls back to the tip. Canaries and hosts of a pool
        # without a ring take the update below unchanged.
        $ring = Resolve-YurunaFrameworkRingTarget
        if ($ring.Role -eq 'follower') {
            if (-not $ring.Revision) {
                $current = Get-OuterCommitSha -RepoRoot $RepoRoot
                if ($ring.Reason -eq 'aggregator-unreachable') {
                    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.framework_ring_hold_unreachable' -Arguments @{ detail = (ConvertTo-RecoverySafeText -Text ([string]$ring.Detail)); current = "$current" })
                } else {
                    Write-Information (Format-YurunaOperatorMessage -Key 'runner.framework_ring_hold_unqualified' -Arguments @{ passes = "$($ring.RequiredPasses)"; current = "$current" }) -InformationAction Continue
                }
                $null = Write-YurunaFrameworkRingDecision -Role follower -Outcome "held-$($ring.Reason)" -Reason $ring.Reason -Confirm:$false
                return $true
            }
            $update.RingRevision = $ring.Revision
        }
        $result = Invoke-GitRepositoryUpdate @update -Confirm:$false
        if ($ring.Role -eq 'follower' -and $result.Success) {
            $arguments = @{ revision = "$($ring.Revision)"; passes = "$($ring.Passes)"; current = "$($result.PreviousRevision)" }
            switch ([string]$result.RingOutcome) {
                'installed' { Write-Information (Format-YurunaOperatorMessage -Key 'runner.framework_ring_follow' -Arguments $arguments) -InformationAction Continue }
                'held-newer' { Write-Information (Format-YurunaOperatorMessage -Key 'runner.framework_ring_hold_newer' -Arguments @{ revision = $arguments.revision; current = $arguments.current }) -InformationAction Continue }
                'held-not-in-history' { Write-Warning (Format-YurunaOperatorMessage -Key 'runner.framework_ring_hold_not_in_history' -Arguments @{ revision = $arguments.revision; current = $arguments.current }) }
            }
            if ($result.RingOutcome) { $null = Write-YurunaFrameworkRingDecision -Role follower -Revision $ring.Revision -Outcome ([string]$result.RingOutcome) -Confirm:$false }
        }
    } catch { $result = @{ Success = $false; ErrorMessage = $_.Exception.Message } }
    if (-not $result.Success) {
        if ($result.FailureClass -and (Test-RecoveryFailureClass -FailureClass $result.FailureClass)) { $script:LastOuterPullFailureClass = [string]$result.FailureClass }
        $script:LastOuterPullFailure = ConvertTo-RecoverySafeText -Text ([string]$result.ErrorMessage)
        if ($script:LastOuterPullFailure) { Write-Information $script:LastOuterPullFailure -InformationAction Continue }
        return $false
    }
    $script:LastOuterSourceSelection = $result.SourceSelection
    if ($result.SourceSelection -and -not (Write-InstalledGitSource -RepoRoot $RepoRoot -Kind framework -Selection $result.SourceSelection -Confirm:$false)) { throw 'source-provenance-write-failed' }
    return $true
}

function Get-OuterSourceSelection {
    <# .SYNOPSIS
        Return evidence retained separately from the legacy Boolean update API.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param()
    return $script:LastOuterSourceSelection
}

function Get-OuterRemoteSha {
    <#
    .SYNOPSIS
        Query a remote repo's current HEAD SHA via git ls-remote without
        needing a local clone (the project is wiped + re-cloned at cycle
        start, so a local clone may not exist mid-pause). $null on empty
        URL or any failure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RemoteUrl,
        [string]$ConfigPath,
        [datetime]$DeadlineUtc = [datetime]::UtcNow.AddSeconds(30))
    if ([string]::IsNullOrWhiteSpace($RemoteUrl)) { return $null }
    if (-not $ConfigPath) { $ConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'test.config.yml' }
    # Same contract as Test-OuterNewCommitsAvailable: a failed probe is "no answer".
    try {
        $snapshot = Get-GitSourceConfiguration -ConfigPath $ConfigPath
        $selection = Resolve-GitSourceSelection -RepositoryUrl $RemoteUrl -Ref HEAD -SourceContext $snapshot.context -Operation Poll -DeadlineUtc $DeadlineUtc
    } catch {
        Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.outer_poll_failed' -Arguments @{ probe = 'project'; message = (ConvertTo-RecoverySafeText -Text ([string]$_.Exception.Message)) })
        return $null
    }
    if (-not $selection.success) { return $null }
    return [string]$selection.selectedSha
}

function Get-OuterConfigMtime {
    <#
    .SYNOPSIS
        Snapshot the on-disk UTC mtime of test.config.yml, or $null when
        the file is missing. The pause loop compares two snapshots with
        -ne, so a $null / non-null transition (config deleted or created
        mid-pause) is itself a change worth breaking on, letting an
        operator edit/create the config and get a near-immediate restart.
    #>
    [CmdletBinding()]
    [OutputType([Nullable[datetime]])]
    param([Parameter(Mandatory)][string]$ConfigPath)
    try {
        if (Test-Path -LiteralPath $ConfigPath) {
            return (Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc
        }
    } catch {
        Write-Verbose "Get-OuterConfigMtime: $($_.Exception.Message)"
    }
    return $null
}

function Get-OuterMaxCycleSeconds {
    <#
    .SYNOPSIS
        Read testCycle.maxCycleSeconds, the absolute bound the resident runner
        puts on one cycle process, with the same per-cycle re-read as the
        watchdog timeouts. 0 (or any non-positive value) disables the bound.
    .DESCRIPTION
        The step-heartbeat watchdog is armed inside the cycle process and stands
        down when it cannot prove the inner's identity, which leaves that cycle
        with no bound at all. This ceiling is enforced by the resident on the
        cycle process it spawned, so it holds whatever happens below it.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural is the unit, not a collection: a duration is named <name>Seconds so a bare number can never be read in the wrong unit (docs/design/naming.md). Singularizing to Second would read as one second.')]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][int]$DefaultSeconds,
        [Parameter()][hashtable]$PoolTestCycleOverride = @{}
    )
    return Get-OuterTimeoutValue -Key maxCycleSeconds -Minimum 0 -MessageKey 'runner.max_cycle_seconds_invalid' @PSBoundParameters
}

function Get-OuterCycleCeilingSeconds {
    <#
    .SYNOPSIS
        The bound on one cycle's working time: testCycle.maxCycleSeconds, or two
        step timeouts for each run the cycle plans when that is more.
    .DESCRIPTION
        A fixed bound fits one size of plan. The template's 21600 is three runs at
        two hours each; a plan with more guests or sequences takes proportionally
        longer, and a bound it always outgrows would stop every cycle of that
        host before it could finish. A non-positive configured value keeps the
        bound disabled whatever the plan.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural is the unit, not a collection: a duration is named <name>Seconds so a bare number can never be read in the wrong unit (docs/design/naming.md). Singularizing to Second would read as one second.')]
    param(
        [Parameter(Mandatory)][int]$ConfiguredSeconds,
        [Parameter(Mandatory)][int]$StepTimeoutSeconds,
        [Parameter()][int]$PlannedRunCount = 0
    )
    if ($ConfiguredSeconds -le 0) { return 0 }
    $planned = [int64][math]::Max(0, $PlannedRunCount) * 2 * [math]::Max(1, $StepTimeoutSeconds)
    return [int][math]::Min([int64][int]::MaxValue, [math]::Max([int64]$ConfiguredSeconds, $planned))
}

function Get-OuterCyclePlannedRunCount {
    <#
    .SYNOPSIS
        How many runs (guests and orchestration sequences) the cycle that this
        attempt spawned lists in status.json, or 0 until it has published them.
    .DESCRIPTION
        The inner publishes the whole plan, every run pending, when the cycle
        starts. A status.json from an earlier cycle, or one read half-written,
        counts as no plan yet.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][datetime]$SpawnedAtUtc
    )
    try {
        $doc = [IO.File]::ReadAllText((Join-Path $RuntimeDir 'status.json')) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    } catch { return 0 }
    if ($doc -isnot [System.Collections.IDictionary] -or -not $doc['cycleStartUtc']) { return 0 }
    try {
        if (([datetime]$doc['cycleStartUtc']).ToUniversalTime() -lt $SpawnedAtUtc.ToUniversalTime()) { return 0 }
    } catch { return 0 }
    return @(@($doc['guests']) | Where-Object { $null -ne $_ }).Count
}

function Test-OuterCycleHeld {
    <#
    .SYNOPSIS
        Whether the running cycle is held by an operator pause, a lab hold or an
        active debug break.
    .DESCRIPTION
        Held time is time someone chose to spend, so it does not count toward the
        cycle ceiling: a cycle paused for an afternoon would otherwise be stopped
        soon after it resumed. A hang between a pause request and the step
        boundary that honors it stays bounded by the step watchdog.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$RuntimeDir)
    foreach ($name in @('control.step-pause', 'control.cycle-pause', 'control.pause', 'control.lab-hold', 'break-active.json')) {
        if ([IO.File]::Exists((Join-Path $RuntimeDir $name))) { return $true }
    }
    return $false
}

function Read-OuterWatchdogLapseBound {
    <#
    .SYNOPSIS
        The step and preamble bounds a standing-down watchdog recorded in its
        lapse sentinel, as @{ StepSeconds; PreambleSeconds }, or $null.
    .DESCRIPTION
        The cycle process resolves those bounds with the pool's overrides, which
        the resident never reads, so the resident takes them from the watchdog
        rather than from its own reading of the configuration.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)
    try { $text = [IO.File]::ReadAllText($Path) } catch { return $null }
    if ($text -cnotmatch '\[stepSeconds=(\d{1,9}) preambleSeconds=(\d{1,9})\]') { return $null }
    $step = [int]$Matches[1]
    if ($step -lt 1) { return $null }
    return @{ StepSeconds = $step; PreambleSeconds = [int]$Matches[2] }
}

function Step-OuterHeartbeatGuard {
    <#
    .SYNOPSIS
        Advance the resident's heartbeat guard by one poll; return the stall,
        as @{ AgeSeconds; BoundSeconds; Phase }, once the step heartbeat has not
        moved for longer than its bound, or $null.
    .DESCRIPTION
        The guard stands in for a step watchdog that stood down, with that
        watchdog's own rules: the preamble bound while runner.phase exists, the
        step bound once it is gone, and an unreadable phase reads as the looser
        bound. Staleness is the time since the guard last saw the heartbeat's
        write time change, on the guard's Stopwatch, so a wall-clock step can
        neither fire it early nor hold it off, and no bound runs out sooner than
        its full length after the guard engaged.
    .PARAMETER Guard
        @{ Watch; LastWriteUtc; StepSeconds; PreambleSeconds }, updated in place.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$Guard,
        [Parameter(Mandatory)][string]$RuntimeDir
    )
    $heartbeat = Join-Path $RuntimeDir 'runner.stepHeartbeat'
    $stamp = $Guard.LastWriteUtc
    try { $stamp = if ([IO.File]::Exists($heartbeat)) { [IO.File]::GetLastWriteTimeUtc($heartbeat) } else { $null } } catch { $stamp = $Guard.LastWriteUtc }
    if ($stamp -ne $Guard.LastWriteUtc) {
        $Guard.LastWriteUtc = $stamp
        $Guard.Watch.Restart()
    }
    $phase = ''
    try {
        $phaseFile = Join-Path $RuntimeDir 'runner.phase'
        if ([IO.File]::Exists($phaseFile)) { $phase = ([IO.File]::ReadAllText($phaseFile)).Trim() }
    } catch { $phase = '' }
    $preamble = [int]$Guard.PreambleSeconds
    $bound = if ($phase -and $preamble -gt 0 -and $preamble -lt [int]$Guard.StepSeconds) { $preamble } else { [int]$Guard.StepSeconds }
    $age = $Guard.Watch.Elapsed.TotalSeconds
    if ($age -le $bound) { return $null }
    return [pscustomobject]@{ AgeSeconds = [int]$age; BoundSeconds = $bound; Phase = $phase }
}

function Write-OuterStopRecord {
    <#
    .SYNOPSIS
        Write runner.watchdog-kill.json for a cycle the resident stopped, in the
        shape the step watchdog writes, atomically.
    .DESCRIPTION
        The post-dispatch accounting reads this record for the attempt it names,
        so a stop the resident made is attributed the way a watchdog stop is.
        A failed write is logged; it never prevents the stop.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Record)
    $killPath = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.watchdog-kill.json'
    if (-not $PSCmdlet.ShouldProcess($killPath, 'Record the cycle stop')) { return $false }
    try {
        $killTemp = $killPath + '.' + [Guid]::NewGuid().ToString('n') + '.tmp'
        [IO.File]::WriteAllText($killTemp, ($Record | ConvertTo-Json -Depth 6))
        [IO.File]::Move($killTemp, $killPath, $true)
        return $true
    } catch {
        Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.outer_poll_failed' -Arguments @{ probe = 'ceiling-record'; message = (ConvertTo-RecoverySafeText -Text ([string]$_.Exception.Message)) })
        return $false
    }
}

function Get-OuterPoolTestCycleOverride {
    <#
    .SYNOPSIS
        Extract a pool's config.testCycle override map from the pool object
        Sync-YurunaPoolConfiguration returns. PURE + null-safe: returns @{} for a
        null pool / no config / no testCycle, so a no-pool host overlays
        nothing (identical to single-host). Reads straight off the pool
        object -- not pool.manifest.json -- so a pool that authors a
        testCycle override WITHOUT repositories still applies it (the manifest
        is deleted when a pool carries no repositories).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowNull()]$Pool)
    if (-not ($Pool -is [System.Collections.IDictionary])) { return @{} }
    $cfg = $Pool['config']
    if (-not ($cfg -is [System.Collections.IDictionary])) { return @{} }
    $tc = $cfg['testCycle']
    if (-not ($tc -is [System.Collections.IDictionary])) { return @{} }
    # Copy into a plain hashtable so callers index it uniformly (the source is the
    # OrderedDictionary ConvertFrom-Yaml produced).
    $out = @{}
    foreach ($k in $tc.Keys) { $out[[string]$k] = $tc[$k] }
    return $out
}

function Get-OuterTimeoutValue {
    <#
    .SYNOPSIS
        Read a named testCycle timeout from test.config.yml for the next spawn.
    .DESCRIPTION
        An operator can edit between cycles without restarting the outer.
        A positive per-pool config.testCycle override wins over local config,
        which wins over the supplied default.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural is the unit, not a collection: a duration is named <name>Seconds so a bare number can never be read in the wrong unit (docs/design/naming.md). Singularizing to Second would read as one second.')]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][int]$Minimum,
        [Parameter(Mandatory)][string]$MessageKey,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][int]$DefaultSeconds,
        # Per-pool config.testCycle overrides (from Get-OuterPoolTestCycleOverride).
        # An override here WINS over test.config.yml (precedence: pool > config >
        # default). Empty @{} for a no-pool host -> identical to single-host.
        [Parameter()][hashtable]$PoolTestCycleOverride = @{}
    )
    # -NoCache so a mid-cycle operator edit (the "lower stepTimeout for
    # the next cycle" workflow documented in test/README.md) takes effect
    # at the spawn boundary even if Read-TestConfig's mtime-keyed cache
    # hasn't noticed yet on a low-resolution filesystem.
    $cfg = Read-TestConfig -Path $ConfigPath -NoCache -LastGoodOnError
    $v = Get-TestConfigValue -Config $cfg -Path ("testCycle." + $Key)
    $result = $DefaultSeconds
    # TryParse rather than a bare [int] cast: this is re-read on EVERY cycle, so
    # a typo in a mid-run edit would throw from inside the cycle and take the
    # outer runner down over a tuning knob -- a runner that stops without saying
    # why, which is exactly what the watchdog work exists to prevent. Warn and
    # keep the default instead.
    if ($null -ne $v) {
        $i = 0
        if ([int]::TryParse("$v".Trim(), [ref]$i)) {
            if ($i -ge $Minimum) { $result = $i }
        } else {
            Write-Warning (Format-YurunaOperatorMessage -Key $MessageKey -Arguments @{ v = "$v"; defaultSeconds = "$DefaultSeconds" })
        }
    }
    if ($PoolTestCycleOverride.ContainsKey($Key)) {
        $p = 0
        if ([int]::TryParse("$($PoolTestCycleOverride[$Key])".Trim(), [ref]$p) -and $p -ge $Minimum) {
            $result = $p
        }
    }
    return $result
}

function Get-OuterStepTimeoutSeconds {
    <#
    .SYNOPSIS
        Read testCycle.stepTimeoutSeconds from test.config.yml each cycle so
        an operator can edit between cycles and the new bound takes effect on
        the next spawn without restarting the outer. A positive per-pool
        config.testCycle override WINS over the local config (precedence:
        pool > config > default).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural is the unit, not a collection: a duration is named <name>Seconds so a bare number can never be read in the wrong unit (docs/design/naming.md). Singularizing to Second would read as one second.')]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][int]$DefaultSeconds,
        # Per-pool config.testCycle overrides (from Get-OuterPoolTestCycleOverride).
        # An override here WINS over test.config.yml (precedence: pool > config >
        # default). Empty @{} for a no-pool host -> identical to single-host.
        [Parameter()][hashtable]$PoolTestCycleOverride = @{}
    )
    return Get-OuterTimeoutValue -Key stepTimeoutSeconds -Minimum 1 -MessageKey 'runner.operator_353411c243b6e1c7' @PSBoundParameters
}

function Get-OuterPreambleTimeoutSeconds {
    <#
    .SYNOPSIS
        Read testCycle.preambleTimeoutSeconds -- the tighter watchdog bound that
        applies before the inner reaches its first sequence step -- with the same
        per-cycle re-read and pool > config > default precedence as
        Get-OuterStepTimeoutSeconds.
    .DESCRIPTION
        Nothing in the inner's preamble is legitimately slow, so this is set far
        below stepTimeoutSeconds: a stall there is a wedged runner (an
        unanswerable sudo / credential prompt on the inherited terminal being
        the motivating case), and the full step budget is 45 minutes of a green
        dashboard over a host that is doing nothing.

        0 (or any non-positive value) opts out: Start-Watchdog then applies
        stepTimeoutSeconds everywhere. That is the escape hatch for a host whose
        preamble really is slow, and it is why the knob defaults into effect
        rather than requiring opt-in.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural is the unit, not a collection: a duration is named <name>Seconds so a bare number can never be read in the wrong unit (docs/design/naming.md). Singularizing to Second would read as one second.')]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][int]$DefaultSeconds,
        [Parameter()][hashtable]$PoolTestCycleOverride = @{}
    )
    return Get-OuterTimeoutValue -Key preambleTimeoutSeconds -Minimum 0 -MessageKey 'runner.operator_c8d5e682839053d0' @PSBoundParameters
}

function Get-OuterAutoRemediation {
    <#
    .SYNOPSIS
        Read the default-off auto-remediation opt-in (enable flag + per-streak
        cap) fresh from test.config.yml so an operator edit takes effect at the
        spawn boundary, like Get-OuterStepTimeoutSeconds. A per-pool config.testCycle
        override WINS over the local config (pool > config > default), so a pool can
        ENGAGE remediation fleet-wide without editing every host's test.config.yml.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter()][hashtable]$PoolTestCycleOverride = @{}
    )
    $enabled = $false
    $maxAttempts = 2
    try {
        $cfg = Read-TestConfig -Path $ConfigPath -NoCache -LastGoodOnError
        $e = Get-TestConfigValue -Config $cfg -Path 'testCycle.autoRemediation.enabled'
        if ($null -ne $e) { $enabled = [bool]$e }
        $m = Get-TestConfigValue -Config $cfg -Path 'testCycle.autoRemediation.maxAttemptsPerCycle'
        if (($null -ne $m) -and ([int]$m -gt 0)) { $maxAttempts = [int]$m }
    } catch { Write-Verbose "Get-OuterAutoRemediation: $($_.Exception.Message)" }
    # The pool override arrives as the pool's testCycle map, so the nested block
    # is a dictionary value under 'autoRemediation' rather than two flat keys.
    $poolAr = $PoolTestCycleOverride['autoRemediation']
    if ($poolAr -is [System.Collections.IDictionary]) {
        if ($poolAr.Contains('enabled')) {
            $enabled = [bool]$poolAr['enabled']
        }
        if ($poolAr.Contains('maxAttemptsPerCycle') -and ([int]$poolAr['maxAttemptsPerCycle'] -gt 0)) {
            $maxAttempts = [int]$poolAr['maxAttemptsPerCycle']
        }
    }
    return @{ Enabled = $enabled; MaxAttempts = $maxAttempts }
}

function Get-OuterLastFailureClass {
    <#
    .SYNOPSIS
        failureClass from the just-failed cycle's last_failure.json. Safe to
        read during the failure-pause -- the pre-spawn wipe runs at the NEXT
        cycle start, so the file is intact here. $null when absent/unparseable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not $env:YURUNA_LOG_DIR) { return $null }
    $f = Join-Path $env:YURUNA_LOG_DIR 'last_failure.json'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try {
        $rec = Get-Content -Raw -LiteralPath $f -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($rec.Contains('failureClass')) { return [string]$rec['failureClass'] }
    } catch { Write-Verbose "Get-OuterLastFailureClass: $($_.Exception.Message)" }
    return $null
}

function Get-OuterProjectUrl {
    <#
    .SYNOPSIS
        Return repositories.projectUrl from test.config.yml, or $null when
        it is unset -- the remote the failure-pause polls for new project
        commits.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$ConfigPath)
    $cfg = Read-TestConfig -Path $ConfigPath -LastGoodOnError
    $v = Get-TestConfigValue -Config $cfg -Path 'repositories.projectUrl'
    if ($v) { return [string]$v }
    return $null
}

function Get-OuterStatusBaseUrl {
    <#
    .SYNOPSIS
        Scheme + host + port of this host's status service, as another machine
        on the LAN would address it. Empty string when no routable address
        exists.
    .DESCRIPTION
        Deliberately never yields localhost: the value is pasted into a link
        an operator hands to someone else, and a loopback URL resolves on the
        reader's own machine instead of failing visibly.

        The address is taken from the interface that carries a default route.
        Selecting by gateway rather than by enumeration order is what keeps a
        hypervisor's host-only bridge out of the link -- it has an address and
        is 'Up', but nothing off this box can reach it. The per-host drivers
        answer the same question via route(8)/ip(8), but they only resolve
        after Initialize-YurunaHost, which the outer runner does not call.

        runtime/ipaddresses.txt is not used: it is rewritten only when the
        status service starts, so it goes stale the moment the host changes
        network -- exactly when a wrong link is most costly.
    .PARAMETER ConfigPath
        test.config.yml, read for the statusService gate + port.
    .PARAMETER ArgList
        The inner-spawn argv, checked for a forwarded -NoStatusService.
    .OUTPUTS
        [string] e.g. 'http://192.168.7.101:8080', or '' when there is no
        server to link to.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter()][AllowNull()][string[]]$ArgList = @()
    )

    # An operator-published base wins: a reverse proxy or tunneled hostname
    # is not discoverable from inside this process, and its presence means a
    # dashboard is served regardless of what this host runs locally.
    if ($env:YURUNA_STATUS_PUBLIC_URL) { return ([string]$env:YURUNA_STATUS_PUBLIC_URL).TrimEnd('/') }

    # Config is the only record of the port: nothing on disk stores the port
    # the listener actually bound to. The same call answers whether a server
    # was meant to start at all -- linking to one that was never started is
    # worse than printing no link.
    $port = 8080
    try {
        $decision = Resolve-StatusServiceStart -Config (Read-TestConfig -Path $ConfigPath -LastGoodOnError) `
            -NoStatusService:(Test-OuterNoStatusServiceForwarded -ArgList $ArgList)
        if (-not $decision.ShouldStart) { return '' }
        if ($decision.Port) { $port = [int]$decision.Port }
    } catch {
        # An unreadable config says nothing about whether a server is up, so
        # fall through to the default port rather than suppressing the link.
        Write-Verbose "Get-OuterStatusBaseUrl: $($_.Exception.Message)"
    }

    $address = ''
    try {
        $address = [string](
            [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                Where-Object { $_.OperationalStatus -eq 'Up' } |
                Where-Object { @($_.GetIPProperties().GatewayAddresses).Count -gt 0 } |
                ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
                ForEach-Object { $_.Address } |
                Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
                Where-Object { -not [System.Net.IPAddress]::IsLoopback($_) } |
                Select-Object -First 1
        )
    } catch {
        Write-Verbose "Get-OuterStatusBaseUrl: $($_.Exception.Message)"
    }
    if (-not $address) { return '' }
    return "http://${address}:$port"
}

function Get-OuterCycleSummaryLine {
    <#
    .SYNOPSIS
        One console line naming the cycle that just ended, its verdict, and a
        short link to its HTML transcript. Empty string when the cycle left no
        number to name.
    .DESCRIPTION
        The verdict comes from the inner's exit code rather than the status
        document's own overallStatus, so the printed word always agrees with
        what the loop does next (retry vs pause): PASS, FAIL, or DEGRADED with
        the count of skipped guests for a cycle that failed nothing but skipped
        a planned guest. The cycle number and the guest rows come from the
        status document, which the inner writes before it exits.

        The link is the status service's /cycle/<number> alias, not the
        transcript's real path: that path carries the cycle's timestamp and
        host id, which makes it too long to paste into a message, and the
        number is the only part of it a reader can recognize. The server
        resolves the number to the on-disk folder, whatever lifecycle suffix
        it currently carries.
    .PARAMETER ConfigPath
        test.config.yml, forwarded to Get-OuterStatusBaseUrl.
    .PARAMETER ExitCode
        The inner runner's exit code for the finished cycle.
    .PARAMETER ArgList
        The inner-spawn argv, forwarded to Get-OuterStatusBaseUrl.
    .OUTPUTS
        [string] e.g. 'Cycle 004062 - FAIL: http://192.168.7.101:8080/cycle/004062'.
        Drops the link when there is no reachable server to link to.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter()][AllowNull()][string[]]$ArgList = @()
    )
    if (-not $env:YURUNA_RUNTIME_DIR) { return '' }
    $statusPath = Join-Path $env:YURUNA_RUNTIME_DIR 'status.json'
    if (-not (Test-Path -LiteralPath $statusPath)) { return '' }
    $doc = $null
    try {
        $doc = Get-Content -Raw -LiteralPath $statusPath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Verbose "Get-OuterCycleSummaryLine: $($_.Exception.Message)"
        return ''
    }
    $cycleNumber = if ($doc -and $doc.cycle) { [int]$doc.cycle } else { 0 }
    if ($cycleNumber -le 0) { return '' }

    $verdict = if ($ExitCode -eq 0) { 'PASS' } else { 'FAIL' }
    if ($ExitCode -eq (Get-DegradedCycleExitCode)) {
        $guests  = @(if ($doc.PSObject.Properties['guests']) { $doc.guests | Where-Object { $null -ne $_ } })
        $skipped = @($guests | Where-Object { $_.PSObject.Properties['status'] -and [string]$_.status -ceq 'skipped' }).Count
        $verdict = "DEGRADED ($skipped of $($guests.Count) guests skipped)"
    }
    $number  = '{0:D6}' -f $cycleNumber
    $baseUrl = Get-OuterStatusBaseUrl -ConfigPath $ConfigPath -ArgList $ArgList
    if (-not $baseUrl) { return "Cycle $number - $verdict" }
    return "Cycle $number - ${verdict}: $baseUrl/cycle/$number"
}

function Test-OuterNoStatusServiceForwarded {
    <#
    .SYNOPSIS
        True when -NoStatusService was forwarded to the inner runner.
    .DESCRIPTION
        New-InnerRunnerArgList folds the forwarded switches into a single
        combined -Command string element, so the token is embedded mid-string
        rather than a standalone arg -- a start-anchored per-element test would
        never see it. Match -NoStatusService as a whole token in the joined list
        so a hypothetical -NoStatusServiceFoo cannot false-match.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string[]]$ArgList)
    if (-not $ArgList) { return $false }
    return (($ArgList -join ' ') -match '(?<![\w-])-NoStatusService(?![\w-])')
}

# --- REGION: Forward-env helper
function Sync-ForwardEnv {
    <#
    .SYNOPSIS
        Re-assert the launch-time snapshot of YURUNA_* env vars so the
        inner sees them even if some module in this outer process
        clobbered $env: mid-run -- which is why the snapshot is
        re-asserted before every spawn rather than once at outer startup.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Re-asserts a known-good snapshot; -WhatIf would be noise per key.')]
    param([Parameter(Mandatory)][hashtable]$ForwardEnvSnapshot)
    foreach ($n in $ForwardEnvSnapshot.Keys) {
        $current = [Environment]::GetEnvironmentVariable($n)
        if ($current -ne $ForwardEnvSnapshot[$n]) {
            Set-Item -Path "Env:$n" -Value $ForwardEnvSnapshot[$n]
        }
    }
}

function Clear-TerminalNotifierJob {
<#
.SYNOPSIS
    Best-effort, non-blocking reap of pool-notifier thread jobs that a prior
    cycle's Wait-Job timeout leaked onto $State.LeakedNotifierJobs.
.DESCRIPTION
    Removes only the jobs that have since gone terminal (Completed/Failed/Stopped)
    and drops them from the list; a job still wedged in a blocking CIFS syscall
    stays Running and is left in place for a later sweep. This is deliberate:
    reading .State and removing a terminal job never block, but a -Force removal
    of a still-running job can block for the OS SMB timeout -- the exact stall the
    leak-and-reap design exists to avoid. No-op when nothing was ever leaked.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)
    if (-not $State.LeakedNotifierJobs) { return }
    foreach ($lj in @($State.LeakedNotifierJobs)) {
        if ($lj.State -in @('Completed', 'Failed', 'Stopped')) {
            Remove-Job -Job $lj -ErrorAction SilentlyContinue
            [void]$State.LeakedNotifierJobs.Remove($lj)
        }
    }
}

# --- REGION: Pool alert delivery on a cadence
# A cycle delivers pool alerts only at its end, so a host held between cycles --
# in a failure pause, a gate or a non-verdict hold -- delivered none, and a host
# whose cycles ended early never did. The resident also runs the notifier from
# its waits, at most once a minute and never blocking: each tick collects the
# run the previous one started. The notifier's own lock keeps the resident and
# a cycle process from running it at once.
$script:PoolNotifierTickIntervalMs = 60000
$script:PoolNotifierRunCapMs = 120000
# The resident's state while its loop runs, so its waits can tick; $null in a
# cycle process, which delivers at its end instead.
$script:OuterWaitTickState = $null

function Invoke-OuterPoolNotifierTick {
    <#
    .SYNOPSIS
        Collect the notifier run the last tick started, and start the next one
        when a minute has passed, without waiting for either.
    .DESCRIPTION
        A run still going after the same 120 s cap the cycle-end hook applies is
        set aside on LeakedNotifierJobs, which the cycle-end reaper sweeps once
        it is terminal: removing a job wedged in a blocking mount call can block
        too.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)
    $now = [Environment]::TickCount64
    $job = $State['PoolNotifierJob']
    if ($job) {
        if ($job.State -in @('Completed', 'Failed', 'Stopped')) {
            try {
                $summary = Receive-Job -Job $job -ErrorAction Stop
                if ($summary -and $summary.ran -and (($summary.enqueued + $summary.delivered + $summary.failed + $summary.retried) -gt 0)) {
                    Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_463371faa645f632' -Arguments @{ cycle = 'resident'; enqueued = "$($summary.enqueued)"; delivered = "$($summary.delivered)"; retried = "$($summary.retried)"; failed = "$($summary.failed)" })
                }
            } catch { Write-Verbose "pool notifier tick: $($_.Exception.Message)" }
            finally { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
            $State['PoolNotifierJob'] = $null
        } elseif (($now - [long]$State['PoolNotifierJobStartedMs']) -ge $script:PoolNotifierRunCapMs) {
            if (-not $State.LeakedNotifierJobs) { $State.LeakedNotifierJobs = [System.Collections.Generic.List[object]]::new() }
            [void]$State.LeakedNotifierJobs.Add($job)
            Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_eb2af2d8a9f44de2' -Arguments @{ cycle = 'resident'; count = "$($State.LeakedNotifierJobs.Count)" })
            $State['PoolNotifierJob'] = $null
        } else {
            return
        }
    }
    if ($State.ContainsKey('PoolNotifierTickMs') -and ($now - [long]$State['PoolNotifierTickMs']) -lt $script:PoolNotifierTickIntervalMs) { return }
    $State['PoolNotifierTickMs'] = $now
    if (-not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) { return }
    $notifierCfg = $null
    if (Get-Command Read-TestConfig -ErrorAction SilentlyContinue) {
        try { $notifierCfg = Read-TestConfig -Path $State.ConfigPath -LastGoodOnError } catch { $null = $_ }
    }
    $notifierModulesDir = $PSScriptRoot
    try {
        $State['PoolNotifierJob'] = Start-ThreadJob -Name 'pool-notifier-resident' -ScriptBlock {
            Import-Module (Join-Path $using:notifierModulesDir 'Test.PoolStorage.psm1') -Global -ErrorAction Stop
            Import-Module (Join-Path $using:notifierModulesDir 'Test.CachingProxyService.psm1') -Global -ErrorAction Stop
            Import-Module (Join-Path $using:notifierModulesDir 'Test.Notify.psm1') -Global -ErrorAction Stop
            Import-Module (Join-Path $using:notifierModulesDir 'Test.PoolNotifier.psm1') -Global -ErrorAction Stop
            Invoke-PoolNotifierCycle -Config $using:notifierCfg
        }
        $State['PoolNotifierJobStartedMs'] = $now
    } catch {
        Write-Verbose "pool notifier tick could not start: $($_.Exception.Message)"
        $State['PoolNotifierJob'] = $null
    }
}

# --- REGION: Main loop
# See https://yuruna.link/4213a0b3-0108
$script:LastOuterCycleResult = $null

# Why the latest framework pull failed (see Get-LastOuterPullFailure).
$script:LastOuterPullFailure = ''
$script:LastOuterPullFailureClass = 'bootstrap_sync'

# Below this, a non-zero cycle child that reported no outcome is treated as having
# aborted on the way in rather than as a failed cycle. Sized well under anything a
# real cycle can do -- the inner's own preamble budget alone is 600s -- so a
# genuine failure can never be swallowed by it, while the observed abort signature
# (a console that broke under the child) lands in single-digit seconds.
$script:CycleAbortSeconds = 30

function Get-LastOuterCycleResult {
    <#
    .SYNOPSIS
        The result of the most recent Invoke-RunnerOuterCycle in this process,
        or $null if none has run.
    .DESCRIPTION
        The out-of-band half of the contract described above. Each cycle runs in
        a fresh process that re-imports this module, so there is no stale value to
        read across cycles. The pool's testCycle override the cycle resolved rides
        along as PoolTestCycle, for the resident's repair decisions.
    .OUTPUTS
        pscustomobject with Outcome and ExitCode, or $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $result = $script:LastOuterCycleResult
    if ($result -and $script:LastOuterPoolTestCycle -is [System.Collections.IDictionary] -and -not $result.PSObject.Properties['PoolTestCycle']) {
        $result | Add-Member -NotePropertyName 'PoolTestCycle' -NotePropertyValue $script:LastOuterPoolTestCycle
    }
    return $result
}

function Get-LastOuterPullFailure {
    <#
    .SYNOPSIS
        Why the most recent framework pull in this process failed, redacted and
        one line long; '' when it did not fail.
    .DESCRIPTION
        Invoke-OuterGitPull reports only pass or fail, and the child process that
        runs the pull cannot hand the runner its console output. The text rides the
        cycle outcome record instead, so the recovery planner can tell a stale git
        lock from a network failure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return [string]$script:LastOuterPullFailure
}

function Publish-OuterRecoveryResult {
    <#
    .SYNOPSIS
        Builds the typed result of a dispatched cycle, records it, and returns it;
        $null when the outcome is not a verdict or the result cannot be built.
    .DESCRIPTION
        Recording how a cycle went must never change how the loop reacts to it, so
        every error here is swallowed after a verbose note.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]$Dispatch,
        [Parameter(Mandatory)][string]$CycleGeneration,
        [Parameter(Mandatory)][datetime]$SpawnedAtUtc
    )
    try {
        $result = ConvertTo-RunnerRecoveryResult -Dispatch $Dispatch -CycleGeneration $CycleGeneration -SpawnedAtUtc $SpawnedAtUtc
        if (-not $result) { return $null }
        if ($env:YURUNA_RUNTIME_DIR) { $null = Write-RecoveryResult -Result $result -RuntimeDir $env:YURUNA_RUNTIME_DIR -Confirm:$false }
        return $result
    } catch {
        Write-Verbose "Publish-OuterRecoveryResult: $($_.Exception.Message)"
        return $null
    }
}

function Write-OuterRecoveryApplied {
    <#
    .SYNOPSIS
        Tells the operator, on the console and in outer.log, that a repair ran in
        place of the failure pause.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][int]$Cycle,
        [Parameter(Mandatory)]$Recovery,
        [Parameter(Mandatory)]$Result
    )
    $line = Format-YurunaOperatorMessage -Key 'runner.recovery_applied' -Arguments @{
        cycle = "$Cycle"; action = "$($Recovery.Action)"; failClass = "$($Result['failureClass'])"; attempt = "$($Recovery.Attempt)"
    }
    Write-Output $line
    Write-OuterLog $line
}

function Set-OuterRecoveryDecision {
    <#
    .SYNOPSIS
        Records what a single repair decided on the cycle's result and persists the
        result again.
    .DESCRIPTION
        The pause shortcut runs inside the failure pause, after the result was
        first written, so its outcome has to be added to the file afterwards or the
        file would keep saying nothing was tried.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Annotates the in-memory result and republishes it inside the failure pause; a -WhatIf prompt there would stall the loop.')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)]$Decision
    )
    try {
        $Result['recovery'] = [ordered]@{
            state    = [string]$Decision.RecoveryState
            action   = [string]$Decision.Action
            attempt  = [int]$Decision.Attempt
            ledgerId = [string]$Decision.AttemptId
            advised  = [string[]]@()
        }
        if ($env:YURUNA_RUNTIME_DIR) { $null = Write-RecoveryResult -Result $Result -RuntimeDir $env:YURUNA_RUNTIME_DIR -LatestOnly -Confirm:$false }
    } catch {
        Write-Verbose "Set-OuterRecoveryDecision: $($_.Exception.Message)"
    }
}

function Invoke-OuterRecovery {
    <#
    .SYNOPSIS
        Plans the registered repairs for a result, runs them when automatic
        recovery is on, and records the decision on the result.
    .DESCRIPTION
        testCycle.autoRemediation.enabled (default off) gates every repair; with it
        off the decision is 'advised' and nothing is written to the ledger. The
        attempt budget is keyed by failure fingerprint and kept in the ledger, so a
        runner restart does not reset it. Never throws: a recovery problem leaves
        the loop on its ordinary path, the failure pause.
    .PARAMETER ExcludeAction
        Repairs to leave out of this planning round (the pause shortcut runs later,
        inside the pause).
    .OUTPUTS
        pscustomobject: RecoveryState, Action, Attempt, SkipFailurePause, Advised.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][hashtable]$State,
        [string[]]$ExcludeAction = @()
    )
    $none = [pscustomobject]@{ RecoveryState = 'none'; Action = ''; Attempt = 0; SkipFailurePause = $false; Advised = @() }
    if (-not $env:YURUNA_RUNTIME_DIR) { return $none }
    try {
        $auto = Get-OuterAutoRemediation -ConfigPath $State.ConfigPath -PoolTestCycleOverride (Get-OuterPoolPolicySnapshot -State $State)
        $context = @{
            Result     = $Result
            RepoRoot   = [string]$State.RepoRoot
            ProjectDir = (Join-Path ([string]$State.RepoRoot) 'project')
            ProjectUrl = (Get-OuterProjectUrl -ConfigPath $State.ConfigPath)
            ConfigPath = [string]$State.ConfigPath
            RuntimeDir = $env:YURUNA_RUNTIME_DIR
        }
        # With repair off nothing runs, so nothing needs leaving out: the advice names every
        # repair that would apply, whenever it would have run.
        $exclude = if ($auto.Enabled) { $ExcludeAction } else { @() }
        $decision = Invoke-RecoveryForResult -Result $Result -Context $context -RuntimeDir $env:YURUNA_RUNTIME_DIR `
            -Enabled ([bool]$auto.Enabled) -MaxAttempts ([int]$auto.MaxAttempts) -ExcludeAction $exclude
        $Result['recovery'] = [ordered]@{
            state    = [string]$decision.RecoveryState
            action   = [string]$decision.Action
            attempt  = [int]$decision.Attempt
            ledgerId = [string]$decision.AttemptId
            advised  = [string[]]@($decision.Advised)
        }
        $null = Write-RecoveryResult -Result $Result -RuntimeDir $env:YURUNA_RUNTIME_DIR -LatestOnly -Confirm:$false
        return [pscustomobject]@{
            RecoveryState    = [string]$decision.RecoveryState
            Action           = [string]$decision.Action
            Attempt          = [int]$decision.Attempt
            SkipFailurePause = [bool]$decision.SkipFailurePause
            Advised          = [string[]]@($decision.Advised)
        }
    } catch {
        Write-Verbose "Invoke-OuterRecovery: $($_.Exception.Message)"
        return $none
    }
}

# --- REGION: Pool-storage move mode (cycle-end archiving that can fail the cycle)
# Every function here is best-effort and Get-Command-guarded: a runner whose
# framework clone predates the archiving module, or a host with no pool storage
# configured, degrades to doing nothing rather than failing to run cycles.

function Import-OuterPoolStorageModuleSet {
    <#
    .SYNOPSIS
    Imports the module set the archiver needs into THIS process, returning $true when the orchestrator is callable afterwards.
    .DESCRIPTION
    The per-cycle process runs the Outer module set, which carries none of it: without
    the authentication extension in particular, the vault pre-check cannot resolve a
    credential and every archiving attempt would exit "vault credential not configured"
    -- silently, once per cycle, forever. Test.HostIdentity additionally re-enables the
    per-run hosts/info.<hostId>.yml refresh. Mirrors the import set of
    Invoke-PoolStorageDrain.ps1, which is what the detached copy-mode path uses.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    foreach ($m in @('Test.PoolStorage.psm1', 'Test.StateFile.psm1', 'Test.Config.psm1',
                     'Test.YurunaDir.psm1', 'Test.HostIdentity.psm1', 'Test.Log.psm1', 'Test.Extension.psm1')) {
        $p = Join-Path $PSScriptRoot $m
        if (Test-Path -LiteralPath $p) { Import-Module $p -Global -ErrorAction SilentlyContinue }
    }
    if (Get-Command Import-Extension -ErrorAction SilentlyContinue) {
        try { $null = Import-Extension -Area 'authentication' -RequireSingle } catch { $null = $_ }
    }
    return [bool](Get-Command Invoke-PoolStorageDrain -ErrorAction SilentlyContinue)
}

<#
.SYNOPSIS
$true when this host archives in MOVE mode (networkStorage.moveLogsToPoolStorage with the three pool paths set). Best-effort: any read failure answers $false, which is the safe direction -- nothing is deleted.
#>
function Get-OuterPoolStorageMoveMode {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$ConfigPath)
    try {
        if (-not (Get-Command Get-YurunaPoolStorageConfig -ErrorAction SilentlyContinue)) {
            if (-not (Import-OuterPoolStorageModuleSet)) { return $false }
        }
        if (-not (Get-Command Read-TestConfig -ErrorAction SilentlyContinue)) { return $false }
        $doc = Read-TestConfig -Path $ConfigPath -LastGoodOnError
        $cfg = Get-YurunaPoolStorageConfig -Config $doc -WarningAction SilentlyContinue
        return [bool]($cfg -and $cfg.MoveLogs)
    } catch {
        Write-Verbose "Get-OuterPoolStorageMoveMode: $($_.Exception.Message)"
        return $false
    }
}

<#
.SYNOPSIS
How long the move may wait for the detached push forwarder to finish reading the cycle folder. Reads the archiving module's constant when loaded, else the same default.
#>
function Get-OuterPoolStoragePushWait {
    [CmdletBinding()]
    [OutputType([int])]
    param()
    $m = Get-Module -Name 'Test.PoolStorage' -ErrorAction SilentlyContinue
    if ($m) {
        try {
            $v = & $m { $script:PoolStoragePushDrainWaitSeconds }
            if ($v -and [int]$v -gt 0) { return [int]$v }
        } catch { $null = $_ }
    }
    return 120
}

<#
.SYNOPSIS
Waits (bounded) for the detached push forwarder to EXIT. Returns $true when it exited within the budget, $false on timeout or when there is nothing to wait for.
.DESCRIPTION
Takes either a Process object (Windows Start-Process -PassThru) or a bare PID (the
POSIX nohup spawn echoes it). Waiting on the process rather than on the forwarder's
lock file is the whole point: the lock is taken well into the child's startup and
skipped entirely on its early-exit paths, so its absence proves nothing.
#>
function Wait-OuterPushForwarder {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()]$Process,
        [Parameter()][int]$ProcessId = 0,
        [Parameter()][int]$TimeoutSeconds = 120
    )
    $budgetMs = [math]::Max(1, $TimeoutSeconds) * 1000
    if ($Process) {
        try { return [bool]$Process.WaitForExit($budgetMs) } catch { Write-Verbose "Wait-OuterPushForwarder: $($_.Exception.Message)"; return $false }
    }
    if ($ProcessId -le 0) { return $false }
    $waitWatch = [Diagnostics.Stopwatch]::StartNew()
    while ($waitWatch.Elapsed.TotalMilliseconds -lt $budgetMs) {
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

<#
.SYNOPSIS
PRE-SPAWN gate: refuses to start a cycle when the pool share cannot hold the cycle it is about to produce. Returns @{ ok; message }. Move mode only; ok = $true for every other state.
.DESCRIPTION
Reads only -- it never mounts. An unmounted share is the unreachable-NAS case, not
the full-share case, so it is skipped: nothing is deleted while the share is away,
and the backlog simply waits. Mount presence is answered by Test-PoolStorageMountEntry
(the mount TABLE), not Test-YurunaPoolStorageMounted, which write-probes the share on
every call and would make a read-only gate perform I/O against a possibly wedged NAS
once per cycle.
#>
function Test-OuterPoolStorageSpaceReady {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ConfigPath
    )
    $ok = @{ ok = $true; message = '' }
    try {
        if (-not (Get-Command Get-YurunaPoolStorageConfig -ErrorAction SilentlyContinue)) {
            if (-not (Import-OuterPoolStorageModuleSet)) { return $ok }
        }
        if (-not (Get-Command Read-TestConfig -ErrorAction SilentlyContinue)) { return $ok }
        $cfg = Get-YurunaPoolStorageConfig -Config (Read-TestConfig -Path $ConfigPath -LastGoodOnError) -WarningAction SilentlyContinue
        if (-not $cfg -or -not $cfg.MoveLogs) { return $ok }
        if (-not (Get-Command Test-PoolStorageMountEntry -ErrorAction SilentlyContinue)) { return $ok }
        if (-not (Test-PoolStorageMountEntry -Config $cfg)) {
            Write-Verbose "pre-spawn storage check: '$($cfg.LocalPath)' is not mounted; skipping (offline NAS is not a full NAS)."
            return $ok
        }
        $free = Get-PoolStorageFreeSpace -Config $cfg
        if ($free -lt 0) { return $ok }
        $ledger = $null
        if ((Get-Command Read-PoolStorageLedger -ErrorAction SilentlyContinue) -and $env:YURUNA_RUNTIME_DIR) {
            try { $ledger = Read-PoolStorageLedger -RuntimeDir $env:YURUNA_RUNTIME_DIR } catch { $null = $_ }
        }
        $projected = Get-PoolStorageProjectedSize -Ledger $ledger
        $verdict = Test-PoolStorageSpaceSufficient -FreeBytes $free -NeedBytes $projected
        if ($verdict.ok) {
            # Room again: re-arm the notification so the NEXT time the share fills the
            # operator hears about it instead of the latch swallowing it.
            $null = Clear-PoolStorageSpaceNotification -Confirm:$false
            return $ok
        }
        $msg = "pool storage is full: '$($cfg.LocalPath)/hosts/' has $(Format-PoolStorageSize -Bytes $free) free but the next cycle needs $(Format-PoolStorageSize -Bytes ([long]$verdict.required)) (a $(Format-PoolStorageSize -Bytes ([long]$verdict.reserve)) reserve plus $(Format-PoolStorageSize -Bytes $projected) projected from recent cycles). No cycle will start until old cycle archives are deleted from the share."
        return @{ ok = $false; message = $msg }
    } catch {
        Write-Verbose "Test-OuterPoolStorageSpaceReady: $($_.Exception.Message)"
        return $ok
    }
}

<#
.SYNOPSIS
Runs the SYNCHRONOUS move at cycle end: archive every finished cycle folder, verify it, then delete the local copy. Returns the archiver's summary hashtable (or $null when it did not run). Never throws.
.DESCRIPTION
Bounded by the archiving module's move-phase cap: the loop is blocked while this
runs, which is the price of a verdict that depends on the copy. Exceeding the cap
leaves every not-yet-moved folder local and reports a warning -- a slow NAS is not a
full NAS, and only the full-NAS verdict is allowed to fail a cycle.
#>
function Invoke-OuterPoolStorageMove {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][int]$Cycle = 0
    )
    try {
        if (-not (Import-OuterPoolStorageModuleSet)) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_c75314523fa23a21' -Arguments @{ cycle = "$Cycle" })
            return $null
        }
        $hid = ''
        if (Get-Command Get-YurunaHostId -ErrorAction SilentlyContinue) {
            try { $hid = [string](Get-YurunaHostId) } catch { $null = $_ }
        }
        if ([string]::IsNullOrWhiteSpace($hid)) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_bf539349ab9e3a84' -Arguments @{ cycle = "$Cycle" })
            return $null
        }
        $started = Get-OuterMonotonicTime
        $summary = Invoke-PoolStorageDrain -HostId $hid -LogDir $env:YURUNA_LOG_DIR -RuntimeDir $env:YURUNA_RUNTIME_DIR `
            -MoveLogs -SpaceCheck -Confirm:$false
        $elapsed = [int]((Get-OuterMonotonicTime) - $started)
        if (-not $summary) { return $null }
        if ($summary.lockBusy) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_7a3882ba7f42809e' -Arguments @{ cycle = "$Cycle" })
            return $null
        }
        $line = "[outer cycle $Cycle] poolStorage move: moved=$($summary.moved) deleted=$($summary.deleted) pending=$($summary.pending) spaceShort=$($summary.spaceShort) in ${elapsed}s"
        Write-Information $line -InformationAction Continue
        Write-OuterLog $line
        if ($summary.error -and -not $summary.spaceShort) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_7bd332a2612f01a9' -Arguments @{ cycle = "$Cycle"; error = "$($summary.error)" })
        }
        return $summary
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_1ca511b6e23b3f3a' -Arguments @{ cycle = "$Cycle"; message = "$($_.Exception.Message)" })
        return $null
    }
}

<#
.SYNOPSIS
Persists a schema-v2 last_failure.json describing a full pool share, so the failure pause classifies on 'pool_storage_full' rather than on a stale record. Writes only when no richer record exists (a cycle that already failed keeps its own).
#>
function Write-PoolStorageSpaceFailureRecord {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter()][string]$Stage = 'PoolStorageMove',
        [Parameter()][int]$Cycle = 0,
        [switch]$Force
    )
    if (-not $env:YURUNA_LOG_DIR) { return $false }
    $path = Join-Path $env:YURUNA_LOG_DIR 'last_failure.json'
    if ((-not $Force) -and (Test-Path -LiteralPath $path)) { return $false }
    if (-not $PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.operator_8b7604c0ecddcc5b'))) { return $false }
    # New-InfraFailureRecord builds the canonical schema-v2 shape but persists
    # nothing, and its module is not in the Outer set -- import it best-effort and
    # fall back to the same shape inline (the watchdog synth above does likewise) so
    # a missing module cannot leave the pause with nothing to classify.
    $record = $null
    if (-not (Get-Command New-InfraFailureRecord -ErrorAction SilentlyContinue)) {
        $sfs = Join-Path $PSScriptRoot 'Test.SequenceFailureState.psm1'
        if (Test-Path -LiteralPath $sfs) { Import-Module $sfs -Global -ErrorAction SilentlyContinue }
    }
    if (Get-Command New-InfraFailureRecord -ErrorAction SilentlyContinue) {
        try {
            $built = New-InfraFailureRecord -Stage $Stage -FailureClass 'pool_storage_full' -Severity 'hard' -ErrorMessage $Message
            if ($built -and $built.File) { $record = $built.File }
        } catch { Write-Verbose "New-InfraFailureRecord: $($_.Exception.Message)" }
    }
    if (-not $record) {
        $record = [ordered]@{
            schemaVersion        = 2
            reason               = 'infra'
            stepNumber           = 0
            totalSteps           = 0
            action               = $Stage
            description          = $Message
            vmName               = ''
            guestKey             = ''
            timestamp            = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
            failureClass         = 'pool_storage_full'
            severity             = 'hard'
            suggestedRecoveries  = @()
            actionVerb           = $Stage
            classificationSource = 'infra-stage'
            sequenceName         = ''
            context              = [ordered]@{ hostType = ''; stage = $Stage; cycle = $Cycle }
        }
    }
    if (Get-Command Write-YurunaStateFileJson -ErrorAction SilentlyContinue) {
        return [bool](Write-YurunaStateFileJson -Path $path -InputObject $record -Depth 6 -Confirm:$false)
    }
    try {
        [System.IO.File]::WriteAllText($path, ($record | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
        return $true
    } catch {
        Write-Verbose "Write-PoolStorageSpaceFailureRecord: $($_.Exception.Message)"
        return $false
    }
}

function Send-OuterCycleFailureNotification {
    <#
    .SYNOPSIS
        Load the optional notification transport and send prepared failure data.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$SubjectSuffix, [string]$GuestKey, [string]$StepName, [string]$ErrorMessage,
        [Parameter(Mandatory)]$EventData)
    if (-not (Get-Command Send-CycleFailureNotification -ErrorAction SilentlyContinue)) {
        $module = Join-Path $PSScriptRoot 'Test.Notify.psm1'
        if (Test-Path -LiteralPath $module) { Import-Module $module -Global -ErrorAction SilentlyContinue -Verbose:$false }
    }
    if (-not (Get-Command Send-CycleFailureNotification -ErrorAction SilentlyContinue)) { return $false }
    $hostType = ''
    if (Get-Command Get-HostType -ErrorAction SilentlyContinue) {
        try { $hostType = [string](Get-HostType) } catch { Write-Verbose $_.Exception.Message }
    }
    Send-CycleFailureNotification -HostType $hostType -SubjectSuffix $SubjectSuffix -GuestKey $GuestKey `
        -StepName $StepName -ErrorMessage $ErrorMessage -EventData $EventData -ErrorAction SilentlyContinue | Out-Null
    return $true
}

function Send-PoolStorageSpaceNotification {
    <#
    .SYNOPSIS
        Latches and sends the storage-space alert for the current failure streak.
    .DESCRIPTION
        The pre-spawn refusal repeats hourly while the share stays full. A
        runtime latch limits identical mail to once per failure streak and
        clears after the next run that finds room.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter()][int]$Cycle = 0
    )
    if (-not $env:YURUNA_RUNTIME_DIR) { return $false }
    $flag = Join-Path $env:YURUNA_RUNTIME_DIR 'poolstorage.space-fail.notified'
    if (Test-Path -LiteralPath $flag) { return $false }
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'runner.operator_411c032a04bd8374'), (Format-YurunaOperatorMessage -Key 'runner.operator_efa1393b4f3400c8'))) { return $false }
    # Latch FIRST. The flag means "this streak has been reported", not "a mail was
    # delivered": a host with no transport configured -- or one whose transport is
    # briefly down -- would otherwise never write it and would re-attempt on every
    # hourly refusal, which is the flood this gate exists to prevent.
    try { [System.IO.File]::WriteAllText($flag, (Get-Date).ToUniversalTime().ToString('o')) } catch { Write-Verbose "space-fail latch: $($_.Exception.Message)" }
    try {
        # EventData is passed PRE-BUILT: the helper's own fallback builder reads
            # last_failure.json out of the cycle folder, which this process does not
            # have, and would ship failureClass 'unknown' for a failure whose whole
            # point is its class.
            $eventData = [ordered]@{
                failureClass = 'pool_storage_full'
                severity     = 'hard'
                reason       = 'infra'
                action       = 'PoolStorageMove'
                description  = $Message
                cycle        = $Cycle
            }
            Send-OuterCycleFailureNotification -SubjectSuffix (Format-YurunaOperatorMessage -Key 'runner.operator_127885b6f7dcb1b0') `
                -GuestKey '(poolStorage)' -StepName (Format-YurunaOperatorMessage -Key 'runner.operator_e25bada6bbd913eb') -ErrorMessage $Message `
                -EventData $eventData | Out-Null
        return $true
    } catch {
        Write-Verbose "Send-PoolStorageSpaceNotification: $($_.Exception.Message)"
        return $false
    }
}

<#
.SYNOPSIS
Clears the space-failure notification latch so the next full share re-alerts.
#>
function Clear-PoolStorageSpaceNotification {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $env:YURUNA_RUNTIME_DIR) { return $false }
    $flag = Join-Path $env:YURUNA_RUNTIME_DIR 'poolstorage.space-fail.notified'
    if (-not (Test-Path -LiteralPath $flag)) { return $false }
    if (-not $PSCmdlet.ShouldProcess($flag, (Format-YurunaOperatorMessage -Key 'runner.operator_6751fc93a0d313b1'))) { return $false }
    Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    return $true
}

<#
.SYNOPSIS
Reports a post-cycle space failure: console, outer log, failure record (only when the inner left none), and a streak-gated notification.
#>
function Write-PoolStorageSpaceFailure {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]$Move,
        [Parameter()][int]$Cycle = 0,
        [Parameter()][int]$InnerExitCode = 0
    )
    $msg = [string]$Move.error
    if ([string]::IsNullOrWhiteSpace($msg)) { $msg = 'pool storage is full; this cycle could not be archived.' }
    $full = "$msg Cycle results were NOT archived and were NOT deleted locally. Delete old cycle archives under the share's hosts/ folder to continue."
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_c56ccc7c3a01b8f3' -Arguments @{ cycle = "$Cycle"; full = "$full" })
    Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_218ebb2c80a76597' -Arguments @{ cycle = "$Cycle"; full = "$full" })
    # Only when the inner passed. A cycle that already failed wrote its own, richer
    # record; replacing it would trade a real diagnosis for a storage message.
    if ($InnerExitCode -eq 0) {
        $null = Write-PoolStorageSpaceFailureRecord -Message $full -Stage 'PoolStorageMove' -Cycle $Cycle -Confirm:$false
    }
    $null = Send-PoolStorageSpaceNotification -Message $full -Cycle $Cycle -Confirm:$false
}

function Initialize-RunnerStateWriter {
<#
.SYNOPSIS
Make Write-YurunaStateFileJson resolvable before a fault-path state write.
.DESCRIPTION
The fault path can run in an outer process that loaded only this module -- a
harness importing it directly, or an outer started without the pool-storage
module set. The writes it performs are the only record that a killed cycle
happened at all, so they import their writer rather than quietly degrade to
writing nothing.
.OUTPUTS
[bool] whether the writer is available.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (Get-Command Write-YurunaStateFileJson -ErrorAction SilentlyContinue) { return $true }
    $stateModule = Join-Path $PSScriptRoot 'Test.StateFile.psm1'
    if (Test-Path -LiteralPath $stateModule) { Import-Module $stateModule -Global -ErrorAction SilentlyContinue }
    return [bool](Get-Command Write-YurunaStateFileJson -ErrorAction SilentlyContinue)
}

# --- REGION: Runner attempt evidence
function Read-RunnerAttemptEvidence {
    <#
    .SYNOPSIS
        Read evidence only when it belongs to the currently spawned attempt.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$AttemptGeneration = '',
        [datetime]$SpawnedAtUtc = [datetime]::MinValue
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $record = Get-Content -Raw -LiteralPath $Path -ErrorAction Stop | ConvertFrom-Json -AsHashtable
        if ($record -isnot [System.Collections.IDictionary]) { return $null }
        if ($AttemptGeneration -and [string]$record['attemptGeneration'] -cne $AttemptGeneration) { return $null }
        $stamp = if ($record['timestamp']) { $record['timestamp'] } elseif ($record['finishedAtUtc']) { $record['finishedAtUtc'] } else { $record['startedAtUtc'] }
        $started = if ($stamp -is [datetime]) { ([datetime]$stamp).ToUniversalTime() }
            else { [datetime]::Parse([string]$stamp, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }
        if ($started -lt $SpawnedAtUtc.ToUniversalTime()) { return $null }
        return $record
    } catch { return $null }
}

function Test-RunnerAttemptCycleStarted {
    <#
    .SYNOPSIS
        Whether the current attempt has published a cycle document.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [string]$AttemptGeneration = '',
        [datetime]$SpawnedAtUtc = [datetime]::MinValue
    )
    try {
        $doc = Get-Content -Raw -LiteralPath (Join-Path $RuntimeDir 'status.json') -ErrorAction Stop | ConvertFrom-Json -AsHashtable
        if (-not $doc['cycleStartUtc']) { return $false }
        if ($AttemptGeneration -and $doc['cycleGeneration']) { return [string]$doc['cycleGeneration'] -ceq $AttemptGeneration }
        if ($SpawnedAtUtc -eq [datetime]::MinValue) { return $false }
        return ([datetime]$doc['cycleStartUtc']).ToUniversalTime() -ge $SpawnedAtUtc.ToUniversalTime()
    } catch { return $false }
}

function Get-RunnerAttemptFault {
    <#
    .SYNOPSIS
        Distinguish a gate refusal, a proven watchdog stop and an ordinary exit.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [string]$AttemptGeneration = '',
        [datetime]$SpawnedAtUtc = [datetime]::MinValue,
        [int]$ExitCode = -1
    )
    $readArgs = @{ AttemptGeneration = $AttemptGeneration; SpawnedAtUtc = $SpawnedAtUtc }
    $kill = Read-RunnerAttemptEvidence -Path (Join-Path $RuntimeDir 'runner.watchdog-kill.json') @readArgs
    if ($kill) {
        $kill['recordPath'] = 'runner.watchdog-kill.json'
        return @{ FailureClass = [string]$kill.failureClass; StalledPhase = [string]$kill.phase; IsCrash = $true; Evidence = $kill }
    }
    $gate = Read-RunnerAttemptEvidence -Path (Join-Path $RuntimeDir 'runner.configGate.json') @readArgs
    if ($gate -and -not $gate.passed) {
        return @{ FailureClass = 'config_gate_failed'; StalledPhase = ''; IsCrash = $false; Evidence = $gate }
    }
    if ($ExitCode -eq (Get-ConfigGateFailureExitCode) -and (Get-RunnerStalledPreamblePhase -RuntimeDir $RuntimeDir) -eq 'config-gate' -and
        -not (Test-RunnerAttemptCycleStarted -RuntimeDir $RuntimeDir @readArgs)) {
        return @{ FailureClass = 'config_gate_failed'; StalledPhase = ''; IsCrash = $false; Evidence = $null }
    }
    return @{ FailureClass = 'inner_exited'; StalledPhase = ''; IsCrash = $true; Evidence = $null }
}

<#
.SYNOPSIS
Names the preamble phase an inner process died in, or '' when it got past the preamble.
.DESCRIPTION
runner.phase exists only between the inner's first Write-RunnerPhase and the
Clear-RunnerPhase that hands off to the sequence, so its presence after the
inner is gone says the inner never reached its first step, and its content
names the last phase it announced. That is the whole discriminator between a
cycle that ran and failed and a cycle that never started.
#>
function Get-RunnerStalledPreamblePhase {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RuntimeDir)
    $phaseFile = Join-Path $RuntimeDir 'runner.phase'
    if (-not (Test-Path -LiteralPath $phaseFile)) { return '' }
    try { return ([string](Get-Content -Raw -LiteralPath $phaseFile -ErrorAction Stop)).Trim() }
    catch { return '' }
}

<#
.SYNOPSIS
Advances the notification-gating counters on behalf of an inner that was killed before it could save them.
.DESCRIPTION
The gating counters live in runner.gating.json and are normally owned by the
inner, which rewrites them in its post-loop cleanup. That cleanup does not run
when the inner is killed rather than exited -- which is exactly what the
step-heartbeat watchdog does to a stalled one. The counters then stay frozen at
their last clean value, so the failure mode that kills the inner is the one
failure mode that can never advance a crash count, trip failuresBeforeAlert, or
disarm the notification gate. A host can repeat it indefinitely and stay silent.

This closes that hole from the outer, which is still alive after the kill. It
writes ONLY when the inner did not: the file's savedAt is compared against the
moment the inner was spawned, so a cycle that saved its own accounting keeps it
and nothing is double-counted.

The notification is sent from here for the same reason the counters are written
from here -- the process that would normally send it is gone.
#>
function Update-RunnerCrashGating {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][datetime]$SpawnedAtUtc,
        [Parameter()][AllowNull()]$Config,
        [Parameter()][int]$Cycle = 0,
        [Parameter()][int]$ExitCode = 0,
        [Parameter()][string]$StalledPhase = '',
        [Parameter()][int]$StallStreak = 0,
        [Parameter()][string]$FailureClass = '',
        [Parameter()][bool]$IsCrash = $true,
        [Parameter()][AllowEmptyString()][string]$Description = ''
    )
    $result = @{ Updated = $false; ConsecutiveCrashes = 0; ConsecutiveFailures = 0; Alerted = $false }
    $gatingFile = Join-Path $RuntimeDir 'runner.gating.json'
    $state = @{ consecutiveFailures = 0; consecutiveSuccesses = 0; consecutiveCrashes = 0; alertArmed = $true }
    if (Test-Path -LiteralPath $gatingFile) {
        try {
            $parsed = Get-Content -Raw -LiteralPath $gatingFile -ErrorAction Stop | ConvertFrom-Json
            if ($null -ne $parsed.consecutiveFailures)  { $state.consecutiveFailures  = [int]$parsed.consecutiveFailures }
            if ($null -ne $parsed.consecutiveSuccesses) { $state.consecutiveSuccesses = [int]$parsed.consecutiveSuccesses }
            if ($null -ne $parsed.consecutiveCrashes)   { $state.consecutiveCrashes   = [int]$parsed.consecutiveCrashes }
            if ($null -ne $parsed.alertArmed)           { $state.alertArmed           = [bool]$parsed.alertArmed }
            # An inner that saved after it was spawned did its own accounting.
            # Adding to it here would count one failed cycle twice and reach the
            # alert threshold in half the failures the operator configured.
            if ($parsed.savedAt) {
                $savedAt = [datetime]::MinValue
                $hasSavedAt = if ($parsed.savedAt -is [datetime]) {
                    $savedAt = ([datetime]$parsed.savedAt).ToUniversalTime()
                    $true
                } else {
                    [datetime]::TryParse([string]$parsed.savedAt, [cultureinfo]::InvariantCulture,
                        ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal), [ref]$savedAt)
                }
                if ($hasSavedAt -and $savedAt -ge $SpawnedAtUtc) { return $result }
            }
        } catch {
            Write-Verbose "Update-RunnerCrashGating: could not parse $gatingFile ($($_.Exception.Message)); treating the counters as unset."
        }
    }
    if (-not $PSCmdlet.ShouldProcess($gatingFile, (Format-YurunaOperatorMessage -Key 'runner.operator_b4a782ed37d78e1d'))) { return $result }

    if ($IsCrash) { $state.consecutiveCrashes++ } else { $state.consecutiveCrashes = 0 }
    $state.consecutiveFailures++
    $state.consecutiveSuccesses = 0
    # Reached through a try rather than a null-coalescing chain: this runs with
    # whatever config the caller could parse, including none, and a property
    # walk over an absent block is a terminating error the moment anything in
    # the call stack asks for strict mode.
    $failuresBeforeAlert = 1
    try {
        if ($Config -and $Config.notification -and $Config.notification.failuresBeforeAlert) {
            $failuresBeforeAlert = [int]$Config.notification.failuresBeforeAlert
        }
    } catch { Write-Verbose "Update-RunnerCrashGating: notification.failuresBeforeAlert unreadable; alerting on the first crash." }
    if ($failuresBeforeAlert -lt 1) { $failuresBeforeAlert = 1 }
    $shouldAlert = ($state.alertArmed -and $state.consecutiveFailures -ge $failuresBeforeAlert)
    if ($shouldAlert) { $state.alertArmed = $false }

    $null = Initialize-RunnerStateWriter
    try {
        $null = Write-YurunaStateFileJson -Path $gatingFile -Depth 4 -Compress:$false -WithBom -Confirm:$false -InputObject @{
            consecutiveFailures  = $state.consecutiveFailures
            consecutiveSuccesses = $state.consecutiveSuccesses
            consecutiveCrashes   = $state.consecutiveCrashes
            alertArmed           = $state.alertArmed
            savedAt              = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        }
        $result.Updated = $true
    } catch {
        Write-Verbose "Update-RunnerCrashGating: gating save failed (best-effort): $($_.Exception.Message)"
    }
    $result.ConsecutiveCrashes  = $state.consecutiveCrashes
    $result.ConsecutiveFailures = $state.consecutiveFailures

    if ($shouldAlert) {
        $where = if ($StalledPhase) { "never reached its first test step -- it stalled in preamble phase '$StalledPhase'" } else { 'was killed before it could report a verdict' }
        $streakNote = if ($StallStreak -gt 1) { " This is the ${StallStreak}th consecutive cycle to stall in the same phase, so it is a standing condition on this host rather than a passing one." } else { '' }
        $message = if ($Description) {
            $Description
        } elseif ($FailureClass -eq 'config_gate_failed') {
            Format-YurunaOperatorMessage -Key 'runner.config_gate_attempt_failed' -Arguments @{ exitCode = "$ExitCode" }
        } elseif (-not $StalledPhase -and $FailureClass -in @('', 'inner_exited')) {
            Format-YurunaOperatorMessage -Key 'runner.inner_attempt_exited' -Arguments @{ exitCode = "$ExitCode" }
        } else {
            Format-YurunaOperatorMessage -Key 'runner.operator_62f77591834076f9' -Arguments @{ exitCode = "$ExitCode"; where = "$where"; streakNote = "$streakNote" }
        }
        try {
            # Built here rather than left to the helper's fallback, which
                # recovers its fields from the cycle folder's failure record --
                # a cycle killed in the preamble never created one.
                $eventData = [ordered]@{
                    failureClass = if ($FailureClass) { $FailureClass } elseif ($StalledPhase) { 'preamble_stall' } else { 'inner_exited' }
                    severity     = 'hard'
                    reason       = 'infra'
                    action       = if ($FailureClass -eq 'config_gate_failed') { 'config-gate' } elseif ($StalledPhase) { "preamble:$StalledPhase" } elseif ($FailureClass -eq 'wait_timeout') { 'inner-killed' } else { 'inner-exited' }
                    description  = $message
                    cycle        = $Cycle
                }
            $sent = Send-OuterCycleFailureNotification -SubjectSuffix (Format-YurunaOperatorMessage -Key 'runner.outer_attempt_failed') `
                    -GuestKey '(preamble)' -StepName $(if ($StalledPhase) { $StalledPhase } else { (Format-YurunaOperatorMessage -Key 'runner.operator_8c401a9e37de2b10') }) `
                    -ErrorMessage $message -EventData $eventData
            $result.Alerted = [bool]$sent
        } catch {
            Write-Verbose "Update-RunnerCrashGating: notification failed (best-effort): $($_.Exception.Message)"
        }
    }
    return $result
}

<#
.SYNOPSIS
Make New-CycleHistoryEntry resolvable before a fault-path history write.
.DESCRIPTION
Same reasoning as Initialize-RunnerStateWriter: the outer process may have
loaded only this module, and the history row a killed cycle gets from the
fault path is the only record of that cycle a reader will ever find --
Complete-Run, which writes every other row, is precisely the code a killed
inner never reaches.
.OUTPUTS
[bool] whether the history-row builder is available.
#>
function Initialize-RunnerHistoryWriter {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (Get-Command New-CycleHistoryEntry -ErrorAction SilentlyContinue) { return $true }
    $statusModule = Join-Path $PSScriptRoot 'Test.Status.psm1'
    if (Test-Path -LiteralPath $statusModule) { Import-Module $statusModule -Global -ErrorAction SilentlyContinue }
    return [bool](Get-Command New-CycleHistoryEntry -ErrorAction SilentlyContinue)
}

<#
.SYNOPSIS
Classifies a cycle the outer runner ended, preferring the watchdog's own on-disk record.
.DESCRIPTION
An inner that was killed never runs the code that classifies a failure, so
status.json's lastFailure stays null and every consumer that switches on
failureClass reads 'unknown' -- including the pool dashboard's failure-class
breakdown, where a killed cycle is exactly the kind an operator most wants
named.

The watchdog already writes a schema-v2 record for the kill it performed.
That record is preferred here so a single event cannot end up carrying two
different class names depending on which reader looks. The synthesized
fallback covers the states that leave no record -- a failure pause entered
behind an inner that exited on its own -- and reuses the two classes the
crash-gating notification already uses for those same conditions.
.PARAMETER FailureRecordPath
Path to the cycle's last_failure.json. Ignored when absent or unparseable.
.PARAMETER Reason
The fault path's own description, used when no record supplies one.
.PARAMETER StalledPhase
Preamble phase the inner stalled in, or '' when it got past the preamble.
.PARAMETER FailureClass
The class the fault path itself names for a cycle it ended without a better
record -- for example a cycle whose outcome nothing recorded. The watchdog's
own record, when present, still wins; '' keeps the stalled-phase and
killed-cycle defaults.
.OUTPUTS
[System.Collections.Specialized.OrderedDictionary] shaped like the lastFailure
that Set-LastFailureSummary writes, so both reach consumers identically.
#>
function Get-RunnerFaultCause {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter()][AllowEmptyString()][string]$FailureRecordPath = '',
        [Parameter()][AllowEmptyString()][string]$Reason = '',
        [Parameter()][AllowEmptyString()][string]$StalledPhase = '',
        [Parameter()][AllowEmptyString()][string]$FailureClass = ''
    )
    $record = $null
    if ($FailureRecordPath -and (Test-Path -LiteralPath $FailureRecordPath -PathType Leaf)) {
        try {
            $record = Get-Content -Raw -LiteralPath $FailureRecordPath -ErrorAction Stop | ConvertFrom-Json -AsHashtable
        } catch {
            Write-Verbose "Get-RunnerFaultCause: could not parse $FailureRecordPath ($($_.Exception.Message))."
        }
    }
    if ($record -isnot [System.Collections.IDictionary]) { $record = $null }

    return [ordered]@{
        failureClass = if ($record -and $record['failureClass']) { [string]$record['failureClass'] }
                       elseif ($FailureClass) { $FailureClass }
                       elseif ($StalledPhase) { 'preamble_stall' }
                       else { 'inner_exited' }
        severity     = if ($record -and $record['severity']) { [string]$record['severity'] } else { 'hard' }
        stepNumber   = if ($record -and $record['stepNumber']) { [int]$record['stepNumber'] } else { 0 }
        sequenceName = if ($record -and $record['sequenceName']) { [string]$record['sequenceName'] } else { '' }
        guestKey     = if ($record -and $record['guestKey']) { [string]$record['guestKey'] } else { '' }
        # The kill destroyed the runspace holding the step location, so the
        # stalled phase is the most specific thing nameable here.
        stepName     = if ($StalledPhase) { $StalledPhase }
                       elseif ($record -and $record['action']) { [string]$record['action'] }
                       elseif ($FailureClass -eq 'config_gate_failed') { 'config-gate' }
                       else { 'runner' }
        errorMessage = if ($record -and $record['description']) { [string]$record['description'] }
                       elseif ($Reason) { $Reason }
                       else { '' }
        reproCommand = ''
        relPath      = ''
        vmName       = if ($record -and $record['vmName']) { [string]$record['vmName'] } else { '' }
        recordedAt   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
}

# --- REGION: Runner fault status
function Test-OuterCycleSkippedGuest {
    <#
    .SYNOPSIS
        $true when the cycle that just ended skipped a guest it planned, as the
        status.json it wrote records (a quarantined guest is marked skipped).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$RuntimeDir)
    try {
        $doc = Get-Content -Raw -LiteralPath (Join-Path $RuntimeDir 'status.json') -ErrorAction Stop | ConvertFrom-Json -AsHashtable
        foreach ($guest in @($doc['guests'])) {
            if ($guest -is [System.Collections.IDictionary] -and [string]$guest['status'] -ceq 'skipped') { return $true }
        }
    } catch { Write-Verbose "Test-OuterCycleSkippedGuest: status.json unreadable: $($_.Exception.Message)" }
    return $false
}

function Get-OuterPoolPolicySnapshot {
    <#
    .SYNOPSIS
        The pool's testCycle override the last cycle recorded, or an empty map.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$State)
    $snapshot = $State['PoolTestCycleOverride']
    if (-not ($snapshot -is [System.Collections.IDictionary])) { return @{} }
    $map = @{}
    foreach ($key in $snapshot.Keys) { $map[[string]$key] = $snapshot[$key] }
    return $map
}

function Get-OuterRetryHoldSeconds {
    <#
    .SYNOPSIS
        How long to hold before retrying after a run of attempts that produced
        no verdict: the base hold, doubled for each attempt after the first, to
        at most 15 minutes.
    .DESCRIPTION
        A framework that cannot be pulled, a cycle process that cannot start and
        a cycle that aborts early all repeat until something changes; a fixed
        30 s hold retried them all day.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural is the unit, not a collection: a time value is named <Name>Seconds so a bare number cannot be read in the wrong unit.')]
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][int]$BaseSeconds, [Parameter(Mandatory)][int]$Streak)
    $doublings = [math]::Min(16, [math]::Max(0, $Streak - 1))
    return [int][math]::Min(900, [math]::Max(1, $BaseSeconds) * [math]::Pow(2, $doublings))
}

function Get-OuterEarlyEndHoldSeconds {
    <#
    .SYNOPSIS
        How long a failure pause runs before an unattended retry may end it.
    .DESCRIPTION
        retry_with_backoff is a real backoff: each early end the recovery ledger
        already holds for this failure doubles the hold, from one poll interval
        to at most 15 minutes (the doubling of Get-OuterRetryHoldSeconds). A pass
        re-arms it together with the attempt budget, because the ledger counts
        only the attempts after the last pass.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural is the unit, not a collection: a time value is named <Name>Seconds so a bare number cannot be read in the wrong unit.')]
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][int]$PollSeconds,
        [AllowNull()][AllowEmptyString()][string]$RuntimeDir,
        [AllowNull()][AllowEmptyString()][string]$Fingerprint
    )
    if (-not $RuntimeDir -or -not $Fingerprint) { return [math]::Max(1, $PollSeconds) }
    $prior = Get-RecoveryAttemptState -RuntimeDir $RuntimeDir -Fingerprint $Fingerprint -Action 'end_failure_pause_early' -MaxAttempts 1000
    return (Get-OuterRetryHoldSeconds -BaseSeconds $PollSeconds -Streak (1 + [int]$prior.Used))
}

function Get-OuterMonotonicTime {
    <#
    .SYNOPSIS
        Seconds on a monotonic clock, for measuring pauses and holds.
    .DESCRIPTION
        Get-Date moves when the clock is corrected and, in local time, by an
        hour at each daylight-saving change; the performance counter moves
        with elapsed time alone. Only differences between two readings mean
        anything. Tests replace it to drive a pause without waiting.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param()
    return [Diagnostics.Stopwatch]::GetTimestamp() / [double][Diagnostics.Stopwatch]::Frequency
}

function Update-RunnerFaultStatus {
    <#
    .SYNOPSIS
        Publish the current attempt's fault separately from completed cycle results.
    .DESCRIPTION
        Only an incomplete cycle started by this attempt receives a failed verdict
        and a synthesized history row. Prior completed results retain their meaning.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][string]$RunnerState,
        [Parameter()][string]$Reason = '',
        [Parameter()][string]$StalledPhase = '',
        [Parameter()][AllowEmptyString()][string]$FailureClass = '',
        [Parameter()][AllowEmptyString()][string]$FailureRecordPath = '',
        [Parameter()][int]$MaxHistoryRuns = 30,
        [Parameter()][string]$AttemptGeneration = '',
        [Parameter()][datetime]$SpawnedAtUtc = [datetime]::MinValue,
        [Parameter()][string]$FrameworkCommitSha = '',
        [Parameter()][int]$ExitCode = 1,
        [Parameter()][AllowNull()][hashtable]$AttemptEvidence = $null
    )
    $statusFile = Join-Path $RuntimeDir 'status.json'
    if (-not $PSCmdlet.ShouldProcess($statusFile, (Format-YurunaOperatorMessage -Key 'runner.operator_83c012a12dddac6a' -Arguments @{ runnerState = "$RunnerState" }))) { return $false }
    try {
        $doc = if (Test-Path -LiteralPath $statusFile -PathType Leaf) {
            Get-Content -Raw -LiteralPath $statusFile -ErrorAction Stop | ConvertFrom-Json -AsHashtable
        } else {
            @{ schemaVersion = 1; overallStatus = 'unknown'; guests = @(); gitCommits = @(); history = @(); lastFailure = $null }
        }
    } catch {
        Write-Verbose "Update-RunnerFaultStatus: could not parse $statusFile ($($_.Exception.Message))."
        return $false
    }
    if ($doc -isnot [System.Collections.IDictionary]) { return $false }
    # An attempt can fail before the cycle document publishes identity. Read the
    # already persisted host UUID so pool discovery can observe that fault too.
    if (-not $doc['hostId'] -and (Test-Path -LiteralPath (Join-Path $RuntimeDir 'host.uuid') -PathType Leaf)) {
        try {
            if (-not (Get-Command Get-YurunaHostId -ErrorAction SilentlyContinue)) {
                Import-Module (Join-Path $PSScriptRoot 'Test.YurunaDir.psm1') -DisableNameChecking -ErrorAction Stop
            }
            $persistedHostId = Get-YurunaHostId -RuntimeDir $RuntimeDir
            if ($persistedHostId) { $doc['hostId'] = [string]$persistedHostId }
        } catch { Write-Verbose "Fault status host identity unavailable: $($_.Exception.Message)" }
    }
    $doc['runnerState']          = $RunnerState
    $doc['runnerStateReason']    = $Reason
    $doc['runnerStateSinceUtc']  = (Get-Date).ToUniversalTime().ToString('o')
    $doc['runnerStalledPhase']   = $StalledPhase
    if ($RunnerState -in @('fault', 'paused')) {
        $currentCycle = $doc['overallStatus'] -eq 'running'
        if ($currentCycle -and $AttemptGeneration -and $doc['cycleGeneration']) {
            $currentCycle = [string]$doc['cycleGeneration'] -ceq $AttemptGeneration
        } elseif ($currentCycle -and $SpawnedAtUtc -ne [datetime]::MinValue) {
            try {
                $cycleStarted = ([datetime]$doc['cycleStartUtc']).ToUniversalTime()
                $currentCycle = $cycleStarted -ge $SpawnedAtUtc.ToUniversalTime()
            } catch { $currentCycle = $false }
        }
        $recordPath = $FailureRecordPath
        if (-not $recordPath -and $currentCycle -and $env:YURUNA_LOG_DIR) {
            $recordPath = Join-Path $env:YURUNA_LOG_DIR 'last_failure.json'
        }
        $cause = Get-RunnerFaultCause -FailureRecordPath $recordPath -Reason $Reason -StalledPhase $StalledPhase -FailureClass $FailureClass
        if ($AttemptEvidence -and $AttemptEvidence['description']) { $cause.errorMessage = [string]$AttemptEvidence['description'] }
        $priorFault = $doc['runnerFault']
        $attemptStarted = if ($SpawnedAtUtc -ne [datetime]::MinValue) { $SpawnedAtUtc.ToUniversalTime().ToString('o') } else { '' }
        $faultRecordedAt = if ($priorFault -and [string]$priorFault['attemptGeneration'] -ceq $AttemptGeneration) { [string]$priorFault['recordedAt'] } else { [DateTime]::UtcNow.ToString('o') }
        $attemptCompleted = $false
        if ($doc['finishedAt']) {
            if ($AttemptGeneration -and $doc['cycleGeneration']) {
                $attemptCompleted = [string]$doc['cycleGeneration'] -ceq $AttemptGeneration
            } elseif ($SpawnedAtUtc -ne [datetime]::MinValue) {
                try { $attemptCompleted = ([datetime]$doc['cycleStartUtc']).ToUniversalTime() -ge $SpawnedAtUtc.ToUniversalTime() } catch { $null = $_ }
            }
        }
        $doc['runnerFault'] = if ($attemptCompleted) { $null } else { [ordered]@{
            failureClass = $cause.failureClass
            stage = if ($AttemptEvidence) { [string]$AttemptEvidence['stage'] } else { '' }
            severity = $cause.severity
            stepName = $cause.stepName
            errorMessage = $cause.errorMessage
            recordedAt = $faultRecordedAt
            attemptGeneration = $AttemptGeneration
            attemptStartedAtUtc = $attemptStarted
            attemptElapsedSeconds = if ($SpawnedAtUtc -ne [datetime]::MinValue) { [math]::Max(0, [math]::Round(([DateTime]::UtcNow - $SpawnedAtUtc.ToUniversalTime()).TotalSeconds, 3)) } else { $null }
            frameworkCommitSha = if ($AttemptEvidence -and $AttemptEvidence['frameworkCommitSha']) { [string]$AttemptEvidence['frameworkCommitSha'] } else { $FrameworkCommitSha }
            recordPath = if ($AttemptEvidence -and $AttemptEvidence['recordPath']) { [string]$AttemptEvidence['recordPath'] } else { '' }
            transcriptPath = if ($AttemptEvidence -and $AttemptEvidence['transcriptPath']) { [string]$AttemptEvidence['transcriptPath'] } else { '' }
        } }
        if (-not $attemptCompleted -and $AttemptGeneration) {
            try {
                if (-not (Get-Command Write-RunnerAttemptFaultArtifact -ErrorAction SilentlyContinue)) {
                    Import-Module (Join-Path $PSScriptRoot 'Test.RunnerAttemptHistory.psm1') -DisableNameChecking -ErrorAction Stop
                }
                $started = if ($SpawnedAtUtc -ne [datetime]::MinValue) { $SpawnedAtUtc } else { [DateTime]::UtcNow }
                $retained = Write-RunnerAttemptFaultArtifact -RuntimeDir $RuntimeDir -AttemptGeneration $AttemptGeneration `
                    -FailureClass $cause.failureClass -Description $cause.errorMessage -StartedAtUtc $started `
                    -FrameworkCommitSha $doc['runnerFault']['frameworkCommitSha'] -ExitCode $ExitCode -Evidence $AttemptEvidence -Confirm:$false
                if ($retained) {
                    $doc['runnerFault']['recordPath'] = $retained.recordPath
                    $doc['runnerFault']['transcriptPath'] = $retained.transcriptPath
                }
            } catch { Write-Verbose "Runner attempt history could not be saved: $($_.Exception.Message)" }
        }
        if ($currentCycle) {
            $doc['overallStatus'] = 'fail'
            if (-not $doc['lastFailure']) { $doc['lastFailure'] = $cause }
            $history = if ($doc['history']) { @($doc['history']) } else { @() }
            $cycleKey = [string]$doc['cycleStartUtc']
            $recorded = $false
            foreach ($row in $history) {
                if ($row -and [string]$row['cycleStartUtc'] -eq $cycleKey) { $recorded = $true; break }
            }
            if ($cycleKey -and -not $recorded -and (Initialize-RunnerHistoryWriter)) {
                $entry = New-CycleHistoryEntry -Document $doc -OverallStatus 'fail' `
                    -CycleFolderUrl ([string]$doc['cycleFolderUrl']) `
                    -FinishedAt ([DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)) `
                    -LastFailure $cause
                $doc['history'] = @(@($entry) + $history | Select-Object -First $MaxHistoryRuns)
            }
        }
    }
    $null = Initialize-RunnerStateWriter
    try {
        $saved = Write-YurunaStateFileJson -Path $statusFile -Depth 32 -Compress:$false -Confirm:$false -InputObject $doc
        return [bool]$saved
    } catch {
        Write-Verbose "Update-RunnerFaultStatus: status save failed (best-effort): $($_.Exception.Message)"
        return $false
    }
}

<#
.SYNOPSIS
Tracks how many cycles in a row have stalled in the same preamble phase, and how far to widen the failure pause because of it.
.DESCRIPTION
The failure pause is sized for a condition a commit or a config edit is likely
to fix. A preamble stall is usually neither: the thing that has stopped
answering is a service on the host, outside the process tree the watchdog
kills, so every retry reproduces the stall exactly and the runner can repeat
the same ten-minute kill on the same hour-long cadence indefinitely.

Repeats widen the pause geometrically, up to a cap. That is not a fix -- only
an operator can clear the host condition -- but it stops a wedged machine from
spending its day proving the same point, and the streak it returns is what
makes the repetition legible in the log and the alert.

The streak is file-backed because each cycle is a fresh inner and this outer
may itself be restarted; a process-local counter would never reach two.
#>
function Get-RunnerPreambleStallStreak {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter()][string]$StalledPhase = '',
        [Parameter()][int]$EscalateAfter = 3,
        [Parameter()][int]$MaxMultiplier = 8
    )
    $stateFile = Join-Path $RuntimeDir 'runner.preambleStall.json'
    $result = @{ Streak = 0; Multiplier = 1; Phase = $StalledPhase }
    if (-not $StalledPhase) {
        # Not a preamble stall: clear the streak so an unrelated failure does
        # not inherit a widened pause from one.
        if ((Test-Path -LiteralPath $stateFile) -and $PSCmdlet.ShouldProcess($stateFile, (Format-YurunaOperatorMessage -Key 'runner.operator_cd7b717a8460f125'))) {
            Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
        }
        return $result
    }
    $priorPhase  = ''
    $priorStreak = 0
    if (Test-Path -LiteralPath $stateFile) {
        try {
            $parsed = Get-Content -Raw -LiteralPath $stateFile -ErrorAction Stop | ConvertFrom-Json
            $priorPhase  = [string]$parsed.phase
            $priorStreak = [int]$parsed.streak
        } catch {
            Write-Verbose "Get-RunnerPreambleStallStreak: could not parse $stateFile (restarting the streak): $($_.Exception.Message)"
        }
    }
    # A stall in a DIFFERENT phase is a different condition, and inheriting the
    # old streak would widen the pause for a fault nobody has seen twice.
    $streak = if ($priorPhase -eq $StalledPhase) { $priorStreak + 1 } else { 1 }
    $result.Streak = $streak
    if ($streak -ge $EscalateAfter) {
        $result.Multiplier = [math]::Min($MaxMultiplier, [math]::Pow(2, $streak - $EscalateAfter + 1))
    }
    if ($PSCmdlet.ShouldProcess($stateFile, (Format-YurunaOperatorMessage -Key 'runner.operator_e52a9d11af803a64' -Arguments @{ streak = "$streak"; stalledPhase = "$StalledPhase" }))) {
        $null = Initialize-RunnerStateWriter
        try {
            $null = Write-YurunaStateFileJson -Path $stateFile -Depth 4 -Compress:$false -Confirm:$false -InputObject @{
                phase       = $StalledPhase
                streak      = $streak
                observedUtc = (Get-Date).ToUniversalTime().ToString('o')
            }
        } catch {
            Write-Verbose "Get-RunnerPreambleStallStreak: streak save failed (best-effort): $($_.Exception.Message)"
        }
    }
    return $result
}

function Invoke-RunnerOuterCycle {
    <#
    .SYNOPSIS
        Run ONE cycle: repo pull, pool-configuration gate, pre-spawn cleanup,
        watchdog, the inner spawn, and the cycle-end hooks.
    .DESCRIPTION
        Split out of Invoke-RunnerOuterLoop so it can be executed in a FRESH process
        per cycle (see Invoke-TestCycleRunner.ps1). That is what lets an edit to this
        logic take effect on the very next cycle: the loop process holds it resident
        and would otherwise keep running the copy it parsed at startup.

        Waits belong to the caller, never here. This function runs where the
        operator's Ctrl+C is NOT observable, so a Start-Sleep here could not be cut
        short; the transient outcomes below report and return instead.
        A host refresh is honored here at two of its gate sites: before the
        framework pull (with no state transition) and again before the
        pre-spawn wipe. A held cycle reports refresh-gated and changes nothing;
        an inner held at its own sites leaves runner.refresh-gated.json, which
        turns this cycle's result into refresh-gated too. A preflight cycle --
        the designated chain of a refresh handoff -- skips the pull, the pool
        configuration sync, the failure-record and break-marker wipes and every
        cycle-end hook, and reports refresh-preflight.
    .OUTPUTS
        pscustomobject with Outcome, ExitCode and CycleGeneration. Outcome is
        'completed' when the inner ran (ExitCode is then the inner's own
        status), 'refresh-preflight' for a preflight cycle, or one of
        'pull-error' | 'paused' | 'drain' | 'spawn-failed' | 'refresh-gated'
        -- the caller owns the pause and the decision to stop.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Implementation reads keys from $State; PSSA cannot track hashtable indexer reads.')]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [int]$cycle = 1
    )
    $required = @(
        'RepoRoot','ConfigPath','InnerScript','PwshExe','ArgList',
        'ForwardEnvSnapshot','ShutdownState','NoGitPull',
        'FailurePauseMaxSeconds','FailureCommitPollSeconds',
        'OuterPullErrorSleepSeconds','InnerSpawnErrorSleepSeconds',
        'StepTimeoutSecondsDefault','WatchdogPollSeconds'
    )
    foreach ($k in $required) {
        if (-not $State.ContainsKey($k)) {
            throw "Invoke-RunnerOuterCycle: -State is missing required key '$k'."
        }
    }
    # Set by the cycle-end move when the share turned out to be full. Read at the
    # single return point, where it can still turn a passing cycle into a failing one.
    $spaceFailure = $null
    $cycleGeneration = if ($State.ContainsKey('CycleGeneration')) { $State['CycleGeneration'] } else { $null }

        # Refresh gate before the pull and before any state transition: a held
        # cycle must leave the runner state, the checkout and the runtime
        # files exactly as they were.
        $refreshMode = Get-OuterRefreshCycleMode -State $State
        if ($refreshMode -eq 'gated') {
            return ($script:LastOuterCycleResult = [pscustomobject]@{ Outcome = 'refresh-gated'; ExitCode = 0; CycleGeneration = $cycleGeneration })
        }
        $preflight = ($refreshMode -eq 'preflight')
        if ($preflight) {
            $preflightLine = Format-YurunaOperatorMessage -Key 'runner.refresh_preflight_cycle' -Arguments @{ cycle = "$cycle" }
            Write-Output $preflightLine
            Write-OuterLog $preflightLine
        }

        # State machine: idle -> cycle-start. The transition lands
        # before any per-cycle work so a watchdog reading
        # runner.state.json sees "cycle-start" while the git pull /
        # pre-spawn cleanup is in flight; a crash during that window
        # leaves "cycle-start" stale, which the next outer's
        # Initialize-RunnerState detects + synthesizes a fault.
        if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
            $null = Set-RunnerState -To 'cycle-start' -Reason "cycle $cycle starting" -Confirm:$false
        }

        # 1. Outer git pull (framework repo). Skip on -NoGitPull. A
        #    failure here is treated as transient: short sleep + retry,
        #    so the loop doesn't burn CPU thrashing on a transient git error.
        if (-not $State.NoGitPull -and -not $preflight) {
            Write-Output ""
            Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_3cdf142915062e6a' -Arguments @{ cycle = "$cycle" })
            if (-not (Invoke-OuterGitPull -RepoRoot $State.RepoRoot -ConfigPath $State.ConfigPath)) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_ddebd33ca8159d3f' -Arguments @{ cycle = "$cycle" })
                # The retry pause is the CALLER's, deliberately: sleeping here would
                # block inside the per-cycle child, where the outer's Ctrl+C flag is
                # not observable and the wait could not be cut short.
                return ($script:LastOuterCycleResult = [pscustomobject]@{ Outcome = 'pull-error'; ExitCode = 0; FailureClass = $script:LastOuterPullFailureClass; Detail = (Get-LastOuterPullFailure) })
            }
        }

        # The inner and its gate consume this installed selection. A second
        # moving-tip update would make a cycle's preflight describe other code.
        if ($cycleGeneration -and -not $preflight) {
            $installed = Get-OuterSourceSelection
            if ($State.NoGitPull -or -not $installed) { $installed = Get-InstalledGitSourceSelection -RepoRoot $State.RepoRoot }
            if (-not (Write-GitSourceHandoff -CycleGeneration $cycleGeneration -RepoRoot $State.RepoRoot -ConfigPath $State.ConfigPath -Framework $installed -Confirm:$false)) {
                throw 'source-handoff-write-failed'
            }
        }

        # See https://yuruna.link/4213a0b3-0109
        $poolTC = @{}
        if (-not $preflight -and (Get-Command Sync-YurunaPoolConfiguration -ErrorAction SilentlyContinue)) {
            $poolState = 'run'
            try {
                $poolObj   = Sync-YurunaPoolConfiguration
                $poolState = Resolve-YurunaPoolConfiguredState -Pool $poolObj
                if (Get-Command Get-OuterPoolTestCycleOverride -ErrorAction SilentlyContinue) {
                    $poolTC = Get-OuterPoolTestCycleOverride -Pool $poolObj
                }
                # The resident decides repairs from the cycle's outcome record and
                # never syncs the pool itself, so the override travels there.
                $script:LastOuterPoolTestCycle = $poolTC
            } catch {
                Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_8a6396e375f1eebc' -Arguments @{ cycle = "$cycle"; message = "$($_.Exception.Message)" })
            }
            if ($poolState -eq 'drain') {
                # Stop-after-cycle: any in-flight cycle already completed (this
                # runs at the cycle boundary), so draining never corrupts an
                # accumulating cycle. The host stops; re-adding it (set configuredState
                # back to run + restart the runner) rejoins the pool.
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_eb75165c27011726' -Arguments @{ cycle = "$cycle" })
                Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_8a85c0a98b2cb1af' -Arguments @{ cycle = "$cycle" })
                # Reported rather than set here: the flag lives in the caller's
                # process, so flipping this copy would not reach the loop that owns
                # the shutdown decision.
                return ($script:LastOuterCycleResult = [pscustomobject]@{ Outcome = 'drain'; ExitCode = 0 })
            }
            if ($poolState -eq 'paused') {
                # Healthy hold (distinct from the failure-pause below): the outer
                # while-loop IS the poll -- log, reflect 'paused' in the runner
                # state, sleep, and re-pull configuration next iteration. Flips back to a
                # normal cycle as soon as a pull shows configuredState=run.
                if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
                    $null = Set-RunnerState -To 'paused' -Reason "pool configuredState=paused (cycle $cycle)" -Confirm:$false
                }
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_7b4a4d46bf482437' -Arguments @{ cycle = "$cycle" })
                Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_214ed60f2015cca4' -Arguments @{ cycle = "$cycle" })
                # Caller owns the hold, for the same reason as the pull retry: a
                # sleep here is not interruptible from the shell the operator
                # actually pressed Ctrl+C in.
                return ($script:LastOuterCycleResult = [pscustomobject]@{ Outcome = 'paused'; ExitCode = 0 })
            }
        }

        # See https://yuruna.link/4213a0b3-010a

        # See https://yuruna.link/4213a0b3-010b
        Sync-ForwardEnv -ForwardEnvSnapshot $State.ForwardEnvSnapshot
        if ($State.ForwardEnvSnapshot.Count -gt 0) {
            Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_0e61ff5245986b3e' -Arguments @{ cycle = "$cycle"; join = "$($State.ForwardEnvSnapshot.Keys -join ', ')" })
        }
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_e1a14bbdcff651de' -Arguments @{ cycle = "$cycle"; zzz = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')" })
        Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_7dcdb16b27e44240' -Arguments @{ cycle = "$cycle" })
        # Refresh gate again before the wipe: the gate can close (or a
        # preflight token be revoked) while the pull and the configuration sync run.
        if ((Get-OuterRefreshCycleMode -State $State) -eq 'gated') {
            if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
                $null = Set-RunnerState -To 'paused' -Reason "host refresh holds the runner (cycle $cycle)" -Confirm:$false
            }
            return ($script:LastOuterCycleResult = [pscustomobject]@{ Outcome = 'refresh-gated'; ExitCode = 0; CycleGeneration = $cycleGeneration })
        }
        # Wipe last cycle's runtime files BEFORE arming the watchdog.
        # --- REGION: https://yuruna.link/42f909ad-000f
        $innerPidFile    = Join-Path $env:YURUNA_RUNTIME_DIR 'inner.pid'
        $innerStartFile  = Join-Path $env:YURUNA_RUNTIME_DIR 'inner.start'
        $stepHbFile      = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.stepHeartbeat'
        $phaseFile       = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.phase'
        $lastFailureFile = Join-Path $env:YURUNA_LOG_DIR     'last_failure.json'
        Remove-Item -LiteralPath $innerPidFile    -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $innerStartFile  -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stepHbFile      -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $phaseFile       -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'runner.configGate.json') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'runner.watchdog-kill.json') -Force -ErrorAction SilentlyContinue
        # A preflight cycle keeps the last real cycle's failure record: the
        # failure pause and its remediation classify from it.
        if (-not $preflight) {
            Remove-Item -LiteralPath $lastFailureFile -Force -ErrorAction SilentlyContinue
        }

        # --- REGION: Pre-spawn pool-storage space check (move mode only)
        # See https://yuruna.link/4213a0b3-010c
        $preSpawnSpace = if ($preflight) { $null } else { Test-OuterPoolStorageSpaceReady -ConfigPath $State.ConfigPath }
        if ($preSpawnSpace -and -not $preSpawnSpace.ok) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_e3e3d086b168105e' -Arguments @{ cycle = "$cycle"; message = "$($preSpawnSpace.message)" })
            Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_1716ae7775fbc1fc' -Arguments @{ cycle = "$cycle"; message = "$($preSpawnSpace.message)" })
            $null = Write-PoolStorageSpaceFailureRecord -Message $preSpawnSpace.message -Stage 'PoolStorageSpaceCheck' -Cycle $cycle -Confirm:$false
            $null = Send-PoolStorageSpaceNotification -Message $preSpawnSpace.message -Cycle $cycle -Confirm:$false
            if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
                $null = Set-RunnerState -To 'fault' -Reason 'pool storage full' -Confirm:$false
            }
            # ExitCode 1 (not 0) so the loop's failure branch takes it into the normal
            # pause; the outcome name keeps it distinguishable from a cycle that ran.
            return ($script:LastOuterCycleResult = [pscustomobject]@{ Outcome = 'storage-full'; ExitCode = 1 })
        }
        # Post-wipe: if Remove-Item failed (locked file, transient
        # permission error, AV mid-scan, anything), the watchdog about
        # to arm would read the stale mtime and kill the new inner
        # inside one poll. Force a fresh stepHeartbeat mtime so the
        # watchdog window is full regardless of whether Remove-Item
        # succeeded.
        try {
            [System.IO.File]::WriteAllText($stepHbFile, [DateTime]::UtcNow.ToString('o'))
        } catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_032ce45db60214c4' -Arguments @{ cycle = "$cycle"; message = "$($_.Exception.Message)" })
            Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_5eff327ca3a1e294' -Arguments @{ cycle = "$cycle"; message = "$($_.Exception.Message)" })
        }
        # inner.pid is the watchdog's other input; the new inner
        # overwrites it at startup. If a stale pidfile survived
        # Remove-Item, log loudly so the operator can investigate;
        # the watchdog's wait-for-pidfile loop sees the stale content
        # and either targets a dead PID (no-op) or, worst case, kills
        # a live unrelated process. Surface so it's diagnosable
        # instead of silently weird.
        if (Test-Path -LiteralPath $innerPidFile) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_7390a218d2e41aed' -Arguments @{ cycle = "$cycle" })
            Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_611a5ec5193bf152' -Arguments @{ cycle = "$cycle" })
        }
        # Same class of problem for runner.phase, opposite consequence: a file
        # that cannot be deleted here probably cannot be deleted by the inner's
        # Clear-RunnerPhase either, which would leave the TIGHT preamble bound
        # in force over the sequence and false-kill healthy long steps. Say so
        # rather than let it read as a mysterious mid-cycle kill.
        if (Test-Path -LiteralPath $phaseFile) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_62172827961c5c2f' -Arguments @{ cycle = "$cycle" })
            Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_d3d6eebb8df6a481' -Arguments @{ cycle = "$cycle" })
        }
        # See https://yuruna.link/4213a0b3-010d
        if (-not $preflight) {
            Remove-Item -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'break-active.json') -Force -ErrorAction SilentlyContinue
        }
        # Arm the watchdog BEFORE the spawn so it's already polling
        # by the time the inner writes inner.pid + the first
        # heartbeat. Re-read stepTimeoutSeconds each cycle so an
        # operator can tighten / loosen the bound between cycles
        # without restarting the outer.
        $stepTimeoutSeconds = Get-OuterStepTimeoutSeconds -ConfigPath $State.ConfigPath -DefaultSeconds $State.StepTimeoutSecondsDefault -PoolTestCycleOverride $poolTC
        # Resolve the default here rather than leaning on the State key: an
        # older caller (or a unit test) that builds State without it would pass
        # $null into a mandatory [int] and take the whole cycle down over a
        # watchdog tuning knob.
        $preambleDefault = if ($State.ContainsKey('PreambleTimeoutSecondsDefault')) { [int]$State.PreambleTimeoutSecondsDefault } else { (Get-RunnerTunableDefault).PreambleTimeoutSecondsDefault }
        $preambleTimeoutSeconds = Get-OuterPreambleTimeoutSeconds -ConfigPath $State.ConfigPath -DefaultSeconds $preambleDefault -PoolTestCycleOverride $poolTC
        Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_8c2c47a19b55bb3d' -Arguments @{ cycle = "$cycle"; stepTimeoutSeconds = "$stepTimeoutSeconds"; preambleTimeoutSeconds = "$preambleTimeoutSeconds" })
        $watchdogJob = Start-Watchdog -StepTimeoutSeconds $stepTimeoutSeconds -RuntimeDir $env:YURUNA_RUNTIME_DIR -PollSeconds $State.WatchdogPollSeconds -PreambleTimeoutSeconds $preambleTimeoutSeconds -CycleGeneration ([string]$cycleGeneration)
        # The watchdog lifetime -- the arm-state check, the in-cycle transition,
        # and the inner spawn -- runs inside try/finally so Stop-Watchdog ALWAYS
        # runs. A throw in the arm-check warn or in Set-RunnerState (between
        # arming and the spawn) would otherwise leak the watchdog job (a
        # background job that outlives the cycle) while the throw propagates. This
        # is the same try/finally discipline the failure-pause loop below uses.
        $innerSpawnFailed = $false
        $hostSampler = $null
        try {
            # --- REGION: https://yuruna.link/42dc5bb9-0010
            if ($IsWindows) {
                try {
                    Import-Module (Join-Path $PSScriptRoot 'Test.HostSampling.psm1') -Global -Force -ErrorAction Stop
                    $hostSampler = Start-YurunaHostSampling -RuntimeDirectory $env:YURUNA_RUNTIME_DIR -PwshPath $State.PwshExe -Confirm:$false
                } catch { Write-Verbose "Host sampler unavailable: $($_.Exception.Message)" }
            }
            # A watchdog that failed to arm (null job, or one already in a
            # terminal/failed state) silently disables hang protection: the inner
            # would run unguarded and a hang would never be killed. Surface it
            # loudly to console AND outer.log. A freshly started job is
            # NotStarted -> Running, so only a terminal state here means the arm did
            # not take -- this avoids a false warn on the NotStarted transition.
            if ((-not $watchdogJob) -or ($watchdogJob.State -in @('Failed', 'Stopped', 'Completed'))) {
                $wdState = if ($watchdogJob) { [string]$watchdogJob.State } else { '<null>' }
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_83668bbddda5ab95' -Arguments @{ cycle = "$cycle"; wdState = "$wdState" })
                Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_5159694d8cb25da2' -Arguments @{ cycle = "$cycle"; wdState = "$wdState" })
            }
            # State machine: cycle-start -> in-cycle. Lands AFTER the
            # watchdog is armed and BEFORE the call-op blocks. A crash
            # while inner is running leaves "in-cycle" stale; boot
            # recovery + Initialize-RunnerState narrate the recovery on
            # the next startup.
            if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
                $null = Set-RunnerState -To 'in-cycle' -Reason "inner spawning" -Confirm:$false
            }
            # --- REGION: https://yuruna.link/42d69dfa-000e
            $exitCode = 0
            $innerSpawnedAtUtc = [DateTime]::UtcNow
            try {
                # The runner-issued cycle generation and the refresh transport
                # ride the same short-lived environment as the relaunch flag:
                # set immediately before the spawn, cleared in the finally.
                if ($cycleGeneration) { $env:YURUNA_CYCLE_GENERATION = [string]$cycleGeneration }
                if ($preflight) {
                    $env:YURUNA_REFRESH_HANDOFF_TOKEN = [string]$State['RefreshPreflightTokenId']
                    $env:YURUNA_REFRESH_PREFLIGHT = '1'
                } else {
                    Remove-Item -LiteralPath 'Env:YURUNA_REFRESH_HANDOFF_TOKEN' -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath 'Env:YURUNA_REFRESH_PREFLIGHT' -ErrorAction SilentlyContinue
                }
                if ($State.ContainsKey('RefreshBarrierRequestId') -and $State['RefreshBarrierRequestId'] -and -not $preflight) {
                    $env:YURUNA_REFRESH_BARRIER = [string]$State['RefreshBarrierRequestId']
                } else {
                    Remove-Item -LiteralPath 'Env:YURUNA_REFRESH_BARRIER' -ErrorAction SilentlyContinue
                }
                # Announce the relaunch to the child immediately before the spawn so
                # it inherits the flag; the finally below clears it from $env: the
                # moment the inner returns so it can never leak into a later invocation.
                $env:YURUNA_RUNNER_RELAUNCH = '1'
                # See https://yuruna.link/4213a0b3-010e
                $env:YURUNA_NONINTERACTIVE = '1'
                # Native stdout belongs to the console even when a caller
                # captures this function's typed result. Descendant services
                # must never inherit a PowerShell success-stream pipe.
                $innerStart = [Diagnostics.ProcessStartInfo]::new([string]$State.PwshExe)
                $innerStart.UseShellExecute = $false
                foreach ($argument in @($State.ArgList)) { $innerStart.ArgumentList.Add([string]$argument) }
                $innerProcess = [Diagnostics.Process]::Start($innerStart)
                # The inner writes these once its modules load, which on a busy
                # host takes long enough that the watchdog sat unarmed. Written
                # here at once, start record before pid; the inner rewrites the
                # same values.
                $null = Write-YurunaProcessStartRecord -Path $innerStartFile -ProcessId $innerProcess.Id -Confirm:$false
                $null = Write-YurunaStateFile -Path $innerPidFile -Content ([string]$innerProcess.Id) -Confirm:$false
                try {
                    $innerProcess.WaitForExit()
                    $exitCode = $innerProcess.ExitCode
                } finally { $innerProcess.Dispose() }
            } catch {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_76f2bf2d6b02efd3' -Arguments @{ cycle = "$cycle"; value = "$_" })
                $innerSpawnFailed = $true
            }
        } finally {
            # Clear the relaunch flag now the inner has returned. It must not persist
            # in $env: past the spawn: a direct-invoke inner started later in this same
            # shell session reads it and skips its single-instance guard + pidfile
            # takeover, which would silently disable concurrency protection. The next
            # cycle re-sets it right before its own spawn.
            Remove-Item -LiteralPath 'Env:YURUNA_RUNNER_RELAUNCH' -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath 'Env:YURUNA_NONINTERACTIVE'  -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath 'Env:YURUNA_CYCLE_GENERATION' -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath 'Env:YURUNA_REFRESH_HANDOFF_TOKEN' -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath 'Env:YURUNA_REFRESH_PREFLIGHT' -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath 'Env:YURUNA_REFRESH_BARRIER' -ErrorAction SilentlyContinue
            # A watchdog job that ENDED in Failed crashed mid-cycle -- the
            # inner ran some or all of the cycle unguarded. The job object
            # is about to be removed, so this is the last chance to say so.
            if ($watchdogJob -and $watchdogJob.State -eq 'Failed') {
                $wdReason = try { [string]$watchdogJob.ChildJobs[0].JobStateInfo.Reason.Message } catch { '(reason unavailable)' }
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_5c72237c09d251a5' -Arguments @{ cycle = "$cycle"; wdReason = "$wdReason" })
                Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_8deca88e1ec08ebb' -Arguments @{ cycle = "$cycle"; wdReason = "$wdReason" })
            }
            Stop-Watchdog -Job $watchdogJob
            if ($hostSampler) { Stop-YurunaHostSampling -Handle $hostSampler -Confirm:$false }
        }
        # The watchdog leaves a durable sentinel when it gives up before
        # arming (inner.pid missing/unreadable, identity unprovable): the
        # outer is blocked on the call-op while that happens, so this is
        # where an unguarded cycle becomes visible.
        $wdLapseFile = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.watchdog.lapsed'
        if (Test-Path -LiteralPath $wdLapseFile) {
            $wdLapse = try { (Get-Content -LiteralPath $wdLapseFile -Raw).Trim() } catch { '(unreadable)' }
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_9ba723dc8ae0e940' -Arguments @{ cycle = "$cycle"; wdLapse = "$wdLapse" })
            Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_37783c4be83f2ae9' -Arguments @{ cycle = "$cycle"; wdLapse = "$wdLapse" })
            Remove-Item -LiteralPath $wdLapseFile -Force -ErrorAction SilentlyContinue
        }
        if ($innerSpawnFailed) {
            return ($script:LastOuterCycleResult = [pscustomobject]@{ Outcome = 'spawn-failed'; ExitCode = 0; CycleGeneration = $cycleGeneration })
        }
        # An inner held at one of its own refresh gate sites changed nothing
        # and says so in runner.refresh-gated.json; this cycle is then held
        # too, and none of the cycle-end hooks below run.
        $gatedSidecarPath = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.refresh-gated.json'
        $gatedSidecar = Read-OuterRefreshGatedSidecar -Path $gatedSidecarPath -SpawnedAtUtc $innerSpawnedAtUtc
        if ($gatedSidecar) {
            Remove-Item -LiteralPath $gatedSidecarPath -Force -ErrorAction SilentlyContinue
            Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.refresh_cycle_held' -Arguments @{ cycle = "$cycle"; site = "$($gatedSidecar.site)" })
            if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
                $null = Set-RunnerState -To 'cycle-end' -Reason "host refresh held the inner at $($gatedSidecar.site)" -Confirm:$false
                $null = Set-RunnerState -To 'idle' -Reason 'host refresh holds the runner' -Confirm:$false
            }
            return ($script:LastOuterCycleResult = [pscustomobject]@{ Outcome = 'refresh-gated'; ExitCode = 0; CycleGeneration = $cycleGeneration })
        }
        # Outer regained control. Emit BOTH to console and to runtime/
        # outer.log so a conhost wedge (documented above) can't hide
        # the moment the call operator returned.
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_a1c2ef44f4d6def3' -Arguments @{ cycle = "$cycle"; zzz = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')" })
        Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_d08530fffb9af7a3' -Arguments @{ cycle = "$cycle" })
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_ee3e83807af13667' -Arguments @{ cycle = "$cycle"; exitCode = "$exitCode" })
        Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_9debb05631886531' -Arguments @{ cycle = "$cycle"; exitCode = "$exitCode" })

        # A preflight cycle ends here: it archives, drains, notifies and
        # classifies nothing -- it only proved the chain.
        if ($preflight) {
            $resultLine = Format-YurunaOperatorMessage -Key 'runner.refresh_preflight_result' -Arguments @{ cycle = "$cycle"; exitCode = "$exitCode" }
            Write-Output $resultLine
            Write-OuterLog $resultLine
            return ($script:LastOuterCycleResult = [pscustomobject]@{ Outcome = 'refresh-preflight'; ExitCode = $exitCode; CycleGeneration = $cycleGeneration })
        }

        $attemptFault = Get-RunnerAttemptFault -RuntimeDir $env:YURUNA_RUNTIME_DIR -AttemptGeneration ([string]$cycleGeneration) -SpawnedAtUtc $innerSpawnedAtUtc -ExitCode $exitCode
        if ($exitCode -ne 0 -and $attemptFault.FailureClass -eq 'config_gate_failed') {
            return ($script:LastOuterCycleResult = [pscustomobject]@{ Outcome = 'config-gate-failed'; ExitCode = $exitCode; CycleGeneration = $cycleGeneration })
        }

        # --- REGION: poolStorage health surfacing (best-effort)
        # The drain below runs DETACHED + best-effort, so a host that has STOPPED
        # replicating (bad credential, read-only share, a Windows drive-letter /
        # credential collision) records the failure ONLY in the ledger -- where no
        # operator looks. Read the PRIOR drain's ledger (the one fired at the end of
        # the previous cycle has had a full cycle to finish) and WARN to console +
        # outer.log when replication is failing/stalled, so a silent failure becomes
        # visible. Never throws; a missing module / config / ledger just skips it.
        try {
            if (-not (Get-Command Get-PoolStorageHealthWarning -ErrorAction SilentlyContinue)) {
                $psHealthMod = Join-Path $PSScriptRoot 'Test.PoolStorage.psm1'
                if (Test-Path -LiteralPath $psHealthMod) { Import-Module $psHealthMod -ErrorAction SilentlyContinue }
            }
            if ((Get-Command Read-PoolStorageLedger -ErrorAction SilentlyContinue) -and
                (Get-Command Get-PoolStorageHealthWarning -ErrorAction SilentlyContinue) -and
                (Get-Command Get-YurunaPoolStorageConfig -ErrorAction SilentlyContinue) -and
                (Get-Command Read-TestConfig -ErrorAction SilentlyContinue)) {
                $psArchiveCfg = $null
                try {
                    $psCfgNow = Read-TestConfig -Path $State.ConfigPath -LastGoodOnError
                    $psArchiveCfg = Get-YurunaPoolStorageConfig -Config $psCfgNow -WarningAction SilentlyContinue
                } catch { $null = $_ }
                if ($psArchiveCfg) {
                    $psLedger = Read-PoolStorageLedger -RuntimeDir $env:YURUNA_RUNTIME_DIR
                    $psWarn   = Get-PoolStorageHealthWarning -Ledger $psLedger
                    if ($psWarn) {
                        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_7a381fc326b7ba77' -Arguments @{ cycle = "$cycle"; psWarn = "$psWarn" })
                        Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_4cdbfac185ae5352' -Arguments @{ cycle = "$cycle"; psWarn = "$psWarn" })
                    }
                }
            }
        } catch {
            Write-Verbose "poolStorage health check skipped: $($_.Exception.Message)"
        }

        # --- REGION: Pool-storage archiving, COPY mode (best-effort, DETACHED)
        # See https://yuruna.link/4213a0b3-010f
        $psMoveMode = Get-OuterPoolStorageMoveMode -ConfigPath $State.ConfigPath
        try {
            $drainScript = Join-Path $PSScriptRoot 'Invoke-PoolStorageDrain.ps1'
            if ((-not $psMoveMode) -and (Test-Path -LiteralPath $drainScript)) {
                $hid = if (Get-Command Get-YurunaHostId -ErrorAction SilentlyContinue) { [string](Get-YurunaHostId) } else { '' }
                $drainErr = Join-Path $env:YURUNA_RUNTIME_DIR 'poolstorage.drain.err'
                Import-Module (Join-Path $PSScriptRoot 'Test.InnerSpawn.psm1') -Global -DisableNameChecking
                $launch = Start-YurunaDetachedProcess -FilePath $drainScript -ArgumentList @('-HostId', $hid) `
                    -WorkingDirectory $State.RepoRoot -StdOutPath (Join-Path $env:YURUNA_RUNTIME_DIR 'poolstorage.drain.out') `
                    -StdErrPath $drainErr -PrivateDirectory $env:YURUNA_RUNTIME_DIR -Confirm:$false
                if (-not $launch.Launched) { throw "pool storage drain launch failed: $($launch.Reason)" }
            }
        } catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_42325e069d98407d' -Arguments @{ cycle = "$cycle"; message = "$($_.Exception.Message)" })
        }

        # --- REGION: Pool push forwarder (best-effort, DETACHED)
        # Ship this cycle's NDJSON events to the aggregator's /ingest so they reach Loki
        # without waiting for the next 30s pull. Runs in its OWN detached process (same
        # idiom as the drain) so a slow/absent aggregator can NEVER delay the next cycle
        # (preserving read-side decoupling); pull backfills anything push drops. The
        # forwarder self-gates: it is a fast no-op unless the internal authentication key is configured
        # (enrollment is the push opt-in) AND a caching-proxy-service is reachable. Spawn failure is
        # non-fatal.
        $pushProc = $null
        $pushPid  = 0
        try {
            $pushScript = Join-Path $PSScriptRoot 'Invoke-PoolPushForwarder.ps1'
            if (Test-Path -LiteralPath $pushScript) {
                $phid = if (Get-Command Get-YurunaHostId -ErrorAction SilentlyContinue) { [string](Get-YurunaHostId) } else { '' }
                $pushErr = Join-Path $env:YURUNA_RUNTIME_DIR 'poolpush.forwarder.err'
                Import-Module (Join-Path $PSScriptRoot 'Test.InnerSpawn.psm1') -Global -DisableNameChecking
                $launch = Start-YurunaDetachedProcess -FilePath $pushScript -ArgumentList @('-HostId', $phid) `
                    -WorkingDirectory $State.RepoRoot -StdOutPath (Join-Path $env:YURUNA_RUNTIME_DIR 'poolpush.forwarder.out') `
                    -StdErrPath $pushErr -PrivateDirectory $env:YURUNA_RUNTIME_DIR -Confirm:$false
                if (-not $launch.Launched) { throw "pool push forwarder launch failed: $($launch.Reason)" }
                $pushPid = [int]$launch.FinalPid
            }
        } catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_1543e1c089df9fda' -Arguments @{ cycle = "$cycle"; message = "$($_.Exception.Message)" })
        }

        # --- REGION: Move mode: let the forwarder finish reading before anything is deleted
        # See https://yuruna.link/4213a0b3-0110
        if ($psMoveMode -and ($pushProc -or $pushPid -gt 0)) {
            $waitSeconds = 120
            if (Get-Command Get-OuterPoolStoragePushWait -ErrorAction SilentlyContinue) {
                $waitSeconds = Get-OuterPoolStoragePushWait
            }
            $exited = Wait-OuterPushForwarder -Process $pushProc -ProcessId $pushPid -TimeoutSeconds $waitSeconds
            if (-not $exited) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_4b262f771b0f9512' -Arguments @{ cycle = "$cycle"; waitSeconds = "${waitSeconds}" })
                Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_12217888a6d3cb8e' -Arguments @{ cycle = "$cycle"; waitSeconds = "${waitSeconds}" })
            }
        }

        # --- REGION: Pool-storage archiving, MOVE mode (SYNCHRONOUS, bounded)
        # Move mode copies, verifies, and then DELETES each finished cycle's local
        # folder, so its outcome is part of the cycle's verdict and it cannot be
        # detached. It blocks the loop by necessity; the phase is wall-clock bounded
        # and a slow NAS is reported as a warning rather than a failure.
        if ($psMoveMode) {
            $moveResult = Invoke-OuterPoolStorageMove -Cycle $cycle
            if ($moveResult -and $moveResult.spaceShort) {
                # The share is full: nothing was copied and nothing was deleted. Fail
                # the cycle so the runner takes its normal failure pause instead of
                # running the next cycle into the same wall.
                $spaceFailure = $moveResult
            }
        }

        # --- REGION: Pool alert notifier (best-effort, BOUNDED cycle-end hook)
        # See https://yuruna.link/4213a0b3-0111
        try {
            # Import the notifier + its dependencies (poolStorage config, caching-proxy-service IP,
            # the Send-Notification dispatcher) best-effort. Plain Import-Module (no -Force)
            # is idempotent and avoids the global-module-eviction trap.
            foreach ($m in @('Test.PoolStorage.psm1', 'Test.CachingProxyService.psm1', 'Test.Notify.psm1', 'Test.PoolNotifier.psm1')) {
                $mp = Join-Path $PSScriptRoot $m
                if (Test-Path -LiteralPath $mp) { Import-Module $mp -ErrorAction SilentlyContinue }
            }
            if (Get-Command Invoke-PoolNotifierCycle -ErrorAction SilentlyContinue) {
                $notifierCfg = $null
                if (Get-Command Read-TestConfig -ErrorAction SilentlyContinue) {
                    try { $notifierCfg = Read-TestConfig -Path $State.ConfigPath -LastGoodOnError } catch { $null = $_ }
                }
                $notifySummary = $null
                # The notifier touches the poolStorage NAS in-process (it needs the delivery
                # ledger to confirm a send). A wedged CIFS mount mid-drain could otherwise
                # block here for the OS SMB timeout, stalling the unattended loop. Run it in a
                # thread job with a hard wall-clock cap: Wait-Job -Timeout returns control to
                # the loop even if a syscall is still blocked (the loop moves on; an
                # uncompleted delivery simply retries next cycle). Send-Notification works in a
                # thread job -- the async notification path relies on the same.
                if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
                    # Reap notifier jobs a prior cycle's timeout leaked, best-effort
                    # and non-blocking (only terminal jobs are removed here).
                    Clear-TerminalNotifierJob -State $State
                    $notifierModulesDir = $PSScriptRoot
                    $njob = Start-ThreadJob -Name "pool-notifier-$cycle" -ScriptBlock {
                        Import-Module (Join-Path $using:notifierModulesDir 'Test.PoolStorage.psm1') -Global -ErrorAction Stop
                        Import-Module (Join-Path $using:notifierModulesDir 'Test.CachingProxyService.psm1') -Global -ErrorAction Stop
                        Import-Module (Join-Path $using:notifierModulesDir 'Test.Notify.psm1') -Global -ErrorAction Stop
                        Import-Module (Join-Path $using:notifierModulesDir 'Test.PoolNotifier.psm1') -Global -ErrorAction Stop
                        Invoke-PoolNotifierCycle -Config $using:notifierCfg
                    }
                    if (Wait-Job -Job $njob -Timeout 120) {
                        try { $notifySummary = Receive-Job -Job $njob -ErrorAction Stop }
                        catch { Write-Warning -Message $_.Exception.Message }
                        finally {
                            # The job completed; removing a terminal job does not block.
                            Remove-Job -Job $njob -Force -ErrorAction SilentlyContinue
                        }
                    } else {
                        # Do NOT Stop-Job/Remove-Job here: on a wedged CIFS syscall
                        # those calls can THEMSELVES block for the OS SMB timeout,
                        # re-introducing the very stall the 120s cap exists to prevent.
                        # Leak the job (a same-process thread job -- true detach is
                        # impossible) and reap it best-effort next cycle once terminal.
                        if (-not $State.LeakedNotifierJobs) { $State.LeakedNotifierJobs = [System.Collections.Generic.List[object]]::new() }
                        [void]$State.LeakedNotifierJobs.Add($njob)
                        # Surface the pending-leak count: a host whose poolStorage CIFS
                        # mount stays wedged keeps accumulating leaked jobs (each holds a
                        # ThreadJob pool slot, default ThrottleLimit 5), so a climbing
                        # count is the signal that the mount -- not the notifier -- is the
                        # problem to fix.
                        Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_eb2af2d8a9f44de2' -Arguments @{ cycle = "$cycle"; count = "$($State.LeakedNotifierJobs.Count)" })
                    }
                } else {
                    $notifySummary = Invoke-PoolNotifierCycle -Config $notifierCfg
                }
                if ($notifySummary -and $notifySummary.ran -and (($notifySummary.enqueued + $notifySummary.delivered + $notifySummary.failed + $notifySummary.retried) -gt 0)) {
                    Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_463371faa645f632' -Arguments @{ cycle = "$cycle"; enqueued = "$($notifySummary.enqueued)"; delivered = "$($notifySummary.delivered)"; retried = "$($notifySummary.retried)"; failed = "$($notifySummary.failed)" })
                }
                if ($notifySummary -and @($notifySummary.spoolErrors).Count -gt 0) {
                    Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.pool_notifier_spool_errors' -Arguments @{ cycle = "$cycle"; count = "$(@($notifySummary.spoolErrors).Count)"; detail = "$(@($notifySummary.spoolErrors)[0])" })
                }
            }
        } catch {
            Write-Verbose "pool notifier hook skipped: $($_.Exception.Message)"
        }

        # See https://yuruna.link/4213a0b3-0112
        if ($exitCode -ne 0 -and $attemptFault.Evidence -and $attemptFault.IsCrash) {
            $stepHbFile = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.stepHeartbeat'
            if (Test-Path -LiteralPath $stepHbFile) {
                $hbAge = ([datetime]::UtcNow - (Get-Item -LiteralPath $stepHbFile).LastWriteTimeUtc).TotalSeconds
                if ($hbAge -gt $stepTimeoutSeconds) {
                    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_496000203b3e66db' -Arguments @{ cycle = "$cycle"; hbAge = "$([int]$hbAge)"; stepTimeoutSeconds = "${stepTimeoutSeconds}" })
                    Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_9427498a7339c0ac' -Arguments @{ cycle = "$cycle"; hbAge = "$([int]$hbAge)"; stepTimeoutSeconds = "${stepTimeoutSeconds}" })
                    # See https://yuruna.link/4213a0b3-0113
                    $synthFailureFile = if ($env:YURUNA_LOG_DIR) { Join-Path $env:YURUNA_LOG_DIR 'last_failure.json' } else { $null }
                    if ($synthFailureFile -and -not (Test-Path -LiteralPath $synthFailureFile) -and (Get-Command Write-YurunaStateFileJson -ErrorAction SilentlyContinue)) {
                        $null = Write-YurunaStateFileJson -Path $synthFailureFile -WarnOnFailure -Confirm:$false -InputObject ([ordered]@{
                            schemaVersion           = 2
                            reason                  = 'watchdog_kill'
                            failureClass            = 'wait_timeout'
                            docUrl                  = $(if (Get-Command Get-FailureClassDocUrl -ErrorAction SilentlyContinue) { Get-FailureClassDocUrl -FailureClass 'wait_timeout' } else { '' })
                            severity                = 'hard'
                            classificationSource    = 'synthetic'
                            # SIGKILL destroyed the inner runspace that held the only
                            # structured step location (runner.stepHeartbeat records a
                            # bare mtime; current-action.json a free-text line), so
                            # these stay unresolved -- 0 / '' (not omitted) keeps the
                            # schema-v2 contract satisfied and Invoke-Remediation
                            # null-safe.
                            stepNumber              = 0
                            sequenceName            = ''
                            # Remaining schema-v2 file fields so the record genuinely
                            # matches the shape New-SequenceFailureRecord emits (all
                            # 'unresolved' -- a SIGKILL left no inner state to read).
                            totalSteps              = 0
                            action                  = 'watchdog kill (inner runspace SIGKILLed)'
                            description             = (Format-YurunaOperatorMessage -Key 'runner.operator_b33e5044e7bc7194')
                            vmName                  = ''
                            guestKey                = ''
                            actionVerb              = 'watchdog'
                            suggestedRecoveries     = @()
                            stepHeartbeatAgeSeconds = [int]$hbAge
                            stepTimeoutSeconds      = $stepTimeoutSeconds
                            cycle                   = $cycle
                            synthesizedBy           = 'outer-watchdog'
                            timestamp               = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
                        })
                        Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_ac172bafbb64e5ce' -Arguments @{ cycle = "$cycle" })
                    }
                }
            }
        }

    # A full share turns a passing cycle into a failing one: its results could not be
    # archived, and on a move-mode host that is the difference between having them and
    # not. A cycle that ALREADY failed keeps its own, richer verdict and its own
    # last_failure.json -- the runner never replaces a real failure with this one.
    if ($spaceFailure) {
        Write-PoolStorageSpaceFailure -Move $spaceFailure -Cycle $cycle -InnerExitCode $exitCode
        if ($exitCode -eq 0) { $exitCode = 1 }
    }

    return ($script:LastOuterCycleResult = [pscustomobject]@{ Outcome = 'completed'; ExitCode = $exitCode; CycleGeneration = $cycleGeneration })
}

# --- REGION: Host-refresh gate at the runner's spawn and pull sites
# While a host refresh reclaims or repairs, no runner process may spawn an
# inner, pull, or sweep: the gate record (Test.SingleInstance) holds every
# site, and an unreadable gate holds them too. A handoff token opens only
# the preflight spawn of the designated chain. These helpers keep the three
# processes' decisions in one place.

function Get-OuterRefreshCycleMode {
    <#
    .SYNOPSIS
        preflight, open or gated for the cycle about to run.
    .DESCRIPTION
        A cycle that carries a validated preflight token runs as preflight
        only while the gate still admits that token. A preflight request that
        can no longer be served is gated rather than turned into an ordinary
        cycle, so the runner re-decides with the gate's current state. With
        no token, the gate decides; gate helpers that cannot be resolved hold
        the cycle.
    .PARAMETER State
        The cycle State hashtable.
    .OUTPUTS
        [string] preflight, open or gated.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$State)
    if (-not (Get-Command Get-YurunaRefreshGateState -ErrorAction SilentlyContinue)) { return 'gated' }
    $token = if ($State.ContainsKey('RefreshPreflightTokenId')) { [string]$State['RefreshPreflightTokenId'] } else { '' }
    $requested = $State.ContainsKey('RefreshPreflightRequested') -and [bool]$State['RefreshPreflightRequested']
    if ($token) {
        $gate = Get-YurunaRefreshGateState -RuntimeDir $env:YURUNA_RUNTIME_DIR -TokenId $token
        if ($gate.PreflightAllowed) { return 'preflight' }
        return 'gated'
    }
    if ($requested) { return 'gated' }
    $gate = Get-YurunaRefreshGateState -RuntimeDir $env:YURUNA_RUNTIME_DIR
    if ($gate.SpawnAllowed) { return 'open' }
    return 'gated'
}

function ConvertTo-OuterRefreshHandoff {
    <#
    .SYNOPSIS
        Normalize a handoff (from the runner's resume parameters or a repair
        result) to @{ TokenId; RequestId; Purpose; Generation }, or $null.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()]$Handoff)
    if ($null -eq $Handoff) { return $null }
    $read = {
        param([string[]]$Names)
        foreach ($name in $Names) {
            if ($Handoff -is [System.Collections.IDictionary]) {
                if ($Handoff.Contains($name)) { return $Handoff[$name] }
            } elseif ($Handoff.PSObject.Properties[$name]) {
                return $Handoff.$name
            }
        }
        return $null
    }
    $tokenId = [string](& $read @('TokenId', 'tokenId'))
    if ($tokenId -notmatch '^[0-9a-f]{32}$') { return $null }
    return @{
        TokenId    = $tokenId
        RequestId  = [string](& $read @('RequestId', 'requestId'))
        Purpose    = [string](& $read @('Purpose', 'purpose'))
        Generation = [string](& $read @('Generation', 'generation'))
    }
}

function Resolve-OuterRefreshDispatch {
    <#
    .SYNOPSIS
        Decide how the resident loop may dispatch this cycle: preflight,
        barrier, ordinary or gated.
    .DESCRIPTION
        A pending handoff whose token validates for this outer dispatches the
        preflight chain. A handoff that no longer validates while the gate is
        open becomes the barrier: the next ordinary cycle first waits for the
        operator's preserved controls. Otherwise the gate decides; a closed,
        recovery-pending, handoff or unreadable gate holds the dispatch.
    .PARAMETER State
        The loop State hashtable (RefreshHandoff and RefreshBarrierRequestId
        are updated here).
    .OUTPUTS
        [pscustomobject] @{ Mode; Gate; TokenId; RequestId; Purpose }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][hashtable]$State)
    $runtime = $env:YURUNA_RUNTIME_DIR
    $unavailable = [pscustomobject]@{ State = 'unknown'; SpawnAllowed = $false; Reason = 'gate-unavailable'; RequestId = $null; Orphaned = $false }
    $gateCommands = @('Get-YurunaRefreshGateState', 'Test-YurunaRunnerHandoffToken')
    if (@($gateCommands | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue }).Count -ne $gateCommands.Count) {
        return [pscustomobject]@{ Mode = 'gated'; Gate = $unavailable; TokenId = $null; RequestId = $null; Purpose = $null }
    }
    $handoff = if ($State.ContainsKey('RefreshHandoff')) { ConvertTo-OuterRefreshHandoff -Handoff $State['RefreshHandoff'] } else { $null }
    if ($handoff) {
        $token = Test-YurunaRunnerHandoffToken -TokenId $handoff.TokenId -Role outer -RuntimeDir $runtime
        if ($token.Valid) {
            $requestId = if ($token.RequestId) { [string]$token.RequestId } else { $handoff.RequestId }
            return [pscustomobject]@{ Mode = 'preflight'; Gate = $null; TokenId = $handoff.TokenId; RequestId = $requestId; Purpose = [string]$token.Purpose }
        }
        $gate = Get-YurunaRefreshGateState -RuntimeDir $runtime
        if ($gate.SpawnAllowed) {
            $State['RefreshHandoff'] = $null
            $State['RefreshBarrierRequestId'] = if ($handoff.RequestId) { $handoff.RequestId } elseif ($gate.RequestId) { [string]$gate.RequestId } else { 'unknown' }
            return [pscustomobject]@{ Mode = 'barrier'; Gate = $gate; TokenId = $null; RequestId = $State['RefreshBarrierRequestId']; Purpose = $null }
        }
        return [pscustomobject]@{ Mode = 'gated'; Gate = $gate; TokenId = $null; RequestId = $handoff.RequestId; Purpose = $handoff.Purpose }
    }
    $gate = Get-YurunaRefreshGateState -RuntimeDir $runtime
    if (-not $gate.SpawnAllowed) {
        return [pscustomobject]@{ Mode = 'gated'; Gate = $gate; TokenId = $null; RequestId = $gate.RequestId; Purpose = $null }
    }
    if ($State.ContainsKey('RefreshBarrierRequestId') -and $State['RefreshBarrierRequestId']) {
        return [pscustomobject]@{ Mode = 'barrier'; Gate = $gate; TokenId = $null; RequestId = [string]$State['RefreshBarrierRequestId']; Purpose = $null }
    }
    return [pscustomobject]@{ Mode = 'ordinary'; Gate = $gate; TokenId = $null; RequestId = $null; Purpose = $null }
}

function Read-OuterRefreshGatedSidecar {
    <#
    .SYNOPSIS
        The inner's runner.refresh-gated.json when it was written by this
        process's own inner during this spawn, else $null.
    .PARAMETER Path
        The sidecar path.
    .PARAMETER SpawnedAtUtc
        When this process spawned the inner.
    .OUTPUTS
        [pscustomobject] or $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][datetime]$SpawnedAtUtc)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $doc = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
    if (-not $doc -or [int]$doc.innerParentPid -ne $PID) { return $null }
    $observed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    $when = if ($doc.observedUtc -is [datetime]) { ([datetime]$doc.observedUtc).ToUniversalTime() }
        elseif ([datetime]::TryParse([string]$doc.observedUtc, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$observed)) { $observed }
        else { $null }
    if ($null -eq $when -or $when -lt $SpawnedAtUtc.AddSeconds(-2)) { return $null }
    return $doc
}

function Import-OuterRefreshTriggerModule {
    <#
    .SYNOPSIS
        Guarded import of Test.HostRefreshTrigger for the automatic-repair
        call sites; the loop never depends on it being present.
    .OUTPUTS
        [bool] $true when its commands resolve.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (Get-Command Invoke-HostRefreshAutoDecision -ErrorAction SilentlyContinue) { return $true }
    $module = Join-Path $PSScriptRoot 'Test.HostRefreshTrigger.psm1'
    if (Test-Path -LiteralPath $module) { Import-Module $module -Global -ErrorAction SilentlyContinue }
    return [bool](Get-Command Invoke-HostRefreshAutoDecision -ErrorAction SilentlyContinue)
}

function Test-OuterRefreshGateOwnedHere {
    <#
    .SYNOPSIS
        $true when the gate's recorded owner is this outer process (PID and
        start time), as a resident-outer handoff leaves it.
    .PARAMETER State
        The loop State hashtable (caches this process's start time).
    .PARAMETER Gate
        A Get-YurunaRefreshGateState view.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][hashtable]$State, [AllowNull()]$Gate)
    if (-not $Gate -or -not $Gate.PSObject.Properties['Owner'] -or -not $Gate.Owner) { return $false }
    $owner = $Gate.Owner
    $ownerPid = if ($owner -is [System.Collections.IDictionary]) { $owner['pid'] } else { $owner.pid }
    $ownerStart = if ($owner -is [System.Collections.IDictionary]) { $owner['startTimeUnixMs'] } else { $owner.startTimeUnixMs }
    if ($null -eq $ownerPid -or [int]$ownerPid -ne $PID -or $null -eq $ownerStart) { return $false }
    if (-not $State.ContainsKey('OuterStartTimeUnixMs') -or $null -eq $State['OuterStartTimeUnixMs']) {
        if (-not (Get-Command Get-YurunaProcessStartUnixMs -ErrorAction SilentlyContinue)) { return $false }
        $State['OuterStartTimeUnixMs'] = Get-YurunaProcessStartUnixMs -ProcessId $PID
    }
    if ($null -eq $State['OuterStartTimeUnixMs']) { return $false }
    return ([Math]::Abs([long]$ownerStart - [long]$State['OuterStartTimeUnixMs']) -le 2000)
}

function Send-OuterRefreshCallerAck {
    <#
    .SYNOPSIS
        Report this resident outer's readiness verdict to the repair's
        request record, when that helper is loaded; failures are logged.
    .PARAMETER RequestId
        The host-refresh request.
    .PARAMETER Ready
        The verdict: ready ($true) or failed.
    .PARAMETER Reason
        Why it failed (a code).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([AllowEmptyString()][string]$RequestId, [switch]$Ready, [AllowEmptyString()][string]$Reason)
    try {
        if (-not (Get-Command Set-HostRefreshCallerAck -ErrorAction SilentlyContinue)) {
            foreach ($module in @('Test.HostRefreshIntent.psm1')) {
                $path = Join-Path $PSScriptRoot $module
                if (Test-Path -LiteralPath $path) { Import-Module $path -Global -ErrorAction SilentlyContinue }
            }
        }
        if (Get-Command Set-HostRefreshCallerAck -ErrorAction SilentlyContinue) {
            $ownStart = Get-YurunaProcessStartUnixMs -ProcessId $PID
            $ack = @{
                RequestId = $RequestId; Readiness = $(if ($Ready) { 'ready' } else { 'failed' })
                CallerPid = $PID; CallerStartTimeUnixMs = [long]$ownStart; Confirm = $false
            }
            if (-not $Ready) { $ack.Reason = $Reason }
            $null = Set-HostRefreshCallerAck @ack
        } else {
            Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.refresh_trigger_call_failed' -Arguments @{ site = 'caller-ack'; message = 'Set-HostRefreshCallerAck unavailable' })
        }
    } catch {
        Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.refresh_trigger_call_failed' -Arguments @{ site = 'caller-ack'; message = "$($_.Exception.Message)" })
    }
}

function Complete-OuterExpiredResidentHandoff {
    <#
    .SYNOPSIS
        End a resident-outer handoff designating this outer whose token can
        no longer be used, so the gate does not stay in handoff for good.
    .DESCRIPTION
        The worker that issued the token has exited and the gate names this
        outer as its owner, so nobody else will complete it. Once the token
        has expired (or the host rebooted since it was issued) without this
        outer dispatching its preflight, the handoff is completed
        recovery-pending as the designated outer, the repair's request record
        is told readiness failed (handoff-expired), and the stale handoff is
        dropped from State. The returned gate view is the one to report.
    .PARAMETER State
        The loop State hashtable.
    .PARAMETER Cycle
        The loop's cycle counter.
    .PARAMETER Gate
        The gate view that held the dispatch.
    .OUTPUTS
        [pscustomobject] the gate view after any completion (or -Gate).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][int]$Cycle, [AllowNull()]$Gate)
    if (-not $Gate -or [string]$Gate.State -ne 'handoff' -or [string]$Gate.Purpose -ne 'resident-outer') { return $Gate }
    $designated = $Gate.DesignatedOuter
    $designatedPid = if ($designated -is [System.Collections.IDictionary]) { $designated['pid'] } elseif ($designated) { $designated.pid } else { $null }
    if ($null -eq $designatedPid -or [int]$designatedPid -ne $PID) { return $Gate }
    if (-not (Get-Command Complete-YurunaRunnerExpiredHandoff -ErrorAction SilentlyContinue)) { return $Gate }
    $done = Complete-YurunaRunnerExpiredHandoff -Confirm:$false
    if (-not $done.Completed) { return $Gate }
    $State['RefreshHandoff'] = $null
    $requestId = if ($done.RequestId) { [string]$done.RequestId } else { [string]$Gate.RequestId }
    $line = Format-YurunaOperatorMessage -Key 'runner.refresh_handoff_unverified' -Arguments @{ cycle = "$Cycle"; requestId = $requestId; reason = 'handoff-expired' }
    Write-Warning $line
    Write-OuterLog $line
    Send-OuterRefreshCallerAck -RequestId $requestId -Reason 'handoff-expired'
    if (Get-Command Get-YurunaRefreshGateState -ErrorAction SilentlyContinue) {
        return (Get-YurunaRefreshGateState -RuntimeDir $env:YURUNA_RUNTIME_DIR)
    }
    return $Gate
}

function Write-OuterRefreshGateHold {
    <#
    .SYNOPSIS
        Log the refresh gate holding the loop, once per transition of
        (request, state, orphaned), to the console and outer.log.
    .PARAMETER State
        The loop State hashtable (remembers the last logged transition).
    .PARAMETER Cycle
        The loop's cycle counter.
    .PARAMETER Gate
        The gate view that held the dispatch.
    .DESCRIPTION
        A gate this outer owns itself -- left recovery-pending by a failed or
        expired resident-outer handoff -- is reported as orphaned too: the
        worker that closed it has exited and this outer is only waiting on
        itself, so the operator needs the same Invoke-HostRefresh.ps1 -Resume
        pointer a dead worker's gate gets.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][int]$Cycle, [AllowNull()]$Gate)
    if (-not $Gate -and (Get-Command Get-YurunaRefreshGateState -ErrorAction SilentlyContinue)) {
        $Gate = Get-YurunaRefreshGateState -RuntimeDir $env:YURUNA_RUNTIME_DIR
    }
    $requestId = if ($Gate) { [string]$Gate.RequestId } else { '' }
    $gateState = if ($Gate) { [string]$Gate.State } else { 'unknown' }
    $orphaned  = [bool]($Gate -and $Gate.Orphaned)
    if (-not $orphaned -and $Gate -and $gateState -in @('closed', 'recovery-pending')) {
        $orphaned = Test-OuterRefreshGateOwnedHere -State $State -Gate $Gate
    }
    $key = "$requestId|$gateState|$orphaned"
    if ($State.ContainsKey('RefreshGateLogged') -and $State['RefreshGateLogged'] -eq $key) { return }
    $State['RefreshGateLogged'] = $key
    $line = if ($gateState -eq 'unknown') {
        Format-YurunaOperatorMessage -Key 'runner.refresh_gate_unreadable' -Arguments @{ cycle = "$Cycle"; reason = "$(if ($Gate) { $Gate.Reason } else { 'gate-unavailable' })" }
    } elseif ($orphaned) {
        Format-YurunaOperatorMessage -Key 'runner.refresh_gate_orphaned' -Arguments @{ cycle = "$Cycle"; requestId = $requestId; state = $gateState }
    } else {
        Format-YurunaOperatorMessage -Key 'runner.refresh_gate_hold' -Arguments @{ cycle = "$Cycle"; requestId = $requestId; state = $gateState }
    }
    Write-Warning $line
    Write-OuterLog $line
}

function Invoke-OuterRefreshResidentCompletion {
    <#
    .SYNOPSIS
        After a resident-outer preflight cycle: verify the acknowledgment
        against the cycle this outer spawned, leave the refresh gate as the
        designated outer, and report readiness to the repair's record.
    .DESCRIPTION
        The chain has already exited, so liveness is replaced by the outer's
        own record of that cycle. A verified ready acknowledgment completes
        the handoff released (the gate may still read recovery-pending when
        obligations remain); anything else completes it recovery-pending.
        The caller acknowledgment goes to the repair's journal when that
        helper is loaded.
    .PARAMETER Handoff
        The normalized handoff.
    .PARAMETER Cycle
        The loop's cycle counter.
    .PARAMETER ExitCode
        The preflight cycle's exit code.
    .PARAMETER CycleIdentity
        { Pid; StartTimeUnixMs } of the cycle this outer spawned.
    .OUTPUTS
        [pscustomobject] @{ Ready; Completed; Reason }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$Handoff,
        [Parameter(Mandatory)][int]$Cycle,
        [Parameter(Mandatory)][int]$ExitCode,
        [AllowNull()]$CycleIdentity
    )
    $ready = $false
    $reason = if ($ExitCode -ne 0) { "preflight-exit-$ExitCode" } else { 'ack-unverified' }
    if ($ExitCode -eq 0 -and $CycleIdentity) {
        $wait = Wait-YurunaRunnerReadiness -TokenId $Handoff.TokenId -Deadline (New-YurunaDeadline -TotalMilliseconds 2000) -ExpectedCycle $CycleIdentity
        $ready = ($wait.State -eq 'ready')
        $reason = [string]$wait.Reason
    }
    $token = Test-YurunaRunnerHandoffToken -TokenId $Handoff.TokenId -Role outer -RuntimeDir $env:YURUNA_RUNTIME_DIR
    $verdict = if ($ready) { 'released' } else { 'recovery-pending' }
    $done = Complete-YurunaRunnerHandoff -TokenId $Handoff.TokenId -Verdict $verdict -ExpectedGeneration ([string]$token.Generation) -AsDesignatedOuter -Confirm:$false
    if ($ready -and $done.Completed) {
        $line = Format-YurunaOperatorMessage -Key 'runner.refresh_handoff_complete' -Arguments @{ cycle = "$Cycle"; requestId = $Handoff.RequestId }
        Write-Information $line -InformationAction Continue
        Write-OuterLog $line
    } else {
        if ($ready -and -not $done.Completed) { $reason = "complete-$($done.Reason)" }
        $line = Format-YurunaOperatorMessage -Key 'runner.refresh_handoff_unverified' -Arguments @{ cycle = "$Cycle"; requestId = $Handoff.RequestId; reason = $reason }
        Write-Warning $line
        Write-OuterLog $line
    }
    Send-OuterRefreshCallerAck -RequestId $Handoff.RequestId -Ready:($ready -and [bool]$done.Completed) -Reason $reason
    return [pscustomobject]@{ Ready = ($ready -and [bool]$done.Completed); Completed = [bool]$done.Completed; Reason = $reason }
}

function Get-RunnerTunableDefault {
    <#
    .SYNOPSIS
        The runner's built-in timing defaults: the one place to read or tune them.
    .DESCRIPTION
        Code constants by design, not test.config.yml keys, so an operator can
        grep and adjust them without a config-schema migration; the testCycle
        keys a config carries (stepTimeoutSeconds, preambleTimeoutSeconds,
        maxCycleSeconds) still override the three timeouts. The resident
        runner (Start-TestRunner.ps1) and the per-cycle process
        (Invoke-TestCycleRunner.ps1) both build their state from this table:
        each used to keep its own copy, the two disagreed, and the copy an
        operator was pointed at was not the one the per-cycle process -- which
        arms the step watchdog -- used.

        Tune the failure-pause cap with care: it keeps a wedged host from
        burning git and network while staying short enough that a one-off
        transient (network blip, mirror hiccup) recovers within an hour
        without an operator.
    .OUTPUTS
        [hashtable] FailurePauseMaxSeconds, OuterNetworkGateRetrySeconds,
        OuterNetworkGateRetryMaxSeconds, OuterNetworkGateRecoveryPollSeconds,
        FailureCommitPollSeconds, OuterPullErrorSleepSeconds,
        InnerSpawnErrorSleepSeconds, StepTimeoutSecondsDefault,
        PreambleTimeoutSecondsDefault, MaxCycleSecondsDefault and
        WatchdogPollSeconds.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{
        FailurePauseMaxSeconds              = 60 * 60   # cap a failure backoff at 60 min
        OuterNetworkGateRetrySeconds        = 120
        OuterNetworkGateRetryMaxSeconds     = 15 * 60
        OuterNetworkGateRecoveryPollSeconds = 30
        FailureCommitPollSeconds            = 30        # source checks share one 30-second budget
        OuterPullErrorSleepSeconds          = 30        # short pause if the runner's own git pull errors
        InnerSpawnErrorSleepSeconds         = 30        # short pause if Start-Process itself fails
        StepTimeoutSecondsDefault           = 2700      # watchdog: kill the inner when its heartbeat is older than this
        # Tighter bound while the inner is still in its preamble (runner.phase
        # present): nothing before the first sequence step is legitimately slow,
        # so a stall there is a wedged runner, not long work. 0 opts out.
        PreambleTimeoutSecondsDefault       = 600
        # Absolute per-cycle bound the resident enforces; 0 disables it (see
        # Get-OuterMaxCycleSeconds).
        MaxCycleSecondsDefault              = 21600
        WatchdogPollSeconds                 = 30        # how often the watchdog re-checks the heartbeat file
    }
}

function Wait-OuterInterruptible {
    <#
    .SYNOPSIS
        Sleep in short slices, returning early once shutdown is requested.
    .DESCRIPTION
        A plain Start-Sleep cannot be cut short by the CancelKeyPress handler: the
        handler only flips a flag, and every consumer has to poll it. Long unsliced
        sleeps are why a Ctrl+C could appear to be ignored for the better part of a
        minute. Returns $true when it was cut short.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][int]$Seconds,
        [Parameter(Mandatory)][hashtable]$ShutdownState,
        [int]$SliceSeconds = 5
    )
    $remaining = $Seconds
    while ($remaining -gt 0) {
        if ($ShutdownState['Requested']) { return $true }
        if ($script:OuterWaitTickState) {
            try { Invoke-OuterPoolNotifierTick -State $script:OuterWaitTickState } catch { Write-Verbose "pool notifier tick: $($_.Exception.Message)" }
        }
        $slice = [math]::Min($SliceSeconds, $remaining)
        Start-Sleep -Seconds $slice
        $remaining -= $slice
    }
    return [bool]$ShutdownState['Requested']
}

function Invoke-OuterCycleDispatch {
    <#
    .SYNOPSIS
        Run one cycle -- in a fresh process when a cycle script is configured,
        in-process otherwise -- and normalize the result.
    .DESCRIPTION
        The fresh process is the whole point of the split: it re-reads the cycle
        logic and its modules from disk every cycle, so an edit lands on the next
        cycle without restarting the runner. The child is polled rather than waited
        on so Ctrl+C is observable mid-cycle, and on shutdown its entire tree is
        killed so no inner pwsh survives.

        The child reports its outcome through a small JSON file rather than an exit
        code, because the inner runner's own exit codes share that space and a
        sentinel number could collide with a real failure. The record is
        required: a child that exits cleanly without leaving one that names this
        cycle's generation is scored 'outcome-unrecorded', never as a pass.

        The host-refresh gate is consulted before anything is spawned. A held
        dispatch returns refresh-gated without a child. A pending handoff whose
        token validates spawns the preflight chain with the token in the
        child's environment; the first ordinary cycle after a handoff carries
        the barrier request instead. The spawned cycle process is recorded in
        runner.cycle.json while it runs, so a refresh identifies it from this
        record rather than from a command line.
    .OUTPUTS
        pscustomobject with Outcome, ExitCode, CycleGeneration, Refresh (the
        dispatch mode), Cycle ({ Pid; StartTimeUnixMs } of the spawned cycle
        process, or $null), Gate (the gate view that held a dispatch) and
        Handoff (@{ TokenId; RequestId; Purpose } as the gate validated it
        for a preflight dispatch, else $null). An 'outcome-unrecorded' result
        also carries OutcomeReason ('missing' | 'malformed' | 'stale-generation')
        and OutcomeDetail.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][int]$Cycle
    )
    $cycleGeneration = if ($State.ContainsKey('CycleGeneration')) { $State['CycleGeneration'] } else { $null }
    $dispatch = Resolve-OuterRefreshDispatch -State $State
    # The handoff as the gate validated it: its purpose, not the one the
    # caller's handoff record claims, decides who completes it.
    $validated = if ($dispatch.Mode -eq 'preflight') {
        @{ TokenId = [string]$dispatch.TokenId; RequestId = [string]$dispatch.RequestId; Purpose = [string]$dispatch.Purpose }
    } else { $null }
    if ($dispatch.Mode -eq 'gated') {
        return [pscustomobject]@{
            Outcome = 'refresh-gated'; ExitCode = 0; CycleGeneration = $cycleGeneration
            Refresh = 'gated'; Cycle = $null; Gate = $dispatch.Gate; Handoff = $null
        }
    }
    $cycleScript = if ($State.ContainsKey('CycleScript')) { [string]$State.CycleScript } else { '' }
    if (-not $cycleScript -or -not (Test-Path -LiteralPath $cycleScript)) {
        # In-process fallback: same code path, no reload benefit. Unit tests drive
        # this shape, and it keeps the loop working if the script is ever missing.
        # The refresh fields a cycle process would read from its environment are
        # threaded into State instead, and reset every dispatch.
        $State['RefreshPreflightRequested'] = ($dispatch.Mode -eq 'preflight')
        $State['RefreshPreflightTokenId']   = if ($dispatch.Mode -eq 'preflight') { $dispatch.TokenId } else { $null }
        $State['RefreshPreflightPurpose']   = if ($dispatch.Mode -eq 'preflight') { $dispatch.Purpose } else { $null }
        $State['RefreshPreflightRequestId'] = if ($dispatch.Mode -eq 'preflight') { $dispatch.RequestId } else { $null }
        # The cycle's own return value is the verdict; its recorded result is the fallback for a
        # path that returned nothing. Capturing it also keeps it out of this function's output,
        # where it would turn the single result into an array.
        $cycleReturned = @(Invoke-RunnerOuterCycle -State $State -Cycle $Cycle) | Where-Object { $null -ne $_ } | Select-Object -Last 1
        $inProcessResult = if ($cycleReturned) { $cycleReturned } else { Get-LastOuterCycleResult }
        if (-not $inProcessResult) { return [pscustomobject]@{ Outcome = 'spawn-failed'; ExitCode = 1 } }
        return [pscustomobject]@{
            Outcome = $inProcessResult.Outcome; ExitCode = $inProcessResult.ExitCode; CycleGeneration = $cycleGeneration
            RecordFailureClass = $inProcessResult.FailureClass; RecordDetail = $inProcessResult.Detail
            RecordPoolTestCycle = $(if ($inProcessResult.PSObject.Properties['PoolTestCycle']) { $inProcessResult.PoolTestCycle } else { $null })
            Refresh = $dispatch.Mode; Cycle = $null; Gate = $null; Handoff = $validated; FromRecord = $true
        }
    }

    $outcomeFile = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.cycle.outcome.json'
    Remove-Item -LiteralPath $outcomeFile -Force -ErrorAction SilentlyContinue

    # See https://yuruna.link/4213a0b3-0114
    $cycleScriptQuoted = '"' + $cycleScript + '"'
    # See https://yuruna.link/4213a0b3-0115
    $argList = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $cycleScriptQuoted, '-Cycle', "$Cycle")
    if ($State.ContainsKey('ConfigPath') -and $State.ConfigPath) {
        $argList += @('-ConfigPath', ('"' + $State.ConfigPath + '"'))
    }
    if ($State.ContainsKey('NoGitPull') -and $State.NoGitPull) { $argList += '-NoGitPull' }
    if ($State.ContainsKey('NoStatusService') -and $State.NoStatusService) { $argList += '-NoStatusService' }
    if ($State.ContainsKey('NoConfigGate') -and $State.NoConfigGate) { $argList += '-NoConfigGate' }
    if ($State.ContainsKey('CycleDelaySeconds') -and $State.CycleDelaySeconds) {
        $argList += @('-CycleDelaySeconds', "$($State.CycleDelaySeconds)")
    }
    if ($State.ContainsKey('LogLevel') -and $State.LogLevel) { $argList += @('-logLevel', $State.LogLevel) }
    # Only when the loop issued one: a State without the key (a unit test, an
    # older caller) keeps the exact argument vector it always had.
    if ($State.ContainsKey('CycleGeneration') -and $State['CycleGeneration']) { $argList += @('-CycleGeneration', [string]$State['CycleGeneration']) }
    $proc = $null
    $cycleIdentity = $null
    $spawnedAt = Get-Date
    # A daylight-saving change moves Get-Date by an hour; how long the cycle ran
    # decides whether it aborted early, so that is read from a monotonic clock.
    $spawnWatch = [Diagnostics.Stopwatch]::StartNew()
    $refreshEnvironment = @{}
    if ($dispatch.Mode -eq 'preflight') {
        $refreshEnvironment['YURUNA_REFRESH_HANDOFF_TOKEN'] = [string]$dispatch.TokenId
        $refreshEnvironment['YURUNA_REFRESH_PREFLIGHT'] = '1'
    } elseif ($dispatch.Mode -eq 'barrier') {
        $refreshEnvironment['YURUNA_REFRESH_BARRIER'] = [string]$dispatch.RequestId
    }
    try {
        # The refresh transport lives in the environment for exactly the spawn:
        # set just before, cleared in the finally that also covers the wait, so
        # a later dispatch never inherits a token or barrier meant for this one.
        foreach ($name in @('YURUNA_REFRESH_HANDOFF_TOKEN', 'YURUNA_REFRESH_PREFLIGHT', 'YURUNA_REFRESH_BARRIER')) {
            if ($refreshEnvironment.ContainsKey($name)) { Set-Item -Path "Env:$name" -Value $refreshEnvironment[$name] }
            else { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
        }
        try {
            $proc = Start-Process -FilePath $State.PwshExe -ArgumentList $argList -NoNewWindow -PassThru -ErrorAction Stop
        } catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_961568a3cc6a695a' -Arguments @{ cycle = "$Cycle"; message = "$($_.Exception.Message)" })
            return [pscustomobject]@{ Outcome = 'spawn-failed'; ExitCode = 0; CycleGeneration = $cycleGeneration; Refresh = $dispatch.Mode; Cycle = $null; Gate = $null; Handoff = $validated }
        }
        # On Windows, Start-Process -PassThru returns a Process looked up by id
        # that holds no handle, and once the child has exited its ExitCode can
        # only be read through a handle opened while it still ran.
        if ($proc.PSObject.Properties['Handle']) { try { $null = $proc.Handle } catch { $null = $_ } }
        if (Get-Command Write-YurunaRunnerCycleRecord -ErrorAction SilentlyContinue) {
            $recordArgs = @{ RuntimeDir = $env:YURUNA_RUNTIME_DIR; Process = $proc; Cycle = $Cycle; Confirm = $false }
            if ($cycleGeneration) { $recordArgs.CycleGeneration = [string]$cycleGeneration }
            $null = Write-YurunaRunnerCycleRecord @recordArgs
            $cycleStart = $null
            try {
                $recorded = Get-Content -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'runner.cycle.json') -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ([int]$recorded.pid -eq [int]$proc.Id) { $cycleStart = $recorded.startTimeUnixMs }
            } catch { $cycleStart = $null }
            $cycleIdentity = [pscustomobject]@{ Pid = [int]$proc.Id; StartTimeUnixMs = $cycleStart }
        }

        # See Get-OuterMaxCycleSeconds. Measured on a Stopwatch, which a wall-clock
        # change (DST, an NTP step) cannot shorten or extend.
        $defaultCeiling = if ($State.ContainsKey('MaxCycleSecondsDefault')) { [int]$State['MaxCycleSecondsDefault'] } else { (Get-RunnerTunableDefault).MaxCycleSecondsDefault }
        $ceilingSeconds = $defaultCeiling
        if ($State.ContainsKey('ConfigPath') -and $State.ConfigPath) {
            # A configuration that cannot be read keeps the default bound; it never
            # stops the cycle from being spawned.
            try { $ceilingSeconds = Get-OuterMaxCycleSeconds -ConfigPath $State.ConfigPath -DefaultSeconds $defaultCeiling }
            catch { Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.outer_poll_failed' -Arguments @{ probe = 'max-cycle-seconds'; message = (ConvertTo-RecoverySafeText -Text ([string]$_.Exception.Message)) }) }
        }
        # The plan raises the ceiling once the inner publishes it, at two step
        # timeouts per run, and held time is subtracted from the working time.
        $ceilingStepSeconds = if ($State.ContainsKey('StepTimeoutSecondsDefault')) { [int]$State['StepTimeoutSecondsDefault'] } else { (Get-RunnerTunableDefault).StepTimeoutSecondsDefault }
        if ($State.ContainsKey('ConfigPath') -and $State.ConfigPath) {
            try { $ceilingStepSeconds = Get-OuterStepTimeoutSeconds -ConfigPath $State.ConfigPath -DefaultSeconds $ceilingStepSeconds }
            catch { Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.outer_poll_failed' -Arguments @{ probe = 'step-timeout-seconds'; message = (ConvertTo-RecoverySafeText -Text ([string]$_.Exception.Message)) }) }
        }
        $effectiveCeiling = $ceilingSeconds
        $plannedRuns = 0
        $planPollSeconds = if ($State.ContainsKey('PlanPollSeconds')) { [int]$State['PlanPollSeconds'] } else { 15 }
        $planWatch = [Diagnostics.Stopwatch]::StartNew()
        $heldWatch = [Diagnostics.Stopwatch]::new()
        $ceilingWatch = [Diagnostics.Stopwatch]::StartNew()
        $lapseFile = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.watchdog.lapsed'
        $lapseReported = $false
        # Armed when the step watchdog stands down: the resident then applies the
        # watchdog's bounds itself, so a cycle it cannot guard is not left to the
        # ceiling alone.
        $heartbeatGuard = $null
        while (-not $proc.HasExited) {
            if ($script:OuterWaitTickState) {
                try { Invoke-OuterPoolNotifierTick -State $script:OuterWaitTickState } catch { Write-Verbose "pool notifier tick: $($_.Exception.Message)" }
            }
            if ($State.ShutdownState['Requested']) {
                Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_2ca94152d51378a0' -Arguments @{ cycle = "$Cycle"; id = "$($proc.Id)" })
                Stop-YurunaProcessTree -ProcessId $proc.Id -Confirm:$false
                try { $null = $proc.WaitForExit(15000) } catch { $null = $_ }
                return [pscustomobject]@{ Outcome = 'shutdown'; ExitCode = 0; CycleGeneration = $cycleGeneration; Refresh = $dispatch.Mode; Cycle = $cycleIdentity; Gate = $null; Handoff = $validated }
            }
            if (Test-OuterCycleHeld -RuntimeDir $env:YURUNA_RUNTIME_DIR) {
                if (-not $heldWatch.IsRunning) { $heldWatch.Start() }
            } elseif ($heldWatch.IsRunning) { $heldWatch.Stop() }
            if ($ceilingSeconds -gt 0 -and $plannedRuns -eq 0 -and $planWatch.Elapsed.TotalSeconds -ge $planPollSeconds) {
                $planWatch.Restart()
                $plannedRuns = Get-OuterCyclePlannedRunCount -RuntimeDir $env:YURUNA_RUNTIME_DIR -SpawnedAtUtc $spawnedAt.ToUniversalTime()
                if ($plannedRuns -gt 0) {
                    $scaledCeiling = Get-OuterCycleCeilingSeconds -ConfiguredSeconds $ceilingSeconds -StepTimeoutSeconds $ceilingStepSeconds -PlannedRunCount $plannedRuns
                    if ($scaledCeiling -gt $effectiveCeiling) {
                        $effectiveCeiling = $scaledCeiling
                        Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.cycle_ceiling_scaled' -Arguments @{ cycle = "$Cycle"; count = "$plannedRuns"; configuredSeconds = "$ceilingSeconds"; ceilingSeconds = "$effectiveCeiling" })
                    }
                }
            }
            # The watchdog writes this sentinel when it stands down; saying so now,
            # rather than after the cycle returns, is what tells an operator the
            # resident is guarding the cycle in its place.
            if (-not $lapseReported -and [IO.File]::Exists($lapseFile)) {
                try {
                    if ([IO.File]::GetLastWriteTimeUtc($lapseFile) -ge $spawnedAt.ToUniversalTime()) {
                        $lapseReported = $true
                        $lapseBound = Read-OuterWatchdogLapseBound -Path $lapseFile
                        if (-not $lapseBound) {
                            $fallbackPreamble = if ($State.ContainsKey('PreambleTimeoutSecondsDefault')) { [int]$State['PreambleTimeoutSecondsDefault'] } else { (Get-RunnerTunableDefault).PreambleTimeoutSecondsDefault }
                            $lapseBound = @{ StepSeconds = $ceilingStepSeconds; PreambleSeconds = $fallbackPreamble }
                        }
                        $heartbeatStamp = $null
                        $heartbeatFile = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.stepHeartbeat'
                        if ([IO.File]::Exists($heartbeatFile)) { $heartbeatStamp = [IO.File]::GetLastWriteTimeUtc($heartbeatFile) }
                        $heartbeatGuard = @{
                            Watch = [Diagnostics.Stopwatch]::StartNew(); LastWriteUtc = $heartbeatStamp
                            StepSeconds = [int]$lapseBound.StepSeconds; PreambleSeconds = [int]$lapseBound.PreambleSeconds
                        }
                        $lapseLine = Format-YurunaOperatorMessage -Key 'runner.watchdog_lapse_seen' -Arguments @{ cycle = "$Cycle"; stepSeconds = "$($heartbeatGuard.StepSeconds)"; preambleSeconds = "$($heartbeatGuard.PreambleSeconds)"; ceilingSeconds = "$effectiveCeiling" }
                        Write-Warning $lapseLine
                        Write-OuterLog $lapseLine
                    }
                } catch { $null = $_ }
            }
            if ($heartbeatGuard) {
                $stall = Step-OuterHeartbeatGuard -Guard $heartbeatGuard -RuntimeDir $env:YURUNA_RUNTIME_DIR
                if ($stall) {
                    $stallClass = if ($stall.Phase) { 'preamble_stall' } else { 'wait_timeout' }
                    $stallReason = if ($stall.Phase) {
                        Format-YurunaOperatorMessage -Key 'runner.resident_watchdog_kill_preamble' -Arguments @{ cycle = "$Cycle"; ageSeconds = "$($stall.AgeSeconds)"; boundSeconds = "$($stall.BoundSeconds)"; phase = "$($stall.Phase)"; id = "$($proc.Id)" }
                    } else {
                        Format-YurunaOperatorMessage -Key 'runner.resident_watchdog_kill_step' -Arguments @{ cycle = "$Cycle"; ageSeconds = "$($stall.AgeSeconds)"; boundSeconds = "$($stall.BoundSeconds)"; id = "$($proc.Id)" }
                    }
                    Write-Warning $stallReason
                    Write-OuterLog $stallReason
                    $null = Write-OuterStopRecord -Confirm:$false -Record ([ordered]@{
                        schemaVersion = 1; recordPath = 'runner.watchdog-kill.json'
                        attemptGeneration = [string]$cycleGeneration
                        startedAtUtc = $spawnedAt.ToUniversalTime().ToString('o')
                        timestamp = [DateTime]::UtcNow.ToString('o')
                        innerPid = [int]$proc.Id; phase = [string]$stall.Phase
                        failureClass = $stallClass; description = $stallReason
                        stepHeartbeatAgeSeconds = [int]$stall.AgeSeconds
                        timeoutSeconds = [int]$stall.BoundSeconds
                    })
                    Stop-YurunaProcessTree -ProcessId $proc.Id -Confirm:$false
                    try { $null = $proc.WaitForExit(15000) } catch { $null = $_ }
                    $stallExit = 1
                    try { if ($proc.HasExited -and $proc.ExitCode -ne 0) { $stallExit = [int]$proc.ExitCode } } catch { $null = $_ }
                    return [pscustomobject]@{
                        Outcome = 'outcome-unrecorded'; ExitCode = $stallExit
                        OutcomeReason = 'resident-watchdog'; OutcomeDetail = $stallReason; RecordFailureClass = $stallClass
                        CycleGeneration = $cycleGeneration; Refresh = $dispatch.Mode; Cycle = $cycleIdentity; Gate = $null; Handoff = $validated
                    }
                }
            }
            if ($effectiveCeiling -gt 0 -and ($ceilingWatch.Elapsed.TotalSeconds - $heldWatch.Elapsed.TotalSeconds) -ge $effectiveCeiling) {
                $ceilingReason = Format-YurunaOperatorMessage -Key 'runner.cycle_ceiling_reached' -Arguments @{ cycle = "$Cycle"; ceilingSeconds = "$effectiveCeiling"; id = "$($proc.Id)" }
                Write-Warning $ceilingReason
                Write-OuterLog $ceilingReason
                # Same record the watchdog leaves, so the post-dispatch accounting
                # attributes the stop to this attempt without guessing.
                $null = Write-OuterStopRecord -Confirm:$false -Record ([ordered]@{
                    schemaVersion = 1; recordPath = 'runner.watchdog-kill.json'
                    attemptGeneration = [string]$cycleGeneration
                    startedAtUtc = $spawnedAt.ToUniversalTime().ToString('o')
                    timestamp = [DateTime]::UtcNow.ToString('o')
                    innerPid = [int]$proc.Id; phase = ''
                    failureClass = 'cycle_killed'; description = $ceilingReason
                    timeoutSeconds = $effectiveCeiling
                })
                Stop-YurunaProcessTree -ProcessId $proc.Id -Confirm:$false
                try { $null = $proc.WaitForExit(15000) } catch { $null = $_ }
                $ceilingExit = 1
                try { if ($proc.HasExited -and $proc.ExitCode -ne 0) { $ceilingExit = [int]$proc.ExitCode } } catch { $null = $_ }
                return [pscustomobject]@{
                    Outcome = 'outcome-unrecorded'; ExitCode = $ceilingExit
                    OutcomeReason = 'cycle-ceiling'; OutcomeDetail = $ceilingReason
                    CycleGeneration = $cycleGeneration; Refresh = $dispatch.Mode; Cycle = $cycleIdentity; Gate = $null; Handoff = $validated
                }
            }
            $null = $proc.WaitForExit(1000)
        }
    } finally {
        foreach ($name in @('YURUNA_REFRESH_HANDOFF_TOKEN', 'YURUNA_REFRESH_PREFLIGHT', 'YURUNA_REFRESH_BARRIER')) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
        if ($proc -and (Get-Command Clear-YurunaRunnerCycleRecord -ErrorAction SilentlyContinue) -and
            (-not $proc.PSObject.Properties['HasExited'] -or $proc.HasExited)) {
            $null = Clear-YurunaRunnerCycleRecord -RuntimeDir $env:YURUNA_RUNTIME_DIR -ProcessId ([int]$proc.Id) -Confirm:$false
        }
    }
    $childExit = $proc.ExitCode

    # The record is the only evidence of what the cycle concluded. A clean exit
    # code is not: a process can exit 0 having failed to say anything, and a
    # record from a different cycle describes a different cycle. Both are
    # rejected here, so a pass is only ever scored from a record that names this
    # cycle's generation.
    $record = Read-CycleOutcomeRecord -Path $outcomeFile -ExpectedGeneration ([string]$cycleGeneration)
    $rejectedPath = ''
    if (-not $record.Valid -and $record.Reason -ne 'missing') {
        # Kept for diagnosis; the next dispatch would otherwise delete the only
        # copy of what the child actually wrote.
        $rejectedPath = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.cycle.outcome.rejected.json'
        try { Move-Item -LiteralPath $outcomeFile -Destination $rejectedPath -Force -ErrorAction Stop } catch { $rejectedPath = '' }
    }
    Remove-Item -LiteralPath $outcomeFile -Force -ErrorAction SilentlyContinue
    $ranForSeconds = [int]$spawnWatch.Elapsed.TotalSeconds
    if ($record.Valid) {
        $reportedGeneration = if ($record.CycleGeneration) { $record.CycleGeneration } else { $cycleGeneration }
        return [pscustomobject]@{
            Outcome = $record.Outcome; ExitCode = $record.ExitCode; CycleGeneration = $reportedGeneration
            RecordFailureClass = $record.FailureClass; RecordDetail = $record.RecordDetail
            RecordPoolTestCycle = $record.PoolTestCycle
            Refresh = $dispatch.Mode; Cycle = $cycleIdentity; Gate = $null; Handoff = $validated; FromRecord = $true
        }
    }
    Write-Verbose "[outer cycle $Cycle] cycle outcome record rejected ($($record.Reason)): $($record.Detail)"
    # See https://yuruna.link/4213a0b3-0116
    if (Test-YurunaCycleAborted -ReportedOutcome $false -ChildExit $childExit -RanForSeconds $ranForSeconds) {
        Write-Warning ((Format-YurunaOperatorMessage -Key 'runner.operator_9120a71c591dce9f' -Arguments @{ cycle = "$Cycle"; childExit = "$childExit"; ranForSeconds = "${ranForSeconds}" }))
        Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_28086350fb4a3aee' -Arguments @{ cycle = "$Cycle"; childExit = "$childExit"; ranForSeconds = "${ranForSeconds}" })
        return [pscustomobject]@{ Outcome = 'cycle-aborted'; ExitCode = $childExit; CycleGeneration = $cycleGeneration; Refresh = $dispatch.Mode; Cycle = $cycleIdentity; Gate = $null; Handoff = $validated }
    }
    # Everything else that reaches here ran long enough to have been a real cycle
    # and left nothing that can be believed. It is an infrastructure fault of its
    # own: not a test verdict, and above all not a pass. A non-zero child exit is
    # kept as the exit code (the failure was real whether or not it was recorded);
    # a clean one is replaced, so no later check reads it as success.
    $unrecordedExit = if ($childExit -ne 0) { $childExit } else { Get-UnrecordedOutcomeExitCode }
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.cycle_outcome_unrecorded' -Arguments @{ cycle = "$Cycle"; childExit = "$childExit"; ranForSeconds = "${ranForSeconds}"; reason = "$($record.Reason)"; detail = "$($record.Detail)" })
    if ($rejectedPath) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.cycle_outcome_rejected_kept' -Arguments @{ cycle = "$Cycle"; rejectedPath = "$rejectedPath" })
    }
    Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.cycle_outcome_unrecorded_log' -Arguments @{ cycle = "$Cycle"; childExit = "$childExit"; ranForSeconds = "${ranForSeconds}"; reason = "$($record.Reason)"; detail = "$($record.Detail)" })
    return [pscustomobject]@{
        Outcome = 'outcome-unrecorded'; ExitCode = $unrecordedExit
        OutcomeReason = $record.Reason; OutcomeDetail = $record.Detail
        CycleGeneration = $cycleGeneration; Refresh = $dispatch.Mode; Cycle = $cycleIdentity; Gate = $null; Handoff = $validated
    }
}

function Test-YurunaCycleAborted {
    <# .SYNOPSIS
    Classifies an unexplained early nonzero child exit using the runner threshold.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([bool]$ReportedOutcome, [int]$ChildExit, [double]$RanForSeconds)
    return (-not $ReportedOutcome -and $ChildExit -ne 0 -and $RanForSeconds -lt $script:CycleAbortSeconds)
}

function Invoke-RunnerOuterLoop {
    <#
    .SYNOPSIS
        Run the eternal cycle loop until ShutdownState['Requested'] flips.
    .DESCRIPTION
        Each iteration runs its cycle in a FRESH pwsh (Invoke-TestCycleRunner.ps1)
        rather than in-process, so the cycle logic -- and every module it imports --
        is re-read from disk every cycle. An operator edit therefore takes effect on
        the next cycle with no runner restart. This process keeps only what must not
        be re-derived per cycle: the pidfile, the boot-recovery sweep, the runner
        state machine, the Ctrl+C subscription, and the cross-cycle counters below.

        The child is waited on in slices rather than blocked on, which is what makes
        Ctrl+C both observable during a cycle and able to take the cycle down with
        it: the whole child tree is killed, so no inner pwsh survives the shutdown.
    .PARAMETER State
        Hashtable carrying per-run config + cross-thread references.
        Required keys (all enforced via the validation block below):
          RepoRoot, ConfigPath, InnerScript, PwshExe, ArgList,
          ForwardEnvSnapshot, ShutdownState, NoGitPull,
          FailurePauseMaxSeconds, FailureCommitPollSeconds,
          OuterPullErrorSleepSeconds, InnerSpawnErrorSleepSeconds,
          StepTimeoutSecondsDefault, WatchdogPollSeconds.
        Optional: CycleScript -- path to Invoke-TestCycleRunner.ps1. Absent, the
        cycle runs IN-PROCESS via Invoke-RunnerOuterCycle, which is the shape the
        unit tests drive and a usable fallback if the script is missing.
        ShutdownState is a hashtable (reference-shared with the caller's Ctrl+C
        handler) whose ['Requested'] key flipping ends the loop.
        Optional refresh keys: RefreshHandoff (a handoff the next dispatch
        runs as a preflight chain), RefreshBarrierRequestId (carried by the
        first ordinary cycle after a handoff), RefreshGateHoldSeconds (the
        hold between dispatches while a host refresh holds the runner,
        default 15).

        Every cycle gets an outer-issued generation, <RunnerInstanceId>:<cycle>,
        which the per-cycle process hands to the inner so per-cycle evidence can
        be matched to the cycle that produced it. The automatic host-refresh
        decision runs after each dispatch through Test.HostRefreshTrigger when
        that module is present; its failures are logged and never change what
        the loop does.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Implementation reads keys from $State; PSSA cannot track hashtable indexer reads.')]
    param([Parameter(Mandatory)][hashtable]$State)
    $required = @(
        'RepoRoot','ConfigPath','InnerScript','PwshExe','ArgList',
        'ForwardEnvSnapshot','ShutdownState','NoGitPull',
        'FailurePauseMaxSeconds','FailureCommitPollSeconds',
        'OuterPullErrorSleepSeconds','InnerSpawnErrorSleepSeconds',
        'StepTimeoutSecondsDefault','WatchdogPollSeconds'
    )
    foreach ($k in $required) {
        if (-not $State.ContainsKey($k)) {
            throw "Invoke-RunnerOuterLoop: -State is missing required key '$k'."
        }
    }
    # The counter lives in $State so a loop re-entered by Invoke-RunnerOuterSupervisor
    # continues the numbering and never issues the same cycle generation twice.
    $cycle = if ($State.ContainsKey('OuterCycleCounter')) { [int]$State['OuterCycleCounter'] } else { 0 }
    # The runner's own identity for cycle generations: kept when the caller
    # already carries one, minted otherwise.
    if (-not ($State.ContainsKey('RunnerInstanceId') -and [string]$State['RunnerInstanceId'] -match '^[0-9a-f]{32}$')) {
        $State['RunnerInstanceId'] = [guid]::NewGuid().ToString('N')
    }
    $gateHoldSeconds = if ($State.ContainsKey('RefreshGateHoldSeconds') -and [int]$State['RefreshGateHoldSeconds'] -gt 0) { [int]$State['RefreshGateHoldSeconds'] } else { 15 }
    $networkRetryBase = if ($State.ContainsKey('OuterNetworkGateRetrySeconds') -and [int]$State.OuterNetworkGateRetrySeconds -gt 0) { [int]$State.OuterNetworkGateRetrySeconds } else { 120 }
    $networkRetryCap = if ($State.ContainsKey('OuterNetworkGateRetryMaxSeconds') -and [int]$State.OuterNetworkGateRetryMaxSeconds -gt 0) { [int]$State.OuterNetworkGateRetryMaxSeconds } else { 900 }
    $networkPollSeconds = if ($State.ContainsKey('OuterNetworkGateRecoveryPollSeconds') -and [int]$State.OuterNetworkGateRecoveryPollSeconds -gt 0) { [math]::Min(30, [int]$State.OuterNetworkGateRecoveryPollSeconds) } else { 30 }
    $networkRetrySeconds = 0
    # Wraps each automatic-refresh call: a trigger failure is logged, and the
    # loop carries on exactly as if the trigger were absent.
    $invokeTrigger = {
        param([string]$Site, [scriptblock]$Call)
        try {
            if (-not (Import-OuterRefreshTriggerModule)) { return $null }
            return (& $Call)
        } catch {
            Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.refresh_trigger_call_failed' -Arguments @{ site = $Site; message = "$($_.Exception.Message)" })
            return $null
        }
    }
    # Cycles that run in their own process deliver at their end; the resident
    # adds the cadence between them. An in-process cycle needs neither.
    if ($State.ContainsKey('CycleScript') -and $State.CycleScript) { $script:OuterWaitTickState = $State }
    while (-not $State.ShutdownState['Requested']) {
        if ((Wait-DiagnosticVmPreservation -ShutdownState $State.ShutdownState -ConfigPath $State.ConfigPath) -eq 'shutdown') { break }
        $cycle++
        $State['OuterCycleCounter'] = $cycle
        $State['CycleGeneration'] = "$($State['RunnerInstanceId']):$cycle"

        # Taken before the dispatch, not inside it: the fault path below uses it
        # to ask whether the inner saved its gating counters during THIS cycle,
        # and a mark that is slightly early can only misread a save as belonging
        # to this cycle -- never a previous cycle's save as this one's.
        $cycleSpawnedAtUtc = [DateTime]::UtcNow
        $cycleResult = Invoke-OuterCycleDispatch -State $State -Cycle $cycle
        $outcome  = $cycleResult.Outcome
        $exitCode = $cycleResult.ExitCode
        $null = Write-OuterCyclePhase -Cycle $cycle -Outcome ([string]$outcome) -ExitCode ([int]$exitCode) -StartedAtUtc $cycleSpawnedAtUtc
        # The pool's testCycle override as the last cycle saw it: a pool can turn
        # automatic recovery on or off for its members.
        if ($cycleResult.PSObject.Properties['RecordPoolTestCycle'] -and $cycleResult.RecordPoolTestCycle -is [System.Collections.IDictionary]) {
            $State['PoolTestCycleOverride'] = $cycleResult.RecordPoolTestCycle
        }
        # How the cycle went, in the one shape every entry point reports. Recorded
        # before anything reacts to it, so the file describes the cycle even when
        # the reaction fails. $null for an outcome that is not a verdict.
        $recoveryResult = Publish-OuterRecoveryResult -Dispatch $cycleResult -CycleGeneration ([string]$State['CycleGeneration']) -SpawnedAtUtc $cycleSpawnedAtUtc
        # See Update-OuterFrameworkHealth: a framework that kills its own cycle
        # process before the pull can only be repaired from this process.
        # Read once: the fault record below names the commit that ran, even when a
        # rescue pull has moved the checkout since.
        $dispatchCommitSha = [string](Get-OuterCommitSha -RepoRoot $State.RepoRoot)
        $frameworkHealth = $null
        if ($env:YURUNA_RUNTIME_DIR) {
            $fromRecord = [bool]($cycleResult.PSObject.Properties['FromRecord'] -and $cycleResult.FromRecord)
            $frameworkHealth = Update-OuterFrameworkHealth -RuntimeDir $env:YURUNA_RUNTIME_DIR -RepoRoot $State.RepoRoot `
                -Outcome ([string]$outcome) -FromRecord:$fromRecord -Sha $dispatchCommitSha -Confirm:$false
            if ($frameworkHealth.RescueDue) {
                $null = Invoke-OuterFrameworkRescue -State $State -Health $frameworkHealth -Cycle $cycle -SpawnedAtUtc $cycleSpawnedAtUtc `
                    -Outcome ([string]$outcome) -ExitCode ([int]$exitCode) -Confirm:$false
            }
        }

        # A preserved guest must survive automatic refresh, recovery, and the
        # next cycle's stale-VM sweep even when repository revisions change.
        if ((Wait-DiagnosticVmPreservation -ShutdownState $State.ShutdownState -ConfigPath $State.ConfigPath `
            -HoldOnFailure:($outcome -eq 'completed' -and $exitCode -ne 0 -and $exitCode -ne (Get-DegradedCycleExitCode))) -eq 'shutdown') { break }

        # Evidence accounting for the automatic refresh decision: every outcome
        # consumes this cycle's evidence sidecar; only a completed one counts.
        $refreshAccounting = & $invokeTrigger 'evidence' {
            Update-HostRefreshAutoEvidence -RuntimeDir $env:YURUNA_RUNTIME_DIR -Generation $State['CycleGeneration'] -Outcome $outcome -Confirm:$false
        }

        if ($outcome -eq 'drain') {
            Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_5e1b22dd0ff54c65' -Arguments @{ cycle = "$cycle" })
            $null = & $invokeTrigger 'pool-drain' {
                Stop-HostRefreshAutoQueuedRequest -Reason pool-drain -Cycle $cycle -Confirm:$false
            }
            $State.ShutdownState['Requested'] = $true
            break
        }

        # --- REGION: Host-refresh outcomes
        # A held cycle is neither a pass nor a failure: no fault state, no
        # crash gating, no streak and no failure pause -- only a short,
        # interruptible hold, logged once per change of what holds it.
        if ($outcome -eq 'refresh-gated') {
            $auto = & $invokeTrigger 'decision-gated' {
                Invoke-HostRefreshAutoDecision -State $State -Cycle $cycle -Branch gated -Accounting $refreshAccounting -Confirm:$false
            }
            if ($auto -and $auto.Handoff) {
                $State['RefreshHandoff'] = $auto.Handoff
                continue
            }
            $holdGate = Complete-OuterExpiredResidentHandoff -State $State -Cycle $cycle -Gate $cycleResult.Gate
            Write-OuterRefreshGateHold -State $State -Cycle $cycle -Gate $holdGate
            $null = Wait-OuterInterruptible -Seconds $gateHoldSeconds -ShutdownState $State.ShutdownState
            continue
        }
        if ($State.ContainsKey('RefreshGateLogged') -and $State['RefreshGateLogged']) {
            $releasedLine = Format-YurunaOperatorMessage -Key 'runner.refresh_gate_released' -Arguments @{ cycle = "$cycle" }
            Write-Output $releasedLine
            Write-OuterLog $releasedLine
            $State['RefreshGateLogged'] = $null
        }
        # The preflight chain of a handoff exited. A resident outer verifies
        # the acknowledgment against the cycle it spawned and leaves the gate
        # itself; for a restarted runner the repair worker does both. Success
        # arms the barrier for the next, ordinary, cycle; a failed preflight
        # keeps the handoff pending and holds, so no inner starts into the
        # same fault.
        if ($outcome -eq 'refresh-preflight') {
            # The handoff as the gate validated it at dispatch; the caller's
            # handoff record may lack its purpose.
            $handoff = if ($cycleResult.PSObject.Properties['Handoff']) { $cycleResult.Handoff } else { $null }
            $preflightOk = ($exitCode -eq 0)
            if ($handoff -and $handoff.Purpose -eq 'resident-outer') {
                $completion = Invoke-OuterRefreshResidentCompletion -Handoff $handoff -Cycle $cycle -ExitCode $exitCode -CycleIdentity $cycleResult.Cycle
                $preflightOk = [bool]$completion.Ready
            }
            if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
                $null = Set-RunnerState -To 'cycle-end' -Reason "refresh preflight exited $exitCode" -Confirm:$false
                $null = Set-RunnerState -To 'idle'      -Reason 'refresh preflight complete' -Confirm:$false
            }
            if ($preflightOk) {
                $State['RefreshHandoff'] = $null
                $State['RefreshBarrierRequestId'] = if ($handoff -and $handoff.RequestId) { $handoff.RequestId } else { 'unknown' }
                continue
            }
            Write-OuterRefreshGateHold -State $State -Cycle $cycle -Gate $null
            $null = Wait-OuterInterruptible -Seconds $gateHoldSeconds -ShutdownState $State.ShutdownState
            continue
        }
        # The barrier belongs to the first ordinary cycle only.
        if ($outcome -eq 'completed' -and $State.ContainsKey('RefreshBarrierRequestId') -and $State['RefreshBarrierRequestId']) {
            $State['RefreshBarrierRequestId'] = $null
        }
        # See https://yuruna.link/4213a0b3-0117
        if ($outcome -in @('pull-error','paused','spawn-failed','cycle-aborted')) {
            if ($outcome -eq 'pull-error' -and $env:YURUNA_RUNTIME_DIR) {
                $updateReason = if ($recoveryResult -and $recoveryResult.reason) { [string]$recoveryResult.reason } else { Get-LastOuterPullFailure }
                $updateClass = if ($recoveryResult -and $recoveryResult.failureClass) { [string]$recoveryResult.failureClass } else { 'bootstrap_sync' }
                $updateEvidence = @{
                    stage = 'FrameworkPull'
                    description = $updateReason
                    frameworkCommitSha = Get-OuterCommitSha -RepoRoot $State.RepoRoot
                }
                $null = Update-RunnerFaultStatus -RuntimeDir $env:YURUNA_RUNTIME_DIR -RunnerState 'paused' `
                    -FailureClass $updateClass -Reason $updateReason -AttemptEvidence $updateEvidence `
                    -AttemptGeneration ([string]$State['CycleGeneration']) -SpawnedAtUtc $cycleSpawnedAtUtc -ExitCode 1 -Confirm:$false
                Write-OuterLog "[FrameworkPull] $updateClass`: $updateReason"
                if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
                    $null = Set-RunnerState -To 'paused' -Reason 'framework update failed; waiting to retry' -Confirm:$false
                }
            }
            # A host that cannot pull or start a cycle holds longer on each try in a
            # row, and a cycle process that never started is a runner fault the
            # pool can see, as a failed pull already is.
            if ($outcome -in @('pull-error', 'spawn-failed')) { $State['NonVerdictStreak'] = 1 + [int]$State['NonVerdictStreak'] }
            if ($outcome -eq 'spawn-failed' -and $env:YURUNA_RUNTIME_DIR) {
                $null = Update-RunnerFaultStatus -RuntimeDir $env:YURUNA_RUNTIME_DIR -RunnerState 'paused' `
                    -FailureClass 'cycle_spawn_failed' -Reason 'the cycle process could not be started' `
                    -AttemptEvidence @{ stage = 'CycleSpawn'; description = 'the cycle process could not be started' } `
                    -AttemptGeneration ([string]$State['CycleGeneration']) -SpawnedAtUtc $cycleSpawnedAtUtc -ExitCode 1 -Confirm:$false
            }
            # A framework pull that fails on a stale git lock is repaired and retried
            # at once; left alone it fails the same way after every hold.
            if ($outcome -eq 'pull-error' -and $recoveryResult) {
                $pullRecovery = Invoke-OuterRecovery -Result $recoveryResult -State $State
                if ($pullRecovery.SkipFailurePause) {
                    Write-OuterRecoveryApplied -Cycle $cycle -Recovery $pullRecovery -Result $recoveryResult
                    continue
                }
            }
            $holdSeconds = switch ($outcome) {
                'pull-error'    { Get-OuterRetryHoldSeconds -BaseSeconds $State.OuterPullErrorSleepSeconds -Streak ([int]$State['NonVerdictStreak']) }
                'spawn-failed'  { Get-OuterRetryHoldSeconds -BaseSeconds $State.InnerSpawnErrorSleepSeconds -Streak ([int]$State['NonVerdictStreak']) }
                'cycle-aborted' {
                    $abortStreak = if ($frameworkHealth) { [math]::Max(1, [int]$frameworkHealth.Streak) } else { 1 }
                    Get-OuterRetryHoldSeconds -BaseSeconds $State.InnerSpawnErrorSleepSeconds -Streak $abortStreak
                }
                default         { 30 }
            }
            $null = Wait-OuterInterruptible -Seconds $holdSeconds -ShutdownState $State.ShutdownState
            continue
        }
        $State['NonVerdictStreak'] = 0
        # One console line per finished cycle. Between the startup banner and
        # the next failure pause the runner is otherwise silent for the whole
        # cycle, leaving an operator watching the terminal with nothing to
        # correlate against the dashboard. Printed before the pass/fail branch
        # so both verdicts get one; 'shutdown' is excluded because its cycle
        # was killed rather than finished and has no verdict to report.
        if ($outcome -eq 'completed') {
            $summaryLine = Get-OuterCycleSummaryLine -ConfigPath $State.ConfigPath -ExitCode $exitCode -ArgList $State.ArgList
            if ($summaryLine) {
                Write-Output $summaryLine
                Write-OuterLog $summaryLine
            }
        }
        # A cycle that failed nothing but skipped a planned guest: no fault and
        # no failure pause, and none of a pass's effects either -- no repair
        # budget re-armed and no success for the automatic refresh decision,
        # because the skipped guest proves nothing.
        if ($outcome -eq 'completed' -and $exitCode -eq (Get-DegradedCycleExitCode)) {
            $networkRetrySeconds = 0
            if ($env:YURUNA_RUNTIME_DIR) {
                $null = Get-RunnerPreambleStallStreak -RuntimeDir $env:YURUNA_RUNTIME_DIR -StalledPhase '' -Confirm:$false
            }
            if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
                $null = Set-RunnerState -To 'cycle-end' -Reason "inner exited $exitCode (degraded)" -Confirm:$false
                $null = Set-RunnerState -To 'idle'      -Reason 'cycle skipped a planned guest' -Confirm:$false
            }
            Write-OuterLog "[outer cycle $cycle] the cycle failed nothing but skipped a planned guest; no fault, and repair budgets stay as they were"
            continue
        }
        if ($exitCode -eq 0) {
            $networkRetrySeconds = 0
            if ($outcome -eq 'completed' -and $env:YURUNA_RUNTIME_DIR) {
                $null = Get-RunnerPreambleStallStreak -RuntimeDir $env:YURUNA_RUNTIME_DIR -StalledPhase '' -Confirm:$false
            }
            # 3a. Success -- next iteration pulls and respawns
            # immediately. State machine: in-cycle -> cycle-end ->
            # idle. Both transitions are emitted so a streaming
            # consumer sees the clean closure explicitly rather than
            # inferring it from the absence of a fault event.
            if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
                $null = Set-RunnerState -To 'cycle-end' -Reason "inner exited 0" -Confirm:$false
                $null = Set-RunnerState -To 'idle'      -Reason "cycle complete"  -Confirm:$false
            }
            # A passing cycle re-arms every repair budget: the ledger counts attempts
            # since the last pass, so this is what ends a streak.
            # A host that never repaired anything has no ledger and gets none from a pass.
            # A cycle that skipped a quarantined guest exits 0 without testing it,
            # and proves no repair worked, so it re-arms nothing.
            if ($recoveryResult -and $recoveryResult['outcome'] -ceq 'passed' -and $env:YURUNA_RUNTIME_DIR -and
                (Test-Path -LiteralPath (Get-RecoveryLedgerPath -RuntimeDir $env:YURUNA_RUNTIME_DIR) -PathType Leaf)) {
                if (Test-OuterCycleSkippedGuest -RuntimeDir $env:YURUNA_RUNTIME_DIR) {
                    Write-OuterLog "[outer cycle $cycle] the cycle skipped a quarantined guest; repair budgets stay as they were"
                } else {
                    $null = Complete-RecoveryFingerprint -RuntimeDir $env:YURUNA_RUNTIME_DIR -Generation ([string]$State['CycleGeneration'])
                }
            }
            if ($outcome -eq 'completed') {
                $auto = & $invokeTrigger 'decision-success' {
                    Invoke-HostRefreshAutoDecision -State $State -Cycle $cycle -Branch success -Accounting $refreshAccounting -Confirm:$false
                }
                if ($auto -and $auto.Handoff) { $State['RefreshHandoff'] = $auto.Handoff }
            }
            continue
        }

        # What the fault records. A cycle whose outcome nothing recorded names
        # that, because "inner exited N" would send an operator after the tests
        # for a fault in the reporting path.
        $faultReason = "inner exited $exitCode"
        $faultClass  = ''
        if ($outcome -eq 'outcome-unrecorded') {
            $unrecordedWhy = if ($cycleResult.PSObject.Properties['OutcomeReason']) { [string]$cycleResult.OutcomeReason } else { 'unknown' }
            $faultReason = "cycle outcome unrecorded ($unrecordedWhy); child exited $exitCode"
            $faultClass  = 'outcome_unrecorded'
            if ($unrecordedWhy -ceq 'cycle-ceiling') {
                $faultReason = [string]$cycleResult.OutcomeDetail
                $faultClass  = 'cycle_killed'
            } elseif ($unrecordedWhy -ceq 'resident-watchdog') {
                # The stop record names wait_timeout or preamble_stall and the
                # phase, exactly as a watchdog stop would; the attempt fault below
                # reads both from it.
                $faultReason = [string]$cycleResult.OutcomeDetail
                $faultClass  = ''
            }
        } elseif ($outcome -eq 'no-cycle-result') {
            # The cycle returned without a verdict to record. Publish-CycleOutcomeRecord
            # recorded that as a failure, so the exit code alone would read as a
            # test failure.
            $faultReason = "the cycle returned no result; child exited $exitCode"
            $faultClass  = 'outcome_unrecorded'
        } elseif ($outcome -eq 'config-gate-failed') {
            $faultReason = "configuration gate refused to start; inner exited $exitCode"
            $faultClass = 'config_gate_failed'
        } elseif ($outcome -eq 'completed') {
            # An inner that refused to start on a host it could not show to be
            # free of other guests exits with a bare code. It leaves the reason in
            # vm-admission.json; naming it here keeps the fault from reading as a
            # test failure.
            $refusal = Read-VmAdmissionRecord -RuntimeDir $env:YURUNA_RUNTIME_DIR -NotBeforeUtc $cycleSpawnedAtUtc
            if ($refusal) {
                $faultReason = "VM admission $($refusal.State) ($($refusal.Reason)); inner exited $exitCode"
                $faultClass  = "vm_admission_$($refusal.State)"
            }
        }

        $faultCommitSha = $dispatchCommitSha

        # State machine: in-cycle -> fault. The transition lands BEFORE
        # the failure-pause loop so a dashboard sees "fault" the moment
        # the inner exits non-zero; the subsequent fault -> paused
        # transition at the start of the pause loop makes the long
        # wait explicit.
        if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
            $null = Set-RunnerState -To 'fault' -Reason $faultReason -Confirm:$false
        }

        # --- REGION: Accounting an inner that was killed rather than exited
        # Everything below runs because the inner may be gone without having
        # closed its own books. The runner state stream already showed the
        # fault; these carry it into the three places an operator or a
        # dashboard actually looks.
        $attemptFault = @{ Evidence = $null; IsCrash = $true }
        $stalledPhase    = ''
        $stallStreak     = 0
        $pauseMultiplier = 1
        if ($env:YURUNA_RUNTIME_DIR -and $outcome -ne 'storage-full') {
            $attemptFault = Get-RunnerAttemptFault -RuntimeDir $env:YURUNA_RUNTIME_DIR `
                -AttemptGeneration ([string]$State['CycleGeneration']) -SpawnedAtUtc $cycleSpawnedAtUtc -ExitCode $exitCode
            if ($faultClass -eq 'config_gate_failed') { $attemptFault.IsCrash = $false }
            $stalledPhase = [string]$attemptFault.StalledPhase
            if (-not $faultClass -and $attemptFault.FailureClass) { $faultClass = [string]$attemptFault.FailureClass }
            if ($stalledPhase) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_4a7854989ba0a6a4' -Arguments @{ cycle = "$cycle"; stalledPhase = "$stalledPhase" })
                Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_ece5a6e7520a60f5' -Arguments @{ cycle = "$cycle"; stalledPhase = "$stalledPhase"; exitCode = "$exitCode" })
            }
            $stall = Get-RunnerPreambleStallStreak -RuntimeDir $env:YURUNA_RUNTIME_DIR -StalledPhase $stalledPhase -Confirm:$false
            $stallStreak     = [int]$stall.Streak
            $pauseMultiplier = [int]$stall.Multiplier
            $cycleConfig = $null
            if (Get-Command Read-TestConfig -ErrorAction SilentlyContinue) {
                try { $cycleConfig = Read-TestConfig -Path $State.ConfigPath -LastGoodOnError } catch { $null = $_ }
            }
            $gating = Update-RunnerCrashGating -RuntimeDir $env:YURUNA_RUNTIME_DIR `
                -SpawnedAtUtc $cycleSpawnedAtUtc -Config $cycleConfig -Cycle $cycle -ExitCode $exitCode `
                -StalledPhase $stalledPhase -StallStreak $stallStreak -FailureClass $faultClass -IsCrash ([bool]$attemptFault.IsCrash) -Confirm:$false
            if ($gating.Updated) {
                Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_d843d4f8b87a6337' -Arguments @{ cycle = "$cycle"; consecutiveCrashes = "$($gating.ConsecutiveCrashes)"; consecutiveFailures = "$($gating.ConsecutiveFailures)"; alerted = "$($gating.Alerted)" })
            }
            $null = Update-RunnerFaultStatus -RuntimeDir $env:YURUNA_RUNTIME_DIR -RunnerState 'fault' `
                -Reason $faultReason -StalledPhase $stalledPhase -FailureClass $faultClass `
                -AttemptGeneration ([string]$State['CycleGeneration']) -SpawnedAtUtc $cycleSpawnedAtUtc `
                -FrameworkCommitSha $faultCommitSha -ExitCode $exitCode -AttemptEvidence $attemptFault.Evidence -Confirm:$false
        }

        # Automatic host refresh, after the streak and crash accounting and
        # before the failure pause. A handoff continues straight to the
        # preflight dispatch; a repaired host skips the pause.
        if ($outcome -eq 'completed') {
            $auto = & $invokeTrigger 'decision-failure' {
                Invoke-HostRefreshAutoDecision -State $State -Cycle $cycle -Branch failure -Accounting $refreshAccounting -Confirm:$false
            }
            if ($auto -and $auto.Handoff) {
                $State['RefreshHandoff'] = $auto.Handoff
                if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
                    $null = Set-RunnerState -To 'idle' -Reason 'host refresh handoff pending' -Confirm:$false
                }
                continue
            }
            if ($auto -and $auto.SkipFailurePause) {
                if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
                    $null = Set-RunnerState -To 'idle' -Reason 'automatic host refresh repaired the host' -Confirm:$false
                }
                $skipLine = Format-YurunaOperatorMessage -Key 'runner.host_refresh_auto_pause_skipped' -Arguments @{ cycle = "$cycle" }
                Write-Information $skipLine -InformationAction Continue
                Write-OuterLog $skipLine
                continue
            }
        }

        # Re-ensure the status service before pausing after a watchdog stop.
        # See https://yuruna.link/42e220c4-0008
        $refreshAllowsEnsure = (-not (Get-Command Test-YurunaRefreshSpawnAllowed -ErrorAction SilentlyContinue)) -or
            (Test-YurunaRefreshSpawnAllowed -RuntimeDir $env:YURUNA_RUNTIME_DIR)
        # A held gate normally holds this ensure too: a live worker may be
        # mid-repair, deliberately stopping or restarting the listener. An
        # orphaned gate -- owner provably dead or recycled, no live handoff
        # token -- has no such worker, and a down status service would cut
        # off the dashboard carrying the unresolved request's resume
        # controls, leaving a remote operator no way to see or relaunch it.
        # The hold on cycle dispatch stands either way.
        if (-not $refreshAllowsEnsure -and (Get-Command Get-YurunaRefreshGateState -ErrorAction SilentlyContinue)) {
            $ensureGate = Get-YurunaRefreshGateState -RuntimeDir $env:YURUNA_RUNTIME_DIR
            if ($ensureGate.Orphaned) {
                $refreshAllowsEnsure = $true
                Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.refresh_status_ensure_orphaned' -Arguments @{ cycle = "$cycle"; requestId = "$($ensureGate.RequestId)"; state = "$($ensureGate.State)" })
            }
        }
        if (-not $refreshAllowsEnsure) {
            Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.refresh_status_ensure_skipped' -Arguments @{ cycle = "$cycle" })
        }
        try {
            if ($refreshAllowsEnsure -and -not (Test-OuterNoStatusServiceForwarded -ArgList $State.ArgList) -and
                (Get-Command Resolve-StatusServiceStart -ErrorAction SilentlyContinue) -and
                (Get-Command Read-TestConfig -ErrorAction SilentlyContinue)) {
                $ensureStartScript = Join-Path $State.RepoRoot 'test/service/Start-StatusService.ps1'
                if (Test-Path -LiteralPath $ensureStartScript) {
                    $ensureCfg      = Read-TestConfig -Path $State.ConfigPath -LastGoodOnError
                    $ensureDecision = Resolve-StatusServiceStart -Config $ensureCfg
                    if ($ensureDecision.ShouldStart) { & $ensureStartScript -Port $ensureDecision.Port }
                }
            }
        } catch {
            Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_1e450b2204f014ac' -Arguments @{ cycle = "$cycle"; message = "$($_.Exception.Message)" })
        }

        # Bounded repairs for this failure (default off). A repair that applied and
        # allows it replaces the failure pause: the next cycle is its proof, and the
        # ledger has already counted the attempt. The pause shortcut is left out of
        # this round; it fires inside the pause, below.
        if ($recoveryResult) {
            $failureRecovery = Invoke-OuterRecovery -Result $recoveryResult -State $State -ExcludeAction @('end_failure_pause_early', 'end_failure_pause_on_probe')
            if ($failureRecovery.SkipFailurePause) {
                if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
                    $null = Set-RunnerState -To 'idle' -Reason "recovery action $($failureRecovery.Action) applied" -Confirm:$false
                }
                Write-OuterRecoveryApplied -Cycle $cycle -Recovery $failureRecovery -Result $recoveryResult
                continue
            }
        }

        # See https://yuruna.link/4213a0b3-0118
        $baselineSha         = Get-OuterCommitSha -RepoRoot $State.RepoRoot
        # Compare remote observations, not a local-only commit, so a stable
        # upstream never shortens every failure pause indefinitely.
        if (-not $State.NoGitPull) {
            $trackingSha = & git -C $State.RepoRoot rev-parse '@{u}' 2>$null
            if ($LASTEXITCODE -eq 0 -and $trackingSha) { $baselineSha = ([string]$trackingSha).Trim() }
        }
        $baselineProjectUrl  = Get-OuterProjectUrl -ConfigPath $State.ConfigPath
        $networkGateOnly = $faultClass -eq 'config_gate_failed' -and
            (Test-RunnerConfigGateNetworkOnly -Gate $attemptFault.Evidence.structuredResult)
        $baselineProjectSha  = if ($baselineProjectUrl -and -not $networkGateOnly) { Get-OuterRemoteSha -RemoteUrl $baselineProjectUrl -ConfigPath $State.ConfigPath } else { $null }
        $baselineConfigMtime = Get-OuterConfigMtime -ConfigPath $State.ConfigPath
        # The pause runs on a monotonic clock, in seconds from its start: a
        # daylight-saving change or a clock correction moves Get-Date, which
        # would cut the pause short or stretch it by an hour.
        $pauseStart  = Get-OuterMonotonicTime
        $pauseElapsed = { (Get-OuterMonotonicTime) - $pauseStart }
        # A repeated stall in the same preamble phase widens the pause. The
        # triggers that end it early -- a commit, a config edit, an operator
        # restart -- all still apply, so widening costs nothing when somebody
        # is acting on it and saves a wedged host from re-running the same
        # ten-minute kill on the hour, every hour, with no one watching.
        $pauseSeconds = [int]$State.FailurePauseMaxSeconds
        if ($pauseMultiplier -gt 1) { $pauseSeconds = $pauseSeconds * $pauseMultiplier }
        if ($networkGateOnly) {
            $networkRetrySeconds = [int][math]::Min($networkRetryCap, $(if ($networkRetrySeconds -gt 0) { 2L * $networkRetrySeconds } else { $networkRetryBase }))
            $pauseSeconds = $networkRetrySeconds
        }
        $pollSeconds = if ($networkGateOnly) { $networkPollSeconds } else { $State.FailureCommitPollSeconds }
        $earlyEndAfter = Get-OuterEarlyEndHoldSeconds -PollSeconds ([int]$pollSeconds) -RuntimeDir $env:YURUNA_RUNTIME_DIR `
            -Fingerprint $(if ($recoveryResult) { [string]$recoveryResult['fingerprint'] } else { '' })
        $nextNetworkPoll = $pollSeconds
        $nextSourcePoll = $pollSeconds
        $deadline    = $pauseSeconds
        $projectWatchMsg = if ($baselineProjectUrl) { "framework + project ($baselineProjectUrl) + local config" } else { "framework + local config (no repositories.projectUrl)" }
        $stallNote = if ($stalledPhase -and $stallStreak -gt 1) {
            " This is stall $stallStreak in a row in preamble phase '$stalledPhase' -- the condition is on the host, not in the code being tested, so a retry alone will not clear it."
        } else { '' }
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_74c3544549a9406c' -Arguments @{ cycle = "$cycle"; pauseSeconds = "$([int]($pauseSeconds / 60))"; projectWatchMsg = "$projectWatchMsg"; failureCommitPollSeconds = "$($State.FailureCommitPollSeconds / 60)"; stallNote = "$stallNote" })
        Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_15a8a0db03dd67cb' -Arguments @{ cycle = "$cycle"; pauseSeconds = "$([int]($pauseSeconds / 60))"; projectWatchMsg = "$projectWatchMsg"; stallNote = "$stallNote" })
        # Progress bar: tracks elapsed time toward the failure-pause
        # cap (or earlier break-out when a trigger fires). Updated on
        # every 5-second slice so the bar advances ~1.4%/tick and the
        # operator sees forward motion instead of a silent terminal.
        # -Id is fixed so we only ever own one progress row;
        # -Completed in the finally clears it cleanly when the loop
        # exits via any path (success, cap, Ctrl+C, exception).
        $progressId = 1
        $pauseStartedUtc = [DateTime]::UtcNow
        # The shortcut below is decided once per pause: a spent budget would
        # otherwise be written to the ledger again on every poll tick.
        $pauseRecoveryDone = $false
        # A host condition that clears on its own ends the pause once its
        # registered probe (Test.RecoveryProbe) says so. The probe runs in a
        # short-lived process at most once per its interval, and only while
        # automatic recovery is on.
        $probeClass = if ($recoveryResult -and $recoveryResult['failureClass']) { [string]$recoveryResult['failureClass'] } else { [string]$faultClass }
        $pauseProbe = if (Get-Command Get-RecoveryProbe -ErrorAction SilentlyContinue) { Get-RecoveryProbe -FailureClass $probeClass } else { $null }
        $nextProbeAt = if ($pauseProbe) { [int]$pauseProbe.IntervalSeconds } else { 0 }
        # State machine: fault -> paused. The pause loop polls the
        # framework + project + config-mtime triggers; this transition
        # makes the waiting state explicit on the NDJSON stream.
        if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
            $null = Set-RunnerState -To 'paused' -Reason "failure-pause begin" -Confirm:$false
        }
        if ($env:YURUNA_RUNTIME_DIR) {
            $null = Update-RunnerFaultStatus -RuntimeDir $env:YURUNA_RUNTIME_DIR -RunnerState 'paused' `
                -Reason "failure-pause begin ($faultReason)" -StalledPhase $stalledPhase -FailureClass $faultClass `
                -AttemptGeneration ([string]$State['CycleGeneration']) -SpawnedAtUtc $cycleSpawnedAtUtc `
                -FrameworkCommitSha $faultCommitSha -ExitCode $exitCode -AttemptEvidence $attemptFault.Evidence -Confirm:$false
        }
        try {
            while ((& $pauseElapsed) -lt $deadline -and -not $State.ShutdownState['Requested']) {
                $remainingPoll = if ($networkGateOnly) {
                    [int][math]::Max(0, [math]::Ceiling($nextNetworkPoll - (& $pauseElapsed)))
                } else { [int][math]::Max(0, [math]::Ceiling($nextSourcePoll - (& $pauseElapsed))) }
                while ($remainingPoll -gt 0 -and -not $State.ShutdownState['Requested']) {
                    $slice = [math]::Min(5, [math]::Min($remainingPoll, [math]::Max(0, [math]::Ceiling($deadline - (& $pauseElapsed)))))
                    if ($slice -le 0) { break }
                    Start-Sleep -Seconds $slice
                    $remainingPoll -= $slice
                    $remainingSeconds = [math]::Max(0, [int]($deadline - (& $pauseElapsed)))
                    $elapsedSeconds   = [int](& $pauseElapsed)
                    # Against the pause actually being served, not the configured
                    # one: a widened pause measured against the base length would
                    # sit at 100% for most of its duration and stop meaning anything.
                    $percent      = [math]::Min(100, [math]::Max(0, [int](($elapsedSeconds * 100) / $pauseSeconds)))
                    $remainingMinutes = [math]::Round($remainingSeconds / 60, 1)
                    # Hardened the same way Wait-WithProgress draws its bar:
                    # Write-Progress throws on tmux/sshd PTYs without a
                    # resolvable TERM (the SetCursorPosition trap). Swallow
                    # the render failure so the pause keeps sleeping + polling
                    # silently instead of aborting the whole outer loop.
                    try {
                        Write-Progress -Id $progressId `
                            -Activity (Format-YurunaOperatorMessage -Key 'runner.operator_0ce5a4fff60dfcfb' -Arguments @{ cycle = "$cycle" }) `
                            -Status  (Format-YurunaOperatorMessage -Key 'runner.operator_c9561b5025849618' -FormatValues ($remainingMinutes, $remainingPoll) -FormatBindings @{ remainingMinutes = '0'; remainingPoll = '1' }) `
                            -PercentComplete $percent `
                            -SecondsRemaining $remainingSeconds
                    } catch { $null = $_ }
                }
                if ($State.ShutdownState['Requested']) { break }
                if ($networkGateOnly -and (& $pauseElapsed) -lt $deadline) {
                    $probeStart = & $pauseElapsed
                    $nextNetworkPoll = $probeStart + $pollSeconds
                    $probeSeconds = [math]::Min($nextNetworkPoll, $deadline) - $probeStart
                    if (Test-OuterRepositoryAccess -RepoRoot $State.RepoRoot -ConfigPath $State.ConfigPath -DeadlineUtc ([datetime]::UtcNow.AddSeconds($probeSeconds)) -NoGitPull:([bool]$State.NoGitPull)) {
                        $networkRetrySeconds = 0
                        Write-Verbose 'Repository access recovered; ending the transient network hold.'
                        break
                    }
                }
                $sourcePollDeadline = [datetime]::UtcNow.AddSeconds(30)
                $nextSourcePoll = (& $pauseElapsed) + $pollSeconds
                # Trigger 1: framework repo new commit.
                if (-not $networkGateOnly -and -not $State.NoGitPull -and $baselineSha -and (Test-OuterNewCommitsAvailable -RepoRoot $State.RepoRoot -BaselineSha $baselineSha -ConfigPath $State.ConfigPath -DeadlineUtc $sourcePollDeadline)) {
                    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_c35b2e556a3ef075' -Arguments @{ cycle = "$cycle" })
                    Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_0211ffdf400b40cc' -Arguments @{ cycle = "$cycle" })
                    break
                }
                # Trigger 2: project repo new commit. ls-remote returns
                # $null on network failure; require a non-null current
                # AND a non-null baseline so a transient failure on
                # either side doesn't fire spuriously, and don't fire
                # when repositories.projectUrl wasn't set in the first
                # place.
                if ($baselineProjectUrl -and -not $networkGateOnly) {
                    $currentProjectSha = Get-OuterRemoteSha -RemoteUrl $baselineProjectUrl -ConfigPath $State.ConfigPath -DeadlineUtc $sourcePollDeadline
                    if ($currentProjectSha -and $baselineProjectSha -and ($currentProjectSha -ne $baselineProjectSha)) {
                        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_f36d5a5f1ae6cebb' -Arguments @{ cycle = "$cycle"; baselineProjectUrl = "$baselineProjectUrl" })
                        Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_3fa87fe4f05bcb17' -Arguments @{ cycle = "$cycle"; baselineProjectUrl = "$baselineProjectUrl"; baselineProjectSha = "$baselineProjectSha"; currentProjectSha = "$currentProjectSha" })
                        break
                    }
                }
                # Trigger 3: local test.config.yml edit (mtime change
                # OR file appearing/disappearing relative to the
                # baseline). Comparing nullable datetimes with -ne
                # handles all three transitions (changed / created /
                # deleted) in one shot.
                $currentConfigMtime = Get-OuterConfigMtime -ConfigPath $State.ConfigPath
                if ($currentConfigMtime -ne $baselineConfigMtime) {
                    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_f3bed31426207a13' -Arguments @{ cycle = "$cycle"; configPath = "$($State.ConfigPath)" })
                    Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_f65549db90ed556f' -Arguments @{ cycle = "$cycle"; configPath = "$($State.ConfigPath)"; baselineConfigMtime = "$baselineConfigMtime"; currentConfigMtime = "$currentConfigMtime" })
                    break
                }
                # See https://yuruna.link/4213a0b3-0119
                $outerRestartFlag = Join-Path $env:YURUNA_RUNTIME_DIR 'control.cycle-restart'
                if (Test-Path -LiteralPath $outerRestartFlag) {
                    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_8b51a0ee51bec50b' -Arguments @{ cycle = "$cycle" })
                    Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_c571bbfec71823df' -Arguments @{ cycle = "$cycle" })
                    Remove-Item -LiteralPath $outerRestartFlag -Force -ErrorAction SilentlyContinue
                    break
                }
                if ($pauseProbe -and $recoveryResult -and (& $pauseElapsed) -ge $nextProbeAt) {
                    $nextProbeAt = (& $pauseElapsed) + [int]$pauseProbe.IntervalSeconds
                    $probeAuto = Get-OuterAutoRemediation -ConfigPath $State.ConfigPath -PoolTestCycleOverride (Get-OuterPoolPolicySnapshot -State $State)
                    if (-not $probeAuto.Enabled) {
                        $pauseProbe = $null
                    } else {
                        $probeRun = Invoke-RecoveryProbe -FailureClass $probeClass -RepoRoot $State.RepoRoot -ConfigPath $State.ConfigPath
                        Write-OuterLog "[outer cycle $cycle] recovery probe for ${probeClass}: $(if ($probeRun.Cleared) { 'cleared' } else { 'not cleared' }) ($($probeRun.Detail))"
                        if ($probeRun.Cleared) {
                            $probeDecision = Invoke-RecoveryAction -Name 'end_failure_pause_on_probe' `
                                -Context @{ Result = $recoveryResult; RuntimeDir = $env:YURUNA_RUNTIME_DIR; Probe = $probeRun } `
                                -RuntimeDir $env:YURUNA_RUNTIME_DIR -MaxAttempts ([int]$probeAuto.MaxAttempts)
                            Set-OuterRecoveryDecision -Result $recoveryResult -Decision $probeDecision
                            if ($probeDecision.Decision -eq 'applied') {
                                $probeLine = Format-YurunaOperatorMessage -Key 'runner.recovery_probe_cleared' -Arguments @{
                                    cycle = "$cycle"; failureClass = $probeClass; detail = [string]$probeRun.Detail
                                    attempt = "$($probeDecision.Attempt)"; maxAttempts = "$($probeAuto.MaxAttempts)" }
                                Write-Output $probeLine
                                Write-OuterLog $probeLine
                                if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
                                    Send-CycleEventSafely -EventRecord @{
                                        timestamp    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
                                        event        = 'auto_remediation_applied'
                                        failureClass = $probeClass
                                        action       = 'end_failure_pause_on_probe'
                                        attempt      = [int]$probeDecision.Attempt
                                        maxAttempts  = [int]$probeAuto.MaxAttempts
                                        attemptId    = [string]$probeDecision.AttemptId
                                    }
                                }
                                break
                            }
                            # A spent budget or a refusal stands for the rest of this pause.
                            $pauseProbe = $null
                        }
                    }
                }
                # See https://yuruna.link/4213a0b3-011a
                if ($recoveryResult -and -not $pauseRecoveryDone -and (& $pauseElapsed) -ge $earlyEndAfter) {
                    $autoRem = Get-OuterAutoRemediation -ConfigPath $State.ConfigPath -PoolTestCycleOverride (Get-OuterPoolPolicySnapshot -State $State)
                    if ($autoRem.Enabled) {
                        $pauseDecision = Invoke-RecoveryAction -Name 'end_failure_pause_early' `
                            -Context @{ Result = $recoveryResult; RuntimeDir = $env:YURUNA_RUNTIME_DIR } `
                            -RuntimeDir $env:YURUNA_RUNTIME_DIR -MaxAttempts ([int]$autoRem.MaxAttempts)
                        $pauseRecoveryDone = ($pauseDecision.Decision -ne 'applied')
                        Set-OuterRecoveryDecision -Result $recoveryResult -Decision $pauseDecision
                        if ($pauseDecision.Decision -eq 'applied') {
                            $failClass = [string]$recoveryResult['failureClass']
                            Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_0a5a75c08d9393f4' -Arguments @{ cycle = "$cycle"; failClass = "$failClass"; remediationAutoSkips = "$($pauseDecision.Attempt)"; maxAttempts = "$($autoRem.MaxAttempts)" })
                            Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_b767a43bc1c25bbd' -Arguments @{ cycle = "$cycle"; failClass = "$failClass"; remediationAutoSkips = "$($pauseDecision.Attempt)"; maxAttempts = "$($autoRem.MaxAttempts)" })
                            if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
                                Send-CycleEventSafely -EventRecord @{
                                    timestamp    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
                                    event        = 'auto_remediation_applied'
                                    failureClass = $failClass
                                    action       = 'end_failure_pause_early'
                                    attempt      = [int]$pauseDecision.Attempt
                                    maxAttempts  = [int]$autoRem.MaxAttempts
                                    attemptId    = [string]$pauseDecision.AttemptId
                                }
                            }
                            break
                        }
                    } else {
                        $pauseRecoveryDone = $true
                    }
                }
                $remainingMinutes = [math]::Max(0, [math]::Round(($deadline - (& $pauseElapsed)) / 60, 1))
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_eb8238e1e37a921c' -Arguments @{ cycle = "$cycle"; remainingMinutes = "${remainingMinutes}" })
            }
        } finally {
            # Dismiss the bar on every exit path (trigger, cap, Ctrl+C,
            # exception). Wrapped for the same render-failure reason as the
            # in-loop draw above; an unrenderable terminal must not turn loop
            # teardown into a thrown error.
            try { Write-Progress -Id $progressId -Activity 'failure-pause' -Completed } catch { $null = $_ }
            # The pause's length, whatever ended it: a host that pauses longer
            # each day shows it here before anyone reads the transcripts.
            if (Get-Command -Name Write-PerfPhaseRow -ErrorAction SilentlyContinue) {
                Write-PerfPhaseRow -Phase 'failure-pause' -StartedAtUtc $pauseStartedUtc -EndedAtUtc ([DateTime]::UtcNow) -Scope resident
            }
            # State machine: paused -> idle. The pause-loop exits via
            # any of: new framework commit, new project commit, config
            # edit, status-UI request, cap elapsed, or Ctrl+C. All are
            # "ready to try again" from the state machine's perspective.
            if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
                $null = Set-RunnerState -To 'idle' -Reason "failure-pause ended" -Confirm:$false
            }
        }
    }
}
function Write-OuterCyclePhase {
    <#
    .SYNOPSIS
        Record a dispatched cycle's wall time as the resident saw it, and check
        a passing one against the cycle-time budget learned from the passing
        cycles before it.
    .DESCRIPTION
        Report only: a passing cycle over its budget (Get-PerfCycleBudget) is a
        warning, an outer.log line and an overBudget field on its phase row,
        never a failed cycle -- a cycle-time regression otherwise passed green.
        The budget is read before the cycle's own row is written, so a cycle is
        judged by the ones before it. Without Test.Perf loaded nothing is
        recorded.
    .OUTPUTS
        [pscustomobject] Outcome (pass, fail, or the dispatch outcome),
        DurationMs, BudgetMs ($null until there is one), Samples, OverBudget;
        $null without Test.Perf.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Cycle,
        [AllowEmptyString()][string]$Outcome = '',
        [int]$ExitCode = 0,
        [Parameter(Mandatory)][DateTime]$StartedAtUtc,
        [DateTime]$EndedAtUtc = [DateTime]::UtcNow
    )
    if (-not (Get-Command -Name Write-PerfPhaseRow -ErrorAction SilentlyContinue)) { return $null }
    $phaseOutcome = if ($Outcome -ceq 'completed') { if ($ExitCode -eq 0) { 'pass' } else { 'fail' } } elseif ($Outcome) { $Outcome } else { 'unknown' }
    $verdict = [pscustomobject]@{
        Outcome = $phaseOutcome; DurationMs = [long][math]::Max(0, ($EndedAtUtc - $StartedAtUtc).TotalMilliseconds)
        BudgetMs = $null; Samples = 0; OverBudget = $false
    }
    $extra = [ordered]@{}
    if ($phaseOutcome -ceq 'pass' -and (Get-Command -Name Get-PerfCycleBudget -ErrorAction SilentlyContinue)) {
        try {
            $budget = Get-PerfCycleBudget -NowUtc $EndedAtUtc
            $verdict.Samples = [int]$budget.Samples
            if ($budget.BudgetMs) {
                $verdict.BudgetMs = [long]$budget.BudgetMs
                $extra.budgetMs = $verdict.BudgetMs
                if ($verdict.DurationMs -gt $verdict.BudgetMs) {
                    $verdict.OverBudget = $true
                    $extra.overBudget = $true
                    $line = Format-YurunaOperatorMessage -Key 'runner.cycle_over_budget' -Arguments @{
                        cycle = "$Cycle"; minutes = "$([math]::Round($verdict.DurationMs / 60000, 1))"
                        budgetMinutes = "$([math]::Round($verdict.BudgetMs / 60000, 1))"; samples = "$($verdict.Samples)" }
                    Write-Warning $line
                    Write-OuterLog $line
                }
            }
        } catch {
            Write-Verbose "Write-OuterCyclePhase: budget check failed (non-fatal): $($_.Exception.Message)"
        }
    }
    Write-PerfPhaseRow -Phase 'cycle' -StartedAtUtc $StartedAtUtc -EndedAtUtc $EndedAtUtc -Outcome $phaseOutcome -Scope resident -Extra $extra
    return $verdict
}

function Update-OuterFrameworkHealth {
    <#
    .SYNOPSIS
        Track whether the installed framework still produces cycle outcomes.
    .DESCRIPTION
        The framework pull runs inside the per-cycle process, after that process
        has imported the framework, so a commit that breaks the import also stops
        every later pull and the host never receives the fix. This record keeps
        the last framework commit whose cycle process produced a valid outcome
        record, and a streak of dispatches at the current commit that ended
        without one (cycle-aborted or outcome-unrecorded with no record behind
        it). RescueDue is set from
        the RescueAfter-th such dispatch on; the resident then pulls with its own,
        already loaded code (Invoke-OuterFrameworkRescue). spawn-failed and
        shutdown say nothing about the framework and leave the record unchanged.
        The record is file-backed so the streak survives a runner restart.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Outcome,
        # The outcome came from a valid record, so the cycle process imported the
        # framework and ran, whatever the outcome is called.
        [switch]$FromRecord,
        # The commit the dispatch ran; read from the checkout when omitted.
        [AllowEmptyString()][string]$Sha,
        [ValidateRange(1, 100)][int]$RescueAfter = 2
    )
    $path = Join-Path $RuntimeDir 'runner.framework-health.json'
    $health = @{ lastGoodSha = ''; lastGoodAtUtc = ''; streak = 0; streakSha = '' }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $parsed = Get-Content -Raw -LiteralPath $path -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            foreach ($name in @('lastGoodSha', 'lastGoodAtUtc', 'streakSha')) { if ($parsed[$name]) { $health[$name] = [string]$parsed[$name] } }
            if ($null -ne $parsed['streak']) { $health.streak = [int]$parsed['streak'] }
        } catch { Write-Verbose "Update-OuterFrameworkHealth: $path is unreadable ($($_.Exception.Message)); starting a new record." }
    }
    $sha = if ($PSBoundParameters.ContainsKey('Sha')) { $Sha } else { [string](Get-OuterCommitSha -RepoRoot $RepoRoot) }
    $unproven = -not $FromRecord -and $Outcome -cin @('cycle-aborted', 'outcome-unrecorded')
    $neutral = -not $FromRecord -and $Outcome -cin @('', 'shutdown', 'spawn-failed')
    if ($unproven) {
        if ($health.streakSha -cne $sha) { $health.streak = 0; $health.streakSha = $sha }
        $health.streak++
    } elseif (-not $neutral) {
        $health.lastGoodSha = $sha
        $health.lastGoodAtUtc = [datetime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        $health.streak = 0
        $health.streakSha = ''
    }
    if (-not $neutral -and $PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.framework_health_write_action'))) {
        $null = Initialize-RunnerStateWriter
        try {
            $null = Write-YurunaStateFileJson -Path $path -Depth 4 -Compress:$false -Confirm:$false -InputObject @{
                schemaVersion = 1; lastGoodSha = $health.lastGoodSha; lastGoodAtUtc = $health.lastGoodAtUtc
                streak = $health.streak; streakSha = $health.streakSha; lastOutcome = $Outcome
            }
        } catch { Write-Verbose "Update-OuterFrameworkHealth: save failed (best-effort): $($_.Exception.Message)" }
    }
    return [pscustomobject]@{
        Sha = $sha; LastGoodSha = $health.lastGoodSha; Streak = [int]$health.streak
        RescueDue = ($unproven -and $health.streak -ge $RescueAfter)
    }
}

function Invoke-OuterFrameworkRescue {
    <#
    .SYNOPSIS
        Pull the framework from the resident process when cycle processes keep
        dying without an outcome, and make the condition visible.
    .DESCRIPTION
        Uses the Invoke-OuterGitPull this process loaded at runner start, which
        predates the commit that the failing cycle processes run, so a fix pushed
        upstream reaches the host even though no cycle process can pull it. The
        attempt and its result go to outer.log. For cycle-aborted, which skips the
        failure pause, the fault is also published to status.json and counted
        toward the crash alert; outcome-unrecorded already publishes both on its
        own path. Returns updated, unchanged, failed or skipped.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][psobject]$Health,
        [int]$Cycle = 0,
        [datetime]$SpawnedAtUtc = [datetime]::UtcNow,
        [AllowEmptyString()][string]$Outcome = '',
        [int]$ExitCode = 1
    )
    $lastGood = if ($Health.LastGoodSha) { [string]$Health.LastGoodSha } else { 'none' }
    $reason = Format-YurunaOperatorMessage -Key 'runner.framework_rescue_due' -Arguments @{
        streak = "$($Health.Streak)"; outcome = $Outcome; sha = [string]$Health.Sha; lastGoodSha = $lastGood
    }
    Write-Warning $reason
    Write-OuterLog $reason
    $result = 'skipped'
    if (-not $State.NoGitPull -and $PSCmdlet.ShouldProcess([string]$State.RepoRoot, (Format-YurunaOperatorMessage -Key 'runner.framework_rescue_action'))) {
        $pulled = $false
        try { $pulled = [bool](Invoke-OuterGitPull -RepoRoot $State.RepoRoot -ConfigPath $State.ConfigPath) } catch { $pulled = $false }
        $after = [string](Get-OuterCommitSha -RepoRoot $State.RepoRoot)
        $result = if (-not $pulled) { 'failed' } elseif ($after -cne [string]$Health.Sha) { 'updated' } else { 'unchanged' }
        $detail = if ($pulled) { '' } else { ConvertTo-RecoverySafeText -Text ([string](Get-LastOuterPullFailure)) }
        Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.framework_rescue_result' -Arguments @{ result = $result; sha = $after; detail = $detail })
    }
    if ($Outcome -ceq 'cycle-aborted' -and $env:YURUNA_RUNTIME_DIR) {
        try {
            $null = Update-RunnerFaultStatus -RuntimeDir $env:YURUNA_RUNTIME_DIR -RunnerState 'paused' -FailureClass 'cycle_killed' `
                -Reason $reason -AttemptGeneration ([string]$State['CycleGeneration']) -SpawnedAtUtc $SpawnedAtUtc `
                -FrameworkCommitSha ([string]$Health.Sha) -ExitCode $ExitCode `
                -AttemptEvidence @{ stage = 'FrameworkRescue'; description = $reason; frameworkCommitSha = [string]$Health.Sha } -Confirm:$false
            $config = Read-TestConfig -Path $State.ConfigPath -NoCache -LastGoodOnError
            $null = Update-RunnerCrashGating -RuntimeDir $env:YURUNA_RUNTIME_DIR -SpawnedAtUtc $SpawnedAtUtc -Config $config `
                -Cycle $Cycle -ExitCode $ExitCode -FailureClass 'cycle_killed' -Description $reason -Confirm:$false
        } catch { Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.outer_poll_failed' -Arguments @{ probe = 'fault-status'; message = (ConvertTo-RecoverySafeText -Text ([string]$_.Exception.Message)) }) }
    }
    return $result
}

function Invoke-RunnerOuterSupervisor {
    <#
    .SYNOPSIS
        Keep the resident outer loop running through an exception that escapes it.
    .DESCRIPTION
        Nothing restarts the resident runner, so an exception that escapes
        Invoke-RunnerOuterLoop (a configuration read during the failure pause, a
        helper that throws on a state file) would otherwise end cycling on the
        host until an operator noticed. Each escape is written to outer.log with
        its type and location, published as a runner fault, counted toward the
        crash alert, and followed by a hold that doubles with each repeat inside
        an hour (BaseHoldSeconds up to MaxHoldSeconds) before the loop is entered
        again. A cycle process the escaped loop left running is stopped first, so
        two cycles never run at once. The cycle counter lives in $State, so
        re-entry never reissues a cycle generation. A shutdown request and a
        pipeline stop (Ctrl+C) still end the runner.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [ValidateRange(1, 86400)][int]$BaseHoldSeconds = 30,
        [ValidateRange(1, 86400)][int]$MaxHoldSeconds = 900,
        [scriptblock]$Loop = { param($LoopState) Invoke-RunnerOuterLoop -State $LoopState }
    )
    $streak = 0
    $lastEscapeUtc = [datetime]::MinValue
    while (-not $State.ShutdownState['Requested']) {
        try {
            & $Loop $State
            return
        } catch [System.Management.Automation.PipelineStoppedException] {
            throw
        } catch {
            if ($State.ShutdownState['Requested']) { return }
            $escape = $_
            $now = [datetime]::UtcNow
            if (($now - $lastEscapeUtc).TotalSeconds -gt 3600) { $streak = 0 }
            $streak++
            $lastEscapeUtc = $now
            $hold = [int][math]::Min($MaxHoldSeconds, $BaseHoldSeconds * [math]::Pow(2, [math]::Min(16, $streak - 1)))
            $location = 'unknown'
            if ($escape.InvocationInfo -and $escape.InvocationInfo.ScriptName) {
                $location = '{0}:{1}' -f (Split-Path -Leaf $escape.InvocationInfo.ScriptName), $escape.InvocationInfo.ScriptLineNumber
            }
            $line = Format-YurunaOperatorMessage -Key 'runner.outer_loop_exception' -Arguments @{
                type = $escape.Exception.GetType().FullName
                message = (ConvertTo-RecoverySafeText -Text ([string]$escape.Exception.Message))
                location = $location; streak = "$streak"; holdSeconds = "$hold"
            }
            Write-Warning $line
            Write-OuterLog $line
            if ($env:YURUNA_RUNTIME_DIR) {
                try {
                    $orphan = Read-YurunaRunnerCycleRecord -RuntimeDir $env:YURUNA_RUNTIME_DIR
                    if ($orphan.State -eq 'AliveOwned') {
                        Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.outer_loop_orphan_stopped' -Arguments @{ id = "$($orphan.Pid)" })
                        Stop-YurunaProcessTree -ProcessId ([int]$orphan.Pid) -Confirm:$false
                        $null = Clear-YurunaRunnerCycleRecord -RuntimeDir $env:YURUNA_RUNTIME_DIR -ProcessId ([int]$orphan.Pid) -Confirm:$false
                    }
                } catch { Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.outer_poll_failed' -Arguments @{ probe = 'cycle-record'; message = (ConvertTo-RecoverySafeText -Text ([string]$_.Exception.Message)) }) }
                try {
                    $commitSha = Get-OuterCommitSha -RepoRoot $State.RepoRoot
                    $null = Update-RunnerFaultStatus -RuntimeDir $env:YURUNA_RUNTIME_DIR -RunnerState 'paused' -FailureClass 'script_error' `
                        -Reason $line -SpawnedAtUtc $now -FrameworkCommitSha ([string]$commitSha) -Confirm:$false
                    $config = Read-TestConfig -Path $State.ConfigPath -NoCache -LastGoodOnError
                    $null = Update-RunnerCrashGating -RuntimeDir $env:YURUNA_RUNTIME_DIR -SpawnedAtUtc $now -Config $config `
                        -Cycle ([int]$State['OuterCycleCounter']) -FailureClass 'script_error' -Description $line -Confirm:$false
                } catch { Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.outer_poll_failed' -Arguments @{ probe = 'fault-status'; message = (ConvertTo-RecoverySafeText -Text ([string]$_.Exception.Message)) }) }
            }
            $null = Wait-OuterInterruptible -Seconds $hold -ShutdownState $State.ShutdownState
        }
    }
    $script:OuterWaitTickState = $null
}
Export-ModuleMember -Function Test-YurunaCycleAborted, `
    Get-OuterCommitSha, Test-OuterNewCommitsAvailable, Invoke-OuterGitPull, Get-OuterSourceSelection, Invoke-OuterNetworkGit, Invoke-OuterPoolNotifierTick, `
    Get-OuterRemoteSha, Get-OuterConfigMtime, Get-OuterStepTimeoutSeconds, Get-OuterPreambleTimeoutSeconds, Get-OuterMaxCycleSeconds, Get-OuterCycleCeilingSeconds, Get-OuterCyclePlannedRunCount, Test-OuterCycleHeld, Read-OuterWatchdogLapseBound, Step-OuterHeartbeatGuard, Get-OuterProjectUrl, `
    Get-OuterPoolTestCycleOverride, Get-OuterAutoRemediation, Test-OuterNoStatusServiceForwarded, `
    Get-OuterStatusBaseUrl, Get-OuterCycleSummaryLine, `
    Sync-ForwardEnv, Write-OuterLog, `
    Clear-TerminalNotifierJob, `
    Get-RunnerTunableDefault, Write-OuterCyclePhase, Wait-OuterInterruptible, Invoke-OuterCycleDispatch, `
    Invoke-RunnerOuterCycle, Get-LastOuterCycleResult, Invoke-RunnerOuterLoop, Invoke-RunnerOuterSupervisor, `
    Update-OuterFrameworkHealth, Invoke-OuterFrameworkRescue, `
    Get-OuterPoolStorageMoveMode, Get-OuterPoolStoragePushWait, `
    Wait-OuterPushForwarder, Test-OuterPoolStorageSpaceReady, Invoke-OuterPoolStorageMove, `
    Write-PoolStorageSpaceFailureRecord, Send-PoolStorageSpaceNotification, `
    Clear-PoolStorageSpaceNotification, Write-PoolStorageSpaceFailure, `
    Read-RunnerAttemptEvidence, Get-RunnerAttemptFault, Get-RunnerStalledPreamblePhase, Update-RunnerCrashGating, Update-RunnerFaultStatus, Get-RunnerFaultCause, `
    Get-RunnerPreambleStallStreak, Test-RunnerConfigGateNetworkOnly, Test-OuterRepositoryAccess, `
    Get-LastOuterPullFailure, Publish-OuterRecoveryResult, Invoke-OuterRecovery, Set-OuterRecoveryDecision, Write-OuterRecoveryApplied, `
    Import-OuterPoolStorageModuleSet, `
    Get-OuterRefreshCycleMode, Resolve-OuterRefreshDispatch, ConvertTo-OuterRefreshHandoff
