<#PSScriptInfo
.VERSION 2026.06.05
.GUID 42f4e5f6-a7b8-4c9d-0123-4e5f6a7b8c81
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
    Creates the Yuruna Stash Service VM on Ubuntu KVM (libvirt).

.DESCRIPTION
    Builds a libvirt VM that boots the Ubuntu 24.04 LTS cloud image
    for the stash-service daemon (SCP receiver + SQLite metadata
    store). Cloud-init only brings up the VM with the harness yuruna
    user; daemon install + launch is out of scope here and runs as a
    later automation step.

    See https://yuruna.link/stash-service for the full specification.

.PARAMETER VMName
    libvirt domain name. Default: yuruna-stash-service.
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = 'yuruna-stash-service'
)

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Error "Invalid VMName '$VMName'. Only alphanumerics, dots, hyphens, underscores."
    exit 1
}
if (-not $IsLinux) {
    Write-Error "host/ubuntu.kvm/guest.stash-service/New-VM.ps1 only runs on Linux."
    exit 1
}

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Self-heal libvirt-qemu's search ACL on $HOME (Ubuntu 24.04+ default 0750).
if (Get-Command -Name 'setfacl' -ErrorAction SilentlyContinue) {
    & getent passwd libvirt-qemu *>$null
    if ($LASTEXITCODE -eq 0) {
        & setfacl -m 'u:libvirt-qemu:--x' $HOME 2>$null
    }
}

# === Locate base image ===
$downloadDir   = "$HOME/yuruna/image/stash-service"
$baseImageName = "host.ubuntu.kvm.guest.stash-service"
$baseImageFile = Join-Path $downloadDir "$baseImageName.qcow2"

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
        Write-Error "Base image not found at '$baseImageFile' after auto Get-Image. Run Get-Image.ps1 manually."
        exit 1
    }
}

Write-Output "Creating VM '$VMName' using image: $baseImageFile"
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))
Import-Module (Join-Path $repoRoot 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

# === Per-VM directory + disk ===
$vmDir   = Join-Path $HOME "yuruna/vms/$VMName"
$diskImg = Join-Path $vmDir "$VMName.qcow2"
$seedImg = Join-Path $vmDir 'seed.iso'
New-Item -ItemType Directory -Force -Path $vmDir | Out-Null

# === Tear down any existing domain with the same name ===
$virshUri = 'qemu:///system'
$destroyOut = & virsh --connect $virshUri destroy $VMName 2>&1
Write-Verbose "virsh destroy '$VMName' exit=$LASTEXITCODE output='$($destroyOut -join '; ')'"
$undefineOut = & virsh --connect $virshUri undefine --nvram $VMName 2>&1
Write-Verbose "virsh undefine '$VMName' exit=$LASTEXITCODE output='$($undefineOut -join '; ')'"
$stillDefined = & virsh --connect $virshUri list --all --name 2>$null |
    Where-Object { $_.Trim() -eq $VMName }
if ($stillDefined) {
    $dominfo = (& virsh --connect $virshUri dominfo $VMName 2>&1 | Out-String).Trim()
    throw "virsh destroy + undefine left '$VMName' defined; aborting before re-creation.`ndominfo:`n$dominfo"
}

# === Copy base image -> per-VM disk ===
if (Test-Path -LiteralPath $diskImg) { Remove-Item -Force -LiteralPath $diskImg }
Write-Output "Copying base image to per-VM disk (sparse copy)..."
& /bin/cp --sparse=always -- $baseImageFile $diskImg
if ($LASTEXITCODE -ne 0) {
    Write-Error "cp --sparse=always failed copying $baseImageFile -> $diskImg"
    exit 1
}

# === Yuruna harness SSH key + vault password ===
Import-Module (Join-Path $repoRoot 'test/modules/Test.Ssh.psm1')       -Force -DisableNameChecking
Import-Module (Join-Path $repoRoot 'test/modules/Test.Extension.psm1') -Global -Force -Verbose:$false
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error "Get-YurunaSshPublicKey returned empty."; exit 1 }
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$YurunaPassword = Get-Password -Username 'yuruna'
if (-not $YurunaPassword) { Write-Error "Get-Password returned empty for 'yuruna'."; exit 1 }
Write-Output "Password came from authentication mechanism: $_authActiveName"
Write-Output "See configuration at: $(Resolve-ExtensionAreaDir -Area 'authentication')"

# === Render user-data / meta-data ===
$baseUserData     = Join-Path $repoRoot 'host/vmconfig/stash-service.base.user-data'
$overlayUserData  = Join-Path $repoRoot 'host/vmconfig/stash-service.kvm.overlay.yml'
$metaDataTemplate = Join-Path $ScriptDir 'vmconfig/meta-data'
foreach ($f in @($baseUserData, $overlayUserData, $metaDataTemplate)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Error "Template missing: $f"
        exit 1
    }
}
# Render user-data from the shared base + KVM overlay (host/vmconfig/
# stash-service.*). The overlay is empty (no per-platform divergence today);
# Build-CloudInitUserData resolves the SSH-key and password placeholders.
Import-Module (Join-Path $repoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force
$userData = Build-CloudInitUserData `
    -BasePath    $baseUserData `
    -OverlayPath $overlayUserData `
    -RepoRoot    $repoRoot `
    -Replacement @{
        SSH_AUTHORIZED_KEY_PLACEHOLDER = $SshAuthorizedKey
        PASSWORD_PLACEHOLDER           = $YurunaPassword
    } -Confirm:$false
$metaData = (Get-Content -Raw -LiteralPath $metaDataTemplate)

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

Write-Output ""
Write-Output "== stash-service console/SSH login (available NOW) =="
Write-Output "  user:     yuruna"
Write-Output "  password: (in authentication vault under 'yuruna')"
Write-Output "  If the wait below stalls or fails, open"
Write-Output "    virt-viewer --connect $virshUri $VMName"
Write-Output "  and log in with the credentials above to inspect cloud-init state."
Write-Output ""

# === Pick libvirt network ===
Import-Module (Join-Path (Split-Path -Parent $ScriptDir) 'modules/Yuruna.Host.psm1') -Force -DisableNameChecking
$networkName = Get-ExternalNetwork
if (-not $networkName) {
    Write-Error "No libvirt network defined. Run 'virsh net-start default' to enable the NAT default, or define 'yuruna-external' (see README.md) for LAN-bridged access."
    exit 1
}
if ($networkName -eq 'default') {
    Write-Warning "Using libvirt NAT 'default' network (192.168.122/24). Dock VM is reachable from this host only; LAN peers will not see <vm-ip>:22 directly. Define a bridged 'yuruna-external' libvirt network for LAN exposure."
} else {
    Write-Output "Using libvirt network: $networkName (stash VM will get a LAN-routable IP)"
}

# === virt-install ===
$arch = (& uname -m).Trim()
$osVariant = 'linux2022'
$osList = & virt-install --osinfo list 2>$null
if ($LASTEXITCODE -eq 0) {
    $canonicalIds = @($osList | ForEach-Object {
        $first = ("$_".Trim() -split '[\s,]', 2)[0]
        ($first -replace ',$', '').Trim()
    } | Where-Object { $_ })
    foreach ($candidate in @('ubuntu24.04', 'ubuntu22.04')) {
        if ($canonicalIds -contains $candidate) { $osVariant = $candidate; break }
    }
    if ($osVariant -eq 'linux2022') {
        Write-Verbose "osinfo-db has no 'ubuntu24.04'/'ubuntu22.04' entry; using 'linux2022' generic variant."
    }
}

# 8 GB RAM, 4 vCPU. Sized for the SCP receive + SQLite metadata writer
# + future in-VM UI.
# --- VM core-count policy: see https://yuruna.link/definition#defining-the-vm-core-count-policy
$hostCores = [int](& nproc --all)
if ($hostCores -lt 4) {
    Write-Error "Host has $hostCores cores; Yuruna requires at least 4. See https://yuruna.link/definition#defining-the-vm-core-count-policy"
    exit 1
}
$vmCores = [math]::Max(4, [math]::Floor($hostCores / 2))

$installArgs = @(
    '--connect',    $virshUri,
    '--name',       $VMName,
    '--memory',     '8192',
    '--vcpus',      "$vmCores",
    '--cpu',        'host-passthrough',
    '--os-variant', $osVariant,
    '--disk',       "path=$diskImg,format=qcow2,bus=virtio",
    '--disk',       "path=$seedImg,device=cdrom",
    '--network',    "network=$networkName,model=virtio",
    '--graphics',   'vnc,listen=127.0.0.1',
    '--channel',    'unix,target_type=virtio,name=org.qemu.guest_agent.0',
    '--events',     'on_reboot=restart',
    '--noautoconsole',
    '--import'
)
if ($arch -eq 'aarch64') {
    $installArgs += @('--machine', 'virt', '--boot', 'uefi')
}

Write-Verbose "virt-install $($installArgs -join ' ')"
$virtInstallOutput = & virt-install @installArgs 2>&1
$virtInstallExit = $LASTEXITCODE
$virtInstallOutput | ForEach-Object { Write-Verbose "$_" }
if ($virtInstallExit -ne 0) {
    $virtInstallOutput | ForEach-Object { Write-Output "$_" }
    Write-Error "virt-install failed (exit $virtInstallExit)"
    exit 1
}

Remove-Item -LiteralPath $seedDir -Recurse -Force -ErrorAction SilentlyContinue

# === Wait for VM IP ===
Write-Output "Waiting for VM to obtain an IP address..."
Write-Output "  (cloud-init brings up networking; first boot can take 1-3 minutes)"

$dockIp = $null
$maxIterations = 120  # 120 * 5s = 10 minutes
$startTime = Get-Date
$baselineSizeMB = [math]::Round((Get-Item $diskImg).Length / 1MB, 0)
# Plain Write-Output progress -- see feedback_pwsh_linux_write_progress_setcursor.md
# for why we don't use Write-Progress on pwsh-on-Linux.

for ($i = 0; $i -lt $maxIterations; $i++) {
    $dockIp = Get-VMIp -VMName $VMName
    if ($dockIp) { break }
    Start-Sleep -Seconds 5

    if (($i % 6) -eq 5) {
        $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
        $sizeMB  = [math]::Round((Get-Item $diskImg).Length / 1MB, 0)
        $deltaMB = $sizeMB - $baselineSizeMB
        $min     = [int][math]::Floor($elapsed / 60)
        $sec     = [int]($elapsed % 60)
        $totalMin = [int][math]::Floor($maxIterations * 5 / 60)
        Write-Output ("  [{0:D2}m{1:D2}s / {2}m] still waiting for IP -- qcow2 {3} MB (+{4} MB since boot)" -f $min, $sec, $totalMin, $sizeMB, $deltaMB)
    }
}

if (-not $dockIp) {
    Write-Error @"

stash-service VM '$VMName' did not obtain an IP address within 10 minutes.
Accessing the VM for debugging:
  * Console:  virt-viewer --connect $virshUri $VMName
              user: yuruna  (password in authentication vault)
"@
    exit 1
}

Write-Output ""
Write-Output "== stash-service VM is READY =="
Write-Output "  VM:       $VMName"
Write-Output "  IP:       $dockIp"
Write-Output "  Network:  $networkName"
Write-Output "  SSH:      ssh yuruna@$dockIp  (harness key authorized)"
Write-Output "  Console:  virt-viewer --connect $virshUri $VMName"
Write-Output ""
Write-Output "Daemon install + launch is a later automation step (see"
Write-Output "https://yuruna.link/stash-service)."
exit 0
