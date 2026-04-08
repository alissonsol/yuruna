<#PSScriptInfo
.VERSION 0.1
.GUID 42e0f1a2-b3c4-4d56-e789-0f1a2b3c4d56
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
    [string]$VMName = "amazon-linux01"
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
$downloadDir = "$HOME/virtual/amazon.linux"

# === Seek the base image ===
$baseImageName = "host.macos.utm.guest.amazon.linux"
$baseImageFile = Join-Path $downloadDir "$baseImageName.qcow2"
if (-not (Test-Path $baseImageFile)) {
    Write-Error "Base image not found at '$baseImageFile'. Run Get-Image.ps1 first."
    exit 1
}

Write-Output "Creating VM '$VMName' using image: $baseImageFile"

# === Create copies and files for VM ===

# Create UTM bundle structure
if (Test-Path $UtmDir) { Remove-Item -Recurse -Force $UtmDir }
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# Convert base image from qcow2 to raw format (required by Apple Virtualization framework)
$DiskImage = "$DataDir/disk.img"
Write-Output "Converting base disk image from qcow2 to raw format..."
& qemu-img convert -f qcow2 -O raw "$baseImageFile" "$DiskImage"
if ($LASTEXITCODE -ne 0) {
    Write-Error "qemu-img convert failed. Install QEMU tools with: brew install qemu"
    exit 1
}

# Resize disk to 128GB (thin-provisioned, no extra space used until written)
Write-Output "Resizing disk image to 128GB..."
& qemu-img resize -f raw "$DiskImage" 128G
if ($LASTEXITCODE -ne 0) {
    Write-Error "qemu-img resize failed."
    exit 1
}

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

# Generate cloud-init seed ISO
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

$MetaData = (Get-Content -Raw $MetaDataTemplate) `
    -replace 'HOSTNAME_PLACEHOLDER', $VMName
$UserData = Get-Content -Raw $UserDataTemplate

Set-Content -Path "$SeedDir/meta-data" -Value $MetaData -NoNewline
Set-Content -Path "$SeedDir/user-data" -Value $UserData -NoNewline

$SeedIso = "$DataDir/seed.iso"
Write-Output "Generating seed.iso with cloud-init configuration..."
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
$SeedId = [guid]::NewGuid().ToString().ToUpper()
$rng = [System.Random]::new()
$MacBytes = [byte[]]::new(6)
$rng.NextBytes($MacBytes)
$MacBytes[0] = ($MacBytes[0] -bor 0x02) -band 0xFE  # locally administered unicast
$MacAddress = ($MacBytes | ForEach-Object { $_.ToString("X2") }) -join ":"

# Generate machineIdentifier (16 random bytes, base64-encoded) for GenericPlatform
$MachineIdBytes = [byte[]]::new(16)
$rng.NextBytes($MachineIdBytes)
$MachineIdentifier = [Convert]::ToBase64String($MachineIdBytes)

$PlistContent = (Get-Content -Raw $TemplatePath) `
    -replace '__VM_NAME__',             $VMName `
    -replace '__VM_UUID__',             $VmUuid `
    -replace '__MAC_ADDRESS__',         $MacAddress `
    -replace '__DISK_IDENTIFIER__',     $DiskId `
    -replace '__DISK_IMAGE_NAME__',     'disk.img' `
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
Write-Output "Backend: Apple Virtualization"
Write-Output "Double-click '$VMName.utm' on your Desktop to import it into UTM."
Write-Output "Cloud-init will configure the VM on first boot."
Write-Output "Default credentials - username: ec2-user, password: amazonlinux"
