<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456705
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

Export-ModuleMember -Function Remove-TestVM
