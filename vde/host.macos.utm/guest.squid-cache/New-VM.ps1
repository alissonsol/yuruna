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
# Get-Image.ps1 already produced raw, resized to 50 GB.
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

# Substitute the SSH key placeholder in user-data. `.Replace()` (literal)
# rather than -replace (regex) because the key contains characters regex
# would interpret (though ssh-rsa base64 usually doesn't, cheap insurance).
$UserData = (Get-Content -Raw (Join-Path $VmConfigDir "user-data")).Replace('SSH_AUTHORIZED_KEY_PLACEHOLDER', $SshAuthorizedKey)
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

# 2 GB RAM, 4 vCPU — same sizing the Hyper-V squid-cache uses. subiquity
# opens 4-8 concurrent .deb downloads per install; with 1 vCPU + 512 MB
# the cache became a bottleneck under the old apt-cacher-ng, making
# proxied installs slower than direct. 4 cores cover the parallel streams.
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
    -replace '__MEMORY_SIZE__',        '2048'

Set-Content -Path "$UtmDir/config.plist" -Value $PlistContent

# === Cleanup temporary folders ===
Remove-Item -Recurse -Force $SeedDir -ErrorAction SilentlyContinue

# === Guidance ===
Write-Output ""
Write-Output "=== VM bundle created ==="
Write-Output "  Path:      $UtmDir"
Write-Output "  Backend:   Apple Virtualization"
Write-Output ""
Write-Output "Next steps (the guest.ubuntu.desktop consumer will ERROR — not"
Write-Output "silently fall back to direct CDN — if it finds this VM but can't"
Write-Output "reach port 3128, so verify all three checks below before starting"
Write-Output "guest installs):"
Write-Output ""
Write-Output "  1. Register with UTM:"
Write-Output "       open '$UtmDir'    # double-click equivalent"
Write-Output ""
Write-Output "  2. Start the VM and wait 5-15 minutes for cloud-init"
Write-Output "     (install squid + apache2 + squid-cgi, then pre-warm):"
Write-Output "       utmctl start $VMName"
Write-Output ""
Write-Output "  3. Verify squid is listening on port 3128:"
Write-Output "       ip=\$(utmctl ip-address $VMName | head -n1)"
Write-Output "       nc -z -w 3 \"\$ip\" 3128 && echo 'squid OK' || echo 'squid DOWN'"
Write-Output ""
Write-Output "  4. Verify pre-warm finished (cache occupancy should be > 0):"
Write-Output "       open \"http://\$ip/cgi-bin/cachemgr.cgi\"    # → 'storedir'"
Write-Output ""
Write-Output "If step 3 reports 'squid DOWN' after 15 minutes, access the VM:"
Write-Output "  * UTM window:  login 'ubuntu' / password 'password' (does NOT expire)"
Write-Output "  * SSH:         ssh ubuntu@\$ip   (uses the yuruna harness key"
Write-Output "                                   at test/.ssh/yuruna_ed25519; passwordless)"
Write-Output ""
Write-Output "Then run:"
Write-Output "  cloud-init status --long"
Write-Output "  sudo tail -n 200 /var/log/cloud-init-output.log"
Write-Output "  systemctl status squid"
