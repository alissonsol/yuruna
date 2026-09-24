<#PSScriptInfo
.VERSION 2026.09.24
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

$arch = (& uname -m).Trim()
if ($arch -ne 'x86_64') {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_bf7819296c37a7e0' -Arguments @{ arch = "$arch" })
    exit 1
}

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- REGION: Seek the base image
# See https://yuruna.link/42e220c4-0003
# Run Get-Image once for all missing ISOs, then fail if manual Windows media is still absent.
$downloadDir   = "$HOME/yuruna/image/windows.11"
$baseImageName = "host.ubuntu.kvm.guest.windows.11"
$winIso    = Join-Path $downloadDir "$baseImageName.iso"
$virtioIso = Join-Path $downloadDir 'virtio-win.iso'
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $ScriptDir)) 'modules/Yuruna.Image.psm1') -Force
if (-not (Assert-YurunaBaseImage -BaseImageFile @($winIso, $virtioIso) -GuestFolder $ScriptDir -ArtifactLabel 'Required image(s)' -ManualHint 'Run Get-Image.ps1 manually and follow its instructions.')) { exit 1 }

Write-Verbose "Creating VM '$VMName' using image: $winIso"
# Provenance side-channel for operators reading the transcript. Emits
# "Provenance: <url>" when the sidecar is healthy; warns otherwise.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $winIso

# --- REGION: Remove existing VM
# See https://yuruna.link/42e220c4-0004
$virshUri = 'qemu:///system'
$destroyOut = & virsh --connect $virshUri destroy $VMName 2>&1
Write-Verbose "virsh destroy '$VMName' exit=$LASTEXITCODE output='$($destroyOut -join '; ')'"
# --- REGION: https://yuruna.link/42d69dfa-001e
$undefineOut = & virsh --connect $virshUri undefine --nvram --managed-save `
    --snapshots-metadata --checkpoints-metadata $VMName 2>&1
Write-Verbose "virsh undefine '$VMName' exit=$LASTEXITCODE output='$($undefineOut -join '; ')'"
$domainNames = @(& virsh --connect $virshUri list --all --name 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw (Format-YurunaOperatorMessage -Key 'exceptions.host_d43d0cab95add9be' -Arguments @{ vMName = "$VMName"; join = "$($domainNames -join '; ')" })
}
if ($domainNames | Where-Object { $_.ToString().Trim() -eq $VMName }) {
    $dominfo = (& virsh --connect $virshUri dominfo $VMName 2>&1 | Out-String).Trim()
    throw (Format-YurunaOperatorMessage -Key 'exceptions.host_9174df31c5ee6350' -Arguments @{ vMName = "$VMName"; dominfo = "$dominfo" })
}

# --- REGION: Create copies and files for VM
$vmDir   = Join-Path $HOME "yuruna/vms/$VMName"
$diskImg = Join-Path $vmDir "$VMName.qcow2"
$autoIso = Join-Path $vmDir 'autounattend.iso'
New-Item -ItemType Directory -Force -Path $vmDir | Out-Null

if (Test-Path -LiteralPath $diskImg) { Remove-Item -Force -LiteralPath $diskImg }
& qemu-img create -f qcow2 $diskImg 64G | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_919e5b9a9a611298'); exit 1 }

# --- REGION: Render the autounattend.xml + build a CD with it
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
$_kvmBootstrapB64 = New-WindowsGuestBootstrap -RepoRoot $_kvmRepoRoot `
    -StatusServiceIp $YurunaHostIp -StatusServicePort $YurunaHostPort `
    -GhToken (Get-YurunaGitHubSource -RepoRoot $_kvmRepoRoot).Token

$autoXml = (Get-Content -Raw -LiteralPath $autoTemplate).
    Replace('COMPUTERNAME_PLACEHOLDER', $VMName).
    Replace('GUEST_BOOTSTRAP_B64_PLACEHOLDER', $_kvmBootstrapB64)
$autoSrc = Join-Path $vmDir 'autounattend.src'
New-Item -ItemType Directory -Force -Path $autoSrc | Out-Null
Set-Content -LiteralPath (Join-Path $autoSrc 'autounattend.xml') -Value $autoXml -Encoding utf8BOM -NoNewline

& genisoimage -output $autoIso -volid AUTOUNATTEND -joliet -rock `
    (Join-Path $autoSrc 'autounattend.xml') 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error (Format-YurunaOperatorMessage -Key 'exceptions.host_9aec44ead873e6bc' -Arguments @{ lASTEXITCODE = "$LASTEXITCODE" })
    exit 1
}

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

# --- REGION: Create and configure the libvirt domain (virt-install)
# See https://yuruna.link/42fa6f45-0015
$hostCores = [int](& nproc --all)
if ($hostCores -lt 4) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_243943232cde57ac' -Arguments @{ hostCores = "$hostCores" })
    exit 1
}
# --- REGION: https://yuruna.link/42fa6f45-0015
# Reserve at least one host thread while applying the shared guest core policy.
$vmCores = [math]::Min($hostCores - 1, [math]::Max(2, [math]::Floor($hostCores / 2)))

# Deterministic per (host, VM name): a rebuilt guest presents the SAME MAC, so
# the DHCP server returns the SAME lease instead of consuming a new one. Random
# MACs make every rebuild a fresh lease request, which drains a shared pool until
# guests boot with no IPv4 at all.
$YurunaGuestMac = Get-YurunaGuestMacAddress -VMName $VMName
Write-Verbose "Deterministic guest MAC for '$VMName': $YurunaGuestMac"

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
& virt-install @installArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_385530ac2faec54f' -Arguments @{ lASTEXITCODE = "$LASTEXITCODE" })
    exit 1
}

# --- REGION: Guidance
Write-Verbose "VM '$VMName' created. Setup will run unattended; first boot lands at the desktop user 'ywuser1' (password: password)."
Write-Verbose "Connect with:  virt-viewer --connect $virshUri $VMName"
