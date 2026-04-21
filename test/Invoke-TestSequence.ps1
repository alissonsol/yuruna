<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456708
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
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

.PARAMETER SequenceName   Base name (no .json, e.g. "Test-Workload.guest.ubuntu.desktop"). Required.
.PARAMETER StartStep      1-based start step. Default 1.
.PARAMETER StopStep       1-based stop (inclusive). VM left running after.
.PARAMETER ConfigPath     Default: test/test-config.json.
.PARAMETER VMName         Override the VM name (default: derived from guest key).
.PARAMETER debug_mode     $true = debug messages.
.PARAMETER verbose_mode   $true = verbose messages.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$SequenceName,

    [int]$StartStep = 1,

    [int]$StopStep = 0,

    [string]$ConfigPath = $null,

    [string]$VMName = $null,

    [bool]$debug_mode   = $false,

    [bool]$verbose_mode = $false
)

$global:InformationPreference = "Continue"

$global:DebugPreference = "SilentlyContinue"
$global:VerbosePreference = "SilentlyContinue"
if ($debug_mode) {
    $global:DebugPreference = "Continue"
}
if ($verbose_mode) {
    $global:VerbosePreference = "Continue"
}

# === Resolve paths ===
$TestRoot       = $PSScriptRoot
$RepoRoot       = Split-Path -Parent $TestRoot
$VirtualRoot        = Join-Path $RepoRoot "virtual"
$ModulesDir     = Join-Path $TestRoot "modules"
$ExtensionsDir  = Join-Path $TestRoot "extensions"
$SequencesDir   = Join-Path $TestRoot "sequences"

if (-not $ConfigPath) { $ConfigPath = Join-Path $TestRoot "test-config.json" }

# === Publish debug/verbose preferences as env vars so child processes inherit them ===
$env:YURUNA_DEBUG   = $debug_mode   ? '1' : '0'
$env:YURUNA_VERBOSE = $verbose_mode ? '1' : '0'

# === Import all modules (suppress engine verbose noise during imports) ===
$savedVerbose = $global:VerbosePreference
$global:VerbosePreference = "SilentlyContinue"

$yurunaLogModule = Join-Path -Path $RepoRoot -ChildPath "automation" -AdditionalChildPath "yuruna-log.psm1"
if (Test-Path $yurunaLogModule) {
    Import-Module $yurunaLogModule -Global -Force
}

foreach ($mod in @("Test.Host", "Test.New-VM", "Test.Start-VM", "Test.Log")) {
    $modPath = Join-Path $ModulesDir "$mod.psm1"
    if (-not (Test-Path $modPath)) { Write-Error "Module not found: $modPath"; exit 1 }
    Import-Module -Name $modPath -Force
}

$engineModule = Join-Path $ExtensionsDir "Invoke-Sequence.psm1"
if (-not (Test-Path $engineModule)) { Write-Error "Invoke-Sequence module not found: $engineModule"; exit 1 }
Import-Module -Name $engineModule -Force
$global:VerbosePreference = $savedVerbose

# === Enable tracing by default for development debugging ===
if (-not $env:NEWTEXT_TRACE) { $env:NEWTEXT_TRACE = '1' }

# === Read config ===
if (-not (Test-Path $ConfigPath)) { Write-Error "Config not found: $ConfigPath"; exit 1 }
$Config = Get-Content -Raw $ConfigPath | ConvertFrom-Json -AsHashtable

# === Ensure status server is running (restart to pick up any changes) ===
$startScript = Join-Path $TestRoot "Start-StatusServer.ps1"
if ($Config.statusServer.enabled) {
    $serverPort = $Config.statusServer.port ? [int]$Config.statusServer.port : 8080
    & $startScript -Port $serverPort -Restart
}

# === Resolve sequence file ===
# Sequences live in mode subfolders (sequences/gui/, sequences/ssh/).
# Resolve-SequencePath returns the active-mode path with gui/ fallback; if
# neither exists, we show a list drawn from both subfolders.
$SequencePath = Resolve-SequencePath -SequencesDir $SequencesDir -Name $SequenceName
if (-not (Test-Path $SequencePath)) {
    Write-Error "Sequence file not found: $SequencePath"
    Write-Output ""
    Write-Output "Available sequences:"
    foreach ($mode in @('gui', 'ssh')) {
        $modeDir = Join-Path $SequencesDir $mode
        if (-not (Test-Path $modeDir)) { continue }
        Write-Output "  [$mode]"
        Get-ChildItem -Path $modeDir -Filter "*.json" -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Output "    $($_.BaseName)"
        }
    }
    exit 1
}

# === Detect host ===
$HostType = Get-HostType
if (-not $HostType) { exit 1 }
Write-Output "Host type: $HostType"

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
# Sequence names follow the pattern: Test-<Phase>.<guestKey>
# e.g. "Test-Workload.guest.ubuntu.desktop" -> "guest.ubuntu.desktop"
# e.g. "Test-Start.guest.amazon.linux" -> "guest.amazon.linux"
$parts = $SequenceName -split '\.', 2
if ($parts.Count -lt 2) {
    Write-Error "Cannot derive guest key from sequence name '$SequenceName'. Expected format: Test-<Phase>.<guestKey>"
    exit 1
}
$GuestKey = $parts[1]

# Validate guest key by checking the folder exists for the current host. No
# hardcoded allow-list — a guest is valid iff its virtual/<hostType>/<guestKey>/
# folder is on disk, matching the convention Invoke-TestRunner.ps1 uses.
if (-not (Test-GuestFolder -VirtualRoot $VirtualRoot -HostType $HostType -GuestKey $GuestKey)) {
    $folder = Join-Path $VirtualRoot "$HostType/$GuestKey"
    Write-Error "Guest folder not found for '$GuestKey' on $HostType`: $folder"
    Write-Output "  Add Get-Image.ps1 + New-VM.ps1 under that path to enable this guest, or"
    Write-Output "  correct the sequence name so it references a guest that exists on this host."
    exit 1
}

# === Derive VM name (use -VMName override if provided) ===
if (-not $VMName) {
    $Prefix = $Config.testVmNamePrefix ?? "test-"
    $VMName = Get-TestVMName -GuestKey $GuestKey -Prefix $Prefix
}

# === Ensure VM exists (reuse or create) ===
$vmExists = Confirm-VMCreated -HostType $HostType -VMName $VMName
if ($vmExists) {
    Write-Output "VM '$VMName' already exists. Reusing."
} else {
    Write-Output "VM '$VMName' not found. Creating..."
    $r = Invoke-NewVM -HostType $HostType -GuestKey $GuestKey -VirtualRoot $VirtualRoot -VMName $VMName
    if (-not $r.success) {
        Write-Error "New-VM failed: $($r.errorMessage)"
        exit 1
    }
    Write-Output "VM '$VMName' created."
}

# === Ensure VM is running ===
$VmStartTimeout = $Config.vmStartTimeoutSeconds ? [int]$Config.vmStartTimeoutSeconds : 120
$VmBootDelay    = $Config.vmBootDelaySeconds    ? [int]$Config.vmBootDelaySeconds    : 15

$isRunning = Confirm-VMStarted -HostType $HostType -VMName $VMName -TimeoutSeconds 5 -BootDelaySeconds 0
if ($isRunning) {
    Write-Output "VM '$VMName' is already running."
} else {
    Write-Output "Starting VM '$VMName'..."
    $r = Invoke-StartVM -HostType $HostType -VMName $VMName
    if (-not $r.success) {
        Write-Error "Start-VM failed: $($r.errorMessage)"
        exit 1
    }
    $ok = Confirm-VMStarted -HostType $HostType -VMName $VMName `
        -TimeoutSeconds $VmStartTimeout -BootDelaySeconds $VmBootDelay
    if (-not $ok) {
        Write-Error "VM '$VMName' did not reach running state within ${VmStartTimeout}s."
        exit 1
    }
    Write-Output "VM '$VMName' is running."
}

# === Load and slice the sequence ===
$sequence = Get-Content -Raw $SequencePath | ConvertFrom-Json
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
# Copy all properties except steps
foreach ($prop in $sequence.PSObject.Properties) {
    if ($prop.Name -ne "steps") {
        $trimmedSequence[$prop.Name] = $prop.Value
    }
}
$trimmedSequence["steps"] = $trimmedSteps

$tempFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.json'
$trimmedSequence | ConvertTo-Json -Depth 10 | Set-Content -Path $tempFile -Encoding UTF8

try {
    Write-Output "Running steps $StartStep to $effectiveStop..."
    Write-Output ""

    $ok = Invoke-Sequence -HostType $HostType -GuestKey $GuestKey -VMName $VMName -SequencePath $tempFile -ShowSensitive
    if ($ok -eq $false) {
        Write-Warning "Sequence failed."
        Write-Output ""
        Write-Output "To reproduce with full diagnostics:"
        Write-Output "  pwsh test/Invoke-TestSequence.ps1 -SequenceName `"$SequenceName`" -StartStep $StartStep -debug_mode `$true -verbose_mode `$true"
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
