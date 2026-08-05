<#PSScriptInfo
.VERSION 2026.08.05
.GUID 424d0279-f3c9-4c22-a616-3c2be9ec025e
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
    Creates (or recreates) the Yuruna download-agent service VM on Hyper-V.

.DESCRIPTION
    Builds an Ubuntu 26.04 LTS cloud-image VM that hosts the
    download-agent-service daemon (operator UI + API over the shared
    download pool on the pool NAS). Cloud-init fetches the framework and
    runs the bring-up script which builds the daemon, CIFS-mounts the pool
    NAS that holds the pool, and launches it under systemd.

    See https://yuruna.link/download-agent-service for the full specification.

.PARAMETER VMName
    Name of the Hyper-V VM. Default: yuruna-download-agent-service.
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = "yuruna-download-agent-service"
)

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Output "Invalid VMName '$VMName'. Only alphanumeric characters, dots, hyphens, and underscores are allowed."
    exit 1
}

$global:InformationPreference = "Continue"
$global:ProgressPreference    = "SilentlyContinue"

$commonModulePath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath "modules/Yuruna.Host.psm1"
Import-Module -Name $commonModulePath -Force

Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output "Please run this script as Administrator."
    exit 1
}

# Assert-HyperVEnabled (Yuruna.Host.psm1) calls dism.exe directly instead
# of Get-WindowsOptionalFeature -- avoids the "Class not registered" COM
# failure that breaks first post-install runs on fresh Windows 11.
if (-not (Assert-HyperVEnabled)) { exit 1 }

# --- REGION: Seek the base image
# One VHDX backs every extension service on this host; this VM grows its own
# copy below (host/modules/Yuruna.Image.psm1).
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "modules/Yuruna.Image.psm1") -Force
$downloadDir = (Get-VMHost).VirtualHardDiskPath
$baseImageFile = (Get-UbuntuExtensionImageInfo -HostType 'windows.hyper-v').BaseImageFile

# Auto-run Get-Image.ps1 once if the base image is missing; recheck and
# only error out when it's still missing afterward.
if (!(Test-Path -Path $baseImageFile)) {
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
    if (!(Test-Path -Path $baseImageFile)) {
        Write-Error "Base image not found at '$baseImageFile' after auto Get-Image. Run Get-Image.ps1 manually."
        exit 1
    }
}

# --- REGION: Remove existing VM
# Runs AFTER the base image is confirmed so a failed image fetch never
# destroys a working VM.
$existingVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($existingVM) {
    Write-Output "VM '$VMName' exists. Deleting..."
    Hyper-V\Stop-VM -Name $VMName -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    try {
        Hyper-V\Remove-VM -Name $VMName -Force -ErrorAction Stop
    } catch {
        # A half-removed VM (locked vhdx, permission, etc.) would trip
        # the next New-VM call with "already exists" and the outer loop
        # has no signal to recover. Dump live Hyper-V state so the
        # operator can clean orphan disks before retrying.
        $diag = Get-VM -Name $VMName -ErrorAction SilentlyContinue |
            Format-List Name, State, Status, Generation, Path | Out-String
        throw "Hyper-V\Remove-VM failed for '$VMName': $($_.Exception.Message)`nLive Hyper-V state:`n$diag"
    }
    # Hyper-V can return Remove-VM success while leaving a ghost entry;
    # a second Get-VM is the only reliable post-condition.
    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
        throw "Hyper-V\Remove-VM returned success for '$VMName' but Get-VM still finds it; aborting before re-creation."
    }
    Write-Output "VM '$VMName' deleted."
}

# --- REGION: Copy base image -> per-VM disk
$vmDir = Join-Path $downloadDir $VMName
if (-not (Test-Path -Path $vmDir)) {
    New-Item -ItemType Directory -Path $vmDir -Force | Out-Null
}
$vhdxFile = Join-Path $vmDir "$VMName.vhdx"
Write-Output "Creating VHDX for '$VMName' by copying base image..."
Copy-Item -Path $baseImageFile -Destination $vhdxFile -Force

# --- REGION: Grow the per-VM disk to 256 GB
# Dynamic VHDX, so 256 GB is the nominal size only: the file grows as the
# download-agent daemon writes. The pool itself lives on the NAS, not here.
if (-not (Expand-ExtensionVmDisk -Path $vhdxFile -SizeBytes 256GB -Format 'vhdx')) {
    Write-Error "Could not resize '$vhdxFile' to 256 GB; refusing to build the VM on base-capacity disk."
    exit 1
}

# --- REGION: Generate cloud-init seed ISO
# meta-data is shared under host/vmconfig/ (byte-identical across all 3 host platforms).
$hostVmConfigDir = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'host/vmconfig'
# 4-digit entropy is weak by design (10k cases) but enough to defeat
# the deterministic-path symlink trap: an attacker dropping a symlink
# at %TEMP%\seed_<VMName>\ before New-VM runs can't predict the
# trailing 4 digits per run.
$SeedDir = Join-Path $env:TEMP ("seed_${VMName}_{0:D4}" -f (Get-Random -Maximum 10000))
if (Test-Path -LiteralPath $SeedDir) { Remove-Item -LiteralPath $SeedDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null

Copy-Item -Path (Join-Path $hostVmConfigDir 'download-agent-service.meta-data') -Destination "$SeedDir/meta-data"
# network-config, shipped alongside meta-data on the same seed: it pins the
# guest DHCP client identity to the interface MAC. Without it the guest
# identifies itself by a machine-id-derived DUID, which cloud-init changes
# mid-boot, so the DHCP server sees a new client and leases a different address
# -- and every host-side artifact aimed at the first address (port-forwarder,
# readiness probe, published URL) is left pointing at one the guest abandoned.
Copy-Item -Path (Join-Path $hostVmConfigDir 'extension-service.network-config') -Destination "$SeedDir/network-config"

# --- REGION: Yuruna harness SSH key + vault password
# The password belongs to THIS VM's own administrator. The account name is
# per-VM-family: a name shared with the caching-proxy-service and stash-service
# VMs would resolve to a single vault entry, and whichever VM was built last
# would invalidate the others' credential.
$_repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Ssh.psm1')       -Force -DisableNameChecking
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Extension.psm1') -Global -Force -Verbose:$false
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error "Get-YurunaSshPublicKey returned empty."; exit 1 }
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$AdminPassword = Get-Password -Username 'download-agent-service-admin'
if (-not $AdminPassword) { Write-Error "Get-Password returned empty for 'download-agent-service-admin'."; exit 1 }
Write-Output "Password came from authentication mechanism: $_authActiveName"
Write-Output "See configuration at: $(Resolve-ExtensionAreaDir -Area 'authentication')"

# --- REGION: Pick a vSwitch (BEFORE building user-data)
# The pool NAS + source coordinates baked into cloud-init depend on the chosen
# network, so resolve it first. Prefer Yuruna-External so the VM gets a LAN
# IP and can reach the NAS + the host status service; fall back to Default
# Switch only when External is unavailable (Wi-Fi-only host), where the VM
# is reachable only from same-host peers and the NAS likely isn't routable.
$switchName = Get-OrCreateYurunaExternalSwitch
if (-not $switchName) {
    $switchName = 'Default Switch'
    if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
        # The Default Switch ships only with Windows client SKUs and an
        # operator can delete it. New-VM throws on a switch name that
        # resolves to nothing, so an unchecked fallback turns a degraded
        # network into a failed provision; any switch that exists still
        # creates and boots the VM. Rank non-External switches first: this
        # path is normally reached because the host uplink is one Hyper-V
        # refuses to carry a bridged guest MAC over, so a guest attached to
        # an External switch there comes up with no carrier at all, while an
        # Internal/NAT switch still gives it a working address.
        $substituteSwitch = @(Get-VMSwitch -ErrorAction SilentlyContinue) |
            Sort-Object @{ Expression = { $_.SwitchType -eq 'External' } }, Name |
            Select-Object -First 1
        if ($substituteSwitch) {
            $switchName = $substituteSwitch.Name
            Write-Warning "This host has no 'Default Switch'. Attaching to vSwitch '$switchName' instead so VM creation still succeeds."
        }
    }
    Write-Information "External vSwitch unavailable -- the VM is attached to '$switchName' (NAT + DHCP). It gets no LAN-bridged address: the host answers only at that switch's gateway address, and anything on the LAN reaches the guest only through a host port-forwarder."
    Write-Information "  The download-agent-service VM won't be reachable from LAN by its own IP, and the NAS may be unreachable."
}

# Host coordinates (status service, for the in-VM source fetch) + pool storage
# coordinates (the NAS that holds the download pool), baked into the seed.
Import-Module (Join-Path $_repoRoot 'test/modules/Test.PoolStorage.psm1')  -Global -Force
Import-Module (Join-Path $_repoRoot 'test/modules/Test.YurunaDir.psm1')    -Global -Force
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Config.psm1')       -Global -Force
Import-Module (Join-Path $_repoRoot 'test/modules/Test.CachingProxyService.psm1') -Global -Force
$YurunaHostIp = Get-GuestReachableHostIp -SwitchName $switchName
if (-not $YurunaHostIp) { $YurunaHostIp = '' }
$YurunaHostPort = '8080'
$YurunaTestConfig = Join-Path $_repoRoot 'test/test.config.yml'
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

# Render user-data from the shared base + Hyper-V overlay (host/vmconfig/
# download-agent-service.*). New-CloudInitUserData resolves placeholders with literal
# .Replace(), so values carrying regex-special chars are safe.
Import-Module (Join-Path $_repoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force
$UserData = New-CloudInitUserData `
    -BasePath    (Join-Path $_repoRoot 'host/vmconfig/download-agent-service.base.user-data') `
    -OverlayPath (Join-Path $_repoRoot 'host/vmconfig/download-agent-service.hyperv.overlay.yml') `
    -RepoRoot    $_repoRoot `
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
Set-Content -Path "$SeedDir/user-data" -Value $UserData -NoNewline

$SeedIso = Join-Path $vmDir "seed.iso"
Write-Output "Generating seed.iso with cloud-init configuration..."
CreateIso -SourceDir $SeedDir -OutputFile $SeedIso -VolumeId "cidata"

Write-Output ""
Write-Output "== download-agent-service console/SSH login (available NOW) =="
Write-Output "  user:     download-agent-service-admin"
Write-Output "  password: (in authentication vault under 'download-agent-service-admin')"
Write-Output "  If the wait below stalls or fails, open 'vmconnect localhost $VMName'"
Write-Output "  and log in with the credentials above to inspect cloud-init state."
Write-Output ""

# --- REGION: Create and configure Hyper-V VM
# 4 GB RAM, 4 vCPU. Sized for the Go daemon streaming multi-GB artifacts between
# the origins and the pool share -- it streams to the share rather than holding
# an artifact in RAM, so the resident set stays far below this. Matches the
# stash-service and pool-control-service VMs so the operator learns one sizing
# baseline across the extension VMs. Memory is pinned (no dynamic balloon), so
# every GB is committed on the host for the life of the VM.
Write-Output "Creating new VM '$VMName' on switch '$switchName'..."
Hyper-V\New-VM -Name $VMName -Generation 2 -MemoryStartupBytes 4GB -SwitchName $switchName -VHDPath $vhdxFile | Out-Null
Set-VM -Name $VMName -MemoryStartupBytes 4GB -MemoryMinimumBytes 4GB -MemoryMaximumBytes 4GB -AutomaticCheckpointsEnabled $false | Out-Null
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off | Out-Null
Add-VMDvdDrive -VMName $VMName -Path $SeedIso | Out-Null
# The agent is meant to be always available: a host that reboots with no runner
# active would otherwise leave the pool unserved until someone re-runs the
# start script. The service-VM roster re-ensure remains the guarantee; this is
# the cheap belt-and-braces the hypervisor already offers.
Set-VM -Name $VMName -AutomaticStartAction Start | Out-Null
# --- REGION: https://yuruna.link/definition#defining-the-vm-core-count-policy
$hostCores = (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
if ($hostCores -lt 4) {
    Write-Error "Host has $hostCores physical cores; Yuruna requires at least 4. See https://yuruna.link/definition#defining-the-vm-core-count-policy"
    exit 1
}
$vmCores = [math]::Max(4, [math]::Floor($hostCores / 2))
Set-VMProcessor -VMName $VMName -Count $vmCores | Out-Null

# --- REGION: Cleanup temporary folders
Remove-Item -LiteralPath $SeedDir -Recurse -Force -ErrorAction SilentlyContinue

# --- REGION: Start VM and wait for IP
Write-Output "Starting VM '$VMName'..."
Hyper-V\Start-VM -Name $VMName

Write-Output "Waiting for VM to obtain an IP address..."
Write-Output "  (cloud-init brings up networking; first boot can take 1-3 minutes)"

# Discover via Get-CacheVmCandidateIp -- shared primitive in Yuruna.Host
# that combines KVP + ARP. Same approach as the caching-proxy-service pattern.
$dockIp = $null
$dockCandidateIps = @()
$maxIterations = 120  # 120 * 5s = 10 minutes
$vmDiscoveryLogged = $false
$vmOnExternalSwitch = $false
$arpProbeAnnounced = $false

# The ARP sweep only makes sense on a bridged (External) switch, where the
# host is not the DHCP server and never observes the guest's lease. The
# External vSwitch name is operator-configurable (Get-OrCreateYurunaExternalSwitch
# honors a pre-created switch under any name), so key off the switch this
# script resolved rather than a literal name -- a literal silently skips the
# sweep on a host that named its bridge anything else.
$switchIsExternal = ((Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue).SwitchType -eq 'External')

$ProgressPreference = 'Continue'
$activity  = "Waiting for '$VMName' to obtain an IP"
$startTime = Get-Date

for ($i = 0; $i -lt $maxIterations; $i++) {
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($vm) {
        # ARP-probe the bridged /24 to populate the host's neighbor cache
        # when the host isn't the DHCP server.
        # feedback_hyperv_external_vswitch_arp_discovery.md
        if ($i -eq 0) {
            $vmOnExternalSwitch = $switchIsExternal -and
                (($vm | Get-VMNetworkAdapter -ErrorAction SilentlyContinue |
                        Select-Object -First 1).SwitchName -eq $switchName)
        }
        if ($vmOnExternalSwitch -and $i -ge 6) {
            if (-not $arpProbeAnnounced) {
                Write-Output "  Active ARP probe on the '$switchName' subnet..."
                $arpProbeAnnounced = $true
            }
            Invoke-YurunaExternalArpProbe -SwitchName $switchName
        }

        $dockCandidateIps = @(Get-CacheVmCandidateIp -VM $vm)
        if ($dockCandidateIps) {
            if (-not $vmDiscoveryLogged) {
                $vmMac = ($vm | Get-VMNetworkAdapter | Select-Object -First 1).MacAddress
                $vmMacDashed = if ($vmMac -match '^[0-9A-Fa-f]{12}$') {
                    (($vmMac -replace '(..)(?!$)', '$1-')).ToUpper()
                } else { '(unknown)' }
                Write-Output "  VM MAC: $vmMacDashed"
                Write-Output "  Discovered IP(s) for ${VMName}: $($dockCandidateIps -join ', ')"
                $vmDiscoveryLogged = $true
            }
            break
        }
    }

    $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
    $pct     = [math]::Min(100, [math]::Round(($elapsed / ($maxIterations * 5)) * 100))
    Write-Progress -Activity $activity -Status "elapsed ${elapsed}s" -PercentComplete $pct -SecondsRemaining (($maxIterations * 5) - $elapsed)

    Start-Sleep -Seconds 5
}
Write-Progress -Activity $activity -Completed

if (-not $dockCandidateIps) {
    Write-Error @"

download-agent-service VM '$VMName' did not obtain an IP address within 10 minutes.
Accessing the VM for debugging:
  * Console:  vmconnect localhost $VMName
              user: download-agent-service-admin  (password in authentication vault)
"@
    exit 1
}

# Single-candidate pick: the download-agent-service UI listens on :80 but v1 does not
# validate it here, so the first non-loopback candidate IP is authoritative.
# When ARP returned multiple candidates, the operator can verify reachability
# with `ssh download-agent-service-admin@<ip>` -- the harness key is already authorized.
$dockIp = $dockCandidateIps | Select-Object -First 1

Write-Output ""
Write-Output "== download-agent-service VM booted (network up; daemon still building in-guest) =="
Write-Output "  VM:       $VMName"
Write-Output "  IP:       $dockIp"
Write-Output "  UI:       http://$dockIp/  (Download pool)"
Write-Output "  SSH:      ssh download-agent-service-admin@$dockIp  (harness key authorized)"
Write-Output "  Console:  vmconnect localhost $VMName  (user download-agent-service-admin, vault password)"
Write-Output ""
Write-Output "Cloud-init fetches the framework and runs the bring-up script, which builds"
Write-Output "the daemon, CIFS-mounts the pool NAS that holds the download pool, and"
Write-Output "launches it under systemd on :80."
Write-Output "Watch progress:  ssh download-agent-service-admin@$dockIp 'sudo tail -f /var/log/cloud-init-output.log'"
Write-Output "  (the log is root-only; download-agent-service-admin has NOPASSWD sudo, so 'sudo tail' works over the harness key)"
Write-Output "See https://yuruna.link/download-agent-service."
exit 0
