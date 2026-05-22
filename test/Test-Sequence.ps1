<#PSScriptInfo
.VERSION 2026.05.22
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456708
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
.PARAMETER ShowSensitive  Print expanded passwords / vault secrets in the
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
$TestRoot       = $PSScriptRoot
$RepoRoot       = Split-Path -Parent $TestRoot
$ModulesDir     = Join-Path $TestRoot "modules"
$SequencesDir   = Join-Path $TestRoot "sequences"

if (-not $ConfigPath) { $ConfigPath = Join-Path $TestRoot "test.config.yml" }

# === logLevel resolution: cmdline > YAML > 'Information' ===
# Each level shows itself + all higher-priority streams; Error is highest.
# Children spawned later inherit the resolved value via $env:YURUNA_LOG_LEVEL.
$cfgForLevel = $null
if (Test-Path $ConfigPath) {
    try { $cfgForLevel = Get-Content -Raw $ConfigPath | ConvertFrom-Yaml -Ordered } catch { $cfgForLevel = $null }
}
$effective = if ($script:CmdLineLogLevel) {
    $script:CmdLineLogLevel
} elseif ($cfgForLevel -is [System.Collections.IDictionary] -and $cfgForLevel.Contains('logLevel') -and $cfgForLevel.logLevel) {
    [string]$cfgForLevel.logLevel
} else { 'Information' }
$valid = @('Error','Warning','Information','Verbose','Debug')
$matched = $valid | Where-Object { $_ -ieq $effective } | Select-Object -First 1
if (-not $matched) {
    Write-Warning "logLevel '$effective' is not one of $($valid -join ', '); falling back to 'Information'."
    $matched = 'Information'
}
$effective = $matched
$rank      = @{ Error=1; Warning=2; Information=3; Verbose=4; Debug=5 }
$effRank   = $rank[$effective]
$global:WarningPreference     = if ($rank.Warning     -le $effRank) { 'Continue' } else { 'SilentlyContinue' }
$global:InformationPreference = if ($rank.Information -le $effRank) { 'Continue' } else { 'SilentlyContinue' }
$global:VerbosePreference     = if ($rank.Verbose     -le $effRank) { 'Continue' } else { 'SilentlyContinue' }
$global:DebugPreference       = if ($rank.Debug       -le $effRank) { 'Continue' } else { 'SilentlyContinue' }
if ($effRank -ge $rank.Verbose) { $global:ProgressPreference = 'SilentlyContinue' }
$env:YURUNA_LOG_LEVEL = $effective

# === Import all modules (suppress engine verbose noise during imports) ===
$savedVerbose = $global:VerbosePreference
$global:VerbosePreference = "SilentlyContinue"

$yurunaLogModule = Join-Path -Path $RepoRoot -ChildPath "automation" -AdditionalChildPath "Yuruna.Log.psm1"
if (Test-Path $yurunaLogModule) {
    Import-Module $yurunaLogModule -Global -Force
}

foreach ($mod in @("Test.Host", "Test.Log")) {
    $modPath = Join-Path $ModulesDir "$mod.psm1"
    if (-not (Test-Path $modPath)) { Write-Error "Module not found: $modPath"; exit 1 }
    Import-Module -Name $modPath -Force
}

$engineModule = Join-Path $ModulesDir "Invoke-Sequence.psm1"
if (-not (Test-Path $engineModule)) { Write-Error "Invoke-Sequence module not found: $engineModule"; exit 1 }
Import-Module -Name $engineModule -Force

# Planner: needed for Resolve-NamedSequenceChain so Test-Sequence runs the
# full baseline -> workload prereq chain (matches Invoke-TestRunner). Import
# AFTER Invoke-Sequence so its own -Force re-import of the engine doesn't
# evict the just-imported engine from the global session.
$plannerModule = Join-Path $ModulesDir "Test.SequencePlanner.psm1"
if (-not (Test-Path $plannerModule)) { Write-Error "Planner module not found: $plannerModule"; exit 1 }
Import-Module -Name $plannerModule -Force
$global:VerbosePreference = $savedVerbose

# Auto-relaunch under sg libvirt on host.ubuntu.kvm when this shell's
# group set lacks libvirt -- Test-Sequence runs the engine which
# calls virsh / virt-install on demand. No-op on other hosts / fresh
# shells.
Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

# === Read config ===
if (-not (Test-Path $ConfigPath)) { Write-Error "Config not found: $ConfigPath"; exit 1 }
$Config = Get-Content -Raw $ConfigPath | ConvertFrom-Yaml -Ordered

# === Pre-cycle config gate ==================================================
# Mirror Invoke-TestRunner: refuse to bring up a VM when test.config.yml /
# vault.yml / users.yml / transports.yml are in a state Test-Config.ps1
# would reject. Without this gate a sequence can "pass" under Test-Sequence
# (extension quirks-mode covers misconfig) while the runner refuses to even
# start the cycle on the same config -- exactly the confusing surprise the
# audit flagged. Bypass with -NoConfigGate for ad-hoc / in-progress edits.
# Spawn a fresh pwsh so an Out-Of-Order ::Stop early-exit inside Test-Config
# cannot unwind this script. -SkipSend stops the smoke-test email from
# flooding subscribers["config.smoke"] on every Test-Sequence invocation.
$ConfigGateScript = Join-Path $TestRoot 'Test-Config.ps1'
if (-not (Test-Path -LiteralPath $ConfigGateScript)) {
    Write-Warning "Pre-cycle config gate skipped: $ConfigGateScript not found."
} elseif ($NoConfigGate) {
    Write-Output "Pre-cycle config gate SKIPPED (-NoConfigGate)."
} else {
    Write-Output "Pre-cycle config gate: running Test-Config.ps1..."
    $pwshExe = (Get-Process -Id $PID).Path
    & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $ConfigGateScript -SkipSend -ConfigPath $ConfigPath
    $gateExit = $LASTEXITCODE
    if ($gateExit -ne 0) {
        Write-Warning ""
        Write-Warning "============================================================"
        Write-Warning "  Pre-cycle config gate FAILED (Test-Config.ps1 exit $gateExit)."
        Write-Warning "  Fix the FAIL items above (test.config.yml, vault.yml,"
        Write-Warning "  users.yml, transports.yml, ...) then re-run."
        Write-Warning ""
        Write-Warning "  To bypass for an ad-hoc / in-progress edit run:"
        Write-Warning "      pwsh test/Test-Sequence.ps1 -NoConfigGate ..."
        Write-Warning "============================================================"
        exit $gateExit
    }
    Write-Output "Pre-cycle config gate PASSED."
}

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
    exit 1
}

# === Ensure status server is running (restart to pick up any changes) ===
$startScript = Join-Path $TestRoot "Start-StatusServer.ps1"
if ($Config.statusServer.isEnabled) {
    $serverPort = $Config.statusServer.port ? [int]$Config.statusServer.port : 8080
    & $startScript -Port $serverPort -Restart
}

# === Detect host ===
# HostType is resolved BEFORE sequence resolution so Resolve-SequencePath can
# prefer a per-host sequence variant (e.g. <Name>.ubuntu.kvm.yml) over the
# generic <Name>.yml -- needed because KVM cloud-image guests skip the
# autoinstall flow that Hyper-V/UTM autoinstall guests run through.
$HostType = Get-HostType
if (-not $HostType) { exit 1 }
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
            Write-Warning "  Pass the variant path explicitly to match runner behaviour."
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
    exit 1
}

# Wire the host driver so contract calls (New-VM, Start-VM, Get-VMState, ...)
# resolve without HostType branches.
[void](Initialize-YurunaHost -RepoRoot $RepoRoot -HostType $HostType)

if (-not (Assert-HostConditionSet -HostType $HostType)) { exit 1 }

$savedVerbose = $global:VerbosePreference
$global:VerbosePreference = "SilentlyContinue"
Import-Module (Join-Path $ModulesDir "Test.RuntimeDir.psm1") -Force
Import-Module (Join-Path $ModulesDir "Test.LogDir.psm1")   -Force
Import-Module (Join-Path $ModulesDir "Test.OcrEngine.psm1") -Force
Import-Module (Join-Path $ModulesDir "Test.Tesseract.psm1") -Force
$global:VerbosePreference = $savedVerbose

$null = Initialize-YurunaRuntimeDir
$null = Initialize-YurunaLogDir
Write-Output "Track directory: $env:YURUNA_RUNTIME_DIR"
Write-Output "Log directory:   $env:YURUNA_LOG_DIR"

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

$activeEngines = Get-EnabledOcrProvider
$combineMode = ($env:YURUNA_OCR_COMBINE -eq 'And') ? 'And' : 'Or'
Write-Output "OCR engines: $($activeEngines -join ', ') | combine: $combineMode"
if (-not (Assert-TesseractInstalled)) { exit 1 }

# === Derive GuestKey from sequence name ===
# Sequence names follow the pattern: <phase>.<guestKey>[.<workload-suffix>]
#   workload.guest.ubuntu.server.24                          -> guest.ubuntu.server.24
#   start.guest.amazon.linux.2023                            -> guest.amazon.linux.2023
#   workload.guest.ubuntu.server.24.k8s.text-to-sql.baseline -> guest.ubuntu.server.24
# Cascade-child sequences (third example) tack workload-specific suffixes
# onto the guest key. The base guest is the LONGEST dotted prefix whose
# host/<short>/<prefix>/ folder exists -- walk from full to shortest and
# stop at the first hit. Explicit -GuestKey skips the walk.
if ($GuestKey) {
    Write-Output "Guest key (override): $GuestKey"
} else {
    $parts = $SequenceName -split '\.', 2
    if ($parts.Count -lt 2) {
        Write-Error "Cannot derive guest key from sequence name '$SequenceName'. Expected format: <phase>.<guestKey>"
        exit 1
    }
    $tried = @()
    $candidate = $parts[1]
    while ($candidate) {
        $tried += $candidate
        if (Test-GuestFolder -RepoRoot $RepoRoot -HostType $HostType -GuestKey $candidate) {
            $GuestKey = $candidate
            break
        }
        if ($candidate -notmatch '\.') { break }
        $candidate = $candidate -replace '\.[^.]+$', ''
    }
    if (-not $GuestKey) {
        $hostShort = $HostType -replace '^host\.',''
        Write-Error "No guest folder found for sequence '$SequenceName' on $HostType."
        Write-Output "  Tried (longest-first): $($tried -join ', ')"
        Write-Output "  Add host/$hostShort/<guestKey>/ for one of those keys, or pass -GuestKey explicitly."
        exit 1
    }
    if ($tried.Count -gt 1) {
        Write-Output "Guest key: $GuestKey (walked $($tried.Count) prefixes from '$($tried[0])')"
    } else {
        Write-Output "Guest key: $GuestKey"
    }
}

# Final safety net: even an explicit -GuestKey must point to a real folder.
if (-not (Test-GuestFolder -RepoRoot $RepoRoot -HostType $HostType -GuestKey $GuestKey)) {
    $folder = Join-Path $RepoRoot (Join-Path (Get-HostFolder $HostType) $GuestKey)
    Write-Error "Guest folder not found for '$GuestKey' on $HostType`: $folder"
    Write-Output "  Add Get-Image.ps1 + New-VM.ps1 under that path to enable this guest, or"
    Write-Output "  correct -GuestKey to a guest that exists on this host."
    exit 1
}

# === Derive VM name (use -VMName override if provided) ===
if (-not $VMName) {
    $Prefix = $Config.vmStart.testVmNamePrefix ?? "test-"
    $VMName = Get-TestVMName -GuestKey $GuestKey -Prefix $Prefix
}

# === Build chain plan ===
# Mirror Invoke-TestRunner's cycle planner: walk the named sequence's
# baseline chain so every prereq runs before the top-level. Both the
# name form and the path form (-TopLevelPath) walk the chain -- prereqs
# living in the framework tree resolve normally; if the path form was
# necessary because the project tree is not at <RepoRoot>/project/
# (e.g. yuruna-project mounted as a sibling working tree), only the
# top-level uses the override. effectiveUsername must be known BEFORE
# New-VM below, matching the runner's same forward.
$osKey = $GuestKey -replace '^guest\.',''
$plannerArgs = @{
    RepoRoot     = $RepoRoot
    SequencesDir = $SequencesDir
    HostType     = $HostType
    SequenceName = $SequenceName
    OsKey        = $osKey
}
if ($SequencePathOverride) { $plannerArgs.TopLevelPath = $SequencePathOverride }
$ChainPlan = Resolve-NamedSequenceChain @plannerArgs
$effectiveUser = $ChainPlan.effectiveUsername

# Build (name, path, sequence, stepCount, globalStart) per chain entry
# using the planner's chainPaths map. Re-reading the YAML here (vs.
# returning parsed sequences from the planner) keeps the planner's
# return type simple; YAML parse cost is trivial next to running steps.
$ChainEntries = New-Object System.Collections.Generic.List[object]
$globalCount = 0
foreach ($name in $ChainPlan.fullChain) {
    $path = $ChainPlan.chainPaths[$name]
    if (-not $path) {
        $searched = Get-SequenceSearchPath -SequencesDir $SequencesDir -Name $name -HostType $HostType -RepoRoot $RepoRoot
        Write-Error "Chain prereq not found: $name (referenced via baseline of $SequenceName)"
        Write-Output "Searched (no match):"
        foreach ($p in $searched) { Write-Output "  $p" }
        exit 1
    }
    $seq = Read-SequenceFile -Path $path
    $count = @($seq.steps).Count
    $ChainEntries.Add([pscustomobject]@{
        name        = $name
        path        = $path
        sequence    = $seq
        stepCount   = $count
        globalStart = ($globalCount + 1)
    })
    $globalCount += $count
}
$ChainTotalSteps = $globalCount

if ($ChainPlan.fullChain.Count -gt 1) {
    Write-Output "Chain: $($ChainPlan.fullChain -join ' -> ')"
} else {
    Write-Output "Chain: $($ChainPlan.fullChain[0]) (no baseline prereqs declared)"
}

# === requiresSnapshot warm-path probe =======================================
# When the top-level sequence declares `requiresSnapshot: { id: <X> }`,
# the chain ends in a saveDiskSnapshot that renames `test-<guestKey>`
# -> <X>. Two paths:
#
#   WARM: persisted VM <X> exists AND already has snapshot <X> on disk.
#         Skip every prereq sequence and run only the top-level against
#         <X>. The top-level's first loadDiskSnapshot reverts the disk.
#
#   COLD: snapshot not present. Walk the full chain. The build VM is
#         created with the test-<guestKey> name (so Remove-TestVMFiles
#         can sweep a failed cold build); saveDiskSnapshot renames it
#         to <X> mid-chain, and subsequent entries operate on <X>. The
#         per-entry loop below detects the rename and updates $VMName.
$requiredSnapshotId = $null
$topLevelEntry      = $ChainEntries[$ChainEntries.Count - 1]
if ($topLevelEntry.sequence.requiresSnapshot -is [System.Collections.IDictionary] -and
    $topLevelEntry.sequence.requiresSnapshot.Contains('id') -and
    $topLevelEntry.sequence.requiresSnapshot.id) {
    $requiredSnapshotId = [string]$topLevelEntry.sequence.requiresSnapshot.id
}
if ($requiredSnapshotId) {
    $snapPresent = $false
    try {
        $snapPresent = [bool](Test-VMDiskSnapshot -VMName $requiredSnapshotId -Id $requiredSnapshotId)
    } catch {
        Write-Verbose "Test-VMDiskSnapshot threw ($($_.Exception.Message)); assuming cold path."
    }
    if ($snapPresent) {
        Write-Output "requiresSnapshot: snapshot '$requiredSnapshotId' present on persisted VM '$requiredSnapshotId' -- skipping baseline chain (warm path)."
        $VMName = $requiredSnapshotId
        # Drop every prereq; keep only the top-level entry and rebase its
        # globalStart to 1 so -StartStep / -StopStep index into the
        # truncated step list naturally.
        $topLevelEntry.globalStart = 1
        $ChainEntries = New-Object System.Collections.Generic.List[object]
        [void]$ChainEntries.Add($topLevelEntry)
        $ChainTotalSteps = $topLevelEntry.stepCount
    } else {
        Write-Output "requiresSnapshot: snapshot '$requiredSnapshotId' not on host -- running full baseline chain (cold path; VM will be renamed to '$requiredSnapshotId' at saveDiskSnapshot)."
    }
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
    # matches today's behaviour when no plan resolves.
    if ($effectiveUser) {
        Write-Verbose "Forwarding -Username '$effectiveUser' from $($SequenceName).variables.username."
        $r = New-VM -GuestKey $GuestKey -RepoRoot $RepoRoot -VMName $VMName -Username $effectiveUser -CachingProxyUrl $newVmProxy -Confirm:$false
    } else {
        $r = New-VM -GuestKey $GuestKey -RepoRoot $RepoRoot -VMName $VMName -CachingProxyUrl $newVmProxy -Confirm:$false
    }
    if (-not $r.success) {
        Write-Error "New-VM failed: $($r.errorMessage)"
        exit 1
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
        exit 1
    }
    $ok = Wait-VMRunning -VMName $VMName `
        -TimeoutSeconds $VmStartTimeout -BootDelaySeconds $VmBootDelay
    if (-not $ok) {
        Write-Error "VM '$VMName' did not reach running state within ${VmStartTimeout}s."
        exit 1
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
    exit 1
}

if ($StopStep -ne 0) {
    if ($StopStep -lt $StartStep) {
        Write-Warning "StopStep ($StopStep) must be greater than or equal to StartStep ($StartStep). Stopping."
        exit 1
    }
    if ($StopStep -gt $totalSteps) {
        Write-Warning "StopStep $StopStep exceeds total steps ($totalSteps). Clamping to $totalSteps."
        $StopStep = $totalSteps
    }
}

$effectiveStop = $StopStep -ne 0 ? $StopStep : $totalSteps

$stopLabel = $StopStep -ne 0 ? ", stopping after step $effectiveStop" : ""

# --- Start log file (transcript captures all console output) ---
$SeqCycleId = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$LogFile    = Start-LogFile -TestRoot $TestRoot -CycleId $SeqCycleId -Hostname (hostname)
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
# Forward $ChainPlan.effectiveVariables on every Invoke-Sequence call so
# the cascaded `variables.username` (etc.) propagates the same way the
# runner's Invoke-SequenceByName forwards them. Empty cascade (no chain
# prereqs found) leaves Invoke-Sequence's own `variables:` block as the
# fallback -- same as the pre-chain single-sequence behaviour.
# A failure in any chain entry aborts the whole run with the original
# error reproduction tip; later entries don't auto-skip past the failure.
$tempFiles = New-Object System.Collections.Generic.List[string]
try {
    Write-Output "Running steps $StartStep to $effectiveStop..."
    Write-Output ""

    foreach ($entry in $ChainEntries) {
        $thisStart = $entry.globalStart
        $thisEnd   = $thisStart + $entry.stepCount - 1

        # Intersect this entry's global range with the requested range.
        $sliceStart = [Math]::Max($StartStep, $thisStart)
        $sliceEnd   = [Math]::Min($effectiveStop, $thisEnd)
        if ($sliceStart -gt $sliceEnd) {
            Write-Output "Skipping (no steps in requested range): $($entry.name)"
            continue
        }

        # Convert global -> local 1-based indices for this entry's slice.
        $localStart = $sliceStart - $thisStart + 1
        $localEnd   = $sliceEnd   - $thisStart + 1

        $allSteps   = @($entry.sequence.steps)
        $slicedSteps = $allSteps[($localStart - 1)..($localEnd - 1)]

        # Same top-level-keys-except-steps copy the original did; chain
        # entries are each their own sequence dictionary.
        $trimmedSequence = [ordered]@{}
        foreach ($key in $entry.sequence.Keys) {
            if ($key -ne 'steps') { $trimmedSequence[$key] = $entry.sequence[$key] }
        }
        $trimmedSequence['steps'] = $slicedSteps

        $tempFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.yml'
        $trimmedSequence | ConvertTo-Yaml | Set-Content -Path $tempFile -Encoding UTF8
        [void]$tempFiles.Add($tempFile)

        Write-Output ""
        Write-Output "--- $($entry.name): local steps $localStart-$localEnd of $($entry.stepCount) (global $sliceStart-$sliceEnd) ---"

        # -ShowSensitive defaults OFF to match Invoke-TestRunner's masking;
        # the operator opts in with the switch when local debugging actually
        # needs the cleartext values rendered.
        $ok = Invoke-Sequence -HostType $HostType -GuestKey $GuestKey -VMName $VMName -SequencePath $tempFile -EffectiveVariables $ChainPlan.effectiveVariables -ShowSensitive:$ShowSensitive
        if ($ok -ne $true) {
            Write-Warning "Sequence failed: $($entry.name)"
            Write-Output ""
            Write-Output "To reproduce with full diagnostics:"
            Write-Output "  pwsh test/Test-Sequence.ps1 -SequenceName `"$SequenceName`" -StartStep $sliceStart -logLevel Debug"
            exit 1
        }

        # Detect a mid-chain saveDiskSnapshot rename. The engine updates
        # its internal $VMName when Save-VMDiskSnapshot succeeds (test-X
        # -> <id>), but this script's outer $VMName is passed by value
        # and is now stale. Without this swap the next entry would target
        # the old, now-absent VM. Only fires when requiresSnapshot was
        # declared, so non-snapshot chains keep their existing behaviour.
        if ($requiredSnapshotId -and $VMName -ne $requiredSnapshotId) {
            if ((Get-VMState -VMName $VMName) -eq 'absent' -and
                (Get-VMState -VMName $requiredSnapshotId) -ne 'absent') {
                Write-Output "VM renamed mid-chain: '$VMName' -> '$requiredSnapshotId'; subsequent entries will target '$requiredSnapshotId'."
                $VMName = $requiredSnapshotId
            }
        }
    }

    Write-Output ""
    if ($StopStep -ne 0 -and $effectiveStop -lt $totalSteps) {
        Write-Output "Chain stopped after step $effectiveStop of $totalSteps. VM '$VMName' left running for inspection."
    } else {
        Write-Output "Chain completed successfully ($totalSteps step(s) across $($ChainPlan.fullChain.Count) sequence(s))."
    }
    exit 0
} finally {
    foreach ($tf in $tempFiles) {
        Remove-Item -Path $tf -Force -ErrorAction SilentlyContinue
    }
    Stop-LogFile
}
