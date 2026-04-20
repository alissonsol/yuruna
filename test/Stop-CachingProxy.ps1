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
    # Repo root for importing VM.common.psm1 (squid forwarder helpers).
    $RepoRoot    = Split-Path -Parent $PSScriptRoot

    Write-Output ""
    Write-Output "=== Stop + delete '$VMName' (macOS/UTM) ==="

    # Host-side forwarders (paired with Start-SquidCache.ps1). Tear them
    # ALL down BEFORE deleting the VM — once the upstream cache is gone,
    # any guest still hitting 192.168.64.1:3128 (or an operator opening
    # :3000 on the host) would get connection-refused from the forwarder,
    # which is less informative than "nothing listening." Stop-All
    # handles every Yuruna forwarder.<Port>.pid under the state dir so
    # the Grafana :3000 tunnel and any future ports clean up together.
    # Unified cross-platform API — dispatches to Stop-AllSquidForwarder
    # under the hood on macOS. Keeps this script symmetrical with the
    # Windows branch further down, which also calls Remove-SquidCache-
    # PortMap via Test.PortMap.psm1.
    $portMapMod = Join-Path $RepoRoot "test/modules/Test.PortMap.psm1"
    if (Test-Path $portMapMod) {
        Import-Module $portMapMod -Force
        Write-Output "  Stopping all host-side forwarders (if any)..."
        [void](Remove-SquidCachePortMap)
    }
    # Clean up the cache-ip breadcrumb that Start-SquidCache wrote for
    # guest provisioners. Leaving it behind wouldn't hurt correctness
    # (guests would just re-fetch against a stale IP and fail open) but
    # matches the tidy-up pattern of the forwarder pidfiles.
    $cacheIpFile = Join-Path $HOME "virtual/squid-cache/cache-ip.txt"
    if (Test-Path $cacheIpFile) { Remove-Item -Path $cacheIpFile -Force -ErrorAction SilentlyContinue }

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

    # Tear down any host-side port mappings a prior cycle exposed for this
    # cache VM (Grafana on :3000 etc.). Done BEFORE deleting the VM so the
    # state file on disk and the in-kernel portproxy + firewall rules are
    # removed in sync — otherwise a stale :3000 listener would outlive the
    # VM and black-hole LAN traffic until the next Invoke-TestRunner cycle.
    $RepoRoot     = Split-Path -Parent $PSScriptRoot
    $portMapMod   = Join-Path $RepoRoot 'test\modules\Test.PortMap.psm1'
    if (Test-Path $portMapMod) {
        Import-Module $portMapMod -Force
        [void](Remove-SquidCachePortMap)
    }

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
