<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456707
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.com
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
    Resilient outer runner. Eternal loop:
      1. git pull the framework repo (this clone)
      2. spawn modules/Invoke-TestInnerRunner.ps1 in a fresh pwsh per cycle
         (so module/Add-Type caches are reset on every cycle, uniformly
          on Windows AND macOS)
      3. on inner success -- immediately loop (next iteration pulls + respawns)
      4. on inner failure -- pause up to FailurePauseMaxSeconds (cap)
         OR until a new framework commit lands, whichever first, polled
         every FailureCommitPollSeconds. Persistent failures don't burn
         the host in a tight retry loop; new commits resume work as soon
         as fresh code lands.
    Stops only on Ctrl+C. Per the resilience contract, anything else --
    a flaky network, a hung sequence, an unhandled exception inside the
    inner -- is just another failure that the outer absorbs and retries.

.DESCRIPTION
    Splits the previous monolithic Invoke-TestRunner.ps1 into a thin
    outer (this file) and a single-cycle inner
    (modules/Invoke-TestInnerRunner.ps1 -- intentionally placed under
    modules/ so it's not mistaken for an entry-point script in the test/
    folder; the operator never invokes it directly).
    Benefits over the prior in-process loop:
      * fresh pwsh per cycle on every host -- one code path, no platform-
        specific in-process / spawn fork
      * O(1) resident memory; outer is the only resident process and
        spends most of its time in Start-Process -Wait
      * backoff with commit polling stops infinite-failure burn

    See test/README.md for cycle flow, config, notifications, and the
    YURUNA_CACHING_PROXY_IP knob; test/CODE.md for harness architecture.

.PARAMETER ConfigPath           test.config.yml path (forwarded to inner)
.PARAMETER NoGitPull            Skip git pull (forwarded; outer also skips its own pull)
.PARAMETER NoServer             Skip the built-in HTTP status server (forwarded)
.PARAMETER CycleDelaySeconds    Pause between cycles inside the inner (forwarded; default 30)
.PARAMETER logLevel             Error|Warning|Information|Verbose|Debug (forwarded)
#>

param(
    [string]$ConfigPath        = $null,
    [switch]$NoGitPull,
    [switch]$NoServer,
    [int]$CycleDelaySeconds    = 30,
    [ValidateSet('Error', 'Warning', 'Information', 'Verbose', 'Debug', IgnoreCase = $true)]
    [string]$logLevel
)

# === Tunable backoff constants ==============================================
# Hardcoded at top-of-file by design -- NOT in test.config.yml -- so an
# operator can grep + adjust without a config-schema migration. Tune with
# care: the cap is meant to keep a wedged host from burning git/network
# while still being short enough that a one-off transient (network blip,
# mirror hiccup) recovers within an hour without manual intervention.
$script:FailurePauseMaxSeconds    = 60 * 60   # cap a backoff at 60 min
$script:FailureCommitPollSeconds  = 5 * 60    # check origin every 5 min
$script:OuterPullErrorSleepSec    = 30        # short pause if outer's own git pull errors
$script:InnerSpawnErrorSleepSec   = 30        # short pause if Start-Process itself fails

# --- See https://yuruna.link/memory#why-yuruna-env-vars-are-snapshotted-and-re-asserted-across-inner-spawns
$script:ForwardEnvNames = @(
    'YURUNA_CACHING_PROXY_IP',  # Test-CachingProxy / external-cache branch
    'YURUNA_TRACK_DIR',         # Test.TrackDir override
    'YURUNA_LOG_DIR',           # Test.LogDir override
    'YURUNA_LOG_LEVEL',         # cascade visibility
    'YURUNA_OCR_COMBINE'        # OCR combine mode (And|Or)
)

# === Resolve paths ==========================================================
$TestRoot    = $PSScriptRoot
$RepoRoot    = Split-Path -Parent $TestRoot
$ModulesDir  = Join-Path $TestRoot 'modules'
$InnerScript = Join-Path $ModulesDir 'Invoke-TestInnerRunner.ps1'
if (-not (Test-Path -LiteralPath $InnerScript)) {
    Write-Error "Invoke-TestInnerRunner.ps1 not found at $InnerScript"
    exit 2
}

# Auto-relaunch under `sg libvirt -c "..."` on host.ubuntu.kvm when this
# shell's running supplementary group set lacks libvirt. Done BEFORE we
# spawn any inner pwsh -- the inner inherits the outer's group set, so
# fixing it here means every cycle's virt-install / virsh call inside
# the inner runner reaches /var/run/libvirt/libvirt-sock cleanly. No-op
# on macOS/Windows and on shells that already have libvirt in the
# effective set. See Invoke-LibvirtGroupReExecIfNeeded for the full
# rationale (sg + initgroups, why $env: would leak, etc.).
Import-Module (Join-Path $ModulesDir 'Test.Host.psm1') -Force
Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters
# Resolve ConfigPath in the outer too (the inner has its own default), so
# the failure-pause break-out triggers can read repositories.projectUrl
# and watch the file's mtime without each call site re-deriving the path.
if (-not $ConfigPath) { $ConfigPath = Join-Path $TestRoot 'test.config.yml' }

# === Bootstrap track dir + log dir ==========================================
# Initialize-YurunaTrackDir / Initialize-YurunaLogDir publish the canonical
# locations as $env:YURUNA_TRACK_DIR / $env:YURUNA_LOG_DIR. The inner pwsh
# inherits these via Start-Process WITHOUT -UseNewEnvironment so the inner
# and the status server agree on the on-disk track + log paths every cycle.
Import-Module (Join-Path $ModulesDir 'Test.TrackDir.psm1') -Force
Import-Module (Join-Path $ModulesDir 'Test.LogDir.psm1')   -Force
$null = Initialize-YurunaTrackDir
$null = Initialize-YurunaLogDir

# Snapshot AFTER Initialize-YurunaTrackDir / Initialize-YurunaLogDir so the
# resolved (or operator-supplied) defaults for YURUNA_TRACK_DIR / YURUNA_-
# LOG_DIR are captured rather than the pre-resolution null. Only names
# present in $env: at this moment are stored — absent names are not
# forwarded (we don't want to set them to '' downstream).
$script:ForwardEnvSnapshot = @{}
foreach ($n in $script:ForwardEnvNames) {
    $v = [Environment]::GetEnvironmentVariable($n)
    if ($null -ne $v -and $v -ne '') {
        $script:ForwardEnvSnapshot[$n] = $v
    }
}

function Sync-ForwardEnv {
    [CmdletBinding()]
    param()
    foreach ($n in $script:ForwardEnvSnapshot.Keys) {
        $current = [Environment]::GetEnvironmentVariable($n)
        if ($current -ne $script:ForwardEnvSnapshot[$n]) {
            Set-Item -Path "Env:$n" -Value $script:ForwardEnvSnapshot[$n]
        }
    }
}

# === Outer milestone log ====================================================
# Persist the cycle-boundary lines (exit code, failure-pause entry/exit) to
# track/outer.log so they survive a console-output wedge. Observed on
# Windows: conhost can swallow every Write-Output for the entire failure-
# pause window, hiding the exit code that drove outer into the pause. The
# file path is resolvable post-hoc (different terminal, status server) so
# the diagnostic survives even when the foreground console is stuck.
function Write-OuterLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    try {
        Add-Content -LiteralPath (Join-Path $env:YURUNA_TRACK_DIR 'outer.log') `
            -Value "$stamp $Message" -Encoding utf8 -ErrorAction Stop
    } catch {
        Write-Verbose "outer.log write failed (non-fatal): $($_.Exception.Message)"
    }
}

# === Single-instance guard ==================================================
# Outer owns the runner.pid file across the whole resilient lifetime. Inner
# detects YURUNA_RUNNER_RELAUNCH=1 and skips its own guard / pidfile write.
# Same takedown logic the prior monolithic runner used: kill the previous
# Invoke-TestRunner.ps1 (verified by command-line) and wipe stranded test
# VMs before we start. Two outers racing on the same host produces the
# stuck-Starting/Stopping VM symptom the original guard was written to
# avoid.
$RunnerPidFile   = Join-Path $env:YURUNA_TRACK_DIR 'runner.pid'
# StartTime sidecar: the script name is not always in the outer's argv
# (interactive `pwsh` REPL → `./Invoke-TestRunner.ps1`, the documented
# macOS/Linux launch, leaves argv as bare `pwsh`), so the cmdline regex
# below false-negatives and Start-StatusServer's /control/runner-status
# reports the live runner as stopped. Recording the process StartTime at
# launch lets every consumer cross-check the recorded value against
# Get-Process -Id <pid>'s live StartTime: a PID reuse has a different
# StartTime, so the check is forgery-resistant without depending on
# argv visibility.
$RunnerStartFile = Join-Path $env:YURUNA_TRACK_DIR 'runner.start'
if (Test-Path -LiteralPath $RunnerPidFile) {
    $existingPid = 0
    try { $existingPid = [int]((Get-Content $RunnerPidFile -Raw -ErrorAction Stop).Trim()) } catch { $existingPid = 0 }
    if ($existingPid -gt 0 -and $existingPid -ne $PID -and (Get-Process -Id $existingPid -ErrorAction SilentlyContinue)) {
        # Identity precedence: StartTime sidecar first (works regardless
        # of how the outer was launched), cmdline regex fallback (older
        # runners without the sidecar still get matched on Windows + on
        # Linux/macOS launches that go through `pwsh -File`).
        $identityMatch = $false
        if (Test-Path -LiteralPath $RunnerStartFile) {
            try {
                $recorded   = (Get-Content -LiteralPath $RunnerStartFile -Raw -ErrorAction Stop).Trim()
                $recordedDt = [DateTimeOffset]::Parse($recorded).UtcDateTime
                $liveDt     = (Get-Process -Id $existingPid -ErrorAction Stop).StartTime.ToUniversalTime()
                # 2s tolerance: ToString('o') is sub-microsecond on .NET
                # but DateTimeOffset.Parse + StartTime can lose precision
                # across the round-trip on some kernels. 2s is wide enough
                # to absorb that without admitting a different process.
                if ([Math]::Abs(($recordedDt - $liveDt).TotalSeconds) -le 2) { $identityMatch = $true }
            } catch { Write-Verbose "runner.start cross-check failed: $($_.Exception.Message)" }
        }
        $cmd = $null
        if (-not $identityMatch) {
            if ($IsWindows) {
                $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$existingPid" -ErrorAction SilentlyContinue).CommandLine
            } elseif ($IsMacOS -or $IsLinux) {
                # `-ww` forces unlimited column width. Without it, BSD/macOS
                # ps truncates `args` to the controlling terminal's columns
                # (or 80 if there's no TTY), hiding the trailing
                # `Invoke-TestRunner.ps1` token and breaking the regex match
                # below.
                $cmd = & '/bin/ps' -ww -p $existingPid -o args= 2>$null
            }
        }
        if ($identityMatch -or ($cmd -and $cmd -match 'Invoke-Test(?:Inner)?Runner\.ps1')) {
            Write-Output ""
            Write-Output "============================================="
            Write-Output "  Another Invoke-TestRunner is running"
            Write-Output "  PID:    $existingPid"
            Write-Output "  Action: stopping it + Remove-TestVMFiles.ps1"
            Write-Output "============================================="
            Stop-Process -Id $existingPid -Force -ErrorAction SilentlyContinue
            for ($i = 0; $i -lt 20; $i++) {
                if (-not (Get-Process -Id $existingPid -ErrorAction SilentlyContinue)) { break }
                Start-Sleep -Milliseconds 500
            }
            try {
                $cleanup = Join-Path $TestRoot 'Remove-TestVMFiles.ps1'
                if (Test-Path -LiteralPath $cleanup) {
                    & pwsh -NoProfile -File $cleanup -Prefix 'test-'
                }
            } catch {
                Write-Warning "Remove-TestVMFiles.ps1 failed during single-instance takeover: $_"
            }
        } else {
            Write-Warning "Stale runner.pid: PID $existingPid is not an Invoke-TestRunner process. Ignoring."
        }
    }
    Remove-Item -LiteralPath $RunnerPidFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $RunnerStartFile -Force -ErrorAction SilentlyContinue
}
$PID | Set-Content -Path $RunnerPidFile -Encoding ascii
# Sidecar consumed by Start-StatusServer's /control/runner-status endpoint
# (and by the single-instance guard above on the next launch). Written
# AFTER runner.pid so a reader that races us sees both or neither.
try {
    $startIso = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    $startIso | Set-Content -Path $RunnerStartFile -Encoding ascii
} catch {
    Write-Verbose "Could not record runner.start (non-fatal): $($_.Exception.Message)"
}

# === Ctrl+C handler =========================================================
# Same shape as the previous in-process runner: subscribe via Register-Object-
# Event so the handler runs on the pipeline thread (a raw .NET event delegate
# would fire on a thread-pool thread with no Runspace, throwing on shutdown).
# Setting $script:ShutdownState['Requested']=$true lets the eternal loop and
# the failure-pause loop both observe the request at their next iteration.
$script:ShutdownState = @{ Requested = $false }
try {
    Unregister-Event -SourceIdentifier YurunaCancelKey -ErrorAction SilentlyContinue
    Remove-Job -Name YurunaCancelKey -Force -ErrorAction SilentlyContinue
    $null = Register-ObjectEvent -InputObject ([Console]) -EventName CancelKeyPress `
        -SourceIdentifier YurunaCancelKey -MessageData $script:ShutdownState -Action {
            $Event.SourceEventArgs.Cancel = $true
            $Event.MessageData['Requested'] = $true
            Write-Warning "Shutdown requested (Ctrl+C). Will exit after the current cycle..."
        }
} catch {
    Write-Verbose "Could not register CancelKeyPress handler (non-interactive session): $_"
}

# === Build inner argument list ==============================================
# -Command (not -File): pwsh's -File parameter binder coerces every argv
# token to [string], which breaks [bool]/[int] inner parameters. -Command
# parses the line as PowerShell so $true/$false/0/1 keep their types.
$pwshExe = (Get-Process -Id $PID).Path
$escapedScript = $InnerScript -replace "'", "''"
$cmdParts = @("& '$escapedScript'")
foreach ($k in $PSBoundParameters.Keys) {
    $v = $PSBoundParameters[$k]
    if ($v -is [System.Management.Automation.SwitchParameter]) {
        if ($v.IsPresent) { $cmdParts += "-$k" }
    } elseif ($v -is [bool]) {
        $cmdParts += "-$k"
        $cmdParts += $(if ($v) { '$true' } else { '$false' })
    } elseif ($v -is [int] -or $v -is [long] -or $v -is [double]) {
        $cmdParts += "-$k"
        $cmdParts += "$v"
    } else {
        $escaped = ("$v") -replace "'", "''"
        $cmdParts += "-$k"
        $cmdParts += "'$escaped'"
    }
}
# -NoProfile blocks operator $PROFILE from re-setting YURUNA_* env vars
# (notably YURUNA_CACHING_PROXY_IP) in the child AFTER the outer's
# snapshot+Sync-ForwardEnv injected the right values. See the comment
# block at the top of this file for the failure mode.
$argList = @('-NoLogo', '-NoProfile', '-Command', ($cmdParts -join ' '))

# === Helpers ================================================================
function Get-OuterCommitSha {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $sha = & git -C $RepoRoot rev-parse HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ([string]$sha).Trim()
}

function Test-OuterNewCommitsAvailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$BaselineSha)
    & git -C $RepoRoot fetch --quiet origin 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    $upstream = & git -C $RepoRoot rev-parse '@{u}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $upstream) { return $false }
    return (([string]$upstream).Trim() -ne $BaselineSha)
}

function Invoke-OuterGitPull {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    & git -C $RepoRoot pull --ff-only --quiet 2>&1 | Write-Output
    return ($LASTEXITCODE -eq 0)
}

# ---- Failure-pause break-out triggers ----------------------------------
# The outer's failure-pause used to wait up to 60 min for ONE signal: a
# new commit on the framework remote. Now it watches THREE signals --
# new framework commit, new project commit, AND a local edit of
# test.config.yml -- and breaks out on whichever fires first. Network
# / IO failure on any individual probe is treated as "no change for now"
# (return $null / unchanged baseline) so a flaky network can't cut a
# pause short and a missing config file can't crash the loop.

# Query a remote repo's current HEAD SHA without needing a local clone.
# Used for the repositories.projectUrl probe (the project is wiped + re-cloned at
# cycle start, so a local clone may not exist mid-pause). Returns $null
# on any failure.
function Get-OuterRemoteSha {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RemoteUrl)
    if ([string]::IsNullOrWhiteSpace($RemoteUrl)) { return $null }
    $line = & git ls-remote $RemoteUrl HEAD 2>$null | Select-Object -First 1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($line)) { return $null }
    # `git ls-remote` line format: "<sha>\tHEAD".
    return ([string]$line).Split("`t")[0].Trim()
}

# Snapshot the on-disk mtime of test.config.yml. Returns $null when the
# file is missing -- pairs with the comparison logic below: a $null/non-
# null transition (file deleted or created mid-pause) is itself a change
# worth breaking on, so the operator can edit/create the config and
# expect a near-immediate cycle restart.
function Get-OuterConfigMtime {
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

# Read repositories.projectUrl from test.config.yml so we know which
# remote to probe. We deliberately read this ONCE at pause start (rather
# than every poll); any in-flight edit of it will trip the config-mtime
# trigger below, which breaks the pause and the next cycle re-reads the
# (now-current) URL. Returns $null when the file is missing or the key
# is empty.
function Get-OuterProjectUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$ConfigPath)
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $null }
    try {
        $cfg = Get-Content -Raw -LiteralPath $ConfigPath -ErrorAction Stop |
            ConvertFrom-Yaml -Ordered -ErrorAction Stop
        if ($cfg -and $cfg.repositories -and $cfg.repositories.projectUrl) { return [string]$cfg.repositories.projectUrl }
    } catch {
        Write-Verbose "Get-OuterProjectUrl: $($_.Exception.Message)"
    }
    return $null
}

# === Banner =================================================================
# First line written to track/outer.log on every outer startup. If this line
# is missing from outer.log after the runner has clearly been running (e.g.
# the inner emitted output to the console), Write-OuterLog itself is broken
# (env var, permissions, encoding) — investigate before trusting outer.log
# absence as evidence that Start-Process -Wait hung.
Write-OuterLog "===== outer runner started (PID $PID) ====="
Write-Output ""
Write-Output "============================================="
Write-Output "  Yuruna outer runner"
Write-Output "  Inner:        $InnerScript"
Write-Output "  Backoff cap:  $($script:FailurePauseMaxSeconds / 60) min"
Write-Output "  Commit poll:  $($script:FailureCommitPollSeconds / 60) min"
Write-Output "  Stop:         Ctrl+C"
if ($script:ForwardEnvSnapshot.Count -gt 0) {
    Write-Output "  Forwarded env to inner:"
    foreach ($n in ($script:ForwardEnvSnapshot.Keys | Sort-Object)) {
        Write-Output "    $n = $($script:ForwardEnvSnapshot[$n])"
    }
} else {
    $namesList = $script:ForwardEnvNames -join ', '
    Write-Output "  Forwarded env: (none of $namesList set in launch shell)"
}
Write-Output "============================================="

# Pre-flight: the cycle planner (Test.SequencePlanner.Resolve-CyclePlan)
# parses project/test/test.sequence.yml via powershell-yaml. When the
# module is missing, the inner runner's try/catch swallows the throw
# into a Write-Warning (whose stream the per-cycle log does not capture)
# and falls back to the legacy guestSequence list. That fallback leaves
# Start-GuestOS without any sequence names -- the step is recorded as
# "skipped" in status.json with no line in the cycle log. Surface the
# condition once at outer startup so the operator notices before
# cycles silently degrade. Install with `Install-Module powershell-yaml
# -Scope CurrentUser` or re-run host/<host>/Enable-TestAutomation.ps1.
if (-not (Get-Module -ListAvailable -Name powershell-yaml -ErrorAction SilentlyContinue)) {
    Write-Warning "powershell-yaml is not installed. The cycle planner will fall back to the legacy guestSequence and Start-GuestOS will be SKIPPED for every guest. Fix with: Install-Module powershell-yaml -Scope CurrentUser  (or re-run host/<host>/Enable-TestAutomation.ps1)"
}

# === Eternal loop ===========================================================
$cycle = 0
while (-not $script:ShutdownState['Requested']) {
    $cycle++

    # 1. Outer git pull (framework repo). Skip on -NoGitPull, mirroring
    #    the prior runner's flag. A failure here is treated as transient:
    #    short sleep + retry, so the loop doesn't burn CPU thrashing on a
    #    transient git error.
    if (-not $NoGitPull) {
        Write-Output ""
        Write-Output "[outer cycle $cycle] git pull (framework)"
        if (-not (Invoke-OuterGitPull)) {
            Write-Warning "[outer cycle $cycle] git pull failed -- sleeping ${script:OuterPullErrorSleepSec}s before retry."
            Start-Sleep -Seconds $script:OuterPullErrorSleepSec
            continue
        }
    }

    # 2. Spawn the inner. YURUNA_RUNNER_RELAUNCH=1 tells the inner that
    #    we (the outer) own the pidfile + Ctrl+C handler; inner skips
    #    its own copies of those. Sync-ForwardEnv re-asserts the launch-
    #    time snapshot of YURUNA_* vars (cache IP, track/log dirs, log
    #    level, OCR combine) so the inner sees them even if some module
    #    in this outer process clobbered $env: mid-run.
    Sync-ForwardEnv
    $env:YURUNA_RUNNER_RELAUNCH = '1'
    if ($script:ForwardEnvSnapshot.Count -gt 0) {
        Write-Output "[outer cycle $cycle] forwarding env: $($script:ForwardEnvSnapshot.Keys -join ', ')"
    }
    Write-Output "[outer cycle $cycle] spawning inner pwsh... (local time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))"
    Write-OuterLog "[outer cycle $cycle] about to invoke inner pwsh"
    # --- See https://yuruna.link/memory#why-the-inner-spawn-uses-the-call-operator-instead-of-start-process
    $exitCode = 0
    try {
        & $pwshExe @argList
        $exitCode = $LASTEXITCODE
    } catch {
        Write-Warning "[outer cycle $cycle] failed to invoke inner pwsh: $_"
        Start-Sleep -Seconds $script:InnerSpawnErrorSleepSec
        continue
    }
    # Outer regained control. Emit BOTH to console and to track/outer.log so
    # a conhost wedge (documented above) can't hide the moment Start-Process
    # -Wait returned. If the operator sees the inner's "wait complete --
    # exiting inner" line but never sees this one in the console, check
    # track/outer.log: presence there means outer IS running (output wedged);
    # absence means Start-Process -Wait itself never returned.
    Write-Output "[outer cycle $cycle] outer runner back in control (local time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))"
    Write-OuterLog "[outer cycle $cycle] outer runner back in control"
    Write-Output "[outer cycle $cycle] inner exited with code $exitCode"
    Write-OuterLog "[outer cycle $cycle] inner exited with code $exitCode"

    if ($exitCode -eq 0) {
        # 3a. Success -- next iteration pulls and respawns immediately.
        continue
    }

    # 3b. Failure -- pause until either a new upstream commit lands on
    #     the framework repo OR a new commit lands on repositories.projectUrl OR
    #     the local test.config.yml is edited OR the cap elapses,
    #     polled every FailureCommitPollSeconds. The wait loop sleeps
    #     in 5-second slices so Ctrl+C is responsive (Start-Sleep can't
    #     be interrupted by our event handler in long sweeps).
    #
    # Three baselines are captured up front; any one of them changing
    # ends the pause and starts the next cycle immediately -- the
    # operator's mental model is "fix anything actionable and the loop
    # picks it up within 5 minutes" without having to Ctrl+C / restart.
    $baselineSha         = Get-OuterCommitSha
    $baselineProjectUrl  = Get-OuterProjectUrl -ConfigPath $ConfigPath
    $baselineProjectSha  = if ($baselineProjectUrl) { Get-OuterRemoteSha -RemoteUrl $baselineProjectUrl } else { $null }
    $baselineConfigMtime = Get-OuterConfigMtime -ConfigPath $ConfigPath
    $pauseStart  = Get-Date
    $deadline    = $pauseStart.AddSeconds($script:FailurePauseMaxSeconds)
    $projectWatchMsg = if ($baselineProjectUrl) { "framework + project ($baselineProjectUrl) + local config" } else { "framework + local config (no repositories.projectUrl)" }
    Write-Warning "[outer cycle $cycle] inner failed -- pausing up to $($script:FailurePauseMaxSeconds / 60) min, polling $projectWatchMsg every $($script:FailureCommitPollSeconds / 60) min."
    Write-OuterLog "[outer cycle $cycle] inner failed -- pausing up to $($script:FailurePauseMaxSeconds / 60) min; watching: $projectWatchMsg."
    # Progress bar: tracks elapsed time toward the 60-min cap (or earlier
    # break-out when a fresh upstream commit lands). Updated on every
    # 5-second slice so the bar advances ~1.4%/tick and the operator sees
    # forward motion instead of a silent terminal. -Id is fixed so we
    # only ever own one progress row; -Completed in the finally clears
    # it cleanly when the loop exits via any path (success, cap, Ctrl+C,
    # exception).
    $progressId = 1
    try {
    while ((Get-Date) -lt $deadline -and -not $script:ShutdownState['Requested']) {
        $remainingPoll = $script:FailureCommitPollSeconds
        while ($remainingPoll -gt 0 -and -not $script:ShutdownState['Requested']) {
            $slice = [math]::Min(5, $remainingPoll)
            Start-Sleep -Seconds $slice
            $remainingPoll -= $slice
            $remainingSec = [math]::Max(0, [int]($deadline - (Get-Date)).TotalSeconds)
            $elapsedSec   = [int]((Get-Date) - $pauseStart).TotalSeconds
            $percent      = [math]::Min(100, [math]::Max(0, [int](($elapsedSec * 100) / $script:FailurePauseMaxSeconds)))
            $remainingMin = [math]::Round($remainingSec / 60, 1)
            Write-Progress -Id $progressId `
                -Activity "[outer cycle $cycle] failure-pause toward next cycle" `
                -Status  ("{0} min remain (next commit poll in {1}s)" -f $remainingMin, $remainingPoll) `
                -PercentComplete $percent `
                -SecondsRemaining $remainingSec
        }
        if ($script:ShutdownState['Requested']) { break }
        # Trigger 1: framework repo new commit (existing behavior, kept).
        if (Test-OuterNewCommitsAvailable -BaselineSha $baselineSha) {
            Write-Output "[outer cycle $cycle] new framework upstream commits detected -- ending pause."
            Write-OuterLog "[outer cycle $cycle] new framework upstream commits detected -- ending pause."
            break
        }
        # Trigger 2: project repo new commit. ls-remote returns $null on
        # network failure; require a non-null current AND a non-null
        # baseline so a transient failure on either side doesn't fire
        # spuriously, and don't fire when repositories.projectUrl wasn't set in
        # the first place.
        if ($baselineProjectUrl) {
            $currentProjectSha = Get-OuterRemoteSha -RemoteUrl $baselineProjectUrl
            if ($currentProjectSha -and $baselineProjectSha -and ($currentProjectSha -ne $baselineProjectSha)) {
                Write-Output "[outer cycle $cycle] new project upstream commits detected at $baselineProjectUrl -- ending pause."
                Write-OuterLog "[outer cycle $cycle] new project upstream commits detected at $baselineProjectUrl ($baselineProjectSha -> $currentProjectSha) -- ending pause."
                break
            }
        }
        # Trigger 3: local test.config.yml edit (mtime change OR file
        # appearing/disappearing relative to the baseline). Comparing
        # nullable datetimes with -ne handles all three transitions
        # (changed / created / deleted) in one shot.
        $currentConfigMtime = Get-OuterConfigMtime -ConfigPath $ConfigPath
        if ($currentConfigMtime -ne $baselineConfigMtime) {
            Write-Output "[outer cycle $cycle] local test.config.yml changed ($ConfigPath) -- ending pause."
            Write-OuterLog "[outer cycle $cycle] local test.config.yml changed (${ConfigPath}: $baselineConfigMtime -> $currentConfigMtime) -- ending pause."
            break
        }
        $remainingMin = [math]::Max(0, [math]::Round((($deadline - (Get-Date)).TotalMinutes), 1))
        Write-Output "[outer cycle $cycle] no new commits, no config edit; ${remainingMin} min remain in pause."
    }
    } finally {
        Write-Progress -Id $progressId -Activity 'failure-pause' -Completed
    }
}

# === Graceful shutdown ======================================================
Write-Output ""
Write-Output "Shutdown requested. Releasing pidfile and exiting."
Unregister-Event -SourceIdentifier YurunaCancelKey -ErrorAction SilentlyContinue
Remove-Job -Name YurunaCancelKey -Force -ErrorAction SilentlyContinue
try {
    if (Test-Path -LiteralPath $RunnerPidFile) {
        $filePid = 0
        try { $filePid = [int]((Get-Content $RunnerPidFile -Raw -ErrorAction Stop).Trim()) } catch { $filePid = 0 }
        if ($filePid -eq $PID) {
            Remove-Item -LiteralPath $RunnerPidFile -Force -ErrorAction SilentlyContinue
        }
    }
} catch {
    Write-Verbose "Pidfile cleanup swallowed error: $($_.Exception.Message)"
}
exit 0
