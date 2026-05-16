<#PSScriptInfo
.VERSION 2026.05.15
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
    Dev helper: run one test sequence from a chosen step. No image
    download; reuses an existing VM if present. See test/README.md
    (Developing test sequences) for usage and naming.

.PARAMETER SequenceName   Base name (no .yml, e.g. "workload.guest.ubuntu.server"). Required.
.PARAMETER StartStep      1-based start step. Default 1.
.PARAMETER StopStep       1-based stop (inclusive). VM left running after.
.PARAMETER ConfigPath     Default: test/test.config.yml.
.PARAMETER VMName         Override the VM name (default: derived from guest key).
.PARAMETER logLevel       Error|Warning|Information|Verbose|Debug. Each level shows itself + all higher-priority streams (Error highest). Omit to read test.config.yml.logLevel (default "Information").
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$SequenceName,

    [int]$StartStep = 1,

    [int]$StopStep = 0,

    [string]$ConfigPath = $null,

    [string]$VMName = $null,

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
$global:VerbosePreference = $savedVerbose

# Auto-relaunch under sg libvirt on host.ubuntu.kvm when this shell's
# group set lacks libvirt -- Confirm-Sequence runs the engine which
# calls virsh / virt-install on demand. No-op on other hosts / fresh
# shells.
Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

# === Read config ===
if (-not (Test-Path $ConfigPath)) { Write-Error "Config not found: $ConfigPath"; exit 1 }
$Config = Get-Content -Raw $ConfigPath | ConvertFrom-Yaml -Ordered

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
$SequencePath = Resolve-SequencePath -SequencesDir $SequencesDir -Name $SequenceName -HostType $HostType -RepoRoot $RepoRoot
if (-not (Test-Path $SequencePath)) {
    Write-Error "Sequence file not found: $SequencePath"
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
Import-Module (Join-Path $ModulesDir "Test.TrackDir.psm1") -Force
Import-Module (Join-Path $ModulesDir "Test.LogDir.psm1")   -Force
Import-Module (Join-Path $ModulesDir "Test.OcrEngine.psm1") -Force
Import-Module (Join-Path $ModulesDir "Test.Tesseract.psm1") -Force
$global:VerbosePreference = $savedVerbose

$null = Initialize-YurunaTrackDir
$null = Initialize-YurunaLogDir
Write-Output "Track directory: $env:YURUNA_TRACK_DIR"
Write-Output "Log directory:   $env:YURUNA_LOG_DIR"

$activeEngines = Get-EnabledOcrProvider
$combineMode = ($env:YURUNA_OCR_COMBINE -eq 'And') ? 'And' : 'Or'
Write-Output "OCR engines: $($activeEngines -join ', ') | combine: $combineMode"
if (-not (Assert-TesseractInstalled)) { exit 1 }

# === Derive GuestKey from sequence name ===
# Sequence names follow the pattern: <phase>.<guestKey>
# e.g. "workload.guest.ubuntu.server" -> "guest.ubuntu.server"
# e.g. "start.guest.amazon.linux" -> "guest.amazon.linux"
$parts = $SequenceName -split '\.', 2
if ($parts.Count -lt 2) {
    Write-Error "Cannot derive guest key from sequence name '$SequenceName'. Expected format: <phase>.<guestKey>"
    exit 1
}
$GuestKey = $parts[1]

# Validate guest key by checking the folder exists for the current host. No
# hardcoded allow-list — a guest is valid iff its host/<short-host>/<guestKey>/
# folder is on disk, matching the convention Invoke-TestRunner.ps1 uses.
if (-not (Test-GuestFolder -RepoRoot $RepoRoot -HostType $HostType -GuestKey $GuestKey)) {
    $folder = Join-Path $RepoRoot (Join-Path (Get-HostFolder $HostType) $GuestKey)
    Write-Error "Guest folder not found for '$GuestKey' on $HostType`: $folder"
    Write-Output "  Add Get-Image.ps1 + New-VM.ps1 under that path to enable this guest, or"
    Write-Output "  correct the sequence name so it references a guest that exists on this host."
    exit 1
}

# === Derive VM name (use -VMName override if provided) ===
if (-not $VMName) {
    $Prefix = $Config.vmStart.testVmNamePrefix ?? "test-"
    $VMName = Get-TestVMName -GuestKey $GuestKey -Prefix $Prefix
}

# === Ensure VM exists (reuse or create) ===
if ((Get-VMState -VMName $VMName) -ne 'absent') {
    Write-Output "VM '$VMName' already exists. Reusing."
} else {
    Write-Output "VM '$VMName' not found. Creating..."
    $r = New-VM -GuestKey $GuestKey -RepoRoot $RepoRoot -VMName $VMName -Confirm:$false
    if (-not $r.success) {
        Write-Error "New-VM failed: $($r.errorMessage)"
        exit 1
    }
    Write-Output "VM '$VMName' created."
}

# === Ensure VM is running ===
$VmStartTimeout = $Config.vmStart.startTimeoutSeconds ? [int]$Config.vmStart.startTimeoutSeconds : 120
$VmBootDelay    = $Config.vmStart.bootDelaySeconds    ? [int]$Config.vmStart.bootDelaySeconds    : 15

if ((Get-VMState -VMName $VMName) -eq 'running') {
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

# === Load and slice the sequence ===
$sequence = Read-SequenceFile -Path $SequencePath
$totalSteps = @($sequence.steps).Count

if ($StartStep -lt 1 -or $StartStep -gt $totalSteps) {
    Write-Error "StartStep $StartStep is out of range. The sequence has $totalSteps steps (1-$totalSteps)."
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
$GitCommit  = Get-CurrentGitCommit -RepoRoot $RepoRoot
$LogFile    = Start-LogFile -TestRoot $TestRoot -CycleId $SeqCycleId -Hostname (hostname) -GitCommit $GitCommit
Write-Output "Log file: $LogFile"

Write-Output ""
Write-Output "============================================="
Write-Output "  Sequence: $SequenceName"
Write-Output "  Steps:    $totalSteps total, starting at step $StartStep$stopLabel"
Write-Output "  VM:       $VMName"
Write-Output "  Guest:    $GuestKey"
Write-Output "============================================="

Write-Output ""
Write-Output "Step list:"
$stepIdx = 0
foreach ($step in $sequence.steps) {
    $stepIdx++
    $marker = ($stepIdx -ge $StartStep -and $stepIdx -le $effectiveStop) ? ">>" : "  "
    $desc = $step.description ?? $step.action
    Write-Output "  $marker [$stepIdx] $($step.action): $desc"
}
Write-Output ""

# === Build a trimmed sequence and write to a temp file ===
$trimmedSteps = @($sequence.steps)[$($StartStep - 1)..($effectiveStop - 1)]

$trimmedSequence = [ordered]@{}
# Copy all top-level keys except steps. ConvertFrom-Yaml -Ordered hands us
# an OrderedDictionary, so we walk .Keys instead of PSObject.Properties.
foreach ($key in $sequence.Keys) {
    if ($key -ne "steps") {
        $trimmedSequence[$key] = $sequence[$key]
    }
}
$trimmedSequence["steps"] = $trimmedSteps

$tempFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.yml'
$trimmedSequence | ConvertTo-Yaml | Set-Content -Path $tempFile -Encoding UTF8

try {
    Write-Output "Running steps $StartStep to $effectiveStop..."
    Write-Output ""

    $ok = Invoke-Sequence -HostType $HostType -GuestKey $GuestKey -VMName $VMName -SequencePath $tempFile -ShowSensitive
    if ($ok -eq $false) {
        Write-Warning "Sequence failed."
        Write-Output ""
        Write-Output "To reproduce with full diagnostics:"
        Write-Output "  pwsh test/Confirm-Sequence.ps1 -SequenceName `"$SequenceName`" -StartStep $StartStep -logLevel Debug"
        exit 1
    }

    Write-Output ""
    if ($StopStep -ne 0 -and $effectiveStop -lt $totalSteps) {
        Write-Output "Sequence stopped after step $effectiveStop of $totalSteps. VM '$VMName' left running for inspection."
    } else {
        Write-Output "Sequence completed successfully."
    }
    exit 0
} finally {
    Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
    Stop-LogFile
}
