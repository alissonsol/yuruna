<#PSScriptInfo
.VERSION 2026.10.18.2
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

.PARAMETER SequenceName
    Base name (no .yml, e.g. "workload.guest.ubuntu.server.24")
    OR a path to an existing .yml sequence file. The path
    form is shell-tab-completion friendly; it supplies the
    top-level file directly while the baseline chain is
    still walked via the standard search paths. GuestKey
    is derived from the basename. Required.
.PARAMETER StartStep
    1-based start step in the CONCATENATED chain. Default 1.
.PARAMETER StopStep
    1-based stop (inclusive) in the CONCATENATED chain.
    VM left running after.
.PARAMETER ConfigPath
    Default: test/test.config.yml.
.PARAMETER VMName
    Override the VM name (default: derived from guest key).
.PARAMETER GuestKey
    Override guest-folder lookup. Default: walk dotted
    prefixes of the name after the first dot, longest
    first, and pick the first one with a
    host/<short>/<guestKey>/ folder. Needed when a
    cascade-child sequence (e.g.
    workload.guest.ubuntu.server.24.k8s.text-to-sql.baseline)
    must reuse a shorter guest's scripts but the walk
    would pick the wrong base.
.PARAMETER ShowSensitive
    Print expanded passwords / vault secrets in the
    transcript. OFF by default to match production
    (Start-TestRunner). Turn on only for one-off
    local debugging; never share a transcript captured
    with this switch on.
.PARAMETER NoConfigGate
    Skip the pre-cycle Test-Config.ps1 preflight.
    Default: gate runs (matches Start-TestRunner). Use
    for in-progress edits where you want to iterate on
    a sequence while test.config.yml / vault.yml /
    users.yml are still being adjusted.
.PARAMETER logLevel
    Error|Warning|Information|Verbose|Debug. Each level shows itself + all higher-priority streams (Error highest). Omit to read test.config.yml.logLevel (default "Information").
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
    # ONCE before iterating its inner sequences, then passes this so each child
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

# A Windows console code page prints Chinese and Hebrew catalog text as
# question marks; YURUNA_KEEP_CONSOLE_ENCODING=1 keeps the console's own.
if ($IsWindows -and $env:YURUNA_KEEP_CONSOLE_ENCODING -ne '1') { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) }

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

# The steps this run took, in order, for the typed result recorded at every exit.
$script:RecoverySteps = [System.Collections.Generic.List[object]]::new()
# --- REGION: Save-SequenceRecoveryResult
function Save-SequenceRecoveryResult {
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][int]$ExitCode)
    # A nested run is a step of its owner's cycle; the owner records the result.
    if ($isNested -or -not (Get-Command Save-RecoveryResult -ErrorAction SilentlyContinue)) { return }
    $null = Save-RecoveryResult -EntryPoint sequence -ExitCode $ExitCode -Steps @($script:RecoverySteps)
}

# --- REGION: Canonical module set for the Sequence entry-point
# See https://yuruna.link/42010605-0002
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
# See https://yuruna.link/42010605-0002
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

# --- REGION: Elevation check
# See https://yuruna.link/42010605-0002
if (-not (Assert-Elevation -HostType (Get-HostType))) { exit $ExitFailure }

# --- REGION: Read config
$Config = Read-TestConfig -Path $ConfigPath
if (-not $Config) { Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_f62563beddeea65d' -Arguments @{ configPath = "$ConfigPath" }); exit $ExitFailure }

# --- REGION: Pre-cycle config gate
# See https://yuruna.link/42010605-0002
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
    $checkoutStep = Invoke-CycleCheckoutStep -RepoRoot $RepoRoot -ProjectUrl $projUrl
    [void]$script:RecoverySteps.Add($checkoutStep)
    $cloneRes = @{ success = $checkoutStep.Ok; skipped = $checkoutStep.Skipped; errorMessage = $checkoutStep.ErrorMessage }
    if (-not $cloneRes.success) {
        Write-Warning ""
        Write-Warning "========"
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_62763311ebf835f2' -Arguments @{ errorMessage = "$($cloneRes.errorMessage)" })
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_30850c083e8c60e9')
        Write-Warning "  <RepoRoot>/project/. Fix repositories.projectUrl in"
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_a8bdd8fe43f4954f')
        Write-Warning "========"
        Save-SequenceRecoveryResult -ExitCode $ExitFailure
        exit $ExitFailure
    }
}

# --- REGION: Start the host status service
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
# See https://yuruna.link/42010605-0002
$SequencePathOverride = $null
try {
    $resolved = Resolve-Path -LiteralPath $SequenceName -ErrorAction Stop
    if ($resolved -and (Test-Path -LiteralPath $resolved.Path -PathType Leaf) -and
        ($resolved.Path -like '*.yml' -or $resolved.Path -like '*.yaml')) {
        $SequencePathOverride = $resolved.Path
        $SequenceName = [System.IO.Path]::GetFileNameWithoutExtension($SequencePathOverride)
    }
} catch { $null = $_ }

# See https://yuruna.link/42010605-0002
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
# See https://yuruna.link/42010605-0002
if (-not $isNested -and -not (Assert-NoOtherRunner -RuntimeDir $env:YURUNA_RUNTIME_DIR -CallerName 'Debug-TestSequence')) {
    exit $ExitFailure
}

# --- REGION: Ctrl+C handler
# See https://yuruna.link/42010605-0002
$script:CancelState = Register-EntryPointCancelHandler

# See https://yuruna.link/42010605-0002
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
# See https://yuruna.link/42010605-0002
$topLevelDoc = $null
try { $topLevelDoc = Read-SequenceFile -Path $SequencePath } catch {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_0eb9acf2273e09fd' -Arguments @{ sequencePath = "$SequencePath"; message = "$($_.Exception.Message)" })
    exit $ExitFailure
}
if (Test-IsOrchestrationSequence -Sequence $topLevelDoc) {
    # See https://yuruna.link/42010605-0002
    $admissionStep = Invoke-CycleAdmissionStep -HostType $HostType
    [void]$script:RecoverySteps.Add($admissionStep)
    if (-not $admissionStep.Ok) {
        Save-SequenceRecoveryResult -ExitCode $admissionStep.ExitCode
        exit $admissionStep.ExitCode
    }
    $orchRc = Invoke-OrchestrationSequence `
        -Sequence $topLevelDoc -SequencePath $SequencePath `
        -RepoRoot $RepoRoot -SequencesDir $SequencesDir -TestRoot $TestRoot `
        -HostType $HostType -Config $Config -ShowSensitive:$ShowSensitive
    Unregister-EntryPointCancelHandler
    $orchExit = ($orchRc -eq 0 ? $ExitOk : $ExitFailure)
    Save-SequenceRecoveryResult -ExitCode $orchExit
    exit $orchExit
}

# --- REGION: Derive GuestKey from the sequence's baseline map
# See https://yuruna.link/42010605-0002
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

# --- REGION: Derive VM name
if (-not $VMName) {
    $Prefix = $Config.vmStart.testVmNamePrefix ?? "test-"
    $VMName = Get-TestVMName -GuestKey $GuestKey -Prefix $Prefix
}

# --- REGION: Build chain plan
# See https://yuruna.link/42010605-0002
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

# --- REGION: Concurrent-VM admission
# See https://yuruna.link/42010605-0002
$admissionStep = Invoke-CycleAdmissionStep -HostType $HostType -ExceptVmName $VMName
[void]$script:RecoverySteps.Add($admissionStep)
if (-not $admissionStep.Ok) {
    Save-SequenceRecoveryResult -ExitCode $admissionStep.ExitCode
    exit $admissionStep.ExitCode
}

# --- REGION: SSH-user override
# See https://yuruna.link/42010605-0002
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
# See https://yuruna.link/42010605-0002
$envCacheIp    = if ($env:YURUNA_CACHING_PROXY_SERVICE_IP) { $env:YURUNA_CACHING_PROXY_SERVICE_IP.Trim() } else { '' }
$configCacheIp = ''
if ($Config.vmStart -is [System.Collections.IDictionary] -and $Config.vmStart.Contains('cachingProxyIp')) {
    $configCacheIp = "$($Config.vmStart.cachingProxyIp)".Trim()
}
$requiresCacheRegistry = Test-SequenceRequiresCacheRegistry -SequenceName @(
    @($ChainEntries | ForEach-Object { [string]$_.name }) + $SequenceName
)
$cacheEndpoint = $null
if (($envCacheIp -or $configCacheIp) -and (Get-Command Resolve-CachingProxyServiceEndpoint -ErrorAction SilentlyContinue)) {
    $endpoint = Resolve-CachingProxyServiceEndpoint -EnvIp $envCacheIp -ConfigIp $configCacheIp
    $cacheEndpoint = $endpoint
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
# See https://yuruna.link/42010605-0002
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
    # See https://yuruna.link/42010605-0002
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
    # See https://yuruna.link/42010605-0002
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
# See https://yuruna.link/42010605-0002
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

# --- REGION: Register this run as a cycle in status.json
# See https://yuruna.link/42010605-0002
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
    $projectCommitReference = $null
    if ($Config.repositories -is [System.Collections.IDictionary] -and
        (Get-Command Get-ProjectGitCommitReference -ErrorAction SilentlyContinue)) {
        $projectCommitReference = Get-ProjectGitCommitReference -RepoRoot $RepoRoot -ProjectUrl $Config.repositories.projectUrl
    }
    $projectCommit = if ($projectCommitReference) { [string]$projectCommitReference.sha } else { $null }
    if ($projectCommitReference) { $gitCommitsList += $projectCommitReference }
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
                -HarnessCommit $frameworkCommit -ProjectCommit $projectCommit -Confirm:$false
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
# See https://yuruna.link/42010605-0002
$regWait = 900
if ($Config -and $Config.vmStart -is [System.Collections.IDictionary] -and
    $Config.vmStart.Contains('cachingProxyRegistryWaitSeconds')) {
    $regWait = [int]$Config.vmStart.cachingProxyRegistryWaitSeconds
}
if ($requiresCacheRegistry -and $cacheEndpoint -and $cacheEndpoint.EffectiveIp) {
    # VM preparation can overlap a cache rebuild. Check the required manifest
    # path at the last boundary before this direct sequence starts.
    $entryCache = Wait-CachingProxyServiceSettled -CacheIp $cacheEndpoint.EffectiveIp `
        -Port $cacheEndpoint.HttpPort -RegistryTimeoutSeconds $regWait -RequireRegistry
    foreach ($line in $entryCache.Lines) { Write-Output $line }
    if (-not $entryCache.Ready) {
        Write-Error ([string]$entryCache.Lines[-1])
        Save-SequenceRecoveryResult -ExitCode $ExitFailure
        exit $ExitFailure
    }
}
$script:TestSequenceOutcome = 'unknown'
$script:TestSequenceReason  = ''
try {
    # See https://yuruna.link/42010605-0002
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
    Save-SequenceRecoveryResult -ExitCode ($finalOutcome -eq 'pass' ? $ExitOk : $ExitFailure)
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
