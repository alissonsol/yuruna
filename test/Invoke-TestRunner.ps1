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
    [string]$ConfigPath        = $null,
    [switch]$NoGitPull,
    [switch]$NoServer,
    [int]$CycleDelaySeconds    = 30
)

# === Resolve paths ===
$TestRoot       = $PSScriptRoot
$RepoRoot       = Split-Path -Parent $TestRoot
$VdeRoot        = Join-Path $RepoRoot "vde"
$StatusDir      = Join-Path $TestRoot "status"
$StatusFile     = Join-Path $StatusDir "status.json"
$StatusTmpl     = Join-Path $StatusDir "status.json.template"
$ModulesDir     = Join-Path $TestRoot "modules"
$ExtensionsDir  = Join-Path $TestRoot "extensions"
$ScreenshotsDir = Join-Path $TestRoot "screenshots"

if (-not $ConfigPath) { $ConfigPath = Join-Path $TestRoot "test-config.json" }

# === Bootstrap status.json from template if missing ===
if (-not (Test-Path $StatusFile)) {
    if (Test-Path $StatusTmpl) {
        Copy-Item -Path $StatusTmpl -Destination $StatusFile
        Write-Output "Created status.json from template."
    } else {
        Write-Error "Status template not found: $StatusTmpl"; exit 1
    }
}

# === Import modules ===
foreach ($mod in @("Test.Host", "Test.Status", "Test.StatusServer", "Test.Notify", "Test.Get-Image", "Test.New-VM", "Test.Start-VM", "Test.Screenshot")) {
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

# Selenium prerequisite (one-time check for Hyper-V + Windows 11)
$GuestList = Get-GuestList
if ($GuestList -contains "guest.windows.11" -and $HostType -eq "host.windows.hyper-v") {
    if (-not (Test-SeleniumPrerequisite -RepoRoot $RepoRoot)) {
        Write-Error "chromedriver.exe not found. Run test/Get-Selenium.ps1 as Administrator first."
        Stop-StatusServer -Job $ServerJob
        exit 1
    }
}

$Prefix = if ($Config.testVmNamePrefix) { $Config.testVmNamePrefix } else { "test-" }

# Build VM name map
$VMNames = @{}
foreach ($GuestKey in $GuestList) {
    $VMNames[$GuestKey] = switch ($GuestKey) {
        "guest.amazon.linux"   { "${Prefix}amazon-linux01"   }
        "guest.ubuntu.desktop" { "${Prefix}ubuntu-desktop01" }
        "guest.windows.11"     { "${Prefix}windows11-01"     }
        default                { "${Prefix}vm01"             }
    }
}

# Determine step list based on available extensions and screenshot schedules
$BaseSteps = @("NewVM", "StartVM", "VerifyVM")
$hasExtensions = $false
$hasScreenshots = $false
foreach ($GuestKey in $GuestList) {
    if ((Get-GuestTestScripts -GuestKey $GuestKey -ExtensionsDir $ExtensionsDir).Count -gt 0) {
        $hasExtensions = $true
    }
    if ((Get-ScreenshotSchedule -GuestKey $GuestKey -ScreenshotsDir $ScreenshotsDir).Count -gt 0) {
        $hasScreenshots = $true
    }
}
$StepNames = $BaseSteps
if ($hasScreenshots) { $StepNames += @("Screenshots") }
if ($hasExtensions)  { $StepNames += @("CustomTests") }

$VmStartTimeout = if ($Config.vmStartTimeoutSeconds) { [int]$Config.vmStartTimeoutSeconds } else { 120 }
$VmBootDelay    = if ($Config.vmBootDelaySeconds)    { [int]$Config.vmBootDelaySeconds }    else { 15 }
$CycleDelay     = if ($Config.cycleDelaySeconds)     { [int]$Config.cycleDelaySeconds }     else { $CycleDelaySeconds }

# === Continuous test loop ===
$CycleCount     = 0
$OverallPassed  = $true

while ($true) {
    $CycleCount++
    $OverallPassed  = $true
    $FailedGuest    = $null
    $FailedStep     = $null
    $FailureMessage = $null
    $Warnings = [System.Collections.Generic.List[string]]::new()

    Write-Output ""
    Write-Output "============================================="
    Write-Output "  CYCLE $CycleCount"
    Write-Output "============================================="

    # --- Git pull ---
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

    # --- Initialise status for this cycle ---
    $RunId = Initialize-StatusDocument `
        -StatusFilePath $StatusFile `
        -HostType       $HostType `
        -Hostname       (hostname) `
        -GitCommit      $GitCommit `
        -GuestList      $GuestList `
        -StepNames      $StepNames

    Write-Output "Run ID:  $RunId"
    Write-Output "Commit:  $GitCommit"
    Write-Output "Guests:  $($GuestList -join ', ')"

    # --- Get-Image (every 24 hours) ---
    $lastGetImage = Get-LastGetImageTime -StatusFilePath $StatusFile
    $needGetImage = (-not $lastGetImage) -or ((Get-Date) - [datetime]$lastGetImage).TotalHours -ge 24

    if ($needGetImage) {
        Write-Output ""
        Write-Output "--- Get-Image (24h refresh) ---"
        foreach ($GuestKey in $GuestList) {
            Write-Output "Downloading image for $GuestKey..."
            $r = Invoke-GetImage -HostType $HostType -GuestKey $GuestKey -VdeRoot $VdeRoot -AlwaysRedownload $true
            if (-not $r.success) {
                Write-Warning "  ERROR [$GuestKey / GetImage]: $($r.errorMessage)"
                $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "GetImage"; $FailureMessage = $r.errorMessage
                break
            }
            Write-Output "  $GuestKey image: OK"
        }
        if ($OverallPassed) {
            Set-LastGetImageTime
            Write-Output "Get-Image complete. Timestamp updated."
        }
    } else {
        Write-Output "Get-Image: skipped (last run: $lastGetImage)"
    }

    # --- Abort cycle early if Get-Image failed ---
    if (-not $OverallPassed) {
        Complete-Run -OverallStatus "fail" -MaxHistoryRuns ([int]$Config.maxHistoryRuns)
        break
    }

    # --- Delete all previous VMs in block ---
    Write-Output ""
    Write-Output "--- Cleanup previous VMs ---"
    foreach ($GuestKey in $GuestList) {
        $VMName = $VMNames[$GuestKey]
        $cleaned = Remove-TestVM -HostType $HostType -VMName $VMName
        if ($cleaned) {
            Write-Output "  Removed: $VMName"
        } else {
            Write-Output "  Nothing to remove: $VMName"
        }
    }

    # --- Create all VMs (NewVM step for each guest) ---
    Write-Output ""
    Write-Output "--- Create VMs ---"
    foreach ($GuestKey in $GuestList) {
        $VMName = $VMNames[$GuestKey]
        Set-GuestVMName -GuestKey $GuestKey -VMName $VMName
        Set-GuestStatus -GuestKey $GuestKey -Status "running"

        Set-StepStatus -GuestKey $GuestKey -StepName "NewVM" -Status "running"
        $r = Invoke-NewVM -HostType $HostType -GuestKey $GuestKey -VdeRoot $VdeRoot -VMName $VMName
        if ($r.success) {
            Set-StepStatus -GuestKey $GuestKey -StepName "NewVM" -Status "pass"
            Write-Output "  $GuestKey NewVM: PASS"
        } else {
            Write-Warning "  ERROR [$GuestKey / NewVM]: $($r.errorMessage)"
            Set-StepStatus  -GuestKey $GuestKey -StepName "NewVM" -Status "fail" -ErrorMessage $r.errorMessage
            Set-GuestStatus -GuestKey $GuestKey -Status "fail"
            $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "NewVM"; $FailureMessage = $r.errorMessage
            break
        }
    }

    if (-not $OverallPassed) {
        Complete-Run -OverallStatus "fail" -MaxHistoryRuns ([int]$Config.maxHistoryRuns)
        break
    }

    # --- Test each guest individually (start → verify → screenshots → custom → stop) ---
    # Only one guest VM runs at a time so its window is in focus for screenshots.
    foreach ($GuestKey in $GuestList) {
        $VMName = $VMNames[$GuestKey]
        Write-Output ""
        Write-Output "=== $GuestKey (VM: $VMName) ==="

        # --- StartVM ---
        Set-StepStatus -GuestKey $GuestKey -StepName "StartVM" -Status "running"
        $r = Invoke-StartVM -HostType $HostType -VMName $VMName
        if ($r.success) {
            Set-StepStatus -GuestKey $GuestKey -StepName "StartVM" -Status "pass"
        } else {
            Write-Warning "  ERROR [$GuestKey / StartVM]: $($r.errorMessage)"
            Set-StepStatus  -GuestKey $GuestKey -StepName "StartVM" -Status "fail" -ErrorMessage $r.errorMessage
            Set-GuestStatus -GuestKey $GuestKey -Status "fail"
            $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "StartVM"; $FailureMessage = $r.errorMessage
            break
        }

        # --- VerifyVM (poll until running, then wait boot delay) ---
        Set-StepStatus -GuestKey $GuestKey -StepName "VerifyVM" -Status "running"
        $ok = Confirm-VMStarted -HostType $HostType -VMName $VMName `
            -TimeoutSeconds $VmStartTimeout -BootDelaySeconds $VmBootDelay
        if ($ok) {
            Set-StepStatus -GuestKey $GuestKey -StepName "VerifyVM" -Status "pass"
        } else {
            $err = "VM '$VMName' did not reach running state after start."
            Write-Warning "  ERROR [$GuestKey / VerifyVM]: $err"
            Set-StepStatus  -GuestKey $GuestKey -StepName "VerifyVM" -Status "fail" -ErrorMessage $err
            Set-GuestStatus -GuestKey $GuestKey -Status "fail"
            $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "VerifyVM"; $FailureMessage = $err
            break
        }

        # --- Screenshots (compare against trained references) ---
        if ($hasScreenshots) {
            Set-StepStatus -GuestKey $GuestKey -StepName "Screenshots" -Status "running"
            $r = Invoke-ScreenshotTests -HostType $HostType -GuestKey $GuestKey `
                -VMName $VMName -ScreenshotsDir $ScreenshotsDir
            if ($r.skipped) {
                Set-StepStatus -GuestKey $GuestKey -StepName "Screenshots" -Status "skipped" -Skipped $true
            } elseif ($r.success) {
                Set-StepStatus -GuestKey $GuestKey -StepName "Screenshots" -Status "pass"
            } else {
                Write-Warning "  ERROR [$GuestKey / Screenshots]: $($r.errorMessage)"
                Set-StepStatus  -GuestKey $GuestKey -StepName "Screenshots" -Status "fail" -ErrorMessage $r.errorMessage
                Set-GuestStatus -GuestKey $GuestKey -Status "fail"
                $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "Screenshots"; $FailureMessage = $r.errorMessage
                # Stop this guest before breaking
                Stop-TestVM -HostType $HostType -VMName $VMName | Out-Null
                break
            }
        }

        # --- CustomTests (extension scripts) ---
        if ($hasExtensions) {
            Set-StepStatus -GuestKey $GuestKey -StepName "CustomTests" -Status "running"
            $r = Invoke-GuestTests -HostType $HostType -GuestKey $GuestKey -VMName $VMName -ExtensionsDir $ExtensionsDir
            if ($r.skipped) {
                Set-StepStatus -GuestKey $GuestKey -StepName "CustomTests" -Status "skipped" -Skipped $true
            } elseif ($r.success) {
                Set-StepStatus -GuestKey $GuestKey -StepName "CustomTests" -Status "pass"
            } else {
                Write-Warning "  ERROR [$GuestKey / CustomTests]: $($r.errorMessage)"
                Set-StepStatus  -GuestKey $GuestKey -StepName "CustomTests" -Status "fail" -ErrorMessage $r.errorMessage
                Set-GuestStatus -GuestKey $GuestKey -Status "fail"
                $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "CustomTests"; $FailureMessage = $r.errorMessage
                # Stop this guest before breaking
                Stop-TestVM -HostType $HostType -VMName $VMName | Out-Null
                break
            }
        }

        # --- Stop this guest VM before starting the next ---
        Set-GuestStatus -GuestKey $GuestKey -Status "pass"
        Write-Output "  ${GuestKey}: PASS"
        Stop-TestVM -HostType $HostType -VMName $VMName | Out-Null
    }

    # === Finalise cycle ===
    $FinalStatus = if ($OverallPassed) { "pass" } else { "fail" }
    Complete-Run -OverallStatus $FinalStatus -MaxHistoryRuns ([int]$Config.maxHistoryRuns)

    Write-Output ""
    Write-Output "=== Cycle $CycleCount complete: $FinalStatus ==="

    if (-not $OverallPassed) {
        break
    }

    if ($Warnings.Count -gt 0) {
        Write-Output ""
        Write-Output "--- Warnings ---"
        foreach ($w in $Warnings) {
            Write-Warning "  $w"
        }
    }

    Write-Output "Next cycle in $CycleDelay seconds..."
    Start-Sleep -Seconds $CycleDelay
}

# === Failure notification (only reached on break) ===
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

Stop-StatusServer -Job $ServerJob
exit $(if ($OverallPassed) { 0 } else { 1 })
