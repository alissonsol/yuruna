<#PSScriptInfo
.VERSION 2026.07.03
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456743
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.link/license
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

# Canonical path bundle + CachingProxy module kind (Test.VMUtility,
# Test.CachingProxy, Test.HostContract) -- one helper call loads the inline
# Test.HostContract import this script needs.
Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
$paths      = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot
$ModulesDir = $paths.ModulesDir
Initialize-YurunaEntryPointModuleSet -For CachingProxy -ModulesDir $ModulesDir

# Auto-relaunch under sg libvirt on host.ubuntu.kvm when this shell's
# group set is stale -- Stop-CachingProxy on Linux calls virsh destroy /
# undefine on the cache VM. No-op elsewhere.
Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

# === Step 0: plan + sudo preflight ==========================================
# Stop-CachingProxy runs UNATTENDED -- no interactive prompts. It has no
# destructive ShouldProcess gates (every Remove-*/Save-* call below already
# passes -Confirm:$false), so the only thing to resolve up front is sudo:
# the host-proxy wipe edits root-owned files (/etc/environment, apt proxy
# config; on macOS, networksetup). Prime it once, with the reason, so the
# teardown doesn't stop for a password prompt halfway through.
Write-Output ""
Write-Output "== Step 0: plan -- tear down caching proxy '$VMName' =="
Write-Output "  1. wipe machine-wide host proxy config"
Write-Output "  2. remove any host-side port forwarders"
Write-Output "  3. destroy + undefine the cache VM (if registered)"
Write-Output "  4. delete the per-VM disk directory (base image is kept)"
$stopProxyReason = if ($IsMacOS) {
    "clear the macOS system HTTP/HTTPS proxy (networksetup)"
} else {
    "wipe machine-wide host proxy config (/etc/environment, apt)"
}
[void](Initialize-SudoCache -Reasons @($stopProxyReason))
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
    Import-Module (Join-Path $PSScriptRoot 'modules/Test.HostContract.psm1') -Force
    [void](Initialize-YurunaHost -RepoRoot (Split-Path -Parent $PSScriptRoot))
    [void](Remove-HostProxy -Confirm:$false)
} catch {
    # Transient networksetup error or registry permission glitch:
    # surface as a warning so the user can clean up manually, but
    # don't block the VM teardown from finishing.
    Write-Warning "Remove-HostProxy failed: $($_.Exception.Message). VM teardown will continue."
}

if ($IsMacOS) {
    # Repo root for importing Yuruna.Host.psm1 (squid forwarder helpers).
    $RepoRoot    = Split-Path -Parent $PSScriptRoot

    Write-Output ""
    Write-Output "== Stop + delete '$VMName' (macOS/UTM) =="

    # Tear down any leftover host-side forwarders from the retired
    # shared-NAT path (forwarder.<port>.pid pwsh subprocesses under
    # $HOME/yuruna/image/caching-proxy). With the cache VM bridged
    # directly to the host's LAN NIC there is no host:port forwarder
    # layer in the data path -- but an upgrade from the previous shape
    # can leave one running, and on macOS killing the root-owned :80
    # forwarder requires sudo. No-op on a fresh install.
    Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostContract.psm1') -Force
    [void](Initialize-YurunaHost -RepoRoot $RepoRoot)
    $stateDir = Join-Path $HOME "yuruna/image/caching-proxy"
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

    # Host-agnostic teardown via the Yuruna.Host contract (loaded above by
    # Initialize-YurunaHost). On UTM, Remove-VM stops the VM, deletes it
    # from UTM's registry (with a delete retry + wait-for-stopped poll the
    # raw utmctl sequence lacked), and removes the .utm bundle under
    # $HOME/yuruna/guest.nosync. The base image lives in a separate
    # download dir ($HOME/yuruna/image/caching-proxy) and is untouched.
    if ((Get-VMState -VMName $VMName) -ne 'absent') {
        Write-Output "  VM registered with UTM — stopping and deleting..."
        [void](Remove-VM -VMName $VMName -Confirm:$false)
    } else {
        Write-Output "  No VM registered with UTM."
    }

    Write-Output ""
    Write-Output "Base image kept at: $HOME/yuruna/image/caching-proxy/"
    Write-Output "  (delete manually if you want the next Start-CachingProxy.ps1"
    Write-Output "   to re-download a fresh cloud image)."
} elseif ($IsWindows) {
    Write-Output ""
    Write-Output "== Stop + delete '$VMName' (Windows/Hyper-V) =="

    # Tear down any host-side port mappings a prior cycle exposed for this
    # cache VM (Grafana on :3000 etc.). Done BEFORE deleting the VM so the
    # state file on disk and the in-kernel portproxy + firewall rules are
    # removed in sync — otherwise a stale :3000 listener would outlive the
    # VM and black-hole LAN traffic until the next Invoke-TestRunner cycle.
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostContract.psm1') -Force
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
        Remove-Item -LiteralPath $vmDir -Recurse -Force
    } else {
        Write-Output "  No VM disk directory found at $vmDir."
    }

    Write-Output ""
    Write-Output "Base image kept at: $downloadDir\host.windows.hyper-v.guest.caching-proxy.vhdx"
    Write-Output "  (delete manually if you want the next Start-CachingProxy.ps1"
    Write-Output "   to re-download a fresh cloud image)."
} elseif ($IsLinux) {
    Write-Output ""
    Write-Output "== Stop + delete '$VMName' (Linux/KVM/libvirt) =="

    $RepoRoot    = Split-Path -Parent $PSScriptRoot
    $downloadDir = Join-Path $HOME 'yuruna/image/caching-proxy'

    # Tear down any pwsh-based host port forwarders Start-CachingProxy.ps1
    # set up on the NAT 'default' fallback. On a bridged 'yuruna-external'
    # network Start-CachingProxy didn't create any forwarders, so this is
    # a no-op there. Done BEFORE deleting the VM so a stale forwarder
    # can't outlive the VM and tunnel LAN traffic into a black hole.
    Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostContract.psm1') -Force
    [void](Initialize-YurunaHost -RepoRoot $RepoRoot)
    [void](Remove-PortMap -Confirm:$false)

    # Clear the cache-IP breadcrumb that Start-CachingProxy wrote for
    # guest provisioners. The password field is preserved -- it's
    # cross-cycle and survives stop. Matches the macOS branch above.
    Import-Module (Join-Path $PSScriptRoot 'modules/Test.CachingProxy.psm1') -Global -Force -Verbose:$false
    [void](Save-CachingProxyState -IpAddress '' -Confirm:$false)

    # Host-agnostic teardown via the Yuruna.Host contract (loaded above by
    # Initialize-YurunaHost). On KVM, Remove-VM runs virsh destroy +
    # undefine --nvram (NVRAM removal is required or undefine leaves the
    # domain def in place) and deletes the per-VM artifact directory under
    # ~/yuruna/vms/<name>. The base image lives in a separate download dir
    # (~/yuruna/image/caching-proxy) and is untouched.
    if ((Get-VMState -VMName $VMName) -ne 'absent') {
        Write-Output "  VM registered with libvirt -- destroying and undefining..."
        [void](Remove-VM -VMName $VMName -Confirm:$false)
    } else {
        Write-Output "  No VM registered with libvirt."
    }

    Write-Output ""
    Write-Output "Base image kept at: $downloadDir/host.ubuntu.kvm.guest.caching-proxy.qcow2"
    Write-Output "  (delete manually if you want the next Start-CachingProxy.ps1"
    Write-Output "   to re-download a fresh cloud image)."
} else {
    Write-Error "Unsupported host. Stop-CachingProxy.ps1 runs on macOS (UTM), Windows (Hyper-V), or Linux (KVM/libvirt)."
    exit 1
}

Write-Output ""
Write-Output "Done."
