<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456712
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

# ── Create ────────────────────────────────────────────────────────────────────

# Runs New-VM.ps1 for the given host+guest with the specified VM name.
# The script is executed as a child process so that exit codes are properly captured.
# Returns a hashtable: { success, errorMessage }
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
    & pwsh -NoProfile -File $scriptPath -VMName $VMName
    if ($LASTEXITCODE -ne 0) {
        return @{ success=$false; errorMessage="New-VM.ps1 exited with code $LASTEXITCODE" }
    }
    return @{ success=$true; errorMessage=$null }
}

# ── Verify creation ──────────────────────────────────────────────────────────

# Verifies that a VM was successfully created by the New-VM.ps1 script.
# Dispatches to the host-specific implementation. Returns $true on success.
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
    $hostname    = if ($IsMacOS) { (& hostname -s 2>$null).Trim() } else { (& hostname).Trim() }
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

# Removes the test VM created by New-VM.ps1. Returns $true on success.
# A cleanup failure is non-fatal: the runner logs a warning but continues.
function Remove-TestVM {
    param([string]$HostType, [string]$VMName)
    switch ($HostType) {
        "host.macos.utm"       { return Remove-UtmTestVM    -VMName $VMName }
        "host.windows.hyper-v" { return Remove-HyperVTestVM -VMName $VMName }
        default { Write-Warning "Unknown host type for cleanup: $HostType"; return $false }
    }
}

function Remove-UtmTestVM {
    param([string]$VMName)
    $hostname  = if ($IsMacOS) { (& hostname -s 2>$null).Trim() } else { (& hostname).Trim() }
    $utmBundle = "$HOME/Desktop/Yuruna.VDE/$hostname.nosync/$VMName.utm"
    if (Test-Path $utmBundle) {
        Remove-Item -Recurse -Force $utmBundle
        Write-Output "Removed UTM bundle: $utmBundle"
        return $true
    }
    Write-Warning "UTM bundle not found for cleanup: $utmBundle"
    return $false
}

function Remove-HyperVTestVM {
    param([string]$VMName)
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($vm) {
        Stop-VM    -Name $VMName -Force -TurnOff -ErrorAction SilentlyContinue
        Remove-VM  -Name $VMName -Force
        Write-Output "Removed Hyper-V VM: $VMName"
    }
    $vhdPath = (Get-VMHost -ErrorAction SilentlyContinue).VirtualHardDiskPath
    if ($vhdPath) {
        $vmDir = Join-Path $vhdPath $VMName
        if (Test-Path $vmDir) {
            Remove-Item -Recurse -Force $vmDir
            Write-Output "Removed VM disk directory: $vmDir"
        }
    }
    return $true
}

Export-ModuleMember -Function Invoke-NewVM, Confirm-VMCreated, Remove-TestVM
