<#PSScriptInfo
.VERSION 2026.09.18
.GUID 4264b221-526c-4487-9f9f-8d58b28b11dd
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
    Creates a libvirt VM that boots Amazon Linux 2023 from the AL2023 KVM
    cloud image and provisions itself via cloud-init NoCloud seed.

.DESCRIPTION
    Same shape as guest.ubuntu.server.24/New-VM.ps1 but uses the AL2023 qcow2
    base image; default user is ec2-user (matches AL2023 conventions).
#>

param(
    [string]$VMName = "amazon-linux01",
    # No -CachingProxyServiceUrl: this guest boots a prebuilt cloud image, so a
    # templated dnf proxy is written before anything can confirm the address
    # still answers, and a stale one strands every transaction with no way back.
    # amazon.linux.2023.update.sh derives and probes the address at run time
    # instead, so the cache is still used -- just not through the seed. Matches
    # the Hyper-V/UTM AL2023 New-VM.ps1. Invoke-PerGuestNewVm only forwards
    # -CachingProxyServiceUrl to scripts that declare it, so omitting it here is
    # contract-safe.
    # Greppable test user added on top of ec2-user; force-expired by
    # cloud-init chpasswd default so the rotation flow runs.
    [string]$Username = 'yauser1',
    # cloud-init local-hostname for the guest. Empty means "follow the VM
    # name", which keeps host-side lookups that assume hostname == VM name
    # working for every caller that does not ask for a specific hostname.
    [string]$Hostname = ''
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
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_8be0c49190d15cd0' -Arguments @{ vMName = "$VMName" })
    exit 1
}

if ($Hostname -and $Hostname -notmatch '^[a-zA-Z0-9.-]+$') {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_3127c22c5596f553' -Arguments @{ hostname = "$Hostname" })
    exit 1
}
$GuestHostname = if ($Hostname) { $Hostname } else { $VMName }
if (-not $IsLinux) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_0deceeff2eb90b38')
    exit 1
}

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- REGION: libvirt-qemu search ACL on $HOME
# See https://yuruna.link/42e220c4-0004
# Grant libvirt-qemu traverse-only access to the VM storage below this home directory.
if (Get-Command -Name 'setfacl' -ErrorAction SilentlyContinue) {
    & getent passwd libvirt-qemu *>$null
    if ($LASTEXITCODE -eq 0) {
        & setfacl -m 'u:libvirt-qemu:--x' $HOME 2>$null
    }
}

# --- REGION: Host architecture
$arch = (& uname -m).Trim()

# --- REGION: Seek the base image
$downloadDir   = "$HOME/yuruna/image/amazon.linux.2023"
$baseImageName = "host.ubuntu.kvm.guest.amazon.linux.2023"
$baseImageFile = Join-Path $downloadDir "$baseImageName.qcow2"
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules/Yuruna.Image.psm1') -Force
if (-not (Assert-YurunaBaseImage -BaseImageFile $baseImageFile -GuestFolder $PSScriptRoot)) { exit 1 }

# --- REGION: Base image provenance
# Emit the source URL from a healthy sidecar; warn when provenance is incomplete.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

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
$seedImg = Join-Path $vmDir 'seed.iso'
New-Item -ItemType Directory -Force -Path $vmDir | Out-Null

# --- REGION: Yuruna harness SSH key
# Single harness key shared with Test.Diagnostic; see the
# guest.ubuntu.server.24/New-VM.ps1 sibling for the why.
$repoRoot      = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))
$TestSshModule = Join-Path $repoRoot 'test/modules/Test.Ssh.psm1'
Import-Module $TestSshModule -Force -DisableNameChecking
$sshPub = Get-YurunaSshPublicKey
if (-not $sshPub) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_6424990f88c7f7bc' -Arguments @{ testSshModule = "$TestSshModule" }); exit 1 }

# --- REGION: Yuruna host coordinates
# See https://yuruna.link/42e220c4-0004
# Resolve the guest network and its reachable host address as one pair.
Import-Module (Join-Path (Split-Path -Parent $ScriptDir) 'modules/Yuruna.Host.psm1') -Force -DisableNameChecking
$guestBinding = Resolve-GuestHostBinding
$networkName  = $guestBinding.NetworkName
$hostIp       = $guestBinding.HostIp
Import-Module (Join-Path $repoRoot 'test/modules/Test.Config.psm1') -Global -Force
$_statusSeed = Get-YurunaStatusServiceSeed -RepoRoot $repoRoot
$hostPort = $_statusSeed.Port

# user-data AND meta-data are shared under host/vmconfig/ (the meta-data is
# byte-identical across the three host platforms). Anchor contract:
# automation/Yuruna.CloudInitTemplate.psm1.
$metaDataTemplate = Join-Path $repoRoot 'host/vmconfig/amazon.linux.2023.meta-data'
$hostVmConfigDir  = Join-Path $repoRoot 'host/vmconfig'
$baseUserData     = Join-Path $hostVmConfigDir 'amazon.linux.2023.base.user-data'
$overlayUserData  = Join-Path $hostVmConfigDir 'amazon.linux.2023.kvm.overlay.yml'
foreach ($f in @($baseUserData, $overlayUserData, $metaDataTemplate)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_9a1ef2a7551102d0' -Arguments @{ f = "$f" })
        exit 1
    }
}
Import-Module (Join-Path $repoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force
# Per-cycle authentication vault password for $Username.
Import-Module (Join-Path $repoRoot 'test/modules/Test.Extension.psm1') -Global -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Common.psm1') -Force -DisableNameChecking
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$plaintextPassword = Get-LocalOsPassword -Username $Username
if (-not $plaintextPassword) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_a8c8c2c47e517a44' -Arguments @{ username = "$Username" }); exit 1 }
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_762658980a25b8fb' -Arguments @{ authActiveName = "$_authActiveName" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_c427eb2402415f42' -Arguments @{ authentication = "$(Resolve-ExtensionAreaDir -Area 'authentication')" })

# --- REGION: Render user-data / meta-data
# New-CloudInitUserData merges base+overlay, auto-bakes yuruna-retry.sh /
# fetch-and-execute.sh / yuruna-network.sh from $repoRoot/automation/ as base64
# write_files entries, then resolves the per-cycle placeholders below.
$userData = New-CloudInitUserData `
    -BasePath    $baseUserData `
    -OverlayPath $overlayUserData `
    -RepoRoot    $repoRoot `
    -Replacement @{
        USERNAME_PLACEHOLDER           = $Username
        PLAINTEXT_PASSWORD_PLACEHOLDER = $plaintextPassword
        SSH_AUTHORIZED_KEY_PLACEHOLDER = $sshPub
        YURUNA_STATUS_SERVICE_IP_PLACEHOLDER     = $hostIp
        YURUNA_STATUS_SERVICE_PORT_PLACEHOLDER   = $hostPort
    } -Confirm:$false
$metaData = (Get-Content -Raw -LiteralPath $metaDataTemplate).
    Replace('INSTANCE_ID_PLACEHOLDER', $VMName).Replace('HOSTNAME_PLACEHOLDER', $GuestHostname)

# --- REGION: Generate cloud-init seed ISO
$seedDir = Join-Path $vmDir 'seed.src'
New-Item -ItemType Directory -Force -Path $seedDir | Out-Null
Set-Content -LiteralPath (Join-Path $seedDir 'user-data') -Value $userData -NoNewline
Set-Content -LiteralPath (Join-Path $seedDir 'meta-data') -Value $metaData -NoNewline
# --- REGION: https://yuruna.link/4220a755-000b
# Amazon Linux preserves cloud-init fallback networking; pin DHCP identity in user-data.

& genisoimage -output $seedImg -volid cidata -joliet -rock `
    (Join-Path $seedDir 'user-data') (Join-Path $seedDir 'meta-data') 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_3d53fa1f73f89fed' -Arguments @{ lASTEXITCODE = "$LASTEXITCODE" })
    exit 1
}

# --- REGION: Copy base image -> per-VM disk
# See https://yuruna.link/42e220c4-0004
# Delay destructive replacement until the seed preflight succeeds.
if (Test-Path -LiteralPath $diskImg) { Remove-Item -Force -LiteralPath $diskImg }
# An overlay must never be smaller than its backing disk; retain the 16 GiB floor.
$baseInfo = (& qemu-img info --output=json -- $baseImageFile | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_411b830ef7e4b606' -Arguments @{ baseImageFile = "$baseImageFile" }); exit 1 }
$baseVirtualBytes = [int64]$baseInfo.'virtual-size'
$overlayBytes = [int64]16 * 1024 * 1024 * 1024  # 16 GiB minimum
if ($baseVirtualBytes -gt $overlayBytes) { $overlayBytes = $baseVirtualBytes }
& qemu-img create -f qcow2 -F qcow2 -b $baseImageFile $diskImg $overlayBytes | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_919e5b9a9a611298'); exit 1 }

# --- REGION: https://yuruna.link/42d69dfa-0008
$osVariant = 'linux2022'
$osList = & virt-install --osinfo list 2>$null
if ($LASTEXITCODE -eq 0) {
    $canonicalIds = @($osList | ForEach-Object {
        $first = ("$_".Trim() -split '[\s,]', 2)[0]
        ($first -replace ',$', '').Trim()
    } | Where-Object { $_ })
    if ($canonicalIds -contains 'amazonlinux2023') {
        $osVariant = 'amazonlinux2023'
    } else {
        # Verbose, not Warning: the fallback variant works fine on every
        # host we've seen the message on, so it's noise at Info level.
        Write-Verbose "osinfo-db has no 'amazonlinux2023' entry; using 'linux2022' generic variant."
    }
}

# --- REGION: https://yuruna.link/42e220c4-0004
# Keep guest reboots inside QEMU so the domain and console connection survive.
# --- REGION: https://yuruna.link/42fa6f45-0015
$hostCores = [int](& nproc --all)
if ($hostCores -lt 4) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_243943232cde57ac' -Arguments @{ hostCores = "$hostCores" })
    exit 1
}
# --- REGION: https://yuruna.link/42fa6f45-0015
# Reserve at least one host thread while applying the shared guest core policy.
$vmCores = [math]::Min($hostCores - 1, [math]::Max(2, [math]::Floor($hostCores / 2)))

# --- REGION: https://yuruna.link/42e220c4-0004
# Key the MAC by durable guest identity so rebuilds and VM renames keep the DHCP lease.
$YurunaGuestMac = Get-YurunaGuestMacAddress -VMName $GuestHostname
Write-Verbose "Deterministic guest MAC for '$GuestHostname': $YurunaGuestMac"

# --- REGION: Create and configure the libvirt domain (virt-install)
$installArgs = @(
    '--connect', $virshUri,
    '--name',    $VMName,
    '--memory',  '4096',
    '--vcpus',   "$vmCores",
    '--cpu',     'host-passthrough',
    '--os-variant', $osVariant,
    '--disk',    "path=$diskImg,format=qcow2,bus=virtio",
    '--disk',    "path=$seedImg,device=cdrom",
    '--network', "network=$networkName,model=virtio,mac=$YurunaGuestMac",
    '--graphics','vnc,listen=127.0.0.1',
    '--events',  'on_reboot=restart',
    '--noautoconsole',
    '--import',
    # --- REGION: https://yuruna.link/42e220c4-0004
    # Start-VM must open DHCP capture before the first guest boot.
    '--noreboot'
)
# --- REGION: https://yuruna.link/42d69dfa-0009
if ($arch -eq 'aarch64') {
    $installArgs += @('--boot', 'uefi')
    $installArgs += @('--machine', 'virt')
}

Write-Verbose "virt-install $($installArgs -join ' ')"
# Capture instead of streaming: Yuruna.Host\New-VM re-emits every child
# stdout/stderr line via Write-Information, so virt-install's
# "Starting install... / Creating domain... / Domain creation completed."
# would clutter the cycle log at Info level. The verbose stream is not
# captured by the parent's `2>&1`, so Write-Verbose hides these unless
# the operator re-runs the script directly with -Verbose.
$virtInstallOutput = & virt-install @installArgs 2>&1
$virtInstallExit = $LASTEXITCODE
$virtInstallOutput | ForEach-Object { Write-Verbose "$_" }
if ($virtInstallExit -ne 0) {
    # Surface the captured output on failure so the operator has
    # something to debug from without re-running with -Verbose.
    $virtInstallOutput | ForEach-Object { Write-Output "$_" }
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_d74692e9db12304f' -Arguments @{ virtInstallExit = "$virtInstallExit" })
    exit 1
}

# --- REGION: Clean up temporary files
Remove-Item -LiteralPath $seedDir -Recurse -Force -ErrorAction SilentlyContinue

# --- REGION: Guidance
Write-Verbose "VM '$VMName' defined and left shut off; Start-VM boots it. Get IP via 'virsh -c $virshUri domifaddr $VMName' once cloud-init finishes."
