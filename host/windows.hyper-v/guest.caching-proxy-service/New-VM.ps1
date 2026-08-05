<#PSScriptInfo
.VERSION 2026.08.05
.GUID 42f1b2c3-d4e5-4f67-8901-a2b3c4d5e6f8
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
    Creates (or recreates) the squid HTTP-caching-proxy service VM on Hyper-V.

.DESCRIPTION
    Builds a lightweight Ubuntu Server cloud-image VM that runs Squid on
    port 3128. Guest VMs that set their HTTP proxy to this VM's IP will
    transparently cache every cacheable HTTP response -- including the
    .deb packages the Ubuntu installer fetches during its kernel install
    step, which security.ubuntu.com rate-limits with intermittent 429
    failures when each guest fetches them uncached.

    The VM is named "caching-proxy-service" by default. Run Get-Image.ps1 first to
    download the base cloud image.

    After creation the script starts the VM, waits for cloud-init to finish
    and squid to listen on port 3128, then prints the proxy URL that guest
    VMs should use.

.PARAMETER VMName
    Name of the Hyper-V VM. Default: caching-proxy-service

.PARAMETER MacAddress
    Optional stable MAC for the VM's NIC (AA:BB:CC:DD:EE:FF, dashed, or
    bare hex). Lets the operator pin the cache IP with a one-time DHCP
    reservation on the LAN router; without it Hyper-V assigns a fresh
    dynamic MAC on every rebuild and the lease moves.

.EXAMPLE
    .\Get-Image.ps1
    .\New-VM.ps1
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = "yuruna-caching-proxy-service",
    [Parameter()]
    [string]$MacAddress
)

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Output "Invalid VMName '$VMName'. Only alphanumeric characters, dots, hyphens, and underscores are allowed."
    exit 1
}

$global:InformationPreference = "Continue"
$global:ProgressPreference    = "SilentlyContinue"

$commonModulePath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath "modules/Yuruna.Host.psm1"
Import-Module -Name $commonModulePath -Force

# Normalize the optional stable MAC before any teardown/creation work so a
# typo'd value stops the run while the previous VM is still intact.
# ConvertTo-YurunaMacAddress comes from Yuruna.Common (global import above).
if ($MacAddress) {
    $MacAddress = ConvertTo-YurunaMacAddress -MacAddress $MacAddress
    if (-not $MacAddress) {
        Write-Error "Invalid -MacAddress (see warning above). Nothing was changed."
        exit 1
    }
}

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

# --- REGION: Grow the per-VM disk to 512 GB
# Dynamic VHDX, so 512 GB is the nominal size only -- the file grows as the
# guest writes. Sized for squid's `cache_dir ufs /var/spool/squid 393216`
# (= 384 GB) + ~128 GB OS/logs/headroom, and the `maximum_object_size 65 GB`
# directive in host/vmconfig/caching-proxy-service.base.user-data that lets
# the proxy cache multi-GB blobs end-to-end instead of bypassing them.
# An undersized cache disk fills after the first prewarm, so this is fatal.
if (-not (Expand-ExtensionVmDisk -Path $vhdxFile -SizeBytes 512GB -Format 'vhdx')) {
    Write-Error "Could not resize '$vhdxFile' to 512 GB; refusing to build the cache VM on base-capacity disk."
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

Copy-Item -Path (Join-Path $hostVmConfigDir 'caching-proxy-service.meta-data') -Destination "$SeedDir/meta-data"

# --- REGION: Yuruna harness SSH key
# Load the yuruna test-harness SSH public key -- same module the Ubuntu
# Desktop guest uses; one keypair grants passwordless access to every VM
# (including this cache VM, for debugging squid/cloud-init).
$TestSshModule = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) "test/modules/Test.Ssh.psm1"
Import-Module $TestSshModule -Force
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error "Get-YurunaSshPublicKey returned empty. Module path: $TestSshModule"; exit 1 }

# --- REGION: Cache-VM admin password
# --- REGION: https://yuruna.link/caching-proxy-service#cache-vm-password-persistence
# The runtime state file <track>/yuruna-caching-proxy-service.yml is the source of
# truth; Set-Password rehydrates the vault from it before Get-Password.
$_repoRootForExt = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.Extension.psm1')    -Global -Force -Verbose:$false
Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.CachingProxyService.psm1') -Global -Force -Verbose:$false
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$persisted = (Read-CachingProxyServiceState).password
if ($persisted) { Set-Password -Username 'caching-proxy-service-admin' -NewPassword $persisted }
$AdminPassword = Get-Password -Username 'caching-proxy-service-admin'
if (-not $AdminPassword) { Write-Error "Get-Password returned empty for 'caching-proxy-service-admin'."; exit 1 }
Write-Output "Password came from authentication mechanism: $_authActiveName"
Write-Output "See configuration at: $(Resolve-ExtensionAreaDir -Area 'authentication')"
[void](Save-CachingProxyServiceState -Secret $AdminPassword -Confirm:$false)
# Resolve the file path once for the Write-Output lines below.
$PasswordFile = Get-CachingProxyServiceStatePath

# --- REGION: Pick a vSwitch (BEFORE building user-data)
# Prefer the Yuruna External vSwitch (bridged to the host's primary physical
# NIC) so the cache VM gets a real LAN IP via DHCP and remote LAN clients
# reach it directly. Fall back to the built-in Default Switch when no External
# vSwitch can be created. Resolved here (not just before VM-create) because
# Get-GuestReachableHostIp below derives the seed's host IP from the switch
# topology (Default Switch = 172.x gateway; External = host LAN IP).
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
    Write-Information "  Cache VM will not be reachable from LAN by its own IP, and remote clients routed via netsh portproxy will appear as the host's vEthernet IP in squid's access.log (see docs/caching.md)."
}

# --- REGION: https://yuruna.link/network#cache-vm-seed-host-binding
# Hyper-V: the host IP comes from the vSwitch picked above (Get-GuestReachableHostIp -SwitchName); empty -> github fallback.
$YurunaHostIp = Get-GuestReachableHostIp -SwitchName $switchName
if (-not $YurunaHostIp) { $YurunaHostIp = '' }
$YurunaHostPort = '8080'
$YurunaTestConfig = Join-Path $_repoRootForExt 'test/test.config.yml'
$tc = $null
if (Test-Path $YurunaTestConfig) {
    try {
        $tc = Get-Content -Raw $YurunaTestConfig | ConvertFrom-Yaml -Ordered
        if ($tc.statusService.port) { $YurunaHostPort = "$($tc.statusService.port)" }
    } catch { Write-Verbose "test.config.yml parse failed: $_" }
}

# --- REGION: networkStorage pool (ypool-nas) service replication
# --- REGION: https://yuruna.link/caching-proxy-service#cache-vm-nas-and-config-service
# Bake the networkUser credential name, share path, and host id, resolved
# here on the host (networkStorage pool config + vault).
Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.PoolStorage.psm1') -Force
Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.YurunaDir.psm1')   -Force
$ypoolNasCfg = $null
if ($tc) { try { $ypoolNasCfg = Get-YurunaPoolStorageConfig -Config $tc } catch { Write-Verbose "ypool-nas config: $_" } }
$ypoolNasHostId = ''
try { $ypoolNasHostId = [string](Get-YurunaHostId) } catch { $ypoolNasHostId = '' }
if (-not $ypoolNasHostId) { $ypoolNasHostId = 'unknown-host' }
$ypoolNasUser    = if ($ypoolNasCfg) { [string]$ypoolNasCfg.NetworkUser } else { '' }
$ypoolNasNetPath = if ($ypoolNasCfg) { Get-PoolStorageUncPath -Path $ypoolNasCfg.NetworkPath -Style unix } else { '' }
# Refuse to bake a value containing a single quote: it would unbalance the guest's
# single-quoted, sourced /etc/yuruna/ypool-nas.env and could strand the guest's runcmd.
if (($ypoolNasNetPath -match "'") -or ($ypoolNasUser -match "'")) {
    Write-Warning "networkStorage pool: networkPath/networkUser contains a single quote; skipping caching-proxy service replication."
    $ypoolNasUser = ''; $ypoolNasNetPath = ''
}
# REPLICATE turns on only when pool storage is configured; the NAS password
# is NOT baked -- the config service serves it at runtime (/v1/nas/pool).
$ypoolNasReplicate = if ($ypoolNasCfg -and $ypoolNasUser -and $ypoolNasNetPath) { 'true' } else { 'false' }

# --- REGION: Lab shared bearer (control proofs + push-ingest + lab-token exchange)
# --- REGION: https://yuruna.link/caching-proxy-service#cache-vm-nas-and-config-service
# Empty vaultKey means the token is unset: do NOT call Get-Password then (it
# would auto-generate a junk per-host token). 'lab-auth-token' first, then the
# legacy 'pool-auth-token' name, so a host enrolled under the old logical user
# rebuilds its proxy with the token the pool already shares.
$labAuthToken = ''
# A read that THREW is not the same as a vault with no entry: the vault lock
# can time out, and a mint on that path would replace a token the rest of the
# lab still shares. Track the difference so only a completed read that found
# nothing reaches the mint below.
$labTokenReadFailed = $false
try {
    foreach ($labLogical in @('lab-auth-token', 'pool-auth-token')) {
        $paEff = Get-EffectiveUser -LogicalUser $labLogical
        if ($paEff.vaultKey -and (Test-VaultEntry -VaultKey $paEff.vaultKey)) {
            $labAuthToken = [string](Get-Password -Username $labLogical)
            break
        }
    }
} catch {
    $labTokenReadFailed = $true
    Write-Warning ("lab-auth-token: reading this host's vault failed ($($_.Exception.Message)). Building with an EMPTY token and leaving the vault untouched: " +
        "the proxy will mint no control proofs, push-ingest stays disabled, and the dashboard shows no Lab token. Resolve the vault error and rebuild.")
}
# Refuse a token carrying a newline or quote: it would corrupt the baked token file or
# the runner's bearer header.
if ($labAuthToken -match '[\r\n''"]') {
    Write-Warning ("lab-auth-token in this host's vault contains a newline or quote character, which would corrupt the baked token file; building with an EMPTY token. " +
        "Re-enroll this host (pwsh test/Set-LabToken.ps1) or store a clean value, then rebuild.")
    $labAuthToken = ''
    $labTokenReadFailed = $true
}
# No stored token -> mint one and store it NOW, so the proxy is never built
# with an empty token (which would mint no control proofs, keep /ingest 503,
# show no Lab token on the dashboard, and turn every joining host's remote
# control into a 403). The building host becomes the lab's first enrolled
# member; every other host receives the same value through the dashboard's
# Lab token (pwsh test/Set-LabToken.ps1).
if ([string]::IsNullOrEmpty($labAuthToken) -and -not $labTokenReadFailed) {
    $labAuthToken = [Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLowerInvariant()
    Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.ConfigServiceSync.psm1') -Global -Force -DisableNameChecking
    $labProvision = Set-LabAuthToken -Token $labAuthToken
    if ($labProvision.ok) {
        Write-Output "lab-auth-token: none was stored on this host; minted one and stored it (vaultKey '$($labProvision.vaultKey)')."
    } else {
        Write-Warning ("Could not store a freshly minted lab-auth-token in this host's vault " +
            "(keyChanged=$($labProvision.keyChanged), verified=$($labProvision.verified)); building with an EMPTY " +
            "token: the proxy will mint no control proofs, push-ingest stays disabled, and the dashboard shows " +
            "no Lab token until one is provisioned and the proxy rebuilt.")
        $labAuthToken = ''
    }
}

# --- REGION: config service mTLS materials
# --- REGION: https://yuruna.link/caching-proxy-service#cache-vm-nas-and-config-service
# Mint a per-VM client leaf signed by THIS host's Config CA; PEMs are baked
# base64 so they survive the cloud-init write_files block scalar.
Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.ConfigServiceCA.psm1') -Force
$configPort = '8443'
if ($tc -and $tc.configService -and $tc.configService.port) { $configPort = "$($tc.configService.port)" }
$configClientCertB64 = ''
$configClientKeyB64  = ''
$configCaCertB64     = ''
try {
    $clientPem  = New-YurunaConfigClientCertificate -SubjectName $VMName -HostId $ypoolNasHostId
    $utf8NoBom  = [System.Text.UTF8Encoding]::new($false)
    $configClientCertB64 = [Convert]::ToBase64String($utf8NoBom.GetBytes($clientPem.CertificatePem))
    $configClientKeyB64  = [Convert]::ToBase64String($utf8NoBom.GetBytes($clientPem.PrivateKeyPem))
    $configCaCertB64     = [Convert]::ToBase64String($utf8NoBom.GetBytes($clientPem.CaCertificatePem))
} catch {
    Write-Warning "Host Config CA: could not mint a client cert ($($_.Exception.Message)); the cache VM falls back to its baked NAS credential (dynamic rotation disabled for this VM)."
}

# Render user-data from the shared base + Hyper-V overlay
# (host/vmconfig/caching-proxy-service.*). New-CloudInitUserData resolves the
# SSH-key and password placeholders with literal .Replace(), so values
# carrying regex-special chars are safe.
Import-Module (Join-Path $_repoRootForExt 'automation/Yuruna.CloudInitTemplate.psm1') -Force
$UserData = New-CloudInitUserData `
    -BasePath    (Join-Path $_repoRootForExt 'host/vmconfig/caching-proxy-service.base.user-data') `
    -OverlayPath (Join-Path $_repoRootForExt 'host/vmconfig/caching-proxy-service.hyperv.overlay.yml') `
    -RepoRoot    $_repoRootForExt `
    -Replacement @{
        SSH_AUTHORIZED_KEY_PLACEHOLDER = $SshAuthorizedKey
        PASSWORD_PLACEHOLDER           = $AdminPassword
        YURUNA_STATUS_SERVICE_IP_PLACEHOLDER     = $YurunaHostIp
        YURUNA_STATUS_SERVICE_PORT_PLACEHOLDER   = $YurunaHostPort
        YPOOL_NAS_REPLICATE_PLACEHOLDER     = $ypoolNasReplicate
        YPOOL_NAS_NETWORK_PATH_PLACEHOLDER  = $ypoolNasNetPath
        YPOOL_NAS_NETWORK_USER_PLACEHOLDER  = $ypoolNasUser
        YPOOL_NAS_HOST_ID_PLACEHOLDER       = $ypoolNasHostId
        LAB_AUTH_TOKEN_PLACEHOLDER     = $labAuthToken
        YURUNA_CONFIG_SERVICE_PORT_PLACEHOLDER               = $configPort
        YURUNA_CONFIG_SERVICE_CLIENT_CERT_BASE64_PLACEHOLDER = $configClientCertB64
        YURUNA_CONFIG_SERVICE_CLIENT_KEY_BASE64_PLACEHOLDER  = $configClientKeyB64
        YURUNA_CONFIG_SERVICE_CA_CERT_BASE64_PLACEHOLDER     = $configCaCertB64
    } `
    -AllowedUnresolved 'AGGREGATOR_BASE_PLACEHOLDER' `
    -Confirm:$false
Set-Content -Path "$SeedDir/user-data" -Value $UserData -NoNewline

$SeedIso = Join-Path $vmDir "seed.iso"
Write-Output "Generating seed.iso with cloud-init configuration..."
CreateIso -SourceDir $SeedDir -OutputFile $SeedIso -VolumeId "cidata"

# Surface credentials BEFORE the long VM-create/boot/cloud-init wait.
# If anything in those 20-35 minutes fails (cloud-init stall, apt rate-
# limit, yuruna.conf parse error), the operator needs to console-login
# via vmconnect -- without the password they'd have to dig seed.iso off
# disk. The final "ready" banner reprints the same credentials.
Write-Output ""
Write-Output "== caching-proxy-service console/SSH login (available NOW) =="
Write-Output "  user:     caching-proxy-service-admin"
Write-Output "  password: $PasswordFile"
Write-Output "  If the wait below stalls or fails, open 'vmconnect localhost $VMName'"
Write-Output "  and log in with the credentials above to inspect cloud-init state."
Write-Output ""

# --- REGION: Create and configure Hyper-V VM
# --- REGION: https://yuruna.link/caching-proxy-service#cache-vm-sizing
# 12 GB RAM, 4 vCPU on all three hosts, budgeted around squid's cache_mem;
# swap is masked, so undersizing is an unrecoverable OOM.
Write-Output "Creating new VM '$VMName' on switch '$switchName'..."
Hyper-V\New-VM -Name $VMName -Generation 2 -MemoryStartupBytes 12GB -SwitchName $switchName -VHDPath $vhdxFile | Out-Null
if ($MacAddress) {
    # Pin the NIC's MAC before first start so the very first DHCP request
    # already carries it -- an operator DHCP reservation keyed to this MAC
    # then gives the cache VM a known, stable IP across rebuilds.
    # StaticMacAddress takes bare hex (no separators).
    Set-VMNetworkAdapter -VMName $VMName -StaticMacAddress ($MacAddress -replace ':', '') | Out-Null
    Write-Output "  NIC pinned to static MAC $MacAddress"
}
Set-VM -Name $VMName -MemoryStartupBytes 12GB -MemoryMinimumBytes 12GB -MemoryMaximumBytes 12GB -AutomaticCheckpointsEnabled $false | Out-Null
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off | Out-Null
Add-VMDvdDrive -VMName $VMName -Path $SeedIso | Out-Null
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

# --- REGION: Start VM and wait for squid
Write-Output "Starting VM '$VMName'..."
Hyper-V\Start-VM -Name $VMName

Write-Output "Waiting for VM to obtain an IP address..."
Write-Output "  (first boot runs cloud-init: apt update + install squid + hyperv-daemons;"
Write-Output "   this can take 5-15 minutes on a slow connection -- be patient)"

# Discover the cache VM's IP via Get-CacheVmCandidateIp (Yuruna.Host.psm1,
# KVP+ARP). Same primitive called by consumers (ubuntu guests) and
# Start-CachingProxyServiceVM.ps1's summary, so producer and consumers never see
# different answers about which IPs belong to this VM.
#
# No :3128 probe in this loop -- squid isn't listening yet (cloud-init is
# what we're waiting for). A later loop ("Waiting for squid to listen on
# port 3128") takes $cacheCandidateIps and tiebreaks stale vs live ARP
# entries by picking whichever answers squid.
$cacheIp = $null
$cacheCandidateIps = @()
$vmDiscoveryLogged = $false
$cacheVmOnExternalSwitch = $false
$arpProbeAnnounced = $false

# The ARP sweep only makes sense on a bridged (External) switch, where the
# host is not the DHCP server and never observes the guest's lease. The
# External vSwitch name is operator-configurable (Get-OrCreateYurunaExternalSwitch
# honors a pre-created switch under any name), so key off the switch this
# script resolved rather than a literal name -- a literal silently skips the
# sweep on a host that named its bridge anything else.
$switchIsExternal = ((Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue).SwitchType -eq 'External')

# A Hyper-V vSwitch object outlives its uplink binding across a host reboot,
# so the switch still existing is not evidence that its bridge forwards. When
# the bridge is dead the VM's DHCP request never reaches the LAN and no amount
# of waiting produces an address, so bound the discovery budget instead of
# spending the full 20 minutes re-proving it. The classifier is driver-private
# and may be absent, in which case the uplink is treated as usable.
$uplinkVerdict = 'unknown'
if ($switchIsExternal -and (Get-Command Test-YurunaExternalSwitchUplink -ErrorAction SilentlyContinue)) {
    $uplinkVerdict = Test-YurunaExternalSwitchUplink -SwitchName $switchName
}
$uplinkDegraded = ($uplinkVerdict -notin @('healthy', 'unknown'))
if ($uplinkDegraded) {
    Write-Warning "vSwitch '$switchName' classifies as '$uplinkVerdict': its bridge has no working uplink, so the cache VM cannot obtain a LAN address on it. Shortening the IP-discovery wait."
}
# 5s per iteration: 20 minutes normally, 3 minutes when the bridge is known dead.
$maxIterations = if ($uplinkDegraded) { 36 } else { 240 }

# Re-enable Write-Progress for the wait loop (script default is
# SilentlyContinue so web-download progress doesn't spam non-interactive shells).
$ProgressPreference = 'Continue'
$activity  = "Waiting for '$VMName' cloud-init (squid install)"
$startTime = Get-Date
$baselineSizeMB = [math]::Round((Get-Item $vhdxFile).Length / 1MB, 0)

for ($i = 0; $i -lt $maxIterations; $i++) {
    # Hyper-V assigns MAC + leases an IP asynchronously after Start-VM;
    # first few iterations normally return an empty candidate list.
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($vm) {
        # On a bridged External vSwitch the host is no longer the DHCP server so
        # the cache VM's lease never lands in the host's ARP cache
        # passively. KVP would eventually populate IPAddresses but only
        # after cloud-init's runcmd starts hv_kvp_daemon -- that's 5-15
        # minutes of "not discovered yet" while the VM is fine. Active-
        # probe the subnet (parallel ICMP sweep, ~5s) to ARP-resolve
        # every host on the LAN; the cache VM appears in
        # Get-NetNeighbor on the next iteration. Default-Switch path
        # doesn't need this -- Hyper-V's NAT populates ARP at DHCP time.
        if ($i -eq 0) {
            $cacheVmOnExternalSwitch = $switchIsExternal -and
                (($vm | Get-VMNetworkAdapter -ErrorAction SilentlyContinue |
                        Select-Object -First 1).SwitchName -eq $switchName)
        }
        if ($cacheVmOnExternalSwitch -and $i -ge 6) {
            if (-not $arpProbeAnnounced) {
                Write-Output "  Active ARP probe on the '$switchName' subnet (cache VM has DHCP'd a LAN IP the host hasn't seen yet; KVP catches up later)..."
                $arpProbeAnnounced = $true
            }
            Invoke-YurunaExternalArpProbe -SwitchName $switchName
        }

        $cacheCandidateIps = @(Get-CacheVmCandidateIp -VM $vm)
        if ($cacheCandidateIps) {
            if (-not $vmDiscoveryLogged) {
                $vmMac = ($vm | Get-VMNetworkAdapter | Select-Object -First 1).MacAddress
                $vmMacDashed = if ($vmMac -match '^[0-9A-Fa-f]{12}$') {
                    (($vmMac -replace '(..)(?!$)', '$1-')).ToUpper()
                } else { '(unknown)' }
                Write-Output "  VM MAC: $vmMacDashed"
                Write-Output "  Discovered IP(s) for ${VMName}: $($cacheCandidateIps -join ', ')"
                $vmDiscoveryLogged = $true
            }
            break
        }
    }

    # Single-line progress: elapsed, CPU%, VHDX size + heartbeat status.
    # VHDX growth means cloud-init is making progress (apt unpacking).
    # Heartbeat = Hyper-V's view of integration services -- "OK" means
    # the VM is alive and the kernel is healthy even if KVP hasn't
    # started; "Lost Communication" / "No Contact" means the VM may be
    # frozen, panicked, or networking-broken.
    $elapsed  = [int]((Get-Date) - $startTime).TotalSeconds
    $pct      = [math]::Min(100, [math]::Round(($elapsed / ($maxIterations * 5)) * 100))
    $vmInfo   = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    $cpu      = if ($vmInfo) { $vmInfo.CPUUsage } else { 0 }
    $hb       = if ($vmInfo) { $vmInfo.Heartbeat } else { 'Unknown' }
    if ($null -eq $cpu) { $cpu = 0 }
    $sizeMB   = [math]::Round((Get-Item $vhdxFile).Length / 1MB, 0)
    $deltaMB  = $sizeMB - $baselineSizeMB
    $min      = [math]::Floor($elapsed / 60)
    $sec      = $elapsed % 60
    $status   = "elapsed ${min}m${sec}s | CPU ${cpu}% | heartbeat ${hb} | VHDX ${sizeMB} MB (+${deltaMB} MB since boot)"
    Write-Progress -Activity $activity -Status $status -PercentComplete $pct -SecondsRemaining (($maxIterations * 5) - $elapsed)

    Start-Sleep -Seconds 5
}

Write-Progress -Activity $activity -Completed

if (-not $cacheCandidateIps) {
    $waitMinutes = [int](($maxIterations * 5) / 60)
    # Name the topology that actually applies. Attributing every missing
    # lease to Wi-Fi sends the operator after the wrong cause on a wired
    # host, and prescribing Remove-VMSwitch is destructive: the long-lived
    # service VMs on that switch have no code path back onto a replacement.
    $switchDiagnosis = if ($uplinkDegraded) {
        @"
vSwitch '$switchName' classifies as '$uplinkVerdict': the bridge has no
working uplink, so the VM's DHCP request never reached the LAN. A vSwitch
object outlives its uplink binding across a host reboot, so the switch
still existing is not evidence that it forwards. Re-bind it to a live
physical adapter, or restore its management-OS vNIC, then re-run.
"@
    } elseif ($switchIsExternal) {
        @"
The VM is on the External vSwitch '$switchName' (uplink classified
'$uplinkVerdict'). If the host uplink is Wi-Fi, the AP refuses to forward a
bridged guest MAC's DHCP request -- a documented Hyper-V limitation; move
the host to a wired uplink. Otherwise the LAN DHCP server did not answer.
"@
    } else {
        @"
The VM is on '$switchName', where the host itself is the NAT/DHCP server, so
an address should have appeared within seconds. Suspect cloud-init or the
guest's own networking rather than the LAN.
"@
    }
    $detail = @"

=========================================================================
ERROR: caching-proxy-service VM '$VMName' did not obtain an IP address within $waitMinutes minutes.
=========================================================================

The VM is running but never showed up in the host's ARP cache and
never reported an IP via Hyper-V KVP. Exiting with failure so guest
installs won't silently fall back to direct CDN access and 429.

$switchDiagnosis
Accessing the VM for debugging:
  * Console:  vmconnect localhost $VMName
              login:    caching-proxy-service-admin
              password: $PasswordFile
              (cloud-init sets it from user-data; does NOT expire.)
  * SSH:      not available until the VM has a reachable IP -- that's
              what failed here, so console is the only path.

Diagnostic steps inside the VM:
  1. Check network:          ip -br a   # should show eth0 with an IPv4
  2. Check cloud-init:       cloud-init status --long
  3. Check squid:            systemctl status squid
  4. Check KVP daemon:       systemctl status hv-kvp-daemon
  5. View cloud-init logs:   sudo journalctl -u cloud-init -n 200

If cloud-init is still running (package install is slow or the mirror
is throttled), re-run .\New-VM.ps1 after it finishes -- the script is
idempotent and will rebuild the VM cleanly.
=========================================================================
"@
    $Host.UI.WriteLine([ConsoleColor]::Red, $Host.UI.RawUI.BackgroundColor, $detail)
    exit 1
}

Write-Output "Cache VM candidate IP(s): $($cacheCandidateIps -join ', ')"
Write-Output "Waiting for squid to listen on port 3128 (up to 15 minutes)..."
Write-Output "  (cloud-init installs squid + apache2, then pre-warms"
Write-Output "   the cache by pulling linux-firmware through the local proxy --"
Write-Output "   squid binds :3128 before pre-warm starts, so port response"
Write-Output "   usually happens 3-5 minutes in on a responsive mirror.)"

$portActivity = "Waiting for squid on :3128 (candidates: $($cacheCandidateIps -join ', '))"
$portMaxIterations = 360  # 360 * 2.5s = 15 minutes -- matches the cloud-init budget we advertise
$portStartTime = Get-Date

for ($i = 0; $i -lt $portMaxIterations; $i++) {
    # Probe each candidate on :3128. When ARP returned stale + live IPs
    # for one MAC, only the live one answers; whichever responds first
    # becomes the authoritative $cacheIp. Test-CachingProxyServicePort
    # (Yuruna.Host.psm1) is the shared non-blocking probe; 500 ms rides
    # over momentary scheduler stalls during heavy apt-install.
    $cacheHttpPort = Get-CachingProxyServicePort -Scheme http
    $connected = $false
    foreach ($ip in $cacheCandidateIps) {
        if (Test-CachingProxyServicePort -IpAddress $ip -Port $cacheHttpPort -TimeoutMs 500) {
            $cacheIp = $ip
            $connected = $true
            break
        }
    }

    if ($connected) {
        Write-Progress -Activity $portActivity -Completed
        Write-Output ""
        Write-Output "== caching-proxy-service is READY =="
        Write-Output "  VM:        $VMName"
        Write-Output "  IP:        $cacheIp"
        Write-Output "  Proxy:     http://${cacheIp}:${cacheHttpPort}"
        Write-Output "  Monitor:   ssh to the VM, then 'squidclient mgr:info'  (web UI dropped in Ubuntu 26.04)"
        Write-Output ""
        Write-Output "  Console/SSH login:"
        Write-Output "    user:     caching-proxy-service-admin"
        Write-Output "    password: $PasswordFile"
        Write-Output "    (also embedded in the seed.iso's user-data -- chpasswd)"
        Write-Output ""
        Write-Output "Pre-warm may still be running in the background (pulling"
        Write-Output "linux-firmware and the HWE kernel meta through the local"
        Write-Output "proxy). Confirm completion with 'squidclient mgr:storedir'"
        Write-Output "on the VM and checking cache occupancy > 0."
        Write-Output ""
        Write-Output "Guest VMs will auto-detect squid at port 3128 when their"
        Write-Output "New-VM.ps1 runs. Keep the VM running across cycles."
        exit 0
    }

    # Progress: elapsed, CPU%, VHDX growth since script start.
    # Rising VHDX / non-zero CPU = cloud-init still apt-installing.
    $totalBudgetSeconds = 900  # 15 minutes
    $elapsed = [int]((Get-Date) - $portStartTime).TotalSeconds
    $pct     = [math]::Min(100, [math]::Round(($elapsed / $totalBudgetSeconds) * 100))
    $cpu     = (Get-VM -Name $VMName -ErrorAction SilentlyContinue).CPUUsage
    if ($null -eq $cpu) { $cpu = 0 }
    $sizeMB  = [math]::Round((Get-Item $vhdxFile).Length / 1MB, 0)
    $deltaMB = $sizeMB - $baselineSizeMB
    $min     = [math]::Floor($elapsed / 60)
    $sec     = $elapsed % 60
    $status  = "elapsed ${min}m${sec}s | CPU ${cpu}% | VHDX ${sizeMB} MB (+${deltaMB} MB since boot)"
    Write-Progress -Activity $portActivity -Status $status -PercentComplete $pct -SecondsRemaining ($totalBudgetSeconds - $elapsed)

    Start-Sleep -Seconds 2  # 500ms WaitOne + 2s sleep = ~2.5s per iteration
}

Write-Progress -Activity $portActivity -Completed
$candidateList = $cacheCandidateIps -join ', '
$detail = @"

=========================================================================
ERROR: squid did not start listening on :3128 within 15 minutes.
  Candidate IPs probed: $candidateList
=========================================================================

The VM is running and has an IP, but port 3128 never accepted a TCP
connection. Exiting with failure so subsequent guest installs can't
silently fall back to direct CDN access and hit 429 rate limits.

Accessing the VM for debugging:
  * Console:  vmconnect localhost $VMName
              login:    caching-proxy-service-admin
              password: $PasswordFile
              (cloud-init sets it from user-data; does NOT expire.)
  * SSH:      ssh caching-proxy-service-admin@<candidate>    (try each of: $candidateList)
              (uses the yuruna harness key at test\status\ssh\yuruna_ed25519 --
               same key the Ubuntu Server guest uses; passwordless)

=== Step 1: find the actual apt / cloud-init error ===
'cloud-init status --long' only SHOWS the fact that something failed;
the REAL error is in the output log. Run this first -- it's the single
most useful diagnostic:

  sudo grep -E 'E:|429 |Hash Sum|Failed to fetch|Unable to locate|Exit code' /var/log/cloud-init-output.log | head -40

Or dump the whole tail:

  sudo tail -n 300 /var/log/cloud-init-output.log

Common patterns you'll see there:
  * '429 Too Many Requests'    -> Ubuntu's CDN is rate-limiting this
                                  host's public IP. Wait 15-30 min and
                                  re-run .\New-VM.ps1 (idempotent -- it
                                  rebuilds the VM cleanly).
  * 'Unable to locate package' -> a package name changed on the mirror;
                                  report the specific name so it can be
                                  fixed in host/vmconfig/caching-proxy-service.base.user-data.
  * 'Could not resolve'        -> DNS broken inside the VM. Check
                                  'resolvectl status' and netplan config.
  * Nothing obvious            -> run the fuller diagnostic block below.

=== Step 2: deeper diagnostics (only if step 1 is inconclusive) ===
  systemctl status squid                # 'could not be found' = install failed
  ss -ltn 'sport = :3128'               # port bound? who's listening?
  sudo ufw status ; sudo iptables -L -n # guest-side firewall
  ip -br a                              # IP matches one of: $candidateList ?

Recovery options:
  * Retry:   re-run .\New-VM.ps1 (idempotent rebuild).
  * Manual:  ssh in, fix (e.g. wait for rate-limit, then
             'sudo cloud-init clean --logs && sudo cloud-init init').
  * Probe:   Test-NetConnection -Port 3128 -ComputerName <candidate>   # each of: $candidateList
=========================================================================
"@
$Host.UI.WriteLine([ConsoleColor]::Red, $Host.UI.RawUI.BackgroundColor, $detail)
exit 1
