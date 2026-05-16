<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456743
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.com
.PROJECTURI https://yuruna.com
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
    Inverse of Start-CachingProxy.ps1 — stops the yuruna-caching-proxy
    VM and removes its disk/bundle + stashed password. Base image is
    KEPT so the next start doesn't re-download ~600 MB. Safe to re-run.
    Remove-PortMap tears down EVERY yuruna-managed host port forward
    (80, 3000, 3128, 3129, 9302, 8022, ...) — no port-list change is
    needed when a new forwarded port is added on the Start side.

.PARAMETER VMName   Name of the cache VM. Default: yuruna-caching-proxy.
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = "yuruna-caching-proxy"
)

$global:InformationPreference = "Continue"
$global:ProgressPreference    = "SilentlyContinue"

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Error "Invalid VMName '$VMName'. Only alphanumeric, dot, hyphen, and underscore are allowed."
    exit 1
}

# Auto-relaunch under sg libvirt on host.ubuntu.kvm when this shell's
# group set is stale -- Stop-CachingProxy on Linux calls virsh destroy /
# undefine on the cache VM. No-op elsewhere.
Import-Module (Join-Path $PSScriptRoot 'modules/Test.Host.psm1') -Force
Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

# === Step 0: plan + sudo preflight ==========================================
# Stop-CachingProxy runs UNATTENDED -- no interactive prompts. It has no
# destructive ShouldProcess gates (every Remove-*/Save-* call below already
# passes -Confirm:$false), so the only thing to resolve up front is sudo:
# the host-proxy wipe edits root-owned files (/etc/environment, apt proxy
# config; on macOS, networksetup). Prime it once, with the reason, so the
# teardown doesn't stop for a password prompt halfway through.
Write-Output ""
Write-Output "=== Step 0: plan -- tear down caching proxy '$VMName' ==="
Write-Output "  1. wipe machine-wide host proxy config"
Write-Output "  2. remove any host-side port forwarders"
Write-Output "  3. destroy + undefine the cache VM (if registered)"
Write-Output "  4. delete the per-VM disk directory (base image is kept)"
[void](Initialize-SudoCache -Reasons @("wipe machine-wide host proxy config (/etc/environment, apt)"))
Write-Output "  Proceeding unattended (no further prompts)."

# === Wipe machine-wide host proxy (if it was promoted) =====================
# Symmetric with Test-CachingProxy.ps1 -SetHostProxy. Runs UNCONDITIONALLY
# and uses Remove-HostProxy (definitive wipe) rather than the older
# Clear-HostProxy (snapshot/restore from $HOME/.yuruna/host-proxy.backup.json).
# Definitive wipe is the right model here: any HTTP_PROXY/HTTPS_PROXY env
# var or WinINet ProxyServer string left after Stop-CachingProxy is, by
# definition, pointing at a cache VM we are tearing down -- restoring
# whatever was there before just leaks a stale IP into the next cycle.
# Done first so a failure tearing down the VM doesn't leave the host
# pointing at a dead proxy for the rest of the session.
# On macOS networksetup requires root — the sudo preamble above guarantees
# we are already elevated by the time this runs.
try {
    Import-Module (Join-Path $PSScriptRoot 'modules/Test.Host.psm1') -Force
    [void](Initialize-YurunaHost -RepoRoot (Split-Path -Parent $PSScriptRoot))
    [void](Remove-HostProxy -Confirm:$false)
} catch {
    # Transient networksetup error or registry permission glitch:
    # surface as a warning so the user can clean up manually, but
    # don't block the VM teardown from finishing.
    Write-Warning "Remove-HostProxy failed: $($_.Exception.Message). VM teardown will continue."
}

if ($IsMacOS) {
    $UtmDir      = "$HOME/yuruna/guest.nosync/$VMName.utm"
    # Repo root for importing Yuruna.Host.psm1 (squid forwarder helpers).
    $RepoRoot    = Split-Path -Parent $PSScriptRoot

    Write-Output ""
    Write-Output "=== Stop + delete '$VMName' (macOS/UTM) ==="

    # Tear down any leftover host-side forwarders from the retired
    # shared-NAT path (forwarder.<port>.pid pwsh subprocesses under
    # $HOME/yuruna/image/squid-cache). With the cache VM bridged
    # directly to the host's LAN NIC there is no host:port forwarder
    # layer in the data path -- but an upgrade from the previous shape
    # can leave one running, and on macOS killing the root-owned :80
    # forwarder requires sudo. No-op on a fresh install.
    Import-Module (Join-Path $RepoRoot 'test/modules/Test.Host.psm1') -Force
    [void](Initialize-YurunaHost -RepoRoot $RepoRoot)
    $stateDir = Join-Path $HOME "yuruna/image/squid-cache"
    $hasRootForwarder = $false
    $meIsRoot = $false
    try { $meIsRoot = ((& '/usr/bin/id' -u) -eq '0') } catch { Write-Verbose "id -u check failed, assuming non-root: $_" }
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
        Write-Output "  Root-owned legacy forwarder detected -- caching sudo credentials (you may be prompted for your password)..."
        & sudo -v
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "  sudo -v failed -- legacy port 80 forwarder may not be stopped cleanly."
        }
    }
    Write-Output "  Tearing down any legacy host-side forwarders..."
    [void](Remove-PortMap -Confirm:$false)
    # Clear the cache-IP breadcrumb that Start-CachingProxy wrote for
    # guest provisioners. Leaving it behind wouldn't hurt correctness
    # (guests would just re-fetch against a stale IP and fail open) but
    # matches the tidy-up pattern of the forwarder pidfiles. The
    # password field is preserved -- it's cross-cycle and survives stop.
    Import-Module (Join-Path $PSScriptRoot 'modules/Test.CachingProxy.psm1') -Global -Force -Verbose:$false
    [void](Save-CachingProxyState -IpAddress '' -Confirm:$false)

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
    Write-Output "Base image kept at: $HOME/yuruna/image/squid-cache/"
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
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $RepoRoot 'test/modules/Test.Host.psm1') -Force
    [void](Initialize-YurunaHost -RepoRoot $RepoRoot)
    [void](Remove-PortMap -Confirm:$false)

    # (Get-VMHost) loads the Hyper-V module on first use; fails cleanly if
    # Hyper-V isn't installed -- same dependency Start-CachingProxy.ps1 has.
    $downloadDir = (Get-VMHost).VirtualHardDiskPath
    $vmDir       = Join-Path $downloadDir $VMName

    if ((Get-VMState -VMName $VMName) -ne 'absent') {
        Write-Output "  VM found (state: $(Get-VMState -VMName $VMName)) -- stopping and removing..."
        [void](Stop-VM -VMName $VMName -Force -Confirm:$false)
        [void](Remove-VM -VMName $VMName -Confirm:$false)
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
} elseif ($IsLinux) {
    Write-Output ""
    Write-Output "=== Stop + delete '$VMName' (Linux/KVM/libvirt) ==="

    $RepoRoot    = Split-Path -Parent $PSScriptRoot
    $downloadDir = Join-Path $HOME 'yuruna/image/squid-cache'
    $vmDir       = Join-Path $HOME "yuruna/vms/$VMName"

    # Tear down any pwsh-based host port forwarders Start-CachingProxy.ps1
    # set up on the NAT 'default' fallback. On a bridged 'yuruna-external'
    # network Start-CachingProxy didn't create any forwarders, so this is
    # a no-op there. Done BEFORE deleting the VM so a stale forwarder
    # can't outlive the VM and tunnel LAN traffic into a black hole.
    Import-Module (Join-Path $RepoRoot 'test/modules/Test.Host.psm1') -Force
    [void](Initialize-YurunaHost -RepoRoot $RepoRoot)
    [void](Remove-PortMap -Confirm:$false)

    # Clear the cache-IP breadcrumb that Start-CachingProxy wrote for
    # guest provisioners. The password field is preserved -- it's
    # cross-cycle and survives stop. Matches the macOS branch above.
    Import-Module (Join-Path $PSScriptRoot 'modules/Test.CachingProxy.psm1') -Global -Force -Verbose:$false
    [void](Save-CachingProxyState -IpAddress '' -Confirm:$false)

    # `virsh dominfo` exits non-zero with "Domain not found" when the
    # VM isn't defined; cheap probe, no need to parse `virsh list`.
    & virsh --connect qemu:///system dominfo $VMName 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Output "  VM registered with libvirt -- destroying and undefining..."
        # `destroy` is force-stop; we are about to delete the disk
        # anyway. `undefine --nvram` removes the domain definition AND
        # any per-domain NVRAM (UEFI EFI vars), without which undefine
        # refuses to remove the domain and leaves the def in place.
        & virsh --connect qemu:///system destroy $VMName 2>&1 | Out-Null
        & virsh --connect qemu:///system undefine --nvram $VMName 2>&1 | Out-Null
    } else {
        Write-Output "  No VM registered with libvirt."
    }

    if (Test-Path $vmDir) {
        Write-Output "  Removing VM disk directory $vmDir"
        Remove-Item -Recurse -Force $vmDir
    } else {
        Write-Output "  No VM disk directory found at $vmDir."
    }

    Write-Output ""
    Write-Output "Base image kept at: $downloadDir/host.ubuntu.kvm.guest.squid-cache.qcow2"
    Write-Output "  (delete manually if you want the next Start-CachingProxy.ps1"
    Write-Output "   to re-download a fresh cloud image)."
} else {
    Write-Error "Unsupported host. Stop-CachingProxy.ps1 runs on macOS (UTM), Windows (Hyper-V), or Linux (KVM/libvirt)."
    exit 1
}

Write-Output ""
Write-Output "Done."
