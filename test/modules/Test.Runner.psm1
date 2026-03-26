<#PSScriptInfo
.VERSION 0.1
.GUID a1b2c3d4-e5f6-4789-8abc-def012345606
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

# Returns the expected filesystem path of the base image for a given host+guest pair.
# Returns $null if the path cannot be determined statically (caller should not skip Get-Image).
function Get-ImagePath {
    param([string]$HostType, [string]$GuestKey)
    switch ("$HostType/$GuestKey") {
        "host.macos.utm/guest.amazon.linux" {
            return "$HOME/virtual/amazon.linux/host.macos.utm.guest.amazon.linux.qcow2"
        }
        "host.macos.utm/guest.ubuntu.desktop" {
            return "$HOME/virtual/ubuntu.env/host.macos.utm.guest.ubuntu.desktop.iso"
        }
        "host.macos.utm/guest.windows.11" {
            return "$HOME/virtual/windows.env/host.macos.utm.guest.windows.11.iso"
        }
        "host.windows.hyper-v/guest.amazon.linux" {
            try {
                $vhdPath = (Get-VMHost -ErrorAction Stop).VirtualHardDiskPath
                return Join-Path $vhdPath "host.windows.hyper-v.guest.amazon.linux.vhdx"
            } catch { return $null }
        }
        "host.windows.hyper-v/guest.ubuntu.desktop" {
            try {
                $vhdPath = (Get-VMHost -ErrorAction Stop).VirtualHardDiskPath
                return Join-Path $vhdPath "host.windows.hyper-v.guest.ubuntu.desktop.iso"
            } catch { return $null }
        }
        "host.windows.hyper-v/guest.windows.11" {
            try {
                $vhdPath = (Get-VMHost -ErrorAction Stop).VirtualHardDiskPath
                return Join-Path $vhdPath "host.windows.hyper-v.guest.windows.11.iso"
            } catch { return $null }
        }
        default { return $null }
    }
}

# Runs Get-Image.ps1 for the given host+guest, or skips if the image exists and AlwaysRedownload is false.
# Returns a hashtable: { success, skipped, errorMessage }
function Invoke-GetImage {
    param(
        [string]$HostType,
        [string]$GuestKey,
        [string]$VdeRoot,
        [bool]  $AlwaysRedownload
    )
    $scriptPath = Join-Path $VdeRoot "$HostType/$GuestKey/Get-Image.ps1"
    if (-not (Test-Path $scriptPath)) {
        return @{ success=$false; skipped=$false; errorMessage="Get-Image.ps1 not found at: $scriptPath" }
    }

    if (-not $AlwaysRedownload) {
        $imagePath = Get-ImagePath -HostType $HostType -GuestKey $GuestKey
        if ($imagePath -and (Test-Path $imagePath)) {
            Write-Output "Image exists, skipping download: $imagePath"
            return @{ success=$true; skipped=$true; errorMessage=$null }
        }
    }

    Write-Output "Running: $scriptPath"
    & $scriptPath
    if ($LASTEXITCODE -ne 0) {
        return @{ success=$false; skipped=$false; errorMessage="Get-Image.ps1 exited with code $LASTEXITCODE" }
    }
    return @{ success=$true; skipped=$false; errorMessage=$null }
}

# Runs New-VM.ps1 for the given host+guest with the specified VM name.
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
    & $scriptPath -VMName $VMName
    if ($LASTEXITCODE -ne 0) {
        return @{ success=$false; errorMessage="New-VM.ps1 exited with code $LASTEXITCODE" }
    }
    return @{ success=$true; errorMessage=$null }
}

Export-ModuleMember -Function Get-ImagePath, Invoke-GetImage, Invoke-NewVM
