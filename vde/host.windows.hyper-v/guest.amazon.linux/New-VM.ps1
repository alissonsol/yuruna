<#PSScriptInfo
.VERSION 0.1
.GUID 42e9f0a1-b2c3-4d45-e678-9f0a1b2c3d45
.AUTHOR Alisson Sol
.COMPANYNAME None
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

# Script parameters. Default VMName should not match the base image name.
param(
	[Parameter(Position = 0)]
	[string]$VMName = "amazon-linux01"
)

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
	Write-Output "Invalid VMName '$VMName'. Only alphanumeric characters, dots, hyphens, and underscores are allowed."
	exit 1
}

$global:InformationPreference = "Continue"
$global:DebugPreference = "SilentlyContinue"
$global:VerbosePreference = "SilentlyContinue"
$global:ProgressPreference = "SilentlyContinue"

$commonModulePath = Join-Path -Path $PSScriptRoot -ChildPath "VM.common.psm1"
Import-Module -Name $commonModulePath -Force

# Inform and check for elevation
Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
	Write-Output "Please run this script as Administrator."
	Write-Output "Be careful."
	exit 1
}

# Check if Hyper-V services are installed and running
$hypervFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($hypervFeature.State -ne 'Enabled') {
	Write-Output "Hyper-V is not enabled. Please enable Hyper-V from Windows Features."
	Write-Output "Instructions: https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/quick-start/enable-hyper-v"
	exit 1
}

$service = Get-Service -Name vmms -ErrorAction SilentlyContinue
if (!$service -or $service.Status -ne 'Running') {
	Write-Output "Hyper-V Virtual Machine Management service (vmms) is not running. Please start the service."
	Write-Output "Instructions: https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/quick-start/enable-hyper-v"
	exit 1
}

# Check if VM exists and force delete it
$existingVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($existingVM) {
	Write-Output "VM '$VMName' exists. Deleting..."
	Stop-VM -Name $VMName -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
	Remove-VM -Name $VMName -Force
	Write-Output "VM '$VMName' deleted."
}

# === Seek the base image ===
$downloadDir = (Get-VMHost).VirtualHardDiskPath
$baseImageName = "host.windows.hyper-v.guest.amazon.linux"
$baseImageFile = Join-Path $downloadDir "$baseImageName.vhdx"

Write-Output "Hyper-V default VHDX folder: $downloadDir"
if (!(Test-Path -Path $downloadDir)) {
	Write-Output "The Hyper-V default VHDX folder does not exist: $downloadDir"
	exit 1
}

if (!(Test-Path -Path $baseImageFile)) {
	Write-Output "Base image not found at '$baseImageFile'. Run Get-Image.ps1 first."
	exit 1
}

# === Create copies and files for VM ===

# Copy base image as the VM disk
$vmDir = Join-Path $downloadDir $VMName
if (-not (Test-Path -Path $vmDir)) {
	New-Item -ItemType Directory -Path $vmDir -Force | Out-Null
}
$vhdxFile = Join-Path $vmDir "$VMName.vhdx"
if (!(Test-Path -Path $vhdxFile)) {
	Write-Output "Creating VHDX for '$VMName' by copying base image..."
	Copy-Item -Path $baseImageFile -Destination $vhdxFile -Force
	Write-Output "Copied '$baseImageFile' -> '$vhdxFile'."
} else {
	Write-Output "Target VHDX already exists: $vhdxFile -- leaving as is."
}

$vmConfigDir = Join-Path $PSScriptRoot "vmconfig"
$MetaDataTemplate = Join-Path $vmConfigDir "meta-data"
$UserDataTemplate = Join-Path $vmConfigDir "user-data"

# Generate cloud-init seed ISO
$SeedDir = Join-Path $env:TEMP "seed_$VMName"
if (Test-Path $SeedDir) { Remove-Item -Recurse -Force $SeedDir }
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null

$MetaData = (Get-Content -Raw $MetaDataTemplate) `
	-replace 'HOSTNAME_PLACEHOLDER', $VMName
Set-Content -Path "$SeedDir/meta-data" -Value $MetaData -NoNewline
Copy-Item -Path $UserDataTemplate -Destination "$SeedDir/user-data"

$SeedIso = Join-Path $vmDir "seed.iso"
$VolumeId = "cidata"
CreateIso -SourceDir $SeedDir -OutputFile $SeedIso -VolumeId $VolumeId

# Create and configure Hyper-V VM
Write-Output "Creating new VM '$VMName'..."
New-VM -Name $VMName -Generation 2 -MemoryStartupBytes 16384MB -SwitchName "Default Switch" -VHDPath $vhdxFile | Out-Null
Set-VM -Name $VMName -MemoryStartupBytes 16384MB -MemoryMinimumBytes 16384MB -MemoryMaximumBytes 16384MB -AutomaticCheckpointsEnabled $false | Out-Null
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off | Out-Null
Add-VMDvdDrive -VMName $VMName -Path $SeedIso | Out-Null
$Cores = (Get-CimInstance -ClassName Win32_Processor).NumberOfCores | Measure-Object -Sum
$CoreCount = $Cores.Sum
$vmCores = [math]::Floor($CoreCount / 2)
Set-VMProcessor -VMName $VMName -Count $vmCores | Out-Null

# Set display resolution to 1920x1080.
# WARNING: The test harness OCR is calibrated for 1920x1080.
# Changing this resolution may break automated screen-text detection
# in waitForText sequence steps.
Set-VMVideo -VMName $VMName -HorizontalResolution 1920 -VerticalResolution 1080 -ResolutionType Single

# === Cleanup temporary folders ===
Remove-Item -Recurse -Force $SeedDir -ErrorAction SilentlyContinue

# === Guidance ===
Write-Output "VM '$VMName' created and configured."
