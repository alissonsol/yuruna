<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456707
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

# The global variable is the cross-module communication channel with yuruna-log.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '')]
param(
    [string]$ConfigPath        = $null,
    [switch]$NoGitPull,
    [switch]$NoServer,
    [switch]$NoExtensionOutput,
    [int]$CycleDelaySeconds    = 30,
    [bool]$debug_mode          = $false,
    [bool]$verbose_mode        = $false
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
$VdeRoot        = Join-Path $RepoRoot "vde"
$StatusDir      = Join-Path $TestRoot "status"
$StatusFile     = Join-Path $StatusDir "status.json"
$StatusTmpl     = Join-Path $StatusDir "status.json.template"
$ModulesDir     = Join-Path $TestRoot "modules"
$ExtensionsDir  = Join-Path $TestRoot "extensions"
$ScreenshotsDir = Join-Path $TestRoot "screenshots"
$VerifyDir      = Join-Path $TestRoot "verify"

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

foreach ($mod in @("Test.Host", "Test.Status", "Test.Notify", "Test.Get-Image", "Test.New-VM", "Test.Start-VM", "Test.Install-OS", "Test.Screenshot", "Test.Invoke-PoolTest", "Test.Log")) {
    $modPath = Join-Path $ModulesDir "$mod.psm1"
    if (-not (Test-Path $modPath)) { Write-Error "Module not found: $modPath"; exit 1 }
    Import-Module -Name $modPath -Force
}

$global:VerbosePreference = $savedVerbose

# === Bootstrap status.json from template if missing ===
if (-not (Test-Path $StatusFile)) {
    if (Test-Path $StatusTmpl) {
        Copy-Item -Path $StatusTmpl -Destination $StatusFile
        Write-Output "Created status.json from template."
    } else {
        Write-Error "Status template not found: $StatusTmpl"; exit 1
    }
}

# === Read config ===
if (-not (Test-Path $ConfigPath)) { Write-Error "Config not found: $ConfigPath"; exit 1 }
$Config = Get-Content -Raw $ConfigPath | ConvertFrom-Json -AsHashtable

# === Phase 0: Bootstrap ===
$HostType = Get-HostType
if (-not $HostType) { exit 1 }
Write-Output "Host type: $HostType"

if (-not (Assert-HostConditionSet -HostType $HostType)) { exit 1 }

$savedVerbose = $global:VerbosePreference
$global:VerbosePreference = "SilentlyContinue"
Import-Module (Join-Path $ModulesDir "Test.LogDir.psm1") -Force
$global:VerbosePreference = $savedVerbose
$YurunaLogDir = Get-YurunaLogDir
Write-Output "Log folder: $YurunaLogDir"

$savedVerbose = $global:VerbosePreference
$global:VerbosePreference = "SilentlyContinue"
Import-Module (Join-Path $ModulesDir "Test.OcrEngine.psm1") -Force
Import-Module (Join-Path $ModulesDir "Test.Tesseract.psm1") -Force
$global:VerbosePreference = $savedVerbose
$activeEngines = Get-EnabledOcrProvider
$combineMode = ($env:YURUNA_OCR_COMBINE -eq 'And') ? 'And' : 'Or'
Write-Debug "OCR engines: $($activeEngines -join ', ') | combine: $combineMode"
if (-not (Assert-TesseractInstalled)) { exit 1 }

$startScript = Join-Path $TestRoot "Start-StatusServer.ps1"
if ($Config.statusServer.enabled -and -not $NoServer) {
    $serverPort  = $Config.statusServer.port ? [int]$Config.statusServer.port : 8080
    & $startScript -Port $serverPort -Restart
}

# === Helper: copy failure artifacts to status/log for remote inspection ===
function Copy-FailureArtifactsToStatusLog {
    param([string]$VMName)
    try {
        if (-not $LogFile) { return }
        $logId = [System.IO.Path]::GetFileNameWithoutExtension($LogFile)
        $statusLogDir = [System.IO.Path]::GetDirectoryName($LogFile)
        # Include a UTC error timestamp so multiple failures within the same run don't overwrite each other
        $errorTimestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH-mm-ssZ')

        $srcScreen = Join-Path $YurunaLogDir "failure_screenshot_${VMName}.png"
        if (Test-Path $srcScreen) {
            $destName = "$logId.$errorTimestamp.failure-screenshot.png"
            $dest = Join-Path $statusLogDir $destName
            Copy-Item -Path $srcScreen -Destination $dest -Force
            Write-Output "  Failure screenshot saved: ./status/log/$destName"
            # Write clickable HTML link directly to log file (bypasses proxy encoding)
            if ($global:__YurunaLogFile) {
                "  <a href=""$destName"">Failure screenshot: $destName</a>" |
                    Microsoft.PowerShell.Utility\Out-File -FilePath $global:__YurunaLogFile -Append -ErrorAction SilentlyContinue
            }
        }

        $srcOcr = Join-Path $YurunaLogDir "failure_ocr_${VMName}.txt"
        if (Test-Path $srcOcr) {
            $destName = "$logId.$errorTimestamp.failure-ocr.txt"
            $dest = Join-Path $statusLogDir $destName
            Copy-Item -Path $srcOcr -Destination $dest -Force
            Write-Output "  Failure OCR text saved: ./status/log/$destName"
            if ($global:__YurunaLogFile) {
                "  <a href=""$destName"">Failure OCR text: $destName</a>" |
                    Microsoft.PowerShell.Utility\Out-File -FilePath $global:__YurunaLogFile -Append -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Write-Warning "  Could not copy failure artifacts to status/log: $_"
    }
}

# === Graceful shutdown support ===
$script:ShutdownRequested = $false
$script:ActiveVMName      = $null
$script:CycleFinalized    = $true    # tracks whether Complete-Run/Stop-LogFile have been called

try {
    [Console]::CancelKeyPress += {
        param($eventSender, $e)
        $null = $eventSender  # required by .NET event signature
        $e.Cancel = $true
        $script:ShutdownRequested = $true
        Write-Warning "Shutdown requested (Ctrl+C). Will clean up after current operation..."
    }
} catch {
    Write-Verbose "Could not register CancelKeyPress handler (non-interactive session): $_"
}

# === Continuous test loop ===
$HeartbeatFile = Join-Path $StatusDir "server.heartbeat"
$CycleCount     = 0
try {
    $prevStatus = Get-Content -Raw $StatusFile | ConvertFrom-Json
    if ($prevStatus.cycle) { $CycleCount = [int]$prevStatus.cycle }
} catch { Write-Warning "Could not read previous cycle count from status file: $_" }
$OverallPassed       = $true
$ConsecutiveCrashes  = 0
$MaxConsecutiveCrashes = 3

while ($true) {
    if ($script:ShutdownRequested) {
        Write-Output "Shutdown requested. Exiting cycle loop."
        break
    }

    # Re-check all host conditions before each cycle — settings can revert
    # (e.g. after a system update or user change) between long-running cycles.
    if (-not (Assert-HostConditionSet -HostType $HostType)) {
        Write-Warning "Host conditions failed. Fix the reported issues and restart."
        break
    }

    $CycleCount++
    $OverallPassed  = $true
    $FailedGuest    = $null
    $FailedStep     = $null
    $FailureMessage = $null
    $script:CycleFinalized = $false
    $Warnings = [System.Collections.Generic.List[string]]::new()

  try {

    # Touch heartbeat so the status server knows the runner is alive
    Set-Content -Path $HeartbeatFile -Value (Get-Date -Format o) -ErrorAction SilentlyContinue

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

    # --- Re-read config (may have changed via git pull) ---
    try {
        $Config = Get-Content -Raw $ConfigPath | ConvertFrom-Json -AsHashtable
    } catch {
        Write-Warning "Could not reload config after git pull, using previous config: $_"
    }

    # --- Restart status server to pick up any file/config changes ---
    if ($Config.statusServer.enabled -and -not $NoServer) {
        $serverPort = $Config.statusServer.port ? [int]$Config.statusServer.port : 8080
        & $startScript -Port $serverPort -Restart
    }

    $GuestList = Get-GuestList -Config $Config
    $Prefix = $Config.testVmNamePrefix ?? "test-"

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

    $VmStartTimeout = $Config.vmStartTimeoutSeconds ? [int]$Config.vmStartTimeoutSeconds : 120
    $VmBootDelay    = $Config.vmBootDelaySeconds    ? [int]$Config.vmBootDelaySeconds    : 15
    $CycleDelay     = $Config.cycleDelaySeconds     ? [int]$Config.cycleDelaySeconds     : $CycleDelaySeconds
    $GetImageRefreshHours = $Config.getImageRefreshHours ? [int]$Config.getImageRefreshHours : 24
    $StopOnFailure  = if ($Config.ContainsKey('stopOnFailure')) { [bool]$Config.stopOnFailure } else { $false }

    # --- Initialize status for this cycle ---
    $RunId = Initialize-StatusDocument `
        -StatusFilePath $StatusFile `
        -HostType       $HostType `
        -Hostname       (hostname) `
        -GitCommit      $GitCommit `
        -RepoUrl        $Config.repoUrl `
        -GuestList      $GuestList `
        -StepNames      $StepNames

    # --- Start log file (transcript captures all console output) ---
    $LogFile = Start-LogFile -TestRoot $TestRoot -RunId $RunId -Hostname (hostname) -GitCommit $GitCommit
    Write-Output "Log file: $LogFile"

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
                Write-Output "  Log folder: $YurunaLogDir"
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
        # Timer not expired, but verify each image file actually exists.
        # Re-download any that are missing (e.g. manually deleted or first run after a clean).
        $missingAny = $false
        foreach ($GuestKey in $GuestList) {
            $imagePath = Get-ImagePath -HostType $HostType -GuestKey $GuestKey
            if (-not $imagePath -or -not (Test-Path $imagePath)) {
                $label = $imagePath ?? "$HostType/$GuestKey"
                Write-Output "Image file missing: $label — re-downloading..."
                $r = Invoke-GetImage -HostType $HostType -GuestKey $GuestKey -VdeRoot $VdeRoot -AlwaysRedownload $true
                if (-not $r.success) {
                    Write-Warning "  ERROR [$GuestKey / GetImage]: $($r.errorMessage)"
                    Write-Output "  Log folder: $YurunaLogDir"
                    $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "GetImage"; $FailureMessage = $r.errorMessage
                    $missingAny = $true
                    break
                }
                Write-Output "  $GuestKey image: OK (re-downloaded)"
            }
        }
        if (-not $missingAny) {
            Write-Output "Get-Image: skipped (last run: $lastGetImage, all images present)"
        }
    }

    # --- Abort cycle early if Get-Image failed ---
    if (-not $OverallPassed) {
        Complete-Run -OverallStatus "fail" -MaxHistoryRuns ([int]$Config.maxHistoryRuns)
        Stop-LogFile
        break
    }

    # --- Test each guest sequentially (cleanup → create → start → verify → screenshots → pool test → stop) ---
    # Only one guest VM exists at a time, so failures don't leave other VMs active.
    foreach ($GuestKey in $GuestList) {
        if ($script:ShutdownRequested) {
            Write-Output "Shutdown requested. Skipping remaining guests."
            $OverallPassed = $false; $FailedStep = "shutdown"
            break
        }
        $VMName = $VMNames[$GuestKey]
        $script:ActiveVMName = $VMName
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
            Write-Output "  Log folder: $YurunaLogDir"
            Set-StepStatus  -GuestKey $GuestKey -StepName "New-VM" -Status "fail" -ErrorMessage $r.errorMessage
            Set-GuestStatus -GuestKey $GuestKey -Status "fail"
            $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "New-VM"; $FailureMessage = $r.errorMessage
            if ($StopOnFailure) { break }
            Copy-FailureArtifactsToStatusLog -VMName $VMName
            continue
        }

        # --- Start-VM ---
        Set-StepStatus -GuestKey $GuestKey -StepName "Start-VM" -Status "running"
        $r = Invoke-StartVM -HostType $HostType -VMName $VMName
        if ($r.success) {
            Set-StepStatus -GuestKey $GuestKey -StepName "Start-VM" -Status "pass"
            Write-Output "  $GuestKey Start-VM: PASS"
        } else {
            Write-Warning "  ERROR [$GuestKey / Start-VM]: $($r.errorMessage)"
            Write-Output "  Log folder: $YurunaLogDir"
            Set-StepStatus  -GuestKey $GuestKey -StepName "Start-VM" -Status "fail" -ErrorMessage $r.errorMessage
            Set-GuestStatus -GuestKey $GuestKey -Status "fail"
            $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "Start-VM"; $FailureMessage = $r.errorMessage
            if ($StopOnFailure) { break }
            Copy-FailureArtifactsToStatusLog -VMName $VMName
            continue
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
            Write-Output "  Log folder: $YurunaLogDir"
            Set-StepStatus  -GuestKey $GuestKey -StepName "Install-OS" -Status "fail" -ErrorMessage $r.errorMessage
            Set-GuestStatus -GuestKey $GuestKey -Status "fail"
            $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "Install-OS"; $FailureMessage = $r.errorMessage
            if ($StopOnFailure) {
                Write-Output "  VM '$VMName' left running for investigation."
                break
            }
            Copy-FailureArtifactsToStatusLog -VMName $VMName
            Write-Output "  Cleaning up VM '$VMName' after failure..."
            $savedProgress = $global:ProgressPreference
            $global:ProgressPreference = 'SilentlyContinue'
            Stop-TestVM -HostType $HostType -VMName $VMName | Out-Null
            Remove-TestVM -HostType $HostType -VMName $VMName | Out-Null
            $global:ProgressPreference = $savedProgress
            continue
        }

        # --- Verify-VM (poll until running, wait boot delay, then verify screenshot) ---
        Set-StepStatus -GuestKey $GuestKey -StepName "Verify-VM" -Status "running"
        $ok = Confirm-VMStarted -HostType $HostType -VMName $VMName `
            -TimeoutSeconds $VmStartTimeout -BootDelaySeconds $VmBootDelay
        if (-not $ok) {
            $err = "VM '$VMName' did not reach running state after start."
            Write-Warning "  ERROR [$GuestKey / Verify-VM]: $err"
            Write-Output "  Log folder: $YurunaLogDir"
            Set-StepStatus  -GuestKey $GuestKey -StepName "Verify-VM" -Status "fail" -ErrorMessage $err
            Set-GuestStatus -GuestKey $GuestKey -Status "fail"
            $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "Verify-VM"; $FailureMessage = $err
            if ($StopOnFailure) {
                Write-Output "  VM '$VMName' left running for investigation."
                break
            }
            Copy-FailureArtifactsToStatusLog -VMName $VMName
            Write-Output "  Cleaning up VM '$VMName' after failure..."
            $savedProgress = $global:ProgressPreference
            $global:ProgressPreference = 'SilentlyContinue'
            Stop-TestVM -HostType $HostType -VMName $VMName | Out-Null
            Remove-TestVM -HostType $HostType -VMName $VMName | Out-Null
            $global:ProgressPreference = $savedProgress
            continue
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
                $threshold = $Config.verifyScreenshotThreshold ? [double]$Config.verifyScreenshotThreshold : 0.85
                $cmp = Compare-Screenshot -ReferencePath $verifyRef -ActualPath $verifyCapture -Threshold $threshold
                if (-not $cmp.match) {
                    $err = "Verify screenshot mismatch: similarity=$($cmp.similarity) threshold=$threshold"
                    Write-Warning "  ERROR [$GuestKey / Verify-VM]: $err"
                    Write-Output "  Log folder: $YurunaLogDir"
                    Set-StepStatus  -GuestKey $GuestKey -StepName "Verify-VM" -Status "fail" -ErrorMessage $err
                    Set-GuestStatus -GuestKey $GuestKey -Status "fail"
                    $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "Verify-VM"; $FailureMessage = $err
                    if ($StopOnFailure) {
                        Write-Output "  VM '$VMName' left running for investigation."
                        break
                    }
                    Copy-FailureArtifactsToStatusLog -VMName $VMName
                    Write-Output "  Cleaning up VM '$VMName' after failure..."
                    $savedProgress = $global:ProgressPreference
                    $global:ProgressPreference = 'SilentlyContinue'
                    Stop-TestVM -HostType $HostType -VMName $VMName | Out-Null
                    Remove-TestVM -HostType $HostType -VMName $VMName | Out-Null
                    $global:ProgressPreference = $savedProgress
                    continue
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
                Write-Output "  Log folder: $YurunaLogDir"
                Set-StepStatus  -GuestKey $GuestKey -StepName "Screenshots" -Status "fail" -ErrorMessage $r.errorMessage
                Set-GuestStatus -GuestKey $GuestKey -Status "fail"
                $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "Screenshots"; $FailureMessage = $r.errorMessage
                if ($StopOnFailure) {
                    Write-Output "  VM '$VMName' left running for investigation."
                    break
                }
                Copy-FailureArtifactsToStatusLog -VMName $VMName
                Write-Output "  Cleaning up VM '$VMName' after failure..."
                $savedProgress = $global:ProgressPreference
                $global:ProgressPreference = 'SilentlyContinue'
                Stop-TestVM -HostType $HostType -VMName $VMName | Out-Null
                Remove-TestVM -HostType $HostType -VMName $VMName | Out-Null
                $global:ProgressPreference = $savedProgress
                continue
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
                Write-Output "  Log folder: $YurunaLogDir"
                Set-StepStatus  -GuestKey $GuestKey -StepName "Invoke-PoolTest" -Status "fail" -ErrorMessage $r.errorMessage
                Set-GuestStatus -GuestKey $GuestKey -Status "fail"
                $OverallPassed = $false; $FailedGuest = $GuestKey; $FailedStep = "Invoke-PoolTest"; $FailureMessage = $r.errorMessage
                if ($StopOnFailure) {
                    Write-Output "  VM '$VMName' left running for investigation."
                    break
                }
                Copy-FailureArtifactsToStatusLog -VMName $VMName
                Write-Output "  Cleaning up VM '$VMName' after failure..."
                $savedProgress = $global:ProgressPreference
                $global:ProgressPreference = 'SilentlyContinue'
                Stop-TestVM -HostType $HostType -VMName $VMName | Out-Null
                Remove-TestVM -HostType $HostType -VMName $VMName | Out-Null
                $global:ProgressPreference = $savedProgress
                continue
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
        $script:ActiveVMName = $null
    }

    # === Finalise cycle ===
    $FinalStatus = $OverallPassed ? "pass" : "fail"
    Complete-Run -OverallStatus $FinalStatus -MaxHistoryRuns ([int]$Config.maxHistoryRuns)
    Stop-LogFile
    $script:CycleFinalized = $true

    Write-Output ""
    Write-Output "=== Cycle $CycleCount complete: $FinalStatus ==="

    if ($OverallPassed) { $ConsecutiveCrashes = 0 }

    if (-not $OverallPassed) {
        if ($StopOnFailure) {
            break
        }
        # Send notification but continue to next cycle
        if ($FailedGuest) {
            Write-Output ""
            Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            Write-Output "  FAILURE in cycle $CycleCount (continuing)"
            Write-Output "  Guest:   $FailedGuest"
            Write-Output "  Step:    $FailedStep"
            Write-Output "  Error:   $FailureMessage"
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
    }

    if ($Warnings.Count -gt 0) {
        Write-Output ""
        Write-Output "--- Warnings ---"
        foreach ($w in $Warnings) {
            Write-Warning "  $w"
        }
    }

  } catch {
    # --- Unhandled exception in cycle — emergency cleanup ---
    $ConsecutiveCrashes++
    Write-Output ""
    Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Output "  UNHANDLED ERROR in cycle $CycleCount"
    Write-Output "  $_"
    Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"

    # Stop/remove the active VM if one was in progress
    if ($script:ActiveVMName) {
        try {
            Write-Output "  Emergency cleanup: stopping VM '$($script:ActiveVMName)'..."
            $savedProgress = $global:ProgressPreference
            $global:ProgressPreference = 'SilentlyContinue'
            Stop-TestVM -HostType $HostType -VMName $script:ActiveVMName -ErrorAction SilentlyContinue | Out-Null
            Remove-TestVM -HostType $HostType -VMName $script:ActiveVMName -ErrorAction SilentlyContinue | Out-Null
            $global:ProgressPreference = $savedProgress
        } catch { Write-Warning "  Emergency VM cleanup failed: $_" }
        $script:ActiveVMName = $null
    }

    # Finalize the cycle if not already done
    if (-not $script:CycleFinalized) {
        try {
            Complete-Run -OverallStatus "fail" -MaxHistoryRuns ([int]$Config.maxHistoryRuns) -ErrorAction SilentlyContinue
            Stop-LogFile -ErrorAction SilentlyContinue
        } catch { Write-Warning "  Emergency cycle finalization failed: $_" }
        $script:CycleFinalized = $true
    }

    if ($ConsecutiveCrashes -ge $MaxConsecutiveCrashes) {
        Write-Output "  $ConsecutiveCrashes consecutive unhandled errors — aborting."
        $OverallPassed = $false
        break
    }
    Write-Output "  Will retry next cycle ($ConsecutiveCrashes/$MaxConsecutiveCrashes consecutive errors)."
  }

    if ($script:ShutdownRequested) {
        Write-Output "Shutdown requested. Exiting cycle loop."
        break
    }

    # Clean up all test VMs and files before the inter-cycle wait
    & (Join-Path $TestRoot "Remove-TestVMFiles.ps1") -Prefix $Prefix

    $delay = if ($CycleDelay) { $CycleDelay } else { $CycleDelaySeconds }
    for ($remaining = $delay; $remaining -gt 0; $remaining--) {
        $pct = [math]::Round((($delay - $remaining) / $delay) * 100)
        Write-Progress -Activity "Next cycle" -Status "in $remaining seconds..." -PercentComplete $pct
        Start-Sleep -Seconds 1
    }
    Write-Progress -Activity "Next cycle" -Completed

    # Clean up all test VMs and files after the inter-cycle wait
    & (Join-Path $TestRoot "Remove-TestVMFiles.ps1") -Prefix $Prefix
}

# === Failure notification (only reached when stopOnFailure breaks the loop) ===
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
    Write-Output "  Log:     $LogFile"
    Write-Output "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Output ""
    Write-Output "To reproduce with full diagnostics:"
    Write-Output "  pwsh test/Invoke-TestRunner.ps1 -NoGitPull -debug_mode `$true -verbose_mode `$true"

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

exit ($OverallPassed ? 0 : 1)
