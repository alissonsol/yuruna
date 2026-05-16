<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456706
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
    Continuous test cycle entry point. See test/README.md for the
    cycle flow, config schema, notifications, and YURUNA_CACHING_PROXY_IP;
    see test/CODE.md for harness architecture.

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

# Severity rank used by the cascade. Lower = higher priority. Error is
# always shown (the env var YURUNA_LOG_LEVEL exists so children can apply
# the same map; we don't override $ErrorActionPreference because it also
# governs `-ErrorAction Stop` semantics that scripts rely on).
$script:LogLevelRank = @{
    Error       = 1
    Warning     = 2
    Information = 3
    Verbose     = 4
    Debug       = 5
}

# Resolve effective level + apply preference cascade + publish env var.
# Called (a) at startup with cmdline-only data, (b) after Update-Test-
# ConfigFromTemplate loads $script:Config, and (c) at the end of every
# Sync-RuntimeConfig so a JSON edit takes effect on the next step's
# child processes via $env:YURUNA_LOG_LEVEL.
function Resolve-LogLevel {
    [CmdletBinding()]
    param()
    $cfg = $script:Config
    $hasCfg = $cfg -is [System.Collections.IDictionary]
    $effective = if ($script:CmdLineLogLevel) {
        $script:CmdLineLogLevel
    } elseif ($hasCfg -and $cfg.Contains('logLevel') -and $cfg.logLevel) {
        [string]$cfg.logLevel
    } else { 'Information' }

    # Normalize case. Reject anything not in the valid set; fall back to
    # 'Information' so a typo in JSON still surfaces step-level output.
    $valid = @('Error','Warning','Information','Verbose','Debug')
    $matched = $valid | Where-Object { $_ -ieq $effective } | Select-Object -First 1
    if (-not $matched) {
        Write-Warning "logLevel '$effective' is not one of $($valid -join ', '); falling back to 'Information'."
        $matched = 'Information'
    }
    $effective = $matched
    $effRank   = $script:LogLevelRank[$effective]

    # Stream visibility cascade. $ErrorActionPreference is intentionally
    # left at its inherited default ('Continue') — even at logLevel='Error'/'Information'
    # we want errors visible, and lowering it would also hide them.
    $global:WarningPreference     = if ($script:LogLevelRank.Warning     -le $effRank) { 'Continue' } else { 'SilentlyContinue' }
    $global:InformationPreference = if ($script:LogLevelRank.Information -le $effRank) { 'Continue' } else { 'SilentlyContinue' }
    $global:VerbosePreference     = if ($script:LogLevelRank.Verbose     -le $effRank) { 'Continue' } else { 'SilentlyContinue' }
    $global:DebugPreference       = if ($script:LogLevelRank.Debug       -le $effRank) { 'Continue' } else { 'SilentlyContinue' }
    # Verbose and below want a quiet progress bar — Write-Progress
    # otherwise overwrites the per-poll OCR debug lines and makes the
    # transcript unreadable.
    if ($effRank -ge $script:LogLevelRank.Verbose) {
        $global:ProgressPreference = 'SilentlyContinue'
    }

    $env:YURUNA_LOG_LEVEL = $effective
}

# Initial pass: cmdline-only (test.config.yml hasn't been loaded yet).
# Subsequent passes happen right after Update-TestConfigFromTemplate and
# at the end of every Sync-RuntimeConfig.
Resolve-LogLevel

# === Resolve paths ===
# Track/log dirs come from Test.TrackDir / Test.LogDir; override with
# $env:YURUNA_TRACK_DIR / $env:YURUNA_LOG_DIR. Defaults: test/status/track/
# and test/status/log/, both served by the status HTTP server.
# This script lives under test/modules/ (kept out of test/'s entry-point
# layer so operators never run it directly -- the outer runner is the
# only legitimate caller). $PSScriptRoot is therefore test/modules/, and
# $TestRoot has to walk one level up to reach test/.
$ModulesDir     = $PSScriptRoot
$TestRoot       = Split-Path -Parent $ModulesDir
$RepoRoot       = Split-Path -Parent $TestRoot
$StatusDir      = Join-Path $TestRoot "status"
$StatusTmpl     = Join-Path $StatusDir "status.json.template"
$ScreenshotsDir = Join-Path $TestRoot "screenshots"
$SequencesDir   = Join-Path $TestRoot "sequences"

Import-Module (Join-Path $ModulesDir "Test.TrackDir.psm1") -Force
Import-Module (Join-Path $ModulesDir "Test.LogDir.psm1")   -Force
# Authentication extension loader. Imported here so each cycle's
# Initialize-VaultConnection / Clear-VaultStorage / Get-Password call
# resolves without per-call importing.
Import-Module (Join-Path $ModulesDir "Test.Extension.psm1") -Global -Force
$null = Initialize-YurunaTrackDir
$null = Initialize-YurunaLogDir
$StatusFile = Join-Path $env:YURUNA_TRACK_DIR "status.json"

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
        Add-Content -LiteralPath (Join-Path $env:YURUNA_TRACK_DIR 'outer.log') `
            -Value "$stamp [inner] $Message" -Encoding utf8 -ErrorAction Stop
    } catch {
        Write-Verbose "outer.log write failed (non-fatal): $($_.Exception.Message)"
    }
}

if (-not $ConfigPath) { $ConfigPath = Join-Path $TestRoot "test.config.yml" }
$TemplatePath = Join-Path $TestRoot "test.config.yml.template"

# === Single-instance guard ===
# Defensive: if another Invoke-TestRunner.ps1 (the outer) is running,
# stop it and wipe stranded test VMs. The normal call path is the
# outer spawning THIS inner with YURUNA_RUNNER_RELAUNCH=1 -- in which
# case this whole block is skipped (the outer owns the pidfile). This
# branch only fires when an operator invokes modules/Invoke-Test-
# InnerRunner.ps1 directly (which they shouldn't -- it lives under
# modules/ for that reason, but the guard is the safety net for when
# they do). Two instances race on VM names and shared status files,
# leaving VMs stuck in Starting/Stopping state.
$RunnerPidFile = Join-Path $env:YURUNA_TRACK_DIR "runner.pid"
if ($env:YURUNA_RUNNER_RELAUNCH -ne '1' -and (Test-Path $RunnerPidFile)) {
    $existingPid = 0
    # Unreadable/malformed/missing pidfile treated as "no prior runner";
    # Get-Process 0 returns null so the branch is a safe no-op.
    try { $existingPid = [int]((Get-Content $RunnerPidFile -Raw -ErrorAction Stop).Trim()) } catch { $existingPid = 0 }
    if ($existingPid -gt 0 -and $existingPid -ne $PID -and (Get-Process -Id $existingPid -ErrorAction SilentlyContinue)) {
        # Verify the PID is an Invoke-TestRunner.ps1 — don't kill a process
        # that recycled this PID. Windows uses CIM; macOS/Linux use
        # /bin/ps (path-qualified so PSSA doesn't confuse it with the `ps`
        # alias for Get-Process — we need `-o args=` which Get-Process
        # can't produce portably on Unix).
        $cmd = $null
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
        if ($cmd -and $cmd -match 'Invoke-TestRunner\.ps1') {
            Write-Output ""
            Write-Output "============================================="
            Write-Output "  Another Invoke-TestRunner.ps1 is running"
            Write-Output "  PID:     $existingPid"
            Write-Output "  Action:  stopping it and running"
            Write-Output "           Remove-TestVMFiles.ps1 before start"
            Write-Output "============================================="
            Stop-Process -Id $existingPid -Force -ErrorAction SilentlyContinue
            # Wait for the old process to die so its Hyper-V/UTM VM ops
            # can't race with ours.
            for ($i = 0; $i -lt 20; $i++) {
                if (-not (Get-Process -Id $existingPid -ErrorAction SilentlyContinue)) { break }
                Start-Sleep -Milliseconds 500
            }
            try {
                $cleanup = Join-Path $TestRoot "Remove-TestVMFiles.ps1"
                if (Test-Path $cleanup) {
                    # Use 'test-' (template default): test.config.yml
                    # hasn't been merged yet, so we can't read a user
                    # override. If the user picked a custom prefix this
                    # cleanup is a no-op — same as if the guard didn't run.
                    & pwsh -NoProfile -File $cleanup -Prefix 'test-'
                }
            } catch {
                Write-Warning "Remove-TestVMFiles.ps1 failed during single-instance takeover: $_"
            }
        } else {
            Write-Warning "Stale runner.pid: PID $existingPid is not an Invoke-TestRunner.ps1 process. Ignoring."
        }
    }
    Remove-Item $RunnerPidFile -Force -ErrorAction SilentlyContinue
}
# When the outer Invoke-TestRunner.ps1 spawned us (YURUNA_RUNNER_RELAUNCH=1),
# leave the pidfile alone -- the outer owns the lock for the whole run.
# Standalone (direct) invocation owns its own pidfile.
if ($env:YURUNA_RUNNER_RELAUNCH -ne '1') {
    $PID | Set-Content -Path $RunnerPidFile -Encoding ascii
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

# Top-level module list, reused at startup AND at the start of every cycle on
# macOS (see the re-import block after `Invoke-GitPull` in the cycle loop).
# Windows chains a fresh pwsh per cycle via Start-Process so modules reload
# automatically there; the macOS in-process loop reuses cached modules
# unless we explicitly force-reload, which means a mid-run `git pull` never
# propagates source changes to the running cycles.
$script:RunnerModules = @("Test.Host", "Test.Status", "Test.Notify", "Test.Provenance", "Test.Start-GuestOS", "Test.Start-GuestWorkload", "Test.Log", "Test.SequencePlanner")
foreach ($mod in $script:RunnerModules) {
    $modPath = Join-Path $ModulesDir "$mod.psm1"
    if (-not (Test-Path $modPath)) { Write-Error "Module not found: $modPath"; exit 1 }
    Import-Module -Name $modPath -Force
}

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
# is added out-of-band by the notification-credentials path). A flat,
# pre-nesting test.config.yml (vmBootDelaySeconds, frameworkRepoUrl, ...
# at the root — historical flat-layout names that have since moved to
# vmStart.bootDelaySeconds, repositories.frameworkUrl, etc.) fails both
# tests. Leaf values are NOT compared -- only
# container structure -- so any operator-set value passes.
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
        exit 1
    }

    # 2026-05 migration to test/extension/notification/notification.transports.yml:
    # secrets.resend and notification.toEmailAddress no longer live in
    # test.config.yml. The merge (ConvertTo-MergedHashtable) drops
    # template-orphan keys, so populated legacy values would vanish
    # silently -- warn the operator to move them by hand before the
    # merge takes effect. Soft migration: do NOT auto-move credentials
    # across files.
    $notifConfigPath = Join-Path (Split-Path -Parent $ConfigPath) 'extension/notification/notification.transports.yml'
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
            Write-Warning "test.config.yml contains legacy notification settings (secrets.resend / notification.toEmailAddress) that have moved to test/extension/notification/notification.transports.yml. Copy notification.transports.yml.template to notification.transports.yml and populate transports.resend + subscribers BEFORE the next cycle, otherwise notifications will silently no-op."
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

function Sync-RuntimeConfig {
<#
.SYNOPSIS
Re-reads test.config.yml mid-cycle so values changed via the status
server's "Edit config" page take effect on the next step rather than
waiting for the next git pull / next cycle.
.DESCRIPTION
Updates the script-scoped $Config and re-derives the cycle-relevant
locals that drive subsequent step behaviour:
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

    try {
        $script:Config = Get-Content -Raw $ConfigPath -ErrorAction Stop | ConvertFrom-Yaml -Ordered -ErrorAction Stop
    } catch {
        Write-Warning "Config reload from '$ConfigPath' failed: $_ -- keeping previous values."
        return
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
    Write-Error "Neither config nor template found. Config: $ConfigPath  Template: $TemplatePath"; exit 1
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

# Wire the host driver. After this call the contract functions
# (New-VM, Start-VM, Stop-VM, Send-Text, Get-VMScreenshot, ...) are
# resolvable from this script's session without any HostType branches.
[void](Initialize-YurunaHost -RepoRoot $RepoRoot -HostType $HostType)

if (-not (Assert-HostConditionSet -HostType $HostType)) { exit 1 }

Write-Output "Track directory: $env:YURUNA_TRACK_DIR"
Write-Output "Log directory:   $env:YURUNA_LOG_DIR"

# Proxy-cache detection lives in Test.CachingProxy.psm1 so Start-StatusServer
# shares the same probe — console banner here and the status-page banner
# (via $env:YURUNA_TRACK_DIR/caching-proxy.txt) stay in lockstep with the
# URL injected into autoinstall user-data by guest.ubuntu.server/New-VM.ps1.
$cachingProxyUrl = Test-CachingProxyAvailable

# Local cache detected: expose the VM's ports on the host so LAN clients
# and other machines can reach the proxy, ssl-bump listener, Apache CA
# cert, and Grafana dashboard without reaching into the VM's NAT subnet.
# Add-CachingProxyPortMap dispatches per-platform via Test.PortMap.psm1
# (netsh portproxy + firewall rule on Hyper-V; detached TcpListener
# forwarders on macOS/UTM). No cache: undo any mapping a prior cycle left.
#
# Windows: port lists across callers MUST match — Add-CachingProxyPortMap
# runs Clear-AllCachingProxyPortMapping first (netsh), so any omitted port
# gets torn down. macOS: per-port pidfiles mean callers manage subsets
# independently. Port 80 (<1024) is excluded on macOS — it is privileged
# and managed exclusively by Start-CachingProxy.ps1 (see below).
# Local guests reach the VM directly on its NAT subnet regardless.
#
# External-cache branch: when $Env:YURUNA_CACHING_PROXY_IP is set,
# Test-CachingProxyAvailable returns the remote URL and the remote host
# serves all four ports. Guests reach it via the host's outbound NAT —
# no local portproxy/forwarder needed. Skip Add-CachingProxyPortMap and
# link the dashboard directly at the remote IP. Remove leftover mappings
# from a prior local-cache cycle so the old VM IP doesn't answer stale
# proxy requests.
#
# The "detected" word is an ANSI OSC 8 hyperlink to the Grafana dashboard
# so modern terminals (Windows Terminal, VS Code) can ctrl-click into the
# caching-proxy view. Terminals without OSC 8 drop the escapes silently —
# no regression.
if ($cachingProxyUrl) {
    $vmIp = if ($cachingProxyUrl -match '^http://([0-9.]+):') { $matches[1] } else { $null }
    $isExternal = [bool]$Env:YURUNA_CACHING_PROXY_IP
    $mapOk  = $false
    $bestIp = $null
    if ($isExternal) {
        # Remote cache serves its own ports; clear any local mapping
        # left by a prior cycle, then point the dashboard at the remote.
        # Install VMs default to Yuruna-External (see each guest's
        # New-VM.ps1) so they sit on the LAN and reach the remote IP
        # directly without any host-side forwarder. The operator's
        # browser also hits the remote URL directly. (Don't assume
        # Hyper-V Default Switch's NAT will route to LAN destinations
        # for fallback VMs -- empirically it requires `IPEnableRouter=1`,
        # which the runner doesn't toggle. The Yuruna-External default
        # avoids the need.)
        [void](Remove-PortMap -Confirm:$false)
        $mapOk  = $true
        $bestIp = $vmIp
    } elseif ($vmIp) {
        # On macOS the detection URL is the VZ gateway (192.168.64.1),
        # not the cache VM's real IP. Add-CachingProxyPortMap needs the
        # real IP so forwarders tunnel to squid rather than looping back.
        # Get-CachingProxyVMIp reads the yuruna-caching-proxy state file
        # via Test.CachingProxy; on Windows the URL already carries the
        # cache VM's IP so we fall through.
        $portMapIp = Get-CachingProxyVMIp
        if (-not $portMapIp) { $portMapIp = $vmIp }

        # Yuruna-External vSwitch fast path: when the cache VM is bridged
        # to LAN, install VMs (which also prefer Yuruna-External -- see
        # each guest's New-VM.ps1) sit on the same LAN segment and reach
        # the cache directly at its DHCP-assigned LAN IP. squid sees the
        # real client IP at TCP level; no host-side forwarder, no
        # PROXY-protocol header, no portproxy. Tear down any leftover
        # netsh portproxy from a prior Default-Switch cycle so it can't
        # silently NAT-rewrite a parallel path. The dashboard URL points
        # at the cache VM's own LAN IP; Get-BestHostIp would point at
        # the host, which is no longer the proxy entry point.
        #
        # Note: Default Switch's NAT does NOT route to LAN destinations
        # without `IPEnableRouter=1` (the engine isn't a separate kernel
        # bypass like the Hyper-V private-network switches). An install
        # VM that falls back to Default Switch while the cache stays on
        # Yuruna-External would not be able to reach the cache -- which
        # is why the install scripts default to Yuruna-External and only
        # fall back to Default Switch when External cannot be created
        # (no LAN, Wi-Fi-only). In that fallback case the cache also
        # lands on Default Switch (same Get-OrCreateYurunaExternalSwitch
        # logic), so this fast path is FALSE and the portproxy branch
        # below handles cross-network reachability.
        # Yuruna.Host's Test-CacheVMOnExternalNetwork checks for any
        # External-type vSwitch on Windows; on macOS it always returns
        # $true (VMnet shared). No host-conditional needed at the caller.
        $cacheOnExternalSwitch = [bool](Test-CacheVMOnExternalNetwork)
        if ($cacheOnExternalSwitch) {
            [void](Remove-PortMap -Confirm:$false)
            $mapOk  = $true
            $bestIp = $vmIp
        } else {
            # Default-Switch fallback: squid lives on the same NAT as
            # the install VMs but doesn't accept LAN clients directly.
            # Forward host:port -> cache:port for LAN reachability.
            #
            # On Windows: port 80 is included -- netsh portproxy clears
            # ALL ports at once (Clear-AllCachingProxyPortMapping), so
            # every port the host should expose must appear in every
            # caller's list. On macOS: each port is managed independently
            # (per-port pidfile). Port 80 (<1024) requires root;
            # Start-CachingProxy.ps1 is the only caller that pre-caches
            # sudo, so leave :80 out here.
            # HTTP / HTTPS port mapping is platform-divergent:
            #   * macOS: host:HTTP -> VM:3138 / host:HTTPS -> VM:3139 via
            #     userspace pwsh forwarder + PROXY v1 -- squid logs real
            #     client IPs via the PROXY v1 header.
            #   * Windows: host:HTTP -> VM:HTTP / host:HTTPS -> VM:HTTPS
            #     via plain netsh portproxy.
            # HTTP/HTTPS port values come from YURUNA_CACHING_PROXY_*_PORT
            # env vars (defaults 3128 / 3129 -- match squid's stock config).
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
        $dashboardUrl   = "http://${bestIp}:3000/d/yuruna-squid/squid-cache-yuruna?orgId=1&from=now-2h&to=now&timezone=browser&refresh=1m"
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

$startScript = Join-Path $TestRoot "Start-StatusServer.ps1"
if ($Config.statusServer.isEnabled -and -not $NoServer) {
    $serverPort  = $Config.statusServer.port ? [int]$Config.statusServer.port : 8080
    & $startScript -Port $serverPort -Restart
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
# different SSID/subnet mid-cycle. The squid-cache VM is on the host's
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
        $cycleBase   = Split-Path -Leaf $global:__YurunaCycleFolder

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
        $srcSequenceDir = Join-Path $env:YURUNA_LOG_DIR "screens_${VMName}"
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
        Write-Warning "$($pair.Label) repo at $($pair.Path) has $($lines.Count) uncommitted change(s); $($pair.Endpoint) is built from ``git archive HEAD`` and will NOT include them. Guests will see committed content while the host runs working-tree code."
        foreach ($l in ($lines | Select-Object -First 10)) { Write-Warning "    $l" }
        if ($lines.Count -gt 10) { Write-Warning "    ... and $($lines.Count - 10) more" }
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
# in the track dir. Without this, every inner would start fresh-armed
# and a flapping host would email on every cycle. Outer-launched runs
# (YURUNA_RUNNER_RELAUNCH=1) load + save; standalone direct-invoke runs
# also load + save so the operator can Ctrl+C and resume without losing
# the gating context.
$FailuresBeforeAlert  = [int]($Config.notification.failuresBeforeAlert  ?? 1)
$SuccessesBeforeRearm = [int]($Config.notification.successesBeforeRearm ?? 1)
$ConsecutiveFailures  = 0
$ConsecutiveSuccesses = 0
$AlertArmed           = $true
$GatingFile = Join-Path $env:YURUNA_TRACK_DIR 'runner.gating.json'
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

    # --- Host SSH server: drive state from config via the extension ---
    # The hostSshServer.enabled config key replaces the dashboard's old
    # SSH toggle button. Apply the operator's declared intent through the
    # host-ssh-server extension (default provider delegates to the
    # Yuruna.Host SSH contract). Absent config block = leave SSH state
    # alone, preserving backward compat with older test.config.yml files.
    if ($Config.Contains('hostSshServer') -and $Config.hostSshServer -is [System.Collections.IDictionary] -and $Config.hostSshServer.Contains('enabled')) {
        try {
            [void](Import-Extension -Area 'host-ssh-server' -RequireSingle)
            $sshIntent = [bool]$Config.hostSshServer.enabled
            $sshResult = if ($sshIntent) { Enable-SshServer -Confirm:$false } else { Disable-SshServer -Confirm:$false }
            $verb = if ($sshIntent) { 'enable' } else { 'disable' }
            if ($sshResult.ok) {
                Write-Output "Host SSH server ${verb}: supported=$($sshResult.supported), installed=$($sshResult.installed), enabled=$($sshResult.enabled)"
            } else {
                Write-Warning "Host SSH server ${verb} reported not-ok: $($sshResult.message)"
            }
        } catch {
            Write-Warning "host-ssh-server extension init/apply failed: $($_.Exception.Message). Continuing; SSH state on this host is unchanged."
        }
    }

    # --- Reset status.json so the dashboard stops showing the previous
    # cycle's pass/fail + per-guest pills while the slow setup below
    # (git pull, project clone, status-server restart, module re-imports,
    # cycle-plan resolution) runs. Initialize-StatusDocument later
    # populates the fully-shaped doc once the guest list is known.
    Reset-StatusDocumentForCycleStart -StatusFilePath $StatusFile -Confirm:$false

    # --- Git pull ---
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
            $body = Format-FailureMessage `
                -HostType     $HostType `
                -Hostname     (hostname) `
                -GuestKey     "(bootstrap)" `
                -StepName     "GitPull" `
                -ErrorMessage "Git sync failed. Branch may have diverged, or network is unreachable." `
                -CycleId      "(not yet assigned)" `
                -GitCommit    (Get-CurrentGitCommit -RepoRoot $RepoRoot)
            Send-Notification -EventCode    'cycle.failure' `
                              -EventMessage "Yuruna Test: FAIL on $HostType / GitPull" `
                              -EventNote    $body
            exit 1
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
    $cloneRes = Update-ProjectClone -RepoRoot $RepoRoot -ProjectUrl $projUrl -Confirm:$false
    if (-not $cloneRes.success) {
        Write-Warning "Project clone failed: $($cloneRes.errorMessage). Retrying next cycle."
        $body = Format-FailureMessage `
            -HostType     $HostType `
            -Hostname     (hostname) `
            -GuestKey     "(bootstrap)" `
            -StepName     "ProjectClone" `
            -ErrorMessage $cloneRes.errorMessage `
            -CycleId      "(not yet assigned)" `
            -GitCommit    $GitCommit
        Send-Notification -EventCode    'cycle.failure' `
                          -EventMessage "Yuruna Test: FAIL on $HostType / ProjectClone" `
                          -EventNote    $body
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
    # per cycle for 13 module reloads — cheap insurance and the same code
    # path on both platforms is easier to reason about.
    foreach ($mod in $script:RunnerModules) {
        $modPath = Join-Path $ModulesDir "$mod.psm1"
        if (Test-Path $modPath) { Import-Module -Name $modPath -Force }
    }
    # Re-call Initialize-YurunaHost so the host driver (Yuruna.Host.psm1)
    # AND the cross-host helpers (Test.VM.common.psm1 -- Wait-VMRunning,
    # Test-IpAddress, ...) are re-imported with -Global on every cycle.
    # Without this, anything that wipes the runner's session mid-cycle
    # (a sequence step calling Get-Module | Remove-Module, a transitive
    # Import-Module without -Global, etc.) leaves the runner unable to
    # find Wait-VMRunning at the next New-VM.Resource step -- the symptom that
    # drove this defense was a long-running macOS in-process runner
    # crashing at cycle 729 with "Wait-VMRunning is not recognized".
    [void](Initialize-YurunaHost -RepoRoot $RepoRoot -HostType $HostType)

    # --- Re-read config (may have changed via git pull); sync against template ---
    try {
        $Config = Update-TestConfigFromTemplate -ConfigPath $ConfigPath -TemplatePath $TemplatePath
    } catch {
        Write-Warning "Could not reload config after git pull, using previous config: $_"
    }

    # --- Restart status server to pick up any file/config changes ---
    if ($Config.statusServer.isEnabled -and -not $NoServer) {
        $serverPort = $Config.statusServer.port ? [int]$Config.statusServer.port : 8080
        & $startScript -Port $serverPort -Restart
    }

    # Build per-cycle execution plan from project/test/test.sequence.yml.
    # Each plan entry is a (top-level workload, guest, sequence chain) tuple;
    # multiple top-levels can share a guest, so we dedupe to GuestList for
    # the parts of the cycle that operate per unique VM (folder check,
    # Get-Image, the cleanup → create → start → verify per-guest loop).
    # Falls back to the legacy guestSequence list when the cycle config is
    # missing — useful before the project repo clone bootstrap lands and
    # for operators who haven't migrated yet.
    $script:CyclePlan = $null
    try {
        $script:CyclePlan = Resolve-CyclePlan -RepoRoot $RepoRoot -SequencesDir $SequencesDir -HostType $HostType
    } catch {
        Write-Warning "Could not resolve cycle plan from project/test/test.sequence.yml - falling back to guestSequence: $($_.Exception.Message)"
    }
    if ($script:CyclePlan -and $script:CyclePlan.Count -gt 0) {
        $GuestList = Get-CyclePlanGuestList -Plan $script:CyclePlan
        Write-Output "Cycle plan: $($script:CyclePlan.Count) entries across $($GuestList.Count) guest(s)."
    } else {
        $GuestList = Get-GuestList -Config $Config
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
    # the post-prep verification (formerly "Verify-VM"), kept distinct from
    # the "New-VM" definition step. The HTML collapses the New-VM /
    # Start-VM / New-VM.Resource triplet into a single tile.
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
        -StepNames      $StepNames

    # --- Seed per-guest provenance so the UI shows the actual ISO filename
    # (e.g. "ubuntu-24.04.4-live-server-amd64.iso") instead of "guest.ubuntu.server".
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
    $LogFile = Start-LogFile -TestRoot $TestRoot -CycleId $CycleId -Hostname (hostname) -GitCommit $GitCommit -CycleNumber $CycleNumber
    Write-Output "Log file: $LogFile"

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
        Stop-LogFile
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
        Stop-LogFile
        break
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
            Write-Output "=== $GuestKey (skipped — earlier failure) ==="
            continue
        }
        $VMName = $VMNames[$GuestKey]
        $script:ActiveVMName = $VMName
        Write-Output ""
        Write-Output "=== $GuestKey (VM: $VMName) ==="

        # Eagerly create this guest's cycleGuestDataFolder so the
        # dashboard tile has a destination to link to from the start of
        # the iteration -- not only after a failure produces files.
        # Get-CycleGuestDataFolder mkdir's it on demand. The URL is
        # recorded on the live status doc immediately so the live UI
        # makes the tile clickable mid-cycle too.
        $guestFolderPath = Get-CycleGuestDataFolder -VMName $VMName
        if ($guestFolderPath) {
            $cycleBaseName  = Split-Path -Leaf $global:__YurunaCycleFolder
            Set-GuestFailureArtifact -GuestKey $GuestKey -RelativeUrl "log/$cycleBaseName/$VMName/"
        }

        # --- Cleanup previous VM ---
        $savedProgress = $global:ProgressPreference
        $global:ProgressPreference = 'SilentlyContinue'
        Remove-VM -VMName $VMName -Confirm:$false | Out-Null
        $global:ProgressPreference = $savedProgress

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
        $r = New-VM -GuestKey $GuestKey -RepoRoot $RepoRoot -VMName $VMName -CachingProxyUrl $newVmProxy -Confirm:$false
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
            continue
        }

        # --- Start-GuestOS (start.guest.* sequences from the cycle plan) ---
        Assert-CachingProxyStillReachable -ProxyUrl $cachingProxyUrl -StepName "Start-GuestOS" -GuestKey $GuestKey
        Set-StepStatus -GuestKey $GuestKey -StepName "Start-GuestOS" -Status "running"
        $startSeqs = @()
        $workSeqs  = @()
        if ($script:CyclePlan -and $script:CyclePlan.Count -gt 0) {
            $merged    = Get-CyclePlanSequencesForGuest -Plan $script:CyclePlan -GuestKey $GuestKey
            $startSeqs = @($merged.startSequences)
            $workSeqs  = @($merged.workloadSequences)
        }
        $r = Start-GuestOS -HostType $HostType -GuestKey $GuestKey -VMName $VMName -RepoRoot $RepoRoot -SequencesDir $SequencesDir -SequenceNames $startSeqs
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
            $savedProgress = $global:ProgressPreference
            $global:ProgressPreference = 'SilentlyContinue'
            Stop-VM -VMName $VMName -Confirm:$false | Out-Null
            Remove-VM -VMName $VMName -Confirm:$false | Out-Null
            $global:ProgressPreference = $savedProgress
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
            $savedProgress = $global:ProgressPreference
            $global:ProgressPreference = 'SilentlyContinue'
            Stop-VM -VMName $VMName -Confirm:$false | Out-Null
            Remove-VM -VMName $VMName -Confirm:$false | Out-Null
            $global:ProgressPreference = $savedProgress
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
                $savedProgress = $global:ProgressPreference
                $global:ProgressPreference = 'SilentlyContinue'
                Stop-VM -VMName $VMName -Confirm:$false | Out-Null
                Remove-VM -VMName $VMName -Confirm:$false | Out-Null
                $global:ProgressPreference = $savedProgress
                continue
            }
        }

        # --- Start-GuestWorkload (workload sequences from the cycle plan) ---
        if ($hasExtensions) {
            Assert-CachingProxyStillReachable -ProxyUrl $cachingProxyUrl -StepName "Start-GuestWorkload" -GuestKey $GuestKey
            Set-StepStatus -GuestKey $GuestKey -StepName "Start-GuestWorkload" -Status "running"
            $r = Start-GuestWorkload -HostType $HostType -GuestKey $GuestKey -VMName $VMName -RepoRoot $RepoRoot -SequencesDir $SequencesDir -SequenceNames $workSeqs
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
                $savedProgress = $global:ProgressPreference
                $global:ProgressPreference = 'SilentlyContinue'
                Stop-VM -VMName $VMName -Confirm:$false | Out-Null
                Remove-VM -VMName $VMName -Confirm:$false | Out-Null
                $global:ProgressPreference = $savedProgress
                continue
            }
        }

        # --- Stop and remove this guest VM before starting the next ---
        Set-GuestStatus -GuestKey $GuestKey -Status "pass"
        Write-Output "  ${GuestKey}: PASS"
        # Guest passed → discard the per-VM ring-buffer of pre-OCR screen
        # captures. On any prior failure path this directory is preserved
        # (Copy-FailureArtifactsToStatusLog copies it before we get here).
        $screensDir = Join-Path $env:YURUNA_LOG_DIR "screens_${VMName}"
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

    # Vault cleanup: wipe vault.yml on successful cycles only.
    # A failed cycle leaves the file (in plaintext, gitignored) for
    # debugging; the next successful cycle's cleanup removes it.
    if ($OverallPassed) {
        try { Clear-VaultStorage } catch { Write-Verbose "Clear-VaultStorage failed (best-effort): $($_.Exception.Message)" }
    }

    Complete-Run -OverallStatus $FinalStatus -MaxHistoryRuns ([int]$Config.testCycle.recentDisplayCount)
    Stop-LogFile
    $script:CycleFinalized = $true

    Write-Output ""
    Write-Output "=== Cycle $CycleCount complete: $FinalStatus ==="

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
                $body = Format-FailureMessage `
                    -HostType     $HostType `
                    -Hostname     (hostname) `
                    -GuestKey     $FailedGuest `
                    -StepName     $FailedStep `
                    -ErrorMessage $FailureMessage `
                    -CycleId      $CycleId `
                    -GitCommit    $GitCommit
                Send-Notification -EventCode    'cycle.failure' `
                                  -EventMessage "Yuruna Test: FAIL on $HostType / $FailedGuest / $FailedStep" `
                                  -EventNote    $body
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
            $savedProgress = $global:ProgressPreference
            $global:ProgressPreference = 'SilentlyContinue'
            Stop-VM -VMName $script:ActiveVMName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            Remove-VM -VMName $script:ActiveVMName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            $global:ProgressPreference = $savedProgress
        } catch { Write-Warning "  Emergency VM cleanup failed: $_" }
        $script:ActiveVMName = $null
    }

    if (-not $script:CycleFinalized) {
        try {
            Complete-Run -OverallStatus "fail" -MaxHistoryRuns ([int]$Config.testCycle.recentDisplayCount) -ErrorAction SilentlyContinue
            Stop-LogFile -ErrorAction SilentlyContinue
        } catch { Write-Warning "  Emergency cycle finalization failed: $_" }
        $script:CycleFinalized = $true
    }

    if ($ConsecutiveCrashes -ge $MaxConsecutiveCrashes) {
        Write-Output "  $ConsecutiveCrashes consecutive unhandled errors — aborting."
        $OverallPassed = $false
        break
    }
    Write-Output "  Will retry next cycle ($ConsecutiveCrashes/$MaxConsecutiveCrashes consecutive errors)."
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
        & (Join-Path $TestRoot "Remove-TestVMFiles.ps1") -Prefix $Prefix
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
    # endpoint creates $env:YURUNA_TRACK_DIR/control.cycle-pause. Gate
    # here — AFTER cleanup, BEFORE the inter-cycle wait — so the UI's
    # "Cycle pause" stops the runner at the cycle boundary with VMs torn
    # down. /control/cycle-resume removes the file and the loop proceeds
    # to the normal wait. ShutdownState is checked alongside so Ctrl-C
    # still breaks out of the wait.
    $cyclePauseFlagFile = Join-Path $env:YURUNA_TRACK_DIR 'control.cycle-pause'
    if (Test-Path $cyclePauseFlagFile) {
        Write-Output "Cycle pause set via status UI. Waiting for resume..."
        while ((Test-Path $cyclePauseFlagFile) -and (-not $script:ShutdownState['Requested'])) {
            Start-Sleep -Seconds 1
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
        $delayStart    = Get-Date
        $delayDeadline = $delayStart.AddSeconds($effectiveDelay)
        $nextTick      = 0
        try {
            while ((Get-Date) -lt $delayDeadline -and -not $script:ShutdownState['Requested']) {
                if (Test-Path $cyclePauseFlagFile) { break }
                $remainingSec = [math]::Max(0, [int]($delayDeadline - (Get-Date)).TotalSeconds)
                $elapsedSec   = [int]((Get-Date) - $delayStart).TotalSeconds
                $percent      = [math]::Min(100, [math]::Max(0, [int](($elapsedSec * 100) / $effectiveDelay)))
                Write-Progress -Id $delayId `
                    -Activity "[cycle $CycleCount] inter-cycle delay" `
                    -Status  ("$remainingSec s remain (of $effectiveDelay s)") `
                    -PercentComplete $percent `
                    -SecondsRemaining $remainingSec
                if ($elapsedSec -ge $nextTick) {
                    Write-Output "  [cycle $CycleCount] $remainingSec s remain..."
                    $nextTick = $elapsedSec + 5
                }
                Start-Sleep -Seconds 1
            }
        } finally {
            Write-Progress -Id $delayId -Activity 'inter-cycle delay' -Completed
        }
        Write-Output "[cycle $CycleCount] cycleDelaySeconds wait complete -- exiting inner; outer will respawn. (local time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))"
        Write-InnerLog "[cycle $CycleCount] cycleDelaySeconds wait complete -- entering exit path"
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
    @{
        consecutiveFailures  = $ConsecutiveFailures
        consecutiveSuccesses = $ConsecutiveSuccesses
        alertArmed           = $AlertArmed
        savedAt              = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $GatingFile -Encoding utf8
} catch {
    Write-Verbose "Gating-state save failed (best-effort, ignoring): $($_.Exception.Message)"
}
Write-InnerLog "post-loop cleanup: gating state saved"

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
        $body = Format-FailureMessage `
            -HostType     $HostType `
            -Hostname     (hostname) `
            -GuestKey     $FailedGuest `
            -StepName     $FailedStep `
            -ErrorMessage $FailureMessage `
            -CycleId      $CycleId `
            -GitCommit    $GitCommit
        Send-Notification -EventCode    'cycle.failure' `
                          -EventMessage "Yuruna Test: FAIL on $HostType / $FailedGuest / $FailedStep" `
                          -EventNote    $body
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
    @{
        consecutiveFailures  = $ConsecutiveFailures
        consecutiveSuccesses = $ConsecutiveSuccesses
        alertArmed           = $AlertArmed
        savedAt              = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $GatingFile -Encoding utf8
} catch {
    Write-Verbose "Final gating-state save failed (best-effort, ignoring): $($_.Exception.Message)"
}

$finalCode = ($OverallPassed ? 0 : 1)
Write-InnerLog "about to exit with code $finalCode"
exit $finalCode
