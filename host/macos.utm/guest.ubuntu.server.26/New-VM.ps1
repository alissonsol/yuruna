<#PSScriptInfo
.VERSION 2026.09.18
.GUID 422f8480-0c5e-4aaf-bac0-6975691a9ce1
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
    Creates a UTM VM that installs Ubuntu Server 26.04 unattended.

.DESCRIPTION
    Uses the Server live ISO. The Server ISO's cdrom has linux-generic
    and a network-configured ubuntu.sources, so subiquity's
    install_kernel step always succeeds. First boot lands at the
    text-mode login prompt; the test harness's Test-Start sequence
    drives that prompt directly.
#>

param(
    [string]$VMName = "ubuntu-server01",
    # Forwarded by the test harness (Start-TestRunner -> Invoke-NewVM) so
    # every guest in a run agrees on a single caching-proxy service URL. When bound
    # (even to ""), the local subnet probe is skipped and this value is
    # used verbatim: "" means "no cache, go direct"; a URL means "use this".
    # When NOT bound (standalone / manual run), fall back to the probe below.
    [string]$CachingProxyServiceUrl,
    # OS user created by autoinstall and exercised by the test
    # sequences. See host/windows.hyper-v/guest.ubuntu.server.26/New-VM.ps1
    # for the rationale on the 'yuuser26' default name.
    [string]$Username = 'yuuser26',
    # cloud-init local-hostname for the guest. Empty means "follow the VM
    # name", which keeps host-side lookups that assume hostname == VM name
    # working for every caller that does not ask for a specific hostname.
    [string]$Hostname = '',
    # Planner-cascaded VM memory (variables.memoryStartupBytes). Raw byte count
    # or a KB/MB/GB suffix (e.g. 34359738368, 32768MB, 32GB); converted to the
    # MB the UTM plist wants. Empty keeps the 12 GB default below.
    [string]$MemoryStartupBytes = '',
    # Planner-cascaded vCPU count (variables.cores). Overrules the default
    # calculation below. Empty keeps the default. Clamped to the host cores.
    [string]$Cores = ''
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
$downloadDir = "$HOME/yuruna/image/ubuntu.env"

# --- REGION: Environment checks
# See https://yuruna.link/42d69dfa-000a
# Check macOS version (requires macOS 12 Monterey or later for UTM 4.x)
$macosVersion = & sw_vers -productVersion 2>$null
$macosMajor = [int]($macosVersion -split '\.')[0]
if ($macosMajor -lt 12) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_f51ff9819bafacb5' -Arguments @{ macosVersion = "$macosVersion" })
    exit 1
}
Write-Verbose "macOS version: $macosVersion (OK)"

# Check Apple Silicon chip (any generation works under QEMU+HVF)
$chipName = (& system_profiler SPHardwareDataType 2>$null | Select-String "Chip" | ForEach-Object { $_ -replace '.*Chip:\s*', '' }).Trim()
if (-not $chipName) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_c748b36dc0a02031')
    exit 1
}
if ($chipName -notmatch 'Apple M\d') {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_7e08260225888b2c' -Arguments @{ chipName = "$chipName" })
    exit 1
}
Write-Verbose "Chip: $chipName (OK)"

# Check UTM version (requires v4.0.0 or later for ConfigurationVersion 4 / QEMU backend)
$utmPlist = "/Applications/UTM.app/Contents/Info.plist"
if (-not (Test-Path $utmPlist)) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_b17b4a09c8f6f0f6')
    exit 1
}
$utmVersion = (& /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $utmPlist 2>$null)
if ($utmVersion) {
    $utmParts = $utmVersion -split '\.'
    $utmMajor = [int]$utmParts[0]
    if ($utmMajor -lt 4) {
        Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_ce8e82f0d1b545c8' -Arguments @{ utmVersion = "$utmVersion" })
        Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_9c80476fdd14c462')
        exit 1
    }
    Write-Verbose "UTM version: $utmVersion (OK)"
} else {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_fa7ca00859916941')
}

Write-Verbose "All requirements met."
Write-Output ""

# --- REGION: Seek the base image
# Auto-run Get-Image.ps1 once if the base image is missing; recheck and
# only error out when it's still missing afterward.
$baseImageName = "host.macos.utm.guest.ubuntu.server.26"
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules/Yuruna.Image.psm1') -Force
if (-not (Assert-YurunaBaseImage -BaseImageFile $baseImageFile -GuestFolder $PSScriptRoot)) { exit 1 }

# --- REGION: https://yuruna.link/42e220c4-0004
# Read the persistent authentication vault; a new cycle must not reset credentials.
$_repoRootForExt = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))
Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.Extension.psm1') -Global -Force -Verbose:$false
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$Password = Get-LocalOsPassword -Username $Username
if (-not $Password) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_a8c8c2c47e517a44' -Arguments @{ username = "$Username" }); exit 1 }
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_762658980a25b8fb' -Arguments @{ authActiveName = "$_authActiveName" })
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_c427eb2402415f42' -Arguments @{ authentication = "$(Resolve-ExtensionAreaDir -Area 'authentication')" })

# --- REGION: Autoinstall password hash
# See https://yuruna.link/429f3d06-0017
# Keep the shared hash helper: its -- separator protects leading-dash passwords.
Import-Module (Join-Path $_repoRootForExt 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
try {
    $PasswordHash = ConvertTo-Sha512CryptHash -Plaintext $Password
} catch {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_a22129b198b9c117' -Arguments @{ message = "$($_.Exception.Message)" })
    exit 1
}

Write-Verbose "Creating VM '$VMName' using image: $baseImageFile"
# --- REGION: Base image provenance
# Emit the source URL from a healthy sidecar; warn when provenance is incomplete.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

# --- REGION: Import host modules
# Load shared helpers (retry-on-EACCES bundle removal -- handles the race
# where UTM.app / QEMUHelper.xpc still holds file handles on disk.qcow2
# immediately after `utmctl delete`).
Import-Module (Join-Path (Split-Path -Parent $ScriptDir) "modules/Yuruna.Host.psm1") -Force

# --- REGION: Remove existing VM
if (-not (Remove-UtmBundleWithRetry -Path $UtmDir)) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_7565389d0d010c89' -Arguments @{ utmDir = "$UtmDir" })
    exit 1
}
# --- REGION: Create copies and files for VM
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

$DestIso = "$DataDir/$VMName.iso"
Copy-Item -Path $baseImageFile -Destination $DestIso
Write-Verbose "Copied installer ISO as: $VMName.iso"

# --- REGION: Create empty install target
# Create blank disk for installation (64GB, qcow2 sparse -- grows on
# demand inside the qcow2 container, so the host doesn't pre-reserve
# the full nominal size). Uniform cap across hosts: ubuntu.kvm /
# windows.hyper-v / macos.utm. Paired with sizing-policy: all in
# host/vmconfig/ubuntu.server.base.user-data so the root LV consumes the whole PV.
$DiskImage = "$DataDir/disk.qcow2"
Write-Verbose "Creating 64GB disk image (qcow2 format for QEMU backend)..."
& qemu-img create -f qcow2 "$DiskImage" 64G 2>&1 | ForEach-Object { Write-Verbose $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_15c7a852ad128a63')
    exit 1
}

$SeedDir = Join-Path $downloadDir "seed_temp/$VMName"
if (Test-Path -LiteralPath $SeedDir) { Remove-Item -LiteralPath $SeedDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null

# user-data AND meta-data are shared under host/vmconfig/ (the meta-data is
# byte-identical across the three host platforms; ubuntu.server.24 and .26
# share one file). Anchor contract: automation/Yuruna.CloudInitTemplate.psm1.
$RepoRoot        = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))
$HostVmConfigDir = Join-Path $RepoRoot 'host/vmconfig'
$BaseUserData    = Join-Path $HostVmConfigDir 'ubuntu.server.base.user-data'
$OverlayUserData = Join-Path $HostVmConfigDir 'ubuntu.server.utm.overlay.yml'
$MetaDataTemplate = Join-Path $HostVmConfigDir 'ubuntu.server.meta-data'
foreach ($p in @($BaseUserData, $OverlayUserData)) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_fcf4372c1612b691' -Arguments @{ p = "$p" }); exit 1 }
}
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.GuestSeed.psm1') -Force

# --- REGION: Yuruna harness SSH key
# Load the SSH public key used by the test harness to drive the VM over SSH.
$TestSshModule = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))) "test/modules/Test.Ssh.psm1"
Import-Module $TestSshModule -Force
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_6424990f88c7f7bc' -Arguments @{ testSshModule = "$TestSshModule" }); exit 1 }

# --- REGION: Detect the caching-proxy service
# See https://yuruna.link/4220a755-0017
# Detect the caching-proxy-service and inject its proxy URL if available. Severity:
# URL found -> inject; cache VM started but no :3128 on LAN -> ERROR, exit 1;
# cache VM not registered / not started -> WARNING, proceed direct.
if ($PSBoundParameters.ContainsKey('CachingProxyServiceUrl')) {
    # URL was forwarded by the caller (test runner). Skip the probe so this
    # script and the runner's detection agree on a single cache URL.
    if ($CachingProxyServiceUrl) {
        Write-Verbose "  caching-proxy service URL forwarded by caller: $CachingProxyServiceUrl -- skipping local probe."
    } else {
        Write-Verbose "  No proxy forwarded by caller -- guest will download directly."
    }
} else {
$CachingProxyServiceUrl = ""
$utmctl = (Get-Command utmctl -ErrorAction SilentlyContinue)?.Source
if (-not $utmctl -and (Test-Path "/Applications/UTM.app/Contents/MacOS/utmctl")) {
    $utmctl = "/Applications/UTM.app/Contents/MacOS/utmctl"
}

$squidStatus = $null
if ($utmctl) {
    try {
        $squidStatus = (& $utmctl status yuruna-caching-proxy-service 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -ne 0) { $squidStatus = $null }
    } catch {
        Write-Verbose "utmctl status yuruna-caching-proxy-service failed: $($_.Exception.Message)"
        $squidStatus = $null
    }
}

# Delegate to the host driver: state-file fast path + LAN /24 scan
# (self-healing if state went stale). Yuruna.Host is already imported
# by the caller via Initialize-YurunaHost. Returns http://<lan-ip>:3128
# or $null.
$probedUrl = $null
try { $probedUrl = Test-CachingProxyServiceAvailable } catch {
    Write-Verbose "Test-CachingProxyServiceAvailable threw: $($_.Exception.Message)"
}

if ($probedUrl) {
    $CachingProxyServiceUrl = $probedUrl
    Write-Verbose "  caching-proxy-service reachable on LAN -- guest will use $CachingProxyServiceUrl."
} elseif ($squidStatus -and $squidStatus.ToString().Trim() -match 'start') {
    # VM is up but no :3128 answer was found on the LAN. Could be: the
    # bridged DHCP lease failed (Wi-Fi AP MAC filter), cloud-init still
    # bringing up squid (5-15 min on first boot), or the LAN /24 we
    # scanned does not match the cache's lease. Abort loudly so this
    # surfaces during the install, not as a slow 429 storm later.
    $detail = @"

========
ERROR: yuruna-caching-proxy-service VM is started but no :3128 listener was
       found on this host's LAN /24.
========
  utmctl status yuruna-caching-proxy-service : $squidStatus
  LAN /24 scan                       : no answer

The cache VM is bridged to the host's physical NIC (QEMU/vmnet
bridged mode) and is expected to have a DHCP lease on the
same /24 the host is on. If it doesn't answer:
  * Wi-Fi AP may be filtering the cache's locally-administered MAC
    (rotate the cache and retry on a network that allows it, or
    switch to Ethernet).
  * cloud-init may still be installing squid (5-15 min first boot).
  * LAN may not be /24 (the scan assumes a single contiguous /24).

Fix:
  test/service/Start-CachingProxyServiceVM.ps1   (rebuilds and re-discovers; safe to re-invoke)

To intentionally skip the cache:
  test/service/Stop-CachingProxyServiceVM.ps1     (guest will then WARN and download direct).
========
"@
    $Host.UI.WriteLine([ConsoleColor]::Red, $Host.UI.RawUI.BackgroundColor, $detail)
    exit 1
} elseif ($squidStatus) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_b8e47643acd55dfa' -Arguments @{ squidStatus = "$squidStatus" })
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_852eb7f6f45f8c86')
} else {
    if (-not $utmctl) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_ed6f405da50b5ea4')
    } else {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_9a5f74f11757033e')
    }
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_d02a5e01de3815cb')
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_13283fba83b986c8')
}
}

# --- REGION: Build the autoinstall apt block
# See https://yuruna.link/429f3d06-000a
# Use the shared apt builder to keep mirror selection and retry budgets identical.
$AptProxyBlock = New-AptProxyBlock -PrimaryUri 'http://ports.ubuntu.com/ubuntu-ports' -CachingProxyServiceUrl $CachingProxyServiceUrl

# --- REGION: Yuruna host coordinates
# Yuruna host (status service) IP+port baked into the seed for the dev
# iteration loop. Guest scripts read /etc/yuruna/host.env (written by
# the user-data late-commands) to resolve a local URL before falling
# back to GitHub. See Test-YurunaHost.ps1 for the in-guest probe.
$YurunaHostIp = Get-GuestReachableHostIp
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))) 'test/modules/Test.Config.psm1') -Global -Force
$_statusSeed = Get-YurunaStatusServiceSeed -RepoRoot (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir)))
$YurunaHostPort = $_statusSeed.Port

# --- REGION: Fetch caching-proxy-service CA cert (base64-embedded in seed)
# See https://yuruna.link/4220a755-0015
# An empty $CaCertBase64 is NOT a harmless no-op (curl rc=60 SSL-bump gate).
Import-Module (Join-Path $RepoRoot "test/modules/Test.CachingProxyService.psm1") -Force -DisableNameChecking
$CaCertBase64 = ""
$cacheVmIp = $null
if ($Env:YURUNA_CACHING_PROXY_SERVICE_IP -and (Test-IpAddress $Env:YURUNA_CACHING_PROXY_SERVICE_IP)) {
    # External cache: the state file is not updated for external caches; use the env IP.
    $cacheVmIp = $Env:YURUNA_CACHING_PROXY_SERVICE_IP.Trim()
} elseif ($CachingProxyServiceUrl) {
    $candidate = (Read-CachingProxyServiceState).ipAddress
    if ($candidate -and (Test-IpAddress $candidate)) { $cacheVmIp = $candidate }
}
if ($CachingProxyServiceUrl -and $cacheVmIp) {
    $cacheVmHost = Format-IpUrlHost $cacheVmIp
    $ca = Get-CachingProxyServiceCaCertBase64 -CacheCaUrl "http://${cacheVmHost}/yuruna-squid-ca.crt" -CacheHost $cacheVmIp
    $CaCertBase64 = $ca.CaCertBase64
    if ($ca.Exhausted) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_f2bb24df290cd0c1')
    }
} elseif ($CachingProxyServiceUrl) {
    # No cache IP resolved: surface it rather than skipping silently.
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_3116a0bcc76026cb' -Arguments @{ cachingProxyServiceUrl = "$CachingProxyServiceUrl" })
}

# --- REGION: Render user-data / meta-data
# See https://yuruna.link/4220a755-0003
# Bake yuruna-retry.sh + fetch-and-execute.sh into the seed as base64-encoded
# write_files entries. Eliminates the legacy network-dependent wget+wget
# bootstrap and ensures both files are on disk before any guest script runs.
$null = New-CloudInitUserData `
    -BasePath    $BaseUserData `
    -OverlayPath $OverlayUserData `
    -RepoRoot    $RepoRoot `
    -OutputPath  "$SeedDir/user-data" `
    -Replacement @{
        HOSTNAME_PLACEHOLDER           = $GuestHostname
        USERNAME_PLACEHOLDER           = $Username
        HASH_PLACEHOLDER               = $PasswordHash
        SSH_AUTHORIZED_KEY_PLACEHOLDER = $SshAuthorizedKey
        APT_PROXY_BLOCK_PLACEHOLDER    = $AptProxyBlock
        CACHING_PROXY_URL_PLACEHOLDER  = $CachingProxyServiceUrl
        CA_CERT_BASE64_PLACEHOLDER     = $CaCertBase64
        YURUNA_STATUS_SERVICE_IP_PLACEHOLDER     = $YurunaHostIp
        YURUNA_STATUS_SERVICE_PORT_PLACEHOLDER   = $YurunaHostPort
    } -Confirm:$false
$MetaData = (Get-Content -Raw $MetaDataTemplate) `
    -replace 'INSTANCE_ID_PLACEHOLDER', $VMName `
    -replace 'HOSTNAME_PLACEHOLDER', $GuestHostname
Set-Content -Path "$SeedDir/meta-data" -Value $MetaData -NoNewline
# --- REGION: https://yuruna.link/4220a755-000b
# The shared network-config pins DHCP identity during installation and after reboot.
Copy-Item -LiteralPath (Join-Path $HostVmConfigDir 'guest-dhcp.network-config') `
    -Destination "$SeedDir/network-config" -Force

# --- REGION: Generate cloud-init seed ISO
$SeedIso = "$DataDir/seed.iso"
Write-Verbose "Generating seed.iso with autoinstall configuration..."
& hdiutil makehybrid -o "$SeedIso" -joliet -iso -default-volume-name cidata "$SeedDir" 2>&1 | ForEach-Object { Write-Verbose $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_fea701fd46026b88')
    exit 1
}

# --- REGION: Create and configure the UTM bundle (config.plist, QEMU backend)
# Generate UTM config.plist from template (QEMU backend, with -vnc 127.0.0.1:N AdditionalArgument)
$TemplatePath = Join-Path $ScriptDir "config.plist.template"
if (-not (Test-Path $TemplatePath)) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_603b5ff75924a72c' -Arguments @{ templatePath = "$TemplatePath" })
    exit 1
}

$VmUuid = [guid]::NewGuid().ToString().ToUpper()
$DiskId = [guid]::NewGuid().ToString().ToUpper()
$IsoId = [guid]::NewGuid().ToString().ToUpper()
$SeedId = [guid]::NewGuid().ToString().ToUpper()
# --- REGION: https://yuruna.link/4220a755-000a
# Keyed on the guest's durable identity, not on the name the VM carries now: a
# guest is built in a per-kind slot and renamed to its real name when its
# baseline is snapshotted, and an address that moved with that rename would
# re-DHCP a guest whose own state already records the one it was built on.
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
# Cascaded variables.cores overrules the default; clamp to the host cores.
if ($Cores) {
    $coresInt = 0
    if (-not [int]::TryParse($Cores, [ref]$coresInt) -or $coresInt -lt 1) {
        Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_0e7d8993e0f54ff9' -Arguments @{ cores = "$Cores" })
        exit 1
    }
    if ($coresInt -gt $hostCores) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_fb77dad01082953b' -Arguments @{ coresInt = "$coresInt"; hostCores = "$hostCores" })
        $coresInt = $hostCores
    }
    $vmCores = $coresInt
}

# --- REGION: https://yuruna.link/42fa6f45-0016
# The UTM plist __MEMORY_SIZE__ is in MB, so convert from the byte count.
try { $vmMemoryBytes = ConvertTo-MemoryStartupBytes $MemoryStartupBytes } catch { Write-Error $_.Exception.Message; exit 1 }
$vmMemoryMb = if ($vmMemoryBytes -gt 0) { [int]($vmMemoryBytes / 1MB) } else { 12288 }

$PlistContent = (Get-Content -Raw $TemplatePath) `
    -replace '__VM_NAME__',             $VMName `
    -replace '__VM_UUID__',             $VmUuid `
    -replace '__MAC_ADDRESS__',         $MacAddress `
    -replace '__DISK_IDENTIFIER__',     $DiskId `
    -replace '__DISK_IMAGE_NAME__',     'disk.qcow2' `
    -replace '__ISO_IDENTIFIER__',      $IsoId `
    -replace '__ISO_IMAGE_NAME__',      "$VMName.iso" `
    -replace '__SEED_IDENTIFIER__',     $SeedId `
    -replace '__SEED_IMAGE_NAME__',     'seed.iso' `
    -replace '__VNC_DISPLAY__',         "$VncDisplay" `
    -replace '__CPU_COUNT__',           "$vmCores" `
    -replace '__MEMORY_SIZE__',         "$vmMemoryMb"

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
Write-Output ""
Write-Verbose "VM bundle created: $UtmDir"
Write-Verbose "Backend: QEMU (HVF) with -vnc 127.0.0.1:$VncDisplay (port $(5900 + $VncDisplay))"
Write-Verbose "Drive without focus: the harness picks up VNC automatically (Get-VncScreenshot,"
Write-Verbose "Send-TextVNC, Send-KeyVNC). UTM no longer needs to be raised to inject keystrokes."
Write-Verbose "Double-click '$VMName.utm' in ~/yuruna/guest.nosync/ to import it into UTM."
Write-Verbose ""
Write-Verbose "Boot sequence:"
Write-Verbose "  1. Ubuntu Server autoinstalls via subiquity (~5-10 min)."
Write-Verbose "  2. First boot lands at the text-mode login prompt."
Write-Verbose ""
Write-Verbose "Default credentials - username: $Username, password: <vault-managed> (must be changed on first login). Vault: test/status/extension/authentication/vault.yml"
