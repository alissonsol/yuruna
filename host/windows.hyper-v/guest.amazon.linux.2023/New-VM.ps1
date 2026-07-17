<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42e9f0a1-b2c3-4d45-e678-9f0a1b2c3d45
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

# Script parameters. Default VMName should not match the base image name.
param(
	[Parameter(Position = 0)]
	[string]$VMName = "amazon-linux01",
	# Greppable test user added on top of ec2-user; force-expired by
	# cloud-init chpasswd default so the rotation flow runs.
	[string]$Username = 'yauser1'
)

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
	Write-Output "Invalid VMName '$VMName'. Only alphanumeric characters, dots, hyphens, and underscores are allowed."
	exit 1
}

$global:ProgressPreference = "SilentlyContinue"

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

$commonModulePath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath "modules/Yuruna.Host.psm1"
Import-Module -Name $commonModulePath -Force

Write-Verbose "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
	Write-Output "Please run this script as Administrator."
	Write-Output "Be careful."
	exit 1
}

# Check Hyper-V. Assert-HyperVEnabled (Yuruna.Host.psm1) calls dism.exe
# directly instead of Get-WindowsOptionalFeature, which avoids the
# "Class not registered" COM failure that breaks the first post-install
# run on a fresh Windows 11 machine.
if (-not (Assert-HyperVEnabled)) {
	Write-Output "Instructions: https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/quick-start/enable-hyper-v"
	exit 1
}

# --- REGION: Seek the base image
$downloadDir = (Get-VMHost).VirtualHardDiskPath
$baseImageName = "host.windows.hyper-v.guest.amazon.linux.2023"
$baseImageFile = Join-Path $downloadDir "$baseImageName.vhdx"

Write-Verbose "Hyper-V default VHDX folder: $downloadDir"
if (!(Test-Path -Path $downloadDir)) {
	Write-Output "The Hyper-V default VHDX folder does not exist: $downloadDir"
	exit 1
}

# Auto-run Get-Image.ps1 once if the base image is missing; recheck and
# only error out when it's still missing afterward.
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
        Write-Error "Base image not found at '$baseImageFile' after auto Get-Image. Run Get-Image.ps1 manually."
        exit 1
    }
}

# --- REGION: Remove existing VM
# Runs AFTER the base image is confirmed so a failed image fetch never
# destroys a working VM.
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

Write-Verbose "Creating VM '$VMName' using image: $baseImageFile"
# Provenance side-channel for operators reading the transcript. Emits
# "Provenance: <url>" when the sidecar is healthy; warns otherwise.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

# --- REGION: Create copies and files for VM

# Copy base image as the VM disk
$vmDir = Join-Path $downloadDir $VMName
if (-not (Test-Path -Path $vmDir)) {
	New-Item -ItemType Directory -Path $vmDir -Force | Out-Null
}
$vhdxFile = Join-Path $vmDir "$VMName.vhdx"
if (!(Test-Path -Path $vhdxFile)) {
	Write-Verbose "Creating VHDX for '$VMName' by copying base image..."
	Copy-Item -Path $baseImageFile -Destination $vhdxFile -Force
	Write-Verbose "Copied '$baseImageFile' -> '$vhdxFile'."
} else {
	Write-Verbose "Target VHDX already exists: $vhdxFile -- leaving as is."
}

# user-data AND meta-data are shared under host/vmconfig/ (the meta-data is
# byte-identical across the three host platforms). Anchor contract:
# automation/Yuruna.CloudInitTemplate.psm1.
$repoRoot        = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$hostVmConfigDir = Join-Path $repoRoot 'host/vmconfig'
$baseUserData    = Join-Path $hostVmConfigDir 'amazon.linux.2023.base.user-data'
$overlayUserData = Join-Path $hostVmConfigDir 'amazon.linux.2023.hyperv.overlay.yml'
$MetaDataTemplate = Join-Path $hostVmConfigDir 'amazon.linux.2023.meta-data'
foreach ($f in @($baseUserData, $overlayUserData, $MetaDataTemplate)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Error "Template missing: $f"
        exit 1
    }
}
Import-Module (Join-Path $repoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force

# --- REGION: Generate cloud-init seed ISO
# 4-digit entropy is weak by design (10k cases) but enough to defeat the
# deterministic-path symlink trap: an attacker dropping a symlink at
# %TEMP%\seed_<VMName>\ before New-VM runs can't predict the trailing 4
# digits per run.
$SeedDir = Join-Path $env:TEMP ("seed_${VMName}_{0:D4}" -f (Get-Random -Maximum 10000))
if (Test-Path -LiteralPath $SeedDir) { Remove-Item -LiteralPath $SeedDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null

$MetaData = (Get-Content -Raw $MetaDataTemplate) `
	-replace 'HOSTNAME_PLACEHOLDER', $VMName
Set-Content -Path "$SeedDir/meta-data" -Value $MetaData -NoNewline

# Load the SSH public key used by the test harness to drive the VM over SSH.
$TestSshModule = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) "test/modules/Test.Ssh.psm1"
Import-Module $TestSshModule -Force
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error "Get-YurunaSshPublicKey returned empty. Module path: $TestSshModule"; exit 1 }

# Per-cycle authentication vault password for $Username (default
# 'yauser1'). cloud-init's chpasswd default 'expire: true' force-expires
# this on first console login, so the test sequence's Current/New/Retype
# rotation runs against the OS prompt.
$_repoRootForExt = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.Extension.psm1') -Global -Force -Verbose:$false
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$Password = Get-LocalOsPassword -Username $Username
if (-not $Password) { Write-Error "Get-LocalOsPassword returned empty for '$Username'."; exit 1 }
Write-Output "Password came from authentication mechanism: $_authActiveName"
Write-Output "See configuration at: $(Resolve-ExtensionAreaDir -Area 'authentication')"

# Pick a vSwitch FIRST -- prefer Yuruna-External (LAN-bridged) so the
# install VM gets a real LAN IP via DHCP and can reach the squid cache
# directly. Default Switch fallback works for hosts that can't create
# an External vSwitch (no LAN, Wi-Fi-only); install proceeds direct
# against Amazon's CDN. The switch choice MUST be resolved before
# Get-GuestReachableHostIp below, because the host IP a guest reaches
# differs by topology: Default Switch -> 172.x.x.x gateway IP;
# External -> host's LAN IP via the bridged NIC.
$switchName = Get-OrCreateYurunaExternalSwitch
if (-not $switchName) {
    Write-Warning "External vSwitch unavailable -- falling back to 'Default Switch'."
    $switchName = 'Default Switch'
}

# Yuruna host (status server) IP+port baked into the seed for the dev
# iteration loop. Guest scripts read /etc/yuruna/host.env (written by
# user-data runcmd) to resolve a local URL before falling back to
# GitHub. Default Switch's host IP changes across host reboots -- see
# Test-YurunaHost.ps1 for the in-guest probe.
$YurunaHostIp = Get-GuestReachableHostIp -SwitchName $switchName
if (-not $YurunaHostIp) { $YurunaHostIp = '' }
$YurunaHostPort = '8080'
$YurunaTestConfig = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/test.config.yml'
if (Test-Path $YurunaTestConfig) {
    try {
        $tc = Get-Content -Raw $YurunaTestConfig | ConvertFrom-Yaml -Ordered
        if ($tc.statusService.port) { $YurunaHostPort = "$($tc.statusService.port)" }
    } catch { Write-Verbose "test.config.yml parse failed: $_" }
}

# Build-CloudInitUserData merges base+overlay, auto-bakes yuruna-retry.sh /
# fetch-and-execute.sh / yuruna-network.sh from $repoRoot/automation/ as base64
# write_files entries, then resolves the per-cycle placeholders below.
$UserData = Build-CloudInitUserData `
    -BasePath    $baseUserData `
    -OverlayPath $overlayUserData `
    -RepoRoot    $repoRoot `
    -Replacement @{
        USERNAME_PLACEHOLDER           = $Username
        PLAINTEXT_PASSWORD_PLACEHOLDER = $Password
        SSH_AUTHORIZED_KEY_PLACEHOLDER = $SshAuthorizedKey
        YURUNA_HOST_IP_PLACEHOLDER     = $YurunaHostIp
        YURUNA_HOST_PORT_PLACEHOLDER   = $YurunaHostPort
    } -Confirm:$false
Set-Content -Path "$SeedDir/user-data" -Value $UserData -NoNewline

$SeedIso = Join-Path $vmDir "seed.iso"
$VolumeId = "cidata"
CreateIso -SourceDir $SeedDir -OutputFile $SeedIso -VolumeId $VolumeId

Write-Verbose "Creating new VM '$VMName' on switch '$switchName'..."
Hyper-V\New-VM -Name $VMName -Generation 2 -MemoryStartupBytes 12288MB -SwitchName $switchName -VHDPath $vhdxFile | Out-Null
Set-VM -Name $VMName -MemoryStartupBytes 12288MB -MemoryMinimumBytes 12288MB -MemoryMaximumBytes 12288MB -AutomaticCheckpointsEnabled $false | Out-Null
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off | Out-Null
Add-VMDvdDrive -VMName $VMName -Path $SeedIso | Out-Null
# --- REGION: https://yuruna.link/definition#defining-the-vm-core-count-policy
$hostCores = (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
if ($hostCores -lt 4) {
    Write-Error "Host has $hostCores physical cores; Yuruna requires at least 4. See https://yuruna.link/definition#defining-the-vm-core-count-policy"
    exit 1
}
$vmCores = [math]::Max(4, [math]::Floor($hostCores / 2))
Set-VMProcessor -VMName $VMName -Count $vmCores | Out-Null

# WARNING: The test harness OCR is calibrated for 1920x1080.
# Changing this resolution may break automated screen-text detection
# in waitForText sequence steps.
Set-VMVideo -VMName $VMName -HorizontalResolution 1920 -VerticalResolution 1080 -ResolutionType Single

# --- REGION: Cleanup temporary folders
Remove-Item -LiteralPath $SeedDir -Recurse -Force -ErrorAction SilentlyContinue

# --- REGION: Guidance
Write-Verbose "VM '$VMName' created and configured."
