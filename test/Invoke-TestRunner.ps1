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
$Warnings = [System.Collections.Generic.List[string]]::new()
if (-not $NoGitPull) {
    if (-not (Invoke-GitPull -RepoRoot $RepoRoot)) {
        Write-Output ""
        Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        Write-Output "  ERROR: git pull failed"
        Write-Output "  Check network connectivity and repository access."
        Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        Write-Output ""
        $body = Format-FailureMessage `
            -HostType     $HostType `
            -GuestKey     "(bootstrap)" `
            -StepName     "GitPull" `
            -ErrorMessage "git pull failed. Check network connectivity and repository access." `
            -RunId        "(not yet assigned)" `
            -GitCommit    (Get-CurrentGitCommit -RepoRoot $RepoRoot)
        Send-Notification -Config $Config `
            -Subject "Yuruna VDE Test: FAIL on $HostType / GitPull" `
            -Body    $body
        Stop-StatusServer -Job $ServerJob
        exit 1
    }
} else {
    $Warnings.Add("Git pull was skipped (-NoGitPull).")
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
            Write-Warning "  ERROR: $err"
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
        Write-Warning "  ERROR [$GuestKey / GetImage]: $($r.errorMessage)"
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
        Write-Warning "  ERROR [$GuestKey / NewVM]: $($r.errorMessage)"
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
        Write-Warning "  ERROR [$GuestKey / VerifyVM]: $err"
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
            $err = "Cleanup failed. Manual removal required for $VMName."
            Set-StepStatus -GuestKey $GuestKey -StepName "CleanupVM" -Status "fail" -ErrorMessage $err
            Write-Warning "[$GuestKey / CleanupVM]: $err"
            $Warnings.Add("$GuestKey / CleanupVM: $err")
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

# === Error / Warning summary ===
if (-not $OverallPassed -and $FailedGuest) {
    Write-Output ""
    Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Output "  FAILURE SUMMARY"
    Write-Output "  Host:    $HostType"
    Write-Output "  Guest:   $FailedGuest"
    Write-Output "  Step:    $FailedStep"
    Write-Output "  Error:   $FailureMessage"
    Write-Output "  Run ID:  $RunId"
    Write-Output "  Commit:  $GitCommit"
    Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"

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

if ($Warnings.Count -gt 0) {
    Write-Output ""
    Write-Output "--- Warnings ---"
    foreach ($w in $Warnings) {
        Write-Warning "  $w"
    }
}

Stop-StatusServer -Job $ServerJob
exit $(if ($OverallPassed) { 0 } else { 1 })
