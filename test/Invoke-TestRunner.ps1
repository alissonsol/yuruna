<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456707
.AUTHOR Alisson Sol
.COMPANYNAME None
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

param(
    [string]$ConfigPath  = $null,
    [switch]$NoGitPull,
    [switch]$NoServer
)

# === Resolve paths ===
$TestRoot  = $PSScriptRoot
$RepoRoot  = Split-Path -Parent $TestRoot
$VdeRoot   = Join-Path $RepoRoot "vde"
$StatusDir = Join-Path $TestRoot "status"
$StatusFile = Join-Path $StatusDir "status.json"
$ModulesDir = Join-Path $TestRoot "modules"

if (-not $ConfigPath) { $ConfigPath = Join-Path $TestRoot "test-config.json" }

# === Import modules ===
foreach ($mod in @("Test.Host", "Test.Status", "Test.Notify", "Test.Runner", "Test.Verify", "Test.Cleanup")) {
    $modPath = Join-Path $ModulesDir "$mod.psm1"
    if (-not (Test-Path $modPath)) { Write-Error "Module not found: $modPath"; exit 1 }
    Import-Module -Name $modPath -Force
}

# === Read config ===
if (-not (Test-Path $ConfigPath)) { Write-Error "Config not found: $ConfigPath"; exit 1 }
$Config = Get-Content -Raw $ConfigPath | ConvertFrom-Json -AsHashtable

# === Phase 0: Bootstrap ===
$HostType = Get-HostType
if (-not $HostType) { exit 1 }
Write-Output "Host type: $HostType"

if (-not (Assert-Elevation -HostType $HostType)) { exit 1 }

$ServerJob = $null
if ($Config.statusServer.enabled -and -not $NoServer) {
    $ServerJob = Start-StatusServer -StatusDir $StatusDir -Port ([int]$Config.statusServer.port)
}

# === Phase 1: Git pull ===
if (-not $NoGitPull) {
    if (-not (Invoke-GitPull -RepoRoot $RepoRoot)) {
        Send-Notification -Config $Config `
            -Subject "Yuruna VDE Test: git pull failed on $HostType" `
            -Body    "git pull failed. Check network connectivity and repository access."
        Stop-StatusServer -Job $ServerJob
        exit 1
    }
}
$GitCommit = Get-CurrentGitCommit -RepoRoot $RepoRoot

# === Phase 0 cont: Initialise status ===
$GuestList = Get-GuestList
$RunId = Initialize-StatusDocument `
    -StatusFilePath $StatusFile `
    -HostType       $HostType `
    -Hostname       (hostname) `
    -GitCommit      $GitCommit `
    -GuestList      $GuestList

Write-Output "Run ID:  $RunId"
Write-Output "Commit:  $GitCommit"
Write-Output "Guests:  $($GuestList -join ', ')"

# === Phase 2: Guest loop ===
$OverallPassed  = $true
$FailedGuest    = $null
$FailedStep     = $null
$FailureMessage = $null

$Prefix = if ($Config.testVmNamePrefix) { $Config.testVmNamePrefix } else { "test-" }

foreach ($GuestKey in $GuestList) {
    $VMName = switch ($GuestKey) {
        "guest.amazon.linux"   { "${Prefix}amazon-linux01"   }
        "guest.ubuntu.desktop" { "${Prefix}ubuntu-desktop01" }
        "guest.windows.11"     { "${Prefix}windows11-01"     }
        default                { "${Prefix}vm01"             }
    }

    Set-GuestVMName -GuestKey $GuestKey -VMName $VMName
    Write-Output ""
    Write-Output "=== $GuestKey (VM: $VMName) ==="

    # Selenium prerequisite for Windows 11 on Hyper-V
    if ($GuestKey -eq "guest.windows.11" -and $HostType -eq "host.windows.hyper-v") {
        if (-not (Test-SeleniumPrerequisite -RepoRoot $RepoRoot)) {
            $err = "chromedriver.exe not found. Run vde/host.windows.hyper-v/Get-Selenium.ps1 as Administrator first."
            Write-Error $err
            Set-StepStatus  -GuestKey $GuestKey -StepName "GetImage" -Status "fail" -ErrorMessage $err
            Set-GuestStatus -GuestKey $GuestKey -Status "fail"
            $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "GetImage"; $FailureMessage = $err
            break
        }
    }

    Set-GuestStatus -GuestKey $GuestKey -Status "running"

    # --- GetImage ---
    Set-StepStatus -GuestKey $GuestKey -StepName "GetImage" -Status "running"
    $r = Invoke-GetImage -HostType $HostType -GuestKey $GuestKey -VdeRoot $VdeRoot -AlwaysRedownload ([bool]$Config.alwaysRedownloadImages)
    if ($r.skipped) {
        Set-StepStatus -GuestKey $GuestKey -StepName "GetImage" -Status "skipped" -Skipped $true
    } elseif ($r.success) {
        Set-StepStatus -GuestKey $GuestKey -StepName "GetImage" -Status "pass"
    } else {
        Set-StepStatus  -GuestKey $GuestKey -StepName "GetImage" -Status "fail" -ErrorMessage $r.errorMessage
        Set-GuestStatus -GuestKey $GuestKey -Status "fail"
        $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "GetImage"; $FailureMessage = $r.errorMessage
        break
    }

    # --- NewVM ---
    Set-StepStatus -GuestKey $GuestKey -StepName "NewVM" -Status "running"
    $r = Invoke-NewVM -HostType $HostType -GuestKey $GuestKey -VdeRoot $VdeRoot -VMName $VMName
    if ($r.success) {
        Set-StepStatus -GuestKey $GuestKey -StepName "NewVM" -Status "pass"
    } else {
        Set-StepStatus  -GuestKey $GuestKey -StepName "NewVM" -Status "fail" -ErrorMessage $r.errorMessage
        Set-GuestStatus -GuestKey $GuestKey -Status "fail"
        $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "NewVM"; $FailureMessage = $r.errorMessage
        break
    }

    # --- VerifyVM ---
    Set-StepStatus -GuestKey $GuestKey -StepName "VerifyVM" -Status "running"
    $ok = Confirm-VMCreated -HostType $HostType -VMName $VMName
    if ($ok) {
        Set-StepStatus -GuestKey $GuestKey -StepName "VerifyVM" -Status "pass"
    } else {
        $err = "VM '$VMName' not found after New-VM.ps1 succeeded."
        Set-StepStatus  -GuestKey $GuestKey -StepName "VerifyVM" -Status "fail" -ErrorMessage $err
        Set-GuestStatus -GuestKey $GuestKey -Status "fail"
        $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "VerifyVM"; $FailureMessage = $err
        break
    }

    # --- CleanupVM ---
    Set-StepStatus -GuestKey $GuestKey -StepName "CleanupVM" -Status "running"
    if ($Config.cleanupAfterTest) {
        $cleaned = Remove-TestVM -HostType $HostType -VMName $VMName
        if ($cleaned) {
            Set-StepStatus -GuestKey $GuestKey -StepName "CleanupVM" -Status "pass"
        } else {
            Set-StepStatus -GuestKey $GuestKey -StepName "CleanupVM" -Status "fail" `
                -ErrorMessage "Cleanup failed. Manual removal required for $VMName."
            Write-Warning "CleanupVM failed for '$VMName'. Continuing to next guest."
        }
    } else {
        Set-StepStatus -GuestKey $GuestKey -StepName "CleanupVM" -Status "skipped" -Skipped $true
        Write-Output "Cleanup skipped (cleanupAfterTest=false)."
    }

    Set-GuestStatus -GuestKey $GuestKey -Status "pass"
    Write-Output "${GuestKey}: PASS"
}

# === Phase 3: Finalise ===
$FinalStatus = if ($OverallPassed) { "pass" } else { "fail" }
Complete-Run -OverallStatus $FinalStatus -MaxHistoryRuns ([int]$Config.maxHistoryRuns)

Write-Output ""
Write-Output "=== Run complete: $FinalStatus ==="

if (-not $OverallPassed -and $FailedGuest) {
    $body = Format-FailureMessage `
        -HostType     $HostType `
        -GuestKey     $FailedGuest `
        -StepName     $FailedStep `
        -ErrorMessage $FailureMessage `
        -RunId        $RunId `
        -GitCommit    $GitCommit
    Send-Notification -Config $Config `
        -Subject "Yuruna VDE Test: FAIL on $HostType / $FailedGuest / $FailedStep" `
        -Body    $body
}

Stop-StatusServer -Job $ServerJob
exit $(if ($OverallPassed) { 0 } else { 1 })
