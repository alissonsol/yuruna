<#PSScriptInfo
.VERSION 2026.08.05
.GUID 42f1b2c3-d4e5-4f67-8901-a2b3c4d5e6f9
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
    Builds the squid HTTP-caching-proxy service VM bundle for macOS UTM.

.DESCRIPTION
    Creates a UTM .utm bundle (QEMU backend with -vnc) that boots
    the arm64 Ubuntu cloud image from Get-Image.ps1 and runs Squid on
    port 3128. Cloud-init (seed.iso) installs squid-openssl + apache2,
    pre-warms linux-firmware through the proxy, and exposes the squid CA
    cert + Grafana. Cache-manager data is via 'squidclient mgr:' on the VM
    (the squid-cgi web UI was dropped in Ubuntu 26.04).

    Mirrors the Ubuntu UTM New-VM.ps1 pattern, minus:
      * nested-virt preflight (squid needs no KVM)
      * installer ISO drive (cloud image is already bootable)
      * blank qemu-img disk (we use the resized qcow2 cloud image)

.PARAMETER VMName
    Name of the UTM VM. Default: yuruna-caching-proxy-service

.PARAMETER MacAddress
    Optional stable MAC for the VM's NIC (AA:BB:CC:DD:EE:FF, dashed, or
    bare hex). Lets the operator pin the cache IP with a one-time DHCP
    reservation on the LAN router (bridged) or macOS bootpd (Shared NAT);
    without it every rebuilt bundle gets a fresh random MAC and the
    lease moves. MAC-based discovery (Resolve-UtmGuestIpByMac) reads the
    MAC from config.plist either way, so both modes keep working.

.EXAMPLE
    ./Get-Image.ps1
    ./New-VM.ps1
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = "yuruna-caching-proxy-service",
    [Parameter()]
    [string]$MacAddress
)

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Output "Invalid VMName '$VMName'. Only alphanumeric characters, dots, hyphens, and underscores are allowed."
    exit 1
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Normalize the optional stable MAC before any bundle teardown or image
# work so a typo'd value stops the run before anything heavy or
# destructive happens.
if ($MacAddress) {
    Import-Module (Join-Path $ScriptDir '../../../automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    $MacAddress = ConvertTo-YurunaMacAddress -MacAddress $MacAddress
    if (-not $MacAddress) {
        Write-Error "Invalid -MacAddress (see warning above). Nothing was changed."
        exit 1
    }
}

$GuestDir = "$HOME/yuruna/guest.nosync"
New-Item -ItemType Directory -Force -Path $GuestDir | Out-Null
$UtmDir = "$GuestDir/$VMName.utm"
$DataDir = "$UtmDir/Data"
$downloadDir = "$HOME/yuruna/image/caching-proxy-service"

# UTM presence check (no nested-virt / M3 check -- squid needs neither).
$utmPlist = "/Applications/UTM.app/Contents/Info.plist"
if (-not (Test-Path $utmPlist)) {
    Write-Error "UTM not found at /Applications/UTM.app. Install with: brew install --cask utm"
    exit 1
}

# --- REGION: Seek the base image
# One cloud image backs every extension service on this host; this VM grows
# its own copy below (host/modules/Yuruna.Image.psm1).
# Auto-run Get-Image.ps1 once if the base image is missing; recheck and
# only error out when it's still missing afterward.
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules/Yuruna.Image.psm1') -Force
$baseImageFile = (Get-UbuntuExtensionImageInfo -HostType 'macos.utm').BaseImageFile
if (-not (Test-Path $baseImageFile)) {
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
    if (-not (Test-Path $baseImageFile)) {
        Write-Error "Base image not found at '$baseImageFile' after auto Get-Image. Run Get-Image.ps1 manually."
        exit 1
    }
}

Write-Output "Creating VM '$VMName' using image: $baseImageFile"
# Provenance side-channel for operators reading the transcript. Emits
# "Provenance: <url>" when the sidecar is healthy; warns otherwise.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

# --- REGION: Create copies and files for VM
if (Test-Path -LiteralPath $UtmDir) { Remove-Item -LiteralPath $UtmDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# EFI vars: QEMU has its own EDK2 firmware; UEFIBoot=true in the plist
# makes UTM provide a per-bundle pflash file automatically. No Swift
# VZEFIVariableStore step required (that was the AVF-only path).

# --- REGION: Copy base image -> per-VM disk
# Copy the pre-built qcow2 cloud image into the bundle as the boot disk; no
# conversion here. qcow2 (not raw) is deliberate: UTM's QEMU backend boots it
# directly and it sidesteps the macOS F_PUNCHHOLE-alignment EINVAL a raw
# disk hits under UTM's discard=unmap,detect-zeroes=unmap -- see
# feedback_macos-qemu-punchhole-alignment.md.
$DiskImage = "$DataDir/disk.qcow2"
Write-Output "Copying cloud image into bundle as disk.qcow2 (APFS clone)..."
# `/bin/cp -c` triggers APFS clone (O(1), sparse-preserving). Falls back
# to Copy-Item if the destination isn't APFS (rare). Full path bypasses
# the PowerShell `cp` alias for Copy-Item.
& /bin/cp -c $baseImageFile $DiskImage
if ($LASTEXITCODE -ne 0) {
    Write-Warning "/bin/cp -c (APFS clone) failed; falling back to Copy-Item."
    Copy-Item -Path $baseImageFile -Destination $DiskImage
}

# --- REGION: Grow the per-VM disk to 512 GB
# 512 GB is the APPARENT size (qcow2 grows on demand: actual consumption is
# only what the guest writes). Sized for squid's `cache_dir ufs
# /var/spool/squid 393216` (= 384 GB) + ~128 GB OS/logs/headroom, and the
# `maximum_object_size 65 GB` directive in
# host/vmconfig/caching-proxy-service.base.user-data that lets the proxy cache
# files like the macOS install image (~18 GB) and other multi-GB blobs
# end-to-end instead of bypassing them direct to CDN.
if (-not (Expand-ExtensionVmDisk -Path $DiskImage -SizeBytes 512GB -Format 'qcow2')) {
    Write-Warning "Resize failed -- continuing with original size."
    Write-Warning "The cache VM will only have the base cloud-image capacity (~2.5 GB)"
    Write-Warning "which fills up after 1-2 installs. Resize manually with:"
    Write-Warning "  qemu-img resize -f qcow2 '$DiskImage' 512G"
}

# --- REGION: Generate cloud-init seed ISO
$SeedDir = Join-Path $downloadDir "seed_temp/$VMName"
if (Test-Path -LiteralPath $SeedDir) { Remove-Item -LiteralPath $SeedDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null

# meta-data is shared under host/vmconfig/ (byte-identical across all 3 host platforms).
$hostVmConfigDir = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))) 'host/vmconfig'
Copy-Item -Path (Join-Path $hostVmConfigDir 'caching-proxy-service.meta-data') -Destination "$SeedDir/meta-data"

# --- REGION: Yuruna harness SSH key
# yuruna test-harness SSH public key (same module the Ubuntu Server
# guest uses). One keypair grants passwordless access to every VM,
# including this cache VM for debugging squid/cloud-init issues.
$TestSshModule = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))) "test/modules/Test.Ssh.psm1"
Import-Module $TestSshModule -Force
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error "Get-YurunaSshPublicKey returned empty. Module path: $TestSshModule"; exit 1 }

# --- REGION: Cache-VM admin password
# --- REGION: https://yuruna.link/caching-proxy-service#cache-vm-password-persistence
# The runtime state file <track>/yuruna-caching-proxy-service.yml is the source of
# truth; Set-Password rehydrates the vault from it before Get-Password.
$_repoRootForExt = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))
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
$PasswordFile = Get-CachingProxyServiceStatePath

# --- REGION: https://yuruna.link/network#cache-vm-seed-host-binding
# macOS: NetworkMode pair -- Wi-Fi -> Shared NAT (VZ gateway 192.168.64.1), Ethernet -> bridged (host LAN IP). Resolved once here and reused for the plist below, so the mode and the address can never disagree.
Import-Module (Join-Path $_repoRootForExt 'host/macos.utm/modules/Yuruna.Host.psm1') -Force
$NetworkMode = Resolve-UtmNetworkMode
if ($env:YURUNA_GUEST_REACHABLE_HOST_IP) {
    $YurunaHostIp = $env:YURUNA_GUEST_REACHABLE_HOST_IP
} else {
    $YurunaHostIp = Get-GuestReachableHostIp -NetworkMode $NetworkMode
}
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

# Render user-data from the shared base + UTM overlay (host/vmconfig/
# caching-proxy-service.*). New-CloudInitUserData resolves the SSH-key and
# password placeholders with literal .Replace(), so values with
# regex-special characters are safe.
Import-Module (Join-Path $_repoRootForExt 'automation/Yuruna.CloudInitTemplate.psm1') -Force
$UserData = New-CloudInitUserData `
    -BasePath    (Join-Path $_repoRootForExt 'host/vmconfig/caching-proxy-service.base.user-data') `
    -OverlayPath (Join-Path $_repoRootForExt 'host/vmconfig/caching-proxy-service.utm.overlay.yml') `
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

$SeedIso = "$DataDir/seed.iso"
Write-Output "Generating seed.iso with cloud-init configuration..."
& hdiutil makehybrid -o "$SeedIso" -joliet -iso -default-volume-name cidata "$SeedDir" 2>&1 | ForEach-Object { Write-Verbose $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to create seed.iso with hdiutil."
    exit 1
}

# --- REGION: config.plist (QEMU backend)
$TemplatePath = Join-Path $ScriptDir "config.plist.template"
if (-not (Test-Path $TemplatePath)) {
    Write-Error "Template not found at '$TemplatePath'."
    exit 1
}

$VmUuid  = [guid]::NewGuid().ToString().ToUpper()
$DiskId  = [guid]::NewGuid().ToString().ToUpper()
$SeedId  = [guid]::NewGuid().ToString().ToUpper()

# An operator-supplied -MacAddress (already normalized to colon form
# above) wins; it lets a DHCP reservation pin the cache IP across
# rebuilds. Otherwise generate a fresh random per-bundle MAC.
if (-not $MacAddress) {
    $rng = [System.Random]::new()
    $MacBytes = [byte[]]::new(6)
    $rng.NextBytes($MacBytes)
    $MacBytes[0] = ($MacBytes[0] -bor 0x02) -band 0xFE  # locally administered unicast
    $MacAddress = ($MacBytes | ForEach-Object { $_.ToString("X2") }) -join ":"
}

# Per-VM VNC display number (Get-VncDisplayForVm hashes the name into
# 10..89). Get-VncPortForVm in the harness derives the same value from
# $VMName, so the producer (this plist) and the consumers (capture,
# keystrokes) agree without a sidecar file.
Import-Module (Join-Path (Split-Path -Parent $ScriptDir) "modules/Yuruna.Host.psm1") -Force
$VncDisplay = Get-VncDisplayForVm -VMName $VMName

# Bridge interface: QEMU's bridged network mode needs a physical NIC
# name (en0/en7/...). Resolve from the host's default IPv4 route so
# the cache rides whichever interface currently carries LAN traffic --
# matches what Get-BestHostIp does and avoids hardcoding en0 (Ethernet
# adapters often enumerate as en7/en8 instead). Falls back to en0 if
# `route` reports no default; an unreachable bridge surfaces later as a
# DHCP timeout in Start-CachingProxyServiceVM.ps1 Step 4 (better diagnostic than
# silently failing here).
$BridgeInterface = $null
try {
    $routeOut = & '/sbin/route' -n get default 2>$null
    foreach ($line in $routeOut) {
        if ($line -match 'interface:\s*(\S+)') { $BridgeInterface = $matches[1]; break }
    }
} catch {
    Write-Verbose "route -n get default failed: $($_.Exception.Message)"
}
if (-not $BridgeInterface) {
    Write-Warning "Could not resolve default-route interface; falling back to 'en0' for VZ bridge."
    $BridgeInterface = 'en0'
}

# --- REGION: Pick network mode
# Bridged QEMU networking is unreliable over Wi-Fi: the AP commonly drops
# frames from the VM's locally-administered MAC, so a bridged cache never
# gets a LAN DHCP lease. On a Wi-Fi-only default route build the cache on
# UTM Shared NAT (192.168.64.x) instead -- the host and other Shared-NAT
# UTM guests reach it directly, and Start-CachingProxyServiceVM.ps1 exposes it to
# the wider LAN via host port-forwarders. Ethernet keeps bridged (LAN-
# direct, real client IPs).
if ($NetworkMode -eq 'Shared') {
    Write-Output "Default route is Wi-Fi ($BridgeInterface) -- bridged can't get a LAN lease over Wi-Fi; building the cache on UTM Shared NAT. Start-CachingProxyServiceVM.ps1 will forward host ports to it for LAN access."
} else {
    Write-Output "Bridge interface: $BridgeInterface (cache VM will request DHCP on this LAN)"
}

# --- REGION: https://yuruna.link/caching-proxy-service#cache-vm-sizing
# 12 GB RAM on all three hosts, vCPUs from the core-count policy
# (min 4), budgeted around squid's cache_mem;
# swap is masked, so undersizing is an unrecoverable OOM.
# --- REGION: https://yuruna.link/definition#defining-the-vm-core-count-policy
$hostCores = [int](& /usr/sbin/sysctl -n hw.physicalcpu)
if ($hostCores -lt 4) {
    Write-Error "Host has $hostCores physical cores; Yuruna requires at least 4. See https://yuruna.link/definition#defining-the-vm-core-count-policy"
    exit 1
}
$vmCores = [math]::Max(4, [math]::Floor($hostCores / 2))

$PlistContent = (Get-Content -Raw $TemplatePath) `
    -replace '__VM_NAME__',            $VMName `
    -replace '__VM_UUID__',            $VmUuid `
    -replace '__MAC_ADDRESS__',        $MacAddress `
    -replace '__NETWORK_MODE__',       $NetworkMode `
    -replace '__DISK_IDENTIFIER__',    $DiskId `
    -replace '__DISK_IMAGE_NAME__',    'disk.qcow2' `
    -replace '__SEED_IDENTIFIER__',    $SeedId `
    -replace '__SEED_IMAGE_NAME__',    'seed.iso' `
    -replace '__VNC_DISPLAY__',        "$VncDisplay" `
    -replace '__CPU_COUNT__',          "$vmCores" `
    -replace '__MEMORY_SIZE__',        '12288'

# Bridged mode needs the physical NIC name; Shared NAT carries no
# BridgedInterface key (matches the sibling Shared templates, e.g.
# guest.amazon.linux.2023), so drop the key/value entirely in that mode.
if ($NetworkMode -eq 'Shared') {
    $PlistContent = $PlistContent -replace "(?m)^[ \t]*<key>BridgedInterface</key>\r?\n[ \t]*<string>__BRIDGE_INTERFACE__</string>\r?\n", ''
} else {
    $PlistContent = $PlistContent -replace '__BRIDGE_INTERFACE__', $BridgeInterface
}

Set-Content -Path "$UtmDir/config.plist" -Value $PlistContent

$lintOutput = & plutil -lint "$UtmDir/config.plist" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Generated config.plist failed plist validation: $lintOutput"
    Write-Error "Inspect the file at: $UtmDir/config.plist"
    exit 1
}
Write-Verbose "config.plist validated OK (VNC on 127.0.0.1:$(5900 + $VncDisplay))."

# --- REGION: Cleanup temporary folders
Remove-Item -LiteralPath $SeedDir -Recurse -Force -ErrorAction SilentlyContinue

# --- REGION: Guidance
# LITERAL here-string (@'...'@) for the multi-line block. Shell snippets
# below contain $(utmctl ...), "$ip", etc. -- pass through verbatim, do
# NOT let PowerShell evaluate. Placeholders like __VM_NAME__ are
# substituted after the fact via .Replace(). Backslash-escaping (\$)
# does NOT work: \ is not a PowerShell string escape, so `\$(utmctl ...)`
# inside a double-quoted/expandable string actually runs utmctl mid-guidance.
Write-Output ""
Write-Output "== VM bundle created =="
Write-Output "  Path:      $UtmDir"
Write-Output "  Backend:   QEMU (HVF) with -vnc 127.0.0.1:$VncDisplay (port $(5900 + $VncDisplay))"
Write-Output ""
Write-Output "  Console/SSH login:"
Write-Output "    user:     caching-proxy-service-admin"
Write-Output "    password: $PasswordFile"
Write-Output "    (also embedded in the seed.iso's user-data -- chpasswd)"
$guidance = @'

Next steps (any guest consumer will ERROR -- not silently fall back
to direct CDN -- if it finds this VM but can't reach port 3128, so
verify all three checks below before starting guest installs):

  1. Register with UTM:
       open '__UTM_DIR__'    # double-click equivalent

  2. Start the VM and wait 5-15 minutes for cloud-init
     (install squid + apache2, then pre-warm):
       utmctl start __VM_NAME__

  3. Find the VM's IP. `utmctl ip-address` needs the qemu-guest-agent
     inside the guest (not installed by this seed) -- use one of these
     instead:
     a) Easiest -- look in the UTM window for __VM_NAME__; the Linux
        console prints "eth0: <ip>" at the login prompt after DHCP.
     b) Apple's shared-NAT DHCP leases (usually user-readable):
          awk -F'[ =]' '/name=__VM_NAME__/{found=1} found && /ip_address/{print $NF; exit}' \
              /var/db/dhcpd_leases
     c) Port-scan the Shared-NAT subnet for a squid listener:
          for i in $(seq 2 254); do
            nc -z -w 1 192.168.64.$i 3128 2>/dev/null && echo "squid at 192.168.64.$i"
          done
     Call the resulting address `$ip` in the remaining steps.

  4. Verify squid is listening on port 3128:
       nc -z -w 3 "$ip" 3128 && echo 'squid OK' || echo 'squid DOWN'

  5. Verify pre-warm finished (cache occupancy should be > 0):
       ssh caching-proxy-service-admin@$ip "squidclient mgr:storedir"    # StoreEntries > 0

If step 4 reports 'squid DOWN' after 15 minutes, access the VM:
  * UTM window:  login 'caching-proxy-service-admin' / password '__PASSWORD__'
                 (password also at __PASSWORD_FILE__; does NOT expire)
  * SSH:         ssh caching-proxy-service-admin@$ip   (uses the yuruna harness key
                                   at test/status/ssh/yuruna_ed25519; passwordless)

Then -- REAL apt/cloud-init errors live in the output log, not in
'cloud-init status'. Run this FIRST:
  sudo grep -E 'E:|429 |Hash Sum|Failed to fetch|Unable to locate|Exit code' \
    /var/log/cloud-init-output.log | head -40

If that's inconclusive, fall back to:
  cloud-init status --long
  sudo tail -n 300 /var/log/cloud-init-output.log
  systemctl status squid

'429 Too Many Requests' in the log -> Ubuntu's CDN rate-limited
this Mac's public IP while cloud-init tried to install squid.
Wait 15-30 min and rebuild by re-running this script.
'@
Write-Output ($guidance.
    Replace('__VM_NAME__', $VMName).
    Replace('__UTM_DIR__', $UtmDir).
    Replace('__PASSWORD__', $AdminPassword).
    Replace('__PASSWORD_FILE__', $PasswordFile))

# --- REGION: hand root-run artifacts back to the operator
# Guard only: the supported invocation is UNELEVATED (these scripts elevate the
# individual operations that need it, and root has no Aqua session for open /
# utmctl / osascript). But a run that did reach here as root left the bundle,
# the base image, the seed and the harness key root-owned, and UTM -- running as
# the operator -- could neither open this VM nor delete it on the next rebuild.
# The whole ~/yuruna tree, not just this bundle: unlinking a directory needs
# write permission on its parent, and guest.nosync is shared by every builder.
[void](Restore-SudoUserOwnership -Path @("$HOME/yuruna", (Join-Path $_repoRootForExt 'test/status')) -Confirm:$false)
