<#PSScriptInfo
.VERSION 2026.08.05
.GUID 42f4e5f6-a7b8-4c9d-0123-4e5f6a7b8c81
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
    Creates the Yuruna stash service VM on Ubuntu KVM (libvirt).

.DESCRIPTION
    Builds a libvirt VM that boots the Ubuntu 26.04 LTS cloud image
    for the stash-service daemon (SCP receiver + SQLite metadata index).
    Cloud-init mounts the stash share, fetches the framework, and runs the
    bring-up script which builds + launches the daemon under systemd.

    See https://yuruna.link/stash-guide for the stash user guide.

.PARAMETER VMName
    libvirt domain name. Default: yuruna-stash-service.
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = 'yuruna-stash-service'
)

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Error "Invalid VMName '$VMName'. Only alphanumerics, dots, hyphens, underscores."
    exit 1
}
if (-not $IsLinux) {
    Write-Error "host/ubuntu.kvm/guest.stash-service/New-VM.ps1 only runs on Linux."
    exit 1
}

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- REGION: libvirt-qemu search ACL on $HOME (self-heal)
# Self-heal libvirt-qemu's search ACL on $HOME (Ubuntu 24.04+ default 0750).
if (Get-Command -Name 'setfacl' -ErrorAction SilentlyContinue) {
    & getent passwd libvirt-qemu *>$null
    if ($LASTEXITCODE -eq 0) {
        & setfacl -m 'u:libvirt-qemu:--x' $HOME 2>$null
    }
}

# --- REGION: Seek the base image
# One cloud image backs every extension service on this host; this VM grows
# its own copy below (host/modules/Yuruna.Image.psm1).
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules/Yuruna.Image.psm1') -Force
$baseImageFile = (Get-UbuntuExtensionImageInfo -HostType 'ubuntu.kvm').BaseImageFile

if (-not (Test-Path -LiteralPath $baseImageFile)) {
    $getImageScript = Join-Path $PSScriptRoot 'Get-Image.ps1'
    if (Test-Path -LiteralPath $getImageScript) {
        Write-Output "Base image missing: $baseImageFile"
        Write-Output "Auto-running $getImageScript to fetch it..."
        & pwsh -NoProfile -File $getImageScript
        $getImageExit = $LASTEXITCODE
        if ($getImageExit -ne 0) {
            Write-Error "Auto Get-Image.ps1 exited $getImageExit. Cannot create VM."
            exit 1
        }
    }
    if (-not (Test-Path -LiteralPath $baseImageFile)) {
        Write-Error "Base image not found at '$baseImageFile' after auto Get-Image. Run Get-Image.ps1 manually."
        exit 1
    }
}

Write-Output "Creating VM '$VMName' using image: $baseImageFile"
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))
Import-Module (Join-Path $repoRoot 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

# --- REGION: Per-VM directory + disk
$vmDir   = Join-Path $HOME "yuruna/vms/$VMName"
$diskImg = Join-Path $vmDir "$VMName.qcow2"
$seedImg = Join-Path $vmDir 'seed.iso'
New-Item -ItemType Directory -Force -Path $vmDir | Out-Null

# --- REGION: Remove existing VM
$virshUri = 'qemu:///system'
$destroyOut = & virsh --connect $virshUri destroy $VMName 2>&1
Write-Verbose "virsh destroy '$VMName' exit=$LASTEXITCODE output='$($destroyOut -join '; ')'"
# Snapshot metadata, checkpoint metadata and a managed-save image each
# pin the domain: undefine refuses ("cannot delete inactive domain with
# N snapshots") unless asked to drop them, and the re-creation below
# then fails with "domain already defined". A guest workload that takes
# a disk snapshot is routine, so clear every kind of metadata here.
$undefineOut = & virsh --connect $virshUri undefine --nvram --managed-save `
    --snapshots-metadata --checkpoints-metadata $VMName 2>&1
Write-Verbose "virsh undefine '$VMName' exit=$LASTEXITCODE output='$($undefineOut -join '; ')'"
$stillDefined = & virsh --connect $virshUri list --all --name 2>$null |
    Where-Object { $_.Trim() -eq $VMName }
if ($stillDefined) {
    $dominfo = (& virsh --connect $virshUri dominfo $VMName 2>&1 | Out-String).Trim()
    throw "virsh destroy + undefine left '$VMName' defined; aborting before re-creation.`ndominfo:`n$dominfo"
}

# --- REGION: Copy base image -> per-VM disk
if (Test-Path -LiteralPath $diskImg) { Remove-Item -Force -LiteralPath $diskImg }
Write-Output "Copying base image to per-VM disk (sparse copy)..."
& /bin/cp --sparse=always -- $baseImageFile $diskImg
if ($LASTEXITCODE -ne 0) {
    Write-Error "cp --sparse=always failed copying $baseImageFile -> $diskImg"
    exit 1
}

# --- REGION: Grow the per-VM disk to 256 GB
# Apparent size only: qcow2 grows on write, so the host gives up nothing
# until the stash daemon actually stores that much.
if (-not (Expand-ExtensionVmDisk -Path $diskImg -SizeBytes 256GB -Format 'qcow2')) {
    Write-Warning "Resize failed -- continuing with the base cloud-image capacity."
    Write-Warning "Resize manually with: qemu-img resize -f qcow2 '$diskImg' 256G"
}

# --- REGION: Yuruna harness SSH key + vault password
Import-Module (Join-Path $repoRoot 'test/modules/Test.Ssh.psm1')       -Force -DisableNameChecking
Import-Module (Join-Path $repoRoot 'test/modules/Test.Extension.psm1') -Global -Force -Verbose:$false
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error "Get-YurunaSshPublicKey returned empty."; exit 1 }
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$AdminPassword = Get-Password -Username 'stash-admin'
if (-not $AdminPassword) { Write-Error "Get-Password returned empty for 'stash-admin'."; exit 1 }
Write-Output "Password came from authentication mechanism: $_authActiveName"
Write-Output "See configuration at: $(Resolve-ExtensionAreaDir -Area 'authentication')"

# --- REGION: Render user-data / meta-data
$baseUserData     = Join-Path $repoRoot 'host/vmconfig/stash-service.base.user-data'
$overlayUserData  = Join-Path $repoRoot 'host/vmconfig/stash-service.kvm.overlay.yml'
$metaDataTemplate = Join-Path $repoRoot 'host/vmconfig/stash-service.meta-data'
foreach ($f in @($baseUserData, $overlayUserData, $metaDataTemplate)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Error "Template missing: $f"
        exit 1
    }
}
# --- REGION: Pick libvirt network (BEFORE building user-data)
# The baked share + source coordinates depend on whether this is NAT
# 'default' (host = libvirt gateway) or bridged 'yuruna-external' (host =
# LAN IP), so resolve the network first. Resolve-GuestHostBinding returns the
# matched pair -- the same helper the cache and the install guests use, so
# every VM on this host lands on one network and the baked host address is
# always routable from it.
Import-Module (Join-Path (Split-Path -Parent $ScriptDir) 'modules/Yuruna.Host.psm1') -Force -DisableNameChecking
$guestBinding = Resolve-GuestHostBinding
$networkName  = $guestBinding.NetworkName
if (-not $networkName) {
    Write-Error "No libvirt network defined. Run 'virsh net-start default' to enable the NAT default, or define 'yuruna-external' (see README.md) for LAN-bridged access."
    exit 1
}
if ($networkName -eq 'default') {
    Write-Warning "Using libvirt NAT 'default' network (192.168.122/24). The stash-service VM is reachable from this host only and the NAS likely isn't routable; define a bridged 'yuruna-external' libvirt network for LAN + NAS access."
} else {
    Write-Output "Using libvirt network: $networkName (stash-service VM will get a LAN-routable IP)"

    # --- REGION: bridge-uplink preflight (fail fast, not a silent 20-min wait)
    # A libvirt <forward mode='bridge'/> network stays ACTIVE even after its host
    # bridge loses its physical uplink (only guest tap ports remain): virsh reports
    # the network as fine, the guest attaches and boots, but its DHCP request has no
    # path to the LAN's DHCP server -- so it NEVER leases, cloud-init stalls with no
    # network (disk growth freezes), and qemu-guest-agent, itself installed over that
    # network, never comes up. The IP wait below would then burn its whole budget for
    # nothing. Detect it HERE and stop with the remediation. The bridge lifecycle is
    # owned by test/Start-CachingProxyServiceVM.ps1 (New-YurunaExternalNetwork self-heals or
    # rebuilds the uplink); this guest script only consumes the network, so it must
    # not flap host networking itself -- it points at the owner instead. Same brif
    # check as Test-YurunaBridgeHasUplink; inlined via direct virsh (the module's
    # bridge probes are internal, not exported). Best-effort: any probe gap leaves
    # the build to proceed rather than false-fail.
    $netXml = (& virsh --connect $virshUri net-dumpxml $networkName 2>$null) -join "`n"
    if ($netXml -match "<forward\s+mode='bridge'" -and $netXml -match "<bridge\s+name='([^']+)'") {
        $extBridge = $Matches[1]
        $brifDir   = "/sys/class/net/$extBridge/brif"
        $physPorts = if (Test-Path -LiteralPath $brifDir) {
            @(Get-ChildItem -LiteralPath $brifDir -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch '^(vnet|tap)\d+$' })
        } else { @() }
        if ($physPorts.Count -eq 0) {
            Write-Error @"

libvirt network '$networkName' is active, but its host bridge '$extBridge' has NO
physical LAN uplink (only guest tap ports are attached). A guest on it can never
obtain a DHCP lease -- this is the silent 20-minute 'no IP' wait, not a slow boot.

Heal the bridge, then re-run this script:
    test/Start-CachingProxyServiceVM.ps1
(it owns the 'yuruna-external' bridge lifecycle and self-heals or rebuilds the
uplink NIC). Nothing was created; the stash-service VM was not started.
"@
            exit 1
        }
    }
}

# Host coordinates (status service, for the in-VM source fetch) + stash storage
# coordinates (the share), baked into the seed. The host address came from the
# same binding as the network above ($env:YURUNA_GUEST_REACHABLE_HOST_IP wins
# there); empty means the guest falls back to the public github mirror.
Import-Module (Join-Path $repoRoot 'test/modules/Test.PoolStorage.psm1')  -Global -Force
Import-Module (Join-Path $repoRoot 'test/modules/Test.YurunaDir.psm1')    -Global -Force
Import-Module (Join-Path $repoRoot 'test/modules/Test.Config.psm1')       -Global -Force
Import-Module (Join-Path $repoRoot 'test/modules/Test.CachingProxyService.psm1') -Global -Force
$YurunaHostIp = $guestBinding.HostIp
$YurunaHostPort = '8080'
$YurunaTestConfig = Join-Path $repoRoot 'test/test.config.yml'
$tc = $null
if (Test-Path -LiteralPath $YurunaTestConfig) {
    try { $tc = Read-TestConfig -Path $YurunaTestConfig } catch { Write-Verbose "test.config.yml read: $($_.Exception.Message)" }
    if ($tc -and $tc.statusService -and $tc.statusService.port) { $YurunaHostPort = "$($tc.statusService.port)" }
}
$ystashNas = Get-YurunaStashSeedValue -Config $tc -GuestReachableAddress $YurunaHostIp
# Pool-aggregator service base URL for the guest's presence beacon + remote-host
# resolution; '' (no caching-proxy service known) leaves those features off in-guest.
# Wait for the aggregator BEFORE resolving: whatever is resolved here is baked
# into the seed once and never re-resolved in-guest, so an empty value taken
# while the aggregator is still compiling leaves the beacon permanently off --
# the service serves correctly and simply never appears on the dashboard.
# Returns $false (rather than throwing) when there is no proxy to wait for or
# the budget expires; the seed then carries '' exactly as it did before.
$null = Wait-YurunaAggregatorReady
$aggregatorSeedUrl = Get-PoolAggregatorServiceSeedUrl

# Render user-data from the shared base + KVM overlay (host/vmconfig/
# stash-service.*). New-CloudInitUserData resolves placeholders with literal
# .Replace(), so values carrying regex-special chars are safe.
Import-Module (Join-Path $repoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force
$userData = New-CloudInitUserData `
    -BasePath    $baseUserData `
    -OverlayPath $overlayUserData `
    -RepoRoot    $repoRoot `
    -Replacement @{
        SSH_AUTHORIZED_KEY_PLACEHOLDER = $SshAuthorizedKey
        PASSWORD_PLACEHOLDER           = $AdminPassword
        YURUNA_STATUS_SERVICE_IP_PLACEHOLDER     = $YurunaHostIp
        YURUNA_STATUS_SERVICE_PORT_PLACEHOLDER   = $YurunaHostPort
        YSTASH_NAS_NETWORK_PATH_PLACEHOLDER  = $ystashNas.NetworkPath
        YSTASH_NAS_NETWORK_IP_PLACEHOLDER    = $ystashNas.NetworkIp
        YSTASH_NAS_NETWORK_USER_PLACEHOLDER  = $ystashNas.NetworkUser
        YSTASH_NAS_PASSWORD_PLACEHOLDER      = $ystashNas.Password
        YSTASH_NAS_HOST_ID_PLACEHOLDER       = $ystashNas.HostId
        YURUNA_AGGREGATOR_URL_PLACEHOLDER    = $aggregatorSeedUrl
    } -Confirm:$false
$metaData = (Get-Content -Raw -LiteralPath $metaDataTemplate)

$seedDir = Join-Path $vmDir 'seed.src'
New-Item -ItemType Directory -Force -Path $seedDir | Out-Null
Set-Content -LiteralPath (Join-Path $seedDir 'user-data') -Value $userData -NoNewline
Set-Content -LiteralPath (Join-Path $seedDir 'meta-data') -Value $metaData -NoNewline
# network-config, on the same seed: it pins the guest DHCP client identity to
# the interface MAC. Without it the guest identifies itself by a
# machine-id-derived DUID, which cloud-init changes mid-boot, so the DHCP server
# sees a new client and leases a different address -- and every host-side
# artifact aimed at the first address (port-forwarder, readiness probe,
# published URL) is left pointing at one the guest abandoned.
Copy-Item -Path (Join-Path $repoRoot 'host/vmconfig/extension-service.network-config') `
    -Destination (Join-Path $seedDir 'network-config')

# --- REGION: Generate cloud-init seed ISO
& genisoimage -output $seedImg -volid cidata -joliet -rock `
    (Join-Path $seedDir 'user-data') (Join-Path $seedDir 'meta-data') `
    (Join-Path $seedDir 'network-config') 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "genisoimage failed (exit $LASTEXITCODE)"
    exit 1
}

Write-Output ""
Write-Output "== stash-service console/SSH login (available NOW) =="
Write-Output "  user:     stash-admin"
Write-Output "  password: (in authentication vault under 'stash-admin')"
Write-Output "  If the wait below stalls or fails, open"
Write-Output "    virt-viewer --connect $virshUri $VMName"
Write-Output "  and log in with the credentials above to inspect cloud-init state."
Write-Output ""

# --- REGION: virt-install
$arch = (& uname -m).Trim()
$osVariant = 'linux2022'
$osList = & virt-install --osinfo list 2>$null
if ($LASTEXITCODE -eq 0) {
    $canonicalIds = @($osList | ForEach-Object {
        $first = ("$_".Trim() -split '[\s,]', 2)[0]
        ($first -replace ',$', '').Trim()
    } | Where-Object { $_ })
    # Ubuntu 26.04 may not be in the host's osinfo-db yet; fall back through
    # ubuntu24.04 -> ubuntu22.04 -> linux2022 generic.
    foreach ($candidate in @('ubuntu26.04', 'ubuntu24.04', 'ubuntu22.04')) {
        if ($canonicalIds -contains $candidate) { $osVariant = $candidate; break }
    }
    if ($osVariant -eq 'linux2022') {
        Write-Verbose "osinfo-db has no 'ubuntu26.04'/'ubuntu24.04'/'ubuntu22.04' entry; using 'linux2022' generic variant."
    }
}

# 4 GB RAM, 4 vCPU. Sized for the SCP receive + SQLite metadata writer
# + in-VM UI, none of which holds a large resident working set: the transfers
# stream to disk rather than buffering whole artifacts. One baseline across all
# three extension VMs. The domain has no balloon target below this, so the whole
# amount stays committed on the host -- the extension VMs share one machine with
# the cache VM on a standalone host.
# --- REGION: https://yuruna.link/definition#defining-the-vm-core-count-policy
$hostCores = [int](& nproc --all)
if ($hostCores -lt 4) {
    Write-Error "Host has $hostCores cores; Yuruna requires at least 4. See https://yuruna.link/definition#defining-the-vm-core-count-policy"
    exit 1
}
$vmCores = [math]::Max(4, [math]::Floor($hostCores / 2))

$installArgs = @(
    '--connect',    $virshUri,
    '--name',       $VMName,
    '--memory',     '4096',
    '--vcpus',      "$vmCores",
    '--cpu',        'host-passthrough',
    '--os-variant', $osVariant,
    '--disk',       "path=$diskImg,format=qcow2,bus=virtio",
    '--disk',       "path=$seedImg,device=cdrom",
    '--network',    "network=$networkName,model=virtio",
    '--graphics',   'vnc,listen=127.0.0.1',
    '--channel',    'unix,target_type=virtio,name=org.qemu.guest_agent.0',
    '--events',     'on_reboot=restart',
    '--noautoconsole',
    '--import'
)
if ($arch -eq 'aarch64') {
    $installArgs += @('--machine', 'virt', '--boot', 'uefi')
}

Write-Verbose "virt-install $($installArgs -join ' ')"
$virtInstallOutput = & virt-install @installArgs 2>&1
$virtInstallExit = $LASTEXITCODE
$virtInstallOutput | ForEach-Object { Write-Verbose "$_" }
if ($virtInstallExit -ne 0) {
    $virtInstallOutput | ForEach-Object { Write-Output "$_" }
    Write-Error "virt-install failed (exit $virtInstallExit)"
    exit 1
}

Remove-Item -LiteralPath $seedDir -Recurse -Force -ErrorAction SilentlyContinue

# --- REGION: Wait for VM IP
# On the bridged 'yuruna-external' network the host is NOT the DHCP server, so
# `virsh domifaddr` (default --source lease) returns nothing and the address is
# reported by qemu-guest-agent (--source agent), which the guest installs in its
# package phase. ARP (--source arp) covers the window before the agent is up,
# but only answers once the guest has sent this host a packet. So the budget has
# to cover a first-boot apt run, not just DHCP.
Write-Output "Waiting for VM to obtain an IP address..."
Write-Output "  (cloud-init brings up networking, then installs packages -- on a"
Write-Output "   first boot over a slow mirror this can take several minutes)"

$dockIp = $null
$maxIterations = 240  # 240 * 5s = 20 minutes
$startTime = Get-Date
$baselineSizeMB = [math]::Round((Get-Item $diskImg).Length / 1MB, 0)
# Plain Write-Output progress -- see feedback_pwsh_linux_write_progress_setcursor.md
# for why we don't use Write-Progress on pwsh-on-Linux.

for ($i = 0; $i -lt $maxIterations; $i++) {
    $dockIp = Get-VMIp -VMName $VMName
    if ($dockIp) { break }
    Start-Sleep -Seconds 5

    if (($i % 6) -eq 5) {
        $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
        $sizeMB  = [math]::Round((Get-Item $diskImg).Length / 1MB, 0)
        $deltaMB = $sizeMB - $baselineSizeMB
        $min     = [int][math]::Floor($elapsed / 60)
        $sec     = [int]($elapsed % 60)
        $totalMinutes = [int][math]::Floor($maxIterations * 5 / 60)
        Write-Output ("  [{0:D2}m{1:D2}s / {2}m] still waiting for IP -- qcow2 {3} MB (+{4} MB since boot)" -f $min, $sec, $totalMinutes, $sizeMB, $deltaMB)
    }
}

if (-not $dockIp) {
    # Dump what each discovery source actually said. "No IP" has three very
    # different causes -- the guest never got a lease, the guest has a lease the
    # host cannot observe, or the domain died -- and only the raw per-source
    # output separates them.
    Write-Output ""
    Write-Output "Address discovery, per source:"
    Write-Output "  domain state: $((& virsh --connect $virshUri domstate $VMName 2>&1 | Out-String).Trim())"
    foreach ($src in @('lease', 'agent', 'arp')) {
        $probe = (& virsh --connect $virshUri domifaddr $VMName --source $src 2>&1 | Out-String).Trim()
        if (-not $probe) { $probe = '(empty)' }
        Write-Output "  --source ${src}: $($probe -replace "`r?`n", ' | ')"
    }
    Write-Error @"

stash-service VM '$VMName' did not obtain an IP address within 20 minutes
(network '$networkName'; sources lease, agent, arp all returned empty).

  * 'agent' says the agent is not connected -> the guest is still in its package
    phase (or apt failed), so qemu-guest-agent has not started yet. The console
    log below shows where cloud-init is.
  * All three empty AND the VM is on a bridged network whose uplink is Wi-Fi:
    some access points refuse to forward the guest's DHCP request (MAC-based AP
    isolation). Use a wired uplink, or undefine 'yuruna-external' to fall back
    to the NAT 'default' network.

Accessing the VM for debugging:
  * Console:  virt-viewer --connect $virshUri $VMName
              user: stash-admin  (password in authentication vault)
              then: cloud-init status --long; ip -4 addr
"@
    exit 1
}

Write-Output ""
Write-Output "== stash-service VM is READY =="
Write-Output "  VM:       $VMName"
Write-Output "  IP:       $dockIp"
Write-Output "  Network:  $networkName"
Write-Output "  SSH:      ssh stash-admin@$dockIp  (harness key authorized)"
Write-Output "  Console:  virt-viewer --connect $virshUri $VMName"
Write-Output ""
Write-Output "Cloud-init mounts the stash share, fetches the framework, and runs the"
Write-Output "bring-up script. Once it finishes, the stash daemon owns :22 (the OS"
Write-Output "sshd is disabled), so reach it with scp:  scp ./file user@$dockIp`:/scratch"
Write-Output "Watch progress:  ssh stash-admin@$dockIp 'sudo tail -f /var/log/cloud-init-output.log'"
Write-Output "(the log is root-only; stash-admin has NOPASSWD sudo, so 'sudo tail' works over the harness key)"
Write-Output "(harness key authorized until the daemon takes over :22). See"
Write-Output "https://yuruna.link/stash-guide."
exit 0
