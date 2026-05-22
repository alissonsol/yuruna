<#PSScriptInfo
.VERSION 2026.05.22
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456730
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
    The guest to train. Any guest.<name> whose host/<short-host>/<guestKey>/ folder
    exists on the current host is accepted (e.g. guest.amazon.linux.2023,
    guest.ubuntu.server.24, guest.windows.11).

.PARAMETER ConfigPath
    Path to test.config.yml. Defaults to test/test.config.yml.

.PARAMETER Threshold
    Default similarity threshold for screenshot comparisons (0.0-1.0). Default: 0.85.

.EXAMPLE
    pwsh test/Train-Screenshots.ps1 -GuestKey guest.amazon.linux.2023

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
$ModulesDir    = Join-Path $TestRoot "modules"
$ScreenshotsDir = Join-Path $TestRoot "screenshots"

if (-not $ConfigPath) { $ConfigPath = Join-Path $TestRoot "test.config.yml" }

foreach ($mod in @("Test.Host", "Test.Get-Image", "Test.New-VM", "Test.Start-VM", "Test.Screenshot")) {
    $modPath = Join-Path $ModulesDir "$mod.psm1"
    if (-not (Test-Path $modPath)) { Write-Error "Module not found: $modPath"; exit 1 }
    Import-Module -Name $modPath -Force
}

if (-not (Test-Path $ConfigPath)) { Write-Error "Config not found: $ConfigPath"; exit 1 }
$Config = Get-Content -Raw $ConfigPath | ConvertFrom-Yaml -Ordered

$HostType = Get-HostType
if (-not $HostType) { exit 1 }

# Auto-relaunch under sg libvirt on host.ubuntu.kvm when this shell's
# group set is stale -- Train-Screenshots provisions a VM via the
# Yuruna.Host contract (New-VM -> virt-install), which needs the
# libvirt socket. No-op elsewhere.
Invoke-LibvirtGroupReExecIfNeeded -HostType $HostType -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

Write-Output "Host type: $HostType"
Write-Output "Guest:     $GuestKey"
Write-Output ""

# Wire the host driver so contract calls (New-VM, Start-VM, Get-VMState,
# Get-VMScreenshot, ...) resolve without HostType branches.
[void](Initialize-YurunaHost -RepoRoot $RepoRoot -HostType $HostType)

if (-not (Test-GuestFolder -RepoRoot $RepoRoot -HostType $HostType -GuestKey $GuestKey)) {
    Write-Error "Guest folder not found for '$GuestKey' on $HostType`: $(Join-Path $RepoRoot (Join-Path (Get-HostFolder $HostType) $GuestKey))"
    exit 1
}

$Prefix = if ($Config.vmStart.testVmNamePrefix) { $Config.vmStart.testVmNamePrefix } else { "test-" }
$VMName = Get-TestVMName -GuestKey $GuestKey -Prefix $Prefix

$guestDir = Join-Path $ScreenshotsDir $GuestKey
$refDir   = Join-Path $guestDir "reference"
if (-not (Test-Path $refDir)) { New-Item -ItemType Directory -Force -Path $refDir | Out-Null }

Write-Output "Reference screenshots will be saved to: $refDir"
Write-Output ""

Write-Output "--- Checking base image ---"
$r = Get-Image -GuestKey $GuestKey -RepoRoot $RepoRoot -Confirm:$false
if (-not $r.success) { Write-Error "Get-Image failed: $($r.errorMessage)"; exit 1 }

Write-Output "--- Cleaning previous VM ---"
Remove-VM -VMName $VMName -Confirm:$false | Out-Null

Write-Output "--- Creating VM ---"
$r = New-VM -GuestKey $GuestKey -RepoRoot $RepoRoot -VMName $VMName -Confirm:$false
if (-not $r.success) { Write-Error "New-VM failed: $($r.errorMessage)"; exit 1 }

Write-Output "--- Starting VM ---"
$r = Start-VM -VMName $VMName -Confirm:$false
if (-not $r.success) { Write-Error "Start-VM failed: $($r.errorMessage)"; exit 1 }

Write-Output "--- Waiting for VM to reach running state ---"
$ok = Wait-VMRunning -VMName $VMName -TimeoutSeconds 120
if (-not $ok) { Write-Error "VM did not start"; exit 1 }

Write-Output ""
Write-Output "========================================="
Write-Output "  VM '$VMName' is running."
Write-Output "  Screenshot training mode is active."
Write-Output "========================================="
Write-Output ""

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
            $schedule = [ordered]@{
                guestKey    = $GuestKey
                hostType    = $HostType
                trainedAt   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                vmName      = $VMName
                checkpoints = @($checkpoints)
            }
            $scheduleFile = Join-Path $guestDir "schedule.json"
            $schedule | ConvertTo-Json -Depth 5 | Set-Content -Path $scheduleFile -Encoding utf8BOM
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
        $cpName = $cpName -replace '[^a-zA-Z0-9._-]', '-'

        $delay = [Math]::Round(((Get-Date) - $startTime).TotalSeconds)
        $outFile = Join-Path $refDir "$cpName.png"

        Write-Output "Capturing '$cpName'..."
        $captured = Get-VMScreenshot -VMName $VMName -OutFile $outFile
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

Write-Output ""
Write-Output "--- Stopping VM ---"
Stop-VM -VMName $VMName -Confirm:$false
Write-Output "Training complete."
