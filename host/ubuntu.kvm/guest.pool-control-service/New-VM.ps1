<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42cb87f4-7e53-4a64-bea3-4c874894dd2d
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
    Creates the Yuruna pool-control service VM on Ubuntu KVM (libvirt).

.DESCRIPTION
    Builds a libvirt VM that boots the Ubuntu 26.04 LTS cloud image
    for the pool-control-service daemon (operator UI + API for the pool intent).
    Cloud-init fetches the framework and runs the bring-up script which
    builds the daemon, installs pwsh + the pool-admin CLIs, CIFS-mounts the
    pool NAS for its state dir, and launches it under systemd.

    See https://yuruna.link/4207d71a-000c for the full specification.

.PARAMETER VMName
    libvirt domain name. Default: yuruna-pool-control-service.
.PARAMETER AllowPseudoLocale
    Open pseudo-locale negotiation for an explicit reference run. Off by default.
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = 'yuruna-pool-control-service',
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
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_e830a3679f57bed6')
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
# until the pool-control daemon actually stores that much.
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
$AdminPassword = Get-Password -Username 'pool-control-service-admin'
if (-not $AdminPassword) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_4b6e32db84a17902'); exit 1 }
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_762658980a25b8fb' -Arguments @{ authActiveName = "$_authActiveName" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_c427eb2402415f42' -Arguments @{ authentication = "$(Resolve-ExtensionAreaDir -Area 'authentication')" })

# --- REGION: Render user-data / meta-data
$baseUserData     = Join-Path $repoRoot 'host/vmconfig/pool-control-service.base.user-data'
$overlayUserData  = Join-Path $repoRoot 'host/vmconfig/pool-control-service.kvm.overlay.yml'
$metaDataTemplate = Join-Path $repoRoot 'host/vmconfig/pool-control-service.meta-data'
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
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_123fb1ab620bc2d4')
} else {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_c08a2cd955043a9e' -Arguments @{ networkName = "$networkName" })

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
            Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_c6ed9927d5052f27' -Arguments @{ networkName = "$networkName"; extBridge = "$extBridge" })
            exit 1
        }
    }
}

# --- REGION: https://yuruna.link/4220a755-001b
# Host coordinates (status service, for the in-VM source fetch) + pool storage
# coordinates (the NAS), baked into the seed. Honor an explicit override.
Import-Module (Join-Path $repoRoot 'test/modules/Test.PoolStorage.psm1')  -Global -Force
Import-Module (Join-Path $repoRoot 'test/modules/Test.YurunaDir.psm1')    -Global -Force
Import-Module (Join-Path $repoRoot 'test/modules/Test.Config.psm1')       -Global -Force
Import-Module (Join-Path $repoRoot 'test/modules/Test.Locale.psm1')       -Global -Force
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
$poolControlLanguage = if ([string]::IsNullOrWhiteSpace($languageRaw) -or $languageRaw -ieq 'auto') {
    'auto'
} else {
    ConvertTo-CanonicalLocaleTag -Tag $languageRaw
}
if (-not $poolControlLanguage) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_8fa181c2fe215cd1' -Arguments @{ languageRaw = "$languageRaw" }) }
$allowPseudoLocaleValue = if ($AllowPseudoLocale) { 'true' } else { 'false' }
$poolNas = Get-YurunaPoolSeedValue -Config $tc -GuestReachableAddress $YurunaHostIp
# --- REGION: https://yuruna.link/42e220c4-0004
# Wait before resolving the aggregator URL: an empty value remains baked into the guest seed.
$null = Wait-YurunaAggregatorReady
$aggregatorSeedUrl = Get-PoolAggregatorServiceSeedUrl
# Writable pool-intent git url the daemon commits to; empty degrades the daemon
# (read-only). An explicit test.config.yml pool.intentGitUrl wins; otherwise this
# resolves the bare repo on the pool NAS, which the guest creates and seeds on
# first bring-up so a fresh VM reaches a working UI with nothing pre-staged.
$intentGitUrl = Get-PoolIntentSeedUrl -Config $tc

# Render user-data from the shared base + KVM overlay (host/vmconfig/
# pool-control-service.*). New-CloudInitUserData resolves placeholders with literal
# .Replace(), so values carrying regex-special chars are safe.
Import-Module (Join-Path $repoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force
$userData = New-CloudInitUserData `
    -BasePath    $baseUserData `
    -OverlayPath $overlayUserData `
    -RepoRoot    $repoRoot `
    -Replacement @{
        SSH_AUTHORIZED_KEY_PLACEHOLDER = $SshAuthorizedKey
        PASSWORD_PLACEHOLDER           = $AdminPassword
        YURUNA_STATUS_SERVICE_IP_PLACEHOLDER     = $YurunaHostIp
        YURUNA_STATUS_SERVICE_PORT_PLACEHOLDER   = $YurunaHostPort
        YURUNA_HOST_ID_PLACEHOLDER     = $poolNas.HostId
        YURUNA_AGGREGATOR_URL_PLACEHOLDER      = $aggregatorSeedUrl
        YURUNA_POOL_INTENT_GIT_URL_PLACEHOLDER = $intentGitUrl
        YURUNA_LANGUAGE_PLACEHOLDER       = $poolControlLanguage
        YURUNA_ALLOW_PSEUDO_LOCALE_PLACEHOLDER = $allowPseudoLocaleValue
        POOL_NAS_NETWORK_PATH_PLACEHOLDER  = $poolNas.NetworkPath
        POOL_NAS_NETWORK_IP_PLACEHOLDER    = $poolNas.NetworkIp
        POOL_NAS_NETWORK_USER_PLACEHOLDER  = $poolNas.NetworkUser
        POOL_NAS_PASSWORD_PLACEHOLDER      = $poolNas.Password
        POOL_NAS_HOST_ID_PLACEHOLDER       = $poolNas.HostId
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
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_fa53e475b2cdd39b')
Write-Output "  user:     pool-control-service-admin"
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_d8dbc60970be040a')
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
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_95e05e441841ef8e' -Arguments @{ vMName = "$VMName"; virshUri = "$virshUri" })
    exit 1
}

Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_4b8f66555bd13ab8')
Write-Output "  VM:       $VMName"
Write-Output "  IP:       $dockIp"
Write-Output "  Network:  $networkName"
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_bb96ec06f5e4f923' -Arguments @{ dockIp = "$dockIp" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_005bab80fe0f8f32' -Arguments @{ dockIp = "$dockIp" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_3e974f3b27099a83' -Arguments @{ virshUri = "$virshUri"; vMName = "$VMName" })
Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_57389bd87d496290')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_1bba161bfe1aef2a')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_be62924d72343522')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_6830e43fa44f64ae' -Arguments @{ dockIp = "$dockIp" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_e7f311f3856f8c90')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_3d9418096712c514')
exit 0
