<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42f81a2e-d65b-4d01-a8b1-3eb5638207d8
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
    [string]$VMName = "amazon-linux01",
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
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_e147c2f7708fdd27' -Arguments @{ vMName = "$VMName" })
    exit 1
}

if ($Hostname -and $Hostname -notmatch '^[a-zA-Z0-9.-]+$') {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_cd82e39650ead9bb' -Arguments @{ hostname = "$Hostname" })
    exit 1
}
$GuestHostname = if ($Hostname) { $Hostname } else { $VMName }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$GuestDir = "$HOME/yuruna/guest.nosync"
New-Item -ItemType Directory -Force -Path $GuestDir | Out-Null
$UtmDir = "$GuestDir/$VMName.utm"
$DataDir = "$UtmDir/Data"
$downloadDir = "$HOME/yuruna/image/amazon.linux.2023"

# --- REGION: Seek the base image
# Auto-run Get-Image.ps1 once if the base image is missing; recheck and
# only error out when it's still missing afterward.
$baseImageName = "host.macos.utm.guest.amazon.linux.2023"
$baseImageFile = Join-Path $downloadDir "$baseImageName.qcow2"
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules/Yuruna.Image.psm1') -Force
if (-not (Assert-YurunaBaseImage -BaseImageFile $baseImageFile -GuestFolder $PSScriptRoot)) { exit 1 }

# --- REGION: Base image provenance
# Emit the source URL from a healthy sidecar; warn when provenance is incomplete.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

# --- REGION: Remove existing VM
Write-Verbose "Creating VM '$VMName' using image: $baseImageFile"
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/Yuruna.Host.psm1') -Force
if (-not (Remove-UtmBundleWithRetry -Path $UtmDir)) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_7565389d0d010c89' -Arguments @{ utmDir = "$UtmDir" })
    exit 1
}
# --- REGION: Create copies and files for VM
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# Copy qcow2 directly (QEMU backend reads qcow2 natively; no raw conversion
# needed). The base qcow2 sparse-allocates and grows on demand, so a fresh
# clone for each VM costs only a few hundred MB on disk.
$DiskImage = "$DataDir/disk.qcow2"
Write-Verbose "Copying base qcow2 disk image..."
Copy-Item -Path $baseImageFile -Destination $DiskImage
if (-not (Test-Path $DiskImage)) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_e543f3b62fe834ce' -Arguments @{ diskImage = "$DiskImage" })
    exit 1
}

# Resize to 128GB (thin-provisioned inside qcow2; no host disk usage until
# written by the guest).
Write-Verbose "Resizing disk image to 128GB..."
& qemu-img resize -f qcow2 "$DiskImage" 128G 2>&1 | ForEach-Object { Write-Verbose $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_d077adca37bbf33b')
    exit 1
}

# --- REGION: Generate cloud-init seed ISO
$SeedDir = Join-Path $downloadDir "seed_temp/$VMName"
if (Test-Path -LiteralPath $SeedDir) { Remove-Item -LiteralPath $SeedDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null

# user-data AND meta-data are shared under host/vmconfig/ (the meta-data is
# byte-identical across the three host platforms). Anchor contract:
# automation/Yuruna.CloudInitTemplate.psm1.
$repoRoot        = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))
$hostVmConfigDir = Join-Path $repoRoot 'host/vmconfig'
$baseUserData    = Join-Path $hostVmConfigDir 'amazon.linux.2023.base.user-data'
$overlayUserData = Join-Path $hostVmConfigDir 'amazon.linux.2023.utm.overlay.yml'
$MetaDataTemplate = Join-Path $hostVmConfigDir 'amazon.linux.2023.meta-data'
foreach ($f in @($baseUserData, $overlayUserData, $MetaDataTemplate)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_9a1ef2a7551102d0' -Arguments @{ f = "$f" })
        exit 1
    }
}
Import-Module (Join-Path $repoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force

$MetaData = (Get-Content -Raw $MetaDataTemplate) `
    -replace 'INSTANCE_ID_PLACEHOLDER', $VMName `
    -replace 'HOSTNAME_PLACEHOLDER', $GuestHostname

# Test-harness SSH public key, used to drive the VM post-boot.
$TestSshModule = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))) "test/modules/Test.Ssh.psm1"
Import-Module $TestSshModule -Force
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_6424990f88c7f7bc' -Arguments @{ testSshModule = "$TestSshModule" }); exit 1 }

# --- REGION: https://yuruna.link/42e220c4-0004
# Read the persistent authentication vault; a new cycle must not reset credentials.
$_repoRootForExt = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))
Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.Extension.psm1') -Global -Force -Verbose:$false
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$Password = Get-LocalOsPassword -Username $Username
if (-not $Password) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_a8c8c2c47e517a44' -Arguments @{ username = "$Username" }); exit 1 }
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_762658980a25b8fb' -Arguments @{ authActiveName = "$_authActiveName" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_c427eb2402415f42' -Arguments @{ authentication = "$(Resolve-ExtensionAreaDir -Area 'authentication')" })

# Yuruna host (status service) IP+port baked into the seed for the dev
# iteration loop. Guest scripts read /etc/yuruna/host.env (written by
# user-data runcmd) to resolve a local URL before falling back to
# GitHub. See Test-YurunaHost.ps1 for the in-guest probe.
Import-Module (Join-Path (Split-Path -Parent $ScriptDir) "modules/Yuruna.Host.psm1") -Force
Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Common.psm1') -Force -DisableNameChecking
$YurunaHostIp = Get-GuestReachableHostIp
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))) 'test/modules/Test.Config.psm1') -Global -Force
$_statusSeed = Get-YurunaStatusServiceSeed -RepoRoot (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir)))
$YurunaHostPort = $_statusSeed.Port

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

Set-Content -Path "$SeedDir/meta-data" -Value $MetaData -NoNewline
Set-Content -Path "$SeedDir/user-data" -Value $UserData -NoNewline
# --- REGION: https://yuruna.link/4220a755-000b
# Amazon Linux preserves cloud-init fallback networking; pin DHCP identity in user-data.

$SeedIso = "$DataDir/seed.iso"
Write-Verbose "Generating seed.iso with cloud-init configuration..."
& hdiutil makehybrid -o "$SeedIso" -joliet -iso -default-volume-name cidata "$SeedDir" 2>&1 | ForEach-Object { Write-Verbose $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_fea701fd46026b88')
    exit 1
}

# --- REGION: Create and configure the UTM bundle (config.plist, QEMU backend)
$TemplatePath = Join-Path $ScriptDir "config.plist.template"
if (-not (Test-Path $TemplatePath)) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_603b5ff75924a72c' -Arguments @{ templatePath = "$TemplatePath" })
    exit 1
}

$VmUuid = [guid]::NewGuid().ToString().ToUpper()
$DiskId = [guid]::NewGuid().ToString().ToUpper()
$SeedId = [guid]::NewGuid().ToString().ToUpper()
# --- REGION: https://yuruna.link/42e220c4-0004
# Key the MAC by durable guest identity so rebuilds and VM renames keep the DHCP lease.
$MacAddress = Get-YurunaGuestMacAddress -VMName $GuestHostname

# Per-VM VNC display number (Get-VncDisplayForVm hashes the name into
# 10..89). Get-VncPortForVm in the harness derives the same value from
# $VMName, so the producer (this plist) and the consumers (capture,
# keystrokes) agree without a sidecar file.
$VncDisplay = Get-VncDisplayForVm -VMName $VMName

# --- REGION: https://yuruna.link/42fa6f45-0015
$hostCores = [int](& /usr/sbin/sysctl -n hw.physicalcpu)
if ($hostCores -lt 4) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_b35de16dca777b44' -Arguments @{ hostCores = "$hostCores" })
    exit 1
}
$vmCores = [math]::Max(4, [math]::Floor($hostCores / 2))

$PlistContent = (Get-Content -Raw $TemplatePath) `
    -replace '__VM_NAME__',             $VMName `
    -replace '__VM_UUID__',             $VmUuid `
    -replace '__MAC_ADDRESS__',         $MacAddress `
    -replace '__DISK_IDENTIFIER__',     $DiskId `
    -replace '__DISK_IMAGE_NAME__',     'disk.qcow2' `
    -replace '__SEED_IDENTIFIER__',     $SeedId `
    -replace '__SEED_IMAGE_NAME__',     'seed.iso' `
    -replace '__VNC_DISPLAY__',         "$VncDisplay" `
    -replace '__CPU_COUNT__',           "$vmCores" `
    -replace '__MEMORY_SIZE__',         '12288'

Set-Content -Path "$UtmDir/config.plist" -Value $PlistContent

$lintOutput = & plutil -lint "$UtmDir/config.plist" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_1f3a41b9c5302d96' -Arguments @{ lintOutput = "$lintOutput" })
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_24e25e0303ffb73b' -Arguments @{ utmDir = "$UtmDir" })
    exit 1
}
Write-Verbose "config.plist validated OK (VNC on 127.0.0.1:$(5900 + $VncDisplay))."

# --- REGION: Clean up temporary files
Remove-Item -LiteralPath $SeedDir -Recurse -Force -ErrorAction SilentlyContinue

# --- REGION: Guidance
Write-Verbose ""
Write-Verbose "VM bundle created: $UtmDir"
Write-Verbose "Backend: QEMU (HVF) with -vnc 127.0.0.1:$VncDisplay (port $(5900 + $VncDisplay))"
Write-Verbose "Drive without focus: the harness picks up VNC automatically (Get-VncScreenshot,"
Write-Verbose "Send-TextVNC, Send-KeyVNC). UTM no longer needs to be raised to inject keystrokes."
Write-Verbose "Double-click '$VMName.utm' in ~/yuruna/guest.nosync/ to import it into UTM."
Write-Verbose "Cloud-init will configure the VM on first boot."
Write-Verbose "Default credentials - username: $Username, password: <vault-managed> (must be changed on first login). Vault: test/status/extension/authentication/vault.yml"
