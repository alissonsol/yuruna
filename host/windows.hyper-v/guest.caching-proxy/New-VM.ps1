<#PSScriptInfo
.VERSION 2026.07.10
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
    Creates (or recreates) the squid HTTP-caching proxy VM on Hyper-V.

.DESCRIPTION
    Builds a lightweight Ubuntu Server cloud-image VM that runs Squid on
    port 3128. Guest VMs that set their HTTP proxy to this VM's IP will
    transparently cache every cacheable HTTP response -- including the
    .deb packages the Ubuntu installer fetches during its kernel install
    step, which security.ubuntu.com rate-limits with intermittent 429
    failures when each guest fetches them uncached.

    The VM is named "caching-proxy" by default. Run Get-Image.ps1 first to
    download the base cloud image.

    After creation the script starts the VM, waits for cloud-init to finish
    and squid to listen on port 3128, then prints the proxy URL that guest
    VMs should use.

.PARAMETER VMName
    Name of the Hyper-V VM. Default: caching-proxy

.EXAMPLE
    .\Get-Image.ps1
    .\New-VM.ps1
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = "yuruna-caching-proxy"
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
$downloadDir = (Get-VMHost).VirtualHardDiskPath
$baseImageName = "host.windows.hyper-v.guest.caching-proxy"
$baseImageFile = Join-Path $downloadDir "$baseImageName.vhdx"

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

Copy-Item -Path (Join-Path $hostVmConfigDir 'caching-proxy.meta-data') -Destination "$SeedDir/meta-data"

# --- REGION: Yuruna harness SSH key
# Load the yuruna test-harness SSH public key -- same module the Ubuntu
# Desktop guest uses; one keypair grants passwordless access to every VM
# (including this cache VM, for debugging squid/cloud-init).
$TestSshModule = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) "test/modules/Test.Ssh.psm1"
Import-Module $TestSshModule -Force
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error "Get-YurunaSshPublicKey returned empty. Module path: $TestSshModule"; exit 1 }

# --- REGION: Cache-VM yuruna password
# --- REGION: https://yuruna.link/caching-proxy#cache-vm-password-persistence
# The runtime state file <track>/yuruna-caching-proxy.yml is the source of
# truth; Set-Password rehydrates the vault from it before Get-Password.
$_repoRootForExt = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.Extension.psm1')    -Global -Force -Verbose:$false
Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.CachingProxy.psm1') -Global -Force -Verbose:$false
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$persisted = (Read-CachingProxyState).password
if ($persisted) { Set-Password -Username 'yuruna' -NewPassword $persisted }
$YurunaPassword = Get-Password -Username 'yuruna'
if (-not $YurunaPassword) { Write-Error "Get-Password returned empty for 'yuruna'."; exit 1 }
Write-Output "Password came from authentication mechanism: $_authActiveName"
Write-Output "See configuration at: $(Resolve-ExtensionAreaDir -Area 'authentication')"
[void](Save-CachingProxyState -Secret $YurunaPassword -Confirm:$false)
# Resolve the file path once for the Write-Output lines below.
$PasswordFile = Get-CachingProxyStatePath

# --- REGION: Pick a vSwitch (BEFORE building user-data)
# Prefer the Yuruna External vSwitch (bridged to the host's primary physical
# NIC) so the cache VM gets a real LAN IP via DHCP and remote LAN clients
# reach it directly. Fall back to the built-in Default Switch when no External
# vSwitch can be created. Resolved here (not just before VM-create) because
# Get-GuestReachableHostIp below derives the seed's host IP from the switch
# topology (Default Switch = 172.x gateway; External = host LAN IP).
$switchName = Get-OrCreateYurunaExternalSwitch
if (-not $switchName) {
    Write-Output "WARNING: External vSwitch unavailable -- falling back to 'Default Switch'."
    Write-Output "  Cache VM will not be reachable from LAN by its own IP, and remote"
    Write-Output "  clients routed via netsh portproxy will appear as the host's"
    Write-Output "  vEthernet IP in squid's access.log (see docs/caching.md)."
    $switchName = 'Default Switch'
}

# Yuruna host (status server) IP+port baked into the seed so the cache VM's
# cloud-init build block fetches collector/parser source from the LOCAL host
# working tree (/yuruna-repo/) instead of public github -- a rebuild never
# waits on the private->public mirror. Empty values make the build fall back
# to github. Start-CachingProxy.ps1 ensures the status server is running.
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
# --- REGION: https://yuruna.link/caching-proxy#cache-vm-nas-and-config-service
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
# is NOT baked -- the Host Config Service serves it at runtime (/v1/nas/pool).
$ypoolNasReplicate = if ($ypoolNasCfg -and $ypoolNasUser -and $ypoolNasNetPath) { 'true' } else { 'false' }

# --- REGION: Pool push-ingest shared bearer
# --- REGION: https://yuruna.link/caching-proxy#cache-vm-nas-and-config-service
# Empty vaultKey means push is DISABLED: do NOT call Get-Password then (it
# would auto-generate a junk per-host token); bake EMPTY instead.
$poolAuthToken = ''
try {
    $paEff = Get-EffectiveUser -LogicalUser 'pool-auth-token'
    if ($paEff.vaultKey -and (Test-VaultEntry -VaultKey $paEff.vaultKey)) {
        $poolAuthToken = [string](Get-Password -Username 'pool-auth-token')
    }
} catch { Write-Verbose "pool auth token: $($_.Exception.Message)" }
# Refuse a token carrying a newline or quote: it would corrupt the baked token file or
# the runner's bearer header.
if ($poolAuthToken -match '[\r\n''"]') {
    Write-Warning "pool.auth.token contains a newline or quote character; refusing to bake (push disabled)."
    $poolAuthToken = ''
}

# --- REGION: Host Config Service mTLS materials
# --- REGION: https://yuruna.link/caching-proxy#cache-vm-nas-and-config-service
# Mint a per-VM client leaf signed by THIS host's Config CA; PEMs are baked
# base64 so they survive the cloud-init write_files block scalar.
Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.HostConfigCA.psm1') -Force
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
# (host/vmconfig/caching-proxy.*). Build-CloudInitUserData resolves the
# SSH-key and password placeholders with literal .Replace(), so values
# carrying regex-special chars are safe.
Import-Module (Join-Path $_repoRootForExt 'automation/Yuruna.CloudInitTemplate.psm1') -Force
$UserData = Build-CloudInitUserData `
    -BasePath    (Join-Path $_repoRootForExt 'host/vmconfig/caching-proxy.base.user-data') `
    -OverlayPath (Join-Path $_repoRootForExt 'host/vmconfig/caching-proxy.hyperv.overlay.yml') `
    -RepoRoot    $_repoRootForExt `
    -Replacement @{
        SSH_AUTHORIZED_KEY_PLACEHOLDER = $SshAuthorizedKey
        PASSWORD_PLACEHOLDER           = $YurunaPassword
        YURUNA_HOST_IP_PLACEHOLDER     = $YurunaHostIp
        YURUNA_HOST_PORT_PLACEHOLDER   = $YurunaHostPort
        YPOOL_NAS_REPLICATE_PLACEHOLDER     = $ypoolNasReplicate
        YPOOL_NAS_NETWORK_PATH_PLACEHOLDER  = $ypoolNasNetPath
        YPOOL_NAS_NETWORK_USER_PLACEHOLDER  = $ypoolNasUser
        YPOOL_NAS_HOST_ID_PLACEHOLDER       = $ypoolNasHostId
        POOL_AUTH_TOKEN_PLACEHOLDER    = $poolAuthToken
        YURUNA_CONFIG_PORT_PLACEHOLDER               = $configPort
        YURUNA_CONFIG_CLIENT_CERT_BASE64_PLACEHOLDER = $configClientCertB64
        YURUNA_CONFIG_CLIENT_KEY_BASE64_PLACEHOLDER  = $configClientKeyB64
        YURUNA_CONFIG_CA_CERT_BASE64_PLACEHOLDER     = $configCaCertB64
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
Write-Output "== caching-proxy console/SSH login (available NOW) =="
Write-Output "  user:     yuruna"
Write-Output "  password: $PasswordFile"
Write-Output "  If the wait below stalls or fails, open 'vmconnect localhost $VMName'"
Write-Output "  and log in with the credentials above to inspect cloud-init state."
Write-Output ""

# --- REGION: Create and configure Hyper-V VM
# --- REGION: https://yuruna.link/caching-proxy#cache-vm-sizing
# 12 GB RAM, 4 vCPU -- same sizing on all three hosts, budgeted around
# squid's `cache_mem 9 GB`; swap is masked, so undersizing is an
# unrecoverable OOM.
Write-Output "Creating new VM '$VMName' on switch '$switchName'..."
Hyper-V\New-VM -Name $VMName -Generation 2 -MemoryStartupBytes 12GB -SwitchName $switchName -VHDPath $vhdxFile | Out-Null
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
# Start-CachingProxy.ps1's summary, so producer and consumers never see
# different answers about which IPs belong to this VM.
#
# No :3128 probe in this loop -- squid isn't listening yet (cloud-init is
# what we're waiting for). A later loop ("Waiting for squid to listen on
# port 3128") takes $cacheCandidateIps and tiebreaks stale vs live ARP
# entries by picking whichever answers squid.
$cacheIp = $null
$cacheCandidateIps = @()
$maxIterations = 240  # 240 * 5s = 20 minutes
$vmDiscoveryLogged = $false
$cacheVmOnExternalSwitch = $false
$arpProbeAnnounced = $false

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
        # On Yuruna-External, the host is no longer the DHCP server so
        # the cache VM's lease never lands in the host's ARP cache
        # passively. KVP would eventually populate IPAddresses but only
        # after cloud-init's runcmd starts hv_kvp_daemon -- that's 5-15
        # minutes of "not discovered yet" while the VM is fine. Active-
        # probe the subnet (parallel ICMP sweep, ~5s) to ARP-resolve
        # every host on the LAN; the cache VM appears in
        # Get-NetNeighbor on the next iteration. Default-Switch path
        # doesn't need this -- Hyper-V's NAT populates ARP at DHCP time.
        if ($i -eq 0) {
            $cacheVmOnExternalSwitch = (($vm | Get-VMNetworkAdapter -ErrorAction SilentlyContinue |
                                          Select-Object -First 1).SwitchName -eq 'Yuruna-External')
        }
        if ($cacheVmOnExternalSwitch -and $i -ge 6) {
            if (-not $arpProbeAnnounced) {
                Write-Output "  Active ARP probe on Yuruna-External subnet (cache VM has DHCP'd a LAN IP the host hasn't seen yet; KVP catches up later)..."
                $arpProbeAnnounced = $true
            }
            Invoke-YurunaExternalArpProbe -SwitchName 'Yuruna-External'
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
    $detail = @"

=========================================================================
ERROR: caching-proxy VM '$VMName' did not obtain an IP address within 20 minutes.
=========================================================================

The VM is running but never showed up in the host's ARP cache and
never reported an IP via Hyper-V KVP. Exiting with failure so guest
installs won't silently fall back to direct CDN access and 429.

If the VM is on the Yuruna-External vSwitch and the host is on Wi-Fi:
the AP probably refused to forward the cache VM's DHCP request -- this
is a known Hyper-V-on-Wi-Fi limitation. Use a wired connection, or
remove the Yuruna-External vSwitch (Remove-VMSwitch -Name 'Yuruna-External')
to fall back to Default Switch on the next New-VM.ps1 run.

Accessing the VM for debugging:
  * Console:  vmconnect localhost $VMName
              login:    yuruna
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
    # becomes the authoritative $cacheIp. Test-CachingProxyPort
    # (Yuruna.Host.psm1) is the shared non-blocking probe; 500 ms rides
    # over momentary scheduler stalls during heavy apt-install.
    $cacheHttpPort = Get-CachingProxyPort -Scheme http
    $connected = $false
    foreach ($ip in $cacheCandidateIps) {
        if (Test-CachingProxyPort -IpAddress $ip -Port $cacheHttpPort -TimeoutMs 500) {
            $cacheIp = $ip
            $connected = $true
            break
        }
    }

    if ($connected) {
        Write-Progress -Activity $portActivity -Completed
        Write-Output ""
        Write-Output "== caching-proxy is READY =="
        Write-Output "  VM:        $VMName"
        Write-Output "  IP:        $cacheIp"
        Write-Output "  Proxy:     http://${cacheIp}:${cacheHttpPort}"
        Write-Output "  Monitor:   ssh to the VM, then 'squidclient mgr:info'  (web UI dropped in Ubuntu 26.04)"
        Write-Output ""
        Write-Output "  Console/SSH login:"
        Write-Output "    user:     yuruna"
        Write-Output "    password: $PasswordFile"
        Write-Output "    (also embedded in the seed.iso's user-data -- chpasswd)"
        Write-Output ""
        Write-Output "Pre-warm may still be running in the background (pulling"
        Write-Output "linux-firmware and the HWE kernel meta through the local"
        Write-Output "proxy). Confirm completion by opening the Monitor URL"
        Write-Output "above -> 'storedir' and checking cache occupancy > 0."
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
              login:    yuruna
              password: $PasswordFile
              (cloud-init sets it from user-data; does NOT expire.)
  * SSH:      ssh yuruna@<candidate>    (try each of: $candidateList)
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
                                  fixed in host/vmconfig/caching-proxy.base.user-data.
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
