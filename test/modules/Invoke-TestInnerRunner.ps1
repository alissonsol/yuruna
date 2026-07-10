<#PSScriptInfo
.VERSION 2026.07.10
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

# Wraps Test.LogLevel\Resolve-LogLevel so the bootstrap stays terse. Called
# (a) at startup with cmdline-only data and (b) after Update-TestConfigFromTemplate
# loads $script:Config. The per-step refresh inside a cycle is the module sibling
# Resolve-RunnerLogLevel (run after each Sync-RunnerCycleConfig), so a JSON edit
# reaches the next step's child processes via $env:YURUNA_LOG_LEVEL.
function Resolve-LogLevel {
    [CmdletBinding()]
    param()
    $cfg = $script:Config
    $configLevel = if ($cfg -is [System.Collections.IDictionary] -and $cfg.Contains('logLevel')) {
        [string]$cfg.logLevel
    } else { $null }
    $null = Test.LogLevel\Resolve-LogLevel -CmdLineLevel $script:CmdLineLogLevel -ConfigLevel $configLevel
}

# Initial pass: cmdline-only (test.config.yml hasn't been loaded yet). The
# next pass runs right after Update-TestConfigFromTemplate; per-step refreshes
# inside a cycle run via Resolve-RunnerLogLevel.
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
# Update-TransportDefault reads the SAME file Sync-RunnerCycleConfig uses.
# Outer also publishes this on its own ForwardEnvNames list; setting it
# here covers the standalone-direct invocation case (operator runs
# Invoke-TestInnerRunner.ps1 by hand).
$env:YURUNA_CONFIG_PATH = $ConfigPath

# Canonical Inner-kind module set: Test.SingleInstance, Test.YurunaDir,
# Test.Extension, Test.HostContract, Test.Status, Test.Notify, Test.Provenance,
# Test.Start-GuestOS, Test.Start-GuestWorkload, Test.Log, Test.Sequence-
# Planner, Test.CachingProxy, Test.Perf, Test.HostIO, Test.Capability,
# Test.Transport. One helper covers both the early-bootstrap modules
# (Test.YurunaDir, Test.Extension, Test.SingleInstance) and the per-cycle
# workhorse list, replacing per-site inline Import-Module calls. The
# mid-cycle refresh loop re-calls this helper so a `git pull` between
# cycles propagates source changes to every covered module in lockstep --
# without having to maintain a parallel list.
Initialize-YurunaEntryPointModuleSet -For Inner -ModulesDir $ModulesDir
$null = Initialize-YurunaRuntimeDir
$null = Initialize-YurunaLogDir
# Stable per-host pool identity on the process global (before any NDJSON event)
# so cycle events + status.json carry hostId for cross-host joins. Script-top
# assignment, mirroring $global:__YurunaRunId.
$global:__YurunaHostId = Get-YurunaHostId
$StatusFile = Join-Path $env:YURUNA_RUNTIME_DIR "status.json"

# Per-cycle helpers live in Test.RunnerInnerLoop.psm1 (imported with the Inner
# module set): Write-InnerLog (exit-path timeline log), the cycle-start
# working-tree-drift guard (Convert-LocalRepoUrlToPath /
# Write-UncommittedChangesWarning), and Assert-CachingProxyStillReachable
# (per-step caching-proxy reachability probe).

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
# Check the write: a failed inner.pid leaves the inner un-targetable by the
# outer's watchdog, so a hung inner would run unguarded. That is a degraded
# (unmonitored) run, not a fatal one -- warn and continue. The console
# Write-Warning here is only inherited by the outer (the Yuruna.Log Write-Warning
# proxy is not imported yet, and the call-op spawn does not redirect stderr), so
# also mirror it to outer.log via Write-InnerLog where it stays durable and
# diagnosable next to the outer/watchdog entries.
$innerPidWritten = Write-YurunaStateFile -Path $InnerPidFile -Content ([string]$PID) -Confirm:$false
if (-not $innerPidWritten) {
    $innerPidWarn = "inner.pid write to '$InnerPidFile' failed; the outer watchdog cannot target this inner by PID (a hung inner will run unguarded this cycle). Check YURUNA_RUNTIME_DIR permissions/free space."
    Write-Warning $innerPidWarn
    Write-InnerLog $innerPidWarn
}
[System.IO.File]::WriteAllText($StepHeartbeatFile, [DateTime]::UtcNow.ToString('o'))

# Background heartbeat timer lives in Test.RunnerHeartbeat.psm1 (imported with
# the Inner module set): a threadpool-driven runner.heartbeat the outer watchdog
# reads to prove the inner PROCESS is alive even when the runspace is wedged in
# a long OCR / SSH call. The in-runspace runner.stepHeartbeat (seeded above,
# touched per step by Invoke-Sequence) proves the RUNSPACE is alive. Get-Runner-
# HeartbeatError surfaces consecutive write failures (disk full / AV) for
# diagnostics.
Start-RunnerHeartbeat -Path $HeartbeatFile
# Note: $env:YURUNA_LOG_LEVEL is published by Resolve-LogLevel (here at
# bootstrap) and by Resolve-RunnerLogLevel per step inside the cycle. Children
# spawned from this runner inherit the value from the env block and apply the
# same severity cascade.

# === Import all modules (suppress engine verbose noise during imports) ===
$savedVerbose = $global:VerbosePreference
$global:VerbosePreference = "SilentlyContinue"

$yurunaLogModule = Join-Path -Path $RepoRoot -ChildPath "automation" -AdditionalChildPath "Yuruna.Log.psm1"
if (Test-Path $yurunaLogModule) {
    Import-Module $yurunaLogModule -Global -Force
}

# Shared retry policy with automation/yuruna-retry.sh (Get-YurunaRetryBackoff).
# Used by the post-cycle-failure backoff path in the cycle catch handler.
# --- REGION: https://yuruna.link/network#defining-yuruna-retry-lib
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
        Write-Error "Status template not found: $StatusTmpl"; exit $ExitFailure
    }
}

# test.config.yml <-> template reconciliation lives in Test.ConfigSync.psm1
# (imported with the Inner module set): ConvertTo-MergedHashtable,
# Copy-HashtableWithoutSecretNode, Test-ConfigMatchesTemplateShape,
# Update-TestConfigFromTemplate (the cycle-start overlay + structure-departure
# guard), and Hide-SecretsInConfig (redacts the 'secrets' node before logging).

# Mutable per-run config state consumed by Invoke-RunnerInnerCycle
# (Test.RunnerInnerLoop.psm1): the mtime parse-cache slots plus the reloadable
# knobs. Built once here so the cmdline log level and the -CycleDelaySeconds
# fallback are captured; Sync-RunnerCycleConfig mutates it each step inside the
# cycle, keeping the parse-cache + reloadable-knob rules in one tested place.
$script:RunnerCfgState = New-RunnerConfigState -CmdLineLogLevel $script:CmdLineLogLevel -CycleDelayFallback $CycleDelaySeconds

# === Read config (syncs against template first) ===
if (-not (Test-Path $ConfigPath) -and -not (Test-Path $TemplatePath)) {
    Write-Error "Neither config nor template found. Config: $ConfigPath Template: $TemplatePath"; exit $ExitFailure
}
$Config = Update-TestConfigFromTemplate -ConfigPath $ConfigPath -TemplatePath $TemplatePath
$script:Config = $Config
# Re-resolve now that JSON values are loaded — the early Resolve-LogLevel
# at the top of the script saw cmdline-only data. Per-step refreshes inside a
# cycle run via Resolve-RunnerLogLevel.
Resolve-LogLevel

# === Phase 0: Bootstrap ===
$HostType = Get-HostType
if (-not $HostType) { exit $ExitFailure }
Write-Output "Host type: $HostType"

# Externalize this host's identity + capabilities to runtime/host.registration.json
# (served at /runtime/host.registration.json) for the multi-host pool aggregator.
# Once per cycle, main runspace, best-effort. See docs/opportunities-hostpool.md.
if (Get-Command Write-HostRegistrationRecord -ErrorAction SilentlyContinue) {
    $null = Write-HostRegistrationRecord -HostType $HostType -RepoRoot $RepoRoot
}

# Wire the host driver so the contract functions (New-VM, Start-VM,
# Stop-VM, Send-Text, Get-VMScreenshot, ...) are resolvable from this
# script's session without any HostType branches.
[void](Initialize-YurunaHost -RepoRoot $RepoRoot -HostType $HostType)

# Keep a stash host's advertised address current: re-resolve the stash VM's guest IP
# (single-shot, now that Get-VMIp is wired) and rewrite the marker's stashBaseUrl when
# it changes, so the Extension cell's /go/stash deep-link self-heals after a DHCP lease
# change. The refreshed URL folds into host.registration.json on the next cycle's
# Write-HostRegistrationRecord. No-op when this host runs no stash server.
if (Get-Command Update-StashServerMarkerAddress -ErrorAction SilentlyContinue) {
    $null = Update-StashServerMarkerAddress
}

if (-not (Assert-HostConditionSet -HostType $HostType)) { exit $ExitFailure }

# === UTM concurrent-VM pre-flight ===========================================
# On some macOS versions vmnet-shared puts each vmnet session on a separate
# host-side bridge (bridge100, bridge101, ...) that don't route between each
# other, so a foreign concurrent VM can split the test guests onto a
# different bridge from the host's vmnet gateway and break the cloud-init
# host-proxy URL baked into seed.iso. Refuse at cycle start if a foreign VM
# is running. The caching-proxy VM is exempt inside Assert-NoConcurrentUtmVm
# (it is a dependency the guests consume, reachable on the shared bridge),
# so a running cache no longer blocks the cycle.
if ($HostType -eq 'host.macos.utm') {
    if (-not (Assert-NoConcurrentUtmVm)) { exit $ExitFailure }
}

Write-Output "Runtime directory: $env:YURUNA_RUNTIME_DIR"
Write-Output "Log directory:     $env:YURUNA_LOG_DIR"

# --- REGION: Stale cycle-restart flag sweep
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

# --- REGION: Cycle-start caching-proxy gate
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
    if ($isExternal -and $vmIp) {
        # External handling below Remove-PortMaps this host's forwarders,
        # so it may only run when the endpoint is POSITIVELY not this
        # host. 'local': the "external" endpoint is this host's own
        # forwarder set fronting its NAT'd cache VM -- removing it severs
        # the very listeners that just answered the probe (self-teardown).
        # 'unknown': NIC churn from per-cycle VM start/stop can blank the
        # enumeration for a moment, and a wrong 'external' verdict tears
        # the forwarders down while a wrong 'local' verdict merely
        # re-asserts a port map -- so unknown must land on the local side.
        $ownVerdict = Get-HostOwnIpVerdict -IpAddress $vmIp
        if ($ownVerdict -ne 'nonlocal') {
            Write-Output "Caching proxy: YURUNA_CACHING_PROXY_IP ($vmIp) is not positively external (verdict: $ownVerdict) -- treating the cache as locally owned."
            $isExternal = $false
        }
    }
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
        } elseif (Test-HostOwnIpAddress -IpAddress $portMapIp) {
            # The target resolved no further than one of this host's own
            # addresses (no recorded cache-VM IP to tunnel to): a forwarder
            # aimed there would loop each port back onto its own listener.
            # Keep the port map that is currently serving traffic instead
            # of replacing it with a loop.
            $mapOk  = $true
            $bestIp = Get-BestHostIp
            if (-not $bestIp) { $bestIp = $vmIp }
        } else {
            $cacheHttpPort  = Get-CachingProxyPort -Scheme http
            $cacheHttpsPort = Get-CachingProxyPort -Scheme https
            # 9302 (caching-proxy-parser live tail) must stay in lockstep
            # with Start-CachingProxy.ps1's install list: Add-PortMap is
            # clear-all-first, so any port omitted here goes dark on
            # reinstall.
            $CachingProxyExposedPorts = if ($IsMacOS) { @(3000) } else { @(80, 3000, 9302, $cacheHttpPort, $cacheHttpsPort) }
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
    # A probe can miss for one cycle (cold socket-activated forwarder,
    # momentary host contention) while the cache behind this host's own
    # forwarders is perfectly healthy. When the operator's env still
    # names this host (or the ownership can't be positively ruled out),
    # removing the port map here strands guests on refused proxy ports
    # until a later cycle rebuilds it -- keep the forwarders instead.
    $envCacheIp = [string]$Env:YURUNA_CACHING_PROXY_IP
    if ($envCacheIp -and ((Get-HostOwnIpVerdict -IpAddress $envCacheIp) -ne 'nonlocal')) {
        Write-Output "Caching proxy: keeping existing port maps (YURUNA_CACHING_PROXY_IP '$envCacheIp' is not positively external; treating the probe miss as transient)."
    } else {
        [void](Remove-PortMap -Confirm:$false)
    }
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
if (-not (Assert-TesseractInstalled)) { exit $ExitFailure }

$startScript = Join-Path $TestRoot "Start-StatusService.ps1"
# Startup: no -Restart -- Start-YurunaStatusServiceIfEnabled lets the server
# compare-and-skip the relaunch when its in-memory code is still current (zero
# downtime on the common no-change cycle). The shared gate (Test.Prelude) keeps
# isEnabled / -NoServer / port handling identical across the entry-point trio.
$null = Start-YurunaStatusServiceIfEnabled -Config $Config -StartScript $startScript -NoServer:$NoServer

# NOTE: the Host Config Service (mTLS NAS-credential endpoint) is NOT started here.
# It is a companion of the CACHING PROXY (it serves NAS creds to the caching-proxy
# / stash VMs a host created), so its lifecycle belongs to Start-CachingProxy.ps1
# (Step 2.6) on the caching-proxy host -- not the test runner. A plain test-runner
# host that never brings up a caching proxy must not start it.

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
# The per-cycle work runs in Invoke-RunnerInnerCycle (Test.RunnerInnerLoop.psm1).
# The State hashtable threads paths, flags, the shared ShutdownState reference,
# and the config-reload state in, and carries the cycle outcome + gating
# counters back onto the locals the exit path below reads.
$cycleState = @{
    RepoRoot=$RepoRoot; TestRoot=$TestRoot; SequencesDir=$SequencesDir; ScreenshotsDir=$ScreenshotsDir
    StatusFile=$StatusFile; ConfigPath=$ConfigPath; TemplatePath=$TemplatePath; HostType=$HostType; ModulesDir=$ModulesDir
    NoServer=[bool]$NoServer; NoGitPull=[bool]$NoGitPull; NoProjectClone=[bool]$NoProjectClone; CycleDelaySeconds=$CycleDelaySeconds
    CachingProxyUrl=$cachingProxyUrl; StartScript=$startScript; StepHeartbeatFile=$StepHeartbeatFile
    ShutdownState=$script:ShutdownState; RunnerCfgState=$script:RunnerCfgState; Config=$script:Config
}
Invoke-RunnerInnerCycle -State $cycleState
$OverallPassed        = $cycleState.OverallPassed
$FailedGuest          = $cycleState.FailedGuest
$FailedStep           = $cycleState.FailedStep
$FailureMessage       = $cycleState.FailureMessage
$CycleId              = $cycleState.CycleId
$LogFile              = $cycleState.LogFile
$GitCommit            = $cycleState.GitCommit
$ProjectGitCommit     = $cycleState.ProjectGitCommit
$ConsecutiveFailures  = $cycleState.ConsecutiveFailures
$ConsecutiveSuccesses = $cycleState.ConsecutiveSuccesses
$ConsecutiveCrashes   = [int]$cycleState.ConsecutiveCrashes
$AlertArmed           = $cycleState.AlertArmed
$FailuresBeforeAlert  = $cycleState.FailuresBeforeAlert
$GatingFile           = $cycleState.GatingFile

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
        consecutiveCrashes   = $ConsecutiveCrashes
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
try { Stop-RunnerHeartbeat } catch { $null = $_ }
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
        # Advisory remediation dispatch (same as the in-cycle path): computes
        # the recommendation, emits the NDJSON breadcrumb, and persists the
        # durable last_remediation.json into the cycle folder (replicated to the
        # pool). Records the decision; never acts. Skip the planner-abort case
        # (FailedGuest '(planner)' / PlannerFatal): a duplicate-sequence config
        # error is never auto-remediable and would only route to
        # operator_intervention_required.
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
        consecutiveCrashes   = $ConsecutiveCrashes
        alertArmed           = $AlertArmed
        savedAt              = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
} catch {
    Write-Verbose "Final gating-state save failed (best-effort, ignoring): $($_.Exception.Message)"
}

$finalCode = ($OverallPassed ? $ExitOk : $ExitFailure)
Write-InnerLog "about to exit with code $finalCode"
exit $finalCode
