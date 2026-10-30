<#PSScriptInfo
.VERSION 2026.10.30
.GUID 4210ad59-ce3d-4890-bc1a-eb6a22a42087
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

<#
.SYNOPSIS
    Creates a libvirt VM that installs Windows 11 unattended on KVM/QEMU.

.DESCRIPTION
    Workflow:
      1. Build an autounattend ISO from vmconfig/autounattend.xml. Setup
         scans CD/DVDs at the root for autounattend.xml and consumes it
         automatically -- a separate ISO keeps the install ISO untouched.
      2. Create a fresh 64 G qcow2 disk under ~/yuruna/vms/<vmname>/.
      3. virt-install with three CDs (Windows 11 install, virtio-win
         drivers, autounattend), q35 + UEFI (OVMF) firmware, swtpm 2.0
         emulator, virtio NIC + virtio SCSI disk. The autounattend
         <DriverPaths> picks up the virtio-win bus driver during the
         windowsPE pass so Setup can see the SCSI disk.

    Windows 11 enforces TPM 2.0 + Secure Boot + UEFI; the script wires
    all three. Without swtpm + ovmf the Setup pass fails with "This PC
    can't run Windows 11."
#>

param(
    [string]$VMName = "windows-11-01"
)

Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Globalization.psm1') -DisableNameChecking

# --- REGION: Log level from environment
# See https://yuruna.link/42e220c4-0003
# Reuse the caller's log module; a forced reload discards its state.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (-not (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) -and (Test-Path $_logLevelMod)) {
    Import-Module $_logLevelMod -Global
}
if (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) { Use-LogLevelFromEnv }

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_79ce90e85de037ab' -Arguments @{ vMName = "$VMName" })
    exit 1
}
if (-not $IsLinux) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_9b91b0e58e31c650')
    exit 1
}

# --- REGION: Environment checks
$arch = (& uname -m).Trim()
if ($arch -ne 'x86_64') {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_bf7819296c37a7e0' -Arguments @{ arch = "$arch" })
    exit 1
}

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- REGION: Seek the base image
# See https://yuruna.link/42e220c4-0003
# Fetch missing media once; fail if manual-download requirements remain unmet.
$downloadDir   = "$HOME/yuruna/image/windows.11"
$baseImageName = "host.ubuntu.kvm.guest.windows.11"
$winIso    = Join-Path $downloadDir "$baseImageName.iso"
$virtioIso = Join-Path $downloadDir 'virtio-win.iso'
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $ScriptDir)) 'modules/Yuruna.Image.psm1') -Force
if (-not (Assert-YurunaBaseImage -BaseImageFile @($winIso, $virtioIso) -GuestFolder $ScriptDir -ArtifactLabel 'Required image(s)' -ManualHint 'Run Get-Image.ps1 manually and follow its instructions.')) { exit 1 }

Write-Verbose "Creating VM '$VMName' using image: $winIso"
# --- REGION: Base image provenance
# Emit the source URL from a healthy sidecar; warn when provenance is incomplete.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $winIso

# --- REGION: Remove existing VM
# See https://yuruna.link/42e220c4-0004
# Runs AFTER the base image is confirmed so a failed image fetch never
# destroys a working VM.
Import-Module (Join-Path $PSScriptRoot '../modules/Yuruna.Host.psm1') -DisableNameChecking -Verbose:$false
$virshUri = 'qemu:///system'
Remove-KvmDomainDefinition -VMName $VMName -Confirm:$false

# --- REGION: Create copies and files for VM
$vmDir   = Join-Path $HOME "yuruna/vms/$VMName"
$diskImg = Join-Path $vmDir "$VMName.qcow2"
$autoIso = Join-Path $vmDir 'autounattend.iso'
New-Item -ItemType Directory -Force -Path $vmDir | Out-Null

if (Test-Path -LiteralPath $diskImg) { Remove-Item -Force -LiteralPath $diskImg }
& qemu-img create -f qcow2 $diskImg 64G | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_919e5b9a9a611298'); exit 1 }

# --- REGION: Render the autounattend.xml + build a CD with it
# Autounattend seed ISO: Windows Setup scans all drives for autounattend.xml.
$autoTemplate = Join-Path $ScriptDir 'vmconfig/autounattend.xml'
if (-not (Test-Path -LiteralPath $autoTemplate)) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_b416f0c3ecd65028' -Arguments @{ autoTemplate = "$autoTemplate" })
    exit 1
}
# --- REGION: https://yuruna.link/4220a755-002d
# The NAT gateway is stable; seed the resolver so a future bridged topology can recover.
$_kvmRepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path (Split-Path -Parent $ScriptDir) 'modules/Yuruna.Host.psm1') -Force
Import-Module (Join-Path $_kvmRepoRoot 'automation/Yuruna.GitHubSource.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $_kvmRepoRoot 'automation/Yuruna.GuestSeed.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $_kvmRepoRoot 'test/modules/Test.Config.psm1') -Global -Force
Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Common.psm1') -Force -DisableNameChecking
$YurunaHostIp = Get-GuestReachableHostIp
if (-not $YurunaHostIp) { $YurunaHostIp = '' }
$_statusSeed = Get-YurunaStatusServiceSeed -RepoRoot $_kvmRepoRoot
$YurunaHostPort = $_statusSeed.Port
$ghSource = Get-YurunaGitHubSource -RepoRoot $_kvmRepoRoot
# The answer file and the bootstrap carry the repository token. They are staged
# in a private (0700) workspace beside the disk and published as an owner-only
# image, and the finally below removes the workspace on every exit, a failed
# build included.
Import-Module (Join-Path $_kvmRepoRoot 'host/modules/Yuruna.SeedMedia.psm1') -Force
# A plaintext source an older builder left beside the disk goes first.
Remove-Item -LiteralPath (Join-Path $vmDir 'autounattend.src') -Recurse -Force -ErrorAction SilentlyContinue
$seedWorkspace = $null
try {
    $seedWorkspace = New-SeedMediaWorkspace -ParentPath $vmDir
    $autoSrc = $seedWorkspace.Source
    $_kvmBootstrap = New-WindowsGuestBootstrap -RepoRoot $_kvmRepoRoot `
        -StatusServiceIp $YurunaHostIp -StatusServicePort $YurunaHostPort `
        -GhToken $ghSource.Token `
        -FrameworkUrl $ghSource.FrameworkUrl -ProjectUrl $ghSource.ProjectUrl

    $autoXml = (Get-Content -Raw -LiteralPath $autoTemplate).
        Replace('COMPUTERNAME_PLACEHOLDER', $VMName).
        Replace('GUEST_BOOTSTRAP_B64_PLACEHOLDER', $_kvmBootstrap.EncodedCommand)
    foreach ($seedFile in $_kvmBootstrap.Files.Keys) {
        [IO.File]::WriteAllText((Join-Path $autoSrc $seedFile), $_kvmBootstrap.Files[$seedFile], [Text.UTF8Encoding]::new($true))
    }
    Set-Content -LiteralPath (Join-Path $autoSrc 'autounattend.xml') -Value $autoXml -Encoding utf8BOM -NoNewline

    & genisoimage -output $seedWorkspace.Image -volid AUTOUNATTEND -joliet -rock `
        $autoSrc 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error (Format-YurunaOperatorMessage -Key 'exceptions.host_9aec44ead873e6bc' -Arguments @{ lASTEXITCODE = "$LASTEXITCODE" })
        exit 1
    }
    Publish-SeedMediaImage -Workspace $seedWorkspace -Path $autoIso -Confirm:$false

    # --- REGION: OVMF firmware + variables
    # Ubuntu's `ovmf` package ships the secure-boot-enabled binary at
    # /usr/share/OVMF/OVMF_CODE_4M.secboot.fd plus a 4M VARS template at
    # /usr/share/OVMF/OVMF_VARS_4M.ms.fd (the .ms variant has the Microsoft
    # Secure Boot keys pre-enrolled -- needed because Windows 11 install
    # refuses without an MS-signed bootloader chain).
    $ovmfCode = '/usr/share/OVMF/OVMF_CODE_4M.secboot.fd'
    $ovmfVars = '/usr/share/OVMF/OVMF_VARS_4M.ms.fd'
    foreach ($p in @($ovmfCode, $ovmfVars)) {
        if (-not (Test-Path -LiteralPath $p)) {
            Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_2b90323d7af4844d' -Arguments @{ p = "$p" })
            exit 1
        }
    }
    $nvram = Join-Path $vmDir "$VMName.nvram.fd"
    if (-not (Test-Path -LiteralPath $nvram)) {
        Copy-Item -Path $ovmfVars -Destination $nvram
    }

    # --- REGION: https://yuruna.link/42fa6f45-0015
    $hostCores = [int](& nproc --all)
    if ($hostCores -lt 4) {
        Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_243943232cde57ac' -Arguments @{ hostCores = "$hostCores" })
        exit 1
    }
    # See https://yuruna.link/42fa6f45-0015
    # Reserve at least one host thread while applying the shared guest core policy.
    $vmCores = [math]::Min($hostCores - 1, [math]::Max(2, [math]::Floor($hostCores / 2)))

    # --- REGION: https://yuruna.link/4220a755-000a
    # Key the MAC by VM name so a rebuild presents the same address and keeps its DHCP lease.
    $YurunaGuestMac = Get-YurunaGuestMacAddress -VMName $VMName
    Write-Verbose "Deterministic guest MAC for '$VMName': $YurunaGuestMac"

    # --- REGION: Create and configure the libvirt domain
    $installArgs = @(
        '--connect',     $virshUri,
        '--name',        $VMName,
        '--memory',      '8192',
        '--vcpus',       "$vmCores",
        '--cpu',         'host-passthrough',
        '--os-variant',  'win11',
        '--machine',     'q35',
        '--boot',        "loader=$ovmfCode,loader.readonly=yes,loader.type=pflash,loader.secure=yes,nvram.template=$ovmfVars,nvram=$nvram",
        '--features',    'smm.state=on',
        '--tpm',         'backend.type=emulator,backend.version=2.0,model=tpm-crb',
        '--disk',        "path=$diskImg,format=qcow2,bus=scsi,discard=unmap",
        '--controller',  'scsi,model=virtio-scsi',
        '--cdrom',       $winIso,
        '--disk',        "path=$virtioIso,device=cdrom,bus=sata",
        '--disk',        "path=$autoIso,device=cdrom,bus=sata",
        '--network',     "network=default,model=virtio,mac=$YurunaGuestMac",
        '--graphics',    'vnc,listen=127.0.0.1',
        '--noautoconsole'
    )

    Write-Verbose "virt-install $($installArgs -join ' ')"
    # Bounded like every other libvirt call: a daemon that stops answering is
    # recorded as such for the runner instead of holding the build.
    $installed = Invoke-BoundedNativeCommand -FilePath 'virt-install' -ArgumentList $installArgs -TimeoutSeconds 300
    Get-BoundedNativeOutputLine -Result $installed -IncludeError | ForEach-Object { Write-Information "$_" -InformationAction Continue }
    $virtInstallExit = if (Test-BoundedNativeResultComplete -Result $installed) { $installed.ExitCode } else { -1 }
    if ($virtInstallExit -ne 0) {
        $message = Format-YurunaOperatorMessage -Key 'host.operator_385530ac2faec54f' -Arguments @{ lASTEXITCODE = "$virtInstallExit" }
        Write-YurunaProvisionResult -Kind $(if ($installed.Started -and $virtInstallExit -eq -1) { 'unresponsive' } else { 'tool' }) -Message $message
        Write-Error $message
        exit 1
    }
} finally {
    # --- REGION: Clean up temporary files
    Remove-SeedMediaWorkspace -Workspace $seedWorkspace -Confirm:$false
}

# --- REGION: Guidance
Write-Verbose "VM '$VMName' created. Setup will run unattended; first boot lands at the desktop user 'ywuser1' (password: password)."
Write-Verbose "Connect with:  virt-viewer --connect $virshUri $VMName"
