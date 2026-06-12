<#PSScriptInfo
.VERSION 2026.06.12
.GUID 42f1b2c3-d4e5-4f67-8901-a2b3c4d5e680
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
    Creates (or recreates) the Yuruna Stash Service VM on Hyper-V.

.DESCRIPTION
    Builds a lightweight Ubuntu 24.04 LTS cloud-image VM intended to
    host the stash-service daemon (SCP receiver + SQLite metadata
    store). Cloud-init only brings up the VM with the harness yuruna
    user; daemon install + launch is out of scope here and runs as a
    later automation step.

    See https://yuruna.link/stash-service for the full specification.

.PARAMETER VMName
    Name of the Hyper-V VM. Default: yuruna-stash-service.
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = "yuruna-stash-service"
)

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Output "Invalid VMName '$VMName'. Only alphanumeric characters, dots, hyphens, and underscores are allowed."
    exit 1
}

$global:InformationPreference = "Continue"
$global:ProgressPreference    = "SilentlyContinue"

$commonModulePath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath "modules/Yuruna.Host.psm1"
Import-Module -Name $commonModulePath -Force

Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output "Please run this script as Administrator."
    exit 1
}

if (-not (Assert-HyperVEnabled)) { exit 1 }

# === Remove existing VM ===
$existingVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($existingVM) {
    Write-Output "VM '$VMName' exists. Deleting..."
    Hyper-V\Stop-VM -Name $VMName -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    try {
        Hyper-V\Remove-VM -Name $VMName -Force -ErrorAction Stop
    } catch {
        $diag = Get-VM -Name $VMName -ErrorAction SilentlyContinue |
            Format-List Name, State, Status, Generation, Path | Out-String
        throw "Hyper-V\Remove-VM failed for '$VMName': $($_.Exception.Message)`nLive Hyper-V state:`n$diag"
    }
    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
        throw "Hyper-V\Remove-VM returned success for '$VMName' but Get-VM still finds it; aborting before re-creation."
    }
    Write-Output "VM '$VMName' deleted."
}

# === Locate base image ===
$downloadDir = (Get-VMHost).VirtualHardDiskPath
$baseImageName = "host.windows.hyper-v.guest.stash-service"
$baseImageFile = Join-Path $downloadDir "$baseImageName.vhdx"

if (!(Test-Path -Path $baseImageFile)) {
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
    if (!(Test-Path -Path $baseImageFile)) {
        Write-Output "Base image not found at '$baseImageFile' after auto Get-Image. Run Get-Image.ps1 manually."
        exit 1
    }
}

# === Create VM disk (copy of base image) ===
$vmDir = Join-Path $downloadDir $VMName
if (-not (Test-Path -Path $vmDir)) {
    New-Item -ItemType Directory -Path $vmDir -Force | Out-Null
}
$vhdxFile = Join-Path $vmDir "$VMName.vhdx"
Write-Output "Creating VHDX for '$VMName' by copying base image..."
Copy-Item -Path $baseImageFile -Destination $vhdxFile -Force

# === Generate cloud-init seed ISO ===
# meta-data is shared under host/vmconfig/ (byte-identical across all 3 host platforms).
$hostVmConfigDir = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'host/vmconfig'
$SeedDir = Join-Path $env:TEMP ("seed_${VMName}_{0:D4}" -f (Get-Random -Maximum 10000))
if (Test-Path -LiteralPath $SeedDir) { Remove-Item -LiteralPath $SeedDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null

Copy-Item -Path (Join-Path $hostVmConfigDir 'stash-service.meta-data') -Destination "$SeedDir/meta-data"

# Yuruna harness SSH key + vault-managed yuruna password. Shared with the
# caching-proxy and the test guests under the same username, so a single
# vault entry serves every VM the harness creates.
$_repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Ssh.psm1')       -Force -DisableNameChecking
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Extension.psm1') -Global -Force -Verbose:$false
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error "Get-YurunaSshPublicKey returned empty."; exit 1 }
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$YurunaPassword = Get-Password -Username 'yuruna'
if (-not $YurunaPassword) { Write-Error "Get-Password returned empty for 'yuruna'."; exit 1 }
Write-Output "Password came from authentication mechanism: $_authActiveName"
Write-Output "See configuration at: $(Resolve-ExtensionAreaDir -Area 'authentication')"

# Render user-data from the shared base + Hyper-V overlay (host/vmconfig/
# stash-service.*). The overlay is empty (no per-platform divergence today);
# Build-CloudInitUserData resolves the SSH-key and password placeholders.
Import-Module (Join-Path $_repoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force
$UserData = Build-CloudInitUserData `
    -BasePath    (Join-Path $_repoRoot 'host/vmconfig/stash-service.base.user-data') `
    -OverlayPath (Join-Path $_repoRoot 'host/vmconfig/stash-service.hyperv.overlay.yml') `
    -RepoRoot    $_repoRoot `
    -Replacement @{
        SSH_AUTHORIZED_KEY_PLACEHOLDER = $SshAuthorizedKey
        PASSWORD_PLACEHOLDER           = $YurunaPassword
    } -Confirm:$false
Set-Content -Path "$SeedDir/user-data" -Value $UserData -NoNewline

$SeedIso = Join-Path $vmDir "seed.iso"
Write-Output "Generating seed.iso with cloud-init configuration..."
CreateIso -SourceDir $SeedDir -OutputFile $SeedIso -VolumeId "cidata"

Write-Output ""
Write-Output "== stash-service console/SSH login (available NOW) =="
Write-Output "  user:     yuruna"
Write-Output "  password: (in authentication vault under 'yuruna')"
Write-Output "  If the wait below stalls or fails, open 'vmconnect localhost $VMName'"
Write-Output "  and log in with the credentials above to inspect cloud-init state."
Write-Output ""

# === Pick a vSwitch ===
# Prefer the Yuruna-External vSwitch so the stash VM gets a real LAN IP
# via DHCP and peers reach it directly at <vm-ip>:22. Fall back to
# Default Switch only when External isn't available (Wi-Fi-only host,
# etc.); stash-service-on-Default-Switch is only reachable from same-host
# guests.
$switchName = Get-OrCreateYurunaExternalSwitch
if (-not $switchName) {
    Write-Output "WARNING: External vSwitch unavailable -- falling back to 'Default Switch'."
    Write-Output "  Dock VM will not be reachable from LAN by its own IP."
    $switchName = 'Default Switch'
}

# === Create and configure Hyper-V VM ===
# 8 GB RAM, 4 vCPU. Sized for the SCP receive + SQLite metadata writer
# + future in-VM UI. Roughly 4x caching-proxy's working-set baseline at
# 1/3 of its cache_mem allocation -- room to grow without locking the
# operator into the heaviest profile from day one.
Write-Output "Creating new VM '$VMName' on switch '$switchName'..."
Hyper-V\New-VM -Name $VMName -Generation 2 -MemoryStartupBytes 8GB -SwitchName $switchName -VHDPath $vhdxFile | Out-Null
Set-VM -Name $VMName -MemoryStartupBytes 8GB -MemoryMinimumBytes 8GB -MemoryMaximumBytes 8GB -AutomaticCheckpointsEnabled $false | Out-Null
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off | Out-Null
Add-VMDvdDrive -VMName $VMName -Path $SeedIso | Out-Null
# --- VM core-count policy: see https://yuruna.link/definition#defining-the-vm-core-count-policy
$hostCores = (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
if ($hostCores -lt 4) {
    Write-Error "Host has $hostCores physical cores; Yuruna requires at least 4. See https://yuruna.link/definition#defining-the-vm-core-count-policy"
    exit 1
}
$vmCores = [math]::Max(4, [math]::Floor($hostCores / 2))
Set-VMProcessor -VMName $VMName -Count $vmCores | Out-Null

Remove-Item -LiteralPath $SeedDir -Recurse -Force -ErrorAction SilentlyContinue

# === Start VM and wait for IP ===
Write-Output "Starting VM '$VMName'..."
Hyper-V\Start-VM -Name $VMName

Write-Output "Waiting for VM to obtain an IP address..."
Write-Output "  (cloud-init brings up networking; first boot can take 1-3 minutes)"

# Discover via Get-CacheVmCandidateIp -- shared primitive in Yuruna.Host
# that combines KVP + ARP. Same approach as the caching-proxy pattern.
$dockIp = $null
$dockCandidateIps = @()
$maxIterations = 120  # 120 * 5s = 10 minutes
$vmDiscoveryLogged = $false
$vmOnExternalSwitch = $false
$arpProbeAnnounced = $false

$ProgressPreference = 'Continue'
$activity  = "Waiting for '$VMName' to obtain an IP"
$startTime = Get-Date

for ($i = 0; $i -lt $maxIterations; $i++) {
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($vm) {
        # ARP-probe the Yuruna-External /24 to populate the host's
        # neighbor cache when the host isn't the DHCP server.
        # feedback_hyperv_external_vswitch_arp_discovery.md
        if ($i -eq 0) {
            $vmOnExternalSwitch = (($vm | Get-VMNetworkAdapter -ErrorAction SilentlyContinue |
                                          Select-Object -First 1).SwitchName -eq 'Yuruna-External')
        }
        if ($vmOnExternalSwitch -and $i -ge 6) {
            if (-not $arpProbeAnnounced) {
                Write-Output "  Active ARP probe on Yuruna-External subnet..."
                $arpProbeAnnounced = $true
            }
            Invoke-YurunaExternalArpProbe -SwitchName 'Yuruna-External'
        }

        $dockCandidateIps = @(Get-CacheVmCandidateIp -VM $vm)
        if ($dockCandidateIps) {
            if (-not $vmDiscoveryLogged) {
                $vmMac = ($vm | Get-VMNetworkAdapter | Select-Object -First 1).MacAddress
                $vmMacDashed = if ($vmMac -match '^[0-9A-Fa-f]{12}$') {
                    (($vmMac -replace '(..)(?!$)', '$1-')).ToUpper()
                } else { '(unknown)' }
                Write-Output "  VM MAC: $vmMacDashed"
                Write-Output "  Discovered IP(s) for ${VMName}: $($dockCandidateIps -join ', ')"
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
    Write-Error @"

stash-service VM '$VMName' did not obtain an IP address within 10 minutes.
Accessing the VM for debugging:
  * Console:  vmconnect localhost $VMName
              user: yuruna  (password in authentication vault)
"@
    exit 1
}

# Single-candidate pick: dock has no listening port to validate against
# in v1, so the first non-loopback candidate IP is authoritative. When
# ARP returned multiple candidates, the operator can verify reachability
# with `ssh yuruna@<ip>` -- the harness key is already authorized.
$dockIp = $dockCandidateIps | Select-Object -First 1

Write-Output ""
Write-Output "== stash-service VM is READY =="
Write-Output "  VM:       $VMName"
Write-Output "  IP:       $dockIp"
Write-Output "  SSH:      ssh yuruna@$dockIp  (harness key authorized)"
Write-Output "  Console:  vmconnect localhost $VMName  (user yuruna, vault password)"
Write-Output ""
Write-Output "Daemon install + launch is a later automation step (see"
Write-Output "https://yuruna.link/stash-service)."
exit 0
