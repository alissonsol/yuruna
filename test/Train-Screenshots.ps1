<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456730
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

<#
.SYNOPSIS
    Captures reference screenshots for a guest VM at timed checkpoints.

.DESCRIPTION
    Interactive training tool that:
    1. Creates a new VM for the specified guest
    2. Starts the VM
    3. Prompts you to capture screenshots at key moments
    4. Saves the screenshots and generates a schedule.json

    The schedule.json and reference PNGs are later used by the test runner
    to verify that VMs boot correctly by comparing live screenshots against
    the trained references.

.PARAMETER GuestKey
    The guest to train (e.g. guest.amazon.linux, guest.ubuntu.desktop, guest.windows.11).

.PARAMETER ConfigPath
    Path to test-config.json. Defaults to test/test-config.json.

.PARAMETER Threshold
    Default similarity threshold for screenshot comparisons (0.0-1.0). Default: 0.85.

.EXAMPLE
    pwsh test/Train-Screenshots.ps1 -GuestKey guest.amazon.linux

.EXAMPLE
    pwsh test/Train-Screenshots.ps1 -GuestKey guest.windows.11 -Threshold 0.80
#>

param(
    [Parameter(Mandatory)]
    [string]$GuestKey,
    [string]$ConfigPath = $null,
    [double]$Threshold  = 0.85
)

$TestRoot      = $PSScriptRoot
$RepoRoot      = Split-Path -Parent $TestRoot
$VdeRoot       = Join-Path $RepoRoot "vde"
$ModulesDir    = Join-Path $TestRoot "modules"
$ScreenshotsDir = Join-Path $TestRoot "screenshots"

if (-not $ConfigPath) { $ConfigPath = Join-Path $TestRoot "test-config.json" }

# Import required modules
foreach ($mod in @("Test.Host", "Test.Get-Image", "Test.New-VM", "Test.Start-VM", "Test.Screenshot")) {
    $modPath = Join-Path $ModulesDir "$mod.psm1"
    if (-not (Test-Path $modPath)) { Write-Error "Module not found: $modPath"; exit 1 }
    Import-Module -Name $modPath -Force
}

# Read config
if (-not (Test-Path $ConfigPath)) { Write-Error "Config not found: $ConfigPath"; exit 1 }
$Config = Get-Content -Raw $ConfigPath | ConvertFrom-Json -AsHashtable

$HostType = Get-HostType
if (-not $HostType) { exit 1 }
Write-Output "Host type: $HostType"
Write-Output "Guest:     $GuestKey"
Write-Output ""

$Prefix = if ($Config.testVmNamePrefix) { $Config.testVmNamePrefix } else { "test-" }
$VMName = switch ($GuestKey) {
    "guest.amazon.linux"   { "${Prefix}amazon-linux01"   }
    "guest.ubuntu.desktop" { "${Prefix}ubuntu-desktop01" }
    "guest.windows.11"     { "${Prefix}windows11-01"     }
    default                { "${Prefix}vm01"             }
}

# Setup directories
$guestDir = Join-Path $ScreenshotsDir $GuestKey
$refDir   = Join-Path $guestDir "reference"
if (-not (Test-Path $refDir)) { New-Item -ItemType Directory -Force -Path $refDir | Out-Null }

Write-Output "Reference screenshots will be saved to: $refDir"
Write-Output ""

# Ensure image exists
Write-Output "--- Checking base image ---"
$r = Invoke-GetImage -HostType $HostType -GuestKey $GuestKey -VdeRoot $VdeRoot -AlwaysRedownload $false
if (-not $r.success) { Write-Error "Get-Image failed: $($r.errorMessage)"; exit 1 }

# Clean up any previous VM
Write-Output "--- Cleaning previous VM ---"
Remove-TestVM -HostType $HostType -VMName $VMName | Out-Null

# Create VM
Write-Output "--- Creating VM ---"
$r = Invoke-NewVM -HostType $HostType -GuestKey $GuestKey -VdeRoot $VdeRoot -VMName $VMName
if (-not $r.success) { Write-Error "New-VM failed: $($r.errorMessage)"; exit 1 }

# Start VM
Write-Output "--- Starting VM ---"
$r = Invoke-StartVM -HostType $HostType -VMName $VMName
if (-not $r.success) { Write-Error "Start-VM failed: $($r.errorMessage)"; exit 1 }

# Wait for VM to be running
Write-Output "--- Waiting for VM to reach running state ---"
$ok = Confirm-VMStarted -HostType $HostType -VMName $VMName -TimeoutSeconds 120
if (-not $ok) { Write-Error "VM did not start"; exit 1 }

Write-Output ""
Write-Output "========================================="
Write-Output "  VM '$VMName' is running."
Write-Output "  Screenshot training mode is active."
Write-Output "========================================="
Write-Output ""

# Interactive checkpoint capture loop
$checkpoints = [System.Collections.Generic.List[object]]::new()
$startTime   = Get-Date
$cpIndex     = 0

Write-Output "Commands:"
Write-Output "  c [name]  — Capture a screenshot checkpoint (e.g. 'c boot-complete')"
Write-Output "  d         — Done, save schedule and exit"
Write-Output "  q         — Quit without saving"
Write-Output ""

while ($true) {
    $elapsed = [Math]::Round(((Get-Date) - $startTime).TotalSeconds)
    $userInput = Read-Host "[$($elapsed)s elapsed] Enter command"

    if ($userInput -eq 'q') {
        Write-Output "Quitting without saving."
        break
    }

    if ($userInput -eq 'd') {
        if ($checkpoints.Count -eq 0) {
            Write-Output "No checkpoints captured. Nothing to save."
        } else {
            # Write schedule.json
            $schedule = [ordered]@{
                guestKey    = $GuestKey
                hostType    = $HostType
                trainedAt   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                vmName      = $VMName
                checkpoints = @($checkpoints)
            }
            $scheduleFile = Join-Path $guestDir "schedule.json"
            $schedule | ConvertTo-Json -Depth 5 | Set-Content -Path $scheduleFile -Encoding utf8
            Write-Output ""
            Write-Output "Schedule saved: $scheduleFile"
            Write-Output "Reference screenshots: $refDir"
            Write-Output "Checkpoints: $($checkpoints.Count)"
            foreach ($cp in $checkpoints) {
                Write-Output "  - $($cp.name): delay=$($cp.delaySeconds)s threshold=$($cp.threshold)"
            }
        }
        break
    }

    if ($userInput -match '^c\s*(.*)$') {
        $cpIndex++
        $cpName = $Matches[1].Trim()
        if (-not $cpName) { $cpName = "checkpoint-$cpIndex" }
        # Sanitize name
        $cpName = $cpName -replace '[^a-zA-Z0-9._-]', '-'

        $delay = [Math]::Round(((Get-Date) - $startTime).TotalSeconds)
        $outFile = Join-Path $refDir "$cpName.png"

        Write-Output "Capturing '$cpName'..."
        $captured = Get-VMScreenshot -HostType $HostType -VMName $VMName -OutputPath $outFile
        if ($captured) {
            $checkpoints.Add([ordered]@{
                name         = $cpName
                delaySeconds = $delay
                threshold    = $Threshold
            })
            Write-Output "  Saved: $outFile (delay=${delay}s from VM start)"
        } else {
            Write-Warning "  Capture failed for '$cpName'"
        }
        continue
    }

    Write-Output "Unknown command. Use: c [name], d (done), q (quit)"
}

# Cleanup
Write-Output ""
Write-Output "--- Stopping VM ---"
Stop-TestVM -HostType $HostType -VMName $VMName
Write-Output "Training complete."
