<#PSScriptInfo
.VERSION 0.3
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

# 4. Copy Ubuntu ISO into the bundle (named after hostname)
$DestIso = "$DataDir/$VMName.iso"
Copy-Item -Path $IsoSource -Destination $DestIso
Write-Output "Copied installer ISO as: $VMName.iso"

# 5. Create blank disk for installation (512GB, thin-provisioned qcow2)
$DiskImage = "$DataDir/disk.qcow2"
Write-Output "Creating 512GB disk image..."
& qemu-img create -f qcow2 "$DiskImage" 512G
if ($LASTEXITCODE -ne 0) {
    Write-Error "qemu-img failed. Install QEMU tools with: brew install qemu"
    exit 1
}

# 6. Generate autoinstall seed ISO
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

$UserData = (Get-Content -Raw $UserDataTemplate) `
    -replace 'HOSTNAME_PLACEHOLDER', $VMName `
    -replace 'HASH_PLACEHOLDER', $PasswordHash

Set-Content -Path "$SeedDir/user-data" -Value $UserData
$MetaData = (Get-Content -Raw $MetaDataTemplate) `
    -replace 'HOSTNAME_PLACEHOLDER', $VMName
Set-Content -Path "$SeedDir/meta-data" -Value $MetaData

$SeedIso = "$DataDir/seed.iso"
Write-Output "Generating seed.iso with autoinstall configuration..."
& hdiutil makehybrid -o "$SeedIso" -hfs -joliet -iso -default-volume-name cidata "$SeedDir"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to create seed.iso with hdiutil."
    exit 1
}

# Clean up temp directory
Remove-Item -Recurse -Force $SeedDir -ErrorAction SilentlyContinue

# 7. Generate UTM config.plist from template
$TemplatePath = Join-Path $ScriptDir "config.plist.template"
if (-not (Test-Path $TemplatePath)) {
    Write-Error "Template not found at '$TemplatePath'."
    exit 1
}

# Generate UUIDs and MAC address for this VM
$VmUuid = [guid]::NewGuid().ToString().ToUpper()
$DiskId = [guid]::NewGuid().ToString().ToUpper()
$IsoId = [guid]::NewGuid().ToString().ToUpper()
$SeedId = [guid]::NewGuid().ToString().ToUpper()
$MacBytes = [byte[]]::new(6)
[System.Random]::new().NextBytes($MacBytes)
$MacBytes[0] = ($MacBytes[0] -bor 0x02) -band 0xFE  # locally administered unicast
$MacAddress = ($MacBytes | ForEach-Object { $_.ToString("X2") }) -join ":"

$PlistContent = (Get-Content -Raw $TemplatePath) `
    -replace '__VM_NAME__',        $VMName `
    -replace '__VM_UUID__',        $VmUuid `
    -replace '__MAC_ADDRESS__',    $MacAddress `
    -replace '__DISK_IDENTIFIER__', $DiskId `
    -replace '__DISK_IMAGE_NAME__', 'disk.qcow2' `
    -replace '__ISO_IDENTIFIER__',  $IsoId `
    -replace '__ISO_IMAGE_NAME__',  "$VMName.iso" `
    -replace '__SEED_IDENTIFIER__', $SeedId `
    -replace '__SEED_IMAGE_NAME__', 'seed.iso' `
    -replace '__CPU_COUNT__',       '4' `
    -replace '__MEMORY_SIZE__',     '16384'

Set-Content -Path "$UtmDir/config.plist" -Value $PlistContent

Write-Output ""
Write-Output "VM bundle created: $UtmDir"
Write-Output "Double-click '$VMName.utm' on your Desktop to import it into UTM."
Write-Output "The Ubuntu installer will start automatically with autoinstall."
Write-Output "Default credentials - username: ubuntu, password: password (must be changed on first login)"
