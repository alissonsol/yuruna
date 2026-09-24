<#PSScriptInfo
.VERSION 2026.09.24
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
        [Parameter()][int]$TimeoutSeconds = 30
    )
    # Classifier captured as CommandInfo once, so the foreign-module call works
    # regardless of import scope (see feedback_closure_foreign_module_command_resolution).
    $classifier = Get-Command Test-GitRemoteAuthFailure -ErrorAction SilentlyContinue
    $attempts   = @()
    if (Get-Command Get-YurunaGitAuthAttemptList -ErrorAction SilentlyContinue) {
        $attempts = @(Get-YurunaGitAuthAttemptList)
    }
    foreach ($attempt in $attempts) {
        # The -c credential args are git GLOBAL options -- they precede the caller's args.
        $r   = Invoke-PoolSyncGitCapture -ArgumentList (@($attempt.Args) + @($ArgumentList)) -TimeoutSeconds $TimeoutSeconds
        $out = ((@($r.StdOut, $r.StdErr) | Where-Object { $_ }) -join "`n").Trim()
        $hit = @{ ExitCode = [int]$r.ExitCode; StdOut = [string]$r.StdOut; StdErr = [string]$r.StdErr; Output = $out }
        if ($hit.ExitCode -eq 0) { return $hit }
        if (-not ($classifier -and (& $classifier -Output $out))) { return $hit }
        Write-Verbose "Invoke-OuterNetworkGit: the $($attempt.Source) attempt was rejected as unauthorized; trying the next credential source."
    }
    $r = Invoke-PoolSyncGitCapture -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds
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
        Fetch origin and report whether the upstream tracking branch's tip
        now differs from $BaselineSha. $false on any git/fetch failure or
        when there is no upstream.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$BaselineSha
    )
    # Bounded + credential-prompt-proof + credential-chained: a wedged /
    # half-dead remote or a credential prompt must never hang the outer loop
    # (the watchdog only guards the inner). rev-parse below is local -- no
    # network -- so it stays raw.
    if ((Invoke-OuterNetworkGit -ArgumentList @('-C', $RepoRoot, 'fetch', '--quiet', 'origin') -TimeoutSeconds 45).ExitCode -ne 0) { return $false }
    $upstream = & git -C $RepoRoot rev-parse '@{u}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $upstream) { return $false }
    if (([string]$upstream).Trim() -eq $BaselineSha) { return $false }
    # Differing from the baseline is necessary but not sufficient. A clone
    # holding a local commit that was never pushed differs from the upstream
    # tip permanently, so a tip-vs-HEAD comparison alone reports "new commits"
    # on every poll forever: the failure pause then breaks at the first poll
    # each cycle, the backoff cap never applies, and the console announces
    # upstream commits that do not exist. Only commits this clone does NOT
    # have are new, which is what the behind-count answers.
    $behind = & git -C $RepoRoot rev-list --count 'HEAD..@{u}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $behind) { return $false }
    return ([int]([string]$behind).Trim() -gt 0)
}

function Invoke-OuterGitPull {
    <#
    .SYNOPSIS
        Fast-forward-only pull of the repo at $RepoRoot, streaming git's
        output. Returns $true when the pull succeeded, $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    # Bounded + credential-prompt-proof + credential-chained (see
    # Invoke-OuterNetworkGit). The capture shape preserves git's (already
    # --quiet) output for the console.
    # Stream via Write-Information, NOT Write-Output: this function's contract is a
    # single [bool], and git's stderr on a failure would otherwise ride the pipeline
    # and turn the caller's `-not (Invoke-OuterGitPull ...)` into `-not <array>`
    # ($false), masking the failure. See feedback_powershell_writeoutput_pipeline_pollution.
    $pull = Invoke-OuterNetworkGit -ArgumentList @('-C', $RepoRoot, 'pull', '--ff-only', '--quiet') -TimeoutSeconds 60
    if ($pull.StdOut) { Write-Information ($pull.StdOut.TrimEnd()) -InformationAction Continue }
    if ($pull.StdErr) { Write-Information ($pull.StdErr.TrimEnd()) -InformationAction Continue }
    if ($pull.ExitCode -ne 0) {
        # A stale/expired GitHub credential is the one failure worth naming: surface
        # the same refresh-your-login guidance the inner pull uses so an operator
        # fixes it in one step instead of chasing a generic pull error or a hang.
        if ((Get-Command Test-GitRemoteAuthFailure -ErrorAction SilentlyContinue) -and (Test-GitRemoteAuthFailure -Output $pull.Output)) {
            $remoteUrl = & git -C $RepoRoot config --get remote.origin.url 2>$null
            Write-GitAuthRefreshBanner -RemoteUrl ("$remoteUrl".Trim()) -GitOutput $pull.Output
        }
    }
    if ($pull.ExitCode -ne 0) { return $false }
    # Exit 0 is not proof the working copy is usable. Every yuruna clone runs
    # with rebase.autoStash, so a pull against a dirty worktree can fast-forward
    # and then fail to re-apply the stash -- git writes conflict markers into
    # the sources and still exits 0. Spawning the inner runner on that checkout
    # executes .ps1/.psm1 files containing '<<<<<<<'.
    if ((Get-Command Test-GitWorktreeMerged -ErrorAction SilentlyContinue) -and
        -not (Test-GitWorktreeMerged -RepoRoot $RepoRoot -Label 'framework repository')) {
        return $false
    }
    return $true
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
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RemoteUrl)
    if ([string]::IsNullOrWhiteSpace($RemoteUrl)) { return $null }
    # Bounded + credential-prompt-proof + credential-chained: ls-remote reaches
    # an arbitrary remote that may hang or prompt; it must not block the pause loop.
    $ls = Invoke-OuterNetworkGit -ArgumentList @('ls-remote', $RemoteUrl, 'HEAD') -TimeoutSeconds 30
    if ($ls.ExitCode -ne 0) { return $null }
    $line = ($ls.StdOut -split "`r?`n" | Where-Object { $_ }) | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    return ([string]$line).Split("`t")[0].Trim()
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

function Get-OuterPoolTestCycleOverride {
    <#
    .SYNOPSIS
        Extract a pool's config.testCycle override map from the pool object
        Sync-YurunaPoolIntent returns. PURE + null-safe: returns @{} for a
        null pool / no config / no testCycle, so a no-pool host overlays
        nothing (identical to single-host). Reads straight off the pool
        object -- not pool.manifest.json -- so a pool that authors a
        testCycle override WITHOUT test-sets still applies it (the manifest
        is deleted when a pool has no test-sets).
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
    # -NoCache so a mid-cycle operator edit (the "lower stepTimeout for
    # the next cycle" workflow documented in test/README.md) takes effect
    # at the spawn boundary even if Read-TestConfig's mtime-keyed cache
    # hasn't noticed yet on a low-resolution filesystem.
    $cfg = Read-TestConfig -Path $ConfigPath -NoCache
    $v = Get-TestConfigValue -Config $cfg -Path 'testCycle.stepTimeoutSeconds'
    $result = $DefaultSeconds
    # TryParse rather than a bare [int] cast: this is re-read on EVERY cycle, so
    # a typo in a mid-run edit would throw from inside the cycle and take the
    # outer runner down over a tuning knob -- a runner that stops without saying
    # why, which is exactly what the watchdog work exists to prevent. Warn and
    # keep the default instead.
    if ($null -ne $v) {
        $i = 0
        if ([int]::TryParse("$v".Trim(), [ref]$i)) {
            if ($i -gt 0) { $result = $i }
        } else {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_353411c243b6e1c7' -Arguments @{ v = "$v"; defaultSeconds = "$DefaultSeconds" })
        }
    }
    if ($PoolTestCycleOverride.ContainsKey('stepTimeoutSeconds')) {
        $p = 0
        if ([int]::TryParse("$($PoolTestCycleOverride['stepTimeoutSeconds'])".Trim(), [ref]$p) -and $p -gt 0) {
            $result = $p
        }
    }
    return $result
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
    # -NoCache for the same reason as Get-OuterStepTimeoutSeconds: an operator
    # edit must take effect at the next spawn boundary, not whenever the
    # mtime-keyed cache happens to notice.
    $cfg = Read-TestConfig -Path $ConfigPath -NoCache
    $v = Get-TestConfigValue -Config $cfg -Path 'testCycle.preambleTimeoutSeconds'
    $result = $DefaultSeconds
    # TryParse, not a [int] cast. This is re-read on EVERY cycle, so a typo in a
    # mid-run edit of test.config.yml would otherwise throw from inside the cycle
    # and take the outer runner down over a tuning knob -- the "stops without
    # saying why" failure this bound exists to prevent. Warn and keep the
    # default instead: the operator gets a loud, per-cycle line and the host
    # keeps testing.
    # -ge 0, not -gt 0: 0 is the meaningful "no tighter bound" opt-out, so it
    # must be distinguishable from an absent key (which takes the default).
    if ($null -ne $v) {
        $i = 0
        if ([int]::TryParse("$v".Trim(), [ref]$i)) {
            if ($i -ge 0) { $result = $i }
        } else {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_c8d5e682839053d0' -Arguments @{ v = "$v"; defaultSeconds = "$DefaultSeconds" })
        }
    }
    if ($PoolTestCycleOverride.ContainsKey('preambleTimeoutSeconds')) {
        $p = 0
        if ([int]::TryParse("$($PoolTestCycleOverride['preambleTimeoutSeconds'])".Trim(), [ref]$p) -and $p -ge 0) {
            $result = $p
        }
    }
    return $result
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
        $cfg = Read-TestConfig -Path $ConfigPath -NoCache
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
    $cfg = Read-TestConfig -Path $ConfigPath
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
        $decision = Resolve-StatusServiceStart -Config (Read-TestConfig -Path $ConfigPath) `
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
        what the loop does next (retry vs pause). The cycle number comes from
        the status document, which the inner writes before it exits.

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

# --- REGION: Forward-env + outer.log helpers
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

function Write-OuterLog {
    <#
    .SYNOPSIS
        Append a timestamped line to runtime/outer.log. Survives a
        console-output wedge (observed on Windows: conhost can swallow
        every Write-Output for the entire failure-pause window).
    .DESCRIPTION
        outer.log is written concurrently by this loop, the watchdog thread
        job, the inner runner, and the status service, so a lone Add-Content
        can lose the race to another writer's exclusive open (a transient
        Windows sharing violation). The first write is attempted immediately
        -- the common uncontended case is unchanged; only on failure does it
        retry a few times with jittered backoff to ride out the contention
        window. If every attempt fails (a genuinely broken/read-only runtime
        dir, not mere contention) the failure is surfaced with a WARNING
        exactly once per session rather than swallowed to Verbose, so a
        silently vanishing outer.log becomes visible; the dedup keeps a
        persistently broken dir from warning on every cycle.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    $logPath = Join-Path $env:YURUNA_RUNTIME_DIR 'outer.log'
    $line = "$stamp $Message"
    $maxAttempts = 4
    $lastErr = $null
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Add-Content -LiteralPath $logPath -Value $line -Encoding utf8 -ErrorAction Stop
            return
        } catch {
            $lastErr = $_
            if ($attempt -lt $maxAttempts) {
                # Jittered backoff so two writers that collided do not re-collide
                # in lockstep on the retry. Sub-second and bounded (worst case a
                # few hundred ms across the attempts) so a contended log never
                # meaningfully delays the loop.
                Start-Sleep -Milliseconds (Get-Random -Minimum 20 -Maximum 80)
            }
        }
    }
    # Every attempt failed. Warn ONCE per session (not per cycle) so a broken
    # runtime dir surfaces without spamming the console; further failures still
    # drop to Verbose, which on its own would mask a vanishing outer.log.
    if (-not $script:OuterLogWriteWarned) {
        $script:OuterLogWriteWarned = $true
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_4ceb90c3873a42c7' -Arguments @{ logPath = "$logPath"; maxAttempts = "$maxAttempts"; message = "$($lastErr.Exception.Message)" })
    } else {
        Write-Verbose "outer.log write failed (non-fatal): $($lastErr.Exception.Message)"
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

# --- REGION: Main loop
# Every Invoke-RunnerOuterCycle return lands here as well as on the pipeline, so
# Invoke-TestCycleRunner.ps1 can read the outcome WITHOUT capturing the success
# stream. It must not capture: doing so makes PowerShell hand the inner pwsh an
# anonymous pipe for stdout instead of letting it inherit the console, and the
# call operator then returns on that pipe reaching EOF rather than on the inner
# exiting. The status service the inner spawns is the process that keeps it open --
# Start-Process -RedirectStandard* sets bInheritHandles=TRUE, so it receives a
# duplicate of the write end and holds it for its whole unbounded life. The host
# then completes exactly one cycle and never starts another: the inner logs
# "about to exit with code 0" and "outer runner back in control" never follows.
# Windows only; the POSIX detach in Start-StatusService.ps1 replaces the
# descriptors outright, so nothing crosses the exec there.
$script:LastOuterCycleResult = $null

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
        read across cycles.
    .OUTPUTS
        pscustomobject with Outcome and ExitCode, or $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    return $script:LastOuterCycleResult
}

# --- REGION: Pool-storage move mode (cycle-end archiving that can fail the cycle)
# Every function here is best-effort and Get-Command-guarded: a runner whose
# framework clone predates the archiving module, or a host with no pool storage
# configured, degrades to doing nothing rather than failing to run cycles.

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
function Import-OuterPoolStorageModuleSet {
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
        $doc = Read-TestConfig -Path $ConfigPath
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
    $deadline = (Get-Date).AddMilliseconds($budgetMs)
    while ((Get-Date) -lt $deadline) {
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
        $cfg = Get-YurunaPoolStorageConfig -Config (Read-TestConfig -Path $ConfigPath) -WarningAction SilentlyContinue
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
        $started = Get-Date
        $summary = Invoke-PoolStorageDrain -HostId $hid -LogDir $env:YURUNA_LOG_DIR -RuntimeDir $env:YURUNA_RUNTIME_DIR `
            -MoveLogs -SpaceCheck -Confirm:$false
        $elapsed = [int]((Get-Date) - $started).TotalSeconds
        if (-not $summary) { return $null }
        if ($summary.lockBusy) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_7a3882ba7f42809e' -Arguments @{ cycle = "$Cycle" })
            return $null
        }
        $line = "[outer cycle $Cycle] poolStorage move: moved=$($summary.moved) deleted=$($summary.deleted) pending=$($summary.pending) spaceShort=$($summary.spaceShort) in ${elapsed}s"
        Write-Output $line
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
            timestamp            = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
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

<#
.SYNOPSIS
Sends the cycle-failure notification for a full share, at most once per consecutive-failure streak. Best-effort.
.DESCRIPTION
Gated on a runtime flag rather than sent every time: the pre-spawn refusal repeats
every hour for as long as the share stays full, and an unbounded stream of identical
"pool storage is full" mails is how an operator learns to filter the channel that
also carries real failures. The flag clears on the next run that finds room.
#>
function Send-PoolStorageSpaceNotification {
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
        if (-not (Get-Command Send-CycleFailureNotification -ErrorAction SilentlyContinue)) {
            $nm = Join-Path $PSScriptRoot 'Test.Notify.psm1'
            if (Test-Path -LiteralPath $nm) { Import-Module $nm -Global -ErrorAction SilentlyContinue }
        }
        if (Get-Command Send-CycleFailureNotification -ErrorAction SilentlyContinue) {
            $hostType = ''
            if (Get-Command Get-HostType -ErrorAction SilentlyContinue) {
                try { $hostType = [string](Get-HostType) } catch { $null = $_ }
            }
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
            Send-CycleFailureNotification -HostType $hostType -SubjectSuffix (Format-YurunaOperatorMessage -Key 'runner.operator_127885b6f7dcb1b0') `
                -GuestKey '(poolStorage)' -StepName (Format-YurunaOperatorMessage -Key 'runner.operator_e25bada6bbd913eb') -ErrorMessage $Message `
                -EventData $eventData -ErrorAction SilentlyContinue
        }
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
        [Parameter()][int]$StallStreak = 0
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
                if ([datetime]::TryParse([string]$parsed.savedAt, [ref]$savedAt)) {
                    if ($savedAt.ToUniversalTime() -ge $SpawnedAtUtc) { return $result }
                }
            }
        } catch {
            Write-Verbose "Update-RunnerCrashGating: could not parse $gatingFile ($($_.Exception.Message)); treating the counters as unset."
        }
    }
    if (-not $PSCmdlet.ShouldProcess($gatingFile, (Format-YurunaOperatorMessage -Key 'runner.operator_b4a782ed37d78e1d'))) { return $result }

    $state.consecutiveCrashes++
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
            savedAt              = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
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
        $message = (Format-YurunaOperatorMessage -Key 'runner.operator_62f77591834076f9' -Arguments @{ exitCode = "$ExitCode"; where = "$where"; streakNote = "$streakNote" })
        try {
            if (-not (Get-Command Send-CycleFailureNotification -ErrorAction SilentlyContinue)) {
                $notifyModule = Join-Path $PSScriptRoot 'Test.Notify.psm1'
                if (Test-Path -LiteralPath $notifyModule) { Import-Module $notifyModule -Global -ErrorAction SilentlyContinue }
            }
            if (Get-Command Send-CycleFailureNotification -ErrorAction SilentlyContinue) {
                $hostType = ''
                if (Get-Command Get-HostType -ErrorAction SilentlyContinue) {
                    try { $hostType = [string](Get-HostType) } catch { $null = $_ }
                }
                # Built here rather than left to the helper's fallback, which
                # recovers its fields from the cycle folder's failure record --
                # a cycle killed in the preamble never created one.
                $eventData = [ordered]@{
                    failureClass = if ($StalledPhase) { 'preamble_stall' } else { 'cycle_killed' }
                    severity     = 'hard'
                    reason       = 'infra'
                    action       = if ($StalledPhase) { "preamble:$StalledPhase" } else { 'inner-killed' }
                    description  = $message
                    cycle        = $Cycle
                }
                Send-CycleFailureNotification -HostType $hostType -SubjectSuffix (Format-YurunaOperatorMessage -Key 'runner.operator_4c698a30b7a49186') `
                    -GuestKey '(preamble)' -StepName $(if ($StalledPhase) { $StalledPhase } else { (Format-YurunaOperatorMessage -Key 'runner.operator_8c401a9e37de2b10') }) `
                    -ErrorMessage $message -EventData $eventData -ErrorAction SilentlyContinue
                $result.Alerted = $true
            }
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
        [Parameter()][AllowEmptyString()][string]$StalledPhase = ''
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
                       elseif ($StalledPhase) { 'preamble_stall' }
                       else { 'cycle_killed' }
        severity     = if ($record -and $record['severity']) { [string]$record['severity'] } else { 'hard' }
        stepNumber   = if ($record -and $record['stepNumber']) { [int]$record['stepNumber'] } else { 0 }
        sequenceName = if ($record -and $record['sequenceName']) { [string]$record['sequenceName'] } else { '' }
        guestKey     = if ($record -and $record['guestKey']) { [string]$record['guestKey'] } else { '' }
        # The kill destroyed the runspace holding the step location, so the
        # stalled phase is the most specific thing nameable here.
        stepName     = if ($StalledPhase) { $StalledPhase }
                       elseif ($record -and $record['action']) { [string]$record['action'] }
                       else { 'watchdog' }
        errorMessage = if ($record -and $record['description']) { [string]$record['description'] }
                       elseif ($Reason) { $Reason }
                       else { '' }
        reproCommand = ''
        relPath      = ''
        vmName       = if ($record -and $record['vmName']) { [string]$record['vmName'] } else { '' }
        recordedAt   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
}

<#
.SYNOPSIS
Stamps the runner's own state into status.json so a host that is not running tests stops reporting the verdict of the last one that did.
.DESCRIPTION
status.json is written by the inner at the end of a cycle and describes that
cycle. Nothing rewrites it when a later cycle dies before producing one, so a
host in a failure pause keeps publishing the last completed cycle's
overallStatus -- and the fleet view, which reads exactly that field, shows a
green host that has not run anything for hours.

Two fields carry the correction. runnerState is the precise answer, taken from
the same vocabulary the state machine and the NDJSON stream already use.
overallStatus moves to 'fail' because it is the field consumers already switch
on and 'fail' is already in its value set: a cycle that was killed did not
pass, and any consumer that understands a failed cycle understands this one.

Correcting the live fields is not enough on its own, because they describe
only the current moment: the next cycle resets overallStatus to 'running' and
the killed cycle is gone. History is what outlives it, and Complete-Run --
the only other writer of a history row -- is unreachable once the inner has
been killed. So this path records the row itself, which is what keeps the
host page's own account of a cycle from disagreeing with the pool
dashboard's.
.PARAMETER FailureRecordPath
Overrides where the cycle's last_failure.json is read from. Defaults to the
running cycle's log directory.
.PARAMETER MaxHistoryRuns
History depth, matching Complete-Run's own default so both writers trim the
list identically.
#>
function Update-RunnerFaultStatus {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][string]$RunnerState,
        [Parameter()][string]$Reason = '',
        [Parameter()][string]$StalledPhase = '',
        [Parameter()][AllowEmptyString()][string]$FailureRecordPath = '',
        [Parameter()][int]$MaxHistoryRuns = 30
    )
    $statusFile = Join-Path $RuntimeDir 'status.json'
    if (-not (Test-Path -LiteralPath $statusFile)) { return $false }
    if (-not $PSCmdlet.ShouldProcess($statusFile, (Format-YurunaOperatorMessage -Key 'runner.operator_83c012a12dddac6a' -Arguments @{ runnerState = "$RunnerState" }))) { return $false }
    try {
        $doc = Get-Content -Raw -LiteralPath $statusFile -ErrorAction Stop | ConvertFrom-Json -AsHashtable
    } catch {
        Write-Verbose "Update-RunnerFaultStatus: could not parse $statusFile ($($_.Exception.Message))."
        return $false
    }
    if ($doc -isnot [System.Collections.IDictionary]) { return $false }
    $doc['runnerState']          = $RunnerState
    $doc['runnerStateReason']    = $Reason
    $doc['runnerStateSinceUtc']  = (Get-Date).ToUniversalTime().ToString('o')
    $doc['runnerStalledPhase']   = $StalledPhase
    # Only a state that means "no cycle is producing a verdict" overrides the
    # verdict field. A transient state would otherwise repaint a genuinely
    # passing host on its way through.
    if ($RunnerState -in @('fault', 'paused')) {
        $doc['overallStatus'] = 'fail'

        $recordPath = $FailureRecordPath
        if (-not $recordPath -and $env:YURUNA_LOG_DIR) {
            $recordPath = Join-Path $env:YURUNA_LOG_DIR 'last_failure.json'
        }
        $cause = Get-RunnerFaultCause -FailureRecordPath $recordPath -Reason $Reason -StalledPhase $StalledPhase
        # Only when the inner left none: a cycle that got far enough to
        # classify its own failure has the better answer, and this one would
        # overwrite a specific cause with a generic one.
        if (-not $doc['lastFailure']) { $doc['lastFailure'] = $cause }

        # Keyed on cycleStartUtc because this runs more than once for a single
        # kill -- 'fault' when the inner is reaped, then 'paused' when the
        # failure pause opens -- and because a cycle that did reach
        # Complete-Run already carries its own, richer row.
        $history = if ($doc['history']) { @($doc['history']) } else { @() }
        $cycleKey = [string]$doc['cycleStartUtc']
        $recorded = $false
        foreach ($row in $history) {
            if ($row -and [string]$row['cycleStartUtc'] -eq $cycleKey) { $recorded = $true; break }
        }
        if ($cycleKey -and -not $recorded -and (Initialize-RunnerHistoryWriter)) {
            # The '.incomplete/' suffix is kept deliberately. Stop-LogFile
            # renames the folder only on the completion path this cycle never
            # reached, so the suffixed name is where its partial results are
            # and a stripped row would link to nothing.
            $entry = New-CycleHistoryEntry -Document $doc -OverallStatus 'fail' `
                -CycleFolderUrl ([string]$doc['cycleFolderUrl']) `
                -FinishedAt ((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")) `
                -LastFailure $cause
            $doc['history'] = @(@($entry) + $history | Select-Object -First $MaxHistoryRuns)
        }
    }
    $null = Initialize-RunnerStateWriter
    try {
        $null = Write-YurunaStateFileJson -Path $statusFile -Depth 32 -Compress:$false -Confirm:$false -InputObject $doc
        return $true
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
        Run ONE cycle: repo pull, pool-intent gate, pre-spawn cleanup,
        watchdog, the inner spawn, and the cycle-end hooks.
    .DESCRIPTION
        Split out of Invoke-RunnerOuterLoop so it can be executed in a FRESH process
        per cycle (see Invoke-TestCycleRunner.ps1). That is what lets an edit to this
        logic take effect on the very next cycle: the loop process holds it resident
        and would otherwise keep running the copy it parsed at startup.

        Waits belong to the caller, never here. This function runs where the
        operator's Ctrl+C is NOT observable, so a Start-Sleep here could not be cut
        short; the transient outcomes below report and return instead.
    .OUTPUTS
        pscustomobject with Outcome and ExitCode. Outcome is 'completed' when the
        inner ran (ExitCode is then the inner's own status), or one of
        'pull-error' | 'paused' | 'drain' | 'spawn-failed' -- the caller owns the
        pause and the decision to stop.
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
        if (-not $State.NoGitPull) {
            Write-Output ""
            Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_3cdf142915062e6a' -Arguments @{ cycle = "$cycle" })
            if (-not (Invoke-OuterGitPull -RepoRoot $State.RepoRoot)) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_ddebd33ca8159d3f' -Arguments @{ cycle = "$cycle" })
                # The retry pause is the CALLER's, deliberately: sleeping here would
                # block inside the per-cycle child, where the outer's Ctrl+C flag is
                # not observable and the wait could not be cut short.
                return ($script:LastOuterCycleResult = [pscustomobject]@{ Outcome = 'pull-error'; ExitCode = 0 })
            }
        }

        # 1b. Pool intent sync (best-effort, IN-PROCESS, DEFAULT-OFF). Pull the
        #     pool intent over the LAN and reconcile desiredState BEFORE spawning
        #     the inner, so a pulled paused/drain gates THIS cycle. A no-op (single
        #     try-wrapped call that short-circuits) when pool sync is unconfigured
        #     -- a no-pool host is unaffected. The pull is wall-clock-bounded +
        #     credential-prompt-proof inside Sync-YurunaPoolIntent, so this can't
        #     hang the (bare-pwsh-INTERACTIVE) outer loop; any error is non-fatal.
        # Per-pool config.testCycle override (default-off, empty for a no-pool host),
        # captured at the cycle boundary so the watchdog (step-timeout) below can let
        # a pool tighten the step timeout fleet-wide without editing each host's
        # test.config.yml. This value is per-PROCESS: the failure pause lives in
        # Invoke-RunnerOuterLoop, in the parent, and cannot read it.
        $poolTC = @{}
        if (Get-Command Sync-YurunaPoolIntent -ErrorAction SilentlyContinue) {
            $poolState = 'run'
            try {
                $poolObj   = Sync-YurunaPoolIntent
                $poolState = Resolve-YurunaPoolDesiredState -Pool $poolObj
                if (Get-Command Get-OuterPoolTestCycleOverride -ErrorAction SilentlyContinue) {
                    $poolTC = Get-OuterPoolTestCycleOverride -Pool $poolObj
                }
            } catch {
                Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_8a6396e375f1eebc' -Arguments @{ cycle = "$cycle"; message = "$($_.Exception.Message)" })
            }
            if ($poolState -eq 'drain') {
                # Stop-after-cycle: any in-flight cycle already completed (this
                # runs at the cycle boundary), so draining never corrupts an
                # accumulating cycle. The host stops; re-adding it (set desiredState
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
                # state, sleep, and re-pull intent next iteration. Flips back to a
                # normal cycle as soon as a pull shows desiredState=run.
                if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
                    $null = Set-RunnerState -To 'paused' -Reason "pool desiredState=paused (cycle $cycle)" -Confirm:$false
                }
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_7b4a4d46bf482437' -Arguments @{ cycle = "$cycle" })
                Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_214ed60f2015cca4' -Arguments @{ cycle = "$cycle" })
                # Caller owns the hold, for the same reason as the pull retry: a
                # sleep here is not interruptible from the shell the operator
                # actually pressed Ctrl+C in.
                return ($script:LastOuterCycleResult = [pscustomobject]@{ Outcome = 'paused'; ExitCode = 0 })
            }
        }

        # No clock repair here. Guests take their clock from the host's
        # virtual RTC at power-on, so a drifted host is worth knowing about
        # -- but every platform's fix is a privileged call (Administrator,
        # or a sudo credential nobody is present to type), and an unattended
        # loop that stops to ask is a hang. Assert-HostConditionSet inside
        # the inner measures the skew once per cycle and warns; the repair
        # is offered where a console can answer for it (test/Test-Config.ps1,
        # host/*/Enable-TestAutomation.ps1).

        # 2. Spawn the inner. YURUNA_RUNNER_RELAUNCH=1 (set just before the
        #    spawn, cleared in the finally that follows it) tells the inner
        #    that we (the outer) own the pidfile + Ctrl+C handler; inner
        #    skips its own copies of those. It is scoped tightly to the spawn:
        #    left set in $env: after the inner returns it would suppress the
        #    inner's single-instance guard for any LATER direct invocation in
        #    the same shell session, silently disabling concurrency protection.
        #    Sync-ForwardEnv re-asserts the launch-time snapshot of YURUNA_*
        #    vars (cache IP, track/log dirs, log level, OCR combine) so the
        #    inner sees them even if some module in this outer process
        #    clobbered $env: mid-run.
        Sync-ForwardEnv -ForwardEnvSnapshot $State.ForwardEnvSnapshot
        if ($State.ForwardEnvSnapshot.Count -gt 0) {
            Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_0e61ff5245986b3e' -Arguments @{ cycle = "$cycle"; join = "$($State.ForwardEnvSnapshot.Keys -join ', ')" })
        }
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_e1a14bbdcff651de' -Arguments @{ cycle = "$cycle"; zzz = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')" })
        Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_7dcdb16b27e44240' -Arguments @{ cycle = "$cycle" })
        # Wipe last cycle's runtime files BEFORE arming the watchdog.
        # --- REGION: https://yuruna.link/42f909ad-000f
        $innerPidFile    = Join-Path $env:YURUNA_RUNTIME_DIR 'inner.pid'
        $stepHbFile      = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.stepHeartbeat'
        $phaseFile       = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.phase'
        $lastFailureFile = Join-Path $env:YURUNA_LOG_DIR     'last_failure.json'
        Remove-Item -LiteralPath $innerPidFile    -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stepHbFile      -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $phaseFile       -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $lastFailureFile -Force -ErrorAction SilentlyContinue

        # --- REGION: Pre-spawn pool-storage space check (move mode only)
        # Deliberately AFTER the last_failure.json wipe. The failure pause classifies
        # from that file, so a check placed before the wipe would leave the PREVIOUS
        # cycle's record in place -- and if its class were a transient one, a host with
        # auto-remediation on would cut the storage pause short and re-enter the same
        # wall every few minutes instead of holding for the hour.
        #
        # Running a full cycle only to discover at the end that its results cannot be
        # archived wastes the cycle; this refuses before the spawn, on a projection
        # from what recent cycles actually cost.
        $preSpawnSpace = Test-OuterPoolStorageSpaceReady -ConfigPath $State.ConfigPath
        if ($preSpawnSpace -and -not $preSpawnSpace.ok) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_e3e3d086b168105e' -Arguments @{ cycle = "$cycle"; message = "$($preSpawnSpace.message)" })
            Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_1716ae7775fbc1fc' -Arguments @{ cycle = "$cycle"; message = "$($preSpawnSpace.message)" })
            Write-PoolStorageSpaceFailureRecord -Message $preSpawnSpace.message -Stage 'PoolStorageSpaceCheck' -Cycle $cycle
            Send-PoolStorageSpaceNotification -Message $preSpawnSpace.message -Cycle $cycle
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
        # break-active.json: written by the `break` sequence action
        # when a cooperative breakpoint parks the cycle, removed on
        # resume. If the operator restarts only Start-TestRunner.ps1
        # while a break is parked, the file survives and the first
        # new-cycle step's Gate #1 thinks a break is still active --
        # hanging the cycle on a non-existent marker. Status-server
        # startup also sweeps this file but the runner can start
        # without the status service; clean here so both startup paths
        # agree.
        Remove-Item -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'break-active.json') -Force -ErrorAction SilentlyContinue
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
        $preambleDefault = if ($State.ContainsKey('PreambleTimeoutSecondsDefault')) { [int]$State.PreambleTimeoutSecondsDefault } else { 600 }
        $preambleTimeoutSeconds = Get-OuterPreambleTimeoutSeconds -ConfigPath $State.ConfigPath -DefaultSeconds $preambleDefault -PoolTestCycleOverride $poolTC
        Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_8c2c47a19b55bb3d' -Arguments @{ cycle = "$cycle"; stepTimeoutSeconds = "$stepTimeoutSeconds"; preambleTimeoutSeconds = "$preambleTimeoutSeconds" })
        $watchdogJob = Start-Watchdog -StepTimeoutSeconds $stepTimeoutSeconds -RuntimeDir $env:YURUNA_RUNTIME_DIR -PollSeconds $State.WatchdogPollSeconds -PreambleTimeoutSeconds $preambleTimeoutSeconds
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
            try {
                # Announce the relaunch to the child immediately before the spawn so
                # it inherits the flag; the finally below clears it from $env: the
                # moment the inner returns so it can never leak into a later invocation.
                $env:YURUNA_RUNNER_RELAUNCH = '1'
                # Same lifetime, different contract: YURUNA_NONINTERACTIVE tells the
                # child there is nobody at the console to answer a prompt. The spawn
                # is the call operator, so the inner INHERITS this terminal -- any
                # prompt it raises blocks the whole host until the watchdog kills it,
                # with the dashboard still green. Elevation helpers (Initialize-Sudo-
                # Cache) read this and decline to prompt; the inner widens it to git
                # and Console.In at its own startup. Cleared in the finally for the
                # same reason as the relaunch flag: a value left in $env: would make a
                # later INTERACTIVE run in this shell silently refuse to prompt.
                $env:YURUNA_NONINTERACTIVE = '1'
                & $State.PwshExe @($State.ArgList)
                $exitCode = $LASTEXITCODE
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
            return ($script:LastOuterCycleResult = [pscustomobject]@{ Outcome = 'spawn-failed'; ExitCode = 0 })
        }
        # Outer regained control. Emit BOTH to console and to runtime/
        # outer.log so a conhost wedge (documented above) can't hide
        # the moment the call operator returned.
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_a1c2ef44f4d6def3' -Arguments @{ cycle = "$cycle"; zzz = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')" })
        Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_d08530fffb9af7a3' -Arguments @{ cycle = "$cycle" })
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_ee3e83807af13667' -Arguments @{ cycle = "$cycle"; exitCode = "$exitCode" })
        Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_9debb05631886531' -Arguments @{ cycle = "$cycle"; exitCode = "$exitCode" })

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
                    $psCfgNow = Read-TestConfig -Path $State.ConfigPath
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
        # Fire the backlog-draining archiver in its OWN detached process so a
        # slow/absent NAS can NEVER delay the next cycle. The drain self-dedupes
        # (single-instance lock file), fail-fasts on an unreachable share, copies
        # every not-yet-archived cycle atomically, and is a no-op unless the three
        # pool paths are configured. Spawn failure is non-fatal. Detach idiom mirrors
        # Start-StatusService.ps1 (empty stdin sink on Windows so the child can't pin
        # conhost; nohup + own process group on macOS/Linux).
        #
        # MOVE mode is deliberately excluded here: it deletes local folders, so it has
        # to run synchronously (below) where its verdict can still fail the cycle, and
        # a detached copy running beside it would race it for the same folders.
        $psMoveMode = Get-OuterPoolStorageMoveMode -ConfigPath $State.ConfigPath
        try {
            $drainScript = Join-Path $PSScriptRoot 'Invoke-PoolStorageDrain.ps1'
            if ((-not $psMoveMode) -and (Test-Path -LiteralPath $drainScript)) {
                $hid = if (Get-Command Get-YurunaHostId -ErrorAction SilentlyContinue) { [string](Get-YurunaHostId) } else { '' }
                $drainErr = Join-Path $env:YURUNA_RUNTIME_DIR 'poolstorage.drain.err'
                if ($IsWindows) {
                    $drainStdin = Join-Path $env:YURUNA_RUNTIME_DIR 'poolstorage.drain.stdin.empty'
                    if (-not (Test-Path -LiteralPath $drainStdin)) { [System.IO.File]::WriteAllBytes($drainStdin, [byte[]]@()) }
                    $drainOut = Join-Path $env:YURUNA_RUNTIME_DIR 'poolstorage.drain.out'
                    $scriptQuoted = '"' + $drainScript + '"'
                    Start-Process -FilePath $State.PwshExe `
                        -ArgumentList "-NoProfile", "-WindowStyle", "Hidden", "-File", $scriptQuoted, "-HostId", $hid `
                        -RedirectStandardInput  $drainStdin `
                        -RedirectStandardOutput $drainOut `
                        -RedirectStandardError  $drainErr | Out-Null
                } else {
                    & bash -c "set -m; nohup '$($State.PwshExe)' -NoProfile -File '$drainScript' -HostId '$hid' </dev/null >/dev/null 2>'$drainErr' & echo `$!" | Out-Null
                }
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
                if ($IsWindows) {
                    $pushStdin = Join-Path $env:YURUNA_RUNTIME_DIR 'poolpush.forwarder.stdin.empty'
                    if (-not (Test-Path -LiteralPath $pushStdin)) { [System.IO.File]::WriteAllBytes($pushStdin, [byte[]]@()) }
                    $pushOut = Join-Path $env:YURUNA_RUNTIME_DIR 'poolpush.forwarder.out'
                    $pushScriptQuoted = '"' + $pushScript + '"'
                    $pushProc = Start-Process -FilePath $State.PwshExe `
                        -ArgumentList "-NoProfile", "-WindowStyle", "Hidden", "-File", $pushScriptQuoted, "-HostId", $phid `
                        -RedirectStandardInput  $pushStdin `
                        -RedirectStandardOutput $pushOut `
                        -RedirectStandardError  $pushErr `
                        -PassThru
                } else {
                    $spawned = & bash -c "set -m; nohup '$($State.PwshExe)' -NoProfile -File '$pushScript' -HostId '$phid' </dev/null >/dev/null 2>'$pushErr' & echo `$!"
                    $parsedPid = 0
                    if ([int]::TryParse("$spawned".Trim(), [ref]$parsedPid)) { $pushPid = $parsedPid }
                }
            }
        } catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_1543e1c089df9fda' -Arguments @{ cycle = "$cycle"; message = "$($_.Exception.Message)" })
        }

        # --- REGION: Move mode: let the forwarder finish reading before anything is deleted
        # Wait on the forwarder PROCESS, not on its lock file. The lock is created
        # well into the child's own startup -- after module imports, the vault token,
        # the proxy-IP read and the cycle-folder scan -- and three gated paths exit
        # without ever taking it. A wait-for-release would therefore observe "released"
        # instantly while the child was still booting, and the mover would delete the
        # cycle folder out from under the read it exists to protect. Process exit is
        # the only signal that means every read is done.
        #
        # Timing out is survivable, not silent: the archived folder carries its own
        # cycle.events.ndjson, so the events are never lost -- only their arrival in
        # Loki is delayed until the aggregator's pull re-reaches the file through the
        # host's mount fallback.
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
        # On the ONE host the operator configured the pool.alert transport, deliver the
        # aggregator's ADVISORY pool-degraded alerts: read the latched yuruna_pool_alert_
        # active gauge over HTTP, enqueue rising edges on the poolStorage NAS spool, deliver
        # via the notification extension, move to delivered/. Self-elects -- a clean no-op
        # everywhere the transport is not configured. Fully bounded (HTTP -TimeoutSec on the
        # gauge fetch AND the Resend POST, plus a per-cycle message cap) and never throws,
        # so it is safe on the bare-pwsh-INTERACTIVE outer loop (the cycle-end hook
        # prompt-safe + subprocess-bounded contract). IN-PROCESS so the dispatcher's delivery
        # ledger (the confirmation channel) is readable; no detached spawn needed.
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
                    try { $notifierCfg = Read-TestConfig -Path $State.ConfigPath } catch { $null = $_ }
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
                    $njob = Start-ThreadJob -Name "pool-notifier-$cycle" -ScriptBlock {
                        Invoke-PoolNotifierCycle -Config $using:notifierCfg
                    }
                    if (Wait-Job -Job $njob -Timeout 120) {
                        $notifySummary = Receive-Job -Job $njob -ErrorAction SilentlyContinue
                        # The job completed; removing a terminal job does not block.
                        Remove-Job -Job $njob -Force -ErrorAction SilentlyContinue
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
            }
        } catch {
            Write-Verbose "pool notifier hook skipped: $($_.Exception.Message)"
        }

        # Watchdog-kill detection: when the inner exits non-zero AND
        # the last step heartbeat is older than the threshold, the
        # cause was almost certainly the watchdog (the exit code is
        # whatever Stop-Process -Force happened to deliver; the
        # application-level failure path can't run after a SIGKILL/
        # TerminateProcess). Tag the situation so the operator doesn't
        # waste time hunting an application-level failure that never
        # happened.
        if ($exitCode -ne 0) {
            $stepHbFile = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.stepHeartbeat'
            if (Test-Path -LiteralPath $stepHbFile) {
                $hbAge = ((Get-Date) - (Get-Item -LiteralPath $stepHbFile).LastWriteTime).TotalSeconds
                if ($hbAge -gt $stepTimeoutSeconds) {
                    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_496000203b3e66db' -Arguments @{ cycle = "$cycle"; hbAge = "$([int]$hbAge)"; stepTimeoutSeconds = "${stepTimeoutSeconds}" })
                    Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_9427498a7339c0ac' -Arguments @{ cycle = "$cycle"; hbAge = "$([int]$hbAge)"; stepTimeoutSeconds = "${stepTimeoutSeconds}" })
                    # A SIGKILL leaves no last_failure.json (the inner's application
                    # failure path cannot run), so the auto-remediation pause-skip
                    # below has nothing to classify and the cycle escalates straight
                    # to the full human-wait pause. Synthesize a minimal schema-v2
                    # record -- only when the inner left none -- with the already-
                    # wired 'wait_timeout' class so the streak-capped auto-retry can
                    # end the pause early. Atomic write so a reader never sees a
                    # partial record; the existing per-streak cap still escalates a
                    # deterministic hang after MaxAttempts.
                    $synthFailureFile = if ($env:YURUNA_LOG_DIR) { Join-Path $env:YURUNA_LOG_DIR 'last_failure.json' } else { $null }
                    if ($synthFailureFile -and -not (Test-Path -LiteralPath $synthFailureFile) -and (Get-Command Write-YurunaStateFileJson -ErrorAction SilentlyContinue)) {
                        $null = Write-YurunaStateFileJson -Path $synthFailureFile -Confirm:$false -InputObject ([ordered]@{
                            schemaVersion           = 2
                            reason                  = 'watchdog_kill'
                            failureClass            = 'wait_timeout'
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
                            timestamp               = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
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

    return ($script:LastOuterCycleResult = [pscustomobject]@{ Outcome = 'completed'; ExitCode = $exitCode })
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
        $slice = [math]::Min($SliceSeconds, $remaining)
        Start-Sleep -Seconds $slice
        $remaining -= $slice
    }
    return [bool]$ShutdownState['Requested']
}

function Stop-ProcessTree {
    <#
    .SYNOPSIS
        Kill a process and everything it spawned.
    .DESCRIPTION
        Killing only the cycle process would orphan the inner pwsh it spawned (and
        the watchdog job), leaving VMs mid-operation with nothing supervising them.
        Windows has taskkill /T; elsewhere the child is its own process-group leader
        so a group kill reaches the whole tree.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][int]$ProcessId)
    if (-not $PSCmdlet.ShouldProcess("PID $ProcessId", (Format-YurunaOperatorMessage -Key 'runner.operator_ed5c9d2fcb476c82'))) { return }
    try {
        if ($IsWindows) {
            & taskkill /PID $ProcessId /T /F 2>&1 | Out-Null
        } else {
            & pkill -TERM -P $ProcessId 2>&1 | Out-Null
            Start-Sleep -Milliseconds 500
            # Full path, not the bare name: `kill` is also a PowerShell alias for
            # Stop-Process, which would target the wrong thing on a host where the
            # alias wins name resolution.
            & '/bin/kill' -TERM $ProcessId 2>&1 | Out-Null
        }
    } catch {
        Write-Verbose "Stop-ProcessTree($ProcessId) swallowed: $($_.Exception.Message)"
    }
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

        The child reports a transient outcome through a small JSON file rather than
        an exit code, because the inner runner's own exit codes share that space and
        a sentinel number could collide with a real failure.
    .OUTPUTS
        pscustomobject with Outcome and ExitCode.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][int]$Cycle
    )
    $cycleScript = if ($State.ContainsKey('CycleScript')) { [string]$State.CycleScript } else { '' }
    if (-not $cycleScript -or -not (Test-Path -LiteralPath $cycleScript)) {
        # In-process fallback: same code path, no reload benefit. Unit tests drive
        # this shape, and it keeps the loop working if the script is ever missing.
        return Invoke-RunnerOuterCycle -State $State -Cycle $Cycle
    }

    $outcomeFile = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.cycle.outcome.json'
    Remove-Item -LiteralPath $outcomeFile -Force -ErrorAction SilentlyContinue

    # Wrap the script path in literal double quotes before it reaches
    # -ArgumentList. Start-Process joins the array elements with spaces WITHOUT
    # quoting, so a path like "C:\Users\Yuruna Test\..." gets re-split by
    # CreateProcess and the child pwsh sees -File C:\Users\Yuruna and exits 64
    # with: The argument 'C:\Users\Yuruna' is not recognized as the name of a
    # script file. The outer reads that as a failed cycle, so a host whose path
    # contains a space never completes one. Same pre-quoting as the detached
    # drain / push spawns above and Start-StatusService.ps1.
    $cycleScriptQuoted = '"' + $cycleScript + '"'
    # -NonInteractive: this child shares the operator's terminal (-NoNewWindow),
    # and a pwsh that loses its script context there falls into the console input
    # loop, whose first act is to ask the terminal for the cursor position. On a
    # terminal another process is also reading, that query never gets its answer
    # and PowerShell answers a failed console read with Environment.FailFast --
    # the process dies outright, mid-cycle. A cycle child has no business
    # prompting for anything, so the input loop is refused rather than survived.
    # Every supported operator option forwards into the per-cycle child, not
    # just -Cycle: a custom config path, -NoStatusService, -NoConfigGate and
    # a non-default cycle delay/log level used to silently revert to
    # Invoke-TestCycleRunner.ps1's own defaults on every cycle, because
    # nothing here ever passed them through. ContainsKey guards each one so
    # a caller (a unit test, or an older State shape) that omits a key keeps
    # that script's own default instead of binding $null/0/empty explicitly.
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
    $proc = $null
    $spawnedAt = Get-Date
    try {
        $proc = Start-Process -FilePath $State.PwshExe -ArgumentList $argList -NoNewWindow -PassThru -ErrorAction Stop
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_961568a3cc6a695a' -Arguments @{ cycle = "$Cycle"; message = "$($_.Exception.Message)" })
        return [pscustomobject]@{ Outcome = 'spawn-failed'; ExitCode = 0 }
    }

    while (-not $proc.HasExited) {
        if ($State.ShutdownState['Requested']) {
            Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_2ca94152d51378a0' -Arguments @{ cycle = "$Cycle"; id = "$($proc.Id)" })
            Stop-ProcessTree -ProcessId $proc.Id -Confirm:$false
            try { $null = $proc.WaitForExit(15000) } catch { $null = $_ }
            return [pscustomobject]@{ Outcome = 'shutdown'; ExitCode = 0 }
        }
        $null = $proc.WaitForExit(1000)
    }
    $childExit = $proc.ExitCode

    $outcome = 'completed'
    $reportedOutcome = $false
    if (Test-Path -LiteralPath $outcomeFile) {
        try {
            $doc = Get-Content -LiteralPath $outcomeFile -Raw | ConvertFrom-Json
            if ($doc -and $doc.outcome) { $outcome = [string]$doc.outcome; $reportedOutcome = $true }
            if ($doc -and $null -ne $doc.exitCode) { $childExit = [int]$doc.exitCode }
        } catch {
            Write-Verbose "[outer cycle $Cycle] unreadable cycle outcome: $($_.Exception.Message)"
        }
        Remove-Item -LiteralPath $outcomeFile -Force -ErrorAction SilentlyContinue
    }
    # A child that died young, non-zero, without ever reporting an outcome did not
    # run a cycle -- it aborted on the way in. Scoring that as a cycle FAIL is a
    # lie in the direction that costs the most: it points an operator at the tests
    # and the dashboard for a fault that is upstream of both. The observed shape is
    # a console that broke under it (a second process on the same terminal, a
    # closed pty), which kills the child in seconds and produces exactly this
    # signature: no outcome file, non-zero exit, no time to have done anything.
    #
    # Threshold, not exit code alone: a cycle that ran for minutes and then exited
    # non-zero DID run, and its failure is real and must keep its verdict. Only the
    # implausibly short ones are reclassified, and they are reported loudly as
    # their own thing rather than folded into either verdict.
    $ranForSeconds = [int]((Get-Date) - $spawnedAt).TotalSeconds
    if (-not $reportedOutcome -and $childExit -ne 0 -and $ranForSeconds -lt $script:CycleAbortSeconds) {
        Write-Warning ((Format-YurunaOperatorMessage -Key 'runner.operator_9120a71c591dce9f' -Arguments @{ cycle = "$Cycle"; childExit = "$childExit"; ranForSeconds = "${ranForSeconds}" }))
        Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_28086350fb4a3aee' -Arguments @{ cycle = "$Cycle"; childExit = "$childExit"; ranForSeconds = "${ranForSeconds}" })
        return [pscustomobject]@{ Outcome = 'cycle-aborted'; ExitCode = $childExit }
    }
    return [pscustomobject]@{ Outcome = $outcome; ExitCode = $childExit }
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
    $cycle = 0
    # Consecutive auto-remediation pause-skips; reset on a passing cycle so a
    # deterministic transient still escalates to the normal wait-for-human
    # pause after the per-streak cap, while an isolated transient retries fast.
    # Deliberately held HERE and not in the per-cycle child: a fresh process each
    # cycle would reset the streak to zero every time, so the cap would never be
    # reached and a deterministic transient would auto-retry forever.
    $remediationAutoSkips = 0
    while (-not $State.ShutdownState['Requested']) {
        $cycle++

        # Taken before the dispatch, not inside it: the fault path below uses it
        # to ask whether the inner saved its gating counters during THIS cycle,
        # and a mark that is slightly early can only misread a save as belonging
        # to this cycle -- never a previous cycle's save as this one's.
        $cycleSpawnedAtUtc = [DateTime]::UtcNow
        $cycleResult = Invoke-OuterCycleDispatch -State $State -Cycle $cycle
        $outcome  = $cycleResult.Outcome
        $exitCode = $cycleResult.ExitCode

        if ($outcome -eq 'drain') {
            Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_5e1b22dd0ff54c65' -Arguments @{ cycle = "$cycle" })
            $State.ShutdownState['Requested'] = $true
            break
        }
        # Transient, non-fault outcomes: hold, then re-enter. The hold is sliced so
        # a Ctrl+C during it is seen within a few seconds instead of at the end.
        # 'cycle-aborted' joins these: the cycle never ran, so there is no verdict
        # to print and nothing for the failure machinery to act on. Holding and
        # re-entering is right for the same reason it is right for a failed spawn --
        # the condition is upstream of the tests and usually momentary.
        # 'storage-full' is deliberately NOT in this list. These outcomes take a short
        # hold and retry, which is right for a momentary condition upstream of the
        # tests; a full share is not momentary -- retrying every 30 seconds would burn
        # the day re-discovering that nobody has deleted anything yet. It falls through
        # to the failure branch below and takes the full pause, which ends early only
        # on a config edit or a new commit: the two things that plausibly change it.
        if ($outcome -in @('pull-error','paused','spawn-failed','cycle-aborted')) {
            $holdSeconds = switch ($outcome) {
                'pull-error'    { $State.OuterPullErrorSleepSeconds }
                'spawn-failed'  { $State.InnerSpawnErrorSleepSeconds }
                'cycle-aborted' { $State.InnerSpawnErrorSleepSeconds }
                default         { 30 }
            }
            Wait-OuterInterruptible -Seconds $holdSeconds -ShutdownState $State.ShutdownState
            continue
        }
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
        if ($exitCode -eq 0) {
            # 3a. Success -- next iteration pulls and respawns
            # immediately. State machine: in-cycle -> cycle-end ->
            # idle. Both transitions are emitted so a streaming
            # consumer sees the clean closure explicitly rather than
            # inferring it from the absence of a fault event.
            if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
                $null = Set-RunnerState -To 'cycle-end' -Reason "inner exited 0" -Confirm:$false
                $null = Set-RunnerState -To 'idle'      -Reason "cycle complete"  -Confirm:$false
            }
            # A passing cycle re-arms the auto-remediation budget.
            $remediationAutoSkips = 0
            continue
        }

        # State machine: in-cycle -> fault. The transition lands BEFORE
        # the failure-pause loop so a dashboard sees "fault" the moment
        # the inner exits non-zero; the subsequent fault -> paused
        # transition at the start of the pause loop makes the long
        # wait explicit.
        if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
            $null = Set-RunnerState -To 'fault' -Reason "inner exited $exitCode" -Confirm:$false
        }

        # --- REGION: Accounting an inner that was killed rather than exited
        # Everything below runs because the inner may be gone without having
        # closed its own books. The runner state stream already showed the
        # fault; these carry it into the three places an operator or a
        # dashboard actually looks.
        $stalledPhase    = ''
        $stallStreak     = 0
        $pauseMultiplier = 1
        if ($env:YURUNA_RUNTIME_DIR) {
            $stalledPhase = Get-RunnerStalledPreamblePhase -RuntimeDir $env:YURUNA_RUNTIME_DIR
            if ($stalledPhase) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_4a7854989ba0a6a4' -Arguments @{ cycle = "$cycle"; stalledPhase = "$stalledPhase" })
                Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_ece5a6e7520a60f5' -Arguments @{ cycle = "$cycle"; stalledPhase = "$stalledPhase"; exitCode = "$exitCode" })
            }
            $stall = Get-RunnerPreambleStallStreak -RuntimeDir $env:YURUNA_RUNTIME_DIR -StalledPhase $stalledPhase -Confirm:$false
            $stallStreak     = [int]$stall.Streak
            $pauseMultiplier = [int]$stall.Multiplier
            $cycleConfig = $null
            if (Get-Command Read-TestConfig -ErrorAction SilentlyContinue) {
                try { $cycleConfig = Read-TestConfig -Path $State.ConfigPath } catch { $null = $_ }
            }
            $gating = Update-RunnerCrashGating -RuntimeDir $env:YURUNA_RUNTIME_DIR `
                -SpawnedAtUtc $cycleSpawnedAtUtc -Config $cycleConfig -Cycle $cycle -ExitCode $exitCode `
                -StalledPhase $stalledPhase -StallStreak $stallStreak -Confirm:$false
            if ($gating.Updated) {
                Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_d843d4f8b87a6337' -Arguments @{ cycle = "$cycle"; consecutiveCrashes = "$($gating.ConsecutiveCrashes)"; consecutiveFailures = "$($gating.ConsecutiveFailures)"; alerted = "$($gating.Alerted)" })
            }
            $null = Update-RunnerFaultStatus -RuntimeDir $env:YURUNA_RUNTIME_DIR -RunnerState 'fault' `
                -Reason "inner exited $exitCode" -StalledPhase $stalledPhase -Confirm:$false
        }

        # Re-ensure the status service before the pause. The step-heartbeat
        # watchdog's Windows tree-kill (taskkill /T) also takes down the status
        # server, which the inner spawns as its own child on Windows -- exactly
        # when the operator's UI recovery path (/control/start-cycle) is needed
        # during the failure-pause below. (The Unix branch re-parents the server
        # so its kill spares it; the config service is owned by
        # Start-CachingProxyServiceVM, not the inner, so it is never in the kill-tree and
        # needs no re-ensure here.) Re-spawning from THIS outer process makes it
        # a stable child that survives the pause; it is a no-op when the server
        # is still alive (the common non-watchdog inner exit -- skip-if-healthy)
        # or when -NoStatusService was requested. Start-StatusService.ps1 is invoked
        # directly (not via Start-YurunaStatusServiceIfEnabled) so that a status-
        # port conflict -- which that wrapper turns into a process-level exit --
        # is caught and logged here, letting the pause proceed instead of tearing
        # down the outer runner over a transient port race during the very
        # failure it is nursing (an `exit` inside the &-invoked script only sets
        # $LASTEXITCODE; the wrapper's exit is inside a function and would not).
        try {
            if (-not (Test-OuterNoStatusServiceForwarded -ArgList $State.ArgList) -and
                (Get-Command Resolve-StatusServiceStart -ErrorAction SilentlyContinue) -and
                (Get-Command Read-TestConfig -ErrorAction SilentlyContinue)) {
                $ensureStartScript = Join-Path $State.RepoRoot 'test/service/Start-StatusService.ps1'
                if (Test-Path -LiteralPath $ensureStartScript) {
                    $ensureCfg      = Read-TestConfig -Path $State.ConfigPath
                    $ensureDecision = Resolve-StatusServiceStart -Config $ensureCfg
                    if ($ensureDecision.ShouldStart) { & $ensureStartScript -Port $ensureDecision.Port }
                }
            }
        } catch {
            Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_1e450b2204f014ac' -Arguments @{ cycle = "$cycle"; message = "$($_.Exception.Message)" })
        }

        # 3b. Failure -- pause until either a new upstream commit
        #     lands on the framework repo OR a new commit lands on
        #     repositories.projectUrl OR the local test.config.yml
        #     is edited OR the status-UI requests a restart OR the
        #     cap elapses, polled every FailureCommitPollSeconds.
        #     The wait loop sleeps in 5-second slices so Ctrl+C is
        #     responsive (Start-Sleep can't be interrupted by our
        #     event handler in long sweeps).
        $baselineSha         = Get-OuterCommitSha -RepoRoot $State.RepoRoot
        $baselineProjectUrl  = Get-OuterProjectUrl -ConfigPath $State.ConfigPath
        $baselineProjectSha  = if ($baselineProjectUrl) { Get-OuterRemoteSha -RemoteUrl $baselineProjectUrl } else { $null }
        $baselineConfigMtime = Get-OuterConfigMtime -ConfigPath $State.ConfigPath
        $pauseStart  = Get-Date
        # A repeated stall in the same preamble phase widens the pause. The
        # triggers that end it early -- a commit, a config edit, an operator
        # restart -- all still apply, so widening costs nothing when somebody
        # is acting on it and saves a wedged host from re-running the same
        # ten-minute kill on the hour, every hour, with no one watching.
        $pauseSeconds = [int]$State.FailurePauseMaxSeconds
        if ($pauseMultiplier -gt 1) { $pauseSeconds = $pauseSeconds * $pauseMultiplier }
        $deadline    = $pauseStart.AddSeconds($pauseSeconds)
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
        # State machine: fault -> paused. The pause loop polls the
        # framework + project + config-mtime triggers; this transition
        # makes the waiting state explicit on the NDJSON stream.
        if (Get-Command Set-RunnerState -ErrorAction SilentlyContinue) {
            $null = Set-RunnerState -To 'paused' -Reason "failure-pause begin" -Confirm:$false
        }
        if ($env:YURUNA_RUNTIME_DIR) {
            $null = Update-RunnerFaultStatus -RuntimeDir $env:YURUNA_RUNTIME_DIR -RunnerState 'paused' `
                -Reason "failure-pause begin (inner exited $exitCode)" -StalledPhase $stalledPhase -Confirm:$false
        }
        try {
            while ((Get-Date) -lt $deadline -and -not $State.ShutdownState['Requested']) {
                $remainingPoll = $State.FailureCommitPollSeconds
                while ($remainingPoll -gt 0 -and -not $State.ShutdownState['Requested']) {
                    $slice = [math]::Min(5, $remainingPoll)
                    Start-Sleep -Seconds $slice
                    $remainingPoll -= $slice
                    $remainingSeconds = [math]::Max(0, [int]($deadline - (Get-Date)).TotalSeconds)
                    $elapsedSeconds   = [int]((Get-Date) - $pauseStart).TotalSeconds
                    # Against the pause actually being served, not the configured
                    # one: a widened pause measured against the base length would
                    # sit at 100% for most of its duration and stop meaning anything.
                    $percent      = [math]::Min(100, [math]::Max(0, [int](($elapsedSeconds * 100) / $pauseSeconds)))
                    $remainingMinutes = [math]::Round($remainingSeconds / 60, 1)
                    # Hardened the same way Wait-WithProgress draws its bar:
                    # Write-Progress throws on tmux/sshd PTYs without a
                    # resolvable TERM (the SetCursorPosition trap in
                    # feedback_pwsh_linux_write_progress_setcursor.md). Swallow
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
                # Trigger 1: framework repo new commit.
                if (Test-OuterNewCommitsAvailable -RepoRoot $State.RepoRoot -BaselineSha $baselineSha) {
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
                if ($baselineProjectUrl) {
                    $currentProjectSha = Get-OuterRemoteSha -RemoteUrl $baselineProjectUrl
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
                # Trigger 4: status-service /control/start-cycle from
                # the UI. The endpoint sees this outer's runner.pid as
                # alive and skips spawning a replacement; without this
                # poll, that path would leave the UI's "Start cycle"
                # button silent until the backoff cap. Consume the
                # flag here so the next inner spawn doesn't re-fire on
                # it (Debug-TestSequence / inner's boot sweep also consume,
                # but the closer the consume to the wake the smaller
                # the window for stale-flag re-entry).
                $outerRestartFlag = Join-Path $env:YURUNA_RUNTIME_DIR 'control.cycle-restart'
                if (Test-Path -LiteralPath $outerRestartFlag) {
                    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_8b51a0ee51bec50b' -Arguments @{ cycle = "$cycle" })
                    Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_c571bbfec71823df' -Arguments @{ cycle = "$cycle" })
                    Remove-Item -LiteralPath $outerRestartFlag -Force -ErrorAction SilentlyContinue
                    break
                }
                # Trigger 5: gated auto-remediation (default off). The remediation
                # dispatcher's recovery vocabulary maps four failure classes to
                # a clearly-safe retry; for those there is no point waiting the
                # full human-commit pause, so end it early and let the next spawn
                # retry. Capped per consecutive-failure streak (reset on a
                # passing cycle) so a DETERMINISTIC transient still escalates to
                # the normal wait-for-human pause after a couple of fast retries.
                # Everything else (pause_and_inspect / operator_intervention_
                # required / restart_from_snapshot classes) keeps the full pause.
                # Local test.config.yml only. The per-pool testCycle override is
                # resolved in Invoke-RunnerOuterCycle, which runs in a SEPARATE
                # process on the shipped path, so no variable of its can be read
                # here -- naming one binds $null over the parameter default and
                # the lookup inside throws on every poll tick. Carrying the
                # override across that boundary needs the outcome file, not a
                # variable.
                $autoRem = Get-OuterAutoRemediation -ConfigPath $State.ConfigPath
                if ($autoRem.Enabled -and $remediationAutoSkips -lt $autoRem.MaxAttempts) {
                    $failClass = Get-OuterLastFailureClass
                    # The allow-list lives with the registry that classifies
                    # failures, not here. A literal in this file could not stay
                    # in step with the handlers: it named four classes while
                    # three more already recommended a retry, and nothing
                    # reconciled the two. If the module is unavailable -- this
                    # runs in a separate process on the shipped path -- the
                    # answer is NO: an unclassifiable failure is the one that
                    # should stop and be looked at, not the one to retry blind.
                    #
                    # The import is guarded and local, matching how this module
                    # picks up its other optional dependencies: the entry-point
                    # module set already carries Test.Remediation on the shipped
                    # path, but this function is also reachable directly, and a
                    # dependency that only resolves via the caller's module set
                    # is one the caller can silently remove.
                    if (-not (Get-Command Test-AutoRemediationAllowed -ErrorAction SilentlyContinue)) {
                        $remMod = Join-Path $PSScriptRoot 'Test.Remediation.psm1'
                        if (Test-Path -LiteralPath $remMod) {
                            Import-Module $remMod -Global -ErrorAction SilentlyContinue
                        }
                    }
                    $mayRetry = $false
                    if (Get-Command Test-AutoRemediationAllowed -ErrorAction SilentlyContinue) {
                        $mayRetry = Test-AutoRemediationAllowed -FailureClass $failClass
                    } else {
                        Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_5f6121773a9b2d3c' -Arguments @{ cycle = "$cycle"; failClass = "$failClass" })
                    }
                    if ($mayRetry) {
                        $remediationAutoSkips++
                        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_0a5a75c08d9393f4' -Arguments @{ cycle = "$cycle"; failClass = "$failClass"; remediationAutoSkips = "$remediationAutoSkips"; maxAttempts = "$($autoRem.MaxAttempts)" })
                        Write-OuterLog (Format-YurunaOperatorMessage -Key 'runner.operator_b767a43bc1c25bbd' -Arguments @{ cycle = "$cycle"; failClass = "$failClass"; remediationAutoSkips = "$remediationAutoSkips"; maxAttempts = "$($autoRem.MaxAttempts)" })
                        if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
                            Send-CycleEventSafely -EventRecord @{
                                timestamp    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                                event        = 'auto_remediation_applied'
                                failureClass = [string]$failClass
                                action       = 'end_failure_pause_early'
                                attempt      = $remediationAutoSkips
                                maxAttempts  = $autoRem.MaxAttempts
                            }
                        }
                        break
                    }
                }
                $remainingMinutes = [math]::Max(0, [math]::Round((($deadline - (Get-Date)).TotalMinutes), 1))
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_eb8238e1e37a921c' -Arguments @{ cycle = "$cycle"; remainingMinutes = "${remainingMinutes}" })
            }
        } finally {
            # Dismiss the bar on every exit path (trigger, cap, Ctrl+C,
            # exception). Wrapped for the same render-failure reason as the
            # in-loop draw above; an unrenderable terminal must not turn loop
            # teardown into a thrown error.
            try { Write-Progress -Id $progressId -Activity 'failure-pause' -Completed } catch { $null = $_ }
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
Export-ModuleMember -Function `
    Get-OuterCommitSha, Test-OuterNewCommitsAvailable, Invoke-OuterGitPull, Invoke-OuterNetworkGit, `
    Get-OuterRemoteSha, Get-OuterConfigMtime, Get-OuterStepTimeoutSeconds, Get-OuterPreambleTimeoutSeconds, Get-OuterProjectUrl, `
    Get-OuterPoolTestCycleOverride, Get-OuterAutoRemediation, Test-OuterNoStatusServiceForwarded, `
    Get-OuterStatusBaseUrl, Get-OuterCycleSummaryLine, `
    Sync-ForwardEnv, Write-OuterLog, `
    Clear-TerminalNotifierJob, `
    Wait-OuterInterruptible, Stop-ProcessTree, Invoke-OuterCycleDispatch, `
    Invoke-RunnerOuterCycle, Get-LastOuterCycleResult, Invoke-RunnerOuterLoop, `
    Get-OuterPoolStorageMoveMode, Get-OuterPoolStoragePushWait, `
    Wait-OuterPushForwarder, Test-OuterPoolStorageSpaceReady, Invoke-OuterPoolStorageMove, `
    Write-PoolStorageSpaceFailureRecord, Send-PoolStorageSpaceNotification, `
    Clear-PoolStorageSpaceNotification, Write-PoolStorageSpaceFailure, `
    Get-RunnerStalledPreamblePhase, Update-RunnerCrashGating, Update-RunnerFaultStatus, Get-RunnerFaultCause, `
    Get-RunnerPreambleStallStreak, `
    Import-OuterPoolStorageModuleSet
