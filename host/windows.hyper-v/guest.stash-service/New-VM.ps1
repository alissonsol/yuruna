<#PSScriptInfo
.VERSION 2026.09.24
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
.PARAMETER AllowPseudoLocale
    Enable developer pseudo locales for this VM. Disabled by default.
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
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = "yuruna-stash-service",
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

# --- REGION: Grow the per-VM disk to 256 GB
# Dynamic VHDX, so 256 GB is the nominal size only: the file grows as the
# stash daemon writes.
if (-not (Expand-ExtensionVmDisk -Path $vhdxFile -SizeBytes 256GB -Format 'vhdx')) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_dd7b45e336b3fcd0' -Arguments @{ vhdxFile = "$vhdxFile" })
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

Copy-Item -Path (Join-Path $hostVmConfigDir 'stash-service.meta-data') -Destination "$SeedDir/meta-data"
# --- REGION: https://yuruna.link/4220a755-000b
Copy-Item -Path (Join-Path $hostVmConfigDir 'guest-dhcp.network-config') -Destination "$SeedDir/network-config"

# --- REGION: Yuruna harness SSH key
$_repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Ssh.psm1')       -Force -DisableNameChecking
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Extension.psm1') -Global -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Common.psm1') -Force -DisableNameChecking
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_24e40b06bcf4c618'); exit 1 }

# --- REGION: Vault admin password
# The password belongs to THIS VM's own administrator. The account name is
# per-VM-family: a name shared with the caching-proxy-service and
# pool-control-service VMs would resolve to a single vault entry, and whichever
# VM was built last would invalidate the others' credential.
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$AdminPassword = Get-Password -Username 'stash-admin'
if (-not $AdminPassword) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_5f54f73b7b1051eb'); exit 1 }
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_762658980a25b8fb' -Arguments @{ authActiveName = "$_authActiveName" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_c427eb2402415f42' -Arguments @{ authentication = "$(Resolve-ExtensionAreaDir -Area 'authentication')" })

# --- REGION: Select the guest network
# The share + source coordinates baked into cloud-init depend on the chosen
# network, so resolve it first. Prefer Yuruna-External so the VM gets a LAN
# IP and can reach the NAS + the host status service; fall back to Default
# Switch only when External is unavailable (Wi-Fi-only host), where the VM
# is reachable only from same-host peers and the NAS likely isn't routable.
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
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_aeb932dd3434973c')
}

# --- REGION: https://yuruna.link/4220a755-001b
# Host coordinates (status service, for the in-VM source fetch) + stash storage
# coordinates (the share the daemon writes to), baked into the seed.
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
$languageRaw = [string](Get-TestConfigValue -Config $tc -Path 'language')
$serviceLanguage = if ([string]::IsNullOrWhiteSpace($languageRaw) -or $languageRaw -ieq 'auto') {
    'auto'
} else {
    ConvertTo-CanonicalLocaleTag -Tag $languageRaw
}
if (-not $serviceLanguage) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_8fa181c2fe215cd1' -Arguments @{ languageRaw = "$languageRaw" }) }
$allowPseudoLocaleValue = if ($AllowPseudoLocale) { 'true' } else { 'false' }
$ystashNas = Get-YurunaStashSeedValue -Config $tc -GuestReachableAddress $YurunaHostIp
# --- REGION: https://yuruna.link/42e220c4-0004
# Wait before resolving the aggregator URL: an empty value remains baked into the guest seed.
$null = Wait-YurunaAggregatorReady
$aggregatorSeedUrl = Get-PoolAggregatorServiceSeedUrl

# Render user-data from the shared base + Hyper-V overlay (host/vmconfig/
# stash-service.*). New-CloudInitUserData resolves placeholders with literal
# .Replace(), so values carrying regex-special chars are safe.
Import-Module (Join-Path $_repoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force
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
        YSTASH_NAS_PASSWORD_PLACEHOLDER      = $ystashNas.Password
        YSTASH_NAS_HOST_ID_PLACEHOLDER       = $ystashNas.HostId
        YURUNA_AGGREGATOR_URL_PLACEHOLDER    = $aggregatorSeedUrl
    } -Confirm:$false
Set-Content -Path "$SeedDir/user-data" -Value $UserData -NoNewline

# --- REGION: Generate cloud-init seed ISO
$SeedIso = Join-Path $vmDir "seed.iso"
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_5f1478be62ab5e8d')
CreateIso -SourceDir $SeedDir -OutputFile $SeedIso -VolumeId "cidata"

Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_75cf4528e83fec3c')
Write-Output "  user:     stash-admin"
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_d16883e5df36f6c1')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_491b6a0a529b230a' -Arguments @{ vMName = "$VMName" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_095582e0ec3b9dc8')
Write-Output ""

# --- REGION: Create and configure the Hyper-V VM
# See https://yuruna.link/42fa6f45-0016
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_b0bde9c66516dc8a' -Arguments @{ vMName = "$VMName"; switchName = "$switchName" })
Hyper-V\New-VM -Name $VMName -Generation 2 -MemoryStartupBytes 2GB -SwitchName $switchName -VHDPath $vhdxFile | Out-Null

# --- REGION: https://yuruna.link/4220a755-000a
# Hyper-V takes bare hex, no separators.
$YurunaGuestMac = Get-YurunaGuestMacAddress -VMName $VMName
Hyper-V\Set-VMNetworkAdapter -VMName $VMName -StaticMacAddress ($YurunaGuestMac -replace ':','')
Write-Verbose "Deterministic guest MAC for '$VMName': $YurunaGuestMac"

Set-VM -Name $VMName -MemoryStartupBytes 2GB -MemoryMinimumBytes 2GB -MemoryMaximumBytes 2GB -AutomaticCheckpointsEnabled $false | Out-Null
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off | Out-Null

# --- REGION: https://yuruna.link/42dc5bb9-0005
# No-op on AMD64. On ARM64 the heartbeat channel drives a Linux guest into
# repeated soft lockups before hv_storvsc registers, so the root disk never
# enumerates and the guest never reaches the service it exists to run. Set
# before the DVD is attached so the guest's first boot is already free of it.
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

# --- REGION: Start VM and wait for IP
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_44a010f47f51d941' -Arguments @{ vMName = "$VMName" })
Hyper-V\Start-VM -Name $VMName

Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_2c8ff2df499f232c')
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_b93b853caa0a1c89')

# Discover via Get-CacheVmCandidateIp -- shared primitive in Yuruna.Host
# that combines KVP + ARP. Same approach as the caching-proxy-service pattern.
$dockIp = $null
$dockCandidateIps = @()
$maxIterations = 120  # 120 * 5s = 10 minutes
$vmDiscoveryLogged = $false
$vmOnExternalSwitch = $false
$arpProbeAnnounced = $false

# The ARP sweep only makes sense on a bridged (External) switch, where the
# host is not the DHCP server and never observes the guest's lease. The
# External vSwitch name is operator-configurable (Get-OrCreateYurunaExternalSwitch
# honors a pre-created switch under any name), so key off the switch this
# script resolved rather than a literal name -- a literal silently skips the
# sweep on a host that named its bridge anything else.
$switchIsExternal = ((Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue).SwitchType -eq 'External')

$ProgressPreference = 'Continue'
$activity  = "Waiting for '$VMName' to obtain an IP"
$startTime = Get-Date

for ($i = 0; $i -lt $maxIterations; $i++) {
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($vm) {
        # ARP-probe the bridged /24 to populate the host's neighbor cache
        # when the host isn't the DHCP server.
        # feedback_hyperv_external_vswitch_arp_discovery.md
        if ($i -eq 0) {
            $vmOnExternalSwitch = $switchIsExternal -and
                (($vm | Get-VMNetworkAdapter -ErrorAction SilentlyContinue |
                        Select-Object -First 1).SwitchName -eq $switchName)
        }
        if ($vmOnExternalSwitch -and $i -ge 6) {
            if (-not $arpProbeAnnounced) {
                Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_86ae3482cd8932d7' -Arguments @{ switchName = "$switchName" })
                $arpProbeAnnounced = $true
            }
            Invoke-YurunaExternalArpProbe -SwitchName $switchName
        }

        $dockCandidateIps = @(Get-CacheVmCandidateIp -VM $vm)
        if ($dockCandidateIps) {
            if (-not $vmDiscoveryLogged) {
                $vmMac = ($vm | Get-VMNetworkAdapter | Select-Object -First 1).MacAddress
                $vmMacDashed = if ($vmMac -match '^[0-9A-Fa-f]{12}$') {
                    (($vmMac -replace '(..)(?!$)', '$1-')).ToUpper()
                } else { '(unknown)' }
                Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_711aec356a249726' -Arguments @{ vmMacDashed = "$vmMacDashed" })
                Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_c31ff5024871e3cc' -Arguments @{ vMName = "${VMName}"; join = "$($dockCandidateIps -join ', ')" })
                $vmDiscoveryLogged = $true
            }
            break
        }
    }

    $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
    $pct     = [math]::Min(100, [math]::Round(($elapsed / ($maxIterations * 5)) * 100))
    Write-Progress -Activity $activity -Status "elapsed ${elapsed}s" -PercentComplete $pct -SecondsRemaining (($maxIterations * 5) - $elapsed)

    Start-Sleep -Seconds 5
}
Write-Progress -Activity $activity -Completed

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
