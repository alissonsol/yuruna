<#PSScriptInfo
.VERSION 2026.08.23
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

# Honor logLevel from Start-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Error "Invalid VMName '$VMName'."
    exit 1
}
if (-not $IsLinux) {
    Write-Error "host/ubuntu.kvm/guest.windows.11/New-VM.ps1 only runs on Linux."
    exit 1
}

$arch = (& uname -m).Trim()
if ($arch -ne 'x86_64') {
    Write-Error "Windows 11 KVM guest is x86_64-only (this host is $arch)."
    exit 1
}

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- REGION: Seek the base image
# If any required ISO is missing, auto-run the sibling Get-Image.ps1 once
# to try to fetch them, then recheck. Two missing ISOs trigger ONE Get-
# Image run (not two), and a still-missing ISO after the run is a hard
# error that names the path the operator needs to provide manually (the
# Win11 ISO has no machine-fetchable URL -- the per-guest Get-Image.ps1
# prints manual-download instructions in that case).
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

# --- REGION: Create copies and files for VM
$vmDir   = Join-Path $HOME "yuruna/vms/$VMName"
$diskImg = Join-Path $vmDir "$VMName.qcow2"
$autoIso = Join-Path $vmDir 'autounattend.iso'
New-Item -ItemType Directory -Force -Path $vmDir | Out-Null

if (Test-Path -LiteralPath $diskImg) { Remove-Item -Force -LiteralPath $diskImg }
& qemu-img create -f qcow2 $diskImg 64G | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "qemu-img create failed"; exit 1 }

# --- REGION: Render the autounattend.xml + build a CD with it
$autoTemplate = Join-Path $ScriptDir 'vmconfig/autounattend.xml'
if (-not (Test-Path -LiteralPath $autoTemplate)) {
    Write-Error "Template missing: $autoTemplate"
    exit 1
}
# --- REGION: https://yuruna.link/network#defining-yuruna-host-locate-lib
# Coordinates for the first-logon bootstrap. This guest is attached to
# libvirt's `default` NAT network (see --network below), so the address it
# reaches the host at is that network's gateway -- a host-owned constant that
# no DHCP lease can move. A KVM Windows guest is therefore already immune to
# the host renumbering that strands bridged guests, and the resolver seeded
# alongside is inert here by design: it probes, finds the gateway answering,
# and returns without consulting anything. It earns its place the day this
# guest is moved onto a bridged network.
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
    Write-Error "genisoimage (autounattend) failed (exit $LASTEXITCODE)"
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
        Write-Error "OVMF firmware missing at $p (apt install ovmf)."
        exit 1
    }
}
$nvram = Join-Path $vmDir "$VMName.nvram.fd"
if (-not (Test-Path -LiteralPath $nvram)) {
    Copy-Item -Path $ovmfVars -Destination $nvram
}

# --- REGION: Define + start the VM via virt-install
$virshUri = 'qemu:///system'
# Capture stdout+stderr + exit code for each call so an operator
# running with -Verbose sees the per-call outcome. The post-condition
# below catches the actual failure mode; this just preserves forensics
# when something unusual surfaces between the two idempotent ops.
$destroyOut = & virsh --connect $virshUri destroy $VMName 2>&1
Write-Verbose "virsh destroy '$VMName' exit=$LASTEXITCODE output='$($destroyOut -join '; ')'"
# Snapshot metadata, checkpoint metadata and a managed-save image each
# pin the domain: undefine refuses ("cannot delete inactive domain with
# N snapshots") unless asked to drop them, and the re-creation below
# then fails with "domain already defined". A guest workload that takes
# a disk snapshot is routine, so clear every kind of metadata here.
$undefineOut = & virsh --connect $virshUri undefine --nvram --managed-save `
    --snapshots-metadata --checkpoints-metadata $VMName 2>&1
Write-Verbose "virsh undefine '$VMName' exit=$LASTEXITCODE output='$($undefineOut -join '; ')'"
# Post-condition: destroy/undefine on a non-existing domain is harmlessly
# non-zero, but a failure that leaves the domain defined makes the next
# virt-install fail with "domain already defined", and the outer loop has
# no signal to recover. Fail loud now with dominfo so the operator can act.
$stillDefined = & virsh --connect $virshUri list --all --name 2>$null |
    Where-Object { $_.Trim() -eq $VMName }
if ($stillDefined) {
    $dominfo = (& virsh --connect $virshUri dominfo $VMName 2>&1 | Out-String).Trim()
    throw "virsh destroy + undefine left '$VMName' defined; aborting before re-creation.`ndominfo:`n$dominfo"
}

# --- REGION: https://yuruna.link/definition#defining-the-vm-core-count-policy
$hostCores = [int](& nproc --all)
if ($hostCores -lt 4) {
    Write-Error "Host has $hostCores cores; Yuruna requires at least 4. See https://yuruna.link/definition#defining-the-vm-core-count-policy"
    exit 1
}
# Floor-half of the host is the target, clamped so a guest never takes
# every thread of a small host: nproc counts hardware threads, and on a
# 4-thread host an unclamped 4-core floor hands EVERY guest the whole
# machine. At least one thread must stay for the host itself (runner,
# OCR polling, VM management) or a busy sibling guest can deschedule an
# installer's vCPUs for seconds at a time and its console appears
# frozen until the step timeout gives up. Windows 11's documented
# minimum is 2 cores, which the clamp's lower bound preserves.
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
    Write-Error "virt-install failed (exit $LASTEXITCODE)"
    exit 1
}

# --- REGION: Guidance
Write-Verbose "VM '$VMName' created. Setup will run unattended; first boot lands at the desktop user 'ywuser1' (password: password)."
Write-Verbose "Connect with:  virt-viewer --connect $virshUri $VMName"
