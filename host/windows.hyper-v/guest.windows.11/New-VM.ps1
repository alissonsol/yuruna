<#PSScriptInfo
.VERSION 2026.09.12
.GUID 427027e4-02aa-49bd-8f50-95db47263320
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
    [string]$VMName = "windows11-01",
    # Planner-cascaded nested-virtualization request
    # (variables.exposeVirtualizationExtensions). 'true' exposes
    # virtualization extensions to the guest so it can run its own hypervisor
    # (e.g. WSL2 or Hyper-V inside the guest). Default off: ARM64 Hyper-V
    # cannot start a VM with the extensions exposed, and most guests never
    # need them.
    [string]$ExposeVirtualizationExtensions = ''
)

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Output "Invalid VMName '$VMName'. Only alphanumeric characters, dots, hyphens, and underscores are allowed."
    exit 1
}

$ProgressPreference = 'SilentlyContinue'

# --- REGION: Log level from environment
# See https://yuruna.link/42e220c4-0003
# Reuse the caller's log module; a forced reload discards its state.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (-not (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) -and (Test-Path $_logLevelMod)) {
    Import-Module $_logLevelMod -Global
}
if (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) { Use-LogLevelFromEnv }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$commonModulePath = Join-Path -Path (Split-Path -Parent $ScriptDir) -ChildPath "modules/Yuruna.Host.psm1"
Import-Module -Name $commonModulePath -Force

# Get-YurunaGitHubSource: the token that opens a private frameworkUrl/projectUrl.
# The Linux guests get it from New-CloudInitUserData; Windows has no cloud-init,
# so this seed resolves it directly.
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $repoRoot 'automation/Yuruna.GitHubSource.psm1') -Force -DisableNameChecking

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

# Nested virtualization is opt-in and AMD64-only: ARM64 Hyper-V rejects a VM
# with virtualization extensions exposed at start time ("this platform does
# not support nested virtualization"), so an impossible ask fails here,
# before any VM state is created. OSArchitecture rather than
# $env:PROCESSOR_ARCHITECTURE, which reports AMD64 for an x64 pwsh under
# emulation on an ARM64 host.
$exposeVirt = $false
if ($ExposeVirtualizationExtensions) {
    if (-not [bool]::TryParse($ExposeVirtualizationExtensions, [ref]$exposeVirt)) {
        Write-Error "Invalid -ExposeVirtualizationExtensions '$ExposeVirtualizationExtensions': expected 'true' or 'false'."
        exit 1
    }
}
if ($exposeVirt -and [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [System.Runtime.InteropServices.Architecture]::X64) {
    Write-Error "Nested virtualization (exposeVirtualizationExtensions: true) was requested, but Hyper-V supports it only on AMD64 hosts; this host is $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture). Remove the variable or run the sequence on an AMD64 host."
    exit 1
}

# --- REGION: Seek the base image
# Auto-run Get-Image.ps1 once if the base image is missing; recheck and
# only error out when it's still missing afterward. The Win11 ISO has
# no machine-fetchable URL -- the per-guest Get-Image.ps1 prints manual-
# download instructions in that case, exits non-zero, and the recheck
# below surfaces the actionable next step.
$baseImageName = "host.windows.hyper-v.guest.windows.11"
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules/Yuruna.Image.psm1') -Force
if (-not (Assert-YurunaBaseImage -BaseImageFile $baseImageFile -GuestFolder $PSScriptRoot -ManualHint 'Run Get-Image.ps1 manually and follow its instructions.')) { exit 1 }

Write-Verbose "Creating VM '$VMName' using image: $baseImageFile"
# Provenance side-channel for operators reading the transcript. Emits
# "Provenance: <url>" when the sidecar is healthy; warns otherwise.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

# --- REGION: Remove existing VM
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

# --- REGION: Create copies and files for VM
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

# Pick a vSwitch -- prefer Yuruna-External (LAN-bridged) so the install
# VM gets a real LAN IP via DHCP. Default Switch fallback for hosts
# that can't create an External vSwitch. Same pattern as guest.caching-proxy-service.
$switchName = Get-OrCreateYurunaExternalSwitch
if (-not $switchName) {
    $switchName = 'Default Switch'
    if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
        # --- REGION: https://yuruna.link/42e220c4-0004
        # Verify the fallback exists; prefer non-External switches when bridging is unavailable.
        $substituteSwitch = @(Get-VMSwitch -ErrorAction SilentlyContinue) |
            Sort-Object @{ Expression = { $_.SwitchType -eq 'External' } }, Name |
            Select-Object -First 1
        if ($substituteSwitch) {
            $switchName = $substituteSwitch.Name
            Write-Warning "This host has no 'Default Switch'. Attaching to vSwitch '$switchName' instead so VM creation still succeeds."
        }
    }
    Write-Information "External vSwitch unavailable -- the VM is attached to '$switchName' (NAT + DHCP). It gets no LAN-bridged address: the host answers only at that switch's gateway address, and anything on the LAN reaches the guest only through a host port-forwarder."
}

# --- REGION: https://yuruna.link/4220a755-002d
# Seed durable host identity; treat the status address as a hint that may expire during Setup.
$YurunaHostIp = Get-GuestReachableHostIp -SwitchName $switchName
if (-not $YurunaHostIp) { $YurunaHostIp = '' }
Import-Module (Join-Path $repoRoot 'test/modules/Test.Config.psm1') -Global -Force
Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Common.psm1') -Force -DisableNameChecking
$_statusSeed = Get-YurunaStatusServiceSeed -RepoRoot $repoRoot
$YurunaHostPort = $_statusSeed.Port
$YurunaHostId = ''
if ($env:YURUNA_RUNTIME_DIR) {
    $uuidPath = Join-Path $env:YURUNA_RUNTIME_DIR 'host.uuid'
    if (Test-Path -LiteralPath $uuidPath -PathType Leaf) {
        $YurunaHostId = ([string](Get-Content -LiteralPath $uuidPath -Raw -ErrorAction SilentlyContinue)).Trim()
    }
}
$YurunaCacheIp = "$($env:YURUNA_CACHING_PROXY_SERVICE_IP)".Trim()

# The first-logon bootstrap: coordinates, resolver, refresh schedule, then git
# credentials. Shared with the UTM and KVM Windows guests -- the script it
# builds is byte-identical given the same inputs, and only the resolution of
# those inputs above is per-platform.
Import-Module (Join-Path $repoRoot 'automation/Yuruna.GuestSeed.psm1') -Force -DisableNameChecking
$ghSource = Get-YurunaGitHubSource -RepoRoot $repoRoot
$guestBootstrapB64 = New-WindowsGuestBootstrap -RepoRoot $repoRoot `
    -StatusServiceIp $YurunaHostIp -StatusServicePort $YurunaHostPort `
    -HostId $YurunaHostId -CachingProxyIp $YurunaCacheIp -GhToken $ghSource.Token

$AnswerFile = (Get-Content -Raw $AnswerFileTemplate) `
    -replace 'COMPUTERNAME_PLACEHOLDER', $VMName `
    -replace 'GUEST_BOOTSTRAP_B64_PLACEHOLDER', $guestBootstrapB64
Set-Content -Path "$SeedDir/autounattend.xml" -Value $AnswerFile -NoNewline

$SeedIso = Join-Path $vmDir "seed.iso"
Write-Verbose "Generating seed.iso with autounattend configuration..."
# OEMDRV volume label causes Windows Setup to automatically pick up autounattend.xml
CreateIso -SourceDir $SeedDir -OutputFile $SeedIso -VolumeId "OEMDRV"

# --- REGION: Create and configure the Hyper-V VM
Write-Verbose "Creating new VM '$VMName' on switch '$switchName'..."
Hyper-V\New-VM -Name $VMName -Generation 2 -MemoryStartupBytes 12288MB -SwitchName $switchName -VHDPath $vhdxFile | Out-Null

# Deterministic per (host, VM name): a rebuilt guest presents the SAME MAC, so the
# DHCP server returns the SAME lease instead of consuming a new one. Random MACs
# make every rebuild a fresh lease request, which drains a shared pool until guests
# boot with no IPv4 at all. Hyper-V takes bare hex, no separators.
$YurunaGuestMac = Get-YurunaGuestMacAddress -VMName $VMName
Hyper-V\Set-VMNetworkAdapter -VMName $VMName -StaticMacAddress ($YurunaGuestMac -replace ':','')
Write-Verbose "Deterministic guest MAC for '$VMName': $YurunaGuestMac"

Set-VM -Name $VMName -MemoryStartupBytes 12288MB -MemoryMinimumBytes 12288MB -MemoryMaximumBytes 12288MB -AutomaticCheckpointsEnabled $false | Out-Null
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
# have permission to open attachment"). See https://yuruna.link/429f3d06-0093
$prunedAce = Remove-OrphanedVMFileAccess -Path $baseImageFile
if ($prunedAce -gt 0) { Write-Verbose "Pruned $prunedAce stale per-VM ACE(s) from base image before attach." }
Add-VMDvdDrive -VMName $VMName -Path $baseImageFile | Out-Null
Add-VMDvdDrive -VMName $VMName -Path $SeedIso | Out-Null

# Set boot order: DVD (Windows ISO) first for installation, then hard drive
$dvdDrive = Get-VMDvdDrive -VMName $VMName | Where-Object { $_.Path -eq $baseImageFile }
Set-VMFirmware -VMName $VMName -FirstBootDevice $dvdDrive

# --- REGION: https://yuruna.link/42fa6f45-0015
$hostCores = (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
if ($hostCores -lt 4) {
    Write-Error "Host has $hostCores physical cores; Yuruna requires at least 4. See https://yuruna.link/42fa6f45-0015"
    exit 1
}
$vmCores = [math]::Max(4, [math]::Floor($hostCores / 2))
Write-Verbose "Host cores: $hostCores -- assigning $vmCores virtual processors to VM."
# Virtualization extensions only on request (validated in the environment
# checks above): the flag is unsupported on ARM64 hosts and unnecessary for
# guests that run no hypervisor of their own.
$vmProcessorArgs = @{ VMName = $VMName; Count = $vmCores }
if ($exposeVirt) { $vmProcessorArgs.ExposeVirtualizationExtensions = $true }
Set-VMProcessor @vmProcessorArgs | Out-Null

# Enable Guest Service Interface for file copy (Hyper-V Integration Services)
Enable-VMIntegrationService -VMName $VMName -Name "Guest Service Interface"

# WARNING: The test harness OCR is calibrated for 1920x1080.
# Changing this resolution may break automated screen-text detection
# in waitForText sequence steps.
Set-VMVideo -VMName $VMName -HorizontalResolution 1920 -VerticalResolution 1080 -ResolutionType Single

# Disable Enhanced Session so VMConnect uses basic mode (no resolution dialog)
# Note: EnhancedSessionTransportType only accepts VMBus or HvSocket; disable at host level instead.
Set-VMHost -EnableEnhancedSessionMode $false

# --- REGION: Clean up temporary files
Remove-Item -LiteralPath $SeedDir -Recurse -Force -ErrorAction SilentlyContinue

# --- REGION: Guidance
Write-Verbose "VM '$VMName' created and configured."
Write-Verbose "The test runner will start the VM, open vmconnect, and send the"
Write-Verbose "'Press any key to boot from CD/DVD' keystroke automatically."
Write-Verbose "To start manually instead:"
Write-Verbose "  Start-VM -Name '$VMName'"
Write-Verbose "  vmconnect.exe localhost '$VMName'"
Write-Verbose "  # Press any key in the vmconnect window within 5 seconds"
Write-Verbose "The Windows installer will run automatically via autounattend.xml."
Write-Verbose "Default credentials - username: ywuser1, password: password (must be changed on first login)"
