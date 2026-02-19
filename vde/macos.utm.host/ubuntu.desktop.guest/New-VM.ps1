<#PSScriptInfo
.VERSION 0.4
.GUID 42b5c6d7-e8f9-4a01-b234-5c6d7e8f9a01
.AUTHOR Alisson Sol
.COMPANYNAME None
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

param(
    [string]$VMName = "ubuntu-desktop01"
)

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Output "Invalid VMName '$VMName'. Only alphanumeric characters, dots, hyphens, and underscores are allowed."
    exit 1
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$UtmDir = "$HOME/Desktop/$VMName.utm"
$DataDir = "$UtmDir/Data"
$DownloadDir = "$HOME/virtual/ubuntu.env"

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
    $utmMinor = if ($utmParts.Count -gt 1) { [int]$utmParts[1] } else { 0 }
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

# ===== VM creation =====

# 1. Locate the downloaded Ubuntu ISO
$IsoSource = Join-Path $DownloadDir "ubuntu.desktop.arm64.downloaded.iso"
if (-not (Test-Path $IsoSource)) {
    Write-Error "Ubuntu ISO not found at '$IsoSource'. Run Get-Image.ps1 first."
    exit 1
}

# 2. Find OpenSSL with SHA-512 passwd support (for autoinstall password hash)
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

Write-Output "Creating VM '$VMName' using ISO: $IsoSource"

# 3. Create UTM Bundle Structure
if (Test-Path $UtmDir) { Remove-Item -Recurse -Force $UtmDir }
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# 4. Create EFI variable store (required by Apple Virtualization UEFI boot)
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

# 5. Copy Ubuntu ISO into the bundle (named after hostname)
$DestIso = "$DataDir/$VMName.iso"
Copy-Item -Path $IsoSource -Destination $DestIso
Write-Output "Copied installer ISO as: $VMName.iso"

# 6. Create blank disk for installation (512GB, sparse raw image for Apple Virtualization)
$DiskImage = "$DataDir/disk.img"
Write-Output "Creating 512GB disk image (raw format for Apple Virtualization)..."
& qemu-img create -f raw "$DiskImage" 512G
if ($LASTEXITCODE -ne 0) {
    Write-Error "qemu-img failed. Install QEMU tools with: brew install qemu"
    exit 1
}

# 7. Generate autoinstall seed ISO
$SeedDir = Join-Path $DownloadDir "seed_temp/$VMName"
if (Test-Path $SeedDir) { Remove-Item -Recurse -Force $SeedDir }
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null

# Autoinstall user-data (username: ubuntu, password: password)
$VmConfigDir = Join-Path $ScriptDir "vmconfig"
$UserDataTemplate = Join-Path $VmConfigDir "user-data"
$MetaDataTemplate = Join-Path $VmConfigDir "meta-data"
if (-not (Test-Path $UserDataTemplate)) {
    Write-Error "user-data template not found at '$UserDataTemplate'."
    exit 1
}

# Use .Replace() (literal) instead of -replace (regex) because the hash
# contains $ delimiters ($6$salt$hash) that regex would interpret as backreferences
$UserData = (Get-Content -Raw $UserDataTemplate).Replace('HOSTNAME_PLACEHOLDER', $VMName).Replace('HASH_PLACEHOLDER', $PasswordHash)

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

# Clean up temp directory
Remove-Item -Recurse -Force $SeedDir -ErrorAction SilentlyContinue

# 8. Generate UTM config.plist from template (Apple Virtualization backend)
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

Write-Output ""
Write-Output "VM bundle created: $UtmDir"
Write-Output "Backend: Apple Virtualization (with nested virtualization / KVM support)"
Write-Output "Double-click '$VMName.utm' on your Desktop to import it into UTM."
Write-Output "The Ubuntu installer will start automatically with autoinstall."
Write-Output "Default credentials - username: ubuntu, password: password (must be changed on first login)"
