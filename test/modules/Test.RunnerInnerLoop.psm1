<#PSScriptInfo
.VERSION 2026.07.03
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
# pointed at the IP the host had on the prior network — which guests can
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
    return [ordered]@{
        StopOnFailure        = if ($tc -is [System.Collections.IDictionary] -and $tc.Contains('shouldStopOnFailure')) { [bool]$tc['shouldStopOnFailure'] } else { $false }
        VmStartTimeout       = if ($vs -is [System.Collections.IDictionary] -and $vs['startTimeoutSeconds']) { [int]$vs['startTimeoutSeconds'] } else { 120 }
        VmBootDelay          = if ($vs -is [System.Collections.IDictionary] -and $vs['bootDelaySeconds'])    { [int]$vs['bootDelaySeconds'] }    else { 15 }
        GetImageRefreshHours = if ($vi -is [System.Collections.IDictionary] -and $vi['refreshHours'])        { [int]$vi['refreshHours'] }        else { 24 }
        CycleDelay           = if ($tc -is [System.Collections.IDictionary] -and $tc['cycleDelaySeconds'])   { [int]$tc['cycleDelaySeconds'] }   else { $CycleDelayFallback }
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
        $cycleBase   = if (Get-Command Get-CycleFolderIdentity -ErrorAction SilentlyContinue) {
            Get-CycleFolderIdentity -Path $global:__YurunaCycleFolder
        } else {
            Split-Path -Leaf $global:__YurunaCycleFolder
        }

        # Three artifact sources, written by different code paths:
        #   * screens_<VM>/raw_*.png         — Wait-ForText ring buffer (GUI mode)
        #   * failure_screenshot_<VM>.png    — single frozen-moment shot from
        #                                      non-waitForText failures (any
        #                                      sequence step that isn't
        #                                      waitForText/waitForAndEnter,
        #                                      including runOverSsh)
        #   * failure_ocr_<VM>.txt           — last OCR text from waitForText
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
            # Frame count uses the .png extension only — .txt files are
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
    # A module function does not see the entry point's script scope, so every
    # input the cycle body reads crosses explicitly through $State.
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
    $VmStartTimeout       = $cfg.VmStartTimeout
    $VmBootDelay          = $cfg.VmBootDelay
    $GetImageRefreshHours = $cfg.GetImageRefreshHours
    $CycleDelay           = $cfg.CycleDelay
# === Continuous test loop ===
$CycleCount     = 0
try {
    $prevStatus = Get-Content -Raw $StatusFile | ConvertFrom-Json
    if ($prevStatus.cycle) { $CycleCount = [int]$prevStatus.cycle }
} catch { Write-Warning "Could not read previous cycle count from status file: $_" }
$OverallPassed       = $true
# Consecutive unhandled-crash counter driving the escalating auto-retry backoff
# and the hard MaxConsecutiveCrashes abort further down. Loaded from
# runner.gating.json below and carried back so it survives the single-cycle
# respawn: a process-local counter would reset to 0 every respawn, so the
# backoff could never escalate past the first step and the abort could never
# fire. A cycle that reaches finalization (pass OR guest-failure) resets it to
# 0, since reaching finalization proves the engine ran without crashing.
$ConsecutiveCrashes  = 0
$MaxConsecutiveCrashes = 3

# === Notification gating ===
# failuresBeforeAlert : consecutive failures needed to send an alert.
# successesBeforeRearm: consecutive successes (or a fresh runner start)
#                       needed before the alert can fire again.
# State: Armed → (N failures) → Fired → (M successes) → Armed
#
# Persisted across the single-cycle inner respawn via runner.gating.json
# in the runtime dir. Without this, every inner would start fresh-armed
# and a flapping host would email on every cycle. Outer-launched runs
# (YURUNA_RUNNER_RELAUNCH=1) load + save; standalone direct-invoke runs
# also load + save so the operator can Ctrl+C and resume without losing
# the gating context.
$FailuresBeforeAlert  = [int]($Config.notification.failuresBeforeAlert  ?? 1)
$SuccessesBeforeRearm = [int]($Config.notification.successesBeforeRearm ?? 1)
$ConsecutiveFailures  = 0
$ConsecutiveSuccesses = 0
$AlertArmed           = $true
$GatingFile = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.gating.json'
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

while ($true) {
    if ($ShutdownState['Requested']) {
        Write-Output "Shutdown requested. Exiting cycle loop."
        break
    }

    # Re-check host conditions each cycle — settings can revert (OS
    # update, manual change) between long-running cycles.
    if (-not (Assert-HostConditionSet -HostType $HostType)) {
        Write-Warning "Host conditions failed. Fix the reported issues and restart."
        break
    }

    # Ensure a usable display surface for this cycle (e.g. attach a virtual
    # display on a headless Hyper-V host) so screen-capture/OCR survives the
    # physical monitor coming and going mid-run (KVM switch). Opt-in: the
    # Hyper-V virtual display attaches only when YURUNA_VIRTUAL_DISPLAY is set.
    # Idempotent and cheap — short-circuits when already present; no-op on
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
    # fail OUTSIDE the sequence engine, so they never write last_failure.json or a
    # step_failure event -- leaving the remediation loop blind to that half of the
    # failure surface. This closure lands a schema-v2 infra record
    # (New-InfraFailureRecord) on disk + the event stream so those stages are
    # classified and routable. It targets the cycle folder once Start-LogFile has
    # run, else $env:YURUNA_LOG_DIR (bootstrap stages); never clobbers a richer
    # engine-written record; and is fully guarded so telemetry can never fail the
    # cycle. Invoked with & in this scope so it reads $HostType / the cycle-folder
    # global directly, and resolves the globally-imported builders.
    $writeInfraFailure = {
        param([string]$Stage, [string]$FailureClass, [string]$Severity = 'hard',
              [string]$GuestKey = '', [string]$VMName = '', [string]$ErrorMessage = '')
        try {
            # Write to the LOG ROOT ($env:YURUNA_LOG_DIR), NOT the per-cycle
            # subfolder: that is exactly where the engine writes last_failure.json
            # and where the routing consumers read it (Get-OuterLastFailureClass +
            # Invoke-Remediation default to $env:YURUNA_LOG_DIR/last_failure.json).
            # A record in the cycle subfolder would be invisible to remediation.
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
            # Surface the classified cause on the live dashboard too (no-op before
            # the status doc exists, e.g. bootstrap stages). RelPath '' -- an infra
            # record sits at the cycle-folder root, not the per-guest subfolder the
            # dashboard deep-links into.
            if (Get-Command Set-LastFailureSummary -ErrorAction SilentlyContinue) {
                Set-LastFailureSummary -FailureClass $FailureClass -Severity $Severity `
                    -SequenceName $Stage -GuestKey $GuestKey -StepName $Stage `
                    -ErrorMessage $ErrorMessage -VmName $VMName -Confirm:$false
            }
        } catch { $null = $_ }
    }

  try {

    Write-Output ""
    Write-Output "============================================="
    Write-Output "  CYCLE $CycleCount"
    Write-Output "  (inner cycle starting -- local time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))"
    Write-Output "============================================="

    # --- Authentication vault: fresh per cycle ---
    # Initialize-VaultConnection creates an empty vault.yml if missing.
    # If a prior failed cycle left one in place, we reuse it as a
    # debugging aid. On cycle success the vault is wiped further down.
    try {
        [void](Import-Extension -Area 'authentication' -RequireSingle)
        Initialize-VaultConnection
    } catch {
        Write-Warning "Authentication extension init failed: $($_.Exception.Message). Continuing; per-guest credential ops will surface the underlying error."
    }

    # --- Reset status.json so the dashboard stops showing the previous
    # cycle's pass/fail + per-guest pills while the slow setup below
    # (git pull, project clone, status-service restart, module re-imports,
    # cycle-plan resolution) runs. Initialize-StatusDocument later
    # populates the fully-shaped doc once the guest list is known.
    Reset-StatusDocumentForCycleStart -StatusFilePath $StatusFile -Confirm:$false

    # --- Git pull ---
    # Unconditional single-shot pull at cycle start by design. Gating on
    # `git ls-remote HEAD` SHA vs local to skip no-op fetches would be
    # two round-trips to github.com (ls-remote + pull) where one already
    # does the work; the single `pull --ff-only` is the source of truth
    # for "did HEAD move?" without an extra network call. Keeping it
    # unconditional also means a host that just came back online
    # recovers in one cycle without an extra branch.
    if (-not $NoGitPull) {
        if (-not (Invoke-GitPull -RepoRoot $RepoRoot)) {
            # Differentiate network-out from local-divergence BEFORE listing
            # the generic causes. Without this, a host whose NIC dropped
            # mid-cycle gets the same "rebase/merge manually" suggestion as
            # a genuinely diverged branch -- the operator wastes time
            # checking the wrong thing. Two probes:
            #   1) DNS resolution of github.com (catches "no DNS" / NIC
            #      down / Wi-Fi disabled scenarios). Cheap and decisive --
            #      the symptom in the cycle log was literally "Could not
            #      resolve host: github.com".
            #   2) TCP reach to github.com:443 (catches firewall / proxy /
            #      partial-network states where DNS resolves but HTTPS
            #      doesn't reach).
            # When DNS or TCP fails, emit the network-specific message and
            # suppress the divergence/uncommitted causes (they're not
            # relevant). When the probes pass, the failure is a real
            # git-side issue and the generic message stands.
            $netDiag = ''
            $dnsOk = $false
            $tcpOk = $false
            try { [void][System.Net.Dns]::GetHostAddresses('github.com'); $dnsOk = $true } catch {
                $netDiag = "DNS resolution of github.com failed: $($_.Exception.Message)"
            }
            if ($dnsOk) {
                try {
                    $tcp = New-Object System.Net.Sockets.TcpClient
                    $async = $tcp.BeginConnect('github.com', 443, $null, $null)
                    $tcpOk = $async.AsyncWaitHandle.WaitOne(3000) -and $tcp.Connected
                    $tcp.Close()
                    if (-not $tcpOk) { $netDiag = 'TCP connect to github.com:443 timed out (DNS resolved but HTTPS unreachable)' }
                } catch {
                    $netDiag = "TCP connect to github.com:443 threw: $($_.Exception.Message)"
                }
            }

            Write-Output ""
            Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            Write-Output "  ERROR: git sync failed"
            if (-not $dnsOk -or -not $tcpOk) {
                Write-Output "  Network connectivity issue detected: $netDiag"
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
            & $writeInfraFailure -Stage 'GitPull' -FailureClass $gitClass -GuestKey '(bootstrap)' -ErrorMessage $gitPullErr
            # Route this bootstrap failure through the SAME notification gating as
            # an in-cycle failure: bump the consecutive-failure counter and alert
            # only once it reaches the threshold while armed, so a flapping network
            # throttles to one email per streak instead of one per cycle. break
            # (not exit) so the carry-back persists the gating counters across the
            # single-cycle respawn; $OverallPassed=$false makes the process exit
            # non-zero so the outer enters its failure-pause. A sync failure is
            # not a code crash, so $ConsecutiveCrashes is left untouched -- a
            # persistent outage is throttled by the outer failure-pause, not the
            # MaxConsecutiveCrashes abort.
            $ConsecutiveSuccesses = 0
            $ConsecutiveFailures++
            $OverallPassed = $false
            Write-Output "  Alert:   $ConsecutiveFailures/$FailuresBeforeAlert failures $(if ($AlertArmed) {'(armed)'} else {'(suppressed)'})"
            if ($AlertArmed -and $ConsecutiveFailures -ge $FailuresBeforeAlert) {
                Send-CycleFailureNotification `
                    -HostType            $HostType `
                    -SubjectSuffix       'GitPull' `
                    -GuestKey            '(bootstrap)' `
                    -StepName            'GitPull' `
                    -ErrorMessage        $gitPullErr `
                    -CycleId             '(not yet assigned)' `
                    -GitCommit           $gitPullCommit `
                    -DefaultFailureClass $gitClass `
                    -DefaultSeverity     'hard'
                $AlertArmed = $false
                Write-Output "  Notification sent. Alert suppressed until $SuccessesBeforeRearm consecutive successes or runner restart."
            } else {
                Write-Output "  Notification suppressed ($ConsecutiveFailures/$FailuresBeforeAlert failures, armed=$AlertArmed)."
            }
            break
        }
    } else {
        $Warnings.Add("Git pull was skipped (-NoGitPull).")
    }
    $GitCommit = Get-CurrentGitCommit -RepoRoot $RepoRoot

    # --- Refresh <RepoRoot>/project from test.config.yml's repositories.projectUrl ---
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
        & $writeInfraFailure -Stage 'ProjectClone' -FailureClass 'bootstrap_sync' -GuestKey '(bootstrap)' -ErrorMessage $cloneRes.errorMessage
        # Route through the same notification gating as an in-cycle failure so a
        # persistent clone problem alerts once per streak, not every cycle. Mark
        # the cycle failed ($OverallPassed=$false) so the carry-back persists the
        # gating counters AND the process exits non-zero -- the outer then enters
        # its failure-pause (60-min cap, polled for new commits) rather than
        # respawning at full speed. The inner does not sleep here; the outer gates
        # re-spawning. Like git-pull, this is not a code crash, so
        # $ConsecutiveCrashes is left untouched.
        $ConsecutiveSuccesses = 0
        $ConsecutiveFailures++
        $OverallPassed = $false
        Write-Output "  Alert:   $ConsecutiveFailures/$FailuresBeforeAlert failures $(if ($AlertArmed) {'(armed)'} else {'(suppressed)'})"
        if ($AlertArmed -and $ConsecutiveFailures -ge $FailuresBeforeAlert) {
            Send-CycleFailureNotification `
                -HostType            $HostType `
                -SubjectSuffix       'ProjectClone' `
                -GuestKey            '(bootstrap)' `
                -StepName            'ProjectClone' `
                -ErrorMessage        $cloneRes.errorMessage `
                -CycleId             '(not yet assigned)' `
                -GitCommit           $GitCommit `
                -DefaultFailureClass 'bootstrap_sync' `
                -DefaultSeverity     'hard'
            $AlertArmed = $false
            Write-Output "  Notification sent. Alert suppressed until $SuccessesBeforeRearm consecutive successes or runner restart."
        } else {
            Write-Output "  Notification suppressed ($ConsecutiveFailures/$FailuresBeforeAlert failures, armed=$AlertArmed)."
        }
        break
    }

    # --- Capture project repo HEAD ---
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

    # --- Unconditional working-tree-drift warning ---
    # /yuruna-archive.tar.gz and /yuruna-project-archive.tar.gz only ship
    # COMMITTED content (`git archive HEAD`). Surface uncommitted local
    # changes via Write-Warning -- bypasses logLevel -- so the operator
    # catches the divergence before a guest hits a "script not found"
    # trap caused by host code referencing a path that isn't yet in HEAD.
    Write-UncommittedChangesWarning -RepoRoot $RepoRoot -ProjectUrl $projUrl

    # --- Re-import modules so a mid-run `git pull` propagates code changes ---
    # Unconditional, both platforms: same guarantee regardless of how the
    # cycle loop is structured. The failure class this guards against: on
    # macOS (which loops in-process via `continue` near the bottom of the
    # cycle), PowerShell's module cache survives across cycles, so a
    # long-running runner keeps executing stale module code after a
    # mid-run `git pull` -- e.g. building UTM bundle paths from a cached
    # Test.Start-VM whose layout no longer matches disk, so Start-VM fails
    # every guest with "UTM bundle not found: …". On
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

    # --- Re-read config (may have changed via git pull); sync against template ---
    try {
        $Config = Update-TestConfigFromTemplate -ConfigPath $ConfigPath -TemplatePath $TemplatePath
    } catch {
        Write-Warning "Could not reload config after git pull, using previous config: $_"
    }

    # --- Restart status server to pick up any file/config changes ---
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
    # Get-Image, the cleanup → create → start → verify per-guest loop).
    # Falls back to the legacy guestSequence list when the cycle config is
    # missing — useful before the project repo clone bootstrap lands and
    # for operators who haven't migrated yet.
    $script:CyclePlan = $null
    $plannerFatal     = $false
    $script:PoolCycle = $false
    try {
        # A pooled host drives the cycle from its pool's assigned test-sets
        # (runtime/pool.manifest.json, written by the outer loop's Sync-YurunaPoolIntent)
        # instead of test.runner.yml. Resolve-PoolCyclePlan returns $null when this
        # host has no manifest or no runnable guest for any assigned set -> fall
        # through to the BYTE-IDENTICAL single-host path below. A test-set sequence
        # typo still throws PlannerFatal, so the catch's banner aborts the cycle
        # exactly as on the single-host path.
        $poolManifest = if (Get-Command Read-YurunaPoolManifest -ErrorAction SilentlyContinue) { Read-YurunaPoolManifest } else { $null }
        if ($poolManifest -and @($poolManifest['testSets']).Count -gt 0 -and (Get-Command Resolve-PoolCyclePlan -ErrorAction SilentlyContinue)) {
            $script:CyclePlan = Resolve-PoolCyclePlan -RepoRoot $RepoRoot -SequencesDir $SequencesDir -HostType $HostType -Manifest $poolManifest
            if ($script:CyclePlan -and $script:CyclePlan.Count -gt 0) {
                $script:PoolCycle = $true
                Write-Output "Pool cycle: $($script:CyclePlan.Count) plan entries from pool '$($poolManifest['poolId'])' test-set(s)."
            }
        }
        if (-not $script:PoolCycle) {
            $script:CyclePlan = Resolve-CyclePlan -RepoRoot $RepoRoot -SequencesDir $SequencesDir -HostType $HostType
        }
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
            & $writeInfraFailure -Stage 'Resolve-CyclePlan' -FailureClass 'plan_invalid' -GuestKey '(planner)' -ErrorMessage $FailureMessage
        } else {
            # Inner message now embeds the offending file path (Read-SequenceFile
            # walks the YamlDotNet exception chain to surface file + line:col),
            # so don't prefix with project/test/test.runner.yml -- the actual
            # failure may be in any sequence the planner walked to.
            Write-Warning "Could not resolve cycle plan - falling back to guestSequence: $($_.Exception.Message)"
        }
    }
    if ($plannerFatal) {
        $GuestList    = @()
        $SequenceList = @()
    } elseif ($script:CyclePlan -and $script:CyclePlan.Count -gt 0) {
        $GuestList    = Get-CyclePlanGuestList -Plan $script:CyclePlan
        # Ordered top-level sequences (test.runner.yml entries) -> guest(s),
        # for the dashboard's per-sequence cards. Empty on the legacy
        # guestSequence path below, where the dashboard falls back to a flat
        # per-guest list.
        $SequenceList = Get-CyclePlanSequenceList -Plan $script:CyclePlan
        Write-Output "Cycle plan: $($script:CyclePlan.Count) entries across $($GuestList.Count) guest(s)."
    } else {
        $GuestList    = Get-GuestList -Config $Config
        $SequenceList = @()
    }

    # Cascade overrides for Test.Ssh.Get-GuestSshUser. The planner already
    # threads `variables.username:` through New-VM (-> cloud-init) and
    # Invoke-Sequence's $vars scope, but Get-GuestSshUser is the lookup
    # point for code paths that DON'T receive $vars: Save-GuestDiagnostic
    # (called by the baseline's saveSystemDiagnostic), the host driver
    # Send-Text / Send-Key SSH-mode dispatchers, and the inner runner's
    # own fetchAndExecute SSH path. Without this registration the cycle
    # creates the VM with the cascaded user but the harness's SSH probes
    # target the hardcoded default, which no longer exists on the VM.
    # Test.Ssh is loaded ad-hoc later in this script (line ~939); ensure
    # the override-registration helpers are available before we call them.
    if (-not (Get-Command Set-GuestSshUserOverride -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $ModulesDir 'Test.Ssh.psm1') -Force -Global -ErrorAction SilentlyContinue
    }
    if (Get-Command Clear-GuestSshUserOverride -ErrorAction SilentlyContinue) {
        Clear-GuestSshUserOverride
    }
    if (-not $plannerFatal -and $script:CyclePlan -and $script:CyclePlan.Count -gt 0 -and
        (Get-Command Set-GuestSshUserOverride -ErrorAction SilentlyContinue)) {
        foreach ($_gk in $GuestList) {
            $_merged = Get-CyclePlanSequencesForGuest -Plan $script:CyclePlan -GuestKey $_gk
            if ($_merged -and $_merged.effectiveUsername) {
                Set-GuestSshUserOverride -GuestKey $_gk -Username ([string]$_merged.effectiveUsername)
            }
        }
    }

    # --- Capability gate ----------------------------------------------------
    # Print the matrix once per cycle (helps post-mortem readers in the
    # cycle log) and refuse the cycle when the plan references a host
    # I/O action no backend on this host has registered — catching it
    # here, at plan time, instead of as a silent "Unknown host: ..."
    # that surfaces only at runtime, deep inside a sequence step.
    if (-not $plannerFatal -and $script:CyclePlan -and $script:CyclePlan.Count -gt 0) {
        Write-HostCapabilityBanner
        $cap = Test-CyclePlanCapabilityFromPlan -Plan $script:CyclePlan -RepoRoot $RepoRoot -SequencesDir $SequencesDir -HostType $HostType
        if (-not $cap.supported) {
            Write-Output ""
            Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            Write-Output "  CAPABILITY GATE FAILED -- cycle aborted on '$($cap.hostType)'."
            if ($cap.missingHostIO.Count) {
                Write-Output "  Sequences reference host I/O actions this host has no backend for:"
                foreach ($a in $cap.missingHostIO) { Write-Output "    - $a" }
                Write-Output "  Wire a backend via Register-HostIOProvider in Invoke-Sequence.psm1,"
                Write-Output "  or drop the requiring action from the cycle's sequence YAMLs."
            }
            if ($cap.ocrRequired -and -not $cap.ocrAvailable) {
                Write-Output "  Sequences require OCR but no OCR provider is enabled+available."
                Write-Output "  Install tesseract or wire a per-host provider via Register-OcrProvider."
            }
            Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            $GuestList      = @()
            $SequenceList   = @()
            $OverallPassed  = $false
            $FailedGuest    = "(capability gate)"
            $FailedStep     = "Test-CyclePlanCapability"
            $FailureMessage = "Missing host I/O: $($cap.missingHostIO -join ', '); ocrRequired=$($cap.ocrRequired) ocrAvailable=$($cap.ocrAvailable)"
            & $writeInfraFailure -Stage 'Test-CyclePlanCapability' -FailureClass 'plan_invalid' -GuestKey '(capability gate)' -ErrorMessage $FailureMessage
        }
        if ($cap.unknownActions.Count) {
            # Don't fail the cycle on an unknown verb — the engine still
            # has its own switch which will throw at runtime, but surface
            # the typo early so the operator notices before the slow path.
            Write-Warning "Cycle plan references unknown action verbs (typo? new verb?): $($cap.unknownActions -join ', ')"
        }
    }
    $Prefix = $Config.vmStart.testVmNamePrefix ?? "test-"
    # On a POOL cycle, scope VM names by this host's id so pool members
    # sharing a store never collide; the single-host path passes '' for a
    # byte-identical name. Also capture the cycle's baseline keystroke mechanism so
    # per-guest overrides can be applied + reset between guests below.
    $_poolHostId = if ($script:PoolCycle) { [string]$global:__YurunaHostId } else { '' }
    $script:PoolBaselineKsm = if (Get-Command Get-DefaultKeystrokeMechanism -ErrorAction SilentlyContinue) { Get-DefaultKeystrokeMechanism } else { 'GUI' }

    # Build VM name map via Get-TestVMName so any guestSequence key yields a
    # stable VM name — no hardcoded per-guest lookup needed.
    $VMNames = @{}
    foreach ($GuestKey in $GuestList) {
        $VMNames[$GuestKey] = Get-TestVMName -GuestKey $GuestKey -Prefix $Prefix -HostId $_poolHostId
    }

    # --- Derive step list from cycle plan and screenshot schedules ---
    # $hasExtensions is true iff the cycle plan has any non-start sequence
    # for any guest (since Start-GuestWorkload now runs the workload-phase
    # sequences from the plan rather than discovering .ps1 files).
    # Step names are also the dashboard tile labels; "New-VM.Resource" is
    # the post-prep verification, kept distinct from the "New-VM"
    # definition step. The HTML collapses the New-VM / Start-VM /
    # New-VM.Resource triplet into a single tile.
    $BaseSteps = @("New-VM", "Start-VM", "Start-GuestOS", "New-VM.Resource")
    $hasExtensions  = $false
    $hasScreenshots = $false
    foreach ($GuestKey in $GuestList) {
        if ($script:CyclePlan -and $script:CyclePlan.Count -gt 0) {
            $merged = Get-CyclePlanSequencesForGuest -Plan $script:CyclePlan -GuestKey $GuestKey
            if ($merged.workloadSequences.Count -gt 0) { $hasExtensions = $true }
        }
        if ((Get-ScreenshotSchedule -GuestKey $GuestKey -ScreenshotsDir $ScreenshotsDir).Count -gt 0) {
            $hasScreenshots = $true
        }
    }
    $StepNames = $BaseSteps
    if ($hasScreenshots) { $StepNames += @("Screenshots") }
    if ($hasExtensions)  { $StepNames += @("Start-GuestWorkload") }

    # Cycle-start reloadable knobs from the freshly-reconciled config, resolved
    # through the same tested rule set as the mid-cycle Sync-RunnerCycleConfig
    # refresh (Get-RunnerReloadableConfig): a 0/absent value falls back to the
    # default and CycleDelay honors the -CycleDelaySeconds override.
    $reloadable = Get-RunnerReloadableConfig -Config $Config -CycleDelayFallback $CycleDelaySeconds
    $VmStartTimeout       = $reloadable.VmStartTimeout
    $VmBootDelay          = $reloadable.VmBootDelay
    $CycleDelay           = $reloadable.CycleDelay
    $GetImageRefreshHours = $reloadable.GetImageRefreshHours
    $StopOnFailure        = $reloadable.StopOnFailure

    # --- Initialize status for this cycle ---
    # Build the gitCommits array: framework FIRST (the dashboard's
    # logFileUrl helper treats element [0] as the primary log key, and
    # the framework SHA is what Start-LogFile actually used to name
    # the per-cycle log file), project SECOND if a clone was produced
    # this cycle. Empty repositories.projectUrl / in-tree fallback yields a
    # one-element array.
    $GitCommitsList = @(
        [ordered]@{ sha = $GitCommit; repoUrl = $Config.repositories.frameworkUrl }
    )
    if ($ProjectGitCommit -and $projUrl) {
        $GitCommitsList += [ordered]@{ sha = $ProjectGitCommit; repoUrl = $projUrl }
    }
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

    # --- Seed per-guest provenance so the UI shows the actual ISO filename
    # (e.g. "ubuntu-24.04.4-live-server-amd64.iso") instead of "guest.ubuntu.server.24".
    # Each Get-Image.ps1 writes a two-line sidecar (filename + source URL);
    # Get-BaseImageProvenance reads it. Missing sidecar or blank URL leaves
    # provenance empty and the UI falls back to guestKey. Per-cycle, so
    # deleting the ISO + re-running Get-Image reflects next cycle.
    foreach ($gk in $GuestList) {
        $imgPath = Get-ImagePath -GuestKey $gk
        if ($imgPath) {
            $prov = Get-BaseImageProvenance -BaseImagePath $imgPath
            Set-GuestProvenance -GuestKey $gk -Filename $prov.Filename -Url $prov.Url
        }
    }

    # --- Start log file (transcript captures console output) ---
    # CycleNumber is read AFTER Initialize-StatusDocument so it sees the
    # incremented value (1, 2, 3, ...). Drives the 6-digit prefix in the
    # cycleFolder name; Start-LogFile also publishes the folder URL onto
    # the status doc via Set-CycleFolderUrl so the dashboard can build
    # per-guest tile links from it.
    $CycleNumber = Get-CycleNumber
    $LogFile = Start-LogFile -TestRoot $TestRoot -CycleId $CycleId -Hostname (hostname) -CycleNumber $CycleNumber
    Write-Output "Log file: $LogFile"

    # --- Cycle-start host diagnostic ---
    # Capture host state at cycle start so a cycle that later gets stuck
    # still leaves behind a baseline of host facts (docker/kubectl state,
    # disk pressure, listening sockets, recent kernel events, top
    # processes). Written at the cycle ROOT so it sits alongside the
    # cycle HTML log -- separate from the per-guest failure-time host
    # diagnostic that Copy-FailureArtifactsToStatusLog writes into each
    # guest's data folder. Forked into a child pwsh so the diagnostic's
    # Start-Transcript and global $script:Problems list don't leak into
    # the runner. Soft-failing in line with the failure-path host diag.
    try {
        $hostDiagScript    = Join-Path $RepoRoot 'automation/Get-SystemDiagnostic.ps1'
        $cycleHostDiagOut  = Join-Path $global:__YurunaCycleFolder 'host.diagnostic.txt'
        if (Test-Path -LiteralPath $hostDiagScript) {
            & pwsh -NoProfile -NonInteractive -File $hostDiagScript -OutFile $cycleHostDiagOut | Out-Null
            if (Test-Path -LiteralPath $cycleHostDiagOut) {
                # Log line uses the cycle's stable identity so the
                # URL resolves to the post-rename location once Stop-
                # LogFile moves the folder to <base>/.
                $cycleBaseName = if (Get-Command Get-CycleFolderIdentity -ErrorAction SilentlyContinue) {
                    Get-CycleFolderIdentity -Path $global:__YurunaCycleFolder
                } else {
                    Split-Path -Leaf $global:__YurunaCycleFolder
                }
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
                -Hostname           (hostname) `
                -HarnessCommit      $GitCommit `
                -ProjectCommit      $ProjectGitCommit `
                -HostDiagnosticPath $cycleHostDiagOut
        } catch {
            Write-Warning "Start-PerfCycle failed (non-fatal): $($_.Exception.Message)"
        }
    }

    Write-Output "Cycle ID: $CycleId"
    # Commit line mirrors the dashboard's "Commit" meta-card: framework
    # SHA first, then the project SHA when repositories.projectUrl is set,
    # comma-space delimited (matching renderCommitLinks() in
    # status/index.html). $ProjectGitCommit is $null when the in-tree
    # fallback path is in use; in that case we emit framework-only so
    # the log doesn't show a dangling ", —".
    $CommitLine = if ($ProjectGitCommit) { "$GitCommit, $ProjectGitCommit" } else { $GitCommit }
    Write-Output "Commit:   $CommitLine"

    # --- Pre-flight: every guestSequence key needs a host/<short-host>/<guest>/
    #     folder on this host. No hardcoded allow-list — this existence
    #     check IS the allow-list. Missing folders fail the guest and skip
    #     it for the rest of the cycle; shouldStopOnFailure ends the cycle now.
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
        & $writeInfraFailure -Stage 'folder-check' -FailureClass 'plan_invalid' -GuestKey $GuestKey -ErrorMessage $err
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
                & $writeInfraFailure -Stage 'GetImage' -FailureClass 'network_timeout' -GuestKey $GuestKey -ErrorMessage $r.errorMessage
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
                Write-Output "Image file missing: $label — re-downloading..."
                $r = Get-Image -GuestKey $GuestKey -RepoRoot $RepoRoot -Force -Confirm:$false
                if (-not $r.success) {
                    Write-Warning "  ERROR [$GuestKey / GetImage]: $($r.errorMessage)"
                    Write-Output "  Log directory: $env:YURUNA_LOG_DIR"
                    [void]$FailedGuests.Add($GuestKey)
                    $OverallPassed = $false
                    if (-not $FailedGuest) { $FailedGuest = $GuestKey; $FailedStep = "GetImage"; $FailureMessage = $r.errorMessage }
                    & $writeInfraFailure -Stage 'GetImage' -FailureClass 'network_timeout' -GuestKey $GuestKey -ErrorMessage $r.errorMessage
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

    # --- Abort cycle early if a pre-pipeline step failed under shouldStopOnFailure ---
    if ($StopOnFailure -and -not $OverallPassed) {
        Complete-Run -OverallStatus "fail" -MaxHistoryRuns ([int]$Config.testCycle.recentDisplayCount)
        $prePipelineReason = if ($FailedGuest -and $FailedStep) { "$FailedGuest / $FailedStep (pre-pipeline)" } else { 'shouldStopOnFailure tripped pre-pipeline' }
        Stop-LogFile -Outcome 'fail' -Reason $prePipelineReason
        break
    }

    # --- Cycle-start VM sweep -------------------------------------------------
    # Remove every test-<prefix>* VM left over from a previous cycle that was
    # killed before its teardown ran (e.g. stepTimeoutMinutes firing mid-
    # sequence, or the outer being SIGKILL'd). The per-guest "Cleanup previous
    # VM" inside the loop below only clears the SAME-named VM, so a leftover
    # guest from cycle N-1 (16 GB Startup, dynamic memory disabled) could
    # starve the FIRST two guests of cycle N with "Insufficient system
    # resources (0x800705AA)" before its own iteration finally evicted it.
    # Calling Remove-TestVMFiles.ps1 here makes the cycle start from a clean
    # slate without relying on the previous cycle's teardown having completed.
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

    # --- Test each guest sequentially: cleanup → create → start → verify → screenshots → pool test → stop ---
    # One guest VM at a time, so failures don't leave other VMs active.
    foreach ($GuestKey in $GuestList) {
        if ($ShutdownState['Requested']) {
            Write-Output "Shutdown requested. Skipping remaining guests."
            $OverallPassed = $false; $FailedStep = "shutdown"
            break
        }
        # Skip guests that already failed pre-flight or Get-Image
        # (shouldStopOnFailure=false path).
        if ($FailedGuests.Contains($GuestKey)) {
            Write-Output ""
            Write-Output "== $GuestKey (skipped — earlier failure) =="
            continue
        }
        $VMName = $VMNames[$GuestKey]
        $script:ActiveVMName = $VMName
        Write-Output ""
        Write-Output "== $GuestKey (VM: $VMName) =="
        # Switch the dispatch mechanism for this guest's VM lifecycle when
        # its test-set declares a per-guest keystrokeMechanism; else the cycle
        # baseline. Set once here -- before Start-GuestOS resolves any sequence -- so
        # both Start-GuestOS and Start-GuestWorkload see it, and reset to the baseline
        # for guests without an override so guest N's mode never leaks to guest N+1.
        # Pool cycles only; the single-host path never touches the mechanism.
        if ($script:PoolCycle -and (Get-Command Set-EngineKeystrokeMechanism -ErrorAction SilentlyContinue)) {
            $_gm  = Get-CyclePlanSequencesForGuest -Plan $script:CyclePlan -GuestKey $GuestKey
            $_ksm = if ($_gm.keystrokeMechanism) { $_gm.keystrokeMechanism } else { $script:PoolBaselineKsm }
            Set-EngineKeystrokeMechanism -Value $_ksm
            Write-Output "  keystrokeMechanism ($GuestKey): $_ksm"
        }

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
            $cycleBaseName = if (Get-Command Get-CycleFolderIdentity -ErrorAction SilentlyContinue) {
                Get-CycleFolderIdentity -Path $global:__YurunaCycleFolder
            } else {
                Split-Path -Leaf $global:__YurunaCycleFolder
            }
            Set-GuestFailureArtifact -GuestKey $GuestKey -RelativeUrl "log/$cycleBaseName/$VMName/"
        }

        # --- Cleanup stale per-VM failure artifacts from prior cycles ---
        # failure_screenshot_<VM>.png and failure_ocr_<VM>.txt still live
        # at the YURUNA_LOG_DIR root (shared across cycles, keyed only by
        # VM name) so without this drop, a later cycle that fails before
        # any sequence runs (e.g. New-VM aborts on a host-side precondition
        # like missing openssl) would have Copy-FailureArtifactsToStatusLog
        # copy the previous cycle's screenshot forward, misleading the
        # operator. Done unconditionally at the top of each guest iteration
        # so any artifact that lands in the per-cycle folder belongs to
        # this cycle. The screens_<VM>/ ring buffer lives INSIDE the cycle
        # folder (Get-CycleScreenDir) so it can't leak forward — no cleanup
        # needed for it here.
        $staleScreen = Join-Path $env:YURUNA_LOG_DIR "failure_screenshot_${VMName}.png"
        $staleOcr    = Join-Path $env:YURUNA_LOG_DIR "failure_ocr_${VMName}.txt"
        Remove-Item -LiteralPath $staleScreen -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $staleOcr    -Force -ErrorAction SilentlyContinue

        # --- Cleanup previous VM ---
        Remove-GuestVMQuietly -VMName $VMName -SkipStop

        # --- New-VM ---
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
        $effectiveUser = ''
        if ($script:CyclePlan -and $script:CyclePlan.Count -gt 0) {
            $mergedPlan = Get-CyclePlanSequencesForGuest -Plan $script:CyclePlan -GuestKey $GuestKey
            if ($mergedPlan -and $mergedPlan.effectiveUsername) {
                $effectiveUser = [string]$mergedPlan.effectiveUsername
            }
        }
        if ($effectiveUser) {
            Write-Verbose "Cascaded username for $GuestKey -> $effectiveUser (overrides per-host New-VM.ps1 default)"
            $r = New-VM -GuestKey $GuestKey -RepoRoot $RepoRoot -VMName $VMName -Username $effectiveUser -CachingProxyUrl $newVmProxy -Confirm:$false
        } else {
            $r = New-VM -GuestKey $GuestKey -RepoRoot $RepoRoot -VMName $VMName -CachingProxyUrl $newVmProxy -Confirm:$false
        }
        $null = Sync-RunnerCycleConfig -State $cfg -ConfigPath $ConfigPath
        $Config = $cfg.Config; $StopOnFailure = $cfg.StopOnFailure; $VmStartTimeout = $cfg.VmStartTimeout; $VmBootDelay = $cfg.VmBootDelay; $GetImageRefreshHours = $cfg.GetImageRefreshHours; $CycleDelay = $cfg.CycleDelay
        $null = Resolve-RunnerLogLevel -State $cfg
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
            $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "New-VM"; $FailureMessage = $r.errorMessage
            & $writeInfraFailure -Stage 'New-VM' -FailureClass 'provisioning_failure' -GuestKey $GuestKey -VMName $VMName -ErrorMessage $r.errorMessage
            # Copy artifacts BEFORE the shouldStopOnFailure break so the debug
            # folder exists, the log links it, and the dashboard's "fail"
            # pill points to it on both paths (continue and stop).
            Copy-FailureArtifactsToStatusLog -VMName $VMName -GuestKey $GuestKey -RepoRoot $RepoRoot -ModulesDir $ModulesDir -LogFile $LogFile
            if ($StopOnFailure) { break }
            # Clean up so a partial Hyper-V definition (Hyper-V\New-VM
            # succeeded but a later Set-VM*/Add-VMDvdDrive threw) doesn't
            # hold its 16 GB Startup reservation against the next guest.
            # Mirrors the Start-GuestOS/Start-GuestWorkload failure branches;
            # Stop-VM and Remove-VM are both safe no-ops on an absent VM.
            Write-Output "  Cleaning up VM '$VMName' after failure..."
            Remove-GuestVMQuietly -VMName $VMName
            continue
        }

        # --- Start-VM ---
        Assert-CachingProxyStillReachable -ProxyUrl $cachingProxyUrl -StepName "Start-VM" -GuestKey $GuestKey
        Set-StepStatus -GuestKey $GuestKey -StepName "Start-VM" -Status "running"
        $r = Start-VM -VMName $VMName -Confirm:$false
        $null = Sync-RunnerCycleConfig -State $cfg -ConfigPath $ConfigPath
        $Config = $cfg.Config; $StopOnFailure = $cfg.StopOnFailure; $VmStartTimeout = $cfg.VmStartTimeout; $VmBootDelay = $cfg.VmBootDelay; $GetImageRefreshHours = $cfg.GetImageRefreshHours; $CycleDelay = $cfg.CycleDelay
        $null = Resolve-RunnerLogLevel -State $cfg
        if ($r.success) {
            Set-StepStatus -GuestKey $GuestKey -StepName "Start-VM" -Status "pass"
            # Resolve the guest's host-side IP so the operator can ssh /
            # vmconnect / VNC straight from the cycle log. Polls briefly —
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
            $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "Start-VM"; $FailureMessage = $r.errorMessage
            & $writeInfraFailure -Stage 'Start-VM' -FailureClass 'provisioning_failure' -GuestKey $GuestKey -VMName $VMName -ErrorMessage $r.errorMessage
            Copy-FailureArtifactsToStatusLog -VMName $VMName -GuestKey $GuestKey -RepoRoot $RepoRoot -ModulesDir $ModulesDir -LogFile $LogFile
            if ($StopOnFailure) { break }
            # Start-VM failed but New-VM passed, so the VM is defined (Off
            # state) and still holds its 16 GB Startup reservation. Tear it
            # down so the next guest in this cycle doesn't hit
            # 0x800705AA (insufficient system resources). Mirrors the
            # Start-GuestOS/Start-GuestWorkload failure branches.
            Write-Output "  Cleaning up VM '$VMName' after failure..."
            Remove-GuestVMQuietly -VMName $VMName
            continue
        }

        # --- Start-GuestOS (start.guest.* sequences from the cycle plan) ---
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
        $null = Sync-RunnerCycleConfig -State $cfg -ConfigPath $ConfigPath
        $Config = $cfg.Config; $StopOnFailure = $cfg.StopOnFailure; $VmStartTimeout = $cfg.VmStartTimeout; $VmBootDelay = $cfg.VmBootDelay; $GetImageRefreshHours = $cfg.GetImageRefreshHours; $CycleDelay = $cfg.CycleDelay
        $null = Resolve-RunnerLogLevel -State $cfg
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
            $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "Start-GuestOS"; $FailureMessage = $r.errorMessage
            Copy-FailureArtifactsToStatusLog -VMName $VMName -GuestKey $GuestKey -RepoRoot $RepoRoot -ModulesDir $ModulesDir -LogFile $LogFile
            if ($StopOnFailure) {
                Write-Output "  VM '$VMName' left running for investigation."
                break
            }
            Write-Output "  Cleaning up VM '$VMName' after failure..."
            Remove-GuestVMQuietly -VMName $VMName
            continue
        }

        # --- New-VM.Resource (poll until running, wait boot delay) ---
        Assert-CachingProxyStillReachable -ProxyUrl $cachingProxyUrl -StepName "New-VM.Resource" -GuestKey $GuestKey
        Set-StepStatus -GuestKey $GuestKey -StepName "New-VM.Resource" -Status "running"
        $ok = Wait-VMRunning -VMName $VMName `
            -TimeoutSeconds $VmStartTimeout -BootDelaySeconds $VmBootDelay
        $null = Sync-RunnerCycleConfig -State $cfg -ConfigPath $ConfigPath
        $Config = $cfg.Config; $StopOnFailure = $cfg.StopOnFailure; $VmStartTimeout = $cfg.VmStartTimeout; $VmBootDelay = $cfg.VmBootDelay; $GetImageRefreshHours = $cfg.GetImageRefreshHours; $CycleDelay = $cfg.CycleDelay
        $null = Resolve-RunnerLogLevel -State $cfg
        if (-not $ok) {
            $err = "VM '$VMName' did not reach running state after start."
            Write-Warning "  ERROR [$GuestKey / New-VM.Resource]: $err"
            Write-Output "  Log directory: $env:YURUNA_LOG_DIR"
            Set-StepStatus  -GuestKey $GuestKey -StepName "New-VM.Resource" -Status "fail" -ErrorMessage $err
            Set-GuestStatus -GuestKey $GuestKey -Status "fail"
            $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "New-VM.Resource"; $FailureMessage = $err
            & $writeInfraFailure -Stage 'New-VM.Resource' -FailureClass 'provisioning_failure' -GuestKey $GuestKey -VMName $VMName -ErrorMessage $err
            Copy-FailureArtifactsToStatusLog -VMName $VMName -GuestKey $GuestKey -RepoRoot $RepoRoot -ModulesDir $ModulesDir -LogFile $LogFile
            if ($StopOnFailure) {
                Write-Output "  VM '$VMName' left running for investigation."
                break
            }
            Write-Output "  Cleaning up VM '$VMName' after failure..."
            Remove-GuestVMQuietly -VMName $VMName
            continue
        }
        Write-Output "  $GuestKey New-VM.Resource: PASS"
        Set-StepStatus -GuestKey $GuestKey -StepName "New-VM.Resource" -Status "pass"

        # --- Screenshots (compare against trained references) ---
        if ($hasScreenshots) {
            Assert-CachingProxyStillReachable -ProxyUrl $cachingProxyUrl -StepName "Screenshots" -GuestKey $GuestKey
            Set-StepStatus -GuestKey $GuestKey -StepName "Screenshots" -Status "running"
            $r = Invoke-ScreenshotTest -GuestKey $GuestKey `
                -VMName $VMName -ScreenshotsDir $ScreenshotsDir
            $null = Sync-RunnerCycleConfig -State $cfg -ConfigPath $ConfigPath
            $Config = $cfg.Config; $StopOnFailure = $cfg.StopOnFailure; $VmStartTimeout = $cfg.VmStartTimeout; $VmBootDelay = $cfg.VmBootDelay; $GetImageRefreshHours = $cfg.GetImageRefreshHours; $CycleDelay = $cfg.CycleDelay
            $null = Resolve-RunnerLogLevel -State $cfg
            if ($r.skipped) {
                Set-StepStatus -GuestKey $GuestKey -StepName "Screenshots" -Status "skipped" -Skipped $true
            } elseif ($r.success) {
                Set-StepStatus -GuestKey $GuestKey -StepName "Screenshots" -Status "pass"
            } else {
                Write-Warning "  ERROR [$GuestKey / Screenshots]: $($r.errorMessage)"
                Write-Output "  Log directory: $env:YURUNA_LOG_DIR"
                Set-StepStatus  -GuestKey $GuestKey -StepName "Screenshots" -Status "fail" -ErrorMessage $r.errorMessage
                Set-GuestStatus -GuestKey $GuestKey -Status "fail"
                $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "Screenshots"; $FailureMessage = $r.errorMessage
                Copy-FailureArtifactsToStatusLog -VMName $VMName -GuestKey $GuestKey -RepoRoot $RepoRoot -ModulesDir $ModulesDir -LogFile $LogFile
                if ($StopOnFailure) {
                    Write-Output "  VM '$VMName' left running for investigation."
                    break
                }
                Write-Output "  Cleaning up VM '$VMName' after failure..."
                Remove-GuestVMQuietly -VMName $VMName
                continue
            }
        }

        # --- Start-GuestWorkload (workload sequences from the cycle plan) ---
        if ($hasExtensions) {
            Assert-CachingProxyStillReachable -ProxyUrl $cachingProxyUrl -StepName "Start-GuestWorkload" -GuestKey $GuestKey
            Set-StepStatus -GuestKey $GuestKey -StepName "Start-GuestWorkload" -Status "running"
            $r = Start-GuestWorkload -HostType $HostType -GuestKey $GuestKey -VMName $VMName -RepoRoot $RepoRoot -SequencesDir $SequencesDir -SequenceNames $workSeqs -EffectiveVariables $cascadeVarsMap
            $null = Sync-RunnerCycleConfig -State $cfg -ConfigPath $ConfigPath
            $Config = $cfg.Config; $StopOnFailure = $cfg.StopOnFailure; $VmStartTimeout = $cfg.VmStartTimeout; $VmBootDelay = $cfg.VmBootDelay; $GetImageRefreshHours = $cfg.GetImageRefreshHours; $CycleDelay = $cfg.CycleDelay
            $null = Resolve-RunnerLogLevel -State $cfg
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
                $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "Start-GuestWorkload"; $FailureMessage = $r.errorMessage
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
                    break
                }
                Write-Output "  Cleaning up VM '$VMName' after failure..."
                Remove-GuestVMQuietly -VMName $VMName
                continue
            }
        }

        # --- Stop and remove this guest VM before starting the next ---
        Set-GuestStatus -GuestKey $GuestKey -Status "pass"
        Write-Output "  ${GuestKey}: PASS"
        # Guest passed → discard the per-VM ring-buffer of pre-OCR screen
        # captures. On any prior failure path this directory is preserved
        # (Copy-FailureArtifactsToStatusLog copies it before we get here).
        # Lives inside the cycle folder; deletion here is success-cleanup
        # only — a stuck cycle that never reaches this line leaves the
        # buffer in place for post-mortem.
        $screensDir = Get-CycleScreenDir -VMName $VMName -WhatIf:$false
        if (Test-Path $screensDir) {
            Remove-Item -Path $screensDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Verbose "  Stopping VM '$VMName'..."
        $savedProgress = $global:ProgressPreference
        $global:ProgressPreference = 'SilentlyContinue'
        Stop-VM -VMName $VMName -Confirm:$false | Out-Null
        Write-Verbose "  Removing VM '$VMName'..."
        Remove-VM -VMName $VMName -Confirm:$false | Out-Null
        $global:ProgressPreference = $savedProgress
        Write-Output "  Cleanup complete for $GuestKey."
        $script:ActiveVMName = $null
    }

    # === Finalise cycle ===
    $FinalStatus = $OverallPassed ? "pass" : "fail"

    # Vault is persisted across cycles to simulate an external auth
    # provider -- no cycle-end wipe. Get-Password's lazy-create branch
    # populates a user on first reference and every later call (this
    # cycle or any future cycle) returns the same stored value.

    Complete-Run -OverallStatus $FinalStatus -MaxHistoryRuns ([int]$Config.testCycle.recentDisplayCount)
    $cycleEndReason = if ($OverallPassed) { '' } elseif ($FailedGuest -and $FailedStep) { "$FailedGuest / $FailedStep" } else { '' }
    Stop-LogFile -Outcome $FinalStatus -Reason $cycleEndReason
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
        $null = Sync-RunnerCycleConfig -State $cfg -ConfigPath $ConfigPath
        $Config = $cfg.Config; $StopOnFailure = $cfg.StopOnFailure; $VmStartTimeout = $cfg.VmStartTimeout; $VmBootDelay = $cfg.VmBootDelay; $GetImageRefreshHours = $cfg.GetImageRefreshHours; $CycleDelay = $cfg.CycleDelay
        $null = Resolve-RunnerLogLevel -State $cfg
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
    # --- Cycle-restart abort (expected) -----------------------------------
    # Invoke-Sequence's per-step gate throws "YurunaCycleRestart: ..." when
    # /control/start-cycle requests an abort mid-cycle. This is the
    # operator clicking "Save and start cycle" while a cycle is actively
    # executing steps: Remove-TestVMFiles has already torn down the VMs,
    # the flag has been touched, and the cycle needs to unwind cleanly.
    # Detected by message prefix (cross-module typed exceptions would
    # need a shared assembly; the prefix is unique enough). Treated as a
    # NORMAL cycle ending, not an UNHANDLED ERROR:
    #   - No ConsecutiveCrashes increment — this is not a code crash.
    #   - No 60-line origin + stack dump banner — the flag was visible to
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
    # --- Unhandled exception in cycle — emergency cleanup ---
    $ConsecutiveCrashes++
    Write-Output ""
    Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Output "  UNHANDLED ERROR in cycle $CycleCount"
    Write-Output "  $_"
    # Print the error origin. Otherwise the operator sees only the message
    # (e.g. "Cannot convert value ' Install ' to 'System.Int32'") and has
    # to grep ten modules to guess the source. PositionMessage gives
    # file:line of the throwing statement; ScriptStackTrace gives the
    # call chain — together they pin the source on a single re-run.
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
        Write-Output "  $ConsecutiveCrashes consecutive unhandled errors — aborting."
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

    # Cycle work is done -- everything from here is teardown the operator
    # should be able to watch from the same window. The explicit boundary
    # marker lets the operator (and any downstream log scraper) tell
    # cycle-work output from teardown output, and pins the moment we
    # transition into the cleanup + delay phase.
    Write-Output ""
    Write-Output "============================================="
    Write-Output "  CYCLE $CycleCount complete -- entering teardown"
    Write-Output "============================================="

    # Per-cycle cleanup MUST NOT poison the cycle's exit code. Remove-
    # TestVMFiles.ps1 sets $ErrorActionPreference='Stop' inside its own
    # script scope, and the Hyper-V cmdlets it (and its orphan-cleanup
    # callee Remove-OrphanedVMFiles.ps1) invoke can emit non-terminating
    # errors that become terminating under EAP=Stop. Without this catch,
    # such an error escapes past `break` below and aborts the inner
    # before `exit ($OverallPassed ? 0 : 1)` -- the script terminates
    # with code 1 even though status.json finalized the cycle as 'pass',
    # and the outer's failure-pause loop then waits 60 min for "new
    # commits" before respawning. Cleanup is best-effort: log + continue
    # so the cycle's actual pass/fail drives the exit code.
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

    # Cycle-pause back-channel: status server's /control/cycle-pause
    # endpoint creates $env:YURUNA_RUNTIME_DIR/control.cycle-pause. Gate
    # here — AFTER cleanup, BEFORE the inter-cycle wait — so the UI's
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
    # host — Windows hosts in particular were going dark between cycles
    # when the delay lived in the outer, since the outer's Write-Output
    # could be swallowed by conhost while the inner pwsh was gone.
    #
    # The countdown is sliced into 1-second waits so Ctrl+C / shutdown /
    # cycle-pause flag can break out without sitting through a long
    # Start-Sleep. Write-Progress shows a percentage bar; Write-Output
    # emits a coarser tick (every ~5 s) so a non-progress-rendering log
    # collector still records forward motion.
    # $CycleDelay is set inside the cycle's try block (line ~1077) once
    # config is merged; an early throw before that line would leave it
    # null. Fall back to the script param so the inter-cycle wait is
    # still respected on the rare crash-before-config path.
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
}
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

Export-ModuleMember -Function `
    Write-InnerLog, Convert-LocalRepoUrlToPath, `
    Write-UncommittedChangesWarning, Assert-CachingProxyStillReachable, `
    Get-RunnerReloadableConfig, New-RunnerConfigState, Sync-RunnerCycleConfig, `
    Resolve-RunnerLogLevel, Copy-FailureArtifactsToStatusLog, Invoke-RunnerInnerCycle
