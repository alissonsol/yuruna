<#PSScriptInfo
.VERSION 2026.09.24
.GUID 4242f187-1ce6-46a5-a5a4-7c2435ed1ac1
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
        Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_5a147a3482612cdd')
        exit 1
    }
}

Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_3e3de8bf7b8f6ba1')
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_73905e18abf967cb')
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

if (-not (Assert-YurunaBaseImage -BaseImageFile $baseImageFile -GuestFolder $PSScriptRoot)) { exit 1 }

# --- REGION: Remove existing VM
# Runs AFTER the base image is confirmed so a failed image fetch never
# destroys a working VM.
$existingVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($existingVM) {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_96658c0e8ad547f3' -Arguments @{ vMName = "$VMName" })
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
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_1c714189825ec0e2' -Arguments @{ vMName = "$VMName"; message = "$($_.Exception.Message)"; diag = "$diag" })
    }
    # Hyper-V can return Remove-VM success while leaving a ghost entry;
    # a second Get-VM is the only reliable post-condition.
    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_634b857addaa8df5' -Arguments @{ vMName = "$VMName" })
    }
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_86f314067f7955de' -Arguments @{ vMName = "$VMName" })
}

# --- REGION: Create copies and files for VM
$vmDir = Join-Path $downloadDir $VMName
if (-not (Test-Path -Path $vmDir)) {
    New-Item -ItemType Directory -Path $vmDir -Force | Out-Null
}
$vhdxFile = Join-Path $vmDir "$VMName.vhdx"

# --- REGION: Copy base image -> per-VM disk
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_ab4cd688f667666f' -Arguments @{ vMName = "$VMName" })
Copy-Item -Path $baseImageFile -Destination $vhdxFile -Force

# --- REGION: Grow the per-VM disk to 512 GB
# See https://yuruna.link/42e220c4-0004
# The dynamic 512 GiB disk must fit Squid's 384 GiB cache plus OS, logs, and headroom.
if (-not (Expand-ExtensionVmDisk -Path $vhdxFile -SizeBytes 512GB -Format 'vhdx')) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_af869066056e98b8' -Arguments @{ vhdxFile = "$vhdxFile" })
    exit 1
}

# --- REGION: Stage the cloud-init seed directory
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

# --- REGION: https://yuruna.link/4220a755-000b
Copy-Item -Path (Join-Path $hostVmConfigDir 'guest-dhcp.network-config') -Destination "$SeedDir/network-config"

# --- REGION: Yuruna harness SSH key
# See https://yuruna.link/42e220c4-0004
# Seed the shared harness key so guest provisioning and failure diagnostics agree.
$TestSshModule = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) "test/modules/Test.Ssh.psm1"
Import-Module $TestSshModule -Force
Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Common.psm1') -Force -DisableNameChecking
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_6424990f88c7f7bc' -Arguments @{ testSshModule = "$TestSshModule" }); exit 1 }

# --- REGION: Vault admin password
# See https://yuruna.link/42f6b05f-0041
# The runtime state file <track>/yuruna-caching-proxy-service.yml is the source of
# truth; Set-Password rehydrates the vault from it before Get-Password.
$_repoRootForExt = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
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
# Resolve the file path once for the Write-Output lines below.
$PasswordFile = Get-CachingProxyServiceStatePath

# --- REGION: Select the guest network
# See https://yuruna.link/42e220c4-0004
# Select the switch before deriving its reachable host address for the seed.
$switchName = Get-OrCreateYurunaExternalSwitch
if (-not $switchName) {
    $switchName = 'Default Switch'
    if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
        # --- REGION: https://yuruna.link/42e220c4-0004
        # Verify the fallback exists; prefer non-External switches when bridging is unavailable.
        $substituteSwitch = @(Get-VMSwitch -ErrorAction SilentlyContinue) |
            Sort-Object @{ Expression = { $_.SwitchType -eq 'External' } }, Name |
            Select-Object -First 1
        if ($substituteSwitch) {
            $switchName = $substituteSwitch.Name
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_38edbb4cc8da6eb6' -Arguments @{ switchName = "$switchName" })
        }
    }
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_6ec7fa5a08a2eb27' -Arguments @{ switchName = "$switchName" })
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_1aa1ad3b20325e89')
}

# --- REGION: https://yuruna.link/4220a755-001b
# Hyper-V: the host IP comes from the vSwitch picked above (Get-GuestReachableHostIp -SwitchName); empty -> github fallback.
$YurunaHostIp = Get-GuestReachableHostIp -SwitchName $switchName
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
$SeedIso = Join-Path $vmDir "seed.iso"
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_5f1478be62ab5e8d')
CreateIso -SourceDir $SeedDir -OutputFile $SeedIso -VolumeId "cidata"

# Surface credentials BEFORE the long VM-create/boot/cloud-init wait.
# If anything in those 20-35 minutes fails (cloud-init stall, apt rate-
# limit, yuruna.conf parse error), the operator needs to console-login
# via vmconnect -- without the password they'd have to dig seed.iso off
# disk. The final "ready" banner reprints the same credentials.
Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_988e727e609d9616')
Write-Output "  user:     caching-proxy-service-admin"
Write-Output "  password: $PasswordFile"
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_491b6a0a529b230a' -Arguments @{ vMName = "$VMName" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_095582e0ec3b9dc8')
Write-Output ""

# --- REGION: Create and configure the Hyper-V VM
# See https://yuruna.link/42f6b05f-0040
# RAM comes from the caller, paired with squid's cache_mem by
# Get-CachingProxyMemoryProfile -- the two are budgeted against each other
# and swap is masked, so undersizing is an unrecoverable OOM. The default
# below is the beacon pairing, matched across all three hosts. 4 vCPU.
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_b0bde9c66516dc8a' -Arguments @{ vMName = "$VMName"; switchName = "$switchName" })
Hyper-V\New-VM -Name $VMName -Generation 2 -MemoryStartupBytes ($MemoryMb * 1MB) -SwitchName $switchName -VHDPath $vhdxFile | Out-Null

# --- REGION: https://yuruna.link/4220a755-000a
# Hyper-V takes bare hex, no separators.
$YurunaGuestMac = Get-YurunaGuestMacAddress -VMName $VMName
Hyper-V\Set-VMNetworkAdapter -VMName $VMName -StaticMacAddress ($YurunaGuestMac -replace ':','')
Write-Verbose "Deterministic guest MAC for '$VMName': $YurunaGuestMac"

if ($MacAddress) {
    # Pin the NIC's MAC before first start so the very first DHCP request
    # already carries it -- an operator DHCP reservation keyed to this MAC
    # then gives the cache VM a known, stable IP across rebuilds.
    # StaticMacAddress takes bare hex (no separators).
    Set-VMNetworkAdapter -VMName $VMName -StaticMacAddress ($MacAddress -replace ':', '') | Out-Null
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_72688841a15cc72b' -Arguments @{ macAddress = "$MacAddress" })
}
Set-VM -Name $VMName -MemoryStartupBytes ($MemoryMb * 1MB) -MemoryMinimumBytes ($MemoryMb * 1MB) -MemoryMaximumBytes ($MemoryMb * 1MB) -AutomaticCheckpointsEnabled $false | Out-Null
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off | Out-Null

# --- REGION: https://yuruna.link/42dc5bb9-0005
# No-op on AMD64. On ARM64 the heartbeat channel drives a Linux guest into
# repeated soft lockups before hv_storvsc registers, so the root disk never
# enumerates and the guest never reaches squid at all. Set before the DVD is
# attached so the guest's first boot is already free of it. The readiness
# summary below reads Heartbeat and has to tolerate its absence as a result.
$null = Disable-HyperVHeartbeatForLinuxGuest -VMName $VMName -Confirm:$false

Add-VMDvdDrive -VMName $VMName -Path $SeedIso | Out-Null
# --- REGION: https://yuruna.link/42fa6f45-0015
$hostCores = (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
if ($hostCores -lt 4) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_b35de16dca777b44' -Arguments @{ hostCores = "$hostCores" })
    exit 1
}
$vmCores = [math]::Max(4, [math]::Floor($hostCores / 2))
$vmCores = Limit-HyperVLinuxGuestCoreCount -RequestedCores $vmCores
Set-VMProcessor -VMName $VMName -Count $vmCores | Out-Null

# --- REGION: Clean up temporary files
Remove-Item -LiteralPath $SeedDir -Recurse -Force -ErrorAction SilentlyContinue

# --- REGION: Start VM and wait for squid
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_44a010f47f51d941' -Arguments @{ vMName = "$VMName" })
Hyper-V\Start-VM -Name $VMName

Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_2c8ff2df499f232c')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_f257239b1955c535')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_e6346c74a10ae90e')

# --- REGION: https://yuruna.link/42e220c4-0004
# Discover address candidates first; the later Squid probe identifies the serving address.
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
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_d46bfe5d280db98e' -Arguments @{ switchName = "$switchName"; uplinkVerdict = "$uplinkVerdict" })
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
        # --- REGION: https://yuruna.link/42e220c4-0004
        # Refresh neighbors on bridged networks while KVP is still unavailable.
        if ($i -eq 0) {
            $cacheVmOnExternalSwitch = $switchIsExternal -and
                (($vm | Get-VMNetworkAdapter -ErrorAction SilentlyContinue |
                        Select-Object -First 1).SwitchName -eq $switchName)
        }
        if ($cacheVmOnExternalSwitch -and $i -ge 6) {
            if (-not $arpProbeAnnounced) {
                Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_30a13394d0b4c5ed' -Arguments @{ switchName = "$switchName" })
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
                Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_711aec356a249726' -Arguments @{ vmMacDashed = "$vmMacDashed" })
                Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_f766bdb59d4e3038' -Arguments @{ vMName = "${VMName}"; join = "$($cacheCandidateIps -join ', ')" })
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
    # Get-VM reports no Heartbeat at all once the integration service is off,
    # which is the ARM64 case above. Name that state rather than rendering an
    # empty field, which reads as a failed probe instead of an absent one.
    if (-not $hb) { $hb = 'n/a' }
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

========
ERROR: caching-proxy-service VM '$VMName' did not obtain an IP address within $waitMinutes minutes.
========

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
========
"@
    $Host.UI.WriteLine([ConsoleColor]::Red, $Host.UI.RawUI.BackgroundColor, $detail)
    exit 1
}

Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_83f218ab43caf348' -Arguments @{ join = "$($cacheCandidateIps -join ', ')" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_9fd4cfcb4f9f1fd3')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_4ace8c3ff53c8f23')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_d5a3fa645b8d4936')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_6a2d68f7c8f9b5ed')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_a7dbfa1fdd6ae717')

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
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_4535de8a13b4592f')
        Write-Output "  VM:        $VMName"
        Write-Output "  IP:        $cacheIp"
        Write-Output "  Proxy:     http://${cacheIp}:${cacheHttpPort}"
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_1043864cdd7a3dc7')
        Write-Output ""
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_a19074ac4867746e')
        Write-Output "    user:     caching-proxy-service-admin"
        Write-Output "    password: $PasswordFile"
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_a9dbdd1577bb8c0e')
        Write-Output ""
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_53cb004a6b8ce8fe')
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_34f70e922875bd84')
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_29c6b97f1b20760c')
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_718c4e1c88e35084')
        Write-Output ""
        Write-Output ((Format-YurunaOperatorMessage -Key 'host.operator_ac9a237901fc8f7d').Replace("`n", [Environment]::NewLine))
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

========
ERROR: squid did not start listening on :3128 within 15 minutes.
  Candidate IPs probed: $candidateList
========

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
========
"@
$Host.UI.WriteLine([ConsoleColor]::Red, $Host.UI.RawUI.BackgroundColor, $detail)
exit 1
