<#PSScriptInfo
.VERSION 2026.06.30
.GUID 42d9e0f1-a2b3-4c45-d678-9e0f1a2b3c46
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

param(
    [string]$VMName = "windows11-01"
)

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Output "Invalid VMName '$VMName'. Only alphanumeric characters, dots, hyphens, and underscores are allowed."
    exit 1
}

$ProgressPreference = 'SilentlyContinue'

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$commonModulePath = Join-Path -Path (Split-Path -Parent $ScriptDir) -ChildPath "modules/Yuruna.Host.psm1"
Import-Module -Name $commonModulePath -Force

Write-Verbose "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output "Please run this script as Administrator."
    Write-Output "Be careful."
    exit 1
}

# Assert-HyperVEnabled calls dism.exe directly instead of
# Get-WindowsOptionalFeature -- avoids the "Class not registered" COM
# failure on first post-install runs on fresh Windows 11.
if (-not (Assert-HyperVEnabled)) {
    Write-Output "Instructions: https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/quick-start/enable-hyper-v"
    exit 1
}

$downloadDir = (Get-VMHost).VirtualHardDiskPath
if (!(Test-Path -Path $downloadDir)) {
    Write-Output "The Hyper-V default VHDX folder does not exist: $downloadDir"
    exit 1
}

# === Seek the base image ===
# Auto-run Get-Image.ps1 once if the base image is missing; recheck and
# only error out when it's still missing afterward. The Win11 ISO has
# no machine-fetchable URL -- the per-guest Get-Image.ps1 prints manual-
# download instructions in that case, exits non-zero, and the recheck
# below surfaces the actionable next step.
$baseImageName = "host.windows.hyper-v.guest.windows.11"
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"
if (!(Test-Path -Path $baseImageFile)) {
    $getImageScript = Join-Path $PSScriptRoot 'Get-Image.ps1'
    if (Test-Path -LiteralPath $getImageScript) {
        Write-Output "Base image missing: $baseImageFile"
        Write-Output "Auto-running $getImageScript to fetch it..."
        & pwsh -NoProfile -File $getImageScript
        $getImageExit = $LASTEXITCODE
        if ($getImageExit -ne 0) {
            Write-Error "Auto Get-Image.ps1 exited $getImageExit. Cannot create VM."
            exit 1
        }
    }
    if (!(Test-Path -Path $baseImageFile)) {
        Write-Error "Base image not found at '$baseImageFile' after auto Get-Image. Run Get-Image.ps1 manually and follow its instructions."
        exit 1
    }
}

Write-Verbose "Creating VM '$VMName' using image: $baseImageFile"
# Provenance side-channel for operators reading the transcript. Emits
# "Provenance: <url>" when the sidecar is healthy; warns otherwise.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

$existingVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($existingVM) {
    Write-Output "VM '$VMName' exists. Deleting..."
    Hyper-V\Stop-VM -Name $VMName -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    try {
        Hyper-V\Remove-VM -Name $VMName -Force -ErrorAction Stop
    } catch {
        # A half-removed VM (locked vhdx, permission, etc.) would trip
        # the next New-VM call with "already exists" and the outer loop
        # has no signal to recover. Dump live Hyper-V state so the
        # operator can clean orphan disks before retrying.
        $diag = Get-VM -Name $VMName -ErrorAction SilentlyContinue |
            Format-List Name, State, Status, Generation, Path | Out-String
        throw "Hyper-V\Remove-VM failed for '$VMName': $($_.Exception.Message)`nLive Hyper-V state:`n$diag"
    }
    # Hyper-V can return Remove-VM success while leaving a ghost entry;
    # a second Get-VM is the only reliable post-condition.
    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
        throw "Hyper-V\Remove-VM returned success for '$VMName' but Get-VM still finds it; aborting before re-creation."
    }
    Write-Output "VM '$VMName' deleted."
}

# === Create copies and files for VM ===

# 512GB dynamically expanding VHDX
$vmDir = Join-Path $downloadDir $VMName
if (!(Test-Path -Path $vmDir)) {
    New-Item -ItemType Directory -Path $vmDir -Force | Out-Null
}
$vhdxFile = Join-Path $vmDir "$VMName.vhdx"
if (Test-Path -Path $vhdxFile) {
    Remove-Item -Path $vhdxFile -Force
}
Write-Verbose "Creating 512GB dynamically expanding VHDX..."
New-VHD -Path $vhdxFile -SizeBytes 512GB -Dynamic | Out-Null

# Autounattend seed ISO. 4-digit entropy is weak by design (10k cases)
# but enough to defeat the deterministic-path symlink trap: an attacker
# dropping a symlink at %TEMP%\seed_<VMName>\ before New-VM runs can't
# predict the trailing 4 digits per run.
$SeedDir = Join-Path $env:TEMP ("seed_${VMName}_{0:D4}" -f (Get-Random -Maximum 10000))
if (Test-Path -LiteralPath $SeedDir) { Remove-Item -LiteralPath $SeedDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null

$VmConfigDir = Join-Path $ScriptDir "vmconfig"
$AnswerFileTemplate = Join-Path $VmConfigDir "autounattend.xml"
if (-not (Test-Path $AnswerFileTemplate)) {
    Write-Error "autounattend.xml template not found at '$AnswerFileTemplate'."
    exit 1
}

$AnswerFile = (Get-Content -Raw $AnswerFileTemplate) `
    -replace 'COMPUTERNAME_PLACEHOLDER', $VMName
Set-Content -Path "$SeedDir/autounattend.xml" -Value $AnswerFile -NoNewline

$SeedIso = Join-Path $vmDir "seed.iso"
Write-Verbose "Generating seed.iso with autounattend configuration..."
# OEMDRV volume label causes Windows Setup to automatically pick up autounattend.xml
CreateIso -SourceDir $SeedDir -OutputFile $SeedIso -VolumeId "OEMDRV"

# Pick a vSwitch -- prefer Yuruna-External (LAN-bridged) so the install
# VM gets a real LAN IP via DHCP. Default Switch fallback for hosts
# that can't create an External vSwitch. Same pattern as guest.caching-proxy.
$switchName = Get-OrCreateYurunaExternalSwitch
if (-not $switchName) {
    Write-Output "WARNING: External vSwitch unavailable -- falling back to 'Default Switch'."
    $switchName = 'Default Switch'
}

Write-Verbose "Creating new VM '$VMName' on switch '$switchName'..."
Hyper-V\New-VM -Name $VMName -Generation 2 -MemoryStartupBytes 16384MB -SwitchName $switchName -VHDPath $vhdxFile | Out-Null
Set-VM -Name $VMName -MemoryStartupBytes 16384MB -MemoryMinimumBytes 16384MB -MemoryMaximumBytes 16384MB -AutomaticCheckpointsEnabled $false | Out-Null
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false

# Enable Secure Boot with Microsoft Windows certificate (required for Windows 11)
Set-VMFirmware -VMName $VMName -SecureBootTemplate MicrosoftWindows | Out-Null

# Add virtual TPM (required for Windows 11)
Set-VMKeyProtector -VMName $VMName -NewLocalKeyProtector
Enable-VMTPM -VMName $VMName

# Prune stale per-VM ACEs accumulated on this SHARED base image before
# Hyper-V appends this VM's ACE on attach. Without it the file's DACL grows
# unbounded across runs (Hyper-V never revokes on Remove-VM) and eventually
# hits the ~64 KB ACL limit, failing the attach with 0x8007053C ("does not
# have permission to open attachment"). See docs/hyperv-iso-ace-bloat.md.
$prunedAce = Remove-OrphanedVMFileAccess -Path $baseImageFile
if ($prunedAce -gt 0) { Write-Verbose "Pruned $prunedAce stale per-VM ACE(s) from base image before attach." }
Add-VMDvdDrive -VMName $VMName -Path $baseImageFile | Out-Null
Add-VMDvdDrive -VMName $VMName -Path $SeedIso | Out-Null

# Set boot order: DVD (Windows ISO) first for installation, then hard drive
$dvdDrive = Get-VMDvdDrive -VMName $VMName | Where-Object { $_.Path -eq $baseImageFile }
Set-VMFirmware -VMName $VMName -FirstBootDevice $dvdDrive

# --- VM core-count policy: see https://yuruna.link/definition#defining-the-vm-core-count-policy
$hostCores = (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
if ($hostCores -lt 4) {
    Write-Error "Host has $hostCores physical cores; Yuruna requires at least 4. See https://yuruna.link/definition#defining-the-vm-core-count-policy"
    exit 1
}
$vmCores = [math]::Max(4, [math]::Floor($hostCores / 2))
Write-Verbose "Host cores: $hostCores -- assigning $vmCores virtual processors to VM."
Set-VMProcessor -VMName $VMName -Count $vmCores -ExposeVirtualizationExtensions $true | Out-Null

# Enable Guest Service Interface for file copy (Hyper-V Integration Services)
Enable-VMIntegrationService -VMName $VMName -Name "Guest Service Interface"

# WARNING: The test harness OCR is calibrated for 1920x1080.
# Changing this resolution may break automated screen-text detection
# in waitForText sequence steps.
Set-VMVideo -VMName $VMName -HorizontalResolution 1920 -VerticalResolution 1080 -ResolutionType Single

# Disable Enhanced Session so VMConnect uses basic mode (no resolution dialog)
# Note: EnhancedSessionTransportType only accepts VMBus or HvSocket; disable at host level instead.
Set-VMHost -EnableEnhancedSessionMode $false

# === Cleanup temporary folders ===
Remove-Item -LiteralPath $SeedDir -Recurse -Force -ErrorAction SilentlyContinue

# === Guidance ===
Write-Verbose "VM '$VMName' created and configured."
Write-Verbose "The test runner will start the VM, open vmconnect, and send the"
Write-Verbose "'Press any key to boot from CD/DVD' keystroke automatically."
Write-Verbose "To start manually instead:"
Write-Verbose "  Start-VM -Name '$VMName'"
Write-Verbose "  vmconnect.exe localhost '$VMName'"
Write-Verbose "  # Press any key in the vmconnect window within 5 seconds"
Write-Verbose "The Windows installer will run automatically via autounattend.xml."
Write-Verbose "Default credentials - username: ywuser1, password: password (must be changed on first login)"
