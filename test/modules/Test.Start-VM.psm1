<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456713
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

# ── Start VM ─────────────────────────────────────────────────────────────────

<#
.SYNOPSIS
    Starts a VM that was previously created by New-VM.ps1.
    Returns a hashtable: { success, errorMessage }
#>
function Invoke-StartVM {
    param([string]$HostType, [string]$VMName)
    switch ($HostType) {
        "host.macos.utm"       { return Start-UtmVM    -VMName $VMName }
        "host.windows.hyper-v" { return Start-HyperVVM -VMName $VMName }
        default { return @{ success=$false; errorMessage="Unknown host type for Start-VM: $HostType" } }
    }
}

function Start-UtmVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([string]$VMName)
    $hostname = $IsMacOS ? (& hostname -s 2>$null).Trim() : (& hostname).Trim()
    $utmBundle = "$HOME/Desktop/Yuruna.VDE/$hostname.nosync/$VMName.utm"
    if (-not (Test-Path $utmBundle)) {
        return @{ success=$false; errorMessage="UTM bundle not found: $utmBundle" }
    }
    try {
        if ($PSCmdlet.ShouldProcess($VMName, 'Start UTM VM')) {
            & open "$utmBundle"
            Start-Sleep -Seconds 5
            & utmctl start "$VMName" 2>&1 | Write-Output
            if ($LASTEXITCODE -ne 0) {
                return @{ success=$false; errorMessage="utmctl start failed for '$VMName' (exit code $LASTEXITCODE)" }
            }
        }
        return @{ success=$true; errorMessage=$null }
    } catch {
        return @{ success=$false; errorMessage="Failed to start UTM VM '$VMName': $_" }
    }
}

function Start-HyperVVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([string]$VMName)
    try {
        if ($PSCmdlet.ShouldProcess($VMName, 'Start Hyper-V VM')) {
            Start-VM -Name $VMName -ErrorAction Stop -WarningAction SilentlyContinue 6>$null
            # Open the VM console window in basic mode (no Enhanced Session).
            # This provides a visible window for screenshots and keystroke delivery
            # without requiring guest integration tools inside the VM.
            $vmconnect = "$env:SystemRoot\System32\vmconnect.exe"
            if (Test-Path $vmconnect) {
                Start-Process -FilePath $vmconnect -ArgumentList "localhost", $VMName
                Start-Sleep -Seconds 2
            }
        }
        return @{ success=$true; errorMessage=$null }
    } catch {
        return @{ success=$false; errorMessage="Start-VM failed for '$VMName': $_" }
    }
}

# ── Stop VM (without destroy) ────────────────────────────────────────────────

<#
.SYNOPSIS
    Stops a running VM without deleting it. Used between per-guest tests
    to avoid one guest's window interfering with another's screenshot.
    Returns $true on success.
#>
function Stop-TestVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([string]$HostType, [string]$VMName)
    switch ($HostType) {
        "host.macos.utm" {
            if ($PSCmdlet.ShouldProcess($VMName, 'Stop UTM VM')) {
                & utmctl stop "$VMName" 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Output "Stopped UTM VM: $VMName"
                    Start-Sleep -Seconds 2
                    return $true
                }
                Write-Warning "utmctl stop failed for '$VMName' (exit $LASTEXITCODE)"
                return $false
            }
            return $true
        }
        "host.windows.hyper-v" {
            if (-not $PSCmdlet.ShouldProcess($VMName, 'Stop Hyper-V VM')) { return $true }
            # Prefer Stop-HyperVVMForce (Test.New-VM.psm1): Stop-VM -TurnOff
            # with a 20 s deadline, then kill vmwp.exe for the VM's GUID if
            # it's still not Off. Plain Stop-VM -TurnOff hangs indefinitely
            # when vmms can't complete a 'Stopping' transition — exactly the
            # stuck test-ubuntu-server-01 case that broke continuous runs
            # even with stopOnFailure=false, because the runner blocked
            # here before it ever got to Remove-TestVM.
            $stopped = $false
            if (Get-Command Stop-HyperVVMForce -ErrorAction SilentlyContinue) {
                try {
                    $stopped = [bool](Stop-HyperVVMForce -VMName $VMName -StopTimeoutSeconds 20 -Confirm:$false)
                } catch {
                    Write-Warning "Stop-HyperVVMForce threw for '$VMName': $_"
                    $stopped = $false
                }
            } else {
                # Fallback only — Test.New-VM.psm1 is loaded by
                # Invoke-TestRunner alongside this module, so this branch
                # is reached only when Test.Start-VM is used in isolation.
                try {
                    Stop-VM -Name $VMName -Force -TurnOff -ErrorAction Stop -WarningAction SilentlyContinue 6>$null
                    $stopped = $true
                } catch {
                    Write-Warning "Stop-VM failed for '$VMName': $_"
                    $stopped = $false
                }
            }
            # Close the vmconnect window for this VM regardless — the host
            # window has no value once the VM is off (or being killed).
            Get-Process -Name "vmconnect" -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowTitle -match [regex]::Escape($VMName) } |
                Stop-Process -Force -ErrorAction SilentlyContinue
            if ($stopped) {
                Write-Output "Stopped Hyper-V VM: $VMName"
            } else {
                Write-Warning "Failed to stop Hyper-V VM '$VMName'; Remove-TestVM may take over."
            }
            return $stopped
        }
        default {
            Write-Warning "Unknown host type for Stop-VM: $HostType"
            return $false
        }
    }
}

# ── Verify running ───────────────────────────────────────────────────────────

<#
.SYNOPSIS
    Polls until the VM reaches a running state or the timeout expires.
    After confirming the VM is running, waits an additional BootDelaySeconds
    to allow the guest OS to initialize before any screenshot or test.
    Returns $true on success.
#>
function Confirm-VMStarted {
    param(
        [string]$HostType,
        [string]$VMName,
        [int]$TimeoutSeconds  = 120,
        [int]$BootDelaySeconds = 0
    )
    $running = switch ($HostType) {
        "host.macos.utm"       { Confirm-UtmVMStarted    -VMName $VMName -TimeoutSeconds $TimeoutSeconds }
        "host.windows.hyper-v" { Confirm-HyperVVMStarted -VMName $VMName -TimeoutSeconds $TimeoutSeconds }
        default { Write-Error "Unknown host type for start verification: $HostType"; $false }
    }
    if ($running -and $BootDelaySeconds -gt 0) {
        Write-Output "VM is running. Waiting ${BootDelaySeconds}s for guest OS to initialize..."
        Start-Sleep -Seconds $BootDelaySeconds
    }
    return $running
}

function Confirm-UtmVMStarted {
    param([string]$VMName, [int]$TimeoutSeconds = 120)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $output = & utmctl status "$VMName" 2>&1
        if ($output -match "started|running") {
            Write-Output "Verified: UTM VM '$VMName' is running"
            return $true
        }
        Start-Sleep -Seconds 5
        $elapsed += 5
    }
    Write-Error "UTM VM '$VMName' did not reach running state within ${TimeoutSeconds}s"
    return $false
}

function Confirm-HyperVVMStarted {
    param([string]$VMName, [int]$TimeoutSeconds = 120)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
        if ($vm -and $vm.State -eq 'Running') {
            Write-Output "Verified: Hyper-V VM '$VMName' is running (State: $($vm.State))"
            return $true
        }
        Start-Sleep -Seconds 5
        $elapsed += 5
    }
    Write-Error "Hyper-V VM '$VMName' did not reach Running state within ${TimeoutSeconds}s"
    return $false
}

# ── Reconnect vmconnect ──────────────────────────────────────────────────────

<#
.SYNOPSIS
    Closes and reopens the vmconnect window for a Hyper-V VM.
    After a host reboot the console window sometimes fails to repaint;
    reconnecting forces a full framebuffer refresh.
    No-op on non-Hyper-V hosts.
#>
function Restart-VMConnect {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$HostType, [string]$VMName)
    if ($HostType -ne "host.windows.hyper-v") { return }
    $vmconnect = "$env:SystemRoot\System32\vmconnect.exe"
    if (-not (Test-Path $vmconnect)) { return }

    if ($PSCmdlet.ShouldProcess($VMName, 'Reconnect vmconnect')) {
        # Close any existing vmconnect window for this VM
        Get-Process -Name "vmconnect" -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowTitle -match [regex]::Escape($VMName) } |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        # Reopen the console
        Start-Process -FilePath $vmconnect -ArgumentList "localhost", $VMName
        Start-Sleep -Seconds 2
        Write-Information "    Reconnected vmconnect for '$VMName'"
    }
}

Export-ModuleMember -Function Invoke-StartVM, Stop-TestVM, Confirm-VMStarted, Restart-VMConnect
