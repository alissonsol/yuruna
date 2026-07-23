<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42d15e27-b2c3-4d4e-9f50-6b7c8d9e0f1a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner inner-loop
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
    Per-cycle helpers for the single-cycle inner runner
    ([Invoke-TestInnerRunner.ps1](Invoke-TestInnerRunner.ps1)).
.DESCRIPTION
    Holds the cycle-scoped helpers the inner runner threads through one
    cycle: an exit-path timeline log (sibling of the outer's Write-OuterLog),
    the working-tree-drift guard that warns when the host runs uncommitted
    code while guests only ever see `git archive HEAD`, and the per-step
    caching-proxy reachability probe that surfaces the moment a roamed host
    network strands guests configured with a now-unreachable proxy URL.

    These functions are imported with the Inner module set so a mid-run
    `git pull` refreshes them in lockstep with the rest of the cycle code.
#>

# The cycle's rename-stable identity (no .incomplete / .aborted.<UTC> suffix) so log
# lines + URLs built mid-cycle resolve to the post-rename <base>/ location once
# Stop-LogFile moves the folder. Get-CycleFolderIdentity lives in sibling Test.Log;
# fall back to the raw leaf when Test.Log is not imported for this cycle.
function Get-StableCycleBaseName {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = '$global:__YurunaCycleFolder is the cross-module per-cycle folder handle the inner runner threads through its helpers; reading it derives the cycle''s rename-stable identity for the URLs/log lines built mid-cycle.')]
    param()
    if (Get-Command Get-CycleFolderIdentity -ErrorAction SilentlyContinue) {
        Get-CycleFolderIdentity -Path $global:__YurunaCycleFolder
    } else {
        Split-Path -Leaf $global:__YurunaCycleFolder
    }
}

# Sibling of the outer's Write-OuterLog (Test.RunnerOuterLoop.psm1). Lets the
# inner record where it is in its own exit path so a hang between
# "cycleDelaySeconds wait complete" and the outer's "back in control" line is
# pinpointable: if inner.<exit-step> entries land on outer.log but the outer's
# "back in control" never does, the hang is in Start-Process / WaitForExit; if
# they stop mid-cleanup, the inner itself is wedged on a specific cmdlet.
function Write-InnerLog {
<#
.SYNOPSIS
    Append a timestamped "[inner]" line to the runtime dir's outer.log so the
    inner runner's exit-path progress is visible alongside the outer's entries.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    try {
        Add-Content -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'outer.log') `
            -Value "$stamp [inner] $Message" -Encoding utf8 -ErrorAction Stop
    } catch {
        Write-Verbose "outer.log write failed (non-fatal): $($_.Exception.Message)"
    }
}

# === Cycle-start guard: warn on working-tree drift vs HEAD =================
# /yuruna-archive.tar.gz and /yuruna-project-archive.tar.gz are built via
# `git archive HEAD`, so guests only ever see COMMITTED content. If the host
# process is running working-tree code that references new file paths not yet
# committed (rename in progress, new automation script staged but not pushed),
# the host SSH/console calls invoke the new names while the guest still has
# the old HEAD content -- the symptom is a baffling "script not found" with
# the correct-looking command line. Write-Warning bypasses logLevel filtering
# so this surfaces regardless of test.config.yml's logLevel setting.
function Convert-LocalRepoUrlToPath {
<#
.SYNOPSIS
    Resolve a local repository URL to its filesystem path, accepting a
    file:/// URL or a bare drive-letter path; returns $null for anything else.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    # file:///c:/git/yuruna-project -> c:/git/yuruna-project
    if ($Url -match '^file:///(.+)$') { return $Matches[1] }
    # Bare drive-letter path (c:/... or c:\...)
    if ($Url -match '^[A-Za-z]:[\\/]') { return $Url }
    return $null
}

<#
.SYNOPSIS
    Warn (via Write-Warning, bypassing logLevel) when the framework or project
    repo has uncommitted changes, since the guest-facing `git archive HEAD`
    tarballs ship only committed content and will not include them.
#>
function Write-UncommittedChangesWarning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$ProjectUrl
    )

    foreach ($pair in @(
        @{ Label = 'Framework';      Path = $RepoRoot;                                       Endpoint = '/yuruna-archive.tar.gz' }
        @{ Label = 'Project source'; Path = (Convert-LocalRepoUrlToPath -Url $ProjectUrl); Endpoint = '/yuruna-project-archive.tar.gz (via Update-ProjectClone)' }
    )) {
        if (-not $pair.Path) { continue }
        if (-not (Test-Path -LiteralPath $pair.Path)) { continue }
        # `git -C` happily runs in any dir; `git status --porcelain` exits
        # non-zero in a non-repo, which we swallow as "not a repo, skip".
        $out = & git -C $pair.Path status --porcelain 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $out) { continue }
        $lines = @($out -split "`r?`n" | Where-Object { $_ })
        Write-Warning ""
        Write-Warning "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        Write-Warning "$($pair.Label) repo at $($pair.Path) has $($lines.Count) uncommitted change(s); $($pair.Endpoint) is built from ``git archive HEAD`` and will NOT include them. Guests will see committed content while the host runs working-tree code."
        foreach ($l in ($lines | Select-Object -First 10)) { Write-Warning "    $l" }
        if ($lines.Count -gt 10) { Write-Warning "    ... and $($lines.Count - 10) more" }
        Write-Warning "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        Write-Warning ""
    }
}

# === Helper: pre-step caching-proxy reachability check ===
# Background: a real-world failure mode is the host's Wi-Fi roaming to a
# different SSID/subnet mid-cycle. The caching-proxy VM is on the host's
# Default Switch (Hyper-V) / VZ shared-NAT (UTM) and remains routable from
# the host, BUT the URL injected into guest cidata at New-VM time may have
# pointed at the IP the host had on the prior network -- which guests can
# no longer reach. Symptom: fetch-and-execute.sh times out on /livecheck
# and silently falls back to GitHub, masking the broken proxy path.
#
# This helper TCP-probes the proxy URL detected at runner startup before
# each step, so the operator sees the moment connectivity is lost. State
# is tracked to keep the log readable: a one-shot loud "LOST" warning on
# the down transition, terse "still unreachable" notes during a sustained
# outage, and a "recovered" note when it comes back. No-op when no proxy
# was detected at startup (nothing to lose) or when the URL doesn't parse
# as http://ip:port. The down/up state is module-scoped: every probe goes
# through this one function so the transition log stays coherent.
$script:CachingProxyLastReachable = $true
<#
.SYNOPSIS
    TCP-probe the startup-detected caching-proxy URL before a step and emit a
    coherent transition log (one-shot LOST warning, terse still-unreachable
    notes, recovered note) so a mid-cycle host network roam is visible.
#>
function Assert-CachingProxyStillReachable {
    param(
        [string]$ProxyUrl,
        [string]$StepName,
        [string]$GuestKey
    )
    if (-not $ProxyUrl) { return }
    if ($ProxyUrl -notmatch '^http://([0-9.]+):(\d+)') { return }
    $ip   = $matches[1]
    $port = [int]$matches[2]

    $tcp = New-Object System.Net.Sockets.TcpClient
    $reachable = $false
    try {
        $async = $tcp.BeginConnect($ip, $port, $null, $null)
        # 3s cap, not 1s: a remote/cross-host cache (UTM/macOS squid over bridged
        # networking) takes 600ms-1s+ to ACCEPT, so a 1s probe produced spurious
        # per-step "Caching proxy LOST" warnings on a healthy remote proxy. The cap
        # only matters when the port is slow/down; a fast cache returns on accept.
        if ($async.AsyncWaitHandle.WaitOne(3000) -and $tcp.Connected) {
            $reachable = $true
        }
    } catch {
        Write-Verbose "Caching proxy probe to ${ip}:${port} threw: $($_.Exception.Message)"
    } finally {
        $tcp.Close()
    }

    if ($reachable) {
        if (-not $script:CachingProxyLastReachable) {
            Write-Output "  Caching proxy reachable again at $GuestKey/$StepName ($ProxyUrl)."
        }
    } else {
        if ($script:CachingProxyLastReachable) {
            Write-Warning "  Caching proxy LOST at ${GuestKey}/${StepName}: $ProxyUrl no longer answers (3s TCP probe)."
            Write-Warning "    Common cause: host Wi-Fi roamed to a different SSID/subnet mid-cycle, or a remote/cross-host cache is briefly slow to accept."
            Write-Warning "    Guests configured at New-VM time with this URL will fall back to direct downloads."
        } else {
            Write-Warning "  Caching proxy still unreachable at $GuestKey/$StepName ($ProxyUrl)."
        }
    }
    $script:CachingProxyLastReachable = $reachable
}

# === Per-cycle config reload =============================================
# Resolve the reloadable per-cycle knobs (with their defaults) from a parsed
# test.config.yml. The cycle-start initialiser and the mid-cycle reload share
# one rule-set here so they cannot drift. A 0 / absent value falls through to
# the default (the runner's historical truthiness check), and CycleDelay falls
# back to -CycleDelayFallback (the runner's -CycleDelaySeconds parameter) when
# the config key is absent so a cmdline override survives a config edit.
function Get-RunnerReloadableConfig {
<#
.SYNOPSIS
    Resolve the reloadable per-cycle knobs (StopOnFailure, VM start timeout,
    boot delay, image refresh hours, cycle delay) from a parsed test.config.yml,
    falling back to defaults so the initialiser and the mid-cycle reload agree.
.OUTPUTS
    [System.Collections.Specialized.OrderedDictionary] the resolved knob values.
#>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Config,
        [Parameter(Mandatory)][int]$CycleDelayFallback
    )
    $tc = if ($Config -is [System.Collections.IDictionary]) { $Config['testCycle'] } else { $null }
    $vs = if ($Config -is [System.Collections.IDictionary]) { $Config['vmStart'] }  else { $null }
    $vi = if ($Config -is [System.Collections.IDictionary]) { $Config['vmImage'] }  else { $null }
    $gq = if ($tc -is [System.Collections.IDictionary]) { $tc['guestQuarantine'] } else { $null }
    $wr = if ($tc -is [System.Collections.IDictionary]) { $tc['warmResume'] } else { $null }
    return [ordered]@{
        StopOnFailure        = if ($tc -is [System.Collections.IDictionary] -and $tc.Contains('shouldStopOnFailure')) { [bool]$tc['shouldStopOnFailure'] } else { $false }
        VmStartTimeout       = if ($vs -is [System.Collections.IDictionary] -and $vs['startTimeoutSeconds']) { [int]$vs['startTimeoutSeconds'] } else { 120 }
        VmBootDelay          = if ($vs -is [System.Collections.IDictionary] -and $vs['bootDelaySeconds'])    { [int]$vs['bootDelaySeconds'] }    else { 15 }
        GetImageRefreshHours = if ($vi -is [System.Collections.IDictionary] -and $vi['refreshHours'])        { [int]$vi['refreshHours'] }        else { 24 }
        CycleDelay           = if ($tc -is [System.Collections.IDictionary] -and $tc['cycleDelaySeconds'])   { [int]$tc['cycleDelaySeconds'] }   else { $CycleDelayFallback }
        # Guest quarantine / circuit breaker: default ON. A guest that fails N
        # times in a row with the SAME failureClass is skipped for up to
        # SkipCycles cycles or until a framework/project commit changes, so a
        # deterministically-broken guest stops costing a full provision+deploy
        # every cycle. Set enabled:false to disable.
        GuestQuarantineEnabled    = if ($gq -is [System.Collections.IDictionary] -and $gq.Contains('enabled')) { [bool]$gq['enabled'] } else { $true }
        GuestQuarantineFailures   = if ($gq -is [System.Collections.IDictionary] -and $gq['failuresToQuarantine']) { [int]$gq['failuresToQuarantine'] } else { 3 }
        GuestQuarantineSkipCycles = if ($gq -is [System.Collections.IDictionary] -and $gq['skipCycles'])           { [int]$gq['skipCycles'] }           else { 5 }
        # Warm-resume: default ON. On an eligible transient workload failure the
        # failed sequence is re-run from its last-good step on the same live VM
        # (up to maxAttempts) before the guest is torn down, so a late-step blip
        # doesn't redo the whole install. Set enabled:false to disable.
        WarmResumeEnabled     = if ($wr -is [System.Collections.IDictionary] -and $wr.Contains('enabled')) { [bool]$wr['enabled'] } else { $true }
        WarmResumeMaxAttempts = if ($wr -is [System.Collections.IDictionary] -and $wr['maxAttempts'])      { [int]$wr['maxAttempts'] }      else { 2 }
    }
}

# Build the mutable per-run config state threaded through Sync-RunnerCycleConfig:
# the immutable inputs (cmdline log level, the -CycleDelaySeconds fallback), the
# mtime parse-cache slots, and the reloadable knobs seeded to their defaults.
function New-RunnerConfigState {
<#
.SYNOPSIS
    Build the mutable per-run config-state hashtable threaded through
    Sync-RunnerCycleConfig: immutable inputs, the mtime parse-cache slots, and
    the reloadable knobs seeded to their defaults.
.OUTPUTS
    [hashtable] the fresh config-state object.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure in-memory builder: returns a fresh state hashtable; changes no externally observable state.')]
    param(
        [AllowNull()][string]$CmdLineLogLevel,
        [Parameter(Mandatory)][int]$CycleDelayFallback
    )
    $defaults = Get-RunnerReloadableConfig -Config $null -CycleDelayFallback $CycleDelayFallback
    return @{
        CmdLineLogLevel      = $CmdLineLogLevel
        CycleDelayFallback   = $CycleDelayFallback
        CachedConfigMtime    = $null
        CachedConfigValue    = $null
        Config               = $null
        StopOnFailure        = $defaults.StopOnFailure
        VmStartTimeout       = $defaults.VmStartTimeout
        VmBootDelay          = $defaults.VmBootDelay
        GetImageRefreshHours = $defaults.GetImageRefreshHours
        CycleDelay           = $defaults.CycleDelay
        GuestQuarantineEnabled    = $defaults.GuestQuarantineEnabled
        GuestQuarantineFailures   = $defaults.GuestQuarantineFailures
        GuestQuarantineSkipCycles = $defaults.GuestQuarantineSkipCycles
        WarmResumeEnabled         = $defaults.WarmResumeEnabled
        WarmResumeMaxAttempts     = $defaults.WarmResumeMaxAttempts
        # Consecutive Sync-RunnerCycleConfig 'failed' reloads and a one-shot latch,
        # so a sustained config-reload outage (the runner coasting on stale config)
        # is surfaced once instead of degrading silently. Reset on any good reload.
        SyncFailedStreak     = 0
        SyncFailureWarned    = $false
    }
}

function Sync-RunnerCycleConfig {
<#
.SYNOPSIS
    Re-read test.config.yml mid-cycle into $State so values changed via the
    status server's "Edit config" page take effect on the next step.
.DESCRIPTION
    mtime-keyed parse cache: ConvertFrom-Yaml on the ~5-10 KB config is
    ~30-100 ms and this fires at ~8 step boundaries per cycle, so an unchanged
    file (same LastWriteTimeUtc) hands back the cached parse instead of
    re-running the parser. A live edit updates the mtime (the editor writes
    atomically) so the next call parses fresh.

    On read/parse failure (mid-write truncation, transient lock, manual edit
    in progress) the previous $State.Config is kept and 'failed' is returned --
    the caller keeps last-known-good values rather than crashing on a
    half-written file. 'nondict' means the parsed value is not a dictionary
    (Config updated, knobs unchanged); 'resolved' means the reloadable knobs
    were refreshed into $State.

    Intentionally does NOT reconcile against the template: schema migration is
    a cycle-start concern (Update-TestConfigFromTemplate); re-merging mid-cycle
    would race the editor's write.
.OUTPUTS
    [string] one of 'resolved' | 'nondict' | 'failed'.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$ConfigPath
    )
    $currentMtime = $null
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $currentMtime = (Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc
        } catch {
            Write-Verbose "Sync-RunnerCycleConfig: mtime probe failed: $($_.Exception.Message)"
        }
    }
    if ($null -ne $currentMtime -and $currentMtime -eq $State.CachedConfigMtime -and $null -ne $State.CachedConfigValue) {
        $State.Config = $State.CachedConfigValue
    } else {
        try {
            $parsed = Get-Content -Raw $ConfigPath -ErrorAction Stop | ConvertFrom-Yaml -Ordered -ErrorAction Stop
            $State.Config            = $parsed
            $State.CachedConfigValue = $parsed
            $State.CachedConfigMtime = $currentMtime
        } catch {
            Write-Warning "Config reload from '$ConfigPath' failed: $_ -- keeping previous values."
            return 'failed'
        }
    }

    if (-not ($State.Config -is [System.Collections.IDictionary])) { return 'nondict' }

    $knobs = Get-RunnerReloadableConfig -Config $State.Config -CycleDelayFallback ([int]$State.CycleDelayFallback)
    $State.StopOnFailure        = $knobs.StopOnFailure
    $State.VmStartTimeout       = $knobs.VmStartTimeout
    $State.VmBootDelay          = $knobs.VmBootDelay
    $State.GetImageRefreshHours = $knobs.GetImageRefreshHours
    $State.CycleDelay           = $knobs.CycleDelay
    $State.GuestQuarantineEnabled    = $knobs.GuestQuarantineEnabled
    $State.GuestQuarantineFailures   = $knobs.GuestQuarantineFailures
    $State.GuestQuarantineSkipCycles = $knobs.GuestQuarantineSkipCycles
    $State.WarmResumeEnabled         = $knobs.WarmResumeEnabled
    $State.WarmResumeMaxAttempts     = $knobs.WarmResumeMaxAttempts
    return 'resolved'
}

# Resolve the per-step log level from a config-state hashtable (the module
# sibling of the entry point's bootstrap Resolve-LogLevel): cmdline > JSON >
# 'Information', re-publishing $env:YURUNA_LOG_LEVEL for child processes.
function Resolve-RunnerLogLevel {
<#
.SYNOPSIS
    Resolve the per-step log level from a config-state hashtable (cmdline > JSON
    config > 'Information') and re-publish $env:YURUNA_LOG_LEVEL for children.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)
    $cfg = $State.Config
    $configLevel = if ($cfg -is [System.Collections.IDictionary] -and $cfg.Contains('logLevel')) { [string]$cfg.logLevel } else { $null }
    $null = Test.LogLevel\Resolve-LogLevel -CmdLineLevel $State.CmdLineLogLevel -ConfigLevel $configLevel
}

# Per-step config-reload hook for the inner loop: re-read test.config.yml into
# $State (Sync-RunnerCycleConfig) and refresh the per-step log level
# (Resolve-RunnerLogLevel) in one call, so a step boundary is a single call plus
# the knob mirror rather than the reload/log-level pair repeated after every step.
# It also captures Sync-RunnerCycleConfig's result to track a sustained reload
# outage: the primitive warns per failed reload, but a run of consecutive failures
# means the runner is coasting on the last good config, so that is surfaced once,
# loudly, instead of degrading silently.
function Sync-RunnerStepConfig {
<#
.SYNOPSIS
    Inner-loop per-step config hook: Sync-RunnerCycleConfig + Resolve-RunnerLogLevel
    in one call, with a one-shot warning when config reloads fail repeatedly.
.DESCRIPTION
    The caller mirrors the refreshed knobs off $State after this returns. The
    consecutive-failure counter and its one-shot latch live on $State
    (SyncFailedStreak / SyncFailureWarned) and reset on any successful reload.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$ConfigPath
    )
    $syncResult = Sync-RunnerCycleConfig -State $State -ConfigPath $ConfigPath
    if ($syncResult -eq 'failed') {
        $State.SyncFailedStreak = [int]$State.SyncFailedStreak + 1
        if ($State.SyncFailedStreak -ge 3 -and -not $State.SyncFailureWarned) {
            $State.SyncFailureWarned = $true
            Write-Warning "Config reload from '$ConfigPath' has failed $($State.SyncFailedStreak) times in a row -- the runner is coasting on the last good config. The file may be mid-edit or corrupt; reloadable knobs (logLevel, timeouts, cycleDelay) stay frozen until a reload succeeds."
        }
    } else {
        $State.SyncFailedStreak = 0
        $State.SyncFailureWarned = $false
    }
    $null = Resolve-RunnerLogLevel -State $State
}

# === Failure-artifact capture for remote inspection ===
function Copy-FailureArtifactsToStatusLog {
<#
.SYNOPSIS
    Gather a failed guest's evidence (screenshot frames, frozen-moment shot, OCR
    text, guest/host system diagnostics, the last fetch-and-execute log) into
    the per-guest cycle folder and link it from the cycle log and status doc.
#>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = '$global:__YurunaCycleFolder / $global:__YurunaLogFile are the cross-module channels with Yuruna.Log for the per-cycle folder and the HTML transcript handle this function appends the artifact link to.')]
    param(
        [Parameter(Mandatory)][string]$VMName,
        # Optional GuestKey: when supplied, the URL of the per-guest
        # data folder produced is recorded on the live status doc via
        # Set-GuestFailureArtifact so Complete-Run can promote it into
        # history.guestSummary, and the dashboard hyperlinks the per-guest
        # pill straight to the artifacts. The folder is created at the
        # top of each guest iteration (so success cycles also have a
        # place to land saveSystemDiagnostic output) -- this function just
        # populates it with failure-specific files.
        [string]$GuestKey = '',
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ModulesDir,
        [AllowEmptyString()][string]$LogFile
    )
    try {
        if (-not $LogFile) { return }

        # cycleGuestDataFolder: one folder per guest per cycle, lives at
        # {cycleFolder}/{VMName}/. Pre-created at the top of the guest
        # loop so successful cycles' saveSystemDiagnostic output has a home;
        # we also call Get-CycleGuestDataFolder defensively here so the
        # function is safe to invoke even from pre-loop failure paths.
        $destSeqDir = Get-CycleGuestDataFolder -VMName $VMName
        if (-not $destSeqDir) {
            Write-Warning "  Copy-FailureArtifactsToStatusLog: no cycle folder established (Start-LogFile not run?)"
            return
        }
        $destSeqName = Split-Path -Leaf $destSeqDir
        # Use the cycle's stable identity (no .incomplete /
        # .aborted.<UTC> suffix) so log lines + URLs constructed here
        # resolve to the post-rename location once Stop-LogFile moves
        # the folder to <base>/.
        $cycleBase   = Get-StableCycleBaseName

        # Three artifact sources, written by different code paths:
        #   * screens_<VM>/raw_*.png         -- Wait-ForText ring buffer (GUI mode)
        #   * failure_screenshot_<VM>.png    -- single frozen-moment shot from
        #                                      non-waitForText failures (any
        #                                      sequence step that isn't
        #                                      waitForText/waitForAndEnter,
        #                                      including runOverSsh)
        #   * failure_ocr_<VM>.txt           -- last OCR text from waitForText
        #
        # All files land flat inside cycleGuestDataFolder (the per-guest
        # folder under cycleFolder). At most one failure per guest per
        # cycle in practice, so the raw_<stamp>.png filenames already
        # encode their own ordering and don't need an additional prefix.
        # Same cycle-folder-nested location Wait-ForText writes into via
        # Get-CycleScreenDir. Falls back to $env:YURUNA_LOG_DIR for the
        # no-cycle-folder edge case (defensive; shouldn't happen here
        # because Start-LogFile ran upstream).
        $srcSequenceDir = Get-CycleScreenDir -VMName $VMName -WhatIf:$false
        $srcScreen      = Join-Path $env:YURUNA_LOG_DIR "failure_screenshot_${VMName}.png"
        $srcOcr         = Join-Path $env:YURUNA_LOG_DIR "failure_ocr_${VMName}.txt"

        $hasFrames = (Test-Path $srcSequenceDir) -and `
            (Get-ChildItem -Path $srcSequenceDir -Filter 'raw_*.png' -File -ErrorAction SilentlyContinue).Count -gt 0
        $hasScreen = Test-Path $srcScreen
        $hasOcr    = Test-Path $srcOcr

        $copied = 0
        if ($hasFrames) {
            # Filter 'raw_*' (no extension) picks up both the .png frames
            # and their .txt OCR sidecars written by Wait-ForText, so the
            # failure dir contains pairs like raw_<stamp>.png + raw_<stamp>.txt.
            # Frame count uses the .png extension only -- .txt files are
            # supporting evidence, not separate frames.
            foreach ($f in (Get-ChildItem -Path $srcSequenceDir -Filter 'raw_*' -File | Sort-Object Name)) {
                Copy-Item -Path $f.FullName -Destination (Join-Path $destSeqDir $f.Name) -Force
                if ($f.Extension -eq '.png') { $copied++ }
            }
            Write-Output "  Failure screenshot saved: ./status/log/$cycleBase/$destSeqName/ ($copied frames leading up to the failure)"
        }
        if ($hasScreen) {
            # Stable filename inside the folder so the operator can spot the
            # frozen-moment shot at a glance (vs. the timestamped raw_* set).
            Copy-Item -Path $srcScreen -Destination (Join-Path $destSeqDir 'failure_screenshot.png') -Force
            if (-not $hasFrames) {
                Write-Output "  Failure screenshot saved: ./status/log/$cycleBase/$destSeqName/failure_screenshot.png"
            }
        }
        if ($hasOcr) {
            Copy-Item -Path $srcOcr -Destination (Join-Path $destSeqDir 'failure_ocr.txt') -Force
            Write-Output "  Failure OCR text saved: ./status/log/$cycleBase/$destSeqName/failure_ocr.txt"
        }

        # Remote system-diagnostics capture. Soft-failing: an unreachable
        # guest, a missing pwsh on the guest, a missing vault entry, all
        # degrade to a Write-Warning -- the cycle's failure flow continues
        # either way. Imported lazily so a host that never hits a failure
        # path doesn't pay the import cost.
        try {
            if (-not (Get-Command Save-GuestDiagnostic -ErrorAction SilentlyContinue)) {
                Import-Module (Join-Path $ModulesDir 'Test.Diagnostic.psm1') -Force -Global
            }
            $null = Save-GuestDiagnostic -VMName $VMName -GuestKey $GuestKey -OutputFolder $destSeqDir -Id 'yuruna.failure'
        } catch {
            Write-Warning "  System diagnostics capture skipped: $($_.Exception.Message)"
        }

        # Last fetch-and-execute log capture. The guest's fetch-and-execute.sh
        # tees every inner-script run to /tmp/yuruna-last-fetch-and-execute.log
        # (truncated at each invocation), so this file holds the full stdout/
        # stderr of whatever wrapper was running when the sequence failed --
        # invaluable for the class of failure where the wrapper's `set -e`
        # bailed silently while the OCR/screen capture was still focused on a
        # downstream poll loop. Soft-failing like the other rungs: an SSH-down
        # guest or a never-written log just logs a Verbose line.
        # Save-GuestDiagnostic already proved SSH works via Wait-SshReady, so
        # we can call Invoke-GuestSsh without re-doing the readiness handshake.
        try {
            if (-not (Get-Command 'Test.Ssh\Invoke-GuestSsh' -ErrorAction SilentlyContinue)) {
                Import-Module (Join-Path $ModulesDir 'Test.Ssh.psm1') -Force -Global -ErrorAction SilentlyContinue
            }
            $faePath   = '/tmp/yuruna-last-fetch-and-execute.log'
            $faeProbe  = "if [ -r $faePath ]; then cat $faePath; else echo '(file not present)'; fi"
            $faeResult = Test.Ssh\Invoke-GuestSsh -VMName $VMName -GuestKey $GuestKey `
                -Command $faeProbe -TimeoutSeconds 60
            if ($faeResult.success -and $faeResult.output -and ($faeResult.output -notmatch '^\(file not present\)\s*$')) {
                $faeOut = Join-Path $destSeqDir 'last-fetch-and-execute.log'
                Set-Content -LiteralPath $faeOut -Value $faeResult.output -Encoding utf8NoBOM -NoNewline
                Write-Output "  Last fetch-and-execute log saved: ./status/log/$cycleBase/$destSeqName/last-fetch-and-execute.log"
            } else {
                Write-Verbose "  fetch-and-execute log: success=$($faeResult.success) exit=$($faeResult.exitCode) output=$($faeResult.output)"
            }
        } catch {
            Write-Warning "  fetch-and-execute log capture skipped: $($_.Exception.Message)"
        }

        # Host system-diagnostics capture. Separate from the guest snapshot
        # above (Save-GuestDiagnostic SSHs into the guest); this one runs
        # automation/Get-SystemDiagnostic.ps1 against the test-runner host
        # itself so the operator can correlate host-side state (docker,
        # kubectl, disk pressure, listening sockets, recent kernel events)
        # with the failure. Forked into a child pwsh so the script's
        # Start-Transcript and global $script:Problems list don't leak
        # into the runner. Soft-failing in line with the guest path.
        try {
            $hostDiagScript = Join-Path $RepoRoot 'automation/Get-SystemDiagnostic.ps1'
            $hostDiagOut    = Join-Path $destSeqDir 'host.diagnostics.txt'
            if (Test-Path -LiteralPath $hostDiagScript) {
                & pwsh -NoProfile -NonInteractive -File $hostDiagScript -OutFile $hostDiagOut | Out-Null
                if (Test-Path -LiteralPath $hostDiagOut) {
                    Write-Output "  Host diagnostics saved: ./status/log/$cycleBase/$destSeqName/host.diagnostics.txt"
                }
            } else {
                Write-Warning "  Host diagnostics skipped: script not found at $hostDiagScript"
            }
        } catch {
            Write-Warning "  Host diagnostics capture skipped: $($_.Exception.Message)"
        }

        # Cycle-log inline link. Label adapts to which artifact dominates so
        # the operator gets a useful description without having to open the
        # folder first. Href is relative to the log file's directory, which
        # IS the cycleFolder, so a bare "{vmName}/" jumps straight in.
        if ($global:__YurunaLogFile -and ($hasFrames -or $hasScreen -or $hasOcr)) {
            $linkLabel = if ($hasFrames) {
                "Failure screenshot sequence: $destSeqName/ ($copied frames)"
            } else {
                "Failure artifacts: $destSeqName/"
            }
            "  <a href=""$destSeqName/"">$linkLabel</a>" |
                Microsoft.PowerShell.Utility\Out-File -FilePath $global:__YurunaLogFile -Append -ErrorAction SilentlyContinue
        }

        # Persist the folder URL on the live status doc. Relative to
        # test/status/, matching the dashboard's logFileUrl() base.
        if ($GuestKey) {
            Set-GuestFailureArtifact -GuestKey $GuestKey -RelativeUrl "log/$cycleBase/$destSeqName/"
        }
    } catch {
        Write-Warning "  Could not copy failure artifacts to status/log: $_"
    }
}

function New-CycleVmNameMap {
    <#
    .SYNOPSIS
        Map each guestSequence key to a stable VM name via Get-TestVMName.
    .DESCRIPTION
        On a pool cycle the caller passes this host's id as -HostId so members
        sharing a store never collide; the single-host path passes '' for a
        byte-identical name. No hardcoded per-guest lookup is needed.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds and returns an in-memory name map; changes no system state, so ShouldProcess would not fit.')]
    param(
        [AllowEmptyCollection()]$GuestList,
        [string]$Prefix,
        [string]$HostId
    )
    $map = @{}
    foreach ($GuestKey in $GuestList) {
        $map[$GuestKey] = Get-TestVMName -GuestKey $GuestKey -Prefix $Prefix -HostId $HostId
    }
    return $map
}

function Update-CycleModuleImport {
    <#
    .SYNOPSIS
        Re-import the Inner module set and the host driver with -Global -Force so a
        mid-run `git pull` propagates code changes into this cycle.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Re-imports modules into the session (the same import the cycle body already performed); no system state changes, so ShouldProcess would not fit.')]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][string]$ModulesDir
    )
    # Unconditional, both platforms: same guarantee regardless of how the
    # cycle loop is structured. The failure class this guards against: on
    # macOS (which loops in-process via `continue` near the bottom of the
    # cycle), PowerShell's module cache survives across cycles, so a
    # long-running runner keeps executing stale module code after a
    # mid-run `git pull` -- e.g. building UTM bundle paths from a cached
    # Test.Start-VM whose layout no longer matches disk, so Start-VM fails
    # every guest with "UTM bundle not found: ...". On
    # Windows each cycle is normally a fresh pwsh via Start-Process, so this
    # block is mostly redundant there, but: (1) Add-Type compiles like
    # YurunaVMConnectDialog / HyperVCapture stick across the same
    # AppDomain, (2) any future change that has Windows fall back to an
    # in-process retry would silently regress without this. Cost is ~1 s
    # per cycle for the full Inner-kind module set -- cheap insurance and
    # the same code path on both platforms is easier to reason about.
    # Re-calling Initialize-YurunaEntryPointModuleSet -For Inner here
    # refreshes every module in the kind list with -Global -Force in
    # lockstep with the bootstrap pass, with no parallel list to keep
    # in sync (the single source of truth lives in Test.Prelude.psm1).
    Initialize-YurunaEntryPointModuleSet -For Inner -ModulesDir $ModulesDir
    # Re-call Initialize-YurunaHost so the host driver (Yuruna.Host.psm1)
    # AND the cross-host helpers (Test.VMUtility.psm1 -- Wait-VMRunning,
    # Test-IpAddress, ...) are re-imported with -Global on every cycle.
    # Without this, anything that wipes the runner's session mid-cycle
    # (a sequence step calling Get-Module | Remove-Module, a transitive
    # Import-Module without -Global, etc.) leaves the runner unable to
    # find Wait-VMRunning at the next New-VM.Resource step -- a
    # long-running in-process runner will eventually crash with
    # "Wait-VMRunning is not recognized" without this defense.
    [void](Initialize-YurunaHost -RepoRoot $RepoRoot -HostType $HostType)
}

function Update-CycleConfigFromTemplate {
    <#
    .SYNOPSIS
        Re-read test.config.yml (possibly changed via the cycle-start git pull) and
        reconcile it against the template, keeping the previous config on failure.
    .OUTPUTS
        The reconciled config, or -PreviousConfig unchanged when the reload throws.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Update-TestConfigFromTemplate may rewrite the config file to add missing template keys; that is the same reconciliation the cycle body already performed, so ShouldProcess would not fit here.')]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$TemplatePath,
        [AllowNull()]$PreviousConfig
    )
    try {
        return Update-TestConfigFromTemplate -ConfigPath $ConfigPath -TemplatePath $TemplatePath
    } catch {
        Write-Warning "Could not reload config after git pull, using previous config: $_"
        return $PreviousConfig
    }
}

function Get-CycleStepNameList {
    <#
    .SYNOPSIS
        Derive the cycle's step-name list (dashboard tile labels) plus the
        hasScreenshots / hasExtensions flags from the plan + screenshot schedules.
    .DESCRIPTION
        $hasExtensions is true iff the cycle plan has any workload (non-start)
        sequence for any guest; $hasScreenshots true iff any guest has a screenshot
        schedule. The base step names ("New-VM"/"Start-VM"/"Start-GuestOS"/
        "New-VM.Resource") are extended with "Screenshots"/"Start-GuestWorkload"
        only when those phases apply, so the dashboard renders exactly the tiles
        the cycle will run.
    .OUTPUTS
        [hashtable] with StepNames, HasScreenshots, HasExtensions.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowEmptyCollection()]$GuestList,
        [AllowNull()]$CyclePlan,
        [Parameter(Mandatory)][string]$ScreenshotsDir
    )
    # Step names are also the dashboard tile labels; "New-VM.Resource" is
    # the post-prep verification, kept distinct from the "New-VM"
    # definition step. The HTML collapses the New-VM / Start-VM /
    # New-VM.Resource triplet into a single tile.
    $BaseSteps = @("New-VM", "Start-VM", "Start-GuestOS", "New-VM.Resource")
    $hasExtensions  = $false
    $hasScreenshots = $false
    foreach ($GuestKey in $GuestList) {
        if ($CyclePlan -and $CyclePlan.Count -gt 0) {
            $merged = Get-CyclePlanSequencesForGuest -Plan $CyclePlan -GuestKey $GuestKey
            if ($merged.workloadSequences.Count -gt 0) { $hasExtensions = $true }
        }
        if ((Get-ScreenshotSchedule -GuestKey $GuestKey -ScreenshotsDir $ScreenshotsDir).Count -gt 0) {
            $hasScreenshots = $true
        }
    }
    $StepNames = $BaseSteps
    if ($hasScreenshots) { $StepNames += @("Screenshots") }
    if ($hasExtensions)  { $StepNames += @("Start-GuestWorkload") }
    return @{
        StepNames      = $StepNames
        HasScreenshots = $hasScreenshots
        HasExtensions  = $hasExtensions
    }
}

function New-CycleGitCommitList {
    <#
    .SYNOPSIS
        Build the cycle's gitCommits array: framework first, project second.
    .DESCRIPTION
        The dashboard's logFileUrl helper treats element [0] as the primary log
        key, and the framework SHA is what Start-LogFile used to name the per-cycle
        log file, so the framework entry must lead. A project entry is appended only
        when this cycle produced a clone (both ProjectGitCommit and ProjectUrl set);
        the in-tree fallback path yields a one-element array.
    .OUTPUTS
        [object[]] one or two ordered dicts, framework-first.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds and returns an in-memory ordered-dict array; changes no system state, so ShouldProcess would not fit.')]
    param(
        # Untyped (not [string]) so a $null sha/url passes through as $null rather
        # than an empty string, matching what the raw config values stored inline.
        [AllowNull()]$GitCommit,
        [AllowNull()]$FrameworkUrl,
        [AllowNull()]$ProjectGitCommit,
        [AllowNull()]$ProjectUrl
    )
    $GitCommitsList = @(
        [ordered]@{ sha = $GitCommit; repoUrl = $FrameworkUrl }
    )
    if ($ProjectGitCommit -and $ProjectUrl) {
        $GitCommitsList += [ordered]@{ sha = $ProjectGitCommit; repoUrl = $ProjectUrl }
    }
    # Unary comma keeps a one-element list from unrolling to a bare dict on return,
    # so the caller always receives an array to hand to -GitCommits.
    return ,$GitCommitsList
}

function Write-CycleConfigLog {
    <#
    .SYNOPSIS
        Echo test.config.yml (with secrets redacted) and its mtime to the cycle log.
    .DESCRIPTION
        Parses + re-emits via ConvertFrom-Yaml/Hide-SecretsInConfig/ConvertTo-Yaml
        so vault tokens never land in the transcript; on any parse/redaction error
        it falls back to the raw file so the operator still sees the config that
        drove the cycle.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath)
    Write-Output ""
    $testConfigMTime = (Test-Path $ConfigPath) ? (Get-Item $ConfigPath).LastWriteTime.ToString('u') : 'n/a'
    Write-Output "===== test.config.yml: $testConfigMTime"
    if (Test-Path $ConfigPath) {
        try {
            $redacted = Get-Content -Raw $ConfigPath | ConvertFrom-Yaml -Ordered
            Hide-SecretsInConfig $redacted
            $redacted | ConvertTo-Yaml | Write-Output
        } catch {
            Write-Warning "Could not redact test.config.yml for log: $_"
            Get-Content -Raw $ConfigPath | Write-Output
        }
    }
}

function Assert-RunnerCycleState {
    <#
    .SYNOPSIS
        Fail fast when the $State hashtable the inner cycle threads through is
        missing a required key, naming the missing key(s) at the call boundary.
    .DESCRIPTION
        A module function does not see the entry point's script scope, so every
        input the cycle body reads crosses explicitly through $State. A malformed
        $State (a renamed/dropped key) would otherwise fail deep inside the cycle
        with a null-deref that points nowhere near the real cause -- e.g. a missing
        ShutdownState surfaces only at the loop's ['Requested'] index, a missing
        RunnerCfgState only when a knob is mirrored. Checks presence (ContainsKey,
        not value: a legitimately-null Config/CachingProxyUrl is well-formed) so the
        missing key is named here; the well-formed success path is untouched.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)
    $requiredStateKeys = @(
        'RepoRoot', 'TestRoot', 'SequencesDir', 'ScreenshotsDir', 'StatusFile',
        'ConfigPath', 'TemplatePath', 'HostType', 'ModulesDir', 'StartScript',
        'StepHeartbeatFile', 'ShutdownState', 'RunnerCfgState'
    )
    $missingStateKeys = @($requiredStateKeys | Where-Object { -not $State.ContainsKey($_) })
    if ($missingStateKeys.Count -gt 0) {
        throw "Invoke-RunnerInnerCycle: malformed `$State -- missing required key(s): $($missingStateKeys -join ', ')."
    }
}

function Complete-CycleRun {
    <#
    .SYNOPSIS
        Finalize the cycle: publish the overall pass/fail to status.json (Complete-Run)
        and close the per-cycle transcript (Stop-LogFile), returning the resolved
        final-status string.
    .DESCRIPTION
        The reason line names the failing guest/step on a failure that pinned one,
        and is blank on a pass or a failure with no attributed guest/step. The caller
        sets $script:CycleFinalized and prints the completion banner after this
        returns, so the crash-path finalizer knows the normal finalize already ran.
    .OUTPUTS
        [string] "pass" or "fail".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Delegates to Complete-Run / Stop-LogFile -- the same status-doc + transcript finalization the cycle body already performed; those callees own their own confirmation surface.')]
    param(
        [Parameter(Mandatory)][bool]$OverallPassed,
        [AllowNull()]$Config,
        [AllowNull()][string]$FailedGuest,
        [AllowNull()][string]$FailedStep
    )
    $FinalStatus = $OverallPassed ? "pass" : "fail"

    # Vault is persisted across cycles to simulate an external auth
    # provider -- no cycle-end wipe. Get-Password's lazy-create branch
    # populates a user on first reference and every later call (this
    # cycle or any future cycle) returns the same stored value.

    Complete-Run -OverallStatus $FinalStatus -MaxHistoryRuns ([int]$Config.testCycle.recentDisplayCount)
    $cycleEndReason = if ($OverallPassed) { '' } elseif ($FailedGuest -and $FailedStep) { "$FailedGuest / $FailedStep" } else { '' }
    Stop-LogFile -Outcome $FinalStatus -Reason $cycleEndReason
    return $FinalStatus
}

function Resolve-CycleVmNamingStrategy {
    <#
    .SYNOPSIS
        Resolve the cycle's VM-name prefix and the pool host-id scoping suffix used
        to name this cycle's guest VMs.
    .DESCRIPTION
        On a POOL cycle the VM names are scoped by this host's id so pool members
        sharing a store never collide; the single-host path uses '' for a
        byte-identical name. Prefix falls back to "test-" when unavailable.
    .OUTPUTS
        [hashtable] with Prefix, PoolHostId.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]$Config,
        [Parameter(Mandatory)][bool]$IsPoolCycle,
        [AllowNull()][string]$HostId
    )
    return @{
        Prefix     = $Config.vmStart.testVmNamePrefix ?? "test-"
        PoolHostId = if ($IsPoolCycle) { [string]$HostId } else { '' }
    }
}

function Initialize-CycleGatingState {
    <#
    .SYNOPSIS
        Load the cycle counter (from status.json) and the notification-gating
        counters (from runner.gating.json, with a parse fallback) that must survive
        the single-cycle inner respawn.
    .DESCRIPTION
        The crash counter drives the escalating auto-retry backoff and the hard
        MaxConsecutiveCrashes abort; the failure/success counters + Armed latch drive
        the notification gate (Armed -> N failures -> Fired -> M successes -> Armed).
        A process-local counter would reset to 0 on every respawn, so the backoff
        could never escalate and a flapping host would email every cycle -- hence the
        load from runner.gating.json. FailuresBeforeAlert / SuccessesBeforeRearm come
        from the config's notification block (defaulting to 1). A read/parse failure
        on either file is soft: the counter keeps its seeded default.
    .OUTPUTS
        [hashtable] with CycleCount, ConsecutiveCrashes, FailuresBeforeAlert,
        SuccessesBeforeRearm, ConsecutiveFailures, ConsecutiveSuccesses, AlertArmed,
        GatingFile.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$StatusFile,
        [AllowNull()]$Config,
        [Parameter(Mandatory)][string]$RuntimeDir
    )
    $CycleCount = 0
    try {
        $prevStatus = Get-Content -Raw $StatusFile | ConvertFrom-Json
        if ($prevStatus.cycle) { $CycleCount = [int]$prevStatus.cycle }
    } catch { Write-Warning "Could not read previous cycle count from status file: $_" }

    $ConsecutiveCrashes   = 0
    $FailuresBeforeAlert  = [int]($Config.notification.failuresBeforeAlert  ?? 1)
    $SuccessesBeforeRearm = [int]($Config.notification.successesBeforeRearm ?? 1)
    $ConsecutiveFailures  = 0
    $ConsecutiveSuccesses = 0
    $AlertArmed           = $true
    $GatingFile = Join-Path $RuntimeDir 'runner.gating.json'
    if (Test-Path -LiteralPath $GatingFile) {
        try {
            $gating = Get-Content -Raw $GatingFile -ErrorAction Stop | ConvertFrom-Json
            if ($null -ne $gating.consecutiveFailures)  { $ConsecutiveFailures  = [int]$gating.consecutiveFailures }
            if ($null -ne $gating.consecutiveSuccesses) { $ConsecutiveSuccesses = [int]$gating.consecutiveSuccesses }
            if ($null -ne $gating.alertArmed)           { $AlertArmed           = [bool]$gating.alertArmed }
            if ($null -ne $gating.consecutiveCrashes)   { $ConsecutiveCrashes   = [int]$gating.consecutiveCrashes }
        } catch {
            Write-Warning "Could not parse $GatingFile (resetting gating state): $($_.Exception.Message)"
        }
    }
    return @{
        CycleCount           = $CycleCount
        ConsecutiveCrashes   = $ConsecutiveCrashes
        FailuresBeforeAlert  = $FailuresBeforeAlert
        SuccessesBeforeRearm = $SuccessesBeforeRearm
        ConsecutiveFailures  = $ConsecutiveFailures
        ConsecutiveSuccesses = $ConsecutiveSuccesses
        AlertArmed           = $AlertArmed
        GatingFile           = $GatingFile
    }
}

function Remove-CycleStartOrphanVM {
    <#
    .SYNOPSIS
        Cycle-start sweep: remove every test-<prefix>* VM left over from a prior
        cycle killed before its teardown ran, soft-failing so cleanup can't fail
        the cycle.
    .DESCRIPTION
        The per-guest "Cleanup previous VM" inside the loop only clears the SAME-
        named VM, so a leftover guest from cycle N-1 (12 GB Startup, dynamic memory
        disabled) could starve cycle N's first guests with 0x800705AA before its own
        iteration evicted it. Running Remove-TestVMFiles.ps1 here makes the cycle
        start from a clean slate without relying on the previous cycle's teardown.
        The child script still runs nested in this module's session state, so the
        caller's post-sweep Initialize-YurunaHost re-assert restores the global host
        contract exactly as before.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Delegates to Remove-TestVMFiles.ps1 -- the same best-effort sweep the cycle body already ran; the child script owns its own confirmation surface.')]
    param(
        [Parameter(Mandatory)][string]$TestRoot,
        [Parameter(Mandatory)][string]$Prefix
    )
    # try/catch + EAP scoping mirrors the teardown invocation at end of cycle:
    # cleanup is best-effort, the cycle's pass/fail drives the exit code.
    Write-Output ""
    Write-Output "--- Cycle-start VM sweep (Prefix: '$Prefix') ---"
    # -Quiet suppresses the per-VM Stopping/Removed chatter + the Remove-
    # OrphanedVMFiles dump. Only a single line --
    #   "Running orphaned VM file cleanup: <path>"
    # -- still prints, proving the sweep ran. Direct invocation of
    # Remove-TestVMFiles.ps1 (without -Quiet) keeps the full operator-
    # facing transcript. Warnings/errors remain visible either way.
    try {
        & (Join-Path $TestRoot "Remove-TestVMFiles.ps1") -Prefix $Prefix -Quiet
    } catch {
        Write-Warning "Remove-TestVMFiles.ps1 raised a terminating error at cycle start (continuing). Error: $_"
    }
}

function Remove-CycleTeardownOrphanVM {
    <#
    .SYNOPSIS
        Print the teardown boundary banner and run the cycle-end VM sweep, dumping
        origin + stack on a terminating error but never letting cleanup poison the
        cycle's exit code.
    .DESCRIPTION
        Remove-TestVMFiles.ps1 sets EAP='Stop' in its own scope, so a Hyper-V
        non-terminating error (from it or its Remove-OrphanedVMFiles.ps1 callee) can
        become terminating. Without the catch, such an error escapes past the loop's
        break and aborts the inner before its exit-code line -- the script exits 1
        even though status.json finalized the cycle as 'pass', dropping the outer
        into a 60-minute "new commits" wait. Cleanup is best-effort: log + continue.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Delegates to Remove-TestVMFiles.ps1 -- the same best-effort teardown sweep the cycle body already ran; the child script owns its own confirmation surface.')]
    param(
        [Parameter(Mandatory)][int]$CycleCount,
        [Parameter(Mandatory)][string]$TestRoot,
        [Parameter(Mandatory)][string]$Prefix
    )
    # Cycle work is done -- everything from here is teardown the operator
    # should be able to watch from the same window. The explicit boundary
    # marker lets the operator (and any downstream log scraper) tell
    # cycle-work output from teardown output, and pins the moment we
    # transition into the cleanup + delay phase.
    Write-Output ""
    Write-Output "============================================="
    Write-Output "  CYCLE $CycleCount complete -- entering teardown"
    Write-Output "============================================="

    try {
        & (Join-Path $TestRoot "Remove-TestVMFiles.ps1") -Prefix $Prefix -Quiet
    } catch {
        Write-Warning "Remove-TestVMFiles.ps1 raised a terminating error; cycle exit code will still reflect the cycle's pass/fail. Error: $_"
        if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
            foreach ($line in ($_.InvocationInfo.PositionMessage -split "`n")) {
                Write-Warning "  $line"
            }
        }
        if ($_.ScriptStackTrace) {
            foreach ($line in ($_.ScriptStackTrace -split "`n")) {
                Write-Warning "  $line"
            }
        }
    }
}

function Initialize-CycleAuthVault {
    <#
    .SYNOPSIS
        Import the authentication extension and open the vault connection for the
        cycle, soft-failing so a missing/broken auth provider defers to the
        per-guest credential ops rather than aborting the cycle here.
    .DESCRIPTION
        Initialize-VaultConnection creates an empty vault.yml if missing; a prior
        failed cycle's vault is reused as a debugging aid (it is wiped on cycle
        success elsewhere). On any init error the underlying message is surfaced as
        a warning and the cycle continues -- the per-guest credential lookups will
        re-surface the real error at the point they need a secret.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Delegates to Import-Extension / Initialize-VaultConnection -- the same auth bootstrap the cycle body already performed; those callees own their own confirmation surface.')]
    param()
    try {
        [void](Import-Extension -Area 'authentication' -RequireSingle)
        Initialize-VaultConnection
    } catch {
        Write-Warning "Authentication extension init failed: $($_.Exception.Message). Continuing; per-guest credential ops will surface the underlying error."
    }
}

function Get-CycleGuestAndSequenceList {
    <#
    .SYNOPSIS
        Derive the cycle's GuestList and per-sequence SequenceList from the resolved
        cycle plan, falling back to the legacy guestSequence config list.
    .DESCRIPTION
        A planner-fatal cycle runs zero guests (empty lists so the guest loop is a
        no-op). A resolved plan yields the deduped guest list plus the ordered
        top-level sequence list the dashboard's per-sequence cards render. The legacy
        path (no plan) reads guestSequence from the config and leaves SequenceList
        empty, where the dashboard falls back to a flat per-guest list. Reads only
        the plan + config, never guest-loop state.
    .OUTPUTS
        [hashtable] with GuestList and SequenceList.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Reads the plan/config and returns two in-memory lists; changes no system state, so ShouldProcess would not fit.')]
    param(
        [Parameter(Mandatory)][bool]$PlannerFatal,
        [AllowNull()]$CyclePlan,
        [AllowNull()]$Config
    )
    if ($PlannerFatal) {
        $GuestList    = @()
        $SequenceList = @()
    } elseif ($CyclePlan -and $CyclePlan.Count -gt 0) {
        $GuestList    = Get-CyclePlanGuestList -Plan $CyclePlan
        # Ordered top-level sequences (test.runner.yml entries) -> guest(s),
        # for the dashboard's per-sequence cards. Empty on the legacy
        # guestSequence path below, where the dashboard falls back to a flat
        # per-guest list.
        $SequenceList = Get-CyclePlanSequenceList -Plan $CyclePlan
        Write-Output "Cycle plan: $($CyclePlan.Count) entries across $($GuestList.Count) guest(s)."
    } else {
        $GuestList    = Get-GuestList -Config $Config
        $SequenceList = @()
    }
    return @{
        GuestList    = $GuestList
        SequenceList = $SequenceList
    }
}

function Register-CycleGuestSshUserOverride {
    <#
    .SYNOPSIS
        Cascade each guest's planner-effective username into Test.Ssh's
        Get-GuestSshUser override registry so $vars-less SSH code paths target the
        cascaded account instead of the hardcoded default.
    .DESCRIPTION
        The planner threads `variables.username:` through New-VM (cloud-init) and
        Invoke-Sequence's $vars scope, but Get-GuestSshUser is the lookup point for
        code that does NOT receive $vars: Save-GuestDiagnostic (the baseline's
        saveSystemDiagnostic), the host driver Send-Text/Send-Key SSH-mode
        dispatchers, and the inner runner's own fetchAndExecute SSH path. Without
        this registration the VM is created with the cascaded user but the harness's
        SSH probes target a default that no longer exists on the VM. Test.Ssh is
        loaded ad-hoc later in the cycle body; the override helpers are ensured
        present first. The registry is cleared before re-seeding so a prior cycle's
        override never leaks forward. No-op on a planner-fatal or plan-less cycle.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Delegates to Clear-/Set-GuestSshUserOverride -- the same in-memory registry seeding the cycle body already performed; those callees own their own confirmation surface.')]
    param(
        [Parameter(Mandatory)][bool]$PlannerFatal,
        [AllowNull()]$CyclePlan,
        [AllowEmptyCollection()]$GuestList,
        [Parameter(Mandatory)][string]$ModulesDir
    )
    if (-not (Get-Command Set-GuestSshUserOverride -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $ModulesDir 'Test.Ssh.psm1') -Force -Global -ErrorAction SilentlyContinue
    }
    if (Get-Command Clear-GuestSshUserOverride -ErrorAction SilentlyContinue) {
        Clear-GuestSshUserOverride
    }
    if (-not $PlannerFatal -and $CyclePlan -and $CyclePlan.Count -gt 0 -and
        (Get-Command Set-GuestSshUserOverride -ErrorAction SilentlyContinue)) {
        foreach ($_gk in $GuestList) {
            $_merged = Get-CyclePlanSequencesForGuest -Plan $CyclePlan -GuestKey $_gk
            if ($_merged -and $_merged.effectiveUsername) {
                Set-GuestSshUserOverride -GuestKey $_gk -Username ([string]$_merged.effectiveUsername)
            }
        }
    }
}

function Set-CycleGuestProvenance {
    <#
    .SYNOPSIS
        Seed each guest's base-image provenance (actual ISO filename + source URL)
        onto the status doc so the UI shows e.g.
        "ubuntu-24.04.4-live-server-amd64.iso" instead of the guest key.
    .DESCRIPTION
        Each Get-Image.ps1 writes a two-line sidecar (filename + source URL);
        Get-BaseImageProvenance reads it. A missing sidecar or blank URL leaves
        provenance empty and the UI falls back to the guest key. Per-cycle, so
        deleting the ISO + re-running Get-Image reflects on the next cycle. Pure
        side-effect over the guest list; reads no guest-loop state.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Delegates to Set-GuestProvenance -- the same status-doc seeding the cycle body already performed; that callee owns its own confirmation surface.')]
    param([AllowEmptyCollection()]$GuestList)
    foreach ($gk in $GuestList) {
        $imgPath = Get-ImagePath -GuestKey $gk
        if ($imgPath) {
            $prov = Get-BaseImageProvenance -BaseImagePath $imgPath
            Set-GuestProvenance -GuestKey $gk -Filename $prov.Filename -Url $prov.Url
        }
    }
}

function Start-CycleLogFile {
    <#
    .SYNOPSIS
        Read the incremented cycle number and open the per-cycle transcript,
        returning both so the caller can name artifacts and link the cycle folder.
    .DESCRIPTION
        CycleNumber is read (via Get-CycleNumber) AFTER Initialize-StatusDocument so
        it sees the incremented value (1, 2, 3, ...); it drives the 6-digit prefix in
        the cycleFolder name. Start-LogFile also publishes the folder URL onto the
        status doc (Set-CycleFolderUrl) so the dashboard can build per-guest tile
        links from it.
    .OUTPUTS
        [hashtable] with CycleNumber and LogFile.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Delegates to Start-LogFile -- the same transcript-open the cycle body already performed; that callee owns its own confirmation surface.')]
    param(
        [Parameter(Mandatory)][string]$TestRoot,
        [Parameter(Mandatory)][string]$CycleId,
        [Parameter(Mandatory)][string]$Hostname
    )
    $CycleNumber = Get-CycleNumber
    $LogFile = Start-LogFile -TestRoot $TestRoot -CycleId $CycleId -Hostname $Hostname -CycleNumber $CycleNumber
    Write-Output "Log file: $LogFile"
    return @{
        CycleNumber = $CycleNumber
        LogFile     = $LogFile
    }
}

function Start-CycleHostDiagnostic {
    <#
    .SYNOPSIS
        Capture cycle-start host state to the cycle folder and open the per-step
        perf log, returning the host-diagnostic path (or $null when it was not
        written) so the caller/perf log can reference it.
    .DESCRIPTION
        The host diagnostic (docker/kubectl state, disk pressure, listening sockets,
        recent kernel events, top processes) is written at the cycle ROOT so it sits
        alongside the cycle HTML log -- separate from the per-guest failure-time host
        diagnostic. Forked into a child pwsh so the diagnostic's Start-Transcript and
        global $script:Problems list don't leak into the runner. Start-PerfCycle is
        initialized AFTER the write so its hostInfoHash points at the fresh dump; the
        path may be $null (script missing / capture failed), in which case
        Start-PerfCycle leaves the hash null and downstream rows lose that one
        dimension. Both rungs are soft-failing -- a diagnostic/perf error never fails
        the cycle. The captured path is consumed entirely here (it feeds
        Start-PerfCycle's hostInfoHash) and is not read downstream, so it is not
        returned -- only the "Host diagnostic (cycle start): ..." log line surfaces.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = '$global:__YurunaCycleFolder is the cross-module per-cycle folder handle the inner runner threads through its helpers; the cycle-start host diagnostic is written at its root.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Delegates to the child diagnostic script / Start-PerfCycle -- the same soft-failing capture the cycle body already performed; those callees own their own confirmation surface.')]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$CycleId,
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][string]$Hostname,
        [AllowNull()][string]$GitCommit,
        [AllowNull()][string]$ProjectGitCommit
    )
    # Init null so a throw before assignment (e.g. a null cycle-folder global)
    # still yields a well-defined return / -HostDiagnosticPath.
    $cycleHostDiagOut = $null
    try {
        $hostDiagScript    = Join-Path $RepoRoot 'automation/Get-SystemDiagnostic.ps1'
        $cycleHostDiagOut  = Join-Path $global:__YurunaCycleFolder 'host.diagnostic.txt'
        if (Test-Path -LiteralPath $hostDiagScript) {
            & pwsh -NoProfile -NonInteractive -File $hostDiagScript -OutFile $cycleHostDiagOut | Out-Null
            if (Test-Path -LiteralPath $cycleHostDiagOut) {
                # Log line uses the cycle's stable identity so the
                # URL resolves to the post-rename location once Stop-
                # LogFile moves the folder to <base>/.
                $cycleBaseName = Get-StableCycleBaseName
                Write-Output "Host diagnostic (cycle start): ./status/log/$cycleBaseName/host.diagnostic.txt"
            }
        } else {
            Write-Warning "Cycle-start host diagnostic skipped: script not found at $hostDiagScript"
        }
    } catch {
        Write-Warning "Cycle-start host diagnostic capture failed: $($_.Exception.Message)"
    }

    # Per-step structured perf log (Test.Perf.psm1). Initialized AFTER
    # the host diagnostic write so hostInfoHash points at the freshly
    # captured dump; cycleHostDiagOut may not exist (script missing /
    # capture failed), in which case Start-PerfCycle leaves the hash
    # null and downstream rows just lose that one dimension.
    if (Get-Command -Name Start-PerfCycle -ErrorAction SilentlyContinue) {
        try {
            Start-PerfCycle `
                -CycleId            $CycleId `
                -HostPlatform       $HostType `
                -Hostname           $Hostname `
                -HarnessCommit      $GitCommit `
                -ProjectCommit      $ProjectGitCommit `
                -HostDiagnosticPath $cycleHostDiagOut
        } catch {
            Write-Warning "Start-PerfCycle failed (non-fatal): $($_.Exception.Message)"
        }
    }
}

function Get-GitHubConnectivityDiagnostic {
    <#
    .SYNOPSIS
        Probe DNS + TCP:443 reachability of github.com so a failed cycle-start
        `git pull` can be told apart from a local branch divergence.
    .DESCRIPTION
        Two probes: DNS resolution of github.com (catches NIC-down / no-DNS /
        Wi-Fi-off -- the observed symptom was literally "Could not resolve host:
        github.com") then a 3s TCP connect to :443 (catches firewall/proxy states
        where DNS resolves but HTTPS does not). The caller emits a network-specific
        operator message and suppresses the divergence/auth causes when either
        probe fails, and classifies the infra failure as network_timeout vs
        bootstrap_sync off the two flags. Reads only the fixed host/port and never
        throws (both probes are try-guarded).
    .OUTPUTS
        [hashtable] with DnsOk, TcpOk (both [bool]) and Message ([string], '' when
        both probes pass).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $dnsOk = $false; $tcpOk = $false; $msg = ''
    try { [void][System.Net.Dns]::GetHostAddresses('github.com'); $dnsOk = $true } catch {
        $msg = "DNS resolution of github.com failed: $($_.Exception.Message)"
    }
    if ($dnsOk) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $async = $tcp.BeginConnect('github.com', 443, $null, $null)
            $tcpOk = $async.AsyncWaitHandle.WaitOne(3000) -and $tcp.Connected
            $tcp.Close()
            if (-not $tcpOk) { $msg = 'TCP connect to github.com:443 timed out (DNS resolved but HTTPS unreachable)' }
        } catch {
            $msg = "TCP connect to github.com:443 threw: $($_.Exception.Message)"
        }
    }
    return @{ DnsOk = $dnsOk; TcpOk = $tcpOk; Message = $msg }
}

function Write-GitPullFailureBanner {
    <#
    .SYNOPSIS
        Print the cycle-start git-sync failure banner, steering the operator to
        host-side network causes (unplugged NIC, dropped Wi-Fi, dead DNS) when a
        DNS/TCP probe failed, or git-side causes (divergence/uncommitted/auth)
        when the network is fine. Pure output; the probe result comes from
        Get-GitHubConnectivityDiagnostic.
    #>
    [CmdletBinding()]
    param([bool]$DnsOk, [bool]$TcpOk, [string]$NetDiag)
    Write-Output ""
    Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Output "  ERROR: git sync failed"
    if (-not $DnsOk -or -not $TcpOk) {
        Write-Output "  Network connectivity issue detected: $NetDiag"
        Write-Output "  Likely host-side causes (check these FIRST):"
        Write-Output "  - Ethernet cable unplugged / NIC reset / driver crash"
        Write-Output "  - Wi-Fi disabled / SSID dropped / Wi-Fi card disabled in Device Manager"
        Write-Output "  - DNS server unreachable (router rebooting, ISP outage)"
        Write-Output "  - Captive portal not re-authenticated (hotel/conference Wi-Fi)"
        Write-Output "  - VPN dropped (corporate DNS no longer reachable)"
        Write-Output "  Quick checks:"
        Write-Output "    Windows : ipconfig ; Get-NetAdapter ; Test-NetConnection github.com -Port 443"
        Write-Output "    Linux   : ip addr ; ping -c 3 8.8.8.8 ; ping -c 3 github.com"
        Write-Output "    macOS   : ifconfig ; ping -c 3 8.8.8.8 ; ping -c 3 github.com"
        Write-Output "  Once connectivity is restored the runner will resume on the next outer-loop tick."
    } else {
        Write-Output "  Could not update from remote. Possible causes:"
        Write-Output "  - Local branch has diverged (rebase/merge manually)"
        Write-Output "  - Uncommitted local changes blocking fast-forward"
        Write-Output "  - GitHub authentication / token expired"
        Write-Output "  (Network probes passed: DNS + TCP/443 to github.com both OK, so this is NOT a connectivity problem.)"
    }
    Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Output ""
}

function Write-CapabilityGateFailureBanner {
    <#
    .SYNOPSIS
        Print the capability-gate failure banner: the cycle plan references a host
        I/O action no backend on this host registered, or requires OCR with no
        provider available. Pure output; $Cap is a Test-CyclePlanCapabilityFromPlan
        result. The caller still zeroes the guest list + writes the infra record.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Cap)
    Write-Output ""
    Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Output "  CAPABILITY GATE FAILED -- cycle aborted on '$($Cap.hostType)'."
    if ($Cap.missingHostIO.Count) {
        Write-Output "  Sequences reference host I/O actions this host has no backend for:"
        foreach ($a in $Cap.missingHostIO) { Write-Output "    - $a" }
        Write-Output "  Wire a backend via Register-HostIOProvider in Invoke-Sequence.psm1,"
        Write-Output "  or drop the requiring action from the cycle's sequence YAMLs."
    }
    if ($Cap.ocrRequired -and -not $Cap.ocrAvailable) {
        Write-Output "  Sequences require OCR but no OCR provider is enabled+available."
        Write-Output "  Install tesseract or wire a per-host provider via Register-OcrProvider."
    }
    Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
}

function Write-CycleInfraFailure {
    <#
    .SYNOPSIS
        Land a schema-v2 infra-failure record (on disk + the event stream + the
        dashboard) for a cycle stage that fails OUTSIDE the sequence engine (git
        sync, project clone, plan, image, VM provisioning). Those stages never
        write last_failure.json or a step_failure event on their own, leaving the
        remediation loop blind to half the failure surface.
    .DESCRIPTION
        Writes to the LOG ROOT ($env:YURUNA_LOG_DIR) when set -- where the engine
        writes last_failure.json and where the routing consumers (Get-Outer-
        LastFailureClass, Invoke-Remediation) read it -- else the per-cycle folder
        (bootstrap stages before Start-LogFile). Never clobbers a richer engine-
        written record (writes only when last_failure.json is absent), and is
        fully guarded (every builder call gated on Get-Command; one catch) so
        telemetry can never fail the cycle. The builders (New-InfraFailureRecord,
        Write-YurunaStateFile, Send-CycleEventSafely, Set-LastFailureSummary) are
        imported -Global by the runner and resolved from the global scope; if none
        is resolvable this is a no-op -- Test.RunnerInnerLoop's
        'Write-CycleInfraFailure' Pester test asserts the record IS written when the
        builders are present, so a resolution break fails loudly instead of
        silently dropping infra records. $HostType is passed explicitly (it was a
        captured local while this was an in-cycle closure).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = '$global:__YurunaCycleFolder is the cross-module per-cycle folder handle; used only as the fallback record directory when $env:YURUNA_LOG_DIR is unset.')]
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$FailureClass,
        [string]$Severity = 'hard',
        [string]$GuestKey = '',
        [string]$VMName = '',
        [string]$ErrorMessage = '',
        [Parameter(Mandatory)][string]$HostType
    )
    try {
        $dir = if ($env:YURUNA_LOG_DIR) { $env:YURUNA_LOG_DIR }
               elseif ($global:__YurunaCycleFolder) { $global:__YurunaCycleFolder }
               else { $null }
        if (-not $dir) { return }
        if (-not (Get-Command New-InfraFailureRecord -ErrorAction SilentlyContinue)) { return }
        $rec = New-InfraFailureRecord -Stage $Stage -FailureClass $FailureClass -Severity $Severity `
            -GuestKey $GuestKey -VMName $VMName -HostType $HostType -ErrorMessage $ErrorMessage
        $failFile = Join-Path $dir 'last_failure.json'
        if (-not (Test-Path -LiteralPath $failFile) -and (Get-Command Write-YurunaStateFile -ErrorAction SilentlyContinue)) {
            $null = Write-YurunaStateFile -Path $failFile -Content ($rec.File | ConvertTo-Json -Depth 6) -Confirm:$false
        }
        if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
            Send-CycleEventSafely -EventRecord $rec.Event
        }
        if (Get-Command Set-LastFailureSummary -ErrorAction SilentlyContinue) {
            Set-LastFailureSummary -FailureClass $FailureClass -Severity $Severity `
                -SequenceName $Stage -GuestKey $GuestKey -StepName $Stage `
                -ErrorMessage $ErrorMessage -VmName $VMName -Confirm:$false
        }
    } catch { $null = $_ }
}

function Invoke-RunnerBootstrapFailureGate {
    <#
    .SYNOPSIS
        Route a bootstrap-stage failure (git pull / project clone -- the stages
        that fail before a cycle plan exists) through the SAME consecutive-failure
        notification gating as an in-cycle failure, so a persistent bootstrap
        problem alerts once per streak instead of once per cycle.
    .DESCRIPTION
        Bumps the streak counters and, when armed AND the failure count has reached
        the alert threshold, sends one Send-CycleFailureNotification and disarms
        until the streak clears. The caller owns the cycle outcome: it sets
        $OverallPassed=$false and `break` so the carry-back persists the gating
        counters across the single-cycle respawn and the process exits non-zero
        (the outer then enters its failure-pause). A bootstrap failure is not a
        code crash, so $ConsecutiveCrashes is left untouched -- a persistent outage
        is throttled by the outer failure-pause, not the MaxConsecutiveCrashes
        abort. The GitPull and ProjectClone paths shared this block verbatim; only
        Stage / ErrorMessage / GitCommit / FailureClass differ.

        Mutates $GatingState IN PLACE (ConsecutiveFailures / ConsecutiveSuccesses /
        AlertArmed; reads FailuresBeforeAlert / SuccessesBeforeRearm) and writes its
        status lines straight to the pipeline. Do NOT capture this function's output
        -- doing so would swallow the console lines (and the mutation is the
        contract, not a return value).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Mutates the passed gating-state bag and sends one notification for an already-decided failure; the caller owns the cycle-outcome flag + break, so ShouldProcess would not fit.')]
    param(
        [Parameter(Mandatory)][hashtable]$GatingState,
        [Parameter(Mandatory)][string]$Stage,
        [string]$ErrorMessage = '',
        [AllowNull()][string]$GitCommit,
        [Parameter(Mandatory)][string]$FailureClass,
        [Parameter(Mandatory)][string]$HostType
    )
    $GatingState.ConsecutiveSuccesses = 0
    $GatingState.ConsecutiveFailures++
    Write-Output "  Alert:   $($GatingState.ConsecutiveFailures)/$($GatingState.FailuresBeforeAlert) failures $(if ($GatingState.AlertArmed) {'(armed)'} else {'(suppressed)'})"
    if ($GatingState.AlertArmed -and $GatingState.ConsecutiveFailures -ge $GatingState.FailuresBeforeAlert) {
        Send-CycleFailureNotification `
            -HostType            $HostType `
            -SubjectSuffix       $Stage `
            -GuestKey            '(bootstrap)' `
            -StepName            $Stage `
            -ErrorMessage        $ErrorMessage `
            -CycleId             '(not yet assigned)' `
            -GitCommit           $GitCommit `
            -DefaultFailureClass $FailureClass `
            -DefaultSeverity     'hard'
        $GatingState.AlertArmed = $false
        Write-Output "  Notification sent. Alert suppressed until $($GatingState.SuccessesBeforeRearm) consecutive successes or runner restart."
    } else {
        Write-Output "  Notification suppressed ($($GatingState.ConsecutiveFailures)/$($GatingState.FailuresBeforeAlert) failures, armed=$($GatingState.AlertArmed))."
    }
}

<#
.SYNOPSIS
    Run the runner's single inner cycle: git pull, project clone, module
    re-import, plan resolution, per-guest provision/sequence execution, failure
    capture, notification gating, and the inter-cycle delay, driven by $State.
#>
function Invoke-RunnerInnerCycle {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = '$global:__Yuruna* are the cross-module channels with Yuruna.Log (per-cycle folder, run id, HTML transcript) the cycle body reads.')]
    param([Parameter(Mandatory)][hashtable]$State)
    # Fail fast on a malformed $State so a renamed/dropped key is named at the call
    # boundary instead of surfacing as a null-deref deep inside the cycle body.
    Assert-RunnerCycleState -State $State
    $RepoRoot          = $State.RepoRoot
    $TestRoot          = $State.TestRoot
    $SequencesDir      = $State.SequencesDir
    $ScreenshotsDir    = $State.ScreenshotsDir
    $StatusFile        = $State.StatusFile
    $ConfigPath        = $State.ConfigPath
    $TemplatePath      = $State.TemplatePath
    $HostType          = $State.HostType
    $ModulesDir        = $State.ModulesDir
    $NoServer          = $State.NoServer
    $NoGitPull         = $State.NoGitPull
    $NoProjectClone    = $State.NoProjectClone
    $CycleDelaySeconds = $State.CycleDelaySeconds
    $cachingProxyUrl   = $State.CachingProxyUrl
    $startScript       = $State.StartScript
    $StepHeartbeatFile = $State.StepHeartbeatFile
    # Shared with the entry point's Ctrl+C handler (same dictionary instance),
    # so a flip of ['Requested'] there ends this cycle.
    $ShutdownState     = $State.ShutdownState
    # Config-reload state: Sync-RunnerCycleConfig mutates $cfg and the body
    # re-reads the mirrored locals after each sync.
    $cfg                  = $State.RunnerCfgState
    $Config               = $State.Config
    $StopOnFailure        = $cfg.StopOnFailure
    $GetImageRefreshHours = $cfg.GetImageRefreshHours
    $CycleDelay           = $cfg.CycleDelay
# === Continuous test loop ===
# Load the cycle counter + gating counters (persisted across the single-cycle
# respawn via status.json + runner.gating.json) and reassign each local by name.
# The crash counter drives the escalating auto-retry backoff and the hard
# MaxConsecutiveCrashes abort further down; a cycle that reaches finalization
# (pass OR guest-failure) resets it to 0. The gating latch follows
# Armed -> (N failures) -> Fired -> (M successes) -> Armed.
$gatingState          = Initialize-CycleGatingState -StatusFile $StatusFile -Config $Config -RuntimeDir $env:YURUNA_RUNTIME_DIR
$CycleCount           = $gatingState.CycleCount
$ConsecutiveCrashes   = $gatingState.ConsecutiveCrashes
$FailuresBeforeAlert  = $gatingState.FailuresBeforeAlert
$SuccessesBeforeRearm = $gatingState.SuccessesBeforeRearm
$ConsecutiveFailures  = $gatingState.ConsecutiveFailures
$ConsecutiveSuccesses = $gatingState.ConsecutiveSuccesses
$AlertArmed           = $gatingState.AlertArmed
$GatingFile           = $gatingState.GatingFile
$OverallPassed        = $true
$MaxConsecutiveCrashes = 3

# Run-once scope: per-cycle iteration is owned by the outer Invoke-TestRunner.ps1,
# so this body executes exactly once. do/while($false) states that single pass
# explicitly; the body's early-exit `break`s each funnel to the post-loop $State
# copy below, and no `continue` re-runs the scope.
do {
    if ($ShutdownState['Requested']) {
        Write-Output "Shutdown requested. Exiting cycle loop."
        break
    }

    # Re-check host conditions each cycle -- settings can revert (OS
    # update, manual change) between long-running cycles.
    if (-not (Assert-HostConditionSet -HostType $HostType)) {
        Write-Warning "Host conditions failed. Fix the reported issues and restart."
        break
    }

    # Ensure a usable display surface for this cycle (e.g. attach a virtual
    # display on a headless Hyper-V host) so screen-capture/OCR survives the
    # physical monitor coming and going mid-run (KVM switch). Opt-in: the
    # Hyper-V virtual display attaches only when YURUNA_VIRTUAL_DISPLAY is set.
    # Idempotent and cheap -- short-circuits when already present; no-op on
    # hosts that need nothing (or when the opt-in is off). Never throws.
    # See docs/host-hyperv.md.
    Initialize-HostDisplay -HostType $HostType

    $CycleCount++
    $OverallPassed  = $true
    $FailedGuest    = $null
    $FailedStep     = $null
    $FailureMessage = $null
    $script:CycleFinalized = $false
    $Warnings = [System.Collections.Generic.List[string]]::new()

    # Infra-stage failures (git sync, project clone, plan, image, VM provisioning)
    # fail outside the sequence engine, so they get a classified, routable
    # last_failure.json + event record via Write-CycleInfraFailure below.

  try {

    Write-Output ""
    Write-Output "============================================="
    Write-Output "  CYCLE $CycleCount"
    Write-Output "  (inner cycle starting -- local time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))"
    Write-Output "============================================="

    # --- REGION: Authentication vault: fresh per cycle
    Initialize-CycleAuthVault

    # --- REGION: Reset status.json for cycle start
    # The dashboard stops showing the previous cycle's pass/fail + per-guest
    # pills while the slow setup below (git pull, project clone, status-service
    # restart, module re-imports, cycle-plan resolution) runs.
    # Initialize-StatusDocument later populates the fully-shaped doc once the
    # guest list is known.
    Reset-StatusDocumentForCycleStart -StatusFilePath $StatusFile -Confirm:$false

    # --- REGION: Git pull
    # Unconditional single-shot pull at cycle start by design. Gating on
    # `git ls-remote HEAD` SHA vs local to skip no-op fetches would be
    # two round-trips to github.com (ls-remote + pull) where one already
    # does the work; the single `pull --ff-only` is the source of truth
    # for "did HEAD move?" without an extra network call. Keeping it
    # unconditional also means a host that just came back online
    # recovers in one cycle without an extra branch.
    if (-not $NoGitPull) {
        if (-not (Invoke-GitPull -RepoRoot $RepoRoot)) {
            # Differentiate a network outage from a local branch divergence so the
            # operator is not sent to "rebase/merge manually" for an unplugged NIC.
            # The two flags also classify the infra failure (network_timeout vs
            # bootstrap_sync) below. See Get-GitHubConnectivityDiagnostic.
            $netProbe = Get-GitHubConnectivityDiagnostic
            $dnsOk   = $netProbe.DnsOk
            $tcpOk   = $netProbe.TcpOk
            $netDiag = $netProbe.Message

            Write-GitPullFailureBanner -DnsOk $dnsOk -TcpOk $tcpOk -NetDiag $netDiag
            $gitPullErr = "Git sync failed. Branch may have diverged, or network is unreachable."
            $gitPullCommit = (Get-CurrentGitCommit -RepoRoot $RepoRoot)
            # Bootstrap-stage failure -- no cycle folder yet, so the helper
            # builds a minimal payload from these scalars. The infra record above
            # already wrote the canonical class (network_timeout when a DNS/TCP
            # probe failed, else bootstrap_sync) + severity 'hard'; pass the same
            # so extensions route on failureClass instead of free-text grep.
            # Network sub-case (a DNS/TCP probe failed) is the transient, retryable
            # kind -> network_timeout; otherwise a divergence / auth / dirty-tree
            # git failure -> bootstrap_sync (operator). Write the schema-v2 record
            # before the notification so its EventData picks up the real class.
            $gitClass = if (-not $dnsOk -or -not $tcpOk) { 'network_timeout' } else { 'bootstrap_sync' }
            Write-CycleInfraFailure -Stage 'GitPull' -FailureClass $gitClass -GuestKey '(bootstrap)' -ErrorMessage $gitPullErr -HostType $HostType
            # Route this bootstrap failure through the shared consecutive-failure
            # notification gating (see Invoke-RunnerBootstrapFailureGate). break +
            # $OverallPassed=$false carry the counters across the single-cycle
            # respawn and exit non-zero into the outer failure-pause; a sync failure
            # is not a code crash, so $ConsecutiveCrashes is left untouched.
            $OverallPassed = $false
            $bootstrapGate = @{
                ConsecutiveFailures  = $ConsecutiveFailures
                ConsecutiveSuccesses = $ConsecutiveSuccesses
                AlertArmed           = $AlertArmed
                FailuresBeforeAlert  = $FailuresBeforeAlert
                SuccessesBeforeRearm = $SuccessesBeforeRearm
            }
            Invoke-RunnerBootstrapFailureGate -GatingState $bootstrapGate -Stage 'GitPull' `
                -ErrorMessage $gitPullErr -GitCommit $gitPullCommit -FailureClass $gitClass -HostType $HostType
            $ConsecutiveFailures  = $bootstrapGate.ConsecutiveFailures
            $ConsecutiveSuccesses = $bootstrapGate.ConsecutiveSuccesses
            $AlertArmed           = $bootstrapGate.AlertArmed
            break
        }
    } else {
        $Warnings.Add("Git pull was skipped (-NoGitPull).")
    }
    $GitCommit = Get-CurrentGitCommit -RepoRoot $RepoRoot

    # --- REGION: Pooled repos override. When this host is in a pool with an
    # assigned testSet (runtime/pool.manifest.json, written by the outer loop's
    # Sync-YurunaPoolIntent), the pool's framework/project repo PAIR overrides this
    # host's repositories.frameworkUrl / repositories.projectUrl for THIS cycle, so
    # the project refresh + framework clone below use the pool's repos. GH_TOKEN is
    # deliberately NOT overridden -- it stays host-local (never travels in pool
    # intent). Unpooled hosts (no manifest / no testSet) are untouched.
    if ($Config -is [System.Collections.IDictionary] -and $Config.repositories -is [System.Collections.IDictionary]) {
        $poolManifestForRepos = if (Get-Command Read-YurunaPoolManifest -ErrorAction SilentlyContinue) { Read-YurunaPoolManifest } else { $null }
        $poolTestSet = if ($poolManifestForRepos -is [System.Collections.IDictionary]) { $poolManifestForRepos['testSet'] } else { $null }
        if ($poolTestSet -is [System.Collections.IDictionary] -and $poolTestSet['frameworkUrl'] -and $poolTestSet['projectUrl']) {
            $Config.repositories['frameworkUrl'] = [string]$poolTestSet['frameworkUrl']
            $Config.repositories['projectUrl']   = [string]$poolTestSet['projectUrl']
            Write-Information ("Pool '{0}' testSet '{1}': repositories overridden (framework={2}, project={3}); GH_TOKEN stays host-local." -f `
                [string]$poolManifestForRepos['poolId'], [string]$poolTestSet['name'], [string]$poolTestSet['frameworkUrl'], [string]$poolTestSet['projectUrl']) -InformationAction Continue
        }
    }

    # --- REGION: Refresh <RepoRoot>/project from test.config.yml's repositories.projectUrl
    # Cycle starts from a clean project tree so previous cycle artifacts
    # (resources.output*.yml, helm renders, generated kubeconfigs) cannot
    # leak forward. Skipped when repositories.projectUrl is empty - that path is
    # the in-tree stop-gap where project/ ships with the framework repo.
    $projUrl = $null
    if ($Config -is [System.Collections.IDictionary] -and
        $Config.repositories -is [System.Collections.IDictionary] -and
        $Config.repositories.Contains('projectUrl')) {
        $projUrl = [string]$Config.repositories.projectUrl
    }
    if ($NoProjectClone) {
        # Test-Project.ps1 spawn path: the wipe + clone happened in the
        # parent before we were invoked. Trust the on-disk state; just
        # verify the project's .git is present so the cycle's downstream
        # consumers (HEAD capture, sequence planner, fetch-and-execute
        # tarball builders) don't trip over a missing tree.
        $projectDir = Join-Path $RepoRoot 'project'
        if (-not (Test-Path -LiteralPath (Join-Path $projectDir '.git'))) {
            Write-Warning "-NoProjectClone is set but $projectDir/.git is missing. Cannot proceed; the caller must clone the project before invoking the inner runner."
            $cloneRes = @{ success = $false; skipped = $false; errorMessage = "No project clone at $projectDir (-NoProjectClone)." }
        } else {
            Write-Information "Project clone skipped (-NoProjectClone). Using existing $projectDir." -InformationAction Continue
            $cloneRes = @{ success = $true; skipped = $false; errorMessage = $null }
        }
    } else {
        $cloneRes = Update-ProjectClone -RepoRoot $RepoRoot -ProjectUrl $projUrl -Confirm:$false
    }
    if (-not $cloneRes.success) {
        Write-Warning "Project clone failed: $($cloneRes.errorMessage). Retrying next cycle."
        # Bootstrap-stage failure -- no cycle folder yet, so the helper builds a
        # minimal payload from these scalars. The infra record above already wrote
        # the canonical 'bootstrap_sync' / 'hard'; pass the same so extensions
        # route on failureClass instead of free-text grep.
        Write-CycleInfraFailure -Stage 'ProjectClone' -FailureClass 'bootstrap_sync' -GuestKey '(bootstrap)' -ErrorMessage $cloneRes.errorMessage -HostType $HostType
        # Route through the shared consecutive-failure notification gating (see
        # Invoke-RunnerBootstrapFailureGate). break + $OverallPassed=$false carry the
        # counters across the single-cycle respawn and exit non-zero into the outer
        # failure-pause (60-min cap, polled for new commits); like git-pull this is
        # not a code crash, so $ConsecutiveCrashes is left untouched.
        $OverallPassed = $false
        $bootstrapGate = @{
            ConsecutiveFailures  = $ConsecutiveFailures
            ConsecutiveSuccesses = $ConsecutiveSuccesses
            AlertArmed           = $AlertArmed
            FailuresBeforeAlert  = $FailuresBeforeAlert
            SuccessesBeforeRearm = $SuccessesBeforeRearm
        }
        Invoke-RunnerBootstrapFailureGate -GatingState $bootstrapGate -Stage 'ProjectClone' `
            -ErrorMessage $cloneRes.errorMessage -GitCommit $GitCommit -FailureClass 'bootstrap_sync' -HostType $HostType
        $ConsecutiveFailures  = $bootstrapGate.ConsecutiveFailures
        $ConsecutiveSuccesses = $bootstrapGate.ConsecutiveSuccesses
        $AlertArmed           = $bootstrapGate.AlertArmed
        break
    }

    # --- REGION: Capture project repo HEAD
    # Now that the project is freshly cloned at <RepoRoot>/project/, snapshot
    # its HEAD short-SHA so the dashboard can link both repos' latest changes
    # for this cycle. Empty/skipped repositories.projectUrl (in-tree fallback path)
    # leaves $ProjectGitCommit as $null; if `Get-CurrentGitCommit` returns
    # 'unknown' (no .git/, or git missing) we also leave it $null so the
    # array we hand to Initialize-StatusDocument stays clean.
    $ProjectGitCommit = $null
    if ($cloneRes.success -and -not $cloneRes.skipped) {
        $projectDir = Join-Path $RepoRoot 'project'
        if (Test-Path (Join-Path $projectDir '.git')) {
            $maybe = Get-CurrentGitCommit -RepoRoot $projectDir
            if ($maybe -and $maybe -ne 'unknown') { $ProjectGitCommit = $maybe }
        }
    }
    # The gitCommits entry's repoUrl is a commit deep-link base, and the status
    # page / pool dashboard only link http(s) values. repositories.projectUrl may
    # legitimately be a local clone path or an ssh remote (both valid clone
    # sources), so resolve it to the underlying web URL for the link; keep the
    # raw value when nothing resolves so the project SHA still shows (unlinked)
    # rather than dropping out of the Commit column.
    $projLinkUrl = $projUrl
    if ($ProjectGitCommit) {
        $resolvedProjUrl = Resolve-GitRepositoryWebUrl -Url $projUrl
        if ($resolvedProjUrl) { $projLinkUrl = $resolvedProjUrl }
    }

    # --- REGION: Unconditional working-tree-drift warning
    # /yuruna-archive.tar.gz and /yuruna-project-archive.tar.gz only ship
    # COMMITTED content (`git archive HEAD`). Surface uncommitted local
    # changes via Write-Warning -- bypasses logLevel -- so the operator
    # catches the divergence before a guest hits a "script not found"
    # trap caused by host code referencing a path that isn't yet in HEAD.
    Write-UncommittedChangesWarning -RepoRoot $RepoRoot -ProjectUrl $projUrl

    # --- REGION: Re-import modules so a mid-run `git pull` propagates code changes
    Update-CycleModuleImport -RepoRoot $RepoRoot -HostType $HostType -ModulesDir $ModulesDir

    # --- REGION: Re-read config (may have changed via git pull); sync against template
    $Config = Update-CycleConfigFromTemplate -ConfigPath $ConfigPath -TemplatePath $TemplatePath -PreviousConfig $Config

    # --- REGION: Restart status server to pick up any file/config changes
    # -Restart forces a relaunch so a mid-cycle git pull / config edit is
    # reflected; the shared gate honors isEnabled / -NoServer / port identically
    # to the startup path and Test-Sequence.
    $null = Start-YurunaStatusServiceIfEnabled -Config $Config -StartScript $startScript -NoServer:$NoServer -Restart

    # The Host Config Service is intentionally NOT ensured here: it is a
    # caching-proxy companion (owned by Start-CachingProxy.ps1 on the caching-proxy
    # host), not a per-cycle runner concern. Coupling it to the test loop would
    # start it on plain runner hosts that never host a caching proxy, and would not
    # help a dedicated caching-proxy host that doesn't run the runner.

    # Build per-cycle execution plan from project/test/test.runner.yml.
    # Each plan entry is a (top-level workload, guest, sequence chain) tuple;
    # multiple top-levels can share a guest, so we dedupe to GuestList for
    # the parts of the cycle that operate per unique VM (folder check,
    # Get-Image, the cleanup -> create -> start -> verify per-guest loop).
    # Falls back to the legacy guestSequence list when the cycle config is
    # missing -- useful before the project repo clone bootstrap lands and
    # for operators who haven't migrated yet.
    $script:CyclePlan = $null
    $plannerFatal     = $false
    $script:PoolCycle = $false
    try {
        # A pooled host has already had its repositories.frameworkUrl/projectUrl
        # redirected to the pool's testSet (the "Pooled repos override" region
        # earlier), so from here the cycle plan resolves from the assigned
        # project's own test.runner.yml exactly like an unpooled host -- there is
        # no separate pool cycle-plan. $script:PoolCycle just records that this is
        # a pooled run (for status/labeling). A sequence typo still throws
        # PlannerFatal, so the catch's banner aborts the cycle as before.
        $poolManifest = if (Get-Command Read-YurunaPoolManifest -ErrorAction SilentlyContinue) { Read-YurunaPoolManifest } else { $null }
        $script:PoolCycle = ($poolManifest -is [System.Collections.IDictionary]) -and ($poolManifest['testSet'] -is [System.Collections.IDictionary])
        $script:CyclePlan = Resolve-CyclePlan -RepoRoot $RepoRoot -SequencesDir $SequencesDir -HostType $HostType
    } catch {
        # PlannerFatal (currently: duplicate project sequence files with the
        # same name under different test/<mode>/ folders) means the plan is
        # ambiguous -- silently falling back to guestSequence would let the
        # cycle run against an arbitrary winner. Print the error prominently
        # and short-circuit GuestList to empty so the foreach loop below
        # runs zero iterations. Cycle still flows through "Finalise cycle"
        # naturally so $OverallPassed=false bumps ConsecutiveFailures and
        # fires notifications on the same threshold as any other failure.
        if ($_.Exception.Message -like 'PlannerFatal:*') {
            Write-Output ""
            Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            Write-Output "  PLANNER ERROR -- cycle aborted, no guests will run."
            foreach ($line in (($_.Exception.Message -replace '^PlannerFatal:\s*','') -split "`n")) {
                Write-Output "  $line"
            }
            Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            $plannerFatal   = $true
            $OverallPassed  = $false
            $FailedGuest    = "(planner)"
            $FailedStep     = "Resolve-CyclePlan"
            $FailureMessage = $_.Exception.Message
            Write-CycleInfraFailure -Stage 'Resolve-CyclePlan' -FailureClass 'plan_invalid' -GuestKey '(planner)' -ErrorMessage $FailureMessage -HostType $HostType
        } else {
            # Inner message now embeds the offending file path (Read-SequenceFile
            # walks the YamlDotNet exception chain to surface file + line:col),
            # so don't prefix with project/test/test.runner.yml -- the actual
            # failure may be in any sequence the planner walked to.
            Write-Warning "Could not resolve cycle plan - falling back to guestSequence: $($_.Exception.Message)"
        }
    }
    $guestSeqLists = Get-CycleGuestAndSequenceList -PlannerFatal $plannerFatal -CyclePlan $script:CyclePlan -Config $Config
    $GuestList    = $guestSeqLists.GuestList
    $SequenceList = $guestSeqLists.SequenceList

    # --- REGION: Orchestration top-level (InvokeTestSequence playbook)
    # A test.runner.yml entry can be an orchestration sequence (no resource:/
    # baseline; steps are InvokeTestSequence). It contributes no per-guest plan
    # entries, so it owns the whole cycle via Invoke-OrchestrationSequence
    # (Test.Orchestrator) -- Reset/Initialize/Start-Log, one dashboard row per
    # inner sequence, Complete/seal -- exactly as a standalone `Test-Sequence
    # <orch>` run does. The runner delegates to it below instead of the per-guest
    # VM lifecycle, and forces GuestList empty so the empty-plan fallback to the
    # legacy guestSequence does NOT bring up a phantom guest (the bug this fixes).
    $isOrchestrationCycle = $false
    $orchestrationDoc     = $null
    $orchestrationName    = $null
    $orchestrationPath    = $null
    $orchestrations = @()
    if (-not $plannerFatal) {
        # Bare assignment, never @(Get-CycleOrchestrationList ...): the planner
        # returns its list through the ,@($list.ToArray()) array-preserving
        # idiom, which reaches the caller as a single already-wrapped object.
        # Re-collecting that with @(...) yields Count 1 for ANY true count --
        # 0, 1, or many alike -- which both fabricates an orchestration out of a
        # guest-only config (spurious orchestration-mix) and hides the
        # >1 case. Plain assignment preserves the real array (0/1/N).
        try { $orchestrations = Get-CycleOrchestrationList -RepoRoot $RepoRoot -SequencesDir $SequencesDir -HostType $HostType }
        catch { Write-Warning "Could not resolve orchestration list: $($_.Exception.Message)" }
    }
    if ($orchestrations.Count -gt 0) {
        # Orchestration + per-guest sequences can't share one status cycle (each
        # wants to own the doc), and two orchestrations would each own their own
        # cycle -- neither composes into this single-cycle runner pass. Reject the
        # ambiguous configs loudly and run nothing rather than silently pick one;
        # the plan_invalid infra-failure funnels to the same fail path as a typo.
        if ($script:CyclePlan -and $script:CyclePlan.Count -gt 0) {
            Write-Warning "test.runner.yml mixes an orchestration sequence with per-guest sequences; that is not supported in one cycle. Split them into separate runner configs."
            $OverallPassed = $false; $FailedGuest = "(planner)"; $FailedStep = "orchestration-mix"
            $FailureMessage = "orchestration + guest sequences in one test.runner.yml"
            Write-CycleInfraFailure -Stage 'orchestration-mix' -FailureClass 'plan_invalid' -GuestKey '(planner)' -ErrorMessage $FailureMessage -HostType $HostType
            $plannerFatal = $true; $GuestList = @(); $SequenceList = @()
        } elseif ($orchestrations.Count -gt 1) {
            Write-Warning "test.runner.yml lists $($orchestrations.Count) orchestration sequences; only one orchestration per cycle is supported."
            $OverallPassed = $false; $FailedGuest = "(planner)"; $FailedStep = "orchestration-multi"
            $FailureMessage = "multiple orchestration sequences in one test.runner.yml"
            Write-CycleInfraFailure -Stage 'orchestration-multi' -FailureClass 'plan_invalid' -GuestKey '(planner)' -ErrorMessage $FailureMessage -HostType $HostType
            $plannerFatal = $true; $GuestList = @(); $SequenceList = @()
        } else {
            $orchestrationName = [string]$orchestrations[0].name
            $orchestrationPath = [string]$orchestrations[0].path
            try {
                $orchestrationDoc = Read-SequenceFile -Path $orchestrationPath
                $isOrchestrationCycle = $true
            } catch {
                Write-Warning "Could not parse orchestration sequence '$orchestrationName': $($_.Exception.Message)"
                $OverallPassed = $false; $FailedGuest = "(orchestration)"; $FailedStep = $orchestrationName
                $FailureMessage = $_.Exception.Message
                Write-CycleInfraFailure -Stage 'orchestration-parse' -FailureClass 'plan_invalid' -GuestKey '(orchestration)' -ErrorMessage $FailureMessage -HostType $HostType
                $plannerFatal = $true
            }
            $GuestList = @(); $SequenceList = @()
        }
    }

    # Cascade the planner-effective username into Test.Ssh's Get-GuestSshUser
    # override registry so $vars-less SSH code paths target the cascaded account.
    Register-CycleGuestSshUserOverride -PlannerFatal $plannerFatal -CyclePlan $script:CyclePlan -GuestList $GuestList -ModulesDir $ModulesDir

    # --- REGION: Capability gate
    # Print the matrix once per cycle (helps post-mortem readers in the
    # cycle log) and refuse the cycle when the plan references a host
    # I/O action no backend on this host has registered -- catching it
    # here, at plan time, instead of as a silent "Unknown host: ..."
    # that surfaces only at runtime, deep inside a sequence step.
    if (-not $plannerFatal -and $script:CyclePlan -and $script:CyclePlan.Count -gt 0) {
        Write-HostCapabilityBanner
        $cap = Test-CyclePlanCapabilityFromPlan -Plan $script:CyclePlan -RepoRoot $RepoRoot -SequencesDir $SequencesDir -HostType $HostType
        if (-not $cap.supported) {
            Write-CapabilityGateFailureBanner -Cap $cap
            $GuestList      = @()
            $SequenceList   = @()
            $OverallPassed  = $false
            $FailedGuest    = "(capability gate)"
            $FailedStep     = "Test-CyclePlanCapability"
            $FailureMessage = "Missing host I/O: $($cap.missingHostIO -join ', '); ocrRequired=$($cap.ocrRequired) ocrAvailable=$($cap.ocrAvailable)"
            Write-CycleInfraFailure -Stage 'Test-CyclePlanCapability' -FailureClass 'plan_invalid' -GuestKey '(capability gate)' -ErrorMessage $FailureMessage -HostType $HostType
        }
        if ($cap.unknownActions.Count) {
            # Don't fail the cycle on an unknown verb -- the engine still
            # has its own switch which will throw at runtime, but surface
            # the typo early so the operator notices before the slow path.
            Write-Warning "Cycle plan references unknown action verbs (typo? new verb?): $($cap.unknownActions -join ', ')"
        }
    }
    $namingStrategy = Resolve-CycleVmNamingStrategy -Config $Config -IsPoolCycle $script:PoolCycle -HostId $global:__YurunaHostId
    $Prefix                 = $namingStrategy.Prefix
    $_poolHostId            = $namingStrategy.PoolHostId

    # Build VM name map via Get-TestVMName so any guestSequence key yields a
    # stable VM name -- no hardcoded per-guest lookup needed.
    $VMNames = New-CycleVmNameMap -GuestList $GuestList -Prefix $Prefix -HostId $_poolHostId

    # --- REGION: Derive step list from cycle plan and screenshot schedules
    $stepDerivation = Get-CycleStepNameList -GuestList $GuestList -CyclePlan $script:CyclePlan -ScreenshotsDir $ScreenshotsDir
    $StepNames      = $stepDerivation.StepNames
    $hasScreenshots = $stepDerivation.HasScreenshots
    $hasExtensions  = $stepDerivation.HasExtensions

    # Cycle-start reloadable knobs from the freshly-reconciled config, resolved
    # through the same tested rule set as the mid-cycle Sync-RunnerCycleConfig
    # refresh (Get-RunnerReloadableConfig): a 0/absent value falls back to the
    # default and CycleDelay honors the -CycleDelaySeconds override.
    $reloadable = Get-RunnerReloadableConfig -Config $Config -CycleDelayFallback $CycleDelaySeconds
    $CycleDelay           = $reloadable.CycleDelay
    $GetImageRefreshHours = $reloadable.GetImageRefreshHours
    $StopOnFailure        = $reloadable.StopOnFailure

    # --- REGION: Initialize status for this cycle
    # Assign the helper's result DIRECTLY -- do NOT wrap the call in @(). The unary
    # comma inside New-CycleGitCommitList already emits the whole list as one
    # pipeline item (so even a one-element list stays an array). Wrapping that single
    # array item in @() nests it one level deeper, yielding gitCommits = [[{...}]]
    # instead of [{...}] -- the array-double-wrap trap class. That malformed shape is
    # rejected by the status schema's gitCommits reader and by the pool aggregator,
    # which then cannot parse the host's status.json at all.
    # An orchestration cycle skips this whole block: Invoke-OrchestrationSequence
    # (delegated at "Finalise cycle" below) does its own Reset/Initialize-Status
    # Document + Start-LogFile so it owns the status doc + transcript. Running the
    # runner's Initialize here too would create an empty guest cycle that the
    # orchestrator then clobbers. $CycleId/$LogFile stay empty; the guest loop
    # (empty GuestList) and the failure-notification tail tolerate that.
    if ($isOrchestrationCycle) {
        $CycleId = ''
        $LogFile = ''
    } else {
        $GitCommitsList = New-CycleGitCommitList -GitCommit $GitCommit `
            -FrameworkUrl $Config.repositories.frameworkUrl `
            -ProjectGitCommit $ProjectGitCommit -ProjectUrl $projLinkUrl
        $CycleId = Initialize-StatusDocument `
            -StatusFilePath $StatusFile `
            -HostType       $HostType `
            -Hostname       (hostname) `
            -GitCommit      $GitCommit `
            -RepoUrl        $Config.repositories.frameworkUrl `
            -GitCommits     $GitCommitsList `
            -GuestList      $GuestList `
            -Sequences      $SequenceList `
            -StepNames      $StepNames

        # --- REGION: Seed per-guest provenance
        Set-CycleGuestProvenance -GuestList $GuestList

        # --- REGION: Start log file (transcript captures all console output)
        # CycleNumber is read AFTER Initialize-StatusDocument so it sees the
        # incremented value (1, 2, 3, ...). Drives the 6-digit prefix in the
        # cycleFolder name; Start-LogFile also publishes the folder URL onto
        # the status doc via Set-CycleFolderUrl so the dashboard can build
        # per-guest tile links from it.
        # CycleNumber (also returned by the helper) is not read downstream in the
        # cycle body -- it is consumed inside Start-CycleLogFile to name the cycle
        # folder -- so only LogFile is captured here.
        $LogFile = (Start-CycleLogFile -TestRoot $TestRoot -CycleId $CycleId -Hostname (hostname)).LogFile

        # --- REGION: Cycle-start host diagnostic + perf-log open
        Start-CycleHostDiagnostic -RepoRoot $RepoRoot -CycleId $CycleId -HostType $HostType `
            -Hostname (hostname) -GitCommit $GitCommit -ProjectGitCommit $ProjectGitCommit

        Write-Output "Cycle ID: $CycleId"
        # Commit line mirrors the dashboard's "Commit" meta-card: framework
        # SHA first, then the project SHA when repositories.projectUrl is set,
        # comma-space delimited (matching renderCommitLinks() in
        # status/index.html). $ProjectGitCommit is $null when the in-tree
        # fallback path is in use; in that case we emit framework-only so
        # the log doesn't show a dangling ", --".
        $CommitLine = if ($ProjectGitCommit) { "$GitCommit, $ProjectGitCommit" } else { $GitCommit }
        Write-Output "Commit:   $CommitLine"
    }

    # --- REGION: Pre-flight guest-folder check
    # Every guestSequence key needs a host/<short-host>/<guest>/ folder on this
    # host. No hardcoded allow-list -- this existence check IS the allow-list.
    # Missing folders fail the guest and skip it for the rest of the cycle;
    # shouldStopOnFailure ends the cycle now.
    $FailedGuests = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($GuestKey in $GuestList) {
        if (Test-GuestFolder -RepoRoot $RepoRoot -HostType $HostType -GuestKey $GuestKey) { continue }
        $folder = Join-Path $RepoRoot (Join-Path (Get-HostFolder $HostType) $GuestKey)
        $err = "Guest folder not found: $folder"
        Write-Warning "  ERROR [$GuestKey / folder check]: $err"
        Write-Output "  (add a $(Get-HostFolder $HostType)/$GuestKey/ directory with Get-Image.ps1 + New-VM.ps1 to enable this guest on $HostType)"
        Set-GuestStatus -GuestKey $GuestKey -Status "fail"
        # Attach the failure to the first step so the status UI shows it
        # on this guest's row (folder-check has no step of its own).
        if ($StepNames.Count -gt 0) {
            Set-StepStatus -GuestKey $GuestKey -StepName $StepNames[0] -Status "fail" -ErrorMessage $err
        }
        [void]$FailedGuests.Add($GuestKey)
        $OverallPassed = $false
        if (-not $FailedGuest) { $FailedGuest = $GuestKey; $FailedStep = "folder-check"; $FailureMessage = $err }
        Write-CycleInfraFailure -Stage 'folder-check' -FailureClass 'plan_invalid' -GuestKey $GuestKey -ErrorMessage $err -HostType $HostType
        if ($StopOnFailure) { break }
    }

    if ($StopOnFailure -and -not $OverallPassed) {
        Complete-Run -OverallStatus "fail" -MaxHistoryRuns ([int]$Config.testCycle.recentDisplayCount)
        $earlyAbortReason = if ($FailedGuest -and $FailedStep) { "$FailedGuest / $FailedStep" } else { 'shouldStopOnFailure tripped' }
        Stop-LogFile -Outcome 'fail' -Reason $earlyAbortReason
        break
    }

    $lastGetImage = Get-LastGetImageTime -StatusFilePath $StatusFile
    $needGetImage = (-not $lastGetImage) -or ((Get-Date).ToUniversalTime() - [datetime]$lastGetImage).TotalHours -ge $GetImageRefreshHours
    if ($needGetImage) {
        Write-Output ""
        Write-Output "--- Get-Image (${GetImageRefreshHours}h refresh) ---"
        foreach ($GuestKey in $GuestList) {
            if ($FailedGuests.Contains($GuestKey)) { continue }
            Write-Output "Downloading image for $GuestKey..."
            $r = Get-Image -GuestKey $GuestKey -RepoRoot $RepoRoot -Force -Confirm:$false
            if (-not $r.success) {
                # Refresh failed (network blip, mirror 5xx, partial transfer,
                # ...). If the cached image from a prior successful run is
                # still on disk, the baseline can still be retried; only
                # skip the guest when there is genuinely nothing to install
                # from. The next refresh window (or a manual rerun) gets
                # another shot at the upstream fetch.
                $cachedPath = Get-ImagePath -GuestKey $GuestKey
                $haveCached = $cachedPath -and (Test-Path $cachedPath)
                Write-Warning "  ERROR [$GuestKey / GetImage]: $($r.errorMessage)"
                if ($haveCached) {
                    Write-Output "  Cached image present at $cachedPath -- proceeding with cached baseline."
                    continue
                }
                Write-Output "  Log directory: $env:YURUNA_LOG_DIR"
                [void]$FailedGuests.Add($GuestKey)
                $OverallPassed = $false
                if (-not $FailedGuest) { $FailedGuest = $GuestKey; $FailedStep = "GetImage"; $FailureMessage = $r.errorMessage }
                Write-CycleInfraFailure -Stage 'GetImage' -FailureClass 'network_timeout' -GuestKey $GuestKey -ErrorMessage $r.errorMessage -HostType $HostType
                if ($StopOnFailure) { break }
                continue
            }
            Write-Output "  $GuestKey image: OK"
        }
        if ($OverallPassed) {
            Set-LastGetImageTime
            Write-Output "Get-Image complete. Timestamp updated."
        }
    } else {
        # Timer not expired, but verify each image exists. Re-download
        # any missing (manually deleted, first run after clean).
        $missingAny = $false
        foreach ($GuestKey in $GuestList) {
            if ($FailedGuests.Contains($GuestKey)) { continue }
            $imagePath = Get-ImagePath -GuestKey $GuestKey
            if (-not $imagePath -or -not (Test-Path $imagePath)) {
                $label = $imagePath ?? "$HostType/$GuestKey"
                Write-Output "Image file missing: $label -- re-downloading..."
                $r = Get-Image -GuestKey $GuestKey -RepoRoot $RepoRoot -Force -Confirm:$false
                if (-not $r.success) {
                    Write-Warning "  ERROR [$GuestKey / GetImage]: $($r.errorMessage)"
                    Write-Output "  Log directory: $env:YURUNA_LOG_DIR"
                    [void]$FailedGuests.Add($GuestKey)
                    $OverallPassed = $false
                    if (-not $FailedGuest) { $FailedGuest = $GuestKey; $FailedStep = "GetImage"; $FailureMessage = $r.errorMessage }
                    Write-CycleInfraFailure -Stage 'GetImage' -FailureClass 'network_timeout' -GuestKey $GuestKey -ErrorMessage $r.errorMessage -HostType $HostType
                    $missingAny = $true
                    if ($StopOnFailure) { break }
                    continue
                }
                Write-Output "  $GuestKey image: OK (re-downloaded)"
            }
        }
        if (-not $missingAny) {
            Write-Output "Get-Image: skipped (last run: $lastGetImage, all images present)"
        }
    }

    Write-CycleConfigLog -ConfigPath $ConfigPath

    # --- REGION: Abort cycle early if a pre-pipeline step failed under shouldStopOnFailure
    if ($StopOnFailure -and -not $OverallPassed) {
        Complete-Run -OverallStatus "fail" -MaxHistoryRuns ([int]$Config.testCycle.recentDisplayCount)
        $prePipelineReason = if ($FailedGuest -and $FailedStep) { "$FailedGuest / $FailedStep (pre-pipeline)" } else { 'shouldStopOnFailure tripped pre-pipeline' }
        Stop-LogFile -Outcome 'fail' -Reason $prePipelineReason
        break
    }

    # --- REGION: Cycle-start VM sweep
    Remove-CycleStartOrphanVM -TestRoot $TestRoot -Prefix $Prefix

    # Re-assert the host driver into the GLOBAL session before the guest loop.
    # The &-invoked child scripts run just above (status-service restart, the
    # Remove-TestVMFiles VM sweep) execute nested in this module's session
    # state, where a -Force import without -Global pulls the host driver out of
    # the global table (the legacy-eviction regression class). Host-contract
    # calls made from THIS module's scope (New-VM/Start-VM) still resolve from
    # the module copy, but a call made from a FOREIGN module mid-sequence
    # (Invoke-Sequence's Restart-VMConsole repaint at sequence start) needs the
    # GLOBAL copy. Re-importing here is idempotent and cheap, and restores the
    # global contract for the sequence engine.
    [void](Initialize-YurunaHost -RepoRoot $RepoRoot -HostType $HostType)

    # --- REGION: Test each guest sequentially: cleanup -> create -> start -> verify -> screenshots -> pool test -> stop
    # One guest VM at a time, so failures don't leave other VMs active.
    foreach ($GuestKey in $GuestList) {
        # Circuit breaker: a guest quarantined by earlier same-class failures is
        # skipped (up to SkipCycles cycles or until a framework/project commit
        # changes) so it stops burning a full provision+deploy every cycle. The
        # gate persists its own skip-budget decrement / release; the loud
        # dashboard flag keeps the skipped guest visible, not silently passing.
        if ($cfg.GuestQuarantineEnabled -and (Get-Command Invoke-GuestQuarantineGate -ErrorAction SilentlyContinue)) {
            $qGate = Invoke-GuestQuarantineGate -RuntimeDir $env:YURUNA_RUNTIME_DIR -GuestKey $GuestKey `
                -GitCommit $GitCommit -ProjectGitCommit $ProjectGitCommit
            if ($qGate.Skip) {
                Write-Output ""
                Write-Output "== $GuestKey (skipped -- quarantined after repeated same-class failures) =="
                Set-GuestStatus     -GuestKey $GuestKey -Status 'skipped'
                Set-GuestQuarantine -GuestKey $GuestKey -Quarantined $true -UntilCommit $GitCommit
                continue
            }
        }
        $guestIterState = @{
            OverallPassed  = $OverallPassed
            FailedGuest    = $FailedGuest
            FailedStep     = $FailedStep
            FailureMessage = $FailureMessage
            Control        = 'proceed'
        }
        try {
            Invoke-GuestProvisionIteration -GuestKey $GuestKey -IterState $guestIterState `
                -VMNames $VMNames -RepoRoot $RepoRoot -HostType $HostType -ModulesDir $ModulesDir `
                -LogFile $LogFile -SequencesDir $SequencesDir -ScreenshotsDir $ScreenshotsDir `
                -hasScreenshots $hasScreenshots -hasExtensions $hasExtensions `
                -cachingProxyUrl $cachingProxyUrl -cfg $cfg -ConfigPath $ConfigPath `
                -FailedGuests $FailedGuests -ShutdownState $ShutdownState
        } finally {
            # Carry cycle state back to caller scope on EVERY path (normal return AND a
            # mid-iteration throw): the four failure fields from $guestIterState, and the
            # config mirrors re-read from the shared reload bag $cfg (mutated in place by
            # the per-step Sync inside the iteration). Complete-CycleRun and the outer
            # catch read these caller-local values.
            $OverallPassed = $guestIterState.OverallPassed
            $FailedGuest = $guestIterState.FailedGuest
            $FailedStep = $guestIterState.FailedStep
            $FailureMessage = $guestIterState.FailureMessage
            $Config = $cfg.Config; $StopOnFailure = $cfg.StopOnFailure; $GetImageRefreshHours = $cfg.GetImageRefreshHours; $CycleDelay = $cfg.CycleDelay
        }
        # Fold this guest's outcome into the quarantine circuit breaker. A failed
        # guest sets $guestIterState.FailedGuest to its own key (a pass leaves it
        # unchanged and keys are unique this cycle, so equality is a reliable
        # "this guest failed" signal); 'proceed' with no failure is a clean pass
        # that clears any streak. A quarantine-skipped guest already `continue`d
        # above and never reaches here.
        if ($cfg.GuestQuarantineEnabled -and (Get-Command Register-GuestQuarantineOutcome -ErrorAction SilentlyContinue)) {
            if ($guestIterState.FailedGuest -eq $GuestKey) {
                $qClass = 'unknown'
                if (Get-Command Get-FailureEventData -ErrorAction SilentlyContinue) {
                    try {
                        $qfe = Get-FailureEventData -HostType $HostType -Hostname (hostname) -GuestKey $GuestKey `
                            -StepName ([string]$guestIterState.FailedStep) -ErrorMessage ([string]$guestIterState.FailureMessage)
                        if ($qfe -and $qfe.failureClass) { $qClass = [string]$qfe.failureClass }
                    } catch { $null = $_ }
                }
                $qOut = Register-GuestQuarantineOutcome -RuntimeDir $env:YURUNA_RUNTIME_DIR -GuestKey $GuestKey -Outcome 'fail' `
                    -FailureClass $qClass -VmName ([string]$VMNames[$GuestKey]) -GitCommit $GitCommit -ProjectGitCommit $ProjectGitCommit `
                    -HostType $HostType -FailuresToQuarantine ([int]$cfg.GuestQuarantineFailures) -SkipCycles ([int]$cfg.GuestQuarantineSkipCycles)
                if ($qOut.NewlyQuarantined) {
                    Set-GuestQuarantine -GuestKey $GuestKey -Quarantined $true -UntilCommit $GitCommit
                    Write-Output "  QUARANTINE: $GuestKey hit $($qOut.ConsecutiveFailures)x '$($qOut.FailureClass)' -- skipping it for up to $($cfg.GuestQuarantineSkipCycles) cycles or until a new commit."
                }
            } elseif ($guestIterState.Control -eq 'proceed') {
                [void](Register-GuestQuarantineOutcome -RuntimeDir $env:YURUNA_RUNTIME_DIR -GuestKey $GuestKey -Outcome 'pass')
            }
        }
        if ($guestIterState.Control -eq 'break') { break }
        if ($guestIterState.Control -eq 'continue') { continue }
    }

    # === Finalise cycle ===
    if ($isOrchestrationCycle) {
        # Delegate the whole cycle to the orchestration runner: it owns Reset/
        # Initialize/Start-Log, walks the InvokeTestSequence steps (one dashboard
        # row per inner sequence), and Completes + seals the transcript itself --
        # the same path a standalone `Test-Sequence <orch>` takes. So we do NOT
        # call Complete-CycleRun here; we only map its exit code to the cycle
        # result the gating/notification tail below reads.
        Write-Output ""
        Write-Output "Delegating cycle to orchestration sequence: $orchestrationName"
        $orchRc = Invoke-OrchestrationSequence `
            -Sequence $orchestrationDoc -SequencePath $orchestrationPath `
            -RepoRoot $RepoRoot -SequencesDir $SequencesDir -TestRoot $TestRoot `
            -HostType $HostType -Config $Config
        $OverallPassed = ($orchRc -eq 0)
        if (-not $OverallPassed -and -not $FailedGuest) {
            $FailedGuest    = "(orchestration)"
            $FailedStep     = $orchestrationName
            $FailureMessage = "orchestration '$orchestrationName' reported one or more failures"
        }
        $FinalStatus = if ($OverallPassed) { 'pass' } else { 'fail' }
    } else {
        $FinalStatus = Complete-CycleRun -OverallPassed $OverallPassed -Config $Config -FailedGuest $FailedGuest -FailedStep $FailedStep
    }
    $script:CycleFinalized = $true

    Write-Output ""
    Write-Output "== Cycle $CycleCount complete: $FinalStatus =="

    if ($OverallPassed) {
        $ConsecutiveCrashes  = 0
        $ConsecutiveFailures = 0
        $ConsecutiveSuccesses++
        if (-not $AlertArmed -and $ConsecutiveSuccesses -ge $SuccessesBeforeRearm) {
            $AlertArmed = $true
            Write-Output "  Notification alert rearmed after $ConsecutiveSuccesses consecutive successes."
        }
    }

    if (-not $OverallPassed) {
        $ConsecutiveSuccesses = 0
        $ConsecutiveFailures++
        # A guest-failure cycle still reached finalization -- the engine ran
        # end-to-end without an unhandled crash (a crash is caught below and
        # never reaches here) -- so it breaks the consecutive-crash streak just
        # like a pass does. Only a crash without completion keeps the count
        # climbing toward the MaxConsecutiveCrashes abort, which exists to stop a
        # tight crash loop making no forward progress.
        $ConsecutiveCrashes = 0
        # Final reload so an edit made during the last step's cleanup
        # affects the cycle-end abort decision (matches per-step semantics).
        Sync-RunnerStepConfig -State $cfg -ConfigPath $ConfigPath
        $Config = $cfg.Config; $StopOnFailure = $cfg.StopOnFailure; $GetImageRefreshHours = $cfg.GetImageRefreshHours; $CycleDelay = $cfg.CycleDelay
        if ($StopOnFailure) {
            break
        }
        if ($FailedGuest) {
            Write-Output ""
            Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            Write-Output "  FAILURE in cycle $CycleCount (continuing)"
            Write-Output "  Guest:   $FailedGuest"
            Write-Output "  Step:    $FailedStep"
            Write-Output "  Error:   $FailureMessage"
            Write-Output "  Alert:   $ConsecutiveFailures/$FailuresBeforeAlert failures $(if ($AlertArmed) {'(armed)'} else {'(suppressed)'})"
            Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"

            if ($AlertArmed -and $ConsecutiveFailures -ge $FailuresBeforeAlert) {
                # EventData: in-cycle alert -- the cycle folder is
                # established, so Get-FailureEventData reads schema-v2
                # last_failure.json (failureClass/severity/suggested
                # Recoveries from the verb registry) and augments with
                # cycle/host context. Built here so it can be remediated
                # below before Send-CycleFailureNotification ships it --
                # the body's JSON trailer and the -EventData payload carry
                # the same hashtable; extensions that declare -EventData
                # route on it, legacy ones still see it in the body.
                $inCycleEventData = Get-FailureEventData `
                    -HostType      $HostType `
                    -Hostname      (hostname) `
                    -GuestKey      $FailedGuest `
                    -StepName      $FailedStep `
                    -ErrorMessage  $FailureMessage `
                    -CycleId       $CycleId `
                    -GitCommit     $GitCommit `
                    -ProjectCommit $ProjectGitCommit
                # Close the self-heal observability loop: route the failure
                # through the remediation dispatcher so it computes a recovery
                # recommendation, emits the remediation_recommended NDJSON event
                # (internally, via Send-CycleEventSafely), persists the durable
                # last_remediation.json beside the failure (archived into the
                # cycle folder and replicated to the pool), and logs the next
                # step. Advisory only -- the dispatcher records the decision but
                # never acts. Pass the in-memory payload so a cycle-boundary wipe
                # of last_failure.json can't route this on a stale file. Auto-
                # applying a recommendation is a separate, default-off feature
                # that needs a per-cycle attempt cap and a class allow-list
                # (and enough human review) before it can act.
                if (Get-Command Invoke-Remediation -ErrorAction SilentlyContinue) {
                    $remediation = Invoke-Remediation -FailureRecord $inCycleEventData
                    if ($remediation) { Write-Output "  Remediation: $($remediation.Recommendation) -- $($remediation.Rationale)" }
                }
                # Payload was built and remediated on above; pass it
                # pre-built so the helper ships the exact same hashtable
                # (no second Get-FailureEventData, no remediation reorder).
                Send-CycleFailureNotification `
                    -HostType      $HostType `
                    -SubjectSuffix "$FailedGuest / $FailedStep" `
                    -GuestKey      $FailedGuest `
                    -StepName      $FailedStep `
                    -ErrorMessage  $FailureMessage `
                    -CycleId       $CycleId `
                    -GitCommit     $GitCommit `
                    -EventData     $inCycleEventData
                $AlertArmed           = $false
                $ConsecutiveSuccesses = 0
                Write-Output "  Notification sent. Alert suppressed until $SuccessesBeforeRearm consecutive successes or runner restart."
            }
        }
    }

    if ($Warnings.Count -gt 0) {
        Write-Output ""
        Write-Output "--- Warnings ---"
        foreach ($w in $Warnings) {
            Write-Warning "  $w"
        }
    }

  } catch {
    # --- REGION: Cycle-restart abort (expected)
    # Invoke-Sequence's per-step gate throws "YurunaCycleRestart: ..." when
    # /control/start-cycle requests an abort mid-cycle. This is the
    # operator clicking "Save and start cycle" while a cycle is actively
    # executing steps: Remove-TestVMFiles has already torn down the VMs,
    # the flag has been touched, and the cycle needs to unwind cleanly.
    # Detected by message prefix (cross-module typed exceptions would
    # need a shared assembly; the prefix is unique enough). Treated as a
    # NORMAL cycle ending, not an UNHANDLED ERROR:
    #   - No ConsecutiveCrashes increment -- this is not a code crash.
    #   - No 60-line origin + stack dump banner -- the flag was visible to
    #     the operator who set it, no postmortem needed.
    #   - Cycle is finalized as 'fail' so status.json reflects the abort
    #     rather than a phantom pass; teardown proceeds normally; the
    #     inter-cycle delay loop's existing flag-check then consumes
    #     control.cycle-restart on its first tick and exits inner, after
    #     which outer respawns with a clean slate.
    if ($_.Exception.Message -like 'YurunaCycleRestart:*') {
        Write-Output ""
        Write-Output "============================================="
        Write-Output "  CYCLE $CycleCount aborted by /control/start-cycle"
        Write-Output "  $($_.Exception.Message)"
        Write-Output "============================================="
        if ($script:ActiveVMName) {
            try {
                Write-Output "  Cycle-restart cleanup: stopping VM '$($script:ActiveVMName)'..."
                Remove-GuestVMQuietly -VMName $script:ActiveVMName -BestEffort
            } catch { Write-Warning "  Cycle-restart VM cleanup failed: $_" }
            $script:ActiveVMName = $null
        }
        if (-not $script:CycleFinalized) {
            try {
                Complete-Run -OverallStatus "fail" -MaxHistoryRuns ([int]$Config.testCycle.recentDisplayCount) -ErrorAction SilentlyContinue
                Stop-LogFile -Outcome 'aborted' -Reason 'cycle-restart marker consumed mid-cycle' -ErrorAction SilentlyContinue
            } catch { Write-Warning "  Cycle-restart finalization failed: $_" }
            $script:CycleFinalized = $true
        }
        $OverallPassed = $false
        # Fall through past the "UNHANDLED ERROR" block via a
        # script-scope marker; the outer-most `if`/`else` below routes the
        # control flow without duplicating that block here.
        $script:CycleRestartHandled = $true
    } else {
        $script:CycleRestartHandled = $false
    }
    if (-not $script:CycleRestartHandled) {
    # --- REGION: Unhandled exception in cycle -- emergency cleanup
    $ConsecutiveCrashes++
    Write-Output ""
    Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Output "  UNHANDLED ERROR in cycle $CycleCount"
    Write-Output "  $_"
    # Print the error origin. Otherwise the operator sees only the message
    # (e.g. "Cannot convert value ' Install ' to 'System.Int32'") and has
    # to grep ten modules to guess the source. PositionMessage gives
    # file:line of the throwing statement; ScriptStackTrace gives the
    # call chain -- together they pin the source on a single re-run.
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Output "  Origin:"
        foreach ($line in ($_.InvocationInfo.PositionMessage -split "`n")) {
            Write-Output "    $line"
        }
    }
    if ($_.ScriptStackTrace) {
        Write-Output "  Stack:"
        foreach ($line in ($_.ScriptStackTrace -split "`n")) {
            Write-Output "    $line"
        }
    }
    Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"

    if ($script:ActiveVMName) {
        try {
            Write-Output "  Emergency cleanup: stopping VM '$($script:ActiveVMName)'..."
            Remove-GuestVMQuietly -VMName $script:ActiveVMName -BestEffort
        } catch { Write-Warning "  Emergency VM cleanup failed: $_" }
        $script:ActiveVMName = $null
    }

    if (-not $script:CycleFinalized) {
        try {
            Complete-Run -OverallStatus "fail" -MaxHistoryRuns ([int]$Config.testCycle.recentDisplayCount) -ErrorAction SilentlyContinue
            $emergencyReason = if ($_) { "engine crash: $($_.Exception.Message)" } else { 'engine crash (no exception object)' }
            Stop-LogFile -Outcome 'fail' -Reason $emergencyReason -ErrorAction SilentlyContinue
        } catch { Write-Warning "  Emergency cycle finalization failed: $_" }
        $script:CycleFinalized = $true
    }

    if ($ConsecutiveCrashes -ge $MaxConsecutiveCrashes) {
        Write-Output "  $ConsecutiveCrashes consecutive unhandled errors -- aborting."
        $OverallPassed = $false
        break
    }
    Write-Output "  Will retry next cycle ($ConsecutiveCrashes/$MaxConsecutiveCrashes consecutive errors)."

    # yuruna_retry-style auto-retry backoff: capped exponential with jitter.
    # Applied on top of the existing inter-cycle delay so a transient failure
    # (subiquity restore_apt_config exit 100, github.com 5xx during tofu init,
    # ...) cools the retry off long enough for the upstream blip to pass
    # without saturating MaxConsecutiveCrashes. Same policy as
    # automation/yuruna-retry.sh: base doubles each consecutive crash,
    # capped at MaxDelaySeconds. Skipped when Get-YurunaRetryBackoff is
    # unavailable (early-bootstrap path before Yuruna.Retry imports).
    if (Get-Command Get-YurunaRetryBackoff -ErrorAction SilentlyContinue) {
        $autoRetryBase = 30 * [Math]::Pow(2, [Math]::Max(0, $ConsecutiveCrashes - 1))
        $autoRetryBase = [int][Math]::Min($autoRetryBase, 300)
        $backoffSeconds = Get-YurunaRetryBackoff -BaseDelay $autoRetryBase -MaxDelay 300 -JitterFraction 0.25
        Write-Output "  Auto-retry backoff (yuruna_retry pattern): sleeping ${backoffSeconds}s before next cycle (consecutiveCrashes=$ConsecutiveCrashes)."
        $backoffDeadline = [DateTime]::UtcNow.AddSeconds($backoffSeconds)
        while ([DateTime]::UtcNow -lt $backoffDeadline -and -not $ShutdownState['Requested']) {
            try {
                [System.IO.File]::WriteAllText($StepHeartbeatFile, [DateTime]::UtcNow.ToString('o'))
            } catch {
                Write-Verbose "stepHeartbeat refresh during auto-retry backoff failed: $($_.Exception.Message)"
            }
            Start-Sleep -Seconds 1
        }
    }
    }  # end if (-not $script:CycleRestartHandled)
  }

    if ($ShutdownState['Requested']) {
        Write-Output "Shutdown requested. Exiting cycle loop."
        break
    }

    Remove-CycleTeardownOrphanVM -CycleCount $CycleCount -TestRoot $TestRoot -Prefix $Prefix

    # Cycle-pause back-channel: status server's /control/cycle-pause
    # endpoint creates $env:YURUNA_RUNTIME_DIR/control.cycle-pause. Gate
    # here -- AFTER cleanup, BEFORE the inter-cycle wait -- so the UI's
    # "Cycle pause" stops the runner at the cycle boundary with VMs torn
    # down. /control/cycle-resume removes the file and the loop proceeds
    # to the normal wait. ShutdownState is checked alongside so Ctrl-C
    # still breaks out of the wait.
    $cyclePauseFlagFile   = Join-Path $env:YURUNA_RUNTIME_DIR 'control.cycle-pause'
    # control.cycle-restart is the "start a new cycle now" signal from the
    # status server's /control/start-cycle endpoint. Polled in the inter-
    # cycle delay loop below: if seen, break out, remove the file, exit
    # inner so outer respawns with no further wait. The endpoint also
    # clears any cycle-pause/step-pause and runs Remove-TestVMFiles before
    # writing this file, so by the time we observe it the in-progress VMs
    # are gone and the operator wants a clean cycle.
    $cycleRestartFlagFile = Join-Path $env:YURUNA_RUNTIME_DIR 'control.cycle-restart'
    if (Test-Path $cyclePauseFlagFile) {
        Write-Output "Cycle pause set via status UI. Waiting for resume..."
        # Refresh runner.stepHeartbeat each iteration: the outer watchdog
        # reads only this file's mtime and kills the inner after
        # testCycle.stepTimeoutMinutes (default 45 min) of staleness. A
        # deliberate pause has no step boundaries to refresh it via
        # Invoke-Sequence's normal path, so without this the watchdog
        # would TerminateProcess the inner mid-pause, drop the outer into
        # its failure backoff, and leave /control/cycle-resume and
        # /control/start-cycle from index.html with nothing to talk to.
        $pauseAttempt = 1
        while ((Test-Path $cyclePauseFlagFile) -and (-not $ShutdownState['Requested'])) {
            try {
                [System.IO.File]::WriteAllText($StepHeartbeatFile, [DateTime]::UtcNow.ToString('o'))
            } catch {
                Write-Verbose "runner.stepHeartbeat refresh during cycle pause failed: $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds (Get-PollDelay -Attempt $pauseAttempt)
            $pauseAttempt++
        }
        if ($ShutdownState['Requested']) {
            Write-Output "Shutdown requested during cycle pause. Exiting cycle loop."
            break
        }
        Write-Output "Cycle pause released. Resuming."
    }

    # Inter-cycle delay LIVES IN THE INNER (not the outer) so the operator
    # sees the countdown in the same console as the cycle's own output.
    # Outer is intentionally dumb: it spawns us, waits, and either
    # respawns immediately (success) or enters its failure-pause (non-
    # zero exit). Putting the delay here means an "Invoke-TestRunner is
    # idle for 30s between cycles" period is observable on the runner
    # host -- Windows hosts in particular were going dark between cycles
    # when the delay lived in the outer, since the outer's Write-Output
    # could be swallowed by conhost while the inner pwsh was gone.
    #
    # The countdown is sliced into 1-second waits so Ctrl+C / shutdown /
    # cycle-pause flag can break out without sitting through a long
    # Start-Sleep. Write-Progress shows a percentage bar; Write-Output
    # emits a coarser tick (every ~5 s) so a non-progress-rendering log
    # collector still records forward motion.
    # $CycleDelay is set inside the cycle's try block once config is
    # merged; an early throw before that point would leave it null.
    # Fall back to the script param so the inter-cycle wait is still
    # respected on the rare crash-before-config path.
    $delayId       = 2
    $effectiveDelay = if ($null -ne $CycleDelay -and [int]$CycleDelay -gt 0) { [int]$CycleDelay } else { [int]$CycleDelaySeconds }
    if ($effectiveDelay -gt 0 -and -not $ShutdownState['Requested']) {
        Write-Output "[cycle $CycleCount] cycleDelaySeconds wait: $effectiveDelay s before exiting to outer."
        $exitReason = Wait-WithProgress -Activity "[cycle $CycleCount] inter-cycle delay" `
            -TotalSeconds $effectiveDelay -PollSeconds 1 -Id $delayId -Test {
                if ($ShutdownState['Requested']) { return 'shutdown' }
                # A cycle-pause armed during the wait does NOT cut the countdown
                # short: the operator asked to pause "after the cycleDelaySeconds",
                # so the wait runs to completion and the post-delay gate below
                # honors the pause before the next cycle. Shutdown and restart
                # still break the wait early.
                if (Test-Path $cycleRestartFlagFile) {
                    Remove-Item $cycleRestartFlagFile -Force -ErrorAction SilentlyContinue
                    return 'restart'
                }
                return $false
            }
        if ($exitReason -eq 'restart') {
            Write-Output "[cycle $CycleCount] cycle-restart signal seen -- breaking delay early."
        }
        Write-Output "[cycle $CycleCount] cycleDelaySeconds wait complete -- exiting inner; outer will respawn. (local time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))"
        Write-InnerLog "[cycle $CycleCount] cycleDelaySeconds wait complete -- entering exit path"
    }

    # Cycle-pause counterpart to the "Cycle-pause back-channel" gate above: a
    # pause armed via the status UI DURING the cycleDelaySeconds wait is honored
    # here -- after the wait runs to completion, before we exit the inner, so the
    # outer respawns the next cycle only once resumed. This is what makes the
    # UI's now-enabled "Pause after cycle" button take effect right after the
    # inter-cycle delay. Gated on $effectiveDelay so it only fires when a wait
    # actually ran; with no inter-cycle delay the pre-delay gate above is the
    # sole cycle boundary. Mirrors that gate's wait loop -- keep the heartbeat-
    # refresh / resume / shutdown handling in sync.
    if (($effectiveDelay -gt 0) -and (Test-Path $cyclePauseFlagFile) -and (-not $ShutdownState['Requested'])) {
        Write-Output "Cycle pause armed during inter-cycle delay. Pausing before next cycle; waiting for resume..."
        $postDelayPauseAttempt = 1
        while ((Test-Path $cyclePauseFlagFile) -and (-not $ShutdownState['Requested'])) {
            try {
                [System.IO.File]::WriteAllText($StepHeartbeatFile, [DateTime]::UtcNow.ToString('o'))
            } catch {
                Write-Verbose "runner.stepHeartbeat refresh during cycle pause failed: $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds (Get-PollDelay -Attempt $postDelayPauseAttempt)
            $postDelayPauseAttempt++
        }
        if ($ShutdownState['Requested']) {
            Write-Output "Shutdown requested during cycle pause. Exiting cycle loop."
            break
        }
        Write-Output "Cycle pause released. Resuming."
    }

    # Single-cycle runner: the per-cycle pwsh respawn lives in the outer
    # Invoke-TestRunner.ps1. Outer's job is intentionally minimal -- it
    # waits for our exit and either respawns us immediately (success) or
    # enters its failure-pause (non-zero). All cycle bookkeeping (work,
    # cleanup, inter-cycle delay) happens here so the operator sees the
    # full per-cycle timeline in one console.
    break
} while ($false)
    # Carry the cycle outcome + gating counters back to the caller's exit path.
    $State.OverallPassed        = $OverallPassed
    $State.FailedGuest          = $FailedGuest
    $State.FailedStep           = $FailedStep
    $State.FailureMessage       = $FailureMessage
    $State.CycleId              = $CycleId
    $State.LogFile              = $LogFile
    $State.GitCommit            = $GitCommit
    $State.ProjectGitCommit     = $ProjectGitCommit
    $State.ConsecutiveFailures  = $ConsecutiveFailures
    $State.ConsecutiveSuccesses = $ConsecutiveSuccesses
    $State.ConsecutiveCrashes   = $ConsecutiveCrashes
    $State.AlertArmed           = $AlertArmed
    $State.FailuresBeforeAlert  = $FailuresBeforeAlert
    $State.GatingFile           = $GatingFile
}

function Invoke-GuestProvisionIteration {
    # One guest's full lifecycle: cleanup -> New-VM -> Start-VM -> Start-GuestOS ->
    # New-VM.Resource -> screenshots -> workload -> stop. Lifted out of the cycle's
    # guest foreach so it is unit-testable. The caller foreach dispatches on
    # $IterState.Control: 'break' ends the guest sweep, 'continue' skips to the next
    # guest, 'proceed' falls through. Mutable cycle state carries back two ways -- the
    # four failure fields through $IterState, and the reloadable config through the
    # shared bag $cfg (mutated in place by the per-step Sync; the caller re-reads the
    # mirrors it needs from $cfg after the call). This helper re-reads only the knobs
    # it acts on: $StopOnFailure (the stop guards) and the VM start/boot timeouts.
    # Status Write-Output flows to the caller's stream exactly as when inline (the
    # helper is invoked as a statement, not captured).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][hashtable]$IterState,
        $VMNames,
        [string]$RepoRoot,
        [string]$HostType,
        [string]$ModulesDir,
        [string]$LogFile,
        [string]$SequencesDir,
        [string]$ScreenshotsDir,
        [bool]$hasScreenshots,
        [bool]$hasExtensions,
        [string]$cachingProxyUrl,
        $cfg,
        [string]$ConfigPath,
        $FailedGuests,
        $ShutdownState
    )
    $IterState.Control = 'proceed'
    $StopOnFailure = $cfg.StopOnFailure; $VmStartTimeout = $cfg.VmStartTimeout; $VmBootDelay = $cfg.VmBootDelay
    if ($ShutdownState['Requested']) {
        Write-Output "Shutdown requested. Skipping remaining guests."
        $IterState.OverallPassed = $false; $IterState.FailedStep = "shutdown"
        $IterState.Control = 'break'; return
    }
    # Skip guests that already failed pre-flight or Get-Image
    # (shouldStopOnFailure=false path).
    if ($FailedGuests.Contains($GuestKey)) {
        Write-Output ""
        Write-Output "== $GuestKey (skipped -- earlier failure) =="
        $IterState.Control = 'continue'; return
    }
    $VMName = $VMNames[$GuestKey]
    $script:ActiveVMName = $VMName
    Write-Output ""
    Write-Output "== $GuestKey (VM: $VMName) =="
    # No per-cycle keystroke-mechanism switch: each sequence carries its own
    # keystrokeMechanism (gui|ssh) and encodes the mechanism in its own steps, so
    # the engine drives it as-authored.

    # Eagerly create this guest's cycleGuestDataFolder so the
    # dashboard tile has a destination to link to from the start of
    # the iteration -- not only after a failure produces files.
    # Get-CycleGuestDataFolder mkdir's it on demand. The URL is
    # recorded on the live status doc immediately so the live UI
    # makes the tile clickable mid-cycle too.
    $guestFolderPath = Get-CycleGuestDataFolder -VMName $VMName
    if ($guestFolderPath) {
        # Use the cycle's stable identity (no .incomplete suffix)
        # so the URL resolves post-rename. The dashboard re-reads
        # status.json after Stop-LogFile updates cycleFolderUrl, but
        # the per-guest artifact URL is recorded mid-cycle and must
        # outlast the rename.
        $cycleBaseName = Get-StableCycleBaseName
        Set-GuestFailureArtifact -GuestKey $GuestKey -RelativeUrl "log/$cycleBaseName/$VMName/"
    }

    # --- REGION: Cleanup stale per-VM failure artifacts from prior cycles
    # failure_screenshot_<VM>.png and failure_ocr_<VM>.txt still live
    # at the YURUNA_LOG_DIR root (shared across cycles, keyed only by
    # VM name) so without this drop, a later cycle that fails before
    # any sequence runs (e.g. New-VM aborts on a host-side precondition
    # like missing openssl) would have Copy-FailureArtifactsToStatusLog
    # copy the previous cycle's screenshot forward, misleading the
    # operator. Done unconditionally at the top of each guest iteration
    # so any artifact that lands in the per-cycle folder belongs to
    # this cycle. The screens_<VM>/ ring buffer lives INSIDE the cycle
    # folder (Get-CycleScreenDir) so it can't leak forward -- no cleanup
    # needed for it here.
    $staleScreen = Join-Path $env:YURUNA_LOG_DIR "failure_screenshot_${VMName}.png"
    $staleOcr    = Join-Path $env:YURUNA_LOG_DIR "failure_ocr_${VMName}.txt"
    Remove-Item -LiteralPath $staleScreen -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $staleOcr    -Force -ErrorAction SilentlyContinue

    # --- REGION: Constrained-host guest serialization
    # On hosts with only a few hardware threads, guests still running
    # from earlier sequences compete with this guest's OS install: vCPU
    # totals above the host's thread count plus guest RAM above physical
    # can deschedule an installer's vCPUs for seconds at a time, so the
    # autoinstall console appears frozen until the step timeout gives up
    # on it. Stop the cycle's other test guests first -- the guest sweep
    # runs one full lifecycle at a time, so guests before this one are
    # already past their sequences. Scoped to $VMNames (this cycle's
    # guests only) so infra VMs -- e.g. the caching proxy, which every
    # step asserts reachable -- are never touched. Force, because a
    # guest sitting in an installer ignores ACPI shutdown.
    # No continue/break in this loop: the enclosing helper's control-flow
    # invariant (see Test.RunnerInnerLoop.Tests.ps1) reserves loop escapes
    # for $IterState.Control signalling, so the skip logic nests instead.
    if (([Environment]::ProcessorCount -le 4) -and $VMNames -and $VMNames.Count -gt 1 -and
        (Get-Command Get-VMState -ErrorAction SilentlyContinue) -and
        (Get-Command Stop-VM -ErrorAction SilentlyContinue)) {
        foreach ($otherKey in @($VMNames.Keys)) {
            $otherVM = if ($otherKey -ne $GuestKey) { [string]$VMNames[$otherKey] } else { '' }
            if ($otherVM -and ($otherVM -ne $VMName)) {
                $otherState = ''
                try { $otherState = [string](Get-VMState -VMName $otherVM) } catch { $otherState = '' }
                if ($otherState -eq 'running') {
                    Write-Output "  Constrained host ($([Environment]::ProcessorCount) threads): stopping '$otherVM' before provisioning $GuestKey"
                    try { Stop-VM -VMName $otherVM -Force -Confirm:$false | Out-Null }
                    catch { Write-Warning "  Could not stop '$otherVM': $($_.Exception.Message)" }
                }
            }
        }
    }

    # --- REGION: Cleanup previous VM
    Remove-GuestVMQuietly -VMName $VMName -SkipStop

    # --- REGION: New-VM
    Set-GuestVMName -GuestKey $GuestKey -VMName $VMName
    Set-GuestStatus -GuestKey $GuestKey -Status "running"
    # Surface the cycle-plan top-level workload(s) covering this
    # guest so the dashboard can render them above the step pills.
    # Joined with " + " when more than one top-level shares a guest.
    if ($script:CyclePlan -and $script:CyclePlan.Count -gt 0) {
        $tops = @($script:CyclePlan | Where-Object { $_.guestKey -eq $GuestKey } | ForEach-Object { $_.topLevel } | Select-Object -Unique)
        if ($tops.Count -gt 0) {
            Set-GuestTopLevel -GuestKey $GuestKey -TopLevel ($tops -join ' + ')
        }
    }

    Assert-CachingProxyStillReachable -ProxyUrl $cachingProxyUrl -StepName "New-VM" -GuestKey $GuestKey
    Set-StepStatus -GuestKey $GuestKey -StepName "New-VM" -Status "running"
    # Forward the cache URL detected at runner startup so every guest
    # uses the same address. Without this, each guest's New-VM.ps1
    # probes independently and races with transient listeners (stale
    # DHCP leases, torn-down sibling VMs), baking a dead IP into the
    # cidata seed -- seen on UTM where apt then fails with "No route
    # to host" at install. This is the same URL Test-CachingProxy.ps1
    # probes; install VMs reach it directly: Default-Switch guests
    # via Hyper-V's NAT-to-LAN, UTM guests via the vmnet-shared
    # gateway forwarder. No cache detected -> pass "" so guests skip
    # their probe: one detection event, one outcome.
    $newVmProxy = if ($cachingProxyUrl) { $cachingProxyUrl } else { "" }
    # Planner-cascaded username: a workload that overrides
    # `variables.username` propagates that value back to the start
    # sequence (and therefore to the cloud-init account this New-VM
    # invocation provisions). Empty effectiveUsername falls through
    # to the per-host New-VM.ps1 default, preserving today's
    # behavior when no plan has been resolved (legacy guestSequence
    # path).
    #
    # variables.hostname cascades the same way and becomes the guest's
    # cloud-init local-hostname, which is the name the guest DHCP-registers
    # under. Empty leaves the guest named after the VM. When it is set, the
    # UTM dhcpd_leases lookup must key on the pinned name: blocks under the
    # VM name are then predecessors' and resolve to dead addresses. The host
    # driver reads the pinned name back out of the bundle's seed ISO, so it
    # does not have to be threaded down from here.
    $effectiveUser = ''
    $effectiveHost = ''
    if ($script:CyclePlan -and $script:CyclePlan.Count -gt 0) {
        $mergedPlan = Get-CyclePlanSequencesForGuest -Plan $script:CyclePlan -GuestKey $GuestKey
        if ($mergedPlan -and $mergedPlan.effectiveUsername) {
            $effectiveUser = [string]$mergedPlan.effectiveUsername
        }
        if ($mergedPlan -and $mergedPlan.effectiveHostname) {
            $effectiveHost = [string]$mergedPlan.effectiveHostname
        }
    }
    $newVmArgs = @{ GuestKey = $GuestKey; RepoRoot = $RepoRoot; VMName = $VMName; CachingProxyUrl = $newVmProxy }
    if ($effectiveUser) {
        Write-Verbose "Cascaded username for $GuestKey -> $effectiveUser (overrides per-host New-VM.ps1 default)"
        $newVmArgs.Username = $effectiveUser
    }
    if ($effectiveHost) {
        Write-Verbose "Cascaded hostname for $GuestKey -> $effectiveHost (overrides the VM-name default)"
        $newVmArgs.Hostname = $effectiveHost
    }
    $r = New-VM @newVmArgs -Confirm:$false
    Sync-RunnerStepConfig -State $cfg -ConfigPath $ConfigPath
    $StopOnFailure = $cfg.StopOnFailure; $VmStartTimeout = $cfg.VmStartTimeout; $VmBootDelay = $cfg.VmBootDelay
    if ($r.success) {
        Set-StepStatus -GuestKey $GuestKey -StepName "New-VM" -Status "pass"
        $prov = Get-GuestProvenance -GuestKey $GuestKey
        $provSuffix = if ($prov.Filename) { " <== $($prov.Filename)" } else { "" }
        Write-Output "  $GuestKey New-VM: PASS$provSuffix"
    } else {
        Write-Warning "  ERROR [$GuestKey / New-VM]: $($r.errorMessage)"
        Write-Output "  Log directory: $env:YURUNA_LOG_DIR"
        Set-StepStatus  -GuestKey $GuestKey -StepName "New-VM" -Status "fail" -ErrorMessage $r.errorMessage
        Set-GuestStatus -GuestKey $GuestKey -Status "fail"
        $IterState.OverallPassed = $false; $IterState.FailedGuest = $GuestKey; $IterState.FailedStep = "New-VM"; $IterState.FailureMessage = $r.errorMessage
        Write-CycleInfraFailure -Stage 'New-VM' -FailureClass 'provisioning_failure' -GuestKey $GuestKey -VMName $VMName -ErrorMessage $r.errorMessage -HostType $HostType
        # Copy artifacts BEFORE the shouldStopOnFailure break so the debug
        # folder exists, the log links it, and the dashboard's "fail"
        # pill points to it on both paths (continue and stop).
        Copy-FailureArtifactsToStatusLog -VMName $VMName -GuestKey $GuestKey -RepoRoot $RepoRoot -ModulesDir $ModulesDir -LogFile $LogFile
        if ($StopOnFailure) { $IterState.Control = 'break'; return }
        # Clean up so a partial Hyper-V definition (Hyper-V\New-VM
        # succeeded but a later Set-VM*/Add-VMDvdDrive threw) doesn't
        # hold its 12 GB Startup reservation against the next guest.
        # Mirrors the Start-GuestOS/Start-GuestWorkload failure branches;
        # Stop-VM and Remove-VM are both safe no-ops on an absent VM.
        Write-Output "  Cleaning up VM '$VMName' after failure..."
        Remove-GuestVMQuietly -VMName $VMName
        $IterState.Control = 'continue'; return
    }

    # --- REGION: Start-VM
    Assert-CachingProxyStillReachable -ProxyUrl $cachingProxyUrl -StepName "Start-VM" -GuestKey $GuestKey
    Set-StepStatus -GuestKey $GuestKey -StepName "Start-VM" -Status "running"
    $r = Start-VM -VMName $VMName -Confirm:$false
    Sync-RunnerStepConfig -State $cfg -ConfigPath $ConfigPath
    $StopOnFailure = $cfg.StopOnFailure; $VmStartTimeout = $cfg.VmStartTimeout; $VmBootDelay = $cfg.VmBootDelay
    if ($r.success) {
        Set-StepStatus -GuestKey $GuestKey -StepName "Start-VM" -Status "pass"
        # Resolve the guest's host-side IP so the operator can ssh /
        # vmconnect / VNC straight from the cycle log. Polls briefly --
        # KVP integration services on Hyper-V and utmctl/dhcpd_leases on
        # UTM typically need a few seconds after start to publish an
        # address. "(pending)" means no host-side answer within the
        # budget; the actual address shows up in later runner output
        # (New-VM.Resource / extension scripts) once the guest is fully up.
        #
        # On Hyper-V's External vSwitch the host is NOT the DHCP server,
        # so KVP-only discovery via hv_kvp_daemon can be 5-15 min late
        # (memory: feedback_hyperv_external_vswitch_arp_discovery.md).
        # Active-probe the /24 first so subsequent ARP/KVP lookups see
        # the guest. The function is exported only on the Hyper-V host
        # driver; Get-Command-guarded so KVM/UTM cycles are unaffected.
        if (Get-Command Invoke-YurunaExternalArpProbe -ErrorAction SilentlyContinue) {
            try { Invoke-YurunaExternalArpProbe } catch {
                Write-Verbose "Invoke-YurunaExternalArpProbe (pre-Wait-VMIp) threw: $($_.Exception.Message)"
            }
        }
        $guestIp = Wait-VMIp -VMName $VMName -TimeoutSeconds 30
        $ipSuffix = if ($guestIp) { " ==> IP: $guestIp" } else { " ==> IP: (pending)" }
        Write-Output "  $GuestKey Start-VM: PASS$ipSuffix"
    } else {
        Write-Warning "  ERROR [$GuestKey / Start-VM]: $($r.errorMessage)"
        Write-Output "  Log directory: $env:YURUNA_LOG_DIR"
        Set-StepStatus  -GuestKey $GuestKey -StepName "Start-VM" -Status "fail" -ErrorMessage $r.errorMessage
        Set-GuestStatus -GuestKey $GuestKey -Status "fail"
        $IterState.OverallPassed = $false; $IterState.FailedGuest = $GuestKey; $IterState.FailedStep = "Start-VM"; $IterState.FailureMessage = $r.errorMessage
        Write-CycleInfraFailure -Stage 'Start-VM' -FailureClass 'provisioning_failure' -GuestKey $GuestKey -VMName $VMName -ErrorMessage $r.errorMessage -HostType $HostType
        Copy-FailureArtifactsToStatusLog -VMName $VMName -GuestKey $GuestKey -RepoRoot $RepoRoot -ModulesDir $ModulesDir -LogFile $LogFile
        if ($StopOnFailure) { $IterState.Control = 'break'; return }
        # Start-VM failed but New-VM passed, so the VM is defined (Off
        # state) and still holds its 12 GB Startup reservation. Tear it
        # down so the next guest in this cycle doesn't hit
        # 0x800705AA (insufficient system resources). Mirrors the
        # Start-GuestOS/Start-GuestWorkload failure branches.
        Write-Output "  Cleaning up VM '$VMName' after failure..."
        Remove-GuestVMQuietly -VMName $VMName
        $IterState.Control = 'continue'; return
    }

    # --- REGION: Start-GuestOS (start.guest.* sequences from the cycle plan)
    Assert-CachingProxyStillReachable -ProxyUrl $cachingProxyUrl -StepName "Start-GuestOS" -GuestKey $GuestKey
    Set-StepStatus -GuestKey $GuestKey -StepName "Start-GuestOS" -Status "running"
    $startSeqs       = @()
    $workSeqs        = @()
    # [ordered]@{} is load-bearing: the planner builds variables
    # in dependency order (a bare 'username' before any value that
    # references ${username}). A plain @{} hashtable loses that
    # order, which made the cascade-expansion loop in Invoke-
    # Sequence call Get-Password('${username}') literally and
    # spawn a bogus '${username}' entry in vault.yml. Keep
    # [ordered] all the way to the engine.
    $cascadeVarsMap  = [ordered]@{}
    if ($script:CyclePlan -and $script:CyclePlan.Count -gt 0) {
        $merged         = Get-CyclePlanSequencesForGuest -Plan $script:CyclePlan -GuestKey $GuestKey
        $startSeqs      = @($merged.startSequences)
        $workSeqs       = @($merged.workloadSequences)
        if ($merged.effectiveVariables) {
            foreach ($_vk in $merged.effectiveVariables.Keys) {
                $cascadeVarsMap[$_vk] = $merged.effectiveVariables[$_vk]
            }
        }
    }
    $r = Start-GuestOS -HostType $HostType -GuestKey $GuestKey -VMName $VMName -RepoRoot $RepoRoot -SequencesDir $SequencesDir -SequenceNames $startSeqs -EffectiveVariables $cascadeVarsMap
    Sync-RunnerStepConfig -State $cfg -ConfigPath $ConfigPath
    $StopOnFailure = $cfg.StopOnFailure; $VmStartTimeout = $cfg.VmStartTimeout; $VmBootDelay = $cfg.VmBootDelay
    if ($r.skipped) {
        Set-StepStatus -GuestKey $GuestKey -StepName "Start-GuestOS" -Status "skipped" -Skipped $true
    } elseif ($r.success) {
        Set-StepStatus -GuestKey $GuestKey -StepName "Start-GuestOS" -Status "pass"
        Write-Output "  $GuestKey Start-GuestOS: PASS"
    } else {
        Write-Warning "  ERROR [$GuestKey / Start-GuestOS]: $($r.errorMessage)"
        Write-Output "  Log directory: $env:YURUNA_LOG_DIR"
        Set-StepStatus  -GuestKey $GuestKey -StepName "Start-GuestOS" -Status "fail" -ErrorMessage $r.errorMessage
        Set-GuestStatus -GuestKey $GuestKey -Status "fail"
        $IterState.OverallPassed = $false; $IterState.FailedGuest = $GuestKey; $IterState.FailedStep = "Start-GuestOS"; $IterState.FailureMessage = $r.errorMessage
        Copy-FailureArtifactsToStatusLog -VMName $VMName -GuestKey $GuestKey -RepoRoot $RepoRoot -ModulesDir $ModulesDir -LogFile $LogFile
        if ($StopOnFailure) {
            Write-Output "  VM '$VMName' left running for investigation."
            $IterState.Control = 'break'; return
        }
        Write-Output "  Cleaning up VM '$VMName' after failure..."
        Remove-GuestVMQuietly -VMName $VMName
        $IterState.Control = 'continue'; return
    }

    # --- REGION: New-VM.Resource (poll until running, wait boot delay)
    Assert-CachingProxyStillReachable -ProxyUrl $cachingProxyUrl -StepName "New-VM.Resource" -GuestKey $GuestKey
    Set-StepStatus -GuestKey $GuestKey -StepName "New-VM.Resource" -Status "running"
    $ok = Wait-VMRunning -VMName $VMName `
        -TimeoutSeconds $VmStartTimeout -BootDelaySeconds $VmBootDelay
    Sync-RunnerStepConfig -State $cfg -ConfigPath $ConfigPath
    $StopOnFailure = $cfg.StopOnFailure; $VmStartTimeout = $cfg.VmStartTimeout; $VmBootDelay = $cfg.VmBootDelay
    if (-not $ok) {
        $err = "VM '$VMName' did not reach running state after start."
        Write-Warning "  ERROR [$GuestKey / New-VM.Resource]: $err"
        Write-Output "  Log directory: $env:YURUNA_LOG_DIR"
        Set-StepStatus  -GuestKey $GuestKey -StepName "New-VM.Resource" -Status "fail" -ErrorMessage $err
        Set-GuestStatus -GuestKey $GuestKey -Status "fail"
        $IterState.OverallPassed = $false; $IterState.FailedGuest = $GuestKey; $IterState.FailedStep = "New-VM.Resource"; $IterState.FailureMessage = $err
        Write-CycleInfraFailure -Stage 'New-VM.Resource' -FailureClass 'provisioning_failure' -GuestKey $GuestKey -VMName $VMName -ErrorMessage $err -HostType $HostType
        Copy-FailureArtifactsToStatusLog -VMName $VMName -GuestKey $GuestKey -RepoRoot $RepoRoot -ModulesDir $ModulesDir -LogFile $LogFile
        if ($StopOnFailure) {
            Write-Output "  VM '$VMName' left running for investigation."
            $IterState.Control = 'break'; return
        }
        Write-Output "  Cleaning up VM '$VMName' after failure..."
        Remove-GuestVMQuietly -VMName $VMName
        $IterState.Control = 'continue'; return
    }
    Write-Output "  $GuestKey New-VM.Resource: PASS"
    Set-StepStatus -GuestKey $GuestKey -StepName "New-VM.Resource" -Status "pass"

    # --- REGION: Screenshots (compare against trained references)
    if ($hasScreenshots) {
        Assert-CachingProxyStillReachable -ProxyUrl $cachingProxyUrl -StepName "Screenshots" -GuestKey $GuestKey
        Set-StepStatus -GuestKey $GuestKey -StepName "Screenshots" -Status "running"
        $r = Invoke-ScreenshotTest -GuestKey $GuestKey `
            -VMName $VMName -ScreenshotsDir $ScreenshotsDir
        Sync-RunnerStepConfig -State $cfg -ConfigPath $ConfigPath
        $StopOnFailure = $cfg.StopOnFailure; $VmStartTimeout = $cfg.VmStartTimeout; $VmBootDelay = $cfg.VmBootDelay
        if ($r.skipped) {
            Set-StepStatus -GuestKey $GuestKey -StepName "Screenshots" -Status "skipped" -Skipped $true
        } elseif ($r.success) {
            Set-StepStatus -GuestKey $GuestKey -StepName "Screenshots" -Status "pass"
        } else {
            Write-Warning "  ERROR [$GuestKey / Screenshots]: $($r.errorMessage)"
            Write-Output "  Log directory: $env:YURUNA_LOG_DIR"
            Set-StepStatus  -GuestKey $GuestKey -StepName "Screenshots" -Status "fail" -ErrorMessage $r.errorMessage
            Set-GuestStatus -GuestKey $GuestKey -Status "fail"
            $IterState.OverallPassed = $false; $IterState.FailedGuest = $GuestKey; $IterState.FailedStep = "Screenshots"; $IterState.FailureMessage = $r.errorMessage
            Copy-FailureArtifactsToStatusLog -VMName $VMName -GuestKey $GuestKey -RepoRoot $RepoRoot -ModulesDir $ModulesDir -LogFile $LogFile
            if ($StopOnFailure) {
                Write-Output "  VM '$VMName' left running for investigation."
                $IterState.Control = 'break'; return
            }
            Write-Output "  Cleaning up VM '$VMName' after failure..."
            Remove-GuestVMQuietly -VMName $VMName
            $IterState.Control = 'continue'; return
        }
    }

    # --- REGION: Start-GuestWorkload (workload sequences from the cycle plan)
    if ($hasExtensions) {
        Assert-CachingProxyStillReachable -ProxyUrl $cachingProxyUrl -StepName "Start-GuestWorkload" -GuestKey $GuestKey
        Set-StepStatus -GuestKey $GuestKey -StepName "Start-GuestWorkload" -Status "running"
        $wlStartUtc = [DateTime]::UtcNow
        $r = Start-GuestWorkload -HostType $HostType -GuestKey $GuestKey -VMName $VMName -RepoRoot $RepoRoot -SequencesDir $SequencesDir -SequenceNames $workSeqs -EffectiveVariables $cascadeVarsMap
        # Warm-resume: on an eligible transient failure, re-run the failed sequence
        # from its last-good step on the SAME still-alive VM (the teardown below
        # fires only on the FINAL result), up to WarmResumeMaxAttempts, before
        # falling through to today's teardown + cold re-provision. A recovered run
        # reaches the pass branch; the warm_resume event keeps a resumed pass
        # observable rather than a silent one.
        if ($cfg.WarmResumeEnabled -and -not $r.success -and -not $r.skipped `
                -and (Get-Command Read-WarmResumeCheckpoint -ErrorAction SilentlyContinue)) {
            # Break-free loop: the iteration signals escapes via $IterState.Control,
            # never a break (which, absent a loop, would escape the guest foreach) --
            # so $wrDone carries the stop condition instead.
            $wrAttempt = 0
            $wrDone    = $false
            while (-not $wrDone -and $wrAttempt -lt [int]$cfg.WarmResumeMaxAttempts) {
                $wrCp  = Read-WarmResumeCheckpoint -LogDir $env:YURUNA_LOG_DIR -NotBeforeUtc $wlStartUtc
                $wrDec = Get-WarmResumeDecision -Enabled $true -FailureClass $wrCp.FailureClass `
                    -SequenceName $wrCp.SequenceName -ResumeFromStep ([int]$wrCp.ResumeFromStep) -WorkloadSequences $workSeqs
                if (-not $wrDec.ShouldResume) {
                    $wrDone = $true
                } else {
                    $wrAttempt++
                    Write-Output "  WARM-RESUME ($wrAttempt/$($cfg.WarmResumeMaxAttempts)): '$($wrDec.ResumeSequence)' failed transiently ($($wrCp.FailureClass)); resuming at step $($wrCp.ResumeFromStep) on VM '$VMName' instead of redoing it from the top."
                    if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
                        $wrEv = New-WarmResumeEvent -GuestKey $GuestKey -VmName $VMName -SequenceName $wrDec.ResumeSequence `
                            -ResumeFromStep ([int]$wrCp.ResumeFromStep) -FailureClass $wrCp.FailureClass -Attempt $wrAttempt -HostType $HostType
                        Send-CycleEventSafely -EventRecord ([hashtable]$wrEv)
                    }
                    $r = Start-GuestWorkload -HostType $HostType -GuestKey $GuestKey -VMName $VMName -RepoRoot $RepoRoot `
                        -SequencesDir $SequencesDir -SequenceNames $workSeqs -EffectiveVariables $cascadeVarsMap `
                        -ResumeFromSequence $wrDec.ResumeSequence -ResumeFromStep ([int]$wrCp.ResumeFromStep)
                    if ($r.success) {
                        Write-Output "  WARM-RESUME: '$($wrDec.ResumeSequence)' recovered after $wrAttempt attempt(s)."
                        $wrDone = $true
                    }
                }
            }
        }
        Sync-RunnerStepConfig -State $cfg -ConfigPath $ConfigPath
        $StopOnFailure = $cfg.StopOnFailure; $VmStartTimeout = $cfg.VmStartTimeout; $VmBootDelay = $cfg.VmBootDelay
        if ($r.skipped) {
            Set-StepStatus -GuestKey $GuestKey -StepName "Start-GuestWorkload" -Status "skipped" -Skipped $true
        } elseif ($r.success) {
            Set-StepStatus -GuestKey $GuestKey -StepName "Start-GuestWorkload" -Status "pass"
            Write-Output "  $GuestKey Start-GuestWorkload: PASS"
        } else {
            Write-Warning "  ERROR [$GuestKey / Start-GuestWorkload]: $($r.errorMessage)"
            Write-Output "  Log directory: $env:YURUNA_LOG_DIR"
            Set-StepStatus  -GuestKey $GuestKey -StepName "Start-GuestWorkload" -Status "fail" -ErrorMessage $r.errorMessage
            Set-GuestStatus -GuestKey $GuestKey -Status "fail"
            $IterState.OverallPassed = $false; $IterState.FailedGuest = $GuestKey; $IterState.FailedStep = "Start-GuestWorkload"; $IterState.FailureMessage = $r.errorMessage
            # Surface the schema-v2 cause (class / repro / step) on the live
            # dashboard at failure time. Reuse Get-FailureEventData so the
            # last_failure.json parse isn't duplicated here.
            if ((Get-Command Get-FailureEventData -ErrorAction SilentlyContinue) -and (Get-Command Set-LastFailureSummary -ErrorAction SilentlyContinue)) {
                try {
                    $fe = Get-FailureEventData -HostType $HostType -Hostname (hostname) -GuestKey $GuestKey -StepName 'Start-GuestWorkload' -ErrorMessage $r.errorMessage
                    $feRepro = if ($fe.repro -is [System.Collections.IDictionary] -and $fe.repro.Contains('command')) { [string]$fe.repro['command'] } elseif ($fe.Contains('reproCommand')) { [string]$fe.reproCommand } else { '' }
                    # No -RelPath: last_failure.json lives at the log root, not
                    # the per-guest cycle folder the dashboard deep-links into,
                    # so a relPath here would render a dead link. The classified
                    # cause + repro command (shown inline) carry the value.
                    Set-LastFailureSummary -FailureClass ([string]$fe.failureClass) -Severity ([string]$fe.severity) `
                        -StepNumber ([int]($fe.stepNumber)) -SequenceName ([string]$fe.sequenceName) -ReproCommand $feRepro `
                        -GuestKey $GuestKey -StepName 'Start-GuestWorkload' -ErrorMessage $r.errorMessage -VmName $VMName -Confirm:$false
                } catch { $null = $_ }
            }
            Copy-FailureArtifactsToStatusLog -VMName $VMName -GuestKey $GuestKey -RepoRoot $RepoRoot -ModulesDir $ModulesDir -LogFile $LogFile
            if ($StopOnFailure) {
                Write-Output "  VM '$VMName' left running for investigation."
                $IterState.Control = 'break'; return
            }
            Write-Output "  Cleaning up VM '$VMName' after failure..."
            Remove-GuestVMQuietly -VMName $VMName
            $IterState.Control = 'continue'; return
        }
    }

    # --- REGION: Stop and remove this guest VM before starting the next
    Set-GuestStatus -GuestKey $GuestKey -Status "pass"
    Write-Output "  ${GuestKey}: PASS"
    # Guest passed -> discard the per-VM ring-buffer of pre-OCR screen
    # captures. On any prior failure path this directory is preserved
    # (Copy-FailureArtifactsToStatusLog copies it before we get here).
    # Lives inside the cycle folder; deletion here is success-cleanup
    # only -- a stuck cycle that never reaches this line leaves the
    # buffer in place for post-mortem.
    $screensDir = Get-CycleScreenDir -VMName $VMName -WhatIf:$false
    if (Test-Path $screensDir) {
        Remove-Item -Path $screensDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Verbose "  Stopping VM '$VMName'..."
    $savedProgress = $global:ProgressPreference
    $global:ProgressPreference = 'SilentlyContinue'
    # -Force: stop-then-DELETE. Remove-VM takes the disk on the next line, so a
    # clean guest shutdown protects nothing here and would add its full duration
    # (tens of seconds on a k8s guest) to every cycle's teardown.
    Stop-VM -VMName $VMName -Force -Confirm:$false | Out-Null
    Write-Verbose "  Removing VM '$VMName'..."
    Remove-VM -VMName $VMName -Confirm:$false | Out-Null
    $global:ProgressPreference = $savedProgress
    # Serialization guard: guests run one at a time, so confirm this VM is
    # actually gone before the next guest cold-starts -- otherwise a teardown
    # that silently stalled (e.g. utmctl unresponsive under host memory
    # pressure) leaves it running and the next guest doubles the load.
    # Remove-VM's own return can't answer this: its status Write-Output lines
    # fold into the [bool] cast, so probe Get-VMState directly. A VM still
    # 'running' after one retry blocks the next guest; anything else (absent /
    # stopped / can't-tell) proceeds.
    if ((Get-VMState -VMName $VMName) -eq 'running') {
        Write-Warning "  Teardown of '$VMName' left it running; retrying removal."
        Remove-VM -VMName $VMName -Confirm:$false | Out-Null
    }
    if ((Get-VMState -VMName $VMName) -eq 'running') {
        $err = "VM '$VMName' is still running after $GuestKey passed and could not be torn down; refusing to start the next guest so guests stay serialized."
        Write-Warning "  ERROR [$GuestKey / Cleanup]: $err"
        $IterState.OverallPassed = $false; $IterState.FailedGuest = $GuestKey; $IterState.FailedStep = "Cleanup"; $IterState.FailureMessage = $err
        Write-CycleInfraFailure -Stage 'Cleanup' -FailureClass 'provisioning_failure' -GuestKey $GuestKey -VMName $VMName -ErrorMessage $err -HostType $HostType
        $IterState.Control = 'break'; $script:ActiveVMName = $null; return
    }
    Write-Output "  Cleanup complete for $GuestKey."
    $script:ActiveVMName = $null
}


Export-ModuleMember -Function `
    Write-InnerLog, Convert-LocalRepoUrlToPath, `
    Write-UncommittedChangesWarning, Assert-CachingProxyStillReachable, `
    Get-RunnerReloadableConfig, New-RunnerConfigState, Sync-RunnerCycleConfig, `
    Sync-RunnerStepConfig, `
    Resolve-RunnerLogLevel, Copy-FailureArtifactsToStatusLog, Invoke-RunnerInnerCycle
