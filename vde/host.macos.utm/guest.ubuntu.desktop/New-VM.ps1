<#PSScriptInfo
.VERSION 0.1
.GUID 42b5c6d7-e8f9-4a01-b234-5c6d7e8f9a01
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
    [string]$VMName = "ubuntu-desktop01"
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
$baseImageName = "host.macos.utm.guest.ubuntu.desktop"
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

# Use .Replace() (literal) instead of -replace (regex) because the hash
# contains $ delimiters ($6$salt$hash) that regex would interpret as backreferences
# Load the SSH public key used by the test harness to drive the VM over SSH.
$TestSshModule = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))) "test/modules/Test.Ssh.psm1"
Import-Module $TestSshModule -Force
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error "Get-YurunaSshPublicKey returned empty. Module path: $TestSshModule"; exit 1 }

# Detect the squid-cache VM and inject its proxy URL if available.
# On macOS/UTM there is no Get-VM equivalent; we use `utmctl status squid-cache`
# to tell "VM doesn't exist" from "VM exists but port unreachable" — that
# distinction drives severity (WARNING vs ERROR) below.
#
# Severity policy (to avoid silent fallback-to-429):
#   * No squid-cache VM registered with UTM → WARNING, proceed (direct CDN)
#   * VM registered but not started         → WARNING, proceed (direct CDN)
#   * VM started but :3128 unreachable      → ERROR, exit 1 (don't guess;
#                                              the cache owner should fix it
#                                              before launching guest installs)
$ProxyUrl = ""
# Resolve utmctl. The brew cask install puts it on PATH; a plain UTM.app
# install (Mac App Store or direct .dmg) does not, so fall back to the
# canonical path inside the bundle. If neither exists, skip the utmctl
# branch entirely and rely on the subnet-probe fallback below.
$utmctl = (Get-Command utmctl -ErrorAction SilentlyContinue)?.Source
if (-not $utmctl -and (Test-Path "/Applications/UTM.app/Contents/MacOS/utmctl")) {
    $utmctl = "/Applications/UTM.app/Contents/MacOS/utmctl"
}

$squidStatus = $null
if ($utmctl) {
    try {
        # utmctl prints e.g. 'started' / 'stopped' / 'paused' on stdout; errors go to stderr.
        # A non-existent VM exits non-zero — we trap that as "not registered".
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
    # VM exists and is started — port MUST respond, else ERROR.
    # Two discovery attempts, both required because `utmctl ip-address` can
    # return nothing on macOS 15+ when the guest is still negotiating DHCP
    # or when the UTM daemon hasn't polled its agent yet — in which case
    # a subnet probe of 192.168.64.0/24 (Apple Virtualization's Shared NAT
    # range) often succeeds where utmctl didn't.
    $squidIp = (& $utmctl ip-address squid-cache 2>$null |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } |
                Select-Object -First 1)
    if ($squidIp -and (& $probePort3128 $squidIp 1000)) {
        $ProxyUrl = "http://${squidIp}:3128"
        Write-Output "  squid-cache detected at $ProxyUrl (via utmctl ip-address) — guest will use local proxy."
    }
    # Second attempt: subnet-probe when utmctl didn't yield a reachable IP.
    if (-not $ProxyUrl) {
        for ($octet = 2; $octet -le 30; $octet++) {
            $candidate = "192.168.64.$octet"
            if (& $probePort3128 $candidate 200) {
                $ProxyUrl = "http://${candidate}:3128"
                $squidIp = $candidate   # so diagnostic text below has a real IP
                Write-Output "  squid-cache detected at $ProxyUrl (subnet probe fallback, utmctl ip-address gave no usable IP) — guest will use local proxy."
                break
            }
        }
    }
    if (-not $ProxyUrl) {
        # Write-Error reformats multi-line content (wraps + prefixes each
        # line with '|'), which renders our diagnostic block unreadable.
        # Use Write-Host with ForegroundColor for the detail, then exit 1.
        $ipShown = if ($squidIp) { $squidIp } else { '(utmctl returned no IPv4)' }
        $detail = @"

=========================================================================
ERROR: squid-cache VM is started but port 3128 is not reachable.
=========================================================================
  utmctl status squid-cache  : $squidStatus
  utmctl ip-address          : $ipShown
  subnet probe 192.168.64/24 : no listener on :3128

Aborting so this guest install doesn't silently fall back to direct
CDN access and hit the 429 rate limiter (the exact failure squid-cache
was supposed to prevent — especially bad on macOS/UTM where every
guest shares the host's single public IP via Apple Virtualization's
Shared NAT).

Accessing the squid-cache VM for debugging:
  * UTM window:  login 'ubuntu' / password 'password'
                 (cloud-init sets this; does NOT expire after first use)
  * SSH:         ssh ubuntu@<ip>   (find <ip> in the UTM window)
                 (uses the yuruna harness key at test/.ssh/yuruna_ed25519 —
                  same key this Ubuntu Desktop guest uses; passwordless)

=== Step 1: find the actual apt / cloud-init error ===
The REAL error is in /var/log/cloud-init-output.log inside the cache VM,
not in 'cloud-init status' or 'systemctl status'. Run this first:

  sudo grep -E 'E:|429 |Hash Sum|Failed to fetch|Unable to locate|Exit code' /var/log/cloud-init-output.log | head -40

Common patterns:
  * '429 Too Many Requests'    -> Ubuntu's CDN rate-limited this host
                                  when the cache VM tried to install
                                  squid itself (extra-likely on macOS
                                  UTM where every VM shares one public
                                  IP). Wait 15-30 min then rebuild.
  * 'Unable to locate package' -> package name changed; report it.
  * Nothing obvious            -> use the fuller diagnostics below.

=== Step 2: deeper diagnostics ===
  systemctl status squid                # 'could not be found' = install failed
  ss -ltn 'sport = :3128'               # port bound?
  cloud-init status --long              # still running?

Recovery:
  * Cloud-init still running -> wait for it to finish (5-15 min on
    first boot), then re-run this script.
  * Install broken -> rebuild the cache VM:
      vde/host.macos.utm/guest.squid-cache/New-VM.ps1

To intentionally skip the cache for this install, stop it first:
  utmctl stop squid-cache   (guest will then WARN and download direct).
=========================================================================
"@
        Write-Host $detail -ForegroundColor Red
        exit 1
    }
} elseif ($squidStatus) {
    # VM exists but isn't started — warn and fall through to direct CDN.
    Write-Warning "  squid-cache VM exists (status: $squidStatus) but is not started. Guest will download directly (expect occasional 429s)."
    Write-Warning "  To enable caching: utmctl start squid-cache ; then wait for cloud-init to finish."
} else {
    # No VM registered under that name — fall back to subnet probe for
    # alternate setups (user might run a different cache VM name), then
    # warn if nothing responds.
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
            Write-Warning "  utmctl not found (tried PATH and /Applications/UTM.app/Contents/MacOS/utmctl) — can't query UTM directly."
            Write-Warning "  Subnet probe of 192.168.64.0/24:3128 also found nothing. Install UTM with 'brew install --cask utm' or add it to PATH."
        } else {
            Write-Warning "  No squid-cache VM registered with UTM and nothing listening on :3128 in 192.168.64.0/24."
        }
        Write-Warning "  Guest will download directly — expect 429 rate-limit failures on linux-firmware under load."
        Write-Warning "  To enable caching, run: vde/host.macos.utm/guest.squid-cache/New-VM.ps1"
    }
}

# Build the autoinstall apt-proxy block. When a cache is reachable, inject
# a top-level `apt: proxy: http://...` under autoinstall so subiquity's own
# in-installer apt-get calls (including the kernel/linux-firmware step that
# 429'd against security.ubuntu.com) route through squid. When no cache,
# omit the block entirely — subiquity then behaves exactly as before.
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
Write-Output "The Ubuntu installer will start automatically with autoinstall."
Write-Output "Default credentials - username: ubuntu, password: password (must be changed on first login)"
