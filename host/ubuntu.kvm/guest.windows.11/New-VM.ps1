<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42a2b3c4-d5e6-4f78-9012-3a4b5c6d7e99
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

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
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

# --- REGION: Required ISOs
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
$requiredImages = @($winIso, $virtioIso)
$missingImages  = @($requiredImages | Where-Object { -not (Test-Path -LiteralPath $_) })
if ($missingImages.Count -gt 0) {
    $getImageScript = Join-Path $ScriptDir 'Get-Image.ps1'
    if (Test-Path -LiteralPath $getImageScript) {
        Write-Output "Required image(s) missing: $($missingImages -join ', ')"
        Write-Output "Auto-running $getImageScript to fetch them..."
        & pwsh -NoProfile -File $getImageScript
        $getImageExit = $LASTEXITCODE
        if ($getImageExit -ne 0) {
            Write-Error "Auto Get-Image.ps1 exited $getImageExit. Cannot create VM."
            exit 1
        }
        $missingImages = @($requiredImages | Where-Object { -not (Test-Path -LiteralPath $_) })
    }
    if ($missingImages.Count -gt 0) {
        Write-Error "Missing required image(s) after auto Get-Image: $($missingImages -join ', '). Run Get-Image.ps1 manually and follow its instructions."
        exit 1
    }
}

Write-Verbose "Creating VM '$VMName' using image: $winIso"
# Provenance side-channel for operators reading the transcript. Emits
# "Provenance: <url>" when the sidecar is healthy; warns otherwise.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $winIso

# --- REGION: VM directory + new disk
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
$autoXml = (Get-Content -Raw -LiteralPath $autoTemplate).
    Replace('COMPUTERNAME_PLACEHOLDER', $VMName)
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

# --- REGION: Define + start the VM
$virshUri = 'qemu:///system'
# Capture stdout+stderr + exit code for each call so an operator
# running with -Verbose sees the per-call outcome. The post-condition
# below catches the actual failure mode; this just preserves forensics
# when something unusual surfaces between the two idempotent ops.
$destroyOut = & virsh --connect $virshUri destroy $VMName 2>&1
Write-Verbose "virsh destroy '$VMName' exit=$LASTEXITCODE output='$($destroyOut -join '; ')'"
$undefineOut = & virsh --connect $virshUri undefine --nvram $VMName 2>&1
Write-Verbose "virsh undefine '$VMName' exit=$LASTEXITCODE output='$($undefineOut -join '; ')'"
# Post-condition: virsh destroy/undefine on a non-existing domain is
# idempotent (returns non-zero, swallowed by `2>$null`). But if either
# op failed while the domain remains defined, the next virt-install
# fails with "domain already defined" and the outer loop has no signal
# to recover. Fail-loud now with dominfo so the operator can act.
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
$vmCores = [math]::Max(4, [math]::Floor($hostCores / 2))

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
    '--network',     'network=default,model=virtio',
    '--graphics',    'vnc,listen=127.0.0.1',
    '--noautoconsole'
)

Write-Verbose "virt-install $($installArgs -join ' ')"
& virt-install @installArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "virt-install failed (exit $LASTEXITCODE)"
    exit 1
}

Write-Verbose "VM '$VMName' created. Setup will run unattended; first boot lands at the desktop user 'ywuser1' (password: password)."
Write-Verbose "Connect with:  virt-viewer --connect $virshUri $VMName"
