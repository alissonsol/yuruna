<#PSScriptInfo
.VERSION 2026.09.18
.GUID 4219b9e1-52b6-463b-b9d7-5d2aecaadd27
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
    Builds the Yuruna download-agent service VM bundle for macOS UTM.

.DESCRIPTION
    Creates a UTM .utm bundle (QEMU backend with -vnc) that boots the
    arm64 Ubuntu 26.04 LTS cloud image. Cloud-init fetches the framework
    and runs the bring-up script which builds the download-agent-service
    daemon, CIFS-mounts the pool NAS that holds the download pool, and
    launches it under systemd.

    See https://yuruna.link/4268e4cb for the full specification.

.PARAMETER VMName
    Name of the UTM VM. Default: yuruna-download-agent-service.
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = "yuruna-download-agent-service",
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
$GuestDir = "$HOME/yuruna/guest.nosync"
New-Item -ItemType Directory -Force -Path $GuestDir | Out-Null
$UtmDir = "$GuestDir/$VMName.utm"
$DataDir = "$UtmDir/Data"
# Per-service scratch dir (cloud-init seed staging). The base image itself is
# shared with the other extension services and lives elsewhere.
$downloadDir = "$HOME/yuruna/image/download-agent-service"

$utmPlist = "/Applications/UTM.app/Contents/Info.plist"
if (-not (Test-Path $utmPlist)) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_b17b4a09c8f6f0f6')
    exit 1
}

# --- REGION: Seek the base image
# One cloud image backs every extension service on this host; this VM grows
# its own copy below (host/modules/Yuruna.Image.psm1).
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules/Yuruna.Image.psm1') -Force
$baseImageFile = (Get-UbuntuExtensionImageInfo -HostType 'macos.utm').BaseImageFile
if (-not (Assert-YurunaBaseImage -BaseImageFile $baseImageFile -GuestFolder $PSScriptRoot)) { exit 1 }

Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_d9b89a1cbf294786' -Arguments @{ vMName = "$VMName"; baseImageFile = "$baseImageFile" })
$_repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

# --- REGION: Remove existing VM
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/Yuruna.Host.psm1') -Force
if (-not (Remove-UtmBundleWithRetry -Path $UtmDir)) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_7565389d0d010c89' -Arguments @{ utmDir = "$UtmDir" })
    exit 1
}

# --- REGION: Create copies and files for VM
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# --- REGION: Copy base image -> per-VM disk
# Copy the pre-built qcow2 cloud image into the bundle as the boot disk.
# qcow2 (not raw) is deliberate: UTM's QEMU backend boots it directly and
# it sidesteps the macOS F_PUNCHHOLE-alignment EINVAL a raw disk hits
# under UTM's discard=unmap,detect-zeroes=unmap -- see
# feedback_macos-qemu-punchhole-alignment.md.
$DiskImage = "$DataDir/disk.qcow2"
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_6288433a06ff55be')
& /bin/cp -c $baseImageFile $DiskImage
if ($LASTEXITCODE -ne 0) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_6a80b3350f680db8')
    Copy-Item -Path $baseImageFile -Destination $DiskImage
}

# --- REGION: Grow the per-VM disk to 256 GB
# Apparent size only: qcow2 grows on write, so the host gives up nothing
# until the download-agent daemon actually stores that much. The pool itself
# lives on the NAS, not here.
if (-not (Expand-ExtensionVmDisk -Path $DiskImage -SizeBytes 256GB -Format 'qcow2')) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_5a636fde131a5a2f' -Arguments @{ diskImage = "$DiskImage" })
    exit 1
}

# --- REGION: Stage the cloud-init seed directory
$SeedDir = Join-Path $downloadDir "seed_temp/$VMName"
if (Test-Path -LiteralPath $SeedDir) { Remove-Item -LiteralPath $SeedDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null

# meta-data is shared under host/vmconfig/ (byte-identical across all 3 host platforms).
$hostVmConfigDir = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))) 'host/vmconfig'
Copy-Item -Path (Join-Path $hostVmConfigDir 'download-agent-service.meta-data') -Destination "$SeedDir/meta-data"
# --- REGION: https://yuruna.link/4220a755-000b
Copy-Item -Path (Join-Path $hostVmConfigDir 'guest-dhcp.network-config') -Destination "$SeedDir/network-config"

# --- REGION: Yuruna harness SSH key
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Ssh.psm1')       -Force -DisableNameChecking
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Extension.psm1') -Global -Force -Verbose:$false
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_24e40b06bcf4c618'); exit 1 }

# --- REGION: Vault admin password
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$AdminPassword = Get-Password -Username 'download-agent-service-admin'
if (-not $AdminPassword) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_ce7652d3e480135e'); exit 1 }
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_762658980a25b8fb' -Arguments @{ authActiveName = "$_authActiveName" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_c427eb2402415f42' -Arguments @{ authentication = "$(Resolve-ExtensionAreaDir -Area 'authentication')" })

# --- REGION: Select the guest network
# See https://yuruna.link/4220a755-001b
# Resolve the network and reachable host address together for both seed and bundle.
# YURUNA_GUEST_REACHABLE_HOST_IP overrides the host address.
Import-Module (Join-Path (Split-Path -Parent $ScriptDir) 'modules/Yuruna.Host.psm1') -Force
Import-Module (Join-Path $_repoRoot 'test/modules/Test.PoolStorage.psm1')  -Global -Force
Import-Module (Join-Path $_repoRoot 'test/modules/Test.YurunaDir.psm1')    -Global -Force
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Config.psm1')       -Global -Force
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Locale.psm1') -Global -Force
Import-Module (Join-Path $_repoRoot 'test/modules/Test.CachingProxyService.psm1') -Global -Force
Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Common.psm1') -Force -DisableNameChecking
$NetworkMode = Resolve-UtmNetworkMode
if ($env:YURUNA_GUEST_REACHABLE_HOST_IP) {
    $YurunaHostIp = $env:YURUNA_GUEST_REACHABLE_HOST_IP
} else {
    $YurunaHostIp = Get-GuestReachableHostIp -NetworkMode $NetworkMode
}
if (-not $YurunaHostIp) { $YurunaHostIp = '' }
$_statusSeed = Get-YurunaStatusServiceSeed -RepoRoot $_repoRoot
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
# with an address THIS HOST can dial, and on macOS that can be 127.0.0.1 -- the
# local forwarder into the cache VM, which no guest can reach -- so a loopback
# answer is not a usable seed value.
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

# Render user-data from the shared base + UTM overlay (host/vmconfig/
# download-agent-service.*). New-CloudInitUserData resolves placeholders with literal
# .Replace(), so values carrying regex-special chars are safe.
Import-Module (Join-Path $_repoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force
$UserData = New-CloudInitUserData `
    -BasePath    (Join-Path $_repoRoot 'host/vmconfig/download-agent-service.base.user-data') `
    -OverlayPath (Join-Path $_repoRoot 'host/vmconfig/download-agent-service.utm.overlay.yml') `
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
        POOL_NAS_PASSWORD_PLACEHOLDER      = $poolNas.Password
        DOWNLOAD_AGENT_SCAN_INTERVAL_PLACEHOLDER = $agentScanInterval
        DOWNLOAD_AGENT_FRESHNESS_PLACEHOLDER     = $agentFreshness
        DOWNLOAD_AGENT_PREFETCH_LEAD_PLACEHOLDER = $agentPrefetchLead
        DOWNLOAD_AGENT_AUTO_SEED_PLACEHOLDER     = $agentAutoSeed
        YURUNA_CACHE_PROXY_IP_PLACEHOLDER        = $cacheProxyIp
    } -Confirm:$false
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
# --- REGION: https://yuruna.link/4220a755-000a
$MacAddress = Get-YurunaGuestMacAddress -VMName $VMName

Import-Module (Join-Path (Split-Path -Parent $ScriptDir) "modules/Yuruna.Host.psm1") -Force
$VncDisplay = Get-VncDisplayForVm -VMName $VMName

# Bridge interface: resolve from default-route NIC.
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
if ($NetworkMode -eq 'Shared') {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_69e62e2795b0c3d2' -Arguments @{ bridgeInterface = "$BridgeInterface" })
} else {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_00e0e35404f36e5b' -Arguments @{ bridgeInterface = "$BridgeInterface" })
}

# --- REGION: https://yuruna.link/42fa6f45-0015
# See https://yuruna.link/42fa6f45-0016
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
    -replace '__MEMORY_SIZE__',        '2048'

# Bridged mode needs the physical NIC name; Shared NAT carries no
# BridgedInterface key (matches the sibling Shared templates), so drop the
# key/value entirely in that mode.
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
Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_e12d6ba22d26fe5a')
Write-Output "  Path:      $UtmDir"
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_0a95ec9679adce8d' -Arguments @{ vncDisplay = "$VncDisplay"; vncDisplay2 = "$(5900 + $VncDisplay)" })
Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_a19074ac4867746e')
Write-Output "    user:     download-agent-service-admin"
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_0650f798a0996483')
$guidance = @'

Next steps:

  1. Register with UTM:
       open '__UTM_DIR__'    # double-click equivalent

  2. Start the VM and wait 1-3 minutes for cloud-init:
       utmctl start __VM_NAME__

  3. Find the VM's IP. `utmctl ip-address` needs the qemu-guest-agent
     inside the guest (not installed by this seed) -- use one of these
     instead:
     a) Look in the UTM window console; eth0 prints its IP at the
        login prompt after DHCP.
     b) Your LAN router's DHCP leases (the VM is bridged, so macOS's
        /var/db/dhcpd_leases does not contain it).

  4. Watch the bring-up (cloud-init fetches the framework and builds +
     launches the daemon; the harness key stays authorized on :22):
       ssh download-agent-service-admin@$ip 'sudo tail -f /var/log/cloud-init-output.log'

  5. Once cloud-init finishes, the download-agent-service UI serves on :80:
       open http://$ip/

See https://yuruna.link/4268e4cb.
'@
Write-Output ($guidance.
    Replace('__VM_NAME__', $VMName).
    Replace('__UTM_DIR__', $UtmDir))

# --- REGION: Restore operator file ownership
# See https://yuruna.link/42e220c4-0004
# If invoked through sudo, return generated artifacts to the original operator.
[void](Restore-SudoUserOwnership -Path @("$HOME/yuruna", (Join-Path $_repoRoot 'test/status')) -Confirm:$false)
