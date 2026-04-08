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
            try {
                if ($PSCmdlet.ShouldProcess($VMName, 'Stop Hyper-V VM')) {
                    Stop-VM -Name $VMName -Force -TurnOff -ErrorAction Stop -WarningAction SilentlyContinue 6>$null
                    # Close the vmconnect window for this VM
                    Get-Process -Name "vmconnect" -ErrorAction SilentlyContinue |
                        Where-Object { $_.MainWindowTitle -match [regex]::Escape($VMName) } |
                        Stop-Process -Force -ErrorAction SilentlyContinue
                }
                Write-Output "Stopped Hyper-V VM: $VMName"
                return $true
            } catch {
                Write-Warning "Stop-VM failed for '$VMName': $_"
                return $false
            }
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

Export-ModuleMember -Function Invoke-StartVM, Stop-TestVM, Confirm-VMStarted
