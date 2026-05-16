<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456742
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
    Brings up the yuruna-caching-proxy VM and exposes its ports
    (80, 3128, 3129, 3000, 9302) on the host. See test/CachingProxy.md
    for remote-client setup, elevation requirements (Windows admin;
    macOS `sudo -E` to bind :80), and the YURUNA_CACHING_PROXY_IP
    override that makes this a no-op.

.PARAMETER VMName   Name for the cache VM. Default: yuruna-caching-proxy.
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

# === Pre-flight: drop inherited proxy env vars from THIS process ===========
# This script's whole job is to BRING UP the cache, so by definition every
# network call it makes -- Get-Image.ps1 pulling the cloud image (which
# uses Invoke-WebRequest and on Windows Save-CachedHttpUri), virt-install
# fetching osinfo, qemu-img/genisoimage going out for nothing -- must
# reach the public Internet DIRECTLY. If the caller's shell exports
# HTTPS_PROXY / HTTP_PROXY / ALL_PROXY pointing at a previous cycle's
# cache IP that no longer hosts squid (stale after a host reboot, wrong
# LAN, or a cache VM that just got destroyed by Stop-CachingProxy.ps1),
# .NET's HttpClient honors that env var and every download fails with
# "Network is unreachable" -- well before the cache we're about to build
# exists. YURUNA_CACHING_PROXY_IP belongs in the same bucket: the harness
# (Invoke-TestRunner.ps1's remote-cache branch, Test-CachingProxy*'s
# discovery) translates it into a proxy URL downstream, and it would
# similarly route guest provisioner traffic at a dead IP.
#
# Cross-host: applies uniformly to ubuntu.kvm (Get-Image.ps1 Invoke-
# WebRequest), windows.hyper-v (Save-CachedHttpUri's no-cache fall-
# through Invoke-WebRequest), and macos.utm (same shape) -- the runtime
# is the same .NET HttpClient on all three.
#
# Scope: this process and its children only. The user's shell is
# untouched, so any var they exported for OTHER scripts (later runs of
# Invoke-TestRunner.ps1, Test-CachingProxy.ps1 with the remote-cache
# override) is still set in the next shell. Step 1's Remove-HostProxy
# call handles the persistent/OS-level state (WinINet registry,
# /etc/environment, networksetup); this block handles the in-process
# gap that Remove-HostProxy cannot reach.
$proxyEnvVars = @(
    'HTTP_PROXY',  'http_proxy',
    'HTTPS_PROXY', 'https_proxy',
    'NO_PROXY',    'no_proxy',
    'ALL_PROXY',   'all_proxy',
    'YURUNA_CACHING_PROXY_IP'
)
$clearedProxy = @()
foreach ($pv in $proxyEnvVars) {
    $envProvPath = "Env:$pv"
    if (Test-Path -LiteralPath $envProvPath) {
        $clearedProxy += "$pv=$((Get-Item -LiteralPath $envProvPath).Value)"
        Remove-Item -LiteralPath $envProvPath -ErrorAction SilentlyContinue
    }
}
if ($clearedProxy.Count -gt 0) {
    Write-Output "Pre-flight: cleared inherited proxy env vars from this process so cache bring-up reaches the public Internet directly (caller's shell untouched):"
    foreach ($entry in $clearedProxy) {
        Write-Output "  $entry"
    }
}

# Repo root sits one level above test/.
$RepoRoot = Split-Path -Parent $PSScriptRoot

# Auto-relaunch under sg libvirt on host.ubuntu.kvm when this shell's
# group set is stale -- Start-CachingProxy on Linux provisions the cache
# VM via virt-install and queries its IP via virsh, both of which need
# libvirt-socket access. No-op on macOS / Windows / fresh shells.
Import-Module (Join-Path $PSScriptRoot 'modules/Test.Host.psm1') -Force
Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

if ($IsMacOS) {
    $HostDir      = Join-Path $RepoRoot 'host/macos.utm/guest.squid-cache'
    $downloadDir  = Join-Path $HOME 'yuruna/image/squid-cache'
    $ImageFile    = Join-Path $downloadDir 'host.macos.utm.guest.squid-cache.raw'
    $UtmDir       = "$HOME/yuruna/guest.nosync/$VMName.utm"
} elseif ($IsWindows) {
    $HostDir      = Join-Path $RepoRoot 'host/windows.hyper-v/guest.squid-cache'
    # (Get-VMHost) loads the Hyper-V module on first use; fails cleanly if
    # Hyper-V isn't installed — the underlying New-VM.ps1 has the same
    # dependency, so surfacing it here keeps the error close to the user.
    $downloadDir  = (Get-VMHost).VirtualHardDiskPath
    $ImageFile    = Join-Path $downloadDir 'host.windows.hyper-v.guest.squid-cache.vhdx'
} elseif ($IsLinux) {
    $HostDir      = Join-Path $RepoRoot 'host/ubuntu.kvm/guest.squid-cache'
    # libvirt-qemu boots qcow2 natively; matches the Get-Image.ps1 +
    # New-VM.ps1 output path for the KVM cache.
    $downloadDir  = Join-Path $HOME 'yuruna/image/squid-cache'
    $ImageFile    = Join-Path $downloadDir 'host.ubuntu.kvm.guest.squid-cache.qcow2'
    $KvmVmDir     = Join-Path $HOME "yuruna/vms/$VMName"
} else {
    Write-Error "Unsupported host. Start-CachingProxy.ps1 runs on macOS (UTM), Windows (Hyper-V), or Linux (KVM/libvirt)."
    exit 1
}

# Single cross-cycle persistence file (yuruna password + cache VM IP)
# under the framework's track directory. Replaces the per-platform
# squid-cache-password.txt and cache-ip.txt sidecars that used to live
# next to each host's VHD/raw image. See test/modules/Test.CachingProxy.psm1.
Import-Module (Join-Path $PSScriptRoot 'modules/Test.CachingProxy.psm1') -Global -Force -Verbose:$false
$PasswordFile = Get-CachingProxyStatePath

$GetImageScript = Join-Path $HostDir 'Get-Image.ps1'
$NewVMScript    = Join-Path $HostDir 'New-VM.ps1'

foreach ($p in @($GetImageScript, $NewVMScript)) {
    if (-not (Test-Path $p)) { Write-Error "Missing required script: $p"; exit 1 }
}

# === Step 0: plan + preflight ===============================================
# Past this point Start-CachingProxy runs UNATTENDED -- it must not stop
# for an interactive prompt. Everything that needs operator awareness is
# surfaced and resolved HERE, at the start:
#   * a host-networking change (the 'yuruna-external' bridge) is described
#     up front via Get-YurunaExternalNetworkPlan, before anything happens;
#   * sudo is primed once, with the reasons, so no step re-prompts;
#   * hard requirements (/dev/kvm, libvirtd) are checked so a doomed run
#     stops NOW with a clear explanation instead of failing deep inside
#     Step 3 (virt-install) after a multi-minute image download.
Write-Output ""
Write-Output "=== Step 0: plan + preflight ==="

$preflightErrors = @()
$plannedBridge   = $null   # set on Linux to the Get-YurunaExternalNetworkPlan result

if ($IsLinux) {
    # -- Hard requirements: without these the cache VM cannot boot. -------
    if (-not (Test-Path -LiteralPath '/dev/kvm')) {
        $preflightErrors += "/dev/kvm is missing -- KVM acceleration unavailable (kvm.ko not loaded, or VT-x/AMD-V disabled in firmware). The cache VM cannot boot."
    }
    $libvirtdActive = ((& systemctl is-active libvirtd 2>$null) | Out-String).Trim()
    if ($libvirtdActive -ne 'active') {
        $preflightErrors += "libvirtd is not active (state: '$libvirtdActive'). Start it with: sudo systemctl enable --now libvirtd"
    }

    # -- Bridge plan: decide NOW whether Step 1.5 will perturb host
    #    networking, and tell the operator before anything is touched. ---
    Import-Module (Join-Path $RepoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1') -Force -DisableNameChecking
    if ($env:YURUNA_EXTERNAL_BRIDGE_SKIP -eq '1') {
        Write-Output "  Network plan: bridge step SKIPPED (YURUNA_EXTERNAL_BRIDGE_SKIP=1)."
        Write-Output "    Cache VM will use libvirt NAT 'default' (reachable from this host only)."
    } else {
        $plannedBridge = Get-YurunaExternalNetworkPlan
        Write-Output "  Network plan: $($plannedBridge.Action)"
        foreach ($line in ($plannedBridge.Explanation -split "`r?`n")) {
            Write-Output "    $line"
        }
        if ($plannedBridge.WillChangeHostNetworking) {
            Write-Output ""
            Write-Output "  >> This run WILL briefly interrupt host networking (detail above).  <<"
            Write-Output "  >> Proceeding automatically and unattended. To keep the cache VM   <<"
            Write-Output "  >> on host-only NAT and avoid the change, re-run with              <<"
            Write-Output "  >>   YURUNA_EXTERNAL_BRIDGE_SKIP=1 ./Start-CachingProxy.ps1        <<"
        }
    }
}

if ($preflightErrors.Count -gt 0) {
    Write-Output ""
    Write-Output "  Preflight FAILED -- the run cannot succeed. Nothing was created:"
    foreach ($e in $preflightErrors) { Write-Output "    - $e" }
    Write-Error "Start-CachingProxy preflight failed ($($preflightErrors.Count) blocking issue(s)). Resolve the above and re-run."
    exit 1
}

# Prime sudo ONCE, now, with the reasons -- so the host-proxy wipe (Step 1)
# and, on Linux, the bridge's `sudo nmcli` calls (Step 1.5) never prompt
# mid-run. Initialize-SudoCache is idempotent + silent when the cache is
# already warm or elevation isn't needed (e.g. running as root).
$sudoReasons = @("wipe machine-wide host proxy config (/etc/environment, apt)")
if ($IsLinux -and $plannedBridge -and $plannedBridge.WillChangeHostNetworking) {
    $sudoReasons += "build Linux bridge '$($plannedBridge.BridgeName)' on NIC '$($plannedBridge.Nic)' via nmcli"
}
[void](Initialize-SudoCache -Reasons $sudoReasons)

Write-Output "  Preflight OK -- proceeding unattended (no further prompts)."

# === Step 1: stop + remove any prior VM =====================================

Write-Output ""
Write-Output "=== Step 1: cleanup previous '$VMName' VM ==="

# Wipe any leftover host-proxy state BEFORE provisioning. Remove-HostProxy
# (not Clear-HostProxy) is the right model: a previous cycle's WinINet
# ProxyServer or HTTP_PROXY env var pointing at an IP that no longer hosts
# squid is junk we want gone, not state we want to preserve. The earlier
# snapshot/restore design captured whatever was on disk at first promotion
# and faithfully reinstated it on each Stop, leaking stale IPs into every
# subsequent Test-CachingProxy probe. Symmetric with Stop-CachingProxy.ps1.
try {
    Import-Module (Join-Path $PSScriptRoot 'modules/Test.Host.psm1') -Force
    [void](Initialize-YurunaHost -RepoRoot (Split-Path -Parent $PSScriptRoot))
    [void](Remove-HostProxy -Confirm:$false)
} catch {
    Write-Warning "  Remove-HostProxy failed: $($_.Exception.Message). Cleanup will continue."
}
if ($IsMacOS) {
    # Tear down any leftover host-side TCP forwarders from the retired
    # shared-NAT path (forwarder.<port>.pid pwsh subprocesses under
    # $HOME/yuruna/image/squid-cache). With the bridged cache VM these
    # forwarders are no longer needed -- and if left running on
    # 0.0.0.0:3128 they would conflict with anyone who later sets
    # YURUNA_CACHING_PROXY_IP=<host-lan-ip> pointing back at this Mac.
    # No-op on a fresh install. Stop-CachingProxy.ps1 also calls this
    # symmetrically.
    try {
        Import-Module (Join-Path $PSScriptRoot 'modules/Test.Host.psm1') -Force
        [void](Initialize-YurunaHost -RepoRoot (Split-Path -Parent $PSScriptRoot))
        [void](Remove-PortMap -Confirm:$false)
    } catch {
        Write-Warning "  Remove-PortMap (legacy forwarder cleanup) failed: $($_.Exception.Message). Cleanup will continue."
    }
    # `utmctl status <name>` exits non-zero with "Virtual machine not found"
    # when the VM isn't registered — cheap probe, no need to parse `utmctl list`.
    & utmctl status $VMName 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Output "  Prior VM registered with UTM — stopping and deleting..."
        & utmctl stop $VMName 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        & utmctl delete $VMName 2>&1 | Out-Null
    } else {
        Write-Output "  No prior VM registered with UTM."
    }
    if (Test-Path $UtmDir) {
        Write-Output "  Removing stale bundle $UtmDir"
        Remove-Item -Recurse -Force $UtmDir
    }
} elseif ($IsWindows) {
    $existing = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Output "  Prior VM found (state: $($existing.State)) — stopping and removing..."
        Stop-VM -Name $VMName -Force -TurnOff -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Remove-VM -Name $VMName -Force
    } else {
        Write-Output "  No prior VM registered with Hyper-V."
    }
    $vmDir = Join-Path $downloadDir $VMName
    if (Test-Path $vmDir) {
        Write-Output "  Removing stale VM disk directory $vmDir"
        Remove-Item -Recurse -Force $vmDir
    }
} elseif ($IsLinux) {
    # `virsh dominfo <name>` exits non-zero with "Domain not found" when
    # the VM isn't defined -- cheap probe, no need to parse `virsh list`.
    # `--connect qemu:///system` matches the New-VM.ps1 it pairs with
    # (system-wide libvirt URI; the user is in the libvirt group per
    # install/ubuntu.kvm.sh).
    & virsh --connect qemu:///system dominfo $VMName 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Output "  Prior VM registered with libvirt — destroying and undefining..."
        # `destroy` is libvirt's force-stop (no graceful shutdown); we
        # are about to delete the disk anyway. `undefine --nvram` removes
        # the domain definition AND any per-domain NVRAM file (UEFI EFI
        # vars) -- without --nvram, undefine refuses to remove a domain
        # that has NVRAM and leaves the def in place.
        & virsh --connect qemu:///system destroy $VMName 2>&1 | Out-Null
        & virsh --connect qemu:///system undefine --nvram $VMName 2>&1 | Out-Null
    } else {
        Write-Output "  No prior VM registered with libvirt."
    }
    if (Test-Path $KvmVmDir) {
        Write-Output "  Removing stale VM disk directory $KvmVmDir"
        Remove-Item -Recurse -Force $KvmVmDir
    }

    # === Step 1.5: ensure the 'yuruna-external' libvirt bridge network ────
    # The cache VM is only useful to other LAN hosts when it has its own
    # LAN-routable DHCP lease. libvirt's NAT 'default' network keeps the
    # VM host-only (192.168.122/24, behind libvirt's masquerade), so we
    # promote to a bridged 'yuruna-external' network here. The helper is
    # idempotent: if the network already exists it just ensures it is
    # started + on autostart and returns.
    #
    # This runs UNATTENDED: New-YurunaExternalNetwork is called with
    # -Confirm:$false so its ShouldProcess gate never prompts. The
    # operator was already shown the full host-networking impact (brief
    # outage + rollback recipe) by Step 0's plan phase via
    # Get-YurunaExternalNetworkPlan, so there is nothing left to ask.
    #
    # YURUNA_EXTERNAL_BRIDGE_SKIP=1 short-circuits this -- useful for
    # the host-only path where the operator is fine with the cache VM
    # being reachable only from this host.
    Import-Module (Join-Path $RepoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1') -Force -DisableNameChecking
    if ($env:YURUNA_EXTERNAL_BRIDGE_SKIP -eq '1') {
        Write-Output ""
        Write-Output "=== Step 1.5: bridge auto-creation skipped (YURUNA_EXTERNAL_BRIDGE_SKIP=1) ==="
        Write-Output "  Cache VM will land on libvirt's NAT 'default' network (host-only)."
    } elseif ($plannedBridge -and -not $plannedBridge.CanBridge) {
        # Step 0's plan already determined a LAN-routable bridge is
        # impossible right now (no default route, Wi-Fi NIC, or -- most
        # importantly -- NetworkManager has crashed recently and re-trying
        # the nmcli build would just crash it again + raise another apport
        # dialog). Honor that plan: skip the attempt entirely rather than
        # re-running New-YurunaExternalNetwork only for its internal guard
        # to bail. The full reason was printed in Step 0.
        Write-Output ""
        Write-Output "=== Step 1.5: bridge step skipped (per Step 0 plan: $($plannedBridge.Action)) ==="
        Write-Output "  Cache VM will use libvirt's NAT 'default' network (host-only). Reason"
        Write-Output "  and remediation were printed in the Step 0 plan above."
    } else {
        Write-Output ""
        Write-Output "=== Step 1.5: ensure 'yuruna-external' libvirt bridge network ==="
        $extNet = New-YurunaExternalNetwork -Confirm:$false
        if ($extNet) {
            Write-Output "  libvirt network ready: $extNet (cache VM will get a LAN-routable IP)"
            # New-VM.ps1's Get-ExternalNetwork preferentially honors this
            # env var when picking which libvirt network to use; setting
            # it here removes ambiguity in case the operator has another
            # bridge defined that also passes the 'yuruna-external'
            # detection ordering.
            $env:YURUNA_EXTERNAL_NETWORK = $extNet
        } else {
            Write-Warning "  Could not provision 'yuruna-external'. Cache VM will fall back to NAT 'default' (host-only)."
            Write-Warning "  To use the cache from other LAN hosts you'll need to: define yuruna-external manually (see host/ubuntu.kvm/guest.squid-cache/README.md), or set YURUNA_EXTERNAL_BRIDGE_SKIP=1 to suppress this attempt next time."
        }
    }
}

# === Step 2: base image =====================================================

# Always defer to Get-Image.ps1 -- it owns the cache-vs-refetch decision
# via Test-DownloadAlreadyCurrent (4-line sentinel: filename + URL + byte
# count + Last-Modified). An earlier short-circuit here checked
# Test-Path $ImageFile and skipped Get-Image entirely if the file was on
# disk, which silently masked URL/version bumps (the noble->resolute
# regression where a 24.04 VHDX stayed in place after the script was
# updated to 26.04). Get-Image.ps1 prints its own multi-line "skipping
# download" block when the sentinel matches HEAD, so we don't lose the
# fast-path observability -- we just move the decision to the right
# script.
Write-Output ""
Write-Output "=== Step 2: base image (Get-Image.ps1 decides cache vs refetch) ==="
& $GetImageScript
if ($LASTEXITCODE -ne 0) {
    Write-Error "Get-Image.ps1 failed (exit $LASTEXITCODE)."
    exit 1
}
if (-not (Test-Path $ImageFile)) {
    Write-Error "Get-Image.ps1 exited 0 but '$ImageFile' is still missing."
    exit 1
}

# === Step 3: create the VM ==================================================

Write-Output ""
Write-Output "=== Step 3: create VM '$VMName' ==="
& $NewVMScript $VMName
if ($LASTEXITCODE -ne 0) {
    Write-Error "New-VM.ps1 failed (exit $LASTEXITCODE)."
    exit 1
}

# === Step 4: macOS — register with UTM and start ===========================
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
    Write-Output ""
    Write-Output "=== Step 4: register '$VMName' with UTM and start ==="
    if (-not (Test-Path $UtmDir)) {
        Write-Error "Expected bundle '$UtmDir' missing after New-VM.ps1 ran."
        exit 1
    }
    # `open -g -a UTM` launches UTM in background and imports the bundle.
    # utmctl has no 'import' verb — `open` is the only way to register a
    # freshly-built .utm bundle from the CLI.
    & open -g -a UTM $UtmDir
    if ($LASTEXITCODE -ne 0) {
        Write-Error "'open -g -a UTM $UtmDir' failed (exit $LASTEXITCODE)."
        exit 1
    }

    # UTM registers asynchronously after import — poll for up to 30 s.
    $registered = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        & utmctl status $VMName 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $registered = $true; break }
    }
    if (-not $registered) {
        Write-Error "UTM did not register '$VMName' within 30 s. Open UTM manually to continue."
        exit 1
    }
    # On a freshly-imported bundle, `utmctl start` can return 0 at the RPC
    # level while UTM is still finalizing bundle ingestion, and the start
    # request is silently dropped — the VM stays in 'stopped'. Verify the
    # transition by parsing `utmctl status` output and retry a few times.
    # `utmctl status` prints one of: started / paused / stopped / suspended.
    Write-Output "  Registered. Starting VM..."
    $started = $false
    for ($attempt = 1; $attempt -le 3 -and -not $started; $attempt++) {
        & utmctl start $VMName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Error "'utmctl start $VMName' failed (exit $LASTEXITCODE)."
            exit 1
        }
        # Poll up to 15 s for the VM to leave 'stopped'. A state of 'started'
        # (or any non-stopped/paused state) means the start actually took.
        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep -Seconds 1
            $state = (& utmctl status $VMName 2>&1 | Select-Object -First 1)
            if ($LASTEXITCODE -eq 0 -and $state -and "$state".Trim() -notmatch '^(stopped|paused)\s*$') {
                $started = $true
                break
            }
        }
        if (-not $started) {
            Write-Warning "  'utmctl start' attempt $attempt returned 0 but VM still reports '$state' — retrying."
        }
    }
    if (-not $started) {
        Write-Error "UTM did not transition '$VMName' out of 'stopped' after 3 start attempts. Open UTM manually and start the VM, then re-run."
        exit 1
    }

    # `utmctl ip-address` does not work for Apple Virtualization VMs
    # ("Operation not supported by the backend"). The cache VM is
    # bridged onto the host's LAN NIC (config.plist.template,
    # VZBridgedNetworkDeviceAttachment), so its DHCP lease lands on the
    # same /24 the host sits on. We identify OUR VM by the MAC the
    # bundle was built with (random per-bundle, written into
    # config.plist by guest.squid-cache/New-VM.ps1) and look its IP up
    # via the host's ARP table -- never by "first :3128 we find on the
    # LAN", which would happily lock onto a peer host's yuruna-caching-
    # proxy that DHCP'd before ours did. Matches the narrow
    # Test-CachingProxyAvailable contract: only caches we own.
    $httpPort = Get-CachingProxyPort -Scheme http
    Import-Module (Join-Path $RepoRoot 'test/modules/Test.Host.psm1') -Force
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

    # Pull OUR VM's MAC out of the bundle's config.plist. The bundle is
    # brand new (Step 3 just built it from scratch) so this is
    # unambiguously the MAC the cache VM will boot with. Normalize to
    # the form `arp -an` prints (lowercase, leading zero per octet
    # stripped, e.g. '0F' -> 'f') so the later table lookup matches
    # directly.
    $plistPath = Join-Path $UtmDir 'config.plist'
    $ourMacRaw = $null
    if (Test-Path -LiteralPath $plistPath) {
        $plistText = Get-Content -Raw -LiteralPath $plistPath
        if ($plistText -match '<key>MacAddress</key>\s*<string>([0-9A-Fa-f:]+)</string>') {
            $ourMacRaw = $matches[1]
        }
    }
    if (-not $ourMacRaw) {
        Write-Error "Could not extract MacAddress from $plistPath. Without the bundle's MAC we cannot distinguish our cache VM from any other squid on the LAN; refusing to guess."
        exit 1
    }
    $macNeedle = (($ourMacRaw -split ':') |
        ForEach-Object { ([Convert]::ToInt32($_, 16)).ToString('x') }) -join ':'

    Write-Output ""
    Write-Output "=== Step 5: wait for our cache VM (MAC $ourMacRaw) to DHCP on ${lanPrefix}0/24 and squid to listen on :${httpPort} (up to 15 min) ==="
    Write-Output "  (first boot = cloud-init installs squid + apache2 + squid-cgi,"
    Write-Output "   then pre-warms by pulling linux-firmware through the proxy)"
    Write-Output "  Cache VM is VZ-bridged to '${hostLanIp}'s NIC; IP is matched"
    Write-Output "  by MAC, so a peer host's cache on the same LAN cannot be"
    Write-Output "  misidentified as ours."
    $deadline = (Get-Date).AddMinutes(15)
    while ((Get-Date) -lt $deadline -and -not $cacheIp) {
        # Populate the host's ARP cache by ICMP-pinging the /24 in
        # parallel. ICMP triggers ARP resolve on every live LAN host;
        # the cache VM answers ICMP from cloud-init very early (long
        # before squid binds :3128), so our MAC appears in arp -an
        # within the first iteration on most boots. /sbin/ping with
        # -t 1 keeps the packet on the LAN (TTL 1); -W 200 caps the
        # per-host wait at 200 ms. ThrottleLimit 32 keeps a single
        # sweep around ~2 s on a typical home LAN.
        2..254 |
            Where-Object { "${lanPrefix}$_" -ne $hostLanIp } |
            ForEach-Object -Parallel {
                $c = "$using:lanPrefix$_"
                try { & /sbin/ping -c 1 -W 200 -t 1 $c *>$null } catch { Write-Verbose "ping $c failed: $($_.Exception.Message)" }
            } -ThrottleLimit 32 | Out-Null

        # Find OUR MAC in the host's ARP table. macOS arp prints e.g.
        # '? (192.168.7.93) at 4e:45:2e:88:60:33 on en0 ifscope ...'.
        $candidateIp = $null
        foreach ($line in (& /usr/sbin/arp -an 2>$null)) {
            if ($line -match '^\? \(([\d.]+)\) at (\S+)' -and $matches[2] -eq $macNeedle) {
                $candidateIp = $matches[1]
                break
            }
        }
        if ($candidateIp) {
            $tcp = New-Object System.Net.Sockets.TcpClient
            try {
                $async = $tcp.BeginConnect($candidateIp, $httpPort, $null, $null)
                if ($async.AsyncWaitHandle.WaitOne(500) -and $tcp.Connected) {
                    $cacheIp = $candidateIp
                    break
                }
            } catch {
                Write-Verbose "probe ${candidateIp}:${httpPort} failed: $($_.Exception.Message)"
            } finally { $tcp.Close() }
            Write-Verbose "Step 5: cache VM is at $candidateIp (MAC match) but squid is not yet listening on :${httpPort} -- continuing wait."
        }
        if (-not $cacheIp) { Start-Sleep -Seconds 5 }
    }
    if (-not $cacheIp) {
        Write-Warning "Our cache VM (MAC $ourMacRaw) did not appear in the host's ARP table on ${lanPrefix}0/24 with squid on :${httpPort} after 15 min."
        Write-Warning "Likely causes:"
        Write-Warning "  * Wi-Fi AP filtering the cache's locally-administered MAC -- switch to Ethernet or allow the new MAC."
        Write-Warning "  * cloud-init still installing squid (rare on first run; check progress via UTM window)."
        Write-Warning "  * LAN is not a single /24 (the discovery sweep assumes one)."
        Write-Warning "VM is still running -- log in through the UTM window (utmctl status $VMName) and run:"
        Write-Warning "  sudo grep -E 'E:|429 |Hash Sum|Failed to fetch|Unable to locate|Exit code' /var/log/cloud-init-output.log | head -40"
        Write-Warning "  ip -4 addr show           # verify the VM got a DHCP lease on the LAN"
    }

    # === Step 6: tear down legacy host-side forwarders ======================
    # With bridged networking the cache VM is reachable directly at its
    # LAN IP -- no host:port forwarder layer needed. Any leftover pwsh
    # forwarders from a prior shared-NAT cycle would now bind ports that
    # the operator expects to be free, and would tunnel to a stale IP.
    # Remove-PortMap clears every Yuruna-managed forwarder symmetrically
    # with Stop-CachingProxy.ps1; on a fresh install this is a no-op.
    if ($cacheIp) {
        Write-Output ""
        Write-Output "=== Step 6: tear down any legacy host-side forwarders (bridged cache is LAN-direct) ==="
        [void](Remove-PortMap -Confirm:$false)

        # Persist the cache VM's LAN IP so guest provisioners and the
        # status server's fast path don't have to re-discover it. The
        # host reaches the cache directly on the LAN (same /24); guest
        # provisioners base64-embed the CA cert by fetching it via
        # `curl http://<cacheIp>/yuruna-squid-ca.crt` from the host.
        #
        # Re-import Test.CachingProxy with -Global -Force *here*, even
        # though line 67 already did it once: Initialize-YurunaHost
        # (called in Step 5 via Test.Host.psm1) cascades into Yuruna.-
        # Host.psm1's nested non-global import of Test.CachingProxy.psm1
        # at line 36, and PowerShell's "one active version per module"
        # rule then evicts the script's view of Save-CachingProxyState.
        # Without this re-import the next line errors with "The term
        # 'Save-CachingProxyState' is not recognized." Same pattern is
        # used in Stop-CachingProxy.ps1 just above its Save call.
        Import-Module (Join-Path $PSScriptRoot 'modules/Test.CachingProxy.psm1') -Global -Force -Verbose:$false
        [void](Save-CachingProxyState -IpAddress $cacheIp -Confirm:$false)
    }
} elseif ($IsLinux) {
    # KVM/libvirt: guest.squid-cache/New-VM.ps1 already calls virt-install
    # with --import and blocks until the VM has an IP AND squid is
    # listening on :3128 (see host/ubuntu.kvm/guest.squid-cache/New-VM.ps1
    # for the wait loop). No separate "register + start" phase like UTM,
    # and no host-side discovery loop like Hyper-V -- by the time we
    # reach here the cache is up and reachable, we just need to re-query
    # the IP for the summary and persist it for downstream consumers.
    Write-Output ""
    Write-Output "=== Step 4: re-query cache VM IP for persistence + summary ==="
    Import-Module (Join-Path $RepoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1') -Force -DisableNameChecking
    # Get-VMIp probes virsh domifaddr in source order lease -> agent ->
    # arp, so a NAT 'default' VM (lease) and a 'yuruna-external' VM
    # (agent or arp) both resolve.
    $cacheIp = Get-VMIp -VMName $VMName
    if (-not $cacheIp) {
        Write-Warning "  Get-VMIp returned no IPv4 for '$VMName'. New-VM.ps1 reported the VM started, but discovery sources (lease/agent/arp) are silent. The VM is likely still warming up the guest agent -- retry Start-CachingProxy.ps1 in 30 s, or run 'virsh -c qemu:///system domifaddr --source agent $VMName' to inspect."
    } else {
        Write-Output "  Cache VM IP: $cacheIp"
        # Persist for guest provisioners + status server fast path.
        # Re-import Test.CachingProxy -Global -Force here for the same
        # reason the macOS/Windows branches do (Initialize-YurunaHost
        # via Test.Host.psm1 nested-imports Test.CachingProxy without
        # -Global, which evicts the script's view of the exports).
        Import-Module (Join-Path $PSScriptRoot 'modules/Test.CachingProxy.psm1') -Global -Force -Verbose:$false
        [void](Save-CachingProxyState -IpAddress $cacheIp -Confirm:$false)
    }

    # LAN exposure. On a bridged 'yuruna-external' (or any non-default)
    # network the VM has its own LAN IP and remote consumers reach it
    # directly at $cacheIp. On the NAT 'default' network the VM is
    # host-only, so Add-PortMap installs systemd socket-activated
    # forwarders (systemd-socket-proxyd) and LAN clients reach the cache
    # at the HOST's LAN IP. See Add-PortMap in host/ubuntu.kvm/modules/
    # Yuruna.Host.psm1 for why socket forwarding rather than nftables
    # DNAT: libvirt's own forward chain rejects DNAT'd inbound to its
    # NAT guests, and overriding that is firewall-backend-specific.
    if ($cacheIp) {
        Import-Module (Join-Path $RepoRoot 'test/modules/Test.Host.psm1') -Force
        [void](Initialize-YurunaHost -RepoRoot $RepoRoot)
        if (Test-CacheVMOnExternalNetwork -VMName $VMName) {
            Write-Output "  Cache VM is on a bridged libvirt network (LAN-direct, real client IPs preserved). Skipping host portproxy."
            [void](Remove-PortMap -Confirm:$false)
            $cacheLanIp = $cacheIp
        } else {
            $hPort  = Get-CachingProxyPort -Scheme http
            $hsPort = Get-CachingProxyPort -Scheme https
            # Port set: squid (3128 / 3129), Apache /cgi-bin/cachemgr.cgi
            # + CA cert (80), Grafana (3000), caching-proxy-parser (9302),
            # SSH remap 8022 -> 22 for jump-host access.
            $cacheForwarded = [bool](Add-PortMap -VMIp $cacheIp `
                    -Port @(80, 3000, 9302, $hPort, $hsPort) `
                    -PortRemap @{8022 = 22} -Confirm:$false)
            if ($cacheForwarded) {
                $cacheLanIp = Get-BestHostIp
                Write-Output "  Cache exposed to the LAN at the host IP ($cacheLanIp) via systemd socket forwarders."
            } else {
                Write-Warning "  Port-forwarder setup failed -- cache is reachable from THIS host only (at $cacheIp)."
            }
        }
    }
} elseif ($IsWindows) {
    # Use the same KVP+ARP+:3128-probe discovery the guest consumers
    # (guest.ubuntu.server/desktop/New-VM.ps1) use, so the summary line
    # below matches what a subsequent guest install will actually see.
    # Prior code used KVP-only and printed "(discovery failed)" whenever
    # hv_kvp_daemon wasn't warm, even though the inner New-VM.ps1's ARP
    # path had already found the cache and the cache was serving :3128.
    $vmCommon = Join-Path $RepoRoot "host/windows.hyper-v/modules/Yuruna.Host.psm1"
    Import-Module $vmCommon -Force
    $CachingProxyUrl = Get-WorkingCachingProxyUrl -VMName $VMName
    if ($CachingProxyUrl -match '^http://([0-9.]+):') { $cacheIp = $matches[1] }

    # Persist the cache VM's IP so Test-CachingProxyAvailable's state-
    # file-only discovery path can find it next call. Mirrors the macOS
    # branch above. Re-import Test.CachingProxy -Global -Force here to
    # work around the same nested-import shadowing trap documented in
    # the macOS branch comment.
    if ($cacheIp) {
        Import-Module (Join-Path $PSScriptRoot 'modules/Test.CachingProxy.psm1') -Global -Force -Verbose:$false
        [void](Save-CachingProxyState -IpAddress $cacheIp -Confirm:$false)
    }

    # Expose the cache VM's ports to the host's LAN so remote clients can
    # reach squid (:3128 / :3129), Apache (:80 serving yuruna-squid-ca.crt),
    # and Grafana (:3000). Local guests on the Default Switch already reach
    # the VM directly (172.25.x.x NAT subnet is visible from the host and
    # from every Hyper-V guest on that switch), so this portproxy adds LAN
    # exposure without changing the local-guest path — those still target
    # the VM's private IP. The port list matches Invoke-TestRunner.ps1's
    # Add-CachingProxyPortMap call; mismatched lists fight each other because
    # the function runs Clear-AllCachingProxyPortMapping first. Requires
    # elevation; Add-CachingProxyPortMap warns and no-ops otherwise.
    if ($cacheIp) {
        Import-Module (Join-Path $RepoRoot 'test/modules/Test.Host.psm1') -Force
        [void](Initialize-YurunaHost -RepoRoot $RepoRoot)
        # If the cache VM is on an External vSwitch, it has its own LAN
        # IP via DHCP and remote clients reach it directly -- squid sees
        # real client IPs at TCP level, no host-side forwarder needed.
        # Tear down any leftover netsh portproxy / firewall rules from
        # a prior Default-Switch cycle so they can't NAT-rewrite traffic
        # to a stale host:port path. On the Default-Switch fallback,
        # set up netsh portproxy as before -- kernel-mode IP Helper is
        # the only LAN-reachable path on this Hyper-V host (the user-
        # mode pwsh forwarder is silently dropped by Defender / EDR /
        # WFP regardless of rules -- see docs/caching.md).
        if (Test-CacheVMOnExternalNetwork -VMName $VMName) {
            Write-Output "  Cache VM is on an External vSwitch (LAN-direct, real client IPs preserved). Skipping host portproxy."
            [void](Remove-PortMap -Confirm:$false)
        } else {
            $hPort  = Get-CachingProxyPort -Scheme http
            $hsPort = Get-CachingProxyPort -Scheme https
            # 9302: caching-proxy-parser endpoint (see
            # test/extension/caching-proxy-parser/). Reached directly via
            # netsh portproxy along with squid/Apache/Grafana.
            [void](Add-PortMap -VMIp $cacheIp `
                    -Port @(80, 3000, 9302, $hPort, $hsPort) `
                    -PortRemap @{8022 = 22} -Confirm:$false)
        }
    }
}

# === Final summary ==========================================================
# The yuruna user's password is NOT printed in the banner -- the value
# already lives in <track>/yuruna-caching-proxy.yml (written by squid-
# cache's New-VM.ps1) and the vault. Reading it again here just to echo
# to the terminal leaks the secret into operator transcripts / scrollback
# for no real gain. Operators who need it run:
#     yq .password $PasswordFile        (or: Get-Content $PasswordFile)

Write-Output ""
Write-Output "================================================================="
Write-Output "=== squid-cache is READY ==="
Write-Output "================================================================="
Write-Output "  VM name:     $VMName"
if ($cacheIp) {
    Write-Output "  VM IP:       $cacheIp"
    $summaryHttpPort  = Get-CachingProxyPort -Scheme http
    $summaryHttpsPort = Get-CachingProxyPort -Scheme https
    if ($IsMacOS) {
        # Cache VM is VZ-bridged to the host's NIC -- it has its own LAN
        # DHCP IP and every consumer (host, install VMs on shared NAT,
        # remote LAN hosts) reaches it at $cacheIp:<port> directly. No
        # host-side forwarder layer, no VZ-gateway indirection. Mirrors
        # the Hyper-V Yuruna-External vSwitch path's summary lines.
        Write-Output "  Proxy URL:   http://${cacheIp}:${summaryHttpPort}"
        Write-Output "  HTTPS bump:  http://${cacheIp}:${summaryHttpsPort}  (squid SSL-bump listener)"
        Write-Output "  Grafana:     http://${cacheIp}:3000  (anonymous Viewer)"
        Write-Output "  Recent 100:  http://${cacheIp}:9302/  (in-memory live tail)"
        Write-Output "  cachemgr:    http://${cacheIp}/cgi-bin/cachemgr.cgi"
        Write-Output "  CA cert:     http://${cacheIp}/yuruna-squid-ca.crt  (trust to enable :${summaryHttpsPort} HTTPS caching)"
        Write-Output ""
        Write-Output "  Remote LAN clients (other hosts on this network):"
        Write-Output "    Set on the remote host BEFORE Invoke-TestRunner.ps1:"
        Write-Output "      export YURUNA_CACHING_PROXY_IP=${cacheIp}"
        Write-Output "      (or on Windows: setx YURUNA_CACHING_PROXY_IP ${cacheIp})"
        Write-Output "    Quick check from the remote host:"
        Write-Output "      curl -x http://${cacheIp}:${summaryHttpPort} http://cdimage.ubuntu.com/ -I"
    } else {
        # Linux / Windows. $cacheLanIp is the address LAN clients use:
        # the VM's own IP when it is on a bridge / external vSwitch, or
        # the HOST's LAN IP when the cache is NAT'd and exposed via the
        # systemd socket forwarders. $cacheForwarded is only ever true on
        # the Linux NAT path.
        $lanIp = if ($cacheLanIp) { $cacheLanIp } else { $cacheIp }
        if ($cacheForwarded -and $cacheLanIp -ne $cacheIp) {
            Write-Output "  LAN access:  via host $cacheLanIp -- the cache VM is NAT'd at $cacheIp and"
            Write-Output "               the host forwards these ports to it (systemd socket-proxy)."
        }
        Write-Output "  Proxy URL:   http://${lanIp}:${summaryHttpPort}"
        Write-Output "  Grafana:     http://${lanIp}:3000  (anonymous Viewer)"
        Write-Output "  Recent 100:  http://${lanIp}:9302/  (in-memory live tail)"
        Write-Output "  cachemgr:    http://${lanIp}/cgi-bin/cachemgr.cgi"
        if ($cacheForwarded -and $cacheLanIp -ne $cacheIp) {
            Write-Output ""
            Write-Output "  Remote LAN clients (other hosts on this network):"
            Write-Output "    export YURUNA_CACHING_PROXY_IP=${lanIp}    # before Invoke-TestRunner.ps1"
            Write-Output "    quick check:  curl -x http://${lanIp}:${summaryHttpPort} http://cdimage.ubuntu.com/ -I"
        }
    }
} else {
    Write-Output "  IP address:  (discovery failed — see warnings above)"
}
Write-Output ""
Write-Output "  SSH / console login:"
Write-Output "    user:     yuruna"
Write-Output "    password: (saved at $PasswordFile)"
if ($cacheForwarded -and $cacheLanIp -and $cacheLanIp -ne $cacheIp) {
    # Linux NAT path: SSH reaches the cache via the host's 8022 -> 22
    # forwarder, not the VM's own (host-only) IP.
    Write-Output "    direct:   ssh -p 8022 yuruna@${cacheLanIp}   (host forwards :8022 -> VM :22)"
} elseif ($cacheIp) {
    # macOS bridged + Hyper-V External-vSwitch + Linux bridged: the cache
    # VM has its own LAN IP, so direct SSH from anywhere on the LAN works.
    Write-Output "    direct:   ssh yuruna@${cacheIp}"
}
Write-Output "================================================================="
