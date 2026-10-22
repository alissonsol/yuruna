<#PSScriptInfo
.VERSION 2026.10.22
.GUID 4209caff-b7ce-46f6-896a-1d6710c120e8
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

# The default VMName must not collide with the base image name.
# AL2023 resolves its dnf proxy at runtime; see https://yuruna.link/42e220c4-0004.
param(
    [Parameter(Position = 0)]
    [string]$VMName = "amazon-linux01",
    # Greppable test user added on top of ec2-user; force-expired by
    # cloud-init chpasswd default so the rotation flow runs.
    [string]$Username = 'yauser1',
    # An empty hostname follows the VM name for host-side lookup.
    [string]$Hostname = ''
)

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_e147c2f7708fdd27' -Arguments @{ vMName = "$VMName" })
    exit 1
}
if ($Hostname -and $Hostname -notmatch '^[a-zA-Z0-9.-]+$') {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_cd82e39650ead9bb' -Arguments @{ hostname = "$Hostname" })
    exit 1
}
$GuestHostname = if ($Hostname) { $Hostname } else { $VMName }

$global:ProgressPreference = "SilentlyContinue"

Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = 'Stop'

# --- REGION: Log level from environment
# See https://yuruna.link/42e220c4-0003
# Reuse the caller's log module; a forced reload discards its state.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (-not (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) -and (Test-Path $_logLevelMod)) {
    Import-Module $_logLevelMod -Global
}
if (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) { Use-LogLevelFromEnv }

$commonModulePath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath "modules/Yuruna.Host.psm1"
Import-Module -Name $commonModulePath -Force

$hostCores = (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
if ($hostCores -lt 4) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_b35de16dca777b44' -Arguments @{ hostCores = "$hostCores" })
    exit 1
}

Write-Verbose "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_73905e18abf967cb')
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_d9fd336c78bc7623')
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
# See https://yuruna.link/42e220c4-0003
# Fetch missing media once; fail if manual-download requirements remain unmet.
$downloadDir = (Get-VMHost).VirtualHardDiskPath
$baseImageName = "host.windows.hyper-v.guest.amazon.linux.2023"
$baseImageFile = Join-Path $downloadDir "$baseImageName.vhdx"

Write-Verbose "Hyper-V default VHDX folder: $downloadDir"
if (!(Test-Path -Path $downloadDir)) {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_84177e952e2487af' -Arguments @{ downloadDir = "$downloadDir" })
    exit 1
}

Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules/Yuruna.Image.psm1') -Force
if (-not (Assert-YurunaBaseImage -BaseImageFile $baseImageFile -GuestFolder $PSScriptRoot)) { exit 1 }

# --- REGION: Base image provenance
# Emit the source URL from a healthy sidecar; warn when provenance is incomplete.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

# --- REGION: Remove existing VM
# See https://yuruna.link/42e220c4-0004
# Runs AFTER the base image is confirmed so a failed image fetch never
# destroys a working VM.
Remove-HyperVGuestDefinition -VMName $VMName -Confirm:$false

# --- REGION: Create copies and files for VM
Write-Verbose "Creating VM '$VMName' using image: $baseImageFile"
$vmDir = Join-Path $downloadDir $VMName
if (-not (Test-Path -Path $vmDir)) {
    New-Item -ItemType Directory -Path $vmDir -Force | Out-Null
}
$vhdxFile = Join-Path $vmDir "$VMName.vhdx"
# --- REGION: Copy base image -> per-VM disk
# Rebuild from the base so cloud-init never inherits a previous guest's state.
Write-Verbose "Creating VHDX for '$VMName' by copying base image..."
Copy-Item -LiteralPath $baseImageFile -Destination $vhdxFile -Force -ErrorAction Stop
Write-Verbose "Copied '$baseImageFile' -> '$vhdxFile'."


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
        Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_9a1ef2a7551102d0' -Arguments @{ f = "$f" })
        exit 1
    }
}
Import-Module (Join-Path $repoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force

# --- REGION: Stage the cloud-init seed directory
# New-YurunaSeedDirectory creates the folder exclusively under a random name,
# so nothing planted at a predictable %TEMP% path is ever reused.
Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Common.psm1') -DisableNameChecking
try {
    $SeedDir = New-YurunaSeedDirectory -VMName $VMName

    $MetaData = (Get-Content -Raw $MetaDataTemplate) `
        -replace 'INSTANCE_ID_PLACEHOLDER', $VMName `
        -replace 'HOSTNAME_PLACEHOLDER', $GuestHostname
    Set-Content -Path "$SeedDir/meta-data" -Value $MetaData -NoNewline

    # --- REGION: Yuruna harness SSH key
    # See https://yuruna.link/42e220c4-0004
    # Seed the shared harness key so guest provisioning and failure diagnostics agree.
    $TestSshModule = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) "test/modules/Test.Ssh.psm1"
    Import-Module $TestSshModule -Force
    $SshAuthorizedKey = Get-YurunaSshPublicKey
    if (-not $SshAuthorizedKey) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_6424990f88c7f7bc' -Arguments @{ testSshModule = "$TestSshModule" }); exit 1 }

    # --- REGION: Vault user password
    # See https://yuruna.link/42e220c4-0004
    # Read the persistent authentication vault; a new cycle must not reset credentials.
    $_repoRootForExt = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.Extension.psm1') -Global -Force -Verbose:$false
    Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    $_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
    $Password = Get-LocalOsPassword -Username $Username
    if (-not $Password) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_a8c8c2c47e517a44' -Arguments @{ username = "$Username" }); exit 1 }
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_762658980a25b8fb' -Arguments @{ authActiveName = "$_authActiveName" })
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_c427eb2402415f42' -Arguments @{ authentication = "$(Resolve-ExtensionAreaDir -Area 'authentication')" })

    # --- REGION: Select the guest network
    # See https://yuruna.link/42e220c4-0004
    # Select the switch before resolving the host address reachable through it.
    $switchName = Resolve-HyperVGuestSwitch

    # --- REGION: Yuruna host coordinates
    # See https://yuruna.link/4220a755-001b
    # Bake the status-service address reachable through the selected guest network.
    $YurunaHostIp = Get-GuestReachableHostIp -SwitchName $switchName
    if (-not $YurunaHostIp) { $YurunaHostIp = '' }
    Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.Config.psm1') -Global -Force
    $_statusSeed = Get-YurunaStatusServiceSeed -RepoRoot (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
    $YurunaHostPort = $_statusSeed.Port

    # --- REGION: Render user-data / meta-data
    # New-CloudInitUserData merges base+overlay, auto-bakes yuruna-retry.sh /
    # fetch-and-execute.sh / yuruna-network.sh from $repoRoot/automation/ as base64
    # write_files entries, then resolves the per-cycle placeholders below.
    $UserData = New-CloudInitUserData `
        -BasePath    $baseUserData `
        -OverlayPath $overlayUserData `
        -RepoRoot    $repoRoot `
        -Replacement @{
            USERNAME_PLACEHOLDER           = $Username
            PLAINTEXT_PASSWORD_PLACEHOLDER = $Password
            SSH_AUTHORIZED_KEY_PLACEHOLDER = $SshAuthorizedKey
            YURUNA_STATUS_SERVICE_IP_PLACEHOLDER     = $YurunaHostIp
            YURUNA_STATUS_SERVICE_PORT_PLACEHOLDER   = $YurunaHostPort
        } -Confirm:$false
    Set-Content -Path "$SeedDir/user-data" -Value $UserData -NoNewline
    # --- REGION: https://yuruna.link/4220a755-000b
    # Amazon Linux preserves cloud-init fallback networking; pin DHCP identity in user-data.

    # --- REGION: Generate cloud-init seed ISO
    $SeedIso = Join-Path $vmDir "seed.iso"
    $VolumeId = "cidata"
    CreateIso -SourceDir $SeedDir -OutputFile $SeedIso -VolumeId $VolumeId

    # --- REGION: Create and configure the Hyper-V VM
    Write-Verbose "Creating new VM '$VMName' on switch '$switchName'..."
    Hyper-V\New-VM -Name $VMName -Generation 2 -MemoryStartupBytes 12288MB -SwitchName $switchName -VHDPath $vhdxFile | Out-Null

    # --- REGION: https://yuruna.link/42e220c4-0004
    # Key the MAC by durable guest identity so rebuilds and VM renames keep the DHCP lease.
    $YurunaGuestMac = Get-YurunaGuestMacAddress -VMName $GuestHostname
    Hyper-V\Set-VMNetworkAdapter -VMName $VMName -StaticMacAddress ($YurunaGuestMac -replace ':','')
    Write-Verbose "Deterministic guest MAC for '$GuestHostname': $YurunaGuestMac"

    Set-VM -Name $VMName -MemoryStartupBytes 12288MB -MemoryMinimumBytes 12288MB -MemoryMaximumBytes 12288MB -AutomaticCheckpointsEnabled $false | Out-Null
    Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false
    Set-VMFirmware -VMName $VMName -EnableSecureBoot Off | Out-Null
    Add-VMDvdDrive -VMName $VMName -Path $SeedIso | Out-Null
    # --- REGION: https://yuruna.link/42fa6f45-0015
    $vmCores = [math]::Max(4, [math]::Floor($hostCores / 2))
    Set-VMProcessor -VMName $VMName -Count $vmCores | Out-Null

    # WARNING: The test harness OCR is calibrated for 1920x1080.
    # Changing this resolution may break automated screen-text detection
    # in waitForText sequence steps.
    Set-VMVideo -VMName $VMName -HorizontalResolution 1920 -VerticalResolution 1080 -ResolutionType Single

    # --- REGION: Clean up temporary files
} finally {
    # The seed holds the guest's admin credentials; it must not outlive this
    # script on any path, an early exit or a throw included.
    Remove-Item -LiteralPath $SeedDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- REGION: Guidance
Write-Verbose "VM '$VMName' created and configured."
