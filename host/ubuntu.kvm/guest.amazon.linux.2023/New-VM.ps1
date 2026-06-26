<#PSScriptInfo
.VERSION 2026.06.26
.GUID 42a2b3c4-d5e6-4f78-9012-3a4b5c6d7e97
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
    # No -CachingProxyUrl: AL2023 does not template a dnf proxy into cloud-init
    # (the guest-side placeholder approach was abandoned as unreliable, see
    # feedback_dnf_proxy_via_cloud_init_placeholder), matching the Hyper-V/UTM
    # AL2023 New-VM.ps1. Invoke-PerGuestNewVm only forwards -CachingProxyUrl to
    # scripts that declare it, so omitting it here is contract-safe.
    # Greppable test user added on top of ec2-user; force-expired by
    # cloud-init chpasswd default so the rotation flow runs.
    [string]$Username = 'yauser1'
)

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Error "Invalid VMName '$VMName'."
    exit 1
}
if (-not $IsLinux) {
    Write-Error "host/ubuntu.kvm/guest.amazon.linux.2023/New-VM.ps1 only runs on Linux."
    exit 1
}

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# -- libvirt-qemu search ACL on $HOME (self-heal) --------------------------
# Ubuntu 24.04 cloud images create /home/<user> at mode 0750, which blocks
# the libvirt-qemu user (uid 64055, gid kvm) that runs guest qemu processes
# from traversing $HOME to reach the qcow2 below it. virt-install then
# warns "You will need to grant the 'libvirt-qemu' user search permissions
# for ['/home/<user>']" and errors out with "Cannot access storage file ...
# Permission denied". A traverse-only POSIX ACL is the narrowest fix and
# does not change read/write/listing for any other user. Idempotent --
# safe to run every cycle.
if (Get-Command -Name 'setfacl' -ErrorAction SilentlyContinue) {
    & getent passwd libvirt-qemu *>$null
    if ($LASTEXITCODE -eq 0) {
        & setfacl -m 'u:libvirt-qemu:--x' $HOME 2>$null
    }
}

$arch = (& uname -m).Trim()

$downloadDir   = "$HOME/yuruna/image/amazon.linux.2023"
$baseImageName = "host.ubuntu.kvm.guest.amazon.linux.2023"
$baseImageFile = Join-Path $downloadDir "$baseImageName.qcow2"
# Auto-run Get-Image.ps1 once if the base image is missing; recheck and
# only error out when it's still missing afterward.
if (-not (Test-Path -LiteralPath $baseImageFile)) {
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
    if (-not (Test-Path -LiteralPath $baseImageFile)) {
        Write-Error "Base image missing after auto Get-Image: $baseImageFile. Run Get-Image.ps1 manually."
        exit 1
    }
}

$vmDir   = Join-Path $HOME "yuruna/vms/$VMName"
$diskImg = Join-Path $vmDir "$VMName.qcow2"
$seedImg = Join-Path $vmDir 'seed.iso'
New-Item -ItemType Directory -Force -Path $vmDir | Out-Null

# Single harness key shared with Test.Diagnostic; see the
# guest.ubuntu.server.24/New-VM.ps1 sibling for the why.
$repoRoot      = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))
$TestSshModule = Join-Path $repoRoot 'test/modules/Test.Ssh.psm1'
Import-Module $TestSshModule -Force -DisableNameChecking
$sshPub = Get-YurunaSshPublicKey
if (-not $sshPub) { Write-Error "Get-YurunaSshPublicKey returned empty. Module path: $TestSshModule"; exit 1 }

# Host coordinates + guest network are a topology-aware matched pair: the
# guest attaches to the SAME libvirt network as the caching-proxy
# (Get-ExternalNetwork: bridged 'yuruna-external' when defined, else NAT
# 'default') and reaches the host at an address routable from that network.
# A guest on the NAT 'default' net cannot reach a bridged cache's LAN IP,
# so a mismatch bakes an unreachable host/proxy coordinate. See the sibling
# guest.ubuntu.server.24/New-VM.ps1 for the apt "Network is unreachable"
# failure this prevents.
Import-Module (Join-Path (Split-Path -Parent $ScriptDir) 'modules/Yuruna.Host.psm1') -Force -DisableNameChecking
$guestBinding = Resolve-GuestHostBinding
$networkName  = $guestBinding.NetworkName
$hostIp       = $guestBinding.HostIp
$hostPort = '8080'
$cfg = Join-Path $repoRoot 'test/test.config.yml'
if (Test-Path -LiteralPath $cfg) {
    try {
        $j = Get-Content -Raw -LiteralPath $cfg | ConvertFrom-Yaml -Ordered
        if ($j.statusService.port) { $hostPort = "$($j.statusService.port)" }
    } catch { Write-Verbose "test.config.yml unparseable; using port $hostPort" }
}

# user-data AND meta-data are shared under host/vmconfig/ (the meta-data is
# byte-identical across the three host platforms). Anchor contract:
# automation/Yuruna.CloudInitTemplate.psm1.
$metaDataTemplate = Join-Path $repoRoot 'host/vmconfig/amazon.linux.2023.meta-data'
$hostVmConfigDir  = Join-Path $repoRoot 'host/vmconfig'
$baseUserData     = Join-Path $hostVmConfigDir 'amazon.linux.2023.base.user-data'
$overlayUserData  = Join-Path $hostVmConfigDir 'amazon.linux.2023.kvm.overlay.yml'
foreach ($f in @($baseUserData, $overlayUserData, $metaDataTemplate)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Error "Template missing: $f"
        exit 1
    }
}
Import-Module (Join-Path $repoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force
# Per-cycle authentication vault password for $Username.
Import-Module (Join-Path $repoRoot 'test/modules/Test.Extension.psm1') -Global -Force -Verbose:$false
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$plaintextPassword = Get-LocalOsPassword -Username $Username
if (-not $plaintextPassword) { Write-Error "Get-LocalOsPassword returned empty for '$Username'."; exit 1 }
Write-Output "Password came from authentication mechanism: $_authActiveName"
Write-Output "See configuration at: $(Resolve-ExtensionAreaDir -Area 'authentication')"

# Build-CloudInitUserData merges base+overlay, auto-bakes yuruna-retry.sh /
# fetch-and-execute.sh / yuruna-network.sh from $repoRoot/automation/ as base64
# write_files entries, then resolves the per-cycle placeholders below.
$userData = Build-CloudInitUserData `
    -BasePath    $baseUserData `
    -OverlayPath $overlayUserData `
    -RepoRoot    $repoRoot `
    -Replacement @{
        USERNAME_PLACEHOLDER           = $Username
        PLAINTEXT_PASSWORD_PLACEHOLDER = $plaintextPassword
        SSH_AUTHORIZED_KEY_PLACEHOLDER = $sshPub
        YURUNA_HOST_IP_PLACEHOLDER     = $hostIp
        YURUNA_HOST_PORT_PLACEHOLDER   = $hostPort
    } -Confirm:$false
$metaData = (Get-Content -Raw -LiteralPath $metaDataTemplate).
    Replace('HOSTNAME_PLACEHOLDER', $VMName)

$seedDir = Join-Path $vmDir 'seed.src'
New-Item -ItemType Directory -Force -Path $seedDir | Out-Null
Set-Content -LiteralPath (Join-Path $seedDir 'user-data') -Value $userData -NoNewline
Set-Content -LiteralPath (Join-Path $seedDir 'meta-data') -Value $metaData -NoNewline

& genisoimage -output $seedImg -volid cidata -joliet -rock `
    (Join-Path $seedDir 'user-data') (Join-Path $seedDir 'meta-data') 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "genisoimage failed (exit $LASTEXITCODE)"
    exit 1
}

if (Test-Path -LiteralPath $diskImg) { Remove-Item -Force -LiteralPath $diskImg }
# qemu-img create -b accepts a SIZE smaller than the backing file's virtual
# size, but the resulting overlay only exposes the first SIZE bytes of the
# backing chain to the guest. AL2023's KVM cloud image ships a ~25 GiB
# virtual disk (sparse, so the qcow2 file itself is far smaller), so the
# previous hardcoded 16G silently truncated the rootfs partition and the
# guest stalled at `dracut-initqueue: starting timeout scripts` waiting for
# a device that the kernel could never finish enumerating. Probe the base
# virtual size and pick max(base, 16 GiB) -- preserves the original
# at-least-16G intent without ever shrinking below the backing size.
$baseInfo = (& qemu-img info --output=json -- $baseImageFile | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { Write-Error "qemu-img info on '$baseImageFile' failed"; exit 1 }
$baseVirtualBytes = [int64]$baseInfo.'virtual-size'
$overlayBytes = [int64]16 * 1024 * 1024 * 1024  # 16 GiB minimum
if ($baseVirtualBytes -gt $overlayBytes) { $overlayBytes = $baseVirtualBytes }
& qemu-img create -f qcow2 -F qcow2 -b $baseImageFile $diskImg $overlayBytes | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "qemu-img create failed"; exit 1 }

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

# AL2023 image OS variant; libvirt's osinfo-db ships 'amazonlinux2023'
# on newer libosinfo releases but Ubuntu 24.04's virtinst doesn't pull
# in libosinfo-bin (so osinfo-query is usually absent). Ask virt-install
# itself -- `--osinfo list` enumerates every short-id its loaded osinfo
# library accepts, which is exactly what the upcoming `--os-variant`
# call validates against. Default to the generic 'linux2022' variant
# and opt into 'amazonlinux2023' only when confirmed -- avoids a
# failed virt-install run on hosts whose osinfo-db is too old.
$osVariant = 'linux2022'
$osList = & virt-install --osinfo list 2>$null
if ($LASTEXITCODE -eq 0) {
    # virt-install --osinfo list emits "<canonical-id>, <alias1> <alias2>"
    # per line, NOT one id per line. Parse the canonical id (first
    # whitespace-or-comma-separated token, trailing comma stripped)
    # before equality-checking; otherwise the lookup never matches even
    # when the variant is present.
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

# `--events on_reboot=restart` is explicit even though `--import` (no
# install phase) means virt-install never flips it to `destroy` the way
# `--cdrom` does on guest.ubuntu.server.24. Libvirt's domain default is
# already `restart`, but spelling it out keeps both KVM Linux guests
# symmetric and survives any future virt-install default change. The
# AL2023 boot path doesn't reboot during cloud-init's first run, so this
# only matters for the `sudo reboot now` at the end of
# Test-Start.guest.amazon.linux.2023.json -- with `restart`, QEMU performs
# system_reset rather than exiting, the VNC socket stays alive, and the
# harness's screenshot loop / virt-viewer window survive the reboot.
# --- VM core-count policy: see https://yuruna.link/definition#defining-the-vm-core-count-policy
$hostCores = [int](& nproc --all)
if ($hostCores -lt 4) {
    Write-Error "Host has $hostCores cores; Yuruna requires at least 4. See https://yuruna.link/definition#defining-the-vm-core-count-policy"
    exit 1
}
$vmCores = [math]::Max(4, [math]::Floor($hostCores / 2))

$installArgs = @(
    '--connect', $virshUri,
    '--name',    $VMName,
    '--memory',  '4096',
    '--vcpus',   "$vmCores",
    '--cpu',     'host-passthrough',
    '--os-variant', $osVariant,
    '--disk',    "path=$diskImg,format=qcow2,bus=virtio",
    '--disk',    "path=$seedImg,device=cdrom",
    '--network', "network=$networkName,model=virtio",
    '--graphics','vnc,listen=127.0.0.1',
    '--events',  'on_reboot=restart',
    '--noautoconsole',
    '--import'
)
# --- See https://yuruna.link/memory#why-the-amazonlinux-kvm-guest-uses-seabios-not-uefi
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
    Write-Error "virt-install failed (exit $virtInstallExit)"
    exit 1
}

Write-Verbose "VM '$VMName' created. Get IP via 'virsh -c $virshUri domifaddr $VMName' once cloud-init finishes."
