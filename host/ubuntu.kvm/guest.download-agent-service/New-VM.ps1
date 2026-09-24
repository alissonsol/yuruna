<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42e86329-1c8d-47ab-b9aa-49b5bb5ed6e2
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
.PARAMETER AllowPseudoLocale
    Enable developer pseudo locales for this VM. Disabled by default.
#>

#requires -version 7

<#
.SYNOPSIS
    Creates the Yuruna download-agent service VM on Ubuntu KVM (libvirt).

.DESCRIPTION
    Builds a libvirt VM that boots the Ubuntu 26.04 LTS cloud image
    for the download-agent-service daemon (operator UI + API over the shared
    download pool on the pool NAS). Cloud-init fetches the framework and
    runs the bring-up script which builds the daemon, CIFS-mounts the pool
    NAS that holds the pool, and launches it under systemd.

    See https://yuruna.link/4268e4cb for the full specification.

.PARAMETER VMName
    libvirt domain name. Default: yuruna-download-agent-service.
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = 'yuruna-download-agent-service',
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
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_8be0c49190d15cd0' -Arguments @{ vMName = "$VMName" })
    exit 1
}
if (-not $IsLinux) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_5ca4228177cbc075')
    exit 1
}

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- REGION: libvirt-qemu search ACL on $HOME
# Self-heal libvirt-qemu's search ACL on $HOME (Ubuntu 24.04+ default 0750).
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

Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_d9b89a1cbf294786' -Arguments @{ vMName = "$VMName"; baseImageFile = "$baseImageFile" })
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
    throw (Format-YurunaOperatorMessage -Key 'exceptions.host_d43d0cab95add9be' -Arguments @{ vMName = "$VMName"; join = "$($domainNames -join '; ')" })
}
if ($domainNames | Where-Object { $_.ToString().Trim() -eq $VMName }) {
    $dominfo = (& virsh --connect $virshUri dominfo $VMName 2>&1 | Out-String).Trim()
    throw (Format-YurunaOperatorMessage -Key 'exceptions.host_9174df31c5ee6350' -Arguments @{ vMName = "$VMName"; dominfo = "$dominfo" })
}

# --- REGION: Create copies and files for VM
$vmDir   = Join-Path $HOME "yuruna/vms/$VMName"
$diskImg = Join-Path $vmDir "$VMName.qcow2"
$seedImg = Join-Path $vmDir 'seed.iso'
New-Item -ItemType Directory -Force -Path $vmDir | Out-Null

# --- REGION: Copy base image -> per-VM disk
if (Test-Path -LiteralPath $diskImg) { Remove-Item -Force -LiteralPath $diskImg }
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_8531557fc4c0c787')
& /bin/cp --sparse=always -- $baseImageFile $diskImg
if ($LASTEXITCODE -ne 0) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_a61a7d21cdb5e750' -Arguments @{ baseImageFile = "$baseImageFile"; diskImg = "$diskImg" })
    exit 1
}

# --- REGION: Grow the per-VM disk to 256 GB
# Apparent size only: qcow2 grows on write, so the host gives up nothing
# until the download-agent daemon actually stores that much. The pool itself
# lives on the NAS, not here.
if (-not (Expand-ExtensionVmDisk -Path $diskImg -SizeBytes 256GB -Format 'qcow2')) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_6012ed9325995e9f' -Arguments @{ diskImg = "$diskImg" })
    exit 1
}

# --- REGION: Yuruna harness SSH key
Import-Module (Join-Path $repoRoot 'test/modules/Test.Ssh.psm1')       -Force -DisableNameChecking
Import-Module (Join-Path $repoRoot 'test/modules/Test.Extension.psm1') -Global -Force -Verbose:$false
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_24e40b06bcf4c618'); exit 1 }

# --- REGION: Vault admin password
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$AdminPassword = Get-Password -Username 'download-agent-service-admin'
if (-not $AdminPassword) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_ce7652d3e480135e'); exit 1 }
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_762658980a25b8fb' -Arguments @{ authActiveName = "$_authActiveName" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_c427eb2402415f42' -Arguments @{ authentication = "$(Resolve-ExtensionAreaDir -Area 'authentication')" })

# --- REGION: Render user-data / meta-data
$baseUserData     = Join-Path $repoRoot 'host/vmconfig/download-agent-service.base.user-data'
$overlayUserData  = Join-Path $repoRoot 'host/vmconfig/download-agent-service.kvm.overlay.yml'
$metaDataTemplate = Join-Path $repoRoot 'host/vmconfig/download-agent-service.meta-data'
foreach ($f in @($baseUserData, $overlayUserData, $metaDataTemplate)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_9a1ef2a7551102d0' -Arguments @{ f = "$f" })
        exit 1
    }
}
# --- REGION: Select the guest network
# The baked NAS + source coordinates depend on whether this is NAT
# 'default' (host = libvirt gateway) or bridged 'yuruna-external' (host =
# LAN IP), so resolve the network first.
Import-Module (Join-Path (Split-Path -Parent $ScriptDir) 'modules/Yuruna.Host.psm1') -Force -DisableNameChecking
$networkName = Get-ExternalNetwork
if (-not $networkName) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_a32e7c960a5619ec')
    exit 1
}
if ($networkName -eq 'default') {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_c3465a5d4374dceb')
} else {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_a992df14833de4b7' -Arguments @{ networkName = "$networkName" })

    # --- REGION: Bridge-uplink preflight
    # See https://yuruna.link/42e220c4-0004
    # Reject a confirmed dead bridge; leave network repair to the caching-proxy launcher.
    $netXml = (& virsh --connect $virshUri net-dumpxml $networkName 2>$null) -join "`n"
    if ($netXml -match "<forward\s+mode='bridge'" -and $netXml -match "<bridge\s+name='([^']+)'") {
        $extBridge = $Matches[1]
        $brifDir   = "/sys/class/net/$extBridge/brif"
        $physPorts = if (Test-Path -LiteralPath $brifDir) {
            @(Get-ChildItem -LiteralPath $brifDir -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch '^(vnet|tap)\d+$' })
        } else { @() }
        if ($physPorts.Count -eq 0) {
            Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_da47370b58937f49' -Arguments @{ networkName = "$networkName"; extBridge = "$extBridge" })
            exit 1
        }
    }
}

# --- REGION: https://yuruna.link/4220a755-001b
# Host coordinates (status service, for the in-VM source fetch) + pool storage
# coordinates (the NAS that holds the download pool), baked into the seed.
# Honor an explicit override.
Import-Module (Join-Path $repoRoot 'test/modules/Test.PoolStorage.psm1')  -Global -Force
Import-Module (Join-Path $repoRoot 'test/modules/Test.YurunaDir.psm1')    -Global -Force
Import-Module (Join-Path $repoRoot 'test/modules/Test.Config.psm1')       -Global -Force
Import-Module (Join-Path $repoRoot 'test/modules/Test.Locale.psm1') -Global -Force
Import-Module (Join-Path $repoRoot 'test/modules/Test.CachingProxyService.psm1') -Global -Force
Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Common.psm1') -Force -DisableNameChecking
if ($env:YURUNA_GUEST_REACHABLE_HOST_IP) {
    $YurunaHostIp = $env:YURUNA_GUEST_REACHABLE_HOST_IP
} elseif ($networkName -eq 'default') {
    $YurunaHostIp = Get-GuestReachableHostIp   # NAT 'default': libvirt gateway
} else {
    $YurunaHostIp = Get-BestHostIp             # bridged 'yuruna-external': host LAN IP
}
if (-not $YurunaHostIp) { $YurunaHostIp = '' }
$_statusSeed = Get-YurunaStatusServiceSeed -RepoRoot $repoRoot
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
$poolNas = Get-YurunaPoolSeedValue -Config $tc -GuestReachableAddress $YurunaHostIp
# --- REGION: https://yuruna.link/42e220c4-0004
# Wait before resolving the aggregator URL: an empty value remains baked into the guest seed.
$null = Wait-YurunaAggregatorReady
$aggregatorSeedUrl = Get-PoolAggregatorServiceSeedUrl

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
if ($cacheProxyIp) {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_d4bb65397ec1cb33' -Arguments @{ cacheProxyIp = "$cacheProxyIp" })
} else {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_fdd52e517bbdfc60')
}

# Render user-data from the shared base + KVM overlay (host/vmconfig/
# download-agent-service.*). New-CloudInitUserData resolves placeholders with literal
# .Replace(), so values carrying regex-special chars are safe.
Import-Module (Join-Path $repoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force
$userData = New-CloudInitUserData `
    -BasePath    $baseUserData `
    -OverlayPath $overlayUserData `
    -RepoRoot    $repoRoot `
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
        POOL_NAS_PASSWORD_PLACEHOLDER      = $poolNas.Password
        DOWNLOAD_AGENT_SCAN_INTERVAL_PLACEHOLDER = $agentScanInterval
        DOWNLOAD_AGENT_FRESHNESS_PLACEHOLDER     = $agentFreshness
        DOWNLOAD_AGENT_PREFETCH_LEAD_PLACEHOLDER = $agentPrefetchLead
        DOWNLOAD_AGENT_AUTO_SEED_PLACEHOLDER     = $agentAutoSeed
        YURUNA_CACHE_PROXY_IP_PLACEHOLDER        = $cacheProxyIp
    } -Confirm:$false
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
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_3d53fa1f73f89fed' -Arguments @{ lASTEXITCODE = "$LASTEXITCODE" })
    exit 1
}

Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_2fcefbb032f41229')
Write-Output "  user:     download-agent-service-admin"
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_32648bd2ca442e7e')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_fa07a6efcd13635f')
Write-Output "    virt-viewer --connect $virshUri $VMName"
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_095582e0ec3b9dc8')
Write-Output ""

# --- REGION: Create and configure the libvirt domain (virt-install)
$arch = (& uname -m).Trim()
$osVariant = 'linux2022'
$osList = & virt-install --osinfo list 2>$null
if ($LASTEXITCODE -eq 0) {
    $canonicalIds = @($osList | ForEach-Object {
        $first = ("$_".Trim() -split '[\s,]', 2)[0]
        ($first -replace ',$', '').Trim()
    } | Where-Object { $_ })
    # Ubuntu 26.04 may not be in the host's osinfo-db yet; fall back through
    # ubuntu24.04 -> ubuntu22.04 -> linux2022 generic.
    foreach ($candidate in @('ubuntu26.04', 'ubuntu24.04', 'ubuntu22.04')) {
        if ($canonicalIds -contains $candidate) { $osVariant = $candidate; break }
    }
    if ($osVariant -eq 'linux2022') {
        Write-Verbose "osinfo-db has no 'ubuntu26.04'/'ubuntu24.04'/'ubuntu22.04' entry; using 'linux2022' generic variant."
    }
}

# --- REGION: https://yuruna.link/42fa6f45-0015
# See https://yuruna.link/42fa6f45-0016
$hostCores = [int](& nproc --all)
if ($hostCores -lt 4) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_243943232cde57ac' -Arguments @{ hostCores = "$hostCores" })
    exit 1
}
$vmCores = [math]::Max(4, [math]::Floor($hostCores / 2))

# --- REGION: https://yuruna.link/4220a755-000a
$YurunaGuestMac = Get-YurunaGuestMacAddress -VMName $VMName
Write-Verbose "Deterministic guest MAC for '$VMName': $YurunaGuestMac"

$installArgs = @(
    '--connect',    $virshUri,
    '--name',       $VMName,
    '--memory',     '2048',
    '--vcpus',      "$vmCores",
    '--cpu',        'host-passthrough',
    '--os-variant', $osVariant,
    '--disk',       "path=$diskImg,format=qcow2,bus=virtio",
    '--disk',       "path=$seedImg,device=cdrom",
    '--network',    "network=$networkName,model=virtio,mac=$YurunaGuestMac",
    '--graphics',   'vnc,listen=127.0.0.1',
    '--channel',    'unix,target_type=virtio,name=org.qemu.guest_agent.0',
    '--events',     'on_reboot=restart',
    '--noautoconsole',
    '--import'
)
if ($arch -eq 'aarch64') {
    $installArgs += @('--machine', 'virt', '--boot', 'uefi')
}

Write-Verbose "virt-install $($installArgs -join ' ')"
$virtInstallOutput = & virt-install @installArgs 2>&1
$virtInstallExit = $LASTEXITCODE
$virtInstallOutput | ForEach-Object { Write-Verbose "$_" }
if ($virtInstallExit -ne 0) {
    $virtInstallOutput | ForEach-Object { Write-Output "$_" }
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_d74692e9db12304f' -Arguments @{ virtInstallExit = "$virtInstallExit" })
    exit 1
}

# The agent is meant to be always available: a host that reboots with no runner
# active would otherwise leave the pool unserved until someone re-runs the
# start script. The service-VM roster re-ensure remains the guarantee; this is
# the cheap belt-and-braces libvirt already offers.
$autostartOut = & virsh --connect $virshUri autostart $VMName 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_d86a196b1addbb2e' -Arguments @{ vMName = "$VMName"; join = "$($autostartOut -join '; ')" })
}

# --- REGION: Clean up temporary files
Remove-Item -LiteralPath $seedDir -Recurse -Force -ErrorAction SilentlyContinue

# --- REGION: Wait for VM IP
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_2c8ff2df499f232c')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_b93b853caa0a1c89')

$dockIp = $null
$maxIterations = 120  # 120 * 5s = 10 minutes
$startTime = Get-Date
$baselineSizeMB = [math]::Round((Get-Item $diskImg).Length / 1MB, 0)
# Plain Write-Output progress -- see feedback_pwsh_linux_write_progress_setcursor.md
# for why we don't use Write-Progress on pwsh-on-Linux.

for ($i = 0; $i -lt $maxIterations; $i++) {
    $dockIp = Get-VMIp -VMName $VMName
    if ($dockIp) { break }
    Start-Sleep -Seconds 5

    if (($i % 6) -eq 5) {
        $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
        $sizeMB  = [math]::Round((Get-Item $diskImg).Length / 1MB, 0)
        $deltaMB = $sizeMB - $baselineSizeMB
        $min     = [int][math]::Floor($elapsed / 60)
        $sec     = [int]($elapsed % 60)
        $totalMinutes = [int][math]::Floor($maxIterations * 5 / 60)
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_ab6af692ee9143e8' -FormatValues ($min, $sec, $totalMinutes, $sizeMB, $deltaMB) -FormatBindings @{ min = '0:D2'; sec = '1:D2'; totalMinutes = '2'; sizeMB = '3'; deltaMB = '4' })
    }
}

if (-not $dockIp) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_2387f9a3bd0995a8' -Arguments @{ vMName = "$VMName"; virshUri = "$virshUri" })
    exit 1
}

Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_250f3d63ba951317')
Write-Output "  VM:       $VMName"
Write-Output "  IP:       $dockIp"
Write-Output "  Network:  $networkName"
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_0d2c724a13016680' -Arguments @{ dockIp = "$dockIp" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_a0be18b888b1e5b4' -Arguments @{ dockIp = "$dockIp" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_3e974f3b27099a83' -Arguments @{ virshUri = "$virshUri"; vMName = "$VMName" })
Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_57389bd87d496290')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_01b477e8e8a80cd5')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_7e7ca66d8925191f')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_6867e2b5e9483983' -Arguments @{ dockIp = "$dockIp" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_aa82b2cbd9678151')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_c2aed401248959b0')
exit 0
