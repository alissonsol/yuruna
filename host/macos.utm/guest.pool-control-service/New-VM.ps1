<#PSScriptInfo
.VERSION 2026.10.30
.GUID 42d0ee91-af77-4d3c-9e22-94d5edbc7661
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
    Builds the Yuruna pool-control service VM bundle for macOS UTM.

.DESCRIPTION
    Creates a UTM .utm bundle (QEMU backend with -vnc) that boots the
    arm64 Ubuntu 26.04 LTS cloud image. Cloud-init fetches the framework
    and runs the bring-up script which builds the pool-control-service daemon,
    installs pwsh + the pool-admin CLIs, CIFS-mounts the pool NAS for its
    state dir, and launches it under systemd.

    See https://yuruna.link/4207d71a-000c for the full specification.

.PARAMETER VMName
    Name of the UTM VM. Default: yuruna-pool-control-service.
.PARAMETER AllowPseudoLocale
    Enable developer pseudo locales for this VM. Disabled by default.
.PARAMETER PlanOnly
    Resolve and check every input the build needs, report seed values that
    would be baked empty, and exit 0 without changing anything.
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = "yuruna-pool-control-service",
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

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$GuestDir = "$HOME/yuruna/guest.nosync"
New-Item -ItemType Directory -Force -Path $GuestDir | Out-Null
$UtmDir = "$GuestDir/$VMName.utm"
$DataDir = "$UtmDir/Data"
# Per-service scratch dir (cloud-init seed staging). The base image itself is
# shared with the other extension services and lives elsewhere.
$downloadDir = "$HOME/yuruna/image/pool-control-service"

$utmPlist = "/Applications/UTM.app/Contents/Info.plist"
if (-not (Test-Path $utmPlist)) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_b17b4a09c8f6f0f6')
    exit 1
}

# --- REGION: Resolve the build plan
# Every input that can refuse the build is read before anything is torn down,
# so a missing key, password, template or network leaves the working VM
# untouched. -PlanOnly stops after this region, having changed nothing.
$_repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))

# --- REGION: Yuruna harness SSH key
# See https://yuruna.link/42e220c4-0004
# Seed the shared harness key so guest provisioning and failure diagnostics agree.
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Ssh.psm1')       -Force -DisableNameChecking
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Extension.psm1') -Global -Force -Verbose:$false
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_24e40b06bcf4c618'); exit 1 }

# --- REGION: Vault admin password
# Each service family has its own admin account: a shared name would map several
# VMs to one vault entry, and the last build would invalidate the others' credential.
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$AdminPassword = Get-Password -Username 'pool-control-service-admin'
if (-not $AdminPassword) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_4b6e32db84a17902'); exit 1 }
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_762658980a25b8fb' -Arguments @{ authActiveName = "$_authActiveName" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_c427eb2402415f42' -Arguments @{ authentication = "$(Resolve-ExtensionAreaDir -Area 'authentication')" })

# Check the shared seed templates before the guest network is resolved.
foreach ($f in @((Join-Path $_repoRoot 'host/vmconfig/pool-control-service.base.user-data'),
        (Join-Path $_repoRoot 'host/vmconfig/pool-control-service.utm.overlay.yml'),
        (Join-Path $_repoRoot 'host/vmconfig/pool-control-service.meta-data'))) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_9a1ef2a7551102d0' -Arguments @{ f = "$f" })
        exit 1
    }
}

# --- REGION: Select the guest network
# See https://yuruna.link/42e220c4-0004
# Resolve the network mode once so the seed and the bundle cannot disagree.
Import-Module (Join-Path (Split-Path -Parent $ScriptDir) 'modules/Yuruna.Host.psm1') -Force
Import-Module (Join-Path $_repoRoot 'test/modules/Test.PoolStorage.psm1')  -Global -Force
Import-Module (Join-Path $_repoRoot 'test/modules/Test.YurunaDir.psm1')    -Global -Force
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Config.psm1')       -Global -Force
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Locale.psm1')       -Global -Force
Import-Module (Join-Path $_repoRoot 'test/modules/Test.CachingProxyService.psm1') -Global -Force
$NetworkMode = Resolve-UtmNetworkMode

# --- REGION: Yuruna host coordinates
# See https://yuruna.link/4220a755-001b
# Bake the status-service address and storage coordinates for the selected network.
# YURUNA_GUEST_REACHABLE_HOST_IP overrides the host address.
if ($env:YURUNA_GUEST_REACHABLE_HOST_IP) {
    $YurunaHostIp = $env:YURUNA_GUEST_REACHABLE_HOST_IP
} else {
    $YurunaHostIp = Get-GuestReachableHostIp -NetworkMode $NetworkMode
}
if (-not $YurunaHostIp) { $YurunaHostIp = '' }
$_statusSeed = Get-YurunaStatusServiceSeed -RepoRoot $_repoRoot
$YurunaHostPort = $_statusSeed.Port
$tc = $_statusSeed.Config
$poolControlLanguage = Resolve-SeedLanguageTag -Config $tc
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
# One cloud image backs every extension service on this host; this VM grows
# its own copy below (host/modules/Yuruna.Image.psm1).
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules/Yuruna.Image.psm1') -Force
$baseImageFile = (Get-UbuntuExtensionImageInfo -HostType 'macos.utm').BaseImageFile
if (-not (Assert-YurunaBaseImage -BaseImageFile $baseImageFile -GuestFolder $PSScriptRoot)) { exit 1 }

Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_d9b89a1cbf294786' -Arguments @{ vMName = "$VMName"; baseImageFile = "$baseImageFile" })
# --- REGION: Base image provenance
# Emit the source URL from a healthy sidecar; warn when provenance is incomplete.
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

# --- REGION: https://yuruna.link/42e220c4-0004
# Wait before resolving the aggregator URL: an empty value remains baked into the guest seed.
$null = Wait-YurunaAggregatorReady
$aggregatorSeedUrl = Get-PoolAggregatorServiceSeedUrl
if (-not $aggregatorSeedUrl -and @(Get-PoolAggregatorServiceClaim).Count -gt 0) { Write-SeedDegradation -VMName $VMName -Name 'aggregatorUrl' }
# Writable pool-configuration git url the daemon commits to; empty degrades the daemon
# (read-only). An explicit test.config.yml pool.configurationGitUrl wins; otherwise this
# resolves the bare repo on the pool NAS, which the guest creates and seeds on
# first bring-up so a fresh VM reaches a working UI with nothing pre-staged.
$configurationGitUrl = Get-PoolConfigurationSeedUrl -Config $tc

# --- REGION: Render user-data / meta-data
# Render user-data from the shared base + UTM overlay (host/vmconfig/
# pool-control-service.*). New-CloudInitUserData resolves placeholders with literal
# .Replace(), so values carrying regex-special chars are safe.
Import-Module (Join-Path $_repoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Common.psm1') -Force -DisableNameChecking
# The NAS password is fetched by the guest over mutual TLS; the seed carries
# only this VM's client leaf for the host config service.
Import-Module (Join-Path $PSScriptRoot '../../../test/modules/Test.ConfigServiceCA.psm1') -Force
$configSeed = Get-YurunaConfigServiceSeedMaterial -VMName $VMName -HostId ([string]$poolNas.HostId) -Config $tc
$UserData = New-CloudInitUserData `
    -BasePath    (Join-Path $_repoRoot 'host/vmconfig/pool-control-service.base.user-data') `
    -OverlayPath (Join-Path $_repoRoot 'host/vmconfig/pool-control-service.utm.overlay.yml') `
    -RepoRoot    $_repoRoot `
    -Replacement @{
        SSH_AUTHORIZED_KEY_PLACEHOLDER = $SshAuthorizedKey
        PASSWORD_PLACEHOLDER           = $AdminPassword
        YURUNA_STATUS_SERVICE_IP_PLACEHOLDER     = $YurunaHostIp
        YURUNA_STATUS_SERVICE_PORT_PLACEHOLDER   = $YurunaHostPort
        YURUNA_HOST_ID_PLACEHOLDER     = $poolNas.HostId
        YURUNA_AGGREGATOR_URL_PLACEHOLDER      = $aggregatorSeedUrl
        YURUNA_POOL_CONFIGURATION_GIT_URL_PLACEHOLDER = $configurationGitUrl
        YURUNA_LANGUAGE_PLACEHOLDER       = $poolControlLanguage
        YURUNA_ALLOW_PSEUDO_LOCALE_PLACEHOLDER = $allowPseudoLocaleValue
        POOL_NAS_NETWORK_PATH_PLACEHOLDER  = $poolNas.NetworkPath
        POOL_NAS_NETWORK_IP_PLACEHOLDER    = $poolNas.NetworkIp
        POOL_NAS_NETWORK_USER_PLACEHOLDER  = $poolNas.NetworkUser
        YURUNA_CONFIG_SERVICE_PORT_PLACEHOLDER               = $configSeed.Port
        YURUNA_CONFIG_SERVICE_CA_CERT_BASE64_PLACEHOLDER     = $configSeed.CaCertBase64
        YURUNA_CONFIG_SERVICE_CLIENT_CERT_BASE64_PLACEHOLDER = $configSeed.ClientCertBase64
        YURUNA_CONFIG_SERVICE_CLIENT_KEY_BASE64_PLACEHOLDER  = $configSeed.ClientKeyBase64
        POOL_NAS_HOST_ID_PLACEHOLDER       = $poolNas.HostId
    } -Confirm:$false

# --- REGION: Remove existing VM
# See https://yuruna.link/42e220c4-0004
# Runs after the plan, the base image and the rendered seed are confirmed,
# so a refused input or a failed fetch never destroys a working VM.
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/Yuruna.Host.psm1') -Force
if (-not (Remove-UtmTestVM -VMName $VMName -Confirm:$false)) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_7565389d0d010c89' -Arguments @{ utmDir = "$UtmDir" })
    exit 1
}

# --- REGION: Create copies and files for VM
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# --- REGION: Copy base image -> per-VM disk
# See https://yuruna.link/429f3d06-0092
# Copy the pre-built qcow2 cloud image into the bundle as the boot disk; qcow2,
# not raw, avoids the macOS F_PUNCHHOLE alignment failure a raw disk hits.
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

# --- REGION: Grow the per-VM disk to 256 GB
# Apparent size only: qcow2 grows on write, so the host gives up nothing
# until the pool-control daemon actually stores that much.
if (-not (Expand-ExtensionVmDisk -Path $DiskImage -SizeBytes 256GB -Format 'qcow2')) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_5a636fde131a5a2f' -Arguments @{ diskImage = "$DiskImage" })
    exit 1
}

# --- REGION: Stage the cloud-init seed directory
# The seed carries the admin password. It is staged in a private (0700)
# workspace inside the bundle and published as an owner-only image, and the
# finally below removes the workspace on every exit, a failed build included.
Import-Module (Join-Path $PSScriptRoot '../../modules/Yuruna.SeedMedia.psm1') -Force
# A plaintext source an older builder left in the image directory goes first.
Remove-Item -LiteralPath (Join-Path $downloadDir "seed_temp/$VMName") -Recurse -Force -ErrorAction SilentlyContinue
$seedWorkspace = $null
try {
    $seedWorkspace = New-SeedMediaWorkspace -ParentPath $DataDir
    $SeedDir = $seedWorkspace.Source

    # meta-data is shared under host/vmconfig/ (byte-identical across all 3 host platforms).
    $hostVmConfigDir = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))) 'host/vmconfig'
    Copy-Item -Path (Join-Path $hostVmConfigDir 'pool-control-service.meta-data') -Destination "$SeedDir/meta-data"

    Set-Content -Path "$SeedDir/user-data" -Value $UserData -NoNewline
    # --- REGION: https://yuruna.link/4220a755-000b
    Copy-Item -Path (Join-Path $hostVmConfigDir 'guest-dhcp.network-config') -Destination "$SeedDir/network-config"

    # --- REGION: Generate cloud-init seed ISO
    $SeedIso = "$DataDir/seed.iso"
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_5f1478be62ab5e8d')
    & hdiutil makehybrid -o "$($seedWorkspace.Image)" -joliet -iso -default-volume-name cidata "$SeedDir" 2>&1 | ForEach-Object { Write-Verbose $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_fea701fd46026b88')
        exit 1
    }
    Publish-SeedMediaImage -Workspace $seedWorkspace -Path $SeedIso -Confirm:$false

    # --- REGION: Create and configure the UTM bundle
    # config.plist selects the QEMU backend.
    Import-Module (Join-Path $PSScriptRoot '../modules/Yuruna.Host.psm1') -DisableNameChecking -Verbose:$false
    New-UtmServiceBundleConfiguration -TemplatePath (Join-Path $ScriptDir 'config.plist.template') -BundlePath $UtmDir -VMName $VMName -NetworkMode $NetworkMode -MemoryMb 2048 -Confirm:$false
    $VncDisplay = Get-VncDisplayForVm -VMName $VMName

} finally {
    # --- REGION: Clean up temporary files
    Remove-SeedMediaWorkspace -Workspace $seedWorkspace -Confirm:$false
}

# --- REGION: Guidance
# See https://yuruna.link/42e220c4-0004
# UTM bundles are registered and started by the operator, so this phase prints
# the next steps instead of waiting for an IP.
# Keep the here-string literal: expandable strings would execute the shell examples.
Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_15cdc9f7300def05')
Write-Output "  Path:      $UtmDir"
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_0a95ec9679adce8d' -Arguments @{ vncDisplay = "$VncDisplay"; vncDisplay2 = "$(5900 + $VncDisplay)" })
Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_a19074ac4867746e')
Write-Output "    user:     pool-control-service-admin"
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_35b3305bf5c00a8a')
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
       ssh pool-control-service-admin@$ip 'sudo tail -f /var/log/cloud-init-output.log'

  5. Once cloud-init finishes, the pool-control-service UI serves on :80:
       open http://$ip/

See https://yuruna.link/4207d71a-000c.
'@
Write-Output ($guidance.
    Replace('__VM_NAME__', $VMName).
    Replace('__UTM_DIR__', $UtmDir))

# --- REGION: Restore operator file ownership
# See https://yuruna.link/42e220c4-0004
# If invoked through sudo, return generated artifacts to the original operator.
[void](Restore-SudoUserOwnership -Path @("$HOME/yuruna", (Join-Path $_repoRoot 'test/status')) -Confirm:$false)
