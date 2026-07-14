<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42e0f1a2-b3c4-4d56-e789-0f1a2b3c4d56
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
    [string]$Username = 'yauser1'
)

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Output "Invalid VMName '$VMName'. Only alphanumeric characters, dots, hyphens, and underscores are allowed."
    exit 1
}

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
if (-not (Test-Path $baseImageFile)) {
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
    if (-not (Test-Path $baseImageFile)) {
        Write-Error "Base image not found at '$baseImageFile' after auto Get-Image. Run Get-Image.ps1 manually."
        exit 1
    }
}

Write-Verbose "Creating VM '$VMName' using image: $baseImageFile"
# Provenance side-channel for operators reading the transcript. Emits
# "Provenance: <url>" when the sidecar is healthy; warns otherwise.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

# --- REGION: Create copies and files for VM

if (Test-Path -LiteralPath $UtmDir) { Remove-Item -LiteralPath $UtmDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# Copy qcow2 directly (QEMU backend reads qcow2 natively; no raw conversion
# needed). The base qcow2 sparse-allocates and grows on demand, so a fresh
# clone for each VM costs only a few hundred MB on disk.
$DiskImage = "$DataDir/disk.qcow2"
Write-Verbose "Copying base qcow2 disk image..."
Copy-Item -Path $baseImageFile -Destination $DiskImage
if (-not (Test-Path $DiskImage)) {
    Write-Error "Failed to copy base qcow2 to '$DiskImage'."
    exit 1
}

# Resize to 128GB (thin-provisioned inside qcow2; no host disk usage until
# written by the guest).
Write-Verbose "Resizing disk image to 128GB..."
& qemu-img resize -f qcow2 "$DiskImage" 128G 2>&1 | ForEach-Object { Write-Verbose $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Error "qemu-img resize failed. Install QEMU tools with: brew install qemu"
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
        Write-Error "Template missing: $f"
        exit 1
    }
}
Import-Module (Join-Path $repoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force

$MetaData = (Get-Content -Raw $MetaDataTemplate) `
    -replace 'HOSTNAME_PLACEHOLDER', $VMName

# Test-harness SSH public key, used to drive the VM post-boot.
$TestSshModule = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))) "test/modules/Test.Ssh.psm1"
Import-Module $TestSshModule -Force
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error "Get-YurunaSshPublicKey returned empty. Module path: $TestSshModule"; exit 1 }

# Per-cycle authentication vault password for $Username.
$_repoRootForExt = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))
Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.Extension.psm1') -Global -Force -Verbose:$false
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$Password = Get-LocalOsPassword -Username $Username
if (-not $Password) { Write-Error "Get-LocalOsPassword returned empty for '$Username'."; exit 1 }
Write-Output "Password came from authentication mechanism: $_authActiveName"
Write-Output "See configuration at: $(Resolve-ExtensionAreaDir -Area 'authentication')"

# Yuruna host (status server) IP+port baked into the seed for the dev
# iteration loop. Guest scripts read /etc/yuruna/host.env (written by
# user-data runcmd) to resolve a local URL before falling back to
# GitHub. See Test-YurunaHost.ps1 for the in-guest probe.
Import-Module (Join-Path (Split-Path -Parent $ScriptDir) "modules/Yuruna.Host.psm1") -Force
$YurunaHostIp = Get-GuestReachableHostIp
$YurunaHostPort = '8080'
$YurunaTestConfig = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))) 'test/test.config.yml'
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

Set-Content -Path "$SeedDir/meta-data" -Value $MetaData -NoNewline
Set-Content -Path "$SeedDir/user-data" -Value $UserData -NoNewline

$SeedIso = "$DataDir/seed.iso"
Write-Verbose "Generating seed.iso with cloud-init configuration..."
& hdiutil makehybrid -o "$SeedIso" -joliet -iso -default-volume-name cidata "$SeedDir" 2>&1 | ForEach-Object { Write-Verbose $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to create seed.iso with hdiutil."
    exit 1
}

# --- REGION: config.plist (Apple Virtualization backend)
$TemplatePath = Join-Path $ScriptDir "config.plist.template"
if (-not (Test-Path $TemplatePath)) {
    Write-Error "Template not found at '$TemplatePath'."
    exit 1
}

$VmUuid = [guid]::NewGuid().ToString().ToUpper()
$DiskId = [guid]::NewGuid().ToString().ToUpper()
$SeedId = [guid]::NewGuid().ToString().ToUpper()
$rng = [System.Random]::new()
$MacBytes = [byte[]]::new(6)
$rng.NextBytes($MacBytes)
$MacBytes[0] = ($MacBytes[0] -bor 0x02) -band 0xFE  # locally administered unicast
$MacAddress = ($MacBytes | ForEach-Object { $_.ToString("X2") }) -join ":"

# Per-VM VNC display number (Get-VncDisplayForVm hashes the name into
# 10..89). Get-VncPortForVm in the harness derives the same value from
# $VMName, so the producer (this plist) and the consumers (capture,
# keystrokes) agree without a sidecar file.
$VncDisplay = Get-VncDisplayForVm -VMName $VMName

# --- REGION: https://yuruna.link/definition#defining-the-vm-core-count-policy
$hostCores = [int](& /usr/sbin/sysctl -n hw.physicalcpu)
if ($hostCores -lt 4) {
    Write-Error "Host has $hostCores physical cores; Yuruna requires at least 4. See https://yuruna.link/definition#defining-the-vm-core-count-policy"
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
    -replace '__MEMORY_SIZE__',         '16384'

Set-Content -Path "$UtmDir/config.plist" -Value $PlistContent

# Validate the generated plist is well-formed (matches windows.11/New-VM.ps1).
$lintOutput = & plutil -lint "$UtmDir/config.plist" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Generated config.plist failed plist validation: $lintOutput"
    Write-Error "Inspect the file at: $UtmDir/config.plist"
    exit 1
}
Write-Verbose "config.plist validated OK (VNC on 127.0.0.1:$(5900 + $VncDisplay))."

# --- REGION: Cleanup temporary folders
Remove-Item -LiteralPath $SeedDir -Recurse -Force -ErrorAction SilentlyContinue

# --- REGION: Guidance
Write-Verbose ""
Write-Verbose "VM bundle created: $UtmDir"
Write-Verbose "Backend: QEMU (HVF) with -vnc 127.0.0.1:$VncDisplay (port $(5900 + $VncDisplay))"
Write-Verbose "Drive without focus: the harness picks up VNC automatically (Get-VncScreenshot,"
Write-Verbose "Send-TextVNC, Send-KeyVNC). UTM no longer needs to be raised to inject keystrokes."
Write-Verbose "Double-click '$VMName.utm' on your Desktop to import it into UTM."
Write-Verbose "Cloud-init will configure the VM on first boot."
Write-Verbose "Default credentials - username: $Username, password: <vault-managed> (must be changed on first login). Vault: test/status/extension/authentication/vault.yml"
