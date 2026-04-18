<#PSScriptInfo
.VERSION 0.1
.GUID 42c3d4e5-f6a7-4b89-0c12-de3f4a5b6c7d
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

param(
    [string]$Prefix = "test-"
)

$ErrorActionPreference = "Stop"
$TestRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $TestRoot
$ModulesDir = Join-Path $TestRoot "modules"

# === Import Test.Host + Test.New-VM (the latter provides Stop-HyperVVMForce) ===
$hostModPath = Join-Path $ModulesDir "Test.Host.psm1"
if (-not (Test-Path $hostModPath)) { Write-Error "Module not found: $hostModPath"; exit 1 }
Import-Module -Name $hostModPath -Force
# Test.New-VM.psm1 import is mandatory: it provides Stop-HyperVVMForce, which
# is the only path that escalates to killing vmwp.exe when a VM is stuck in
# 'Stopping'. Without it, a hung VM (e.g. test-ubuntu-server-01) blocks
# cleanup forever.
$newVmModPath = Join-Path $ModulesDir "Test.New-VM.psm1"
if (-not (Test-Path $newVmModPath)) { Write-Error "Module not found: $newVmModPath"; exit 1 }
Import-Module -Name $newVmModPath -Force
if (-not (Get-Command Stop-HyperVVMForce -ErrorAction SilentlyContinue)) {
    Write-Error "Stop-HyperVVMForce not exported from $newVmModPath"; exit 1
}

# === Detect host type ===
$HostType = Get-HostType
if (-not $HostType) { exit 1 }
Write-Output "Host type: $HostType"
Write-Output ""

# === Stop all test-* VMs ===
Write-Output "Stopping VMs with prefix '$Prefix'..."
Write-Output ""

switch ($HostType) {
    "host.windows.hyper-v" {
        $testVMs = Get-VM | Where-Object { $_.Name -like "${Prefix}*" }
        if ($testVMs.Count -eq 0) {
            Write-Output "  No Hyper-V VMs found matching '${Prefix}*'."
        }
        foreach ($vm in $testVMs) {
            Write-Output "  Stopping $($vm.Name) [$($vm.State)]..."
            if ($vm.State -ne 'Off') {
                # Stop-HyperVVMForce escalates to killing the VM's vmwp.exe
                # worker process when Stop-VM -TurnOff can't bring the VM to
                # 'Off' within 20 s (typically a stuck 'Stopping' state).
                # Without this escalation, a hung VM blocks cleanup forever
                # and every subsequent cycle retries against the same stale
                # instance — exactly what happened to test-ubuntu-server-01.
                # -Confirm:$false: automated harness must not prompt.
                $stopped = Stop-HyperVVMForce -VMName $vm.Name -StopTimeoutSeconds 20 -Confirm:$false
                if ($stopped) {
                    Write-Output "    Stopped."
                } else {
                    Write-Warning "    Stop-HyperVVMForce returned `$false for $($vm.Name); Remove-VM may fail."
                }
            } else {
                Write-Output "    Already off."
            }
            Remove-VM -Name $vm.Name -Force -Confirm:$false 6>$null
            Write-Output "    Removed from Hyper-V."
        }
    }
    "host.macos.utm" {
        $utmOutput = & utmctl list 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to query UTM VMs. Is UTM running? Output: $utmOutput"
            exit 1
        }
        $found = $false
        foreach ($line in $utmOutput) {
            $line = "$line".Trim()
            if (-not $line -or $line -match '^-+$') { continue }
            $parts = $line -split '\s{2,}'
            if ($parts.Count -ge 2 -and $parts[0] -match '^[0-9A-Fa-f-]{36}$') {
                $vmUuid = $parts[0].Trim()
                $vmName = $parts[1].Trim()
                if ($vmName -like "${Prefix}*") {
                    $found = $true
                    Write-Output "  Stopping $vmName..."
                    & utmctl stop "$vmName" 2>&1 | Out-Null
                    # Wait for the VM to fully stop before deleting
                    $waited = 0
                    while ($waited -lt 30) {
                        Start-Sleep -Seconds 2
                        $waited += 2
                        $status = & utmctl status "$vmName" 2>&1
                        if ($status -match "stopped|shutdown") { break }
                    }
                    # Delete by UUID (more reliable than by name)
                    $deleted = $false
                    & utmctl delete "$vmUuid" 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) { $deleted = $true }
                    if (-not $deleted) {
                        Write-Warning "    utmctl delete by UUID failed for '$vmName'. Retrying by name..."
                        Start-Sleep -Seconds 3
                        & utmctl delete "$vmName" 2>&1 | Out-Null
                        if ($LASTEXITCODE -eq 0) { $deleted = $true }
                    }
                    # Verify removal from UTM registry
                    if ($deleted) {
                        $null = & utmctl status "$vmUuid" 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            Write-Warning "    VM '$vmName' still present in UTM after delete."
                            $deleted = $false
                        }
                    }
                    if ($deleted) {
                        Write-Output "    Removed from UTM."
                    } else {
                        Write-Warning "    Could not remove '$vmName' from UTM registry. Files will not be cleaned to avoid stale entries."
                    }
                }
            }
        }
        if (-not $found) {
            Write-Output "  No UTM VMs found matching '${Prefix}*'."
        }
    }
    default {
        Write-Error "Unsupported host type: $HostType"
        exit 1
    }
}

Write-Output ""

# === Run Remove-OrphanedVMFiles.ps1 with -Force ===
$vdeDir = Join-Path $RepoRoot "vde"
$cleanupScript = Join-Path -Path $vdeDir -ChildPath "$HostType" -AdditionalChildPath "Remove-OrphanedVMFiles.ps1"

if (-not (Test-Path $cleanupScript)) {
    Write-Error "Cleanup script not found: $cleanupScript"
    exit 1
}

Write-Output "Running orphaned VM file cleanup: $cleanupScript"
Write-Output ""
& $cleanupScript -Force
