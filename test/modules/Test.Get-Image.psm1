<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456711
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

<#
.SYNOPSIS
    Returns the expected filesystem path of the base image for a given host+guest pair.
.DESCRIPTION
    Returns $null if the path cannot be determined statically (caller should not skip Get-Image).
#>
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
        default {
            # Hyper-V guests: image files live under the default virtual hard disk path
            $fileNames = @{
                "host.windows.hyper-v/guest.amazon.linux"    = "host.windows.hyper-v.guest.amazon.linux.vhdx"
                "host.windows.hyper-v/guest.ubuntu.desktop"  = "host.windows.hyper-v.guest.ubuntu.desktop.iso"
                "host.windows.hyper-v/guest.windows.11"      = "host.windows.hyper-v.guest.windows.11.iso"
            }
            $fileName = $fileNames["$HostType/$GuestKey"]
            if (-not $fileName) { return $null }
            try {
                $vhdPath = (Get-VMHost -ErrorAction Stop).VirtualHardDiskPath
                return Join-Path $vhdPath $fileName
            } catch { return $null }
        }
    }
}

<#
.SYNOPSIS
    Runs Get-Image.ps1 for the given host+guest, or skips if the image exists.
.DESCRIPTION
    Returns a hashtable: { success, skipped, errorMessage }
#>
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
    & pwsh -NoProfile -File $scriptPath
    if ($LASTEXITCODE -ne 0) {
        return @{ success=$false; skipped=$false; errorMessage="Get-Image.ps1 exited with code $LASTEXITCODE" }
    }
    return @{ success=$true; skipped=$false; errorMessage=$null }
}

Export-ModuleMember -Function Get-ImagePath, Invoke-GetImage
