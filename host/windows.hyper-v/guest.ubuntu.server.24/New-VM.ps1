<#PSScriptInfo
.VERSION 2026.09.01
.GUID 42303d37-2208-46b9-ad37-c8c5638af258
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
    Creates a Hyper-V VM that installs Ubuntu Server 24.04 in text mode.

.DESCRIPTION
    Uses the Server live ISO. The Server ISO's cdrom has linux-generic
    and a network-configured ubuntu.sources, so subiquity's
    install_kernel step always succeeds. First boot lands at the
    text-mode login prompt; the test harness's Test-Start sequence
    drives that prompt directly.
#>

param(
    [string]$VMName = "ubuntu-server01",
    # Forwarded by the test harness (Start-TestRunner -> Invoke-NewVM)
    # so every guest in a run agrees on one caching-proxy service URL. When
    # bound (even to ""), local discovery is skipped and this value is
    # used verbatim: "" = no cache, go direct; URL = use this. When NOT
    # bound (standalone run), fall back to the discovery block below.
    [string]$CachingProxyServiceUrl,
    # OS user created by autoinstall and exercised by the test
    # sequences. The framework default 'yuuser24' is intentionally
    # unique/greppable (versus the cloud-image default 'ubuntu', which
    # is noisy in any text search) and version-tagged so 24.04 and 26.04
    # guests don't collide in shared logs. Additional users are expected to
    # come from a manifest rather than an override here.
    [string]$Username = 'yuuser24',
    # cloud-init local-hostname for the guest. Empty means "follow the VM
    # name", which keeps host-side lookups that assume hostname == VM name
    # working for every caller that does not ask for a specific hostname.
    [string]$Hostname = '',
    # Planner-cascaded VM memory (variables.memoryStartupBytes). Accepts a raw
    # byte count or a KB/MB/GB suffix (e.g. 34359738368, 32768MB, 32GB) via
    # ConvertTo-MemoryStartupBytes. Empty keeps the 12 GB default below --
    # enough for k8s + dotnet builds, bumped for nested-host / heavy workloads.
    [string]$MemoryStartupBytes = '',
    # Planner-cascaded vCPU count (variables.cores). Overrules the default
    # host/2 calculation below. Empty keeps the default. Clamped to the host's
    # physical core count.
    [string]$Cores = '',
    # Planner-cascaded nested-virtualization request
    # (variables.exposeVirtualizationExtensions). 'true' exposes
    # virtualization extensions to the guest so it can run its own hypervisor
    # (e.g. KVM for a nested host). Default off: ARM64 Hyper-V cannot start a
    # VM with the extensions exposed, and most guests never need them.
    [string]$ExposeVirtualizationExtensions = ''
)

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Output "Invalid VMName '$VMName'. Only alphanumeric characters, dots, hyphens, and underscores are allowed."
    exit 1
}

if ($Hostname -and $Hostname -notmatch '^[a-zA-Z0-9.-]+$') {
    Write-Output "Invalid Hostname '$Hostname'. Only alphanumeric characters, dots, and hyphens are allowed."
    exit 1
}
$GuestHostname = if ($Hostname) { $Hostname } else { $VMName }

$ProgressPreference = 'SilentlyContinue'
# Abort at the first failed cmdlet: this script runs as a child pwsh -File
# process whose non-zero exit is the caller's only failure signal. Without
# Stop, a non-terminating error from the disk/VM-config sequence (New-VHD,
# Set-VM*, Add-VMDvdDrive) prints red and the script marches on, failing
# confusingly at a later step against a half-configured VM. Module
# functions keep their own error handling (preference variables do not
# cross the module boundary), so this hardens exactly the direct cmdlet
# calls in this file.
$ErrorActionPreference = 'Stop'

# Honor logLevel from Start-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$commonModulePath = Join-Path -Path (Split-Path -Parent $ScriptDir) -ChildPath "modules/Yuruna.Host.psm1"
Import-Module -Name $commonModulePath -Force

# --- REGION: Environment checks
Write-Verbose "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output "Please run this script as Administrator."
    Write-Output "Be careful."
    exit 1
}

# Assert-HyperVEnabled calls dism.exe directly instead of
# Get-WindowsOptionalFeature -- avoids the "Class not registered" COM
# failure on first post-install runs on fresh Windows 11.
if (-not (Assert-HyperVEnabled)) {
    Write-Output "Instructions: https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/quick-start/enable-hyper-v"
    exit 1
}

$downloadDir = (Get-VMHost).VirtualHardDiskPath
if (!(Test-Path -Path $downloadDir)) {
    Write-Output "The Hyper-V default VHDX folder does not exist: $downloadDir"
    exit 1
}

# Nested virtualization is opt-in and AMD64-only: ARM64 Hyper-V rejects a VM
# with virtualization extensions exposed at start time ("this platform does
# not support nested virtualization"), so an impossible ask fails here,
# before any VM state is created. OSArchitecture rather than
# $env:PROCESSOR_ARCHITECTURE, which reports AMD64 for an x64 pwsh under
# emulation on an ARM64 host.
$exposeVirt = $false
if ($ExposeVirtualizationExtensions) {
    if (-not [bool]::TryParse($ExposeVirtualizationExtensions, [ref]$exposeVirt)) {
        Write-Error "Invalid -ExposeVirtualizationExtensions '$ExposeVirtualizationExtensions': expected 'true' or 'false'."
        exit 1
    }
}
if ($exposeVirt -and [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [System.Runtime.InteropServices.Architecture]::X64) {
    Write-Error "Nested virtualization (exposeVirtualizationExtensions: true) was requested, but Hyper-V supports it only on AMD64 hosts; this host is $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture). Remove the variable or run the sequence on an AMD64 host."
    exit 1
}

# --- REGION: Seek the base image
# Auto-run Get-Image.ps1 once if the base image is missing; recheck and
# only error out when it's still missing afterward.
$baseImageName = "host.windows.hyper-v.guest.ubuntu.server.24"
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules/Yuruna.Image.psm1') -Force
if (-not (Assert-YurunaBaseImage -BaseImageFile $baseImageFile -GuestFolder $PSScriptRoot)) { exit 1 }

# Resolve the autoinstall password from the per-cycle authentication
# vault. Get-Password returns the stored value if present, else
# generates a fresh one (chained to whatever the previous guest in this
# cycle committed -- see test/extension/authentication/default.psm1).
# Cycle-end cleanup wipes the vault on success; a failed cycle leaves
# it in place for debugging.
$_repoRootForExt = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))
Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.Extension.psm1') -Global -Force -Verbose:$false
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$Password = Get-LocalOsPassword -Username $Username
if (-not $Password) { Write-Error "Get-LocalOsPassword returned empty for '$Username'."; exit 1 }
Write-Output "Password came from authentication mechanism: $_authActiveName"
Write-Output "See configuration at: $(Resolve-ExtensionAreaDir -Area 'authentication')"

# --- REGION: Autoinstall password hash
# SHA-512 ($6$) password hash for the autoinstall HASH_PLACEHOLDER.
# ConvertTo-Sha512CryptHash centralizes the openssl probe + the `--`
# end-of-options safety that keeps a leading-dash password
# (e.g. `-4aWj*CRw` from New-RandomPassword) from being parsed as an
# option. See Yuruna.Common\ConvertTo-Sha512CryptHash for rationale.
Import-Module (Join-Path $_repoRootForExt 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
try {
    $PasswordHash = ConvertTo-Sha512CryptHash -Plaintext $Password
} catch {
    Write-Error "Password hashing failed: $($_.Exception.Message)"
    exit 1
}

Write-Verbose "Creating VM '$VMName' using image: $baseImageFile"
# --- REGION: Base image provenance
# Provenance side-channel for the transcript. Emits "Provenance: <url>"
# when the sidecar is healthy; warns otherwise.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

# --- REGION: Remove existing VM
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

# --- REGION: Create copies and files for VM

$vmDir = Join-Path $downloadDir $VMName
if (!(Test-Path -Path $vmDir)) {
    New-Item -ItemType Directory -Path $vmDir -Force | Out-Null
}
$vhdxFile = Join-Path $vmDir "$VMName.vhdx"
if (Test-Path -Path $vhdxFile) {
    Remove-Item -Path $vhdxFile -Force
}
# --- REGION: Create empty install target
# 64 GB dynamic VHDX is enough headroom for the k8s + dotnet build
# workload yet stays a uniform cap across hosts: ubuntu.kvm /
# windows.hyper-v / macos.utm. Paired with sizing-policy: all in
# host/vmconfig/ubuntu.server.base.user-data so the root LV consumes the whole PV.
Write-Verbose "Creating 64GB dynamically expanding VHDX..."
New-VHD -Path $vhdxFile -SizeBytes 64GB -Dynamic | Out-Null
if (-not (Test-Path -LiteralPath $vhdxFile)) {
    Write-Error "New-VHD reported success but '$vhdxFile' does not exist; aborting before VM creation."
    exit 1
}

# Autoinstall seed ISO. 4-digit entropy is weak by design (10k cases)
# but enough to defeat the deterministic-path symlink trap: an attacker
# dropping a symlink at %TEMP%\seed_<VMName>\ before New-VM runs can't
# predict the trailing 4 digits per run.
$SeedDir = Join-Path $env:TEMP ("seed_${VMName}_{0:D4}" -f (Get-Random -Maximum 10000))
if (Test-Path -LiteralPath $SeedDir) { Remove-Item -LiteralPath $SeedDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null

# user-data AND meta-data are shared under host/vmconfig/ (the meta-data is
# byte-identical across the three host platforms; ubuntu.server.24 and .26
# share one file). Anchor contract: automation/Yuruna.CloudInitTemplate.psm1.
$RepoRoot        = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))
$HostVmConfigDir = Join-Path $RepoRoot 'host/vmconfig'
$BaseUserData    = Join-Path $HostVmConfigDir 'ubuntu.server.base.user-data'
$OverlayUserData = Join-Path $HostVmConfigDir 'ubuntu.server.hyperv.overlay.yml'
$MetaDataTemplate = Join-Path $HostVmConfigDir 'ubuntu.server.meta-data'
foreach ($p in @($BaseUserData, $OverlayUserData)) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Error "user-data template missing: $p"; exit 1 }
}
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force

# --- REGION: Yuruna harness SSH key
# SSH public key used by the test harness.
$TestSshModule = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))) "test/modules/Test.Ssh.psm1"
Import-Module $TestSshModule -Force
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error "Get-YurunaSshPublicKey returned empty. Module path: $TestSshModule"; exit 1 }

# --- REGION: Detect the caching-proxy service
# Detect the caching-proxy-service VM and inject its proxy URL if available.
# Severity policy:
#   * No cache VM         -> WARNING, proceed (direct CDN)
#   * Cache VM stopped    -> WARNING, proceed (direct CDN)
#   * Cache running, :3128
#     doesn't answer      -> ERROR, exit 1
if ($PSBoundParameters.ContainsKey('CachingProxyServiceUrl')) {
    # URL forwarded by the test runner. Skip discovery so this script
    # and the runner agree on one cache URL. On Hyper-V the race is
    # narrower than UTM (MAC-scoped neighbor lookup, not subnet scan),
    # but one source of truth still simplifies debugging.
    if ($CachingProxyServiceUrl) {
        Write-Verbose "  caching-proxy service URL forwarded by caller: $CachingProxyServiceUrl -- skipping local discovery."
    } else {
        Write-Verbose "  No proxy forwarded by caller -- guest will download directly."
    }
} else {
$CachingProxyServiceUrl = ""
$cacheVM = Get-VM -Name "yuruna-caching-proxy-service" -ErrorAction SilentlyContinue
if (-not $cacheVM) {
    Write-Warning "  No yuruna-caching-proxy-service VM exists on this host. Guest will download packages directly from Ubuntu mirrors -- expect occasional 429 rate-limit failures on linux-firmware under load."
    Write-Warning "  To enable caching, run: host\windows.hyper-v\guest.caching-proxy-service\New-VM.ps1"
} elseif ($cacheVM.State -ne 'Running') {
    Write-Warning "  yuruna-caching-proxy-service VM exists but is '$($cacheVM.State)'. Guest will download directly (expect occasional 429s)."
    Write-Warning "  To enable caching: Start-VM yuruna-caching-proxy-service ; then wait for cloud-init to finish."
} else {
    # KVP+ARP discovery + :3128 probe live in Yuruna.Host.psm1
    # (Get-WorkingCachingProxyServiceUrl). One module means this consumer, the
    # producer, and Start-CachingProxyServiceVM.ps1's summary all see the same
    # answer (avoids the regression class where a KVP-only summary
    # reports "discovery failed" while the ARP path already found it).
    $CachingProxyServiceUrl = Get-WorkingCachingProxyServiceUrl -VMName "yuruna-caching-proxy-service"
    if ($CachingProxyServiceUrl) {
        Write-Output "  yuruna-caching-proxy-service VM detected at $CachingProxyServiceUrl -- guest will use local proxy."
    } else {
        $cacheIps = Get-CacheVmCandidateIp -VM $cacheVM
        $ipList = if ($cacheIps) { $cacheIps -join ', ' } else { '(none discovered)' }
        # $Host.UI.WriteLine keeps Write-Host-style color without the
        # PSScriptAnalyzer complaint.
        $detail = @"

========
ERROR: yuruna-caching-proxy-service VM is running but port 3128 is not reachable.
========
  Discovered IPs: $ipList

Aborting so this guest install doesn't silently fall back to direct
CDN access and hit the 429 rate limiter.

Accessing the yuruna-caching-proxy-service VM for debugging:
  * Console:  vmconnect localhost yuruna-caching-proxy-service
              login:    caching-proxy-service-admin
              password: read the 'password:' field from
                test/status/runtime/yuruna-caching-proxy-service.yml
  * SSH:      ssh caching-proxy-service-admin@<ip>

Rebuild the cache VM:
  host\windows.hyper-v\guest.caching-proxy-service\New-VM.ps1

To intentionally skip the cache:
  Stop-VM yuruna-caching-proxy-service   (guest will then WARN and download direct).
========
"@
        $Host.UI.WriteLine([ConsoleColor]::Red, $Host.UI.RawUI.BackgroundColor, $detail)
        exit 1
    }
}
}

# --- REGION: Build the autoinstall apt block
# --- REGION: https://yuruna.link/vmconfig#apt-proxy-block
# Always emit `geoip: false` plus a pinned `primary:` mirror -- deterministic
# election, and `primary:` rather than `sources_list:`. See
# feedback_macos_utm_apt_block_resolute_curtin_trap.md.
# Shared builder: automation/Yuruna.GuestSeed.psm1. The mirror follows the
# guest architecture: archive.ubuntu.com carries amd64 only, and an ARM64
# autoinstall pinned to it finds no packages and dies in curtin. OSArchitecture
# rather than $env:PROCESSOR_ARCHITECTURE, which reports AMD64 for an x64 pwsh
# under emulation on an ARM64 host.
# The apt Acquire tuning it emits is a step-budget bound, so it has to be
# identical on every host driver: copies inlined per driver drift, and a
# mirror stall then burns a step budget on whichever host was missed.
switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    'X64'   { $primaryUri = 'http://archive.ubuntu.com/ubuntu' }
    'Arm64' { $primaryUri = 'http://ports.ubuntu.com/ubuntu-ports' }
    default {
        Write-Error "Unsupported processor architecture: $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture). A Hyper-V host must be AMD64 or ARM64."
        exit 1
    }
}
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.GuestSeed.psm1') -Force
$AptProxyBlock = New-AptProxyBlock -PrimaryUri $primaryUri -CachingProxyServiceUrl $CachingProxyServiceUrl

# --- REGION: Pick a vSwitch
# Pick a vSwitch FIRST -- prefer Yuruna-External (LAN-bridged) so the
# install VM gets a real LAN IP via DHCP and can reach the squid cache
# directly. Default Switch fallback works for hosts that can't create
# an External vSwitch (no LAN, Wi-Fi-only); install proceeds direct
# against Ubuntu mirrors. Switch choice MUST be resolved before
# Get-GuestReachableHostIp below (the host IP a guest reaches differs
# by topology: Default Switch = 172.x.x.x gateway; External = LAN IP).
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
}

# --- REGION: Yuruna host coordinates
# Yuruna host (status service) IP+port baked into the seed for the dev
# iteration loop. Guest scripts read /etc/yuruna/host.env (written by
# the user-data late-commands) to resolve a local URL before falling
# back to GitHub. Default Switch's host IP changes across host
# reboots -- see Test-YurunaHost.ps1 for the in-guest probe.
$YurunaHostIp = Get-GuestReachableHostIp -SwitchName $switchName
if (-not $YurunaHostIp) { $YurunaHostIp = '' }
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.Config.psm1') -Global -Force
$_statusSeed = Get-YurunaStatusServiceSeed -RepoRoot (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$YurunaHostPort = $_statusSeed.Port

# --- REGION: Fetch caching-proxy-service CA cert (base64-embedded in seed)
# --- REGION: https://yuruna.link/network#caching-proxy-service-ca-cert-rc60-gate
# An empty $CaCertBase64 is NOT a harmless no-op (curl rc=60 SSL-bump gate).
$CaCertBase64 = ""
if ($CachingProxyServiceUrl) {
    Import-Module -Name (Join-Path $PSScriptRoot '../../../test/modules/Test.CachingProxyService.psm1') -Force -DisableNameChecking
    $uri = [System.Uri]$CachingProxyServiceUrl
    $cacheHost = if ($uri.Host -match ':') { "[$($uri.Host)]" } else { $uri.Host }
    $ca = Get-CachingProxyServiceCaCertBase64 -CacheCaUrl "http://$cacheHost/yuruna-squid-ca.crt" -CacheHost $uri.Host
    $CaCertBase64 = $ca.CaCertBase64
    if ($ca.Exhausted) {
        Write-Warning "  Guest boots CA-less; it will self-heal the CA from the host status service at update time. HTTP caching via :3128 unaffected."
    }
}

# --- REGION: Render user-data / meta-data
# --- REGION: https://yuruna.link/network#defining-yuruna-retry-lib
# Bake yuruna-retry.sh + fetch-and-execute.sh into the seed as base64-encoded
# write_files entries. Eliminates the legacy network-dependent wget+wget
# bootstrap and ensures both files are on disk before any guest script runs.
$null = New-CloudInitUserData `
    -BasePath    $BaseUserData `
    -OverlayPath $OverlayUserData `
    -RepoRoot    $RepoRoot `
    -OutputPath  "$SeedDir/user-data" `
    -Replacement @{
        HOSTNAME_PLACEHOLDER           = $GuestHostname
        USERNAME_PLACEHOLDER           = $Username
        HASH_PLACEHOLDER               = $PasswordHash
        SSH_AUTHORIZED_KEY_PLACEHOLDER = $SshAuthorizedKey
        APT_PROXY_BLOCK_PLACEHOLDER    = $AptProxyBlock
        CACHING_PROXY_URL_PLACEHOLDER  = $CachingProxyServiceUrl
        CA_CERT_BASE64_PLACEHOLDER     = $CaCertBase64
        YURUNA_STATUS_SERVICE_IP_PLACEHOLDER     = $YurunaHostIp
        YURUNA_STATUS_SERVICE_PORT_PLACEHOLDER   = $YurunaHostPort
    } -Confirm:$false

$MetaData = (Get-Content -Raw $MetaDataTemplate) `
    -replace 'INSTANCE_ID_PLACEHOLDER', $VMName `
    -replace 'HOSTNAME_PLACEHOLDER', $GuestHostname
Set-Content -Path "$SeedDir/meta-data" -Value $MetaData -NoNewline
# --- REGION: https://yuruna.link/network#defining-guest-dhcp-client-identity
# Governs the INSTALLER's own DHCP request, and subiquity carries the network
# config it installed with into the target -- so the pin is present from the
# very first lease this guest ever asks for. The late-command in the
# autoinstall user-data patches the same key into the installed netplan and
# stays as the belt to this braces; it cannot replace this, because by the time
# a late-command runs the installer has already taken a lease under the default
# machine-id identity, and on a long lease that address is spent for a week.
# Matching en*/eth* by name lets one shared file cover enp0s1 on UTM, eth0 on
# Hyper-V and enp1s0 on KVM, and netplan resolves those globs against real
# devices. The match must hold: a seeded network-config REPLACES the config
# cloud-init would otherwise generate, so one that resolves to no interface
# leaves the guest -- or, during an install, the installer -- with no network.
Copy-Item -LiteralPath (Join-Path $HostVmConfigDir 'guest-dhcp.network-config') `
    -Destination "$SeedDir/network-config" -Force

# --- REGION: Generate cloud-init seed ISO
$SeedIso = Join-Path $vmDir "seed.iso"
Write-Verbose "Generating seed.iso with autoinstall configuration..."
CreateIso -SourceDir $SeedDir -OutputFile $SeedIso -VolumeId "cidata"

# --- REGION: https://yuruna.link/definition#defining-the-vm-memory-policy
# Static (min=max=startup, dynamic disabled) so a hung swap/paging never
# distorts a cycle -- see docs/vmconfig.md#disable-swap.
try { $vmMemoryBytes = ConvertTo-MemoryStartupBytes $MemoryStartupBytes } catch { Write-Error $_.Exception.Message; exit 1 }
if ($vmMemoryBytes -le 0) { $vmMemoryBytes = 12288MB }
Write-Verbose "VM memory: $([math]::Round($vmMemoryBytes / 1GB, 2)) GB ($vmMemoryBytes bytes)."

# --- REGION: Create and configure the Hyper-V VM
Write-Verbose "Creating new VM '$VMName' on switch '$switchName'..."
Hyper-V\New-VM -Name $VMName -Generation 2 -MemoryStartupBytes $vmMemoryBytes -SwitchName $switchName -VHDPath $vhdxFile | Out-Null

# --- REGION: https://yuruna.link/network#defining-deterministic-guest-mac-addresses
# Hyper-V takes bare hex, no separators.
# Keyed on the guest's durable identity, not on the name the VM carries now: a
# guest is built in a per-kind slot and renamed to its real name when its
# baseline is snapshotted, and an address that moved with that rename would
# re-DHCP a guest whose own state already records the one it was built on.
$YurunaGuestMac = Get-YurunaGuestMacAddress -VMName $GuestHostname
Hyper-V\Set-VMNetworkAdapter -VMName $VMName -StaticMacAddress ($YurunaGuestMac -replace ':','')
Write-Verbose "Deterministic guest MAC for '$GuestHostname': $YurunaGuestMac"

if (-not (Hyper-V\Get-VM -Name $VMName -ErrorAction SilentlyContinue)) {
    Write-Error "Hyper-V\New-VM completed but '$VMName' is not registered; aborting before configuration."
    exit 1
}
Set-VM -Name $VMName -MemoryStartupBytes $vmMemoryBytes -MemoryMinimumBytes $vmMemoryBytes -MemoryMaximumBytes $vmMemoryBytes -AutomaticCheckpointsEnabled $false | Out-Null
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off | Out-Null

# --- REGION: docs/host-hyperv.md#arm64-hosts-the-heartbeat-channel-wedges-a-linux-guest
# No-op on AMD64. On ARM64 the heartbeat channel stops this guest booting
# at all -- it freezes on the hv_utils IC version lines, one driver short of
# hv_storvsc, so the root disk never enumerates and the installer is never
# reached. Set before the DVDs are attached so the guest's first boot is
# already free of it.
$null = Disable-HyperVHeartbeatForLinuxGuest -VMName $VMName -Confirm:$false

# --- REGION: https://yuruna.link/vmconfig#hyper-v-iso-ace-bloat
# Prune stale per-VM ACEs accumulated on this SHARED base image before
# Hyper-V appends this VM's ACE on attach; the DACL otherwise grows unbounded
# across runs and the attach fails with 0x8007053C.
$prunedAce = Remove-OrphanedVMFileAccess -Path $baseImageFile
if ($prunedAce -gt 0) { Write-Verbose "Pruned $prunedAce stale per-VM ACE(s) from base image before attach." }
Add-VMDvdDrive -VMName $VMName -Path $baseImageFile | Out-Null
Add-VMDvdDrive -VMName $VMName -Path $SeedIso | Out-Null

# Boot order: DVD (Ubuntu ISO) first, then hard drive
$dvdDrive = Get-VMDvdDrive -VMName $VMName | Where-Object { $_.Path -eq $baseImageFile }
Set-VMFirmware -VMName $VMName -FirstBootDevice $dvdDrive

# --- REGION: https://yuruna.link/definition#defining-the-vm-core-count-policy
$hostCores = (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
if ($hostCores -lt 4) {
    Write-Error "Host has $hostCores physical cores; Yuruna requires at least 4. See https://yuruna.link/definition#defining-the-vm-core-count-policy"
    exit 1
}
$vmCores = [math]::Max(4, [math]::Floor($hostCores / 2))
# Cascaded variables.cores overrules the default calculation; clamp to the
# host's physical cores so an over-ask can't fail Set-VMProcessor.
if ($Cores) {
    $coresInt = 0
    if (-not [int]::TryParse($Cores, [ref]$coresInt) -or $coresInt -lt 1) {
        Write-Error "Invalid -Cores '$Cores': expected a positive integer."
        exit 1
    }
    if ($coresInt -gt $hostCores) {
        Write-Warning "Requested -Cores $coresInt exceeds host physical cores ($hostCores); clamping to $hostCores."
        $coresInt = $hostCores
    }
    $vmCores = $coresInt
}
# No-op on AMD64. On ARM64 a Linux guest's virtual processors trap into the
# hypervisor at a rate that grows with their number, and the trapped time comes
# out of guest execution rather than adding to it -- so the count divides the
# speed of every serial path without raising delivered compute. A boot is such
# a path, which is why it is what shows the cost.
$vmCores = Limit-HyperVLinuxGuestCoreCount -RequestedCores $vmCores
# Virtualization extensions only on request (validated in the environment
# checks above): the flag is unsupported on ARM64 hosts and unnecessary for
# guests that run no hypervisor of their own.
$vmProcessorArgs = @{ VMName = $VMName; Count = $vmCores }
if ($exposeVirt) { $vmProcessorArgs.ExposeVirtualizationExtensions = $true }
Set-VMProcessor @vmProcessorArgs | Out-Null

# WARNING: The test harness OCR is calibrated for 1920x1080.
# Changing this resolution may break automated screen-text detection
# in waitForText sequence steps.
Set-VMVideo -VMName $VMName -HorizontalResolution 1920 -VerticalResolution 1080 -ResolutionType Single

# --- REGION: Cleanup temporary folders
Remove-Item -LiteralPath $SeedDir -Recurse -Force -ErrorAction SilentlyContinue

# --- REGION: Guidance
Write-Verbose "VM '$VMName' created and configured."
Write-Verbose "Start the VM from Hyper-V Manager to begin Ubuntu Server installation."
Write-Verbose "Boot sequence:"
Write-Verbose "  1. Ubuntu Server autoinstalls via subiquity (~5-10 min)"
Write-Verbose "  2. First boot: text-mode login prompt."
Write-Verbose "Default credentials - username: $Username, password: <vault-managed> (must be changed on first login). Vault: test/status/extension/authentication/vault.yml"
Write-Verbose "After installation completes, remove the DVD drives:"
Write-Verbose "  Get-VMDvdDrive -VMName '$VMName' | Remove-VMDvdDrive"
