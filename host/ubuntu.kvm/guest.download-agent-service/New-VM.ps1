<#PSScriptInfo
.VERSION 2026.08.04
.GUID 42415d43-f59b-4fe5-bf94-4151fb133409
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna download agent service extension service
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
    Creates the Yuruna download-agent service VM on Ubuntu KVM (libvirt).

.DESCRIPTION
    Builds a libvirt VM that boots the Ubuntu 26.04 LTS cloud image
    for the download-agent-service daemon (operator UI + API over the shared
    download pool on the pool NAS). Cloud-init fetches the framework and
    runs the bring-up script which builds the daemon, CIFS-mounts the pool
    NAS that holds the pool, and launches it under systemd.

    See https://yuruna.link/download-agent-service for the full specification.

.PARAMETER VMName
    libvirt domain name. Default: yuruna-download-agent-service.
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = 'yuruna-download-agent-service'
)

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Error "Invalid VMName '$VMName'. Only alphanumerics, dots, hyphens, underscores."
    exit 1
}
if (-not $IsLinux) {
    Write-Error "host/ubuntu.kvm/guest.download-agent-service/New-VM.ps1 only runs on Linux."
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
# until the download-agent daemon actually stores that much. The pool itself
# lives on the NAS, not here.
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
$AdminPassword = Get-Password -Username 'download-agent-service-admin'
if (-not $AdminPassword) { Write-Error "Get-Password returned empty for 'download-agent-service-admin'."; exit 1 }
Write-Output "Password came from authentication mechanism: $_authActiveName"
Write-Output "See configuration at: $(Resolve-ExtensionAreaDir -Area 'authentication')"

# --- REGION: Render user-data / meta-data
$baseUserData     = Join-Path $repoRoot 'host/vmconfig/download-agent-service.base.user-data'
$overlayUserData  = Join-Path $repoRoot 'host/vmconfig/download-agent-service.kvm.overlay.yml'
$metaDataTemplate = Join-Path $repoRoot 'host/vmconfig/download-agent-service.meta-data'
foreach ($f in @($baseUserData, $overlayUserData, $metaDataTemplate)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Error "Template missing: $f"
        exit 1
    }
}
# --- REGION: Pick libvirt network (BEFORE building user-data)
# The baked NAS + source coordinates depend on whether this is NAT
# 'default' (host = libvirt gateway) or bridged 'yuruna-external' (host =
# LAN IP), so resolve the network first.
Import-Module (Join-Path (Split-Path -Parent $ScriptDir) 'modules/Yuruna.Host.psm1') -Force -DisableNameChecking
$networkName = Get-ExternalNetwork
if (-not $networkName) {
    Write-Error "No libvirt network defined. Run 'virsh net-start default' to enable the NAT default, or define 'yuruna-external' (see README.md) for LAN-bridged access."
    exit 1
}
if ($networkName -eq 'default') {
    Write-Warning "Using libvirt NAT 'default' network (192.168.122/24). The download-agent-service VM is reachable from this host only and the NAS likely isn't routable; define a bridged 'yuruna-external' libvirt network for LAN + NAS access."
} else {
    Write-Output "Using libvirt network: $networkName (download-agent-service VM will get a LAN-routable IP)"
}

# Host coordinates (status service, for the in-VM source fetch) + pool storage
# coordinates (the NAS that holds the download pool), baked into the seed.
# Honor an explicit override.
Import-Module (Join-Path $repoRoot 'test/modules/Test.PoolStorage.psm1')  -Global -Force
Import-Module (Join-Path $repoRoot 'test/modules/Test.YurunaDir.psm1')    -Global -Force
Import-Module (Join-Path $repoRoot 'test/modules/Test.Config.psm1')       -Global -Force
Import-Module (Join-Path $repoRoot 'test/modules/Test.CachingProxyService.psm1') -Global -Force
if ($env:YURUNA_GUEST_REACHABLE_HOST_IP) {
    $YurunaHostIp = $env:YURUNA_GUEST_REACHABLE_HOST_IP
} elseif ($networkName -eq 'default') {
    $YurunaHostIp = Get-GuestReachableHostIp   # NAT 'default': libvirt gateway
} else {
    $YurunaHostIp = Get-BestHostIp             # bridged 'yuruna-external': host LAN IP
}
if (-not $YurunaHostIp) { $YurunaHostIp = '' }
$YurunaHostPort = '8080'
$YurunaTestConfig = Join-Path $repoRoot 'test/test.config.yml'
$tc = $null
if (Test-Path -LiteralPath $YurunaTestConfig) {
    try { $tc = Read-TestConfig -Path $YurunaTestConfig } catch { Write-Verbose "test.config.yml read: $($_.Exception.Message)" }
    if ($tc -and $tc.statusService -and $tc.statusService.port) { $YurunaHostPort = "$($tc.statusService.port)" }
}
$poolNas = Get-YurunaPoolSeedValue -Config $tc -GuestReachableAddress $YurunaHostIp
# Pool-aggregator service base URL for the daemon's presence beacon + the
# auto-seed roster read; '' (no caching-proxy service known) leaves those
# features off in-guest. Wait for the aggregator BEFORE resolving: whatever is
# resolved here is baked into the seed once and never re-resolved in-guest, so
# an empty value taken while the aggregator is still compiling leaves the
# beacon permanently off -- the service serves correctly and simply never
# appears on the dashboard.
# Returns $false (rather than throwing) when there is no proxy to wait for or
# the budget expires; the seed then carries '' exactly as it did before.
$null = Wait-YurunaAggregatorReady
$aggregatorSeedUrl = Get-PoolAggregatorServiceSeedUrl

# --- REGION: Agent tunables + cache-proxy coordinates
# Config seconds become Go durations here because the value lands unmodified on
# the daemon's flag line. Defaults match the daemon's own frozen defaults, so a
# host with no downloadAgentService block and a bare daemon behave identically.
$agentScanInterval = '900s'
$agentFreshness    = '86400s'
$agentPrefetchLead = '7200s'
$agentAutoSeed     = 'true'
if ($tc -and $tc.downloadAgentService) {
    $agentConfig = $tc.downloadAgentService
    if ($agentConfig.scanIntervalSeconds) { $agentScanInterval = "$([int]$agentConfig.scanIntervalSeconds)s" }
    if ($agentConfig.freshnessSeconds)    { $agentFreshness    = "$([int]$agentConfig.freshnessSeconds)s" }
    if ($agentConfig.prefetchLeadSeconds) { $agentPrefetchLead = "$([int]$agentConfig.prefetchLeadSeconds)s" }
    # autoSeed is a real boolean, so an explicit `false` must survive: test for
    # presence, not truthiness, or opting out silently reverts to the default.
    if ($null -ne $agentConfig.autoSeed) {
        $agentAutoSeed = if ($agentConfig.autoSeed) { 'true' } else { 'false' }
    }
}
# Squid coordinates for the daemon's byte downloads. Resolve-CacheHostIp answers
# with an address THIS HOST can dial, and a loopback answer is a host-local
# forwarder the guest can never reach, so it is not a usable seed value.
$cacheProxyIp = ''
try {
    $cacheProxyIp = [string](Resolve-CacheHostIp)
} catch {
    Write-Verbose "Resolve-CacheHostIp: $($_.Exception.Message)"
}
if (-not $cacheProxyIp -or $cacheProxyIp -eq '127.0.0.1' -or $cacheProxyIp -eq '::1') { $cacheProxyIp = '' }
if ($cacheProxyIp) {
    Write-Output "Caching proxy for agent downloads: $cacheProxyIp"
} else {
    Write-Output "No reachable caching proxy; the agent downloads straight from the origins."
}

# Render user-data from the shared base + KVM overlay (host/vmconfig/
# download-agent-service.*). New-CloudInitUserData resolves placeholders with literal
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
        YURUNA_HOST_ID_PLACEHOLDER     = $poolNas.HostId
        YURUNA_AGGREGATOR_URL_PLACEHOLDER      = $aggregatorSeedUrl
        POOL_NAS_NETWORK_PATH_PLACEHOLDER  = $poolNas.NetworkPath
        POOL_NAS_NETWORK_IP_PLACEHOLDER    = $poolNas.NetworkIp
        POOL_NAS_NETWORK_USER_PLACEHOLDER  = $poolNas.NetworkUser
        POOL_NAS_PASSWORD_PLACEHOLDER      = $poolNas.Password
        DOWNLOAD_AGENT_SCAN_INTERVAL_PLACEHOLDER = $agentScanInterval
        DOWNLOAD_AGENT_FRESHNESS_PLACEHOLDER     = $agentFreshness
        DOWNLOAD_AGENT_PREFETCH_LEAD_PLACEHOLDER = $agentPrefetchLead
        DOWNLOAD_AGENT_AUTO_SEED_PLACEHOLDER     = $agentAutoSeed
        YURUNA_CACHE_PROXY_IP_PLACEHOLDER        = $cacheProxyIp
    } -Confirm:$false
$metaData = (Get-Content -Raw -LiteralPath $metaDataTemplate)

$seedDir = Join-Path $vmDir 'seed.src'
New-Item -ItemType Directory -Force -Path $seedDir | Out-Null
Set-Content -LiteralPath (Join-Path $seedDir 'user-data') -Value $userData -NoNewline
Set-Content -LiteralPath (Join-Path $seedDir 'meta-data') -Value $metaData -NoNewline

# --- REGION: Generate cloud-init seed ISO
& genisoimage -output $seedImg -volid cidata -joliet -rock `
    (Join-Path $seedDir 'user-data') (Join-Path $seedDir 'meta-data') 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "genisoimage failed (exit $LASTEXITCODE)"
    exit 1
}

Write-Output ""
Write-Output "== download-agent-service console/SSH login (available NOW) =="
Write-Output "  user:     download-agent-service-admin"
Write-Output "  password: (in authentication vault under 'download-agent-service-admin')"
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

# 8 GB RAM, 4 vCPU. Sized for the Go daemon streaming multi-GB artifacts
# between the origins and the pool share.
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
    '--memory',     '8192',
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

# The agent is meant to be always available: a host that reboots with no runner
# active would otherwise leave the pool unserved until someone re-runs the
# start script. The service-VM roster re-ensure remains the guarantee; this is
# the cheap belt-and-braces libvirt already offers.
$autostartOut = & virsh --connect $virshUri autostart $VMName 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warning "virsh autostart '$VMName' failed: $($autostartOut -join '; '). The VM still starts via the service-VM roster."
}

Remove-Item -LiteralPath $seedDir -Recurse -Force -ErrorAction SilentlyContinue

# --- REGION: Wait for VM IP
Write-Output "Waiting for VM to obtain an IP address..."
Write-Output "  (cloud-init brings up networking; first boot can take 1-3 minutes)"

$dockIp = $null
$maxIterations = 120  # 120 * 5s = 10 minutes
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
    Write-Error @"

download-agent-service VM '$VMName' did not obtain an IP address within 10 minutes.
Accessing the VM for debugging:
  * Console:  virt-viewer --connect $virshUri $VMName
              user: download-agent-service-admin  (password in authentication vault)
"@
    exit 1
}

Write-Output ""
Write-Output "== download-agent-service VM booted (network up; daemon still building in-guest) =="
Write-Output "  VM:       $VMName"
Write-Output "  IP:       $dockIp"
Write-Output "  Network:  $networkName"
Write-Output "  UI:       http://$dockIp/  (Download pool)"
Write-Output "  SSH:      ssh download-agent-service-admin@$dockIp  (harness key authorized)"
Write-Output "  Console:  virt-viewer --connect $virshUri $VMName"
Write-Output ""
Write-Output "Cloud-init fetches the framework and runs the bring-up script, which builds"
Write-Output "the daemon, CIFS-mounts the pool NAS that holds the download pool, and"
Write-Output "launches it under systemd on :80."
Write-Output "Watch progress:  ssh download-agent-service-admin@$dockIp 'sudo tail -f /var/log/cloud-init-output.log'"
Write-Output "  (the log is root-only; download-agent-service-admin has NOPASSWD sudo, so 'sudo tail' works over the harness key)"
Write-Output "See https://yuruna.link/download-agent-service."
exit 0
