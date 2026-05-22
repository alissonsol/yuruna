<#PSScriptInfo
.VERSION 2026.05.22
.GUID 42f2a3b4-c5d6-4e78-9012-3f4a5b6c7d81
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.com
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
    install_kernel step always succeeds. First boot lands at a
    text-mode login prompt; the test harness's Test-Start sequence
    drives that prompt directly.
#>

param(
    [string]$VMName = "ubuntu-server01",
    # Forwarded by the test harness (Invoke-TestRunner → Invoke-NewVM) so
    # every guest in a run agrees on a single caching proxy URL. When bound
    # (even to ""), the local subnet probe is skipped and this value is
    # used verbatim: "" means "no cache, go direct"; a URL means "use this".
    # When NOT bound (standalone / manual run), fall back to the probe below.
    [string]$CachingProxyUrl,
    # OS user created by autoinstall and exercised by the test
    # sequences. See host/windows.hyper-v/guest.ubuntu.server.26/New-VM.ps1
    # for the rationale on the 'yuuser26' default name.
    [string]$Username = 'yuuser26'
)

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL.
# Each level shows itself + all higher-priority streams; Error is highest.
if ($env:YURUNA_LOG_LEVEL) {
    $_rank = @{ Error=1; Warning=2; Information=3; Verbose=4; Debug=5 }
    if ($_rank.ContainsKey($env:YURUNA_LOG_LEVEL)) {
        $_eff = $_rank[$env:YURUNA_LOG_LEVEL]
        $WarningPreference     = if ($_rank.Warning     -le $_eff) { 'Continue' } else { 'SilentlyContinue' }
        $InformationPreference = if ($_rank.Information -le $_eff) { 'Continue' } else { 'SilentlyContinue' }
        $VerbosePreference     = if ($_rank.Verbose     -le $_eff) { 'Continue' } else { 'SilentlyContinue' }
        $DebugPreference       = if ($_rank.Debug       -le $_eff) { 'Continue' } else { 'SilentlyContinue' }
        if ($_eff -ge $_rank.Verbose) { $ProgressPreference = 'SilentlyContinue' }
    }
}

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Output "Invalid VMName '$VMName'. Only alphanumeric characters, dots, hyphens, and underscores are allowed."
    exit 1
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$GuestDir = "$HOME/yuruna/guest.nosync"
New-Item -ItemType Directory -Force -Path $GuestDir | Out-Null
$UtmDir = "$GuestDir/$VMName.utm"
$DataDir = "$UtmDir/Data"
$downloadDir = "$HOME/yuruna/image/ubuntu.env"

# ===== Environment checks =====
# --- See https://yuruna.link/memory#why-the-macos-utm-ubuntu-server-guest-switched-from-avf-to-qemu-and-hvf

# Check macOS version (requires macOS 12 Monterey or later for UTM 4.x)
$macosVersion = & sw_vers -productVersion 2>$null
$macosMajor = [int]($macosVersion -split '\.')[0]
if ($macosMajor -lt 12) {
    Write-Error "macOS 12 Monterey or later is required (found macOS $macosVersion)."
    exit 1
}
Write-Verbose "macOS version: $macosVersion (OK)"

# Check Apple Silicon chip (any generation works under QEMU+HVF)
$chipName = (& system_profiler SPHardwareDataType 2>$null | Select-String "Chip" | ForEach-Object { $_ -replace '.*Chip:\s*', '' }).Trim()
if (-not $chipName) {
    Write-Error "Could not detect Apple Silicon chip. This script requires Apple Silicon."
    exit 1
}
if ($chipName -notmatch 'Apple M\d') {
    Write-Error "Apple Silicon is required (found: $chipName)."
    exit 1
}
Write-Verbose "Chip: $chipName (OK)"

# Check UTM version (requires v4.0.0 or later for ConfigurationVersion 4 / QEMU backend)
$utmPlist = "/Applications/UTM.app/Contents/Info.plist"
if (-not (Test-Path $utmPlist)) {
    Write-Error "UTM not found at /Applications/UTM.app. Install with: brew install --cask utm"
    exit 1
}
$utmVersion = (& /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $utmPlist 2>$null)
if ($utmVersion) {
    $utmParts = $utmVersion -split '\.'
    $utmMajor = [int]$utmParts[0]
    if ($utmMajor -lt 4) {
        Write-Error "UTM v4.0.0 or later is required (found v$utmVersion)."
        Write-Error "Update with: brew upgrade --cask utm"
        exit 1
    }
    Write-Verbose "UTM version: $utmVersion (OK)"
} else {
    Write-Warning "Could not determine UTM version. Ensure UTM v4.0.0 or later is installed."
}

Write-Verbose "All requirements met."
Write-Output ""

# === Seek the base image ===
# Auto-run Get-Image.ps1 once if the base image is missing; recheck and
# only error out when it's still missing afterward.
$baseImageName = "host.macos.utm.guest.ubuntu.server.26"
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"
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

# Resolve the autoinstall password from the per-cycle authentication
# vault (see test/extension/authentication/default.psm1). Mirrors the
# Hyper-V and KVM ubuntu.server.26 New-VM.ps1 implementations.
$_repoRootForExt = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))
Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.Extension.psm1') -Global -Force -Verbose:$false
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$Password = Get-LocalOsPassword -Username $Username
if (-not $Password) { Write-Error "Get-LocalOsPassword returned empty for '$Username'."; exit 1 }
Write-Output "Password came from authentication mechanism: $_authActiveName"
Write-Output "See configuration at: $(Resolve-ExtensionAreaDir -Area 'authentication')"

# SHA-512 ($6$) password hash for the autoinstall HASH_PLACEHOLDER.
# ConvertTo-Sha512CryptHash centralises the openssl probe + the `--`
# end-of-options safety that keeps a leading-dash password
# (e.g. `-4aWj*CRw` from New-RandomPassword) from being parsed as an
# option. See Test.VM.common\ConvertTo-Sha512CryptHash for rationale.
Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.VM.common.psm1') -Force -DisableNameChecking
try {
    $PasswordHash = ConvertTo-Sha512CryptHash -Plaintext $Password
} catch {
    Write-Error "Password hashing failed: $($_.Exception.Message)"
    exit 1
}

Write-Verbose "Creating VM '$VMName' using image: $baseImageFile"
# Provenance side-channel for operators reading the transcript. Emits
# "Provenance: <url>" when the sidecar is healthy; warns otherwise.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

# === Create copies and files for VM ===

# Load shared helpers (retry-on-EACCES bundle removal — handles the race
# where UTM.app / QEMUHelper.xpc still holds file handles on disk.qcow2
# immediately after `utmctl delete`).
Import-Module (Join-Path (Split-Path -Parent $ScriptDir) "modules/Yuruna.Host.psm1") -Force
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..\..\..")).Path
Import-Module (Join-Path $RepoRoot "test/modules/Test.VM.common.psm1") -Force -DisableNameChecking

# Create UTM bundle structure
if (-not (Remove-UtmBundleWithRetry -Path $UtmDir)) {
    Write-Error "Could not remove existing UTM bundle at '$UtmDir' after retries. Aborting."
    exit 1
}
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# Copy base image ISO into the bundle (named after hostname)
$DestIso = "$DataDir/$VMName.iso"
Copy-Item -Path $baseImageFile -Destination $DestIso
Write-Verbose "Copied installer ISO as: $VMName.iso"

# Create blank disk for installation (64GB, qcow2 sparse — grows on
# demand inside the qcow2 container, so the host doesn't pre-reserve
# the full nominal size). Uniform cap across hosts.ubuntu.kvm /
# windows.hyper-v / macos.utm. Paired with sizing-policy: all in
# vmconfig/user-data so the root LV consumes the whole PV.
$DiskImage = "$DataDir/disk.qcow2"
Write-Verbose "Creating 64GB disk image (qcow2 format for QEMU backend)..."
& qemu-img create -f qcow2 "$DiskImage" 64G 2>&1 | ForEach-Object { Write-Verbose $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Error "qemu-img failed. Install QEMU tools with: brew install qemu"
    exit 1
}

# Generate autoinstall seed ISO
$SeedDir = Join-Path $downloadDir "seed_temp/$VMName"
if (Test-Path $SeedDir) { Remove-Item -Recurse -Force $SeedDir }
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null

$VmConfigDir = Join-Path $ScriptDir "vmconfig"
$UserDataTemplate = Join-Path $VmConfigDir "user-data"
$MetaDataTemplate = Join-Path $VmConfigDir "meta-data"
if (-not (Test-Path $UserDataTemplate)) {
    Write-Error "user-data template not found at '$UserDataTemplate'."
    exit 1
}

# Load the SSH public key used by the test harness to drive the VM over SSH.
$TestSshModule = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))) "test/modules/Test.Ssh.psm1"
Import-Module $TestSshModule -Force
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error "Get-YurunaSshPublicKey returned empty. Module path: $TestSshModule"; exit 1 }

# Detect the squid-cache and inject its proxy URL if available.
#
# Cache VM is bridged to the host's physical NIC (VZBridgedNetwork-
# DeviceAttachment in config.plist.template), so it carries its own
# LAN DHCP IP -- e.g. http://192.168.7.150:3128. Install VMs on shared
# NAT reach that LAN IP through VMnet's outbound NAT (same path they
# use to reach Ubuntu mirrors), so no host-side TCP forwarder layer is
# needed. Discovery delegates to Test-CachingProxyAvailable, which owns
# the (state-file fast path → LAN /24 scan → state refresh) logic.
#
# Severity policy:
#   * Test-CachingProxyAvailable returns a URL → inject it.
#   * utmctl sees the cache VM started
#     but no :3128 answer on the LAN          → ERROR, exit 1 (the cache
#                                                came up but is not on
#                                                LAN; bridge interface
#                                                or DHCP problem).
#   * Cache VM not registered / not started   → WARNING, proceed direct.
if ($PSBoundParameters.ContainsKey('CachingProxyUrl')) {
    # URL was forwarded by the caller (test runner). Skip the probe so this
    # script and the runner's detection agree on a single cache URL.
    if ($CachingProxyUrl) {
        Write-Verbose "  caching proxy URL forwarded by caller: $CachingProxyUrl — skipping local probe."
    } else {
        Write-Verbose "  No proxy forwarded by caller — guest will download directly."
    }
} else {
$CachingProxyUrl = ""
$utmctl = (Get-Command utmctl -ErrorAction SilentlyContinue)?.Source
if (-not $utmctl -and (Test-Path "/Applications/UTM.app/Contents/MacOS/utmctl")) {
    $utmctl = "/Applications/UTM.app/Contents/MacOS/utmctl"
}

$squidStatus = $null
if ($utmctl) {
    try {
        $squidStatus = (& $utmctl status yuruna-caching-proxy 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -ne 0) { $squidStatus = $null }
    } catch {
        Write-Verbose "utmctl status yuruna-caching-proxy failed: $($_.Exception.Message)"
        $squidStatus = $null
    }
}

# Delegate to the host driver: state-file fast path + LAN /24 scan
# (self-healing if state went stale). Yuruna.Host is already imported
# by the caller via Initialize-YurunaHost. Returns http://<lan-ip>:3128
# or $null.
$probedUrl = $null
try { $probedUrl = Test-CachingProxyAvailable } catch {
    Write-Verbose "Test-CachingProxyAvailable threw: $($_.Exception.Message)"
}

if ($probedUrl) {
    $CachingProxyUrl = $probedUrl
    Write-Verbose "  squid-cache reachable on LAN — guest will use $CachingProxyUrl."
} elseif ($squidStatus -and $squidStatus.ToString().Trim() -match 'start') {
    # VM is up but no :3128 answer was found on the LAN. Could be: the
    # bridged DHCP lease failed (Wi-Fi AP MAC filter), cloud-init still
    # bringing up squid (5-15 min on first boot), or the LAN /24 we
    # scanned does not match the cache's lease. Abort loudly so this
    # surfaces during the install, not as a slow 429 storm later.
    $detail = @"

=========================================================================
ERROR: yuruna-caching-proxy VM is started but no :3128 listener was
       found on this host's LAN /24.
=========================================================================
  utmctl status yuruna-caching-proxy : $squidStatus
  LAN /24 scan                       : no answer

The cache VM is bridged to the host's physical NIC (VZBridged-
NetworkDeviceAttachment) and is expected to have a DHCP lease on the
same /24 the host is on. If it doesn't answer:
  * Wi-Fi AP may be filtering the cache's locally-administered MAC
    (rotate the cache and retry on a network that allows it, or
    switch to Ethernet).
  * cloud-init may still be installing squid (5-15 min first boot).
  * LAN may not be /24 (the scan assumes a single contiguous /24).

Fix:
  test/Start-CachingProxy.ps1   (rebuilds and re-discovers; safe to re-invoke)

To intentionally skip the cache:
  test/Stop-CachingProxy.ps1     (guest will then WARN and download direct).
=========================================================================
"@
    $Host.UI.WriteLine([ConsoleColor]::Red, $Host.UI.RawUI.BackgroundColor, $detail)
    exit 1
} elseif ($squidStatus) {
    Write-Warning "  yuruna-caching-proxy VM exists (status: $squidStatus) but is not started. Guest will download directly (expect occasional 429s)."
    Write-Warning "  To enable caching: test/Start-CachingProxy.ps1"
} else {
    if (-not $utmctl) {
        Write-Warning "  utmctl not found — can't query UTM directly, and nothing answers on the LAN /24 either."
    } else {
        Write-Warning "  No yuruna-caching-proxy VM registered with UTM and nothing answers on the LAN /24."
    }
    Write-Warning "  Guest will download directly — expect 429 rate-limit failures on linux-firmware under load."
    Write-Warning "  To enable caching, run: test/Start-CachingProxy.ps1"
}
}

# Build the autoinstall apt block. Always emit `geoip: false` + a pinned
# primary mirror, even when no squid-cache is reachable -- subiquity's
# default `geoip: true` fires an HTTPS lookup to geoip.ubuntu.com that
# adds seconds to mirror election. Pinning primary makes the election
# deterministic and lets curtin's `modifymirrors` rewrite the existing
# /etc/apt/sources.list.d/ubuntu.sources (Deb822) in-place. Format /
# placement match the hyper-v and kvm sister scripts.
#
# A previous revision used curtin's `sources_list:` template here (with
# `$PRIMARY` / `$SECURITY` tokens) plus a separate `sources:` entry. On
# noble's curtin that just emitted a redundant per-suite index fetch
# (perf bug). On resolute's curtin (subiquity snap 7227) the same
# pattern aborts `subiquity/Mirror/cmd-apt-config` with exit 1 and
# drops the installer to "An error occurred. Press enter to start a
# shell". Hyper-V/KVM already use the simplified form below; this
# brings macOS UTM in line.
#
# Primary URI is the ports mirror because macOS UTM is always aarch64.
$AptProxyLine = if ($CachingProxyUrl) { "`n    proxy: $CachingProxyUrl" } else { "" }
$AptProxyBlock = @"
  apt:
    geoip: false
    primary:
      - arches: [default]
        uri: http://ports.ubuntu.com/ubuntu-ports$($AptProxyLine)
"@

# Fetch the squid-cache CA on the host so it can be base64-embedded in
# the autoinstall seed. Guests on VZ shared-NAT cannot reach the cache
# VM directly, but this script runs on the host which can. Any failure
# (no recorded cache IP, HTTP error, empty response) leaves $CaCertBase64
# empty and the guest's HTTPS proxy block becomes a no-op.
Import-Module (Join-Path $RepoRoot "test/modules/Test.CachingProxy.psm1") -Force -DisableNameChecking
$CaCertBase64 = ""
$cacheVmIp = $null
if ($Env:YURUNA_CACHING_PROXY_IP -and (Test-IpAddress $Env:YURUNA_CACHING_PROXY_IP)) {
    # External cache: $CachingProxyUrl already points at the remote IP (no VZ-
    # gateway rewrite), and the remote image is identical to the local one
    # -- same Apache on :80 serving /yuruna-squid-ca.crt. The
    # yuruna-caching-proxy state file is not updated for external caches,
    # so read the IP straight from the environment variable.
    $cacheVmIp = $Env:YURUNA_CACHING_PROXY_IP.Trim()
} elseif ($CachingProxyUrl) {
    $candidate = (Read-CachingProxyState).ipAddress
    if ($candidate -and (Test-IpAddress $candidate)) { $cacheVmIp = $candidate }
}
if ($CachingProxyUrl -and $cacheVmIp) {
    $cacheVmHost = Format-IpUrlHost $cacheVmIp
    $cacheVmCaUrl = "http://${cacheVmHost}/yuruna-squid-ca.crt"
    try {
        $caResp = Invoke-WebRequest -Uri $cacheVmCaUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if ($caResp.StatusCode -eq 200 -and $caResp.RawContentLength -gt 0) {
            $caBytes = if ($caResp.Content -is [byte[]]) { $caResp.Content } else { [System.Text.Encoding]::UTF8.GetBytes([string]$caResp.Content) }
            $CaCertBase64 = [Convert]::ToBase64String($caBytes)
            Write-Verbose "  Fetched squid-cache CA from $cacheVmCaUrl ($($caBytes.Length) bytes) — embedded in seed."
        }
    } catch {
        Write-Warning "  Could not fetch CA cert from ${cacheVmCaUrl} : $($_.Exception.Message)"
        Write-Warning "  Guest will skip HTTPS caching (Acquire::https::Proxy); HTTP caching via :3128 unaffected."
    }
}

# Yuruna host (status server) IP+port baked into the seed for the dev
# iteration loop. Guest scripts read /etc/yuruna/host.env (written by
# the user-data late-commands) to resolve a local URL before falling
# back to GitHub. See Test-YurunaHost.ps1 for the in-guest probe.
$YurunaHostIp = Get-GuestReachableHostIp
$YurunaHostPort = '8080'
$YurunaTestConfig = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))) 'test/test.config.yml'
if (Test-Path $YurunaTestConfig) {
    try {
        $tc = Get-Content -Raw $YurunaTestConfig | ConvertFrom-Yaml -Ordered
        if ($tc.statusServer.port) { $YurunaHostPort = "$($tc.statusServer.port)" }
    } catch { Write-Verbose "test.config.yml parse failed: $_" }
}

$UserData = (Get-Content -Raw $UserDataTemplate).Replace('HOSTNAME_PLACEHOLDER', $VMName).Replace('USERNAME_PLACEHOLDER', $Username).Replace('HASH_PLACEHOLDER', $PasswordHash).Replace('SSH_AUTHORIZED_KEY_PLACEHOLDER', $SshAuthorizedKey).Replace('APT_PROXY_BLOCK_PLACEHOLDER', $AptProxyBlock).Replace('CACHING_PROXY_URL_PLACEHOLDER', $CachingProxyUrl).Replace('CA_CERT_BASE64_PLACEHOLDER', $CaCertBase64).Replace('YURUNA_HOST_IP_PLACEHOLDER', $YurunaHostIp).Replace('YURUNA_HOST_PORT_PLACEHOLDER', $YurunaHostPort)

Set-Content -Path "$SeedDir/user-data" -Value $UserData -NoNewline
$MetaData = (Get-Content -Raw $MetaDataTemplate) `
    -replace 'HOSTNAME_PLACEHOLDER', $VMName
Set-Content -Path "$SeedDir/meta-data" -Value $MetaData -NoNewline

$SeedIso = "$DataDir/seed.iso"
Write-Verbose "Generating seed.iso with autoinstall configuration..."
& hdiutil makehybrid -o "$SeedIso" -joliet -iso -default-volume-name cidata "$SeedDir" 2>&1 | ForEach-Object { Write-Verbose $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to create seed.iso with hdiutil."
    exit 1
}

# Generate UTM config.plist from template (QEMU backend, with -vnc 127.0.0.1:N AdditionalArgument)
$TemplatePath = Join-Path $ScriptDir "config.plist.template"
if (-not (Test-Path $TemplatePath)) {
    Write-Error "Template not found at '$TemplatePath'."
    exit 1
}

# Generate UUIDs and MAC address for this VM
$VmUuid = [guid]::NewGuid().ToString().ToUpper()
$DiskId = [guid]::NewGuid().ToString().ToUpper()
$IsoId = [guid]::NewGuid().ToString().ToUpper()
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

# --- VM core-count policy: see https://yuruna.link/definition#defining-the-vm-core-count-policy
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
    -replace '__ISO_IDENTIFIER__',      $IsoId `
    -replace '__ISO_IMAGE_NAME__',      "$VMName.iso" `
    -replace '__SEED_IDENTIFIER__',     $SeedId `
    -replace '__SEED_IMAGE_NAME__',     'seed.iso' `
    -replace '__VNC_DISPLAY__',         "$VncDisplay" `
    -replace '__CPU_COUNT__',           "$vmCores" `
    -replace '__MEMORY_SIZE__',         '16384'

Set-Content -Path "$UtmDir/config.plist" -Value $PlistContent

# Validate the generated plist is well-formed.
$lintOutput = & plutil -lint "$UtmDir/config.plist" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Generated config.plist failed plist validation: $lintOutput"
    Write-Error "Inspect the file at: $UtmDir/config.plist"
    exit 1
}
Write-Verbose "config.plist validated OK (VNC on 127.0.0.1:$(5900 + $VncDisplay))."

# === Cleanup temporary folders ===
Remove-Item -Recurse -Force $SeedDir -ErrorAction SilentlyContinue

# === Guidance ===
Write-Output ""
Write-Verbose "VM bundle created: $UtmDir"
Write-Verbose "Backend: QEMU (HVF) with -vnc 127.0.0.1:$VncDisplay (port $(5900 + $VncDisplay))"
Write-Verbose "Drive without focus: the harness picks up VNC automatically (Get-VncScreenshot,"
Write-Verbose "Send-TextVNC, Send-KeyVNC). UTM no longer needs to be raised to inject keystrokes."
Write-Verbose "Double-click '$VMName.utm' on your Desktop to import it into UTM."
Write-Verbose ""
Write-Verbose "Boot sequence:"
Write-Verbose "  1. Ubuntu Server autoinstalls via subiquity (~5-10 min)."
Write-Verbose "  2. First boot lands at the text-mode login prompt."
Write-Verbose ""
Write-Verbose "Default credentials - username: $Username, password: <vault-managed> (must be changed on first login). Vault: test/status/extension/authentication/vault.yml"
