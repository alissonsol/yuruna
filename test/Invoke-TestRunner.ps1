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
    [switch]$NoExtensionOutput,
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
$VerifyDir      = Join-Path $TestRoot "verify"

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
foreach ($mod in @("Test.Host", "Test.Status", "Test.Notify", "Test.Get-Image", "Test.New-VM", "Test.Start-VM", "Test.Install-OS", "Test.Screenshot", "Test.Invoke-PoolTest")) {
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

Import-Module (Join-Path $ModulesDir "Test.LogDir.psm1") -Force
$YurunaLogDir = Get-YurunaLogDir
Write-Output "Log folder: $YurunaLogDir"

if ($Config.statusServer.enabled -and -not $NoServer) {
    $startScript = Join-Path $TestRoot "Start-StatusServer.ps1"
    $serverPort  = if ($Config.statusServer.port) { [int]$Config.statusServer.port } else { 8080 }
    & $startScript -Port $serverPort
}

$GuestList = Get-GuestList -Config $Config
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
$BaseSteps = @("New-VM", "Start-VM", "Install-OS", "Verify-VM")
$hasExtensions  = $false
$hasScreenshots = $false
foreach ($GuestKey in $GuestList) {
    if ((Get-GuestTestScript -GuestKey $GuestKey -ExtensionsDir $ExtensionsDir).Count -gt 0) {
        $hasExtensions = $true
    }
    if ((Get-ScreenshotSchedule -GuestKey $GuestKey -ScreenshotsDir $ScreenshotsDir).Count -gt 0) {
        $hasScreenshots = $true
    }
}
$StepNames = $BaseSteps
if ($hasScreenshots) { $StepNames += @("Screenshots") }
if ($hasExtensions)  { $StepNames += @("Invoke-PoolTest") }

$VmStartTimeout = if ($Config.vmStartTimeoutSeconds) { [int]$Config.vmStartTimeoutSeconds } else { 120 }
$VmBootDelay    = if ($Config.vmBootDelaySeconds)    { [int]$Config.vmBootDelaySeconds }    else { 15 }
$CycleDelay     = if ($Config.cycleDelaySeconds)     { [int]$Config.cycleDelaySeconds }     else { $CycleDelaySeconds }
$GetImageRefreshHours = if ($Config.getImageRefreshHours) { [int]$Config.getImageRefreshHours } else { 24 }

# === Continuous test loop ===
$CycleCount     = 0
try {
    $prevStatus = Get-Content -Raw $StatusFile | ConvertFrom-Json
    if ($prevStatus.cycle) { $CycleCount = [int]$prevStatus.cycle }
} catch { Write-Warning "Could not read previous cycle count from status file: $_" }
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
            Write-Output "  ERROR: git sync failed"
            Write-Output "  Could not update from remote. Possible causes:"
            Write-Output "  - Local branch has diverged (rebase/merge manually)"
            Write-Output "  - Network connectivity issue"
            Write-Output "  - Uncommitted local changes blocking fast-forward"
            Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            Write-Output ""
            $body = Format-FailureMessage `
                -HostType     $HostType `
                -Hostname     (hostname) `
                -GuestKey     "(bootstrap)" `
                -StepName     "GitPull" `
                -ErrorMessage "Git sync failed. Branch may have diverged, or network is unreachable." `
                -RunId        "(not yet assigned)" `
                -GitCommit    (Get-CurrentGitCommit -RepoRoot $RepoRoot)
            Send-Notification -Config $Config `
                -Subject "Yuruna VDE Test: FAIL on $HostType / GitPull" `
                -Body    $body
            exit 1
        }
    } else {
        $Warnings.Add("Git pull was skipped (-NoGitPull).")
    }
    $GitCommit = Get-CurrentGitCommit -RepoRoot $RepoRoot

    # --- Initialize status for this cycle ---
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

    # --- Get-Image (every N hours, configurable) ---
    $lastGetImage = Get-LastGetImageTime -StatusFilePath $StatusFile
    $needGetImage = (-not $lastGetImage) -or ((Get-Date).ToUniversalTime() - [datetime]$lastGetImage).TotalHours -ge $GetImageRefreshHours

    if ($needGetImage) {
        Write-Output ""
        Write-Output "--- Get-Image (${GetImageRefreshHours}h refresh) ---"
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

    # --- Test each guest sequentially (cleanup → create → start → verify → screenshots → pool test → stop) ---
    # Only one guest VM exists at a time, so failures don't leave other VMs active.
    foreach ($GuestKey in $GuestList) {
        $VMName = $VMNames[$GuestKey]
        Write-Output ""
        Write-Output "=== $GuestKey (VM: $VMName) ==="

        # --- Cleanup previous VM ---
        $savedProgress = $global:ProgressPreference
        $global:ProgressPreference = 'SilentlyContinue'
        Remove-TestVM -HostType $HostType -VMName $VMName | Out-Null
        $global:ProgressPreference = $savedProgress

        # --- New-VM ---
        Set-GuestVMName -GuestKey $GuestKey -VMName $VMName
        Set-GuestStatus -GuestKey $GuestKey -Status "running"

        Set-StepStatus -GuestKey $GuestKey -StepName "New-VM" -Status "running"
        $r = Invoke-NewVM -HostType $HostType -GuestKey $GuestKey -VdeRoot $VdeRoot -VMName $VMName
        if ($r.success) {
            Set-StepStatus -GuestKey $GuestKey -StepName "New-VM" -Status "pass"
            Write-Output "  $GuestKey New-VM: PASS"
        } else {
            Write-Warning "  ERROR [$GuestKey / New-VM]: $($r.errorMessage)"
            Set-StepStatus  -GuestKey $GuestKey -StepName "New-VM" -Status "fail" -ErrorMessage $r.errorMessage
            Set-GuestStatus -GuestKey $GuestKey -Status "fail"
            $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "New-VM"; $FailureMessage = $r.errorMessage
            break
        }

        # --- Start-VM ---
        Set-StepStatus -GuestKey $GuestKey -StepName "Start-VM" -Status "running"
        $r = Invoke-StartVM -HostType $HostType -VMName $VMName
        if ($r.success) {
            Set-StepStatus -GuestKey $GuestKey -StepName "Start-VM" -Status "pass"
            Write-Output "  $GuestKey Start-VM: PASS"
        } else {
            Write-Warning "  ERROR [$GuestKey / Start-VM]: $($r.errorMessage)"
            Set-StepStatus  -GuestKey $GuestKey -StepName "Start-VM" -Status "fail" -ErrorMessage $r.errorMessage
            Set-GuestStatus -GuestKey $GuestKey -Status "fail"
            $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "Start-VM"; $FailureMessage = $r.errorMessage
            break
        }

        # --- Install-OS (run Test-Start scripts to drive OS installation) ---
        Set-StepStatus -GuestKey $GuestKey -StepName "Install-OS" -Status "running"
        $showExtOutput = -not $NoExtensionOutput
        $r = Invoke-StartTest -HostType $HostType -GuestKey $GuestKey -VMName $VMName -ExtensionsDir $ExtensionsDir -ShowOutput $showExtOutput
        if ($r.skipped) {
            Set-StepStatus -GuestKey $GuestKey -StepName "Install-OS" -Status "skipped" -Skipped $true
        } elseif ($r.success) {
            Set-StepStatus -GuestKey $GuestKey -StepName "Install-OS" -Status "pass"
            Write-Output "  $GuestKey Install-OS: PASS"
        } else {
            Write-Warning "  ERROR [$GuestKey / Install-OS]: $($r.errorMessage)"
            Set-StepStatus  -GuestKey $GuestKey -StepName "Install-OS" -Status "fail" -ErrorMessage $r.errorMessage
            Set-GuestStatus -GuestKey $GuestKey -Status "fail"
            $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "Install-OS"; $FailureMessage = $r.errorMessage
            Stop-TestVM -HostType $HostType -VMName $VMName | Out-Null
            break
        }

        # --- Verify-VM (poll until running, wait boot delay, then verify screenshot) ---
        Set-StepStatus -GuestKey $GuestKey -StepName "Verify-VM" -Status "running"
        $ok = Confirm-VMStarted -HostType $HostType -VMName $VMName `
            -TimeoutSeconds $VmStartTimeout -BootDelaySeconds $VmBootDelay
        if (-not $ok) {
            $err = "VM '$VMName' did not reach running state after start."
            Write-Warning "  ERROR [$GuestKey / Verify-VM]: $err"
            Set-StepStatus  -GuestKey $GuestKey -StepName "Verify-VM" -Status "fail" -ErrorMessage $err
            Set-GuestStatus -GuestKey $GuestKey -Status "fail"
            $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "Verify-VM"; $FailureMessage = $err
            Stop-TestVM -HostType $HostType -VMName $VMName | Out-Null
            break
        }
        # Check verification screenshot if one exists for this host+guest
        $verifyRef = Get-VerifyScreenshot -HostType $HostType -GuestKey $GuestKey -VerifyDir $VerifyDir
        if ($verifyRef) {
            $verifyFileName = "$HostType.$GuestKey.png"
            $verifyCapture = Join-Path $VerifyDir "actual/$verifyFileName"
            $actualDir = Join-Path $VerifyDir "actual"
            if (-not (Test-Path $actualDir)) { New-Item -ItemType Directory -Force -Path $actualDir | Out-Null }
            $captured = Get-VMScreenshot -HostType $HostType -VMName $VMName -OutputPath $verifyCapture
            if ($captured) {
                $threshold = if ($Config.verifyScreenshotThreshold) { [double]$Config.verifyScreenshotThreshold } else { 0.85 }
                $cmp = Compare-Screenshot -ReferencePath $verifyRef -ActualPath $verifyCapture -Threshold $threshold
                if (-not $cmp.match) {
                    $err = "Verify screenshot mismatch: similarity=$($cmp.similarity) threshold=$threshold"
                    Write-Warning "  ERROR [$GuestKey / Verify-VM]: $err"
                    Set-StepStatus  -GuestKey $GuestKey -StepName "Verify-VM" -Status "fail" -ErrorMessage $err
                    Set-GuestStatus -GuestKey $GuestKey -Status "fail"
                    $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "Verify-VM"; $FailureMessage = $err
                    Stop-TestVM -HostType $HostType -VMName $VMName | Out-Null
                    break
                }
                Write-Output "  $GuestKey Verify-VM: PASS (screenshot similarity=$($cmp.similarity))"
            } else {
                Write-Output "  $GuestKey Verify-VM: PASS (screenshot capture skipped)"
            }
        } else {
            Write-Output "  $GuestKey Verify-VM: PASS"
        }
        Set-StepStatus -GuestKey $GuestKey -StepName "Verify-VM" -Status "pass"

        # --- Screenshots (compare against trained references) ---
        if ($hasScreenshots) {
            Set-StepStatus -GuestKey $GuestKey -StepName "Screenshots" -Status "running"
            $r = Invoke-ScreenshotTest -HostType $HostType -GuestKey $GuestKey `
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
                Stop-TestVM -HostType $HostType -VMName $VMName | Out-Null
                break
            }
        }

        # --- Invoke-PoolTest (extension scripts) ---
        if ($hasExtensions) {
            Set-StepStatus -GuestKey $GuestKey -StepName "Invoke-PoolTest" -Status "running"
            $r = Invoke-PoolTest -HostType $HostType -GuestKey $GuestKey -VMName $VMName -ExtensionsDir $ExtensionsDir -ShowOutput $showExtOutput
            if ($r.skipped) {
                Set-StepStatus -GuestKey $GuestKey -StepName "Invoke-PoolTest" -Status "skipped" -Skipped $true
            } elseif ($r.success) {
                Set-StepStatus -GuestKey $GuestKey -StepName "Invoke-PoolTest" -Status "pass"
                Write-Output "  $GuestKey Invoke-PoolTest: PASS"
            } else {
                Write-Warning "  ERROR [$GuestKey / Invoke-PoolTest]: $($r.errorMessage)"
                Set-StepStatus  -GuestKey $GuestKey -StepName "Invoke-PoolTest" -Status "fail" -ErrorMessage $r.errorMessage
                Set-GuestStatus -GuestKey $GuestKey -Status "fail"
                $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "Invoke-PoolTest"; $FailureMessage = $r.errorMessage
                Stop-TestVM -HostType $HostType -VMName $VMName | Out-Null
                break
            }
        }

        # --- Stop and remove this guest VM before starting the next ---
        Set-GuestStatus -GuestKey $GuestKey -Status "pass"
        Write-Output "  ${GuestKey}: PASS"
        Write-Output "  Stopping VM '$VMName'..."
        $savedProgress = $global:ProgressPreference
        $global:ProgressPreference = 'SilentlyContinue'
        Stop-TestVM -HostType $HostType -VMName $VMName | Out-Null
        Write-Output "  Removing VM '$VMName'..."
        Remove-TestVM -HostType $HostType -VMName $VMName | Out-Null
        $global:ProgressPreference = $savedProgress
        Write-Output "  Cleanup complete for $GuestKey."
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
        -Hostname     (hostname) `
        -GuestKey     $FailedGuest `
        -StepName     $FailedStep `
        -ErrorMessage $FailureMessage `
        -RunId        $RunId `
        -GitCommit    $GitCommit
    Send-Notification -Config $Config `
        -Subject "Yuruna VDE Test: FAIL on $HostType / $FailedGuest / $FailedStep" `
        -Body    $body
}

exit $(if ($OverallPassed) { 0 } else { 1 })
