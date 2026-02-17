<#PSScriptInfo
.VERSION 0.3
.GUID 42d9e0f1-a2b3-4c45-d678-9e0f1a2b3c45
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

# Script parameters
param(
	[Parameter(Position = 0)]
	[string]$VMName = "ubuntu-desktop01"
)

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
	Write-Output "Invalid VMName '$VMName'. Only alphanumeric characters, dots, hyphens, and underscores are allowed."
	exit 1
}

$global:InformationPreference = "Continue"
$global:DebugPreference = "SilentlyContinue"
$global:VerbosePreference = "SilentlyContinue"

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
	Stop-VM -Name $VMName -Force -ErrorAction SilentlyContinue
	Remove-VM -Name $VMName -Force
	Write-Output "VM '$VMName' deleted."
}

# Files
$localVhdxPath = (Get-VMHost).VirtualHardDiskPath
Write-Output "Hyper-V default VHDX folder: $localVhdxPath"
if (!(Test-Path -Path $localVhdxPath)) {
	Write-Output "The Hyper-V default VHDX folder does not exist: $localVhdxPath"
	exit 1
}

# Locate downloaded Ubuntu Desktop ISO
$ubuntuIsoFile = Join-Path $localVhdxPath "ubuntu.desktop.amd64.iso"
if (!(Test-Path -Path $ubuntuIsoFile)) {
	Write-Output "Ubuntu Desktop ISO not found at '$ubuntuIsoFile'. Please run Get-Image.ps1 first."
	exit 1
}

# Create blank VHDX for installation (512GB, dynamically expanding)
$vmDir = Join-Path $localVhdxPath $VMName
if (!(Test-Path -Path $vmDir)) {
	New-Item -ItemType Directory -Path $vmDir -Force | Out-Null
}
$vhdxFile = Join-Path $vmDir "$VMName.vhdx"
if (Test-Path -Path $vhdxFile) {
	Remove-Item -Path $vhdxFile -Force
}
Write-Output "Creating 512GB dynamically expanding VHDX..."
New-VHD -Path $vhdxFile -SizeBytes 512GB -Dynamic | Out-Null

# Generate SHA-512 crypt password hash (pure PowerShell, no external dependencies)
$PasswordHash = Get-Sha512CryptHash -Password "password"

# Generate autoinstall seed ISO from vmconfig templates
$vmConfig = Join-Path $PSScriptRoot "vmconfig"
$UserDataTemplate = Join-Path $vmConfig "user-data"
$MetaDataTemplate = Join-Path $vmConfig "meta-data"

# Create temp directory for seed ISO content
$seedTempDir = Join-Path $env:TEMP "seed_$VMName"
if (Test-Path $seedTempDir) { Remove-Item -Recurse -Force $seedTempDir }
New-Item -ItemType Directory -Force -Path $seedTempDir | Out-Null

# Process user-data template with hostname and password hash
$UserData = (Get-Content -Raw $UserDataTemplate) `
	-replace 'HOSTNAME_PLACEHOLDER', $VMName `
	-replace 'HASH_PLACEHOLDER', $PasswordHash
Set-Content -Path "$seedTempDir/user-data" -Value $UserData -NoNewline
$MetaData = (Get-Content -Raw $MetaDataTemplate) `
	-replace 'HOSTNAME_PLACEHOLDER', $VMName
Set-Content -Path "$seedTempDir/meta-data" -Value $MetaData -NoNewline

$seedIsoFile = Join-Path $vmDir "seed.iso"
$VolumeId = "cidata"
CreateIso -SourceDir $seedTempDir -OutputFile $seedIsoFile -VolumeId $VolumeId

# Clean up temp directory
Remove-Item -Recurse -Force $seedTempDir -ErrorAction SilentlyContinue

# Create new Generation 2 Hyper-V VM
Write-Output "Creating new VM '$VMName'..."
New-VM -Name $VMName -Generation 2 -MemoryStartupBytes 16384MB -SwitchName "Default Switch" -VHDPath $vhdxFile | Out-Null
Set-VM -Name $VMName -MemoryStartupBytes 16384MB -MemoryMinimumBytes 16384MB -MemoryMaximumBytes 16384MB | Out-Null
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off | Out-Null

# Add DVD drives for Ubuntu ISO and seed ISO
Add-VMDvdDrive -VMName $VMName -Path $ubuntuIsoFile | Out-Null
Add-VMDvdDrive -VMName $VMName -Path $seedIsoFile | Out-Null

# Set boot order: DVD (Ubuntu ISO) first for installation, then hard drive
$dvdDrive = Get-VMDvdDrive -VMName $VMName | Where-Object { $_.Path -eq $ubuntuIsoFile }
Set-VMFirmware -VMName $VMName -FirstBootDevice $dvdDrive

# Set CPU count to half of host cores
$Cores = (Get-CimInstance -ClassName Win32_Processor).NumberOfCores | Measure-Object -Sum
$CoreCount = $Cores.Sum
$vmCores = [math]::Floor($CoreCount / 2)
Set-VMProcessor -VMName $VMName -Count $vmCores | Out-Null

Write-Output "VM '$VMName' created and configured."
Write-Output "Start the VM from Hyper-V Manager to begin Ubuntu Desktop installation."
Write-Output "The Ubuntu installer will run automatically via autoinstall."
Write-Output "Default credentials - username: ubuntu, password: password (must be changed on first login)"
Write-Output ""
Write-Output "After installation completes, remove the DVD drives:"
Write-Output "  Get-VMDvdDrive -VMName '$VMName' | Remove-VMDvdDrive"
