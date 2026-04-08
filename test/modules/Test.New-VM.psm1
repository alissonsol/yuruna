<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456712
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

# ── Create ────────────────────────────────────────────────────────────────────

<#
.SYNOPSIS
Runs New-VM.ps1 for the given host+guest with the specified VM name.
.DESCRIPTION
The script is executed as a child process so that exit codes are properly captured.
Returns a hashtable: { success, errorMessage }
#>
function Invoke-NewVM {
    param(
        [string]$HostType,
        [string]$GuestKey,
        [string]$VdeRoot,
        [string]$VMName
    )
    $scriptPath = Join-Path $VdeRoot "$HostType/$GuestKey/New-VM.ps1"
    if (-not (Test-Path $scriptPath)) {
        return @{ success=$false; errorMessage="New-VM.ps1 not found at: $scriptPath" }
    }
    Write-Output "Running: $scriptPath -VMName $VMName"
    $output = & pwsh -NoProfile -File $scriptPath -VMName $VMName 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) {
        $text = "$line".TrimEnd()
        if ($text -ne '' -and $text -notmatch '^\s*\d+%\s+complete') {
            Write-Output $text
        }
    }
    if ($exitCode -ne 0) {
        return @{ success=$false; errorMessage="New-VM.ps1 exited with code $exitCode" }
    }
    return @{ success=$true; errorMessage=$null }
}

# ── Verify creation ──────────────────────────────────────────────────────────

<#
.SYNOPSIS
Verifies that a VM was successfully created by the New-VM.ps1 script.
.DESCRIPTION
Dispatches to the host-specific implementation. Returns $true on success.
#>
function Confirm-VMCreated {
    param([string]$HostType, [string]$VMName)
    switch ($HostType) {
        "host.macos.utm"       { return Confirm-UtmVMCreated    -VMName $VMName }
        "host.windows.hyper-v" { return Confirm-HyperVVMCreated -VMName $VMName }
        default { Write-Error "Unknown host type for verification: $HostType"; return $false }
    }
}

function Confirm-UtmVMCreated {
    param([string]$VMName)
    $hostname    = $IsMacOS ? (& hostname -s 2>$null).Trim() : (& hostname).Trim()
    $configPlist = "$HOME/Desktop/Yuruna.VDE/$hostname.nosync/$VMName.utm/config.plist"
    if (Test-Path $configPlist) {
        Write-Output "Verified: $configPlist"
        return $true
    }
    Write-Error "VM verification failed: $configPlist not found."
    return $false
}

function Confirm-HyperVVMCreated {
    param([string]$VMName)
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($vm) {
        Write-Output "Verified: Hyper-V VM '$VMName' (State: $($vm.State))"
        return $true
    }
    Write-Error "VM verification failed: Hyper-V VM '$VMName' not found."
    return $false
}

# ── Cleanup ──────────────────────────────────────────────────────────────────

<#
.SYNOPSIS
Removes the test VM created by New-VM.ps1.
.DESCRIPTION
Returns $true on success. A cleanup failure is non-fatal: the runner logs a warning but continues.
#>
function Remove-TestVM {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$HostType, [string]$VMName)
    if ($PSCmdlet.ShouldProcess($VMName, 'Remove VM')) {
        switch ($HostType) {
            "host.macos.utm"       { return Remove-UtmTestVM    -VMName $VMName }
            "host.windows.hyper-v" { return Remove-HyperVTestVM -VMName $VMName }
            default { Write-Warning "Unknown host type for cleanup: $HostType"; return $false }
        }
    }
}

function Remove-UtmTestVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([string]$VMName)
    if ($PSCmdlet.ShouldProcess($VMName, 'Remove VM')) {
        # Stop the VM in UTM first (it may be running from a previous cycle)
        & utmctl stop "$VMName" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Output "Stopped UTM VM: $VMName"
            # Wait for the VM to fully stop before deleting
            $waited = 0
            while ($waited -lt 30) {
                Start-Sleep -Seconds 2
                $waited += 2
                $status = & utmctl status "$VMName" 2>&1
                if ($status -match "stopped|shutdown") { break }
            }
        }
        # Delete the VM from UTM's registry
        & utmctl delete "$VMName" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Start-Sleep -Seconds 3
            & utmctl delete "$VMName" 2>&1 | Out-Null
        }
        if ($LASTEXITCODE -eq 0) {
            Write-Output "Deleted UTM VM from registry: $VMName"
        }
        # Remove the bundle directory from disk
        $hostname  = $IsMacOS ? (& hostname -s 2>$null).Trim() : (& hostname).Trim()
        $utmBundle = "$HOME/Desktop/Yuruna.VDE/$hostname.nosync/$VMName.utm"
        if (Test-Path $utmBundle) {
            Remove-Item -Recurse -Force $utmBundle
            Write-Output "Removed UTM bundle: $utmBundle"
        }
        return $true
    }
}

function Remove-HyperVTestVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([string]$VMName)
    if ($PSCmdlet.ShouldProcess($VMName, 'Remove VM')) {
        $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
        if ($vm) {
            Stop-VM    -Name $VMName -Force -TurnOff -ErrorAction SilentlyContinue -WarningAction SilentlyContinue 6>$null
            Remove-VM  -Name $VMName -Force 6>$null
            Write-Output "Removed Hyper-V VM: $VMName"
        }
        $vhdPath = (Get-VMHost -ErrorAction SilentlyContinue).VirtualHardDiskPath
        if ($vhdPath) {
            $vmDir = Join-Path $vhdPath $VMName
            if (Test-Path $vmDir) {
                Remove-Item -Recurse -Force $vmDir 6>$null
                Write-Output "Removed VM disk directory: $vmDir"
            }
        }
        return $true
    }
}

Export-ModuleMember -Function Invoke-NewVM, Confirm-VMCreated, Remove-TestVM
