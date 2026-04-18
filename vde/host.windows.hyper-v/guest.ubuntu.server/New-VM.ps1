<#PSScriptInfo
.VERSION 0.1
.GUID 42d9e0f1-a2b3-4c45-d678-9e0f1a2b3c47
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
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
    Creates a Hyper-V VM that installs Ubuntu Server 24.04, then adds the
    ubuntu-desktop package on first boot.

.DESCRIPTION
    Mirrors guest.ubuntu.desktop/New-VM.ps1 but uses the Server live ISO.
    The Server ISO's cdrom has linux-generic and a network-configured
    ubuntu.sources, so subiquity's install_kernel step succeeds where the
    Desktop (ubuntu-desktop-bootstrap) ISO fails.

    After autoinstall finishes, cloud-init runs on first boot and installs
    ubuntu-desktop from the Ubuntu archive (through squid-cache when
    available). A second reboot lands on GDM — same end state as the
    desktop guest, just via a server-first install path that actually works.
#>

param(
    [string]$VMName = "ubuntu-server01",
    # Forwarded by the test harness (Invoke-TestRunner → Invoke-NewVM) so
    # every guest in a run agrees on a single squid-cache URL. When bound
    # (even to ""), the local discovery is skipped and this value is used
    # verbatim: "" means "no cache, go direct"; a URL means "use this".
    # When NOT bound (standalone / manual run), fall back to the discovery
    # block below.
    [string]$ProxyUrl
)

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Output "Invalid VMName '$VMName'. Only alphanumeric characters, dots, hyphens, and underscores are allowed."
    exit 1
}

$ProgressPreference = 'SilentlyContinue'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$commonModulePath = Join-Path -Path (Split-Path -Parent $ScriptDir) -ChildPath "VM.common.psm1"
Import-Module -Name $commonModulePath -Force

# Inform and check for elevation
Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output "Please run this script as Administrator."
    Write-Output "Be careful."
    exit 1
}

# Check if Hyper-V services are installed and running
$hypervFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($hypervFeature.State -ne 'Enabled') {
    Write-Output "Hyper-V is not enabled. Please enable Hyper-V from Windows Features."
    Write-Output "Instructions: https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/quick-start/enable-hyper-v"
    exit 1
}

$service = Get-Service -Name vmms -ErrorAction SilentlyContinue
if (!$service -or $service.Status -ne 'Running') {
    Write-Output "Hyper-V Virtual Machine Management service (vmms) is not running. Please start the service."
    Write-Output "Instructions: https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/quick-start/enable-hyper-v"
    exit 1
}

$downloadDir = (Get-VMHost).VirtualHardDiskPath
if (!(Test-Path -Path $downloadDir)) {
    Write-Output "The Hyper-V default VHDX folder does not exist: $downloadDir"
    exit 1
}

# === Seek the base image ===
$baseImageName = "host.windows.hyper-v.guest.ubuntu.server"
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"
if (!(Test-Path -Path $baseImageFile)) {
    Write-Error "Base image not found at '$baseImageFile'. Run Get-Image.ps1 first."
    exit 1
}

# Find OpenSSL with SHA-512 passwd support (for autoinstall password hash)
$PasswordHash = $null
foreach ($path in @("$env:ProgramFiles\Git\usr\bin\openssl.exe", "$env:ProgramFiles\Git\mingw64\bin\openssl.exe", "$env:ProgramFiles\OpenSSL-Win64\bin\openssl.exe", "${env:ProgramFiles(x86)}\OpenSSL-Win32\bin\openssl.exe", "openssl")) {
    try {
        $result = (& $path passwd -6 "password" 2>$null)
        if ($LASTEXITCODE -eq 0 -and $result) {
            $PasswordHash = $result.Trim()
            break
        }
    } catch {
        Write-Warning "Not found: $path"
    }
}
if (-not $PasswordHash) {
    Write-Error "OpenSSL with SHA-512 password support is required. Install Git for Windows or OpenSSL."
    exit 1
}

Write-Output "Creating VM '$VMName' using image: $baseImageFile"

# Check if VM exists and force delete it
$existingVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($existingVM) {
    Write-Output "VM '$VMName' exists. Deleting..."
    Stop-VM -Name $VMName -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    Remove-VM -Name $VMName -Force
    Write-Output "VM '$VMName' deleted."
}

# === Create copies and files for VM ===

# Create blank VHDX for installation (512GB, dynamically expanding)
$vmDir = Join-Path $downloadDir $VMName
if (!(Test-Path -Path $vmDir)) {
    New-Item -ItemType Directory -Path $vmDir -Force | Out-Null
}
$vhdxFile = Join-Path $vmDir "$VMName.vhdx"
if (Test-Path -Path $vhdxFile) {
    Remove-Item -Path $vhdxFile -Force
}
Write-Output "Creating 512GB dynamically expanding VHDX..."
New-VHD -Path $vhdxFile -SizeBytes 512GB -Dynamic | Out-Null

# Generate autoinstall seed ISO
$SeedDir = Join-Path $env:TEMP "seed_$VMName"
if (Test-Path $SeedDir) { Remove-Item -Recurse -Force $SeedDir }
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null

$VmConfigDir = Join-Path $ScriptDir "vmconfig"
$UserDataTemplate = Join-Path $VmConfigDir "user-data"
$MetaDataTemplate = Join-Path $VmConfigDir "meta-data"
if (-not (Test-Path $UserDataTemplate)) {
    Write-Error "user-data template not found at '$UserDataTemplate'."
    exit 1
}

# Load the SSH public key used by the test harness to drive the VM over SSH.
$TestSshModule = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))) "test/modules/Test.Ssh.psm1"
Import-Module $TestSshModule -Force
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error "Get-YurunaSshPublicKey returned empty. Module path: $TestSshModule"; exit 1 }

# Detect the squid-cache VM and inject its proxy URL if available. Same
# severity policy as guest.ubuntu.desktop:
#   * No squid-cache VM on this host      → WARNING, proceed (direct CDN)
#   * squid-cache VM exists but stopped   → WARNING, proceed (direct CDN)
#   * squid-cache VM running but :3128
#     doesn't answer within a few seconds → ERROR, exit 1
#
# For the server-based install the squid-cache is even more valuable than
# for the desktop-ISO flow: installing ubuntu-desktop on first boot pulls
# ~2 GB of .deb packages through apt, and caching them across guest
# rebuilds is a very large cycle-time win.
if ($PSBoundParameters.ContainsKey('ProxyUrl')) {
    # URL was forwarded by the caller (test runner). Skip discovery so this
    # script and the runner agree on a single cache URL. On Hyper-V the
    # race is narrower than on UTM (MAC-scoped neighbor lookup, not subnet
    # scan), but keeping one source of truth still simplifies debugging.
    if ($ProxyUrl) {
        Write-Output "  squid-cache URL forwarded by caller: $ProxyUrl — skipping local discovery."
    } else {
        Write-Output "  No proxy forwarded by caller — guest will download directly."
    }
} else {
$ProxyUrl = ""
$cacheVM = Get-VM -Name "squid-cache" -ErrorAction SilentlyContinue
if (-not $cacheVM) {
    Write-Warning "  No squid-cache VM exists on this host. Guest will download packages directly from Ubuntu mirrors — expect 429 rate-limit failures on linux-firmware + ubuntu-desktop under load."
    Write-Warning "  To enable caching, run: vde\host.windows.hyper-v\guest.squid-cache\New-VM.ps1"
} elseif ($cacheVM.State -ne 'Running') {
    Write-Warning "  squid-cache VM exists but is '$($cacheVM.State)'. Guest will download directly (expect occasional 429s)."
    Write-Warning "  To enable caching: Start-VM squid-cache ; then wait for cloud-init to finish."
} else {
    # Same dual-strategy IP discovery as guest.ubuntu.desktop:
    #   1. Hyper-V KVP (Get-VMNetworkAdapter.IPAddresses) — needs hv_kvp_daemon.
    #   2. ARP cache (Get-NetNeighbor) scoped to Default Switch, matched by MAC.
    $cacheIps = @($cacheVM | Get-VMNetworkAdapter | ForEach-Object { $_.IPAddresses } |
        Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
    if (-not $cacheIps) {
        $hostAdapter = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceAlias -like '*Default Switch*' } | Select-Object -First 1
        $vmMac = ($cacheVM | Get-VMNetworkAdapter | Select-Object -First 1).MacAddress
        if ($hostAdapter -and $vmMac -match '^[0-9A-Fa-f]{12}$' -and $vmMac -ne '000000000000') {
            $vmMacDashed = (($vmMac -replace '(..)(?!$)', '$1-')).ToUpper()
            # DO NOT take only the first neighbor entry. Hyper-V's Default
            # Switch leaves stale entries in the Windows neighbor table as
            # State='Permanent' when VMs are re-created: the SAME MAC can
            # appear at two IPs (e.g. 172.25.181.179 from a prior incarnation
            # AND 172.25.177.161 from the currently-running VM). Picking
            # just one previously caused cache detection to hit the stale
            # IP, fail the TCP probe on :3128, and silently fall back to
            # direct CDN. Collect ALL matching IPs and let the probe loop
            # below pick whichever one actually answers on 3128.
            $cacheIps = @(Get-NetNeighbor -AddressFamily IPv4 -InterfaceIndex $hostAdapter.InterfaceIndex -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.LinkLayerAddress -eq $vmMacDashed -and
                    $_.IPAddress -match '^\d+\.\d+\.\d+\.\d+$' -and
                    $_.State -ne 'Unreachable'
                } | ForEach-Object { $_.IPAddress })
        }
    }

    foreach ($ip in $cacheIps) {
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $async = $tcp.BeginConnect($ip, 3128, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(500) -and $tcp.Connected) {
                $ProxyUrl = "http://${ip}:3128"
                Write-Output "  squid-cache VM detected at $ProxyUrl — guest will use local proxy."
                break
            }
        } catch {
            Write-Verbose "squid-cache probe to ${ip}:3128 failed: $($_.Exception.Message)"
        } finally {
            $tcp.Close()
        }
    }
    if (-not $ProxyUrl) {
        $ipList = if ($cacheIps) { $cacheIps -join ', ' } else { '(none discovered)' }
        # $Host.UI.WriteLine is the PSScriptAnalyzer-safe way to keep the
        # color output Write-Host would give us.
        $detail = @"

=========================================================================
ERROR: squid-cache VM is running but port 3128 is not reachable.
=========================================================================
  Discovered IPs: $ipList

Aborting so this guest install doesn't silently fall back to direct
CDN access and hit the 429 rate limiter.

Accessing the squid-cache VM for debugging:
  * Console:  vmconnect localhost squid-cache
              login:    ubuntu
              password: read it from
                <HyperVVHDPath>\squid-cache\squid-cache-password.txt
  * SSH:      ssh ubuntu@<ip>

Rebuild the cache VM:
  vde\host.windows.hyper-v\guest.squid-cache\New-VM.ps1

To intentionally skip the cache:
  Stop-VM squid-cache   (guest will then WARN and download direct).
=========================================================================
"@
        $Host.UI.WriteLine([ConsoleColor]::Red, $Host.UI.RawUI.BackgroundColor, $detail)
        exit 1
    }
}
}

# Build the autoinstall apt-proxy block. When a cache is reachable, inject
# `apt: proxy: http://...` under autoinstall so subiquity + first-boot
# apt-get all route through squid.
if ($ProxyUrl) {
    $AptProxyBlock = "  apt:`n    proxy: $ProxyUrl"
} else {
    $AptProxyBlock = ""
}

$UserData = (Get-Content -Raw $UserDataTemplate).Replace('HOSTNAME_PLACEHOLDER', $VMName).Replace('HASH_PLACEHOLDER', $PasswordHash).Replace('SSH_AUTHORIZED_KEY_PLACEHOLDER', $SshAuthorizedKey).Replace('APT_PROXY_BLOCK_PLACEHOLDER', $AptProxyBlock).Replace('PROXY_URL_PLACEHOLDER', $ProxyUrl)
Set-Content -Path "$SeedDir/user-data" -Value $UserData -NoNewline

$MetaData = (Get-Content -Raw $MetaDataTemplate) `
    -replace 'HOSTNAME_PLACEHOLDER', $VMName
Set-Content -Path "$SeedDir/meta-data" -Value $MetaData -NoNewline

$SeedIso = Join-Path $vmDir "seed.iso"
Write-Output "Generating seed.iso with autoinstall configuration..."
CreateIso -SourceDir $SeedDir -OutputFile $SeedIso -VolumeId "cidata"

# Create and configure Hyper-V VM
Write-Output "Creating new VM '$VMName'..."
New-VM -Name $VMName -Generation 2 -MemoryStartupBytes 16384MB -SwitchName "Default Switch" -VHDPath $vhdxFile | Out-Null
Set-VM -Name $VMName -MemoryStartupBytes 16384MB -MemoryMinimumBytes 16384MB -MemoryMaximumBytes 16384MB -AutomaticCheckpointsEnabled $false | Out-Null
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off | Out-Null

# Add DVD drives for Ubuntu ISO and seed ISO
Add-VMDvdDrive -VMName $VMName -Path $baseImageFile | Out-Null
Add-VMDvdDrive -VMName $VMName -Path $SeedIso | Out-Null

# Set boot order: DVD (Ubuntu ISO) first for installation, then hard drive
$dvdDrive = Get-VMDvdDrive -VMName $VMName | Where-Object { $_.Path -eq $baseImageFile }
Set-VMFirmware -VMName $VMName -FirstBootDevice $dvdDrive

# Set CPU count to half of host cores
$Cores = (Get-CimInstance -ClassName Win32_Processor).NumberOfCores | Measure-Object -Sum
$CoreCount = $Cores.Sum
$vmCores = [math]::Floor($CoreCount / 2)
Set-VMProcessor -VMName $VMName -Count $vmCores -ExposeVirtualizationExtensions $true | Out-Null

# Set display resolution to 1920x1080.
# WARNING: The test harness OCR is calibrated for 1920x1080.
# Changing this resolution may break automated screen-text detection
# in waitForText sequence steps.
Set-VMVideo -VMName $VMName -HorizontalResolution 1920 -VerticalResolution 1080 -ResolutionType Single

# === Cleanup temporary folders ===
Remove-Item -Recurse -Force $SeedDir -ErrorAction SilentlyContinue

# === Guidance ===
Write-Output ""
Write-Output "VM '$VMName' created and configured."
Write-Output "Start the VM from Hyper-V Manager to begin Ubuntu Server installation."
Write-Output ""
Write-Output "Boot sequence:"
Write-Output "  1. Ubuntu Server autoinstalls via subiquity (~5-10 min)"
Write-Output "  2. First boot: cloud-init installs ubuntu-desktop via apt"
Write-Output "     (~2 GB download — much faster with squid-cache running)"
Write-Output "  3. After ubuntu-desktop install, the VM reboots into GDM."
Write-Output ""
Write-Output "Default credentials - username: ubuntu, password: password (must be changed on first login)"
Write-Output ""
Write-Output "After installation completes, remove the DVD drives:"
Write-Output "  Get-VMDvdDrive -VMName '$VMName' | Remove-VMDvdDrive"
