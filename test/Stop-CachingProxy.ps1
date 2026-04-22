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
    Inverse of Start-CachingProxy.ps1 — stops the squid-cache VM and
    removes its disk/bundle + stashed password. Base image is KEPT so
    the next start doesn't re-download ~600 MB. Safe to re-run.

.PARAMETER VMName   Name of the squid-cache VM. Default: squid-cache.
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

# === Revert machine-wide host proxy (if it was promoted) ===================
# Symmetric with Test-CachingProxy.ps1 -SetHostProxy. Runs UNCONDITIONALLY:
# the module's Clear-HostProxy restores from $HOME/.yuruna/host-proxy.backup.json
# when it exists and no-ops (with a disable-only fallback) when it doesn't,
# so calling it here is safe even if -SetHostProxy was never used. Done
# first so a failure tearing down the VM doesn't leave the host pointing at
# a dead proxy for the rest of the session.
# On macOS networksetup requires root — the sudo preamble above guarantees
# we are already elevated by the time this runs.
$hostProxyMod = Join-Path $PSScriptRoot 'modules/Test.HostProxy.psm1'
if (Test-Path -LiteralPath $hostProxyMod) {
    Import-Module $hostProxyMod -Force
    try {
        Clear-HostProxy
    } catch {
        # Any other failure (e.g. a corrupt backup, a transient networksetup
        # error) surfaces as a warning so the user can clean up manually,
        # but doesn't block the VM teardown from finishing.
        Write-Warning "Clear-HostProxy failed: $($_.Exception.Message). VM teardown will continue."
    }
}

if ($IsMacOS) {
    $MachineName = $(hostname -s)
    $UtmDir      = "$HOME/Desktop/Yuruna.VDE/$MachineName.nosync/$VMName.utm"
    # Repo root for importing VM.common.psm1 (squid forwarder helpers).
    $RepoRoot    = Split-Path -Parent $PSScriptRoot

    Write-Output ""
    Write-Output "=== Stop + delete '$VMName' (macOS/UTM) ==="

    # Host-side forwarders (paired with Start-CachingProxy.ps1). Tear them
    # ALL down BEFORE deleting the VM — once the upstream cache is gone,
    # any guest still hitting 192.168.64.1:3128 (or an operator opening
    # :3000 on the host) would get connection-refused from the forwarder,
    # which is less informative than "nothing listening." Stop-All
    # handles every Yuruna forwarder.<Port>.pid under the state dir so
    # the Grafana :3000 tunnel and any future ports clean up together.
    # Unified cross-platform API — dispatches to Stop-AllCachingProxyForwarder
    # under the hood on macOS. Keeps this script symmetrical with the
    # Windows branch further down, which also calls Remove-SquidCache-
    # PortMap via Test.PortMap.psm1.
    $portMapMod = Join-Path $RepoRoot "test/modules/Test.PortMap.psm1"
    if (Test-Path $portMapMod) {
        Import-Module $portMapMod -Force
        # Port 80's forwarder was started as root (via `sudo -E pwsh`); killing
        # it requires sudo. Detect root-owned forwarder pidfiles and pre-cache
        # credentials once so Stop-CachingProxyForwarder's `sudo kill` succeeds.
        $stateDir = Join-Path $HOME "virtual/squid-cache"
        $hasRootForwarder = $false
        $meIsRoot = $false
        try { $meIsRoot = ((& '/usr/bin/id' -u) -eq '0') } catch {}
        if (-not $meIsRoot -and (Test-Path $stateDir)) {
            foreach ($pf in (Get-ChildItem -LiteralPath $stateDir -Filter 'forwarder.*.pid' -File -ErrorAction SilentlyContinue)) {
                $fp = (Get-Content $pf.FullName -Raw).Trim()
                if ($fp -as [int]) {
                    $owner = (& '/bin/ps' -p $fp -o 'user=' 2>$null).Trim()
                    if ($owner -eq 'root') { $hasRootForwarder = $true; break }
                }
            }
        }
        if ($hasRootForwarder) {
            Write-Output "  Root-owned forwarder detected — caching sudo credentials (you may be prompted for your password)..."
            & sudo -v
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "  sudo -v failed — port 80 forwarder may not be stopped cleanly."
            }
        }
        Write-Output "  Stopping all host-side forwarders (if any)..."
        [void](Remove-CachingProxyPortMap)
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
    Write-Output "  (delete manually if you want the next Start-CachingProxy.ps1"
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
        [void](Remove-CachingProxyPortMap)
    }

    # (Get-VMHost) loads the Hyper-V module on first use; fails cleanly if
    # Hyper-V isn't installed — same dependency Start-CachingProxy.ps1 has.
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
    Write-Output "  (delete manually if you want the next Start-CachingProxy.ps1"
    Write-Output "   to re-download a fresh cloud image)."
} else {
    Write-Error "Unsupported host. Stop-CachingProxy.ps1 runs on macOS (UTM) or Windows (Hyper-V)."
    exit 1
}

Write-Output ""
Write-Output "Done."
