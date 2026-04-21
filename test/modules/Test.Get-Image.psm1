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

# $global:__YurunaLogFile is the cross-module log-file communication channel
# (owned by Test.Log.psm1 / consumed by yuruna-log.psm1's Write-* proxies).
# Suppressing PSAvoidGlobalVars keeps analyzer clean without losing the
# contract.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '')]
param()

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
        "host.macos.utm/guest.ubuntu.server" {
            return "$HOME/virtual/ubuntu.env/host.macos.utm.guest.ubuntu.server.iso"
        }
        "host.macos.utm/guest.windows.11" {
            return "$HOME/virtual/windows.env/host.macos.utm.guest.windows.11.iso"
        }
        default {
            # Hyper-V guests: image files live under the default virtual hard disk path
            $fileNames = @{
                "host.windows.hyper-v/guest.amazon.linux"    = "host.windows.hyper-v.guest.amazon.linux.vhdx"
                "host.windows.hyper-v/guest.ubuntu.desktop"  = "host.windows.hyper-v.guest.ubuntu.desktop.iso"
                "host.windows.hyper-v/guest.ubuntu.server"   = "host.windows.hyper-v.guest.ubuntu.server.iso"
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

# Emits a line to the console and — if active — to the cycle's HTML log.
# Write-Host bypasses the function output pipeline; without this, the caller's
# "$r = Invoke-GetImage ..." captures every line alongside the return hashtable
# and silently throws them away.
function Write-GetImageLine {
    param([string]$Line)
    Microsoft.PowerShell.Utility\Write-Host $Line
    if ($global:__YurunaLogFile) {
        [System.Net.WebUtility]::HtmlEncode($Line) |
            Microsoft.PowerShell.Utility\Out-File -FilePath $global:__YurunaLogFile -Append -Encoding utf8 -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Runs Get-Image.ps1 for the given host+guest, or skips if the image exists.
.DESCRIPTION
    Returns a hashtable: { success, skipped, errorMessage }
    Subprocess stdout/stderr is streamed to the console and HTML log so
    Get-Image.ps1 diagnostics (URL probes, fallback warnings, proxy issues)
    remain visible when invoked through the test runner.
#>
function Invoke-GetImage {
    param(
        [string]$HostType,
        [string]$GuestKey,
        [string]$VirtualRoot,
        [bool]  $AlwaysRedownload
    )
    $scriptPath = Join-Path $VirtualRoot "$HostType/$GuestKey/Get-Image.ps1"
    if (-not (Test-Path $scriptPath)) {
        return @{ success=$false; skipped=$false; errorMessage="Get-Image.ps1 not found at: $scriptPath" }
    }

    if (-not $AlwaysRedownload) {
        $imagePath = Get-ImagePath -HostType $HostType -GuestKey $GuestKey
        if ($imagePath -and (Test-Path $imagePath)) {
            Write-GetImageLine "Image exists, skipping download: $imagePath"
            return @{ success=$true; skipped=$true; errorMessage=$null }
        }
    }

    Write-GetImageLine "Running: $scriptPath"
    # 2>&1 merges stderr into stdout so Write-Warning / Write-Error output from
    # Get-Image.ps1 is forwarded too.
    & pwsh -NoProfile -File $scriptPath 2>&1 | ForEach-Object {
        Write-GetImageLine ([string]$_)
    }
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        return @{ success=$false; skipped=$false; errorMessage="Get-Image.ps1 exited with code $code" }
    }
    return @{ success=$true; skipped=$false; errorMessage=$null }
}

Export-ModuleMember -Function Get-ImagePath, Invoke-GetImage
