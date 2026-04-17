<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456743
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
    Stops and deletes the squid-cache VM for the current host environment.

.DESCRIPTION
    Cross-platform inverse of Start-SquidCache.ps1. Detects the host
    (macOS/UTM or Windows/Hyper-V) and removes the squid-cache VM,
    its disk/bundle, and the stashed password file. The base image
    (host.*.guest.squid-cache.*) is intentionally KEPT so the next
    Start-SquidCache.ps1 run doesn't have to re-download ~600 MB.

    Flow:
      1. Stop and delete the VM registration (utmctl / Hyper-V).
      2. Remove the VM-specific disk/bundle directory.

    Safe to re-run: missing VM or bundle is treated as a no-op.

.PARAMETER VMName
    Name of the squid-cache VM. Default: squid-cache.

.EXAMPLE
    ./Stop-SquidCache.ps1
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = "squid-cache"
)

$global:InformationPreference = "Continue"
$global:ProgressPreference    = "SilentlyContinue"

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Error "Invalid VMName '$VMName'. Only alphanumeric, dot, hyphen, and underscore are allowed."
    exit 1
}

if ($IsMacOS) {
    $MachineName = $(hostname -s)
    $UtmDir      = "$HOME/Desktop/Yuruna.VDE/$MachineName.nosync/$VMName.utm"

    Write-Output ""
    Write-Output "=== Stop + delete '$VMName' (macOS/UTM) ==="

    # `utmctl status <name>` exits non-zero with "Virtual machine not found"
    # when the VM isn't registered — cheap probe, no need to parse `utmctl list`.
    & utmctl status $VMName 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Output "  VM registered with UTM — stopping and deleting..."
        & utmctl stop $VMName 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        & utmctl delete $VMName 2>&1 | Out-Null
    } else {
        Write-Output "  No VM registered with UTM."
    }

    if (Test-Path $UtmDir) {
        Write-Output "  Removing bundle $UtmDir"
        Remove-Item -Recurse -Force $UtmDir
    } else {
        Write-Output "  No bundle found at $UtmDir."
    }

    Write-Output ""
    Write-Output "Base image kept at: $HOME/virtual/squid-cache/"
    Write-Output "  (delete manually if you want the next Start-SquidCache.ps1"
    Write-Output "   to re-download a fresh cloud image)."
} elseif ($IsWindows) {
    Write-Output ""
    Write-Output "=== Stop + delete '$VMName' (Windows/Hyper-V) ==="

    # (Get-VMHost) loads the Hyper-V module on first use; fails cleanly if
    # Hyper-V isn't installed — same dependency Start-SquidCache.ps1 has.
    $downloadDir = (Get-VMHost).VirtualHardDiskPath
    $vmDir       = Join-Path $downloadDir $VMName

    $existing = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Output "  VM found (state: $($existing.State)) — stopping and removing..."
        Stop-VM -Name $VMName -Force -TurnOff -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Remove-VM -Name $VMName -Force
    } else {
        Write-Output "  No VM registered with Hyper-V."
    }

    if (Test-Path $vmDir) {
        Write-Output "  Removing VM disk directory $vmDir"
        Remove-Item -Recurse -Force $vmDir
    } else {
        Write-Output "  No VM disk directory found at $vmDir."
    }

    Write-Output ""
    Write-Output "Base image kept at: $downloadDir\host.windows.hyper-v.guest.squid-cache.vhdx"
    Write-Output "  (delete manually if you want the next Start-SquidCache.ps1"
    Write-Output "   to re-download a fresh cloud image)."
} else {
    Write-Error "Unsupported host. Stop-SquidCache.ps1 runs on macOS (UTM) or Windows (Hyper-V)."
    exit 1
}

Write-Output ""
Write-Output "Done."
