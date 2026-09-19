<#PSScriptInfo
.VERSION 2026.09.18
.GUID 422de2af-9e3f-4bca-8c35-df0040af74c0
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
    Dev helper: run one test sequence (with its baseline chain) from a
    chosen step. No image download; reuses an existing VM if present.
    See test/README.md (Developing test sequences) for usage and naming.

    When the named sequence declares a `baseline:` chain (the same chain
    the cycle planner walks), Debug-TestSequence runs every prereq sequence
    in order BEFORE the named sequence -- start.* + workload.* both, in
    dependency order -- so the VM lands in the same state the runner
    would have produced. -StartStep/-StopStep index into the resulting
    CONCATENATED step list across the whole chain. Both name form and
    path form walk the chain; the path form just supplies the top-level
    file directly (useful when the project repo is a sibling working
    tree, not cloned under <RepoRoot>/project/).

.PARAMETER SequenceName   Base name (no .yml, e.g. "workload.guest.ubuntu.server.24")
                          OR a path to an existing .yml sequence file. The path
                          form is shell-tab-completion friendly; it supplies the
                          top-level file directly while the baseline chain is
                          still walked via the standard search paths. GuestKey
                          is derived from the basename. Required.
.PARAMETER StartStep      1-based start step in the CONCATENATED chain. Default 1.
.PARAMETER StopStep       1-based stop (inclusive) in the CONCATENATED chain.
                          VM left running after.
.PARAMETER ConfigPath     Default: test/test.config.yml.
.PARAMETER VMName         Override the VM name (default: derived from guest key).
.PARAMETER GuestKey       Override guest-folder lookup. Default: walk dotted
                          prefixes of the name after the first dot, longest
                          first, and pick the first one with a
                          host/<short>/<guestKey>/ folder. Needed when a
                          cascade-child sequence (e.g.
                          workload.guest.ubuntu.server.24.k8s.text-to-sql.baseline)
                          must reuse a shorter guest's scripts but the walk
                          would pick the wrong base.
.PARAMETER ShowSensitive Print expanded passwords / vault secrets in the
                          transcript. OFF by default to match production
                          (Start-TestRunner). Turn on only for one-off
                          local debugging; never share a transcript captured
                          with this switch on.
.PARAMETER NoConfigGate   Skip the pre-cycle Test-Config.ps1 preflight.
                          Default: gate runs (matches Start-TestRunner). Use
                          for in-progress edits where you want to iterate on
                          a sequence while test.config.yml / vault.yml /
                          users.yml are still being adjusted.
.PARAMETER logLevel       Error|Warning|Information|Verbose|Debug. Each level shows itself + all higher-priority streams (Error highest). Omit to read test.config.yml.logLevel (default "Information").
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$SequenceName,

    [int]$StartStep = 1,

    [int]$StopStep = 0,

    [string]$ConfigPath = $null,

    [string]$VMName = $null,

    [string]$GuestKey = $null,

    [switch]$ShowSensitive,

    [switch]$NoConfigGate,

    # Skip the built-in HTTP status service, matching Start-TestRunner /
    # Invoke-TestRunnerInnerLoop. Without it, an enabled statusService is started
    # (restarted) so the dashboard tracks this run.
    [switch]$NoStatusService,

    # Skip refreshing <RepoRoot>/project. An orchestration caller clones the project
    # ONCE before iterating a test-set, then passes this so each child
    # Debug-TestSequence reuses that fresh tree instead of re-cloning per entry.
    # Standalone callers should omit it -- the default clone keeps a lone
    # Debug-TestSequence run in sync with the runner (same as Invoke-TestRunnerInnerLoop).
    [switch]$NoProjectClone,

    # Three-state: omitted -> read from test.config.yml.logLevel;
    # explicit value -> override (wins over YAML). Single-pass resolution
    # below -- this script doesn't run a long-lived cycle loop.
    [ValidateSet('Error', 'Warning', 'Information', 'Verbose', 'Debug', IgnoreCase = $true)]
    [string]$logLevel
)

# Cmdline override for three-state resolution further down (after config
# load). PSBoundParameters is the only reliable source -- `[string]` defaults
# to '' when omitted.
Import-Module (Join-Path $PSScriptRoot '../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$script:CmdLineLogLevel = if ($PSBoundParameters.ContainsKey('logLevel')) { $logLevel } else { $null }

# --- REGION: Resolve paths
Import-Module (Join-Path $PSScriptRoot "modules/Test.Prelude.psm1") -Global -Force
$paths        = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -ConfigPath $ConfigPath
$TestRoot     = $paths.TestRoot
$RepoRoot     = $paths.RepoRoot
$ModulesDir   = $paths.ModulesDir
$SequencesDir = $paths.SequencesDir
$ConfigPath   = $paths.ConfigPath
# Publish the resolved config path so Update-TransportDefault and any
# other cross-module reload site read the SAME file when -ConfigPath
# <elsewhere> is in play.
$env:YURUNA_CONFIG_PATH = $ConfigPath

# Canonical exit codes (centralized in Test.Prelude so a future change
# to the contract -- e.g. introduce code 2 for "needs operator action" --
# lands in one place rather than touching ~15 bare `exit 1` sites here.)
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure

# --- REGION: Canonical module set for the Sequence entry-point
# Test.LogLevel + Test.Config + Test.SequenceAction + Test.HostIO +
# Test.HostContract + Test.Log + Invoke-Sequence + Test.SequencePlanner +
# Test.YurunaDir + Test.OcrEngine + Test.Tesseract +
# Test.ConfigPreflight. Order matters: planner AFTER engine so the
# engine's -Force re-import inside the planner doesn't evict the
# just-imported engine.
$savedVerbose = $global:VerbosePreference
$global:VerbosePreference = "SilentlyContinue"
Initialize-YurunaEntryPointModuleSet -For Sequence -ModulesDir $ModulesDir
# Yuruna.Log proxy is in automation/, not test/modules/, so it's not
# part of the canonical set; load it inline.
$yurunaLogModule = Join-Path -Path $RepoRoot -ChildPath "automation" -AdditionalChildPath "Yuruna.Log.psm1"
if (Test-Path $yurunaLogModule) {
    Import-Module $yurunaLogModule -Global -Force
}
# Test.SequenceRunner.psm1 holds this script's chain-planning +
# chain-execution logic so it can be unit-tested with fixture data
# (see test/modules/Test.SequenceRunner.psm1 header).
Import-Module (Join-Path $ModulesDir 'Test.SequenceRunner.psm1') -Global -Force
# Test.Orchestrator runs an orchestration sequence (InvokeTestSequence steps,
# no baseline) in-process under one status cycle. Detected + dispatched below,
# before the guest path.
Import-Module (Join-Path $ModulesDir 'Test.Orchestrator.psm1') -Global -Force
$global:VerbosePreference = $savedVerbose

# --- REGION: Nested-cycle detection
# When this Debug-TestSequence was started inside another run's process tree -- a
# host-action step re-entering us in a child pwsh (e.g. Set-Resource.ps1 fanning
# out per-stage guest builds) -- it inherits the owner's cycle-context handle
# ($env:YURUNA_CYCLE_CONTEXT). Its presence means THIS run is NESTED: it attaches
# a node to the owner's ONE status.json cycle instead of owning its own. A nested
# run must NOT reset status.json, restart the status service, take the single-
# instance lock, sweep the owner's control flags, allocate a top-level cycle
# number, or finalize the cycle -- all owner-only. Absence of the handle ==
# standalone owner, the unchanged classic behavior. See Test.Status.psm1
# "Nested-cycle support" for the ownership model.
$cycleCtx = Get-CycleContext
$isNested = [bool]$cycleCtx
if ($isNested) {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_2ec80e33b40cafb3' -Arguments @{ cycleStartUtc = "$($cycleCtx.cycleStartUtc)"; parentId = "$($cycleCtx.parentId)" })
}

# --- REGION: logLevel resolution: cmdline > YAML > 'Information'
# Canonical cascade: Test.LogLevel.psm1. See docs/loglevels.md.
# Reset + repopulate the sequence-action / host-I/O registries so a
# stale extension registered earlier in the same shell cannot shadow
# a renamed verb today. Rationale + ordering live in Test.Prelude.
Initialize-SequenceEngineRegistry -ModulesDir $ModulesDir -Confirm:$false
$cfgForLevel = Read-TestConfig -Path $ConfigPath
$configLevel = Get-TestConfigValue -Config $cfgForLevel -Path 'logLevel'
$null = Test.LogLevel\Resolve-LogLevel -CmdLineLevel $script:CmdLineLogLevel -ConfigLevel $configLevel

# Auto-relaunch under sg libvirt on host.ubuntu.kvm when this shell's
# group set lacks libvirt -- Debug-TestSequence runs the engine which
# calls virsh / virt-install on demand. No-op on other hosts / fresh
# shells.
Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

# --- REGION: Pre-flight: elevation
# Ahead of the destructive project re-clone below. Assert-HostConditionSet makes
# the same check much later, and with -NoConfigGate nothing catches it before
# <RepoRoot>/project has already been wiped. Self-gating: Assert-Elevation
# short-circuits to true whenever Test-ElevationRequired is false, and only
# host.windows.hyper-v registers RequiresElevation -- so this is a no-op on
# macOS and Linux and cannot introduce a UAC or sudo demand.
if (-not (Assert-Elevation -HostType (Get-HostType))) { exit $ExitFailure }

# --- REGION: Read config
$Config = Read-TestConfig -Path $ConfigPath
if (-not $Config) { Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_f62563beddeea65d' -Arguments @{ configPath = "$ConfigPath" }); exit $ExitFailure }

# --- REGION: Pre-cycle config gate
# Mirror Start-TestRunner: refuse to bring up a VM when test.config.yml /
# vault.yml / users.yml / transports.yml are in a state Test-Config.ps1
# would reject. Without this gate a sequence can "pass" under Debug-TestSequence
# (extension quirks-mode covers misconfig) while the runner refuses to even
# start the cycle on the same config -- exactly the kind of confusing
# surprise this gate guards against. Bypass with -NoConfigGate for
# ad-hoc / in-progress edits.
# Spawn a fresh pwsh so an Out-Of-Order ::Stop early-exit inside Test-Config
# cannot unwind this script. -SkipSend stops the smoke-test email from
# flooding subscribers["config.smoke"] on every Debug-TestSequence invocation.
# Test.ConfigPreflight was imported by Initialize-YurunaEntryPointModuleSet above.
#
# A NESTED run inherits its owner's verdict instead of re-gating. The owner
# cleared this same host and config when it opened the cycle; a nested run is
# one stage of that cycle, so re-validating per stage buys nothing and costs
# something real. The gate reaches github.com, and remote state is not a
# property of the config it is checking: a credential that expires between two
# stages turns a pre-flight into a mid-flight abort, killing a cycle over
# something none of its remaining work depends on and discarding every stage
# already built. A pre-flight belongs at the front of the flight. A standalone
# run (no inherited cycle context) is unaffected and still gates for itself.
$gateSkip   = [bool]($NoConfigGate -or $isNested)
$gateReason = if ($NoConfigGate) { '-NoConfigGate' } else { "nested run -- the owner cycle already gated $ConfigPath" }
$gate = Invoke-ConfigGate -TestRoot $TestRoot -ConfigPath $ConfigPath -Skip:$gateSkip -SkipReason $gateReason -CallerName 'Debug-TestSequence'
if (-not $gate.passed) { exit $gate.exitCode }

# --- REGION: Refresh <RepoRoot>/project from test.config.yml's repositories.projectUrl
# Mirror Invoke-TestRunnerInnerLoop: the cycle's planner (and Resolve-SequencePath
# right below) reads project-tree sequences from <RepoRoot>/project/, so an
# absent or stale clone makes Debug-TestSequence silently diverge from the runner.
# Skipped when repositories.projectUrl is empty (in-tree project layout).
# Failure aborts before VM bring-up, same as the runner.
$projUrl = $null
if ($Config -is [System.Collections.IDictionary] -and
    $Config.repositories -is [System.Collections.IDictionary] -and
    $Config.repositories.Contains('projectUrl')) {
    $projUrl = [string]$Config.repositories.projectUrl
}
if ($NoProjectClone) {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_9d3a2ae3fb5cec6d')
} else {
    $cloneRes = Update-ProjectClone -RepoRoot $RepoRoot -ProjectUrl $projUrl -Confirm:$false
    if (-not $cloneRes.success) {
        Write-Warning ""
        Write-Warning "========"
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_62763311ebf835f2' -Arguments @{ errorMessage = "$($cloneRes.errorMessage)" })
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_30850c083e8c60e9')
        Write-Warning "  <RepoRoot>/project/. Fix repositories.projectUrl in"
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_a8bdd8fe43f4954f')
        Write-Warning "========"
        exit $ExitFailure
    }
}

# --- REGION: Ensure status service is running (restart to pick up any changes)
# Shared gate (Test.Prelude) so enabled / -NoStatusService / port / restart match the
# inner runner. -Restart: a re-invoked Debug-TestSequence must pick up edits.
# Skipped when nested: the owner already started (and owns) the status service;
# a nested child restarting it would bounce the owner's live server mid-cycle.
if (-not $isNested) {
    $startScript = Join-Path $TestRoot "service/Start-StatusService.ps1"
    $null = Start-YurunaStatusServiceIfEnabled -Config $Config -StartScript $startScript -NoStatusService:$NoStatusService -Restart
}
# The config service is a caching-proxy-service companion (owned by Start-CachingProxyServiceVM.ps1),
# not a test-entry-point concern, so it is intentionally not started here.

# --- REGION: Detect host type
# HostType is resolved BEFORE sequence resolution so Resolve-SequencePath can
# prefer a per-host sequence variant (e.g. <Name>.ubuntu.kvm.yml) over the
# generic <Name>.yml -- needed because KVM cloud-image guests skip the
# autoinstall flow that Hyper-V/UTM autoinstall guests run through.
$HostType = Get-HostType
if (-not $HostType) { exit $ExitFailure }
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_82bcd42076e94095' -Arguments @{ hostType = "$HostType" })

# --- REGION: Resolve sequence file
# Sequences live flat under test/sequences/ in the framework and
# project/<...>/test/ in the per-cycle clone; an ssh variant is its own
# <name>.ssh sequence. Resolve-SequencePath checks the project tree first,
# then the framework, host-specific variant before the plain file. If
# nothing matches, list everything available across both trees.
#
# Convenience: when $SequenceName is a path to an existing .yml file (shell
# tab-completion produces this naturally), use it verbatim and reduce the
# name to its basename for downstream GuestKey derivation. The operator
# pointed at a specific file -- honor it, don't second-guess into a
# host-variant from the tier search.
$SequencePathOverride = $null
try {
    $resolved = Resolve-Path -LiteralPath $SequenceName -ErrorAction Stop
    if ($resolved -and (Test-Path -LiteralPath $resolved.Path -PathType Leaf) -and
        ($resolved.Path -like '*.yml' -or $resolved.Path -like '*.yaml')) {
        $SequencePathOverride = $resolved.Path
        $SequenceName = [System.IO.Path]::GetFileNameWithoutExtension($SequencePathOverride)
    }
} catch { $null = $_ }

# Tolerate operator typing the .yml/.yaml extension on the name form
# (e.g. via shell tab-completion against a sibling project working tree
# whose path the Resolve-Path branch couldn't resolve from this cwd).
# Resolve-SequencePath unconditionally appends .yml, so a trailing
# extension here would search for `Name.yml.yml` and miss. Same strip
# Test.SequencePlanner already does when reading baseline entries from
# YAML, kept symmetric so CLI callers and YAML callers behave the same.
if (-not $SequencePathOverride -and $SequenceName -match '\.ya?ml$') {
    $SequenceName = $SequenceName -replace '\.ya?ml$', ''
}

if ($SequencePathOverride) {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_8bd4b02d5e70403a' -Arguments @{ sequencePathOverride = "$SequencePathOverride"; sequenceName = "$SequenceName" })
    # Heads-up: if a host-variant sibling exists, Resolve-SequencePath
    # would have picked it (the runner does). Path-override skips that
    # tier, so warn loudly -- otherwise the operator thinks Debug-TestSequence
    # validated what the runner will execute, when it didn't.
    $hostShort = $HostType -replace '^host\.',''
    if ($SequenceName -notmatch "\.$([regex]::Escape($hostShort))$") {
        $overrideDir  = Split-Path -Parent $SequencePathOverride
        $overrideExt  = [System.IO.Path]::GetExtension($SequencePathOverride)
        $variantPath  = Join-Path $overrideDir "$SequenceName.$hostShort$overrideExt"
        if (Test-Path -LiteralPath $variantPath) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_9c7e07aeec1e2470' -Arguments @{ variantPath = "$variantPath" })
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_760f2248c0947561' -Arguments @{ hostType = "$HostType" })
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_9d268a451a73a838')
        }
    }
    $SequencePath = $SequencePathOverride
} else {
    $SequencePath = Resolve-SequencePath -SequencesDir $SequencesDir -Name $SequenceName -HostType $HostType -RepoRoot $RepoRoot
}
if (-not $SequencePath) {
    # Resolve-SequencePath returns $null on miss; Get-SequenceSearchPath
    # enumerates the same tier order so the operator sees the exact set of
    # candidates that were checked, rather than a fake "resolved path".
    $searched = Get-SequenceSearchPath -SequencesDir $SequencesDir -Name $SequenceName -HostType $HostType -RepoRoot $RepoRoot
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_c8257004f436177e' -Arguments @{ sequenceName = "$SequenceName" })
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_b5abb8162943db18')
    foreach ($p in $searched) { Write-Output "  $p" }
    Write-Output ""
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_b32c788449b89f51')
    $allDirs = @($SequencesDir) + (Get-ProjectFlatTestSearchDir -RepoRoot $RepoRoot)
    $allDirs |
        ForEach-Object { Get-ChildItem -Path $_ -Filter "*.yml" -ErrorAction SilentlyContinue } |
        Where-Object { $_.Name -notin @('actions.yml', '_snippets.yml') } |
        Sort-Object BaseName -Unique |
        ForEach-Object { Write-Output "    $($_.BaseName)" }
    exit $ExitFailure
}

# Wire the host driver so contract calls (New-VM, Start-VM, Get-VMState, ...)
# resolve without HostType branches.
[void](Initialize-YurunaHost -RepoRoot $RepoRoot -HostType $HostType)

if (-not (Assert-HostConditionSet -HostType $HostType)) { exit $ExitFailure }

# Test.YurunaDir / Test.OcrEngine / Test.Tesseract were
# imported by Initialize-YurunaEntryPointModuleSet above.
$null = Initialize-YurunaRuntimeDir
$null = Initialize-YurunaLogDir
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_d0c93f4c1ef556a0' -Arguments @{ dIR = "$env:YURUNA_RUNTIME_DIR" })
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_d86eb14c32191314' -Arguments @{ dIR = "$env:YURUNA_LOG_DIR" })

# --- REGION: Single-instance guard
# Refuse to start when a Start-TestRunner already owns the runtime dir.
# Debug-TestSequence is a dev entry point: it does not coordinate the runner
# state machine, so a concurrent run would race the runner's pidfile,
# status.json registrations, and VM operations. Get-RunnerInstanceState
# (Test.SingleInstance) does the read; Assert-NoOtherRunner wraps it
# with the "refuse + banner" semantics this entry point needs --
# Start-TestRunner's takeover path is the opposite (Stop-StaleRunner).
# Nested runs skip the guard: they don't own the runtime dir (the outer cycle
# owner does), and the owner already passed this same check. Enforcing it here
# would make every nested stage refuse to start the moment the owner registered.
if (-not $isNested -and -not (Assert-NoOtherRunner -RuntimeDir $env:YURUNA_RUNTIME_DIR -CallerName 'Debug-TestSequence')) {
    exit $ExitFailure
}

# --- REGION: Ctrl+C handler
# Register a CancelKeyPress handler that flips $script:CancelState['Requested']
# instead of letting Ctrl+C tear the runspace down mid-step. The finally{}
# block below polls the flag and stops the VM so a half-baked guest
# (interrupted during New-VM / Start-VM / a long sequence step) doesn't
# linger consuming host CPU + memory. The disk is intentionally kept so
# the operator can inspect post-mortem via virsh / vmconnect / utmctl.
$script:CancelState = Register-EntryPointCancelHandler

# Sweep the stale inter-cycle control state a freshly-typed Debug-TestSequence
# command line must not inherit. -Scope Startup consumes control.cycle-
# restart (so Invoke-Sequence Gate #1 doesn't throw YurunaCycleRestart on
# our first step and make it look like the SEQUENCE broke) AND archives a
# leftover break-active.json + clears leftover pause flags (so the status
# UI doesn't show a Continue pending, and the run doesn't start paused,
# from a prior session the operator never resumed). The operator typed
# THIS command line, so we honor the intent to run over the stale flags.
# Nested runs must NOT sweep control state: the pause / cycle-restart flags
# belong to the owner's live cycle, and clearing them from a child would drop a
# Continue the operator armed on the parent. Owner-only.
if (-not $isNested -and (Get-Command Clear-StaleControlState -ErrorAction SilentlyContinue)) {
    $ctl = Clear-StaleControlState -Scope Startup -RuntimeDir $env:YURUNA_RUNTIME_DIR -Confirm:$false
    if ($ctl.cycleRestartCleared) { Write-Verbose "Cleared stale control.cycle-restart flag." }
    foreach ($w in $ctl.warnings) { Write-Verbose "Stale control-state sweep: $w" }
}

$activeEngines = Get-EnabledOcrProvider
$combineMode = ($env:YURUNA_OCR_COMBINE -eq 'And') ? 'And' : 'Or'
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_37b6754fe040268f' -Arguments @{ join = "$($activeEngines -join ', ')"; combineMode = "$combineMode" })
if (-not (Assert-TesseractInstalled)) { exit $ExitFailure }

# --- REGION: Orchestration sequence dispatch (InvokeTestSequence steps)
# An orchestration sequence has no `baseline:` and its steps invoke inner
# sequences (guest or host-action) in order. Detected here -- after the
# host driver, runtime dirs, single-instance guard and OCR setup are up,
# but before the guest-only GuestKey + VM path -- and handed to
# Test.Orchestrator, which owns its own status cycle + log and returns an
# exit code.
$topLevelDoc = $null
try { $topLevelDoc = Read-SequenceFile -Path $SequencePath } catch {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_0eb9acf2273e09fd' -Arguments @{ sequencePath = "$SequencePath"; message = "$($_.Exception.Message)" })
    exit $ExitFailure
}
if (Test-IsOrchestrationSequence -Sequence $topLevelDoc) {
    # Same vmnet-bridge hazard the guest path guards against further down: a
    # foreign running VM can push this run's guests onto a second host-side
    # bridge that does not route to the host's vmnet gateway, breaking the
    # cloud-init host-proxy URL baked into seed.iso. This path returns before
    # ever reaching that guard, and Test.Orchestrator has none of its own, so
    # the pre-flight has to run here too. Stop first, refuse second, so a
    # leftover guest is stopped rather than left to strand the host.
    # No -ExceptVmName: an orchestration run creates a VM per inner sequence
    # instead of targeting one named guest, so there is nothing to exempt.
    [void](Stop-ConcurrentVM)
    if ($HostType -eq 'host.macos.utm') {
        if (-not (Assert-NoConcurrentUtmVm)) { exit $ExitFailure }
    }
    $orchRc = Invoke-OrchestrationSequence `
        -Sequence $topLevelDoc -SequencePath $SequencePath `
        -RepoRoot $RepoRoot -SequencesDir $SequencesDir -TestRoot $TestRoot `
        -HostType $HostType -Config $Config -ShowSensitive:$ShowSensitive
    Unregister-EntryPointCancelHandler
    exit ($orchRc -eq 0 ? $ExitOk : $ExitFailure)
}

# --- REGION: Derive GuestKey from the sequence's baseline map
# Source of truth is the sequence's `baseline:` field -- whichever OS
# key(s) it lists tell us which guest VM the sequence targets. The
# filename is NOT authoritative: a typo or rename would otherwise
# silently derail the whole chain (and a project sequence like
# `ch01.website.example.yml` has no guest token in its name at all).
# Same lookup the cycle planner uses in Resolve-CyclePlan
# (Test.SequencePlanner.psm1) for Start-TestRunner / Invoke-TestProject,
# kept symmetric so Debug-TestSequence behaves the same standalone.
if ($GuestKey) {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_79690a75cc829126' -Arguments @{ guestKey = "$GuestKey" })
} else {
    try {
        $topSeq = Read-SequenceFile -Path $SequencePath
    } catch {
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_0eb9acf2273e09fd' -Arguments @{ sequencePath = "$SequencePath"; message = "$($_.Exception.Message)" })
        exit $ExitFailure
    }
    # Read-SequenceFile normalizes `resource:` into the engine-internal `baseline`
    # key, so the OS-key lookup is the same for the migrated shape.
    $osKeys = @()
    if ($topSeq -is [System.Collections.IDictionary] -and
        $topSeq.baseline -is [System.Collections.IDictionary] -and
        $topSeq.baseline.Keys.Count -gt 0) {
        $osKeys = @($topSeq.baseline.Keys)
    }
    if ($osKeys.Count -eq 0) {
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_a8ae8ccf83869008' -Arguments @{ sequenceName = "$SequenceName"; sequencePath = "$SequencePath" })
        exit $ExitFailure
    }
    $osKey = $osKeys[0]
    if ($osKeys.Count -gt 1) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_ad81569ced59ff6c' -Arguments @{ sequenceName = "$SequenceName"; join = "$($osKeys -join ', ')"; osKey = "$osKey" })
    }
    $GuestKey = "guest.$osKey"
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_3d35ece66aa84b79' -Arguments @{ guestKey = "$GuestKey" })
}

# Final safety net: even an explicit -GuestKey must point to a real folder.
if (-not (Test-GuestFolder -RepoRoot $RepoRoot -HostType $HostType -GuestKey $GuestKey)) {
    $folder = Join-Path $RepoRoot (Join-Path (Get-HostFolder $HostType) $GuestKey)
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_24819dc9d233e1da' -Arguments @{ guestKey = "$GuestKey"; hostType = "$HostType"; folder = "$folder" })
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_dfd80a749d4fee8f')
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_0a7402a9f9613d98')
    exit $ExitFailure
}

# --- REGION: Derive VM name (use -VMName override if provided)
if (-not $VMName) {
    $Prefix = $Config.vmStart.testVmNamePrefix ?? "test-"
    $VMName = Get-TestVMName -GuestKey $GuestKey -Prefix $Prefix
}

# --- REGION: UTM concurrent-VM pre-flight
# On some macOS versions vmnet-shared assigns a separate host-side bridge
# per vmnet "session" (bridge100, bridge101, ...) that don't route between
# each other, so a foreign concurrent VM can push the test guests onto a
# different bridge from the host's vmnet gateway and break the cloud-init
# host-proxy URL baked into seed.iso. Refuse the cycle if a foreign VM is
# running. Two names are exempt inside Assert-NoConcurrentUtmVm: the
# caching-proxy-service VM (a dependency the guests consume, reachable on the
# shared bridge) and the operator's own target VM ($VMName, so the
# iterate-on-an-existing-VM dev loop still works).
# Stop first, refuse second: a leftover guest is stopped rather than left to
# strand the host, and the guard below refuses only over what would not stop.
# The operator's own target VM is left running so the dev loop still works.
[void](Stop-ConcurrentVM -ExceptVmName $VMName)
if ($HostType -eq 'host.macos.utm') {
    if (-not (Assert-NoConcurrentUtmVm -ExceptVmName $VMName)) { exit $ExitFailure }
}

# --- REGION: Build chain plan
# Chain planning + warm-path requiresSnapshot probe live in
# Test.SequenceRunner.psm1 so they can be unit-tested with fixture
# data. Behavior: walk the
# baseline chain, build (name,path,sequence,stepCount,globalStart) per
# entry, and -- when the top-level declares requiresSnapshot.id and
# the snapshot is already on disk -- drop every prereq and run only
# the top-level against the persisted VM. effectiveUsername must be
# known BEFORE New-VM below, matching the runner's same forward.
$osKey = $GuestKey -replace '^guest\.',''
$plan = Resolve-TestSequencePlan `
    -RepoRoot $RepoRoot `
    -SequencesDir $SequencesDir `
    -HostType $HostType `
    -SequenceName $SequenceName `
    -OsKey $osKey `
    -SequencePathOverride $SequencePathOverride
if ($plan.resolveFailed) { exit $ExitFailure }
$ChainEntries       = $plan.chainEntries
$ChainPlan          = $plan.chainPlan
$effectiveUser      = $plan.effectiveUser
$effectiveHost      = $plan.effectiveHost
$effectiveMemory    = $plan.effectiveMemoryStartupBytes
$effectiveCores     = $plan.effectiveCores
$effectiveExposeVirt = $plan.effectiveExposeVirtualizationExtensions
$ChainTotalSteps    = $plan.chainTotalSteps
$requiredSnapshotId = $plan.requiredSnapshotId
# Warm path targets the persisted snapshot VM by its recorded id. An
# explicit -VMName is an operator instruction to run against a specific
# VM, so it wins: overwriting it here would silently redirect the run to
# a different VM than the one the operator named on the command line.
if ($plan.warmPath -and -not $PSBoundParameters.ContainsKey('VMName')) { $VMName = $requiredSnapshotId }

# --- REGION: SSH-user override
# Same cascade registration as Invoke-TestRunnerInnerLoop: Test.Ssh's
# Get-GuestSshUser is the lookup point for Save-GuestDiagnostic +
# host-driver SSH-mode Send-Text / fetchAndExecute SSH. Standalone
# Debug-TestSequence runs the same chain as a one-off, so register the
# same override here. Empty $effectiveUser falls through to the
# hardcoded per-guest default via Get-GuestSshUser unchanged.
if (-not (Get-Command Set-GuestSshUserOverride -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $ModulesDir 'Test.Ssh.psm1') -Force -Global -ErrorAction SilentlyContinue
}
if (Get-Command Clear-GuestSshUserOverride -ErrorAction SilentlyContinue) {
    Clear-GuestSshUserOverride
}
if ($effectiveUser -and (Get-Command Set-GuestSshUserOverride -ErrorAction SilentlyContinue)) {
    Set-GuestSshUserOverride -GuestKey $GuestKey -Username $effectiveUser
}

# --- REGION: Resolve the caching-proxy-service endpoint from config + env
# Invoke-TestRunnerInnerLoop reads BOTH $Config.vmStart.cachingProxyIp (the
# persistent UI-edited key, probed first) and $env:YURUNA_CACHING_PROXY_SERVICE_IP
# (session-scope fallback, probed only when the config candidate is
# absent or fails), keeps the first whose HTTP proxy port is reachable,
# and clears the env when none answers. Debug-TestSequence runs the SAME
# Resolve-CachingProxyServiceEndpoint so a syntactically valid but dead IP
# configured via the status service's Edit-config page can't survive into
# guest cidata here either. When neither source is set, the resolver is
# a no-op and the local-discovery path in Test-CachingProxyServiceAvailable
# below runs unchanged.
$envCacheIp    = if ($env:YURUNA_CACHING_PROXY_SERVICE_IP) { $env:YURUNA_CACHING_PROXY_SERVICE_IP.Trim() } else { '' }
$configCacheIp = ''
if ($Config.vmStart -is [System.Collections.IDictionary] -and $Config.vmStart.Contains('cachingProxyIp')) {
    $configCacheIp = "$($Config.vmStart.cachingProxyIp)".Trim()
}
if (($envCacheIp -or $configCacheIp) -and (Get-Command Resolve-CachingProxyServiceEndpoint -ErrorAction SilentlyContinue)) {
    $endpoint = Resolve-CachingProxyServiceEndpoint -EnvIp $envCacheIp -ConfigIp $configCacheIp
    foreach ($line in $endpoint.Lines) { Write-Output $line }
    # Committing to this address for the guests below -- confirm it stays up
    # rather than trusting the single accept the probe saw. See the same call in
    # Test.Orchestrator: a cache rebuilt just before the run restarts squid once
    # while provisioning finishes, well after its ports first open.
    if ($endpoint.EffectiveIp -and (Get-Command Wait-CachingProxyServiceSettled -ErrorAction SilentlyContinue)) {
        $settle = Wait-CachingProxyServiceSettled -CacheIp $endpoint.EffectiveIp -Port $endpoint.HttpPort
        foreach ($line in $settle.Lines) { Write-Output $line }
    }
    $env:YURUNA_CACHING_PROXY_SERVICE_IP = $endpoint.EffectiveIp
}

# --- REGION: Resolve caching-proxy service URL
# Mirror Invoke-TestRunnerInnerLoop: resolve once via Test-CachingProxyServiceAvailable
# (honors $Env:YURUNA_CACHING_PROXY_SERVICE_IP for remote caches, falls back to
# locally-recorded state) and forward to New-VM so the guest's cloud-init
# user-data templates the proxy URL. Without this forward, the per-guest
# New-VM.ps1 falls into local Get-VM yuruna-caching-proxy-service discovery and
# warns "no cache" even when the operator has a healthy remote cache.
$cachingProxyUrl = Test-CachingProxyServiceAvailable
$newVmProxy = if ($cachingProxyUrl) { $cachingProxyUrl } else { "" }
if ($newVmProxy) {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_00d3aca89d9237fa' -Arguments @{ newVmProxy = "$newVmProxy" })
} else {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_5b5842bc02378c5f')
}

# --- REGION: Ensure VM exists (reuse or create)
if ((Get-VMState -VMName $VMName) -ne 'absent') {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_a1b32a2ad4857b3d' -Arguments @{ vMName = "$VMName" })
    # Reuse skips the entire New-VM path, so the switch selection that runs
    # there never runs: the VM keeps whatever vNIC attachment it was created
    # with, and no host-side network change ever reaches it. A Hyper-V vSwitch
    # object outlives its uplink binding across a host reboot, so the switch
    # still existing is not evidence that it still bridges -- revalidate the
    # attachment before the sequence engine spends its step budget on a guest
    # that can never reach the network. Report only: this script has no
    # VM-file sweep, so re-creating the VM belongs to the runner's per-guest
    # iteration, not here. The Get-Command guards keep the whole block inert
    # on host.ubuntu.kvm and host.macos.utm.
    if ((Get-Command Get-VMNetworkAdapter -ErrorAction SilentlyContinue) -and
        (Get-Command Test-YurunaExternalSwitchUplink -ErrorAction SilentlyContinue)) {
        $reuseSwitchName = ''
        $reuseVerdict    = 'unknown'
        try {
            $reuseAdapter = Get-VMNetworkAdapter -VMName $VMName -ErrorAction Stop | Select-Object -First 1
            if ($reuseAdapter) { $reuseSwitchName = [string]$reuseAdapter.SwitchName }
            if ($reuseSwitchName) {
                $reuseVerdict = [string](Test-YurunaExternalSwitchUplink -SwitchName $reuseSwitchName)
            }
        } catch {
            # Fail open: anything unevaluable stays 'unknown'. A probe that
            # could not run must never be reported as a fault.
            Write-Verbose "VM '$VMName': switch attachment not evaluable: $($_.Exception.Message)"
        }
        if ($reuseVerdict -notin @('healthy', 'unknown')) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_1eeace18e9071c6f' -Arguments @{ vMName = "$VMName"; reuseSwitchName = "$reuseSwitchName"; reuseVerdict = "$reuseVerdict" })
        } else {
            Write-Verbose "VM '$VMName': switch '$reuseSwitchName' uplink verdict '$reuseVerdict'."
        }
    }
} else {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_ad8be36c987288c8' -Arguments @{ vMName = "$VMName" })
    # Forward -Username / -Hostname when the sequence declares them. Mirrors
    # Invoke-TestRunnerInnerLoop's cascade forward (the cascade-walk is not
    # feasible standalone, but the sequence's own variables.username /
    # variables.hostname are the overrides Debug-TestSequence can honor without
    # the planner). Empty values fall through to the per-host New-VM
    # defaults (the account default and the VM name, respectively).
    $newVmArgs = @{ GuestKey = $GuestKey; RepoRoot = $RepoRoot; VMName = $VMName; CachingProxyServiceUrl = $newVmProxy }
    if ($effectiveUser) {
        Write-Verbose "Forwarding -Username '$effectiveUser' from $($SequenceName).variables.username."
        $newVmArgs.Username = $effectiveUser
    }
    if ($effectiveHost) {
        Write-Verbose "Forwarding -Hostname '$effectiveHost' from $($SequenceName).variables.hostname."
        $newVmArgs.Hostname = $effectiveHost
    }
    # VM sizing overrides (variables.memoryStartupBytes / variables.cores) under
    # the same declare-or-drop rule as -Username: forwarded only when the target
    # New-VM.ps1 declares them, else surfaced on Verbose by Invoke-PerGuestNewVm.
    if ($effectiveMemory) {
        Write-Verbose "Forwarding -MemoryStartupBytes '$effectiveMemory' from $($SequenceName).variables.memoryStartupBytes."
        $newVmArgs.MemoryStartupBytes = $effectiveMemory
    }
    if ($effectiveCores) {
        Write-Verbose "Forwarding -Cores '$effectiveCores' from $($SequenceName).variables.cores."
        $newVmArgs.Cores = $effectiveCores
    }
    if ($effectiveExposeVirt) {
        Write-Verbose "Forwarding -ExposeVirtualizationExtensions '$effectiveExposeVirt' from $($SequenceName).variables.exposeVirtualizationExtensions."
        $newVmArgs.ExposeVirtualizationExtensions = $effectiveExposeVirt
    }
    $r = New-VM @newVmArgs -Confirm:$false
    if (-not $r.success) {
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_7fbc520be847a724' -Arguments @{ errorMessage = "$($r.errorMessage)" })
        exit $ExitFailure
    }
    Write-Output "VM '$VMName' created."
}

# --- REGION: Ensure VM is running
# Skipped when the first EXECUTED step (honoring -StartStep, and reading through a
# wrapper such as `retry` to the inner step that actually runs) is `loadDiskSnapshot`:
# that handler tolerates a stopped VM as input (its host driver gates the pre-restore
# Stop-VM on `if running`), runs the restore against the offline disk,
# and starts the VM itself on return. Pre-booting here would only force
# the handler to immediately Stop-VM again -- a wasted Start+Wait cycle
# (~15-20s of boot-delay + Hyper-V cold-stop poll) on every warm-path run.
$VmStartTimeoutSeconds = $Config.vmStart.startTimeoutSeconds ? [int]$Config.vmStart.startTimeoutSeconds : 120
$VmBootDelaySeconds    = $Config.vmStart.bootDelaySeconds    ? [int]$Config.vmStart.bootDelaySeconds    : 15

# Get-FirstExecutedStepAction (Test.SequenceRunner.psm1) returns $null when StartStep
# is past the end -- the StartStep range-check just below reports that; here it simply
# means "start the VM".
$firstStepAction = Get-FirstExecutedStepAction -ChainEntries $ChainEntries -StartStep $StartStep

if ($firstStepAction -eq 'loadDiskSnapshot') {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_99f490076f106bd0' -Arguments @{ vMName = "$VMName" })
} elseif ((Get-VMState -VMName $VMName) -eq 'running') {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_e254f9313b9ad995' -Arguments @{ vMName = "$VMName" })
} else {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_44a010f47f51d941' -Arguments @{ vMName = "$VMName" })
    $r = Start-VM -VMName $VMName -Confirm:$false
    if (-not $r.success) {
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_99bf63cc22ad6315' -Arguments @{ errorMessage = "$($r.errorMessage)" })
        exit $ExitFailure
    }
    $ok = Wait-VMRunning -VMName $VMName `
        -TimeoutSeconds $VmStartTimeoutSeconds -BootDelaySeconds $VmBootDelaySeconds
    if (-not $ok) {
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_f6f4b9dbaaab8f2f' -Arguments @{ vMName = "$VMName"; vmStartTimeoutSeconds = "${VmStartTimeoutSeconds}" })
        exit $ExitFailure
    }
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_871b3d6f64f4b730' -Arguments @{ vMName = "$VMName" })
}

# --- REGION: Validate StartStep / StopStep against the chain's TOTAL step count
# $ChainTotalSteps was computed by the chain-plan block above. With a
# single-sequence chain (no baseline OR path-override) this is exactly
# that sequence's own step count; with prereqs it covers the whole
# concatenated execution.
$totalSteps = $ChainTotalSteps

if ($StartStep -lt 1 -or $StartStep -gt $totalSteps) {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_c5e5437853bd6622' -Arguments @{ startStep = "$StartStep"; totalSteps = "$totalSteps" })
    exit $ExitFailure
}

if ($StopStep -ne 0) {
    if ($StopStep -lt $StartStep) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_9bd6bf003a0b8625' -Arguments @{ stopStep = "$StopStep"; startStep = "$StartStep" })
        exit $ExitFailure
    }
    if ($StopStep -gt $totalSteps) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_6a91c5c4b76cc8ff' -Arguments @{ stopStep = "$StopStep"; totalSteps = "$totalSteps" })
        $StopStep = $totalSteps
    }
}

$effectiveStop = $StopStep -ne 0 ? $StopStep : $totalSteps

$stopLabel = $StopStep -ne 0 ? ", stopping after step $effectiveStop" : ""

# --- REGION: Register this run as a cycle in status.json
# Without this block a Debug-TestSequence run lands under cycle "000000" with
# no row in the dashboard's history table, and break-active.json has no live
# cycle to anchor the Continue button against. Mirrors
# Invoke-TestRunnerInnerLoop's shape but uses a single 'Sequence' step: the
# inner runner's fixed phase pills -- New-VM / Start-VM / Start-GuestOS / ...
# -- would render four "pending" chips that never animate, since
# Debug-TestSequence skips those phase boundaries.
# $nestedNodeId is the id of this run's node in the owner's `nested` map; it
# stays $null for an owner run and is read again in the finally{} to finalize
# the node, so it must live in the script scope BEFORE the branch.
$nestedNodeId = $null
$StatusFile   = Join-Path $env:YURUNA_RUNTIME_DIR 'status.json'
if ($isNested) {
    # --- REGION: NESTED: attach a node to the owner's ONE cycle; never reset/own it
    # Ownership lives in the outermost process; here we only author our own
    # node in `nested` and write our transcript under the owner's cycle folder.
    if ($cycleCtx.statusPath)      { $StatusFile = [string]$cycleCtx.statusPath }
    $parentId     = [string]$cycleCtx.parentId
    $nestedNodeId = if ($parentId) { "$parentId/$SequenceName" } else { $SequenceName }
    # Start this run's own transcript nested under the owner's cycle folder --
    # no new top-level cycle number, no folder rename (owner concerns).
    $nestedLog = Start-NestedLogFile -RootCycleFolder ([string]$cycleCtx.rootCycleFolder) `
        -NodeId $nestedNodeId -CycleStartUtc ([string]$cycleCtx.cycleStartUtc)
    $LogFile   = $nestedLog.LogFile
    # Attach the node (running) so its nested tile appears immediately, with a
    # deep-link (LogRel) to this transcript.
    Register-NestedRunNode -StatusPath $StatusFile -NodeId $nestedNodeId -ParentId $parentId `
        -Name $SequenceName -Kind 'guest' -LogRel $nestedLog.LogRel -CycleStartUtc ([string]$cycleCtx.cycleStartUtc)
    # Propagate context one level deeper so anything THIS run itself spawns
    # attaches UNDER our node -- the same mechanism at any nesting depth.
    Publish-CycleContext -CycleStartUtc ([string]$cycleCtx.cycleStartUtc) -StatusPath $StatusFile `
        -RootCycleFolder ([string]$cycleCtx.rootCycleFolder) -CycleNumber ([int]$cycleCtx.cycleNumber) `
        -ParentId $nestedNodeId
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_e8572ec44a49561c' -Arguments @{ logFile = "$LogFile" })
} else {
    # --- REGION: OWNER: register + own the cycle (classic standalone path)
    Reset-StatusDocumentForCycleStart -StatusFilePath $StatusFile -Confirm:$false

    $frameworkUrl = if ($Config.repositories -is [System.Collections.IDictionary] -and $Config.repositories.frameworkUrl) {
        [string]$Config.repositories.frameworkUrl
    } else { '' }
    $frameworkCommit = ''
    if (Get-Command Get-CurrentGitCommit -ErrorAction SilentlyContinue) {
        try { $frameworkCommit = [string](Get-CurrentGitCommit -RepoRoot $RepoRoot) } catch { $frameworkCommit = '' }
    }
    $gitCommitsList = @()
    if ($frameworkCommit) {
        $gitCommitsList += [ordered]@{ sha = $frameworkCommit; repoUrl = $frameworkUrl }
    }
    $SeqCycleStartUtc = Initialize-StatusDocument `
        -StatusFilePath $StatusFile `
        -HostType       $HostType `
        -Hostname       (hostname) `
        -GitCommit      $frameworkCommit `
        -RepoUrl        $frameworkUrl `
        -GitCommits     $gitCommitsList `
        -GuestList      @($GuestKey) `
        -StepNames      @('Sequence')

    Set-GuestVMName -GuestKey $GuestKey -VMName $VMName -Confirm:$false
    Set-GuestTopLevel -GuestKey $GuestKey -TopLevel $SequenceName -Confirm:$false
    Set-GuestStatus -GuestKey $GuestKey -Status 'running' -Confirm:$false
    Set-StepStatus -GuestKey $GuestKey -StepName 'Sequence' -Status 'running' -Confirm:$false

    $CycleNumber = Get-CycleNumber
    $LogFile    = Start-LogFile -TestRoot $TestRoot -CycleStartUtc $SeqCycleStartUtc -Hostname (hostname) -CycleNumber $CycleNumber -GitCommits $gitCommitsList
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_e8572ec44a49561c' -Arguments @{ logFile = "$LogFile" })

    # Open the per-step perf log for the cycle this run owns, so a standalone
    # sequence contributes rows on the same terms as a runner cycle. The nested
    # case is excluded by the enclosing -not $isNested block: a nested run
    # adopts the owner's cycle instead (Resume-PerfCycle) so both write one
    # cycle file. Soft-failing -- a perf problem must not fail the run.
    if (Get-Command -Name Start-PerfCycle -ErrorAction SilentlyContinue) {
        try {
            Start-PerfCycle -CycleStartUtc $SeqCycleStartUtc -HostPlatform $HostType -Hostname (hostname) `
                -HarnessCommit $frameworkCommit -Confirm:$false
        } catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_99ba6b1738ddcff9' -Arguments @{ message = "$($_.Exception.Message)" })
        }
    }
}

Write-Output ""
Write-Output "========"
Write-Output "  Sequence: $SequenceName"
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_2be40d5be45b6d2f' -Arguments @{ count = "$($ChainPlan.fullChain.Count)"; totalSteps = "$totalSteps" })
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_9eecd5d18a0d7c74' -Arguments @{ startStep = "$StartStep"; stopLabel = "$stopLabel" })
Write-Output "  VM:       $VMName"
Write-Output "  Guest:    $GuestKey"
Write-Output "========"

Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_1e85bba01269d1fa')
$stepIdx = 0
foreach ($entry in $ChainEntries) {
    $marker = ($ChainPlan.fullChain.Count -gt 1) ? "--- " : ""
    Write-Output "  $marker$($entry.name) ($($entry.stepCount) step(s))"
    foreach ($step in $entry.sequence.steps) {
        $stepIdx++
        $m = ($stepIdx -ge $StartStep -and $stepIdx -le $effectiveStop) ? ">>" : "  "
        $desc = $step.description ?? $step.action
        Write-Output "  $m [$stepIdx] $($step.action): $desc"
    }
}
Write-Output ""

# --- REGION: Run each chain entry that overlaps the requested step range
# Per-entry step-window run + mid-chain rename detection lives in
# Test.SequenceRunner.psm1 (Invoke-TestSequenceChain); it runs each entry's real
# file via Invoke-Sequence -StartStep/-StopStep, so there are no slice temp
# files to sweep. A mid-chain saveDiskSnapshot rename surfaces via the returned
# finishedVmName so this script's outer $VMName tracks the rename for the
# post-run banner.
# Outcome tracker for the finally{} -- script-scope so a mid-try exit
# captures the right disposition before Stop-LogFile emits cycle_end.
# 'unknown' is the safe default if control bails before either of the
# success/failure branches assigns.
$script:TestSequenceOutcome = 'unknown'
$script:TestSequenceReason  = ''
try {
    # Pass the planner's List[object] straight through -- do NOT wrap in @().
    # Resolve-TestSequencePlan always returns chainEntries as a List (an IList),
    # which binds directly to the IList parameter. Wrapping a generic List in @()
    # yields an array that a Mandatory [IList]/[object[]] parameter rejects with
    # "Argument types do not match" (a PowerShell @()-over-List binding quirk), so
    # the wrap would break the very single-entry warm path it appears to protect.
    $result = Invoke-TestSequenceChain `
        -ChainEntries $ChainEntries `
        -ChainPlan $ChainPlan `
        -StartStep $StartStep `
        -EffectiveStop $effectiveStop `
        -StopStep $StopStep `
        -ChainTotalSteps $totalSteps `
        -HostType $HostType `
        -GuestKey $GuestKey `
        -VMName $VMName `
        -SequenceName $SequenceName `
        -ShowSensitive:$ShowSensitive
    if (-not $result.ok) {
        # Evidence first: the guest is still up and holding the state that failed.
        $failedVm = if ($result.finishedVmName) { [string]$result.finishedVmName } else { $VMName }
        Save-ChainFailureArtifact -VMName $failedVm -GuestKey $GuestKey -RepoRoot $RepoRoot -ModulesDir $ModulesDir
        $script:TestSequenceOutcome = 'fail'
        $script:TestSequenceReason  = "chain '$SequenceName' (StartStep=$StartStep)"
        exit $ExitFailure
    }
    if ($result.finishedVmName -ne $VMName) { $VMName = $result.finishedVmName }
    $script:TestSequenceOutcome = 'pass'
    exit $ExitOk
} finally {
    # Ctrl+C cleanup: stop the VM so an interrupted run does not orphan
    # a half-baked guest holding host CPU + memory. Normal completion
    # leaves the VM running so the dev can ssh in and iterate. The disk
    # is retained on cancel too -- inspection via virsh / vmconnect /
    # utmctl stays available; only the running process is reclaimed.
    if ($script:CancelState -and $script:CancelState['Requested'] -and $VMName) {
        try {
            # Contract Stop-VM returns [bool] (only Start-VM returns the
            # { success; errorMessage } hashtable shape).
            if (Stop-VM -VMName $VMName -Confirm:$false -ErrorAction Stop) {
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_be382a2694862437' -Arguments @{ vMName = "$VMName" })
            } else {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_28891a03368609b9' -Arguments @{ vMName = "$VMName" })
            }
        } catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_847b851dc7bf561b' -Arguments @{ vMName = "$VMName"; message = "$($_.Exception.Message)" })
        }
    }
    Unregister-EntryPointCancelHandler
    # Finalize the status.json cycle row so the dashboard's history table
    # reflects this Debug-TestSequence run. 'unknown' (mid-try exit before
    # outcome was assigned) is recorded as 'fail' -- a cycle the operator
    # walked away from is closer to a failed cycle than a clean pass for
    # downstream automation (notification, retry, history pruning).
    $finalOutcome = if ($script:TestSequenceOutcome -eq 'pass') { 'pass' } else { 'fail' }
    if ($isNested) {
        # NESTED: finalize only OUR node + seal OUR transcript. Do NOT
        # Complete-Run / Stop-LogFile / rename the folder -- those finalize the
        # OWNER's cycle, which this run does not own.
        if ($nestedNodeId -and (Get-Command Set-NestedRunStatus -ErrorAction SilentlyContinue)) {
            Set-NestedRunStatus -StatusPath $StatusFile -NodeId $nestedNodeId -Status $finalOutcome -ErrorMessage $script:TestSequenceReason
        }
        if (Get-Command Stop-NestedLogFile -ErrorAction SilentlyContinue) { Stop-NestedLogFile }
    } else {
        # OWNER: finalize the cycle row this run owns.
        if (Get-Command Set-StepStatus -ErrorAction SilentlyContinue) {
            Set-StepStatus -GuestKey $GuestKey -StepName 'Sequence' -Status $finalOutcome -ErrorMessage $script:TestSequenceReason -Confirm:$false
        }
        if (Get-Command Set-GuestStatus -ErrorAction SilentlyContinue) {
            Set-GuestStatus -GuestKey $GuestKey -Status $finalOutcome -Confirm:$false
        }
        if (Get-Command Complete-Run -ErrorAction SilentlyContinue) {
            $maxHistory = 30
            if ($Config -is [System.Collections.IDictionary] -and
                $Config.testCycle -is [System.Collections.IDictionary] -and
                $Config.testCycle.recentDisplayCount) {
                $maxHistory = [int]$Config.testCycle.recentDisplayCount
            }
            Complete-Run -OverallStatus $finalOutcome -MaxHistoryRuns $maxHistory
        }
        Stop-LogFile -Outcome $script:TestSequenceOutcome -Reason $script:TestSequenceReason
    }
}
