<#PSScriptInfo
.VERSION 0.1
.GUID a1b2c3d4-e5f6-4789-8abc-def012345604
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

Export-ModuleMember -Function Confirm-VMCreated
