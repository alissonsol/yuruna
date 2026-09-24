<#PSScriptInfo
.VERSION 2026.09.24
.GUID 4220d762-3e46-4f5b-808c-166adb4d8b1b
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
.PARAMETER AllowPseudoLocale
    Enable developer pseudo locales for this VM. Disabled by default.
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
    [string]$MacAddress,
    # Sizing travels as a pair. Swap is masked in the guest, so a cache_mem that
    # outgrows its VM is an unrecoverable OOM rather than a slowdown -- passing
    # one without the other is the mistake these two parameters exist to make
    # visible. The defaults are the lab profile, and they stay literal because
    # the setup preflight reads the committed size out of this source.
    [Parameter()]
    [int]$MemoryMb = 12288,
    [Parameter()]
    [string]$SquidCacheMem = '7 GB',
    [switch]$AllowPseudoLocale
)

Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Globalization.psm1') -DisableNameChecking

# --- REGION: Log level from environment
# See https://yuruna.link/42e220c4-0003
# Reuse the caller's log module; a forced reload discards its state.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (-not (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) -and (Test-Path $_logLevelMod)) {
    Import-Module $_logLevelMod -Global
}
if (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) { Use-LogLevelFromEnv }

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_e147c2f7708fdd27' -Arguments @{ vMName = "$VMName" })
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
        Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_5a147a3482612cdd')
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
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_b17b4a09c8f6f0f6')
    exit 1
}

# --- REGION: Seek the base image
# One cloud image backs every extension service on this host; this VM grows
# its own copy below (host/modules/Yuruna.Image.psm1).
# Auto-run Get-Image.ps1 once if the base image is missing; recheck and
# only error out when it's still missing afterward.
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules/Yuruna.Image.psm1') -Force
$baseImageFile = (Get-UbuntuExtensionImageInfo -HostType 'macos.utm').BaseImageFile
if (-not (Assert-YurunaBaseImage -BaseImageFile $baseImageFile -GuestFolder $PSScriptRoot)) { exit 1 }

Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_d9b89a1cbf294786' -Arguments @{ vMName = "$VMName"; baseImageFile = "$baseImageFile" })
# Provenance side-channel for operators reading the transcript. Emits
# "Provenance: <url>" when the sidecar is healthy; warns otherwise.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

# --- REGION: Remove existing VM
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/Yuruna.Host.psm1') -Force
if (-not (Remove-UtmBundleWithRetry -Path $UtmDir)) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_7565389d0d010c89' -Arguments @{ utmDir = "$UtmDir" })
    exit 1
}

# --- REGION: Create copies and files for VM
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# EFI vars: QEMU has its own EDK2 firmware; UEFIBoot=true in the plist
# makes UTM provide a per-bundle pflash file automatically. A Swift
# VZEFIVariableStore step is needed only for the Apple Virtualization
# backend, which these bundles do not use.

# --- REGION: Copy base image -> per-VM disk
# Copy the pre-built qcow2 cloud image into the bundle as the boot disk; no
# conversion here. qcow2 (not raw) is deliberate: UTM's QEMU backend boots it
# directly and it sidesteps the macOS F_PUNCHHOLE-alignment EINVAL a raw
# disk hits under UTM's discard=unmap,detect-zeroes=unmap -- see
# feedback_macos-qemu-punchhole-alignment.md.
$DiskImage = "$DataDir/disk.qcow2"
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_6288433a06ff55be')
# `/bin/cp -c` triggers APFS clone (O(1), sparse-preserving). Falls back
# to Copy-Item if the destination isn't APFS (rare). Full path bypasses
# the PowerShell `cp` alias for Copy-Item.
& /bin/cp -c $baseImageFile $DiskImage
if ($LASTEXITCODE -ne 0) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_6a80b3350f680db8')
    Copy-Item -Path $baseImageFile -Destination $DiskImage
}

# --- REGION: Grow the per-VM disk to 512 GB
# See https://yuruna.link/42e220c4-0004
# Keep enough virtual capacity for the Squid cache and OS/log headroom.
if (-not (Expand-ExtensionVmDisk -Path $DiskImage -SizeBytes 512GB -Format 'qcow2')) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_016292885d6c36cc' -Arguments @{ diskImage = "$DiskImage" })
    exit 1
}

# --- REGION: Stage the cloud-init seed directory
$SeedDir = Join-Path $downloadDir "seed_temp/$VMName"
if (Test-Path -LiteralPath $SeedDir) { Remove-Item -LiteralPath $SeedDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null

# meta-data is shared under host/vmconfig/ (byte-identical across all 3 host platforms).
$hostVmConfigDir = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))) 'host/vmconfig'
Copy-Item -Path (Join-Path $hostVmConfigDir 'caching-proxy-service.meta-data') -Destination "$SeedDir/meta-data"

# --- REGION: https://yuruna.link/4220a755-000b
Copy-Item -Path (Join-Path $hostVmConfigDir 'guest-dhcp.network-config') -Destination "$SeedDir/network-config"

# --- REGION: Yuruna harness SSH key
# See https://yuruna.link/42e220c4-0004
# Seed the shared harness key so guest provisioning and failure diagnostics agree.
$TestSshModule = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))) "test/modules/Test.Ssh.psm1"
Import-Module $TestSshModule -Force
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_6424990f88c7f7bc' -Arguments @{ testSshModule = "$TestSshModule" }); exit 1 }

# --- REGION: Vault admin password
# See https://yuruna.link/42f6b05f-0041
# The runtime state file <track>/yuruna-caching-proxy-service.yml is the source of
# truth; Set-Password rehydrates the vault from it before Get-Password.
$_repoRootForExt = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))
Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.Extension.psm1')    -Global -Force -Verbose:$false
Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.CachingProxyService.psm1') -Global -Force -Verbose:$false
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$persisted = (Read-CachingProxyServiceState).password
if ($persisted) { Set-Password -Username 'caching-proxy-service-admin' -NewPassword $persisted }
$AdminPassword = Get-Password -Username 'caching-proxy-service-admin'
if (-not $AdminPassword) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_47959938846e1bd4'); exit 1 }
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_762658980a25b8fb' -Arguments @{ authActiveName = "$_authActiveName" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_c427eb2402415f42' -Arguments @{ authentication = "$(Resolve-ExtensionAreaDir -Area 'authentication')" })
[void](Save-CachingProxyServiceState -Secret $AdminPassword -Confirm:$false)
$PasswordFile = Get-CachingProxyServiceStatePath

# --- REGION: Select the guest network
# See https://yuruna.link/4220a755-001b
# macOS: NetworkMode pair -- Wi-Fi -> Shared NAT (VZ gateway 192.168.64.1), Ethernet -> bridged (host LAN IP). Resolved once here and reused for the plist below, so the mode and the address can never disagree.
Import-Module (Join-Path $_repoRootForExt 'host/macos.utm/modules/Yuruna.Host.psm1') -Force
$NetworkMode = Resolve-UtmNetworkMode
if ($env:YURUNA_GUEST_REACHABLE_HOST_IP) {
    $YurunaHostIp = $env:YURUNA_GUEST_REACHABLE_HOST_IP
} else {
    $YurunaHostIp = Get-GuestReachableHostIp -NetworkMode $NetworkMode
}
if (-not $YurunaHostIp) { $YurunaHostIp = '' }
Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.Config.psm1') -Global -Force
Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.Locale.psm1') -Global -Force
$_statusSeed = Get-YurunaStatusServiceSeed -RepoRoot $_repoRootForExt
$YurunaHostPort = $_statusSeed.Port
$tc = $_statusSeed.Config
$languageRaw = [string](Get-TestConfigValue -Config $tc -Path 'language')
$serviceLanguage = if ([string]::IsNullOrWhiteSpace($languageRaw) -or $languageRaw -ieq 'auto') {
    'auto'
} else {
    ConvertTo-CanonicalLocaleTag -Tag $languageRaw
}
if (-not $serviceLanguage) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_8fa181c2fe215cd1' -Arguments @{ languageRaw = "$languageRaw" }) }
$allowPseudoLocaleValue = if ($AllowPseudoLocale) { 'true' } else { 'false' }

# --- REGION: Pool storage replication
# See https://yuruna.link/42f6b05f-0042
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
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_4f836dfb9d84f4e5')
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
    Write-Warning ((Format-YurunaOperatorMessage -Key 'host.operator_7691e5e3206997ff' -Arguments @{ message = "$($_.Exception.Message)" }))
}
# Trim first, then refuse whatever survives. Every reader of the baked file strips
# surrounding whitespace, so a stored value that merely picked up a trailing newline
# is healed here rather than costing the proxy its key. Interior whitespace or a
# quote has no safe reading: it would corrupt the baked key file or the runner's
# bearer header.
$internalAuthKey = $internalAuthKey.Trim()
if ($internalAuthKey -match '[\s''"]') {
    Write-Warning ((Format-YurunaOperatorMessage -Key 'host.operator_714943b9011e0bbd'))
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
    Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.ConfigServiceSync.psm1') -Global -Force -DisableNameChecking
    $keyProvision = Set-InternalAuthKey -Token $internalAuthKey
    if ($keyProvision.ok) {
        # A warning, not a status line: this mint sets the key for the WHOLE lab, and
        # it is silent from every other host's point of view. A pool that was already
        # enrolled against an earlier proxy keeps the old key and reads as
        # "onsite (token mismatch)" on the dashboard from the moment this proxy comes
        # up, with no clue pointing back here.
        Write-Warning ((Format-YurunaOperatorMessage -Key 'host.operator_2098089a9d722ad9' -Arguments @{ vaultKey = "$($keyProvision.vaultKey)" }))
    } else {
        Write-Warning ((Format-YurunaOperatorMessage -Key 'host.operator_641824f231dc3781' -Arguments @{ keyChanged = "$($keyProvision.keyChanged)"; verified = "$($keyProvision.verified)" }))
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
    Write-Warning ((Format-YurunaOperatorMessage -Key 'host.operator_c8f003fc6b37a1de' -Arguments @{ message = "$($_.Exception.Message)" }))
    $dockerHubWarned = $true
}
# Refuse a value carrying a control character, quote, or backslash: the guest
# stores this pair as JSON. A control character or a bare quote leaves that file
# unparseable, and a backslash is the JSON escape introducer, so a stored
# backslash-n reads back as a newline -- a DIFFERENT secret, presented to Hub on
# every sync in place of the anonymous path that would have been served.
if (($dockerHubUsername -match '[\x00-\x1f\x7f''"\\]') -or ($dockerHubToken -match '[\x00-\x1f\x7f''"\\]')) {
    Write-Warning ((Format-YurunaOperatorMessage -Key 'host.operator_62a464c885f1b62c'))
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
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_d4180c81874e5196' -Arguments @{ message = "$($_.Exception.Message)" })
}

# --- REGION: Dashboard brand identity
# The Grafana dashboards this VM serves name the enlistment that built it --
# the same pair the host's status pages carry in their header. Resolved here
# because the guest is handed built artifacts and never the framework
# repository, so it has no way to answer this for itself.
Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.FrameworkSource.psm1') -Force
$brand = Get-YurunaBrandIdentity -RepoRoot $_repoRootForExt -Config $tc

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
        YURUNA_LANGUAGE_PLACEHOLDER = $serviceLanguage
        YURUNA_ALLOW_PSEUDO_LOCALE_PLACEHOLDER = $allowPseudoLocaleValue
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
Set-Content -Path "$SeedDir/user-data" -Value $UserData -NoNewline

# --- REGION: Generate cloud-init seed ISO
$SeedIso = "$DataDir/seed.iso"
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_5f1478be62ab5e8d')
& hdiutil makehybrid -o "$SeedIso" -joliet -iso -default-volume-name cidata "$SeedDir" 2>&1 | ForEach-Object { Write-Verbose $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_fea701fd46026b88')
    exit 1
}

# --- REGION: Create and configure the UTM bundle (config.plist, QEMU backend)
$TemplatePath = Join-Path $ScriptDir "config.plist.template"
if (-not (Test-Path $TemplatePath)) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_603b5ff75924a72c' -Arguments @{ templatePath = "$TemplatePath" })
    exit 1
}

$VmUuid  = [guid]::NewGuid().ToString().ToUpper()
$DiskId  = [guid]::NewGuid().ToString().ToUpper()
$SeedId  = [guid]::NewGuid().ToString().ToUpper()

# An operator-supplied -MacAddress (already normalized to colon form
# above) wins; it lets a DHCP reservation pin the cache IP across
# rebuilds. Otherwise generate a fresh random per-bundle MAC.
if (-not $MacAddress) {
# --- REGION: https://yuruna.link/4220a755-000a
$MacAddress = Get-YurunaGuestMacAddress -VMName $VMName
}

# Per-VM VNC display number (Get-VncDisplayForVm hashes the name into
# 10..89). Get-VncPortForVm in the harness derives the same value from
# $VMName, so the producer (this plist) and the consumers (capture,
# keystrokes) agree without a sidecar file.
Import-Module (Join-Path (Split-Path -Parent $ScriptDir) "modules/Yuruna.Host.psm1") -Force
$VncDisplay = Get-VncDisplayForVm -VMName $VMName

# --- REGION: https://yuruna.link/42e220c4-0004
# Use the default-route interface so the bridge and host address share an uplink.
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
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_15685f8ad1d8fea6')
    $BridgeInterface = 'en0'
}

# --- REGION: Report the resolved network mode
# See https://yuruna.link/42e220c4-0004
# Wi-Fi uses Shared NAT and host forwarding; Ethernet retains direct bridging.
if ($NetworkMode -eq 'Shared') {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_719fe58daf1eaf0e' -Arguments @{ bridgeInterface = "$BridgeInterface" })
} else {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_8e8627820f248e51' -Arguments @{ bridgeInterface = "$BridgeInterface" })
}

# --- REGION: https://yuruna.link/42f6b05f-0040
# Keep RAM paired with Squid's cache_mem; swap is disabled, so undersizing causes OOM.
# --- REGION: https://yuruna.link/42fa6f45-0015
$hostCores = [int](& /usr/sbin/sysctl -n hw.physicalcpu)
if ($hostCores -lt 4) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_b35de16dca777b44' -Arguments @{ hostCores = "$hostCores" })
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
    -replace '__MEMORY_SIZE__',        "$MemoryMb"

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
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_1f3a41b9c5302d96' -Arguments @{ lintOutput = "$lintOutput" })
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_24e25e0303ffb73b' -Arguments @{ utmDir = "$UtmDir" })
    exit 1
}
Write-Verbose "config.plist validated OK (VNC on 127.0.0.1:$(5900 + $VncDisplay))."

# --- REGION: Clean up temporary files
Remove-Item -LiteralPath $SeedDir -Recurse -Force -ErrorAction SilentlyContinue

# --- REGION: Guidance
# See https://yuruna.link/42e220c4-0004
# Keep the here-string literal: expandable strings would execute the shell examples.
Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_0aa25de09813cc1c')
Write-Output "  Path:      $UtmDir"
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_0a95ec9679adce8d' -Arguments @{ vncDisplay = "$VncDisplay"; vncDisplay2 = "$(5900 + $VncDisplay)" })
Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_a19074ac4867746e')
Write-Output "    user:     caching-proxy-service-admin"
Write-Output "    password: $PasswordFile"
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_a9dbdd1577bb8c0e')
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
  * UTM window:  login 'caching-proxy-service-admin'
                 (password at __PASSWORD_FILE__; does NOT expire)
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
# The credential is named by LOCATION, never substituted into the text. This
# banner is captured verbatim into the setup and cycle logs, which are kept long
# after the VM is gone and are read by anyone diagnosing a run -- a password
# printed here outlives the machine it belongs to. The password file is
# permissioned; the log is not.
Write-Output ($guidance.
    Replace('__VM_NAME__', $VMName).
    Replace('__UTM_DIR__', $UtmDir).
    Replace('__PASSWORD_FILE__', $PasswordFile))

# --- REGION: Restore operator file ownership
# See https://yuruna.link/42e220c4-0004
# If invoked through sudo, return generated artifacts to the original operator.
[void](Restore-SudoUserOwnership -Path @("$HOME/yuruna", (Join-Path $_repoRootForExt 'test/status')) -Confirm:$false)
