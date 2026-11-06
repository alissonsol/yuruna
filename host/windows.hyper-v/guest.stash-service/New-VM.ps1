<#PSScriptInfo
.VERSION 2026.11.05
.GUID 4231f6cf-af57-4818-b0ee-59ddbe571ffa
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
    Creates (or recreates) the Yuruna stash service VM on Hyper-V.

.DESCRIPTION
    Builds an Ubuntu 26.04 LTS cloud-image VM that hosts the stash-service
    daemon (SCP receiver + SQLite metadata index). Cloud-init mounts the
    stash share, fetches the framework, and runs the bring-up script which
    builds + launches the daemon under systemd.

    See https://yuruna.link/42f5e921 for the stash user guide.

.PARAMETER VMName
    Name of the Hyper-V VM. Default: yuruna-stash-service.
.PARAMETER AllowPseudoLocale
    Enable developer pseudo locales for this VM. Disabled by default.
.PARAMETER PlanOnly
    Resolve and check every input the build needs, report seed values that
    would be baked empty, and exit 0 without changing anything.
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = "yuruna-stash-service",
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
$AdminPassword = Get-Password -Username 'stash-admin'
if (-not $AdminPassword) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_5f54f73b7b1051eb'); exit 1 }
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_762658980a25b8fb' -Arguments @{ authActiveName = "$_authActiveName" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_c427eb2402415f42' -Arguments @{ authentication = "$(Resolve-ExtensionAreaDir -Area 'authentication')" })

# Check the shared seed templates before the guest network is resolved.
foreach ($f in @((Join-Path $_repoRoot 'host/vmconfig/stash-service.base.user-data'),
        (Join-Path $_repoRoot 'host/vmconfig/stash-service.hyperv.overlay.yml'),
        (Join-Path $_repoRoot 'host/vmconfig/stash-service.meta-data'))) {
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
$ystashNas = Get-YurunaStashSeedValue -Config $tc -GuestReachableAddress $YurunaHostIp
# The names the VM answers to besides its addresses, from this host's
# test.config.yml. Read in the plan, while the working VM is still advertised,
# because a malformed vmStart.serviceHostNames entry refuses the build.
Import-Module (Join-Path $_repoRoot 'test/modules/Test.ExtensionService.psm1') -DisableNameChecking -Verbose:$false
try { $serviceHostNames = Get-ExtensionServiceHostNameSeed -Config $tc }
catch { Write-Error $_.Exception.Message; exit 1 }

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
$downloadDir = (Invoke-HyperVGuestBuildCmdlet -VMName $VMName -Command 'Hyper-V\Get-VMHost').VirtualHardDiskPath
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

# --- REGION: Render user-data / meta-data
# Render user-data from the shared base + Hyper-V overlay (host/vmconfig/
# stash-service.*). New-CloudInitUserData resolves placeholders with literal
# .Replace(), so values carrying regex-special chars are safe.
Import-Module (Join-Path $_repoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force
# The NAS password is fetched by the guest over mutual TLS; the seed carries
# only this VM's client leaf for the host config service.
Import-Module (Join-Path $PSScriptRoot '../../../test/modules/Test.ConfigServiceCA.psm1') -Force
$configSeed = Get-YurunaConfigServiceSeedMaterial -VMName $VMName -HostId ([string]$ystashNas.HostId) -Config $tc
$UserData = New-CloudInitUserData `
    -BasePath    (Join-Path $_repoRoot 'host/vmconfig/stash-service.base.user-data') `
    -OverlayPath (Join-Path $_repoRoot 'host/vmconfig/stash-service.hyperv.overlay.yml') `
    -RepoRoot    $_repoRoot `
    -Replacement @{
        YURUNA_LANGUAGE_PLACEHOLDER = $serviceLanguage
        YURUNA_ALLOW_PSEUDO_LOCALE_PLACEHOLDER = $allowPseudoLocaleValue
        SSH_AUTHORIZED_KEY_PLACEHOLDER = $SshAuthorizedKey
        PASSWORD_PLACEHOLDER           = $AdminPassword
        YURUNA_STATUS_SERVICE_IP_PLACEHOLDER     = $YurunaHostIp
        YURUNA_STATUS_SERVICE_PORT_PLACEHOLDER   = $YurunaHostPort
        YSTASH_NAS_NETWORK_PATH_PLACEHOLDER  = $ystashNas.NetworkPath
        YSTASH_NAS_NETWORK_IP_PLACEHOLDER    = $ystashNas.NetworkIp
        YSTASH_NAS_NETWORK_USER_PLACEHOLDER  = $ystashNas.NetworkUser
        YURUNA_CONFIG_SERVICE_PORT_PLACEHOLDER               = $configSeed.Port
        YURUNA_CONFIG_SERVICE_CA_CERT_BASE64_PLACEHOLDER     = $configSeed.CaCertBase64
        YURUNA_CONFIG_SERVICE_CLIENT_CERT_BASE64_PLACEHOLDER = $configSeed.ClientCertBase64
        YURUNA_CONFIG_SERVICE_CLIENT_KEY_BASE64_PLACEHOLDER  = $configSeed.ClientKeyBase64
        YSTASH_NAS_HOST_ID_PLACEHOLDER       = $ystashNas.HostId
        YURUNA_AGGREGATOR_URL_PLACEHOLDER    = $aggregatorSeedUrl
        YURUNA_SERVICE_HOST_NAMES_PLACEHOLDER = $serviceHostNames
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
# stash daemon writes.
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
    Copy-Item -Path (Join-Path $hostVmConfigDir 'stash-service.meta-data') -Destination "$SeedDir/meta-data"

    Set-Content -Path "$SeedDir/user-data" -Value $UserData -NoNewline
    # --- REGION: https://yuruna.link/4220a755-000b
    Copy-Item -Path (Join-Path $hostVmConfigDir 'guest-dhcp.network-config') -Destination "$SeedDir/network-config"

    # --- REGION: Generate cloud-init seed ISO
    $SeedIso = Join-Path $vmDir "seed.iso"
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_5f1478be62ab5e8d')
    CreateIso -SourceDir $SeedDir -OutputFile $seedWorkspace.Image -VolumeId "cidata"
    Publish-SeedMediaImage -Workspace $seedWorkspace -Path $SeedIso -Confirm:$false

    Write-Output ""
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_75cf4528e83fec3c')
    Write-Output "  user:     stash-admin"
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_d16883e5df36f6c1')
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_491b6a0a529b230a' -Arguments @{ vMName = "$VMName" })
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_095582e0ec3b9dc8')
    Write-Output ""

    # --- REGION: Create and configure the Hyper-V VM
    New-HyperVServiceGuest -VMName $VMName -SwitchName $switchName -DiskPath $vhdxFile -SeedPath $SeedIso -HostCores $hostCores -MemoryMb 2048 -Confirm:$false
    $createdVm = Invoke-HyperVGuestBuildCmdlet -VMName $VMName -Command 'Hyper-V\Get-VM' -Parameter @{ Name = $VMName }
    Grant-SeedMediaVmRead -Path $SeedIso -VMId $createdVm.Id -Confirm:$false

} finally {
    # --- REGION: Clean up temporary files
    Remove-SeedMediaWorkspace -Workspace $seedWorkspace -Confirm:$false
}

# --- REGION: Start the VM
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_44a010f47f51d941' -Arguments @{ vMName = "$VMName" })
$null = Invoke-HyperVGuestBuildCmdlet -VMName $VMName -Command 'Hyper-V\Start-VM' -Parameter @{ Name = $VMName }

# --- REGION: Wait for VM IP
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_2c8ff2df499f232c')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_b93b853caa0a1c89')

# Wait-HyperVServiceGuestAddress polls KVP and bridge neighbors, the same
# discovery the caching-proxy-service builder uses.
$ProgressPreference = 'Continue'
$dockCandidateIps = @(Wait-HyperVServiceGuestAddress -VMName $VMName -SwitchName $switchName -TimeoutSeconds 600)

if (-not $dockCandidateIps) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_279f98db3ee9e89d' -Arguments @{ vMName = "$VMName" })
    exit 1
}

# Single-candidate pick: the stash service has no listening port to validate against
# in v1, so the first non-loopback candidate IP is authoritative. When
# ARP returned multiple candidates, the operator can verify reachability
# with `ssh stash-admin@<ip>` -- the harness key is already authorized.
$dockIp = $dockCandidateIps | Select-Object -First 1

Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_67084b575b89cc58')
Write-Output "  VM:       $VMName"
Write-Output "  IP:       $dockIp"
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_dde8dea17f4f28d3' -Arguments @{ dockIp = "$dockIp" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_5b4ac1913896620c' -Arguments @{ vMName = "$VMName" })
Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_352ce8880d1aa08c')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_4f80523f8f0b08bf')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_2c0350b2a7b87558' -Arguments @{ dockIp = "$dockIp" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_2da2f3a61688f8c3' -Arguments @{ dockIp = "$dockIp" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_5b964572fb8a9e22')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_5482df881e0cb0fe')
Write-Output "https://yuruna.link/42f5e921."
exit 0
