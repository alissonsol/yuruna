<#PSScriptInfo
.VERSION 2026.10.18.1
.GUID 42008bcd-66da-4584-84a4-c4454a7f8958
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
    Inverse of Start-CachingProxyServiceVM.ps1 -- stops the yuruna-caching-proxy-service
    VM and removes its disk/bundle + stashed password. Base image is
    KEPT so the next start doesn't re-download ~600 MB. Safe to re-run.
    Remove-PortMap tears down EVERY yuruna-managed host port forward
    (80, 3000, 3128, 3129, 9302, 8022, ...) -- no port-list change is
    needed when a new forwarded port is added on the Start side.

.PARAMETER VMName
    Name of the cache VM. Default: yuruna-caching-proxy-service.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [string]$VMName = "yuruna-caching-proxy-service"
)

# --- REGION: Confirm the service operation
# See https://yuruna.link/42e220c4-0008
if (-not $PSCmdlet.ShouldProcess($VMName, 'Stop and remove the service VM and withdraw its advertisement')) { return }

$global:InformationPreference = "Continue"
$global:ProgressPreference    = "SilentlyContinue"

# --- REGION: Initialize service runtime
# See https://yuruna.link/42162449-0004
# After the preference assignments above on purpose: an explicit level is the
# operator's choice and replaces this script's own default.
Import-Module (Join-Path $PSScriptRoot '../modules/Test.LogLevel.psm1') -Global -Force -DisableNameChecking
Use-LogLevelFromEnv

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Error "Invalid VMName '$VMName'. Only alphanumeric, dot, hyphen, and underscore are allowed."
    exit 1
}

# Canonical path bundle + CachingProxyService module kind (Test.VMUtility,
# Test.CachingProxyService, Test.HostContract) -- one helper call loads the inline
# Test.HostContract import this script needs.
Import-Module (Join-Path $PSScriptRoot '../modules/Test.Prelude.psm1') -Global -Force
$paths      = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder
$ModulesDir = $paths.ModulesDir
Initialize-YurunaEntryPointModuleSet -For CachingProxyService -ModulesDir $ModulesDir

# Auto-relaunch under sg libvirt on host.ubuntu.kvm when this shell's
# group set is stale -- Stop-CachingProxyServiceVM on Linux calls virsh destroy /
# undefine on the cache VM. No-op elsewhere.
Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

# --- REGION: Record the stop intent
# See https://yuruna.link/42e220c4-0008
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -Global -DisableNameChecking
Import-Module (Join-Path $ModulesDir 'Test.ServiceCensus.psm1') -Global -Force -DisableNameChecking
$serviceOp = Enter-YurunaServiceOperation -Key 'caching-proxy' -VMName $VMName -Operation Stop -Script 'Stop-CachingProxyServiceVM.ps1' -Confirm:$false
if (-not $serviceOp.Proceed) {
    Write-Error $serviceOp.Message
    exit 1
}
# Every exit below runs the finally at the end of this file, which records the
# result and releases the operation lock even inside a long-lived shell.
$serviceOpResult = 'failed'
$serviceOpFinalState = 'unknown'
try {

# --- REGION: Preflight
# Prime sudo once after the operation gate; teardown then runs unattended.
# See https://yuruna.link/42e220c4-0008
Write-Output ""
Write-Output "== Step 0: plan -- tear down caching-proxy service '$VMName' =="
Write-Output "  1. clear any abandoned caching-proxy-service bring-up lock"
Write-Output "  2. wipe machine-wide host proxy config"
Write-Output "  3. remove any host-side port forwarders"
Write-Output "  4. destroy + undefine the cache VM (if registered)"
Write-Output "  5. delete the per-VM disk directory (base image is kept)"
$stopProxyReason = if ($IsMacOS) {
    "clear the macOS system HTTP/HTTPS proxy (networksetup)"
} else {
    "wipe machine-wide host proxy config (/etc/environment, apt)"
}
[void](Initialize-SudoCache -Reasons @($stopProxyReason))
Write-Output "  Proceeding unattended (no further prompts)."

# --- REGION: Clear an abandoned caching-proxy-service bring-up lock
# See https://yuruna.link/42e5cdfd-004a
$cpLockRuntimeDir = if ($env:YURUNA_RUNTIME_DIR) { $env:YURUNA_RUNTIME_DIR } else { Join-Path $PSScriptRoot '../status/runtime' }
if (Get-Command Clear-CachingProxyServiceLock -ErrorAction SilentlyContinue) {
    $cpLockClear = Clear-CachingProxyServiceLock -RuntimeDir $cpLockRuntimeDir
    switch ($cpLockClear.Reason) {
        'no-lock' {
            Write-Output "  No caching-proxy-service bring-up lock to clear."
        }
        'live-foreign' {
            Write-Warning "  A caching-proxy-service bring-up is LIVE in PID $($cpLockClear.HolderPid) -- leaving its lock in place (this teardown is racing that rebuild). Stop that process first if it is not wanted."
        }
        default {
            Write-Output "  Cleared a leftover caching-proxy-service bring-up lock ($($cpLockClear.Reason); recorded PID $($cpLockClear.HolderPid))."
        }
    }
}

# --- REGION: Clear the host proxy
# See https://yuruna.link/42e5cdfd-004b
try {
    Import-Module (Join-Path $PSScriptRoot '../modules/Test.HostContract.psm1') -Force
    [void](Initialize-YurunaHost -RepoRoot (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
    [void](Remove-HostProxy -Confirm:$false)
} catch {
    # Transient networksetup error or registry permission glitch:
    # surface as a warning so the user can clean up manually, but
    # don't block the VM teardown from finishing.
    Write-Warning "Remove-HostProxy failed: $($_.Exception.Message). VM teardown will continue."
}

# --- REGION: Clear the cached service address
# Preserve the persistent password while withdrawing the VM's address.
# See https://yuruna.link/42e220c4-0008
Import-Module (Join-Path $PSScriptRoot '../modules/Test.CachingProxyService.psm1') -Global -Force -Verbose:$false
[void](Save-CachingProxyServiceState -IpAddress '' -Confirm:$false)

if ($IsMacOS) {
    # --- REGION: macOS -- tear down forwarders, then stop and delete the VM
    # Repo root for importing Yuruna.Host.psm1 (squid forwarder helpers).
    $RepoRoot    = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    Write-Output ""
    Write-Output "== Stop + delete '$VMName' (macOS/UTM) =="

    # See https://yuruna.link/42e220c4-0008
    Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostContract.psm1') -Force
    [void](Initialize-YurunaHost -RepoRoot $RepoRoot)
    $stateDir = Join-Path $HOME "yuruna/image/caching-proxy-service"
    $hasRootForwarder = $false
    $meIsRoot = $false
    try { $meIsRoot = ((& '/usr/bin/id' -u) -eq '0') } catch { Write-Verbose "id -u check failed, assuming non-root: $_" }
    if (-not $meIsRoot -and (Test-Path $stateDir)) {
        foreach ($pf in (Get-ChildItem -LiteralPath $stateDir -Filter 'forwarder.*.pid' -File -ErrorAction SilentlyContinue)) {
            $fp = (Get-Content $pf.FullName -Raw).Trim()
            if ($fp -as [int]) {
                $owner = ([string](& '/bin/ps' -p $fp -o 'user=' 2>$null)).Trim()
                if ($owner -eq 'root') { $hasRootForwarder = $true; break }
            }
        }
    }
    if ($hasRootForwarder) {
        # A bare `sudo -v` takes the password from /dev/tty, which a closed stdin
        # and -NonInteractive both leave untouched -- so under a captured child it
        # parks the run on a prompt whose text went to a log nobody is watching.
        # Probing instead turns a cold timestamp into an answer the operator can
        # act on, at the cost of leaving one forwarder for them to stop by hand.
        if ($env:YURUNA_NONINTERACTIVE -eq '1') {
            & sudo -n -v 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning ("  Root-owned legacy forwarder detected and this run is non-interactive, so it cannot be stopped: " +
                               "sudo has no live authorization. Run 'sudo -v' and re-run, or stop it by hand. Continuing without it.")
            }
        } else {
            Write-Output "  Root-owned legacy forwarder detected -- caching sudo credentials (you may be prompted for your password)..."
            & sudo -v
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "  sudo -v failed -- legacy port 80 forwarder may not be stopped cleanly."
            }
        }
    }
    Write-Output "  Tearing down any legacy host-side forwarders..."
    [void](Remove-PortMap -Confirm:$false)

    # The host contract removes registration and private VM files; keep the base image.
    # See https://yuruna.link/42e220c4-0004
    if ((Get-VMState -VMName $VMName) -ne 'absent') {
        Write-Output "  VM registered with UTM -- stopping and deleting..."
        [void](Remove-VM -VMName $VMName -Confirm:$false)
    } else {
        Write-Output "  No VM registered with UTM."
    }

    # Shared across every extension service on this host, so deleting it makes
    # the next stash / pool-control build re-download too.
    Import-Module (Join-Path $RepoRoot 'host/modules/Yuruna.Image.psm1') -Force
    Write-Output ""
    Write-Output "Base image kept at: $((Get-UbuntuExtensionImageInfo -HostType 'macos.utm').BaseImageFile)"
    Write-Output "  (delete manually if you want the next Start-CachingProxyServiceVM.ps1"
    Write-Output "   to re-download a fresh cloud image)."
} elseif ($IsWindows) {
    # --- REGION: Windows -- tear down port maps, then stop and delete the VM
    Write-Output ""
    Write-Output "== Stop + delete '$VMName' (Windows/Hyper-V) =="

    # Tear down any host-side port mappings a prior cycle exposed for this
    # cache VM (Grafana on :3000 etc.). Done BEFORE deleting the VM so the
    # state file on disk and the in-kernel portproxy + firewall rules are
    # removed in sync -- otherwise a stale :3000 listener would outlive the
    # VM and black-hole LAN traffic until the next Start-TestRunner cycle.
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostContract.psm1') -Force
    [void](Initialize-YurunaHost -RepoRoot $RepoRoot)
    [void](Remove-PortMap -Confirm:$false)

    # (Get-VMHost) loads the Hyper-V module on first use; fails cleanly if
    # Hyper-V isn't installed -- same dependency Start-CachingProxyServiceVM.ps1 has.
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

    # Shared across every extension service on this host, so deleting it makes
    # the next stash / pool-control build re-download too.
    Import-Module (Join-Path $RepoRoot 'host/modules/Yuruna.Image.psm1') -Force
    Write-Output ""
    Write-Output "Base image kept at: $((Get-UbuntuExtensionImageInfo -HostType 'windows.hyper-v').BaseImageFile)"
    Write-Output "  (delete manually if you want the next Start-CachingProxyServiceVM.ps1"
    Write-Output "   to re-download a fresh cloud image)."
} elseif ($IsLinux) {
    # --- REGION: Linux -- tear down forwarders, then destroy and undefine the VM
    Write-Output ""
    Write-Output "== Stop + delete '$VMName' (Linux/KVM/libvirt) =="

    $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    # Tear down any pwsh-based host port forwarders Start-CachingProxyServiceVM.ps1
    # set up on the NAT 'default' fallback. On a bridged 'yuruna-external'
    # network Start-CachingProxyServiceVM didn't create any forwarders, so this is
    # a no-op there. Done BEFORE deleting the VM so a stale forwarder
    # can't outlive the VM and tunnel LAN traffic into a black hole.
    Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostContract.psm1') -Force
    [void](Initialize-YurunaHost -RepoRoot $RepoRoot)
    [void](Remove-PortMap -Confirm:$false)

    # The host contract removes registration and private VM files; keep the base image.
    # See https://yuruna.link/42e220c4-0004
    if ((Get-VMState -VMName $VMName) -ne 'absent') {
        Write-Output "  VM registered with libvirt -- destroying and undefining..."
        [void](Remove-VM -VMName $VMName -Confirm:$false)
    } else {
        Write-Output "  No VM registered with libvirt."
    }

    # Shared across every extension service on this host, so deleting it makes
    # the next stash / pool-control build re-download too.
    Import-Module (Join-Path $RepoRoot 'host/modules/Yuruna.Image.psm1') -Force
    Write-Output ""
    Write-Output "Base image kept at: $((Get-UbuntuExtensionImageInfo -HostType 'ubuntu.kvm').BaseImageFile)"
    Write-Output "  (delete manually if you want the next Start-CachingProxyServiceVM.ps1"
    Write-Output "   to re-download a fresh cloud image)."
} else {
    Write-Error "Unsupported host. Stop-CachingProxyServiceVM.ps1 runs on macOS (UTM), Windows (Hyper-V), or Linux (KVM/libvirt)."
    exit 1
}

# --- REGION: Verify the final VM state
# Confirmed only by a final reading of absent: a removal that left the VM
# registered is a failed stop, and the stop request still stands. Every branch
# above loaded the host contract, so Get-VMState is in scope here.
$serviceOpFinalState = 'unknown'
try { $serviceOpFinalState = [string](Get-VMState -VMName $VMName) } catch { Write-Verbose "final state of '$VMName': $($_.Exception.Message)" }
Write-Output ""
if ($serviceOpFinalState -eq 'absent') {
    $serviceOpResult = 'confirmed'
    Write-Output "Done."
    # Explicit, not a fall-through: the teardown branches call native commands
    # (sudo -n -v, id, ps) that legitimately exit non-zero on a healthy run, and
    # without this the script would report the last one's code as its own.
    exit 0
}
Write-Warning (Format-YurunaOperatorMessage -Key 'runner.service_stop_final_state_unexpected' -Arguments @{
        vmName = $VMName; finalState = $serviceOpFinalState })
exit 1
} finally {
    [void](Exit-YurunaServiceOperation -Context $serviceOp -Result $serviceOpResult -FinalState $serviceOpFinalState -Confirm:$false)
}
