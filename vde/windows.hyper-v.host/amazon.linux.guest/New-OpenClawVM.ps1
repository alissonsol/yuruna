<#PSScriptInfo
.VERSION 0.3
.GUID 42f1a2b3-c4d5-4e67-f890-1a2b3c4d5e67
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

# Script parameters. Default VMName should not be "amazonlinux" (same name as downloaded VHDX).
param(
	[Parameter(Position=0)]
	[string]$VMName = "openclaw01"
)

$global:InformationPreference = "Continue"
$global:DebugPreference = "SilentlyContinue"
$global:VerbosePreference = "SilentlyContinue"

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
$defaultVMName = "amazonlinux"
$defaultVhdxName = "$defaultVMName"
$vhdxName = "$VMName"
$vhdxFile = Join-Path $localVhdxPath "$vhdxName/$vhdxName.vhdx"
$defaultVhdxFile = Join-Path $localVhdxPath "$defaultVhdxName.vhdx"

# If the VMName parameter was provided and differs from the default, ensure the VHDX is a copy
if ($VMName -ne $defaultVMName) {
	if (Test-Path -Path $defaultVhdxFile) {
		if (!(Test-Path -Path $vhdxFile)) {
			Write-Output "Creating VHDX for '$VMName' by copying default VHDX..."
			# Ensure destination folder exists
			$destDir = Split-Path -Path $vhdxFile -Parent
			if ($destDir -and -not (Test-Path -Path $destDir)) {
				New-Item -ItemType Directory -Path $destDir -Force | Out-Null
			}
			Copy-Item -Path $defaultVhdxFile -Destination $vhdxFile -Force
			Write-Output "Copied '$defaultVhdxFile' -> '$vhdxFile'."
		}
		else {
			Write-Output "Target VHDX already exists: $vhdxFile -- leaving as is."
		}
	}
 else {
		Write-Output "Default VHDX not found: $defaultVhdxFile. Cannot create '$vhdxFile'. Please ensure default VHDX exists."
		exit 1
	}
}

if (!(Test-Path -Path $vhdxFile)) {
	Write-Output "The VHDX file does not exist: $vhdxFile"
	Write-Output "Please run the download script first."
	exit 1
}

$seedIsoFile = Join-Path $localVhdxPath "$VMName/seed.iso"
$sourceSeedIsoFile = Join-Path $PSScriptRoot "seed.iso"
if (!(Test-Path -Path $seedIsoFile)) {
	Copy-Item -Path $sourceSeedIsoFile -Destination $seedIsoFile -Force
	Write-Output "Copied '$sourceSeedIsoFile' -> '$seedIsoFile'."
	if (!(Test-Path -Path $seedIsoFile)) {
		Write-Output "Failed to copy '$sourceSeedIsoFile' -> '$seedIsoFile'."
		exit 1
	}
}

# Create new Generation 2 Hyper-V VM
Write-Output "Creating new VM '$VMName'..."
New-VM -Name $VMName -Generation 2 -MemoryStartupBytes 16384MB -SwitchName "Default Switch" -VHDPath $vhdxFile | Out-Null
Set-VM -Name $VMName -MemoryStartupBytes 16384MB -MemoryMinimumBytes 16384MB -MemoryMaximumBytes 16384MB | Out-Null
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off | Out-Null
Add-VMDvdDrive -VMName $VMName -Path $seedIsoFile | Out-Null
$Cores = (Get-CimInstance -ClassName Win32_Processor).NumberOfCores | Measure-Object -Sum
$CoreCount = $Cores.Sum
$vmCores = [math]::Floor($CoreCount / 2)
Set-VMProcessor -VMName $VMName -Count $vmCores | Out-Null
Write-Output "VM '$VMName' created and configured."