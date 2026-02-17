<#PSScriptInfo
.VERSION 0.3
.GUID 42e0f1a2-b3c4-4d56-e789-0f1a2b3c4d56
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
    [string]$VMName = "amazon-linux01"
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$UtmDir = "$HOME/Desktop/$VMName.utm"
$DataDir = "$UtmDir/Data"
$DownloadDir = "$HOME/virtual/amazon.linux"

# 1. Locate the downloaded Amazon Linux qcow2 image
$Qcow2Source = Join-Path $DownloadDir "amazonlinux.qcow2"
if (-not (Test-Path $Qcow2Source)) {
    Write-Error "Amazon Linux qcow2 image not found at '$Qcow2Source'. Run Get-Image.ps1 first."
    exit 1
}

Write-Output "Creating VM '$VMName' using image: $Qcow2Source"

# 2. Create UTM Bundle Structure
if (Test-Path $UtmDir) { Remove-Item -Recurse -Force $UtmDir }
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# 3. Copy Amazon Linux qcow2 as the VM disk
$DiskImage = "$DataDir/disk.qcow2"
Write-Output "Copying Amazon Linux disk image..."
Copy-Item -Path $Qcow2Source -Destination $DiskImage

# 4. Resize disk to 128GB (thin-provisioned, no extra space used until written)
Write-Output "Resizing disk image to 128GB..."
& qemu-img resize "$DiskImage" 128G
if ($LASTEXITCODE -ne 0) {
    Write-Error "qemu-img failed. Install QEMU tools with: brew install qemu"
    exit 1
}

# 5. Generate cloud-init seed ISO
$SeedDir = Join-Path $DownloadDir "seed_temp/$VMName"
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

Set-Content -Path "$SeedDir/meta-data" -Value $MetaData
Set-Content -Path "$SeedDir/user-data" -Value $UserData

$SeedIso = "$DataDir/seed.iso"
Write-Output "Generating seed.iso with cloud-init configuration..."
& hdiutil makehybrid -o "$SeedIso" -hfs -joliet -iso -default-volume-name cidata "$SeedDir"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to create seed.iso with hdiutil."
    exit 1
}

# Clean up temp directory
Remove-Item -Recurse -Force $SeedDir -ErrorAction SilentlyContinue

# 6. Generate UTM config.plist from template
$TemplatePath = Join-Path $ScriptDir "config.plist.template"
if (-not (Test-Path $TemplatePath)) {
    Write-Error "Template not found at '$TemplatePath'."
    exit 1
}

# Generate UUIDs and MAC address for this VM
$VmUuid = [guid]::NewGuid().ToString().ToUpper()
$DiskId = [guid]::NewGuid().ToString().ToUpper()
$SeedId = [guid]::NewGuid().ToString().ToUpper()
$MacBytes = [byte[]]::new(6)
[System.Random]::new().NextBytes($MacBytes)
$MacBytes[0] = ($MacBytes[0] -bor 0x02) -band 0xFE  # locally administered unicast
$MacAddress = ($MacBytes | ForEach-Object { $_.ToString("X2") }) -join ":"

$PlistContent = (Get-Content -Raw $TemplatePath) `
    -replace '__VM_NAME__',          $VMName `
    -replace '__VM_UUID__',          $VmUuid `
    -replace '__MAC_ADDRESS__',      $MacAddress `
    -replace '__DISK_IDENTIFIER__',  $DiskId `
    -replace '__DISK_IMAGE_NAME__',  'disk.qcow2' `
    -replace '__SEED_IDENTIFIER__',  $SeedId `
    -replace '__SEED_IMAGE_NAME__',  'seed.iso' `
    -replace '__CPU_COUNT__',        '4' `
    -replace '__MEMORY_SIZE__',      '8192'

Set-Content -Path "$UtmDir/config.plist" -Value $PlistContent

Write-Output ""
Write-Output "VM bundle created: $UtmDir"
Write-Output "Double-click '$VMName.utm' on your Desktop to import it into UTM."
Write-Output "Cloud-init will configure the VM on first boot."
Write-Output "Default credentials - username: ec2-user, password: amazonlinux"
