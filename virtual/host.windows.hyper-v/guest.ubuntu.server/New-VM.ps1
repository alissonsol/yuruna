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
    # Forwarded by the test harness (Invoke-TestRunner → Invoke-NewVM)
    # so every guest in a run agrees on one caching proxy URL. When
    # bound (even to ""), local discovery is skipped and this value is
    # used verbatim: "" = no cache, go direct; URL = use this. When NOT
    # bound (standalone run), fall back to the discovery block below.
    [string]$CachingProxyUrl
)

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Output "Invalid VMName '$VMName'. Only alphanumeric characters, dots, hyphens, and underscores are allowed."
    exit 1
}

$ProgressPreference = 'SilentlyContinue'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$commonModulePath = Join-Path -Path (Split-Path -Parent $ScriptDir) -ChildPath "VM.common.psm1"
Import-Module -Name $commonModulePath -Force

Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output "Please run this script as Administrator."
    Write-Output "Be careful."
    exit 1
}

# Assert-HyperVEnabled calls dism.exe directly instead of
# Get-WindowsOptionalFeature — avoids the "Class not registered" COM
# failure on first post-install runs on fresh Windows 11.
if (-not (Assert-HyperVEnabled)) {
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

# Find OpenSSL with SHA-512 passwd for autoinstall password hash
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
# Provenance side-channel for the transcript. Emits "Provenance: <url>"
# when the sidecar is healthy; warns otherwise.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

$existingVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($existingVM) {
    Write-Output "VM '$VMName' exists. Deleting..."
    Stop-VM -Name $VMName -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    Remove-VM -Name $VMName -Force
    Write-Output "VM '$VMName' deleted."
}

# === Create copies and files for VM ===

# 512GB dynamically expanding VHDX
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

# Autoinstall seed ISO
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

# SSH public key used by the test harness.
$TestSshModule = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))) "test/modules/Test.Ssh.psm1"
Import-Module $TestSshModule -Force
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error "Get-YurunaSshPublicKey returned empty. Module path: $TestSshModule"; exit 1 }

# Detect the squid-cache VM and inject its proxy URL if available. Same
# severity policy as guest.ubuntu.desktop:
#   * No cache VM         → WARNING, proceed (direct CDN)
#   * Cache VM stopped    → WARNING, proceed (direct CDN)
#   * Cache running, :3128
#     doesn't answer      → ERROR, exit 1
#
# Cache is even more valuable here than for the desktop-ISO flow:
# ubuntu-desktop on first boot pulls ~2 GB through apt — caching across
# rebuilds is a large cycle-time win.
if ($PSBoundParameters.ContainsKey('CachingProxyUrl')) {
    # URL forwarded by the test runner. Skip discovery so this script
    # and the runner agree on one cache URL. On Hyper-V the race is
    # narrower than UTM (MAC-scoped neighbor lookup, not subnet scan),
    # but one source of truth still simplifies debugging.
    if ($CachingProxyUrl) {
        Write-Output "  caching proxy URL forwarded by caller: $CachingProxyUrl — skipping local discovery."
    } else {
        Write-Output "  No proxy forwarded by caller — guest will download directly."
    }
} else {
$CachingProxyUrl = ""
$cacheVM = Get-VM -Name "squid-cache" -ErrorAction SilentlyContinue
if (-not $cacheVM) {
    Write-Warning "  No squid-cache VM exists on this host. Guest will download packages directly from Ubuntu mirrors — expect 429 rate-limit failures on linux-firmware + ubuntu-desktop under load."
    Write-Warning "  To enable caching, run: virtual\host.windows.hyper-v\guest.squid-cache\New-VM.ps1"
} elseif ($cacheVM.State -ne 'Running') {
    Write-Warning "  squid-cache VM exists but is '$($cacheVM.State)'. Guest will download directly (expect occasional 429s)."
    Write-Warning "  To enable caching: Start-VM squid-cache ; then wait for cloud-init to finish."
} else {
    # KVP+ARP discovery + :3128 probe live in VM.common.psm1
    # (Get-WorkingCachingProxyUrl). One module means this consumer, the
    # producer, and Start-CachingProxy.ps1's summary see the same
    # answer — earlier drift had Start-SquidCache's KVP-only summary
    # reporting "discovery failed" while ARP path found the cache.
    $CachingProxyUrl = Get-WorkingCachingProxyUrl -VMName "squid-cache"
    if ($CachingProxyUrl) {
        Write-Output "  squid-cache VM detected at $CachingProxyUrl — guest will use local proxy."
    } else {
        $cacheIps = Get-CacheVmCandidateIp -VM $cacheVM
        $ipList = if ($cacheIps) { $cacheIps -join ', ' } else { '(none discovered)' }
        # $Host.UI.WriteLine keeps Write-Host-style color without the
        # PSScriptAnalyzer complaint.
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
  virtual\host.windows.hyper-v\guest.squid-cache\New-VM.ps1

To intentionally skip the cache:
  Stop-VM squid-cache   (guest will then WARN and download direct).
=========================================================================
"@
        $Host.UI.WriteLine([ConsoleColor]::Red, $Host.UI.RawUI.BackgroundColor, $detail)
        exit 1
    }
}
}

# Build the autoinstall apt-proxy block. Cache reachable = inject
# `apt: proxy: http://...` so subiquity + first-boot apt-get route
# through squid.
#
# sources_list: the Server 24.04 amd64 squashfs ships
# /etc/apt/sources.list.d/ubuntu.sources (deb822) with ONLY a file:/cdrom
# entry and no network URI. Curtin's apt-config does "modifymirrors" —
# it rewrites an existing URI, not adds one. No archive.ubuntu.com to
# substitute = the proxied mirror never lands on the target, and
# `apt-get install --download-only ubuntu-desktop` postinstall fails
# with E: Unable to locate package. A classic /etc/apt/sources.list via
# sources_list bypasses the no-op: apt merges both files, ubuntu-desktop
# resolves via archive.ubuntu.com through squid.
# (`$PRIMARY/`$SECURITY/`$RELEASE are curtin tokens — backtick escapes
# the $ so PowerShell doesn't expand them.)
if ($CachingProxyUrl) {
    $AptProxyBlock = @"
  apt:
    proxy: $CachingProxyUrl
    sources_list: |
      deb `$PRIMARY `$RELEASE main restricted universe multiverse
      deb `$PRIMARY `$RELEASE-updates main restricted universe multiverse
      deb `$PRIMARY `$RELEASE-backports main restricted universe multiverse
      deb `$SECURITY `$RELEASE-security main restricted universe multiverse
"@
} else {
    $AptProxyBlock = ""
}

# Yuruna host (status server) IP+port baked into the seed for the dev
# iteration loop. Guest scripts read /etc/yuruna/host.env (written by
# the user-data late-commands) to resolve a local URL before falling
# back to GitHub. Default Switch's host IP changes across host
# reboots — see Test-YurunaHost.ps1 for the in-guest probe.
$YurunaHostIp = Get-GuestReachableHostIp
if (-not $YurunaHostIp) { $YurunaHostIp = '' }
$YurunaHostPort = '8080'
$YurunaTestConfig = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/test-config.json'
if (Test-Path $YurunaTestConfig) {
    try {
        $tc = Get-Content -Raw $YurunaTestConfig | ConvertFrom-Json
        if ($tc.statusServer.port) { $YurunaHostPort = "$($tc.statusServer.port)" }
    } catch { Write-Verbose "test-config.json parse failed: $_" }
}

$UserData = (Get-Content -Raw $UserDataTemplate).Replace('HOSTNAME_PLACEHOLDER', $VMName).Replace('HASH_PLACEHOLDER', $PasswordHash).Replace('SSH_AUTHORIZED_KEY_PLACEHOLDER', $SshAuthorizedKey).Replace('APT_PROXY_BLOCK_PLACEHOLDER', $AptProxyBlock).Replace('CACHING_PROXY_URL_PLACEHOLDER', $CachingProxyUrl).Replace('YURUNA_HOST_IP_PLACEHOLDER', $YurunaHostIp).Replace('YURUNA_HOST_PORT_PLACEHOLDER', $YurunaHostPort)
Set-Content -Path "$SeedDir/user-data" -Value $UserData -NoNewline

$MetaData = (Get-Content -Raw $MetaDataTemplate) `
    -replace 'HOSTNAME_PLACEHOLDER', $VMName
Set-Content -Path "$SeedDir/meta-data" -Value $MetaData -NoNewline

$SeedIso = Join-Path $vmDir "seed.iso"
Write-Output "Generating seed.iso with autoinstall configuration..."
CreateIso -SourceDir $SeedDir -OutputFile $SeedIso -VolumeId "cidata"

Write-Output "Creating new VM '$VMName'..."
New-VM -Name $VMName -Generation 2 -MemoryStartupBytes 16384MB -SwitchName "Default Switch" -VHDPath $vhdxFile | Out-Null
Set-VM -Name $VMName -MemoryStartupBytes 16384MB -MemoryMinimumBytes 16384MB -MemoryMaximumBytes 16384MB -AutomaticCheckpointsEnabled $false | Out-Null
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off | Out-Null

Add-VMDvdDrive -VMName $VMName -Path $baseImageFile | Out-Null
Add-VMDvdDrive -VMName $VMName -Path $SeedIso | Out-Null

# Boot order: DVD (Ubuntu ISO) first, then hard drive
$dvdDrive = Get-VMDvdDrive -VMName $VMName | Where-Object { $_.Path -eq $baseImageFile }
Set-VMFirmware -VMName $VMName -FirstBootDevice $dvdDrive

# CPU count = half host cores
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
