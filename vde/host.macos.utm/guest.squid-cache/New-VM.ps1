<#PSScriptInfo
.VERSION 0.1
.GUID 42f1b2c3-d4e5-4f67-8901-a2b3c4d5e6f9
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
    Builds the squid HTTP-caching proxy VM bundle for macOS UTM.

.DESCRIPTION
    Creates a UTM .utm bundle (Apple Virtualization backend) that boots the
    arm64 Ubuntu cloud image produced by Get-Image.ps1 and runs Squid on
    port 3128. Cloud-init (via seed.iso) installs squid + apache2 + squid-cgi,
    pre-warms the linux-firmware package through the proxy, and exposes
    cachemgr.cgi at http://<vm-ip>/cgi-bin/cachemgr.cgi.

    Mirrors guest.ubuntu.desktop/New-VM.ps1 in structure, minus:
      * nested-virt preflight (squid doesn't need KVM)
      * installer ISO drive (cloud image is already bootable)
      * blank qemu-img disk (we use the converted raw cloud image directly)

.PARAMETER VMName
    Name of the UTM VM. Default: squid-cache

.EXAMPLE
    ./Get-Image.ps1
    ./New-VM.ps1
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = "squid-cache"
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
$downloadDir = "$HOME/virtual/squid-cache"

# UTM presence check (skip the nested-virt + M3 checks — squid needs neither).
$utmPlist = "/Applications/UTM.app/Contents/Info.plist"
if (-not (Test-Path $utmPlist)) {
    Write-Error "UTM not found at /Applications/UTM.app. Install with: brew install --cask utm"
    exit 1
}

# === Seek the base image ===
$baseImageName = "host.macos.utm.guest.squid-cache"
$baseImageFile = Join-Path $downloadDir "$baseImageName.raw"
if (-not (Test-Path $baseImageFile)) {
    Write-Error "Base image not found at '$baseImageFile'. Run Get-Image.ps1 first."
    exit 1
}

Write-Output "Creating VM '$VMName' using image: $baseImageFile"
# Provenance side-channel for operators reading the transcript. Emits
# "Provenance: <url>" when the sidecar is healthy; warns otherwise.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

# === Create UTM bundle ===
if (Test-Path $UtmDir) { Remove-Item -Recurse -Force $UtmDir }
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# EFI variable store — same swift snippet guest.ubuntu.desktop uses.
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
    Write-Error "Failed to create EFI variable store. Ensure Xcode command line tools are installed (xcode-select --install)."
    exit 1
}

# Copy the pre-built raw cloud image into the bundle as the boot disk.
# Apple Virtualization.framework reads this directly; no conversion here —
# Get-Image.ps1 already produced raw, resized to 144 GB.
$DiskImage = "$DataDir/disk.img"
Write-Output "Copying cloud image into bundle as disk.img (sparse copy on APFS)..."
# `/bin/cp -c` triggers APFS clone (O(1), sparse-preserving). Falls back
# to Copy-Item if the destination isn't APFS (rare on modern macOS).
# Full path bypasses the PowerShell `cp` alias for Copy-Item.
& /bin/cp -c $baseImageFile $DiskImage
if ($LASTEXITCODE -ne 0) {
    Write-Warning "/bin/cp -c (APFS clone) failed; falling back to Copy-Item."
    Copy-Item -Path $baseImageFile -Destination $DiskImage
}

# === Generate cloud-init seed ISO ===
$SeedDir = Join-Path $downloadDir "seed_temp/$VMName"
if (Test-Path $SeedDir) { Remove-Item -Recurse -Force $SeedDir }
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null

$VmConfigDir = Join-Path $ScriptDir "vmconfig"
Copy-Item -Path (Join-Path $VmConfigDir "meta-data") -Destination "$SeedDir/meta-data"

# Load the yuruna test-harness SSH public key — same module the Ubuntu
# Desktop guest uses, so one keypair grants passwordless access to every
# VM in the yuruna environment (including this cache VM, for debugging
# when squid or cloud-init misbehave).
$TestSshModule = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))) "test/modules/Test.Ssh.psm1"
Import-Module $TestSshModule -Force
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error "Get-YurunaSshPublicKey returned empty. Module path: $TestSshModule"; exit 1 }

# Generate a random 10-char alphanumeric password for the 'ubuntu' user.
# Using a fresh password per rebuild (rather than the constant 'password')
# prevents browsers from caching / auto-suggesting it when opening
# cachemgr.cgi, which was triggering repeated password-manager popups.
# Charset is ASCII alphanumerics only: no YAML-escape surprises, and no
# shell-special characters when the user ssh's with the password.
$pwChars = [char[]]'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
$UbuntuPassword = -join (1..10 | ForEach-Object {
    $pwChars[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32(0, $pwChars.Length)]
})

# Stash the password next to the raw image so users can retrieve it long
# after this script's console output has scrolled away. The file is
# plaintext — the download dir lives under ~/virtual/squid-cache (owner-
# only on default APFS home perms), and this is a dev-only credential
# with RFC1918-only reachability.
$PasswordFile = Join-Path $downloadDir "squid-cache-password.txt"
Set-Content -Path $PasswordFile -Value $UbuntuPassword -NoNewline
& chmod 600 $PasswordFile 2>&1 | Out-Null

# Substitute the SSH key and password placeholders in user-data. `.Replace()`
# (literal) rather than -replace (regex) because the key contains characters
# regex would interpret (though ssh-rsa base64 usually doesn't, cheap insurance).
$UserData = (Get-Content -Raw (Join-Path $VmConfigDir "user-data")).
    Replace('SSH_AUTHORIZED_KEY_PLACEHOLDER', $SshAuthorizedKey).
    Replace('PASSWORD_PLACEHOLDER', $UbuntuPassword)
Set-Content -Path "$SeedDir/user-data" -Value $UserData -NoNewline

$SeedIso = "$DataDir/seed.iso"
Write-Output "Generating seed.iso with cloud-init configuration..."
& hdiutil makehybrid -o "$SeedIso" -joliet -iso -default-volume-name cidata "$SeedDir"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to create seed.iso with hdiutil."
    exit 1
}

# === Render config.plist from template ===
$TemplatePath = Join-Path $ScriptDir "config.plist.template"
if (-not (Test-Path $TemplatePath)) {
    Write-Error "Template not found at '$TemplatePath'."
    exit 1
}

$VmUuid  = [guid]::NewGuid().ToString().ToUpper()
$DiskId  = [guid]::NewGuid().ToString().ToUpper()
$SeedId  = [guid]::NewGuid().ToString().ToUpper()
$rng     = [System.Random]::new()

$MacBytes = [byte[]]::new(6)
$rng.NextBytes($MacBytes)
$MacBytes[0] = ($MacBytes[0] -bor 0x02) -band 0xFE  # locally administered unicast
$MacAddress = ($MacBytes | ForEach-Object { $_.ToString("X2") }) -join ":"

$MachineIdBytes = [byte[]]::new(16)
$rng.NextBytes($MachineIdBytes)
$MachineIdentifier = [Convert]::ToBase64String($MachineIdBytes)

# 4 GB RAM, 4 vCPU — same sizing the Hyper-V squid-cache uses. subiquity
# opens 4-8 concurrent .deb downloads per install; with 1 vCPU + 512 MB
# the cache became a bottleneck under the old apt-cacher-ng, making
# proxied installs slower than direct. 4 cores cover the parallel streams.
# 4 GB (up from 2 GB) gives headroom for squid's larger in-memory index as
# the on-disk cache grows to 128 GB — squid keeps one metadata entry per
# cached object in RAM (~400 bytes each).
$PlistContent = (Get-Content -Raw $TemplatePath) `
    -replace '__VM_NAME__',            $VMName `
    -replace '__VM_UUID__',            $VmUuid `
    -replace '__MAC_ADDRESS__',        $MacAddress `
    -replace '__DISK_IDENTIFIER__',    $DiskId `
    -replace '__DISK_IMAGE_NAME__',    'disk.img' `
    -replace '__SEED_IDENTIFIER__',    $SeedId `
    -replace '__SEED_IMAGE_NAME__',    'seed.iso' `
    -replace '__MACHINE_IDENTIFIER__', $MachineIdentifier `
    -replace '__CPU_COUNT__',          '4' `
    -replace '__MEMORY_SIZE__',        '4096'

Set-Content -Path "$UtmDir/config.plist" -Value $PlistContent

# === Cleanup temporary folders ===
Remove-Item -Recurse -Force $SeedDir -ErrorAction SilentlyContinue

# === Guidance ===
# Use a LITERAL here-string (@'...'@ — single quotes) for the multi-line
# block. The shell snippets below contain $(utmctl ...), "$ip", and other
# bash syntax that MUST be passed through verbatim for the user to read,
# NOT evaluated by PowerShell. Placeholders like __VM_NAME__ / __UTM_DIR__
# are substituted after the fact with .Replace(). An earlier version tried
# to escape $ with \$ — but \ is NOT a PowerShell string escape, so
# `\$(utmctl ...)` actually ran utmctl and produced "Virtual machine not
# found" in the middle of the guidance output.
Write-Output ""
Write-Output "=== VM bundle created ==="
Write-Output "  Path:      $UtmDir"
Write-Output "  Backend:   Apple Virtualization"
Write-Output ""
Write-Output "  Console/SSH login:"
Write-Output "    user:     ubuntu"
Write-Output "    password: $UbuntuPassword"
Write-Output "    (saved also at: $PasswordFile,"
Write-Output "     and embedded in the seed.iso's user-data — chpasswd)"
$guidance = @'

Next steps (the guest.ubuntu.desktop consumer will ERROR — not
silently fall back to direct CDN — if it finds this VM but can't
reach port 3128, so verify all three checks below before starting
guest installs):

  1. Register with UTM:
       open '__UTM_DIR__'    # double-click equivalent

  2. Start the VM and wait 5-15 minutes for cloud-init
     (install squid + apache2 + squid-cgi, then pre-warm):
       utmctl start __VM_NAME__

  3. Find the VM's IP. `utmctl ip-address` does NOT work for Apple
     Virtualization VMs (returns "Operation not supported by the
     backend") — use one of these instead:
     a) Easiest — look in the UTM window for __VM_NAME__; the Linux
        console prints "eth0: <ip>" at the login prompt after DHCP.
     b) Apple's shared-NAT DHCP leases (usually user-readable):
          awk -F'[ =]' '/name=__VM_NAME__/{found=1} found && /ip_address/{print $NF; exit}' \
              /var/db/dhcpd_leases
     c) Port-scan the Shared-NAT subnet for a squid listener:
          for i in $(seq 2 30); do
            nc -z -w 1 192.168.64.$i 3128 2>/dev/null && echo "squid at 192.168.64.$i"
          done
     Call the resulting address `$ip` in the remaining steps.

  4. Verify squid is listening on port 3128:
       nc -z -w 3 "$ip" 3128 && echo 'squid OK' || echo 'squid DOWN'

  5. Verify pre-warm finished (cache occupancy should be > 0):
       open "http://$ip/cgi-bin/cachemgr.cgi"    # -> 'storedir'

If step 4 reports 'squid DOWN' after 15 minutes, access the VM:
  * UTM window:  login 'ubuntu' / password '__PASSWORD__'
                 (password also at __PASSWORD_FILE__; does NOT expire)
  * SSH:         ssh ubuntu@$ip   (uses the yuruna harness key
                                   at test/.ssh/yuruna_ed25519; passwordless)

Then — REAL apt/cloud-init errors live in the output log, not in
'cloud-init status'. Run this FIRST:
  sudo grep -E 'E:|429 |Hash Sum|Failed to fetch|Unable to locate|Exit code' \
    /var/log/cloud-init-output.log | head -40

If that's inconclusive, fall back to:
  cloud-init status --long
  sudo tail -n 300 /var/log/cloud-init-output.log
  systemctl status squid

'429 Too Many Requests' in the log -> Ubuntu's CDN rate-limited
this Mac's public IP while cloud-init tried to install squid.
Wait 15-30 min and rebuild by re-running this script.
'@
Write-Output ($guidance.
    Replace('__VM_NAME__', $VMName).
    Replace('__UTM_DIR__', $UtmDir).
    Replace('__PASSWORD__', $UbuntuPassword).
    Replace('__PASSWORD_FILE__', $PasswordFile))
