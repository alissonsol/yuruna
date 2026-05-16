<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42d9e0f1-a2b3-4c45-d678-9e0f1a2b3c47
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
    Creates a Hyper-V VM that installs Ubuntu Server 24.04 in text mode.

.DESCRIPTION
    Uses the Server live ISO. The Server ISO's cdrom has linux-generic
    and a network-configured ubuntu.sources, so subiquity's
    install_kernel step always succeeds. First boot lands at the
    text-mode login prompt; the test harness's Test-Start sequence
    drives that prompt directly.
#>

param(
    [string]$VMName = "ubuntu-server01",
    # Forwarded by the test harness (Invoke-TestRunner → Invoke-NewVM)
    # so every guest in a run agrees on one caching proxy URL. When
    # bound (even to ""), local discovery is skipped and this value is
    # used verbatim: "" = no cache, go direct; URL = use this. When NOT
    # bound (standalone run), fall back to the discovery block below.
    [string]$CachingProxyUrl,
    # OS user created by autoinstall and exercised by the test
    # sequences. The framework default 'yuuser1' is intentionally
    # unique/greppable (versus the cloud-image default 'ubuntu', which
    # is noisy in any text search). Multi-user future (gap 33) will
    # spawn additional users via a manifest -- no need to override here.
    [string]$Username = 'yuuser1'
)

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Output "Invalid VMName '$VMName'. Only alphanumeric characters, dots, hyphens, and underscores are allowed."
    exit 1
}

$ProgressPreference = 'SilentlyContinue'

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
    }
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$commonModulePath = Join-Path -Path (Split-Path -Parent $ScriptDir) -ChildPath "modules/Yuruna.Host.psm1"
Import-Module -Name $commonModulePath -Force

Write-Verbose "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output "Please run this script as Administrator."
    Write-Output "Be careful."
    exit 1
}

# Assert-HyperVEnabled calls dism.exe directly instead of
# Get-WindowsOptionalFeature — avoids the "Class not registered" COM
# failure on first post-install runs on fresh Windows 11.
if (-not (Assert-HyperVEnabled)) {
    Write-Output "Instructions: https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/quick-start/enable-hyper-v"
    exit 1
}

$downloadDir = (Get-VMHost).VirtualHardDiskPath
if (!(Test-Path -Path $downloadDir)) {
    Write-Output "The Hyper-V default VHDX folder does not exist: $downloadDir"
    exit 1
}

# === Seek the base image ===
# Auto-run Get-Image.ps1 once if the base image is missing; recheck and
# only error out when it's still missing afterward.
$baseImageName = "host.windows.hyper-v.guest.ubuntu.server"
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"
if (!(Test-Path -Path $baseImageFile)) {
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
    if (!(Test-Path -Path $baseImageFile)) {
        Write-Error "Base image not found at '$baseImageFile' after auto Get-Image. Run Get-Image.ps1 manually."
        exit 1
    }
}

# Resolve the autoinstall password from the per-cycle authentication
# vault. Get-Password returns the stored value if present, else
# generates a fresh one (chained to whatever the previous guest in this
# cycle committed -- see test/extension/authentication/default.psm1).
# Cycle-end cleanup wipes the vault on success; a failed cycle leaves
# it in place for debugging.
$_repoRootForExt = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))
Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.Extension.psm1') -Global -Force -Verbose:$false
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$Password = Get-Password -Username $Username
if (-not $Password) { Write-Error "Get-Password returned empty for '$Username'."; exit 1 }
Write-Output "Password came from authentication mechanism: $_authActiveName"
Write-Output "See configuration at: $(Resolve-ExtensionAreaDir -Area 'authentication')"

# Find OpenSSL with SHA-512 passwd for the autoinstall password hash
$PasswordHash = $null
foreach ($path in @("$env:ProgramFiles\Git\usr\bin\openssl.exe", "$env:ProgramFiles\Git\mingw64\bin\openssl.exe", "$env:ProgramFiles\OpenSSL-Win64\bin\openssl.exe", "${env:ProgramFiles(x86)}\OpenSSL-Win32\bin\openssl.exe", "openssl")) {
    try {
        $result = (& $path passwd -6 $Password 2>$null)
        if ($LASTEXITCODE -eq 0 -and $result) {
            $PasswordHash = $result.Trim()
            break
        }
    } catch {
        Write-Warning "Not found: $path"
    }
}
if (-not $PasswordHash) {
    Write-Error "OpenSSL with SHA-512 password support is required. Install Git for Windows or OpenSSL."
    exit 1
}

Write-Verbose "Creating VM '$VMName' using image: $baseImageFile"
# Provenance side-channel for the transcript. Emits "Provenance: <url>"
# when the sidecar is healthy; warns otherwise.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

$existingVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($existingVM) {
    Write-Output "VM '$VMName' exists. Deleting..."
    Hyper-V\Stop-VM -Name $VMName -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    Hyper-V\Remove-VM -Name $VMName -Force
    Write-Output "VM '$VMName' deleted."
}

# === Create copies and files for VM ===

# 512GB dynamically expanding VHDX
$vmDir = Join-Path $downloadDir $VMName
if (!(Test-Path -Path $vmDir)) {
    New-Item -ItemType Directory -Path $vmDir -Force | Out-Null
}
$vhdxFile = Join-Path $vmDir "$VMName.vhdx"
if (Test-Path -Path $vhdxFile) {
    Remove-Item -Path $vhdxFile -Force
}
Write-Verbose "Creating 512GB dynamically expanding VHDX..."
New-VHD -Path $vhdxFile -SizeBytes 512GB -Dynamic | Out-Null

# Autoinstall seed ISO
$SeedDir = Join-Path $env:TEMP "seed_$VMName"
if (Test-Path $SeedDir) { Remove-Item -Recurse -Force $SeedDir }
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null

$VmConfigDir = Join-Path $ScriptDir "vmconfig"
$UserDataTemplate = Join-Path $VmConfigDir "user-data"
$MetaDataTemplate = Join-Path $VmConfigDir "meta-data"
if (-not (Test-Path $UserDataTemplate)) {
    Write-Error "user-data template not found at '$UserDataTemplate'."
    exit 1
}

# SSH public key used by the test harness.
$TestSshModule = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))) "test/modules/Test.Ssh.psm1"
Import-Module $TestSshModule -Force
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error "Get-YurunaSshPublicKey returned empty. Module path: $TestSshModule"; exit 1 }

# Detect the squid-cache VM and inject its proxy URL if available.
# Severity policy:
#   * No cache VM         → WARNING, proceed (direct CDN)
#   * Cache VM stopped    → WARNING, proceed (direct CDN)
#   * Cache running, :3128
#     doesn't answer      → ERROR, exit 1
if ($PSBoundParameters.ContainsKey('CachingProxyUrl')) {
    # URL forwarded by the test runner. Skip discovery so this script
    # and the runner agree on one cache URL. On Hyper-V the race is
    # narrower than UTM (MAC-scoped neighbor lookup, not subnet scan),
    # but one source of truth still simplifies debugging.
    if ($CachingProxyUrl) {
        Write-Verbose "  caching proxy URL forwarded by caller: $CachingProxyUrl — skipping local discovery."
    } else {
        Write-Verbose "  No proxy forwarded by caller — guest will download directly."
    }
} else {
$CachingProxyUrl = ""
$cacheVM = Get-VM -Name "yuruna-caching-proxy" -ErrorAction SilentlyContinue
if (-not $cacheVM) {
    Write-Warning "  No yuruna-caching-proxy VM exists on this host. Guest will download packages directly from Ubuntu mirrors — expect occasional 429 rate-limit failures on linux-firmware under load."
    Write-Warning "  To enable caching, run: host\windows.hyper-v\guest.squid-cache\New-VM.ps1"
} elseif ($cacheVM.State -ne 'Running') {
    Write-Warning "  yuruna-caching-proxy VM exists but is '$($cacheVM.State)'. Guest will download directly (expect occasional 429s)."
    Write-Warning "  To enable caching: Start-VM yuruna-caching-proxy ; then wait for cloud-init to finish."
} else {
    # KVP+ARP discovery + :3128 probe live in Yuruna.Host.psm1
    # (Get-WorkingCachingProxyUrl). One module means this consumer, the
    # producer, and Start-CachingProxy.ps1's summary see the same
    # answer — earlier drift had Start-SquidCache's KVP-only summary
    # reporting "discovery failed" while ARP path found the cache.
    $CachingProxyUrl = Get-WorkingCachingProxyUrl -VMName "yuruna-caching-proxy"
    if ($CachingProxyUrl) {
        Write-Output "  yuruna-caching-proxy VM detected at $CachingProxyUrl — guest will use local proxy."
    } else {
        $cacheIps = Get-CacheVmCandidateIp -VM $cacheVM
        $ipList = if ($cacheIps) { $cacheIps -join ', ' } else { '(none discovered)' }
        # $Host.UI.WriteLine keeps Write-Host-style color without the
        # PSScriptAnalyzer complaint.
        $detail = @"

=========================================================================
ERROR: yuruna-caching-proxy VM is running but port 3128 is not reachable.
=========================================================================
  Discovered IPs: $ipList

Aborting so this guest install doesn't silently fall back to direct
CDN access and hit the 429 rate limiter.

Accessing the yuruna-caching-proxy VM for debugging:
  * Console:  vmconnect localhost yuruna-caching-proxy
              login:    yuruna
              password: read the 'password:' field from
                test/status/track/yuruna-caching-proxy.yml
  * SSH:      ssh yuruna@<ip>

Rebuild the cache VM:
  host\windows.hyper-v\guest.squid-cache\New-VM.ps1

To intentionally skip the cache:
  Stop-VM yuruna-caching-proxy   (guest will then WARN and download direct).
=========================================================================
"@
        $Host.UI.WriteLine([ConsoleColor]::Red, $Host.UI.RawUI.BackgroundColor, $detail)
        exit 1
    }
}
}

# Build the autoinstall apt block. We ALWAYS emit it — even when no
# squid-cache is reachable — because subiquity's default apt behavior
# is `geoip: true`, which fires an HTTPS lookup to geoip.ubuntu.com
# to elect a regional mirror. That lookup is slow and prone to
# retry-storming during configure_apt/cmd-in-target on this host;
# previously it added minutes to every install. `geoip: false` plus
# an explicit `primary:` pin keeps mirror election deterministic.
#
# `primary:` (not `sources_list:`): the Server 24.04 amd64 squashfs ships
# /etc/apt/sources.list.d/ubuntu.sources (deb822) ALREADY pointing at
# archive.ubuntu.com. Curtin's apt-config does "modifymirrors" — it
# rewrites the existing URI in ubuntu.sources to whatever `primary:`
# says, in place. So one block of pinning is enough; apt sees a single
# fully-rewritten ubuntu.sources and fetches indexes once.
#
# A previous revision used curtin's `sources_list:` template here
# (with `$PRIMARY` / `$SECURITY` tokens). That writes a SECOND apt
# config file alongside the existing ubuntu.sources, so apt fetched
# every per-suite index twice — doubling configure_apt/cmd-in-target's
# fetch volume through the squid-cache proxy and pushing install past
# the harness's login-prompt timeout. Switching to `primary:` matches
# the macOS sister script and aligns with subiquity's own examples.
# `$AptProxyLine` is appended to the end of the `uri:` line below: when a
# proxy is configured we want a leading newline + 4-space indent so the
# YAML lands at the same level as `geoip:` / `primary:`; when there's no
# proxy the whole expansion is empty. Keeping the closing `"@` on its
# own line at column 0 — required by PowerShell's here-string parser; an
# earlier draft accidentally inlined `$(...)"@` and produced
# "The string is missing the terminator: `"@."
$AptProxyLine = if ($CachingProxyUrl) { "`n    proxy: $CachingProxyUrl" } else { "" }
$AptProxyBlock = @"
  apt:
    geoip: false
    primary:
      - arches: [default]
        uri: http://archive.ubuntu.com/ubuntu$($AptProxyLine)
"@

# Pick a vSwitch FIRST -- prefer Yuruna-External (LAN-bridged) so the
# install VM gets a real LAN IP via DHCP and can reach the squid cache
# directly. Default Switch fallback works for hosts that can't create
# an External vSwitch (no LAN, Wi-Fi-only); install proceeds direct
# against Ubuntu mirrors. Switch choice MUST be resolved before
# Get-GuestReachableHostIp below (the host IP a guest reaches differs
# by topology: Default Switch = 172.x.x.x gateway; External = LAN IP).
$switchName = Get-OrCreateYurunaExternalSwitch
if (-not $switchName) {
    Write-Warning "External vSwitch unavailable -- falling back to 'Default Switch'."
    $switchName = 'Default Switch'
}

# Yuruna host (status server) IP+port baked into the seed for the dev
# iteration loop. Guest scripts read /etc/yuruna/host.env (written by
# the user-data late-commands) to resolve a local URL before falling
# back to GitHub. Default Switch's host IP changes across host
# reboots -- see Test-YurunaHost.ps1 for the in-guest probe.
$YurunaHostIp = Get-GuestReachableHostIp -SwitchName $switchName
if (-not $YurunaHostIp) { $YurunaHostIp = '' }
$YurunaHostPort = '8080'
$YurunaTestConfig = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/test.config.yml'
if (Test-Path $YurunaTestConfig) {
    try {
        $tc = Get-Content -Raw $YurunaTestConfig | ConvertFrom-Yaml -Ordered
        if ($tc.statusServer.port) { $YurunaHostPort = "$($tc.statusServer.port)" }
    } catch { Write-Verbose "test.config.yml parse failed: $_" }
}

# -- Fetch squid-cache CA cert (base64-embedded in seed) -------------------
# Mirrors host/macos.utm/guest.ubuntu.server/New-VM.ps1. The installer's
# late-commands write the cert from CA_CERT_BASE64_PLACEHOLDER before
# any HTTPS apt fetch, so SSL-bump caching works from the first install
# request. Any failure (no URL, unreachable cache, HTTP error, empty
# body) leaves $CaCertBase64 empty and the guest's HTTPS proxy block
# becomes a no-op -- HTTP caching via :3128 still works.
$CaCertBase64 = ""
if ($CachingProxyUrl) {
    try {
        $uri = [System.Uri]$CachingProxyUrl
        $cacheHost = if ($uri.Host -match ':') { "[$($uri.Host)]" } else { $uri.Host }
        $cacheCaUrl = "http://$cacheHost/yuruna-squid-ca.crt"
        $caResp = Invoke-WebRequest -Uri $cacheCaUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if ($caResp.StatusCode -eq 200 -and $caResp.RawContentLength -gt 0) {
            $caBytes = if ($caResp.Content -is [byte[]]) { $caResp.Content } else { [System.Text.Encoding]::UTF8.GetBytes([string]$caResp.Content) }
            $CaCertBase64 = [Convert]::ToBase64String($caBytes)
            Write-Verbose "  Fetched squid-cache CA from $cacheCaUrl ($($caBytes.Length) bytes) -- embedded in seed."
        }
    } catch {
        Write-Warning "  Could not fetch CA cert from squid-cache : $($_.Exception.Message)"
        Write-Warning "  Guest will skip HTTPS caching (Acquire::https::Proxy); HTTP caching via :3128 unaffected."
    }
}

$UserData = (Get-Content -Raw $UserDataTemplate).Replace('HOSTNAME_PLACEHOLDER', $VMName).Replace('USERNAME_PLACEHOLDER', $Username).Replace('HASH_PLACEHOLDER', $PasswordHash).Replace('SSH_AUTHORIZED_KEY_PLACEHOLDER', $SshAuthorizedKey).Replace('APT_PROXY_BLOCK_PLACEHOLDER', $AptProxyBlock).Replace('CACHING_PROXY_URL_PLACEHOLDER', $CachingProxyUrl).Replace('CA_CERT_BASE64_PLACEHOLDER', $CaCertBase64).Replace('YURUNA_HOST_IP_PLACEHOLDER', $YurunaHostIp).Replace('YURUNA_HOST_PORT_PLACEHOLDER', $YurunaHostPort)
Set-Content -Path "$SeedDir/user-data" -Value $UserData -NoNewline

$MetaData = (Get-Content -Raw $MetaDataTemplate) `
    -replace 'HOSTNAME_PLACEHOLDER', $VMName
Set-Content -Path "$SeedDir/meta-data" -Value $MetaData -NoNewline

$SeedIso = Join-Path $vmDir "seed.iso"
Write-Verbose "Generating seed.iso with autoinstall configuration..."
CreateIso -SourceDir $SeedDir -OutputFile $SeedIso -VolumeId "cidata"

Write-Verbose "Creating new VM '$VMName' on switch '$switchName'..."
Hyper-V\New-VM -Name $VMName -Generation 2 -MemoryStartupBytes 16384MB -SwitchName $switchName -VHDPath $vhdxFile | Out-Null
Set-VM -Name $VMName -MemoryStartupBytes 16384MB -MemoryMinimumBytes 16384MB -MemoryMaximumBytes 16384MB -AutomaticCheckpointsEnabled $false | Out-Null
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off | Out-Null

Add-VMDvdDrive -VMName $VMName -Path $baseImageFile | Out-Null
Add-VMDvdDrive -VMName $VMName -Path $SeedIso | Out-Null

# Boot order: DVD (Ubuntu ISO) first, then hard drive
$dvdDrive = Get-VMDvdDrive -VMName $VMName | Where-Object { $_.Path -eq $baseImageFile }
Set-VMFirmware -VMName $VMName -FirstBootDevice $dvdDrive

# --- VM core-count policy: see https://yuruna.link/definition#defining-the-vm-core-count-policy
$hostCores = (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
if ($hostCores -lt 4) {
    Write-Error "Host has $hostCores physical cores; Yuruna requires at least 4. See https://yuruna.link/definition#defining-the-vm-core-count-policy"
    exit 1
}
$vmCores = [math]::Max(4, [math]::Floor($hostCores / 2))
Set-VMProcessor -VMName $VMName -Count $vmCores -ExposeVirtualizationExtensions $true | Out-Null

# Set display resolution to 1920x1080.
# WARNING: The test harness OCR is calibrated for 1920x1080.
# Changing this resolution may break automated screen-text detection
# in waitForText sequence steps.
Set-VMVideo -VMName $VMName -HorizontalResolution 1920 -VerticalResolution 1080 -ResolutionType Single

# === Cleanup temporary folders ===
Remove-Item -Recurse -Force $SeedDir -ErrorAction SilentlyContinue

# === Guidance ===
Write-Verbose "VM '$VMName' created and configured."
Write-Verbose "Start the VM from Hyper-V Manager to begin Ubuntu Server installation."
Write-Verbose "Boot sequence:"
Write-Verbose "  1. Ubuntu Server autoinstalls via subiquity (~5-10 min)"
Write-Verbose "  2. First boot: text-mode login prompt."
Write-Verbose "Default credentials - username: $Username, password: <vault-managed> (must be changed on first login). Vault: test/extension/authentication/vault.yml"
Write-Verbose "After installation completes, remove the DVD drives:"
Write-Verbose "  Get-VMDvdDrive -VMName '$VMName' | Remove-VMDvdDrive"
