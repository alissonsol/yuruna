<#PSScriptInfo
.VERSION 2026.06.05
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456706
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
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
    Continuous test cycle entry point. See test/README.md for the
    cycle flow, config schema, notifications, and YURUNA_CACHING_PROXY_IP;
    see docs/test-harness.md for harness architecture.

.PARAMETER ConfigPath           test.config.yml path (default: next to this script)
.PARAMETER NoGitPull             Skip `git pull` at cycle start
.PARAMETER NoServer              Skip the built-in HTTP status server
.PARAMETER CycleDelaySeconds     Pause between cycles (default 30)
.PARAMETER logLevel              One of Error|Warning|Information|Verbose|Debug. Each level shows itself + all higher-priority levels (Error highest). Omit to read test.config.yml.logLevel (default "Information").
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = '$global:__YurunaLogFile is the cross-module channel with Yuruna.Log; the proxy reads it to mirror Write-* output to the per-cycle log.')]
param(
    [string]$ConfigPath        = $null,
    [switch]$NoGitPull,
    [switch]$NoServer,
    # Skip the in-cycle Update-ProjectClone (wipe + re-clone of
    # <RepoRoot>/project from repositories.projectUrl). Used by Test-Project.ps1,
    # which performs the wipe + clone itself as discrete steps before
    # spawning the inner -- so the inner re-doing them would be wasted
    # work. The cycle still requires <RepoRoot>/project/.git to exist;
    # if it doesn't, the cycle fails fast with a clear message.
    [switch]$NoProjectClone,
    [int]$CycleDelaySeconds    = 30,
    # Three-state: omitted -> read test.config.yml.logLevel; explicit
    # value -> override JSON for the lifetime of this runner. Cmdline
    # override survives a JSON edit so a `-logLevel Information` started
    # at launch isn't flipped back to "Information" by a hot-reload. Each level
    # in the cascade shows itself + all higher-priority streams (Error is
    # highest), so e.g. logLevel="Warning" enables Error + Warning and
    # silences Information / Verbose / Debug. Validated at parse time.
    [ValidateSet('Error', 'Warning', 'Information', 'Verbose', 'Debug', IgnoreCase = $true)]
    [string]$logLevel
)

# Capture cmdline override for three-state resolution. PSBoundParameters
# is the only reliable source — `[string]` defaults to '' when omitted,
# which would shadow "operator left it blank" vs "operator typed nothing"
# if we just read $logLevel.
$script:CmdLineLogLevel = if ($PSBoundParameters.ContainsKey('logLevel')) { $logLevel } else { $null }

# Canonical cascade implementation: Test.LogLevel.psm1. See docs/loglevels.md
# for the rank semantics and why we propagate the resolved level to child
# pwsh processes via $env:YURUNA_LOG_LEVEL.
Import-Module (Join-Path $PSScriptRoot 'Test.LogLevel.psm1') -Global -Force

# Exponential-backoff helper for filesystem-state poll loops is
# centralised in Test.Backoff.psm1 (Get-PollDelay) so a tuning change
# lands once. Imported with -Global by Test.Prelude's module sets,
# so callers in this file resolve the function via the global scope.

# Wraps Test.LogLevel\Resolve-LogLevel so callers in this file stay terse.
# Called (a) at startup with cmdline-only data, (b) after Update-Test-
# ConfigFromTemplate loads $script:Config, and (c) at the end of every
# Sync-RuntimeConfig so a JSON edit takes effect on the next step's
# child processes via $env:YURUNA_LOG_LEVEL.
function Resolve-LogLevel {
    [CmdletBinding()]
    param()
    $cfg = $script:Config
    $configLevel = if ($cfg -is [System.Collections.IDictionary] -and $cfg.Contains('logLevel')) {
        [string]$cfg.logLevel
    } else { $null }
    $null = Test.LogLevel\Resolve-LogLevel -CmdLineLevel $script:CmdLineLogLevel -ConfigLevel $configLevel
}

# Initial pass: cmdline-only (test.config.yml hasn't been loaded yet).
# Subsequent passes happen right after Update-TestConfigFromTemplate and
# at the end of every Sync-RuntimeConfig.
Resolve-LogLevel

# === Resolve paths ===
# Track/log dirs come from Test.YurunaDir; override with
# $env:YURUNA_RUNTIME_DIR / $env:YURUNA_LOG_DIR. Defaults: test/status/runtime/
# and test/status/log/, both served by the status HTTP server.
# This script lives under test/modules/ (kept out of test/'s entry-point
# layer so operators never run it directly -- the outer runner is the
# only legitimate caller). $PSScriptRoot is therefore test/modules/, and
# $TestRoot has to walk one level up to reach test/.
Import-Module (Join-Path $PSScriptRoot 'Test.Prelude.psm1') -Global -Force
$paths          = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideModulesDir -ConfigPath $ConfigPath
$ModulesDir     = $paths.ModulesDir
$TestRoot       = $paths.TestRoot
$RepoRoot       = $paths.RepoRoot
$StatusDir      = $paths.StatusDir
$StatusTmpl     = Join-Path $StatusDir "status.json.template"
$ScreenshotsDir = Join-Path $TestRoot "screenshots"
$SequencesDir   = $paths.SequencesDir

# Canonical exit codes from Test.Prelude. A future change to the contract
# (e.g. introduce code 2 for "needs operator action") lands in one place.
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure
$ConfigPath     = $paths.ConfigPath
# Publish the resolved config path so Test.Transport's
# Update-TransportDefault reads the SAME file Sync-RuntimeConfig uses.
# Outer also publishes this on its own ForwardEnvNames list; setting it
# here covers the standalone-direct invocation case (operator runs
# Invoke-TestInnerRunner.ps1 by hand).
$env:YURUNA_CONFIG_PATH = $ConfigPath

# Canonical Inner-kind module set: Test.SingleInstance, Test.YurunaDir,
# Test.Extension, Test.HostContract, Test.Status, Test.Notify, Test.Provenance,
# Test.Start-GuestOS, Test.Start-GuestWorkload, Test.Log, Test.Sequence-
# Planner, Test.CachingProxy, Test.Perf, Test.HostIO, Test.Capability,
# Test.Transport. Replaces seven separate inline Import-Module sites that
# used to cover the early-bootstrap (Test.YurunaDir, Test.Extension,
# Test.SingleInstance) and the per-cycle workhorse list ($script:Runner-
# Modules). The mid-cycle refresh loop re-calls this helper so a `git
# pull` between cycles propagates source changes to every covered module
# in lockstep -- without having to maintain a parallel list.
Initialize-YurunaEntryPointModuleSet -For Inner -ModulesDir $ModulesDir
$null = Initialize-YurunaRuntimeDir
$null = Initialize-YurunaLogDir
$StatusFile = Join-Path $env:YURUNA_RUNTIME_DIR "status.json"

# === Timeline log =========================================================
# Mirror of the outer's Write-OuterLog. Lets the inner record where it is
# in its own exit path so a future hang between "cycleDelaySeconds wait
# complete" and the outer's "back in control" line is pinpointable: if
# inner.<exit-step> entries land on outer.log but the outer's "back in
# control" never does, the hang is in Start-Process / WaitForExit; if
# they stop mid-cleanup, the inner itself is wedged on a specific cmdlet.
function Write-InnerLog {
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

# ConfigPath was resolved by Initialize-YurunaEntryPoint above.
$TemplatePath = Join-Path $TestRoot "test.config.yml.template"

# === Single-instance guard ===
# Defensive: if another Invoke-TestRunner.ps1 (the outer) is running,
# stop it and wipe stranded test VMs. The normal call path is the
# outer spawning THIS inner with YURUNA_RUNNER_RELAUNCH=1 -- in which
# case this whole block is skipped (the outer owns the pidfile). This
# branch only fires when an operator invokes modules/Invoke-Test-
# InnerRunner.ps1 directly (which they shouldn't -- it lives under
# modules/ for that reason, but the guard is the safety net for when
# they do).
# Shared implementation in Test.SingleInstance.psm1 -- same identity-
# probe logic as outer, with the inner-specific cmdline pattern below
# (matches only Invoke-TestRunner.ps1, never a sibling inner). Imported
# by the Inner kind at file top.
$RunnerPidFile = Join-Path $env:YURUNA_RUNTIME_DIR "runner.pid"
if ($env:YURUNA_RUNNER_RELAUNCH -ne '1') {
    $priorRunner = Get-RunnerInstanceState -RunnerPidFile $RunnerPidFile -CmdLinePattern 'Invoke-TestRunner\.ps1'
    switch ($priorRunner.status) {
        'OtherRunner' {
            Write-Output ""
            Write-Output "============================================="
            Write-Output "  Another Invoke-TestRunner.ps1 is running"
            Write-Output "  PID:     $($priorRunner.pid)"
            Write-Output "  Action:  stopping it and running"
            Write-Output "           Remove-TestVMFiles.ps1 before start"
            Write-Output "============================================="
            # 'test-' is the template default: test.config.yml hasn't been
            # merged yet, so we can't read a user override. If the user
            # picked a custom prefix this cleanup is a no-op -- same as
            # if the guard didn't run.
            Stop-StaleRunner -ProcessId $priorRunner.pid -TestRoot $TestRoot -CleanupPrefix 'test-' -Confirm:$false
        }
        'Stale' {
            if ($priorRunner.pid -gt 0) {
                Write-Warning "Stale runner.pid: PID $($priorRunner.pid) is not an Invoke-TestRunner.ps1 process. Ignoring."
            }
        }
        default { } # 'None' / 'Self' -- nothing to do
    }
    Remove-Item -LiteralPath $RunnerPidFile -Force -ErrorAction SilentlyContinue
}
# When the outer Invoke-TestRunner.ps1 spawned us (YURUNA_RUNNER_RELAUNCH=1),
# leave the pidfile alone -- the outer owns the lock for the whole run.
# Standalone (direct) invocation owns its own pidfile (no StartTime
# sidecar -- the outer publishes that).
if ($env:YURUNA_RUNNER_RELAUNCH -ne '1') {
    # Atomic CreateNew lock. Two standalone-direct inner invocations
    # racing on the same host both see "None" from Get-RunnerInstanceState
    # above; the atomic write turns the race into a clear winner/loser.
    $pidWritten = Write-RunnerPidFile -RunnerPidFile $RunnerPidFile -Confirm:$false
    if (-not $pidWritten) {
        Write-Error "Lost the pidfile race against a concurrent Invoke-TestInnerRunner. Inspect $RunnerPidFile and retry."
        exit $ExitFailure
    }
}

# === Inner PID + heartbeat ============================================
# inner.pid lets the outer's watchdog target the inner pwsh by PID even
# though the outer spawns it via the call-operator (which doesn't return
# a Process handle). Written unconditionally on every inner start, regard-
# less of whether YURUNA_RUNNER_RELAUNCH is set, so a direct-invoke inner
# also publishes its PID for any external monitor.
$InnerPidFile      = Join-Path $env:YURUNA_RUNTIME_DIR "inner.pid"
$HeartbeatFile     = Join-Path $env:YURUNA_RUNTIME_DIR "runner.heartbeat"
# Companion file to runner.heartbeat. The threadpool-timer-driven
# runner.heartbeat is proof of life at the process level but stays
# fresh even when the runspace is wedged inside a non-terminating
# OCR / SSH loop -- it can't catch in-runspace hangs. runner.step-
# Heartbeat is touched from the runspace itself at the top of every
# step in Invoke-Sequence; the outer watchdog reads its mtime to
# detect a single step that has exceeded testCycle.stepTimeoutMinutes.
# Seed here so the first watchdog poll sees a fresh file even before
# the first sequence step runs.
$StepHeartbeatFile = Join-Path $env:YURUNA_RUNTIME_DIR "runner.stepHeartbeat"
# inner.pid: atomic temp-file + rename via the shared state-file
# helper so a crash mid-write can't leave a truncated PID for the
# outer watchdog to misread. UTF-8 no-BOM is correct here:
# ASCII-clean digits, and the outer reads via [int]::Parse which
# would reject a BOM prefix.
$null = Write-YurunaStateFile -Path $InnerPidFile -Content ([string]$PID) -Confirm:$false
[System.IO.File]::WriteAllText($HeartbeatFile,     [DateTime]::UtcNow.ToString('o'))
[System.IO.File]::WriteAllText($StepHeartbeatFile, [DateTime]::UtcNow.ToString('o'))

# Background heartbeat timer: uses a threadpool thread (System.Threading.
# Timer), NOT a Register-ObjectEvent action, so the heartbeat keeps
# advancing even when the runspace thread is blocked inside a long SSH
# call / Wait-Job / OCR pass. The callback MUST be a compiled .NET method,
# not a PowerShell scriptblock cast to [TimerCallback] -- the scriptblock
# path goes through ScriptBlock.GetContextFromTLS() which throws
# PSInvalidOperationException ("There is no Runspace available...") on the
# threadpool thread that fires the timer. We compile a tiny C# helper so
# the callback is pure IL and needs no runspace. The outer watchdog reads
# this file's mtime: stale beyond testCycle.stepTimeoutMinutes (default 45)
# means the inner is wedged and gets Stop-Process'd.
if (-not ('Yuruna.HeartbeatWriter' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Threading;
namespace Yuruna {
    public static class HeartbeatWriter {
        private static Timer _timer;
        private static string _path;
        // Silent error-swallowing here would let a disk-full condition
        // stay invisible until the watchdog killed the inner as
        // "stale". These two fields surface persistent failures via
        // a sibling `.errors.log` AND expose the counter to the main
        // runspace (Get-Error*) so a Wait-For-Text observer can flag
        // the degraded state.
        private static long _consecutiveErrors = 0;
        private static DateTime _lastErrorLogUtc = DateTime.MinValue;
        public static long ConsecutiveErrors { get { return _consecutiveErrors; } }
        public static void Start(string path, int dueMs, int periodMs) {
            _path = path;
            _timer = new Timer(Tick, null, dueMs, periodMs);
        }
        public static void Stop() {
            if (_timer != null) { _timer.Dispose(); _timer = null; }
        }
        private static void Tick(object state) {
            try {
                File.WriteAllText(_path, DateTime.UtcNow.ToString("o"));
                _consecutiveErrors = 0;
            } catch (Exception ex) {
                // Disk full / AV write-lock / network share gone. The
                // next tick may recover. We surface the failure in two
                // ways without flooding the disk:
                //   * Increment a static counter the main runspace can
                //     poll (Get-HeartbeatTimerErrors below).
                //   * Append at most one line per minute to a sibling
                //     `<path>.errors.log` so a post-hoc operator sees
                //     the underlying error class (vs. just "stale").
                _consecutiveErrors++;
                try {
                    DateTime now = DateTime.UtcNow;
                    if ((now - _lastErrorLogUtc).TotalSeconds >= 60.0) {
                        _lastErrorLogUtc = now;
                        string errPath = _path + ".errors.log";
                        string line = now.ToString("o") + " consecutive=" + _consecutiveErrors + " " + ex.GetType().Name + ": " + ex.Message + System.Environment.NewLine;
                        File.AppendAllText(errPath, line);
                    }
                } catch { /* throttle write itself failed -- nothing
                             reasonable to do from a threadpool thread */ }
            }
        }
    }
}
"@
}
try {
    [Yuruna.HeartbeatWriter]::Start($HeartbeatFile, 30000, 30000)
    $script:HeartbeatStarted = $true
} catch {
    $script:HeartbeatStarted = $false
    Write-Verbose "Could not start heartbeat timer (non-fatal): $($_.Exception.Message)"
}

# Callable from the main runspace to flag a degraded heartbeat. The
# watchdog "stale" detection still fires on mtime, but a high
# ConsecutiveErrors value pinpoints the cause as write failures
# (disk full, AV) rather than a wedged runspace.
function Get-HeartbeatTimerError {
    [CmdletBinding()]
    [OutputType([long])]
    param()
    try { return [long]([Yuruna.HeartbeatWriter]::ConsecutiveErrors) }
    catch { return [long]0 }
}

# Note: $env:YURUNA_LOG_LEVEL is published by Resolve-LogLevel (above and
# at end of Sync-RuntimeConfig). Children spawned from this runner inherit
# the value from the env block and apply the same severity cascade.

# === Import all modules (suppress engine verbose noise during imports) ===
$savedVerbose = $global:VerbosePreference
$global:VerbosePreference = "SilentlyContinue"

$yurunaLogModule = Join-Path -Path $RepoRoot -ChildPath "automation" -AdditionalChildPath "Yuruna.Log.psm1"
if (Test-Path $yurunaLogModule) {
    Import-Module $yurunaLogModule -Global -Force
}

# Shared retry policy with automation/yuruna-retry.sh (Get-YurunaRetryBackoff).
# Used by the post-cycle-failure backoff path in the cycle catch handler.
# --- See https://yuruna.link/network#defining-yuruna-retry-lib
$yurunaRetryModule = Join-Path -Path $RepoRoot -ChildPath "automation" -AdditionalChildPath "Yuruna.Retry.psm1"
if (Test-Path $yurunaRetryModule) {
    Import-Module $yurunaRetryModule -Global -Force
}

# The Inner kind import set covers Test.HostContract, Test.Status, Test.Notify,
# Test.Provenance, Test.Start-GuestOS, Test.Start-GuestWorkload, Test.Log,
# Test.SequencePlanner, Test.CachingProxy, Test.Perf, Test.HostIO,
# Test.Capability, Test.Transport (plus the early-bootstrap imports). The
# file-top pass via Initialize-YurunaEntryPointModuleSet -For Inner is
# repeated below to pick up a `git pull` between cycles. Windows chains
# a fresh pwsh per cycle via Start-Process so modules reload automatically
# there; the macOS in-process loop reuses cached modules unless we
# explicitly force-reload, which means a mid-run `git pull` would otherwise
# never propagate source changes.

$global:VerbosePreference = $savedVerbose

# === Bootstrap status.json from template if missing ===
if (-not (Test-Path $StatusFile)) {
    if (Test-Path $StatusTmpl) {
        Copy-Item -Path $StatusTmpl -Destination $StatusFile
        Write-Output "Created status.json from template."
    } else {
        Write-Error "Status template not found: $StatusTmpl"; exit 1
    }
}

# === Helpers: sync test.config.yml against its template ===
# Each cycle overlays the live config on the template so new template keys
# are picked up without losing user values. Rewrite to disk only when the
# merge differs from disk outside the 'secrets' subtree (credentials
# always diverge from template blanks; including them would churn the
# file every cycle).

# Overlay $Current onto $Template. Template shape wins (which keys exist);
# current values win for overlapping scalars/arrays. Keys only in $Current
# are dropped — template is the schema source of truth. Keys emitted
# alphabetically at every nesting level so regenerated test.config.yml
# is stable regardless of the template's own key ordering.
function ConvertTo-MergedHashtable {
    param($Template, $Current)

    if ($Template -isnot [System.Collections.IDictionary]) { return $Template }

    $result = [ordered]@{}
    foreach ($key in ($Template.Keys | Sort-Object)) {
        $tVal = $Template[$key]
        $hasCurrent = ($Current -is [System.Collections.IDictionary]) -and $Current.Contains($key)
        if ($tVal -is [System.Collections.IDictionary]) {
            $cVal = $hasCurrent ? $Current[$key] : $null
            $result[$key] = ConvertTo-MergedHashtable -Template $tVal -Current $cVal
        } elseif ($hasCurrent) {
            $result[$key] = $Current[$key]
        } else {
            $result[$key] = $tVal
        }
    }
    return $result
}

# Shallow clone of $Config without top-level 'secrets' for diff comparison.
function Copy-HashtableWithoutSecretNode {
    param($Config)
    if ($Config -isnot [System.Collections.IDictionary]) { return $Config }
    $copy = [ordered]@{}
    foreach ($key in $Config.Keys) {
        if ($key -eq 'secrets') { continue }
        $copy[$key] = $Config[$key]
    }
    return $copy
}

# Returns $true when $Current has the same nested node shape as $Template:
# every dictionary node in the template is present as a dictionary, and
# $Current carries no unexpected top-level keys ('secrets' excepted -- it
# is added out-of-band by the notification-credentials path). A flat
# test.config.yml (vmBootDelaySeconds, frameworkRepoUrl, ... at the
# root, where the current schema puts vmStart.bootDelaySeconds,
# repositories.frameworkUrl, etc.) fails both tests. Leaf values are NOT
# compared -- only container structure -- so any operator-set value passes.
function Test-ConfigMatchesTemplateShape {
    param($Template, $Current)
    if ($Template -isnot [System.Collections.IDictionary]) { return $true }
    if ($Current  -isnot [System.Collections.IDictionary]) { return $false }
    foreach ($key in $Template.Keys) {
        if ($Template[$key] -is [System.Collections.IDictionary]) {
            if (-not $Current.Contains($key))                          { return $false }
            if ($Current[$key] -isnot [System.Collections.IDictionary]) { return $false }
        }
    }
    foreach ($key in $Current.Keys) {
        if (-not $Template.Contains($key) -and $key -ne 'secrets') { return $false }
    }
    return $true
}

function Update-TestConfigFromTemplate {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ConfigPath,
        [Parameter(Mandatory)] [string]$TemplatePath
    )

    if (-not (Test-Path $TemplatePath)) {
        Write-Warning "Template not found: $TemplatePath — loading config as-is."
        return (Get-Content -Raw $ConfigPath | ConvertFrom-Yaml -Ordered)
    }
    if (-not (Test-Path $ConfigPath)) {
        Write-Information "Config not found: $ConfigPath — bootstrapping from template." -InformationAction Continue
        Copy-Item -Path $TemplatePath -Destination $ConfigPath
        return (Get-Content -Raw $ConfigPath | ConvertFrom-Yaml -Ordered)
    }

    $template = Get-Content -Raw $TemplatePath | ConvertFrom-Yaml -Ordered
    $current  = Get-Content -Raw $ConfigPath   | ConvertFrom-Yaml -Ordered

    # Silently drop deprecated top-level keys before the shape check below.
    # Without this, removing a key from the template would make the
    # structure-departure guard fire on every existing test.config.yml that
    # still carries it, backing the file up and resetting the operator's
    # values to template defaults. Targeted drops belong here; whole-layout
    # migrations (e.g. flat -> nested) should still trip the backup path.
    $deprecatedTopKeys = @('hostSshServer')
    if ($current -is [System.Collections.IDictionary]) {
        foreach ($k in $deprecatedTopKeys) {
            if ($current.Contains($k)) { $current.Remove($k) }
        }
    }

    # --- Structure-departure guard ---------------------------------------
    # test.config.yml uses a nested layout (vmStart / vmImage /
    # vmCommunication / repositories / testCycle nodes). When the on-disk
    # file departs from that shape -- e.g. a checkout left over from the
    # pre-nesting flat layout -- the template overlay below would silently
    # drop the orphaned flat keys and reset every node to its default.
    # Rather than lose the operator's values without a trace, back the
    # file up, reset it to the template, and stop the run so the operator
    # can copy values across by hand. Restarting then finds a well-formed
    # file and proceeds normally.
    if (-not (Test-ConfigMatchesTemplateShape -Template $template -Current $current)) {
        $backupPath = "$ConfigPath.backup"
        Copy-Item -LiteralPath $ConfigPath   -Destination $backupPath -Force
        Copy-Item -LiteralPath $TemplatePath -Destination $ConfigPath -Force
        Write-Warning @"
test.config.yml does not match the required nested format.
  - Previous file backed up to: $backupPath
  - test.config.yml has been reset to defaults from the template.
ACTION: copy any custom values from the .backup file into the new
test.config.yml by hand -- the layout is now nested (vmStart, vmImage,
vmCommunication, repositories, testCycle). See test/read.more.md.
Restarting the test will then proceed normally.
"@
        exit $ExitFailure
    }

    # Notification config (including secrets) lives at
    # test/status/extension/notification/transports.yml. The template
    # ships in-tree at test/extension/notification/transports.yml.template.
    # The legacy keys secrets.resend and notification.toEmailAddress in
    # test.config.yml are no longer schema-valid. The merge
    # (ConvertTo-MergedHashtable) drops template-orphan keys, so any
    # populated legacy values would vanish silently -- warn the operator
    # to move them by hand. Soft migration: do NOT auto-move credentials
    # across files.
    $statusExtNotif  = Join-Path -Path (Split-Path -Parent $ConfigPath) `
                          -ChildPath 'status' `
                          -AdditionalChildPath 'extension', 'notification'
    $notifConfigPath = Join-Path $statusExtNotif 'transports.yml'
    $hasNotifLive    = Test-Path $notifConfigPath
    if ($current -is [System.Collections.IDictionary]) {
        $legacyApiKey = $null
        if ($current.Contains('secrets') -and
            $current['secrets'] -is [System.Collections.IDictionary] -and
            $current['secrets'].Contains('resend') -and
            $current['secrets']['resend'] -is [System.Collections.IDictionary]) {
            $legacyApiKey = "$($current['secrets']['resend']['apiKey'])"
        }
        $legacyTo = $null
        if ($current.Contains('notification') -and
            $current['notification'] -is [System.Collections.IDictionary] -and
            $current['notification'].Contains('toEmailAddress')) {
            $legacyTo = "$($current['notification']['toEmailAddress'])"
        }
        if (-not $hasNotifLive -and ((-not [string]::IsNullOrEmpty($legacyApiKey)) -or (-not [string]::IsNullOrEmpty($legacyTo)))) {
            Write-Warning "test.config.yml contains legacy notification settings (secrets.resend / notification.toEmailAddress) that have moved to test/status/extension/notification/transports.yml. Copy test/extension/notification/transports.yml.template to test/status/extension/notification/transports.yml and populate transports.resend + subscribers BEFORE the next cycle, otherwise notifications will silently no-op."
        }
    }

    $merged = ConvertTo-MergedHashtable -Template $template -Current $current

    # Validate keystrokeMechanism. Canonical values "GUI"/"SSH";
    # recognition is case-insensitive, value is normalized to uppercase.
    # Unrecognized values (including legacy "hypervisor") are discarded
    # and replaced with the template default. No migration.
    $validMechanisms = @('GUI', 'SSH')
    $mergedComm = if ($merged -is [System.Collections.IDictionary]) { $merged['vmCommunication'] } else { $null }
    if ($mergedComm -is [System.Collections.IDictionary] -and $mergedComm.Contains('keystrokeMechanism')) {
        $original = "$($mergedComm['keystrokeMechanism'])"
        $upper    = $original.ToUpperInvariant()
        if ($upper -in $validMechanisms) {
            if ($original -cne $upper) {
                $mergedComm['keystrokeMechanism'] = $upper
            }
        } else {
            $default = "$($template['vmCommunication']['keystrokeMechanism'])"
            Write-Information "test.config.yml: vmCommunication.keystrokeMechanism='$original' not recognized — resetting to '$default'." -InformationAction Continue
            $mergedComm['keystrokeMechanism'] = $default
        }
    }

    $mergedForDiff  = Copy-HashtableWithoutSecretNode $merged
    $currentForDiff = Copy-HashtableWithoutSecretNode $current
    $mergedYaml  = $mergedForDiff  | ConvertTo-Yaml
    $currentYaml = $currentForDiff | ConvertTo-Yaml

    if ($mergedYaml -ne $currentYaml) {
        if ($PSCmdlet.ShouldProcess($ConfigPath, "Rewrite with template overlay")) {
            Write-Information "test.config.yml: applying template overlay to pick up schema changes." -InformationAction Continue
            $merged | ConvertTo-Yaml | Set-Content -Path $ConfigPath -Encoding utf8NoBOM
        }
    }

    return $merged
}

# mtime-keyed parse cache for Sync-RuntimeConfig. powershell-yaml's
# ConvertFrom-Yaml on the ~5-10 KB test.config.yml is ~30-100 ms and
# Sync-RuntimeConfig fires at ~8 step boundaries per cycle, so most of
# those parses regenerate the same object from an unchanged file. The
# file's own LastWriteTimeUtc is the source-of-truth freshness signal:
# unchanged mtime means unchanged content, so we hand back the cached
# parse instead of re-running the YAML parser. A live edit from the
# status-service "Edit config" page updates the mtime (the editor writes
# atomically), so the next Sync-RuntimeConfig parses fresh -- the
# documented live-edit semantics are preserved.
#
# $script:Config is read-only across this file (only re-assigned via
# this function), so returning a cached reference is safe; no callsite
# mutates the hashtable.
$script:CachedConfigMtime = $null
$script:CachedConfigValue = $null

function Sync-RuntimeConfig {
<#
.SYNOPSIS
Re-reads test.config.yml mid-cycle so values changed via the status
server's "Edit config" page take effect on the next step rather than
waiting for the next git pull / next cycle.
.DESCRIPTION
Updates the script-scoped $Config and re-derives the cycle-relevant
locals that drive subsequent step behavior:
  $StopOnFailure        — most-actionable: flips the post-step branch
                          between "abort cycle" and "log + continue".
  $VmStartTimeout       — New-VM.Resource uses this; lets an operator
                          extend the wait without restarting the runner
                          when a guest takes longer than expected to boot.
  $VmBootDelay          — same, applied after New-VM.Resource passes.
  $GetImageRefreshHours — picked up at next cycle's Get-Image gate.
  $CycleDelay           — read at end of cycle, before Start-Sleep.

On read or parse failure (mid-write truncation by the editor, transient
file lock, manual edit in progress) keeps the previous in-memory copy
and warns once -- the cycle continues with last-known-good values
rather than crashing on a half-written file.

Intentionally does NOT call Update-TestConfigFromTemplate: schema
migration is a per-cycle concern (runs after git pull at cycle start),
and re-merging mid-cycle would write back to the very file the editor
just wrote, creating a write-write race with the UI.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath)

    # mtime-keyed parse cache. Probe the on-disk mtime first; if it
    # matches the cached value we already have the parsed object in
    # $script:CachedConfigValue and can skip the file read + YAML parse
    # entirely. A failed Test-Path or Get-Item (e.g. the file was just
    # deleted) falls through to the parse path, which will surface the
    # failure via the existing warning branch.
    $currentMtime = $null
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $currentMtime = (Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc
        } catch {
            Write-Verbose "Sync-RuntimeConfig: mtime probe failed: $($_.Exception.Message)"
        }
    }
    if ($null -ne $currentMtime -and $currentMtime -eq $script:CachedConfigMtime -and $null -ne $script:CachedConfigValue) {
        $script:Config = $script:CachedConfigValue
    } else {
        try {
            $script:Config = Get-Content -Raw $ConfigPath -ErrorAction Stop | ConvertFrom-Yaml -Ordered -ErrorAction Stop
            $script:CachedConfigValue = $script:Config
            $script:CachedConfigMtime = $currentMtime
        } catch {
            Write-Warning "Config reload from '$ConfigPath' failed: $_ -- keeping previous values."
            return
        }
    }

    $cfg = $script:Config
    if (-not ($cfg -is [System.Collections.IDictionary])) { return }

    $tc = $cfg.testCycle
    $vs = $cfg.vmStart
    $vi = $cfg.vmImage
    $script:StopOnFailure        = if ($tc -is [System.Collections.IDictionary] -and $tc.Contains('shouldStopOnFailure')) { [bool]$tc.shouldStopOnFailure } else { $false }
    $script:VmStartTimeout       = if ($vs.startTimeoutSeconds) { [int]$vs.startTimeoutSeconds } else { 120 }
    $script:VmBootDelay          = if ($vs.bootDelaySeconds)    { [int]$vs.bootDelaySeconds }    else { 15 }
    $script:GetImageRefreshHours = if ($vi.refreshHours)        { [int]$vi.refreshHours }        else { 24 }
    # $CycleDelaySeconds is the script parameter (default fallback when
    # the config key is absent); use it not the literal 30 so that
    # `pwsh Invoke-TestRunner -CycleDelaySeconds 60` keeps its override.
    $script:CycleDelay           = if ($tc.cycleDelaySeconds)   { [int]$tc.cycleDelaySeconds }   else { $script:CycleDelaySeconds }
    # logLevel shares the same per-step semantics: cmdline > JSON >
    # 'Information'. Re-publishes $env:YURUNA_LOG_LEVEL so child processes
    # spawned in the next step inherit the latest value.
    Resolve-LogLevel
}

# === Read config (syncs against template first) ===
if (-not (Test-Path $ConfigPath) -and -not (Test-Path $TemplatePath)) {
    Write-Error "Neither config nor template found. Config: $ConfigPath Template: $TemplatePath"; exit 1
}
$Config = Update-TestConfigFromTemplate -ConfigPath $ConfigPath -TemplatePath $TemplatePath
$script:Config = $Config
# Re-resolve now that JSON values are loaded — the early Resolve-LogLevel
# at the top of the script saw cmdline-only data. Subsequent calls happen
# in Sync-RuntimeConfig per step.
Resolve-LogLevel

# === Phase 0: Bootstrap ===
$HostType = Get-HostType
if (-not $HostType) { exit 1 }
Write-Output "Host type: $HostType"

# Wire the host driver so the contract functions (New-VM, Start-VM,
# Stop-VM, Send-Text, Get-VMScreenshot, ...) are resolvable from this
# script's session without any HostType branches.
[void](Initialize-YurunaHost -RepoRoot $RepoRoot -HostType $HostType)

if (-not (Assert-HostConditionSet -HostType $HostType)) { exit 1 }

# === UTM concurrent-VM pre-flight ===========================================
# macOS vmnet-shared puts each new vmnet session on a separate host-side
# bridge (bridge100, bridge101, ...) that don't route between each other.
# Concurrent UTM VMs at cycle start split the test guests onto a different
# bridge from the host's vmnet gateway, breaking the cloud-init host-proxy
# URL baked into seed.iso. Refuse at cycle start
# if anything else is running. No ExceptVmName here: the runner is about
# to start its own test guests fresh; no carve-out is needed.
if ($HostType -eq 'host.macos.utm') {
    if (-not (Assert-NoConcurrentUtmVm)) { exit 1 }
}

Write-Output "Runtime directory: $env:YURUNA_RUNTIME_DIR"
Write-Output "Log directory:     $env:YURUNA_LOG_DIR"

# --- Stale cycle-restart flag sweep --------------------------------------
# control.cycle-restart is written by the status server's /control/start-
# cycle endpoint. The inter-cycle delay loop consumes it on its next tick;
# the per-step gate in Invoke-Sequence.psm1 honours it too. But if a prior
# session was killed mid-cycle before consuming the flag (operator Ctrl-C,
# outer-runner restart, process crash), the file persists. A freshly
# starting inner IS the restart the operator asked for, so consume the
# flag here unconditionally — otherwise the brand-new cycle's first step
# would immediately throw YurunaCycleRestart, mark the cycle failed, and
# loop until ConsecutiveCrashes aborts the runner. The flag's job is to
# wake a running inner, not to nag a fresh one.
try {
    $bootRestartFlag = Join-Path $env:YURUNA_RUNTIME_DIR 'control.cycle-restart'
    if (Test-Path -LiteralPath $bootRestartFlag) {
        $flagAge = (Get-Date) - (Get-Item -LiteralPath $bootRestartFlag).LastWriteTime
        Remove-Item -LiteralPath $bootRestartFlag -Force -ErrorAction SilentlyContinue
        Write-Output "Consumed stale control.cycle-restart (age: $([int]$flagAge.TotalSeconds)s) — this inner start IS the restart."
    }
} catch { Write-Verbose "Stale cycle-restart sweep failed: $($_.Exception.Message)" }

# Re-import Test.CachingProxy with -Global -Force AFTER Initialize-YurunaHost.
# Yuruna.Host.psm1 imports Test.CachingProxy non-globally during its
# module-load (line 46 in each host driver); per the eviction pattern,
# that nested -Force pulls Test.CachingProxy out of the global session,
# so Invoke-CachingProxyProbe stops resolving from this script even
# though the Inner-kind bootstrap import above ran first. -Global -Force
# here puts it back; same fix used by Start-StatusService.ps1 immediately
# after its own Initialize-YurunaHost.
Import-Module (Join-Path $ModulesDir 'Test.CachingProxy.psm1') -Global -Force -DisableNameChecking -Verbose:$false

# --- Cycle-start caching-proxy gate -------------------------------------
# Run the full Test-CachingProxy.ps1 probe suite (Invoke-CachingProxyProbe
# in Test.CachingProxy.psm1: :3128 / :3129 / :80 / :3000 TCP probes plus
# /yuruna-squid-ca.crt fetch) against the two operator-specified sources,
# in priority order:
#   1. $env:YURUNA_CACHING_PROXY_IP   -- session-scope env var
#   2. $Config.vmStart.cachingProxyIP -- persistent UI-edited config key
# Acceptance criterion: the cache's HTTP proxy port (:3128) is reachable
# -- the only requirement the runner actually depends on (it routes guest
# installs through this port). The other probes (:3129 ssl-bump, :3000
# Grafana, :80 + CA cert) still run for operator visibility, but failing
# them does NOT reject the cache. Keying on full probe Success
# (FailCount == 0) instead would reject barebones-squid caches that
# lack Grafana/ssl-bump and silently destroy $env:YURUNA_CACHING_PROXY_IP
# for downstream code.
# Empty/whitespace in either source is treated as absent. If neither
# source is set, the env var is left untouched and the original
# local-discovery path in Test-CachingProxyAvailable below runs unchanged.
# If sources are set but :3128 is unreachable on each, the env var is
# cleared so the same local-discovery fallback applies.
$envCacheIp    = if ($env:YURUNA_CACHING_PROXY_IP) { $env:YURUNA_CACHING_PROXY_IP.Trim() } else { '' }
$configCacheIp = ''
if ($Config.vmStart -is [System.Collections.IDictionary] -and $Config.vmStart.Contains('cachingProxyIP')) {
    $configCacheIp = "$($Config.vmStart.cachingProxyIP)".Trim()
}
if ($envCacheIp -or $configCacheIp) {
    $effectiveCacheIp = ''
    foreach ($cand in @(
        @{ Ip = $envCacheIp;    Source = '$env:YURUNA_CACHING_PROXY_IP' }
        @{ Ip = $configCacheIp; Source = 'vmStart.cachingProxyIP'        }
    )) {
        if (-not $cand.Ip) { continue }
        if (-not (Test-IpAddress $cand.Ip)) {
            Write-Output "Caching proxy '$($cand.Ip)' (source: $($cand.Source)): rejected -- not a valid IPv4 or IPv6 address."
            continue
        }
        Write-Output ""
        Write-Output "== Probing caching proxy at $($cand.Ip) (source: $($cand.Source)) =="
        $probe = Invoke-CachingProxyProbe -CacheIp $cand.Ip
        foreach ($line in $probe.Lines) { Write-Output $line }
        Write-Output "  Summary: $($probe.PassCount) PASS, $($probe.WarnCount) WARN, $($probe.FailCount) FAIL"
        if ($probe.HttpProxyReachable) {
            $effectiveCacheIp = $cand.Ip
            if ($probe.Success) {
                Write-Output "Caching proxy at $($cand.Ip) ACCEPTED (full probe suite passed)."
            } else {
                Write-Output "Caching proxy at $($cand.Ip) ACCEPTED (HTTP proxy :$($probe.HttpPort) reachable; see WARN/FAIL above for the non-essential checks that did not pass)."
            }
            break
        }
        Write-Output "Caching proxy at $($cand.Ip) REJECTED -- HTTP proxy :$($probe.HttpPort) not reachable."
    }
    # Publish the effective IP (or clear if no candidate had a reachable
    # :3128) so the rest of the cycle sees a coherent view via
    # $env:YURUNA_CACHING_PROXY_IP.
    $env:YURUNA_CACHING_PROXY_IP = $effectiveCacheIp
}

# Proxy-cache detection lives in Test.CachingProxy.psm1 so Start-StatusService
# shares the same probe — console banner here and the status-page banner
# (via $env:YURUNA_RUNTIME_DIR/caching-proxy.txt) stay in lockstep with the
# URL injected into autoinstall user-data by guest.ubuntu.server.24/New-VM.ps1.
$cachingProxyUrl = Test-CachingProxyAvailable

# Port-map dispatch (external / Yuruna-External fast path /
# Default-Switch fallback) and the Windows-vs-macOS port-list shape:
# https://yuruna.link/caching-proxy
if ($cachingProxyUrl) {
    $vmIp = if ($cachingProxyUrl -match '^http://([0-9.]+):') { $matches[1] } else { $null }
    $isExternal = [bool]$Env:YURUNA_CACHING_PROXY_IP
    $mapOk  = $false
    $bestIp = $null
    if ($isExternal) {
        [void](Remove-PortMap -Confirm:$false)
        $mapOk  = $true
        $bestIp = $vmIp
    } elseif ($vmIp) {
        # On macOS the detection URL is the VZ gateway (192.168.64.1),
        # not the cache VM's real IP. Get-CachingProxyVMIp reads the
        # yuruna-caching-proxy state file for the real IP so forwarders
        # tunnel to squid rather than looping back. On Windows the URL
        # already carries the cache VM IP.
        $portMapIp = Get-CachingProxyVMIp
        if (-not $portMapIp) { $portMapIp = $vmIp }

        $cacheOnExternalSwitch = [bool](Test-CacheVMOnExternalNetwork)
        if ($cacheOnExternalSwitch) {
            [void](Remove-PortMap -Confirm:$false)
            $mapOk  = $true
            $bestIp = $vmIp
        } else {
            $cacheHttpPort  = Get-CachingProxyPort -Scheme http
            $cacheHttpsPort = Get-CachingProxyPort -Scheme https
            $CachingProxyExposedPorts = if ($IsMacOS) { @(3000) } else { @(80, 3000, $cacheHttpPort, $cacheHttpsPort) }
            $portMapArgs = @{
                VMIp      = $portMapIp
                Port      = $CachingProxyExposedPorts
                PortRemap = @{ 8022 = 22 }
            }
            if ($IsMacOS) {
                $portMapArgs.PortRemap[$cacheHttpPort]  = 3138
                $portMapArgs.PortRemap[$cacheHttpsPort] = 3139
                $portMapArgs.ProxyProtocolPort          = @($cacheHttpPort, $cacheHttpsPort)
            }
            $mapResult = Add-PortMap @portMapArgs -Confirm:$false
            $mapOk     = [bool]$mapResult
            $bestIp    = Get-BestHostIp
            if (-not $bestIp) { $bestIp = $vmIp }  # no routable iface -- fall back
        }
    }
    if ($mapOk) {
        $dashboardUrl   = "http://${bestIp}:3000/d/yuruna-squid/caching-proxy-yuruna?orgId=1&from=now-2h&to=now&timezone=browser&refresh=1m"
        $esc            = [char]27
        $label          = if ($isExternal) { "detected (external: $vmIp)" } else { "detected" }
        $linkedDetected = "${esc}]8;;${dashboardUrl}${esc}\${label}${esc}]8;;${esc}\"
        Write-Output "Caching proxy: $linkedDetected"
    } else {
        Write-Output "Caching proxy: detected (port map failed)"
    }
} else {
    Write-Output "Caching proxy: not detected (guests will download directly from Ubuntu mirrors)"
    [void](Remove-PortMap -Confirm:$false)
}

$savedVerbose = $global:VerbosePreference
$global:VerbosePreference = "SilentlyContinue"
Import-Module (Join-Path $ModulesDir "Test.OcrEngine.psm1") -Force
Import-Module (Join-Path $ModulesDir "Test.Tesseract.psm1") -Force
# Test.Ssh exposes Get-GuestAddress + Wait-GuestIp for the per-guest IP
# suffix printed alongside Start-VM: PASS. Imported even though SSH itself
# is optional, because IP discovery uses host-side facilities (Hyper-V
# KVP, utmctl, dhcpd_leases) and works without sshd in the guest.
Import-Module (Join-Path $ModulesDir "Test.Ssh.psm1") -Force
$global:VerbosePreference = $savedVerbose
$activeEngines = Get-EnabledOcrProvider
$combineMode = ($env:YURUNA_OCR_COMBINE -eq 'And') ? 'And' : 'Or'
Write-Debug "OCR engines: $($activeEngines -join ', ') | combine: $combineMode"
if (-not (Assert-TesseractInstalled)) { exit 1 }

$startScript = Join-Path $TestRoot "Start-StatusService.ps1"
if ($Config.statusService.isEnabled -and -not $NoServer) {
    $serverPort  = $Config.statusService.port ? [int]$Config.statusService.port : 8080
    # No -Restart: Start-StatusService compares the running server's
    # persisted server.sha against the current framework HEAD and skips
    # the kill+relaunch when the code it has in memory is still current.
    # Zero downtime in the no-change cycle (the common case after the
    # outer's `git pull` was a no-op); an automatic restart kicks in
    # only when `git pull` actually moved HEAD. An operator who wants
    # to force a relaunch (e.g. after editing the server here-string
    # without committing) invokes Start-StatusService.ps1 -Restart by
    # hand -- the flag still has its original semantics.
    & $startScript -Port $serverPort
}

# === Helper: strip everything under the top-level 'secrets' node before logging ===
# Hide- (rather than Remove-) is deliberate: PSScriptAnalyzer's
# PSUseShouldProcessForStateChangingFunctions rule triggers on Remove-/Set-/etc.
# verbs but not on Hide-. The function still mutates the passed config -- the
# verb just signals "redacting from a logged view" rather than "deleting".
function Hide-SecretsInConfig {
    param($Config)
    if ($Config -is [System.Collections.IDictionary] -and $Config.Contains('secrets')) {
        $node = $Config['secrets']
        if ($node -is [System.Collections.IDictionary]) {
            foreach ($key in @($node.Keys)) { $node.Remove($key) }
        }
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
# as http://ip:port.
$script:CachingProxyLastReachable = $true
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
        if ($async.AsyncWaitHandle.WaitOne(1000) -and $tcp.Connected) {
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
            Write-Warning "  Caching proxy LOST at ${GuestKey}/${StepName}: $ProxyUrl no longer answers (1s TCP probe)."
            Write-Warning "    Common cause: host Wi-Fi roamed to a different SSID/subnet mid-cycle."
            Write-Warning "    Guests configured at New-VM time with this URL will fall back to direct downloads."
        } else {
            Write-Warning "  Caching proxy still unreachable at $GuestKey/$StepName ($ProxyUrl)."
        }
    }
    $script:CachingProxyLastReachable = $reachable
}

# === Helper: copy failure artifacts to status/log for remote inspection ===
function Copy-FailureArtifactsToStatusLog {
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
        [string]$GuestKey = ''
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

# === Graceful shutdown support ===
# CancelKeyPress handler runs in a separate SessionState (Register-ObjectEvent
# -Action creates its own scope) so $script:var would not propagate back.
# Use a thread-safe dictionary so the event action and main loop share state.
$script:ShutdownState = [System.Collections.Concurrent.ConcurrentDictionary[string,bool]]::new()
$script:ShutdownState['Requested'] = $false
$script:ActiveVMName      = $null
$script:CycleFinalized    = $true    # have Complete-Run/Stop-LogFile been called?

try {
    # Register-ObjectEvent (not [Console]::add_CancelKeyPress) so the
    # handler runs on the PowerShell pipeline thread with a runspace.
    # A raw .NET event delegate fires on a CLR thread-pool thread with
    # no runspace, causing a fatal PSInvalidOperationException
    # ("There is no Runspace available...") that kills the process and
    # prevents graceful cleanup.
    $shutdownRef = $script:ShutdownState
    # Clean up any subscriber/job left by a prior run that exited without
    # reaching the bottom-of-script Unregister-Event (Ctrl+C, error,
    # IDE-terminated). Otherwise re-running in the same shell fails with
    # "A subscriber with the source identifier ... already exists".
    Unregister-Event -SourceIdentifier YurunaCancelKey -ErrorAction SilentlyContinue
    Remove-Job -Name YurunaCancelKey -Force -ErrorAction SilentlyContinue
    $null = Register-ObjectEvent -InputObject ([Console]) -EventName CancelKeyPress `
        -SourceIdentifier YurunaCancelKey -MessageData $shutdownRef -Action {
            $Event.SourceEventArgs.Cancel = $true
            $Event.MessageData['Requested'] = $true
            Write-Warning "Shutdown requested (Ctrl+C). Will clean up after current operation..."
        }
} catch {
    Write-Verbose "Could not register CancelKeyPress handler (non-interactive session): $_"
}

# === Continuous test loop ===
$CycleCount     = 0
try {
    $prevStatus = Get-Content -Raw $StatusFile | ConvertFrom-Json
    if ($prevStatus.cycle) { $CycleCount = [int]$prevStatus.cycle }
} catch { Write-Warning "Could not read previous cycle count from status file: $_" }
$OverallPassed       = $true
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
    } catch {
        Write-Warning "Could not parse $GatingFile (resetting gating state): $($_.Exception.Message)"
    }
}

while ($true) {
    if ($script:ShutdownState['Requested']) {
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
            # builds a minimal payload from these scalars. 'git_sync' /
            # 'blocking' let extensions route on failureClass instead of
            # free-text grep.
            Send-CycleFailureNotification `
                -HostType            $HostType `
                -SubjectSuffix       'GitPull' `
                -GuestKey            '(bootstrap)' `
                -StepName            'GitPull' `
                -ErrorMessage        $gitPullErr `
                -CycleId             '(not yet assigned)' `
                -GitCommit           $gitPullCommit `
                -DefaultFailureClass 'git_sync' `
                -DefaultSeverity     'blocking'
            exit $ExitFailure
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
        # Bootstrap-stage failure -- no cycle folder yet, so the helper
        # builds a minimal payload from these scalars. 'project_clone' /
        # 'blocking' let extensions route on failureClass.
        Send-CycleFailureNotification `
            -HostType            $HostType `
            -SubjectSuffix       'ProjectClone' `
            -GuestKey            '(bootstrap)' `
            -StepName            'ProjectClone' `
            -ErrorMessage        $cloneRes.errorMessage `
            -CycleId             '(not yet assigned)' `
            -GitCommit           $GitCommit `
            -DefaultFailureClass 'project_clone' `
            -DefaultSeverity     'blocking'
        # Single-cycle runner: project-clone failure exits with the
        # generic "cycle failed" code so the outer Invoke-TestRunner's
        # backoff loop pauses (60-min cap, polled by new commits) before
        # respawning. Network blips and transient git auth failures
        # surface there as the natural retry path; the inner doesn't
        # sleep here since the outer already gates re-spawning.
        $script:InnerCycleFailed = $true
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
    # cycle loop is structured. Symptom that drove this defense: on macOS
    # (which loops in-process via `continue` near the bottom of the cycle),
    # PowerShell's module cache survives across cycles, so a long-running
    # runner kept building UTM bundle paths under the pre-rename
    # `~/Desktop/Yuruna.VDE/<host>.nosync/` layout from the cached
    # Test.Start-VM module after the path-rename commits landed — Start-VM
    # failed every guest with "UTM bundle not found: …/Yuruna.VDE/…". On
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
    if ($Config.statusService.isEnabled -and -not $NoServer) {
        $serverPort = $Config.statusService.port ? [int]$Config.statusService.port : 8080
        & $startScript -Port $serverPort -Restart
    }

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
    try {
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
    # I/O action no backend on this host has registered — replaces
    # the silent "Unknown host: ..." that used to surface only at
    # runtime, deep inside a sequence step.
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
        }
        if ($cap.unknownActions.Count) {
            # Don't fail the cycle on an unknown verb — the engine still
            # has its own switch which will throw at runtime, but surface
            # the typo early so the operator notices before the slow path.
            Write-Warning "Cycle plan references unknown action verbs (typo? new verb?): $($cap.unknownActions -join ', ')"
        }
    }
    $Prefix = $Config.vmStart.testVmNamePrefix ?? "test-"

    # Build VM name map via Get-TestVMName so any guestSequence key yields a
    # stable VM name — no hardcoded per-guest lookup needed.
    $VMNames = @{}
    foreach ($GuestKey in $GuestList) {
        $VMNames[$GuestKey] = Get-TestVMName -GuestKey $GuestKey -Prefix $Prefix
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

    $VmStartTimeout = $Config.vmStart.startTimeoutSeconds ? [int]$Config.vmStart.startTimeoutSeconds : 120
    $VmBootDelay    = $Config.vmStart.bootDelaySeconds    ? [int]$Config.vmStart.bootDelaySeconds    : 15
    $CycleDelay     = $Config.testCycle.cycleDelaySeconds ? [int]$Config.testCycle.cycleDelaySeconds : $CycleDelaySeconds
    $GetImageRefreshHours = $Config.vmImage.refreshHours ? [int]$Config.vmImage.refreshHours : 24
    $StopOnFailure  = ($Config.testCycle -is [System.Collections.IDictionary] -and $Config.testCycle.Contains('shouldStopOnFailure')) ? [bool]$Config.testCycle.shouldStopOnFailure : $false

    # --- Initialize status for this cycle ---
    # Build the gitCommits array: framework FIRST (the dashboard's
    # logFileUrl helper treats element [0] as the primary log key, and
    # the framework SHA is what Start-LogFile actually used to name
    # the per-cycle log file), project SECOND if a clone was produced
    # this cycle. Empty repositories.projectUrl / in-tree fallback yields a
    # one-element array, identical to the pre-array behavior.
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

    # --- Test each guest sequentially: cleanup → create → start → verify → screenshots → pool test → stop ---
    # One guest VM at a time, so failures don't leave other VMs active.
    foreach ($GuestKey in $GuestList) {
        if ($script:ShutdownState['Requested']) {
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
        Sync-RuntimeConfig -ConfigPath $ConfigPath
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
            # Copy artifacts BEFORE the shouldStopOnFailure break so the debug
            # folder exists, the log links it, and the dashboard's "fail"
            # pill points to it on both paths (continue and stop).
            Copy-FailureArtifactsToStatusLog -VMName $VMName -GuestKey $GuestKey
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
        Sync-RuntimeConfig -ConfigPath $ConfigPath
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
            Copy-FailureArtifactsToStatusLog -VMName $VMName -GuestKey $GuestKey
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
        Sync-RuntimeConfig -ConfigPath $ConfigPath
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
            Copy-FailureArtifactsToStatusLog -VMName $VMName -GuestKey $GuestKey
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
        Sync-RuntimeConfig -ConfigPath $ConfigPath
        if (-not $ok) {
            $err = "VM '$VMName' did not reach running state after start."
            Write-Warning "  ERROR [$GuestKey / New-VM.Resource]: $err"
            Write-Output "  Log directory: $env:YURUNA_LOG_DIR"
            Set-StepStatus  -GuestKey $GuestKey -StepName "New-VM.Resource" -Status "fail" -ErrorMessage $err
            Set-GuestStatus -GuestKey $GuestKey -Status "fail"
            $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "New-VM.Resource"; $FailureMessage = $err
            Copy-FailureArtifactsToStatusLog -VMName $VMName -GuestKey $GuestKey
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
            Sync-RuntimeConfig -ConfigPath $ConfigPath
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
                Copy-FailureArtifactsToStatusLog -VMName $VMName -GuestKey $GuestKey
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
            Sync-RuntimeConfig -ConfigPath $ConfigPath
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
                Copy-FailureArtifactsToStatusLog -VMName $VMName -GuestKey $GuestKey
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
        # Final reload so an edit made during the last step's cleanup
        # affects the cycle-end abort decision (matches per-step semantics).
        Sync-RuntimeConfig -ConfigPath $ConfigPath
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
                # (internally, via Send-CycleEventSafely), and logs the next
                # step. Advisory only -- the dispatcher never acts. Pass the
                # in-memory payload so a cycle-boundary wipe of last_failure.json
                # can't route this on a stale file. Auto-applying a
                # recommendation is a separate, default-off feature that needs a
                # per-cycle attempt cap and a class allow-list before it can act.
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
        while ([DateTime]::UtcNow -lt $backoffDeadline -and -not $script:ShutdownState['Requested']) {
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

    if ($script:ShutdownState['Requested']) {
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
        while ((Test-Path $cyclePauseFlagFile) -and (-not $script:ShutdownState['Requested'])) {
            try {
                [System.IO.File]::WriteAllText($StepHeartbeatFile, [DateTime]::UtcNow.ToString('o'))
            } catch {
                Write-Verbose "runner.stepHeartbeat refresh during cycle pause failed: $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds (Get-PollDelay -Attempt $pauseAttempt)
            $pauseAttempt++
        }
        if ($script:ShutdownState['Requested']) {
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
    if ($effectiveDelay -gt 0 -and -not $script:ShutdownState['Requested']) {
        Write-Output "[cycle $CycleCount] cycleDelaySeconds wait: $effectiveDelay s before exiting to outer."
        $exitReason = Wait-WithProgress -Activity "[cycle $CycleCount] inter-cycle delay" `
            -TotalSeconds $effectiveDelay -PollSeconds 1 -Id $delayId -Test {
                if ($script:ShutdownState['Requested']) { return 'shutdown' }
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
    if (($effectiveDelay -gt 0) -and (Test-Path $cyclePauseFlagFile) -and (-not $script:ShutdownState['Requested'])) {
        Write-Output "Cycle pause armed during inter-cycle delay. Pausing before next cycle; waiting for resume..."
        $postDelayPauseAttempt = 1
        while ((Test-Path $cyclePauseFlagFile) -and (-not $script:ShutdownState['Requested'])) {
            try {
                [System.IO.File]::WriteAllText($StepHeartbeatFile, [DateTime]::UtcNow.ToString('o'))
            } catch {
                Write-Verbose "runner.stepHeartbeat refresh during cycle pause failed: $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds (Get-PollDelay -Attempt $postDelayPauseAttempt)
            $postDelayPauseAttempt++
        }
        if ($script:ShutdownState['Requested']) {
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

Write-InnerLog "post-loop cleanup: Unregister-Event YurunaCancelKey"
Unregister-Event -SourceIdentifier YurunaCancelKey -ErrorAction SilentlyContinue
Remove-Job -Name YurunaCancelKey -Force -ErrorAction SilentlyContinue
Write-InnerLog "post-loop cleanup: Unregister-Event/Remove-Job complete"

# Persist gating state so the next single-cycle inner respawn picks
# up the correct (Armed | Fired) phase. Writes are best-effort.
try {
    $null = Write-YurunaStateFileJson -Path $GatingFile -Depth 4 -Compress:$false -WithBom -Confirm:$false -InputObject @{
        consecutiveFailures  = $ConsecutiveFailures
        consecutiveSuccesses = $ConsecutiveSuccesses
        alertArmed           = $AlertArmed
        savedAt              = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
} catch {
    Write-Verbose "Gating-state save failed (best-effort, ignoring): $($_.Exception.Message)"
}
Write-InnerLog "post-loop cleanup: gating state saved"

# === Heartbeat cleanup ===
# Dispose the threadpool timer first so it can't race a final file write
# against the inner.pid removal that the outer's watchdog reads to know
# we exited cleanly. Errors are swallowed -- this runs after the cycle
# already produced its exit code, so a cleanup hiccup must not change it.
try {
    if ($script:HeartbeatStarted) {
        [Yuruna.HeartbeatWriter]::Stop()
        $script:HeartbeatStarted = $false
    }
} catch { $null = $_ }
try {
    if (Test-Path $InnerPidFile) {
        $innerFilePid = 0
        try { $innerFilePid = [int]((Get-Content $InnerPidFile -Raw -ErrorAction Stop).Trim()) } catch { $innerFilePid = 0 }
        # Only remove if it still points to us. Don't clobber a competing
        # inner's pidfile (same pattern as the runner.pid cleanup below).
        if ($innerFilePid -eq $PID) {
            Remove-Item $InnerPidFile -Force -ErrorAction SilentlyContinue
        }
    }
} catch { $null = $_ }

# Outer (Invoke-TestRunner.ps1) owns the runner.pid file across our
# single-cycle lifetime; only release it if the inner was invoked
# directly (no YURUNA_RUNNER_RELAUNCH=1 from the outer).
if ($env:YURUNA_RUNNER_RELAUNCH -ne '1') {

# Release runner.pid on graceful exit — only if it still points to us.
# A competing runner may have taken over and rewritten the file with its
# own PID; don't clobber theirs. Crash / kill -9 / power loss leaves a
# stale PID; next startup's single-instance guard handles it.
try {
    if (Test-Path $RunnerPidFile) {
        $filePid = 0
        # Malformed pidfile → leave it alone (don't remove something we
        # can't identify as ours). $filePid stays 0 so the -eq $PID check
        # below is false.
        try { $filePid = [int]((Get-Content $RunnerPidFile -Raw -ErrorAction Stop).Trim()) } catch { $filePid = 0 }
        if ($filePid -eq $PID) {
            Remove-Item $RunnerPidFile -Force -ErrorAction SilentlyContinue
        }
    }
} catch {
    # Shutdown cleanup is best-effort: any failure (pidfile race with a
    # competing runner, fs permission blip) leaves a possibly-stale file.
    # Fine — the single-instance guard handles it on next launch.
    Write-Verbose "Shutdown pidfile cleanup swallowed error: $($_.Exception.Message)"
}

}  # end of: if YURUNA_RUNNER_RELAUNCH -ne '1' (pidfile cleanup)

# === Failure notification (only reached when shouldStopOnFailure breaks the loop) ===
if (-not $OverallPassed -and $FailedGuest) {
    Write-Output ""
    Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Output "  FAILURE SUMMARY"
    Write-Output "  Host:    $HostType"
    Write-Output "  Guest:   $FailedGuest"
    Write-Output "  Step:    $FailedStep"
    Write-Output "  Error:    $FailureMessage"
    Write-Output "  Cycle ID: $CycleId"
    $CommitLine = if ($ProjectGitCommit) { "$GitCommit, $ProjectGitCommit" } else { $GitCommit }
    Write-Output "  Commit:   $CommitLine"
    Write-Output "  Log:     $LogFile"
    Write-Output "  Alert:   $ConsecutiveFailures/$FailuresBeforeAlert failures $(if ($AlertArmed) {'(armed)'} else {'(suppressed)'})"
    Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Output ""
    Write-Output "To reproduce with full diagnostics:"
    Write-Output "  pwsh test/Invoke-TestRunner.ps1 -NoGitPull -logLevel Debug"

    if ($AlertArmed -and $ConsecutiveFailures -ge $FailuresBeforeAlert) {
        # EventData: post-loop alert (shouldStopOnFailure path). Same
        # contract as the in-cycle handler above -- read schema-v2
        # last_failure.json from the cycle folder, augment with cycle/
        # host context, remediate below, then ship via
        # Send-CycleFailureNotification (its body JSON trailer and
        # -EventData both carry this payload).
        $postLoopEventData = Get-FailureEventData `
            -HostType      $HostType `
            -Hostname      (hostname) `
            -GuestKey      $FailedGuest `
            -StepName      $FailedStep `
            -ErrorMessage  $FailureMessage `
            -CycleId       $CycleId `
            -GitCommit     $GitCommit `
            -ProjectCommit $ProjectGitCommit
        # Advisory remediation dispatch (same as the in-cycle path). Skip the
        # planner-abort case (FailedGuest '(planner)' / PlannerFatal): a
        # duplicate-sequence config error is never auto-remediable and would
        # only route to operator_intervention_required.
        if ((Get-Command Invoke-Remediation -ErrorAction SilentlyContinue) -and $FailedGuest -ne '(planner)') {
            $remediation = Invoke-Remediation -FailureRecord $postLoopEventData
            if ($remediation) { Write-Output "  Remediation: $($remediation.Recommendation) -- $($remediation.Rationale)" }
        }
        # Payload built + (planner-guarded) remediated above; pass it
        # pre-built so the helper ships the same hashtable without
        # rebuilding or reordering remediation.
        Send-CycleFailureNotification `
            -HostType      $HostType `
            -SubjectSuffix "$FailedGuest / $FailedStep" `
            -GuestKey      $FailedGuest `
            -StepName      $FailedStep `
            -ErrorMessage  $FailureMessage `
            -CycleId       $CycleId `
            -GitCommit     $GitCommit `
            -EventData     $postLoopEventData
        # Disarm so a shouldStopOnFailure stream (this block fires only when
        # shouldStopOnFailure broke before the in-cycle inline handler could
        # update gating state) doesn't re-alert on every outer respawn.
        # The disarmed state is persisted further down by the gating-state
        # save, so the next inner reads it on entry. Successive successes
        # rearm via the in-cycle handler.
        $AlertArmed           = $false
        $ConsecutiveSuccesses = 0
    } else {
        Write-Output "  Notification suppressed ($ConsecutiveFailures/$FailuresBeforeAlert failures, armed=$AlertArmed)."
    }
}

# Re-save gating state so the disarmed flag set by the post-loop block
# (above) is captured. The earlier save right after the cycle loop
# captures the in-cycle inline handler's state; this second write covers
# the shouldStopOnFailure path.
try {
    $null = Write-YurunaStateFileJson -Path $GatingFile -Depth 4 -Compress:$false -WithBom -Confirm:$false -InputObject @{
        consecutiveFailures  = $ConsecutiveFailures
        consecutiveSuccesses = $ConsecutiveSuccesses
        alertArmed           = $AlertArmed
        savedAt              = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
} catch {
    Write-Verbose "Final gating-state save failed (best-effort, ignoring): $($_.Exception.Message)"
}

$finalCode = ($OverallPassed ? $ExitOk : $ExitFailure)
Write-InnerLog "about to exit with code $finalCode"
exit $finalCode
