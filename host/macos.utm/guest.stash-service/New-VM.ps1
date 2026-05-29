<#PSScriptInfo
.VERSION 2026.05.29
.GUID 42f1b2c3-d4e5-4f67-8901-a2b3c4d5e681
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
    Builds the Yuruna Stash Service VM bundle for macOS UTM.

.DESCRIPTION
    Creates a UTM .utm bundle (QEMU backend with -vnc) that boots the
    arm64 Ubuntu 24.04 LTS cloud image. Cloud-init only brings up the
    VM with the harness yuruna user; daemon install + launch is out
    of scope here and runs as a later automation step.

    See https://yuruna.link/stash-service for the full specification.

.PARAMETER VMName
    Name of the UTM VM. Default: yuruna-stash-service.
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = "yuruna-stash-service"
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
$downloadDir = "$HOME/yuruna/image/stash-service"

$utmPlist = "/Applications/UTM.app/Contents/Info.plist"
if (-not (Test-Path $utmPlist)) {
    Write-Error "UTM not found at /Applications/UTM.app. Install with: brew install --cask utm"
    exit 1
}

# === Seek the base image ===
$baseImageName = "host.macos.utm.guest.stash-service"
$baseImageFile = Join-Path $downloadDir "$baseImageName.raw"
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

Write-Output "Creating VM '$VMName' using image: $baseImageFile"
$_repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

# === Create UTM bundle ===
if (Test-Path -LiteralPath $UtmDir) { Remove-Item -LiteralPath $UtmDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# Copy the pre-built raw cloud image into the bundle as the boot disk.
$DiskImage = "$DataDir/disk.img"
Write-Output "Copying cloud image into bundle as disk.img (APFS clone)..."
& /bin/cp -c $baseImageFile $DiskImage
if ($LASTEXITCODE -ne 0) {
    Write-Warning "/bin/cp -c (APFS clone) failed; falling back to Copy-Item."
    Copy-Item -Path $baseImageFile -Destination $DiskImage
}

# === Generate cloud-init seed ISO ===
$SeedDir = Join-Path $downloadDir "seed_temp/$VMName"
if (Test-Path -LiteralPath $SeedDir) { Remove-Item -LiteralPath $SeedDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null

$VmConfigDir = Join-Path $ScriptDir "vmconfig"
Copy-Item -Path (Join-Path $VmConfigDir "meta-data") -Destination "$SeedDir/meta-data"

# === Yuruna harness SSH key + vault password ===
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Ssh.psm1')       -Force -DisableNameChecking
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Extension.psm1') -Global -Force -Verbose:$false
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error "Get-YurunaSshPublicKey returned empty."; exit 1 }
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$YurunaPassword = Get-Password -Username 'yuruna'
if (-not $YurunaPassword) { Write-Error "Get-Password returned empty for 'yuruna'."; exit 1 }
Write-Output "Password came from authentication mechanism: $_authActiveName"
Write-Output "See configuration at: $(Resolve-ExtensionAreaDir -Area 'authentication')"

$UserData = (Get-Content -Raw (Join-Path $VmConfigDir "user-data")).
    Replace('SSH_AUTHORIZED_KEY_PLACEHOLDER', $SshAuthorizedKey).
    Replace('PASSWORD_PLACEHOLDER', $YurunaPassword)
Set-Content -Path "$SeedDir/user-data" -Value $UserData -NoNewline

$SeedIso = "$DataDir/seed.iso"
Write-Output "Generating seed.iso with cloud-init configuration..."
& hdiutil makehybrid -o "$SeedIso" -joliet -iso -default-volume-name cidata "$SeedDir" 2>&1 | ForEach-Object { Write-Verbose $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to create seed.iso with hdiutil."
    exit 1
}

# === Render config.plist from template ===
$TemplatePath = Join-Path $ScriptDir "config.plist.template"
if (-not (Test-Path $TemplatePath)) {
    Write-Error "Template not found at '$TemplatePath'."
    exit 1
}

$VmUuid  = [guid]::NewGuid().ToString().ToUpper()
$DiskId  = [guid]::NewGuid().ToString().ToUpper()
$SeedId  = [guid]::NewGuid().ToString().ToUpper()
$rng     = [System.Random]::new()

$MacBytes = [byte[]]::new(6)
$rng.NextBytes($MacBytes)
$MacBytes[0] = ($MacBytes[0] -bor 0x02) -band 0xFE  # locally administered unicast
$MacAddress = ($MacBytes | ForEach-Object { $_.ToString("X2") }) -join ":"

Import-Module (Join-Path (Split-Path -Parent $ScriptDir) "modules/Yuruna.Host.psm1") -Force
$VncDisplay = Get-VncDisplayForVm -VMName $VMName

# Bridge interface: resolve from default-route NIC.
$BridgeInterface = $null
try {
    $routeOut = & '/sbin/route' -n get default 2>$null
    foreach ($line in $routeOut) {
        if ($line -match 'interface:\s*(\S+)') { $BridgeInterface = $matches[1]; break }
    }
} catch {
    Write-Verbose "route -n get default failed: $($_.Exception.Message)"
}
if (-not $BridgeInterface) {
    Write-Warning "Could not resolve default-route interface; falling back to 'en0' for VZ bridge."
    $BridgeInterface = 'en0'
}
Write-Output "Bridge interface: $BridgeInterface (stash VM will request DHCP on this LAN)"

# 8 GB RAM, 4 vCPU. Sized for the SCP receive + SQLite metadata writer
# + future in-VM UI.
# --- VM core-count policy: see https://yuruna.link/definition#defining-the-vm-core-count-policy
$hostCores = [int](& /usr/sbin/sysctl -n hw.physicalcpu)
if ($hostCores -lt 4) {
    Write-Error "Host has $hostCores physical cores; Yuruna requires at least 4. See https://yuruna.link/definition#defining-the-vm-core-count-policy"
    exit 1
}
$vmCores = [math]::Max(4, [math]::Floor($hostCores / 2))

$PlistContent = (Get-Content -Raw $TemplatePath) `
    -replace '__VM_NAME__',            $VMName `
    -replace '__VM_UUID__',            $VmUuid `
    -replace '__MAC_ADDRESS__',        $MacAddress `
    -replace '__BRIDGE_INTERFACE__',   $BridgeInterface `
    -replace '__DISK_IDENTIFIER__',    $DiskId `
    -replace '__DISK_IMAGE_NAME__',    'disk.img' `
    -replace '__SEED_IDENTIFIER__',    $SeedId `
    -replace '__SEED_IMAGE_NAME__',    'seed.iso' `
    -replace '__VNC_DISPLAY__',        "$VncDisplay" `
    -replace '__CPU_COUNT__',          "$vmCores" `
    -replace '__MEMORY_SIZE__',        '8192'

Set-Content -Path "$UtmDir/config.plist" -Value $PlistContent

$lintOutput = & plutil -lint "$UtmDir/config.plist" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Generated config.plist failed plist validation: $lintOutput"
    Write-Error "Inspect the file at: $UtmDir/config.plist"
    exit 1
}
Write-Verbose "config.plist validated OK (VNC on 127.0.0.1:$(5900 + $VncDisplay))."

Remove-Item -LiteralPath $SeedDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Output ""
Write-Output "=== stash-service VM bundle created ==="
Write-Output "  Path:      $UtmDir"
Write-Output "  Backend:   QEMU (HVF) with -vnc 127.0.0.1:$VncDisplay (port $(5900 + $VncDisplay))"
Write-Output ""
Write-Output "  Console/SSH login:"
Write-Output "    user:     yuruna"
Write-Output "    password: (in authentication vault under 'yuruna')"
$guidance = @'

Next steps:

  1. Register with UTM:
       open '__UTM_DIR__'    # double-click equivalent

  2. Start the VM and wait 1-3 minutes for cloud-init:
       utmctl start __VM_NAME__

  3. Find the VM's IP. `utmctl ip-address` does NOT work for Apple
     Virtualization VMs (returns "Operation not supported by the
     backend") -- use one of these instead:
     a) Apple's shared-NAT DHCP leases:
          awk -F'[ =]' '/name=__VM_NAME__/{found=1} found && /ip_address/{print $NF; exit}' \
              /var/db/dhcpd_leases
     b) Look in the UTM window console; eth0 prints its IP at the
        login prompt after DHCP.

  4. SSH in (harness key is already authorized):
       ssh yuruna@$ip

Daemon install + launch is a later automation step (see
https://yuruna.link/stash-service).
'@
Write-Output ($guidance.
    Replace('__VM_NAME__', $VMName).
    Replace('__UTM_DIR__', $UtmDir))
