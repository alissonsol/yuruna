<#PSScriptInfo
.VERSION 2026.10.30
.GUID 4284f1a3-c3b1-43a6-8b63-36822be6e25d
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

    See https://yuruna.link/4268e4cb for the full specification.

.PARAMETER VMName
    Name of the Hyper-V VM. Default: yuruna-download-agent-service.
.PARAMETER AllowPseudoLocale
    Enable developer pseudo locales for this VM. Disabled by default.
.PARAMETER PlanOnly
    Resolve and check every input the build needs, report seed values that
    would be baked empty, and exit 0 without changing anything.
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = "yuruna-download-agent-service",
    [switch]$AllowPseudoLocale,
    [switch]$PlanOnly
)

Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = 'Stop'

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

$hostCores = (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
if ($hostCores -lt 4) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_b35de16dca777b44' -Arguments @{ hostCores = "$hostCores" })
    exit 1
}

Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_3e3de8bf7b8f6ba1')
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_73905e18abf967cb')
    exit 1
}

# Assert-HyperVEnabled calls dism.exe directly instead of
# Get-WindowsOptionalFeature -- avoids the "Class not registered" COM
# failure on first post-install runs on fresh Windows 11.
if (-not (Assert-HyperVEnabled)) { exit 1 }

# --- REGION: Resolve the build plan
# Every input that can refuse the build is read before anything is torn down,
# so a missing key, password, template or network leaves the working VM
# untouched. -PlanOnly stops after this region, having changed nothing.
# --- REGION: Yuruna harness SSH key
# See https://yuruna.link/42e220c4-0004
# Seed the shared harness key so guest provisioning and failure diagnostics agree.
$_repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Ssh.psm1')       -Force -DisableNameChecking
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Extension.psm1') -Global -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Common.psm1') -Force -DisableNameChecking
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_24e40b06bcf4c618'); exit 1 }

# --- REGION: Vault admin password
# Each service family has its own admin account: a shared name would map several
# VMs to one vault entry, and the last build would invalidate the others' credential.
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$AdminPassword = Get-Password -Username 'download-agent-service-admin'
if (-not $AdminPassword) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_ce7652d3e480135e'); exit 1 }
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_762658980a25b8fb' -Arguments @{ authActiveName = "$_authActiveName" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_c427eb2402415f42' -Arguments @{ authentication = "$(Resolve-ExtensionAreaDir -Area 'authentication')" })

# Check the shared seed templates before the guest network is resolved.
foreach ($f in @((Join-Path $_repoRoot 'host/vmconfig/download-agent-service.base.user-data'),
        (Join-Path $_repoRoot 'host/vmconfig/download-agent-service.hyperv.overlay.yml'),
        (Join-Path $_repoRoot 'host/vmconfig/download-agent-service.meta-data'))) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_9a1ef2a7551102d0' -Arguments @{ f = "$f" })
        exit 1
    }
}

# --- REGION: Select the guest network
# See https://yuruna.link/42e220c4-0004
# Select the switch before resolving the host address reachable through it.
$switchName = Resolve-HyperVGuestSwitch

# --- REGION: Yuruna host coordinates
# See https://yuruna.link/4220a755-001b
# Bake the status-service address and storage coordinates for the selected network.
Import-Module (Join-Path $_repoRoot 'test/modules/Test.PoolStorage.psm1')  -Global -Force
Import-Module (Join-Path $_repoRoot 'test/modules/Test.YurunaDir.psm1')    -Global -Force
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Config.psm1')       -Global -Force
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Locale.psm1') -Global -Force
Import-Module (Join-Path $_repoRoot 'test/modules/Test.CachingProxyService.psm1') -Global -Force
$YurunaHostIp = Get-GuestReachableHostIp -SwitchName $switchName
if (-not $YurunaHostIp) { $YurunaHostIp = '' }
$_statusSeed = Get-YurunaStatusServiceSeed -RepoRoot $_repoRoot
$YurunaHostPort = $_statusSeed.Port
$tc = $_statusSeed.Config
$serviceLanguage = Resolve-SeedLanguageTag -Config $tc
$allowPseudoLocaleValue = if ($AllowPseudoLocale) { 'true' } else { 'false' }
$poolNas = Get-YurunaPoolSeedValue -Config $tc -GuestReachableAddress $YurunaHostIp

# --- REGION: Report seed values baked empty
# The build goes on without them, because the guest can still serve, but it
# reports each one so the Start says the bring-up is degraded instead of clean.
Import-Module (Join-Path $PSScriptRoot '../../modules/Yuruna.SeedMedia.psm1') -Force
if (-not $YurunaHostIp) { Write-SeedDegradation -VMName $VMName -Name 'hostAddress' }

if ($PlanOnly) {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.service_build_plan_accepted' -Arguments @{ vMName = "$VMName" })
    exit 0
}

# --- REGION: Seek the base image
# One VHDX backs every extension service on this host; this VM grows its own
# copy below (host/modules/Yuruna.Image.psm1).
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "modules/Yuruna.Image.psm1") -Force
$downloadDir = (Get-VMHost).VirtualHardDiskPath
$baseImageFile = (Get-UbuntuExtensionImageInfo -HostType 'windows.hyper-v').BaseImageFile

if (-not (Assert-YurunaBaseImage -BaseImageFile $baseImageFile -GuestFolder $PSScriptRoot)) { exit 1 }

# --- REGION: Base image provenance
# Emit the source URL from a healthy sidecar; warn when provenance is incomplete.
Import-Module (Join-Path $PSScriptRoot '../../../test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

# --- REGION: https://yuruna.link/42e220c4-0004
# Wait before resolving the aggregator URL: an empty value remains baked into the guest seed.
$null = Wait-YurunaAggregatorReady
$aggregatorSeedUrl = Get-PoolAggregatorServiceSeedUrl
if (-not $aggregatorSeedUrl -and @(Get-PoolAggregatorServiceClaim).Count -gt 0) { Write-SeedDegradation -VMName $VMName -Name 'aggregatorUrl' }

# --- REGION: Download-agent configuration
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
# The proxy CA travels in the seed, resolved through this host's pin
# (Resolve-YurunaPinnedProxyCa), instead of the guest fetching it over HTTP.
$cacheCaB64 = ''
if ($cacheProxyIp) {
    Import-Module (Join-Path $PSScriptRoot '../../../test/modules/Test.CachingProxyService.psm1') -Global -Force -WarningAction SilentlyContinue
    $cacheUrlHost = if ($cacheProxyIp.Contains(':')) { "[$cacheProxyIp]" } else { $cacheProxyIp }
    $cacheCa = Get-CachingProxyServiceCaCertBase64 -CacheCaUrl "http://$cacheUrlHost/yuruna-squid-ca.crt" -CacheHost $cacheProxyIp -MaxAttempts 2
    if ($cacheCa.Refused) {
        # An agent seeded with another root would meet a proxy that bumps with
        # this one; the refusal is reported as source_integrity, not built around.
        Write-Error (Format-YurunaOperatorMessage -Key 'host.proxy_ca_refused_build' -Arguments @{ vMName = "$VMName"; cacheHost = "$cacheProxyIp"; reason = "$($cacheCa.Reason)" }) -ErrorAction Continue
        exit (Get-YurunaSourceIntegrityExitCode)
    }
    $cacheCaB64 = [string]$cacheCa.CaCertBase64
}
if ($cacheProxyIp) {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_d4bb65397ec1cb33' -Arguments @{ cacheProxyIp = "$cacheProxyIp" })
} else {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_fdd52e517bbdfc60')
}

# --- REGION: Render user-data / meta-data
# Render user-data from the shared base + Hyper-V overlay (host/vmconfig/
# download-agent-service.*). New-CloudInitUserData resolves placeholders with literal
# .Replace(), so values carrying regex-special chars are safe.
Import-Module (Join-Path $_repoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force
# The NAS password is fetched by the guest over mutual TLS; the seed carries
# only this VM's client leaf for the host config service.
Import-Module (Join-Path $PSScriptRoot '../../../test/modules/Test.ConfigServiceCA.psm1') -Force
$configSeed = Get-YurunaConfigServiceSeedMaterial -VMName $VMName -HostId ([string]$poolNas.HostId) -Config $tc
$UserData = New-CloudInitUserData `
    -BasePath    (Join-Path $_repoRoot 'host/vmconfig/download-agent-service.base.user-data') `
    -OverlayPath (Join-Path $_repoRoot 'host/vmconfig/download-agent-service.hyperv.overlay.yml') `
    -RepoRoot    $_repoRoot `
    -Replacement @{
        YURUNA_LANGUAGE_PLACEHOLDER = $serviceLanguage
        YURUNA_ALLOW_PSEUDO_LOCALE_PLACEHOLDER = $allowPseudoLocaleValue
        SSH_AUTHORIZED_KEY_PLACEHOLDER = $SshAuthorizedKey
        PASSWORD_PLACEHOLDER           = $AdminPassword
        YURUNA_STATUS_SERVICE_IP_PLACEHOLDER     = $YurunaHostIp
        YURUNA_STATUS_SERVICE_PORT_PLACEHOLDER   = $YurunaHostPort
        YURUNA_HOST_ID_PLACEHOLDER     = $poolNas.HostId
        YURUNA_AGGREGATOR_URL_PLACEHOLDER      = $aggregatorSeedUrl
        POOL_NAS_NETWORK_PATH_PLACEHOLDER  = $poolNas.NetworkPath
        POOL_NAS_NETWORK_IP_PLACEHOLDER    = $poolNas.NetworkIp
        POOL_NAS_NETWORK_USER_PLACEHOLDER  = $poolNas.NetworkUser
        YURUNA_CONFIG_SERVICE_PORT_PLACEHOLDER               = $configSeed.Port
        YURUNA_CONFIG_SERVICE_CA_CERT_BASE64_PLACEHOLDER     = $configSeed.CaCertBase64
        YURUNA_CONFIG_SERVICE_CLIENT_CERT_BASE64_PLACEHOLDER = $configSeed.ClientCertBase64
        YURUNA_CONFIG_SERVICE_CLIENT_KEY_BASE64_PLACEHOLDER  = $configSeed.ClientKeyBase64
        DOWNLOAD_AGENT_SCAN_INTERVAL_PLACEHOLDER = $agentScanInterval
        DOWNLOAD_AGENT_FRESHNESS_PLACEHOLDER     = $agentFreshness
        DOWNLOAD_AGENT_PREFETCH_LEAD_PLACEHOLDER = $agentPrefetchLead
        DOWNLOAD_AGENT_AUTO_SEED_PLACEHOLDER     = $agentAutoSeed
        YURUNA_CACHE_PROXY_IP_PLACEHOLDER        = $cacheProxyIp
        YURUNA_CACHE_CA_CERT_BASE64_PLACEHOLDER  = $cacheCaB64
    } -Confirm:$false

# --- REGION: Remove existing VM
# See https://yuruna.link/42e220c4-0004
# Runs after the plan, the base image and the rendered seed are confirmed,
# so a refused input or a failed fetch never destroys a working VM.
Remove-HyperVGuestDefinition -VMName $VMName -Confirm:$false

# --- REGION: Create copies and files for VM
$vmDir = Join-Path $downloadDir $VMName
if (-not (Test-Path -Path $vmDir)) {
    New-Item -ItemType Directory -Path $vmDir -Force | Out-Null
}
$vhdxFile = Join-Path $vmDir "$VMName.vhdx"

# --- REGION: Copy base image -> per-VM disk
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_ab4cd688f667666f' -Arguments @{ vMName = "$VMName" })
Copy-Item -Path $baseImageFile -Destination $vhdxFile -Force

# --- REGION: Grow the per-VM disk to 256 GB
# Dynamic VHDX, so 256 GB is the nominal size only: the file grows as the
# download-agent daemon writes. The pool itself lives on the NAS, not here.
if (-not (Expand-ExtensionVmDisk -Path $vhdxFile -SizeBytes 256GB -Format 'vhdx')) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_dd7b45e336b3fcd0' -Arguments @{ vhdxFile = "$vhdxFile" })
    exit 1
}

# --- REGION: Stage the cloud-init seed directory
# The seed carries the admin password. It is staged in a private workspace
# beside the disk (owner, SYSTEM and Administrators only), published as an
# image only the new VM may read, and removed on every exit by the finally below.
$hostVmConfigDir = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'host/vmconfig'
Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '../../modules/Yuruna.SeedMedia.psm1') -Force
# A plaintext source an older builder left in the temp folder goes first.
Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter "seed_${VMName}_*" -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
$seedWorkspace = $null
try {
    $seedWorkspace = New-SeedMediaWorkspace -ParentPath $vmDir
    $SeedDir = $seedWorkspace.Source

    # meta-data is shared under host/vmconfig/ (byte-identical across all 3 host platforms).
    Copy-Item -Path (Join-Path $hostVmConfigDir 'download-agent-service.meta-data') -Destination "$SeedDir/meta-data"

    Set-Content -Path "$SeedDir/user-data" -Value $UserData -NoNewline
    # --- REGION: https://yuruna.link/4220a755-000b
    Copy-Item -Path (Join-Path $hostVmConfigDir 'guest-dhcp.network-config') -Destination "$SeedDir/network-config"

    # --- REGION: Generate cloud-init seed ISO
    $SeedIso = Join-Path $vmDir "seed.iso"
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_5f1478be62ab5e8d')
    CreateIso -SourceDir $SeedDir -OutputFile $seedWorkspace.Image -VolumeId "cidata"
    Publish-SeedMediaImage -Workspace $seedWorkspace -Path $SeedIso -Confirm:$false

    Write-Output ""
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_2fcefbb032f41229')
    Write-Output "  user:     download-agent-service-admin"
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_32648bd2ca442e7e')
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_491b6a0a529b230a' -Arguments @{ vMName = "$VMName" })
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_095582e0ec3b9dc8')
    Write-Output ""

    # --- REGION: Create and configure the Hyper-V VM
    New-HyperVServiceGuest -VMName $VMName -SwitchName $switchName -DiskPath $vhdxFile -SeedPath $SeedIso -HostCores $hostCores -MemoryMb 2048 -Confirm:$false
    $createdVm = Hyper-V\Get-VM -Name $VMName -ErrorAction Stop
    Grant-SeedMediaVmRead -Path $SeedIso -VMId $createdVm.Id -Confirm:$false

} finally {
    # --- REGION: Clean up temporary files
    Remove-SeedMediaWorkspace -Workspace $seedWorkspace -Confirm:$false
}

# --- REGION: Start the VM
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_44a010f47f51d941' -Arguments @{ vMName = "$VMName" })
Hyper-V\Start-VM -Name $VMName

# --- REGION: Wait for VM IP
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_2c8ff2df499f232c')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_b93b853caa0a1c89')

# Wait-HyperVServiceGuestAddress polls KVP and bridge neighbors, the same
# discovery the caching-proxy-service builder uses.
$ProgressPreference = 'Continue'
$dockCandidateIps = @(Wait-HyperVServiceGuestAddress -VMName $VMName -SwitchName $switchName -TimeoutSeconds 600)

if (-not $dockCandidateIps) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_7e2712db7de40785' -Arguments @{ vMName = "$VMName" })
    exit 1
}

# Single-candidate pick: the download-agent-service UI listens on :80 but v1 does not
# validate it here, so the first non-loopback candidate IP is authoritative.
# When ARP returned multiple candidates, the operator can verify reachability
# with `ssh download-agent-service-admin@<ip>` -- the harness key is already authorized.
$dockIp = $dockCandidateIps | Select-Object -First 1

Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_250f3d63ba951317')
Write-Output "  VM:       $VMName"
Write-Output "  IP:       $dockIp"
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_0d2c724a13016680' -Arguments @{ dockIp = "$dockIp" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_a0be18b888b1e5b4' -Arguments @{ dockIp = "$dockIp" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_e3c81edbb00cfb45' -Arguments @{ vMName = "$VMName" })
Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_57389bd87d496290')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_01b477e8e8a80cd5')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_7e7ca66d8925191f')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_6867e2b5e9483983' -Arguments @{ dockIp = "$dockIp" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_aa82b2cbd9678151')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_c2aed401248959b0')
exit 0
