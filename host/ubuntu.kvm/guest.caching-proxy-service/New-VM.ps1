<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42f8395b-50cf-4a59-bfc3-49af26e60079
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
    Creates the squid HTTP-caching-proxy service VM on Ubuntu KVM (libvirt).

.DESCRIPTION
    Builds a libvirt VM that boots the Ubuntu 26.04 cloud image and runs
    Squid 7 on port 3128 plus an SSL-bump listener on 3129. Cloud-init
    (NoCloud seed) installs squid-openssl + apache2 +
    Prometheus + Grafana + loki + promtail + caching-proxy-parser-service,
    pre-warms linux-firmware through the proxy, then flips into
    `offline_mode on` so guest installs against this proxy work fully
    disconnected from the internet.

    Network choice:
      * Prefer the libvirt-defined `yuruna-external` bridge so the cache
        VM gets a real LAN IP via the upstream DHCP server and remote
        LAN clients reach it directly by IP. Squid then sees the actual
        client IP at TCP level with no host-side forwarder in the path.
      * Fall back to the built-in NAT 'default' network when no
        bridged network is defined. Cache still works for guests on
        the same host but is NOT reachable from LAN clients without an
        additional host-side port forwarder. README.md documents the
        net-define command for the bridged path.

.PARAMETER VMName
    libvirt domain name. Default: yuruna-caching-proxy-service

.PARAMETER MacAddress
    Optional stable MAC for the VM's NIC (AA:BB:CC:DD:EE:FF, dashed, or
    bare hex). Lets the operator pin the cache IP with a one-time DHCP
    reservation on the LAN router (bridged 'yuruna-external') or in the
    'default' network's dnsmasq (NAT fallback); without it virt-install
    assigns a fresh random MAC on every rebuild and the lease moves.
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = 'yuruna-caching-proxy-service',
    [Parameter()]
    [string]$MacAddress,
    # Sizing travels as a pair. Swap is masked in the guest, so a cache_mem that
    # outgrows its VM is an unrecoverable OOM rather than a slowdown -- passing
    # one without the other is the mistake these two parameters exist to make
    # visible. The defaults are the lab profile, and they stay literal because
    # the setup preflight reads the committed size out of this source.
    [Parameter()]
    [int]$MemoryMb = 12288,
    [Parameter()]
    [string]$SquidCacheMem = '7 GB'
)

# --- REGION: Log level from environment
# See https://yuruna.link/42e220c4-0003
# Reuse the caller's log module; a forced reload discards its state.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (-not (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) -and (Test-Path $_logLevelMod)) {
    Import-Module $_logLevelMod -Global
}
if (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) { Use-LogLevelFromEnv }

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Error "Invalid VMName '$VMName'. Only alphanumerics, dots, hyphens, underscores."
    exit 1
}
if (-not $IsLinux) {
    Write-Error "host/ubuntu.kvm/guest.caching-proxy-service/New-VM.ps1 only runs on Linux."
    exit 1
}

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Normalize the optional stable MAC before any image seek or VM work so a
# typo'd value stops the run before anything heavy or destructive happens.
if ($MacAddress) {
    Import-Module (Join-Path $ScriptDir '../../../automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    $MacAddress = ConvertTo-YurunaMacAddress -MacAddress $MacAddress
    if (-not $MacAddress) {
        Write-Error "Invalid -MacAddress (see warning above). Nothing was changed."
        exit 1
    }
}

# --- REGION: libvirt-qemu search ACL on $HOME
# See https://yuruna.link/42e220c4-0004
# Grant libvirt-qemu traverse-only access to the VM storage below this home directory.
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

if (-not (Assert-YurunaBaseImage -BaseImageFile $baseImageFile -GuestFolder $PSScriptRoot)) { exit 1 }

Write-Output "Creating VM '$VMName' using image: $baseImageFile"
# Provenance side-channel for operators reading the transcript. Emits
# "Provenance: <url>" when the sidecar is healthy; warns otherwise.
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))
Import-Module (Join-Path $repoRoot 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

# --- REGION: Remove existing VM
# See https://yuruna.link/42e220c4-0004
$virshUri = 'qemu:///system'
$destroyOut = & virsh --connect $virshUri destroy $VMName 2>&1
Write-Verbose "virsh destroy '$VMName' exit=$LASTEXITCODE output='$($destroyOut -join '; ')'"
# --- REGION: https://yuruna.link/42d69dfa-001e
$undefineOut = & virsh --connect $virshUri undefine --nvram --managed-save `
    --snapshots-metadata --checkpoints-metadata $VMName 2>&1
Write-Verbose "virsh undefine '$VMName' exit=$LASTEXITCODE output='$($undefineOut -join '; ')'"
$domainNames = @(& virsh --connect $virshUri list --all --name 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Cannot verify removal of '$VMName': virsh list failed: $($domainNames -join '; ')"
}
if ($domainNames | Where-Object { $_.ToString().Trim() -eq $VMName }) {
    $dominfo = (& virsh --connect $virshUri dominfo $VMName 2>&1 | Out-String).Trim()
    throw "virsh destroy + undefine left '$VMName' defined; aborting before re-creation.`ndominfo:`n$dominfo"
}

# --- REGION: Create copies and files for VM
# See https://yuruna.link/42e220c4-0004
# Copy the base image: a persistent VM cannot depend on a backing file that rotates.
$vmDir   = Join-Path $HOME "yuruna/vms/$VMName"
$diskImg = Join-Path $vmDir "$VMName.qcow2"
$seedImg = Join-Path $vmDir 'seed.iso'
New-Item -ItemType Directory -Force -Path $vmDir | Out-Null

# --- REGION: Copy base image -> per-VM disk
if (Test-Path -LiteralPath $diskImg) { Remove-Item -Force -LiteralPath $diskImg }
Write-Output "Copying base image to per-VM disk (sparse copy)..."
# `cp --sparse=always` preserves qcow2 hole semantics on ext4/btrfs/xfs.
# The cloud image is mostly empty; cp WITHOUT --sparse=always would fully
# allocate every hole in it.
& /bin/cp --sparse=always -- $baseImageFile $diskImg
if ($LASTEXITCODE -ne 0) {
    Write-Error "cp --sparse=always failed copying $baseImageFile -> $diskImg"
    exit 1
}

# --- REGION: Grow the per-VM disk to 512 GB
# See https://yuruna.link/42e220c4-0004
# Keep enough virtual capacity for the Squid cache and OS/log headroom.
if (-not (Expand-ExtensionVmDisk -Path $diskImg -SizeBytes 512GB -Format 'qcow2')) {
    Write-Error "Could not resize '$diskImg' to 512 GB; refusing to build the cache VM on base-capacity disk."
    exit 1
}

# --- REGION: Yuruna harness SSH key
# See https://yuruna.link/42e220c4-0004
# Seed the shared harness key so guest provisioning and failure diagnostics agree.
$TestSshModule = Join-Path $repoRoot 'test/modules/Test.Ssh.psm1'
Import-Module $TestSshModule -Force -DisableNameChecking
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error "Get-YurunaSshPublicKey returned empty. Module path: $TestSshModule"; exit 1 }

# --- REGION: Vault admin password
# See https://yuruna.link/42f6b05f-0041
# The runtime state file <track>/yuruna-caching-proxy-service.yml is the source of
# truth; Set-Password rehydrates the vault from it before Get-Password.
Import-Module (Join-Path $repoRoot 'test/modules/Test.Extension.psm1')    -Global -Force -Verbose:$false
Import-Module (Join-Path $repoRoot 'test/modules/Test.CachingProxyService.psm1') -Global -Force -Verbose:$false
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$persisted = (Read-CachingProxyServiceState).password
if ($persisted) { Set-Password -Username 'caching-proxy-service-admin' -NewPassword $persisted }
$AdminPassword = Get-Password -Username 'caching-proxy-service-admin'
if (-not $AdminPassword) { Write-Error "Get-Password returned empty for 'caching-proxy-service-admin'."; exit 1 }
Write-Output "Password came from authentication mechanism: $_authActiveName"
Write-Output "See configuration at: $(Resolve-ExtensionAreaDir -Area 'authentication')"
[void](Save-CachingProxyServiceState -Secret $AdminPassword -Confirm:$false)
$PasswordFile = Get-CachingProxyServiceStatePath

# --- REGION: Render user-data / meta-data
$baseUserData     = Join-Path $repoRoot 'host/vmconfig/caching-proxy-service.base.user-data'
$overlayUserData  = Join-Path $repoRoot 'host/vmconfig/caching-proxy-service.kvm.overlay.yml'
$metaDataTemplate = Join-Path $repoRoot 'host/vmconfig/caching-proxy-service.meta-data'
foreach ($f in @($baseUserData, $overlayUserData, $metaDataTemplate)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Error "Template missing: $f"
        exit 1
    }
}
# --- REGION: Select the guest network
# See https://yuruna.link/4220a755-001b
# KVM: Resolve-GuestHostBinding pairs the libvirt network + host IP (NAT 'default' -> 192.168.122.1); the resolved $networkName is reused below for virt-install.
Import-Module (Join-Path $repoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1') -Force -DisableNameChecking
$guestBinding = Resolve-GuestHostBinding
$networkName  = $guestBinding.NetworkName
$YurunaHostIp = $guestBinding.HostIp
Import-Module (Join-Path $repoRoot 'test/modules/Test.Config.psm1') -Global -Force
$_statusSeed = Get-YurunaStatusServiceSeed -RepoRoot $repoRoot
$YurunaHostPort = $_statusSeed.Port
$tc = $_statusSeed.Config

# --- REGION: Pool storage replication
# See https://yuruna.link/42f6b05f-0042
# Bake the networkUser credential name, share path, and host id, resolved
# here on the host (networkStorage pool config + vault).
Import-Module (Join-Path $repoRoot 'test/modules/Test.PoolStorage.psm1') -Force
Import-Module (Join-Path $repoRoot 'test/modules/Test.YurunaDir.psm1')   -Force
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

# --- REGION: Internal authentication key
# See https://yuruna.link/42f6b05f-0042
# Empty vaultKey means the token is unset: do NOT call Get-Password then (it
# would auto-generate a junk per-host key). 'internal-auth-key' first, then the
# legacy 'lab-auth-token' and 'pool-auth-token' names, so a host enrolled under
# an older logical user rebuilds its proxy with the key the pool already shares.
$internalAuthKey = ''
# A read that THREW is not the same as a vault with no entry: the vault lock
# can time out, and a mint on that path would replace a token the rest of the
# lab still shares. Track the difference so only a completed read that found
# nothing reaches the mint below.
$keyReadFailed = $false
try {
    foreach ($keyLogical in @('internal-auth-key', 'lab-auth-token', 'pool-auth-token')) {
        $paEff = Get-EffectiveUser -LogicalUser $keyLogical
        if ($paEff.vaultKey -and (Test-VaultEntry -VaultKey $paEff.vaultKey)) {
            $internalAuthKey = [string](Get-Password -Username $keyLogical)
            break
        }
    }
} catch {
    $keyReadFailed = $true
    Write-Warning ("internal authentication key: reading this host's vault failed ($($_.Exception.Message)). Building with an EMPTY key and leaving the vault untouched: " +
        "the proxy will mint no control proofs, push-ingest stays disabled, and the dashboard shows no Lab token. Resolve the vault error and rebuild.")
}
# Refuse a token carrying a newline or quote: it would corrupt the baked token file or
# the runner's bearer header.
if ($internalAuthKey -match '[\r\n''"]') {
    Write-Warning ("The internal authentication key in this host's vault contains a newline or quote character, which would corrupt the baked key file; building with an EMPTY key. " +
        "Re-enroll this host (pwsh test/lab/Set-LabToken.ps1) or store a clean value, then rebuild.")
    $internalAuthKey = ''
    $keyReadFailed = $true
}
# No stored token -> mint one and store it NOW, so the proxy is never built
# with an empty token (which would mint no control proofs, keep /ingest 503,
# show no Lab token on the dashboard, and turn every joining host's remote
# control into a 403). The building host becomes the lab's first enrolled
# member; every other host receives the same value through the dashboard's
# Lab token (pwsh test/lab/Set-LabToken.ps1).
if ([string]::IsNullOrEmpty($internalAuthKey) -and -not $keyReadFailed) {
    $internalAuthKey = [Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLowerInvariant()
    Import-Module (Join-Path $repoRoot 'test/modules/Test.ConfigServiceSync.psm1') -Global -Force -DisableNameChecking
    $keyProvision = Set-InternalAuthKey -Token $internalAuthKey
    if ($keyProvision.ok) {
        Write-Output "internal authentication key: none was stored on this host; minted one and stored it (vaultKey '$($keyProvision.vaultKey)')."
    } else {
        Write-Warning ("Could not store a freshly minted internal authentication key in this host's vault " +
            "(keyChanged=$($keyProvision.keyChanged), verified=$($keyProvision.verified)); building with an EMPTY " +
            "token: the proxy will mint no control proofs, push-ingest stays disabled, and the dashboard shows " +
            "no Lab token until one is provisioned and the proxy rebuilt.")
        $internalAuthKey = ''
    }
}

# --- REGION: Docker Hub pull-through credential
# See https://yuruna.link/42e220c4-0004
# Only use stored Docker Hub credentials; a generated password cannot authenticate.
$dockerHubUsername = ''
$dockerHubToken    = ''
$dockerHubWarned   = $false
try {
    $dhEff = Get-EffectiveUser -LogicalUser 'dockerhub-token'
    if ($dhEff.vaultKey -and (Test-VaultEntry -VaultKey $dhEff.vaultKey)) {
        $dockerHubToken = [string](Get-Password -Username 'dockerhub-token')
        # loginUser falls back to the logical user's own name when the mapping
        # names no account, so that value means "no username configured" rather
        # than a Docker Hub identity.
        if ($dhEff.loginUser -and ($dhEff.loginUser -ne 'dockerhub-token')) {
            $dockerHubUsername = [string]$dhEff.loginUser
        }
    }
} catch {
    Write-Warning ("dockerhub-token: reading this host's vault failed ($($_.Exception.Message)). Building with NO Docker Hub credential: the cache syncs " +
        "anonymously against a pull budget shared by every guest behind this egress IP. Resolve the vault error and rebuild.")
    $dockerHubWarned = $true
}
# Refuse a value carrying a control character, quote, or backslash: the guest
# stores this pair as JSON. A control character or a bare quote leaves that file
# unparseable, and a backslash is the JSON escape introducer, so a stored
# backslash-n reads back as a newline -- a DIFFERENT secret, presented to Hub on
# every sync in place of the anonymous path that would have been served.
if (($dockerHubUsername -match '[\x00-\x1f\x7f''"\\]') -or ($dockerHubToken -match '[\x00-\x1f\x7f''"\\]')) {
    Write-Warning ("dockerhub-token: the stored account name or secret contains a control character, quote, or backslash, which the guest's JSON " +
        "credential file cannot carry unchanged; building with NO Docker Hub credential. Store a clean value, then rebuild.")
    $dockerHubUsername = ''
    $dockerHubToken    = ''
    $dockerHubWarned   = $true
}
# The pair travels together or not at all: an account name with no secret (or a
# secret with no account name) authenticates as nobody, which is worse than the
# anonymous path it replaces.
if ((-not $dockerHubUsername) -or (-not $dockerHubToken)) {
    $dockerHubUsername = ''
    $dockerHubToken    = ''
    if (-not $dockerHubWarned) {
        Write-Verbose ("Docker Hub: no complete credential (account name + secret) for logical user 'dockerhub-token' in this host's vault; the cache syncs " +
            "anonymously against a pull budget shared by every guest behind this egress IP. Store the Hub account name as that user's localOsUser and its " +
            "access token in the vault to move the cache onto the account's own budget.")
    }
}

# --- REGION: Config service mTLS materials
# See https://yuruna.link/42f6b05f-0042
# Mint a per-VM client leaf signed by THIS host's Config CA; PEMs are baked
# base64 so they survive the cloud-init write_files block scalar.
Import-Module (Join-Path $repoRoot 'test/modules/Test.ConfigServiceCA.psm1') -Force
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

# --- REGION: Dashboard brand identity
# The Grafana dashboards this VM serves name the enlistment that built it --
# the same pair the host's status pages carry in their header. Resolved here
# because the guest is handed built artifacts and never the framework
# repository, so it has no way to answer this for itself.
Import-Module (Join-Path $repoRoot 'test/modules/Test.FrameworkSource.psm1') -Force
$brand = Get-YurunaBrandIdentity -RepoRoot $repoRoot -Config $tc

# Render user-data from the shared base + KVM overlay (host/vmconfig/
# caching-proxy-service.*). New-CloudInitUserData resolves the SSH-key and
# password placeholders with literal .Replace(), so regex-special chars
# in the values are safe.
Import-Module (Join-Path $repoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force
$userData = New-CloudInitUserData `
    -BasePath    $baseUserData `
    -OverlayPath $overlayUserData `
    -RepoRoot    $repoRoot `
    -Replacement @{
        SQUID_CACHE_MEM_PLACEHOLDER    = $SquidCacheMem
        SSH_AUTHORIZED_KEY_PLACEHOLDER = $SshAuthorizedKey
        PASSWORD_PLACEHOLDER           = $AdminPassword
        YURUNA_STATUS_SERVICE_IP_PLACEHOLDER     = $YurunaHostIp
        YURUNA_STATUS_SERVICE_PORT_PLACEHOLDER   = $YurunaHostPort
        YPOOL_NAS_REPLICATE_PLACEHOLDER     = $ypoolNasReplicate
        YPOOL_NAS_NETWORK_PATH_PLACEHOLDER  = $ypoolNasNetPath
        YPOOL_NAS_NETWORK_USER_PLACEHOLDER  = $ypoolNasUser
        YPOOL_NAS_HOST_ID_PLACEHOLDER       = $ypoolNasHostId
        INTERNAL_AUTH_KEY_PLACEHOLDER  = $internalAuthKey
        YURUNA_DOCKERHUB_USERNAME_PLACEHOLDER = $dockerHubUsername
        YURUNA_DOCKERHUB_TOKEN_PLACEHOLDER    = $dockerHubToken
        YURUNA_CONFIG_SERVICE_PORT_PLACEHOLDER               = $configPort
        YURUNA_CONFIG_SERVICE_CLIENT_CERT_BASE64_PLACEHOLDER = $configClientCertB64
        YURUNA_CONFIG_SERVICE_CLIENT_KEY_BASE64_PLACEHOLDER  = $configClientKeyB64
        YURUNA_CONFIG_SERVICE_CA_CERT_BASE64_PLACEHOLDER     = $configCaCertB64
        YURUNA_BRAND_NAME_PLACEHOLDER    = $brand.Name
        YURUNA_BRAND_VERSION_PLACEHOLDER = $brand.Version
    } `
    -AllowedUnresolved 'AGGREGATOR_BASE_PLACEHOLDER' `
    -Confirm:$false
$metaData = (Get-Content -Raw -LiteralPath $metaDataTemplate)

$seedDir = Join-Path $vmDir 'seed.src'
New-Item -ItemType Directory -Force -Path $seedDir | Out-Null
Set-Content -LiteralPath (Join-Path $seedDir 'user-data') -Value $userData -NoNewline
Set-Content -LiteralPath (Join-Path $seedDir 'meta-data') -Value $metaData -NoNewline

# --- REGION: https://yuruna.link/4220a755-000b
Copy-Item -Path (Join-Path $repoRoot 'host/vmconfig/guest-dhcp.network-config') `
    -Destination (Join-Path $seedDir 'network-config')

# --- REGION: Generate cloud-init seed ISO
& genisoimage -output $seedImg -volid cidata -joliet -rock `
    (Join-Path $seedDir 'user-data') (Join-Path $seedDir 'meta-data') `
    (Join-Path $seedDir 'network-config') 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "genisoimage failed (exit $LASTEXITCODE)"
    exit 1
}

# Surface credentials BEFORE the long VM-create/boot/cloud-init wait.
# If anything in those 20-35 minutes fails (cloud-init stall, apt rate-
# limit, yuruna.conf parse error), the operator needs to console-login
# via virt-viewer -- without the password they'd have to dig seed.iso
# off disk. The final "ready" banner reprints the same credentials.
Write-Output ""
Write-Output "== caching-proxy-service console/SSH login (available NOW) =="
Write-Output "  user:     caching-proxy-service-admin"
Write-Output "  password: $PasswordFile"
Write-Output "  If the wait below stalls or fails, open"
Write-Output "    virt-viewer --connect $virshUri $VMName"
Write-Output "  and log in with the credentials above to inspect cloud-init state."
Write-Output ""

# --- REGION: Validate the resolved libvirt network
# $networkName was resolved above via Resolve-GuestHostBinding; see the
# .DESCRIPTION network-choice notes for what each mode costs.
if (-not $networkName) {
    Write-Error "No libvirt network defined. Run 'virsh net-start default' to enable the NAT default, or define 'yuruna-external' (see README.md) for LAN-bridged access."
    exit 1
}
if ($networkName -eq 'default') {
    Write-Warning ""
    Write-Warning "Using libvirt NAT 'default' network (192.168.122/24). The"
    Write-Warning "cache VM will be reachable from this host only; LAN clients"
    Write-Warning "will NOT see the cache VM at its libvirt IP."
    Write-Warning ""
    Write-Warning "The multi-host POOL DASHBOARD will not work on this NAT path:"
    Write-Warning "the host-side forwarder masks every LAN client as the NAT gateway"
    Write-Warning "(192.168.122.1), so the pool-aggregator-service -- which discovers hosts by"
    Write-Warning "their real client IP in squid's log -- discovers none, and the"
    Write-Warning "'Yuruna hosts' Grafana dashboard shows 'No data'."
    Write-Warning ""
    Write-Warning "For LAN exposure AND a working pool dashboard (cache VM gets a real"
    Write-Warning "LAN IP so squid sees real client IPs), put it on the bridged"
    Write-Warning "'yuruna-external' network: connect the host by Ethernet and run"
    Write-Warning "test/service/Start-CachingProxyServiceVM.ps1 (auto-builds the bridge + rebuilds the"
    Write-Warning "cache VM on it), or define it by hand -- see"
    Write-Warning "host/ubuntu.kvm/guest.caching-proxy-service/README.md."
    Write-Warning ""
} else {
    Write-Output "Using libvirt network: $networkName (cache VM will get a LAN-routable IP)"
    # --- REGION: https://yuruna.link/42e220c4-0004
    # Require a physical uplink only for bridge-mode networks; NAT bridges need none.
    $netXml = & virsh --connect $virshUri net-dumpxml $networkName 2>&1
    $isBridgeMode = $false
    $bridgeDev = $null
    foreach ($line in @($netXml)) {
        if ("$line" -match "<forward\s+mode='bridge'") { $isBridgeMode = $true }
        if (-not $bridgeDev -and "$line" -match "<bridge\s+name='([^']+)'") { $bridgeDev = $Matches[1] }
    }
    if ($isBridgeMode -and $bridgeDev) {
        $brifDir = "/sys/class/net/$bridgeDev/brif"
        $uplink = if (Test-Path -LiteralPath $brifDir) {
            @(Get-ChildItem -LiteralPath $brifDir -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -notmatch '^(vnet|tap)\d+$' })
        } else { @() }
        if ($uplink.Count -eq 0) {
            Write-Error "libvirt network '$networkName' is backed by bridge '$bridgeDev', which is missing or has NO physical uplink port -- guests on it can never get DHCP. Re-run test/service/Start-CachingProxyServiceVM.ps1 (it heals or rebuilds the bridge), or roll the bridge back per host/ubuntu.kvm/guest.caching-proxy-service/README.md."
            exit 1
        }
    }
}

# --- REGION: Create and configure the libvirt domain (virt-install)
# See https://yuruna.link/42e220c4-0004
# Keep guest reboots inside QEMU so the persistent service restarts normally.
$arch = (& uname -m).Trim()

# Ubuntu 26.04 may not be in the host's osinfo-db yet. Probe what
# virt-install accepts and fall back through ubuntu24.04 -> linux2022
# generic. Same pattern as guest.ubuntu.server.24/New-VM.ps1.
$osVariant = 'linux2022'
$osList = & virt-install --osinfo list 2>$null
if ($LASTEXITCODE -eq 0) {
    $canonicalIds = @($osList | ForEach-Object {
        $first = ("$_".Trim() -split '[\s,]', 2)[0]
        ($first -replace ',$', '').Trim()
    } | Where-Object { $_ })
    foreach ($candidate in @('ubuntu26.04', 'ubuntu24.04', 'ubuntu22.04')) {
        if ($canonicalIds -contains $candidate) { $osVariant = $candidate; break }
    }
    if ($osVariant -eq 'linux2022') {
        Write-Verbose "osinfo-db has no 'ubuntu26.04'/'ubuntu24.04'/'ubuntu22.04' entry; using 'linux2022' generic variant."
    }
}

# --- REGION: https://yuruna.link/42f6b05f-0040
# RAM comes from the caller, paired with squid's cache_mem by
# Get-CachingProxyMemoryProfile -- the two are budgeted against each other
# and swap is masked, so undersizing is an unrecoverable OOM. The default
# below is the beacon pairing, matched across all three hosts. 4 vCPU.
# --- REGION: https://yuruna.link/42fa6f45-0015
$hostCores = [int](& nproc --all)
if ($hostCores -lt 4) {
    Write-Error "Host has $hostCores cores; Yuruna requires at least 4. See https://yuruna.link/42fa6f45-0015"
    exit 1
}
$vmCores = [math]::Max(4, [math]::Floor($hostCores / 2))

# --- REGION: https://yuruna.link/4220a755-000a
$YurunaGuestMac = Get-YurunaGuestMacAddress -VMName $VMName
Write-Verbose "Deterministic guest MAC for '$VMName': $YurunaGuestMac"

$installArgs = @(
    '--connect',    $virshUri,
    '--name',       $VMName,
    '--memory',     "$MemoryMb",
    '--vcpus',      "$vmCores",
    '--cpu',        'host-passthrough',
    '--os-variant', $osVariant,
    '--disk',       "path=$diskImg,format=qcow2,bus=virtio",
    '--disk',       "path=$seedImg,device=cdrom",
    # ",mac=" pins the NIC's MAC so an operator DHCP reservation keyed to
    # it gives the cache VM a known, stable IP across rebuilds; empty
    # $MacAddress keeps virt-install's per-run random MAC.
    '--network',    ("network=$networkName,model=virtio" + $(if ($MacAddress) { ",mac=$MacAddress" } else { ",mac=$YurunaGuestMac" })),
    '--graphics',   'vnc,listen=127.0.0.1',
    # qemu-guest-agent socket: lets `virsh domifaddr --source agent`
    # query the guest's IPv4 directly when the host can't observe DHCP
    # (i.e. on a bridged network where the host isn't the DHCP server).
    # The guest-side qemu-guest-agent package is installed via cloud-init.
    '--channel',    'unix,target_type=virtio,name=org.qemu.guest_agent.0',
    '--events',     'on_reboot=restart',
    '--noautoconsole',
    '--import'
)
# aarch64 has no BIOS option in QEMU, so UEFI is mandatory.
# x86_64 cloud images boot fine with the libvirt default (i440fx + SeaBIOS)
# from the qcow2's hybrid GRUB MBR, so no --boot uefi here for x86_64
# (avoids the NVRAM-empty fallback issue described at
# https://yuruna.link/42d69dfa-0009).
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

# --- REGION: Clean up temporary files
Remove-Item -LiteralPath $seedDir -Recurse -Force -ErrorAction SilentlyContinue

# --- REGION: Wait for VM IP
# On the bridged 'yuruna-external' network the host is NOT the DHCP
# server, so `virsh domifaddr` (default --source lease) returns nothing.
# qemu-guest-agent (installed via cloud-init) lets `--source agent`
# query the guest directly. ARP (`--source arp`) is the third fallback
# for the brief window before the guest agent comes up.
Write-Output "Waiting for VM to obtain an IP address..."
Write-Output "  (first boot runs cloud-init: apt update + install squid + monitoring;"
Write-Output "   this can take 5-15 minutes on a slow connection -- be patient)"

$cacheIp = $null
$maxIterations = 240  # 240 * 5s = 20 minutes
$startTime = Get-Date
$baselineSizeMB = [math]::Round((Get-Item $diskImg).Length / 1MB, 0)
# Print one status line per ~30 s rather than Write-Progress. PowerShell-
# on-Linux's progress renderer trips an internal SetCursorPosition with
# nonsensical column values ("Parameter 'left'. Actual value was
# 51515410") on certain ANSI-styled terminals (tmux, vscode integrated,
# some sshd PTYs). Falling back to plain stdout lines makes the wait
# loop terminal-agnostic and keeps the operator informed.

for ($i = 0; $i -lt $maxIterations; $i++) {
    # --- REGION: https://yuruna.link/42e220c4-0004
    # Use shared address discovery to reject loopback and link-local agent rows.
    $cacheIp = Get-VMIp -VMName $VMName
    if ($cacheIp) { break }
    Start-Sleep -Seconds 5

    # Print a one-line status every 6 iterations (30 s) so the operator
    # can see apt is making progress even before the network comes up.
    # Disk growth is the reliable apt-busy signal.
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

if (-not $cacheIp) {
    $detail = @"

========
ERROR: caching-proxy-service VM '$VMName' did not obtain an IP address within 20 minutes.
========

The VM is running but virsh domifaddr (sources: lease, agent, arp) all
returned empty. Exiting with failure so guest installs won't silently
fall back to direct CDN access and 429.

If the VM is on the 'yuruna-external' bridge and the upstream AP is
Wi-Fi: some access points refuse to forward the cache VM's DHCP request
(MAC-based AP isolation). Use a wired connection, or fall back to the
NAT 'default' network by undefining 'yuruna-external' before re-running
this script.

Accessing the VM for debugging:
  * Console:  virt-viewer --connect $virshUri $VMName
              login:    caching-proxy-service-admin
              password: $PasswordFile
              (cloud-init sets it from user-data; does NOT expire.)

Diagnostic steps inside the VM:
  1. Check network:          ip -br a   # should show ens* with an IPv4
  2. Check cloud-init:       cloud-init status --long
  3. Check squid:            systemctl status squid
  4. Check guest agent:      systemctl status qemu-guest-agent
  5. View cloud-init logs:   sudo journalctl -u cloud-init -n 200

If cloud-init is still running (package install is slow or the mirror
is throttled), re-run New-VM.ps1 after it finishes -- the script is
idempotent and will rebuild the VM cleanly.
========
"@
    Write-Output $detail
    exit 1
}

Write-Output "Cache VM IP: $cacheIp"
Write-Output "Waiting for squid to listen on port 3128 (up to 15 minutes)..."
Write-Output "  (cloud-init installs squid + apache2, then pre-warms"
Write-Output "   the cache by pulling linux-firmware through the local proxy --"
Write-Output "   squid binds :3128 before pre-warm starts, so port response"
Write-Output "   usually happens 3-5 minutes in on a responsive mirror.)"

$portMaxIterations = 360  # 360 * 2.5s = 15 minutes
$portStartTime = Get-Date

for ($i = 0; $i -lt $portMaxIterations; $i++) {
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $tcp.BeginConnect($cacheIp, 3128, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne(500, $false) -and $tcp.Connected) {
            $tcp.EndConnect($async) | Out-Null
            $tcp.Close()
            Write-Output ""
            Write-Output "== caching-proxy-service is READY =="
            Write-Output "  VM:        $VMName"
            Write-Output "  IP:        $cacheIp"
            Write-Output "  Network:   $networkName"
            Write-Output "  Proxy:     http://${cacheIp}:3128"
            Write-Output "  Monitor:   ssh to the VM, then 'squidclient mgr:info'  (web UI dropped in Ubuntu 26.04)"
            Write-Output "  Grafana:   http://${cacheIp}:3000"
            Write-Output ""
            Write-Output "  Console/SSH login:"
            Write-Output "    user:     caching-proxy-service-admin"
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
    } catch {
        Write-Verbose "squid :3128 probe failed (will retry): $($_.Exception.Message)"
    } finally {
        $tcp.Close()
    }

    # Print a one-line status every ~30 s (~12 iterations of 2.5 s) -- see
    # the rationale on the IP-wait loop above. The probe itself takes
    # up to 0.5 s blocking on BeginConnect + 2 s Start-Sleep below.
    if (($i % 12) -eq 11) {
        $elapsed = [int]((Get-Date) - $portStartTime).TotalSeconds
        $sizeMB  = [math]::Round((Get-Item $diskImg).Length / 1MB, 0)
        $deltaMB = $sizeMB - $baselineSizeMB
        $min     = [int][math]::Floor($elapsed / 60)
        $sec     = [int]($elapsed % 60)
        $totalMinutes = 15
        Write-Output ("  [{0:D2}m{1:D2}s / {2}m] still waiting for squid on :3128 -- qcow2 {3} MB (+{4} MB since boot)" -f $min, $sec, $totalMinutes, $sizeMB, $deltaMB)
    }

    Start-Sleep -Seconds 2
}
$detail = @"

========
ERROR: squid did not start listening on :3128 within 15 minutes.
  Cache IP probed: $cacheIp
========

The VM is running and has an IP, but port 3128 never accepted a TCP
connection. Exiting with failure so subsequent guest installs can't
silently fall back to direct CDN access and hit 429 rate limits.

Accessing the VM for debugging:
  * Console:  virt-viewer --connect $virshUri $VMName
              login:    caching-proxy-service-admin
              password: $PasswordFile
              (cloud-init sets it from user-data; does NOT expire.)
  * SSH:      ssh caching-proxy-service-admin@$cacheIp
              (uses the yuruna harness key at test/status/ssh/yuruna_ed25519 --
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
                                  re-run New-VM.ps1 (idempotent -- it
                                  rebuilds the VM cleanly).
  * 'Unable to locate package' -> a package name changed on the mirror;
                                  report the specific name so it can be
                                  fixed in host/vmconfig/caching-proxy-service.base.user-data.
  * 'Could not resolve'        -> DNS broken inside the VM. Check
                                  'resolvectl status' and netplan config.

=== Step 2: deeper diagnostics (only if step 1 is inconclusive) ===
  systemctl status squid                # 'could not be found' = install failed
  ss -ltn 'sport = :3128'               # port bound? who's listening?
  sudo ufw status ; sudo iptables -L -n # guest-side firewall
  ip -br a                              # IP matches $cacheIp ?

Recovery options:
  * Retry:   re-run New-VM.ps1 (idempotent rebuild).
  * Manual:  ssh in, fix (e.g. wait for rate-limit, then
             'sudo cloud-init clean --logs && sudo cloud-init init').
  * Probe:   nc -z -w 3 $cacheIp 3128
========
"@
Write-Output $detail
exit 1
