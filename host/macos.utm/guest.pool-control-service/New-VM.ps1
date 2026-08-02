<#PSScriptInfo
.VERSION 2026.08.02
.GUID 42a3c4d5-f6a7-4c89-0123-d4e5f6a7b8c3
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
    Builds the Yuruna pool-control service VM bundle for macOS UTM.

.DESCRIPTION
    Creates a UTM .utm bundle (QEMU backend with -vnc) that boots the
    arm64 Ubuntu 26.04 LTS cloud image. Cloud-init fetches the framework
    and runs the bring-up script which builds the pool-control-service daemon,
    installs pwsh + the pool-admin CLIs, CIFS-mounts the pool NAS for its
    state dir, and launches it under systemd.

    See https://yuruna.link/pool-control-service for the full specification.

.PARAMETER VMName
    Name of the UTM VM. Default: yuruna-pool-control-service.
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = "yuruna-pool-control-service"
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
# Per-service scratch dir (cloud-init seed staging). The base image itself is
# shared with the other extension services and lives elsewhere.
$downloadDir = "$HOME/yuruna/image/pool-control-service"

$utmPlist = "/Applications/UTM.app/Contents/Info.plist"
if (-not (Test-Path $utmPlist)) {
    Write-Error "UTM not found at /Applications/UTM.app. Install with: brew install --cask utm"
    exit 1
}

# --- REGION: Seek the base image
# One cloud image backs every extension service on this host; this VM grows
# its own copy below (host/modules/Yuruna.Image.psm1).
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules/Yuruna.Image.psm1') -Force
$baseImageFile = (Get-UbuntuExtensionImageInfo -HostType 'macos.utm').BaseImageFile
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

# --- REGION: Create copies and files for VM
if (Test-Path -LiteralPath $UtmDir) { Remove-Item -LiteralPath $UtmDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# --- REGION: Copy base image -> per-VM disk
# Copy the pre-built qcow2 cloud image into the bundle as the boot disk.
# qcow2 (not raw) is deliberate: UTM's QEMU backend boots it directly and
# it sidesteps the macOS F_PUNCHHOLE-alignment EINVAL a raw disk hits
# under UTM's discard=unmap,detect-zeroes=unmap -- see
# feedback_macos-qemu-punchhole-alignment.md.
$DiskImage = "$DataDir/disk.qcow2"
Write-Output "Copying cloud image into bundle as disk.qcow2 (APFS clone)..."
& /bin/cp -c $baseImageFile $DiskImage
if ($LASTEXITCODE -ne 0) {
    Write-Warning "/bin/cp -c (APFS clone) failed; falling back to Copy-Item."
    Copy-Item -Path $baseImageFile -Destination $DiskImage
}

# --- REGION: Grow the per-VM disk to 256 GB
# Apparent size only: qcow2 grows on write, so the host gives up nothing
# until the pool-control daemon actually stores that much.
if (-not (Expand-ExtensionVmDisk -Path $DiskImage -SizeBytes 256GB -Format 'qcow2')) {
    Write-Warning "Resize failed -- continuing with the base cloud-image capacity."
    Write-Warning "Resize manually with: qemu-img resize -f qcow2 '$DiskImage' 256G"
}

# --- REGION: Generate cloud-init seed ISO
$SeedDir = Join-Path $downloadDir "seed_temp/$VMName"
if (Test-Path -LiteralPath $SeedDir) { Remove-Item -LiteralPath $SeedDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null

# meta-data is shared under host/vmconfig/ (byte-identical across all 3 host platforms).
$hostVmConfigDir = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))) 'host/vmconfig'
Copy-Item -Path (Join-Path $hostVmConfigDir 'pool-control-service.meta-data') -Destination "$SeedDir/meta-data"

# --- REGION: Yuruna harness SSH key + vault password
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Ssh.psm1')       -Force -DisableNameChecking
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Extension.psm1') -Global -Force -Verbose:$false
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error "Get-YurunaSshPublicKey returned empty."; exit 1 }
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$AdminPassword = Get-Password -Username 'pool-control-service-admin'
if (-not $AdminPassword) { Write-Error "Get-Password returned empty for 'pool-control-service-admin'."; exit 1 }
Write-Output "Password came from authentication mechanism: $_authActiveName"
Write-Output "See configuration at: $(Resolve-ExtensionAreaDir -Area 'authentication')"

# Host coordinates (status service, for the in-VM source fetch) + pool storage
# coordinates (the NAS), baked into the seed. The network mode and the host
# address are a matched pair -- the address only works from the network the VM
# lands on -- so Resolve-UtmNetworkMode decides once here and the config.plist
# below is rendered from that same value.
# $env:YURUNA_GUEST_REACHABLE_HOST_IP overrides.
Import-Module (Join-Path (Split-Path -Parent $ScriptDir) 'modules/Yuruna.Host.psm1') -Force
Import-Module (Join-Path $_repoRoot 'test/modules/Test.PoolStorage.psm1')  -Global -Force
Import-Module (Join-Path $_repoRoot 'test/modules/Test.YurunaDir.psm1')    -Global -Force
Import-Module (Join-Path $_repoRoot 'test/modules/Test.Config.psm1')       -Global -Force
Import-Module (Join-Path $_repoRoot 'test/modules/Test.CachingProxyService.psm1') -Global -Force
$NetworkMode = Resolve-UtmNetworkMode
if ($env:YURUNA_GUEST_REACHABLE_HOST_IP) {
    $YurunaHostIp = $env:YURUNA_GUEST_REACHABLE_HOST_IP
} else {
    $YurunaHostIp = Get-GuestReachableHostIp -NetworkMode $NetworkMode
}
if (-not $YurunaHostIp) { $YurunaHostIp = '' }
$YurunaHostPort = '8080'
$YurunaTestConfig = Join-Path $_repoRoot 'test/test.config.yml'
$tc = $null
if (Test-Path -LiteralPath $YurunaTestConfig) {
    try { $tc = Read-TestConfig -Path $YurunaTestConfig } catch { Write-Verbose "test.config.yml read: $($_.Exception.Message)" }
    if ($tc -and $tc.statusService -and $tc.statusService.port) { $YurunaHostPort = "$($tc.statusService.port)" }
}
$poolNas = Get-YurunaPoolSeedValue -Config $tc -GuestReachableAddress $YurunaHostIp
# Pool-aggregator service base URL for the daemon's presence beacon + remote-host
# resolution; '' (no caching-proxy service known) leaves those features off in-guest.
# Wait for the aggregator BEFORE resolving: whatever is resolved here is baked
# into the seed once and never re-resolved in-guest, so an empty value taken
# while the aggregator is still compiling leaves the beacon permanently off --
# the service serves correctly and simply never appears on the dashboard.
# Returns $false (rather than throwing) when there is no proxy to wait for or
# the budget expires; the seed then carries '' exactly as it did before.
$null = Wait-YurunaAggregatorReady
$aggregatorSeedUrl = Get-PoolAggregatorServiceSeedUrl
# Writable pool-intent git url the daemon commits to; empty degrades the daemon
# (read-only). An explicit test.config.yml pool.intentGitUrl wins; otherwise this
# resolves the bare repo on the pool NAS, which the guest creates and seeds on
# first bring-up so a fresh VM reaches a working UI with nothing pre-staged.
$intentGitUrl = Get-PoolIntentSeedUrl -Config $tc

# Render user-data from the shared base + UTM overlay (host/vmconfig/
# pool-control-service.*). New-CloudInitUserData resolves placeholders with literal
# .Replace(), so values carrying regex-special chars are safe.
Import-Module (Join-Path $_repoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force
$UserData = New-CloudInitUserData `
    -BasePath    (Join-Path $_repoRoot 'host/vmconfig/pool-control-service.base.user-data') `
    -OverlayPath (Join-Path $_repoRoot 'host/vmconfig/pool-control-service.utm.overlay.yml') `
    -RepoRoot    $_repoRoot `
    -Replacement @{
        SSH_AUTHORIZED_KEY_PLACEHOLDER = $SshAuthorizedKey
        PASSWORD_PLACEHOLDER           = $AdminPassword
        YURUNA_STATUS_SERVICE_IP_PLACEHOLDER     = $YurunaHostIp
        YURUNA_STATUS_SERVICE_PORT_PLACEHOLDER   = $YurunaHostPort
        YURUNA_HOST_ID_PLACEHOLDER     = $poolNas.HostId
        YURUNA_AGGREGATOR_URL_PLACEHOLDER      = $aggregatorSeedUrl
        YURUNA_POOL_INTENT_GIT_URL_PLACEHOLDER = $intentGitUrl
        POOL_NAS_NETWORK_PATH_PLACEHOLDER  = $poolNas.NetworkPath
        POOL_NAS_NETWORK_IP_PLACEHOLDER    = $poolNas.NetworkIp
        POOL_NAS_NETWORK_USER_PLACEHOLDER  = $poolNas.NetworkUser
        POOL_NAS_PASSWORD_PLACEHOLDER      = $poolNas.Password
        POOL_NAS_HOST_ID_PLACEHOLDER       = $poolNas.HostId
    } -Confirm:$false
Set-Content -Path "$SeedDir/user-data" -Value $UserData -NoNewline

$SeedIso = "$DataDir/seed.iso"
Write-Output "Generating seed.iso with cloud-init configuration..."
& hdiutil makehybrid -o "$SeedIso" -joliet -iso -default-volume-name cidata "$SeedDir" 2>&1 | ForEach-Object { Write-Verbose $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to create seed.iso with hdiutil."
    exit 1
}

# --- REGION: config.plist (QEMU backend)
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
if ($NetworkMode -eq 'Shared') {
    Write-Output "Default route is Wi-Fi ($BridgeInterface) -- bridged can't get a LAN lease over Wi-Fi; building the pool-control-service VM on UTM Shared NAT. Start-PoolControlServiceVM.ps1 will forward a host port to it for LAN access."
} else {
    Write-Output "Bridge interface: $BridgeInterface (pool-control-service VM will request DHCP on this LAN)"
}

# 8 GB RAM, 4 vCPU. Sized for the Go daemon + the pwsh pool-admin CLIs it
# shells out to + future in-VM UI.
# --- REGION: https://yuruna.link/definition#defining-the-vm-core-count-policy
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
    -replace '__NETWORK_MODE__',       $NetworkMode `
    -replace '__DISK_IDENTIFIER__',    $DiskId `
    -replace '__DISK_IMAGE_NAME__',    'disk.qcow2' `
    -replace '__SEED_IDENTIFIER__',    $SeedId `
    -replace '__SEED_IMAGE_NAME__',    'seed.iso' `
    -replace '__VNC_DISPLAY__',        "$VncDisplay" `
    -replace '__CPU_COUNT__',          "$vmCores" `
    -replace '__MEMORY_SIZE__',        '8192'

# Bridged mode needs the physical NIC name; Shared NAT carries no
# BridgedInterface key (matches the sibling Shared templates), so drop the
# key/value entirely in that mode.
if ($NetworkMode -eq 'Shared') {
    $PlistContent = $PlistContent -replace "(?m)^[ \t]*<key>BridgedInterface</key>\r?\n[ \t]*<string>__BRIDGE_INTERFACE__</string>\r?\n", ''
} else {
    $PlistContent = $PlistContent -replace '__BRIDGE_INTERFACE__', $BridgeInterface
}

Set-Content -Path "$UtmDir/config.plist" -Value $PlistContent

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
Write-Output ""
Write-Output "== pool-control-service VM bundle created =="
Write-Output "  Path:      $UtmDir"
Write-Output "  Backend:   QEMU (HVF) with -vnc 127.0.0.1:$VncDisplay (port $(5900 + $VncDisplay))"
Write-Output ""
Write-Output "  Console/SSH login:"
Write-Output "    user:     pool-control-service-admin"
Write-Output "    password: (in authentication vault under 'pool-control-service-admin')"
$guidance = @'

Next steps:

  1. Register with UTM:
       open '__UTM_DIR__'    # double-click equivalent

  2. Start the VM and wait 1-3 minutes for cloud-init:
       utmctl start __VM_NAME__

  3. Find the VM's IP. `utmctl ip-address` needs the qemu-guest-agent
     inside the guest (not installed by this seed) -- use one of these
     instead:
     a) Look in the UTM window console; eth0 prints its IP at the
        login prompt after DHCP.
     b) Your LAN router's DHCP leases (the VM is bridged, so macOS's
        /var/db/dhcpd_leases does not contain it).

  4. Watch the bring-up (cloud-init fetches the framework and builds +
     launches the daemon; the harness key stays authorized on :22):
       ssh pool-control-service-admin@$ip 'sudo tail -f /var/log/cloud-init-output.log'

  5. Once cloud-init finishes, the pool-control-service UI serves on :80:
       open http://$ip/

See https://yuruna.link/pool-control-service.
'@
Write-Output ($guidance.
    Replace('__VM_NAME__', $VMName).
    Replace('__UTM_DIR__', $UtmDir))

# --- REGION: hand root-run artifacts back to the operator
# Guard only: the supported invocation is UNELEVATED (these scripts elevate the
# individual operations that need it, and root has no Aqua session for open /
# utmctl / osascript). But a run that did reach here as root left the bundle,
# the base image, the seed and the harness key root-owned, and UTM -- running as
# the operator -- could neither open this VM nor delete it on the next rebuild.
# The whole ~/yuruna tree, not just this bundle: unlinking a directory needs
# write permission on its parent, and guest.nosync is shared by every builder.
[void](Restore-SudoUserOwnership -Path @("$HOME/yuruna", (Join-Path $_repoRoot 'test/status')) -Confirm:$false)
