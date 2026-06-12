<#PSScriptInfo
.VERSION 2026.06.12
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456708
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
    the cycle planner walks), Test-Sequence runs every prereq sequence
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
                          (Invoke-TestRunner). Turn on only for one-off
                          local debugging; never share a transcript captured
                          with this switch on.
.PARAMETER NoConfigGate   Skip the pre-cycle Test-Config.ps1 preflight.
                          Default: gate runs (matches Invoke-TestRunner). Use
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

    # Skip the built-in HTTP status server, matching Invoke-TestRunner /
    # Invoke-TestInnerRunner. Without it, an enabled statusService is started
    # (restarted) so the dashboard tracks this run.
    [switch]$NoServer,

    # Three-state: omitted -> read from test.config.yml.logLevel;
    # explicit value -> override (wins over YAML). Single-pass resolution
    # below — this script doesn't run a long-lived cycle loop.
    [ValidateSet('Error', 'Warning', 'Information', 'Verbose', 'Debug', IgnoreCase = $true)]
    [string]$logLevel
)

# Cmdline override for three-state resolution further down (after config
# load). PSBoundParameters is the only reliable source — `[string]` defaults
# to '' when omitted.
$script:CmdLineLogLevel = if ($PSBoundParameters.ContainsKey('logLevel')) { $logLevel } else { $null }

# === Resolve paths ===
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

# Canonical exit codes (centralised in Test.Prelude so a future change
# to the contract -- e.g. introduce code 2 for "needs operator action" --
# lands in one place rather than touching ~15 bare `exit 1` sites here.)
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure

# === Canonical module set for the Sequence entry-point ===
# Test.LogLevel + Test.Config + Test.SequenceAction + Test.HostIO +
# Test.HostContract + Test.Log + Invoke-Sequence + Test.SequencePlanner +
# Test.YurunaDir + Test.OcrEngine + Test.Tesseract +
# Test.ConfigPreflight. Order in the helper matches the prior inline
# sequence (planner AFTER engine so the engine's -Force re-import
# inside the planner doesn't evict the just-imported engine).
$savedVerbose = $global:VerbosePreference
$global:VerbosePreference = "SilentlyContinue"
Initialize-YurunaEntryPointModuleSet -For Sequence -ModulesDir $ModulesDir
# Yuruna.Log proxy is in automation/, not test/modules/, so it's not
# part of the canonical set; load it inline.
$yurunaLogModule = Join-Path -Path $RepoRoot -ChildPath "automation" -AdditionalChildPath "Yuruna.Log.psm1"
if (Test-Path $yurunaLogModule) {
    Import-Module $yurunaLogModule -Global -Force
}
# Test.SequenceRunner.psm1 holds the chain-planning + chain-execution
# blocks extracted out of this script so they can be unit-tested with
# fixture data (see test/modules/Test.SequenceRunner.psm1 header).
Import-Module (Join-Path $ModulesDir 'Test.SequenceRunner.psm1') -Global -Force
$global:VerbosePreference = $savedVerbose

# === logLevel resolution: cmdline > YAML > 'Information' ===
# Canonical cascade: Test.LogLevel.psm1. See docs/loglevels.md.
# Reset + repopulate the sequence-action / host-I/O registries so a
# stale extension registered earlier in the same shell cannot shadow
# a renamed verb today. Rationale + ordering live in Test.Prelude.
Initialize-SequenceEngineRegistry -ModulesDir $ModulesDir -Confirm:$false
$cfgForLevel = Read-TestConfig -Path $ConfigPath
$configLevel = Get-TestConfigValue -Config $cfgForLevel -Path 'logLevel'
$null = Test.LogLevel\Resolve-LogLevel -CmdLineLevel $script:CmdLineLogLevel -ConfigLevel $configLevel

# Auto-relaunch under sg libvirt on host.ubuntu.kvm when this shell's
# group set lacks libvirt -- Test-Sequence runs the engine which
# calls virsh / virt-install on demand. No-op on other hosts / fresh
# shells.
Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

# === Read config ===
$Config = Read-TestConfig -Path $ConfigPath
if (-not $Config) { Write-Error "Config not found or unparseable: $ConfigPath"; exit $ExitFailure }

# === Pre-cycle config gate ==================================================
# Mirror Invoke-TestRunner: refuse to bring up a VM when test.config.yml /
# vault.yml / users.yml / transports.yml are in a state Test-Config.ps1
# would reject. Without this gate a sequence can "pass" under Test-Sequence
# (extension quirks-mode covers misconfig) while the runner refuses to even
# start the cycle on the same config -- exactly the kind of confusing
# surprise this gate guards against. Bypass with -NoConfigGate for
# ad-hoc / in-progress edits.
# Spawn a fresh pwsh so an Out-Of-Order ::Stop early-exit inside Test-Config
# cannot unwind this script. -SkipSend stops the smoke-test email from
# flooding subscribers["config.smoke"] on every Test-Sequence invocation.
# Test.ConfigPreflight was imported by Initialize-YurunaEntryPointModuleSet above.
$gate = Invoke-ConfigGate -TestRoot $TestRoot -ConfigPath $ConfigPath -Skip:$NoConfigGate -CallerName 'Test-Sequence'
if (-not $gate.passed) { exit $gate.exitCode }

# === Refresh <RepoRoot>/project from test.config.yml's repositories.projectUrl ===
# Mirror Invoke-TestInnerRunner: the cycle's planner (and Resolve-SequencePath
# right below) reads project-tree sequences from <RepoRoot>/project/, so an
# absent or stale clone makes Test-Sequence silently diverge from the runner.
# Skipped when repositories.projectUrl is empty (in-tree project layout).
# Failure aborts before VM bring-up, same as the runner.
$projUrl = $null
if ($Config -is [System.Collections.IDictionary] -and
    $Config.repositories -is [System.Collections.IDictionary] -and
    $Config.repositories.Contains('projectUrl')) {
    $projUrl = [string]$Config.repositories.projectUrl
}
$cloneRes = Update-ProjectClone -RepoRoot $RepoRoot -ProjectUrl $projUrl -Confirm:$false
if (-not $cloneRes.success) {
    Write-Warning ""
    Write-Warning "============================================================"
    Write-Warning "  Project clone FAILED: $($cloneRes.errorMessage)"
    Write-Warning "  Test-Sequence cannot resolve project-tree sequences without"
    Write-Warning "  <RepoRoot>/project/. Fix repositories.projectUrl in"
    Write-Warning "  test.config.yml (or empty it to use the in-tree project)."
    Write-Warning "============================================================"
    exit $ExitFailure
}

# === Ensure status server is running (restart to pick up any changes) ===
# Shared gate (Test.Prelude) so isEnabled / -NoServer / port / restart match the
# inner runner. -Restart: a re-invoked Test-Sequence must pick up edits.
$startScript = Join-Path $TestRoot "Start-StatusService.ps1"
$null = Start-YurunaStatusServiceIfEnabled -Config $Config -StartScript $startScript -NoServer:$NoServer -Restart

# === Detect host ===
# HostType is resolved BEFORE sequence resolution so Resolve-SequencePath can
# prefer a per-host sequence variant (e.g. <Name>.ubuntu.kvm.yml) over the
# generic <Name>.yml -- needed because KVM cloud-image guests skip the
# autoinstall flow that Hyper-V/UTM autoinstall guests run through.
$HostType = Get-HostType
if (-not $HostType) { exit $ExitFailure }
Write-Output "Host type: $HostType"

# === Resolve sequence file ===
# Sequences live in mode subfolders (sequences/gui/, sequences/ssh/) under
# the framework, and project/<...>/test/<mode>/ under the per-cycle clone.
# Resolve-SequencePath checks the project tree first, then the framework,
# with gui fallback for missing ssh variants. If nothing matches, list
# everything available across both trees.
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
    Write-Output "Sequence path: $SequencePathOverride (basename: $SequenceName)"
    # Heads-up: if a host-variant sibling exists, Resolve-SequencePath
    # would have picked it (the runner does). Path-override skips that
    # tier, so warn loudly -- otherwise the operator thinks Test-Sequence
    # validated what the runner will execute, when it didn't.
    $hostShort = $HostType -replace '^host\.',''
    if ($SequenceName -notmatch "\.$([regex]::Escape($hostShort))$") {
        $overrideDir  = Split-Path -Parent $SequencePathOverride
        $overrideExt  = [System.IO.Path]::GetExtension($SequencePathOverride)
        $variantPath  = Join-Path $overrideDir "$SequenceName.$hostShort$overrideExt"
        if (Test-Path -LiteralPath $variantPath) {
            Write-Warning "Host-variant sibling exists: $variantPath"
            Write-Warning "  Invoke-TestRunner would pick the variant on $HostType, but Test-Sequence is running the generic file you passed."
            Write-Warning "  Pass the variant path explicitly to match runner behavior."
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
    Write-Error "Sequence file not found: $SequenceName"
    Write-Output "Searched (no match):"
    foreach ($p in $searched) { Write-Output "  $p" }
    Write-Output ""
    Write-Output "Available sequences:"
    foreach ($mode in @('gui', 'ssh')) {
        $modeDir = Join-Path $SequencesDir $mode
        $projectDirs = Get-ProjectTestSearchDir -RepoRoot $RepoRoot -Mode $mode
        if ((-not (Test-Path $modeDir)) -and ($projectDirs.Count -eq 0)) { continue }
        Write-Output "  [$mode]"
        $allDirs = @()
        if (Test-Path $modeDir) { $allDirs += $modeDir }
        $allDirs += $projectDirs
        $allDirs |
            ForEach-Object { Get-ChildItem -Path $_ -Filter "*.yml" -ErrorAction SilentlyContinue } |
            Sort-Object BaseName -Unique |
            ForEach-Object { Write-Output "    $($_.BaseName)" }
    }
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
Write-Output "Track directory: $env:YURUNA_RUNTIME_DIR"
Write-Output "Log directory:   $env:YURUNA_LOG_DIR"

# === Single-instance guard ==================================================
# Refuse to start when an Invoke-TestRunner already owns the runtime dir.
# Test-Sequence is a dev entry point: it does not coordinate the runner
# state machine, so a concurrent run would race the runner's pidfile,
# status.json registrations, and VM operations. Get-RunnerInstanceState
# (Test.SingleInstance) does the read; Assert-NoOtherRunner wraps it
# with the "refuse + banner" semantics this entry point needs --
# Invoke-TestRunner's takeover path is the opposite (Stop-StaleRunner).
if (-not (Assert-NoOtherRunner -RuntimeDir $env:YURUNA_RUNTIME_DIR -CallerName 'Test-Sequence')) {
    exit $ExitFailure
}

# === Ctrl+C handler =========================================================
# Register a CancelKeyPress handler that flips $script:CancelState['Requested']
# instead of letting Ctrl+C tear the runspace down mid-step. The finally{}
# block below polls the flag and stops the VM so a half-baked guest
# (interrupted during New-VM / Start-VM / a long sequence step) doesn't
# linger consuming host CPU + memory. The disk is intentionally kept so
# the operator can inspect post-mortem via virsh / vmconnect / utmctl.
$script:CancelState = Register-EntryPointCancelHandler

# Archive any break-active.json left behind by a prior Test-Sequence /
# Invoke-TestRunner that crashed (or was Ctrl-C'd) while paused at a
# breakpoint. Otherwise the stale file would tell the status UI that a
# Continue is pending for THIS new run before its break step has even
# fired -- and the next break would write over the stale file with no
# audit trail of what the previous one was paused on. Resolve-Stale-
# BreakActive renames to break-active.<UTC>.json.aborted so forensics
# survive. Same helper Invoke-TestRunner's outer-startup sweep runs.
if (Get-Command Resolve-StaleBreakActive -ErrorAction SilentlyContinue) {
    $null = Resolve-StaleBreakActive -RuntimeDir $env:YURUNA_RUNTIME_DIR -Confirm:$false
}

# Clear any stale control.cycle-restart flag. The status server's
# /control/start-cycle endpoint writes this file to ask the runner to
# rewind to step 1. If Invoke-TestRunner was Ctrl-C'd between flag write
# and flag consumption, the file persists. Invoke-Sequence Gate #1 would
# then throw YurunaCycleRestart on our first step and exit non-zero --
# making it look like the SEQUENCE broke, when really it was leftover
# inter-cycle control state. Mirror Invoke-TestInnerRunner: a freshly
# starting Test-Sequence IS the restart, so consume the flag here.
$restartFlag = Join-Path $env:YURUNA_RUNTIME_DIR 'control.cycle-restart'
if (Test-Path -LiteralPath $restartFlag) {
    try {
        Remove-Item -LiteralPath $restartFlag -Force -ErrorAction Stop
        Write-Verbose "Cleared stale control.cycle-restart flag."
    } catch {
        Write-Verbose "Could not clear control.cycle-restart: $($_.Exception.Message)"
    }
}

# Clear any leftover pause flags (control.step-pause / .cycle-pause).
# A fresh Test-Sequence invocation should never inherit a pause request
# from a prior session the operator never explicitly resumed -- the
# operator typed THIS command line, so we honour the intent to run, not
# the stale flag. Same helper Invoke-YurunaBootRecovery uses.
if (Get-Command Clear-StalePauseFlag -ErrorAction SilentlyContinue) {
    $null = Clear-StalePauseFlag -RuntimeDir $env:YURUNA_RUNTIME_DIR -Confirm:$false
}

$activeEngines = Get-EnabledOcrProvider
$combineMode = ($env:YURUNA_OCR_COMBINE -eq 'And') ? 'And' : 'Or'
Write-Output "OCR engines: $($activeEngines -join ', ') | combine: $combineMode"
if (-not (Assert-TesseractInstalled)) { exit $ExitFailure }

# === Derive GuestKey from the sequence's baseline map ===
# Source of truth is the sequence's `baseline:` field -- whichever OS
# key(s) it lists tell us which guest VM the sequence targets. The
# filename is NOT authoritative: a typo or rename would otherwise
# silently derail the whole chain (and a project sequence like
# `ch01.website.example.yml` has no guest token in its name at all).
# Same lookup the cycle planner uses in Resolve-CyclePlan
# (Test.SequencePlanner.psm1) for Invoke-TestRunner / Test-Project,
# kept symmetric so Test-Sequence behaves the same standalone.
if ($GuestKey) {
    Write-Output "Guest key (override): $GuestKey"
} else {
    try {
        $topSeq = Read-SequenceFile -Path $SequencePath
    } catch {
        Write-Error "Could not parse sequence file '$SequencePath': $($_.Exception.Message)"
        exit $ExitFailure
    }
    $osKeys = @()
    if ($topSeq -is [System.Collections.IDictionary] -and
        $topSeq.baseline -is [System.Collections.IDictionary] -and
        $topSeq.baseline.Keys.Count -gt 0) {
        $osKeys = @($topSeq.baseline.Keys)
    }
    if ($osKeys.Count -eq 0) {
        Write-Error "Sequence '$SequenceName' has no 'baseline:' OS key in $SequencePath. Add a 'baseline:' block (e.g. 'baseline: { amazon.linux.2023: [start.guest.amazon.linux.2023] }') or pass -GuestKey explicitly."
        exit $ExitFailure
    }
    $osKey = $osKeys[0]
    if ($osKeys.Count -gt 1) {
        Write-Warning "Sequence '$SequenceName' declares multiple baseline OS keys ($($osKeys -join ', ')). Test-Sequence will target '$osKey'. Pass -GuestKey to choose explicitly."
    }
    $GuestKey = "guest.$osKey"
    Write-Output "Guest key (from baseline): $GuestKey"
}

# Final safety net: even an explicit -GuestKey must point to a real folder.
if (-not (Test-GuestFolder -RepoRoot $RepoRoot -HostType $HostType -GuestKey $GuestKey)) {
    $folder = Join-Path $RepoRoot (Join-Path (Get-HostFolder $HostType) $GuestKey)
    Write-Error "Guest folder not found for '$GuestKey' on $HostType`: $folder"
    Write-Output "  Add Get-Image.ps1 + New-VM.ps1 under that path to enable this guest, or"
    Write-Output "  correct -GuestKey to a guest that exists on this host."
    exit $ExitFailure
}

# === Derive VM name (use -VMName override if provided) ===
if (-not $VMName) {
    $Prefix = $Config.vmStart.testVmNamePrefix ?? "test-"
    $VMName = Get-TestVMName -GuestKey $GuestKey -Prefix $Prefix
}

# === UTM concurrent-VM pre-flight ===========================================
# macOS vmnet-shared assigns one host-side bridge interface per vmnet
# "session" (bridge100, bridge101, ...). Two concurrent UTM VMs land on
# different bridges that don't route between each other. Observed: an
# unrelated macos-26-01 running before the cycle pushed the test guests
# onto bridge101, breaking the cloud-init host-proxy URL baked into
# seed.iso. Refuse the cycle if anything else is running. The
# operator's own target VM ($VMName) is exempted so the iterate-on-an-
# existing-VM dev loop still works (Test-Sequence reuses a running VM
# at line below).
if ($HostType -eq 'host.macos.utm') {
    if (-not (Assert-NoConcurrentUtmVm -ExceptVmName $VMName)) { exit $ExitFailure }
}

# === Build chain plan ===
# Chain planning + warm-path requiresSnapshot probe live in
# Test.SequenceRunner.psm1 so they can be unit-tested with fixture
# data. Behavior identical to the previous inline blocks: walk the
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
$ChainTotalSteps    = $plan.chainTotalSteps
$requiredSnapshotId = $plan.requiredSnapshotId
if ($plan.warmPath) { $VMName = $requiredSnapshotId }

# Same cascade registration as Invoke-TestInnerRunner: Test.Ssh's
# Get-GuestSshUser is the lookup point for Save-GuestDiagnostic +
# host-driver SSH-mode Send-Text / fetchAndExecute SSH. Standalone
# Test-Sequence runs the same chain as a one-off, so register the
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

# === Promote vmStart.cachingProxyIP config -> env ==========================
# Invoke-TestInnerRunner reads BOTH $env:YURUNA_CACHING_PROXY_IP and
# $Config.vmStart.cachingProxyIP (the persistent UI-edited key) before
# probing. Without this promotion, a proxy configured only via the status
# server's Edit-config page is invisible to Test-Sequence's
# Test-CachingProxyAvailable call. Bridge them here so both paths agree.
# Empty env wins (operator can clear the env to test the no-cache branch
# even when the config has a stale IP).
if (-not $env:YURUNA_CACHING_PROXY_IP -and
    $Config.vmStart -is [System.Collections.IDictionary] -and
    $Config.vmStart.Contains('cachingProxyIP')) {
    $cfgCacheIp = "$($Config.vmStart.cachingProxyIP)".Trim()
    if ($cfgCacheIp -and (Test-IpAddress $cfgCacheIp)) {
        $env:YURUNA_CACHING_PROXY_IP = $cfgCacheIp
        Write-Verbose "Promoted vmStart.cachingProxyIP=$cfgCacheIp into env."
    }
}

# === Resolve caching proxy URL ===
# Mirror Invoke-TestInnerRunner: resolve once via Test-CachingProxyAvailable
# (honors $Env:YURUNA_CACHING_PROXY_IP for remote caches, falls back to
# locally-recorded state) and forward to New-VM so the guest's cloud-init
# user-data templates the proxy URL. Without this forward, the per-guest
# New-VM.ps1 falls into local Get-VM yuruna-caching-proxy discovery and
# warns "no cache" even when the operator has a healthy remote cache.
$cachingProxyUrl = Test-CachingProxyAvailable
$newVmProxy = if ($cachingProxyUrl) { $cachingProxyUrl } else { "" }
if ($newVmProxy) {
    Write-Output "Caching proxy: $newVmProxy (forwarded to New-VM)"
} else {
    Write-Output "Caching proxy: none -- guest will download directly."
}

# === Ensure VM exists (reuse or create) ===
if ((Get-VMState -VMName $VMName) -ne 'absent') {
    Write-Output "VM '$VMName' already exists. Reusing."
} else {
    Write-Output "VM '$VMName' not found. Creating..."
    # Forward -Username when the sequence declares one. Mirrors
    # Invoke-TestInnerRunner's effectiveUsername forward (the cascade-walk
    # is not feasible standalone, but the sequence's own variables.username
    # is the only override Test-Sequence can honor without the planner).
    # Empty $effectiveUser falls through to the per-host New-VM default --
    # matches today's behavior when no plan resolves.
    if ($effectiveUser) {
        Write-Verbose "Forwarding -Username '$effectiveUser' from $($SequenceName).variables.username."
        $r = New-VM -GuestKey $GuestKey -RepoRoot $RepoRoot -VMName $VMName -Username $effectiveUser -CachingProxyUrl $newVmProxy -Confirm:$false
    } else {
        $r = New-VM -GuestKey $GuestKey -RepoRoot $RepoRoot -VMName $VMName -CachingProxyUrl $newVmProxy -Confirm:$false
    }
    if (-not $r.success) {
        Write-Error "New-VM failed: $($r.errorMessage)"
        exit $ExitFailure
    }
    Write-Output "VM '$VMName' created."
}

# === Ensure VM is running ===
# Skipped when the chain's first step is `loadDiskSnapshot`: that handler
# tolerates a stopped VM as input (its host driver gates the pre-restore
# Stop-VM on `if running`), runs the restore against the offline disk,
# and starts the VM itself on return. Pre-booting here would only force
# the handler to immediately Stop-VM again -- a wasted Start+Wait cycle
# (~15-20s of boot-delay + Hyper-V cold-stop poll) on every warm-path run.
$VmStartTimeout = $Config.vmStart.startTimeoutSeconds ? [int]$Config.vmStart.startTimeoutSeconds : 120
$VmBootDelay    = $Config.vmStart.bootDelaySeconds    ? [int]$Config.vmStart.bootDelaySeconds    : 15

$firstStepAction = $null
if ($ChainEntries.Count -gt 0) {
    $firstSteps = @($ChainEntries[0].sequence.steps)
    if ($firstSteps.Count -gt 0) { $firstStepAction = [string]$firstSteps[0].action }
}

if ($firstStepAction -eq 'loadDiskSnapshot') {
    Write-Output "VM '$VMName': skipping pre-sequence start -- first step is loadDiskSnapshot (handler will start the VM after the restore)."
} elseif ((Get-VMState -VMName $VMName) -eq 'running') {
    Write-Output "VM '$VMName' is already running."
} else {
    Write-Output "Starting VM '$VMName'..."
    $r = Start-VM -VMName $VMName -Confirm:$false
    if (-not $r.success) {
        Write-Error "Start-VM failed: $($r.errorMessage)"
        exit $ExitFailure
    }
    $ok = Wait-VMRunning -VMName $VMName `
        -TimeoutSeconds $VmStartTimeout -BootDelaySeconds $VmBootDelay
    if (-not $ok) {
        Write-Error "VM '$VMName' did not reach running state within ${VmStartTimeout}s."
        exit $ExitFailure
    }
    Write-Output "VM '$VMName' is running."
}

# === Validate StartStep / StopStep against the chain's TOTAL step count ===
# $ChainTotalSteps was computed by the chain-plan block above. With a
# single-sequence chain (no baseline OR path-override) this is exactly
# the old single-sequence step count; with prereqs it covers the whole
# concatenated execution.
$totalSteps = $ChainTotalSteps

if ($StartStep -lt 1 -or $StartStep -gt $totalSteps) {
    Write-Error "StartStep $StartStep is out of range. The chain has $totalSteps steps (1-$totalSteps)."
    exit $ExitFailure
}

if ($StopStep -ne 0) {
    if ($StopStep -lt $StartStep) {
        Write-Warning "StopStep ($StopStep) must be greater than or equal to StartStep ($StartStep). Stopping."
        exit $ExitFailure
    }
    if ($StopStep -gt $totalSteps) {
        Write-Warning "StopStep $StopStep exceeds total steps ($totalSteps). Clamping to $totalSteps."
        $StopStep = $totalSteps
    }
}

$effectiveStop = $StopStep -ne 0 ? $StopStep : $totalSteps

$stopLabel = $StopStep -ne 0 ? ", stopping after step $effectiveStop" : ""

# === Register this run as a cycle in status.json ============================
# Without this block Test-Sequence runs landed under cycle "000000" with no
# row in the dashboard's history table, and break-active.json had no live
# cycle to anchor the Continue button against. Mirrors Invoke-TestInner-
# Runner's shape but uses a single 'Sequence' step (the inner runner's
# fixed phase pills -- New-VM / Start-VM / Start-GuestOS / ... -- would
# render four "pending" chips that never animate, since Test-Sequence
# skips those phase boundaries).
$StatusFile = Join-Path $env:YURUNA_RUNTIME_DIR 'status.json'
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
$SeqCycleId = Initialize-StatusDocument `
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

# --- Start log file (transcript captures all console output) ---
$CycleNumber = Get-CycleNumber
$LogFile    = Start-LogFile -TestRoot $TestRoot -CycleId $SeqCycleId -Hostname (hostname) -CycleNumber $CycleNumber
Write-Output "Log file: $LogFile"

Write-Output ""
Write-Output "============================================="
Write-Output "  Sequence: $SequenceName"
Write-Output "  Chain:    $($ChainPlan.fullChain.Count) sequence(s), $totalSteps total step(s)"
Write-Output "  Range:    starting at step $StartStep$stopLabel"
Write-Output "  VM:       $VMName"
Write-Output "  Guest:    $GuestKey"
Write-Output "============================================="

Write-Output ""
Write-Output "Step list:"
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

# === Run each chain entry that overlaps the requested step range ===
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
            $stopResult = Stop-VM -VMName $VMName -Confirm:$false -ErrorAction Stop
            if ($stopResult -and $stopResult.success) {
                Write-Output "Stopped VM '$VMName' after Ctrl+C (disk retained for inspection)."
            } elseif ($stopResult) {
                Write-Warning "Stop-VM '$VMName' after Ctrl+C reported: $($stopResult.errorMessage)"
            }
        } catch {
            Write-Warning "Could not stop VM '$VMName' after Ctrl+C: $($_.Exception.Message)"
        }
    }
    Unregister-EntryPointCancelHandler
    # Finalize the status.json cycle row so the dashboard's history table
    # reflects this Test-Sequence run. 'unknown' (mid-try exit before
    # outcome was assigned) is recorded as 'fail' -- a cycle the operator
    # walked away from is closer to a failed cycle than a clean pass for
    # downstream automation (notification, retry, history pruning).
    $finalOutcome = if ($script:TestSequenceOutcome -eq 'pass') { 'pass' } else { 'fail' }
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

