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

# === Import Test.Host (needed for Get-HostType on every platform) ===
$hostModPath = Join-Path $ModulesDir "Test.Host.psm1"
if (-not (Test-Path $hostModPath)) { Write-Error "Module not found: $hostModPath"; exit 1 }
Import-Module -Name $hostModPath -Force

# === Detect host type ===
$HostType = Get-HostType
if (-not $HostType) { exit 1 }
Write-Output "Host type: $HostType"
Write-Output ""

# === Hyper-V-only: Test.New-VM.psm1 provides Stop-HyperVVMForce ===
# macOS/UTM uses utmctl directly and doesn't need this module. Loading it
# unconditionally (and gating Get-Command Stop-HyperVVMForce before the
# host-type switch) was skipping cleanup on macOS if anything in that chain
# tripped under $ErrorActionPreference='Stop'.
if ($HostType -eq "host.windows.hyper-v") {
    $newVmModPath = Join-Path $ModulesDir "Test.New-VM.psm1"
    if (-not (Test-Path $newVmModPath)) { Write-Error "Module not found: $newVmModPath"; exit 1 }
    Import-Module -Name $newVmModPath -Force
    if (-not (Get-Command Stop-HyperVVMForce -ErrorAction SilentlyContinue)) {
        Write-Error "Stop-HyperVVMForce not exported from $newVmModPath"; exit 1
    }
}

# === Stop all test-* VMs ===
Write-Output "Stopping VMs with prefix '$Prefix'..."
Write-Output ""

# Track every VM we attempted, with a final disposition. Per-VM ops MUST
# NOT abort the whole loop: on a long-running host, a single stuck VM
# (locked .vhdx, wedged vmms, UTM helper holding a file handle) used to
# throw under $ErrorActionPreference='Stop' and skip every later test-*
# VM, so survivors accumulated cycle after cycle. Each VM is now wrapped
# in try/catch with its own continue-on-failure path; survivors are
# reported at the end and the orphan-file cleanup still runs so we
# reclaim disk even when one VM resists deletion.
$survivors = [System.Collections.Generic.List[string]]::new()
$removedCount = 0

switch ($HostType) {
    "host.windows.hyper-v" {
        $testVMs = @(Get-VM | Where-Object { $_.Name -like "${Prefix}*" })
        if ($testVMs.Count -eq 0) {
            Write-Output "  No Hyper-V VMs found matching '${Prefix}*'."
        }
        # Hyper-V reports several non-running states that all mean "Remove-VM
        # can take this without a stop call":
        #   Off          — cleanly powered down
        #   Saved        — saved state (suspended); stopping would just discard it
        #   OffCritical  — Hyper-V flagged a critical error and the VM is down
        # Skipping Stop-HyperVVMForce on those avoids the ~30 s force-stop chain
        # (20 s Stop-VM poll + vmwp.exe lookup + 10 s retry) that fires for
        # already-stopped VMs because the original gate only matched 'Off'.
        $stoppedStates = @('Off', 'Saved', 'OffCritical')
        foreach ($vm in $testVMs) {
            $vmName = $vm.Name
            Write-Output "  Stopping $vmName [$($vm.State)]..."
            try {
                if ($vm.State -notin $stoppedStates) {
                    # Stop-HyperVVMForce escalates to killing the VM's vmwp.exe
                    # worker process when Stop-VM -TurnOff can't bring the VM to
                    # 'Off' within 20 s (typically a stuck 'Stopping' state).
                    # Without this escalation, a hung VM blocks cleanup forever
                    # and every subsequent cycle retries against the same stale
                    # instance — exactly what happened to test-ubuntu-server-01.
                    # -Confirm:$false: automated harness must not prompt.
                    $stopped = Stop-HyperVVMForce -VMName $vmName -StopTimeoutSeconds 20 -Confirm:$false
                    if ($stopped) {
                        Write-Output "    Stopped."
                    } else {
                        Write-Warning "    Stop-HyperVVMForce returned `$false for $vmName; Remove-VM may fail."
                    }
                } else {
                    Write-Output "    Already stopped."
                }
                # Remove-VM throws on a locked .vhdx or a vmms RPC fault;
                # -ErrorAction Stop turns that into a catchable terminating
                # error so we don't drop into the global Stop preference and
                # abort the whole loop.
                Remove-VM -Name $vmName -Force -Confirm:$false -ErrorAction Stop 6>$null
                # Verify: vmms occasionally returns success while the VM
                # lingers as 'OffCritical'. Treat a re-readable Get-VM as
                # failure and surface it.
                $stillThere = Get-VM -Name $vmName -ErrorAction SilentlyContinue
                if ($stillThere) {
                    Write-Warning "    Remove-VM returned 0 but '$vmName' is still registered (state: $($stillThere.State))."
                    $survivors.Add("$vmName [$($stillThere.State)]")
                } else {
                    Write-Output "    Removed from Hyper-V."
                    $removedCount++
                }
            } catch {
                Write-Warning "    Failed to remove '$vmName': $_"
                $finalState = (Get-VM -Name $vmName -ErrorAction SilentlyContinue).State
                $survivors.Add("$vmName$(if ($finalState) { " [$finalState]" })")
            }
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
                    try {
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
                            $removedCount++
                        } else {
                            Write-Warning "    Could not remove '$vmName' from UTM registry. Files will not be cleaned to avoid stale entries."
                            $survivors.Add($vmName)
                        }
                    } catch {
                        Write-Warning "    Failed to remove '$vmName': $_"
                        $survivors.Add($vmName)
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

# Re-scan to catch survivors that the per-VM block missed (e.g. a VM
# that flipped to OffCritical while the loop was iterating). Belt-and-
# suspenders against the very symptom this script exists to fix:
# test-* VMs surviving across cycles on a long-running host.
switch ($HostType) {
    "host.windows.hyper-v" {
        $remaining = @(Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "${Prefix}*" })
        if ($remaining.Count -gt 0) {
            Write-Warning "  $($remaining.Count) Hyper-V VM(s) still match '${Prefix}*' after cleanup:"
            foreach ($vm in $remaining) {
                Write-Warning "    $($vm.Name) [$($vm.State)]"
            }
        }
    }
    "host.macos.utm" {
        $reList = & utmctl list 2>&1
        if ($LASTEXITCODE -eq 0) {
            $remaining = @()
            foreach ($line in $reList) {
                $line = "$line".Trim()
                if (-not $line -or $line -match '^-+$') { continue }
                $parts = $line -split '\s{2,}'
                if ($parts.Count -ge 2 -and $parts[0] -match '^[0-9A-Fa-f-]{36}$' -and $parts[1].Trim() -like "${Prefix}*") {
                    $remaining += $parts[1].Trim()
                }
            }
            if ($remaining.Count -gt 0) {
                Write-Warning "  $($remaining.Count) UTM VM(s) still match '${Prefix}*' after cleanup:"
                foreach ($n in $remaining) { Write-Warning "    $n" }
            }
        }
    }
}

Write-Output ""
Write-Output "Removed $removedCount VM(s); $($survivors.Count) survivor(s)."
if ($survivors.Count -gt 0) {
    foreach ($s in $survivors) { Write-Warning "  Survivor: $s" }
}
Write-Output ""

$virtualDir = Join-Path $RepoRoot "virtual"
$cleanupScript = Join-Path -Path $virtualDir -ChildPath "$HostType" -AdditionalChildPath "Remove-OrphanedVMFiles.ps1"

if (-not (Test-Path $cleanupScript)) {
    Write-Error "Cleanup script not found: $cleanupScript"
    exit 1
}

# Always run the orphan-file sweep — even if some VMs survived the
# registry-removal step. Their on-disk files are still claimed by the
# surviving registration so the orphan script will skip them, but
# files left over from earlier failures (the actual symptom on
# long-running hosts) get reclaimed.
Write-Output "Running orphaned VM file cleanup: $cleanupScript"
Write-Output ""
& $cleanupScript -Force
