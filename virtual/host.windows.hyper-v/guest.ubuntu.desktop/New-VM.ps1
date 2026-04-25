<#PSScriptInfo
.VERSION 0.1
.GUID 42d9e0f1-a2b3-4c45-d678-9e0f1a2b3c45
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

param(
    [string]$VMName = "ubuntu-desktop01",
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

# Inform and check for elevation
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
$baseImageName = "host.windows.hyper-v.guest.ubuntu.desktop"
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

# .Replace() (literal) not -replace (regex): the hash has $-delimiters
# ($6$salt$hash) regex would read as backreferences.
# SSH public key used by the test harness; Test.Ssh.psm1 generates the
# key pair on first use under test/.ssh/.
$TestSshModule = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))) "test/modules/Test.Ssh.psm1"
Import-Module $TestSshModule -Force
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error "Get-YurunaSshPublicKey returned empty. Module path: $TestSshModule"; exit 1 }

# Detect the squid-cache VM and inject its proxy URL if available.
# Running cache = guest installs go through local HTTP cache instead of
# Ubuntu's CDN (no 429s, ~30 min → ~2 min on cache hit). Replaces
# apt-cacher-ng, which only cached .deb URLs and missed subiquity's
# pre-install kernel fetch (the one that was 429'ing).
#
# Severity policy (avoids silent fallback-to-429):
#   * No squid-cache VM         → WARNING, proceed (direct CDN)
#   * squid-cache stopped       → WARNING, proceed (direct CDN)
#   * squid-cache running but
#     :3128 silent after probe  → ERROR, exit 1 (fix the cache first)
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
    Write-Warning "  No squid-cache VM exists on this host. Guest will download packages directly from Ubuntu mirrors — expect 429 rate-limit failures on linux-firmware under load."
    Write-Warning "  To enable caching, run: virtual\host.windows.hyper-v\guest.squid-cache\New-VM.ps1"
} elseif ($cacheVM.State -ne 'Running') {
    Write-Warning "  squid-cache VM exists but is '$($cacheVM.State)'. Guest will download directly (expect occasional 429s)."
    Write-Warning "  To enable caching: Start-VM squid-cache ; then wait for cloud-init to finish."
} else {
    # KVP+ARP discovery + :3128 probe live in VM.common.psm1
    # (Get-WorkingCachingProxyUrl). One module means this consumer, the
    # producer, and Start-CachingProxy.ps1's summary see the same answer
    # — earlier drift had Start-SquidCache's KVP-only summary reporting
    # "discovery failed" while this script's ARP path found the cache.
    $CachingProxyUrl = Get-WorkingCachingProxyUrl -VMName "squid-cache"
    if ($CachingProxyUrl) {
        Write-Output "  squid-cache VM detected at $CachingProxyUrl — guest will use local proxy."
    } else {
        $cacheIps = Get-CacheVmCandidateIp -VM $cacheVM
        $ipList = if ($cacheIps) { $cacheIps -join ', ' } else { '(none discovered)' }
        # Write-Error reformats multi-line content (wraps + prefixes
        # with '|'), unreadable. $Host.UI.WriteLine keeps Write-Host-
        # style color output without the PSScriptAnalyzer complaint.
        $detail = @"

=========================================================================
ERROR: squid-cache VM is running but port 3128 is not reachable.
=========================================================================
  Discovered IPs: $ipList

Aborting so this guest install doesn't silently fall back to direct
CDN access and hit the 429 rate limiter (the exact failure squid-cache
was supposed to prevent).

Accessing the squid-cache VM for debugging:
  * Console:  vmconnect localhost squid-cache
              login:    ubuntu
              password: read it from
                <HyperVVHDPath>\squid-cache\squid-cache-password.txt
              (the squid-cache New-VM.ps1 generates a fresh random
               10-char password on each rebuild and saves it there.)
  * SSH:      ssh ubuntu@<ip>
              (uses the yuruna harness key at test\.ssh\yuruna_ed25519 --
               same key this Ubuntu Desktop guest uses; passwordless)

=== Step 1: find the actual apt / cloud-init error ===
The REAL error is in /var/log/cloud-init-output.log inside the cache VM,
not in 'cloud-init status' or 'systemctl status'. Run this first:

  sudo grep -E 'E:|429 |Hash Sum|Failed to fetch|Unable to locate|Exit code' /var/log/cloud-init-output.log | head -40

Common patterns:
  * '429 Too Many Requests'    -> Ubuntu's CDN rate-limited this host
                                  when the cache VM tried to install
                                  squid itself. Wait 15-30 min then
                                  re-run guest.squid-cache/New-VM.ps1
                                  (rebuilds the cache VM cleanly).
  * 'Unable to locate package' -> package name changed; report it.
  * Nothing obvious            -> use the fuller diagnostics below.

=== Step 2: deeper diagnostics ===
  systemctl status squid                # 'could not be found' = install failed
  ss -ltn 'sport = :3128'               # port bound?
  cloud-init status --long              # still running?
  Test-NetConnection -Port 3128 -ComputerName <ip>   # from this host

Recovery:
  * Cloud-init still running -> wait for it to finish (5-15 min on
    first boot), then re-run this script.
  * Install broken -> rebuild the cache VM:
      virtual\host.windows.hyper-v\guest.squid-cache\New-VM.ps1
    (exits non-zero on port-bind failure, so you'll see the real error.)

To intentionally skip the cache for this install, stop the cache VM
first:  Stop-VM squid-cache   (guest will then WARN and download direct).
=========================================================================
"@
        $Host.UI.WriteLine([ConsoleColor]::Red, $Host.UI.RawUI.BackgroundColor, $detail)
        exit 1
    }
}
}

# Build the autoinstall apt-proxy block. When a cache is reachable,
# inject `apt: proxy: http://...` under autoinstall so subiquity's
# in-installer apt (kernel + linux-firmware, the steps that 429'd
# against security.ubuntu.com) routes through squid. No cache = omit
# the block; subiquity behaves as before.
#
# Kept in sync with guest.ubuntu.server/New-VM.ps1.
# sources_list: the Desktop 24.04 amd64 squashfs ships
# /etc/apt/sources.list.d/ubuntu.sources (deb822) with ONLY a file:/cdrom
# entry and no network URI. Curtin's apt-config does a "modifymirrors"
# substitution — it can only rewrite an existing URI, not add one. A
# classic /etc/apt/sources.list via sources_list bypasses the no-op; apt
# merges both files so off-cdrom packages (openssh-server, HWE kernel)
# are reachable via archive.ubuntu.com through squid during install.
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

# DVD drives for Ubuntu ISO + seed ISO
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
Write-Output "Start the VM from Hyper-V Manager to begin Ubuntu Desktop installation."
Write-Output "The Ubuntu installer will run automatically via autoinstall."
Write-Output "Default credentials - username: ubuntu, password: password (must be changed on first login)"
Write-Output ""
Write-Output "After installation completes, remove the DVD drives:"
Write-Output "  Get-VMDvdDrive -VMName '$VMName' | Remove-VMDvdDrive"
