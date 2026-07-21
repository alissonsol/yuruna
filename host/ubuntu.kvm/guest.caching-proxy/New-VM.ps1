<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42f4e5f6-a7b8-4c9d-0123-4e5f6a7b8c9d
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
    Creates the squid HTTP-caching proxy VM on Ubuntu KVM (libvirt).

.DESCRIPTION
    Builds a libvirt VM that boots the Ubuntu 26.04 cloud image and runs
    Squid 7 on port 3128 plus an SSL-bump listener on 3129. Cloud-init
    (NoCloud seed) installs squid-openssl + apache2 +
    Prometheus + Grafana + loki + promtail + caching-proxy-parser,
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
    libvirt domain name. Default: yuruna-caching-proxy

.PARAMETER MacAddress
    Optional stable MAC for the VM's NIC (AA:BB:CC:DD:EE:FF, dashed, or
    bare hex). Lets the operator pin the cache IP with a one-time DHCP
    reservation on the LAN router (bridged 'yuruna-external') or in the
    'default' network's dnsmasq (NAT fallback); without it virt-install
    assigns a fresh random MAC on every rebuild and the lease moves.
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = 'yuruna-caching-proxy',
    [Parameter()]
    [string]$MacAddress
)

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Error "Invalid VMName '$VMName'. Only alphanumerics, dots, hyphens, underscores."
    exit 1
}
if (-not $IsLinux) {
    Write-Error "host/ubuntu.kvm/guest.caching-proxy/New-VM.ps1 only runs on Linux."
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

# --- REGION: libvirt-qemu search ACL on $HOME (self-heal)
# Ubuntu 24.04+ cloud images create /home/<user> at mode 0750, which
# blocks the libvirt-qemu user (uid 64055, gid kvm) that runs guest qemu
# processes from traversing $HOME to reach the qcow2 below it. virt-install
# then warns "You will need to grant the 'libvirt-qemu' user search
# permissions for ['/home/<user>']" and errors out with "Cannot access
# storage file ... Permission denied". A traverse-only POSIX ACL is the
# narrowest fix and does not change read/write/listing for any other
# user. Idempotent -- safe to run every cycle.
if (Get-Command -Name 'setfacl' -ErrorAction SilentlyContinue) {
    & getent passwd libvirt-qemu *>$null
    if ($LASTEXITCODE -eq 0) {
        & setfacl -m 'u:libvirt-qemu:--x' $HOME 2>$null
    }
}

# --- REGION: Seek the base image
$downloadDir   = "$HOME/yuruna/image/caching-proxy"
$baseImageName = "host.ubuntu.kvm.guest.caching-proxy"
$baseImageFile = Join-Path $downloadDir "$baseImageName.qcow2"

# Auto-run Get-Image.ps1 once if the base image is missing; recheck and
# only error out when it's still missing afterward.
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
# Provenance side-channel for operators reading the transcript. Emits
# "Provenance: <url>" when the sidecar is healthy; warns otherwise.
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))
Import-Module (Join-Path $repoRoot 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

# --- REGION: Per-VM directory + disk
# The caching-proxy VM is long-lived (one job: serve the cache to every
# subsequent guest install), so we COPY the base image into the VM
# directory rather than chaining a qcow2 overlay against it. Overlay
# semantics break the moment Get-Image.ps1 rotates the base on the next
# `resolute` point release: the overlay's referenced backing file would
# disappear or change content, and the next VM start would fail or
# silently boot a different OS. A full copy is ~2.5 GB sparse (qcow2
# allocates on write) so the cost is acceptable.
$vmDir   = Join-Path $HOME "yuruna/vms/$VMName"
$diskImg = Join-Path $vmDir "$VMName.qcow2"
$seedImg = Join-Path $vmDir 'seed.iso'
New-Item -ItemType Directory -Force -Path $vmDir | Out-Null

# --- REGION: Remove existing VM
# Idempotent rebuild: destroy + undefine (with --nvram so the EFI vars
# go with the domain) before laying down new files. virsh returns
# non-zero when the domain isn't defined; stderr is captured and
# surfaced only at -Verbose.
$virshUri = 'qemu:///system'
# Capture stdout+stderr + exit code for each call so an operator
# running with -Verbose sees the per-call outcome. The post-condition
# below catches the actual failure mode; this just preserves forensics
# when something unusual surfaces between the two idempotent ops.
$destroyOut = & virsh --connect $virshUri destroy $VMName 2>&1
Write-Verbose "virsh destroy '$VMName' exit=$LASTEXITCODE output='$($destroyOut -join '; ')'"
$undefineOut = & virsh --connect $virshUri undefine --nvram $VMName 2>&1
Write-Verbose "virsh undefine '$VMName' exit=$LASTEXITCODE output='$($undefineOut -join '; ')'"
# Post-condition: virsh destroy/undefine on a non-existing domain is
# idempotent (returns non-zero; stderr captured and shown only at
# -Verbose). But if either
# op failed while the domain remains defined, the next virt-install
# fails with "domain already defined" and the outer loop has no signal
# to recover. Fail-loud now with dominfo so the operator can act.
$stillDefined = & virsh --connect $virshUri list --all --name 2>$null |
    Where-Object { $_.Trim() -eq $VMName }
if ($stillDefined) {
    $dominfo = (& virsh --connect $virshUri dominfo $VMName 2>&1 | Out-String).Trim()
    throw "virsh destroy + undefine left '$VMName' defined; aborting before re-creation.`ndominfo:`n$dominfo"
}

# --- REGION: Copy base image -> per-VM disk
if (Test-Path -LiteralPath $diskImg) { Remove-Item -Force -LiteralPath $diskImg }
Write-Output "Copying base image to per-VM disk (sparse copy)..."
# `cp --sparse=always` preserves qcow2 hole semantics on ext4/btrfs/xfs.
# The cloud image is mostly empty; cp WITHOUT --sparse=always would
# fully allocate ~512 GB on disk after the prior Get-Image resize.
& /bin/cp --sparse=always -- $baseImageFile $diskImg
if ($LASTEXITCODE -ne 0) {
    Write-Error "cp --sparse=always failed copying $baseImageFile -> $diskImg"
    exit 1
}

# --- REGION: Yuruna harness SSH key
# The harness uses one ed25519 key pair at test/status/ssh/yuruna_ed25519,
# owned by Test.Ssh\Get-YurunaSshPublicKey. Test.Diagnostic's post-
# failure SSH path (Invoke-GuestSsh) authenticates with that SAME key,
# so the public bytes seeded into the guest's authorized_keys MUST be
# this key -- not an ad-hoc per-host pair.
$TestSshModule = Join-Path $repoRoot 'test/modules/Test.Ssh.psm1'
Import-Module $TestSshModule -Force -DisableNameChecking
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error "Get-YurunaSshPublicKey returned empty. Module path: $TestSshModule"; exit 1 }

# --- REGION: Cache-VM yuruna password
# --- REGION: https://yuruna.link/caching-proxy#cache-vm-password-persistence
# The runtime state file <track>/yuruna-caching-proxy.yml is the source of
# truth; Set-Password rehydrates the vault from it before Get-Password.
Import-Module (Join-Path $repoRoot 'test/modules/Test.Extension.psm1')    -Global -Force -Verbose:$false
Import-Module (Join-Path $repoRoot 'test/modules/Test.CachingProxy.psm1') -Global -Force -Verbose:$false
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$persisted = (Read-CachingProxyState).password
if ($persisted) { Set-Password -Username 'yuruna' -NewPassword $persisted }
$YurunaPassword = Get-Password -Username 'yuruna'
if (-not $YurunaPassword) { Write-Error "Get-Password returned empty for 'yuruna'."; exit 1 }
Write-Output "Password came from authentication mechanism: $_authActiveName"
Write-Output "See configuration at: $(Resolve-ExtensionAreaDir -Area 'authentication')"
[void](Save-CachingProxyState -Secret $YurunaPassword -Confirm:$false)
$PasswordFile = Get-CachingProxyStatePath

# --- REGION: Render user-data / meta-data
$baseUserData     = Join-Path $repoRoot 'host/vmconfig/caching-proxy.base.user-data'
$overlayUserData  = Join-Path $repoRoot 'host/vmconfig/caching-proxy.kvm.overlay.yml'
$metaDataTemplate = Join-Path $repoRoot 'host/vmconfig/caching-proxy.meta-data'
foreach ($f in @($baseUserData, $overlayUserData, $metaDataTemplate)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Error "Template missing: $f"
        exit 1
    }
}
# Yuruna host (status server) IP+port baked into the seed so the cache VM's
# cloud-init build block fetches collector/parser source from the LOCAL host
# working tree (/yuruna-repo/) instead of public github -- a rebuild never
# waits on the private->public mirror. The reachable host address and the
# libvirt network the cache attaches to are a topology-aware matched pair:
# on the bridged 'yuruna-external' network the cache VM gets a LAN IP and
# reaches the host at its LAN address; on the NAT 'default' network it
# reaches the host at the libvirt gateway (192.168.122.1).
# Resolve-GuestHostBinding resolves both at once (the same helper every
# install guest uses, so the cache and the guests always land on the same
# network). $env:YURUNA_GUEST_REACHABLE_HOST_IP overrides the host IP;
# empty value -> github fallback. Start-CachingProxy.ps1 starts the status
# server. The resolved $networkName is reused below for virt-install.
Import-Module (Join-Path $repoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1') -Force -DisableNameChecking
$guestBinding = Resolve-GuestHostBinding
$networkName  = $guestBinding.NetworkName
$YurunaHostIp = $guestBinding.HostIp
$YurunaHostPort = '8080'
$YurunaTestConfig = Join-Path $repoRoot 'test/test.config.yml'
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
Import-Module (Join-Path $repoRoot 'test/modules/Test.HostConfigCA.psm1') -Force
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

# Render user-data from the shared base + KVM overlay (host/vmconfig/
# caching-proxy.*). New-CloudInitUserData resolves the SSH-key and
# password placeholders with literal .Replace(), so regex-special chars
# in the values are safe.
Import-Module (Join-Path $repoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force
$userData = New-CloudInitUserData `
    -BasePath    $baseUserData `
    -OverlayPath $overlayUserData `
    -RepoRoot    $repoRoot `
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
$metaData = (Get-Content -Raw -LiteralPath $metaDataTemplate)

$seedDir = Join-Path $vmDir 'seed.src'
New-Item -ItemType Directory -Force -Path $seedDir | Out-Null
Set-Content -LiteralPath (Join-Path $seedDir 'user-data') -Value $userData -NoNewline
Set-Content -LiteralPath (Join-Path $seedDir 'meta-data') -Value $metaData -NoNewline

& genisoimage -output $seedImg -volid cidata -joliet -rock `
    (Join-Path $seedDir 'user-data') (Join-Path $seedDir 'meta-data') 2>&1 | Out-Null
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
Write-Output "== caching-proxy console/SSH login (available NOW) =="
Write-Output "  user:     yuruna"
Write-Output "  password: $PasswordFile"
Write-Output "  If the wait below stalls or fails, open"
Write-Output "    virt-viewer --connect $virshUri $VMName"
Write-Output "  and log in with the credentials above to inspect cloud-init state."
Write-Output ""

# --- REGION: Pick libvirt network
# $networkName was resolved above via Resolve-GuestHostBinding (prefers
# a bridged 'yuruna-external' network so the cache VM gets a real LAN IP via
# the upstream DHCP server and remote LAN clients reach it directly by IP;
# falls back to the NAT 'default' network when no bridged network is defined
# -- cache still works for same-host guests but is NOT directly reachable
# from LAN clients without a host-side port forwarder). README.md documents
# the `virsh net-define` command for the bridged path.
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
    Write-Warning "(192.168.122.1), so the pool-aggregator -- which discovers hosts by"
    Write-Warning "their real client IP in squid's log -- discovers none, and the"
    Write-Warning "'Yuruna hosts' Grafana dashboard shows 'No data'."
    Write-Warning ""
    Write-Warning "For LAN exposure AND a working pool dashboard (cache VM gets a real"
    Write-Warning "LAN IP so squid sees real client IPs), put it on the bridged"
    Write-Warning "'yuruna-external' network: connect the host by Ethernet and run"
    Write-Warning "test/Start-CachingProxy.ps1 (auto-builds the bridge + rebuilds the"
    Write-Warning "cache VM on it), or define it by hand -- see"
    Write-Warning "host/ubuntu.kvm/guest.caching-proxy/README.md."
    Write-Warning ""
} else {
    Write-Output "Using libvirt network: $networkName (cache VM will get a LAN-routable IP)"
    # Fail fast on a dead bridge: a bridged network whose host bridge has
    # no physical uplink port can never deliver a DHCP offer to the
    # guest, so the 20-minute IP wait below would burn in full and then
    # fail anyway. Probe /sys/class/net/<bridge>/brif for a non-tap port
    # BEFORE creating the VM. Only <forward mode='bridge'/> networks
    # qualify: NAT/routed/isolated networks also carry a <bridge
    # name='virbrN'/> element, but that bridge is libvirt's own and
    # legitimately has no physical uplink (its dnsmasq serves DHCP
    # directly), so probing it would veto a working network.
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
            Write-Error "libvirt network '$networkName' is backed by bridge '$bridgeDev', which is missing or has NO physical uplink port -- guests on it can never get DHCP. Re-run test/Start-CachingProxy.ps1 (it heals or rebuilds the bridge), or roll the bridge back per host/ubuntu.kvm/guest.caching-proxy/README.md."
            exit 1
        }
    }
}

# --- REGION: virt-install
# `--import` (no install phase) since the cloud image is bootable.
# `--events on_reboot=restart` matches the amazon.linux.2023 guest -- a
# system_reset inside the VM (e.g. unattended-upgrades pulling a kernel)
# performs QMP reset rather than exiting QEMU; the libvirt domain stays
# defined and re-boots from its NVRAM-stored boot entry. Without this,
# subiquity-style on_reboot=destroy would kill the VM at the first
# guest reboot. The Ubuntu cloud image's first-run path doesn't reboot
# during cloud-init's first phase, so this only matters for the long-
# lived service-VM behavior.
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

# --- REGION: https://yuruna.link/caching-proxy#cache-vm-sizing
# 12 GB RAM, 4 vCPU on all three hosts, budgeted around squid's cache_mem;
# swap is masked, so undersizing is an unrecoverable OOM.
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
    '--memory',     '12288',
    '--vcpus',      "$vmCores",
    '--cpu',        'host-passthrough',
    '--os-variant', $osVariant,
    '--disk',       "path=$diskImg,format=qcow2,bus=virtio",
    '--disk',       "path=$seedImg,device=cdrom",
    # ",mac=" pins the NIC's MAC so an operator DHCP reservation keyed to
    # it gives the cache VM a known, stable IP across rebuilds; empty
    # $MacAddress keeps virt-install's per-run random MAC.
    '--network',    ("network=$networkName,model=virtio" + $(if ($MacAddress) { ",mac=$MacAddress" } else { '' })),
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
# (avoids the NVRAM-empty fallback issue described in the amazon.linux.2023
# New-VM.ps1 SeaBIOS comment).
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

# --- REGION: Cleanup temporary folders
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
    # Delegate to Get-VMIp (Yuruna.Host) -- it iterates the same
    # lease/agent/arp sources but filters loopback (127/8) and link-
    # local (169.254/16) and requires the row to have the literal
    # 'ipv4' column. A naive `(\d+\.\d+\.\d+\.\d+)/\d+` regex matches
    # the 'lo ... ipv4 127.0.0.1/8' row that `--source agent` emits
    # as its FIRST line, sending the next port-wait probe to the
    # host's own loopback and stalling Start-CachingProxy.ps1 with
    # `Cache VM IP: 127.0.0.1`.
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
        $totalMin = [int][math]::Floor($maxIterations * 5 / 60)
        Write-Output ("  [{0:D2}m{1:D2}s / {2}m] still waiting for IP -- qcow2 {3} MB (+{4} MB since boot)" -f $min, $sec, $totalMin, $sizeMB, $deltaMB)
    }
}

if (-not $cacheIp) {
    $detail = @"

=========================================================================
ERROR: caching-proxy VM '$VMName' did not obtain an IP address within 20 minutes.
=========================================================================

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
              login:    yuruna
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
=========================================================================
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
            Write-Output "== caching-proxy is READY =="
            Write-Output "  VM:        $VMName"
            Write-Output "  IP:        $cacheIp"
            Write-Output "  Network:   $networkName"
            Write-Output "  Proxy:     http://${cacheIp}:3128"
            Write-Output "  Monitor:   ssh to the VM, then 'squidclient mgr:info'  (web UI dropped in Ubuntu 26.04)"
            Write-Output "  Grafana:   http://${cacheIp}:3000"
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
        $totalMin = 15
        Write-Output ("  [{0:D2}m{1:D2}s / {2}m] still waiting for squid on :3128 -- qcow2 {3} MB (+{4} MB since boot)" -f $min, $sec, $totalMin, $sizeMB, $deltaMB)
    }

    Start-Sleep -Seconds 2
}
$detail = @"

=========================================================================
ERROR: squid did not start listening on :3128 within 15 minutes.
  Cache IP probed: $cacheIp
=========================================================================

The VM is running and has an IP, but port 3128 never accepted a TCP
connection. Exiting with failure so subsequent guest installs can't
silently fall back to direct CDN access and hit 429 rate limits.

Accessing the VM for debugging:
  * Console:  virt-viewer --connect $virshUri $VMName
              login:    yuruna
              password: $PasswordFile
              (cloud-init sets it from user-data; does NOT expire.)
  * SSH:      ssh yuruna@$cacheIp
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
                                  fixed in host/vmconfig/caching-proxy.base.user-data.
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
=========================================================================
"@
Write-Output $detail
exit 1
