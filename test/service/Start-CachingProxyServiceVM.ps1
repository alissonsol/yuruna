<#PSScriptInfo
.VERSION 2026.10.14
.GUID 42647c3a-19a7-4931-b638-07791d5f0b1b
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
    Brings up the yuruna-caching-proxy-service VM and exposes its ports
    (80, 3128, 3129, 3000, 9302) on the host. See the operator reference in docs/caching.md
    for remote-client setup, elevation requirements (Windows admin;
    macOS `sudo -E` to bind :80), and the external-cache sources
    (vmStart.cachingProxyIp probed first, YURUNA_CACHING_PROXY_SERVICE_IP as
    fallback) that make this a no-op.

.PARAMETER VMName
    Name for the cache VM. Default: yuruna-caching-proxy-service.

.PARAMETER MacAddress
    Optional stable MAC address for the cache VM's NIC, accepted as
    AA:BB:CC:DD:EE:FF, AA-BB-CC-DD-EE-FF, or AABBCCDDEEFF. Without it,
    every rebuild gets a fresh random MAC, so the DHCP server leases a
    new IP each time. With it, the operator can create a one-time DHCP
    reservation on the LAN router (or libvirt/UTM NAT DHCP) and the
    cache VM's IP is known and stable across rebuilds. Use a
    locally-administered unicast address (first octet 02/06/0A/0E),
    distinct per host -- two hosts on one LAN must not share a MAC.
.PARAMETER AllowPseudoLocale
    Enable developer pseudo locales for the rebuilt service VM. Disabled by default.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [string]$VMName = "yuruna-caching-proxy-service",
    [Parameter()]
    [string]$MacAddress,
    # Force a full destroy+rebuild even when a healthy proxy already exists.
    # Default (adopt-if-healthy) skips the ~15-min rebuild when the current VM
    # is running and its squid / ssl-bump / CA probe passes. Pass this after a
    # base-image or config change to guarantee a fresh build.
    [switch]$ForceRebuild,
    # See https://yuruna.link/42e220c4-0008
    [switch]$Lab,
    [switch]$AllowPseudoLocale
)

# --- REGION: Confirm the service operation
# See https://yuruna.link/42e220c4-0008
if (-not $PSCmdlet.ShouldProcess($VMName, 'Start or rebuild the service VM and configure host services')) { return }

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

# --- REGION: Elevation check
# See https://yuruna.link/42e220c4-0008
if ($IsWindows -and -not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Verbose ""
    Write-Output "This script requires elevation (Run as Administrator)."
    Write-Output "Start-CachingProxyServiceVM needs an elevated session to:"
    Write-Verbose "  * query Hyper-V for the VHD folder (Get-VMHost)"
    Write-Verbose "  * create and remove the '$VMName' VM and its disk"
    Write-Verbose "  * set the host proxy (WinINet) and netsh portproxy rules"
    Write-Output "Re-launch PowerShell as Administrator and run this script again."
    Write-Error "Start-CachingProxyServiceVM requires Administrator on Windows. Nothing was changed."
    exit 1
}

# --- REGION: Clear the inherited proxy environment
# Pre-flight: drop inherited proxy env vars from THIS process and its
# children so .NET HttpClient downloads go DIRECT (a stale upstream IP
# would fail every Get-Image / virt-install / qemu-img call before the
# cache exists). Rationale and scope: https://yuruna.link/42f6b05f-003c
$proxyEnvVars = @(
    'HTTP_PROXY',  'http_proxy',
    'HTTPS_PROXY', 'https_proxy',
    'NO_PROXY',    'no_proxy',
    'ALL_PROXY',   'all_proxy',
    'YURUNA_CACHING_PROXY_SERVICE_IP'
)
# See https://yuruna.link/42e220c4-0008
$envSidecarDir = if ($env:YURUNA_RUNTIME_DIR) { $env:YURUNA_RUNTIME_DIR } else { Join-Path $PSScriptRoot '../status/runtime' }
$envSidecarPath = Join-Path $envSidecarDir '.caching-proxy-service.env.json'
$clearedProxy = @()
Import-Module (Join-Path $PSScriptRoot '../modules/Test.StateFile.psm1') -Global -DisableNameChecking
$sidecarPayload = [ordered]@{}
foreach ($pv in $proxyEnvVars) {
    $envProvPath = "Env:$pv"
    if (Test-Path -LiteralPath $envProvPath) {
        $val = (Get-Item -LiteralPath $envProvPath).Value
        $clearedProxy += "$pv=$val"
        $sidecarPayload[$pv] = [string]$val
        Remove-Item -LiteralPath $envProvPath -ErrorAction SilentlyContinue
    }
}
if ($clearedProxy.Count -gt 0) {
    Write-Verbose "Pre-flight: cleared inherited proxy env vars from this process so cache bring-up reaches the public Internet directly (caller's shell untouched):"
    foreach ($entry in $clearedProxy) {
        Write-Verbose "  $entry"
    }
    try {
        if (-not (Test-Path -LiteralPath $envSidecarDir)) {
            New-Item -Path $envSidecarDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        # Atomic write via the shared state-file helper so a crash
        # mid-write can't leave a truncated JSON sidecar for a later
        # cache-proxy bring-up to mis-parse.
        $ok = Write-YurunaStateFileJson -Path $envSidecarPath -InputObject $sidecarPayload -Confirm:$false
        if ($ok) {
            Write-Verbose "  (persisted to $envSidecarPath for restore on re-invocation)"
        } else {
            Write-Verbose "Could not persist .caching-proxy-service.env.json (see Verbose stream)."
        }
    } catch {
        Write-Verbose "Could not persist .caching-proxy-service.env.json: $($_.Exception.Message)"
    }
}

# --- REGION: Initialize host access
# Canonical path bundle + CachingProxyService module kind (Test.VMUtility,
# Test.CachingProxyService, Test.HostContract -- the union every caching-proxy-service
# entry-point script needs).
Import-Module (Join-Path $PSScriptRoot '../modules/Test.Prelude.psm1') -Global -Force
$paths      = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder
$RepoRoot   = $paths.RepoRoot
$ModulesDir = $paths.ModulesDir
Initialize-YurunaEntryPointModuleSet -For CachingProxyService -ModulesDir $ModulesDir

# Normalize + validate the optional stable MAC NOW, before any teardown or
# download work, so a typo'd value stops the run while nothing has changed.
# The canonical colon form is what every platform New-VM.ps1 accepts; each
# reformats to its hypervisor's native notation.
if ($MacAddress) {
    Import-Module (Join-Path $RepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    $MacAddress = ConvertTo-YurunaMacAddress -MacAddress $MacAddress
    if (-not $MacAddress) {
        Write-Error "Invalid -MacAddress (see warning above). Nothing was changed."
        exit 1
    }
    Write-Verbose "Cache VM NIC will use stable MAC $MacAddress (set a DHCP reservation for it to pin the cache IP)."
}

# Auto-relaunch under sg libvirt on host.ubuntu.kvm when this shell's
# group set is stale -- Start-CachingProxyServiceVM on Linux provisions the cache
# VM via virt-install and queries its IP via virsh, both of which need
# libvirt-socket access. No-op on macOS / Windows / fresh shells.
Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

# See https://yuruna.link/42e220c4-0008
if ($IsMacOS -or $IsLinux) {
    Write-Verbose ""
    Write-Verbose "Note: bringing up the cache proxy uses sudo -- you may be prompted for your password."
    Write-Verbose "  Elevation is needed to:"
    if ($IsMacOS) {
        Write-Verbose "    * clear the macOS system HTTP/HTTPS proxy (networksetup)"
    } else {
        Write-Verbose "    * wipe machine-wide host proxy config (/etc/environment, apt)"
        Write-Verbose "    * if needed, build/heal the 'yuruna-external' libvirt bridge"
        Write-Verbose "      (nmcli or netplan, plus cleanup of any half-built leftovers)"
    }
    Write-Verbose "    * if needed, stop whatever still holds the status-service port"
    Write-Verbose "      (a root-owned server from an earlier run keeps this one from binding)"
}

if ($IsMacOS) {
    $HostType = 'macos.utm'
    $UtmDir   = "$HOME/yuruna/guest.nosync/$VMName.utm"
} elseif ($IsWindows) {
    $HostType = 'windows.hyper-v'
} elseif ($IsLinux) {
    $HostType = 'ubuntu.kvm'
} else {
    Write-Error "Unsupported host. Start-CachingProxyServiceVM.ps1 runs on macOS (UTM), Windows (Hyper-V), or Linux (KVM/libvirt)."
    exit 1
}

# --- REGION: Resolve the VM builder
# See https://yuruna.link/42e220c4-0008
# See https://yuruna.link/42f52e37-0020
# Resolved ahead of Preflight and the start intent: a missing builder script
# stops the run before anything is recorded or changed.
$HostDir = Join-Path $RepoRoot "host/$HostType/guest.caching-proxy-service"

Import-Module (Join-Path $RepoRoot 'host/modules/Yuruna.Image.psm1') -Force
try {
    $ImageFile = (Get-UbuntuExtensionImageInfo -HostType $HostType).BaseImageFile
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

$PasswordFile = Get-CachingProxyServiceStatePath

$GetImageScript = Join-Path $HostDir 'Get-Image.ps1'
$NewVMScript    = Join-Path $HostDir 'New-VM.ps1'

foreach ($p in @($GetImageScript, $NewVMScript)) {
    if (-not (Test-Path $p)) { Write-Error "Missing required script: $p"; exit 1 }
}

# --- REGION: Preflight
# See https://yuruna.link/42e5cdfd-0031
Write-Verbose ""
Write-Verbose "== Step 0: plan + preflight =="

$preflightErrors = @()
$plannedBridge   = $null   # set on Linux to the Get-YurunaExternalNetworkPlan result

if ($IsLinux) {
    # --- REGION: Hard requirements -- without these the cache VM cannot boot
    if (-not (Test-Path -LiteralPath '/dev/kvm')) {
        $preflightErrors += "/dev/kvm is missing -- KVM acceleration unavailable (kvm.ko not loaded, or VT-x/AMD-V disabled in firmware). The cache VM cannot boot."
    }
    $libvirtdActive = ((& systemctl is-active libvirtd 2>$null) | Out-String).Trim()
    if ($libvirtdActive -ne 'active') {
        $preflightErrors += "libvirtd is not active (state: '$libvirtdActive'). Start it with: sudo systemctl enable --now libvirtd"
    }

    # --- REGION: Bridge plan -- does the bridge step perturb host networking?
    # Decided NOW and told to the operator before anything is touched.
    Import-Module (Join-Path $RepoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1') -Force -DisableNameChecking
    if ($env:YURUNA_EXTERNAL_BRIDGE_SKIP -eq '1') {
        Write-Verbose "  Network plan: bridge step SKIPPED (YURUNA_EXTERNAL_BRIDGE_SKIP=1)."
        Write-Verbose "    Cache VM will use libvirt NAT 'default' (reachable from this host only)."
    } else {
        $plannedBridge = Get-YurunaExternalNetworkPlan
        Write-Verbose "  Network plan: $($plannedBridge.Action)"
        foreach ($line in ($plannedBridge.Explanation -split "`r?`n")) {
            Write-Verbose "    $line"
        }
        if ($plannedBridge.WillChangeHostNetworking) {
            Write-Verbose ""
            Write-Verbose "  >> This run WILL briefly interrupt host networking (detail above).  <<"
            Write-Verbose "  >> Proceeding automatically and unattended. To keep the cache VM   <<"
            Write-Verbose "  >> on host-only NAT and avoid the change, re-run with              <<"
            Write-Verbose "  >>   YURUNA_EXTERNAL_BRIDGE_SKIP=1 test/service/Start-CachingProxyServiceVM.ps1        <<"
        }
    }
}

if ($preflightErrors.Count -gt 0) {
    Write-Verbose ""
    Write-Verbose "  Preflight FAILED -- the run cannot succeed. Nothing was created:"
    foreach ($e in $preflightErrors) { Write-Output "    - $e" }
    Write-Error "Start-CachingProxyServiceVM preflight failed ($($preflightErrors.Count) blocking issue(s)). Resolve the above and re-run."
    exit 1
}

# See https://yuruna.link/42e5cdfd-0032
$proxyWipeReason = if ($IsMacOS) {
    "clear the macOS system HTTP/HTTPS proxy (networksetup)"
} else {
    "wipe machine-wide host proxy config (/etc/environment, apt)"
}
$sudoReasons = @($proxyWipeReason)
# Step 2.5 starts the status service, and the port it needs can still be held by
# a root-owned server from an earlier run -- which only root can stop. Priming
# for it HERE keeps the promise the preflight prints ("proceeding unattended, no
# further prompts"): without it, the takeover would have to raise a second
# password prompt in the middle of the bring-up, or give up and refuse.
$sudoReasons += 'stop a leftover root-owned holder of the status-service port, if one is still there'
if ($IsLinux -and $plannedBridge -and $plannedBridge.WillChangeHostNetworking) {
    # The reuse-network plan branch flags a heal/rebuild without always
    # resolving the NIC -- don't render an empty '' into the prompt.
    $sudoReasons += if ($plannedBridge.Nic) {
        "build Linux bridge '$($plannedBridge.BridgeName)' on NIC '$($plannedBridge.Nic)' via nmcli/netplan (sweeping half-built leftovers first)"
    } else {
        "heal or rebuild Linux bridge '$($plannedBridge.BridgeName)' for the existing 'yuruna-external' network"
    }
}
[void](Initialize-SudoCache -Reasons $sudoReasons)

Write-Verbose "  Preflight OK -- proceeding unattended (no further prompts)."

# --- REGION: Record the start intent
# See https://yuruna.link/42e220c4-0008
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.Globalization.psm1') -Global -DisableNameChecking
Import-Module (Join-Path $ModulesDir 'Test.ServiceCensus.psm1') -Global -Force -DisableNameChecking
$serviceOp = Enter-YurunaServiceOperation -Key 'caching-proxy' -VMName $VMName -Operation Start -Script 'Start-CachingProxyServiceVM.ps1' -Confirm:$false
if (-not $serviceOp.Proceed) {
    Write-Error $serviceOp.Message
    exit 1
}
# Every exit below runs the outer finally at the end of this file, which
# records the result and releases the operation lock even inside a long-lived
# shell.
$serviceOpResult = 'failed'
try {

# --- REGION: Acquire the service lifecycle lock
# Hold one lock across VM replacement and host port-map changes.
# See https://yuruna.link/42e220c4-0008
$cpLock = Enter-CachingProxyServiceLock -RuntimeDir $envSidecarDir -Role 'rebuild' -TimeoutSeconds 30
if (-not $cpLock.Acquired) {
    Write-Error "Another caching-proxy-service bring-up holds the lock (PID $($cpLock.HolderPid)). Refusing a second concurrent destroy/rebuild -- wait for it to finish (or stop that process), then re-run. Run Stop-CachingProxyServiceVM.ps1 to clear an abandoned lock."
    exit 1
}

# Release on every exit: this script can share the caller's long-lived PID.
# See https://yuruna.link/42e220c4-0008
try {

# --- REGION: Adopt a healthy VM
# Load the host contract so Get-VMState / Test-CacheVMOnExternalNetwork /
# Add-PortMap resolve for the probe + exposure re-assert. The Test.CachingProxyService
# re-import afterward is mandatory, not redundant:
# docs/workarounds.md#nested-non-global-import-evicts-a-callers-view-of-a-module
if (-not $ForceRebuild) {
    Import-Module (Join-Path $PSScriptRoot '../modules/Test.HostContract.psm1') -Force
    [void](Initialize-YurunaHost -RepoRoot (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
    Import-Module (Join-Path $PSScriptRoot '../modules/Test.CachingProxyService.psm1') -Global -Force -Verbose:$false
    $cpAdopt = Test-CachingProxyServiceAdoptable -VMName $VMName
    if ($cpAdopt.Adoptable) {
        Write-Verbose ""
        Write-Verbose "== Adopting the healthy '$VMName' at $($cpAdopt.Ip) (pass -ForceRebuild to rebuild from scratch) =="
        Write-Verbose "  squid + ssl-bump + CA cert verified healthy -- skipping destroy/rebuild + ~15-min discovery;"
        Write-Verbose "  re-asserting host-side services + port maps only."
        # Host services the running VM depends on -- best-effort (no hard-fail):
        # we are NOT minting a new client cert here, so a down config service just
        # means the VM keeps its current baked creds until it is back up.
        Import-Module (Join-Path $ModulesDir 'Test.Config.psm1') -Global -Force
        $cpAdoptConfig = Read-TestConfig -Path (Join-Path $PSScriptRoot '../test.config.yml')
        [void](Start-YurunaStatusServiceIfEnabled -Config $cpAdoptConfig -StartScript (Join-Path $PSScriptRoot 'Start-StatusService.ps1'))
        [void](Start-YurunaConfigServiceIfEnabled -Config $cpAdoptConfig -StartScript (Join-Path $PSScriptRoot 'Start-ConfigService.ps1'))
        # Re-assert LAN exposure (idempotent, clear-all-first): LAN-direct
        # (bridged/external) needs no forwarder; a NAT'd cache gets host port maps.
        # Best-effort -- the per-cycle runner re-applies port maps regardless.
        try {
            if (Test-CacheVMOnExternalNetwork -VMName $VMName) {
                Write-Verbose "  Cache VM is LAN-direct (bridged/external) -- no host port-forwarders needed."
                [void](Remove-PortMap -Confirm:$false)
            } else {
                $adoptHttpPort  = Get-CachingProxyServicePort -Scheme http
                $adoptHttpsPort = Get-CachingProxyServicePort -Scheme https
                [void](Add-PortMap -VMIp $cpAdopt.Ip `
                        -Port (Get-CachingProxyServiceExposedPort -HttpPort $adoptHttpPort -HttpsPort $adoptHttpsPort) `
                        -PortRemap @{8022 = 22} -Confirm:$false)
                Write-Verbose "  Re-applied host port-forwarders to the cache at $($cpAdopt.Ip)."
            }
        } catch {
            Write-Warning "  Port-map refresh on adopt failed: $($_.Exception.Message). The per-cycle runner re-applies port maps, so this is non-fatal."
        }
        # Refresh the recorded IP (unchanged, but keeps the state file current).
        Import-Module (Join-Path $PSScriptRoot '../modules/Test.CachingProxyService.psm1') -Global -Force -Verbose:$false
        [void](Save-CachingProxyServiceState -IpAddress $cpAdopt.Ip -Confirm:$false)
        Write-Verbose ""
        Write-Verbose "========"
        Write-Output "== caching-proxy-service ADOPTED (already healthy -- no rebuild) =="
        Write-Verbose "========"
        Write-Verbose "  VM name:  $VMName"
        Write-Verbose "  VM IP:    $($cpAdopt.Ip)"
        Write-Verbose "  Detail:   verified healthy; skipped the ~15-min destroy/rebuild/discovery."
        Write-Verbose "            Pass -ForceRebuild to force a fresh build (e.g. after an image/config change)."
        Write-Verbose "========"
        [void](Exit-CachingProxyServiceLock -Handle $cpLock)
        $serviceOpResult = 'confirmed'
        exit 0
    }
    Write-Verbose ""
    Write-Verbose "== No healthy '$VMName' to adopt ($($cpAdopt.Reason)) -- performing a full rebuild. =="
} else {
    Write-Verbose ""
    Write-Verbose "== -ForceRebuild specified -- rebuilding '$VMName' from scratch (adopt fast-path skipped). =="
}

# A stop published while this start was preparing wins: nothing is torn down
# or built for a request that no longer stands (the outer finally reports the
# newer one).
if (-not (Test-YurunaServiceOperationCurrent -Context $serviceOp)) { exit 1 }

# --- REGION: Remove existing VM
Write-Verbose ""
Write-Verbose "== Step 1: cleanup previous '$VMName' VM =="

# See https://yuruna.link/42e5cdfd-0033
try {
    Import-Module (Join-Path $PSScriptRoot '../modules/Test.HostContract.psm1') -Force
    [void](Initialize-YurunaHost -RepoRoot (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
    [void](Remove-HostProxy -Confirm:$false)
} catch {
    Write-Warning "  Remove-HostProxy failed: $($_.Exception.Message). Cleanup will continue."
}
if ($IsMacOS) {
    # See https://yuruna.link/42e5cdfd-0033
    try {
        Import-Module (Join-Path $PSScriptRoot '../modules/Test.HostContract.psm1') -Force
        [void](Initialize-YurunaHost -RepoRoot (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
        [void](Remove-PortMap -Confirm:$false)
    } catch {
        Write-Warning "  Remove-PortMap (legacy forwarder cleanup) failed: $($_.Exception.Message). Cleanup will continue."
    }
    # Kill any UTM dialog watchdog left over from a prior run that exited
    # before its Step 4 Stop, so it isn't still auto-clicking UTM dialogs.
    # Yuruna.Host (loaded by Initialize-YurunaHost above) exports it.
    if (Get-Command Stop-UtmDialogWatchdog -ErrorAction SilentlyContinue) { Stop-UtmDialogWatchdog }
    # The host contract removes registration and private VM files; keep the base image.
    # See https://yuruna.link/42e220c4-0004
    if ((Get-VMState -VMName $VMName) -ne 'absent') {
        Write-Verbose "  Prior VM registered with UTM -- stopping and deleting..."
        [void](Remove-VM -VMName $VMName -Confirm:$false)
    } else {
        Write-Verbose "  No prior VM registered with UTM."
    }
} elseif ($IsWindows) {
    # The host contract removes registration and private VM files; keep the base image.
    # See https://yuruna.link/42e220c4-0004
    if ((Get-VMState -VMName $VMName) -ne 'absent') {
        Write-Verbose "  Prior VM found (state: $(Get-VMState -VMName $VMName)) -- stopping and removing..."
        [void](Stop-VM -VMName $VMName -Force -Confirm:$false)
        [void](Remove-VM -VMName $VMName -Confirm:$false)
    } else {
        Write-Verbose "  No prior VM registered with Hyper-V."
    }
} elseif ($IsLinux) {
    # The host contract removes registration and private VM files; keep the base image.
    # See https://yuruna.link/42e220c4-0004
    if ((Get-VMState -VMName $VMName) -ne 'absent') {
        Write-Verbose "  Prior VM registered with libvirt -- destroying and undefining..."
        [void](Remove-VM -VMName $VMName -Confirm:$false)
    } else {
        Write-Verbose "  No prior VM registered with libvirt."
    }

    # --- REGION: Configure the external bridge
    # Promote the cache VM off libvirt's NAT 'default' network onto the
    # bridged 'yuruna-external' network so other LAN hosts can reach it.
    # Unattended; YURUNA_EXTERNAL_BRIDGE_SKIP=1 short-circuits it.
    # See the operator reference in docs/caching.md (yuruna-external bridge bring-up).
    Import-Module (Join-Path $RepoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1') -Force -DisableNameChecking
    if ($env:YURUNA_EXTERNAL_BRIDGE_SKIP -eq '1') {
        Write-Verbose ""
        Write-Verbose "== Step 1.5: bridge auto-creation skipped (YURUNA_EXTERNAL_BRIDGE_SKIP=1) =="
        Write-Verbose "  Cache VM will land on libvirt's NAT 'default' network (host-only)."
    } elseif ($plannedBridge -and -not $plannedBridge.CanBridge) {
        # See https://yuruna.link/42e220c4-0008
        Write-Verbose ""
        Write-Verbose "== Step 1.5: bridge step skipped (per Step 0 plan: $($plannedBridge.Action)) =="
        Write-Verbose "  Cache VM will use libvirt's NAT 'default' network (host-only). Reason"
        Write-Verbose "  and remediation were printed in the Step 0 plan above."
    } else {
        Write-Verbose ""
        Write-Verbose "== Step 1.5: ensure 'yuruna-external' libvirt bridge network =="
        $extNet = New-YurunaExternalNetwork -Confirm:$false
        if ($extNet) {
            Write-Verbose "  libvirt network ready: $extNet (cache VM will get a LAN-routable IP)"
            # New-VM.ps1's Get-ExternalNetwork preferentially honors this
            # env var when picking which libvirt network to use; setting
            # it here removes ambiguity in case the operator has another
            # bridge defined that also passes the 'yuruna-external'
            # detection ordering.
            $env:YURUNA_EXTERNAL_NETWORK = $extNet
        } else {
            Write-Warning "  Could not provision 'yuruna-external'. Cache VM will fall back to NAT 'default' (host-only)."
            Write-Warning "  To use the cache from other LAN hosts you'll need to: define yuruna-external manually (see host/ubuntu.kvm/guest.caching-proxy-service/README.md), or set YURUNA_EXTERNAL_BRIDGE_SKIP=1 to suppress this attempt next time."
        }
    }
}

# --- REGION: Acquire the base image
# Get-Image owns sentinel validation, including URL and version changes.
# See https://yuruna.link/42e220c4-0003
Write-Verbose ""
Write-Verbose "== Step 2: base image (Get-Image.ps1 decides cache vs refetch) =="
$global:LASTEXITCODE = $null
& $GetImageScript
# $? must be captured on the VERY next statement; it detects the child
# never having run at all (parse failure), which $LASTEXITCODE cannot see
# -- and on a cache-hit re-run the artifact check below false-passes
# because the image file already exists.
$getImageInvokeOk = $?
# Read the child's exit code after resetting the global, never a local shadow.
# See https://yuruna.link/42e220c4-0008
if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    Write-Error "Get-Image.ps1 failed (exit $LASTEXITCODE)."
    exit 1
}
if (-not $getImageInvokeOk) {
    Write-Error "Get-Image.ps1 did not run to completion (invocation failed -- e.g. parse error; see the error above)."
    exit 1
}
if (-not (Test-Path $ImageFile)) {
    Write-Error "Get-Image.ps1 exited 0 but '$ImageFile' is still missing."
    exit 1
}

# --- REGION: Start the host status service
# See https://yuruna.link/42e5cdfd-0034
Write-Verbose ""
Write-Verbose "== Step 2.5: host status service (serves the local repo to the cache VM) =="
Import-Module (Join-Path $ModulesDir 'Test.Config.psm1') -Global -Force
$cpStatusScript = Join-Path $PSScriptRoot 'Start-StatusService.ps1'
$cpConfig = Read-TestConfig -Path (Join-Path $PSScriptRoot '../test.config.yml')
$cpStatusDecision = Start-YurunaStatusServiceIfEnabled -Config $cpConfig -StartScript $cpStatusScript
if ($cpStatusDecision.ShouldStart) {
    # "ShouldStart" is a decision, not an outcome: it says the config asked for
    # the service, and stays true whether or not the port ever answered. A
    # headline printed off it can therefore claim the service is up in the same
    # breath as the launch reports that it is not. Verify the port the way Step
    # 2.6 verifies the config service, and say which of the two actually happened.
    $cpStatusUp = Test-TcpEndpointOpen -Address '127.0.0.1' -Port ([int]$cpStatusDecision.Port) -TimeoutMilliseconds 3000
    if ($cpStatusUp) {
        Write-Verbose "  status service up on :$($cpStatusDecision.Port) -- the cache VM will build from http://<host>:$($cpStatusDecision.Port)/yuruna-repo/"
    } else {
        # Not fatal, unlike the config service: the guest's build block falls back
        # to the public github mirror when the local repo is unreachable, so the VM
        # still comes up -- just built from mirrored source rather than this
        # working tree. Say exactly that instead of claiming the service is up.
        Write-Warning "  status service is NOT answering on :$($cpStatusDecision.Port) -- the cache VM will build collector/parser source from github instead of this working tree."
        $cpStatusRuntimeDir = if ($env:YURUNA_RUNTIME_DIR) { $env:YURUNA_RUNTIME_DIR } else { Join-Path $PSScriptRoot '../status/runtime' }
        Write-Warning "  Server error log: $(Join-Path $cpStatusRuntimeDir 'server.err')"
    }
} else {
    Write-Verbose "  statusService disabled (test.config.yml) -- the cache VM will fall back to github for collector/parser source."
}

# --- REGION: Start the host config service
# See https://yuruna.link/42e5cdfd-0035
Write-Verbose ""
Write-Verbose "== Step 2.6: config service (serves NAS creds to this host's VMs over mTLS) =="
# Shares the runner's lifecycle gate (Test.Prelude) so enabled / port / the
# idempotent skip-if-healthy ensure behave identically here and on every runner
# cycle -- the config service is no longer started ONLY by this one-shot script.
$cpConfigDecision = Start-YurunaConfigServiceIfEnabled -Config $cpConfig -StartScript (Join-Path $PSScriptRoot 'Start-ConfigService.ps1')
if ($cpConfigDecision.ShouldStart) {
    # See https://yuruna.link/42e5cdfd-0036
    $cpConfigUp = Test-TcpEndpointOpen -Address '127.0.0.1' -Port ([int]$cpConfigDecision.Port) -TimeoutMilliseconds 3000
    if ($cpConfigUp) {
        Write-Verbose "  config service verified accepting on :$($cpConfigDecision.Port) (mTLS; serves NAS creds to this host's VMs)."
    } else {
        # See https://yuruna.link/42e5cdfd-0036
        Write-Verbose ""
        Write-Output "  Building the cache VM now would bake EMPTY mTLS materials into its seed: it could not fetch"
        Write-Verbose "  its ystash-nas/ypool-nas credentials -- so NO password rotation, and an EMPTY 'Extension"
        Write-Verbose "  Hosts' panel (the stash crawler never appears, since ystash-nas is never mounted)."
        Write-Verbose "  Fix the config service first (check config-server.err under the runtime dir), then re-run"
        Write-Verbose "  Start-CachingProxyServiceVM.ps1. To build without it intentionally, set configService.enabled=false."
        Write-Error "config service is NOT accepting on :$($cpConfigDecision.Port) -- refusing to build the cache VM (configService is enabled)."
        exit 1
    }
} else {
    Write-Verbose "  configService disabled (test.config.yml) -- VMs use their baked NAS credential; password rotation won't propagate until re-enabled."
}

# --- REGION: Create the VM
Write-Verbose ""
Write-Verbose "== Step 3: create VM '$VMName' =="
$global:LASTEXITCODE = $null
# See https://yuruna.link/42e220c4-0008
$newVmParams = @{ VMName = $VMName; AllowPseudoLocale = $AllowPseudoLocale }
if ($MacAddress) { $newVmParams.MacAddress = $MacAddress }
# Both or neither: the profile is the only place these two are chosen, so a
# caller cannot shrink the VM and leave squid budgeted for the larger one.
# Imported here rather than relying on the -MacAddress branch above, which only
# loads the module when the operator pinned a MAC.
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
$cacheProfile = Get-CachingProxyMemoryProfile -Lab:$Lab
$newVmParams.MemoryMb      = $cacheProfile.VmMemoryMb
$newVmParams.SquidCacheMem = $cacheProfile.SquidCacheMem
Write-Verbose ("  Cache VM sizing: {0} MB RAM, squid cache_mem {1} ({2} profile)." -f `
    $cacheProfile.VmMemoryMb, $cacheProfile.SquidCacheMem, $(if ($Lab) { 'lab' } else { 'standalone' }))
& $NewVMScript @newVmParams
# $? must be captured on the VERY next statement; any intervening command
# overwrites it.
$newVmInvokeOk = $?
# Same $LASTEXITCODE-reliability guard as Get-Image above: a child .ps1 that ends
# on a cmdlet leaves it unset, so only a REAL non-zero is a failure. New-VM.ps1 is
# the real gate -- it builds and (Hyper-V/KVM) starts the VM and blocks on :3128,
# exiting non-zero or throwing on failure (a throw terminates this script before
# the check); the UTM branch's registration check below is a further gate.
if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    Write-Error "New-VM.ps1 failed (exit $LASTEXITCODE)."
    exit 1
}
# $LASTEXITCODE cannot see a child that never RAN: a parameter-binding or
# parse failure surfaces only as a non-terminating error on the invocation
# ($? = $false) and leaves $LASTEXITCODE $null -- without this check the
# run would sail on to discovery and print a false "READY" banner over a
# VM that was never created.
if (-not $newVmInvokeOk) {
    Write-Error "New-VM.ps1 did not run to completion (invocation failed -- e.g. parameter-binding or parse error; see the error above)."
    exit 1
}

# --- REGION: Register and start the UTM VM
# (Hyper-V's New-VM.ps1 already starts the VM and waits for :3128.)

$cacheIp = $null
# LAN-reachable address for the cache, and whether host forwarders are in
# play. $cacheLanIp defaults (later) to the VM's own IP -- correct for
# macOS bridged / Windows external vSwitch / Linux bridged 'yuruna-
# external'. On the Linux NAT path it is overridden to the HOST's LAN IP,
# because that is where the systemd socket forwarders expose the cache.
$cacheLanIp     = $null
$cacheForwarded = $false
if ($IsMacOS) {
    Write-Verbose ""
    Write-Verbose "== Step 4: register '$VMName' with UTM and start =="
    if (-not (Test-Path $UtmDir)) {
        Write-Error "Expected bundle '$UtmDir' missing after New-VM.ps1 ran."
        exit 1
    }
    # See https://yuruna.link/42e5cdfd-0037
    if (-not (Get-Command Start-UtmDialogWatchdog -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $RepoRoot 'host/macos.utm/modules/Yuruna.Host.psm1') -Global -Force -DisableNameChecking
    }
    Start-UtmDialogWatchdog
    # `open -g -a UTM` launches UTM in background and imports the bundle.
    # utmctl has no 'import' verb -- `open` is the only way to register a
    # freshly-built .utm bundle from the CLI.
    & open -g -a UTM $UtmDir
    if ($LASTEXITCODE -ne 0) {
        Stop-UtmDialogWatchdog
        Write-Error "'open -g -a UTM $UtmDir' failed (exit $LASTEXITCODE)."
        exit 1
    }

    # See https://yuruna.link/42e5cdfd-0037
    $cpUtmctl = {
        param([string]$Verb, [string]$Name, [int]$TimeoutSeconds)
        if ($Verb -eq 'start' -and (Get-Command Invoke-UtmctlLifecycle -ErrorAction SilentlyContinue)) {
            return (Invoke-UtmctlLifecycle -Verb start -VMName $Name -TimeoutSeconds $TimeoutSeconds -Quiet)
        }
        if ($Verb -eq 'status' -and (Get-Command Invoke-UtmctlProbe -ErrorAction SilentlyContinue)) {
            return (Invoke-UtmctlProbe -Arguments @('status', $Name) -TimeoutSeconds $TimeoutSeconds -Quiet)
        }
        return (Invoke-BoundedNativeCommand -FilePath 'utmctl' -ArgumentList @($Verb, $Name) -TimeoutSeconds $TimeoutSeconds)
    }
    # UTM registers asynchronously after import -- poll for up to 30 s against a
    # wall-clock deadline (an iteration counter drifts past 30 s by the per-call
    # utmctl status latency; feedback_iter_counter_wallclock_trap). Each call
    # gets at most the whole seconds left of those 30 s, and none starts with
    # less than one left, so the window ends on time.
    $registered = $false
    $cpRegisterDeadline = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $cpRegisterDeadline) {
        Start-Sleep -Seconds 1
        $cpRegisterLeft = [int][Math]::Min(10, [Math]::Floor(($cpRegisterDeadline - [DateTime]::UtcNow).TotalSeconds))
        if ($cpRegisterLeft -lt 1) { break }
        $cpRegisterProbe = & $cpUtmctl 'status' $VMName $cpRegisterLeft
        if ((Test-BoundedNativeResultComplete -Result $cpRegisterProbe) -and [int]$cpRegisterProbe.ExitCode -eq 0) { $registered = $true; break }
    }
    if (-not $registered) {
        Stop-UtmDialogWatchdog
        Write-Error "UTM did not register '$VMName' within 30 s. Open UTM manually to continue."
        exit 1
    }
    # See https://yuruna.link/42e5cdfd-0037
    Write-Verbose "  Registered. Starting VM..."
    $started = $false
    $lastState = ''
    for ($attempt = 1; $attempt -le 3 -and -not $started; $attempt++) {
        # A start that timed out or could not be read has an unknown outcome,
        # which is a failure here: the status poll below cannot tell a start
        # still in flight from one that never happened.
        $cpStartCall = & $cpUtmctl 'start' $VMName 120
        $cpStartRc = if (Test-BoundedNativeResultComplete -Result $cpStartCall) { [int]$cpStartCall.ExitCode } else { -1 }
        if ($cpStartRc -ne 0) {
            Stop-UtmDialogWatchdog
            Write-Error (Format-YurunaOperatorMessage -Key 'runner.service_cachingproxy_utmctl_start_failed' -Arguments @{ vmName = "$VMName"; exitCode = "$cpStartRc" })
            exit 1
        }
        # Poll up to 15 s (wall-clock) for the VM to report itself running. Only
        # 'started' counts; see the allow-list note above.
        $cpStartDeadline = [DateTime]::UtcNow.AddSeconds(15)
        while ([DateTime]::UtcNow -lt $cpStartDeadline) {
            Start-Sleep -Seconds 1
            # See https://yuruna.link/42e5cdfd-0037
            $cpStatusCall = & $cpUtmctl 'status' $VMName 10
            $statusRc = if (Test-BoundedNativeResultComplete -Result $cpStatusCall) { [int]$cpStatusCall.ExitCode } else { -1 }
            $statusOut = @(Get-BoundedNativeOutputLine -Result $cpStatusCall -IncludeError | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
            # Scanned across every line rather than taken from the first: utmctl
            # puts its diagnostics ahead of its payload, so the state is not
            # reliably line one. Confirm-UtmVMStarted reads it the same way.
            if ($statusRc -eq 0 -and $statusOut.Count -gt 0) { $lastState = ($statusOut -join '; ') }
            if ($statusRc -eq 0 -and @($statusOut | Where-Object { $_ -match '^(started|running)$' }).Count -gt 0) {
                $started = $true
                break
            }
        }
        if (-not $started) {
            Write-Warning "  'utmctl start' attempt $attempt returned 0 but VM reports '$lastState' -- retrying."
        }
    }
    if (-not $started) {
        Stop-UtmDialogWatchdog
        # See https://yuruna.link/42e5cdfd-0037
        $observed = if ($lastState) { "it reports '$lastState'" } else { 'utmctl never returned a status for it' }
        Write-Error ("UTM did not bring '$VMName' to 'started' after 3 attempts; $observed. " +
            "Open UTM, bring the VM to a running state, then re-run.")
        exit 1
    }
    # VM is up; the launch-time custom-QEMU-args warning is past. Stop the
    # watchdog so it isn't left clicking UTM dialogs through the (up to
    # 15-min) Step 5 discovery wait and the cache VM's long lifetime.
    Stop-UtmDialogWatchdog

    # Networking mode mirrors what New-VM.ps1 built. On a Wi-Fi default
    # route bridging can't get the cache VM a LAN lease, so the VM is on
    # UTM Shared NAT (192.168.64.x): discover it by bundle MAC via ARP
    # and expose it to the LAN with host port-forwarders. On Ethernet the
    # VM is bridged (LAN-direct) and discovered by ARP (the else-branch).
    if (Test-MacUplinkNotBridgeable) {
        # --- REGION: Configure Shared NAT forwarding
        Write-Verbose ""
        Write-Verbose "== Step 5: discover Shared-NAT cache VM + expose to LAN (Wi-Fi host) =="
        $httpPort  = Get-CachingProxyServicePort -Scheme http
        $httpsPort = Get-CachingProxyServicePort -Scheme https
        Import-Module (Join-Path $RepoRoot 'host/macos.utm/modules/Yuruna.Host.psm1') -Global -Force -DisableNameChecking
        # See https://yuruna.link/42e5cdfd-0038
        $sharedGw     = Get-GuestReachableHostIp           # 192.168.64.1
        $sharedPrefix = $sharedGw -replace '\d+$', ''      # 192.168.64.
        Write-Verbose "  Discovering cache VM by bundle MAC on ${sharedPrefix}0/24 + waiting for squid on :${httpPort} (up to 15 min)..."
        $cacheIp = Resolve-UtmGuestIpByMac -PlistPath (Join-Path $UtmDir 'config.plist') `
            -SubnetPrefix $sharedPrefix -HostIp $sharedGw -ProbePort $httpPort -TimeoutMinutes 15 -PollSeconds 5
        if (-not $cacheIp) {
            Write-Warning "Shared-NAT discovery: our cache VM (by bundle MAC) did not appear on ${sharedPrefix}0/24 with squid on :${httpPort} within 15 min. The VM may still be running cloud-init -- re-run Start-CachingProxyServiceVM.ps1, or open the UTM window to check."
        } else {
            Write-Verbose "  Cache VM (Shared NAT) is at $cacheIp (matched by bundle MAC; squid listening)."
            # Expose to the LAN via host port-forwarders (mirrors the Linux
            # NAT branch). squid's ACL already allows 192.168.0.0/16, which
            # covers the host's gateway forwarder source, so plain forwarding
            # works with no PROXY protocol. Re-import the host contract first
            # so Add-PortMap / Get-BestHostIp resolve.
            Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostContract.psm1') -Force
            [void](Initialize-YurunaHost -RepoRoot $RepoRoot)
            # See https://yuruna.link/42e5cdfd-0038
            if (Get-Command Initialize-SudoCache -ErrorAction SilentlyContinue) {
                [void](Initialize-SudoCache -Reasons @("bind host port 80 to forward the cache VM's CA-cert page to remote LAN clients"))
            } elseif ((& /usr/bin/id -u).Trim() -ne '0') {
                # Same reason the branch above prefers Initialize-SudoCache: a bare
                # `sudo -v` reads the password from /dev/tty, which a captured child
                # cannot show and cannot answer. The forwarder is a remote-LAN
                # convenience, so declining to prompt costs only that.
                if ($env:YURUNA_NONINTERACTIVE -eq '1') {
                    & sudo -n -v 2>$null
                    if ($LASTEXITCODE -ne 0) {
                        Write-Warning ("  sudo has no live authorization and this run is non-interactive, so the :80 forwarder " +
                                       "will be skipped. Remote LAN clients can still fetch the CA cert from the VM directly.")
                    }
                } else {
                    Write-Verbose "  Re-priming sudo (the :80 forwarder needs root to bind a sub-1024 port)..."
                    & sudo -v
                }
            }
            $cacheForwarded = [bool](Add-PortMap -VMIp $cacheIp `
                    -Port (Get-CachingProxyServiceExposedPort -HttpPort $httpPort -HttpsPort $httpsPort) `
                    -PortRemap @{8022 = 22} -Confirm:$false)
            if ($cacheForwarded) {
                $cacheLanIp = Get-BestHostIp
                Write-Verbose "  Cache exposed to the LAN at host $cacheLanIp via pwsh socket forwarders."
            } else {
                Write-Warning "  Forwarder setup failed -- the cache is reachable from this host and Shared-NAT UTM guests at $cacheIp, but not from other LAN machines."
            }
            # Re-import Test.CachingProxyService -Global -Force: Initialize-YurunaHost
            # evicts this script's view via the host module's nested non-
            # global import (feedback_module_force_import_evicts_global).
            Import-Module (Join-Path $PSScriptRoot '../modules/Test.CachingProxyService.psm1') -Global -Force -Verbose:$false
            [void](Save-CachingProxyServiceState -IpAddress $cacheIp -Confirm:$false)
        }
    } else {
    # See https://yuruna.link/42e5cdfd-0038
    $httpPort = Get-CachingProxyServicePort -Scheme http
    Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostContract.psm1') -Force
    [void](Initialize-YurunaHost -RepoRoot $RepoRoot)
    $lanPrefix = $null
    $hostLanIp = $null
    try { $hostLanIp = Get-BestHostIp } catch { $null = $_ }
    if ($hostLanIp -and $hostLanIp -match '^(\d+\.\d+\.\d+)\.(\d+)$') {
        $lanPrefix = $matches[1] + '.'
    }
    if (-not $lanPrefix) {
        Write-Error "Could not resolve host's LAN /24 (no default-route IPv4). The cache VM is bridged to the host's NIC; without a host LAN address we cannot resolve the cache's DHCP-assigned IP. Connect the Mac to a network with a default route and re-run."
        exit 1
    }

    # --- REGION: Step 5: macOS bridged -- wait for the cache VM to DHCP and squid to listen
    # See https://yuruna.link/42e5cdfd-0038
    Write-Verbose ""
    Write-Verbose "== Step 5: wait for our cache VM (by bundle MAC) to DHCP on ${lanPrefix}0/24 and squid to listen on :${httpPort} (up to 15 min) =="
    Write-Verbose "  (first boot = cloud-init installs squid + apache2,"
    Write-Verbose "   then pre-warms by pulling linux-firmware through the proxy)"
    Write-Verbose "  Cache VM is VZ-bridged to '${hostLanIp}'s NIC; IP is matched"
    Write-Verbose "  by MAC, so a peer host's cache on the same LAN cannot be"
    Write-Verbose "  misidentified as ours."
    $cacheIp = Resolve-UtmGuestIpByMac -PlistPath (Join-Path $UtmDir 'config.plist') `
        -SubnetPrefix $lanPrefix -HostIp $hostLanIp -ProbePort $httpPort -TimeoutMinutes 15 -PollSeconds 5
    if (-not $cacheIp) {
        Write-Warning "Our cache VM (by bundle MAC) did not appear in the host's ARP table on ${lanPrefix}0/24 with squid on :${httpPort} after 15 min."
        Write-Warning "Likely causes:"
        Write-Warning "  * Wi-Fi AP filtering the cache's locally-administered MAC -- switch to Ethernet or allow the new MAC."
        Write-Warning "  * cloud-init still installing squid (rare on first run; check progress via UTM window)."
        Write-Warning "  * LAN is not a single /24 (the discovery sweep assumes one)."
        # Asked for rather than asserted: whether the VM is still running is one
        # of the things that can be wrong here -- a VM
        # stopped or suspended out from under the sweep looks identical to one
        # that never got a DHCP lease, and sending the operator inside a guest
        # that is not running costs them the whole diagnosis.
        Write-Warning "First check the VM is still running:  utmctl status $VMName"
        Write-Warning "If it reports 'started', log in through the UTM window and run:"
        Write-Warning "  sudo grep -E 'E:|429 |Hash Sum|Failed to fetch|Unable to locate|Exit code' /var/log/cloud-init-output.log | head -40"
        Write-Warning "  ip -4 addr show           # verify the VM got a DHCP lease on the LAN"
    }

    # --- REGION: Step 6: macOS bridged -- tear down legacy host-side forwarders
    # See https://yuruna.link/42e5cdfd-0039
    if ($cacheIp) {
        Write-Verbose ""
        Write-Verbose "== Step 6: tear down any legacy host-side forwarders (bridged cache is LAN-direct) =="
        [void](Remove-PortMap -Confirm:$false)

        # See https://yuruna.link/42e5cdfd-0039
        Import-Module (Join-Path $PSScriptRoot '../modules/Test.CachingProxyService.psm1') -Global -Force -Verbose:$false
        [void](Save-CachingProxyServiceState -IpAddress $cacheIp -Confirm:$false)
    }
    }
} elseif ($IsLinux) {
    # See https://yuruna.link/42e5cdfd-0039
    # --- REGION: Linux -- re-query the cache VM IP for persistence + summary
    Write-Verbose ""
    Write-Verbose "== Step 4: re-query cache VM IP for persistence + summary =="
    Import-Module (Join-Path $RepoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1') -Force -DisableNameChecking
    # Get-VMIp probes virsh domifaddr in source order lease -> agent ->
    # arp, so a NAT 'default' VM (lease) and a 'yuruna-external' VM
    # (agent or arp) both resolve.
    $cacheIp = Get-VMIp -VMName $VMName
    if (-not $cacheIp) {
        Write-Warning "  Get-VMIp returned no IPv4 for '$VMName'. New-VM.ps1 reported the VM started, but discovery sources (lease/agent/arp) are silent. The VM is likely still warming up the guest agent -- retry Start-CachingProxyServiceVM.ps1 in 30 s, or run 'virsh -c qemu:///system domifaddr --source agent $VMName' to inspect."
    } else {
        Write-Verbose "  Cache VM IP: $cacheIp"
        # Persist for guest provisioners + status service fast path.
        # Re-import Test.CachingProxyService -Global -Force here for the same
        # reason the macOS/Windows branches do (Initialize-YurunaHost
        # via Test.HostContract.psm1 nested-imports Test.CachingProxyService without
        # -Global, which evicts the script's view of the exports).
        Import-Module (Join-Path $PSScriptRoot '../modules/Test.CachingProxyService.psm1') -Global -Force -Verbose:$false
        [void](Save-CachingProxyServiceState -IpAddress $cacheIp -Confirm:$false)
    }

    # See https://yuruna.link/42e5cdfd-003a
    if ($cacheIp) {
        Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostContract.psm1') -Force
        [void](Initialize-YurunaHost -RepoRoot $RepoRoot)
        if (Test-CacheVMOnExternalNetwork -VMName $VMName) {
            Write-Verbose "  Cache VM is on a bridged libvirt network (LAN-direct, real client IPs preserved). Skipping host portproxy."
            [void](Remove-PortMap -Confirm:$false)
            $cacheLanIp = $cacheIp
        } else {
            $hPort  = Get-CachingProxyServicePort -Scheme http
            $hsPort = Get-CachingProxyServicePort -Scheme https
            # Port set: squid (3128 / 3129), Apache CA cert (80),
            # Grafana (3000), caching-proxy-parser-service (9302),
            # pool-aggregator-service (9400), SSH remap 8022 -> 22 for jump-host access.
            $cacheForwarded = [bool](Add-PortMap -VMIp $cacheIp `
                    -Port (Get-CachingProxyServiceExposedPort -HttpPort $hPort -HttpsPort $hsPort) `
                    -PortRemap @{8022 = 22} -Confirm:$false)
            if ($cacheForwarded) {
                $cacheLanIp = Get-BestHostIp
                Write-Verbose "  Cache exposed to the LAN at the host IP ($cacheLanIp) via systemd socket forwarders."
            } else {
                Write-Warning "  Port-forwarder setup failed -- cache is reachable from THIS host only (at $cacheIp)."
            }
            # See https://yuruna.link/42e5cdfd-003a
            Write-Warning ""
            Write-Warning "  POOL DASHBOARD: the 'Yuruna hosts' dashboard on this cache VM will show NO"
            Write-Warning "  hosts while it is on the NAT 'default' network -- the host-side forwarder"
            Write-Warning "  masks every client as the NAT gateway, so the pool-aggregator-service discovers"
            Write-Warning "  nothing. To fix, put the cache VM on the bridged 'yuruna-external' network"
            Write-Warning "  (needs a WIRED default-route NIC; Wi-Fi APs block bridging) and rebuild it:"
            Write-Warning "    connect the host by Ethernet, then re-run test/service/Start-CachingProxyServiceVM.ps1"
            Write-Warning "    (it auto-builds yuruna-external + rebuilds the cache VM on the bridge),"
            Write-Warning "    or define the bridge by hand per host/ubuntu.kvm/guest.caching-proxy-service/README.md."
            Write-Warning ""
        }
    }
} elseif ($IsWindows) {
    # --- REGION: Windows -- discover the cache VM and expose its ports to the LAN
    # See https://yuruna.link/42e5cdfd-003b
    $vmCommon = Join-Path $RepoRoot "host/windows.hyper-v/modules/Yuruna.Host.psm1"
    Import-Module $vmCommon -Force
    $CachingProxyServiceUrl = Get-WorkingCachingProxyServiceUrl -VMName $VMName
    if ($CachingProxyServiceUrl -match '^http://([0-9.]+):') { $cacheIp = $matches[1] }
    # Both outcomes are said out loud, because everything downstream on this
    # branch is gated on $cacheIp and silently does nothing without it -- no
    # recorded state, no port maps -- and a bring-up that ends that way stops
    # the run with nothing on screen to explain why.
    if (-not $cacheIp) {
        if ($CachingProxyServiceUrl) {
            # See https://yuruna.link/42e5cdfd-003b
            Write-Warning "The cache answered at $CachingProxyServiceUrl, but no IPv4 address could be read from it, so there is nothing to record or to point guests at. A cache reachable only over IPv6 lands here; give it an IPv4 address on the vSwitch it is attached to."
        } else {
            Write-Warning "No caching-proxy VM answered on the proxy port. Hyper-V KVP may be cold (hv_kvp_daemon not yet running in the guest) and the host's neighbor entry for the VM's MAC may have aged out. Check the VM is running, then re-run this script."
        }
    }

    # Persist the cache VM's IP so Test-CachingProxyServiceAvailable's state-
    # file-only discovery path can find it next call. Mirrors the macOS
    # branch above. Re-import Test.CachingProxyService -Global -Force here to
    # work around the same nested-import shadowing trap documented in
    # the macOS branch comment.
    if ($cacheIp) {
        Import-Module (Join-Path $PSScriptRoot '../modules/Test.CachingProxyService.psm1') -Global -Force -Verbose:$false
        [void](Save-CachingProxyServiceState -IpAddress $cacheIp -Confirm:$false)
    }

    # See https://yuruna.link/42e5cdfd-003b
    if ($cacheIp) {
        Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostContract.psm1') -Force
        [void](Initialize-YurunaHost -RepoRoot $RepoRoot)
        # See https://yuruna.link/42e5cdfd-003b
        if (Test-CacheVMOnExternalNetwork -VMName $VMName) {
            Write-Verbose "  Cache VM is on an External vSwitch (LAN-direct, real client IPs preserved). Skipping host portproxy."
            [void](Remove-PortMap -Confirm:$false)
        } else {
            $hPort  = Get-CachingProxyServicePort -Scheme http
            $hsPort = Get-CachingProxyServicePort -Scheme https
            # 9302: caching-proxy-parser-service endpoint (see
            # test/extension/caching-proxy-parser-service/). Reached directly via
            # netsh portproxy along with squid/Apache/Grafana.
            [void](Add-PortMap -VMIp $cacheIp `
                    -Port (Get-CachingProxyServiceExposedPort -HttpPort $hPort -HttpsPort $hsPort) `
                    -PortRemap @{8022 = 22} -Confirm:$false)
        }
    }
}

# --- REGION: Confirm caching proxy readiness
# See https://yuruna.link/42f6b05f-003e
# A successful bring-up must record the guest address before releasing its lock.
if (-not $cacheIp) {
    Write-Output "== caching-proxy-service is NOT READY -- '$VMName' =="
    exit 1
}
$serviceOpResult = 'confirmed'

} finally {
    # Rebuild critical section done -- normally, via any of the `exit 1` paths above,
    # or via a throw. Release the serialization lock before the (read-only) summary so
    # a waiting bring-up / the runner's port-map can proceed. Exit- is idempotent and
    # ownership-checked, so the adopt fast path's explicit release is not double-work.
    [void](Exit-CachingProxyServiceLock -Handle $cpLock)
}

# --- REGION: Report the service state
# See https://yuruna.link/42e5cdfd-003c

Write-Verbose ""
Write-Verbose "========"
# Reached only when the cache answered -- the critical section exits before this
# otherwise -- so READY is a claim this can still make truthfully.
Write-Output "== caching-proxy-service is READY -- '$VMName' =="
Write-Verbose "========"
if ($cacheIp) {
    Write-Output "  VM IP:       $cacheIp"
    $summaryHttpPort  = Get-CachingProxyServicePort -Scheme http
    $summaryHttpsPort = Get-CachingProxyServicePort -Scheme https
    if ($IsMacOS -and -not $cacheForwarded) {
        # Ethernet/bridged: the cache has its own LAN DHCP IP and every
        # consumer (host, Shared-NAT install VMs, remote LAN hosts) reaches
        # it at $cacheIp:<port> directly. No host-side forwarder layer.
        # Mirrors the Hyper-V Yuruna-External vSwitch path's summary lines.
        Write-Verbose "  Proxy URL:   http://${cacheIp}:${summaryHttpPort}"
        Write-Verbose "  HTTPS bump:  http://${cacheIp}:${summaryHttpsPort}  (squid SSL-bump listener)"
        Write-Verbose "  Grafana:     http://${cacheIp}:3000  (anonymous Viewer)"
        Write-Verbose "  Recent 100:  http://${cacheIp}:9302/  (in-memory live tail)"
        Write-Verbose "  cachemgr:    ssh to the VM, then 'squidclient mgr:info'  (web UI dropped in Ubuntu 26.04)"
        Write-Verbose "  CA cert:     http://${cacheIp}/yuruna-squid-ca.crt  (trust to enable :${summaryHttpsPort} HTTPS caching)"
        Write-Verbose ""
        Write-Verbose "  Remote LAN clients (other hosts on this network):"
        Write-Verbose "    Set on the remote host BEFORE Start-TestRunner.ps1:"
        Write-Verbose "      export YURUNA_CACHING_PROXY_SERVICE_IP=${cacheIp}"
        Write-Verbose "      (or on Windows: setx YURUNA_CACHING_PROXY_SERVICE_IP ${cacheIp})"
        Write-Verbose "    Quick check from the remote host:"
        Write-Verbose "      curl -x http://${cacheIp}:${summaryHttpPort} http://cdimage.ubuntu.com/ -I"
        Write-Verbose "    NOTE: a populated vmStart.cachingProxyIp in the remote host's"
        Write-Verbose "      test.config.yml is probed first and outranks the env var."
    } elseif ($IsMacOS) {
        # See https://yuruna.link/42e5cdfd-003c
        Write-Verbose "  Local URL:   http://${cacheIp}:${summaryHttpPort}  (this host + same-Mac UTM test VMs, auto-discovered)"
        Write-Verbose "  HTTPS bump:  http://${cacheIp}:${summaryHttpsPort}  (squid SSL-bump listener)"
        Write-Verbose "  Grafana:     http://${cacheIp}:3000  (anonymous Viewer)"
        Write-Verbose "  Recent 100:  http://${cacheIp}:9302/  (in-memory live tail)"
        Write-Verbose "  cachemgr:    ssh to the VM, then 'squidclient mgr:info'  (web UI dropped in Ubuntu 26.04)"
        Write-Verbose "  CA cert:     http://${cacheIp}/yuruna-squid-ca.crt  (trust to enable :${summaryHttpsPort} HTTPS caching)"
        Write-Verbose ""
        Write-Verbose "  Same-Mac test VM: just run Start-TestRunner.ps1 -- do NOT set"
        Write-Verbose "    YURUNA_CACHING_PROXY_SERVICE_IP. The guest finds the cache at ${cacheIp}."
        if ($cacheLanIp) {
            Write-Verbose ""
            Write-Verbose "  Remote LAN clients (OTHER physical hosts only) -- best-effort:"
            Write-Verbose "    reach the cache via host $cacheLanIp, which forwards these ports to"
            Write-Verbose "    $cacheIp (pwsh socket-proxy). NOTE: this forwarder is torn down by any"
            Write-Verbose "    later Remove-PortMap (test run / status restart); if a remote client"
            Write-Verbose "    gets 'connection refused', re-run Start-CachingProxyServiceVM.ps1 to restore it."
            Write-Verbose "    export YURUNA_CACHING_PROXY_SERVICE_IP=${cacheLanIp}    # remote host, before Start-TestRunner.ps1"
            Write-Verbose "      (or on Windows: setx YURUNA_CACHING_PROXY_SERVICE_IP ${cacheLanIp})"
            Write-Verbose "    quick check:  curl -x http://${cacheLanIp}:${summaryHttpPort} http://cdimage.ubuntu.com/ -I"
            Write-Verbose "    NOTE: a populated vmStart.cachingProxyIp in the remote host's"
            Write-Verbose "      test.config.yml is probed first and outranks the env var."
        }
    } else {
        # Linux / Windows. $cacheLanIp is the address LAN clients use:
        # the VM's own IP when it is on a bridge / external vSwitch, or
        # the HOST's LAN IP when the cache is NAT'd and exposed via the
        # systemd socket forwarders. $cacheForwarded is only ever true on
        # the Linux NAT path.
        $lanIp = if ($cacheLanIp) { $cacheLanIp } else { $cacheIp }
        if ($cacheForwarded -and $cacheLanIp -ne $cacheIp) {
            Write-Verbose "  LAN access:  via host $cacheLanIp -- the cache VM is NAT'd at $cacheIp and"
            Write-Verbose "               the host forwards these ports to it (systemd socket-proxy)."
        }
        Write-Verbose "  Proxy URL:   http://${lanIp}:${summaryHttpPort}"
        Write-Verbose "  Grafana:     http://${lanIp}:3000  (anonymous Viewer)"
        Write-Verbose "  Recent 100:  http://${lanIp}:9302/  (in-memory live tail)"
        Write-Verbose "  cachemgr:    ssh to the VM, then 'squidclient mgr:info'  (web UI dropped in Ubuntu 26.04)"
        if ($cacheForwarded -and $cacheLanIp -ne $cacheIp) {
            Write-Verbose ""
            Write-Verbose "  Remote LAN clients (OTHER physical hosts only):"
            Write-Verbose "    export YURUNA_CACHING_PROXY_SERVICE_IP=${lanIp}    # remote host, before Start-TestRunner.ps1"
            Write-Verbose "    quick check:  curl -x http://${lanIp}:${summaryHttpPort} http://cdimage.ubuntu.com/ -I"
            Write-Verbose "    NOTE: a populated vmStart.cachingProxyIp in the remote host's"
            Write-Verbose "      test.config.yml is probed first and outranks the env var."
            Write-Verbose "  This host needs no env var: the runner auto-detects its own cache, and a"
            Write-Verbose "  YURUNA_CACHING_PROXY_SERVICE_IP naming this host's own IP is treated as local."
        }
    }
}
Write-Verbose ""
Write-Verbose "  SSH / console login:"
Write-Verbose "    user:     caching-proxy-service-admin"
Write-Verbose "    password: (saved at $PasswordFile)"
if ($cacheForwarded -and $cacheLanIp -and $cacheLanIp -ne $cacheIp) {
    # Linux NAT path: SSH reaches the cache via the host's 8022 -> 22
    # forwarder, not the VM's own (host-only) IP.
    Write-Verbose "    direct:   ssh -p 8022 caching-proxy-service-admin@${cacheLanIp}   (host forwards :8022 -> VM :22)"
} elseif ($cacheIp) {
    # macOS bridged + Hyper-V External-vSwitch + Linux bridged: the cache
    # VM has its own LAN IP, so direct SSH from anywhere on the LAN works.
    Write-Verbose "    direct:   ssh caching-proxy-service-admin@${cacheIp}"
}
Write-Verbose "========"
} finally {
    [void](Exit-YurunaServiceOperation -Context $serviceOp -Result $serviceOpResult -Confirm:$false)
}
