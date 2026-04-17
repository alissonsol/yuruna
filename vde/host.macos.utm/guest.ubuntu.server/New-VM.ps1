<#PSScriptInfo
.VERSION 0.1
.GUID 42b5c6d7-e8f9-4a01-b234-5c6d7e8f9a02
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
    Creates a UTM VM that installs Ubuntu Server 24.04, then adds the
    ubuntu-desktop package on first boot.

.DESCRIPTION
    Mirrors guest.ubuntu.desktop/New-VM.ps1 but uses the Server live ISO.
    The Server ISO's cdrom has linux-generic and a network-configured
    ubuntu.sources, so subiquity's install_kernel step succeeds where the
    Desktop (ubuntu-desktop-bootstrap) ISO fails.

    After autoinstall finishes, cloud-init runs on first boot and installs
    ubuntu-desktop from ubuntu-ports (through squid-cache when available).
    A second reboot lands on GDM — same end state as the desktop guest,
    just via a server-first install path that actually works.
#>

param(
    [string]$VMName = "ubuntu-server01"
)

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Output "Invalid VMName '$VMName'. Only alphanumeric characters, dots, hyphens, and underscores are allowed."
    exit 1
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$MachineName = $(hostname -s)
$VdeDir = "$HOME/Desktop/Yuruna.VDE/$MachineName.nosync"
New-Item -ItemType Directory -Force -Path $VdeDir | Out-Null
$UtmDir = "$VdeDir/$VMName.utm"
$DataDir = "$UtmDir/Data"
$downloadDir = "$HOME/virtual/ubuntu.env"

# ===== Environment checks for nested virtualization (Docker Desktop / KVM) =====

# Check macOS version (requires macOS 15 Sequoia or later)
$macosVersion = & sw_vers -productVersion 2>$null
$macosMajor = [int]($macosVersion -split '\.')[0]
if ($macosMajor -lt 15) {
    Write-Error "macOS 15 Sequoia or later is required for nested virtualization (found macOS $macosVersion)."
    Write-Error "Docker Desktop inside the VM requires nested virtualization to expose /dev/kvm."
    exit 1
}
Write-Output "macOS version: $macosVersion (OK)"

# Check Apple Silicon chip (requires M3 or later for nested virtualization)
$chipName = (& system_profiler SPHardwareDataType 2>$null | Select-String "Chip" | ForEach-Object { $_ -replace '.*Chip:\s*', '' }).Trim()
if (-not $chipName) {
    Write-Error "Could not detect Apple Silicon chip. This script requires Apple Silicon (M3 or later)."
    exit 1
}
if ($chipName -notmatch 'Apple M([3-9]|[1-9]\d)') {
    Write-Error "Apple Silicon M3 or later is required for nested virtualization (found: $chipName)."
    Write-Error "M1 and M2 chips do not support nested virtualization. Docker Desktop will not work inside the VM."
    exit 1
}
Write-Output "Chip: $chipName (OK)"

# Check UTM version (requires v4.6.0 or later)
$utmPlist = "/Applications/UTM.app/Contents/Info.plist"
if (-not (Test-Path $utmPlist)) {
    Write-Error "UTM not found at /Applications/UTM.app. Install with: brew install --cask utm"
    exit 1
}
$utmVersion = (& /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $utmPlist 2>$null)
if ($utmVersion) {
    $utmParts = $utmVersion -split '\.'
    $utmMajor = [int]$utmParts[0]
    $utmMinor = $utmParts.Count -gt 1 ? [int]$utmParts[1] : 0
    if ($utmMajor -lt 4 -or ($utmMajor -eq 4 -and $utmMinor -lt 6)) {
        Write-Error "UTM v4.6.0 or later is required for nested virtualization (found v$utmVersion)."
        Write-Error "Update with: brew upgrade --cask utm"
        exit 1
    }
    Write-Output "UTM version: $utmVersion (OK)"
} else {
    Write-Warning "Could not determine UTM version. Ensure UTM v4.6.0 or later is installed."
}

Write-Output "All nested virtualization requirements met."
Write-Output ""

# === Seek the base image ===
$baseImageName = "host.macos.utm.guest.ubuntu.server"
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"
if (-not (Test-Path $baseImageFile)) {
    Write-Error "Base image not found at '$baseImageFile'. Run Get-Image.ps1 first."
    exit 1
}

# Find OpenSSL with SHA-512 passwd support (for autoinstall password hash)
$PasswordHash = $null
foreach ($path in @("/opt/homebrew/opt/openssl@3/bin/openssl", "/opt/homebrew/opt/openssl/bin/openssl", "/usr/local/opt/openssl@3/bin/openssl", "/usr/local/opt/openssl/bin/openssl", "openssl")) {
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
    Write-Error "OpenSSL with SHA-512 password support is required. Install with: brew install openssl"
    exit 1
}

Write-Output "Creating VM '$VMName' using image: $baseImageFile"

# === Create copies and files for VM ===

# Create UTM bundle structure
if (Test-Path $UtmDir) { Remove-Item -Recurse -Force $UtmDir }
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# Create EFI variable store (required by Apple Virtualization UEFI boot)
$EfiVarsFile = "$DataDir/efi_vars.fd"
Write-Output "Creating EFI variable store..."
$swiftCode = @'
import Foundation
import Virtualization
let url = URL(fileURLWithPath: CommandLine.arguments[1])
do { _ = try VZEFIVariableStore(creatingVariableStoreAt: url) }
catch { fputs("Error: \(error.localizedDescription)\n", stderr); exit(1) }
'@
$swiftCode | & swift - "$EfiVarsFile"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to create EFI variable store. Ensure Xcode command line tools are installed."
    exit 1
}
Write-Output "EFI variable store created."

# Copy base image ISO into the bundle (named after hostname)
$DestIso = "$DataDir/$VMName.iso"
Copy-Item -Path $baseImageFile -Destination $DestIso
Write-Output "Copied installer ISO as: $VMName.iso"

# Create blank disk for installation (512GB, sparse raw image for Apple Virtualization)
$DiskImage = "$DataDir/disk.img"
Write-Output "Creating 512GB disk image (raw format for Apple Virtualization)..."
& qemu-img create -f raw "$DiskImage" 512G
if ($LASTEXITCODE -ne 0) {
    Write-Error "qemu-img failed. Install QEMU tools with: brew install qemu"
    exit 1
}

# Generate autoinstall seed ISO
$SeedDir = Join-Path $downloadDir "seed_temp/$VMName"
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
#   * No squid-cache VM registered with UTM → WARNING, proceed (direct CDN)
#   * VM registered but not started         → WARNING, proceed (direct CDN)
#   * VM started but :3128 unreachable      → ERROR, exit 1
#
# For the server-based install the squid-cache is even more valuable than
# for the desktop-ISO flow: installing ubuntu-desktop on first boot pulls
# ~2 GB of .deb packages through apt, and caching them across guest
# rebuilds is a very large cycle-time win.
$ProxyUrl = ""
$utmctl = (Get-Command utmctl -ErrorAction SilentlyContinue)?.Source
if (-not $utmctl -and (Test-Path "/Applications/UTM.app/Contents/MacOS/utmctl")) {
    $utmctl = "/Applications/UTM.app/Contents/MacOS/utmctl"
}

$squidStatus = $null
if ($utmctl) {
    try {
        $squidStatus = (& $utmctl status squid-cache 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -ne 0) { $squidStatus = $null }
    } catch {
        Write-Verbose "utmctl status squid-cache failed: $($_.Exception.Message)"
        $squidStatus = $null
    }
}

$probePort3128 = {
    param($ipToTest, $timeoutMs)
    $tcp = New-Object System.Net.Sockets.TcpClient
    $ok = $false
    try {
        $h = $tcp.BeginConnect($ipToTest, 3128, $null, $null)
        if ($h.AsyncWaitHandle.WaitOne($timeoutMs) -and $tcp.Connected) { $ok = $true }
    } catch {
        Write-Verbose "squid-cache probe to ${ipToTest}:3128 failed: $($_.Exception.Message)"
    } finally { $tcp.Close() }
    return $ok
}

if ($squidStatus -and $squidStatus.ToString().Trim() -match 'start') {
    # VM exists and is started — discover its IP via subnet scan on
    # Apple Virtualization Shared-NAT (192.168.64.0/24).
    for ($octet = 2; $octet -le 30; $octet++) {
        $candidate = "192.168.64.$octet"
        if (& $probePort3128 $candidate 200) {
            $ProxyUrl = "http://${candidate}:3128"
            Write-Output "  squid-cache detected at $ProxyUrl — guest will use local proxy."
            break
        }
    }
    if (-not $ProxyUrl) {
        # $Host.UI.WriteLine is the PSScriptAnalyzer-safe way to keep the
        # color output Write-Host would give us (Write-Error wraps +
        # prefixes each line with '|', rendering diagnostic blocks unreadable).
        $detail = @"

=========================================================================
ERROR: squid-cache VM is started but port 3128 is not reachable.
=========================================================================
  utmctl status squid-cache  : $squidStatus
  subnet probe 192.168.64/24 : no listener on :3128 (ports 2-30 checked)

Aborting so this guest install doesn't silently fall back to direct
CDN access and hit the 429 rate limiter.

Accessing the squid-cache VM for debugging:
  * UTM window:  login 'ubuntu', password from
                   ~/virtual/squid-cache/squid-cache-password.txt
  * SSH:         ssh ubuntu@<ip>

Rebuild the cache VM:
  vde/host.macos.utm/guest.squid-cache/New-VM.ps1

To intentionally skip the cache:
  utmctl stop squid-cache   (guest will then WARN and download direct).
=========================================================================
"@
        $Host.UI.WriteLine([ConsoleColor]::Red, $Host.UI.RawUI.BackgroundColor, $detail)
        exit 1
    }
} elseif ($squidStatus) {
    Write-Warning "  squid-cache VM exists (status: $squidStatus) but is not started. Guest will download directly (expect occasional 429s)."
    Write-Warning "  To enable caching: utmctl start squid-cache ; then wait for cloud-init to finish."
} else {
    # No VM registered — fall back to subnet probe for alternate setups.
    for ($octet = 2; $octet -le 30; $octet++) {
        $candidate = "192.168.64.$octet"
        if (& $probePort3128 $candidate 200) {
            $ProxyUrl = "http://${candidate}:3128"
            Write-Output "  squid-cache detected at $ProxyUrl (subnet probe fallback) — guest will use local proxy."
            break
        }
    }
    if (-not $ProxyUrl) {
        if (-not $utmctl) {
            Write-Warning "  utmctl not found — can't query UTM directly. Subnet probe of 192.168.64.0/24:3128 also found nothing."
        } else {
            Write-Warning "  No squid-cache VM registered with UTM and nothing listening on :3128 in 192.168.64.0/24."
        }
        Write-Warning "  Guest will download directly — expect 429 rate-limit failures on linux-firmware + ubuntu-desktop under load."
        Write-Warning "  To enable caching, run: vde/host.macos.utm/guest.squid-cache/New-VM.ps1"
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

$SeedIso = "$DataDir/seed.iso"
Write-Output "Generating seed.iso with autoinstall configuration..."
& hdiutil makehybrid -o "$SeedIso" -joliet -iso -default-volume-name cidata "$SeedDir"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to create seed.iso with hdiutil."
    exit 1
}

# Generate UTM config.plist from template (Apple Virtualization backend)
$TemplatePath = Join-Path $ScriptDir "config.plist.template"
if (-not (Test-Path $TemplatePath)) {
    Write-Error "Template not found at '$TemplatePath'."
    exit 1
}

# Generate UUIDs, MAC address, and machine identifier for this VM
$VmUuid = [guid]::NewGuid().ToString().ToUpper()
$DiskId = [guid]::NewGuid().ToString().ToUpper()
$IsoId = [guid]::NewGuid().ToString().ToUpper()
$SeedId = [guid]::NewGuid().ToString().ToUpper()
$rng = [System.Random]::new()
$MacBytes = [byte[]]::new(6)
$rng.NextBytes($MacBytes)
$MacBytes[0] = ($MacBytes[0] -bor 0x02) -band 0xFE  # locally administered unicast
$MacAddress = ($MacBytes | ForEach-Object { $_.ToString("X2") }) -join ":"

# Generate machineIdentifier (16 random bytes, base64-encoded) for GenericPlatform
# Required by Apple Virtualization.framework for nested virtualization support
$MachineIdBytes = [byte[]]::new(16)
$rng.NextBytes($MachineIdBytes)
$MachineIdentifier = [Convert]::ToBase64String($MachineIdBytes)

$PlistContent = (Get-Content -Raw $TemplatePath) `
    -replace '__VM_NAME__',             $VMName `
    -replace '__VM_UUID__',             $VmUuid `
    -replace '__MAC_ADDRESS__',         $MacAddress `
    -replace '__DISK_IDENTIFIER__',     $DiskId `
    -replace '__DISK_IMAGE_NAME__',     'disk.img' `
    -replace '__ISO_IDENTIFIER__',      $IsoId `
    -replace '__ISO_IMAGE_NAME__',      "$VMName.iso" `
    -replace '__SEED_IDENTIFIER__',     $SeedId `
    -replace '__SEED_IMAGE_NAME__',     'seed.iso' `
    -replace '__MACHINE_IDENTIFIER__',  $MachineIdentifier `
    -replace '__CPU_COUNT__',           '4' `
    -replace '__MEMORY_SIZE__',         '16384'

Set-Content -Path "$UtmDir/config.plist" -Value $PlistContent

# === Cleanup temporary folders ===
Remove-Item -Recurse -Force $SeedDir -ErrorAction SilentlyContinue

# === Guidance ===
Write-Output ""
Write-Output "VM bundle created: $UtmDir"
Write-Output "Backend: Apple Virtualization (with nested virtualization / KVM support)"
Write-Output "Double-click '$VMName.utm' on your Desktop to import it into UTM."
Write-Output ""
Write-Output "Boot sequence:"
Write-Output "  1. Ubuntu Server autoinstalls via subiquity (~5-10 min)"
Write-Output "  2. First boot: cloud-init installs ubuntu-desktop via apt"
Write-Output "     (~2 GB download — much faster with squid-cache running)"
Write-Output "  3. After ubuntu-desktop install, the VM reboots into GDM."
Write-Output ""
Write-Output "Default credentials - username: ubuntu, password: password (must be changed on first login)"
